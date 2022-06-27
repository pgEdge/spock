/*-------------------------------------------------------------------------
 *
 * spock_manager.c
 * 		spock worker for managing apply workers in a database
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *		  spock_manager.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"

#include "access/xact.h"

#include "commands/dbcommands.h"
#include "commands/extension.h"

#include "storage/ipc.h"
#include "storage/proc.h"

#include "utils/memutils.h"
#include "utils/resowner.h"
#include "utils/timestamp.h"

#include "pgstat.h"

#include "spock_node.h"
#include "spock_worker.h"
#include "spock.h"

#define INITIAL_SLEEP 10000L
#define MAX_SLEEP 180000L
#define MIN_SLEEP 5000L

void spock_manager_main(Datum main_arg);

/*
 * Manage the apply workers - start new ones, kill old ones.
 */
static bool
manage_apply_workers(void)
{
	SpockLocalNode *node;
	List	   *subscriptions;
	List	   *workers;
	List	   *subs_to_start = NIL;
	ListCell   *slc,
			   *wlc;
	bool		ret = true;

	/* Get list of existing workers. */
	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
	workers = spock_apply_find_all(MySpockWorker->dboid);
	LWLockRelease(SpockCtx->lock);

	StartTransactionCommand();

	/* Get local node, exit if no found. */
	node = get_local_node(true, true);
	if (!node)
		proc_exit(0);

	/* Get list of subscribers. */
	subscriptions = get_node_subscriptions(node->node->id, false);

	/* Check for active workers for each subscription. */
	foreach (slc, subscriptions)
	{
		SpockSubscription  *sub = (SpockSubscription *) lfirst(slc);
		SpockWorker		   *apply = NULL;
#if PG_VERSION_NUM < 130000
		ListCell			   *next;
		ListCell			   *prev = NULL;
#endif

		/*
		 * Skip if subscriber not enabled.
		 * This must be called before the following search loop because
		 * we want to kill any workers for disabled subscribers.
		 */
		if (!sub->enabled)
			continue;

		/* Check if the subscriber already has registered worker. */
#if PG_VERSION_NUM >= 130000
		foreach(wlc, workers)
#else
		for (wlc = list_head(workers); wlc; wlc = next)
#endif
		{
			apply = (SpockWorker *) lfirst(wlc);

#if PG_VERSION_NUM < 130000
			/* We might delete the cell so advance it now. */
			next = lnext(wlc);
#endif

			if (apply->worker.apply.subid == sub->id)
			{
#if PG_VERSION_NUM >= 130000
				workers = foreach_delete_current(workers, wlc);
#else
				workers = list_delete_cell(workers, wlc, prev);
#endif
				break;
			}
			else
			{
#if PG_VERSION_NUM < 130000
				prev = wlc;
#endif
			}
		}
		/* If the subscriber does not have a registered worker. */
		if (!wlc)
			apply = NULL;

		/* Skip if the worker was alrady registered. */
		if (spock_worker_running(apply))
			continue;

		/* Check if this is crashed worker and if we want to restart it now. */
		if (apply)
		{
			if (apply->crashed_at != 0)
			{
				TimestampTz	restart_time;

				restart_time = TimestampTzPlusMilliseconds(apply->crashed_at,
														   MIN_SLEEP);

				if (restart_time > GetCurrentTimestamp())
				{
					ret = false;
					continue;
				}
			}
			else
			{
				ret = false;
				continue;
			}
		}

		subs_to_start = lappend(subs_to_start, sub);
	}

	foreach (slc, subs_to_start)
	{
		SpockSubscription  *sub = (SpockSubscription *) lfirst(slc);
		SpockWorker			apply;

		memset(&apply, 0, sizeof(SpockWorker));
		apply.worker_type = SPOCK_WORKER_APPLY;
		apply.dboid = MySpockWorker->dboid;
		apply.worker.apply.subid = sub->id;
		apply.worker.apply.sync_pending = true;
		apply.worker.apply.replay_stop_lsn = InvalidXLogRecPtr;

		spock_worker_register(&apply);
	}

	CommitTransactionCommand();

	/* Kill any remaining running workers that should not be running. */
	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
	foreach (wlc, workers)
	{
		SpockWorker *worker = (SpockWorker *) lfirst(wlc);
		spock_worker_kill(worker);

		/* Cleanup old info about crashed apply workers. */
		if (worker && worker->crashed_at != 0)
		{
			elog(DEBUG2, "cleaning spock worker slot %zu",
			     (worker - &SpockCtx->workers[0]));
			worker->worker_type = SPOCK_WORKER_NONE;
			worker->crashed_at = 0;
		}
	}
	LWLockRelease(SpockCtx->lock);

	return ret;
}

/*
 * Entry point for manager worker.
 */
void
spock_manager_main(Datum main_arg)
{
	int			slot = DatumGetInt32(main_arg);
	Oid			extoid;
	int			sleep_timer = INITIAL_SLEEP;

	/* Setup shmem. */
	spock_worker_attach(slot, SPOCK_WORKER_MANAGER);

	/* Establish signal handlers. */
	pqsignal(SIGTERM, handle_sigterm);

	CurrentResourceOwner = ResourceOwnerCreate(NULL, "spock manager");

	StartTransactionCommand();

	/* If the extension is not installed in this DB, exit. */
	extoid = get_extension_oid(EXTENSION_NAME, true);
	if (!OidIsValid(extoid))
		proc_exit(0);

	elog(LOG, "starting spock database manager for database %s",
		 get_database_name(MyDatabaseId));

	CommitTransactionCommand();

	/* Use separate transaction to avoid lock escalation. */
	StartTransactionCommand();
	spock_manage_extension();
	CommitTransactionCommand();

	/* Main wait loop. */
	while (!got_SIGTERM)
    {
		int		rc;
		bool	processed_all;

		/* Launch the apply workers. */
		processed_all = manage_apply_workers();

		/* Handle sequences and update our sleep timer as necessary. */
		if (synchronize_sequences())
			sleep_timer = Min(sleep_timer * 2, MAX_SLEEP);
		else
			sleep_timer = Max(sleep_timer / 2, MIN_SLEEP);

		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   processed_all ? sleep_timer : MIN_SLEEP);

        ResetLatch(&MyProc->procLatch);

        /* emergency bailout if postmaster has died */
        if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		CHECK_FOR_INTERRUPTS();
	}

	proc_exit(0);
}
