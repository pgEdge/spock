/*-------------------------------------------------------------------------
 *
 * spock_group.c
 * 		spock group functions definitions
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *
 * Spock Group Registry (shmem + file snapshot)
 * --------------------------------------------
 *
 * This module owns the in-memory state of apply groups and their persistent
 * progress snapshots, and the file dump/load used to seed state on clean restart.
 *
 *   - SpockGroupHash: shmem hash keyed by (dbid, node_id, remote_node_id).
 *     Each entry (SpockGroupEntry) contains:
 *       * key                           -- identity
 *       * progress (SpockApplyProgress) -- last applied remote commit snapshot
 *       * nattached, prev_processed_cv  -- apply-worker coordination (runtime)
 *
 * Persistence:
 *   - WAL: authoritative. spock_rmgr_redo() replays progress into this hash.
 *   - File: PGDATA/spock/resource.dat on clean shutdown (on_shmem_exit).
 *           Load during shmem_startup_hook to seed shmem quickly. WAL replay
 *           runs after and overrides stale file contents.
 *
 *
 * Notes:
 *   - Entries are never deleted during normal operation; pointers returned by
 *     spock_group_attach() are stable for the lifetime of the postmaster.
 *   - File header contains version + system_identifier; mismatches cause the
 *     loader to skip the file.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"

#include "common/hashfn.h"
#include "datatype/timestamp.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/elog.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"

#include "spock_common.h"
#include "spock_worker.h"
#include "spock_compat.h"
#include "spock_group.h"

#if PG_VERSION_NUM >= 150000
static shmem_request_hook_type prev_shmem_request_hook = NULL;
#endif
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

#define SPOCK_GROUP_TRANCHE_NAME   "spock_apply_groups"

HTAB	   *SpockGroupHash = NULL;

/*
 * Install hooks to request shared resources for apply workers
 */
void
spock_group_shmem_init(void)
{
#if 0
#if PG_VERSION_NUM < 150000
	spock_group_shmem_request();
#else
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = spock_group_shmem_request;
#endif
	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = spock_group_shmem_startup;
#endif
}

/*
 * spock_group_shmem_request
 *
 * Request and initialize the shmem structures backing the group registry.
 *
 * - _request: called in _PG_init(); calls RequestAddinShmemSpace() and
 *   RequestNamedLWLockTranche() for the hash and the gate lock.
 *
 * - _init: called from shmem_startup_hook while AddinShmemInitLock is held
 *   by core. Creates/attaches the shmem hash (SpockGroupHash).
 */
void
spock_group_shmem_request(void)
{
	int			napply_groups;
	Size		size;

#if PG_VERSION_NUM >= 150000
	if (prev_shmem_request_hook != NULL)
		prev_shmem_request_hook();
#endif

	/*
	 * This is cludge for Windows (Postgres does not define the GUC variable as
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
void
spock_group_shmem_startup(int napply_groups, bool found)
{
	HASHCTL		hctl;

	if (prev_shmem_startup_hook != NULL)
		prev_shmem_startup_hook();

	if (SpockGroupHash)
		return;

	MemSet(&hctl, 0, sizeof(hctl));
	hctl.keysize = sizeof(SpockGroupKey);
	hctl.entrysize = sizeof(SpockGroupEntry);
	hctl.hash = tag_hash;
	hctl.num_partitions = 16;

	/* Get the shared resources */
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

	if (found)
		return;

	/* First time through, nothing to load */
	elog(DEBUG1, "spock_group_shmem_startup: initialized apply group data");
	spock_group_resource_load();
}

SpockGroupKey
make_key(Oid dbid, Oid node_id, Oid remote_node_id)
{
	SpockGroupKey k;

	memset(&k, 0, sizeof(k));
	k.dbid = dbid;
	k.node_id = node_id;
	k.remote_node_id = remote_node_id;

	return k;
}

/*
 * Static value to use to initialize newly created progress entry.
 *
 * Follow the CommitTsShmemInit() code as an example how to initialize such data
 * types in shared memory. Keep the order according to the SpockApplyProgress
 * declaration.
 *
 * The main purpose to introduce this standard initialization is to identify
 * empty (not initialized) values to avoid weird calculations.
 */
static const SpockApplyProgress init_apply_progress =
{
	.remote_commit_ts = 0,
	.prev_remote_ts = 0,
	.remote_commit_lsn = InvalidXLogRecPtr,
	.remote_insert_lsn = InvalidXLogRecPtr,
	.last_updated_ts = 0,
	.updated_by_decode = false
};

/*
 * spock_group_attach
 *
 * Ensure a group entry exists for (dbid,node_id,remote_node_id) and return a
 * stable pointer to it. Increment nattached for visibility/metrics. Safe to
 * call from an apply worker during startup/attach.
 */
SpockGroupEntry *
spock_group_attach(Oid dbid, Oid node_id, Oid remote_node_id)
{
	SpockGroupKey		key = make_key(dbid, node_id, remote_node_id);
	SpockGroupEntry	   *e;
	bool				found;

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);

	e = (SpockGroupEntry *) hash_search(SpockGroupHash, &key, HASH_ENTER, &found);
	if (!found)
	{
		/* initialize key values; Other entries will be updated later */
		e->progress = init_apply_progress;

		pg_atomic_init_u32(&e->nattached, 0);
		ConditionVariableInit(&e->prev_processed_cv);
	}

	pg_atomic_add_fetch_u32(&e->nattached, 1);
	LWLockRelease(SpockCtx->apply_group_master_lock);
	return e;
}

/*
 * spock_group_detach
 *
 * Decrements nattached. Entries are not deleted (stable pointers).
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
 * Update the progress state for (dbid,node_id,remote_node_id).
 * Uses hash_search(HASH_ENTER) for table access, then copies 'sap' into the
 * entry's progress payload under the gate lock (writers EXCLUSIVE).
 *
 * Returns true if the entry already exists, false otherwise.
 */
bool
spock_group_progress_update(const SpockGroupKey *key,
							const SpockApplyProgress *progress)
{
	SpockGroupEntry	   *entry;
	bool				found;

	Assert(key && progress);

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);

	entry = (SpockGroupEntry *) hash_search(SpockGroupHash, &key,
											HASH_ENTER, &found);

	if (!found)					/* New Entry */
	{
		pg_atomic_init_u32(&entry->nattached, 0);
		ConditionVariableInit(&entry->prev_processed_cv);
	}

	entry->progress = *progress;
	LWLockRelease(SpockCtx->apply_group_master_lock);
	return found;
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

static SpockApplyProgress apply_progress = init_apply_progress;

/*
 * apply_worker_get_progress
 *
 * Quick look into the progress state.
 * Because it lies in the shared memory we can't just check it without a lock.
 * For the sake of performance, copy state into the static variable and return
 * the pointer.
 */
SpockApplyProgress *
apply_worker_get_progress(void)
{
    Assert(MyApplyWorker != NULL);
    Assert(MyApplyWorker->apply_group != NULL);

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_SHARED);
	apply_progress = MyApplyWorker->apply_group->progress;
	LWLockRelease(SpockCtx->apply_group_master_lock);

    return &apply_progress;
}

/*
 * spock_group_lookup
 *
 * Snapshot-read the progress payload for the specified group. Uses HASH_FIND
 * to locate the entry.
 *
 * Returns entry if found, NULL otherwise.
 */
SpockGroupEntry *
spock_group_lookup(Oid dbid, Oid node_id, Oid remote_node_id)
{
	SpockGroupKey		key = make_key(dbid, node_id, remote_node_id);
	SpockGroupEntry	   *e;
	bool				found;

	e = (SpockGroupEntry *) hash_search(SpockGroupHash, &key, HASH_FIND, &found);

	if (!found)
		return NULL;

	Assert(e != NULL);
	return e;
}

/*
 * spock_group_foreach
 *
 * Iterate all entries in the group hash and invoke 'cb(e, arg)' for each.
 * Caller selects any gating needed for consistency (e.g., take the gate in
 * SHARED before calling this if you want a coherent snapshot).
 */
void
spock_group_foreach(SpockGroupIterCB cb, void *arg)
{
	HASH_SEQ_STATUS it;
	SpockGroupEntry *e;

	Assert(cb);
	hash_seq_init(&it, SpockGroupHash);
	while ((e = (SpockGroupEntry *) hash_seq_search(&it)) != NULL)
		cb(e, arg);
}


/* --- resource.dat dump/load ---------------------------------------------- */

/* emit one record */
static void
dump_one_group_cb(const SpockGroupEntry *e, void *arg)
{
	DumpCtx					   *ctx = (DumpCtx *) arg;
	spock_xl_apply_progress		rec;

	rec.key = e->key;
	rec.progress = e->progress;

	/* Only the progress payload goes to disk. It already contains the key. */
	write_buf(ctx->fd, &rec, sizeof(spock_xl_apply_progress),
			  SPOCK_RES_DUMPFILE "(data)");
	ctx->count++;
}

/*
 * spock_group_resource_dump
 *
 * Write a clean-shutdown snapshot to PGDATA/spock/resource.dat.
 * - Header: version, system_identifier, flags, entry_count (patched after scan)
 * - Body:   array of SpockApplyProgress records (struct layout is prefix-stable)
 * Writes to a temp file, fsyncs, then durable_rename() into place.
 * Typically invoked via on_shmem_exit() from the main Spock process.
 */
/*
 * spock_group_resource_dump
 * -------------------------
 * Write a clean-shutdown snapshot to PGDATA/spock/resource.dat.
 * - Header: version, system_identifier, flags, entry_count (patched after scan)
 * - Body:   array of SpockApplyProgress records (struct layout is prefix-stable)
 * Writes to a temp file, fsyncs, then durable_rename_excl() into place.
 * Typically invoked via on_shmem_exit() from the main Spock process.
 *
 */
void
spock_group_resource_dump(void)
{
	char		pathdir[MAXPGPATH];
	char		pathtmp[MAXPGPATH];
	char		pathfin[MAXPGPATH];
	int			fd = -1;

	SpockResFileHeader hdr = {0};
	DumpCtx		dctx = {0};

	Assert(!IsUnderPostmaster);

	/* build paths */
	snprintf(pathdir, sizeof(pathdir), "%s/%s", DataDir, SPOCK_RES_DIRNAME);
	snprintf(pathtmp, sizeof(pathtmp), "%s/%s", pathdir, SPOCK_RES_TMPNAME);
	snprintf(pathfin, sizeof(pathfin), "%s/%s", pathdir, SPOCK_RES_DUMPFILE);

	/* ensure directory exists */
	(void) pg_mkdir_p(pathdir, S_IRWXU);

	/* open temp file */
	fd = OpenTransientFile(pathtmp, O_CREAT | O_WRONLY | O_TRUNC | PG_BINARY);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create \"%s\": %m", pathtmp)));

	/* write header */
	hdr.version = SPOCK_RES_VERSION;
	hdr.system_identifier = GetSystemIdentifier();
	hdr.flags = 0;
	hdr.entry_count = hash_get_num_entries(SpockGroupHash);

	write_buf(fd, &hdr, sizeof(hdr), SPOCK_RES_DUMPFILE "(header)");

	/* We are inside the postmaster without any backends. No lock needed */

	dctx.fd = fd;
	dctx.count = 0;

	/* write all entries */
	spock_group_foreach(dump_one_group_cb, &dctx);

	if (dctx.count != hdr.entry_count)
		ereport(ERROR,
				(errmsg("spock resource.dat entry count mismatch: header=%u, actual=%u",
						hdr.entry_count, dctx.count)));

	/* fsync file */
	if (pg_fsync(fd) != 0)
		ereport(data_sync_elevel(ERROR),
				(errcode_for_file_access(),
				 errmsg("could not fsync file \"%s\": %m", pathtmp)));


	if (CloseTransientFile(fd) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not close file \"%s\": %m", pathtmp)));

	/* durable rename temp -> final */
	if (durable_rename(pathtmp, pathfin, LOG) != 0)
		ereport(ERROR,
				(errmsg("could not rename \"%s\" to \"%s\"",
						pathtmp, pathfin)));
}

/*
 * spock_group_resource_load
 *
 * Load an existing snapshot (if present) during shmem startup. Validates
 * version and system_identifier, then update each record via
 * spock_group_progress_update().
 */
void
spock_group_resource_load(void)
{
	char		pathfin[MAXPGPATH];
	int			fd;
	SpockResFileHeader hdr;

	snprintf(pathfin, sizeof(pathfin), "%s/%s/%s", DataDir, SPOCK_RES_DIRNAME, SPOCK_RES_DUMPFILE);

	fd = OpenTransientFile(pathfin, O_RDONLY | PG_BINARY);
	if (fd < 0)
	{
		if (errno == ENOENT)
		{
			/* No snapshot available — normal on first boot or after crash */
			return;
		}
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open \"%s\": %m", pathfin)));
	}

	read_buf(fd, &hdr, sizeof(hdr), SPOCK_RES_DUMPFILE "(header)");

	/* Basic sanity checks */
	if (hdr.version != SPOCK_RES_VERSION)
	{
		CloseTransientFile(fd);
		ereport(WARNING,
				(errmsg("spock resource.dat version mismatch (file=%u, expected=%u) — ignoring",
						hdr.version, SPOCK_RES_VERSION)));
		return;
	}

	if (hdr.system_identifier != GetSystemIdentifier())
	{
		CloseTransientFile(fd);
		ereport(WARNING,
				(errmsg("spock resource.dat system identifier mismatch — ignoring")));
		return;
	}

	/* Read each record and upsert */
	for (uint32 i = 0; i < hdr.entry_count; i++)
	{
		spock_xl_apply_progress		rec;
		bool						ret;

		read_buf(fd, &rec, sizeof(spock_xl_apply_progress),
				 SPOCK_RES_DUMPFILE "(data)");

		/*
		 * Note: if ever version is changed in SpockApplyProgress and need
		 * compatibility, it should be translated here. For now, 1:1.
		 */
		ret = spock_group_progress_update(&rec.key, &rec.progress);
		Assert(!ret);
	}

	CloseTransientFile(fd);
}
