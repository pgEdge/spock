/*-------------------------------------------------------------------------
 *
 * spock_autoddl.c
 * 		spock autoddl replication support
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/relation.h"
#include "access/table.h"

#include "catalog/index.h"
#include "catalog/namespace.h"
#include "catalog/pg_authid_d.h"
#include "catalog/pg_inherits.h"

#include "commands/defrem.h"
#include "commands/extension.h"

#include "tcop/utility.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"

#include "spock_autoddl.h"
#include "spock_executor.h"
#include "spock_queue.h"
#include "spock_repset.h"
#include "spock_node.h"
#include "spock_output_plugin.h"
#include "spock.h"

static void remove_table_from_repsets(Oid nodeid, Oid reloid, bool only_for_update);
static void add_ddl_to_repset(Node *parsetree);
static bool autoddl_can_proceed(ProcessUtilityContext context, NodeTag toplevel_stmt, NodeTag stmt);

/*
 * spock_autoddl_process
 *
 * Central entrypoint for AutoDDL. Keep the executor hook thin; all policy and
 * privilege handling lives here.
 *
 * Filter utility statements for DDL replication, apply Spock's DDL policy
 * (routing, filtering, privilege elevation), replicate qualifying DDL, and
 * warn/error on disallowed cases.
 */
void
spock_autoddl_process(PlannedStmt *pstmt,
					  const char *queryString,
					  ProcessUtilityContext context,
					  NodeTag *toplevel_stmt)
{
	Oid			roleoid = InvalidOid;
	Oid			save_userid = 0;
	int			save_sec_context = 0;
	Node	   *parsetree = pstmt->utilityStmt;

	roleoid = GetUserId();

	/*
	 * Check that we have a local node. We need to elevate access because this
	 * is called as an executor Utility hook under the session user, who not
	 * necessarily has access permission to Spock extension objects.
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
			autoddl_can_proceed(context, *toplevel_stmt, nodeTag(parsetree)))
		{
			*toplevel_stmt = T_Invalid;
			add_ddl_to_repset(parsetree);
		}

		/*
		 * Do Nothing else. Hook was called as a result of
		 * spock.replicate_ddl(). The action has already been taken, so no
		 * need for the duplication.
		 */
	}
	else if (GetCommandLogLevel(parsetree) == LOGSTMT_DDL &&
			 spock_enable_ddl_replication &&
			 get_local_node(false, true))
	{
		if (autoddl_can_proceed(context, *toplevel_stmt, nodeTag(parsetree)))
		{
			const char *curr_qry;
			int			loc = pstmt->stmt_location;
			int			len = pstmt->stmt_len;

			*toplevel_stmt = T_Invalid;
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
	Oid			reloid = InvalidOid;
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
			ListCell   *cell;
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
		ListCell   *cell;
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

	foreach(lc, reloids)
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

		/*
		 * choose the 'default' repset, if table has PK or replica identity
		 * defined.
		 */
		if (OidIsValid(targetrel->rd_pkindex) || OidIsValid(targetrel->rd_replidindex))
		{
			repset = get_replication_set_by_name(node->node->id, DEFAULT_REPSET_NAME, false);

			/*
			 * remove table from previous repsets, it will be added to
			 * 'default' down below.
			 */
			remove_table_from_repsets(node->node->id, reloid, false);
		}
		else
		{
			repset = get_replication_set_by_name(node->node->id, DEFAULT_INSONLY_REPSET_NAME, false);

			/*
			 * no primary key defined. let's see if the table is part of any
			 * other repset or not?
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

/*
 * remove_table_from_repsets
 *		removes given table from the other replication sets.
 */
static void
remove_table_from_repsets(Oid nodeid, Oid reloid, bool only_for_update)
{
	ListCell   *lc;
	List	   *repsets;

	repsets = get_table_replication_sets(nodeid, reloid);
	foreach(lc, repsets)
	{
		SpockRepSet *rs = (SpockRepSet *) lfirst(lc);

		if (only_for_update)
		{
			if (rs->replicate_update || rs->replicate_delete)
				replication_set_remove_table(rs->id, reloid, true);
		}
		else
			replication_set_remove_table(rs->id, reloid, true);
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
	 * Indicates a portion of a query. These statements should be handled by
	 * the corresponding top-level query.
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
