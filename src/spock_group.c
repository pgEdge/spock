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


HTAB	   *SpockGroupHash = NULL;

static void spock_group_resource_load(void);

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
	 * This is kludge for Windows (Postgres does not define the GUC variable
	 * as PGDDLIMPORT)
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

	SpockGroupHash = ShmemInitHash("spock group hash",
								   napply_groups,
								   napply_groups,
								   &hctl,
								   HASH_ELEM | HASH_BLOBS |
								   HASH_SHARED_MEM | HASH_PARTITION |
								   HASH_FIXED_SIZE);

	if (!SpockGroupHash)
		elog(ERROR, "spock_group_shmem_startup: failed to init group map");

	/*
	 * If the shared memory structures already existed (found = true), then
	 * we're a background process attaching to structures created by the
	 * postmaster. The hash was already seeded from the file during postmaster
	 * startup, so skip loading.
	 *
	 * If found = false, we're the postmaster doing initial setup. Load the
	 * file to quickly seed the hash, then WAL recovery will run afterward and
	 * provide authoritative updates.
	 *
	 * Note: ShmemInitHash() doesn't have a 'found' output parameter like
	 * ShmemInitStruct(), so we rely on the 'found' status of other Spock
	 * structures (SpockCtx, etc.) as a proxy since they're all created
	 * together.
	 */
	if (found)
		return;

	spock_group_resource_load();
	elog(DEBUG1,
		 "spock_group_shmem_startup: loading resource file to seed hash. loaded records: %lu",
		 hash_get_num_entries(SpockGroupHash));
}

/*
 * TODO:
 * here is always looming issue with UB around padding until we implement
 * our own 'hash' and 'cmp' routines for the key operations.
 */
static inline SpockGroupKey
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
 * spock_group_attach
 *
 * Ensure a group entry exists for (dbid,node_id,remote_node_id) and return a
 * stable pointer to it. Increment nattached for visibility/metrics. Safe to
 * call from an apply worker during startup/attach.
 */
SpockGroupEntry *
spock_group_attach(Oid dbid, Oid node_id, Oid remote_node_id)
{
	SpockGroupKey key = make_key(dbid, node_id, remote_node_id);
	SpockGroupEntry *e;
	bool		found;

	e = (SpockGroupEntry *) hash_search(SpockGroupHash, &key, HASH_ENTER, &found);
	if (!found)
	{
		/* initialize key values; Other entries will be updated later */
		memset(&e->progress, 0, sizeof(e->progress));

		pg_atomic_init_u32(&e->nattached, 0);
		ConditionVariableInit(&e->prev_processed_cv);
	}

	pg_atomic_add_fetch_u32(&e->nattached, 1);

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
 * To have fresh statistics we need to update subsets of these fields in
 * different situations. For example, we need remote_insert_lsn more frequently
 * than just on a commit.
 *
 * This function allows us to control update behaviour and write only the most
 * recent data (remember, members of the group work simultaneously).
 */
static void
progress_update_struct(SpockApplyProgress *dest, const SpockApplyProgress *src)
{
	if (dest->remote_commit_ts < src->remote_commit_ts)
	{
		/*
		 * This is the most advanced commit. Save its progress.
		 *
		 * NOTE: According to apply group machinery their commit order should
		 * follow the timestamp order. That means there are no way for a
		 * commit to come with an oldest commit timestamp except we don't
		 * update this commit's part of the data at all.
		 */
		dest->remote_commit_ts = src->remote_commit_ts;
		dest->prev_remote_ts = src->prev_remote_ts;
		dest->remote_commit_lsn = src->remote_commit_lsn;
		dest->last_updated_ts = src->last_updated_ts;
		dest->updated_by_decode = src->updated_by_decode;
	}

	/* Here is more frequent statistics to update */
	if (dest->remote_insert_lsn < src->remote_insert_lsn)
		dest->remote_insert_lsn = src->remote_insert_lsn;
	if (dest->received_lsn < src->received_lsn)
		/* XXX: do we need to also track the most lagging worker of the group? */
		dest->received_lsn = src->received_lsn;

	/*
	 * It is a good place to check the entry consistency, But only do so after
	 * all fields are updated. During partial updates some fields might still
	 * be InvalidXLogRecPtr (0) while others have been set.
	 */
	Assert(dest->remote_insert_lsn == InvalidXLogRecPtr ||
		   dest->remote_commit_lsn == InvalidXLogRecPtr ||
		   dest->remote_insert_lsn >= dest->remote_commit_lsn);

	Assert(dest->received_lsn == InvalidXLogRecPtr ||
		   dest->remote_commit_lsn == InvalidXLogRecPtr ||
		   dest->received_lsn >= dest->remote_commit_lsn);

	/*
	 * Value of the received_lsn potentially can exceed remote_insert_lsn
	 * because it is reported more frequently (by keepalive messages).
	 */
	Assert(!(dest->remote_commit_ts == 0 ^ dest->last_updated_ts == 0));
	Assert(dest->remote_commit_ts >= 0 && dest->last_updated_ts >= 0);
}

/*
 * spock_group_progress_update
 *
 * Update the progress snapshot for (dbid,node_id,remote_node_id).
 * Uses hash_search(HASH_ENTER) for table access, then copies 'sap' into the
 * entry's progress payload under the gate lock (writers EXCLUSIVE).
 *
 * RETURNS: true, if record has been updated or false - if inserted.
 */
bool
spock_group_progress_update(Oid dbId, Oid nodeId, Oid remoteNodeId,
							const SpockApplyProgress *sap)
{
	SpockGroupKey		key;
	SpockGroupEntry	   *entry;
	bool				found;

	Assert(OidIsValid(dbId) && OidIsValid(nodeId) && OidIsValid(remoteNodeId));
	Assert(sap != NULL);
	Assert(SpockGroupHash && SpockCtx);

	if (!SpockGroupHash || !SpockCtx)
	{
		/*
		 * It should never happen. Skip it in production to allow recovery even
		 * when Spock fails.
		 * TODO: work out a test (automatic or manual) to check this behaviour.
		 */
		elog(WARNING, "SpockGroupHash is not initialized");

		/*
		 * It is unclear what to return in this case. Hence, keep correct
		 * processing of return value on the shoulders of the caller.
		 */
		return false;
	}

	key = make_key(dbId, nodeId, remoteNodeId);

	/* Potential hash table change needs an exclusive lock */
	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);

	entry = (SpockGroupEntry *) hash_search(SpockGroupHash, &key,
											HASH_ENTER, &found);

	if (!found)
	{
		/*
		 * Initialize key values; This is a convention to zero each field.
		 * Follow it in the UpdateWorkerStats too.
		 */
		memset(&entry->progress, 0, sizeof(entry->progress));

		pg_atomic_init_u32(&entry->nattached, 0);
		ConditionVariableInit(&entry->prev_processed_cv);
	}

	progress_update_struct(&entry->progress, sap);
	LWLockRelease(SpockCtx->apply_group_master_lock);
	return found;
}

/* Fast update when you already hold the pointer (apply hot path) */
void
spock_group_progress_update_ptr(SpockGroupEntry *e,
								const SpockApplyProgress *sap)
{
	Assert(e && sap);
	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);
	progress_update_struct(&e->progress, sap);

	/* Insert LSN can't be less than the end of an inserted record */
	Assert(e->progress.remote_insert_lsn == InvalidXLogRecPtr ||
		   e->progress.remote_commit_lsn == InvalidXLogRecPtr ||
		   e->progress.remote_commit_lsn <= e->progress.remote_insert_lsn);

	LWLockRelease(SpockCtx->apply_group_master_lock);
}

/*
 * apply_worker_get_progress
 *
 * Return a pointer to the current apply worker's progress payload, or NULL
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
	SpockGroupKey key = make_key(dbid, node_id, remote_node_id);
	SpockGroupEntry *e;

	e = (SpockGroupEntry *) hash_search(SpockGroupHash, &key, HASH_FIND, NULL);
	return e;					/* may be NULL */
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
dump_one_group_cb(const SpockGroupEntry *entry, void *arg)
{
	DumpCtx	   *ctx = (DumpCtx *) arg;
	xl_progress	rec;

	rec.dbid = entry->key.dbid;
	rec.node_id = entry->key.node_id;
	rec.remote_node_id = entry->key.remote_node_id;
	memcpy(&rec.sap, &entry->progress, sizeof(SpockApplyProgress));

	/* Only the progress payload goes to disk. It already contains the key. */
	write_buf(ctx->fd, &rec, sizeof(xl_progress), SPOCK_RES_DUMPFILE "(data)");
	ctx->count++;
}

/*
 * spock_group_resource_dump
 *
 * Write a clean-shutdown snapshot to PGDATA/spock/resource.dat.
 * - Header: version, system_identifier, flags, entry_count
 * - Body:   array of SpockApplyProgress records
 * Writes to a temp file, fsyncs, then durable_rename() into place.
 * Typically invoked via on_shmem_exit() from the main Spock process.
 */
void
spock_group_resource_dump(void)
{
	char				pathdir[MAXPGPATH];
	char				pathtmp[MAXPGPATH];
	char				pathfin[MAXPGPATH];
	int					fd = -1;
	SpockResFileHeader	hdr = {0};
	DumpCtx				dctx = {0};

	/*
	 * Safety check: if shared memory isn't initialized, we can't dump. This
	 * shouldn't happen but check anyway.
	 * Do not tolerate it in development.
	 */
	Assert(SpockCtx && SpockGroupHash);
	if (!SpockCtx || !SpockGroupHash)
	{
		elog(WARNING, "spock_group_resource_dump: shared memory not initialized, skipping dump");
		return;
	}

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

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_SHARED);

	dctx.fd = fd;
	dctx.count = 0;

	/* write all entries */
	spock_group_foreach(dump_one_group_cb, &dctx);

	LWLockRelease(SpockCtx->apply_group_master_lock);

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
static void
spock_group_resource_load(void)
{
	char				pathfin[MAXPGPATH];
	int					fd;
	SpockResFileHeader	hdr;

	/*
	 * Check that we are actually inside shmem startup or recovery that
	 * guarantees we are alone.
	 */
	Assert(LWLockHeldByMe(AddinShmemInitLock));
	Assert(hash_get_num_entries(SpockGroupHash) == 0);

	snprintf(pathfin, sizeof(pathfin), "%s/%s/%s",
			 DataDir, SPOCK_RES_DIRNAME, SPOCK_RES_DUMPFILE);

	/* Following the logic to lock during redo, do the same reading the file */
	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);

	fd = OpenTransientFile(pathfin, O_RDONLY | PG_BINARY);
	if (fd < 0)
	{
		if (errno == ENOENT)
		{
			LWLockRelease(SpockCtx->apply_group_master_lock);
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
		LWLockRelease(SpockCtx->apply_group_master_lock);
		ereport(WARNING,
				(errmsg("spock resource.dat version mismatch (file=%u, expected=%u) - ignoring",
						hdr.version, SPOCK_RES_VERSION)));
		return;
	}

	if (hdr.system_identifier != GetSystemIdentifier())
	{
		CloseTransientFile(fd);
		LWLockRelease(SpockCtx->apply_group_master_lock);
		ereport(WARNING,
				(errmsg("spock resource.dat system identifier mismatch - ignoring")));
		return;
	}

	/* Read each record and upsert */
	for (uint32 i = 0; i < hdr.entry_count; i++)
	{
		xl_progress			rec;
		bool				ret;

		/* XXX: Do we need any kind of CRC here? */
		read_buf(fd, &rec, sizeof(xl_progress), SPOCK_RES_DUMPFILE "(data)");

		/*
		 * Note: if ever version is changed in SpockApplyProgress and need
		 * compatibility, it should be translated here. For now, 1:1.
		 */
		ret = spock_group_progress_update(rec.dbid, rec.node_id,
										  rec.remote_node_id, &rec.sap);
		/*
		 * Should never happen in real life, but be tolerant in production as
		 * much as possible.
		 */
		Assert(!ret);
		if (ret)
			elog(WARNING, "restoring the replication state (dbid=%u, node_id=%u, remote_node_id=%u) spock found a duplicate",
				 rec.dbid, rec.node_id, rec.remote_node_id);
	}

	CloseTransientFile(fd);
	LWLockRelease(SpockCtx->apply_group_master_lock);
}

void
spock_checkpoint_hook(XLogRecPtr checkPointRedo, int flags)
{
	if ((flags & (CHECKPOINT_IS_SHUTDOWN | CHECKPOINT_END_OF_RECOVERY)) == 0)
		return;

	/* Dump group progress to resource.dat */
	spock_group_resource_dump();
}
