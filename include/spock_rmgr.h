/*-------------------------------------------------------------------------
 *
 * spock_rmgr.h
 * 		spock resource manager declarations
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_RMGR_H
#define SPOCK_RMGR_H

#include "access/xlog.h"
#include "access/xlog_internal.h"

#include "spock_group.h"

/* Spock resouce manager */
#define SPOCK_RMGR_NAME             	    "spock_custom_rmgr"
#define SPOCK_RMGR_ID		    	        144

/* Spock RMGR tags. */
#define SPOCK_RMGR_APPLY_PROGRESS			0x10
#define SPOCK_RMGR_SUBTRANS_COMMIT_TS       0x20

typedef struct SpockApplyProgress SpockApplyProgress;

#if 0
typedef struct SubTransactionCommitTsEntry
{
	TransactionId xid;
	TimestampTz time;
	RepOriginId nodeid;
} SubTransactionCommitTsEntry;
#endif

/* RMGR function declarations */
extern void spock_rmgr_init(void);
extern void spock_rmgr_desc(StringInfo buf, XLogReaderState *record);
extern const char *spock_rmgr_identify(uint8 info);
extern void spock_rmgr_redo(XLogReaderState *record);
extern void spock_rmgr_startup(void);
extern void spock_rmgr_cleanup(void);

/* WAL helpers */
extern XLogRecPtr spock_apply_progress_add_to_wal(const SpockApplyProgress *sap);


#endif							/* SPOCK_RMGR_H */
