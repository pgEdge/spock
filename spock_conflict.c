/*-------------------------------------------------------------------------
 *
 * spock_conflict.c
 * 		Functions for detecting and handling conflicts
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
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
#include "nodes/makefuncs.h"

#include "executor/executor.h"
#include "executor/spi.h"

#include "parser/parse_relation.h"

#include "replication/origin.h"
#include "replication/reorderbuffer.h"

#include "storage/bufmgr.h"
#include "storage/lmgr.h"

#include "utils/builtins.h"
#include "utils/datetime.h"
#include "utils/fmgroids.h"
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
bool	spock_save_resolutions = false;

static	Relation	spock_ctt_rel = NULL;
static	Oid			spock_ctt_relind = InvalidOid;

static void tuple_to_stringinfo(StringInfo s, TupleDesc tupdesc,
	HeapTuple tuple);
static Datum spock_conflict_row_to_json(Datum row, bool row_isnull,
	bool *ret_isnull);

/*
 * Support functions for conflict tracking permanent table
 */
static void spock_ctt_remove(Oid relid, ItemPointer tid);
static bool spock_ctt_fetch(Oid relid, ItemPointer tid,
							RepOriginId *last_origin, TransactionId *last_xmin,
							TimestampTz *last_ts);

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
				 * XXX: Improve how?
				 */
				ereport(DEBUG1,
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

		/*
		 * If this index may not be complete enough to exhibit
		 * uniqueness and drive correct query results, move on to other
		 * indexes.  If no index meets all qualifications and this one
		 * is ii_ReadyForInserts, one could argue for using this one
		 * instead of using no index.  We don't offer that.  (The
		 * server's infer_arbiter_indexes(), which performs a similar
		 * role, also requires indisvalid.)
		 */
		if (!idxrel->rd_index->indisvalid)
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
	RepOriginId		last_origin;
	TransactionId	last_xmin;
	TimestampTz		last_ts;
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

	if (tid == NULL)
	{
		/*
		 * This is an INSERT, we can't find anything in the hash table.
		 */
		return TransactionIdGetCommitTsData(*xmin, local_ts, local_origin);
	}

	if (!TransactionIdEquals(*xmin, GetTopTransactionId()) &&
		!TransactionIdGetCommitTsData(*xmin, local_ts, local_origin))
	{
		/*
		 * The commit timestamp info for this transaction was trimmed
		 * already. Nothing much we can do other than drop the tracking
		 * entry, if we have one.
		 */
		spock_ctt_remove(relid, tid);
		return false;
	}

	/*
	 * Try to lookup a tracking entry in hour conflict tracking data.
	 *
	 * If we don't find one then we return the original results from
	 * TransactionIdGetCommitTsData().
	 *
	 * If we find one and it wins the conflict criteria, we keep it and
	 * change the origin and timestamp information returned to that.
	 *
	 * If we find one and it loses the conflict criteria, we drop it.
	 */

	if (!spock_ctt_fetch(relid, tid, &last_origin, &last_xmin, &last_ts))
		return true;

	if (!TransactionIdEquals(last_xmin, *xmin))
	{
		/*
		 * The local tuple at this ItemPointer (ctid) isn't the one that
		 * we remembered this entry for. This can happen when a tuple we
		 * remembered was deleted, vacuumed and the ItemPointer then
		 * reused. We can identify that because the xmin in the local slot
		 * is now different from when we stored it.
		 */
		spock_ctt_remove(relid, tid);
		return true;
	}

    cmp = timestamptz_cmp_internal(*local_ts, last_ts);
	if (spock_conflict_resolver == SPOCK_RESOLVE_FIRST_UPDATE_WINS)
		cmp = -cmp;

	if (cmp > 0)
	{
		spock_ctt_remove(relid, tid);
	}
	else
	{
		*local_origin = last_origin;
		*local_ts = last_ts;

		spock_ctt_store(relid, tid, last_origin, *xmin, last_ts);
	}

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

	/* Count statistics */
	handle_stats_counter(rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_CONFLICT_COUNT, 1);

	/* If configured log resolution to table */
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
#if PG_VERSION_NUM >= 170000
		seqoid = getIdentitySequence(RelationIdGetRelation(reloid), InvalidAttrNumber, false);
#else
		seqoid = getIdentitySequence(reloid, InvalidAttrNumber, false);
#endif
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
 * Private structures for spock_ctt_prune()
 */
typedef struct CTTPruneSub
{
	Oid				sub_id;
	char		   *sub_name;
	RepOriginId		replorigin;
} CTTPruneSub;

typedef struct CTTPruneOrig
{
	RepOriginId		replorigin;
	TimestampTz		last_ts;
} CTTPruneOrig;

int32
spock_ctt_prune(void)
{
	int32			num_pruned = 0;
	TupleDesc		tupdesc;
	List		   *subscriptions = NIL;
	ListCell	   *slc;
	CTTPruneSub	   *sub;
	List		   *origins = NIL;
	ListCell	   *olc;
	CTTPruneOrig   *origin;
	List		   *workers = NIL;
	ListCell	   *wlc;
	SpockWorker	   *worker;
	TimestampTz		min_last_ts = 0;
	TimestampTz		cmp_last_ts = 0;
	Datum			intvl10;
	Oid				argtypes[1];
	Datum			args[1];
	int				rc;
	uint64			i;
	bool			all_ok = true;

	/*
	 * We need to find the min(max(last commit ts of every remote)).
	 * This is the safe timestamp from before which we don't need
	 * to keep any tracking entries. The idea is that transactions
	 * are received in commit order per replorigin. If an entry has a
	 * last_ts before the last_ts of a node, then we can never
	 * again receive any replication action that is before that and
	 * the last update wins will always apply. If this is true for
	 * all remotes, we no longer need the entry.
	 */


	/* Get a list of all spock.subscriptions */
	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPOCK: SPI_connect() failed");
	rc = SPI_execute("SELECT sub_id, sub_name "
					 "FROM spock.subscription", true, 0);
	if (rc != SPI_OK_SELECT)
		elog(ERROR, "SPOCK: SPI_execute() failed");
	if (SPI_tuptable == NULL)
	{
		SPI_finish();
		return 0;
	}
	tupdesc = SPI_tuptable->tupdesc;
	for (i = 0; i < SPI_tuptable->numvals; i++)
	{
		HeapTuple	tup = SPI_tuptable->vals[i];
		bool		isnull;

		sub = palloc(sizeof(CTTPruneSub));
		sub->sub_id = DatumGetObjectId(SPI_getbinval(tup, tupdesc, 1,
													 &isnull));
		sub->sub_name = SPI_getvalue(tup, tupdesc, 2);
		sub->replorigin = InvalidRepOriginId;
		subscriptions = lappend(subscriptions, sub);
	}

	/*
	 * Now find all the workers and fill in the replorigin. While at
	 * it build the list of unique replorigins with their max(last_ts).
	 */
	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
	workers = spock_apply_find_all(MyDatabaseId);
	foreach (slc, subscriptions)
	{
		sub = (CTTPruneSub *)lfirst(slc);

		foreach (wlc, workers)
		{
			bool	found = false;

			worker = (SpockWorker *)lfirst(wlc);

			if (worker->worker.apply.subid == sub->sub_id)
			{
				sub->replorigin = worker->worker.apply.replorigin;
			}

			foreach (olc, origins)
			{
				origin = (CTTPruneOrig *)lfirst(olc);

				if (origin->replorigin == worker->worker.apply.replorigin)
				{
					if (timestamptz_cmp_internal(origin->last_ts,
												 worker->worker.apply.last_ts) > 0)
					{
						origin->last_ts = worker->worker.apply.last_ts;
					}
					found = true;
					break;
				}
			}
			if (!found)
			{
				origin = (CTTPruneOrig *)palloc(sizeof(CTTPruneOrig));
				origin->replorigin = worker->worker.apply.replorigin;
				origin->last_ts = worker->worker.apply.last_ts;
				origins = lappend(origins, origin);
			}
		}
	}
	LWLockRelease(SpockCtx->lock);

	/*
	 * Make sure we found a replorigin and last_ts for every
	 * subscription. We cannot proceed without that because
	 * we don't know how we lost connection to that node and
	 * there could be outstanding transactions there with
	 * conflicts that need the current entries to resolve.
	 */
	foreach (slc, subscriptions)
	{
		sub = (CTTPruneSub *)lfirst(slc);


		if (sub->replorigin == InvalidRepOriginId)
		{
			elog(LOG, "SPOCK: sub_id=%u sub_name=%s "
				 "replorigin=InvalidRepOriginId",
				 sub->sub_id, sub->sub_name);
			all_ok = false;
		}
	}
	if (!all_ok)
	{
		elog(LOG, "SPOCK: cannot prune conflict tracking, one or more "
			 "subscriptions have unknown last commit timestamp.");
		SPI_finish();
		return 0;
	}

	/*
	 * Now find the min of the last commit timestamps of all replorigins.
	 */
	foreach(olc, origins)
	{
		origin = (CTTPruneOrig *)lfirst(olc);

		if (min_last_ts == 0)
			min_last_ts = origin->last_ts;
		else
			if (timestamptz_cmp_internal(origin->last_ts, min_last_ts) < 0)
				min_last_ts = origin->last_ts;
	}

	/*
	 * We apply a 10s safety distance because there is a small chance
	 * that a node's commit timestamp actually does run backwards.
	 * This is because the commit timestamp is placed into the commit
	 * WAL record before it is added to the WAL. So there is a race
	 * condition where one backend gets a timestamp after another but
	 * writes the WAL record first.
	 */
	intvl10 = DirectFunctionCall3(interval_in, PointerGetDatum("10s"),
								  ObjectIdGetDatum(InvalidOid),
								  Int32GetDatum(-1));
	cmp_last_ts = DatumGetTimestampTz(DirectFunctionCall2(timestamptz_mi_interval,
														  TimestampTzGetDatum(min_last_ts),
														  intvl10));

	argtypes[0] = TIMESTAMPTZOID;
	args[0] = TimestampTzGetDatum(cmp_last_ts);
	rc = SPI_execute_with_args("DELETE FROM " EXTENSION_NAME "."
							   SPOCK_CTT_NAME " WHERE last_ts < $1",
							   1, argtypes, args, NULL, false, 0);
	if (rc != SPI_OK_DELETE)
		elog(ERROR, "SPOCK: SPI_execute() failed");
	num_pruned = SPI_processed;

	SPI_finish();

	return num_pruned;
}

void
spock_ctt_store(Oid relid, ItemPointer tid,
				RepOriginId last_origin, TransactionId last_xmin,
				TimestampTz last_ts)
{
	Relation	rel;
	HeapTuple	tup = NULL;
	TupleDesc	tupdesc;
	Datum		values[5];
	bool		nulls[5];
	bool		replaces[5];

	/* Delete any eventually existing old tuple. */
	spock_ctt_remove(relid, tid);

	rel = spock_ctt_rel;
	tupdesc = RelationGetDescr(rel);

	MemSet(values, 0, sizeof(values));
	MemSet(nulls, 0, sizeof(nulls));
	MemSet(replaces, 0, sizeof(replaces));

	/* key */
	values[0] = ObjectIdGetDatum(relid);
	values[1] = PointerGetDatum(tid);

	values[2] = Int16GetDatum(last_origin);
	replaces[2] = true;

	values[3] = TransactionIdGetDatum(last_xmin);
	replaces[3] = true;

	values[4] = TimestampTzGetDatum(last_ts);
	replaces[3] = true;

	/* Inser new tuple in catalog. */
	tup = heap_form_tuple(tupdesc, values, nulls);
	CatalogTupleInsert(rel, tup);
	heap_freetuple(tup);
}

static void
spock_ctt_remove(Oid relid, ItemPointer tid)
{
	Relation	rel;
	HeapTuple	tup;
	ScanKeyData key[2];
	SysScanDesc scan;

	ScanKeyInit(&key[0],
				1,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(relid));
	ScanKeyInit(&key[1],
				2,
				BTEqualStrategyNumber, F_TIDEQ,
				PointerGetDatum(tid));

	if (spock_ctt_rel == NULL)
	{
		RangeVar   *rv;
		List	   *indexes;

		rv = makeRangeVar(EXTENSION_NAME, SPOCK_CTT_NAME, -1);
		spock_ctt_rel = table_openrv(rv, RowExclusiveLock);
		indexes = RelationGetIndexList(spock_ctt_rel);
		Assert(list_length(indexes) == 1);
		spock_ctt_relind = linitial_oid(indexes);
		list_free(indexes);
	}
	rel = spock_ctt_rel;

	scan = systable_beginscan(rel, spock_ctt_relind, true, NULL, 2, key);
	while ((tup = systable_getnext(scan)) != NULL)
	{
		/* Remove the tuple in catalog. */
		CatalogTupleDelete(rel, &tup->t_self);

		break;				/* there can be only one match */
	}

	/* Cleanup */
	systable_endscan(scan);
}

static bool
spock_ctt_fetch(Oid relid, ItemPointer tid,
				RepOriginId *last_origin, TransactionId *last_xmin,
				TimestampTz *last_ts)
{
	Relation	rel;
	HeapTuple	tup;
	ScanKeyData key[2];
	SysScanDesc scan;
	TupleDesc	tupdesc;
	bool		ctt_found = false;

	ScanKeyInit(&key[0],
				1,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(relid));
	ScanKeyInit(&key[1],
				2,
				BTEqualStrategyNumber, F_TIDEQ,
				PointerGetDatum(tid));

	if (spock_ctt_rel == NULL)
	{
		RangeVar   *rv;
		List	   *indexes;

		rv = makeRangeVar(EXTENSION_NAME, SPOCK_CTT_NAME, -1);
		spock_ctt_rel = table_openrv(rv, RowExclusiveLock);
		indexes = RelationGetIndexList(spock_ctt_rel);
		Assert(list_length(indexes) == 1);
		spock_ctt_relind = linitial_oid(indexes);
		list_free(indexes);
	}
	rel = spock_ctt_rel;
	tupdesc = RelationGetDescr(rel);

	scan = systable_beginscan(rel, spock_ctt_relind, true, NULL, 2, key);
	tup = systable_getnext(scan);
	if (tup)
	{
		bool	isnull;

		ctt_found = true;

		*last_origin = DatumGetInt16(heap_getattr(tup, 3, tupdesc, &isnull));
		*last_xmin = DatumGetTransactionId(heap_getattr(tup, 4,
														tupdesc, &isnull));
		*last_ts = DatumGetTimestampTz(heap_getattr(tup, 5, tupdesc, &isnull));
	}
	systable_endscan(scan);

	return ctt_found;
}

void
spock_ctt_close(void)
{
	if (spock_ctt_rel != NULL)
	{
		table_close(spock_ctt_rel, NoLock);
		spock_ctt_rel = NULL;
		spock_ctt_relind = InvalidOid;
	}
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
