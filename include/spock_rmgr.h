/*-------------------------------------------------------------------------
 *
 * spock_rmgr.h
 * 		spock resource manager declarations
 *
 * Emits one WAL record per SpockGroupHash entry at every resource.dat dump
 * event (clean shutdown, add_node post-loop, table-sync post-loop) carrying
 * the full SpockApplyProgress snapshot for that entry. The records are not
 * required for state recovery (shmem is reseeded from resource.dat plus
 * replorigin reconcile plus pg_commit_ts scan); they exist so that a
 * pg_waldump trace shows the exact progress snapshot that was persisted
 * at each dump LSN -- useful for incident reconstruction over time.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_RMGR_H
#define SPOCK_RMGR_H

#include "access/xlog.h"
#include "access/xlog_internal.h"
#include "nodes/pg_list.h"

#include "spock_group.h"

#define SPOCK_RMGR_NAME					"spock_custom_rmgr"
#define SPOCK_RMGR_ID					144

/* Spock RMGR record types (high nibble of info byte) */
#define SPOCK_RMGR_RESOURCE_DUMP		0x10

/* Event type within a SPOCK_RMGR_RESOURCE_DUMP record */
typedef enum SpockResourceDumpEvent
{
	SPOCK_DUMP_SHUTDOWN = 0,
	SPOCK_DUMP_ADD_NODE = 1,
	SPOCK_DUMP_TABLE_SYNC = 2
} SpockResourceDumpEvent;

typedef struct SpockResourceDumpRec
{
	uint8				event_type;		/* SpockResourceDumpEvent */
	uint8				flags;			/* reserved */
	uint16				entry_seq;		/* 0-based index within this dump event */
	uint16				entry_total;	/* total entries in this dump event */
	uint16				_pad;
	SpockApplyProgress	progress;		/* full snapshot for this entry */
} SpockResourceDumpRec;

/* RMGR function declarations */
extern void spock_rmgr_init(void);
extern void spock_rmgr_redo(XLogReaderState *record);
extern void spock_rmgr_desc(StringInfo buf, XLogReaderState *record);
extern const char *spock_rmgr_identify(uint8 info);

/*
 * Emit helper -- called from the dump call sites in spock_group.c /
 * spock_shmem.c. Emits one WAL record per progress entry, then issues a
 * single XLogFlush at the end.
 *
 * If `changed_entries` is NULL, walks SpockGroupHash and emits a record
 * for each entry (used by SHUTDOWN and ADD_NODE — both reflect changes
 * across all subscriptions).
 *
 * If `changed_entries` is non-NULL, it is treated as a List of
 * SpockApplyProgress* and emits one record per list element (used by
 * TABLE_SYNC, which only affects one subscription's progress).
 */
extern void spock_rmgr_log_resource_dump(SpockResourceDumpEvent event,
										 List *changed_entries);

#endif							/* SPOCK_RMGR_H */
