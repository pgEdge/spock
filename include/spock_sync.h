/*-------------------------------------------------------------------------
 *
 * spock_sync.h
 *		table synchronization functions
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_SYNC_H
#define SPOCK_SYNC_H

#include "libpq-fe.h"

#include "nodes/primnodes.h"
#include "spock_node.h"

typedef struct SpockSyncStatus
{
	char		kind;
	Oid			subid;
	NameData	nspname;
	NameData	relname;
	char		status;
	XLogRecPtr	statuslsn;		/* remote lsn of the state change used for
								 * synchronization coordination */
} SpockSyncStatus;

#define SYNC_KIND_INIT		'i'
#define SYNC_KIND_FULL		'f'
#define SYNC_KIND_STRUCTURE	's'
#define SYNC_KIND_DATA		'd'

#define SyncKindData(kind) \
	(kind == SYNC_KIND_FULL || kind == SYNC_KIND_DATA)

#define SyncKindStructure(kind) \
	(kind == SYNC_KIND_FULL || kind == SYNC_KIND_STRUCTURE)

#define SYNC_STATUS_NONE		'\0'	/* No sync. */
#define SYNC_STATUS_INIT		'i' /* Ask for sync. */
#define SYNC_STATUS_STRUCTURE	's' /* Sync structure */
#define SYNC_STATUS_DATA		'd' /* Data sync. */
#define SYNC_STATUS_CONSTRAINTS	'c' /* Constraint sync (post-data structure). */
#define SYNC_STATUS_SYNCWAIT	'w' /* Table sync is waiting to get OK from
									 * main thread. */
#define SYNC_STATUS_CATCHUP		'u' /* Catching up. */
#define SYNC_STATUS_SYNCDONE	'y' /* Synchronization finished (at lsn). */
#define SYNC_STATUS_READY		'r' /* Done. */

extern void spock_sync_worker_finish(void);

extern void spock_sync_subscription(SpockSubscription *sub);
extern char spock_sync_table(SpockSubscription *sub, RangeVar *table, XLogRecPtr *status_lsn);

extern void create_local_sync_status(SpockSyncStatus *sync);
extern void drop_subscription_sync_status(Oid subid);

extern SpockSyncStatus *get_subscription_sync_status(Oid subid,
													 bool missing_ok);
extern void set_subscription_sync_status(Oid subid, char status);

extern void drop_table_sync_status(const char *nspname, const char *relname);
extern void drop_table_sync_status_for_sub(Oid subid, const char *nspname,
										   const char *relname);

extern SpockSyncStatus *get_table_sync_status(Oid subid,
											  const char *schemaname,
											  const char *relname,
											  bool missing_ok);
extern void set_table_sync_status(Oid subid, const char *schemaname,
								  const char *relname, char status,
								  XLogRecPtr status_lsn);
extern List *get_unsynced_tables(Oid subid);

/* For interface compat with spk3 */
inline static void
free_sync_status(SpockSyncStatus *sync)
{
	pfree(sync);
}

extern bool wait_for_sync_status_change(Oid subid, const char *nspname,
										const char *relname, char desired_state,
										XLogRecPtr *status_lsn);

extern void truncate_table(char *nspname, char *relname);
extern List *get_subscription_tables(Oid subid);

#endif							/* SPOCK_SYNC_H */
