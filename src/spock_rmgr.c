/*-------------------------------------------------------------------------
 *
 * spock_rmgr.c
 * 		spock resource manager definitions
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *
 * Spock Resource Manager (RMGR)
 * -----------------------------
 *
 * This module implements the WAL side of Spock's apply progress persistence.
 *
 *   - WAL is authoritative for progress. We emit compact progress records
 *     after each locally-committed, remotely-originated transaction on the
 *     subscriber, and REDO replays them into shared memory after crash/restart.
 *   - Shared memory holds a hash map keyed by (dbid, node_id, remote_node_id),
 *     storing the latest SpockApplyProgress snapshot for each group.
 *   - On clean shutdowns we also take a file snapshot (resource.dat) so restarts
 *     can seed shmem quickly; WAL REDO still runs after load and will overwrite
 *     any stale entries.
 *
 * Startup ordering:
 *   1) postmaster creates shared memory and runs shmem_startup_hook
 *        -> shmem_init()
 *        -> spock_group_resource_load() to load file snapshot (if any)
 *   2) startup process begins WAL recovery
 *        -> calls spock_rmgr_redo() for our records
 *        -> redo update the same shmem hash (wins over file load)
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xlog.h"
#include "access/xlog_internal.h"
#include "access/xloginsert.h"
#include "access/xlogreader.h"
#include "access/xlogrecord.h"
#include "utils/pg_lsn.h"

#include "spock_rmgr.h"
#include "spock_worker.h"
#include "spock_apply.h"

static RmgrData spock_custom_rmgr = {
	.rm_name = SPOCK_RMGR_NAME,
	.rm_redo = spock_rmgr_redo,
	.rm_desc = spock_rmgr_desc,
	.rm_identify = spock_rmgr_identify,
	.rm_startup = spock_rmgr_startup,
	.rm_cleanup = spock_rmgr_cleanup,
};

/*
 * spock_rmgr_init
 *
 * Register Spock's resource manager so our WAL records are recognized during
 * recovery. Called in _PG_init() before recovery can begin;
 * do not allocate shmem here.
 */
void
spock_rmgr_init(void)
{
	RegisterCustomRmgr(SPOCK_RMGR_ID, &spock_custom_rmgr);
}

/*
 * spock_rmgr_redo
 *
 * Redo handler for Spock WAL records. For APPLY_PROGRESS records, decode the
 * payload (SpockApplyProgress) and upsert into the shmem group registry via
 * spock_group_update_progress(). This runs during recovery and overwrites any
 * shmem contents previously seeded by file load.
 */
void
spock_rmgr_redo(XLogReaderState *record)
{
	uint8		info = XLogRecGetInfo(record) & XLR_RMGR_INFO_MASK;

	switch (info)
	{
		case SPOCK_RMGR_APPLY_PROGRESS:
			{
				SpockApplyProgress   *rec;

				rec = (SpockApplyProgress *) XLogRecGetData(record);

				/*
				 * During WAL replay, we must acquire locks when accessing
				 * shared hash tables (per commit c6d76d7 in PostgreSQL core).
				 * The spock_group_progress_update() function acquires
				 * apply_group_master_lock internally for us.
				 */
				(void) spock_group_progress_update(rec);
			}
			break;

		case SPOCK_RMGR_SUBTRANS_COMMIT_TS:
			break;

		default:
			elog(PANIC, "spock_rmgr_redo: unknown op code %u", info);
	}
}

void
spock_rmgr_desc(StringInfo buf, XLogReaderState *record)
{
	uint8		info = XLogRecGetInfo(record) & XLR_RMGR_INFO_MASK;

	switch (info)
	{
		case SPOCK_RMGR_APPLY_PROGRESS:
			{
				SpockApplyProgress   *rec;

				rec = (SpockApplyProgress *) XLogRecGetData(record);
				appendStringInfo(buf, "spock apply progress for dbid %u, node_id %u, remote_node_id %u; "
								 "remote_commit_lsn %X/%X, remote_insert_lsn %X/%X, received_lsn %X/%X",
								 rec->key.dbid,
								 rec->key.node_id,
								 rec->key.remote_node_id,
								 LSN_FORMAT_ARGS(rec->remote_commit_lsn),
								 LSN_FORMAT_ARGS(rec->remote_insert_lsn),
								 LSN_FORMAT_ARGS(rec->received_lsn));
			}
			break;
		case SPOCK_RMGR_SUBTRANS_COMMIT_TS:
			appendStringInfo(buf, "spock rmgr: sub transaction commit ts");
			break;

		default:
			appendStringInfo(buf, "spock rmgr: unknown(%u)", info);
	}
}

const char *
spock_rmgr_identify(uint8 info)
{
	switch (info)
	{
		case SPOCK_RMGR_APPLY_PROGRESS:
			return "APPLY_PROGRESS";
			break;
		case SPOCK_RMGR_SUBTRANS_COMMIT_TS:
			return "SUBTRANS_COMMIT_TS";
			break;
	}

	return NULL;
}

void
spock_rmgr_startup(void)
{
}

void
spock_rmgr_cleanup(void)
{
}

/*
 * spock_apply_progress_add_to_wal
 *
 * Emit and flush a progress record to WAL after committing a remote-origin
 * transaction locally. This makes the progress update durable and guarantees
 * redo will restore it after crash.
 *
 *   - Must be called *after* CommitTransactionCommand() of the applied txn.
 *   - Uses info code SPOCK_RMGR_APPLY_PROGRESS (0x10).
 *
 * Returns: the LSN of the inserted record.
 */
XLogRecPtr
spock_apply_progress_add_to_wal(const SpockApplyProgress *sap)
{
	XLogRecPtr			lsn;

	Assert(sap != NULL);

	XLogBeginInsert();
	XLogRegisterData((char *) sap, sizeof(SpockApplyProgress));
	lsn = XLogInsert(SPOCK_RMGR_ID, SPOCK_RMGR_APPLY_PROGRESS);

	/*
	 * Force the WAL record to disk immediately. This ensures that progress
	 * is durably recorded before we update the in-memory state and continue
	 * processing. If we crash after updating memory but before the WAL
	 * flushes, we could lose progress tracking and replay would be incorrect.
	 */
	XLogFlush(lsn);

	return lsn;
}
