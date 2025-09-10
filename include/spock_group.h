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

SpockGroupEntry *spock_group_attach(Oid dbid, Oid node_id, Oid remote_node_id,
									bool *created);
void		spock_group_detach(void);
bool		spock_group_progress_update(const SpockApplyProgress *sap);
void		spock_group_progress_update_ptr(SpockGroupEntry *e, const SpockApplyProgress *sap);

bool		spock_group_get_progress(Oid dbid, Oid node_id, Oid remote_node_id,
									 SpockApplyProgress *out /* nullable */ );
extern SpockApplyProgress *apply_worker_get_progress(void);
SpockGroupEntry *spock_group_lookup(Oid dbid, Oid node_id, Oid remote_node_id);

/* Iterate all groups */
typedef void (*SpockGroupIterCB) (const SpockGroupEntry *e, void *arg);
void		spock_group_foreach(SpockGroupIterCB cb, void *arg);

#endif							/* SPOCK_GROUP_H */
