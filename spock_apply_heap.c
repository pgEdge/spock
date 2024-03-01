/*-------------------------------------------------------------------------
 *
 * spock_apply_heap.c
 *             spock apply functions using heap api
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 * IDENTIFICATION
 *		  spock_apply_heap.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"
#include "libpq-fe.h"
#include "pgstat.h"

#include "access/htup_details.h"
#include "access/xact.h"

#include "catalog/namespace.h"

#include "commands/dbcommands.h"
#include "commands/sequence.h"
#include "commands/tablecmds.h"
#include "commands/trigger.h"

#include "executor/executor.h"

#include "libpq/pqformat.h"

#include "mb/pg_wchar.h"

#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"

#include "optimizer/clauses.h"
#include "optimizer/optimizer.h"

#include "parser/parse_relation.h"

#include "replication/origin.h"
#include "replication/reorderbuffer.h"
#include "replication/logicalrelation.h"

#include "rewrite/rewriteHandler.h"

#include "storage/ipc.h"
#include "storage/lmgr.h"
#include "storage/proc.h"

#include "tcop/pquery.h"
#include "tcop/utility.h"

#include "utils/attoptcache.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"

#include "spock_conflict.h"
#include "spock_executor.h"
#include "spock_node.h"
#include "spock_proto_native.h"
#include "spock_queue.h"
#include "spock_relcache.h"
#include "spock_repset.h"
#include "spock_rpc.h"
#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_apply_heap.h"

typedef struct ApplyExecutionData
{
	EState *estate; /* executor state, used to track resources */

	SpockRelation *targetRel;	  /* replication target rel */
	ResultRelInfo *targetRelInfo; /* ResultRelInfo for same */
} ApplyExecutionData;

typedef struct ApplyExecState
{
	EState *estate;
	EPQState epqstate;
	ResultRelInfo *resultRelInfo;
	TupleTableSlot *slot;
} ApplyExecState;

/* State related to bulk insert */
typedef struct ApplyMIState
{
	SpockRelation *rel;
	ApplyExecState *aestate;

	CommandId cid;
	BulkInsertState bistate;

	TupleTableSlot **buffered_tuples;
	int maxbuffered_tuples;
	int nbuffered_tuples;
} ApplyMIState;

typedef struct ApplyErrorCallbackArg
{
	LogicalRepMsgType command; /* 0 if invalid */
	LogicalRepRelMapEntry *rel;

	/* Remote node information */
	int remote_attnum; /* -1 if invalid */
	TransactionId remote_xid;
	XLogRecPtr finish_lsn;
	char *origin_name;
} ApplyErrorCallbackArg;

/* errcontext tracker */
ApplyErrorCallbackArg apply_error_callback_arg =
	{
		.command = 0,
		.rel = NULL,
		.remote_attnum = -1,
		.remote_xid = InvalidTransactionId,
		.finish_lsn = InvalidXLogRecPtr,
		.origin_name = NULL,
};

#define TTS_TUP(slot) (((HeapTupleTableSlot *)slot)->tuple)

static ApplyMIState *spkmistate = NULL;

#ifndef NO_LOG_OLD_VALUE
static void build_delta_tuple(SpockRelation *rel, SpockTupleData *oldtup,
							  SpockTupleData *newtup, SpockTupleData *deltatup,
							  TupleTableSlot *localslot);
#endif

/*
 * Executor state preparation for evaluation of constraint expressions,
 * indexes and triggers for the specified relation.
 *
 * Note that the caller must open and close any indexes to be updated.
 */
static ApplyExecutionData *
create_edata_for_relation(SpockRelation *rel)
{
	ApplyExecutionData *edata;
	EState *estate;
	RangeTblEntry *rte;
	List *perminfos = NIL;
	ResultRelInfo *resultRelInfo;

	edata = (ApplyExecutionData *)palloc0(sizeof(ApplyExecutionData));
	edata->targetRel = rel;

	edata->estate = estate = CreateExecutorState();

	rte = makeNode(RangeTblEntry);
	rte->rtekind = RTE_RELATION;
	rte->relid = RelationGetRelid(rel->rel);
	rte->relkind = rel->rel->rd_rel->relkind;
	rte->rellockmode = AccessShareLock;

	addRTEPermissionInfo(&perminfos, rte);

	ExecInitRangeTable(estate, list_make1(rte), perminfos);

	edata->targetRelInfo = resultRelInfo = makeNode(ResultRelInfo);

	/*
	 * Use Relation opened by logicalrep_rel_open() instead of opening it
	 * again.
	 */
	InitResultRelInfo(resultRelInfo, rel->rel, 1, NULL, 0);

	/*
	 * We put the ResultRelInfo in the es_opened_result_relations list, even
	 * though we don't populate the es_result_relations array.  That's a bit
	 * bogus, but it's enough to make ExecGetTriggerResultRel() find them.
	 *
	 * ExecOpenIndices() is not called here either, each execution path doing
	 * an apply operation being responsible for that.
	 */
	estate->es_opened_result_relations =
		lappend(estate->es_opened_result_relations, resultRelInfo);

	estate->es_output_cid = GetCurrentCommandId(true);

	/* Prepare to catch AFTER triggers. */
	AfterTriggerBeginQuery();

	/* other fields of edata remain NULL for now */

	return edata;
}

/*
 * Finish any operations related to the executor state created by
 * create_edata_for_relation().
 */
static void
finish_edata(ApplyExecutionData *edata)
{
	EState *estate = edata->estate;

	/* Handle any queued AFTER triggers. */
	AfterTriggerEndQuery(estate);

	/*
	 * Cleanup.  It might seem that we should call ExecCloseResultRelations()
	 * here, but we intentionally don't.  It would close the rel we added to
	 * es_opened_result_relations above, which is wrong because we took no
	 * corresponding refcount.  We rely on ExecCleanupTupleRouting() to close
	 * any other relations opened during execution.
	 */
	ExecResetTupleTable(estate->es_tupleTable, false);
	FreeExecutorState(estate);
	pfree(edata);
}

/*
 * Executes default values for columns for which we can't map to remote
 * relation columns.
 *
 * This allows us to support tables which have more columns on the downstream
 * than on the upstream.
 */
static void
slot_fill_defaults(SpockRelation *rel, EState *estate,
				   TupleTableSlot *slot)
{
#if 0
	TupleDesc	desc = RelationGetDescr(rel->localrel);
	int			num_phys_attrs = desc->natts;
	int			i;
	int			attnum,
				num_defaults = 0;
	int		   *defmap;
	ExprState **defexprs;
	ExprContext *econtext;

	econtext = GetPerTupleExprContext(estate);

	/* We got all the data via replication, no need to evaluate anything. */
	if (num_phys_attrs == rel->remoterel.natts)
		return;

	defmap = (int *) palloc(num_phys_attrs * sizeof(int));
	defexprs = (ExprState **) palloc(num_phys_attrs * sizeof(ExprState *));

	Assert(rel->attrmap->maplen == num_phys_attrs);
	for (attnum = 0; attnum < num_phys_attrs; attnum++)
	{
		Expr	   *defexpr;

		if (TupleDescAttr(desc, attnum)->attisdropped || TupleDescAttr(desc, attnum)->attgenerated)
			continue;

		if (rel->attrmap->attnums[attnum] >= 0)
			continue;

		defexpr = (Expr *) build_column_default(rel->localrel, attnum + 1);

		if (defexpr != NULL)
		{
			/* Run the expression through planner */
			defexpr = expression_planner(defexpr);

			/* Initialize executable expression in copycontext */
			defexprs[num_defaults] = ExecInitExpr(defexpr, NULL);
			defmap[num_defaults] = attnum;
			num_defaults++;
		}
	}

	for (i = 0; i < num_defaults; i++)
		slot->tts_values[defmap[i]] =
			ExecEvalExpr(defexprs[i], econtext, &slot->tts_isnull[defmap[i]]);
#endif
}

/*
 * Store tuple data into slot.
 *
 * Incoming data can be either text or binary format.
 */
static void
slot_store_data(TupleTableSlot *slot, SpockRelation *rel,
				SpockTupleData *tupleData)
{
	int natts = slot->tts_tupleDescriptor->natts;
	int i;

	ExecClearTuple(slot);

	/* Call the "in" function for each non-dropped, non-null attribute */
	Assert(natts == rel->natts);
	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(slot->tts_tupleDescriptor, i);
		int remoteattnum = rel->attmap[i];

		if (!att->attisdropped && remoteattnum >= 0)
		{
			Assert(remoteattnum < rel->natts);

			if (!tupleData->nulls[remoteattnum])
			{
				/*
				 * Fill in the Datum for this attribute
				 */
				slot->tts_values[i] = tupleData->values[i];
				slot->tts_isnull[i] = false;
			}
			else
			{
				/*
				 * NULL value from remote.
				 */
				slot->tts_values[i] = (Datum)0;
				slot->tts_isnull[i] = true;
			}
		}
		else
		{
			/*
			 * We assign NULL to dropped attributes and missing values
			 * (missing values should be later filled using
			 * slot_fill_defaults).
			 */
			slot->tts_values[i] = (Datum)0;
			slot->tts_isnull[i] = true;
		}
	}

	ExecStoreVirtualTuple(slot);
}

/*
 * Store tuple data into slot from HeapTuple.
 */
static void
slot_store_htup(TupleTableSlot *slot, SpockRelation *rel,
				HeapTuple htup)
{
	int natts = slot->tts_tupleDescriptor->natts;
	int i;

	ExecClearTuple(slot);

	/* Call the "in" function for each non-dropped, non-null attribute */
	Assert(natts == rel->natts);
	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(slot->tts_tupleDescriptor, i);
		int remoteattnum = rel->attmap[i];

		if (!att->attisdropped && remoteattnum >= 0)
		{
			slot->tts_values[i] = heap_getattr(htup, i + 1,
											   slot->tts_tupleDescriptor,
											   &slot->tts_isnull[i]);
		}
		else
		{
			/*
			 * We assign NULL to dropped attributes
			 */
			slot->tts_values[i] = (Datum)0;
			slot->tts_isnull[i] = true;
		}
	}

	ExecStoreVirtualTuple(slot);
}

/*
 * Replace updated columns with data from the SpockTupleData struct.
 * This is somewhat similar to heap_modify_tuple but also calls the type
 * input functions on the user data.
 *
 * "slot" is filled with a copy of the tuple in "srcslot", replacing
 * columns provided in "tupleData" and leaving others as-is.
 *
 * Caution: unreplaced pass-by-ref columns in "slot" will point into the
 * storage for "srcslot".  This is OK for current usage, but someday we may
 * need to materialize "slot" at the end to make it independent of "srcslot".
 */
static void
slot_modify_data(TupleTableSlot *slot, TupleTableSlot *srcslot,
				 SpockRelation *rel,
				 SpockTupleData *tupleData)
{
	int natts = slot->tts_tupleDescriptor->natts;
	int i;

	/* We'll fill "slot" with a virtual tuple, so we must start with ... */
	ExecClearTuple(slot);

	/*
	 * Copy all the column data from srcslot, so that we'll have valid values
	 * for unreplaced columns.
	 */
	Assert(natts == srcslot->tts_tupleDescriptor->natts);
	slot_getallattrs(srcslot);
	memcpy(slot->tts_values, srcslot->tts_values, natts * sizeof(Datum));
	memcpy(slot->tts_isnull, srcslot->tts_isnull, natts * sizeof(bool));

	/* Call the "in" function for each replaced attribute */
	Assert(natts == rel->natts);
	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(slot->tts_tupleDescriptor, i);
		int remoteattnum = rel->attmap[i];

		if (remoteattnum < 0)
			continue;

		if (!att->attisdropped && remoteattnum >= 0)
		{
			if (!tupleData->nulls[remoteattnum])
			{
				/* Use the value from the NEW remote tuple */
				slot->tts_values[i] = tupleData->values[i];
				slot->tts_isnull[i] = false;
			}
			else
			{
				/* Must be LOGICALREP_COLUMN_NULL */
				slot->tts_values[i] = (Datum)0;
				slot->tts_isnull[i] = true;
			}
		}
	}

	/* And finally, declare that "slot" contains a valid virtual tuple */
	ExecStoreVirtualTuple(slot);
}

/*
 * Try to find a tuple received from the publication side (in 'remoteslot') in
 * the corresponding local relation using either replica identity index,
 * primary key, index or if needed, sequential scan.
 *
 * Local tuple, if found, is returned in '*localslot'.
 */
static bool
FindReplTupleInLocalRel(ApplyExecutionData *edata, Relation localrel,
						Oid localidxoid,
						TupleTableSlot *remoteslot,
						TupleTableSlot **localslot)
{
	EState *estate = edata->estate;
	bool found;

	*localslot = table_slot_create(localrel, &estate->es_tupleTable);

	if (OidIsValid(localidxoid))
	{
#ifdef USE_ASSERT_CHECKING
		Relation idxrel = index_open(localidxoid, AccessShareLock);

		/* Index must be PK, or RI */
		Assert(GetRelationIdentityOrPK(localrel) == localidxoid);
		index_close(idxrel, AccessShareLock);
#endif

		found = RelationFindReplTupleByIndex(localrel, localidxoid,
											 LockTupleExclusive,
											 remoteslot, *localslot);
	}
	else
		found = RelationFindReplTupleSeq(localrel, LockTupleExclusive,
										 remoteslot, *localslot);

	return found;
}

void spock_apply_heap_begin(void)
{
	return;
}

void spock_apply_heap_commit(void)
{
}

static bool
physatt_in_attmap(SpockRelation *rel, int attid)
{
	AttrNumber i;

	for (i = 0; i < rel->natts; i++)
		if (rel->attmap[i] == attid)
			return true;

	return false;
}

/*
 * Executes default values for columns for which we didn't get any data.
 *
 * TODO: this needs caching, it's not exactly fast.
 */
static void
fill_missing_defaults(SpockRelation *rel, EState *estate,
					  SpockTupleData *tuple)
{
	TupleDesc desc = RelationGetDescr(rel->rel);
	AttrNumber num_phys_attrs = desc->natts;
	int i;
	AttrNumber attnum,
		num_defaults = 0;
	int *defmap;
	ExprState **defexprs;
	ExprContext *econtext;

	econtext = GetPerTupleExprContext(estate);

	/* We got all the data via replication, no need to evaluate anything. */
	if (num_phys_attrs == rel->natts)
		return;

	defmap = (int *)palloc(num_phys_attrs * sizeof(int));
	defexprs = (ExprState **)palloc(num_phys_attrs * sizeof(ExprState *));

	for (attnum = 0; attnum < num_phys_attrs; attnum++)
	{
		Expr *defexpr;

		if (TupleDescAttr(desc, attnum)->attisdropped)
			continue;

		if (physatt_in_attmap(rel, attnum))
			continue;

		defexpr = (Expr *)build_column_default(rel->rel, attnum + 1);

		if (defexpr != NULL)
		{
			/* Run the expression through planner */
			defexpr = expression_planner(defexpr);

			/* Initialize executable expression in copycontext */
			defexprs[num_defaults] = ExecInitExpr(defexpr, NULL);
			defmap[num_defaults] = attnum;
			num_defaults++;
		}
	}

	for (i = 0; i < num_defaults; i++)
		tuple->values[defmap[i]] = ExecEvalExpr(defexprs[i],
												econtext,
												&tuple->nulls[defmap[i]],
												NULL);
}

#ifndef NO_LOG_OLD_VALUE

static void
build_delta_tuple(SpockRelation *rel, SpockTupleData *oldtup,
				  SpockTupleData *newtup,
				  SpockTupleData *deltatup,
				  TupleTableSlot *localslot)
{
	TupleDesc tupdesc = RelationGetDescr(rel->rel);
	int attidx;
	Datum loc_value;
	Datum result;
	bool loc_isnull;

	for (attidx = 0; attidx < tupdesc->natts; attidx++)
	{
		if (rel->delta_apply_functions[attidx] == InvalidOid)
		{
			deltatup->values[attidx] = 0xdeadbeef;
			deltatup->nulls[attidx] = true;
			deltatup->changed[attidx] = false;
			continue;
		}

		/*
		 * Column is marked LOG_OLD_VALUE=true. We use that as flag
		 * to apply the delta between the remote old and new instead
		 * of the plain new value.
		 *
		 * To perform the actual delta math we need the functions behind
		 * the '+' and '-' operators for the data type.
		 *
		 * XXX: This is currently hardcoded for the builtin data types
		 * we support. Ideally we would lookup those operators in the
		 * system cache, but that isn't straight forward and we get into
		 * all sorts of trouble when it comes to user defined data types
		 * and the search path.
		 */

		if (oldtup->nulls[attidx])
		{
			/*
			 * This is a special case. Columns for delta apply need to
			 * be marked NOT NULL and LOG_OLD_VALUE=true. During this
			 * remote UPDATE LOG_OLD_VALUE setting was false. We use this
			 * as a flag to force plain NEW value application. This is
			 * useful in case a server ever gets out of sync.
			 */
			deltatup->values[attidx] = newtup->values[attidx];
			deltatup->nulls[attidx] = false;
			deltatup->changed[attidx] = true;
		}
		else
		{
			loc_value = heap_getattr(TTS_TUP(localslot), attidx + 1, tupdesc,
									 &loc_isnull);

			result = OidFunctionCall3Coll(rel->delta_apply_functions[attidx], InvalidOid, oldtup->values[attidx], newtup->values[attidx], loc_value);
			deltatup->values[attidx] = result;
			deltatup->nulls[attidx] = false;
			deltatup->changed[attidx] = true;
		}
	}
}
#endif /* NO_LOG_OLD_VALUE */

static ApplyExecState *
init_apply_exec_state(SpockRelation *rel)
{
	ApplyExecState *aestate = palloc0(sizeof(ApplyExecState));

	/* Initialize the executor state. */
	aestate->estate = create_estate_for_relation(rel->rel, true);

	aestate->resultRelInfo = makeNode(ResultRelInfo);
	InitResultRelInfo(aestate->resultRelInfo, rel->rel, 1, NULL, 0);

#if PG_VERSION_NUM < 140000
	aestate->estate->es_result_relations = aestate->resultRelInfo;
	aestate->estate->es_num_result_relations = 1;
	aestate->estate->es_result_relation_info = aestate->resultRelInfo;
#endif

	// aestate->slot = ExecInitExtraTupleSlot(aestate->estate);
	ExecSetSlotDescriptor(aestate->slot, RelationGetDescr(rel->rel));

	if (aestate->resultRelInfo->ri_TrigDesc)
		EvalPlanQualInit(&aestate->epqstate, aestate->estate, NULL, NIL, -1,
						 NIL);

	/* Prepare to catch AFTER triggers. */
	AfterTriggerBeginQuery();

	return aestate;
}

static void
finish_apply_exec_state(ApplyExecState *aestate)
{
	/* Close indexes */
	ExecCloseIndices(aestate->resultRelInfo);

	/* Handle queued AFTER triggers. */
	AfterTriggerEndQuery(aestate->estate);

	/* Terminate EPQ execution if active. */
	if (aestate->resultRelInfo->ri_TrigDesc)
	{
		EvalPlanQualEnd(&aestate->epqstate);
		ExecCloseResultRelations(aestate->estate);
	}

	/* Cleanup tuple table. */
	ExecResetTupleTable(aestate->estate->es_tupleTable, true);

	/* Free the memory. */
	FreeExecutorState(aestate->estate);
	pfree(aestate);
}

/*
 * Handle insert via low level api.
 */
void spock_apply_heap_insert(SpockRelation *rel, SpockTupleData *newtup)
{
	ApplyExecutionData *edata;
	EState *estate;
	TupleTableSlot *remoteslot;
	MemoryContext oldctx;

	/* Initialize the executor state. */
	edata = create_edata_for_relation(rel);
	estate = edata->estate;
	remoteslot = ExecInitExtraTupleSlot(estate,
										RelationGetDescr(rel->rel),
										&TTSOpsVirtual);

	/* update stats */
	handle_stats_counter(rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_INSERT_COUNT, 1);

	/*
	 * TODO: Spock does an all-column UPDATE if row exists on INSERT
	 */

	/* Process and store remote tuple in the slot */
	oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(estate));
	slot_store_data(remoteslot, rel, newtup);
	slot_fill_defaults(rel, estate, remoteslot);
	MemoryContextSwitchTo(oldctx);

	/* Do the actual INSERT */
	ExecOpenIndices(edata->targetRelInfo, false);
	ExecSimpleRelationInsert(edata->targetRelInfo, estate, remoteslot);
	ExecCloseIndices(edata->targetRelInfo);

	/* Cleanup */
	finish_edata(edata);
}

/*
 * Handle update via low level api.
 */
void spock_apply_heap_update(SpockRelation *rel, SpockTupleData *oldtup,
							 SpockTupleData *newtup)
{
	ApplyExecutionData *edata;
	EState *estate;
	EPQState epqstate;
	TupleTableSlot *remoteslot;
	TupleTableSlot *localslot;
	HeapTuple remotetuple;
	MemoryContext oldctx;
	ResultRelInfo *relinfo;
	bool found;
	int retry;
	bool clear_remoteslot = false;
	bool clear_localslot = false;

	/* Initialize the executor state. */
	edata = create_edata_for_relation(rel);
	estate = edata->estate;
	remoteslot = ExecInitExtraTupleSlot(estate,
										RelationGetDescr(rel->rel),
										&TTSOpsVirtual);

	/* update stats */
	handle_stats_counter(rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_UPDATE_COUNT, 1);

	/* Build the search tuple. */
	oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(estate));
	slot_store_data(remoteslot, rel, oldtup);
	MemoryContextSwitchTo(oldctx);

	/* Find the current local tuple */
	EvalPlanQualInit(&epqstate, estate, NULL, NIL, -1, NIL);
	ExecOpenIndices(edata->targetRelInfo, false);

	relinfo = edata->targetRelInfo;

	retry = 0;
	while (retry < 5)
	{
		found = FindReplTupleInLocalRel(edata, relinfo->ri_RelationDesc,
										edata->targetRel->idxoid,
										remoteslot, &localslot);
		if (found)
			break;

		retry++;
	}

	if (retry > 0)
		elog(LOG, "spock_apply_heap_update() retried %d times", retry);

	/*
	 * Perform the UPDATE if Tuple found.
	 *
	 * Note this will fail if there are other conflicting unique indexes.
	 */
	if (found)
	{
		TransactionId xmin;
		TimestampTz local_ts;
		RepOriginId local_origin;
		bool local_origin_found;
		bool apply;
		HeapTuple applytuple;
		SpockConflictResolution resolution;

		/* Process and store remote tuple in the slot */
		oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(estate));
		MemoryContextSwitchTo(oldctx);

		remotetuple = ExecFetchSlotHeapTuple(remoteslot, true,
											 &clear_remoteslot);
		local_origin_found = get_tuple_origin(rel, TTS_TUP(localslot),
											  &(localslot->tts_tid), &xmin,
											  &local_origin, &local_ts);

		apply = try_resolve_conflict(rel->rel, TTS_TUP(localslot),
									 remotetuple, &applytuple,
									 local_origin, local_ts,
									 &resolution);

		/*
		 * If remote tuple won we go forward with that as a base.
		 */
		if (apply && applytuple == remotetuple)
		{
			/* Set _Spock_CommitTS_ and _Spock_CommitOrigin_ to NULL */
			if (rel->att_commit_ts > 0 && rel->att_commit_origin > 0)
			{
				newtup->nulls[rel->att_commit_ts] = true;
				newtup->nulls[rel->att_commit_origin] = true;
				newtup->changed[rel->att_commit_ts] = true;
				newtup->changed[rel->att_commit_origin] = true;
			}
			slot_modify_data(remoteslot, localslot, rel, newtup);
		}
		else
		{
			spock_report_conflict(CONFLICT_UPDATE_UPDATE, rel,
								  TTS_TUP(localslot), oldtup,
								  remotetuple, applytuple, resolution,
								  xmin, local_origin_found, local_origin,
								  local_ts, rel->idxoid,
								  true /* FIXME: unused in the call chain*/);
		}

		if (rel->has_delta_columns)
		{
			SpockTupleData deltatup;
			HeapTuple currenttuple;

			/*
			 * Depending on previous conflict resolution our final NEW
			 * tuple will be based on either the incoming remote tuple
			 * or the existing local one and then the delta processing
			 * on top of that.
			 */
			if (apply)
			{
				currenttuple = remotetuple;
			}
			else
			{
				currenttuple = ExecFetchSlotHeapTuple(localslot, true,
													  &clear_localslot);
			}
			oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(estate));
			build_delta_tuple(rel, oldtup, newtup, &deltatup, localslot);
			if (!apply)
			{
				/*
				 * We are overriding apply=false because of delta apply.
				 * Remember the current commit timestamp and origin
				 * in the hidden columns.
				 */
				apply = true;

				deltatup.values[rel->att_commit_ts] = TimestampTzGetDatum(local_ts);
				deltatup.nulls[rel->att_commit_ts] = false;
				deltatup.changed[rel->att_commit_ts] = true;
				deltatup.values[rel->att_commit_origin] = Int32GetDatum(local_origin);
				deltatup.nulls[rel->att_commit_origin] = false;
				deltatup.changed[rel->att_commit_origin] = true;

				/* Count the DCA event in stats */
				handle_stats_counter(rel->rel, MyApplyWorker->subid,
									 SPOCK_STATS_DCA_COUNT, 1);
			}
			else
			{
				/*
				 * We let the remote row get applied. Set the hidden
				 * commit_ts and _origin columns to NULL.
				 */
				deltatup.nulls[rel->att_commit_ts] = true;
				deltatup.changed[rel->att_commit_ts] = true;
				deltatup.nulls[rel->att_commit_origin] = true;
				deltatup.changed[rel->att_commit_origin] = true;
			}
			applytuple = heap_modify_tuple(currenttuple,
										   RelationGetDescr(rel->rel),
										   deltatup.values,
										   deltatup.nulls,
										   deltatup.changed);
			MemoryContextSwitchTo(oldctx);
			slot_store_htup(remoteslot, rel, applytuple);
		}

		/*
		 * Finally do the actual tuple update if needed.
		 */
		if (apply)
		{
			EvalPlanQualSetSlot(&epqstate, remoteslot);
			ExecSimpleRelationUpdate(edata->targetRelInfo, estate, &epqstate,
									 localslot, remoteslot);
		}
	}
	else
	{
		/*
		 * The tuple to be updated could not be found.  Do nothing except for
		 * emitting a log message.
		 */
		elog(LOG,
			 "logical replication did not find row to be updated "
			 "in replication target relation \"%s\"",
			 RelationGetRelationName(rel->rel));
	}

	/* Cleanup. */
	if (clear_remoteslot)
		ExecClearTuple(remoteslot);
	if (clear_localslot)
		ExecClearTuple(localslot);
	ExecCloseIndices(edata->targetRelInfo);
	EvalPlanQualEnd(&epqstate);
	finish_edata(edata);
}

/*
 * Handle delete via low level api.
 */
void spock_apply_heap_delete(SpockRelation *rel, SpockTupleData *oldtup)
{
	ApplyExecutionData *edata;
	EState *estate;
	EPQState epqstate;
	TupleTableSlot *remoteslot;
	TupleTableSlot *localslot;
	MemoryContext oldctx;
	ResultRelInfo *relinfo;
	bool found;
	int retry;

	/* Initialize the executor state. */
	edata = create_edata_for_relation(rel);
	estate = edata->estate;
	remoteslot = ExecInitExtraTupleSlot(estate,
										RelationGetDescr(rel->rel),
										&TTSOpsVirtual);

	/* update stats */
	handle_stats_counter(rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_UPDATE_COUNT, 1);

	/* Build the search tuple. */
	oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(estate));
	slot_store_data(remoteslot, rel, oldtup);
	MemoryContextSwitchTo(oldctx);

	/* Find the current local tuple */
	EvalPlanQualInit(&epqstate, estate, NULL, NIL, -1, NIL);
	ExecOpenIndices(edata->targetRelInfo, false);

	relinfo = edata->targetRelInfo;

	retry = 0;
	while (retry < 5)
	{
		found = FindReplTupleInLocalRel(edata, relinfo->ri_RelationDesc,
										edata->targetRel->idxoid,
										remoteslot, &localslot);
		if (found)
			break;

		retry++;
	}
	ExecClearTuple(remoteslot);

	if (retry > 0)
		elog(LOG, "spock_apply_heap_delete() retried %d times", retry);

	/*
	 * Perform the DELETE if Tuple found.
	 *
	 * Note this will fail if there are other conflicting unique indexes.
	 */
	if (found)
	{
		/* Delete the tuple found */
		EvalPlanQualSetSlot(&epqstate, remoteslot);
		ExecSimpleRelationDelete(edata->targetRelInfo, estate, &epqstate,
								 localslot);
	}
	else
	{
		/*
		 * The tuple to be updated could not be found.  Do nothing except for
		 * emitting a log message.
		 */
		elog(LOG,
			 "logical replication did not find row to be deleted "
			 "in replication target relation \"%s\"",
			 RelationGetRelationName(rel->rel));
	}

	/* Cleanup. */
	ExecCloseIndices(edata->targetRelInfo);
	EvalPlanQualEnd(&epqstate);
	finish_edata(edata);
}

bool spock_apply_heap_can_mi(SpockRelation *rel)
{
	/* Multi insert is only supported when conflicts result in errors. */
	return spock_conflict_resolver == SPOCK_RESOLVE_ERROR;
}

/*
 * MultiInsert initialization.
 */
static void
spock_apply_heap_mi_start(SpockRelation *rel)
{
	MemoryContext oldctx;
	ApplyExecState *aestate;
	ResultRelInfo *resultRelInfo;
	TupleDesc desc;
	bool volatile_defexprs = false;

	if (spkmistate && spkmistate->rel == rel)
		return;

	if (spkmistate && spkmistate->rel != rel)
		spock_apply_heap_mi_finish(spkmistate->rel);

	oldctx = MemoryContextSwitchTo(TopTransactionContext);

	/* Initialize new MultiInsert state. */
	spkmistate = palloc0(sizeof(ApplyMIState));

	spkmistate->rel = rel;

	/* Initialize the executor state. */
	spkmistate->aestate = aestate = init_apply_exec_state(rel);
	MemoryContextSwitchTo(TopTransactionContext);
	resultRelInfo = aestate->resultRelInfo;

	ExecOpenIndices(resultRelInfo, false);

	/* Check if table has any volatile default expressions. */
	desc = RelationGetDescr(rel->rel);
	if (desc->natts != rel->natts)
	{
		int attnum;

		for (attnum = 0; attnum < desc->natts; attnum++)
		{
			Expr *defexpr;

			if (TupleDescAttr(desc, attnum)->attisdropped)
				continue;

			defexpr = (Expr *)build_column_default(rel->rel, attnum + 1);

			if (defexpr != NULL)
			{
				/* Run the expression through planner */
				defexpr = expression_planner(defexpr);
				volatile_defexprs = contain_volatile_functions_not_nextval((Node *)defexpr);

				if (volatile_defexprs)
					break;
			}
		}
	}

	/*
	 * Decide if to buffer tuples based on the collected information
	 * about the table.
	 */
	if ((resultRelInfo->ri_TrigDesc != NULL &&
		 (resultRelInfo->ri_TrigDesc->trig_insert_before_row ||
		  resultRelInfo->ri_TrigDesc->trig_insert_instead_row)) ||
		volatile_defexprs)
	{
		spkmistate->maxbuffered_tuples = 1;
	}
	else
	{
		spkmistate->maxbuffered_tuples = 1000;
	}

	spkmistate->cid = GetCurrentCommandId(true);
	spkmistate->bistate = GetBulkInsertState();

	/* Make the space for buffer. */
	spkmistate->buffered_tuples = palloc0(spkmistate->maxbuffered_tuples * sizeof(TupleTableSlot *));
	spkmistate->nbuffered_tuples = 0;

	MemoryContextSwitchTo(oldctx);
}

/* Write the buffered tuples. */
static void
spock_apply_heap_mi_flush(void)
{
	MemoryContext oldctx;
	ResultRelInfo *resultRelInfo;
	int i;

	if (!spkmistate || spkmistate->nbuffered_tuples == 0)
		return;

	/* update stats */
	handle_stats_counter(spkmistate->rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_INSERT_COUNT,
						 spkmistate->nbuffered_tuples);

	oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(spkmistate->aestate->estate));
	heap_multi_insert(spkmistate->rel->rel,
					  spkmistate->buffered_tuples,
					  spkmistate->nbuffered_tuples,
					  spkmistate->cid,
					  0, /* hi_options */
					  spkmistate->bistate);
	MemoryContextSwitchTo(oldctx);

	resultRelInfo = spkmistate->aestate->resultRelInfo;

	/*
	 * If there are any indexes, update them for all the inserted tuples, and
	 * run AFTER ROW INSERT triggers.
	 */
	if (resultRelInfo->ri_NumIndices > 0)
	{
		for (i = 0; i < spkmistate->nbuffered_tuples; i++)
		{
			List *recheckIndexes = NIL;

			recheckIndexes =
				ExecInsertIndexTuples(
#if PG_VERSION_NUM >= 140000
					resultRelInfo,
#endif
					spkmistate->buffered_tuples[i],
					spkmistate->aestate->estate
#if PG_VERSION_NUM >= 140000
					,
					false
#endif
					,
					false, NULL, NIL
#if PG_VERSION_NUM >= 160000
					,
					false
#endif
				);
			ExecARInsertTriggers(spkmistate->aestate->estate, resultRelInfo,
								 spkmistate->buffered_tuples[i],
								 recheckIndexes);
			list_free(recheckIndexes);
		}
	}

	/*
	 * There's no indexes, but see if we need to run AFTER ROW INSERT triggers
	 * anyway.
	 */
	else if (resultRelInfo->ri_TrigDesc != NULL &&
			 resultRelInfo->ri_TrigDesc->trig_insert_after_row)
	{
		for (i = 0; i < spkmistate->nbuffered_tuples; i++)
		{
			ExecARInsertTriggers(spkmistate->aestate->estate, resultRelInfo,
								 spkmistate->buffered_tuples[i],
								 NIL);
		}
	}

	spkmistate->nbuffered_tuples = 0;
}

/* Add tuple to the MultiInsert. */
void spock_apply_heap_mi_add_tuple(SpockRelation *rel,
								   SpockTupleData *tup)
{
	MemoryContext oldctx;
	ApplyExecState *aestate;
	HeapTuple remotetuple;
	TupleTableSlot *slot;

	spock_apply_heap_mi_start(rel);

	/*
	 * If sufficient work is pending, process that first
	 */
	if (spkmistate->nbuffered_tuples >= spkmistate->maxbuffered_tuples)
		spock_apply_heap_mi_flush();

	/* Process and store remote tuple in the slot */
	aestate = spkmistate->aestate;

	if (spkmistate->nbuffered_tuples == 0)
	{
		/*
		 * Reset the per-tuple exprcontext. We can only do this if the
		 * tuple buffer is empty. (Calling the context the per-tuple
		 * memory context is a bit of a misnomer now.)
		 */
		ResetPerTupleExprContext(aestate->estate);
	}

	oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(aestate->estate));
	fill_missing_defaults(rel, aestate->estate, tup);
	remotetuple = heap_form_tuple(RelationGetDescr(rel->rel),
								  tup->values, tup->nulls);
	MemoryContextSwitchTo(TopTransactionContext);
	slot = aestate->slot;
	/* Store the tuple in slot, but make sure it's not freed. */
	ExecStoreHeapTuple(remotetuple, slot, false);

	if (aestate->resultRelInfo->ri_TrigDesc &&
		aestate->resultRelInfo->ri_TrigDesc->trig_insert_before_row)
	{
		if (!ExecBRInsertTriggers(aestate->estate,
								  aestate->resultRelInfo,
								  slot))
		{
			MemoryContextSwitchTo(oldctx);
			return;
		}
	}

	/* Check the constraints of the tuple */
	if (rel->rel->rd_att->constr)
		ExecConstraints(aestate->resultRelInfo, slot,
						aestate->estate);

	if (spkmistate->buffered_tuples[spkmistate->nbuffered_tuples] == NULL)
		spkmistate->buffered_tuples[spkmistate->nbuffered_tuples] = table_slot_create(rel->rel, NULL);
	else
		ExecClearTuple(spkmistate->buffered_tuples[spkmistate->nbuffered_tuples]);
	ExecCopySlot(spkmistate->buffered_tuples[spkmistate->nbuffered_tuples], slot);
	spkmistate->nbuffered_tuples++;
	MemoryContextSwitchTo(oldctx);
}

void spock_apply_heap_mi_finish(SpockRelation *rel)
{
	if (!spkmistate)
		return;

	Assert(spkmistate->rel == rel);

	spock_apply_heap_mi_flush();

	FreeBulkInsertState(spkmistate->bistate);

	finish_apply_exec_state(spkmistate->aestate);

	for (int i = 0; i < spkmistate->maxbuffered_tuples; i++)
		if (spkmistate->buffered_tuples[i])
			ExecDropSingleTupleTableSlot(spkmistate->buffered_tuples[i]);

	pfree(spkmistate->buffered_tuples);
	pfree(spkmistate);

	spkmistate = NULL;
}
