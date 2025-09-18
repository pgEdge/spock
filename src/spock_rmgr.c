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

const RmgrData spock_custom_rmgr = {
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
				SpockApplyProgress *sap;

				sap = (SpockApplyProgress *) XLogRecGetData(record);

				/* LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE); */

				spock_group_progress_update(sap);
				/* LWLockRelease(SpockCtx->lock); */
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
				SpockApplyProgress *sap;

				sap = (SpockApplyProgress *) XLogRecGetData(record);
				appendStringInfo(buf, "spock apply progress for db %u, node %u, remote_node %u",
								 sap->key.dbid,
								 sap->key.node_id,
								 sap->key.remote_node_id);
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
	XLogRecPtr	lsn;

	Assert(sap != NULL);

	XLogBeginInsert();
	XLogRegisterData((char *) sap, sizeof(SpockApplyProgress));
	lsn = XLogInsert(SPOCK_RMGR_ID, SPOCK_RMGR_APPLY_PROGRESS);

	return lsn;
}
