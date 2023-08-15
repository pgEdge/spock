/*-------------------------------------------------------------------------
 *
 * spock_executor.c
 * 		spock executor related functions
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"

#include "access/hash.h"
#include "access/htup_details.h"
#include "access/xact.h"
#include "access/xlog.h"

#include "catalog/dependency.h"
#include "catalog/namespace.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_authid_d.h"
#include "catalog/pg_extension.h"
#include "catalog/pg_type.h"

#include "commands/extension.h"
#include "commands/trigger.h"

#include "executor/executor.h"

#include "nodes/nodeFuncs.h"

#include "optimizer/optimizer.h"

#include "parser/parse_coerce.h"
#include "parser/parse_relation.h"

#include "tcop/utility.h"

#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/json.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#include "spock_node.h"
#include "spock_executor.h"
#include "spock_repset.h"
#include "spock_queue.h"
#include "spock_dependency.h"
#include "spock.h"

List *spock_truncated_tables = NIL;

static DropBehavior	spock_lastDropBehavior = DROP_RESTRICT;
static bool			dropping_spock_obj = false;
static object_access_hook_type next_object_access_hook = NULL;

static ProcessUtility_hook_type next_ProcessUtility_hook = NULL;

EState *
create_estate_for_relation(Relation rel, bool forwrite)
{
	EState	   *estate;
	RangeTblEntry *rte;
	List	   *perminfos = NIL;

	/* Dummy range table entry needed by executor. */
	rte = makeNode(RangeTblEntry);
	rte->rtekind = RTE_RELATION;
	rte->relid = RelationGetRelid(rel);
	rte->relkind = rel->rd_rel->relkind;

	/* Initialize executor state. */
	estate = CreateExecutorState();

	addRTEPermissionInfo(&perminfos, rte);
	ExecInitRangeTable(estate, list_make1(rte)
#if PG_VERSION_NUM >= 160000
		, perminfos
#endif
		);

	estate->es_output_cid = GetCurrentCommandId(forwrite);

	return estate;
}

ExprContext *
prepare_per_tuple_econtext(EState *estate, TupleDesc tupdesc)
{
	ExprContext	   *econtext;
	MemoryContext	oldContext;

	econtext = GetPerTupleExprContext(estate);

	oldContext = MemoryContextSwitchTo(estate->es_query_cxt);
	econtext->ecxt_scantuple = ExecInitExtraTupleSlot(estate);
	MemoryContextSwitchTo(oldContext);

	ExecSetSlotDescriptor(econtext->ecxt_scantuple, tupdesc);

	return econtext;
}

ExprState *
spock_prepare_row_filter(Node *row_filter)
{
	ExprState  *exprstate;
	Expr	   *expr;
	Oid			exprtype;

	exprtype = exprType(row_filter);
	expr = (Expr *) coerce_to_target_type(NULL,	/* no UNKNOWN params here */
										  row_filter, exprtype,
										  BOOLOID, -1,
										  COERCION_ASSIGNMENT,
										  COERCE_IMPLICIT_CAST,
										  -1);

	/* This should never happen but just to be sure. */
	if (expr == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("cannot cast the row_filter to boolean"),
			   errhint("You will need to rewrite the row_filter.")));

	expr = expression_planner(expr);
	exprstate = ExecInitExpr(expr, NULL);

	return exprstate;
}

static void
spock_start_truncate(void)
{
	spock_truncated_tables = NIL;
}

static void
spock_finish_truncate(void)
{
	ListCell	   *tlc;
	SpockLocalNode *local_node;
	Oid				session_userid = GetUserId();
	Oid				save_userid = 0;
	int				save_sec_context = 0;

	/* Elevate permissions to access spock objects */
	GetUserIdAndSecContext(&save_userid, &save_sec_context);
	SetUserIdAndSecContext(BOOTSTRAP_SUPERUSERID,
						   save_sec_context | SECURITY_LOCAL_USERID_CHANGE);

	/* If this is not a spock node, don't do anything. */
	local_node = get_local_node(false, true);
	if (!local_node || !list_length(spock_truncated_tables))
	{
		SetUserIdAndSecContext(save_userid, save_sec_context);
		return;
	}

	foreach (tlc, spock_truncated_tables)
	{
		Oid			reloid = lfirst_oid(tlc);
		char	   *nspname;
		char	   *relname;
		List	   *repsets;
		StringInfoData	json;

		/* Format the query. */
		nspname = get_namespace_name(get_rel_namespace(reloid));
		relname = get_rel_name(reloid);

		elog(DEBUG3, "truncating the table %s.%s", nspname, relname);

		/* It's easier to construct json manually than via Jsonb API... */
		initStringInfo(&json);
		appendStringInfo(&json, "{\"schema_name\": ");
		escape_json(&json, nspname);
		appendStringInfo(&json, ",\"table_name\": ");
		escape_json(&json, relname);
		appendStringInfo(&json, "}");

		repsets = get_table_replication_sets(local_node->node->id, reloid);

		if (list_length(repsets))
		{
			List	   *repset_names = NIL;
			ListCell   *rlc;

			foreach (rlc, repsets)
			{
				SpockRepSet	    *repset = (SpockRepSet *) lfirst(rlc);
				repset_names = lappend(repset_names, pstrdup(repset->name));
				elog(DEBUG1, "truncating the table %s.%s for %s repset",
					 nspname, relname, repset->name);
			}

			/* Queue the truncate for replication. */
			queue_message(repset_names, session_userid,
						  QUEUE_COMMAND_TYPE_TRUNCATE, json.data);
		}
	}

	/* Restore original session permissions */
	SetUserIdAndSecContext(save_userid, save_sec_context);

	list_free(spock_truncated_tables);
	spock_truncated_tables = NIL;
}

static void
spock_ProcessUtility(
						 PlannedStmt *pstmt,
						 const char *queryString,
#if PG_VERSION_NUM >= 140000
						 bool readOnlyTree,
#endif
						 ProcessUtilityContext context,
						 ParamListInfo params,
						 QueryEnvironment *queryEnv,
						 DestReceiver *dest,
#ifdef XCP
						 bool sentToRemote,
#endif
						 QueryCompletion *qc)
{
	Node	   *parsetree = pstmt->utilityStmt;
#ifndef XCP
	#define		sentToRemote NULL
#endif

	dropping_spock_obj = false;

	if (spock_deny_ddl && GetCommandLogLevel(parsetree) == LOGSTMT_DDL)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("cannot execute %s within spock cluster",
						CreateCommandName(parsetree))));
	}

	if (nodeTag(parsetree) == T_TruncateStmt)
		spock_start_truncate();

	if (nodeTag(parsetree) == T_DropStmt)
		spock_lastDropBehavior = ((DropStmt *)parsetree)->behavior;

	/* There's no reason we should be in a long lived context here */
	Assert(CurrentMemoryContext != TopMemoryContext
		   && CurrentMemoryContext != CacheMemoryContext);

	if (next_ProcessUtility_hook)
		SPKnext_ProcessUtility_hook(pstmt, queryString, readOnlyTree, context, params,
									queryEnv, dest,
									sentToRemote,
									qc);
	else
		SPKstandard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params,
								   queryEnv, dest,
								   sentToRemote,
								   qc);

	if (nodeTag(parsetree) == T_TruncateStmt)
		spock_finish_truncate();
}


/*
 * Handle object drop.
 *
 * Calls to dependency tracking code.
 */
static void
spock_object_access(ObjectAccessType access,
						Oid classId,
						Oid objectId,
						int subId,
						void *arg)
{
	Oid		save_userid = 0;
	int		save_sec_context = 0;

	if (next_object_access_hook)
		(*next_object_access_hook) (access, classId, objectId, subId, arg);

	if (access == OAT_DROP)
	{
		ObjectAccessDrop   *drop_arg = (ObjectAccessDrop *) arg;
		ObjectAddress		object;
		DropBehavior		behavior;

		/* No need to check for internal deletions. */
		if ((drop_arg->dropflags & PERFORM_DELETION_INTERNAL) != 0)
			return;

		/* Dropping spock itself? */
		if (classId == ExtensionRelationId &&
			objectId == get_extension_oid(EXTENSION_NAME, true) &&
			objectId != InvalidOid /* Should not happen but check anyway */)
			dropping_spock_obj = true;

		/* Dropping relation within spock? */
		if (classId == RelationRelationId)
		{
			Oid			relnspoid;
			Oid			spknspoid;

			spknspoid = get_namespace_oid(EXTENSION_NAME, true);
			relnspoid = get_rel_namespace(objectId);

			if (spknspoid == relnspoid)
				dropping_spock_obj = true;
		}

		/*
		 * Don't do extra dependency checks for internal objects, those
		 * should be handled by Postgres.
		 */
		if (dropping_spock_obj)
			return;

		/*
		 * Check that we have a local node. We need to elevate access
		 * because this is called as an executor DROP hook under the
		 * session user, who not necessarily has access permission to
		 * Spock extension objects.
		 */
		GetUserIdAndSecContext(&save_userid, &save_sec_context);
		SetUserIdAndSecContext(BOOTSTRAP_SUPERUSERID,
							   save_sec_context | SECURITY_LOCAL_USERID_CHANGE);
		if(!get_local_node(false, true))
		{
			SetUserIdAndSecContext(save_userid, save_sec_context);
			return;
		}

		ObjectAddressSubSet(object, classId, objectId, subId);

		if (SessionReplicationRole == SESSION_REPLICATION_ROLE_REPLICA)
			behavior = DROP_CASCADE;
		else
			behavior = spock_lastDropBehavior;

		spock_checkDependency(&object, behavior);

		/* Restore previous session privileges */
		SetUserIdAndSecContext(save_userid, save_sec_context);
	}
}

void
spock_executor_init(void)
{
	next_ProcessUtility_hook = ProcessUtility_hook;
	ProcessUtility_hook = spock_ProcessUtility;

	/* Object access hook */
	next_object_access_hook = object_access_hook;
	object_access_hook = spock_object_access;
}
