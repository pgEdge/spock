/*-------------------------------------------------------------------------
 *
 * spock_apply_heap.c
 * 		spock apply functions using heap api
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
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
#if PG_VERSION_NUM >= 120000
#include "optimizer/optimizer.h"
#else
#include "optimizer/planner.h"
#endif

#include "replication/origin.h"
#include "replication/reorderbuffer.h"

#include "rewrite/rewriteHandler.h"

#include "storage/ipc.h"
#include "storage/lmgr.h"
#include "storage/proc.h"

#include "tcop/pquery.h"
#include "tcop/utility.h"

#include "utils/builtins.h"
#include "utils/int8.h"
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

typedef struct ApplyExecState {
	EState			   *estate;
	EPQState			epqstate;
	ResultRelInfo	   *resultRelInfo;
	TupleTableSlot	   *slot;
} ApplyExecState;

/* State related to bulk insert */
typedef struct ApplyMIState
{
	SpockRelation  *rel;
	ApplyExecState	   *aestate;

	CommandId			cid;
	BulkInsertState		bistate;

#if PG_VERSION_NUM >= 120000
	TupleTableSlot	  **buffered_tuples;
#else
	HeapTuple		   *buffered_tuples;
#endif
	int					maxbuffered_tuples;
	int					nbuffered_tuples;
} ApplyMIState;


#if PG_VERSION_NUM >= 120000
#define TTS_TUP(slot) (((HeapTupleTableSlot *)slot)->tuple)
#else
#define TTS_TUP(slot) (slot->tts_tuple)
#endif


static ApplyMIState *pglmistate = NULL;

void
spock_apply_heap_begin(void)
{
}

void
spock_apply_heap_commit(void)
{
}


static List *
UserTableUpdateOpenIndexes(ResultRelInfo *relinfo, EState *estate, TupleTableSlot *slot, bool update)
{
	List	   *recheckIndexes = NIL;

	if (relinfo->ri_NumIndices > 0)
	{
		recheckIndexes = ExecInsertIndexTuples(
#if PG_VERSION_NUM >= 140000
											   relinfo,
#endif
											   slot,
#if PG_VERSION_NUM < 120000
											   &slot->tts_tuple->t_self,
#endif
											   estate
#if PG_VERSION_NUM >= 140000
											   , update
#endif
#if PG_VERSION_NUM >= 90500
											   , false, NULL, NIL
#endif
											   );

		/* FIXME: recheck the indexes */
		if (recheckIndexes != NIL)
		{
			StringInfoData si;
			ListCell *lc;
			const char *idxname, *relname, *nspname;
			Relation target_rel = relinfo->ri_RelationDesc;

			relname = RelationGetRelationName(target_rel);
			nspname = get_namespace_name(RelationGetNamespace(target_rel));

			initStringInfo(&si);
			foreach (lc, recheckIndexes)
			{
				Oid idxoid = lfirst_oid(lc);
				idxname = get_rel_name(idxoid);
				if (idxname == NULL)
					elog(ERROR, "cache lookup failed for index oid %u", idxoid);
				if (si.len > 0)
					appendStringInfoString(&si, ", ");
				appendStringInfoString(&si, quote_identifier(idxname));
			}

			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("spock doesn't support deferrable indexes"),
					 errdetail("relation %s.%s has deferrable indexes: %s",
								quote_identifier(nspname),
								quote_identifier(relname),
								si.data)));
		}

		list_free(recheckIndexes);
	}

	return recheckIndexes;
}

static bool
physatt_in_attmap(SpockRelation *rel, int attid)
{
	AttrNumber	i;

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
	TupleDesc	desc = RelationGetDescr(rel->rel);
	AttrNumber	num_phys_attrs = desc->natts;
	int			i;
	AttrNumber	attnum,
				num_defaults = 0;
	int		   *defmap;
	ExprState **defexprs;
	ExprContext *econtext;

	econtext = GetPerTupleExprContext(estate);

	/* We got all the data via replication, no need to evaluate anything. */
	if (num_phys_attrs == rel->natts)
		return;

	defmap = (int *) palloc(num_phys_attrs * sizeof(int));
	defexprs = (ExprState **) palloc(num_phys_attrs * sizeof(ExprState *));

	for (attnum = 0; attnum < num_phys_attrs; attnum++)
	{
		Expr	   *defexpr;

		if (TupleDescAttr(desc,attnum)->attisdropped)
			continue;

		if (physatt_in_attmap(rel, attnum))
			continue;

		defexpr = (Expr *) build_column_default(rel->rel, attnum + 1);

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

static ApplyExecState *
init_apply_exec_state(SpockRelation *rel)
{
	ApplyExecState	   *aestate = palloc0(sizeof(ApplyExecState));

	/* Initialize the executor state. */
	aestate->estate = create_estate_for_relation(rel->rel, true);

	aestate->resultRelInfo = makeNode(ResultRelInfo);
	InitResultRelInfo(aestate->resultRelInfo, rel->rel, 1, 0);

#if PG_VERSION_NUM < 140000
	aestate->estate->es_result_relations = aestate->resultRelInfo;
	aestate->estate->es_num_result_relations = 1;
	aestate->estate->es_result_relation_info = aestate->resultRelInfo;
#endif

	aestate->slot = ExecInitExtraTupleSlot(aestate->estate);
	ExecSetSlotDescriptor(aestate->slot, RelationGetDescr(rel->rel));

	if (aestate->resultRelInfo->ri_TrigDesc)
		EvalPlanQualInit(&aestate->epqstate, aestate->estate, NULL, NIL, -1);

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
		EvalPlanQualEnd(&aestate->epqstate);

	/* Cleanup tuple table. */
	ExecResetTupleTable(aestate->estate->es_tupleTable, true);

	/* Free the memory. */
	FreeExecutorState(aestate->estate);
	pfree(aestate);
}

/*
 * Handle insert via low level api.
 */
void
spock_apply_heap_insert(SpockRelation *rel, SpockTupleData *newtup)
{
	ApplyExecState	   *aestate;
	Oid					conflicts_idx_id;
	TupleTableSlot	   *localslot;
	HeapTuple			remotetuple;
	HeapTuple			applytuple;
	SpockConflictResolution resolution;
	List			   *recheckIndexes = NIL;
	MemoryContext		oldctx;
	bool				has_before_triggers = false;

	/* Initialize the executor state. */
	aestate = init_apply_exec_state(rel);
#if PG_VERSION_NUM >= 120000
	localslot = table_slot_create(rel->rel, &aestate->estate->es_tupleTable);
#else
	localslot = ExecInitExtraTupleSlot(aestate->estate);
	ExecSetSlotDescriptor(localslot, RelationGetDescr(rel->rel));
#endif

	ExecOpenIndices(aestate->resultRelInfo
#if PG_VERSION_NUM >= 90500
					, false
#endif
					);

	/*
	 * Check for existing tuple with same key in any unique index containing
	 * only normal columns. This doesn't just check the replica identity index,
	 * but it'll prefer it and use it first.
	 */
	conflicts_idx_id = spock_tuple_find_conflict(aestate->resultRelInfo,
													 newtup,
													 localslot);

	/* Process and store remote tuple in the slot */
	oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(aestate->estate));
	fill_missing_defaults(rel, aestate->estate, newtup);
	remotetuple = heap_form_tuple(RelationGetDescr(rel->rel),
								  newtup->values, newtup->nulls);
	MemoryContextSwitchTo(oldctx);
	ExecStoreHeapTuple(remotetuple, aestate->slot, true);

	if (aestate->resultRelInfo->ri_TrigDesc &&
		aestate->resultRelInfo->ri_TrigDesc->trig_insert_before_row)
	{
		has_before_triggers = true;

#if PG_VERSION_NUM >= 120000
		if (!ExecBRInsertTriggers(aestate->estate,
								  aestate->resultRelInfo,
								  aestate->slot))
#else
		aestate->slot = ExecBRInsertTriggers(aestate->estate,
											 aestate->resultRelInfo,
											 aestate->slot);

		if (aestate->slot == NULL)		/* "do nothing" */
#endif
		{
			finish_apply_exec_state(aestate);
			return;
		}

	}

	/* trigger might have changed tuple */
#if PG_VERSION_NUM >= 120000
	remotetuple = ExecFetchSlotHeapTuple(aestate->slot, true, NULL);
#else
	remotetuple = ExecMaterializeSlot(aestate->slot);
#endif

	/* Did we find matching key in any candidate-key index? */
	if (OidIsValid(conflicts_idx_id))
	{
		TransactionId		xmin;
		TimestampTz			local_ts;
		RepOriginId			local_origin;
		bool				apply;
		bool				local_origin_found;

		local_origin_found = get_tuple_origin(TTS_TUP(localslot), &xmin,
											  &local_origin, &local_ts);

		/* Tuple already exists, try resolving conflict. */
		apply = try_resolve_conflict(rel->rel, TTS_TUP(localslot),
									 remotetuple, &applytuple,
									 &resolution);

		spock_report_conflict(CONFLICT_INSERT_INSERT, rel,
								  TTS_TUP(localslot), NULL, remotetuple,
								  applytuple, resolution, xmin,
								  local_origin_found, local_origin,
								  local_ts, conflicts_idx_id,
								  has_before_triggers);

		if (apply)
		{
#if PG_VERSION_NUM >= 120000
			bool update_indexes;
#endif

			if (applytuple != remotetuple)
				ExecStoreHeapTuple(applytuple, aestate->slot, false);

			if (aestate->resultRelInfo->ri_TrigDesc &&
				aestate->resultRelInfo->ri_TrigDesc->trig_update_before_row)
			{
#if PG_VERSION_NUM >= 120000
				if (!ExecBRUpdateTriggers(aestate->estate,
										  &aestate->epqstate,
										  aestate->resultRelInfo,
										  &(TTS_TUP(localslot)->t_self),
										  NULL,
										  aestate->slot))
#else
				aestate->slot = ExecBRUpdateTriggers(aestate->estate,
													 &aestate->epqstate,
													 aestate->resultRelInfo,
													 &(TTS_TUP(localslot)->t_self),
													 NULL,
													 aestate->slot);

				if (aestate->slot == NULL)		/* "do nothing" */
#endif
				{
					finish_apply_exec_state(aestate);
					return;
				}

			}

			/* trigger might have changed tuple */
#if PG_VERSION_NUM >= 120000
			remotetuple = ExecFetchSlotHeapTuple(aestate->slot, true, NULL);
#else
			remotetuple = ExecMaterializeSlot(aestate->slot);
#endif

			/* Check the constraints of the tuple */
			if (rel->rel->rd_att->constr)
				ExecConstraints(aestate->resultRelInfo, aestate->slot,
								aestate->estate);

#if PG_VERSION_NUM >= 120000
			simple_table_tuple_update(rel->rel,
									  &(localslot->tts_tid),
									  aestate->slot,
									  aestate->estate->es_snapshot,
									  &update_indexes);
			if (update_indexes)
#else
			simple_heap_update(rel->rel, &(TTS_TUP(localslot)->t_self),
							   TTS_TUP(aestate->slot));
			if (!HeapTupleIsHeapOnly(TTS_TUP(aestate->slot)))
#endif
				recheckIndexes = UserTableUpdateOpenIndexes(aestate->resultRelInfo,
															aestate->estate,
															aestate->slot,
															true);

			/* AFTER ROW UPDATE Triggers */
#if PG_VERSION_NUM >= 120000
			ExecARUpdateTriggers(aestate->estate, aestate->resultRelInfo,
								 &(TTS_TUP(localslot)->t_self),
								 NULL, aestate->slot, recheckIndexes);
#else
			ExecARUpdateTriggers(aestate->estate, aestate->resultRelInfo,
								 &(TTS_TUP(localslot)->t_self),
								 NULL, applytuple, recheckIndexes);
#endif
		}
	}
	else
	{
		/* Check the constraints of the tuple */
		if (rel->rel->rd_att->constr)
			ExecConstraints(aestate->resultRelInfo, aestate->slot,
							aestate->estate);

#if PG_VERSION_NUM >= 120000
		simple_table_tuple_insert(aestate->resultRelInfo->ri_RelationDesc, aestate->slot);
#else
		simple_heap_insert(rel->rel, TTS_TUP(aestate->slot));
#endif
		UserTableUpdateOpenIndexes(aestate->resultRelInfo, aestate->estate, aestate->slot, false);

		/* AFTER ROW INSERT Triggers */
#if PG_VERSION_NUM >= 120000
		ExecARInsertTriggers(aestate->estate, aestate->resultRelInfo,
							 aestate->slot, recheckIndexes);
#else
		ExecARInsertTriggers(aestate->estate, aestate->resultRelInfo,
							 remotetuple, recheckIndexes);
#endif
	}

	finish_apply_exec_state(aestate);

	CommandCounterIncrement();
}


/*
 * Handle update via low level api.
 */
void
spock_apply_heap_update(SpockRelation *rel, SpockTupleData *oldtup,
							SpockTupleData *newtup)
{
	ApplyExecState	   *aestate;
	bool				found;
	TupleTableSlot	   *localslot;
	HeapTuple			remotetuple;
	List			   *recheckIndexes = NIL;
	MemoryContext		oldctx;
	Oid					replident_idx_id;
	bool				has_before_triggers = false;

	/* Initialize the executor state. */
	aestate = init_apply_exec_state(rel);
#if PG_VERSION_NUM >= 120000
	localslot = table_slot_create(rel->rel, &aestate->estate->es_tupleTable);
#else
	localslot = ExecInitExtraTupleSlot(aestate->estate);
	ExecSetSlotDescriptor(localslot, RelationGetDescr(rel->rel));
#endif

	/* Search for existing tuple with same key */
	found = spock_tuple_find_replidx(aestate->resultRelInfo, oldtup, localslot,
										 &replident_idx_id);

	/*
	 * Tuple found, update the local tuple.
	 *
	 * Note this will fail if there are other unique indexes and one or more of
	 * them would be violated by the new tuple.
	 */
	if (found)
	{
		TransactionId	xmin;
		TimestampTz		local_ts;
		RepOriginId		local_origin;
		bool			local_origin_found;
		bool			apply;
		HeapTuple		applytuple;

		/* Process and store remote tuple in the slot */
		oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(aestate->estate));
		fill_missing_defaults(rel, aestate->estate, newtup);
		remotetuple = heap_modify_tuple(TTS_TUP(localslot),
										RelationGetDescr(rel->rel),
										newtup->values,
										newtup->nulls,
										newtup->changed);
		MemoryContextSwitchTo(oldctx);
		ExecStoreHeapTuple(remotetuple, aestate->slot, true);

		if (aestate->resultRelInfo->ri_TrigDesc &&
			aestate->resultRelInfo->ri_TrigDesc->trig_update_before_row)
		{
			has_before_triggers = true;

#if PG_VERSION_NUM >= 120000
			if (!ExecBRUpdateTriggers(aestate->estate,
									  &aestate->epqstate,
									  aestate->resultRelInfo,
									  &(TTS_TUP(localslot)->t_self),
									  NULL, aestate->slot))
#else
			aestate->slot = ExecBRUpdateTriggers(aestate->estate,
												 &aestate->epqstate,
												 aestate->resultRelInfo,
												 &(TTS_TUP(localslot)->t_self),
												 NULL, aestate->slot);

			if (aestate->slot == NULL)		/* "do nothing" */
#endif
			{
				finish_apply_exec_state(aestate);
				return;
			}
		}

		/* trigger might have changed tuple */
#if PG_VERSION_NUM >= 120000
		remotetuple = ExecFetchSlotHeapTuple(aestate->slot, true, NULL);
#else
		remotetuple = ExecMaterializeSlot(aestate->slot);
#endif
		local_origin_found = get_tuple_origin(TTS_TUP(localslot), &xmin,
											  &local_origin, &local_ts);

		/*
		 * If the local tuple was previously updated by different transaction
		 * on different server, consider this to be conflict and resolve it.
		 */
		if (local_origin_found &&
			xmin != GetTopTransactionId() &&
			local_origin != replorigin_session_origin)
		{
			SpockConflictResolution resolution;

			apply = try_resolve_conflict(rel->rel, TTS_TUP(localslot),
										 remotetuple, &applytuple,
										 &resolution);

			spock_report_conflict(CONFLICT_UPDATE_UPDATE, rel,
									  TTS_TUP(localslot), oldtup,
									  remotetuple, applytuple, resolution,
									  xmin, local_origin_found, local_origin,
									  local_ts, replident_idx_id,
									  has_before_triggers);

			if (applytuple != remotetuple)
				ExecStoreHeapTuple(applytuple, aestate->slot, false);
		}
		else
		{
			apply = true;
			applytuple = remotetuple;
		}

		if (apply)
		{
#if PG_VERSION_NUM >= 120000
			bool update_indexes;
#endif

			/* Check the constraints of the tuple */
			if (rel->rel->rd_att->constr)
				ExecConstraints(aestate->resultRelInfo, aestate->slot,
								aestate->estate);

#if PG_VERSION_NUM >= 120000
			simple_table_tuple_update(rel->rel,
									  &(localslot->tts_tid),
									  aestate->slot,
									  aestate->estate->es_snapshot,
									  &update_indexes);
			if (update_indexes)
#else
			simple_heap_update(rel->rel, &(TTS_TUP(localslot)->t_self),
							   TTS_TUP(aestate->slot));

			/* Only update indexes if it's not HOT update. */
			if (!HeapTupleIsHeapOnly(TTS_TUP(aestate->slot)))
#endif
			{
				ExecOpenIndices(aestate->resultRelInfo
#if PG_VERSION_NUM >= 90500
								, false
#endif
							   );
				recheckIndexes = UserTableUpdateOpenIndexes(aestate->resultRelInfo,
															aestate->estate,
															aestate->slot,
															true);
			}

			/* AFTER ROW UPDATE Triggers */
#if PG_VERSION_NUM >= 120000
			ExecARUpdateTriggers(aestate->estate, aestate->resultRelInfo,
								 &(TTS_TUP(localslot)->t_self),
								 NULL, aestate->slot, recheckIndexes);
#else
			ExecARUpdateTriggers(aestate->estate, aestate->resultRelInfo,
								 &(TTS_TUP(localslot)->t_self),
								 NULL, applytuple, recheckIndexes);
#endif
		}
	}
	else
	{
		/*
		 * The tuple to be updated could not be found.
		 *
		 * We can't do INSERT here because we might not have whole tuple.
		 */
		remotetuple = heap_form_tuple(RelationGetDescr(rel->rel),
									  newtup->values,
									  newtup->nulls);
		spock_report_conflict(CONFLICT_UPDATE_DELETE, rel, NULL, oldtup,
								  remotetuple, NULL, SpockResolution_Skip,
								  InvalidTransactionId, false,
								  InvalidRepOriginId, (TimestampTz)0,
								  replident_idx_id, has_before_triggers);
	}

	/* Cleanup. */
	finish_apply_exec_state(aestate);

	CommandCounterIncrement();
}

/*
 * Handle delete via low level api.
 */
void
spock_apply_heap_delete(SpockRelation *rel, SpockTupleData *oldtup)
{
	ApplyExecState	   *aestate;
	TupleTableSlot	   *localslot;
	Oid					replident_idx_id;
	bool				has_before_triggers = false;

	/* Initialize the executor state. */
	aestate = init_apply_exec_state(rel);
#if PG_VERSION_NUM >= 120000
	localslot = table_slot_create(rel->rel, &aestate->estate->es_tupleTable);
#else
	localslot = ExecInitExtraTupleSlot(aestate->estate);
	ExecSetSlotDescriptor(localslot, RelationGetDescr(rel->rel));
#endif

	if (spock_tuple_find_replidx(aestate->resultRelInfo, oldtup, localslot,
									 &replident_idx_id))
	{
		if (aestate->resultRelInfo->ri_TrigDesc &&
			aestate->resultRelInfo->ri_TrigDesc->trig_delete_before_row)
		{
			bool dodelete = ExecBRDeleteTriggers(aestate->estate,
												 &aestate->epqstate,
												 aestate->resultRelInfo,
												 &(TTS_TUP(localslot)->t_self),
												 NULL);

			has_before_triggers = true;

			if (!dodelete)		/* "do nothing" */
			{
				finish_apply_exec_state(aestate);
				return;
			}
		}

		/* Tuple found, delete it. */
		simple_heap_delete(rel->rel, &(TTS_TUP(localslot)->t_self));

		/* AFTER ROW DELETE Triggers */
		ExecARDeleteTriggers(aestate->estate, aestate->resultRelInfo,
							 &(TTS_TUP(localslot)->t_self), NULL);
	}
	else
	{
		/* The tuple to be deleted could not be found. */
		HeapTuple remotetuple = heap_form_tuple(RelationGetDescr(rel->rel),
												oldtup->values, oldtup->nulls);
		spock_report_conflict(CONFLICT_DELETE_DELETE, rel, NULL, oldtup,
								  remotetuple, NULL, SpockResolution_Skip,
								  InvalidTransactionId, false,
								  InvalidRepOriginId, (TimestampTz)0,
								  replident_idx_id, has_before_triggers);
	}

	/* Cleanup. */
	finish_apply_exec_state(aestate);

	CommandCounterIncrement();
}


bool
spock_apply_heap_can_mi(SpockRelation *rel)
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
	MemoryContext	oldctx;
	ApplyExecState *aestate;
	ResultRelInfo  *resultRelInfo;
	TupleDesc		desc;
	bool			volatile_defexprs = false;

	if (pglmistate && pglmistate->rel == rel)
		return;

	if (pglmistate && pglmistate->rel != rel)
		spock_apply_heap_mi_finish(pglmistate->rel);

	oldctx = MemoryContextSwitchTo(TopTransactionContext);

	/* Initialize new MultiInsert state. */
	pglmistate = palloc0(sizeof(ApplyMIState));

	pglmistate->rel = rel;

	/* Initialize the executor state. */
	pglmistate->aestate = aestate = init_apply_exec_state(rel);
	MemoryContextSwitchTo(TopTransactionContext);
	resultRelInfo = aestate->resultRelInfo;

	ExecOpenIndices(resultRelInfo
#if PG_VERSION_NUM >= 90500
					, false
#endif
					);

	/* Check if table has any volatile default expressions. */
	desc = RelationGetDescr(rel->rel);
	if (desc->natts != rel->natts)
	{
		int			attnum;

		for (attnum = 0; attnum < desc->natts; attnum++)
		{
			Expr	   *defexpr;

			if (TupleDescAttr(desc,attnum)->attisdropped)
				continue;

			defexpr = (Expr *) build_column_default(rel->rel, attnum + 1);

			if (defexpr != NULL)
			{
				/* Run the expression through planner */
				defexpr = expression_planner(defexpr);
				volatile_defexprs = contain_volatile_functions_not_nextval((Node *) defexpr);

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
		pglmistate->maxbuffered_tuples = 1;
	}
	else
	{
		pglmistate->maxbuffered_tuples = 1000;
	}

	pglmistate->cid = GetCurrentCommandId(true);
	pglmistate->bistate = GetBulkInsertState();

	/* Make the space for buffer. */
#if PG_VERSION_NUM >= 120000
	pglmistate->buffered_tuples = palloc0(pglmistate->maxbuffered_tuples * sizeof(TupleTableSlot *));
#else
	pglmistate->buffered_tuples = palloc0(pglmistate->maxbuffered_tuples * sizeof(HeapTuple));
#endif
	pglmistate->nbuffered_tuples = 0;

	MemoryContextSwitchTo(oldctx);
}

/* Write the buffered tuples. */
static void
spock_apply_heap_mi_flush(void)
{
	MemoryContext	oldctx;
	ResultRelInfo  *resultRelInfo;
	int				i;

	if (!pglmistate || pglmistate->nbuffered_tuples == 0)
		return;

	oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(pglmistate->aestate->estate));
	heap_multi_insert(pglmistate->rel->rel,
					  pglmistate->buffered_tuples,
					  pglmistate->nbuffered_tuples,
					  pglmistate->cid,
					  0, /* hi_options */
					  pglmistate->bistate);
	MemoryContextSwitchTo(oldctx);

	resultRelInfo = pglmistate->aestate->resultRelInfo;

	/*
	 * If there are any indexes, update them for all the inserted tuples, and
	 * run AFTER ROW INSERT triggers.
	 */
	if (resultRelInfo->ri_NumIndices > 0)
	{
		for (i = 0; i < pglmistate->nbuffered_tuples; i++)
		{
			List	   *recheckIndexes = NIL;

#if PG_VERSION_NUM < 120000
			ExecStoreTuple(pglmistate->buffered_tuples[i],
						   pglmistate->aestate->slot,
						   InvalidBuffer, false);
#endif
			recheckIndexes =
				ExecInsertIndexTuples(
#if PG_VERSION_NUM >= 140000
									  resultRelInfo,
#endif
#if PG_VERSION_NUM >= 120000
									  pglmistate->buffered_tuples[i],
#else
									  pglmistate->aestate->slot,
									  &(pglmistate->buffered_tuples[i]->t_self),
#endif
									  pglmistate->aestate->estate
#if PG_VERSION_NUM >= 90500
#if PG_VERSION_NUM >= 140000
									  , false
#endif
									  , false, NULL, NIL
#endif
									 );
			ExecARInsertTriggers(pglmistate->aestate->estate, resultRelInfo,
								 pglmistate->buffered_tuples[i],
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
		for (i = 0; i < pglmistate->nbuffered_tuples; i++)
		{
			ExecARInsertTriggers(pglmistate->aestate->estate, resultRelInfo,
								 pglmistate->buffered_tuples[i],
								 NIL);
		}
	}

	pglmistate->nbuffered_tuples = 0;
}

/* Add tuple to the MultiInsert. */
void
spock_apply_heap_mi_add_tuple(SpockRelation *rel,
								  SpockTupleData *tup)
{
	MemoryContext	oldctx;
	ApplyExecState *aestate;
	HeapTuple		remotetuple;
	TupleTableSlot *slot;

	spock_apply_heap_mi_start(rel);

	/*
	 * If sufficient work is pending, process that first
	 */
	if (pglmistate->nbuffered_tuples >= pglmistate->maxbuffered_tuples)
		spock_apply_heap_mi_flush();

	/* Process and store remote tuple in the slot */
	aestate = pglmistate->aestate;

	if (pglmistate->nbuffered_tuples == 0)
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
#if PG_VERSION_NUM >= 120000
		if (!ExecBRInsertTriggers(aestate->estate,
								 aestate->resultRelInfo,
								 slot))
#else
		slot = ExecBRInsertTriggers(aestate->estate,
									aestate->resultRelInfo,
									slot);

		if (slot == NULL)
#endif
		{
			MemoryContextSwitchTo(oldctx);
			return;
		}
#if PG_VERSION_NUM < 120000
		else
			remotetuple = ExecMaterializeSlot(slot);
#endif
	}

	/* Check the constraints of the tuple */
	if (rel->rel->rd_att->constr)
		ExecConstraints(aestate->resultRelInfo, slot,
						aestate->estate);

#if PG_VERSION_NUM >= 120000
	if (pglmistate->buffered_tuples[pglmistate->nbuffered_tuples] == NULL)
		pglmistate->buffered_tuples[pglmistate->nbuffered_tuples] = table_slot_create(rel->rel, NULL);
	else
		ExecClearTuple(pglmistate->buffered_tuples[pglmistate->nbuffered_tuples]);
	ExecCopySlot(pglmistate->buffered_tuples[pglmistate->nbuffered_tuples], slot);
#else
	pglmistate->buffered_tuples[pglmistate->nbuffered_tuples] = remotetuple;
#endif
	pglmistate->nbuffered_tuples++;
	MemoryContextSwitchTo(oldctx);
}

void
spock_apply_heap_mi_finish(SpockRelation *rel)
{
	if (!pglmistate)
		return;

	Assert(pglmistate->rel == rel);

	spock_apply_heap_mi_flush();

	FreeBulkInsertState(pglmistate->bistate);

	finish_apply_exec_state(pglmistate->aestate);

#if PG_VERSION_NUM >= 120000
	for (int i = 0; i < pglmistate->maxbuffered_tuples; i++)
		if (pglmistate->buffered_tuples[i])
			ExecDropSingleTupleTableSlot(pglmistate->buffered_tuples[i]);
#endif

	pfree(pglmistate->buffered_tuples);
	pfree(pglmistate);

	pglmistate = NULL;
}
