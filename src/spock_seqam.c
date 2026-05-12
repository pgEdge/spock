/*-------------------------------------------------------------------------
 *
 * spock_seqam.c
 *		Distributed sequence access method (SeqAM) dispatcher for Spock.
 *
 * This module attaches Spock's sequence dispatcher to PostgreSQL's
 * nextval_hook (added by patches/{15,16,17,18}/pgNN-050-nextval-hook.diff),
 * maintains a per-backend OID -> method cache with relcache-driven
 * invalidation, owns the per-sequence shared-memory state used by the
 * Snowflake method, and exposes the SQL surface
 * (spock.alter_sequence_set_kind, spock.convert_all_sequences,
 * spock.seq_hook_available, spock.seq_snowflake_decode).
 *
 * Per-call cost on the fast path: one null-pointer check (in the in-core
 * hook site), one hash lookup against a backend-local HTAB, one function
 * pointer dispatch, and the method-specific computation.  Snowflake's
 * computation is a single pg_atomic_compare_exchange_u64() on a packed
 * (timestamp_ms, counter) word held in shared memory; no LWLock is taken
 * on the hot path.
 *
 * The on-disk catalog (spock.sequence_kind) maps sequence OID -> method
 * name and is replicated across the Spock cluster by the existing
 * user_catalog_table machinery.  Method assignments take effect on the
 * next nextval() call in every backend because the relcache invalidation
 * fires on every commit that touches spock.sequence_kind.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/parallel.h"
#include "access/xact.h"
#include "access/xlog.h"

#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/pg_class.h"
#include "catalog/pg_index.h"
#include "catalog/pg_sequence.h"

#include "commands/extension.h"
#include "commands/sequence.h"

#include "utils/syscache.h"

#include "miscadmin.h"

#include "funcapi.h"

#include "nodes/makefuncs.h"

#include "port/atomics.h"

#include "storage/ipc.h"
#include "storage/lmgr.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"

#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"

#include "spock.h"
#include "spock_compat.h"
#include "spock_node.h"
#include "spock_seqam.h"


/* ----- GUCs ------------------------------------------------------------- */

int			spock_seqam_max_managed_sequences = 1024;
int			spock_seqam_default_kind = SPOCK_SEQAM_LOCAL;
int			spock_snowflake_node_id = 0;

static const struct config_enum_entry SpockSeqAmKindOptions[] = {
	{"local", SPOCK_SEQAM_LOCAL, false},
	{"snowflake", SPOCK_SEQAM_SNOWFLAKE, false},
	{NULL, 0, false}
};


/* ----- Shared memory ---------------------------------------------------- */

SpockSeqShmem *SpockSeqShmemCtx = NULL;

static Size
spock_seqam_shmem_size(void)
{
	Size		size;

	size = offsetof(SpockSeqShmem, slots);
	size = add_size(size,
					mul_size(sizeof(SpockSeqShmemSlot),
							 spock_seqam_max_managed_sequences));
	return size;
}

void
spock_seqam_shmem_request(void)
{
	RequestAddinShmemSpace(spock_seqam_shmem_size());
	RequestNamedLWLockTranche("spock seqam slot alloc", 1);
}

void
spock_seqam_shmem_startup(bool found)
{
	bool		seqam_found;

	SpockSeqShmemCtx = ShmemInitStruct("spock_seqam",
									   spock_seqam_shmem_size(),
									   &seqam_found);
	if (!seqam_found)
	{
		int			i;

		SpockSeqShmemCtx->alloc_lock =
			&(GetNamedLWLockTranche("spock seqam slot alloc")[0].lock);
		SpockSeqShmemCtx->nslots = spock_seqam_max_managed_sequences;
		SpockSeqShmemCtx->nallocated = 0;

		for (i = 0; i < SpockSeqShmemCtx->nslots; i++)
		{
			SpockSeqShmemSlot *slot = &SpockSeqShmemCtx->slots[i];

			slot->seqoid = InvalidOid;
			slot->kind = SPOCK_SEQAM_LOCAL;
			pg_atomic_init_u64(&slot->packed_state, 0);
		}
	}
}


/* ----- Per-backend lookup cache ----------------------------------------- */

/*
 * A backend-local hash entry mapping a sequence OID to the method assignment
 * we discovered in spock.sequence_kind (or to "local" if no entry exists).
 *
 * The slot pointer is the in-shared-memory state for the (seqoid, method)
 * pair, allocated lazily on the first lookup that requires it.  For LOCAL
 * the slot is NULL.
 */
typedef struct SeqAmCacheEntry
{
	Oid					seqoid;		/* hash key */
	SpockSeqAmKind		kind;
	SpockSeqShmemSlot  *slot;
	bool				stale;		/* set by invalidation callback */
} SeqAmCacheEntry;

static HTAB			   *SeqAmCache = NULL;
static MemoryContext	SeqAmCacheCtx = NULL;
static bool				SeqAmCacheInvalAll = false;
static Oid				SeqAmCatalogRelid = InvalidOid;
static Oid				SeqAmCatalogPKIdxRelid = InvalidOid;

/*
 * Resolve the OID of the spock.sequence_kind PK index, lazily.  Used to
 * turn the catalog lookup from a seqscan into an index scan -- the catalog
 * is small (one row per managed sequence), but DDL on it invalidates every
 * backend's cache and triggers re-lookup, so index-bounded latency matters.
 */
static Oid
seqam_catalog_pkidx_oid(Relation rel)
{
	List	   *idxlist;
	ListCell   *lc;

	if (OidIsValid(SeqAmCatalogPKIdxRelid))
		return SeqAmCatalogPKIdxRelid;

	idxlist = RelationGetIndexList(rel);
	foreach(lc, idxlist)
	{
		Oid			idxoid = lfirst_oid(lc);
		HeapTuple	tup = SearchSysCache1(INDEXRELID, ObjectIdGetDatum(idxoid));
		bool		is_pk;

		if (!HeapTupleIsValid(tup))
			continue;
		is_pk = ((Form_pg_index) GETSTRUCT(tup))->indisprimary;
		ReleaseSysCache(tup);
		if (is_pk)
		{
			SeqAmCatalogPKIdxRelid = idxoid;
			break;
		}
	}
	list_free(idxlist);

	return SeqAmCatalogPKIdxRelid;
}

/*
 * Forward declaration of the snowflake method.  Defined in
 * src/spock_seqam_snowflake.c.
 */
extern int64 spock_seqam_snowflake_nextval(Oid seqoid,
										   Form_pg_sequence seqform,
										   SpockSeqShmemSlot *slot);
extern void spock_seqam_snowflake_init_slot(SpockSeqShmemSlot *slot,
											Oid seqoid,
											Form_pg_sequence seqform);

/*
 * Method registry.  Indexed by SpockSeqAmKind value.  Sized by the highest
 * registered kind plus one; using a literal here would silently corrupt
 * memory the moment a new kind is added to the enum.
 */
static const SpockSeqAmMethod *SeqAmMethods[SPOCK_SEQAM_SNOWFLAKE + 1];

static void
spock_seqam_register_methods(void)
{
	static const SpockSeqAmMethod snowflake_method = {
		.name = "snowflake",
		.kind = SPOCK_SEQAM_SNOWFLAKE,
		.nextval = spock_seqam_snowflake_nextval,
		.init_slot = spock_seqam_snowflake_init_slot,
	};

	/* LOCAL has no method entry -- absence means fall through. */
	SeqAmMethods[SPOCK_SEQAM_LOCAL] = NULL;
	SeqAmMethods[SPOCK_SEQAM_SNOWFLAKE] = &snowflake_method;
}


/*
 * Look up the spock.sequence_kind row for seqoid.  Returns the parsed kind
 * via *kind_out and true if a row exists; false if no row.  Caller must be
 * inside a transaction.
 */
static bool
seqam_catalog_lookup(Oid seqoid, SpockSeqAmKind *kind_out)
{
	RangeVar	   *rv;
	Relation		rel;
	SysScanDesc		scan;
	ScanKeyData		key[1];
	HeapTuple		tup;
	bool			found = false;
	Oid				idxoid;

	rv = makeRangeVar(EXTENSION_NAME, CATALOG_SEQUENCE_KIND, -1);
	rel = table_openrv(rv, AccessShareLock);

	/* Remember the relid for invalidation routing. */
	if (SeqAmCatalogRelid == InvalidOid)
		SeqAmCatalogRelid = RelationGetRelid(rel);

	idxoid = seqam_catalog_pkidx_oid(rel);

	ScanKeyInit(&key[0],
				Anum_sequence_kind_seqoid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(seqoid));

	scan = systable_beginscan(rel, idxoid, OidIsValid(idxoid), NULL, 1, key);
	tup = systable_getnext(scan);
	if (HeapTupleIsValid(tup))
	{
		bool		isnull;
		Datum		d;
		text	   *t;
		char	   *kindstr;

		d = heap_getattr(tup, Anum_sequence_kind_kind,
						 RelationGetDescr(rel), &isnull);
		if (isnull)
			elog(ERROR,
				 "spock.sequence_kind row for sequence %u has NULL kind",
				 seqoid);

		t = DatumGetTextPP(d);
		kindstr = text_to_cstring(t);

		if (strcmp(kindstr, "local") == 0)
			*kind_out = SPOCK_SEQAM_LOCAL;
		else if (strcmp(kindstr, "snowflake") == 0)
			*kind_out = SPOCK_SEQAM_SNOWFLAKE;
		else
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("unrecognized spock.sequence_kind value \"%s\" for sequence %u",
							kindstr, seqoid)));

		pfree(kindstr);
		found = true;
	}

	systable_endscan(scan);
	table_close(rel, AccessShareLock);

	return found;
}


/*
 * Find or allocate the shared-memory slot for (seqoid, kind).  Returns NULL
 * for SPOCK_SEQAM_LOCAL (no slot needed).  For other methods, the slot is
 * initialised on first allocation via method->init_slot if that callback
 * is set.
 *
 * The lookup is currently a linear scan, which is fine for nslots in the
 * low thousands.  If that becomes a bottleneck we can index by oid hash.
 */
static SpockSeqShmemSlot *
seqam_locate_slot(Oid seqoid, SpockSeqAmKind kind, Form_pg_sequence seqform)
{
	SpockSeqShmemSlot  *slot = NULL;
	int					i;
	const SpockSeqAmMethod *method;

	if (kind == SPOCK_SEQAM_LOCAL)
		return NULL;

	method = SeqAmMethods[kind];
	Assert(method != NULL);

	/*
	 * Lock-free pre-scan.  Read seqoid first; only if it matches do we
	 * issue a read barrier and trust the rest of the slot.  This pairs
	 * with the pg_write_barrier() in the publication path below.  On x86
	 * the barrier is a no-op; on ARM/POWER it is load-ordered acquire.
	 */
	for (i = 0; i < SpockSeqShmemCtx->nslots; i++)
	{
		Oid			sid = SpockSeqShmemCtx->slots[i].seqoid;

		if (sid != seqoid)
			continue;
		pg_read_barrier();
		if (SpockSeqShmemCtx->slots[i].kind == kind)
			return &SpockSeqShmemCtx->slots[i];
	}

	/* Slow path: allocate a slot under the lock. */
	LWLockAcquire(SpockSeqShmemCtx->alloc_lock, LW_EXCLUSIVE);

	/* Re-scan in case someone allocated a slot for us. */
	for (i = 0; i < SpockSeqShmemCtx->nslots; i++)
	{
		if (SpockSeqShmemCtx->slots[i].seqoid == seqoid &&
			SpockSeqShmemCtx->slots[i].kind == kind)
		{
			slot = &SpockSeqShmemCtx->slots[i];
			break;
		}
	}

	if (slot == NULL)
	{
		for (i = 0; i < SpockSeqShmemCtx->nslots; i++)
		{
			if (SpockSeqShmemCtx->slots[i].seqoid == InvalidOid)
			{
				slot = &SpockSeqShmemCtx->slots[i];
				/*
				 * Initialise per-method state *before* setting kind and
				 * publishing seqoid.  This way, a reader that observes a
				 * stale recycled slot before the publish cannot also see
				 * a partly-initialised kind / packed_state.
				 */
				if (method->init_slot != NULL)
					method->init_slot(slot, seqoid, seqform);
				slot->kind = kind;
				/*
				 * Publish seqoid last.  pg_write_barrier() pairs with the
				 * pg_read_barrier() in the lock-free reader above.
				 */
				pg_write_barrier();
				slot->seqoid = seqoid;
				SpockSeqShmemCtx->nallocated++;
				break;
			}
		}
	}

	LWLockRelease(SpockSeqShmemCtx->alloc_lock);

	if (slot == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
				 errmsg("out of Spock managed sequence slots"),
				 errhint("Increase spock.max_managed_sequences (currently %d) "
						 "and restart the server.",
						 spock_seqam_max_managed_sequences)));

	return slot;
}


/*
 * Per-backend cache invalidation callback.  Fired on every commit that
 * touches a relation whose OID matches our cached relation OID for
 * spock.sequence_kind, plus all sequence relations (so a DROP SEQUENCE on
 * a managed sequence forces a re-resolve and frees the cached slot
 * pointer).
 *
 * Rather than dirty individual entries (which would require deserialising
 * what changed), we mark the entire backend-local cache stale and let the
 * next nextval() rebuild lazily.  Method changes are rare; the rebuild
 * cost is negligible.
 */
static void
seqam_relcache_invalidate(Datum arg, Oid relid)
{
	(void) arg;

	/*
	 * If we have not yet learned the OID of spock.sequence_kind, conservatively
	 * mark all stale.  We will learn it on the next catalog lookup.
	 *
	 * Also invalidate the cached PK index OID.  Without this, a REINDEX or
	 * a DROP-then-CREATE EXTENSION cycle within a single backend's
	 * lifetime would leave SeqAmCatalogPKIdxRelid pointing at an old or
	 * dropped index, which would then make systable_beginscan() error out
	 * on the next managed nextval().
	 */
	if (SeqAmCatalogRelid == InvalidOid || relid == InvalidOid ||
		relid == SeqAmCatalogRelid)
	{
		SeqAmCacheInvalAll = true;
		SeqAmCatalogPKIdxRelid = InvalidOid;
		SeqAmCatalogRelid = InvalidOid;
	}
	/* Also invalidate when a sequence relation is invalidated. */
	else if (SeqAmCache != NULL)
	{
		SeqAmCacheEntry *entry = hash_search(SeqAmCache, &relid,
											 HASH_FIND, NULL);

		if (entry != NULL)
			entry->stale = true;
	}
}

static void
seqam_init_cache(void)
{
	HASHCTL		ctl;

	if (SeqAmCache != NULL)
		return;

	SeqAmCacheCtx = AllocSetContextCreate(TopMemoryContext,
										  "spock seqam cache",
										  ALLOCSET_SMALL_SIZES);

	MemSet(&ctl, 0, sizeof(ctl));
	ctl.keysize = sizeof(Oid);
	ctl.entrysize = sizeof(SeqAmCacheEntry);
	ctl.hcxt = SeqAmCacheCtx;

	SeqAmCache = hash_create("spock seqam backend cache",
							 128, &ctl,
							 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	/*
	 * NOTE: the relcache callback itself is registered once at module load
	 * in spock_seqam_init(), not here, so that backends which never call a
	 * managed nextval() still receive DROP SEQUENCE invalidations.
	 */
}

static void
seqam_clear_cache_if_invalidated(void)
{
	HASH_SEQ_STATUS hseq;
	SeqAmCacheEntry *entry;

	if (SeqAmCacheInvalAll)
	{
		hash_seq_init(&hseq, SeqAmCache);
		while ((entry = (SeqAmCacheEntry *) hash_seq_search(&hseq)) != NULL)
			(void) hash_search(SeqAmCache, &entry->seqoid, HASH_REMOVE, NULL);
		SeqAmCacheInvalAll = false;
		return;
	}

	/* Garbage-collect individually-stale entries. */
	hash_seq_init(&hseq, SeqAmCache);
	while ((entry = (SeqAmCacheEntry *) hash_seq_search(&hseq)) != NULL)
	{
		if (entry->stale)
			(void) hash_search(SeqAmCache, &entry->seqoid, HASH_REMOVE, NULL);
	}
}


/* ----- The hook --------------------------------------------------------- */

static nextval_hook_type prev_nextval_hook = NULL;

static bool
spock_seqam_nextval(Oid seqoid, Form_pg_sequence seqform, int64 *result)
{
	SeqAmCacheEntry	   *entry;
	bool				cache_found;
	const SpockSeqAmMethod *method;

	/*
	 * Defensive short-circuits.  In any of these states we cannot or
	 * should not consult our catalog; fall through to the in-core
	 * sequence AM, which is the safe default.
	 *
	 *   - SpockSeqShmemCtx NULL: shmem_startup_hook has not run yet, or
	 *     we are inside pg_upgrade (IsBinaryUpgrade caused
	 *     spock_shmem_init() to be skipped).
	 *   - RecoveryInProgress(): standby; nextval() should be a no-op
	 *     anyway, but if it ever runs, do not generate managed values.
	 *   - !IsTransactionState(): no transaction to run a catalog lookup
	 *     in.
	 *   - creating_extension or InitializingParallelWorker: avoid
	 *     touching our catalog when its own row may be in flight.
	 */
	if (SpockSeqShmemCtx == NULL ||
		RecoveryInProgress() ||
		!IsTransactionState() ||
		creating_extension ||
		IsBinaryUpgrade ||
		InitializingParallelWorker)
		return false;

	if (SeqAmCache == NULL)
		seqam_init_cache();
	else
		seqam_clear_cache_if_invalidated();

	entry = (SeqAmCacheEntry *) hash_search(SeqAmCache, &seqoid,
											HASH_ENTER, &cache_found);

	if (!cache_found || entry->stale)
	{
		SpockSeqAmKind	kind;
		bool			found_in_catalog;

		entry->slot = NULL;
		entry->stale = false;

		found_in_catalog = seqam_catalog_lookup(seqoid, &kind);
		if (!found_in_catalog)
			kind = spock_seqam_default_kind;

		entry->kind = kind;
		entry->slot = seqam_locate_slot(seqoid, kind, seqform);
	}

	if (entry->kind == SPOCK_SEQAM_LOCAL)
	{
		/*
		 * Chain to any previous hook installed before ours.  This keeps
		 * composition with other extensions working: they get a chance
		 * to handle sequences that Spock has chosen not to manage.
		 */
		if (prev_nextval_hook != NULL)
			return prev_nextval_hook(seqoid, seqform, result);
		return false;
	}

	method = SeqAmMethods[entry->kind];
	Assert(method != NULL);
	Assert(method->nextval != NULL);

	*result = method->nextval(seqoid, seqform, entry->slot);
	return true;
}


/* ----- _PG_init entry point -------------------------------------------- */

void
spock_seqam_init(void)
{
	DefineCustomIntVariable("spock.max_managed_sequences",
							"Maximum number of sequences managed by Spock SeqAM",
							"Determines the size of the shared-memory area "
							"that holds per-sequence state for distributed "
							"sequence access methods (e.g. Snowflake).  Each "
							"slot is roughly 24 bytes.  Changes require a "
							"server restart.",
							&spock_seqam_max_managed_sequences,
							1024,
							64,
							INT_MAX / (int) sizeof(SpockSeqShmemSlot),
							PGC_POSTMASTER,
							0,
							NULL, NULL, NULL);

	DefineCustomEnumVariable("spock.default_sequence_kind",
							 "Method used for sequences not explicitly registered",
							 "Determines the dispatch behaviour when a "
							 "sequence has no row in spock.sequence_kind.  "
							 "'local' means stock PostgreSQL semantics.  "
							 "'snowflake' assigns the Snowflake method to "
							 "every nextval() call cluster-wide.",
							 &spock_seqam_default_kind,
							 SPOCK_SEQAM_LOCAL,
							 SpockSeqAmKindOptions,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("spock.snowflake_node_id",
							"Node id embedded in Snowflake sequence values",
							"Must be unique across the Spock cluster, in the "
							"range 0 to 1023.  If 0, the value is derived "
							"from spock.node_id at first use.",
							&spock_snowflake_node_id,
							0,
							0,
							SPOCK_SNOWFLAKE_MAX_NODE_ID,
							PGC_POSTMASTER,
							0,
							NULL, NULL, NULL);

	spock_seqam_register_methods();

	/*
	 * Register the relcache invalidation callback once at module load.
	 * Registering it lazily on first hook firing meant that a backend
	 * which never called a managed nextval() (e.g. one that ran nothing
	 * but DDL) would never see invalidations and could leak orphan
	 * entries in the per-backend cache.
	 */
	CacheRegisterRelcacheCallback(seqam_relcache_invalidate, (Datum) 0);

	/* Chain into the in-core nextval_hook. */
	prev_nextval_hook = nextval_hook;
	nextval_hook = spock_seqam_nextval;
}


/* ----- DROP SEQUENCE cleanup ------------------------------------------- */

/*
 * Delete the spock.sequence_kind row (if any) and free the per-sequence
 * shared-memory slot for the given sequence OID.  Called from the
 * object_access OAT_DROP path for RELKIND_SEQUENCE relations.
 *
 * The caller has already verified that the object is a sequence; we do
 * not re-check, because by the time OAT_DROP fires the relation may not
 * be openable.  We perform best-effort cleanup: missing rows / unused
 * slots are not an error.
 */
void
spock_seqam_drop_sequence_record(Oid seqoid)
{
	RangeVar	   *rv;
	Relation		rel;
	SysScanDesc		scan;
	ScanKeyData		key[1];
	HeapTuple		tup;
	int				i;
	bool			is_apply;

	/*
	 * Cleanup uses superuser privileges because OAT_DROP can fire under a
	 * caller who has no rights on spock.sequence_kind.  See
	 * spock_executor.c for the matching SetUserIdAndSecContext shuffle.
	 *
	 * If the extension is being dropped, the catalog table is about to
	 * disappear too -- skip the catalog cleanup but still free the
	 * shared-memory slot below.
	 */
	if (get_extension_oid(EXTENSION_NAME, true) == InvalidOid)
		goto cleanup_shmem;

	/*
	 * If we are inside a Spock apply worker (REPLICA replication role),
	 * skip the explicit catalog delete: the originating node's DELETE on
	 * spock.sequence_kind is itself replicated as user_catalog_table DML
	 * and will arrive separately.  Issuing our own delete here races
	 * against that and would either no-op (best case) or trigger Spock's
	 * conflict-resolution path and bump spock.resolutions with noise
	 * proportional to the number of dropped sequences.  Freeing the
	 * shared-memory slot is still required: shmem is per-node and not
	 * touched by replication.
	 */
	is_apply = (SessionReplicationRole == SESSION_REPLICATION_ROLE_REPLICA);
	if (is_apply)
		goto cleanup_shmem;

	/*
	 * Open spock.sequence_kind tolerating absence (catalog dropped or not
	 * yet created).  RangeVarGetRelid(..., missing_ok=true) returns
	 * InvalidOid when the relation is missing; portable across PG 15-18.
	 */
	{
		Oid			catrelid;

		rv = makeRangeVar(EXTENSION_NAME, CATALOG_SEQUENCE_KIND, -1);
		catrelid = RangeVarGetRelid(rv, RowExclusiveLock, true);
		if (!OidIsValid(catrelid))
			goto cleanup_shmem;
		rel = table_open(catrelid, NoLock);
	}

	ScanKeyInit(&key[0],
				Anum_sequence_kind_seqoid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(seqoid));
	scan = systable_beginscan(rel, 0, true, NULL, 1, key);
	tup = systable_getnext(scan);
	if (HeapTupleIsValid(tup))
		simple_heap_delete(rel, &tup->t_self);
	systable_endscan(scan);
	table_close(rel, RowExclusiveLock);

cleanup_shmem:
	/* Free the shmem slot.  Always runs, including in apply contexts. */
	if (SpockSeqShmemCtx != NULL)
	{
		LWLockAcquire(SpockSeqShmemCtx->alloc_lock, LW_EXCLUSIVE);
		for (i = 0; i < SpockSeqShmemCtx->nslots; i++)
		{
			SpockSeqShmemSlot *slot = &SpockSeqShmemCtx->slots[i];

			if (slot->seqoid == seqoid)
			{
				/*
				 * Mirror the allocation publish-ordering: write the
				 * "unallocated" payload first (kind, packed_state), then
				 * a write barrier, then publish seqoid = InvalidOid last.
				 * This way a lock-free reader either sees the slot fully
				 * allocated (matching seqoid + readable kind / state) or
				 * fully free (seqoid == InvalidOid), but never an
				 * in-between state where seqoid still matches but kind
				 * has been overwritten.
				 */
				slot->kind = SPOCK_SEQAM_LOCAL;
				pg_atomic_write_u64(&slot->packed_state, 0);
				pg_write_barrier();
				slot->seqoid = InvalidOid;
				if (SpockSeqShmemCtx->nallocated > 0)
					SpockSeqShmemCtx->nallocated--;
				break;
			}
		}
		LWLockRelease(SpockSeqShmemCtx->alloc_lock);
	}
}


/* ----- SQL-callable functions ------------------------------------------ */

PG_FUNCTION_INFO_V1(spock_alter_sequence_set_kind);
PG_FUNCTION_INFO_V1(spock_convert_all_sequences);
PG_FUNCTION_INFO_V1(spock_seq_hook_available);
PG_FUNCTION_INFO_V1(spock_seq_snowflake_decode);

/*
 * spock.alter_sequence_set_kind(seqname regclass, kind text)
 *
 * Insert or replace the spock.sequence_kind row for the given sequence.
 * 'kind' must be one of: 'local', 'snowflake'.
 *
 * Replicated to peer nodes via Spock's existing user_catalog_table
 * machinery.  Method change takes effect on the next nextval() call in
 * every backend on every node.
 */
Datum
spock_alter_sequence_set_kind(PG_FUNCTION_ARGS)
{
	Oid			seqoid = PG_GETARG_OID(0);
	text	   *kind_in = PG_GETARG_TEXT_PP(1);
	char	   *kindstr = text_to_cstring(kind_in);
	RangeVar   *rv;
	Relation	rel;
	SysScanDesc scan;
	ScanKeyData key[1];
	HeapTuple	tup;
	bool		found;

	/* Validate kind */
	if (strcmp(kindstr, "local") != 0 &&
		strcmp(kindstr, "snowflake") != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid sequence kind \"%s\"", kindstr),
				 errhint("Valid kinds are: local, snowflake.")));

	/* Validate that seqoid points to a sequence */
	if (get_rel_relkind(seqoid) != RELKIND_SEQUENCE)
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("relation \"%s\" is not a sequence",
						get_rel_name(seqoid))));

	/*
	 * Only the sequence owner (or a member of the owning role) may change
	 * its kind.  Cluster-wide flipping by anyone with EXECUTE on this
	 * function would let a non-owner corrupt monotonicity of another
	 * tenant's sequence by toggling between local and snowflake.
	 *
	 * pg_class_ownercheck was renamed to object_ownercheck in PG 16; gate
	 * via PG_VERSION_NUM to keep this source compatible with PG 15-18.
	 */
#if PG_VERSION_NUM >= 160000
	if (!object_ownercheck(RelationRelationId, seqoid, GetUserId()))
		aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_SEQUENCE,
					   get_rel_name(seqoid));
#else
	if (!pg_class_ownercheck(seqoid, GetUserId()))
		aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_SEQUENCE,
					   get_rel_name(seqoid));
#endif

	rv = makeRangeVar(EXTENSION_NAME, CATALOG_SEQUENCE_KIND, -1);
	rel = table_openrv(rv, RowExclusiveLock);

	ScanKeyInit(&key[0],
				Anum_sequence_kind_seqoid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(seqoid));
	scan = systable_beginscan(rel, 0, true, NULL, 1, key);
	tup = systable_getnext(scan);
	found = HeapTupleIsValid(tup);

	{
		Datum		values[Natts_sequence_kind];
		bool		nulls[Natts_sequence_kind];
		bool		replaces[Natts_sequence_kind];
		HeapTuple	newtup;

		MemSet(nulls, false, sizeof(nulls));
		MemSet(replaces, false, sizeof(replaces));

		values[Anum_sequence_kind_seqoid - 1] = ObjectIdGetDatum(seqoid);
		values[Anum_sequence_kind_kind - 1] = CStringGetTextDatum(kindstr);

		if (found)
		{
			replaces[Anum_sequence_kind_kind - 1] = true;
			newtup = heap_modify_tuple(tup, RelationGetDescr(rel),
									   values, nulls, replaces);
			CatalogTupleUpdate(rel, &tup->t_self, newtup);
		}
		else
		{
			newtup = heap_form_tuple(RelationGetDescr(rel), values, nulls);
			CatalogTupleInsert(rel, newtup);
		}
	}

	systable_endscan(scan);
	table_close(rel, RowExclusiveLock);

	CommandCounterIncrement();

	pfree(kindstr);
	PG_RETURN_VOID();
}

/*
 * spock.convert_all_sequences(method text default 'snowflake',
 *                             force bool default false)
 *   returns integer
 *
 * For every user-visible sequence in the current database, insert a row
 * into spock.sequence_kind assigning it to the given method.  Sequences
 * that already have a row are skipped unless force is true.
 *
 * Returns the number of sequences converted (or re-converted).
 *
 * NOTE for non-Snowflake methods: a non-trivial implementation would also
 * pre-set the sequence's starting value above the max(col) value across
 * the cluster.  Snowflake values are well above any realistic local
 * value (the timestamp field starts at the Spock epoch shifted left by
 * 22 bits, so even the first value after epoch is around 2^53 to 2^54);
 * they cannot collide with realistic local values, so no such
 * pre-seeding is needed here.
 */
Datum
spock_convert_all_sequences(PG_FUNCTION_ARGS)
{
	text	   *kind_in = PG_GETARG_TEXT_PP(0);
	bool		force = PG_GETARG_BOOL(1);
	char	   *kindstr = text_to_cstring(kind_in);
	Relation	pgclass;
	Relation	skrel;
	RangeVar   *skrv;
	SysScanDesc	scan;
	HeapTuple	tup;
	int			n_converted = 0;

	/*
	 * Iterates every sequence in the database and writes spock.sequence_kind
	 * rows for sequences whose owner may differ from the caller.  Restrict
	 * to superuser to avoid cross-tenant corruption of monotonicity
	 * (a non-owner could otherwise switch another role's sequences to a
	 * different generator).
	 */
	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to run spock.convert_all_sequences"),
				 errhint("Use spock.sequence_set_kind() per sequence to "
						 "convert sequences you own.")));

	if (strcmp(kindstr, "local") != 0 &&
		strcmp(kindstr, "snowflake") != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid sequence kind \"%s\"", kindstr),
				 errhint("Valid kinds are: local, snowflake.")));

	/*
	 * Serialise concurrent conversions on this node.  Two callers (in
	 * different sessions, or running this on different nodes simultaneously)
	 * would otherwise produce a last-write-wins race in spock.sequence_kind.
	 * The advisory xact lock is database-scoped; cluster-wide ordering is
	 * provided by Spock's replication of the user_catalog_table.
	 */
	{
		LOCKTAG		tag;

		SET_LOCKTAG_ADVISORY(tag, MyDatabaseId,
							 (uint32) 0x53504F43,	/* "SPOC" */
							 (uint32) 0x4B534551,	/* "KSEQ" */
							 1);
		(void) LockAcquire(&tag, ExclusiveLock, false, false);
	}

	/* Open spock.sequence_kind once for the whole loop. */
	skrv = makeRangeVar(EXTENSION_NAME, CATALOG_SEQUENCE_KIND, -1);
	skrel = table_openrv(skrv, RowExclusiveLock);

	pgclass = table_open(RelationRelationId, AccessShareLock);
	scan = systable_beginscan(pgclass, InvalidOid, false, NULL, 0, NULL);

	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_class classform = (Form_pg_class) GETSTRUCT(tup);
		Oid			seqoid;
		SysScanDesc	sscan;
		ScanKeyData	key[1];
		HeapTuple	srow;
		bool		exists;

		if (classform->relkind != RELKIND_SEQUENCE)
			continue;

		/* Skip system / extension-owned sequences. */
		if (classform->relnamespace < FirstNormalObjectId)
			continue;

		seqoid = classform->oid;

		/* Check existing assignment. */
		ScanKeyInit(&key[0],
					Anum_sequence_kind_seqoid,
					BTEqualStrategyNumber, F_OIDEQ,
					ObjectIdGetDatum(seqoid));
		sscan = systable_beginscan(skrel, 0, true, NULL, 1, key);
		srow = systable_getnext(sscan);
		exists = HeapTupleIsValid(srow);

		if (!exists || force)
		{
			Datum		values[Natts_sequence_kind];
			bool		nulls[Natts_sequence_kind];
			bool		replaces[Natts_sequence_kind];
			HeapTuple	newtup;

			MemSet(nulls, false, sizeof(nulls));
			MemSet(replaces, false, sizeof(replaces));

			values[Anum_sequence_kind_seqoid - 1] = ObjectIdGetDatum(seqoid);
			values[Anum_sequence_kind_kind - 1] = CStringGetTextDatum(kindstr);

			if (exists)
			{
				replaces[Anum_sequence_kind_kind - 1] = true;
				newtup = heap_modify_tuple(srow, RelationGetDescr(skrel),
										   values, nulls, replaces);
				CatalogTupleUpdate(skrel, &srow->t_self, newtup);
			}
			else
			{
				newtup = heap_form_tuple(RelationGetDescr(skrel),
										 values, nulls);
				CatalogTupleInsert(skrel, newtup);
			}

			n_converted++;
		}

		systable_endscan(sscan);
	}

	systable_endscan(scan);
	table_close(pgclass, AccessShareLock);
	table_close(skrel, RowExclusiveLock);

	CommandCounterIncrement();
	pfree(kindstr);

	PG_RETURN_INT32(n_converted);
}

/*
 * spock.seq_hook_available() returns boolean
 *
 * True when the patched PostgreSQL binary exports the nextval_hook
 * variable and Spock has successfully attached to it.  Because Spock
 * declares 'extern PGDLLIMPORT nextval_hook' and references it from
 * _PG_init, the shared library will simply fail to load on unpatched
 * PostgreSQL -- so by the time SQL can call this function, the hook is
 * available.  The function returns false only on the (impossible at this
 * point) path where spock_seqam_init() chose not to attach.  We keep
 * the function for monitoring tools and forward compatibility with a
 * future runtime-feature-probe build.
 */
Datum
spock_seq_hook_available(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(nextval_hook == spock_seqam_nextval);
}

/*
 * spock.seq_snowflake_decode(val bigint)
 *   returns table(timestamp_ms bigint, node_id int, counter int,
 *                 ts_utc timestamptz)
 *
 * Decoder for snowflake values, used in tests and in support.
 */
Datum
spock_seq_snowflake_decode(PG_FUNCTION_ARGS)
{
	int64		val = PG_GETARG_INT64(0);
	uint64		u = (uint64) val;
	int64		ts_ms;
	int32		node;
	int32		counter;
	TupleDesc	tupdesc;
	Datum		values[4];
	bool		nulls[4] = {false, false, false, false};
	HeapTuple	tuple;
	TimestampTz tstz;

	if (val < 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid snowflake value " INT64_FORMAT, val),
				 errdetail("Snowflake values are non-negative.")));

	ts_ms = (int64) ((u & SPOCK_SNOWFLAKE_TIMESTAMP_MASK)
					 >> SPOCK_SNOWFLAKE_TIMESTAMP_SHIFT);
	node = (int32) ((u & SPOCK_SNOWFLAKE_NODE_MASK)
					>> SPOCK_SNOWFLAKE_NODE_SHIFT);
	counter = (int32) (u & SPOCK_SNOWFLAKE_COUNTER_MASK);

	/*
	 * Convert ms-since-snowflake-epoch to TimestampTz (us since postgres
	 * epoch 2000-01-01).
	 */
	{
		int64	unix_ms = ts_ms + SPOCK_SNOWFLAKE_EPOCH_MS;
		int64	pg_us = (unix_ms - INT64CONST(946684800000)) * INT64CONST(1000);

		tstz = (TimestampTz) pg_us;
	}

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in context "
						"that cannot accept type record")));

	values[0] = Int64GetDatum(ts_ms);
	values[1] = Int32GetDatum(node);
	values[2] = Int32GetDatum(counter);
	values[3] = TimestampTzGetDatum(tstz);

	tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}
