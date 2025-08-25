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

void
spock_rmgr_init(void)
{
    RegisterCustomRmgr(SPOCK_RMGR_ID, &spock_custom_rmgr);
}


void
spock_rmgr_redo(XLogReaderState *record)
{
    uint8 info = XLogRecGetInfo(record) & XLR_RMGR_INFO_MASK;

	switch(info)
	{
		case SPOCK_RMGR_PROGRESS_INFO:
			{
				ProgressInfoEntry *entry;

				entry = (ProgressInfoEntry *) XLogRecGetData(record);
				(void) entry;
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

	switch(info)
	{
		case SPOCK_RMGR_PROGRESS_INFO:
			{
				ProgressInfoEntry *entry;

				entry = (ProgressInfoEntry *) XLogRecGetData(record);
				appendStringInfo(buf, "spock rmgr: entry for db %u, node %u, remote_node %u",
						entry->dbid,
						entry->node_id,
						entry->remote_node_id);
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
	switch(info)
	{
		case SPOCK_RMGR_PROGRESS_INFO:
			return "PROGRESS_INFO";
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

bool
ProgressEntryAddToWAL(ProgressInfoEntry *entry)
{
	return true;
}
