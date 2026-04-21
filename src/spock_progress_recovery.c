/*-------------------------------------------------------------------------
 *
 * spock_progress_recovery.c
 * 		Set up an apply worker's spock.progress shmem entry at startup.
 *
 * After WAL recovery loads PGDATA/spock/resource.dat into shmem, the apply
 * worker calls spock_init_progress_state() to reconcile its entry against
 * the durable replication origin LSN. If the loaded file is stale, the
 * commit LSN is advanced from the origin and the timestamp fields are
 * cleared (later restored by recover_progress_timestamps_from_commit_ts()).
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"

#include "access/xact.h"
#include "access/xlog.h"
#include "datatype/timestamp.h"
#include "replication/origin.h"
#include "storage/condition_variable.h"
#include "storage/lwlock.h"
#include "utils/hsearch.h"
#include "utils/rel.h"

#include "spock_group.h"
#include "spock_node.h"
#include "spock_progress_recovery.h"
#include "spock_worker.h"

static void reconcile_progress_with_origin(XLogRecPtr origin_lsn);

/*
 * spock_init_progress_state
 *
 * Public entry point: reconcile the apply worker's shmem entry against the
 * replication origin. Called once between replorigin_session_setup() and
 * spock_start_replication().
 */
void
spock_init_progress_state(XLogRecPtr origin_lsn)
{
	reconcile_progress_with_origin(origin_lsn);
}

/*
 * Reconcile this worker's shmem progress entry against the replication
 * origin's LSN. Called once at worker startup after replorigin_session_setup
 * but before entering the apply loop.
 *
 * - Entry absent: initialize with origin_lsn, other fields zero/NULL.
 * - Entry present, file_lsn == origin_lsn: file is in sync; keep timestamps.
 * - Entry present, file_lsn <  origin_lsn: file is stale; clear timestamps.
 * - Entry present, file_lsn >  origin_lsn: anomalous; prefer origin_lsn.
 *
 * remote_insert_lsn and received_lsn are left alone here; the forced
 * keepalive sent right after spock_start_replication will overwrite them.
 */
static void
reconcile_progress_with_origin(XLogRecPtr origin_lsn)
{
	SpockGroupKey	key;
	SpockGroupEntry *entry;
	bool			found;

	if (!SpockGroupHash || !SpockCtx)
	{
		elog(WARNING, "SPOCK %s: SpockGroupHash is not initialized; reconcile skipped",
			 MySubscription->name);
		return;
	}

	key.dbid = MyDatabaseId;
	key.node_id = MySubscription->target->id;
	key.remote_node_id = MySubscription->origin->id;

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);

	entry = (SpockGroupEntry *) hash_search(SpockGroupHash, &key,
											HASH_ENTER, &found);
	if (entry == NULL)
	{
		LWLockRelease(SpockCtx->apply_group_master_lock);
		elog(WARNING, "SpockGroupHash is full, cannot reconcile progress for "
			 "(dbid=%u, node_id=%u, remote_node_id=%u)",
			 key.dbid, key.node_id, key.remote_node_id);
		return;
	}

	if (!found)
	{
		/*
		 * New entry: hash_search already copied the key into
		 * entry->progress.key. Zero the remaining fields inline because
		 * init_progress_fields is static to spock_group.c.
		 *
		 * MAINTENANCE: if SpockApplyProgress gains new fields, this block
		 * must be updated in lockstep with init_progress_fields in
		 * spock_group.c:init_progress_fields().
		 */
		Assert(OidIsValid(entry->progress.key.dbid));
		Assert(OidIsValid(entry->progress.key.node_id));
		Assert(OidIsValid(entry->progress.key.remote_node_id));
		entry->progress.remote_commit_ts = 0;
		entry->progress.prev_remote_ts = 0;
		entry->progress.remote_commit_lsn = origin_lsn;
		entry->progress.remote_insert_lsn = InvalidXLogRecPtr;
		entry->progress.received_lsn = InvalidXLogRecPtr;
		entry->progress.last_updated_ts = 0;
		entry->progress.updated_by_decode = false;
		pg_atomic_init_u32(&entry->nattached, 0);
		ConditionVariableInit(&entry->prev_processed_cv);
		elog(LOG, "SPOCK %s: reconcile: new entry seeded at origin LSN %X/%X",
			 MySubscription->name, LSN_FORMAT_ARGS(origin_lsn));
	}
	else if (entry->progress.remote_commit_lsn == origin_lsn)
	{
		/* File and origin agree; keep timestamps. */
		elog(DEBUG1, "SPOCK %s: reconcile: file LSN matches origin (%X/%X)",
			 MySubscription->name, LSN_FORMAT_ARGS(origin_lsn));
	}
	else if (entry->progress.remote_commit_lsn < origin_lsn)
	{
		/* File is stale. Overwrite LSN, clear timestamp fields. */
		elog(LOG, "SPOCK %s: reconcile: file LSN %X/%X stale vs origin %X/%X; clearing ts",
			 MySubscription->name,
			 LSN_FORMAT_ARGS(entry->progress.remote_commit_lsn),
			 LSN_FORMAT_ARGS(origin_lsn));
		entry->progress.remote_commit_lsn = origin_lsn;
		entry->progress.remote_commit_ts = 0;
		entry->progress.prev_remote_ts = 0;
		entry->progress.last_updated_ts = 0;
		/*
		 * Preserve the invariant remote_insert_lsn >= remote_commit_lsn.
		 * If we only advance commit_lsn, later calls to
		 * progress_update_struct will assert-fail. The publisher's forced
		 * keepalive on reconnect will refresh remote_insert_lsn to a
		 * current value; until then, pinning it to origin_lsn is correct
		 * (any prior commit has necessarily already been inserted).
		 */
		if (entry->progress.remote_insert_lsn < origin_lsn)
			entry->progress.remote_insert_lsn = origin_lsn;
		if (entry->progress.received_lsn < origin_lsn)
			entry->progress.received_lsn = origin_lsn;
	}
	else
	{
		/* Anomaly: file ahead of origin. Trust origin. */
		elog(WARNING, "SPOCK %s: reconcile: file LSN %X/%X ahead of origin %X/%X; trusting origin",
			 MySubscription->name,
			 LSN_FORMAT_ARGS(entry->progress.remote_commit_lsn),
			 LSN_FORMAT_ARGS(origin_lsn));
		entry->progress.remote_commit_lsn = origin_lsn;
		entry->progress.remote_commit_ts = 0;
		entry->progress.prev_remote_ts = 0;
		entry->progress.last_updated_ts = 0;
		/* Same invariant fix as above. */
		if (entry->progress.remote_insert_lsn < origin_lsn)
			entry->progress.remote_insert_lsn = origin_lsn;
		if (entry->progress.received_lsn < origin_lsn)
			entry->progress.received_lsn = origin_lsn;
	}

	LWLockRelease(SpockCtx->apply_group_master_lock);
}
