/*-------------------------------------------------------------------------
 *
 * spock_seqam.c
 *		Distributed sequence access method dispatcher for Spock.
 *
 * Attaches to the in-core nextval_hook (patches/<N>/pgN-050-nextval-hook.diff).
 * The dispatcher maps a sequence OID to a kind (via the spock.sequence_kind
 * catalog, cached per backend) and dispatches to a per-kind method.  Managed
 * kinds keep their state in the sequence relation's own heap tuple; the
 * dispatcher owns no shared memory.
 *
 * Per-backend cache invalidation is relcache-driven.  Mutators of
 * spock.sequence_kind must call CacheInvalidateRelcacheByRelid(seqoid)
 * explicitly: CatalogTupleUpdate on a non-system catalog does not fire
 * relcache invalidations on its own.
 *
 * SQL surface: spock.alter_sequence_set_kind, spock.convert_all_sequences,
 * spock.sequence_hook_available.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
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
#include "access/xloginsert.h"

#include "catalog/catalog.h"			/* IsCatalogNamespace */
#include "catalog/dependency.h"		/* getExtensionOfObject */
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/pg_class.h"
#include "catalog/pg_index.h"
#include "catalog/pg_sequence.h"
#include "catalog/pg_type.h"			/* INT8OID */

#include "commands/extension.h"
#include "commands/sequence.h"
#include "commands/trigger.h"			/* SessionReplicationRole */

#include "utils/syscache.h"

#include "miscadmin.h"

#include "funcapi.h"

#include "nodes/makefuncs.h"

#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "storage/lmgr.h"

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

int			spock_seqam_default_kind = SPOCK_SEQAM_LOCAL;

static const struct config_enum_entry SpockSeqAmKindOptions[] = {
	{"local", SPOCK_SEQAM_LOCAL, false},
	{"snowflake", SPOCK_SEQAM_SNOWFLAKE, false},
	{NULL, 0, false}
};


/* ----- Per-backend lookup cache ----------------------------------------- */

/*
 * A backend-local hash entry mapping a sequence OID to the method assignment
 * we discovered in spock.sequence_kind (or to "local" if no entry exists).
 */
typedef struct SeqAmCacheEntry
{
	Oid					seqoid;		/* hash key */
	SpockSeqAmKind		kind;
} SeqAmCacheEntry;

static HTAB			   *SeqAmCache = NULL;
static Oid				SeqAmCatalogRelid = InvalidOid;
static Oid				SeqAmCatalogPKIdxRelid = InvalidOid;	/* (nspname,relname) PK */
static Oid				SeqAmCatalogOidIdxRelid = InvalidOid;	/* secondary index on seqoid */

/*
 * Resolve both spock.sequence_kind index OIDs (PK on (nspname, relname);
 * secondary on seqoid) in a single index-list scan.  Cached globally; the
 * relcache invalidation callback clears the cache when the catalog or its
 * indexes change.  Either OID may remain InvalidOid if the corresponding
 * index is missing -- callers fall back to a sequential scan.
 */
static void
seqam_catalog_resolve_indexes(Relation rel)
{
	List	   *idxlist;
	ListCell   *lc;

	if (OidIsValid(SeqAmCatalogPKIdxRelid) &&
		OidIsValid(SeqAmCatalogOidIdxRelid))
		return;

	idxlist = RelationGetIndexList(rel);
	foreach(lc, idxlist)
	{
		Oid			idxoid = lfirst_oid(lc);
		HeapTuple	tup;
		bool		is_pk = false;

		tup = SearchSysCache1(INDEXRELID, ObjectIdGetDatum(idxoid));
		if (HeapTupleIsValid(tup))
		{
			is_pk = ((Form_pg_index) GETSTRUCT(tup))->indisprimary;
			ReleaseSysCache(tup);
		}

		if (is_pk)
			SeqAmCatalogPKIdxRelid = idxoid;
		else if (!OidIsValid(SeqAmCatalogOidIdxRelid))
		{
			char	   *nm = get_rel_name(idxoid);

			if (nm != NULL)
			{
				if (strcmp(nm, CATALOG_SEQUENCE_KIND_OID_IDX) == 0)
					SeqAmCatalogOidIdxRelid = idxoid;
				pfree(nm);
			}
		}
	}
	list_free(idxlist);
}

static inline Oid
seqam_catalog_pkidx_oid(Relation rel)
{
	seqam_catalog_resolve_indexes(rel);
	return SeqAmCatalogPKIdxRelid;
}

static inline Oid
seqam_catalog_oididx_oid(Relation rel)
{
	seqam_catalog_resolve_indexes(rel);
	return SeqAmCatalogOidIdxRelid;
}

/* Method registry, indexed by SpockSeqAmKind.  Sized by the enum sentinel. */
static const SpockSeqAmMethod *SeqAmMethods[SPOCK_SEQAM_NMETHODS];


/*
 * Seed the sequence's heap tuple to (last_value = 0, is_called = false,
 * log_cnt = 0).  Used when a sequence is assigned to a managed kind, so
 * the method's first nextval() reads an unambiguous "fresh" state rather
 * than inheriting whatever counter the stock generator had emitted.
 *
 * Mirrors the heap+WAL pattern of sequence_am_local_nextval.  Caller must
 * hold a sufficient lock on seqrel (alter_sequence_set_kind already holds
 * AccessShareLock via LockRelationOid).
 */
static void
seqam_reset_sequence_data(Relation seqrel)
{
	Buffer			buf;
	Page			page;
	ItemId			lp;
	HeapTupleData	tupdata;
	Form_pg_sequence_data seq;

	buf = ReadBuffer(seqrel, 0);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);

	page = BufferGetPage(buf);

	/* Validate page magic; catches layout drift across PG major versions. */
	{
		SpockSequencePageMagic *sm;

		sm = (SpockSequencePageMagic *) PageGetSpecialPointer(page);
		if (sm->magic != SPOCK_SEQUENCE_PAGE_MAGIC)
			elog(ERROR, "bad magic number in sequence \"%s\": %08X",
				 RelationGetRelationName(seqrel), sm->magic);
	}

	/* A sequence page carries exactly one tuple at FirstOffsetNumber. */
	Assert(PageGetMaxOffsetNumber(page) == FirstOffsetNumber);
	lp = PageGetItemId(page, FirstOffsetNumber);
	Assert(ItemIdIsNormal(lp));

	tupdata.t_data = (HeapTupleHeader) PageGetItem(page, lp);
	tupdata.t_len = ItemIdGetLength(lp);
	seq = (Form_pg_sequence_data) GETSTRUCT(&tupdata);

	if (RelationNeedsWAL(seqrel))
		GetTopTransactionId();

	START_CRIT_SECTION();

	MarkBufferDirty(buf);

	if (RelationNeedsWAL(seqrel))
	{
		xl_seq_rec	xlrec;
		XLogRecPtr	recptr;

		XLogBeginInsert();
		XLogRegisterBuffer(0, buf, REGBUF_WILL_INIT);

		seq->last_value = 0;
		seq->is_called = false;
		seq->log_cnt = 0;

#if PG_VERSION_NUM >= 160000
		xlrec.locator = seqrel->rd_locator;
#else
		xlrec.node = seqrel->rd_node;
#endif

		XLogRegisterData(&xlrec, sizeof(xl_seq_rec));
		XLogRegisterData(tupdata.t_data, tupdata.t_len);

		recptr = XLogInsert(RM_SEQ_ID, XLOG_SEQ_LOG);

		PageSetLSN(page, recptr);
	}

	seq->last_value = 0;
	seq->is_called = false;
	seq->log_cnt = 0;

	END_CRIT_SECTION();

	UnlockReleaseBuffer(buf);
}

static void
spock_seqam_register_methods(void)
{
	static const SpockSeqAmMethod snowflake_method = {
		.name = "snowflake",
		.kind = SPOCK_SEQAM_SNOWFLAKE,
		.nextval = spock_seqam_snowflake_nextval,
	};

	/* LOCAL has no method entry -- absence means fall through. */
	SeqAmMethods[SPOCK_SEQAM_LOCAL] = NULL;
	SeqAmMethods[SPOCK_SEQAM_SNOWFLAKE] = &snowflake_method;
}


/*
 * Open spock.sequence_kind.  Returns NULL when the relation does not exist
 * (shared_preload_libraries loaded spock before CREATE EXTENSION).
 * Caller closes with the matching lockmode.
 */
static Relation
seqam_catalog_open(LOCKMODE lockmode)
{
	RangeVar   *rv;
	Oid			catrelid;
	Relation	rel;

	if (OidIsValid(SeqAmCatalogRelid))
		return table_open(SeqAmCatalogRelid, lockmode);

	rv = makeRangeVar(EXTENSION_NAME, CATALOG_SEQUENCE_KIND, -1);
	catrelid = RangeVarGetRelid(rv, lockmode, true);
	if (!OidIsValid(catrelid))
		return NULL;
	rel = table_open(catrelid, NoLock);
	SeqAmCatalogRelid = catrelid;
	return rel;
}

/*
 * Resolve seqoid -> (nspname, relname) via the syscaches, palloc'ing the
 * result strings in CurrentMemoryContext.  Both out-parameters are set to
 * NULL if the relation no longer exists; callers must check.
 */
static void
seqam_resolve_seq_name(Oid seqoid, char **nspname_out, char **relname_out)
{
	HeapTuple	tup;
	Form_pg_class classform;

	*nspname_out = NULL;
	*relname_out = NULL;

	tup = SearchSysCache1(RELOID, ObjectIdGetDatum(seqoid));
	if (!HeapTupleIsValid(tup))
		return;
	classform = (Form_pg_class) GETSTRUCT(tup);
	*nspname_out = get_namespace_name(classform->relnamespace);
	*relname_out = pstrdup(NameStr(classform->relname));
	ReleaseSysCache(tup);
}

/*
 * Parse the catalog row's kind text into the enum.  ereports on garbage.
 */
static SpockSeqAmKind
seqam_parse_kind_datum(Datum kind_datum, const char *context_relname)
{
	text	   *t = DatumGetTextPP(kind_datum);
	char	   *kindstr = text_to_cstring(t);
	SpockSeqAmKind kind;

	if (strcmp(kindstr, "local") == 0)
		kind = SPOCK_SEQAM_LOCAL;
	else if (strcmp(kindstr, "snowflake") == 0)
		kind = SPOCK_SEQAM_SNOWFLAKE;
	else
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("unrecognised spock.sequence_kind value \"%s\" for sequence \"%s\"",
						kindstr,
						context_relname ? context_relname : "?")));

	pfree(kindstr);
	return kind;
}

/*
 * Look up the spock.sequence_kind row by (nspname, relname).  Returns the
 * parsed kind via *kind_out and true if a row exists; false if the catalog
 * does not exist (early extension lifecycle) or no row matches.
 *
 * Caller must be inside a transaction.
 */
bool
spock_seqam_lookup_kind_by_name(const char *nspname, const char *relname,
								SpockSeqAmKind *kind_out)
{
	Relation		rel;
	SysScanDesc		scan;
	ScanKeyData		key[2];
	HeapTuple		tup;
	bool			found = false;
	Oid				idxoid;

	Assert(nspname != NULL);
	Assert(relname != NULL);
	Assert(IsTransactionState());	/* systable_beginscan needs a xact */

	rel = seqam_catalog_open(AccessShareLock);
	if (rel == NULL)
		return false;

	idxoid = seqam_catalog_pkidx_oid(rel);

	ScanKeyInit(&key[0],
				Anum_sequence_kind_nspname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(nspname));
	ScanKeyInit(&key[1],
				Anum_sequence_kind_relname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(relname));

	scan = systable_beginscan(rel, idxoid, OidIsValid(idxoid), NULL, 2, key);
	tup = systable_getnext(scan);
	if (HeapTupleIsValid(tup))
	{
		bool		isnull;
		Datum		d;

		d = heap_getattr(tup, Anum_sequence_kind_kind,
						 RelationGetDescr(rel), &isnull);
		if (isnull)
			elog(ERROR,
				 "spock.sequence_kind row for %s.%s has NULL kind",
				 nspname, relname);

		*kind_out = seqam_parse_kind_datum(d, relname);
		found = true;
	}

	systable_endscan(scan);
	table_close(rel, AccessShareLock);

	return found;
}

/*
 * Look up the spock.sequence_kind row for seqoid.  Returns the parsed kind
 * via *kind_out and true if a row exists; false if no row or if the
 * sequence's relation no longer resolves to a name (concurrent drop).
 *
 * The lookup is keyed on (nspname, relname) -- names round-trip across
 * pg_dump/restore where OIDs do not.  seqoid -> name resolution is via the
 * RELOID syscache, which is hot on the same code path that brought us
 * here from nextval_internal().
 *
 * Caller must be inside a transaction.
 */
static bool
seqam_catalog_lookup(Oid seqoid, SpockSeqAmKind *kind_out)
{
	char		   *nspname;
	char		   *relname;
	bool			found;

	seqam_resolve_seq_name(seqoid, &nspname, &relname);
	if (nspname == NULL || relname == NULL)
		return false;

	found = spock_seqam_lookup_kind_by_name(nspname, relname, kind_out);

	pfree(nspname);
	pfree(relname);

	return found;
}


/*
 * Sinval-driven invalidation callback.  Two paths:
 *
 *   - Catalog or wildcard invalidation: destroy the whole cache.
 *   - Sequence-relation invalidation: remove that one entry.
 *
 * Safe to free outright because the dispatcher never holds an entry
 * pointer across code that can fire callbacks (probe-then-populate
 * pattern; see spock_seqam_nextval).
 */
static void
seqam_relcache_invalidate(Datum arg, Oid relid)
{
	(void) arg;

	if (SeqAmCatalogRelid == InvalidOid || relid == InvalidOid ||
		relid == SeqAmCatalogRelid)
	{
		HTAB	   *cache = SeqAmCache;

		/* NULL the pointer first so any nested callback is idempotent. */
		SeqAmCache = NULL;
		SeqAmCatalogPKIdxRelid = InvalidOid;
		SeqAmCatalogOidIdxRelid = InvalidOid;
		SeqAmCatalogRelid = InvalidOid;
		if (cache != NULL)
			hash_destroy(cache);
	}
	else if (SeqAmCache != NULL)
		(void) hash_search(SeqAmCache, &relid, HASH_REMOVE, NULL);
}

static void
seqam_init_cache(void)
{
	HASHCTL		ctl;

	if (SeqAmCache != NULL)
		return;

	MemSet(&ctl, 0, sizeof(ctl));
	ctl.keysize = sizeof(Oid);
	ctl.entrysize = sizeof(SeqAmCacheEntry);
	ctl.hcxt = AllocSetContextCreate(TopMemoryContext,
									 "spock seqam cache",
									 ALLOCSET_SMALL_SIZES);

	SeqAmCache = hash_create("spock seqam backend cache",
							 128, &ctl,
							 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	/*
	 * NOTE: the relcache callback itself is registered once at module load
	 * in spock_seqam_init(), not here, so that backends which never call a
	 * managed nextval() still receive DROP SEQUENCE invalidations.
	 */
}

/* ----- The hook --------------------------------------------------------- */

/*
 * spock_seqam_nextval
 *		Single-consumer implementation of nextval_hook with the SeqAM-
 *		compatible signature (mirrors Paquier's upstream
 *		SequenceAmRoutine.nextval).  Returns the value to use as the
 *		result of nextval(), and sets *last to the prefetch frontier
 *		so the in-core CACHE fast path is informed.
 *
 *		For sequences Spock has chosen not to manage, delegates to
 *		sequence_am_local_nextval with the same arguments.  For managed
 *		sequences, dispatches to the per-kind method via SeqAmMethods.
 */
static int64
spock_seqam_nextval(Relation rel,
					int64 incby, int64 maxv, int64 minv,
					int64 cache, bool cycle,
					int64 *last)
{
	Oid					seqoid = RelationGetRelid(rel);
	SeqAmCacheEntry	   *entry;
	SpockSeqAmKind		kind;
	const SpockSeqAmMethod *method;

	/* init_sequence() upstream already opened the relation. */
	Assert(IsTransactionState());

	if (SeqAmCache == NULL)
		seqam_init_cache();

	/*
	 * Probe the cache.  On a hit we read kind into a local immediately
	 * and stop referring to `entry`, so the relcache callback is free to
	 * destroy or modify the hash later without worrying about live
	 * pointers from our stack frame.
	 */
	entry = (SeqAmCacheEntry *) hash_search(SeqAmCache, &seqoid,
											HASH_FIND, NULL);
	if (entry != NULL)
	{
		kind = entry->kind;
	}
	else
	{
		bool		found;

		/*
		 * Catalog lookup acquires a lock and processes pending sinval,
		 * which fires our callback.  Hold no entry pointer across this
		 * call -- the callback may HASH_REMOVE this seqoid (individual
		 * inval) or hash_destroy the whole cache (catalog inval).
		 */
		if (!seqam_catalog_lookup(seqoid, &kind))
			kind = spock_seqam_default_kind;

		/* Re-create if a callback nuked the cache during the lookup. */
		if (SeqAmCache == NULL)
			seqam_init_cache();

		entry = (SeqAmCacheEntry *) hash_search(SeqAmCache, &seqoid,
												HASH_ENTER, &found);
		entry->kind = kind;
	}

	/* Unmanaged sequence: stock semantics. */
	if (kind == SPOCK_SEQAM_LOCAL)
		return sequence_am_local_nextval(rel, incby, maxv, minv,
										 cache, cycle, last);

	/* Managed dispatch is unsupported in these states. */
	Assert(!RecoveryInProgress());
	Assert(!creating_extension);
	Assert(!IsBinaryUpgrade);
	Assert(kind > SPOCK_SEQAM_LOCAL && kind < SPOCK_SEQAM_NMETHODS);

	method = SeqAmMethods[kind];
	Assert(method != NULL);
	Assert(method->nextval != NULL);

	return method->nextval(rel, incby, maxv, minv, cache, cycle, last);
}


/* ----- _PG_init entry point -------------------------------------------- */

void
spock_seqam_init(void)
{
	/*
	 * Managed-sequence state lives in the sequence's own heap tuple
	 * (last_value), so there is no per-sequence shared-memory subsystem to
	 * configure here.  spock.max_managed_sequences from earlier revisions
	 * is gone; an entry in postgresql.conf for it produces a
	 * "unrecognized configuration parameter" message at startup.
	 */

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

	spock_seqam_register_methods();

	/*
	 * Register the relcache invalidation callback once at module load.
	 * Registering it lazily on first hook firing meant that a backend
	 * which never called a managed nextval() (e.g. one that ran nothing
	 * but DDL) would never see invalidations and could leak orphan
	 * entries in the per-backend cache.
	 */
	CacheRegisterRelcacheCallback(seqam_relcache_invalidate, (Datum) 0);

	/*
	 * Install the nextval_hook.  Single-consumer: refuse to load if
	 * another extension already installed the hook, since the hook is
	 * the full value-generation path and chaining is not supported (see
	 * contract in commands/sequence.h).
	 */
	if (nextval_hook != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("nextval_hook is already installed by another extension"),
				 errhint("Only one extension may install nextval_hook.  "
						 "Remove the conflicting extension from "
						 "shared_preload_libraries, or unload it before "
						 "loading Spock.")));
	nextval_hook = spock_seqam_nextval;
}


/* ----- DROP SEQUENCE cleanup ------------------------------------------- */

/*
 * Delete the spock.sequence_kind row (if any) and free the per-sequence
 * shared-memory slot for the given sequence OID.  Called from the
 * object_access OAT_DROP path for RELKIND_SEQUENCE relations.
 *
 * Cross-node propagation: under autoddl, the DROP SEQUENCE itself
 * replicates and fires this hook locally on each node, so no special
 * apply-context handling is needed -- every node runs its own delete.
 *
 * The row is keyed on (nspname, relname).  We can still resolve the
 * sequence's name from its OID at OAT_DROP time: pg_class hasn't been
 * removed yet.  If the resolution fails (extension dropping, sequence
 * already removed from pg_class), the row -- if any -- becomes orphaned
 * and is cleaned up by the next spock.convert_all_sequences() run; this
 * is acceptable best-effort behaviour.
 */
void
spock_seqam_drop_sequence_record(Oid seqoid)
{
	Relation		rel;
	SysScanDesc		scan;
	ScanKeyData		key[2];
	HeapTuple		tup;
	char		   *nspname;
	char		   *relname;

	/*
	 * If the extension itself is being dropped, the catalog table is about
	 * to disappear too -- nothing to clean up.  Cleanup runs under
	 * superuser privileges because OAT_DROP can fire under a caller who
	 * has no rights on spock.sequence_kind -- see spock_executor.c for
	 * the SetUserIdAndSecContext shuffle.
	 */
	if (get_extension_oid(EXTENSION_NAME, true) == InvalidOid)
		return;

	seqam_resolve_seq_name(seqoid, &nspname, &relname);
	if (nspname == NULL || relname == NULL)
		return;

	rel = seqam_catalog_open(RowExclusiveLock);
	if (rel == NULL)
		return;

	ScanKeyInit(&key[0],
				Anum_sequence_kind_nspname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(nspname));
	ScanKeyInit(&key[1],
				Anum_sequence_kind_relname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(relname));
	scan = systable_beginscan(rel, seqam_catalog_pkidx_oid(rel), true,
							  NULL, 2, key);
	tup = systable_getnext(scan);
	if (HeapTupleIsValid(tup))
		simple_heap_delete(rel, &tup->t_self);
	systable_endscan(scan);
	table_close(rel, RowExclusiveLock);
}


/* ----- ALTER SEQUENCE RENAME / SET SCHEMA cleanup ---------------------- */

/*
 * Update the (nspname, relname) of a spock.sequence_kind row when ALTER
 * SEQUENCE ... RENAME TO ... or ALTER SEQUENCE ... SET SCHEMA fires.
 *
 * Called from spock_object_access on OAT_POST_ALTER for RELKIND_SEQUENCE
 * with subId == 0.  At this point pg_class already reflects the new name;
 * we look up our row by the (rename-stable) seqoid via the secondary
 * index and rewrite (nspname, relname) if they differ.
 *
 * Best-effort: if no row matches seqoid (no kind assigned, or seqoid
 * column is stale from a logical restore), nothing to do.  The next
 * spock.alter_sequence_set_kind() or spock.convert_all_sequences() on
 * this sequence refreshes the seqoid column.
 */
void
spock_seqam_relocate_sequence_record(Oid seqoid)
{
	Relation		rel;
	SysScanDesc		scan;
	ScanKeyData		key[1];
	HeapTuple		tup;
	Oid				idxoid;
	char		   *new_nsp;
	char		   *new_rel;

	if (get_extension_oid(EXTENSION_NAME, true) == InvalidOid)
		return;

	/*
	 * OAT_POST_ALTER fires after the catalog tuple update but before the
	 * CommandCounterIncrement that would publish it to the syscaches.
	 * Without an explicit CCI here, the syscache lookup below returns
	 * the pre-rename name and we conclude (wrongly) that nothing changed.
	 */
	CommandCounterIncrement();

	seqam_resolve_seq_name(seqoid, &new_nsp, &new_rel);
	if (new_nsp == NULL || new_rel == NULL)
		return;

	rel = seqam_catalog_open(RowExclusiveLock);
	if (rel == NULL)
		return;

	idxoid = seqam_catalog_oididx_oid(rel);

	ScanKeyInit(&key[0],
				Anum_sequence_kind_seqoid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(seqoid));
	scan = systable_beginscan(rel, idxoid, OidIsValid(idxoid), NULL, 1, key);
	tup = systable_getnext(scan);
	if (HeapTupleIsValid(tup))
	{
		Datum		values[Natts_sequence_kind];
		bool		nulls[Natts_sequence_kind];
		bool		replaces[Natts_sequence_kind];
		bool		row_nsp_isnull;
		bool		row_rel_isnull;
		Datum		row_nsp_d;
		Datum		row_rel_d;

		row_nsp_d = heap_getattr(tup, Anum_sequence_kind_nspname,
								 RelationGetDescr(rel), &row_nsp_isnull);
		row_rel_d = heap_getattr(tup, Anum_sequence_kind_relname,
								 RelationGetDescr(rel), &row_rel_isnull);

		/*
		 * Compare with the live name.  If unchanged (the typical case for
		 * non-rename ALTER SEQUENCE: OWNER TO, SET LOGGED/UNLOGGED, ...)
		 * skip the catalog rewrite.  Saves an unnecessary WAL record per
		 * ALTER on every managed sequence.
		 */
		if (!row_nsp_isnull && !row_rel_isnull &&
			strcmp(NameStr(*DatumGetName(row_nsp_d)), new_nsp) == 0 &&
			strcmp(NameStr(*DatumGetName(row_rel_d)), new_rel) == 0)
		{
			systable_endscan(scan);
			table_close(rel, RowExclusiveLock);
			return;
		}

		MemSet(nulls, false, sizeof(nulls));
		MemSet(replaces, false, sizeof(replaces));

		values[Anum_sequence_kind_nspname - 1] = CStringGetDatum(new_nsp);
		values[Anum_sequence_kind_relname - 1] = CStringGetDatum(new_rel);
		replaces[Anum_sequence_kind_nspname - 1] = true;
		replaces[Anum_sequence_kind_relname - 1] = true;

		{
			HeapTuple newtup = heap_modify_tuple(tup, RelationGetDescr(rel),
												 values, nulls, replaces);

			CatalogTupleUpdate(rel, &tup->t_self, newtup);
		}
	}
	systable_endscan(scan);
	table_close(rel, RowExclusiveLock);

	/*
	 * Invalidate per-backend cache entries on this node so subsequent
	 * nextval() calls re-resolve under the new name.  The seqoid hasn't
	 * changed but the kind lookup for it depends on the (now updated)
	 * (nspname, relname) row.
	 */
	CacheInvalidateRelcacheByRelid(seqoid);
}


/* ----- SQL-callable functions ------------------------------------------ */

PG_FUNCTION_INFO_V1(spock_alter_sequence_set_kind);
PG_FUNCTION_INFO_V1(spock_convert_all_sequences);
PG_FUNCTION_INFO_V1(spock_sequence_hook_available);

/*
 * Parse a "kind" string into a SpockSeqAmKind, ereporting on bad input.
 *
 * Centralised so the same validation/errmsg fires from every entry point
 * (spock_alter_sequence_set_kind, spock_convert_all_sequences).
 */
static SpockSeqAmKind
parse_sequence_kind(const char *kindstr)
{
	if (strcmp(kindstr, "local") == 0)
		return SPOCK_SEQAM_LOCAL;
	if (strcmp(kindstr, "snowflake") == 0)
		return SPOCK_SEQAM_SNOWFLAKE;

	ereport(ERROR,
			(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
			 errmsg("invalid sequence kind \"%s\"", kindstr),
			 errhint("Valid kinds are: local, snowflake.")));
	pg_unreachable();
}

/*
 * Validate that a sequence is a legitimate target for a managed kind.
 *
 * Caller holds a lock that conflicts with ALTER SEQUENCE, so seqtypid /
 * seqmax / seqcache are stable for the duration of this call.
 *
 * SPOCK_SEQAM_LOCAL is always valid.  SPOCK_SEQAM_SNOWFLAKE refuses:
 *   - seqtypid != INT8OID (a snowflake doesn't fit in a smaller type),
 *   - seqmax < 1 << 22 (any non-zero snowflake timestamp shifts left
 *     22 bits; smaller MAXVALUE excludes the snowflake range),
 *   - seqcache > 1 (the in-core CACHE fast path would emit (cache-1)
 *     stock-arithmetic values between hook calls).
 *
 * Note: snowflake otherwise ignores seqincrement, seqmin, seqcycle.  The
 * SQL standard treats them as monotonicity contracts on nextval(); managed
 * kinds opt out of that contract by construction.  We do not currently
 * reject non-default values for those clauses, but operators should be
 * aware they are advisory once kind != local.
 */
static void
validate_sequence_target(Oid seqoid, SpockSeqAmKind kind)
{
	Form_pg_sequence	seqform;
	HeapTuple			tup;
	Oid					typid;
	int64				maxv;
	int64				cachev;
	int64				incby;
	const char		   *relname;

	if (kind != SPOCK_SEQAM_SNOWFLAKE)
		return;

	tup = SearchSysCache1(SEQRELID, ObjectIdGetDatum(seqoid));
	if (!HeapTupleIsValid(tup))
		elog(ERROR, "cache lookup failed for sequence %u", seqoid);
	seqform = (Form_pg_sequence) GETSTRUCT(tup);
	typid = seqform->seqtypid;
	maxv = seqform->seqmax;
	cachev = seqform->seqcache;
	incby = seqform->seqincrement;
	ReleaseSysCache(tup);

	/* Caller holds a lock on the sequence; the name is stable. */
	relname = get_rel_name(seqoid);
	if (relname == NULL)
		relname = "?";

	if (typid != INT8OID)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("sequence \"%s\" cannot be set to kind \"snowflake\"",
						relname),
				 errdetail("Snowflake values are bigint; the sequence is declared with a smaller type."),
				 errhint("Use ALTER SEQUENCE %s AS bigint, then retry.",
						 relname)));

	/*
	 * Snowflake values use the full non-negative int64 range: as the
	 * 41-bit timestamp field advances toward its year-2092 ceiling, the
	 * emitted bigint approaches PG_INT64_MAX.  Any user-imposed MAXVALUE
	 * less than PG_INT64_MAX would eventually be violated by some valid
	 * emission, so require NO MAXVALUE (which sets seqmax to
	 * PG_INT64_MAX on an ascending sequence).
	 */
	if (maxv < PG_INT64_MAX)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("sequence \"%s\" cannot be set to kind \"snowflake\"",
						relname),
				 errdetail("Sequence MAXVALUE is " INT64_FORMAT
						   "; snowflake emissions use the full int64 range.",
						   maxv),
				 errhint("Use ALTER SEQUENCE %s NO MAXVALUE, then retry.",
						 relname)));

	/*
	 * CACHE > 1 would let the in-core CACHE fast path emit (cache-1)
	 * values via stock += increment before re-entering the hook; those
	 * are not valid snowflakes.
	 */
	if (cachev > 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("sequence \"%s\" cannot be set to kind \"snowflake\"",
						relname),
				 errdetail("Sequence CACHE is " INT64_FORMAT
						   "; managed kinds require CACHE 1.", cachev),
				 errhint("Use ALTER SEQUENCE %s CACHE 1, then retry.",
						 relname)));

	/*
	 * INCREMENT must be in 1..SPOCK_SNOWFLAKE_COUNTER_MASK.
	 *
	 * Lower bound: non-positive increments would either collide on the
	 * counter portion (0) or emit decreasing counters (< 0), violating
	 * per-node monotonicity.
	 *
	 * Upper bound: the snowflake counter is 12 bits; an increment greater
	 * than COUNTER_MASK (4095) overflows the counter every call,
	 * degenerating to "one millisecond per nextval".  Beyond being useless
	 * for batch-allocation patterns it costs throughput, and a large
	 * positive int64 would overflow when cast to int32 in the hot path.
	 * Reject up front rather than silently degrade or invoke undefined
	 * behaviour.
	 *
	 * Useful range: 1 covers single-id allocation; 32..1000 covers the
	 * Hibernate pooled-hi/lo patterns (each nextval skips that many
	 * counter slots so the application can derive the intermediate IDs
	 * locally without colliding with another node).
	 */
	if (incby <= 0 || incby > (int64) SPOCK_SNOWFLAKE_COUNTER_MASK)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("sequence \"%s\" cannot be set to kind \"snowflake\"",
						relname),
				 errdetail("Sequence INCREMENT is " INT64_FORMAT
						   "; managed kinds require an increment in 1..%u.",
						   incby, (unsigned) SPOCK_SNOWFLAKE_COUNTER_MASK),
				 errhint("Use ALTER SEQUENCE %s INCREMENT 1, then retry.",
						 relname)));
}

/*
 * spock.alter_sequence_set_kind(seqname regclass, kind text)
 *
 * Insert or replace the spock.sequence_kind row for the given sequence.
 * 'kind' must be one of: 'local', 'snowflake'.
 *
 * The row is keyed on (nspname, relname) and also stores the local seqoid
 * for the OAT_POST_ALTER hook's by-OID lookup.  Effect is node-local:
 * autoddl replicates only LOGSTMT_DDL utility statements, not SQL function
 * invocations, so cross-node propagation requires the operator to run this
 * call on every node (each node then writes its own row with its own
 * local seqoid).  See sql/spock--6.0.0.sql at spock.sequence_kind for the
 * full caveat.
 */
Datum
spock_alter_sequence_set_kind(PG_FUNCTION_ARGS)
{
	Oid				seqoid = PG_GETARG_OID(0);
	text		   *kind_in = PG_GETARG_TEXT_PP(1);
	char		   *kindstr = text_to_cstring(kind_in);
	SpockSeqAmKind	kind;
	SpockSeqAmKind	row_kind = SPOCK_SEQAM_LOCAL;	/* unused unless found */
	Relation		rel;
	SysScanDesc		scan;
	ScanKeyData		key[2];
	HeapTuple		tup;
	bool			found;

	kind = parse_sequence_kind(kindstr);

	/*
	 * Lock the sequence before any property check.  ShareUpdateExclusive
	 * conflicts with ALTER SEQUENCE (ShareRowExclusive) so the seqcache
	 * / seqmax / seqtypid we validate below cannot drift between the
	 * check and our catalog write, and is self-conflicting so two
	 * concurrent alter_sequence_set_kind callers serialise.  Does not
	 * conflict with nextval (RowExclusive).
	 */
	LockRelationOid(seqoid, ShareUpdateExclusiveLock);

	/* Concurrent DROP that committed before our lock: report cleanly. */
	if (get_rel_relkind(seqoid) != RELKIND_SEQUENCE)
	{
		UnlockRelationOid(seqoid, ShareUpdateExclusiveLock);
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("relation with OID %u is not a sequence", seqoid)));
	}

	/*
	 * Stash the name now: get_rel_name() can return NULL under syscache
	 * pressure even while we hold the lock, which aclcheck_error() would
	 * pass straight to %s.
	 */
	{
		char	   *seqrelname = get_rel_name(seqoid);

		if (seqrelname == NULL)
			elog(ERROR, "cache lookup failed for sequence %u", seqoid);

		/* pg_class_ownercheck was renamed in PG 16; gate via PG_VERSION_NUM. */
#if PG_VERSION_NUM >= 160000
		if (!object_ownercheck(RelationRelationId, seqoid, GetUserId()))
			aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_SEQUENCE, seqrelname);
#else
		if (!pg_class_ownercheck(seqoid, GetUserId()))
			aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_SEQUENCE, seqrelname);
#endif
		pfree(seqrelname);
	}

	validate_sequence_target(seqoid, kind);

	{
		char	   *nspname;
		char	   *relname;

		seqam_resolve_seq_name(seqoid, &nspname, &relname);
		if (nspname == NULL || relname == NULL)
			elog(ERROR, "cache lookup failed for sequence %u", seqoid);

		rel = seqam_catalog_open(RowExclusiveLock);
		if (rel == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_TABLE),
					 errmsg("spock.sequence_kind catalog not found"),
					 errhint("The library is loaded but the extension is not "
							 "yet created.  Run CREATE EXTENSION spock first.")));

		ScanKeyInit(&key[0],
					Anum_sequence_kind_nspname,
					BTEqualStrategyNumber, F_NAMEEQ,
					CStringGetDatum(nspname));
		ScanKeyInit(&key[1],
					Anum_sequence_kind_relname,
					BTEqualStrategyNumber, F_NAMEEQ,
					CStringGetDatum(relname));
		scan = systable_beginscan(rel, seqam_catalog_pkidx_oid(rel), true,
								  NULL, 2, key);
		tup = systable_getnext(scan);
		found = HeapTupleIsValid(tup);

		/*
		 * If a row already exists, capture its current kind so we can tell
		 * whether this call is a true kind change (which must reset the
		 * sequence's heap-tuple state) or a no-op same-kind re-assertion
		 * (which must NOT wipe accumulated snowflake state -- doing so
		 * risks emitting a value that was already issued earlier in the
		 * same millisecond).
		 */
		if (found)
		{
			Datum		d;
			bool		isnull;
			char	   *existing_kindstr;

			d = heap_getattr(tup, Anum_sequence_kind_kind,
							 RelationGetDescr(rel), &isnull);
			Assert(!isnull);
			existing_kindstr = TextDatumGetCString(d);
			row_kind = parse_sequence_kind(existing_kindstr);
			pfree(existing_kindstr);
		}

		{
			Datum		values[Natts_sequence_kind];
			bool		nulls[Natts_sequence_kind];
			bool		replaces[Natts_sequence_kind];
			HeapTuple	newtup;

			MemSet(nulls, false, sizeof(nulls));
			MemSet(replaces, false, sizeof(replaces));

			values[Anum_sequence_kind_nspname - 1] = CStringGetDatum(nspname);
			values[Anum_sequence_kind_relname - 1] = CStringGetDatum(relname);
			values[Anum_sequence_kind_kind - 1] = CStringGetTextDatum(kindstr);
			values[Anum_sequence_kind_seqoid - 1] = ObjectIdGetDatum(seqoid);

			if (found)
			{
				/* Update kind+seqoid in place; nspname/relname are the PK. */
				replaces[Anum_sequence_kind_kind - 1] = true;
				replaces[Anum_sequence_kind_seqoid - 1] = true;
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
	}

	/*
	 * Seed last_value = 0 so the method's first nextval doesn't misread
	 * stale stock counts as packed state.  LOCAL needs no seed.
	 *
	 * Only reset on a real transition: a fresh insert (!found) or an
	 * actual kind change (row_kind != kind).  Resetting a sequence
	 * already in the target kind would clobber its accumulated
	 * (ts, ctr) state and could cause a same-millisecond duplicate.
	 */
	if (kind != SPOCK_SEQAM_LOCAL && (!found || row_kind != kind))
	{
		Relation	seqrel;

		seqrel = table_open(seqoid, RowExclusiveLock);
		seqam_reset_sequence_data(seqrel);
		table_close(seqrel, NoLock);
	}

	/*
	 * CatalogTupleUpdate on a non-system catalog does not fire relcache
	 * invalidations on its own; force one keyed on the sequence so other
	 * backends ON THIS NODE rebuild their cached (seqoid -> kind) entry.
	 * Cross-node propagation is the operator's job (this function runs
	 * separately on every node); when autoddl learns to replicate SQL
	 * function calls, each node's local invocation will fire its own
	 * invalidation locally.
	 */
	CacheInvalidateRelcacheByRelid(seqoid);

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
	text		   *kind_in = PG_GETARG_TEXT_PP(0);
	bool			force = PG_GETARG_BOOL(1);
	char		   *kindstr = text_to_cstring(kind_in);
	SpockSeqAmKind	kind;
	Relation		pgclass;
	Relation		skrel;
	RangeVar	   *skrv;
	SysScanDesc		scan;
	HeapTuple		tup;
	int				n_converted = 0;

	/* Touches sequences owned by other roles; restrict to superuser. */
	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to run spock.convert_all_sequences"),
				 errhint("Use spock.alter_sequence_set_kind() per sequence to "
						 "convert sequences you own.")));

	kind = parse_sequence_kind(kindstr);

	/* Database-scoped advisory xact lock: serialise concurrent conversions. */
	{
		LOCKTAG		tag;

		SET_LOCKTAG_ADVISORY(tag, MyDatabaseId,
							 (uint32) 0x53504F43,	/* "SPOC" */
							 (uint32) 0x4B534551,	/* "KSEQ" */
							 1);
		(void) LockAcquire(&tag, ExclusiveLock, false, false);
	}

	skrv = makeRangeVar(EXTENSION_NAME, CATALOG_SEQUENCE_KIND, -1);
	skrel = table_openrv(skrv, RowExclusiveLock);

	pgclass = table_open(RelationRelationId, AccessShareLock);
	scan = systable_beginscan(pgclass, InvalidOid, false, NULL, 0, NULL);

	while (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_class classform = (Form_pg_class) GETSTRUCT(tup);
		Oid			seqoid;
		SysScanDesc	sscan;
		ScanKeyData	key[2];
		HeapTuple	srow;
		bool		exists;

		if (classform->relkind != RELKIND_SEQUENCE)
			continue;

		/*
		 * Skip system / temp schemas.  `relnamespace < FirstNormalObjectId`
		 * would also skip "public" (OID 2200), which is wrong; filter by
		 * IsCatalogNamespace + isAnyTempNamespace + "pg_*"/"information_schema".
		 */
		{
			Oid			nspoid = classform->relnamespace;
			char	   *nspname;

			if (IsCatalogNamespace(nspoid) || isAnyTempNamespace(nspoid))
				continue;

			nspname = get_namespace_name(nspoid);
			if (nspname == NULL)
				continue;
			if (strncmp(nspname, "pg_", 3) == 0 ||
				strcmp(nspname, "information_schema") == 0)
			{
				pfree(nspname);
				continue;
			}
			pfree(nspname);
		}

		seqoid = classform->oid;

		/* Extension-owned sequences (e.g. Spock's own sub_id_generator). */
		if (OidIsValid(getExtensionOfObject(RelationRelationId, seqoid)))
			continue;

		/*
		 * ShareUpdateExclusive blocks concurrent ALTER SEQUENCE; held to
		 * commit, so seqcache / seqmax / seqtypid we validate below cannot
		 * drift before our catalog write.  Self-conflicting; doesn't block
		 * nextval.
		 */
		LockRelationOid(seqoid, ShareUpdateExclusiveLock);
		if (get_rel_relkind(seqoid) != RELKIND_SEQUENCE)
		{
			UnlockRelationOid(seqoid, ShareUpdateExclusiveLock);
			continue;
		}

		/*
		 * Fail the whole conversion on any incompatible target -- partial
		 * conversion across the cluster is worse than none.
		 */
		validate_sequence_target(seqoid, kind);

		{
			char	   *nspname = get_namespace_name(classform->relnamespace);
			char	   *relname = NameStr(classform->relname);

			ScanKeyInit(&key[0],
						Anum_sequence_kind_nspname,
						BTEqualStrategyNumber, F_NAMEEQ,
						CStringGetDatum(nspname));
			ScanKeyInit(&key[1],
						Anum_sequence_kind_relname,
						BTEqualStrategyNumber, F_NAMEEQ,
						CStringGetDatum(relname));
			sscan = systable_beginscan(skrel, seqam_catalog_pkidx_oid(skrel),
									   true, NULL, 2, key);
			srow = systable_getnext(sscan);
			exists = HeapTupleIsValid(srow);

			/*
			 * (a) no row -> INSERT; (b) row exists, force or kind change ->
			 * UPDATE kind+seqoid; (c) row exists, no kind change, seqoid
			 * drifted (logical restore) -> refresh seqoid only.
			 */
			{
				Datum		values[Natts_sequence_kind];
				bool		nulls[Natts_sequence_kind];
				bool		replaces[Natts_sequence_kind];
				HeapTuple	newtup;
				bool		did_write = false;
				bool		needs_reset = false;

				MemSet(nulls, false, sizeof(nulls));
				MemSet(replaces, false, sizeof(replaces));

				values[Anum_sequence_kind_nspname - 1] = CStringGetDatum(nspname);
				values[Anum_sequence_kind_relname - 1] = CStringGetDatum(relname);
				values[Anum_sequence_kind_kind - 1] = CStringGetTextDatum(kindstr);
				values[Anum_sequence_kind_seqoid - 1] = ObjectIdGetDatum(seqoid);

				if (!exists)
				{
					newtup = heap_form_tuple(RelationGetDescr(skrel),
											 values, nulls);
					CatalogTupleInsert(skrel, newtup);
					did_write = true;
					needs_reset = (kind != SPOCK_SEQAM_LOCAL);
				}
				else
				{
					Datum		row_kind_d;
					Datum		row_seqoid_d;
					bool		isnull;
					SpockSeqAmKind	row_kind;
					Oid			row_seqoid;

					row_kind_d = heap_getattr(srow, Anum_sequence_kind_kind,
											  RelationGetDescr(skrel), &isnull);
					if (isnull)
						elog(ERROR,
							 "spock.sequence_kind row for %s.%s has NULL kind",
							 nspname, relname);
					row_kind = seqam_parse_kind_datum(row_kind_d, relname);

					row_seqoid_d = heap_getattr(srow, Anum_sequence_kind_seqoid,
												RelationGetDescr(skrel), &isnull);
					row_seqoid = isnull ? InvalidOid : DatumGetObjectId(row_seqoid_d);

					if (force || row_kind != kind)
					{
						replaces[Anum_sequence_kind_kind - 1] = true;
						replaces[Anum_sequence_kind_seqoid - 1] = true;
						newtup = heap_modify_tuple(srow,
												   RelationGetDescr(skrel),
												   values, nulls, replaces);
						CatalogTupleUpdate(skrel, &srow->t_self, newtup);
						did_write = true;
						/* Reset only on actual transition; force-rewrite
						 * of the same kind keeps in-flight (ts, ctr). */
						needs_reset = (kind != SPOCK_SEQAM_LOCAL &&
									   row_kind != kind);
					}
					else if (row_seqoid != seqoid)
					{
						/* Refresh stale seqoid only. */
						replaces[Anum_sequence_kind_seqoid - 1] = true;
						newtup = heap_modify_tuple(srow,
												   RelationGetDescr(skrel),
												   values, nulls, replaces);
						CatalogTupleUpdate(skrel, &srow->t_self, newtup);
						did_write = true;
					}
				}

				if (needs_reset)
				{
					Relation	seqrel;

					seqrel = table_open(seqoid, RowExclusiveLock);
					seqam_reset_sequence_data(seqrel);
					table_close(seqrel, NoLock);
				}

				if (did_write)
				{
					CacheInvalidateRelcacheByRelid(seqoid);
					n_converted++;
				}
			}

			systable_endscan(sscan);
		}
	}

	systable_endscan(scan);
	table_close(pgclass, AccessShareLock);
	table_close(skrel, RowExclusiveLock);

	CommandCounterIncrement();
	pfree(kindstr);

	PG_RETURN_INT32(n_converted);
}

/*
 * True when Spock is attached to the in-core nextval_hook.  The library
 * fails to load on unpatched PG (PGDLLIMPORT reference), so this is
 * effectively always true once SQL can call it; retained for monitoring
 * tools and forward compatibility with a runtime-feature-probe build.
 */
Datum
spock_sequence_hook_available(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL((void *) nextval_hook == (void *) spock_seqam_nextval);
}
