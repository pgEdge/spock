/*-------------------------------------------------------------------------
 *
 * spock_group.c
 * 		spock group functions definitions
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"

#include "utils/guc.h"
#include "utils/builtins.h"
#include "datatype/timestamp.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "utils/hsearch.h"
#include "common/hashfn.h"

#include "spock_worker.h"
#include "spock_compat.h"
#include "spock_group.h"

#if PG_VERSION_NUM >= 150000
static shmem_request_hook_type prev_shmem_request_hook = NULL;
#endif
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

#define SPOCK_GROUP_TRANCHE_NAME   "spock_apply_groups"

static HTAB *SpockGroupHash = NULL;

static void spock_group_shmem_request(void);
static void spock_group_shmem_startup(void);

/*
 * Install hooks to request shared resources for apply workers
 */
void
spock_group_shmem_init(void)
{
#if PG_VERSION_NUM < 150000
	spock_group_shmem_request();
#else
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = spock_group_shmem_request;
#endif
	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = spock_group_shmem_startup;
}

static void
spock_group_shmem_request(void)
{
	int			napply_groups;
	Size		size;

#if PG_VERSION_NUM >= 150000
	if (prev_shmem_request_hook != NULL)
		prev_shmem_request_hook();
#endif

	/*
	 * This is cludge for Windows (Postgres des not define the GUC variable as
	 * PGDDLIMPORT)
	 */
	napply_groups = atoi(GetConfigOptionByName("max_worker_processes", NULL,
											   false));
	if (napply_groups <= 0)
		napply_groups = 9;

	/*
	 * Request enough shared memory for napply_groups (dbid and origin id)
	 */
	size = hash_estimate_size(napply_groups, sizeof(SpockGroupEntry));
	size += mul_size(16, sizeof(LWLockPadded));
	RequestAddinShmemSpace(size);

	/*
	 * Request the LWlocks needed
	 */
	RequestNamedLWLockTranche(SPOCK_GROUP_TRANCHE_NAME, napply_groups + 1);
}

/*
 * Initialize shared resources for db-origin management
 */
static void
spock_group_shmem_startup(void)
{
	HASHCTL		hctl;
	int			napply_groups;

	if (prev_shmem_startup_hook != NULL)
		prev_shmem_startup_hook();

	if (SpockGroupHash)
		return;

	/*
	 * This is kludge for Windows (Postgres does not define the GUC variable
	 * as PGDLLIMPORT)
	 */
	napply_groups = atoi(GetConfigOptionByName("max_worker_processes", NULL,
											   false));
	if (napply_groups <= 0)
		napply_groups = 9;

	MemSet(&hctl, 0, sizeof(hctl));
	hctl.keysize = sizeof(SpockGroupKey);
	hctl.entrysize = sizeof(SpockGroupEntry);
	hctl.hash = tag_hash;
	hctl.num_partitions = 16;

	/* Get the shared resources */
	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);
	SpockCtx->apply_group_master_lock = &((GetNamedLWLockTranche(SPOCK_GROUP_TRANCHE_NAME)[0]).lock);
	SpockGroupHash = ShmemInitHash("spock group hash",
								   napply_groups,
								   napply_groups,
								   &hctl,
								   HASH_ELEM | HASH_BLOBS |
								   HASH_SHARED_MEM | HASH_PARTITION |
								   HASH_FIXED_SIZE);

	if (!SpockGroupHash)
		elog(ERROR, "spock_group_shmem_startup: failed to init group map");

	LWLockRelease(AddinShmemInitLock);
}

static inline SpockGroupKey
make_key(Oid dbid, Oid node_id, Oid remote_node_id)
{
	SpockGroupKey k = {dbid, node_id, remote_node_id};

	return k;
}

/*
 * spock_group_attach
 */
SpockGroupEntry *
spock_group_attach(Oid dbid, Oid node_id, Oid remote_node_id, bool *created)
{
	SpockGroupKey key = make_key(dbid, node_id, remote_node_id);
	SpockGroupEntry *e;
	bool		found;

	e = (SpockGroupEntry *) hash_search(SpockGroupHash, &key, HASH_ENTER, &found);
	if (!found)
	{
		/* initialize new entry */
		e->key = key;

		/* initialize key values; Other entries will be updated later */
		memset(&e->progress, 0, sizeof(e->progress));
		e->progress.key = e->key;

		pg_atomic_init_u32(&e->nattached, 0);
		ConditionVariableInit(&e->prev_processed_cv);
		if (created)
			*created = true;
	}
	else
	{
		if (created)
			*created = false;
	}

	pg_atomic_add_fetch_u32(&e->nattached, 1);

	return e;
}

/*
 * spock_group_detach
 *
 * Remove a worker from it's group.
 */
void
spock_group_detach(void)
{
	if (MyApplyWorker->apply_group)
		pg_atomic_sub_fetch_u32(&MyApplyWorker->apply_group->nattached, 1);

	MyApplyWorker->apply_group = NULL;
}

/*
 * spock_group_progress_update
 *
 * update progress - used by apply worker, REDO, file loader
 */
bool
spock_group_progress_update(const SpockApplyProgress *sap)
{
	SpockGroupKey key;
	SpockGroupEntry *e;
	bool		found;

	if (!sap)
		return false;

	key = make_key(sap->key.dbid, sap->key.node_id, sap->key.remote_node_id);
	e = (SpockGroupEntry *) hash_search(SpockGroupHash, &key, HASH_ENTER, &found);

	if (!found)					/* New Entry */
	{
		e->key = key;
		/* Initialize key values; Other entries will be updated later */
		memset(&e->progress, 0, sizeof(e->progress));
		e->progress.key = e->key;

		pg_atomic_init_u32(&e->nattached, 0);
		ConditionVariableInit(&e->prev_processed_cv);
	}

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);
	e->progress = *sap;
	LWLockRelease(SpockCtx->apply_group_master_lock);
	return true;
}

/* Fast update when you already hold the pointer (apply hot path) */
void
spock_group_progress_update_ptr(SpockGroupEntry *e, const SpockApplyProgress *sap)
{
	Assert(e && sap);
	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);
	e->progress = *sap;
	LWLockRelease(SpockCtx->apply_group_master_lock);
}

/*
 * apply_worker_get_progress
 */
SpockApplyProgress *
apply_worker_get_progress(void)
{
	Assert(MyApplyWorker != NULL);
	Assert(MyApplyWorker->apply_group != NULL);
	if (MyApplyWorker && MyApplyWorker->apply_group)
		return &MyApplyWorker->apply_group->progress;
	return NULL;
}

/*
 * spock_group_get_progress
 */
bool
spock_group_get_progress(Oid dbid, Oid node_id, Oid remote_node_id,
						 SpockApplyProgress *out)
{
	SpockGroupKey key = make_key(dbid, node_id, remote_node_id);
	SpockGroupEntry *e;

	e = (SpockGroupEntry *) hash_search(SpockGroupHash, &key, HASH_FIND, NULL);
	if (!e)
		return false;

	if (out)
		*out = e->progress;
	return true;
}

/*
 * spock_group_lookup
 */
SpockGroupEntry *
spock_group_lookup(Oid dbid, Oid node_id, Oid remote_node_id)
{
	SpockGroupKey key = make_key(dbid, node_id, remote_node_id);
	SpockGroupEntry *e;

	e = (SpockGroupEntry *) hash_search(SpockGroupHash, &key, HASH_FIND, NULL);
	return e;					/* may be NULL */
}
