/*-------------------------------------------------------------------------
 *
 * spock_conflict.c
 * 		Functions for detecting and handling conflicts
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
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


/* From src/backend/replication/logical/conflict.c */
static const char *const ConflictTypeNames[] = {
	[CT_INSERT_EXISTS] = "insert_exists",
	[CT_UPDATE_ORIGIN_DIFFERS] = "update_origin_differs",
	[CT_UPDATE_EXISTS] = "update_exists",
	[CT_UPDATE_MISSING] = "update_missing",
	[CT_DELETE_ORIGIN_DIFFERS] = "delete_origin_differs",
	[CT_DELETE_MISSING] = "delete_missing"
};


int			spock_conflict_resolver = SPOCK_RESOLVE_LAST_UPDATE_WINS;
int			spock_conflict_log_level = LOG;
bool		spock_save_resolutions = false;

static Datum spock_conflict_row_to_json(Datum row, bool row_isnull,
										bool *ret_isnull);

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
	 * The logic below assumes last update wins, we invert the logic by
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
		 * The timestamps were equal. Use the "tiebreaker" from the spock.node
		 * configuration to come up with a winner.
		 */
		SpockNode  *loc_node;
		SpockNode  *rmt_node;

		/* If the current local tuple is really local, use our own node.id */
		if (local_origin_id == InvalidRepOriginId)
		{
			SpockLocalNode *local_node = get_local_node(false, false);

			local_origin_id = local_node->node->id;
		}

		/* Get the two nodes for their "tiebreaker" */
		loc_node = get_node(local_origin_id);
		rmt_node = get_node(remote_origin_id);

		if (loc_node->tiebreaker == rmt_node->tiebreaker)
		{
			/*
			 * Major pilot error here. Our default for the tiebreaker is the
			 * unique 16-bit node.id but the user somehow managed to get
			 * identical values into the "info" jsonb "tiebreaker" element.
			 */
			elog(WARNING, "CONFLICT: current node=%d and remote node=%d "
				 "tiebreaker values are equal!",
				 loc_node->id, rmt_node->id);
			*resolution = SpockResolution_ApplyRemote;
			return true;
		}

		if (loc_node->tiebreaker < rmt_node->tiebreaker)
		{
			/* TODO: Need diagnostic logging for ACE here */
			elog(LOG, "CONFLICT: current node=%d wins over %d by tiebreaker", loc_node->id, rmt_node->id);
			*resolution = SpockResolution_KeepLocal;
			return false;
		}
		else
		{
			/* TODO: Need diagnostic logging for ACE here */
			elog(LOG, "CONFLICT: remote  node=%d wins over %d by tiebreaker", rmt_node->id, loc_node->id);
			*resolution = SpockResolution_ApplyRemote;
			return true;
		}
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
get_tuple_origin(SpockRelation *rel, HeapTuple local_tuple, ItemPointer tid,
				 TransactionId *xmin,
				 RepOriginId *local_origin, TimestampTz *local_ts)
{
	/* Initialize local origin and timestamp */
	*local_origin = InvalidRepOriginId;
	*local_ts = 0;

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
		 * Pg emits an ERROR if you try to pass FrozenTransactionId (2) or
		 * BootstrapTransactionId (1) to TransactionIdGetCommitTsData, per
		 * RT#46983 . This seems like an oversight in the core function, but
		 * we can work around it here by setting it to the same thing we'd get
		 * if the xid's commit timestamp was trimmed already.
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

	if (TransactionIdEquals(*xmin, GetTopTransactionId()))
	{
		/*
		 * The tuple was created by current xact, no commit timestamp yet.
		 */
		*local_origin = replorigin_session_origin;
		*local_ts = replorigin_session_origin_timestamp;
		return true;
	}

	/* Try to get real commit timestamp */
	if (TransactionIdGetCommitTsData(*xmin, local_ts, local_origin))
		return true;

	return false;
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
	bool		apply = false;

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
 * If configured to do so, also log to the spock.resolutions table
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
spock_report_conflict(ConflictType conflict_type,
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
					  Oid conflict_idx_oid)
{
	char		local_tup_ts_str[MAXDATELEN] = "(unset)";
	StringInfoData localtup,
				remotetup;
	TupleDesc	desc = RelationGetDescr(rel->rel);
	const char *idxname = "(unknown)";
	const char *qualrelname;

	/* Ignore update-update conflict for same origin */
	if (conflict_type == CT_UPDATE_EXISTS)
	{
		/*
		 * If updating a row that came from the same origin, do not report it
		 * as a conflict
		 */
		if (local_tuple_origin == replorigin_session_origin)
			return;

		/* If updated in the same transaction, do not report it as a conflict */
		if (local_tuple_origin == InvalidRepOriginId &&
			TransactionIdEquals(local_tuple_xid, GetTopTransactionId()))
			return;

		/* Differing origin */
		conflict_type = CT_UPDATE_ORIGIN_DIFFERS;
	}

	/* Count statistics */
	handle_stats_counter(rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_CONFLICT_COUNT, 1);

	/* If configured log resolution to spock.resolutions table */
	spock_conflict_log_table(conflict_type, rel, localtuple, oldkey,
							 remotetuple, applytuple, resolution,
							 local_tuple_xid, found_local_origin,
							 local_tuple_origin, local_tuple_commit_ts,
							 conflict_idx_oid);

	memset(local_tup_ts_str, 0, MAXDATELEN);
	if (found_local_origin)
		strlcpy(local_tup_ts_str,
				timestamptz_to_str(local_tuple_commit_ts),
				MAXDATELEN);

	initStringInfo(&remotetup);

	/* Check for old tuple to in case handling DELETE case */
	if (remotetuple)
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
	 *
	 * Handling for CT_DELETE_ORIGIN_DIFFERS will be added separately.
	 */
	switch (conflict_type)
	{
		case CT_INSERT_EXISTS:
		case CT_UPDATE_EXISTS:
		case CT_UPDATE_ORIGIN_DIFFERS:
			ereport(spock_conflict_log_level,
					(errcode(ERRCODE_INTEGRITY_CONSTRAINT_VIOLATION),
					 errmsg("CONFLICT: remote %s on relation %s (local index %s). Resolution: %s.",
							ConflictTypeNames[conflict_type],
							qualrelname, idxname,
							conflict_resolution_to_string(resolution)),
					 errdetail("existing local tuple {%s} xid=%u,origin=%d,timestamp=%s; remote tuple {%s} in xact origin=%u,timestamp=%s,commit_lsn=%X/%X",
							   localtup.data, local_tuple_xid,
							   found_local_origin ? (int) local_tuple_origin : -1,
							   local_tup_ts_str,
							   remotetup.data,
							   replorigin_session_origin,
							   timestamptz_to_str(replorigin_session_origin_timestamp),
							   (uint32) (replorigin_session_origin_lsn << 32),
							   (uint32) replorigin_session_origin_lsn)));
			break;
		case CT_UPDATE_MISSING:
		case CT_DELETE_MISSING:
			ereport(spock_conflict_log_level,
					(errcode(ERRCODE_INTEGRITY_CONSTRAINT_VIOLATION),
					 errmsg("CONFLICT: remote %s on relation %s replica identity index %s (tuple not found). Resolution: %s.",
							ConflictTypeNames[conflict_type],
							qualrelname, idxname,
							conflict_resolution_to_string(resolution)),
					 errdetail("remote tuple {%s} in xact origin=%u,timestamp=%s,commit_lsn=%X/%X",
							   remotetup.data,
							   replorigin_session_origin,
							   timestamptz_to_str(replorigin_session_origin_timestamp),
							   (uint32) (replorigin_session_origin_lsn << 32),
							   (uint32) replorigin_session_origin_lsn)));
			break;
		case CT_DELETE_ORIGIN_DIFFERS:
			/* keep compiler happy; handling will be added separately */
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
spock_conflict_log_table(ConflictType conflict_type,
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
						 Oid conflict_idx_oid)
{
	HeapTuple	tup;
	Datum		values[SPOCK_LOG_TABLE_COLS];
	bool		nulls[SPOCK_LOG_TABLE_COLS];
	TupleDesc	desc = RelationGetDescr(rel->rel);
	Relation	logrel;
	const char *qualrelname;
	SpockLocalNode *localnode;
	SpockNode  *node;
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
		char	   *idxname;

		idxname = get_rel_name(conflict_idx_oid);
		values[4] = CStringGetTextDatum(idxname);
	}
	else
		nulls[4] = true;

	/* conflict type */
	values[5] = CStringGetTextDatum(ConflictTypeNames[conflict_type]);
	/* conflict_resolution */
	values[6] = CStringGetTextDatum(conflict_resolution_to_string(resolution));
	/* local_origin */
	values[7] = Int32GetDatum(found_local_origin ? (int) local_tuple_origin : -1);

	/* local_tuple */
	if (localtuple != NULL)
	{
		Datum		datum;

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
	/* local_timestamp. If 0, it is a missing local tuple, so use NULL */
	if (local_tuple_commit_ts == 0)
		nulls[10] = true;
	else
		values[10] = TimestampTzGetDatum(local_tuple_commit_ts);

	/* remote_origin */
	values[11] = Int32GetDatum((int) replorigin_session_origin);

	/* remote_tuple */
	if (remotetuple != NULL)
	{
		Datum		datum;

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
	static Oid	seqoid = InvalidOid;

	if (seqoid == InvalidOid)
	{
		Oid			reloid = get_conflict_log_table_oid();
#if PG_VERSION_NUM >= 170000
		Relation	rel = RelationIdGetRelation(reloid);

		seqoid = getIdentitySequence(rel, InvalidAttrNumber, false);
		RelationClose(rel);
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
	 * Only allow SPOCK_RESOLVE_APPLY_REMOTE when track_commit_timestamp is
	 * off, because there is no way to know where the local tuple originated
	 * from.
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
 * print the tuple 'tuple' into the StringInfo s
 *
 * (Based on bdr2)
 */
void
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
		Datum		val = PointerGetDatum(NULL);	/* definitely detoasted
													 * Datum */
		char	   *outputstr = NULL;
		bool		isnull;		/* column is null? */

		attr = TupleDescAttr(tupdesc, natt);

		/*
		 * don't print dropped or generated columns, we can't be sure everything
		 * is available for them
		 */
		if (attr->attisdropped || attr->attgenerated)
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
		 * Abbreviate the Datum if it's too long. This may make it
		 * syntatically invalid, but it's not like we're writing out a valid
		 * ROW(...) as it is.
		 */
		if (strlen(outputstr) > MAX_CONFLICT_LOG_ATTR_LEN)
		{
			/* The null written at the end of strcpy will truncate the string */
			strlcpy(&outputstr[MAX_CONFLICT_LOG_ATTR_LEN - 5], "...", 3);
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
	Datum		row_json;

	if (row_isnull)
	{
		row_json = (Datum) 0;
		*ret_isnull = 1;
	}
	else
	{
		/*
		 * We don't handle errors with a PG_TRY / PG_CATCH here, because
		 * that's not sufficient to make the transaction usable given that we
		 * might fail in user defined casts, etc. We'd need a full savepoint,
		 * which is too expensive. So if this fails we'll just propagate the
		 * exception and abort the apply transaction.
		 *
		 * It shouldn't fail unless something's pretty broken anyway.
		 */
		row_json = DirectFunctionCall1(row_to_json, row);
		*ret_isnull = 0;
	}
	return row_json;
}
