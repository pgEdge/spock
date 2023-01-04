/*-------------------------------------------------------------------------
 *
 * spock_conflict.c
 * 		Functions for detecting and handling conflicts
 *
 * Copyright (c) 2021-2022, OSCG Partners, LLC
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "libpq-fe.h"

#include "miscadmin.h"

#include "access/commit_ts.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/transam.h"
#include "access/xact.h"

#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/pg_type.h"

#include "common/hashfn.h"

#include "executor/executor.h"

#include "parser/parse_relation.h"

#include "replication/origin.h"
#include "replication/reorderbuffer.h"

#include "storage/bufmgr.h"
#include "storage/lmgr.h"

#include "utils/builtins.h"
#include "utils/datetime.h"
#include "utils/lsyscache.h"
#include "utils/pg_lsn.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"
#include "utils/typcache.h"

#include "spock.h"
#include "spock_conflict.h"
#include "spock_proto_native.h"
#include "spock_node.h"
#include "spock_worker.h"

int		spock_conflict_resolver = SPOCK_RESOLVE_APPLY_REMOTE;
int		spock_conflict_log_level = LOG;
int		spock_conflict_max_tracking = 0;
bool	spock_save_resolutions = false;

static void tuple_to_stringinfo(StringInfo s, TupleDesc tupdesc,
	HeapTuple tuple);
static Datum spock_conflict_row_to_json(Datum row, bool row_isnull,
	bool *ret_isnull);

/*
 * Setup a ScanKey for a search in the relation 'rel' for a tuple 'key' that
 * is setup to match 'rel' (*NOT* idxrel!).
 *
 * Returns whether any column in the passed tuple contains a NULL for an
 * indexed field.
 */
static bool
build_index_scan_key(ScanKey skey, Relation rel, Relation idxrel, SpockTupleData *tup)
{
	int			attoff;
	Datum		indclassDatum;
	Datum		indkeyDatum;
	bool		isnull;
	oidvector  *opclass;
	int2vector  *indkey;
	bool		hasnulls = false;

	indclassDatum = SysCacheGetAttr(INDEXRELID, idxrel->rd_indextuple,
									Anum_pg_index_indclass, &isnull);
	Assert(!isnull);
	opclass = (oidvector *) DatumGetPointer(indclassDatum);

	indkeyDatum = SysCacheGetAttr(INDEXRELID, idxrel->rd_indextuple,
								  Anum_pg_index_indkey, &isnull);
	Assert(!isnull);
	indkey = (int2vector *) DatumGetPointer(indkeyDatum);

	/*
	 * Examine each indexed attribute to ensure the passed tuple's matching
	 * value isn't NULL and we have an equality operator for it.
	 */
	for (attoff = 0; attoff < IndexRelationGetNumberOfKeyAttributes(idxrel);
		 attoff++)
	{
		Oid			operator;
		Oid			opfamily;
		RegProcedure regop;
		int			pkattno = attoff + 1;
		int			mainattno = indkey->values[attoff];
		Oid			atttype = attnumTypeId(rel, mainattno);
		Oid			optype = get_opclass_input_type(opclass->values[attoff]);

		opfamily = get_opclass_family(opclass->values[attoff]);

		operator = get_opfamily_member(opfamily, optype,
									   optype,
									   BTEqualStrategyNumber);

		if (!OidIsValid(operator))
			elog(ERROR,
				 "could not lookup equality operator for type %u, optype %u in opfamily %u",
				 atttype, optype, opfamily);

		regop = get_opcode(operator);

		/* FIXME: convert type? */
		ScanKeyInit(&skey[attoff],
					pkattno,
					BTEqualStrategyNumber,
					regop,
					tup->values[mainattno - 1]);

		skey[attoff].sk_collation = idxrel->rd_indcollation[attoff];

		if (tup->nulls[mainattno - 1])
		{
			hasnulls = true;
			skey[attoff].sk_flags |= SK_ISNULL;
		}
	}

	return hasnulls;
}

/*
 * Search the index 'idxrel' for a tuple identified by 'skey' in 'rel'.
 *
 * If a matching tuple is found lock it with lockmode, fill the slot with its
 * contents and return true, false is returned otherwise.
 */
static bool
find_index_tuple(ScanKey skey, Relation rel, Relation idxrel,
				 LockTupleMode lockmode, TupleTableSlot *slot)
{
	bool		found;
	IndexScanDesc scan;
	SnapshotData snap;
	TransactionId xwait;

	/*
	 * We need SnapshotDirty because we're doing uniqueness lookups that must
	 * consider rows added/updated by concurrent transactions, just like a
	 * normal UNIQUE check does.
	 */
	InitDirtySnapshot(snap);
	scan = index_beginscan(rel, idxrel, &snap,
						   IndexRelationGetNumberOfKeyAttributes(idxrel),
						   0);

retry:
	found = false;

	index_rescan(scan, skey, IndexRelationGetNumberOfKeyAttributes(idxrel),
				 NULL, 0);

	if (index_getnext_slot(scan, ForwardScanDirection, slot))
	{
		found = true;
		ExecMaterializeSlot(slot);

		/*
		 * Did any concurrent txn affect the tuple? (See
		 * HeapTupleSatisfiesDirty for how we get this).
		 */
		xwait = TransactionIdIsValid(snap.xmin) ?
			snap.xmin : snap.xmax;

		if (TransactionIdIsValid(xwait))
		{
			/* Wait for the specified transaction to commit or abort */
			XactLockTableWait(xwait, NULL, NULL, XLTW_None);
			goto retry;
		}
	}

	/* Matching tuple found, no concurrent txns modifying it */
	if (found)
	{
		TM_FailureData tmfd;
		TM_Result res;

		PushActiveSnapshot(GetLatestSnapshot());

		res = table_tuple_lock(rel, &(slot->tts_tid), GetLatestSnapshot(),
							   slot,
							   GetCurrentCommandId(false),
							   lockmode,
							   LockWaitBlock,
							   0 /* don't follow updates */ ,
							   &tmfd);

		PopActiveSnapshot();

		switch (res)
		{
			case TM_Ok:
				/* lock was successfully acquired */
				break;
			case TM_Updated:
				/*
				 * We lost a race between when we looked up the tuple and
				 * checked for concurrent modifying txns and when we tried to
				 * lock the matched tuple.
				 *
				 * XXX: Improve handling here.
				 */
				ereport(LOG,
						(errcode(ERRCODE_T_R_SERIALIZATION_FAILURE),
						 errmsg("concurrent update, retrying")));
				goto retry;
			default:
				elog(ERROR, "unexpected HTSU_Result after locking: %u", res);
				break;
		}
	}

	index_endscan(scan);

	return found;
}

/*
 * Find tuple using REPLICA IDENTITY index and output it in 'oldslot'
 * if found.
 *
 * The index oid is also output.
 */
bool
spock_tuple_find_replidx(ResultRelInfo *relinfo, SpockTupleData *tuple,
							 TupleTableSlot *oldslot, Oid *idxrelid)
{
	Oid				idxoid;
	Relation		idxrel;
	ScanKeyData		index_key[INDEX_MAX_KEYS];
	bool			found;

	/* Open REPLICA IDENTITY index.*/
	idxoid = RelationGetReplicaIndex(relinfo->ri_RelationDesc);
	if (!OidIsValid(idxoid))
	{
		ereport(ERROR,
				(errmsg("could not find REPLICA IDENTITY index for table %s with oid %u",
						get_rel_name(RelationGetRelid(relinfo->ri_RelationDesc)),
						RelationGetRelid(relinfo->ri_RelationDesc)),
				 errhint("The REPLICA IDENTITY index is usually the PRIMARY KEY. See the PostgreSQL docs for ALTER TABLE ... REPLICA IDENTITY")));
	}
	*idxrelid = idxoid;
	idxrel = index_open(idxoid, RowExclusiveLock);

	/* Build scan key for just opened index*/
	build_index_scan_key(index_key, relinfo->ri_RelationDesc, idxrel, tuple);

	/* Try to find the row and store any matching row in 'oldslot'. */
	found = find_index_tuple(index_key, relinfo->ri_RelationDesc, idxrel,
							 LockTupleExclusive, oldslot);

	/* Don't release lock until commit. */
	index_close(idxrel, NoLock);

	return found;
}

/*
 * Find the tuple in a table using any index and returns the conflicting
 * index's oid, if any conflict found.
 *
 * This is not wholly safe. It does not consider the table's upstream replica
 * identity, and may choose to resolve the conflict on a unique index that
 * isn't part of the replica identity.
 *
 * Order-of-apply issues between multiple upstreams can lead to
 * non-deterministic behaviour in cases where we resolve one conflict using one
 * index, then a second conflict using a different index.
 *
 * We should really respect the replica identity more (i.e. use
 * spock_tuple_find_replidx). Or at least raise a WARNING that an
 * inconsistency may arise.
 */
Oid
spock_tuple_find_conflict(ResultRelInfo *relinfo, SpockTupleData *tuple,
							  TupleTableSlot *outslot)
{
	Oid				conflict_idx = InvalidOid;
	ScanKeyData		index_key[INDEX_MAX_KEYS];
	int				i;
	ItemPointerData	conflicting_tid;
	Oid				replidxoid;
	bool			found = false;

	ItemPointerSetInvalid(&conflicting_tid);

	/*
	 * Check the replica identity index with a SnapshotDirty scan first, like
	 * spock_tuple_find_replidx, but without ERRORing if we don't find
	 * a replica identity index.
	 */
	replidxoid = RelationGetReplicaIndex(relinfo->ri_RelationDesc);
	if (OidIsValid(replidxoid))
	{
		ScanKeyData	index_key[INDEX_MAX_KEYS];
		Relation	idxrel = index_open(replidxoid, RowExclusiveLock);
		build_index_scan_key(index_key, relinfo->ri_RelationDesc, idxrel, tuple);
		found = find_index_tuple(index_key, relinfo->ri_RelationDesc, idxrel,
							 LockTupleExclusive, outslot);
		index_close(idxrel, NoLock);
		if (found)
			return replidxoid;
	}

	/*
	 * Do a SnapshotDirty search for conflicting tuples. If any is found
	 * store it in outslot and return the oid of the matching index. We
	 * don't continue scanning for matches in other indexes, so we won't
	 * notice if the tuple conflicts with another index, and it'll
	 * raise a unique violation on apply instead.
	 *
	 * We could carry on here even if (found) and look for secondary conflicts,
	 * but all we'd be able to do would be ERROR here instead of later. The
	 * rest of the time we'd just pay a useless performance cost for extra
	 * index scans.
	 */
	for (i = 0; i < relinfo->ri_NumIndices; i++)
	{
		IndexInfo  *ii = relinfo->ri_IndexRelationInfo[i];
		Relation	idxrel;

		/*
		 * Only unique indexes are of interest here, and we can't deal with
		 * expression indexes so far.
		 */
		if (!ii->ii_Unique || ii->ii_Expressions != NIL)
			continue;

		/*
		 * TODO: predicates should be handled better. There's no point scanning
		 * an index where the predicates show it could never match anyway, and
		 * it can produce false conflicts if the predicate includes non-indexed
		 * columns. We could find a local tuple that matches the predicate in
		 * the index, but there's only a true conflict if the remote tuple also
		 * matches the predicate. If we ignore the predicate we generate a false
		 * conflict. See RM#1839.
		 *
		 * For now we reject conflict resolution on indexes with predicates
		 * entirely. If there's a conflict it'll be raised on apply with a
		 * unique violation.
		 */
		if (ii->ii_Predicate != NIL)
			continue;

		idxrel = relinfo->ri_IndexRelationDescs[i];

		/* No point re-scanning the replica identity index */
		if (RelationGetRelid(idxrel) == replidxoid)
			continue;

		if (build_index_scan_key(index_key, relinfo->ri_RelationDesc,
								 idxrel, tuple))
			continue;

		/* Try to find conflicting row and store in 'outslot' */
		found = find_index_tuple(index_key, relinfo->ri_RelationDesc,
								 idxrel, LockTupleExclusive, outslot);

		if (found)
		{
			ItemPointerCopy(&outslot->tts_tid, &conflicting_tid);
			conflict_idx = RelationGetRelid(idxrel);
			break;
		}

		CHECK_FOR_INTERRUPTS();
	}

	return conflict_idx;
}


/*
 * Resolve conflict based on commit timestamp.
 */
static bool
conflict_resolve_by_timestamp(RepOriginId local_origin_id,
							  RepOriginId remote_origin_id,
							  TimestampTz local_ts,
							  TimestampTz remote_ts,
							  bool last_update_wins,
							  SpockConflictResolution *resolution)
{
	int			cmp;

	cmp = timestamptz_cmp_internal(remote_ts, local_ts);

	/*
	 * The logic bellow assumes last update wins, we invert the logic by
	 * inverting result of timestamp comparison if first update wins was
	 * requested.
	 */
	if (!last_update_wins)
		cmp = -cmp;

	if (cmp > 0)
	{
		/* The remote row wins, update the local one. */
		*resolution = SpockResolution_ApplyRemote;
		return true;
	}
	else if (cmp < 0)
	{
		/* The local row wins, retain it */
		*resolution = SpockResolution_KeepLocal;
		return false;
	}
	else
	{
		/*
		 * The timestamps were equal, break the tie in a manner that is
		 * consistent across all nodes.
		 *
		 * XXX: TODO, for now we just always apply remote change.
		 */
		elog(LOG, "SPOCK: conflict_resolve_by_timestamp(): "
				  "timestamps identical!");

		*resolution = SpockResolution_ApplyRemote;
		return true;
	}
}

/*
 * Get the origin of the local tuple.
 *
 * If the track_commit_timestamp is off, we return remote origin info since
 * there is no way to get any meaningful info locally. This means that
 * the caller will assume that all the local tuples came from remote site when
 * track_commit_timestamp is off.
 *
 * This function is used by UPDATE conflict detection so the above means that
 * UPDATEs will not be recognized as conflict even if they change locally
 * modified row.
 *
 * Returns true if local origin data was found, false if not.
 */
bool
get_tuple_origin(Oid relid, HeapTuple local_tuple, ItemPointer tid,
				 TransactionId *xmin,
				 RepOriginId *local_origin, TimestampTz *local_ts)
{
	SpockCTHKey		cth_key;
	SpockCTHEntry  *cth_entry;
	bool			cth_found;
	int				cmp;

	*xmin = HeapTupleHeaderGetXmin(local_tuple->t_data);
	if (!track_commit_timestamp)
	{
		*local_origin = replorigin_session_origin;
		*local_ts = replorigin_session_origin_timestamp;
		return false;
	}

	if (TransactionIdIsValid(*xmin) && !TransactionIdIsNormal(*xmin))
	{
		/*
		 * Pg emits an ERROR if you try to pass FrozenTransactionId (2)
		 * or BootstrapTransactionId (1) to TransactionIdGetCommitTsData,
		 * per RT#46983 . This seems like an oversight in the core function,
		 * but we can work around it here by setting it to the same thing
		 * we'd get if the xid's commit timestamp was trimmed already.
		 */
		*local_origin = InvalidRepOriginId;
		*local_ts = 0;
		return false;
	}

	if (*xmin == GetTopTransactionId())
	{
		/*
		 * This is a tuple that our own transaction created. There cannot
		 * be any meaningful information in the conflict tracking hash.
		 */
		return TransactionIdGetCommitTsData(*xmin, local_ts, local_origin);
	}

	if (tid == NULL)
	{
		/*
		 * This is an INSERT, we can't find anything in the hash table.
		 */
		return TransactionIdGetCommitTsData(*xmin, local_ts, local_origin);
	}

	/* Everything below might change the hash table content. */
	LWLockAcquire(SpockCtx->cth_lock, LW_EXCLUSIVE);

	if (!TransactionIdGetCommitTsData(*xmin, local_ts, local_origin))
	{
		/*
		 * The commit timestamp info for this transaction was trimmed
		 * already. Nothing much we can do other than drop the hash
		 * table entry, if we have one.
		 */
		memset(&cth_key, 0, sizeof(cth_key));
		cth_key.datid = MyDatabaseId;
		cth_key.relid = relid;
		ItemPointerSet(&(cth_key.tid), BlockIdGetBlockNumber(&tid->ip_blkid),
					   tid->ip_posid);
		hash_search(SpockConflictHash, &cth_key, HASH_REMOVE, &cth_found);

		if (cth_found)
		{
			/* If found decrement the entry count */
			SpockCtx->cth_count--;

			/* TODO: Delete the entry from the backing table. */
		}

		LWLockRelease(SpockCtx->cth_lock);
		return false;
	}

	/*
	 * Try to lookup a tracking entry in hour conflict tracking hash table.
	 *
	 * If we don't find one then we return the original results from
	 * TransactionIdGetCommitTsData().
	 *
	 * If we find one and it wins the conflict criteria, we keep it and
	 * change the origin and timestamp information returned to that.
	 *
	 * If we find one and it loses the conflict criteria, we drop it.
	 */
	memset(&cth_key, 0, sizeof(cth_key));
	cth_key.datid = MyDatabaseId;
	cth_key.relid = relid;
	ItemPointerSet(&(cth_key.tid), BlockIdGetBlockNumber(&tid->ip_blkid),
				   tid->ip_posid);
	cth_entry = (SpockCTHEntry *)hash_search(SpockConflictHash,
											 &cth_key, HASH_FIND,
											 &cth_found);
	if (!cth_found)
	{
		LWLockRelease(SpockCtx->cth_lock);
		return true;
	}

	if (!TransactionIdEquals(cth_entry->last_xmin, *xmin))
	{
		/*
		 * The local tuple at this ItemPointer (ctid) isn't the one that
		 * we remembered this entry for. This can happen when a tuple we
		 * remembered was deleted, vacuumed and the ItemPointer then
		 * reused. We can identify that because the xmin in the local slot
		 * is now different from when we stored it.
		 */
		hash_search(SpockConflictHash, &cth_key, HASH_REMOVE, &cth_found);
		SpockCtx->cth_count--;

		/* TODO: delete the entry from the backing table */

		LWLockRelease(SpockCtx->cth_lock);
		return true;
	}

    cmp = timestamptz_cmp_internal(*local_ts, cth_entry->last_ts);
	if (spock_conflict_resolver == SPOCK_RESOLVE_FIRST_UPDATE_WINS)
		cmp = -cmp;

	if (cmp > 0)
	{
		hash_search(SpockConflictHash, &cth_key, HASH_REMOVE, &cth_found);
		SpockCtx->cth_count--;

		/* TODO: delete the entry from the backing table */
	}
	else
	{
		*local_origin = cth_entry->last_origin;
		*local_ts = cth_entry->last_ts;
		cth_entry->last_xmin = *xmin;
	}

	LWLockRelease(SpockCtx->cth_lock);

	return true;
}

/*
 * Try resolving the conflict resolution.
 *
 * Returns true when remote tuple should be applied.
 */
bool
try_resolve_conflict(Relation rel, HeapTuple localtuple, HeapTuple remotetuple,
					 HeapTuple *resulttuple,
					 RepOriginId local_origin, TimestampTz local_ts,
					 SpockConflictResolution *resolution)
{
	bool			apply = false;

	switch (spock_conflict_resolver)
	{
		case SPOCK_RESOLVE_ERROR:
			/* TODO: proper error message */
			elog(ERROR, "cannot apply conflicting row");
			break;
		case SPOCK_RESOLVE_APPLY_REMOTE:
			apply = true;
			*resolution = SpockResolution_ApplyRemote;
			break;
		case SPOCK_RESOLVE_KEEP_LOCAL:
			apply = false;
			*resolution = SpockResolution_KeepLocal;
			break;
		case SPOCK_RESOLVE_LAST_UPDATE_WINS:
			apply = conflict_resolve_by_timestamp(local_origin,
												  replorigin_session_origin,
												  local_ts,
												  replorigin_session_origin_timestamp,
												  true, resolution);
			break;
		case SPOCK_RESOLVE_FIRST_UPDATE_WINS:
			apply = conflict_resolve_by_timestamp(local_origin,
												  replorigin_session_origin,
												  local_ts,
												  replorigin_session_origin_timestamp,
												  false, resolution);
			break;
		default:
			elog(ERROR, "unrecognized spock_conflict_resolver setting %d",
				 spock_conflict_resolver);
	}

	if (apply)
		*resulttuple = remotetuple;
	else
		*resulttuple = localtuple;

	return apply;
}

static char *
conflict_type_to_string(SpockConflictType conflict_type)
{
	switch (conflict_type)
	{
		case CONFLICT_INSERT_INSERT:
			return "insert_insert";
		case CONFLICT_UPDATE_UPDATE:
			return "update_update";
		case CONFLICT_UPDATE_DELETE:
			return "update_delete";
		case CONFLICT_DELETE_DELETE:
			return "delete_delete";
	}

	/* Unreachable */
	return NULL;
}

static char *
conflict_resolution_to_string(SpockConflictResolution resolution)
{
	switch (resolution)
	{
		case SpockResolution_ApplyRemote:
			return "apply_remote";
		case SpockResolution_KeepLocal:
			return "keep_local";
		case SpockResolution_Skip:
			return "skip";
	}

	/* Unreachable */
	return NULL;
}

/*
 * Log the conflict to server log.
 *
 * There are number of tuples passed:
 *
 * - The local tuple we conflict with or NULL if not found [localtuple];
 *
 * - If the remote tuple was an update, the key of the old tuple
 *   as a SpockTuple [oldkey]
 *
 * - The remote tuple, after we fill any defaults and apply any local
 *   BEFORE triggers but before conflict resolution [remotetuple];
 *
 * - The tuple we'll actually apply if any, after conflict resolution
 *   [applytuple]
 *
 * The SpockRelation's name info is for the remote rel. If we add relation
 * mapping we'll need to get the name/namespace of the local relation too.
 *
 * This runs in MessageContext so we don't have to worry about leaks, but
 * we still try to free the big chunks as we go.
 */
void
spock_report_conflict(SpockConflictType conflict_type,
						  SpockRelation *rel,
						  HeapTuple localtuple,
						  SpockTupleData *oldkey,
						  HeapTuple remotetuple,
						  HeapTuple applytuple,
						  SpockConflictResolution resolution,
						  TransactionId local_tuple_xid,
						  bool found_local_origin,
						  RepOriginId local_tuple_origin,
						  TimestampTz local_tuple_commit_ts,
						  Oid conflict_idx_oid,
						  bool has_before_triggers)
{
	char local_tup_ts_str[MAXDATELEN] = "(unset)";
	StringInfoData localtup, remotetup;
	TupleDesc desc = RelationGetDescr(rel->rel);
	const char *idxname = "(unknown)";
	const char *qualrelname;

	/*
	 * Filter out the conflicts that were resolved by applying the remote
	 * tuple.
	 */
	if (resolution == SpockResolution_ApplyRemote)
		return;

	spock_conflict_log_table(conflict_type, rel, localtuple, oldkey,
							 remotetuple, applytuple, resolution,
							 local_tuple_xid, found_local_origin,
							 local_tuple_origin, local_tuple_commit_ts,
							 conflict_idx_oid, has_before_triggers);

	memset(local_tup_ts_str, 0, MAXDATELEN);
	if (found_local_origin)
		strcpy(local_tup_ts_str,
			timestamptz_to_str(local_tuple_commit_ts));

	initStringInfo(&remotetup);
	tuple_to_stringinfo(&remotetup, desc, remotetuple);

	if (localtuple != NULL)
	{
		initStringInfo(&localtup);
		tuple_to_stringinfo(&localtup, desc, localtuple);
	}

	if (OidIsValid(conflict_idx_oid))
		idxname = get_rel_name(conflict_idx_oid);

	qualrelname = quote_qualified_identifier(
		get_namespace_name(RelationGetNamespace(rel->rel)),
		RelationGetRelationName(rel->rel));

	/*
	 * We try to provide a lot of information about conflicting tuples because
	 * the conflicts are often transient and timing-sensitive. It's rare that
	 * we can examine a stopped system or reproduce them at leisure. So the
	 * more info we have in the logs, the better chance we have of diagnosing
	 * application issues. It's worth paying the price of some log spam.
	 *
	 * This deliberately somewhat overlaps with the context info we log with
	 * log_error_verbosity=verbose because we don't necessarily have all that
	 * info enabled.
	 */
	switch (conflict_type)
	{
		case CONFLICT_INSERT_INSERT:
		case CONFLICT_UPDATE_UPDATE:
			ereport(spock_conflict_log_level,
					(errcode(ERRCODE_INTEGRITY_CONSTRAINT_VIOLATION),
					 errmsg("CONFLICT: remote %s on relation %s (local index %s). Resolution: %s.",
							conflict_type == CONFLICT_INSERT_INSERT ? "INSERT" : "UPDATE",
							qualrelname, idxname,
							conflict_resolution_to_string(resolution)),
					 errdetail("existing local tuple {%s} xid=%u,origin=%d,timestamp=%s; remote tuple {%s}%s in xact origin=%u,timestamp=%s,commit_lsn=%X/%X",
							   localtup.data, local_tuple_xid,
							   found_local_origin ? (int)local_tuple_origin : -1,
							   local_tup_ts_str,
							   remotetup.data, has_before_triggers ? "*":"",
							   replorigin_session_origin,
							   timestamptz_to_str(replorigin_session_origin_timestamp),
							   (uint32)(replorigin_session_origin_lsn<<32),
							   (uint32)replorigin_session_origin_lsn)));
			break;
		case CONFLICT_UPDATE_DELETE:
		case CONFLICT_DELETE_DELETE:
			ereport(spock_conflict_log_level,
					(errcode(ERRCODE_INTEGRITY_CONSTRAINT_VIOLATION),
					 errmsg("CONFLICT: remote %s on relation %s replica identity index %s (tuple not found). Resolution: %s.",
							conflict_type == CONFLICT_UPDATE_DELETE ? "UPDATE" : "DELETE",
							qualrelname, idxname,
							conflict_resolution_to_string(resolution)),
					 errdetail("remote tuple {%s}%s in xact origin=%u,timestamp=%s,commit_lsn=%X/%X",
							   remotetup.data, has_before_triggers ? "*":"",
							   replorigin_session_origin,
							   timestamptz_to_str(replorigin_session_origin_timestamp),
							   (uint32)(replorigin_session_origin_lsn<<32),
							   (uint32)replorigin_session_origin_lsn)));
			break;
	}
}

/*
 * Log the conflict to spock.resolutions table
 *
 * There are number of tuples passed:
 *
 * - The local tuple we conflict with or NULL if not found [localtuple];
 *
 * - If the remote tuple was an update, the key of the old tuple
 *   as a SpockTuple [oldkey]
 *
 * - The remote tuple, after we fill any defaults and apply any local
 *   BEFORE triggers but before conflict resolution [remotetuple];
 *
 * - The tuple we'll actually apply if any, after conflict resolution
 *   [applytuple]
 *
 * The SpockRelation's name info is for the remote rel. If we add relation
 * mapping we'll need to get the name/namespace of the local relation too.
 *
 * This runs in MessageContext so we don't have to worry about leaks, but
 * we still try to free the big chunks as we go.
 */
void
spock_conflict_log_table(SpockConflictType conflict_type,
						  SpockRelation *rel,
						  HeapTuple localtuple,
						  SpockTupleData *oldkey,
						  HeapTuple remotetuple,
						  HeapTuple applytuple,
						  SpockConflictResolution resolution,
						  TransactionId local_tuple_xid,
						  bool found_local_origin,
						  RepOriginId local_tuple_origin,
						  TimestampTz local_tuple_commit_ts,
						  Oid conflict_idx_oid,
						  bool has_before_triggers)
{
	HeapTuple	tup;
	Datum	values[SPOCK_LOG_TABLE_COLS];
	bool	nulls[SPOCK_LOG_TABLE_COLS];
	TupleDesc desc = RelationGetDescr(rel->rel);
	Relation	logrel;
	const char *qualrelname;
	SpockLocalNode *localnode;
	SpockNode	*node;
	NameData	node_name;

	/* See the GUC settings for spock.spock_save_resolutions is enabled. */
	if (!spock_save_resolutions)
		return;

	memset(values, 0, sizeof(values));
	memset(nulls, 0, sizeof(nulls));

	localnode = get_local_node(false, false);
	node = localnode->node;

	/* id */
	values[0] = DirectFunctionCall1(nextval_oid, get_conflict_log_seq());

	/* node_name */
	namestrcpy(&node_name, node->name);
	values[1] = NameGetDatum(&node_name);

	/* log_time */
	values[2] = TimestampTzGetDatum(GetCurrentIntegerTimestamp());

	/* relname */
	qualrelname = quote_qualified_identifier(
		get_namespace_name(RelationGetNamespace(rel->rel)),
		RelationGetRelationName(rel->rel));
	values[3] = CStringGetTextDatum(qualrelname);

	/* index name */
	if (OidIsValid(conflict_idx_oid))
	{
		char *idxname;

		idxname = get_rel_name(conflict_idx_oid);
		values[4] = CStringGetTextDatum(idxname);
	}
	else
		nulls[4] = true;

	/* conflict type */
	values[5] = CStringGetTextDatum(conflict_type_to_string(conflict_type));
	/* conflict_resolution */
	values[6] = CStringGetTextDatum(conflict_resolution_to_string(resolution));
	/* local_origin */
	values[7] = Int32GetDatum(found_local_origin? (int)local_tuple_origin : -1);

	/* local_tuple */
	if (localtuple != NULL)
	{
		Datum datum;

		datum = heap_copy_tuple_as_datum(localtuple, desc);
		values[8] = spock_conflict_row_to_json(datum, false, &nulls[7]);
	}
	else
		nulls[8] = true;

	/* local_xid */
	if (local_tuple_xid != InvalidTransactionId)
		values[9] = TransactionIdGetDatum(local_tuple_xid);
	else
		nulls[9] = true;

	/* local_timestamp */
	values[10] = TimestampTzGetDatum(local_tuple_commit_ts);
	/* remote_origin */
	values[11] = Int32GetDatum((int)replorigin_session_origin);

	/* remote_tuple */
	if (remotetuple != NULL)
	{
		Datum datum;

		datum = heap_copy_tuple_as_datum(remotetuple, desc);
		values[12] = spock_conflict_row_to_json(datum, false, &nulls[11]);
	}
	else
		nulls[12] = true;

	/* remote_xid */
	if (remote_xid != InvalidTransactionId)
		values[13] = TransactionIdGetDatum(remote_xid);
	else
		nulls[13] = true;

	/* remote_timestamp */
	values[14] = TimestampTzGetDatum(replorigin_session_origin_timestamp);
	/* remote lsn */
	if (replorigin_session_origin_lsn != InvalidXLogRecPtr)
		values[15] = LSNGetDatum(replorigin_session_origin_lsn);
	else
		nulls[15] = true;

	logrel = table_open(get_conflict_log_table_oid(), RowExclusiveLock);
	tup = heap_form_tuple(logrel->rd_att, values, nulls);
	CatalogTupleInsert(logrel, tup);
	heap_freetuple(tup);
	table_close(logrel, RowExclusiveLock);
}

/*
 * Get (cached) oid of the conflict log table.
 */
Oid
get_conflict_log_table_oid(void)
{
	static Oid	logtableoid = InvalidOid;

	if (logtableoid == InvalidOid)
		logtableoid = get_spock_table_oid(CATALOG_LOGTABLE);

	return logtableoid;
}

/*
 * Get (cached) oid of the conflict log sequence, which is created
 * implicitly.
 */
Oid
get_conflict_log_seq(void)
{
	static Oid seqoid = InvalidOid;

	if (seqoid == InvalidOid)
	{
		Oid	reloid;

		reloid = get_conflict_log_table_oid();
		seqoid = getIdentitySequence(reloid, 0, false);
	}

	return seqoid;
}

/* Checks validity of spock_conflict_resolver GUC */
bool
spock_conflict_resolver_check_hook(int *newval, void **extra,
									   GucSource source)
{
	/*
	 * Only allow SPOCK_RESOLVE_APPLY_REMOTE when track_commit_timestamp
	 * is off, because there is no way to know where the local tuple
	 * originated from.
	 */
	if (!track_commit_timestamp &&
		*newval != SPOCK_RESOLVE_APPLY_REMOTE &&
		*newval != SPOCK_RESOLVE_ERROR)
	{
		GUC_check_errdetail("track_commit_timestamp is off");
		return false;
	}

	return true;
}


/*
 * Conflict Tracking Hash support functions
 */
void
spock_cth_store(Oid relid, ItemPointer tid, RepOriginId last_origin,
				TransactionId last_xmin, TimestampTz last_ts)
{
	SpockCTHKey			cth_key;
	SpockCTHEntry	   *cth_entry;
	bool				cth_found;

	if (!track_commit_timestamp)
		return;

	/* We intend to modify the hash table, lock exclusive */
	LWLockAcquire(SpockCtx->cth_lock, LW_EXCLUSIVE);

	if (SpockCtx->cth_count >= spock_conflict_max_tracking)
	{
		/*
		 * TODO: This means we ran out of memory in the conflict tracking
		 * hash table. We need to attempt a purge of old entries.
		 *
		 * Not sure what we are going to do if we cannot purge at least
		 * one old entry. Do we error out and stall replication or do we
		 * just log the problem and risk data drift between the nodes?
		 *
		 * We can run over this for a while "borrowing" shared memory
		 * from other backend parts as long as they don't need it. But
		 * that sounds like a huge kluge.
		 */

		LWLockRelease(SpockCtx->cth_lock);
		elog(LOG, "spock_cth_store: out of entries");
		return;
	}

	/* Search for the hash entry or create a new one */
	memset(&cth_key, 0, sizeof(cth_key));
	cth_key.datid = MyDatabaseId;
	cth_key.relid = relid;
	ItemPointerSet(&(cth_key.tid), BlockIdGetBlockNumber(&tid->ip_blkid),
				   tid->ip_posid);
	cth_entry = (SpockCTHEntry *)hash_search(SpockConflictHash,
											 &cth_key, HASH_ENTER, &cth_found);
	if (cth_entry == NULL)
	{
		LWLockRelease(SpockCtx->cth_lock);
		elog(ERROR, "spock_cth_store: out of shared memory");
	}

	if (!cth_found)
		SpockCtx->cth_count++;

	cth_entry->last_origin = last_origin;
	cth_entry->last_xmin = last_xmin;
	cth_entry->last_ts = last_ts;

	/*
	 * TODO: Store this entry in the permanent backing table
	 */

	LWLockRelease(SpockCtx->cth_lock);
}

uint32
spock_cth_hash_fn(const void *key, Size keylen)
{
	return hash_bytes(key, keylen);
}

int
spock_cth_match_fn(const void *key1, const void *key2, Size keylen)
{
	if (memcmp(key1, key2, keylen) == 0)
		return 0;

	return 1;
}


/*
 * print the tuple 'tuple' into the StringInfo s
 *
 * (Based on bdr2)
 */
static void
tuple_to_stringinfo(StringInfo s, TupleDesc tupdesc, HeapTuple tuple)
{
	int			natt;
	bool		first = true;

	static const int MAX_CONFLICT_LOG_ATTR_LEN = 40;

	/* print all columns individually */
	for (natt = 0; natt < tupdesc->natts; natt++)
	{
		Form_pg_attribute attr; /* the attribute itself */
		Oid			typid;		/* type of current attribute */
		HeapTuple	type_tuple; /* information about a type */
		Form_pg_type type_form;
		Oid			typoutput;	/* output function */
		bool		typisvarlena;
		Datum		origval;	/* possibly toasted Datum */
		Datum		val	= PointerGetDatum(NULL); /* definitely detoasted Datum */
		char	   *outputstr = NULL;
		bool		isnull;		/* column is null? */

		attr = TupleDescAttr(tupdesc, natt);

		/*
		 * don't print dropped columns, we can't be sure everything is
		 * available for them
		 */
		if (attr->attisdropped)
			continue;

		/*
		 * Don't print system columns
		 */
		if (attr->attnum < 0)
			continue;

		typid = attr->atttypid;

		/* gather type name */
		type_tuple = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typid));
		if (!HeapTupleIsValid(type_tuple))
			elog(ERROR, "cache lookup failed for type %u", typid);
		type_form = (Form_pg_type) GETSTRUCT(type_tuple);

		/* print attribute name */
		if (first)
			first = false;
		else
			appendStringInfoChar(s, ' ');
		appendStringInfoString(s, NameStr(attr->attname));

		/* print attribute type */
		appendStringInfoChar(s, '[');
		appendStringInfoString(s, NameStr(type_form->typname));
		appendStringInfoChar(s, ']');

		/* query output function */
		getTypeOutputInfo(typid,
						  &typoutput, &typisvarlena);

		ReleaseSysCache(type_tuple);

		/* get Datum from tuple */
		origval = heap_getattr(tuple, natt + 1, tupdesc, &isnull);

		if (isnull)
			outputstr = "(null)";
		else if (typisvarlena && VARATT_IS_EXTERNAL_ONDISK(origval))
			outputstr = "(unchanged-toast-datum)";
		else if (typisvarlena)
			val = PointerGetDatum(PG_DETOAST_DATUM(origval));
		else
			val = origval;

		/* print data */
		if (outputstr == NULL)
			outputstr = OidOutputFunctionCall(typoutput, val);

		/*
		 * Abbreviate the Datum if it's too long. This may make it syntatically
		 * invalid, but it's not like we're writing out a valid ROW(...) as it
		 * is.
		 */
		if (strlen(outputstr) > MAX_CONFLICT_LOG_ATTR_LEN)
		{
			/* The null written at the end of strcpy will truncate the string */
			strcpy(&outputstr[MAX_CONFLICT_LOG_ATTR_LEN-5], "...");
		}

		appendStringInfoChar(s, ':');
		appendStringInfoString(s, outputstr);
	}
}

/*
 * Convert the target row to json form if it isn't null.
 */
static Datum
spock_conflict_row_to_json(Datum row, bool row_isnull, bool *ret_isnull)
{
	Datum row_json;
	if (row_isnull)
	{
		row_json = (Datum) 0;
		*ret_isnull = 1;
	}
	else
	{
		/*
		 * We don't handle errors with a PG_TRY / PG_CATCH here, because that's
		 * not sufficient to make the transaction usable given that we might
		 * fail in user defined casts, etc. We'd need a full savepoint, which
		 * is too expensive. So if this fails we'll just propagate the exception
		 * and abort the apply transaction.
		 *
		 * It shouldn't fail unless something's pretty broken anyway.
		 */
		row_json = DirectFunctionCall1(row_to_json, row);
		*ret_isnull = 0;
	}
	return row_json;
}
