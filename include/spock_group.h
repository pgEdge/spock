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

typedef struct SpockApplyProgress
{
	SpockGroupKey key;			/* common elements */
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

/* Hash entry: one per group (stable pointer; not moved by dynahash) */
typedef struct SpockGroupEntry
{
	SpockGroupKey key;			/* hash key */
	SpockApplyProgress progress;
	pg_atomic_uint32 nattached;
	ConditionVariable prev_processed_cv;
} SpockGroupEntry;

/* shmem setup */
void		spock_group_shmem_init(void);
extern void spock_group_shmem_request(void);
extern void spock_group_shmem_startup(int napply_groups, bool found);

SpockGroupEntry *spock_group_attach(Oid dbid, Oid node_id, Oid remote_node_id,
									bool *created);
void		spock_group_detach(void);
bool		spock_group_progress_update(const SpockApplyProgress *sap);
void		spock_group_progress_update_ptr(SpockGroupEntry *e, const SpockApplyProgress *sap);
SpockApplyProgress *apply_worker_get_progress(void);
SpockGroupEntry *spock_group_lookup(Oid dbid, Oid node_id, Oid remote_node_id);

/* Iterate all groups */
typedef void (*SpockGroupIterCB) (const SpockGroupEntry *e, void *arg);
void		spock_group_foreach(SpockGroupIterCB cb, void *arg);

extern void		spock_group_resource_dump(void);
extern void		spock_group_resource_load(void);

#endif							/* SPOCK_GROUP_H */
