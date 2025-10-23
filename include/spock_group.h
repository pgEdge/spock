/*-------------------------------------------------------------------------
 *
 * spock_group.h
 * 		spock group function declarations
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
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
 * Changing something here don't forget to revise the init_apply_progress.
 */
typedef struct SpockApplyProgress
{
	TimestampTz remote_commit_ts;	/* committed remote txn ts */

	/*
	 * Bit of duplication of remote_commit_ts. Serves the same purpose, except
	 * keep the last updated value
	 */
	TimestampTz prev_remote_ts;
	XLogRecPtr	remote_commit_lsn;	/* LSN of remote commit on origin */
	XLogRecPtr	remote_insert_lsn;	/* origin insert/end LSN reported */
	TimestampTz last_updated_ts;	/* when we set this */
	bool		updated_by_decode;	/* set by decode or apply */
} SpockApplyProgress;

/*
 * It is common to differentiate in-memory and WAL representation of a structure
 * There may be multiple reasons - for example, adding crc field or optimise
 * the disk entry size. So, introduce this structure for convenience,
 */
typedef struct spock_xl_apply_progress
{
	SpockGroupKey		key;
	SpockApplyProgress	progress;
} spock_xl_apply_progress;

/* Hash entry: one per group (stable pointer; not moved by dynahash) */
typedef struct SpockGroupEntry
{
	SpockGroupKey key;			/* hash key */
	SpockApplyProgress progress;
	pg_atomic_uint32 nattached;
	ConditionVariable prev_processed_cv;
} SpockGroupEntry;

typedef enum
{
	GP_DBOID = 0,
	GP_NODE_ID,
	GP_REMOTE_NODE_ID,
	GP_REMOTE_COMMIT_TS,
	GP_PREV_REMOTE_TS,
	GP_REMOTE_COMMIT_LSN,
	GP_REMOTE_INSERT_LSN,
	GP_LAST_UPDATED_TS,
	GP_UPDATED_BY_DECODE,

	/* The last value */
	_GP_LAST_
} GroupProgressTupDescColumns;

/* shmem setup */
void		spock_group_shmem_init(void);
extern void spock_group_shmem_request(void);
extern void spock_group_shmem_startup(int napply_groups, bool found);

SpockGroupEntry *spock_group_attach(Oid dbid, Oid node_id, Oid remote_node_id);
void		spock_group_detach(void);
bool spock_group_progress_update(const SpockGroupKey *key,
								 const SpockApplyProgress *progress);
void		spock_group_progress_update_ptr(SpockGroupEntry *e, const SpockApplyProgress *sap);
SpockApplyProgress *apply_worker_get_progress(void);
SpockGroupEntry *spock_group_lookup(Oid dbid, Oid node_id, Oid remote_node_id);

/* Iterate all groups */
typedef void (*SpockGroupIterCB) (const SpockGroupEntry *e, void *arg);
void		spock_group_foreach(SpockGroupIterCB cb, void *arg);

extern void		spock_group_resource_dump(void);
extern void		spock_group_resource_load(void);
extern SpockGroupKey make_key(Oid dbid, Oid node_id, Oid remote_node_id);

#endif							/* SPOCK_GROUP_H */
