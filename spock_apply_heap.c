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
#include "optimizer/optimizer.h"

#include "replication/origin.h"
#include "replication/reorderbuffer.h"

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

	TupleTableSlot	  **buffered_tuples;
	int					maxbuffered_tuples;
	int					nbuffered_tuples;
} ApplyMIState;


#define TTS_TUP(slot) (((HeapTupleTableSlot *)slot)->tuple)

static ApplyMIState *spkmistate = NULL;

static bool relation_has_delta_columns(SpockRelation *rel);
static void build_delta_tuple(SpockRelation *rel, SpockTupleData *oldtup,
							  SpockTupleData *newtup, SpockTupleData *deltatup,
							  TupleTableSlot *localslot);

void
spock_apply_heap_begin(void)
{
	spock_cth_prune(false);
}

void
spock_apply_heap_commit(void)
{
	TimestampTz	next_prune;
	TimestampTz	now;
	int32		num_pruned;

	/*
	 * For pruning of the Conflict Tracking Hash we remember our
	 * assigned origin and the last commit timestamp.
	 */
	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
	if (MySpockWorker->worker.apply.replorigin != replorigin_session_origin)
	{
		if (MySpockWorker->worker.apply.replorigin != InvalidRepOriginId)
			/* This should never happen */
			elog(LOG, "SPOCK: remote origin id changes from %d to %d",
				 MySpockWorker->worker.apply.replorigin,
				 replorigin_session_origin);
		MySpockWorker->worker.apply.replorigin = replorigin_session_origin;
	}
	MySpockWorker->worker.apply.last_ts = replorigin_session_origin_timestamp;
	LWLockRelease(SpockCtx->lock);

	next_prune = TimestampTzPlusMilliseconds(SpockCtx->ctt_last_prune,
											 SpockCtx->ctt_prune_interval * 1000);
	now = GetCurrentTimestamp();
	if (next_prune <= now)
	{
		SpockCtx->ctt_last_prune = now;

		PushActiveSnapshot(GetTransactionSnapshot());
		num_pruned = spock_ctt_prune(false);
		PopActiveSnapshot();
        CommandCounterIncrement();

		elog(DEBUG1, "SPOCK: %d entries pruned from CTT", num_pruned);
	}

	spock_ctt_close();
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
											   estate
#if PG_VERSION_NUM >= 140000
											   , update
#endif
											   , false, NULL, NIL
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

static bool
relation_has_delta_columns(SpockRelation *rel)
{
	TupleDesc			tupdesc = RelationGetDescr(rel->rel);
	AttributeOpts	   *aopt;
	int					attno;

	for (attno = 1; attno <= tupdesc->natts; attno++)
	{
		/* check the attribute options */
		aopt = get_attribute_options(rel->rel->rd_id, attno);
		if (aopt != NULL && aopt->log_old_value)
			return true;
	}

	return false;
}

static void
build_delta_tuple(SpockRelation *rel, SpockTupleData *oldtup,
				  SpockTupleData *newtup,
				  SpockTupleData *deltatup,
				  TupleTableSlot *localslot)
{
	TupleDesc			tupdesc = RelationGetDescr(rel->rel);
	Form_pg_attribute	att;
	AttributeOpts	   *aopt;
	int					attidx;
	Datum				loc_value;
	Datum				delta;
	bool				loc_isnull;
	PGFunction			func_add;
	PGFunction			func_sub;

	for (attidx = 0; attidx < tupdesc->natts; attidx++)
	{
		/* Get the attribute options */
		aopt = get_attribute_options(rel->rel->rd_id, attidx + 1);
		if (aopt == NULL || !aopt->log_old_value)
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
		att = TupleDescAttr(tupdesc, attidx);
		switch (att->atttypid)
		{
			case INT4OID:
				func_add = int4pl;
				func_sub = int4mi;
				break;

			case INT8OID:
				func_add = int8pl;
				func_sub = int8mi;
				break;

			case NUMERICOID:
				func_add = numeric_add;
				func_sub = numeric_sub;
				break;

			default:
				elog(ERROR, "spock delta replication for type %d not supported",
					 att->atttypid);
		}

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
			/* We also need the old value of the current local tuple */
			loc_value = heap_getattr(TTS_TUP(localslot), attidx + 1, tupdesc,
									 &loc_isnull);

			/* Finally we can do the actual delta apply */
			delta = DirectFunctionCall2(func_sub,
										newtup->values[attidx],
										oldtup->values[attidx]);
			deltatup->values[attidx] = DirectFunctionCall2(func_add, loc_value,
															delta);
			deltatup->nulls[attidx] = false;
			deltatup->changed[attidx] = true;
		}
	}
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
	localslot = table_slot_create(rel->rel, &aestate->estate->es_tupleTable);

	/* update stats */
	handle_stats_counter(rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_INSERT_COUNT, 1);

	ExecOpenIndices(aestate->resultRelInfo
					, false
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

		if (!ExecBRInsertTriggers(aestate->estate,
								  aestate->resultRelInfo,
								  aestate->slot))
		{
			finish_apply_exec_state(aestate);
			return;
		}

	}

	/* trigger might have changed tuple */
	remotetuple = ExecFetchSlotHeapTuple(aestate->slot, true, NULL);

	/* Did we find matching key in any candidate-key index? */
	if (OidIsValid(conflicts_idx_id))
	{
		TransactionId		xmin;
		TimestampTz			local_ts;
		RepOriginId			local_origin;
		bool				apply;
		bool				local_origin_found;

		local_origin_found = get_tuple_origin(RelationGetRelid(rel->rel),
											  TTS_TUP(localslot),
											  NULL, &xmin,
											  &local_origin, &local_ts);

		/* Tuple already exists, try resolving conflict. */
		apply = try_resolve_conflict(rel->rel, TTS_TUP(localslot),
									 remotetuple, &applytuple,
									 local_origin, local_ts,
									 &resolution);

		spock_report_conflict(CONFLICT_INSERT_INSERT, rel,
								  TTS_TUP(localslot), NULL, remotetuple,
								  applytuple, resolution, xmin,
								  local_origin_found, local_origin,
								  local_ts, conflicts_idx_id,
								  has_before_triggers);

		if (apply)
		{
			bool update_indexes;

			if (applytuple != remotetuple)
				ExecStoreHeapTuple(applytuple, aestate->slot, false);

			if (aestate->resultRelInfo->ri_TrigDesc &&
				aestate->resultRelInfo->ri_TrigDesc->trig_update_before_row)
			{
				if (!ExecBRUpdateTriggers(aestate->estate,
										  &aestate->epqstate,
										  aestate->resultRelInfo,
										  &(TTS_TUP(localslot)->t_self),
										  NULL,
										  aestate->slot))
				{
					finish_apply_exec_state(aestate);
					return;
				}

			}

			/* trigger might have changed tuple */
			remotetuple = ExecFetchSlotHeapTuple(aestate->slot, true, NULL);

			/* Check the constraints of the tuple */
			if (rel->rel->rd_att->constr)
				ExecConstraints(aestate->resultRelInfo, aestate->slot,
								aestate->estate);

			simple_table_tuple_update(rel->rel,
									  &(localslot->tts_tid),
									  aestate->slot,
									  aestate->estate->es_snapshot,
									  &update_indexes);
			if (update_indexes)
				recheckIndexes = UserTableUpdateOpenIndexes(aestate->resultRelInfo,
															aestate->estate,
															aestate->slot,
															true);

			/* AFTER ROW UPDATE Triggers */
			ExecARUpdateTriggers(aestate->estate, aestate->resultRelInfo,
								 &(TTS_TUP(localslot)->t_self),
								 NULL, aestate->slot, recheckIndexes);
		}
	}
	else
	{
		/* Check the constraints of the tuple */
		if (rel->rel->rd_att->constr)
			ExecConstraints(aestate->resultRelInfo, aestate->slot,
							aestate->estate);

		simple_table_tuple_insert(aestate->resultRelInfo->ri_RelationDesc, aestate->slot);
		UserTableUpdateOpenIndexes(aestate->resultRelInfo, aestate->estate, aestate->slot, false);

		/* AFTER ROW INSERT Triggers */
		ExecARInsertTriggers(aestate->estate, aestate->resultRelInfo,
							 aestate->slot, recheckIndexes);
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
	bool				is_delta_apply = false;

	/* Initialize the executor state. */
	aestate = init_apply_exec_state(rel);
	localslot = table_slot_create(rel->rel, &aestate->estate->es_tupleTable);

	/* update stats */
	handle_stats_counter(rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_UPDATE_COUNT, 1);

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

			if (!ExecBRUpdateTriggers(aestate->estate,
									  &aestate->epqstate,
									  aestate->resultRelInfo,
									  &(TTS_TUP(localslot)->t_self),
									  NULL, aestate->slot))
			{
				finish_apply_exec_state(aestate);
				return;
			}
		}

		/* trigger might have changed tuple */
		remotetuple = ExecFetchSlotHeapTuple(aestate->slot, true, NULL);
		local_origin_found = get_tuple_origin(RelationGetRelid(rel->rel),
											  TTS_TUP(localslot),
											  &(localslot->tts_tid), &xmin,
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
										 local_origin, local_ts,
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

		/*
		 * If the relation has columns that are marked LOG_OLD_VALUE
		 * we apply the delta between the remote new and old values.
		 */
		if (relation_has_delta_columns(rel))
		{
			SpockTupleData	deltatup;
			HeapTuple		currenttuple;

			currenttuple = ExecFetchSlotHeapTuple(aestate->slot, true, NULL);
			oldctx = MemoryContextSwitchTo(GetPerTupleMemoryContext(aestate->estate));
			build_delta_tuple(rel, oldtup, newtup, &deltatup, localslot);
			applytuple = heap_modify_tuple(currenttuple,
										   RelationGetDescr(rel->rel),
										   deltatup.values,
										   deltatup.nulls,
										   deltatup.changed);
			MemoryContextSwitchTo(oldctx);
			ExecStoreHeapTuple(applytuple, aestate->slot, true);

			if (!apply)
			{
				is_delta_apply = true;
				apply = true;

				/* Count the DCA event in stats */
				handle_stats_counter(rel->rel, MyApplyWorker->subid,
									 SPOCK_STATS_DCA_COUNT, 1);
			}
		}

		if (apply)
		{
			bool update_indexes;
			/* Check the constraints of the tuple */
			if (rel->rel->rd_att->constr)
				ExecConstraints(aestate->resultRelInfo, aestate->slot,
								aestate->estate);

			simple_table_tuple_update(rel->rel,
									  &(localslot->tts_tid),
									  aestate->slot,
									  aestate->estate->es_snapshot,
									  &update_indexes);
			if (update_indexes)
			{
				ExecOpenIndices(aestate->resultRelInfo
								, false
							   );
				recheckIndexes = UserTableUpdateOpenIndexes(aestate->resultRelInfo,
															aestate->estate,
															aestate->slot,
															true);
			}

			if (is_delta_apply)
			{
				/*
				 * We forced an update to a row that we normally had
				 * to skip because it has delta resolve columns. Remember
				 * the correct origin, xmin and commit timestamp for
				 * get_tuple_origion() to figure it out.
				 */
				spock_cth_store(RelationGetRelid(rel->rel),
								&(aestate->slot->tts_tid), local_origin,
								GetTopTransactionId(), local_ts, false);
			}

			/* AFTER ROW UPDATE Triggers */
			ExecARUpdateTriggers(aestate->estate, aestate->resultRelInfo,
								 &(TTS_TUP(localslot)->t_self),
								 NULL, aestate->slot, recheckIndexes);
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
	localslot = table_slot_create(rel->rel, &aestate->estate->es_tupleTable);

	/* update stats */
	handle_stats_counter(rel->rel, MyApplyWorker->subid,
						 SPOCK_STATS_DELETE_COUNT, 1);

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

	ExecOpenIndices(resultRelInfo
					, false
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
	MemoryContext	oldctx;
	ResultRelInfo  *resultRelInfo;
	int				i;

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
			List	   *recheckIndexes = NIL;

			recheckIndexes =
				ExecInsertIndexTuples(
#if PG_VERSION_NUM >= 140000
									  resultRelInfo,
#endif
									  spkmistate->buffered_tuples[i],
									  spkmistate->aestate->estate
#if PG_VERSION_NUM >= 140000
									  , false
#endif
                                                                          , false, NULL, NIL
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

void
spock_apply_heap_mi_finish(SpockRelation *rel)
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
