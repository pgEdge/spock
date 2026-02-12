/*-------------------------------------------------------------------------
 *
 * spock_group.h
 * 		spock group function declarations
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_GROUP_H
#define SPOCK_GROUP_H

#include "postgres.h"

#include "storage/condition_variable.h"
#include "storage/lock.h"
#include "storage/lwlock.h"
#include "storage/spin.h"
#include "utils/hsearch.h"

#include "spock_rmgr.h"

extern HTAB *SpockGroupHash;

/* numeric version to store on disk */
#define SPOCK_RES_VERSION   202508251

#define SPOCK_RES_DIRNAME   "spock"
#define SPOCK_RES_DUMPFILE  "resource.dat"
#define SPOCK_RES_TMPNAME   SPOCK_RES_DUMPFILE ".tmp"
#define SPOCK_GROUP_TRANCHE_NAME   "spock_apply_groups"

typedef struct SpockResFileHeader
{
	/* Identify File format */
	uint32		version;

	/* Unique system identifier; from pg_control */
	uint64		system_identifier;

	/* reserved */
	uint16		flags;

	/* how many ProgressInfoEntry */
	uint32		entry_count;
} SpockResFileHeader;

/* context for foreach loop */
typedef struct DumpCtx
{
	int			fd;
	uint32		count;
} DumpCtx;


/* Hash Key */
typedef struct SpockGroupKey
{
	Oid			dbid;
	Oid			node_id;
	Oid			remote_node_id;
} SpockGroupKey;

/*
 * Columns for the UI routine get_apply_group_progress.
 */
typedef enum GroupProgressTupDescColumns
{
	GP_DBOID = 0,
	GP_NODE_ID,
	GP_REMOTE_NODE_ID,
	GP_REMOTE_COMMIT_TS,
	GP_PREV_REMOTE_TS,
	GP_REMOTE_COMMIT_LSN,
	GP_REMOTE_INSERT_LSN,
	GP_RECEIVED_LSN,
	GP_LAST_UPDATED_TS,
	GP_UPDATED_BY_DECODE,

	/* The last value */
	_GP_LAST_
} GroupProgressTupDescColumns;

/*
 * Logical Replication Progress made by a group of apply workers.
 *
 * IMPORTANT: The 'key' field must remain the first member of this structure
 * because the hash table uses SpockGroupKey as its hash key type. The
 * dynahash code accesses the key portion directly, so changing this layout
 * would break the hash table operations.
 *
 * Field descriptions:
 * key - Identifies the replication group (dbid, node_id, remote_node_id).
 *       MUST be first field for hash table compatibility.
 * remote_commit_ts - the most advanced timestamp of COMMIT commands, already
 *       applied by the replication group. In fact, an apply worker may finish
 *       the COMMIT apply if only all other commits with smaller timestamps have
 *       already been committed by other workers. So, this value tells us about
 *       the real progress.
 * prev_remote_ts - XXX: It seems do nothing at the moment and should
 *       be considered to be removed.
 * remote_commit_lsn - LSN of the COMMIT corresponding to the remote_commit_ts.
 * remote_insert_lsn - an LSN of the most advanced WAL record written to
 *       the WAL on the remote side. Replication protocol attempts to update it as
 *       frequently as possible, but it still be a little stale.
 * received_lsn - an LSN of the most advanced WAL record that was received by
 *       the group.
 * last_updated_ts - timestamp when remote COMMIT command (identified by the
 *       remote_commit_ts and remote_commit_lsn) was applied locally.
 *       Spock employs this value to calculate replication_lag.
 * updated_by_decode - obsolete value. It was needed to decide on the LR lag
 *       that seems not needed if we have NULL value for a timestamp column.
 */
typedef struct SpockApplyProgress
{
	SpockGroupKey key;			/* MUST be first field */

	TimestampTz remote_commit_ts;	/* committed remote txn ts */

	/*
	 * Bit of duplication of remote_commit_ts. Serves the same purpose, except
	 * keep the last updated value
	 */
	TimestampTz prev_remote_ts;
	XLogRecPtr	remote_commit_lsn;	/* LSN of remote commit on origin */
	XLogRecPtr	remote_insert_lsn;	/* origin insert/end LSN reported */

	/*
	 * The largest received LSN by the group. It is more or equal to the
	 * remote_commit_lsn.
	 */
	XLogRecPtr	received_lsn;

	TimestampTz last_updated_ts;	/* when we set this */
	bool		updated_by_decode;	/* set by decode or apply. OBSOLETE. Used
									 * in versions <=5.x.x only */
} SpockApplyProgress;

/* Hash entry: one per group (stable pointer; not moved by dynahash) */
typedef struct SpockGroupEntry
{
	SpockApplyProgress progress;
	pg_atomic_uint32 nattached;
	ConditionVariable prev_processed_cv;
} SpockGroupEntry;

/* shmem setup */
extern void spock_group_shmem_request(int nworkers);
extern void spock_group_shmem_startup(bool found);

extern SpockGroupEntry *spock_group_attach(Oid dbid, Oid node_id,
										   Oid remote_node_id);
extern void spock_group_detach(void);
extern bool spock_group_progress_update(const SpockApplyProgress *sap);
extern void spock_group_progress_update_ptr(SpockGroupEntry *entry,
											const SpockApplyProgress *sap);
extern TimestampTz apply_worker_get_prev_remote_ts(void);

extern void spock_group_resource_dump(void);
extern void spock_checkpoint_hook(XLogRecPtr checkPointRedo, int flags);
extern void spock_group_progress_update_list(List *lst);

#endif							/* SPOCK_GROUP_H */
