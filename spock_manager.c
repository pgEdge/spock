/*-------------------------------------------------------------------------
 *
 * spock_manager.c
 * 		spock worker for managing apply workers in a database
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
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

PGDLLEXPORT void spock_manager_main(Datum main_arg);

/*
 * Manage the apply workers - start new ones, kill old ones.
 */
static long
manage_apply_workers(void)
{
	SpockLocalNode *node;
	List	   *subscriptions;
	List	   *workers;
	List	   *subs_to_start = NIL;
	ListCell   *slc,
			   *wlc;
	long		ret = restart_delay_default;

	/* Get list of existing workers. */
	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
	workers = spock_apply_find_all(MySpockWorker->dboid);
	LWLockRelease(SpockCtx->lock);

	StartTransactionCommand();

	/* Get local node, exit if not found. */
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

		/*
		 * Skip if subscription not enabled.
		 * This must be called before the following search loop because
		 * we want to kill any workers for disabled subscription.
		 */
		if (!sub->enabled)
			continue;

		/* Check if the subscription already has registered worker. */
		foreach(wlc, workers)
		{
			apply = (SpockWorker *) lfirst(wlc);


			if (apply->worker.apply.subid == sub->id)
			{
				workers = foreach_delete_current(workers, wlc);
				break;
			}
		}

		/* If the subscription does not have a registered worker */
		if (!wlc)
			apply = NULL;

		/* Skip if the worker was alrady registered. */
		if (spock_worker_running(apply))
			continue;

		/*
		 * Check if this is a terminated worker and if we want to restart
		 * it now.
		 */
		if (apply)
		{
			if (apply->terminated_at != 0)
			{
				TimestampTz	restart_time;
				TimestampTz now = GetCurrentTimestamp();

				/*
				 * The requested restart time is restart_delay ms after
				 * the apply-worker had terminated.
				 */
				restart_time = TimestampTzPlusMilliseconds(apply->terminated_at,
														   apply->restart_delay);

				/*
				 * If it is not time to restart this apply-worker yet
				 * then skip it, but adjust the return value to the
				 * lowest ms when this function needs to be called again.
				 */
				if (restart_time >= now)
				{
					long delay;

					delay = TimestampDifferenceMilliseconds(now,
															restart_time);

					if (delay < ret)
						ret = delay;
					continue;
				}
				else
				{
					/* Ask for re-evaluation right now (in a ms) */
					ret = 1;
				}
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
		if (worker && worker->terminated_at != 0)
		{
			elog(DEBUG2, "cleaning spock worker slot %zu",
			     (worker - &SpockCtx->workers[0]));
			worker->worker_type = SPOCK_WORKER_NONE;
			worker->terminated_at = 0;
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

	/* Setup shmem. */
	spock_worker_attach(slot, SPOCK_WORKER_MANAGER);

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
		int		sleep_timer;

		/*
		 * Launch or restart apply-workers. This determines how long
		 * we have to wait before doing this again based on the restart
		 * delay of any abnormally terminated worker (possibly due to
		 * connection errors or exception handling).
		 */
		sleep_timer = manage_apply_workers();

		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   sleep_timer);

        ResetLatch(&MyProc->procLatch);

        /* emergency bailout if postmaster has died */
        if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		CHECK_FOR_INTERRUPTS();
	}

	proc_exit(0);
}
