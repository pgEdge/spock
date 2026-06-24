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

#include "access/commit_ts.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "datatype/timestamp.h"
#include "replication/origin.h"
#include "storage/condition_variable.h"
#include "storage/lwlock.h"
#include "utils/hsearch.h"
#include "utils/rel.h"
#include "utils/timestamp.h"

#include "spock_group.h"
#include "spock_node.h"
#include "spock_progress_recovery.h"
#include "spock_worker.h"

/*
 * Constants governing the post-crash scan of pg_commit_ts that recovers
 * remote_commit_ts per origin. Plain #defines for now; convert to GUCs only
 * if a deployment ever needs to tune them.
 */
#define SPOCK_TS_RECOVERY_MIN_SEEN_PER_ORIGIN	1000
#define SPOCK_TS_RECOVERY_SCAN_LIMIT			1000000
#define SPOCK_TS_RECOVERY_BATCH_SIZE			1000

typedef enum ReconcileResult
{
	RECONCILE_FILE_IN_SYNC,		/* file_lsn == origin_lsn; recovery scan can
								 * skip */
	RECONCILE_FILE_STALE,		/* file_lsn <  origin_lsn; recovery scan
								 * needed */
	RECONCILE_FILE_ANOMALY,		/* file_lsn >  origin_lsn; recovery scan
								 * needed */
	RECONCILE_FILE_ABSENT		/* no entry was loaded; recovery scan needed */
} ReconcileResult;

static ReconcileResult reconcile_progress_with_origin(XLogRecPtr origin_lsn);
static void recover_progress_timestamps_from_commit_ts(SpockGroupEntry *entry,
													   RepOriginId target_origin);

/*
 * spock_init_progress_state
 *
 * Public entry point: reconcile the apply worker's shmem entry against the
 * replication origin, and if reconcile detected staleness, scan pg_commit_ts
 * to recover the timestamp fields. Called once between
 * replorigin_session_setup() and spock_start_replication().
 */
void
spock_init_progress_state(XLogRecPtr origin_lsn)
{
	ReconcileResult result;
	SpockGroupKey key;
	SpockGroupEntry *entry;
	bool		found;

	/*
	 * Defense in depth: reconcile_progress_with_origin returns ABSENT on NULL
	 * shmem rather than dereferencing it, but the rest of this function does
	 * dereference SpockCtx/SpockGroupHash. Mirror the guard so the
	 * caller-visible contract is self-consistent.
	 */
	if (!SpockCtx || !SpockGroupHash)
		return;

	result = reconcile_progress_with_origin(origin_lsn);

	if (result == RECONCILE_FILE_IN_SYNC)
	{
		elog(LOG, "SPOCK %s: ts recovery: file in sync with origin, skipping scan",
			 MySubscription->name);
		return;
	}

	/*
	 * Fresh subscription: replication origin has never recorded progress.
	 * pg_commit_ts may still hold rows for this publisher's spock node id
	 * from a prior subscription -- scanning would backfill stale historical
	 * timestamps unrelated to the current subscription's actual state.
	 */
	if (XLogRecPtrIsInvalid(origin_lsn))
	{
		elog(LOG, "SPOCK %s: ts recovery: no durable origin progress yet, skipping scan",
			 MySubscription->name);
		return;
	}

	key.dbid = MyDatabaseId;
	key.node_id = MySubscription->target->id;
	key.remote_node_id = MySubscription->origin->id;

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_SHARED);
	entry = (SpockGroupEntry *) hash_search(SpockGroupHash, &key,
											HASH_FIND, &found);
	LWLockRelease(SpockCtx->apply_group_master_lock);

	if (entry != NULL)
	{
		/*
		 * The apply worker overwrites replorigin_session_origin per-message
		 * with the publisher's spock node id (handle_origin) and that value
		 * is what pg_commit_ts records for applied xacts on the subscriber --
		 * NOT the local subscription's roident. Filter the scan on
		 * MySubscription->origin->id so we match the recorded entries.
		 *
		 * Limitation: this filter is not subscription-unique. Sibling subs to
		 * the same publisher, or a dropped/recreated sub with old commits
		 * still in the 1M-xid window, can contribute to running_max_ts.
		 * Forensic-only impact; parallel-apply rework will revisit.
		 */
		recover_progress_timestamps_from_commit_ts(entry,
												   (RepOriginId) MySubscription->origin->id);
	}
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
static ReconcileResult
reconcile_progress_with_origin(XLogRecPtr origin_lsn)
{
	SpockGroupKey key;
	SpockGroupEntry *entry;
	bool		found;
	ReconcileResult result;

	if (!SpockGroupHash || !SpockCtx)
	{
		elog(WARNING, "SPOCK %s: SpockGroupHash is not initialized; reconcile skipped",
			 MySubscription->name);
		return RECONCILE_FILE_ABSENT;
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
		return RECONCILE_FILE_ABSENT;
	}

	if (!found)
	{
		/*
		 * New entry: hash_search already copied the key into
		 * entry->progress.key.  Reset the rest via the same helper that the
		 * hash insert path uses, then position the LSN fields at origin_lsn
		 * so this worker starts from the durable origin position and the
		 * insert >= commit invariant holds.
		 */
		spock_init_progress_fields(&entry->progress);
		entry->progress.remote_commit_lsn = origin_lsn;
		entry->progress.remote_insert_lsn = origin_lsn;
		entry->progress.received_lsn = origin_lsn;
		pg_atomic_init_u32(&entry->nattached, 0);
		ConditionVariableInit(&entry->prev_processed_cv);
		elog(LOG, "SPOCK %s: reconcile: new entry seeded at origin LSN %X/%X",
			 MySubscription->name, LSN_FORMAT_ARGS(origin_lsn));
		result = RECONCILE_FILE_ABSENT;
	}
	else if (entry->progress.remote_commit_lsn == origin_lsn)
	{
		/* File and origin agree; keep timestamps. */
		elog(DEBUG1, "SPOCK %s: reconcile: file LSN matches origin (%X/%X)",
			 MySubscription->name, LSN_FORMAT_ARGS(origin_lsn));
		result = RECONCILE_FILE_IN_SYNC;
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
		 * Preserve the invariant remote_insert_lsn >= remote_commit_lsn. If
		 * we only advance commit_lsn, later calls to progress_update_struct
		 * will assert-fail. The publisher's forced keepalive on reconnect
		 * will refresh remote_insert_lsn to a current value; until then,
		 * pinning it to origin_lsn is correct (any prior commit has
		 * necessarily already been inserted).
		 */
		if (entry->progress.remote_insert_lsn < origin_lsn)
			entry->progress.remote_insert_lsn = origin_lsn;
		if (entry->progress.received_lsn < origin_lsn)
			entry->progress.received_lsn = origin_lsn;
		result = RECONCILE_FILE_STALE;
	}
	else
	{
		/*
		 * Anomaly: file ahead of origin.  Most likely cause is operator
		 * intervention on the replication origin (e.g.
		 * pg_replication_origin_advance to roll back) or filesystem
		 * corruption.  We trust origin because that is the value Postgres
		 * will use for incoming WAL acknowledgements; the file's values are
		 * recorded in the log so an operator can recover them after the fact
		 * if the trust-origin choice turns out to be wrong.
		 */
		elog(WARNING,
			 "SPOCK %s: reconcile: file LSN %X/%X ahead of origin %X/%X; trusting origin "
			 "(discarded file values: commit_lsn=%X/%X insert_lsn=%X/%X received_lsn=%X/%X "
			 "commit_ts=" INT64_FORMAT " prev_remote_ts=" INT64_FORMAT
			 " last_updated_ts=" INT64_FORMAT ")",
			 MySubscription->name,
			 LSN_FORMAT_ARGS(entry->progress.remote_commit_lsn),
			 LSN_FORMAT_ARGS(origin_lsn),
			 LSN_FORMAT_ARGS(entry->progress.remote_commit_lsn),
			 LSN_FORMAT_ARGS(entry->progress.remote_insert_lsn),
			 LSN_FORMAT_ARGS(entry->progress.received_lsn),
			 (int64) entry->progress.remote_commit_ts,
			 (int64) entry->progress.prev_remote_ts,
			 (int64) entry->progress.last_updated_ts);
		entry->progress.remote_commit_lsn = origin_lsn;
		entry->progress.remote_commit_ts = 0;
		entry->progress.prev_remote_ts = 0;
		entry->progress.last_updated_ts = 0;
		/* Same invariant fix as above. */
		if (entry->progress.remote_insert_lsn < origin_lsn)
			entry->progress.remote_insert_lsn = origin_lsn;
		if (entry->progress.received_lsn < origin_lsn)
			entry->progress.received_lsn = origin_lsn;
		result = RECONCILE_FILE_ANOMALY;
	}

	LWLockRelease(SpockCtx->apply_group_master_lock);
	return result;
}

/*
 * recover_progress_timestamps_from_commit_ts
 *
 * After reconcile detects that resource.dat is stale (or absent) for this
 * origin, scan pg_commit_ts backward from the latest xid to recover the
 * most-recent remote_commit_ts for this origin. Restores accurate
 * post-crash values in the spock.progress view; the recovered values are
 * also intended to be useful for the planned parallel-apply rework.
 *
 * Termination: stop after observing SPOCK_TS_RECOVERY_MIN_SEEN_PER_ORIGIN
 * commits for this origin (any older commit is guaranteed to have a smaller
 * commit_ts under realistic concurrency widths) or after scanning
 * SPOCK_TS_RECOVERY_SCAN_LIMIT total xids.
 *
 * Caller must have ensured the entry exists in SpockGroupHash (reconcile
 * does this).
 */
static void
recover_progress_timestamps_from_commit_ts(SpockGroupEntry *entry,
										   RepOriginId target_origin)
{
	TransactionId xid_high;
	TimestampTz running_max_ts = 0;
	int			seen_count = 0;
	int64		total_scanned = 0;

	xid_high = ReadNextTransactionId();
	if (TransactionIdPrecedes(xid_high, FirstNormalTransactionId + 1))
	{
		elog(LOG, "SPOCK %s: ts recovery: no normal transactions yet; skipping",
			 MySubscription->name);
		return;
	}
	xid_high = xid_high - 1;

	while (seen_count < SPOCK_TS_RECOVERY_MIN_SEEN_PER_ORIGIN
		   && total_scanned < SPOCK_TS_RECOVERY_SCAN_LIMIT)
	{
		TransactionId xid_low;
		TransactionId xid;
		int64		batch_count;

		CHECK_FOR_INTERRUPTS();

		/* Compute batch lower bound, clamped at FirstNormalTransactionId. */
		if (TransactionIdPrecedes(xid_high,
								  FirstNormalTransactionId + SPOCK_TS_RECOVERY_BATCH_SIZE))
			xid_low = FirstNormalTransactionId;
		else
			xid_low = xid_high - SPOCK_TS_RECOVERY_BATCH_SIZE + 1;

		batch_count = (int64) xid_high - (int64) xid_low + 1;

		for (xid = xid_low; TransactionIdPrecedes(xid, xid_high + 1); xid++)
		{
			TimestampTz ts;
			RepOriginId origin;

			if (!TransactionIdGetCommitTsData(xid, &ts, &origin))
				continue;		/* aborted, vacuumed, or no commit_ts */
			if (origin != target_origin)
				continue;		/* local writes / other origins */

			seen_count++;
			if (ts > running_max_ts)
				running_max_ts = ts;
		}

		total_scanned += batch_count;

		if (xid_low == FirstNormalTransactionId)
			break;				/* wraparound floor */

		xid_high = xid_low - 1;
	}

	if (running_max_ts > 0)
	{
		LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);
		if (entry->progress.remote_commit_ts < running_max_ts)
		{
			entry->progress.remote_commit_ts = running_max_ts;
			entry->progress.prev_remote_ts = running_max_ts;

			/*
			 * Local apply time isn't recoverable post-crash. Use
			 * remote_commit_ts as a lower bound; refreshes on the next
			 * applied commit.
			 */
			entry->progress.last_updated_ts = running_max_ts;
		}
		LWLockRelease(SpockCtx->apply_group_master_lock);

		elog(LOG, "SPOCK %s: ts recovery: scanned %lld xids, found %d commits, "
			 "recovered remote_commit_ts",
			 MySubscription->name, (long long) total_scanned, seen_count);
	}
	else
	{
		elog(WARNING, "SPOCK %s: ts recovery: scanned %lld xids, no commits found "
			 "for origin %u; remote_commit_ts remains NULL until next applied commit",
			 MySubscription->name, (long long) total_scanned, target_origin);
	}
}
