/*-------------------------------------------------------------------------
 *
 * spock_executor.c
 * 		spock executor related functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
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
#include "catalog/index.h"
#include "catalog/namespace.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_authid_d.h"
#include "catalog/pg_extension.h"
#include "catalog/pg_inherits.h"
#include "catalog/pg_type.h"

#include "commands/defrem.h"
#include "commands/extension.h"

#include "executor/executor.h"

#include "nodes/nodeFuncs.h"

#include "optimizer/optimizer.h"

#include "parser/analyze.h"
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

#include "spock_common.h"
#include "spock_node.h"
#include "spock_output_plugin.h" /* To check the output plugin state */
#include "spock_executor.h"
#include "spock_repset.h"
#include "spock_queue.h"
#include "spock_dependency.h"
#include "spock.h"


static DropBehavior	spock_lastDropBehavior = DROP_RESTRICT;
static bool			dropping_spock_obj = false;
static object_access_hook_type next_object_access_hook = NULL;

static ProcessUtility_hook_type next_ProcessUtility_hook = NULL;

static post_parse_analyze_hook_type prev_post_parse_analyze_hook;
static ExecutorStart_hook_type prev_executor_start_hook;

void spock_post_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate);
void spock_ExecutorStart(QueryDesc *queryDesc, int eflags);

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
	ExecInitRangeTable(estate, list_make1(rte), perminfos);

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
	econtext->ecxt_scantuple = ExecInitExtraTupleSlot(estate, NULL,
													  &TTSOpsHeapTuple);
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

/*
 * remove_table_from_repsets
 *		removes given table from the other replication sets.
 */
static void
remove_table_from_repsets(Oid nodeid, Oid reloid, bool only_for_update)
{
	ListCell *lc;
	List *repsets;

	repsets = get_table_replication_sets(nodeid, reloid);
	foreach(lc, repsets)
	{
		SpockRepSet	   *rs = (SpockRepSet *) lfirst(lc);

		if (only_for_update)
		{
			if (rs->replicate_update || rs->replicate_delete)
				replication_set_remove_table(rs->id, reloid, true);
		}
		else
			replication_set_remove_table(rs->id, reloid, true);
	}
}

/*
 * add_ddl_to_repset
 *		Check if the DDL statement can be added to the replication set. (For
 * now only tables are added). The function also checks whether the table has
 * needed indexes to be added to replication set. If not, they are ignored.
 */
static void
add_ddl_to_repset(Node *parsetree)
{
	Relation	targetrel;
	SpockRepSet *repset;
	SpockLocalNode *node;
	Oid		reloid = InvalidOid;
	RangeVar   *relation = NULL;
	List	   *reloids = NIL;
	ListCell   *lc;

	/* no need to proceed if spock_include_ddl_repset is off */
	if (!spock_include_ddl_repset)
		return;

	if (nodeTag(parsetree) == T_AlterTableStmt)
	{
		if (castNode(AlterTableStmt, parsetree)->objtype == OBJECT_TABLE)
			relation = castNode(AlterTableStmt, parsetree)->relation;
		else if (castNode(AlterTableStmt, parsetree)->objtype == OBJECT_INDEX)
		{
			ListCell *cell;
			AlterTableStmt *atstmt = (AlterTableStmt *) parsetree;

			foreach(cell, atstmt->cmds)
			{
				AlterTableCmd *cmd = (AlterTableCmd *) lfirst(cell);

				if (cmd->subtype == AT_AttachPartition)
				{
					RangeVar   *rv = castNode(AlterTableStmt, parsetree)->relation;
					Relation	indrel;

					indrel = relation_openrv(rv, AccessShareLock);
					reloid = IndexGetRelation(RelationGetRelid(indrel), false);
					table_close(indrel, NoLock);
				}
			}

			if (!OidIsValid(reloid))
				return;
		}
		else
		{
			return;
		}
	}
	else if (nodeTag(parsetree) == T_CreateStmt)
		relation = castNode(CreateStmt, parsetree)->relation;
	else if (nodeTag(parsetree) == T_CreateTableAsStmt &&
			 castNode(CreateTableAsStmt, parsetree)->objtype == OBJECT_TABLE)
		relation = castNode(CreateTableAsStmt, parsetree)->into->rel;
	else if (nodeTag(parsetree) == T_CreateSchemaStmt)
	{
		ListCell *cell;
		CreateSchemaStmt *cstmt = (CreateSchemaStmt *) parsetree;

		foreach(cell, cstmt->schemaElts)
		{
			if (nodeTag(lfirst(cell)) == T_CreateStmt)
				add_ddl_to_repset(lfirst(cell));
		}
		return;
	}
	else if (nodeTag(parsetree) == T_ExplainStmt)
	{
		ExplainStmt *stmt = (ExplainStmt *) parsetree;
		bool		analyze = false;
		ListCell   *cell;

		/* Look through an EXPLAIN ANALYZE to the contained stmt */
		foreach(cell, stmt->options)
		{
			DefElem    *opt = (DefElem *) lfirst(cell);

			if (strcmp(opt->defname, "analyze") == 0)
				analyze = defGetBoolean(opt);
			/* don't "break", as explain.c will use the last value */
		}

		if (analyze &&
			castNode(Query, stmt->query)->commandType == CMD_UTILITY)
			add_ddl_to_repset(castNode(Query, stmt->query)->utilityStmt);

		return;
	}
	else
	{
		/* only tables are added to repset. */
		return;
	}

	node = get_local_node(false, true);
	if (!node)
		return;

	if (OidIsValid(reloid))
		targetrel = RelationIdGetRelation(reloid);
	else
		targetrel = table_openrv(relation, AccessShareLock);

	reloid = RelationGetRelid(targetrel);

	if (targetrel->rd_rel->relkind == RELKIND_PARTITIONED_TABLE)
		reloids = find_all_inheritors(reloid, NoLock, NULL);
	else
		reloids = lappend_oid(reloids, reloid);
	table_close(targetrel, NoLock);

	foreach (lc, reloids)
	{
		reloid = lfirst_oid(lc);
		targetrel = RelationIdGetRelation(reloid);

		/* UNLOGGED and TEMP relations cannot be part of replication set. */
		if (!RelationNeedsWAL(targetrel))
		{
			/* remove table from the repsets. */
			remove_table_from_repsets(node->node->id, reloid, false);

			table_close(targetrel, NoLock);
			return;
		}

		if (targetrel->rd_indexvalid == 0)
			RelationGetIndexList(targetrel);

		/* choose the 'default' repset, if table has PK or replica identity defined. */
		if (OidIsValid(targetrel->rd_pkindex) || OidIsValid(targetrel->rd_replidindex))
		{
			repset = get_replication_set_by_name(node->node->id, DEFAULT_REPSET_NAME, false);

			/*
			 * remove table from previous repsets, it will be added to 'default'
			 * down below.
			 */
			remove_table_from_repsets(node->node->id, reloid, false);
		}
		else
		{
			repset = get_replication_set_by_name(node->node->id, DEFAULT_INSONLY_REPSET_NAME, false);
			/*
			 * no primary key defined. let's see if the table is part of any other
			 * repset or not?
			 */
			remove_table_from_repsets(node->node->id, reloid, true);
		}

		if (!OidIsValid(targetrel->rd_replidindex) &&
			(repset->replicate_update || repset->replicate_delete))
		{
			table_close(targetrel, NoLock);
			return;
		}

		table_close(targetrel, NoLock);

		/* Add if not already present. */
		if (get_table_replication_row(repset->id, reloid, NULL, NULL) == NULL)
		{
			replication_set_add_table(repset->id, reloid, NIL, NULL);

			elog(LOG, "table '%s' was added to '%s' replication set.",
				 get_rel_name(reloid), repset->name);
		}
	}
}

static bool
autoddl_can_proceed(ProcessUtilityContext context, NodeTag toplevel_stmt,
					NodeTag stmt)
{
	if (spock_replication_repair_mode)
		/*
		 * Repair mode means that nothing happened in this state should be
		 * decoded and sent to any subscriber.
		 */
		return false;

	/* Allow all toplevel statements. */
	if (context == PROCESS_UTILITY_TOPLEVEL)
		return true;

	/* Guard against CREATE EXTENSION subcommands */
	if (creating_extension)
		return false;

	/*
	 * Indicates a portion of a query. These statements should be handled by the
	 * corresponding top-level query.
	 */
	if (context == PROCESS_UTILITY_SUBCOMMAND)
		return false;

	/*
	 * When the ProcessUtility hook is invoked due to a function call (enabled
	 * by allow_ddl_from_functions) or a query from the queue (with
	 * in_spock_queue_ddl_command set to true), the context is rarely
	 * PROCESS_UTILITY_TOPLEVEL. Handling the context when it is
	 * PROCESS_UTILITY_TOPLEVEL is straightforward. In other cases, our
	 * objective is to filter out CREATE|DROP EXTENSION and CREATE SCHEMA
	 * statements, which execute scripts or subcommands lacking top-level
	 * status. Therefore, we need to filter out these internal commands.
	 *
	 * The purpose of this filtering is to include only the main statement (or
	 * query provided by the client) in autoddl. To achieve this, we store the
	 * nodetag of these statements in 'toplevel_stmt' and verify if the
	 * current statement matches it. If not, it indicates the invocation of
	 * subcommands, which we disregard.
	 *
	 * All other statements are allowed without filtering.
	 */
	if (context != PROCESS_UTILITY_TOPLEVEL &&
		(allow_ddl_from_functions || in_spock_queue_ddl_command))
	{
		if (toplevel_stmt != T_Invalid)
			return toplevel_stmt == stmt;

		return true;
	}

	return false;
}

static void
spock_ProcessUtility(
						 PlannedStmt *pstmt,
						 const char *queryString,
						 bool readOnlyTree,
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
	static NodeTag toplevel_stmt = T_Invalid;
#ifndef XCP
	#define		sentToRemote NULL
#endif
	Oid			roleoid = InvalidOid;
	Oid			save_userid = 0;
	int			save_sec_context = 0;

	dropping_spock_obj = false;

	if (spock_deny_ddl && GetCommandLogLevel(parsetree) == LOGSTMT_DDL)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("cannot execute %s within spock cluster",
						CreateCommandName(parsetree))));
	}

	if (nodeTag(parsetree) == T_DropStmt)
	{
		/*
		 * Allow one to drop replication tables without specifying the CASCADE
		 * option when in auto ddl replication mode.
		 */
		if (spock_enable_ddl_replication || in_spock_queue_ddl_command)
			spock_lastDropBehavior = DROP_CASCADE;
		else
			spock_lastDropBehavior = ((DropStmt *)parsetree)->behavior;
	}

	/*
	 * When the context is not PROCESS_UTILITY_TOPLEVEL, it becomes
	 * challenging to differentiate between scripted commands and subcommands
	 * generated as a result of CREATE|DROP EXTENSION and CREATE SCHEMA
	 * statements. In autoddl, we only include statements that directly
	 * originate from the client. To accomplish this, we store the nodetag of
	 * the top-level statements for later comparison in the
	 * autoddl_can_proceed() function. If the tags do not match, it indicates
	 * that the statement did not originate from the client but rather is a
	 * subcommand generated internally.
	 */
	if (nodeTag(parsetree) == T_CreateExtensionStmt ||
		nodeTag(parsetree) == T_CreateSchemaStmt ||
		(nodeTag(parsetree) == T_DropStmt &&
		 castNode(DropStmt, parsetree)->removeType == OBJECT_EXTENSION))
		toplevel_stmt = nodeTag(parsetree);

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

	roleoid = GetUserId();

	/*
	 * Check that we have a local node. We need to elevate access
	 * because this is called as an executor Utility hook under the
	 * session user, who not necessarily has access permission to
	 * Spock extension objects.
	 */
	GetUserIdAndSecContext(&save_userid, &save_sec_context);
	SetUserIdAndSecContext(BOOTSTRAP_SUPERUSERID,
							save_sec_context | SECURITY_LOCAL_USERID_CHANGE);

	/*
	 * we don't want to replicate if it's coming from spock.queue. But we do
	 * add tables to repset whenever there is one.
	 */
	if (in_spock_queue_ddl_command || in_spock_replicate_ddl_command)
	{
		/* if DDL is from spoc.queue, add it to the repset. */
		if (in_spock_queue_ddl_command &&
			autoddl_can_proceed(context, toplevel_stmt, nodeTag(parsetree)))
		{
			toplevel_stmt = T_Invalid;
			add_ddl_to_repset(parsetree);
		}

		/*
		 * Do Nothing else. Hook was called as a result of spock.replicate_ddl().
		 * The action has already been taken, so no need for the duplication.
		 */
	}
	else if (GetCommandLogLevel(parsetree) == LOGSTMT_DDL &&
			 spock_enable_ddl_replication &&
			 get_local_node(false, true))
	{
		if (autoddl_can_proceed(context, toplevel_stmt, nodeTag(parsetree)))
		{
			const char *curr_qry;
			int			loc = pstmt->stmt_location;
			int			len = pstmt->stmt_len;

			toplevel_stmt = T_Invalid;
			queryString = CleanQuerytext(queryString, &loc, &len);
			curr_qry = pnstrdup(queryString, len);

			spock_auto_replicate_ddl(curr_qry,
									 list_make1(DEFAULT_INSONLY_REPSET_NAME),
									 roleoid,
									 parsetree);

			add_ddl_to_repset(parsetree);
		}
	}
	/* Restore previous session privileges */
	SetUserIdAndSecContext(save_userid, save_sec_context);
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

	prev_post_parse_analyze_hook = post_parse_analyze_hook;
	post_parse_analyze_hook = spock_post_parse_analyze;

	prev_executor_start_hook = ExecutorStart_hook;
	ExecutorStart_hook = spock_ExecutorStart;
}

void
spock_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	spock_roExecutorStart(queryDesc, eflags);

    if (prev_executor_start_hook)
		prev_executor_start_hook(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);
}

void
spock_post_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate)
{
	spock_ropost_parse_analyze(pstate, query, jstate);

	if (prev_post_parse_analyze_hook)
		prev_post_parse_analyze_hook(pstate, query, jstate);
}
