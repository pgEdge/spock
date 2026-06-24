/*-------------------------------------------------------------------------
 *
 * spock_rmgr.c
 * 		spock resource manager definitions
 *
 * Emits one WAL record per SpockGroupHash entry on each resource.dat dump
 * event so operators can correlate the persisted progress snapshot with
 * WAL position via pg_waldump. Each record carries the full
 * SpockApplyProgress for one entry, the event type, and the (seq, total)
 * pair within the dump event so consumers can reassemble.
 *
 * The records are not required for state recovery: shmem is reseeded at
 * startup from resource.dat plus replication-origin reconcile plus
 * pg_commit_ts scan. Their value is showing what state was on disk at
 * each dump LSN -- useful for incident reconstruction over time.
 *
 * Volume is N entries × handful per cluster per day in normal operation
 * (one event per clean shutdown + one per add_node + one per table sync),
 * so a single XLogFlush at the end of each emit batch is cheap and gives
 * WAL durability symmetric with resource.dat's durable_rename().
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xlog.h"
#include "access/xlog_internal.h"
#include "access/xloginsert.h"
#include "access/xlogreader.h"
#include "access/xlogrecord.h"
#include "storage/lwlock.h"
#include "utils/hsearch.h"

#include "spock_rmgr.h"
#include "spock_worker.h"

static RmgrData spock_custom_rmgr = {
	.rm_name = SPOCK_RMGR_NAME,
	.rm_redo = spock_rmgr_redo,
	.rm_desc = spock_rmgr_desc,
	.rm_identify = spock_rmgr_identify,
	.rm_startup = NULL,
	.rm_cleanup = NULL,
};

void
spock_rmgr_init(void)
{
	RegisterCustomRmgr(SPOCK_RMGR_ID, &spock_custom_rmgr);
}

/*
 * Translate the event_type byte to a stable string for log/desc output.
 */
static const char *
event_name(uint8 event_type)
{
	switch ((SpockResourceDumpEvent) event_type)
	{
		case SPOCK_DUMP_SHUTDOWN:
			return "shutdown";
		case SPOCK_DUMP_ADD_NODE:
			return "add_node";
		case SPOCK_DUMP_TABLE_SYNC:
			return "table_sync";
	}
	return "unknown";
}

/*
 * Replay handler: log only. The actual progress data is reseeded by
 * spock_group_resource_load() (file) plus reconcile_progress_with_origin()
 * (origin) plus the commit_ts recovery scan -- none of which touch this
 * record. We just log so it's visible in recovery logs.
 */
void
spock_rmgr_redo(XLogReaderState *record)
{
	uint8		info = XLogRecGetInfo(record) & XLR_RMGR_INFO_MASK;

	switch (info)
	{
		case SPOCK_RMGR_RESOURCE_DUMP:
			{
				SpockResourceDumpRec *rec;

				rec = (SpockResourceDumpRec *) XLogRecGetData(record);
				elog(LOG,
					 "SPOCK rmgr: resource.dat dump replayed "
					 "(event=%s, entry %u/%u, dbid=%u node_id=%u remote_node_id=%u, "
					 "remote_commit_lsn=%X/%X remote_insert_lsn=%X/%X received_lsn=%X/%X, "
					 "remote_commit_ts=" INT64_FORMAT ")",
					 event_name(rec->event_type),
					 (unsigned) rec->entry_seq + 1, (unsigned) rec->entry_total,
					 rec->progress.key.dbid,
					 rec->progress.key.node_id,
					 rec->progress.key.remote_node_id,
					 LSN_FORMAT_ARGS(rec->progress.remote_commit_lsn),
					 LSN_FORMAT_ARGS(rec->progress.remote_insert_lsn),
					 LSN_FORMAT_ARGS(rec->progress.received_lsn),
					 (int64) rec->progress.remote_commit_ts);
				break;
			}
		default:
			elog(WARNING,
				 "SPOCK rmgr: unknown info byte 0x%02x in WAL record; ignoring",
				 info);
			break;
	}
}

/*
 * pg_waldump descriptor: appended after the standard rmgr/info header.
 */
void
spock_rmgr_desc(StringInfo buf, XLogReaderState *record)
{
	uint8		info = XLogRecGetInfo(record) & XLR_RMGR_INFO_MASK;

	if (info == SPOCK_RMGR_RESOURCE_DUMP)
	{
		SpockResourceDumpRec *rec = (SpockResourceDumpRec *) XLogRecGetData(record);

		appendStringInfo(buf,
						 "event=%s entry=%u/%u "
						 "key=(%u,%u,%u) "
						 "commit_lsn=%X/%X insert_lsn=%X/%X received_lsn=%X/%X "
						 "commit_ts=" INT64_FORMAT,
						 event_name(rec->event_type),
						 (unsigned) rec->entry_seq + 1, (unsigned) rec->entry_total,
						 rec->progress.key.dbid,
						 rec->progress.key.node_id,
						 rec->progress.key.remote_node_id,
						 LSN_FORMAT_ARGS(rec->progress.remote_commit_lsn),
						 LSN_FORMAT_ARGS(rec->progress.remote_insert_lsn),
						 LSN_FORMAT_ARGS(rec->progress.received_lsn),
						 (int64) rec->progress.remote_commit_ts);
	}
}

/*
 * pg_waldump identifier: maps info byte -> human-readable name.
 */
const char *
spock_rmgr_identify(uint8 info)
{
	switch (info & XLR_RMGR_INFO_MASK)
	{
		case SPOCK_RMGR_RESOURCE_DUMP:
			return "RESOURCE_DUMP";
	}
	return NULL;
}

/*
 * Build and insert one SPOCK_RMGR_RESOURCE_DUMP record for `progress`.
 * Returns the inserted record's LSN.
 */
static XLogRecPtr
emit_one_dump_record(SpockResourceDumpEvent event,
					 uint16 entry_seq, uint16 entry_total,
					 const SpockApplyProgress *progress)
{
	SpockResourceDumpRec rec;

	memset(&rec, 0, sizeof(rec));
	rec.event_type = (uint8) event;
	rec.entry_seq = entry_seq;
	rec.entry_total = entry_total;
	rec.progress = *progress;

	XLogBeginInsert();
	XLogRegisterData((char *) &rec, sizeof(rec));
	return XLogInsert(SPOCK_RMGR_ID, SPOCK_RMGR_RESOURCE_DUMP);
}

/*
 * Emit one WAL record per progress entry, then flush once at the end. If
 * changed_entries is NULL, walks the full SpockGroupHash; otherwise iterates
 * the supplied list of SpockApplyProgress*.
 */
void
spock_rmgr_log_resource_dump(SpockResourceDumpEvent event,
							 List *changed_entries)
{
	XLogRecPtr	last_recptr = InvalidXLogRecPtr;
	uint32		entry_total;
	uint16		entry_seq = 0;

	if (SpockGroupHash == NULL || SpockCtx == NULL)
		return;

	if (changed_entries != NULL)
	{
		ListCell   *lc;

		entry_total = list_length(changed_entries);
		if (entry_total == 0)
			return;

		foreach(lc, changed_entries)
		{
			SpockApplyProgress *sap = (SpockApplyProgress *) lfirst(lc);

			last_recptr = emit_one_dump_record(event, entry_seq++,
											   (uint16) entry_total, sap);
		}
	}
	else
	{
		HASH_SEQ_STATUS scan;
		SpockGroupEntry *entry;

		LWLockAcquire(SpockCtx->apply_group_master_lock, LW_SHARED);

		entry_total = hash_get_num_entries(SpockGroupHash);
		if (entry_total == 0)
		{
			LWLockRelease(SpockCtx->apply_group_master_lock);
			return;
		}

		hash_seq_init(&scan, SpockGroupHash);
		while ((entry = (SpockGroupEntry *) hash_seq_search(&scan)) != NULL)
			last_recptr = emit_one_dump_record(event, entry_seq++,
											   (uint16) entry_total,
											   &entry->progress);

		LWLockRelease(SpockCtx->apply_group_master_lock);
	}

	if (!XLogRecPtrIsInvalid(last_recptr))
		XLogFlush(last_recptr);
}
