/*-------------------------------------------------------------------------
 *
 * spock_autoddl.c
 * 		spock autoddl replication support
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
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
#include "utils/snapmgr.h"
#include "spock_autoddl.h"
#include "spock_executor.h"
#include "spock_queue.h"
#include "spock_repset.h"
#include "spock_node.h"
#include "spock_output_plugin.h"
#include "spock.h"

static void remove_table_from_repsets(Oid nodeid, Oid reloid,
									  bool only_for_update);
static bool autoddl_can_proceed(Node *parsetree, ProcessUtilityContext context,
								NodeTag toplevel_stmt);
static bool extract_ddl_target(Node *parsetree, RangeVar **relation,
							   Oid *reloid, bool *missing_ok);
static void apply_repset_policy_for_reloid(SpockLocalNode *node, Oid reloid);

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
					  NodeTag toplevel_stmt)
{
	Oid			save_userid = 0;
	int			save_sec_context = 0;
	const char *curr_qry;
	int			loc = pstmt->stmt_location;
	int			len = pstmt->stmt_len;
	Node	   *parsetree = pstmt->utilityStmt;
	bool		needTx = false;
	bool		needSnapshot = false;

	if (!autoddl_can_proceed(parsetree, context, toplevel_stmt))
	{
		/* Fast path */
		return;
	}

	needTx = !IsTransactionState();
	if (needTx)
		StartTransactionCommand();
	needSnapshot = !HaveRegisteredOrActiveSnapshot();
	if (needSnapshot)
		PushActiveSnapshot(GetTransactionSnapshot());

	/*
	 * Elevate access rights: Utility hook is called under the session user, who
	 * does not necessarily have access permission to Spock extension objects.
	 */
	GetUserIdAndSecContext(&save_userid, &save_sec_context);
	SetUserIdAndSecContext(BOOTSTRAP_SUPERUSERID,
						   save_sec_context | SECURITY_LOCAL_USERID_CHANGE);

	/* Not a Spock node, do nothing */
	if (get_local_node(false, true) == NULL)
		goto end;

	/* Replicate DDL statement */
	queryString = CleanQuerytext(queryString, &loc, &len);
	curr_qry = pnstrdup(queryString, len);

	/*
	 * Only track the affected relation in the replication set if the command
	 * was actually queued for replication.  If replication was skipped (for
	 * example because the statement references a temporary relation), adding
	 * the table here would let its later DML replicate to subscribers that
	 * never received the CREATE, stalling the apply worker.
	 */
	if (spock_auto_replicate_ddl(curr_qry,
								 list_make1(DEFAULT_INSONLY_REPSET_NAME),
								 GetUserId(),
								 parsetree))
		add_ddl_to_repset(parsetree);

end:
	/* Restore previous session privileges */
	SetUserIdAndSecContext(save_userid, save_sec_context);

	/* Clean up transaction and snapshot if we started them */
	if (needSnapshot)
		PopActiveSnapshot();
	if (needTx)
		CommitTransactionCommand();
}

/*
 * add_ddl_to_repset
 *		Route a just-executed DDL statement into the appropriate replication
 *		set(s). Only tables are auto-managed.
 *
 * Pipeline:
 *	1. extract_ddl_target() inspects the parse tree, decides if this DDL
 *	   targets a table, and reports the target.
 *	2. The target is opened and (if partitioned) expanded into all inheritors.
 *	3. apply_repset_policy_for_reloid() handles each concrete relation:
 *	   UNLOGGED/TEMP skip and default/insert-only repset routing.
 */
void
add_ddl_to_repset(Node *parsetree)
{
	Relation		targetrel;
	SpockLocalNode *node;
	Oid				reloid = InvalidOid;
	RangeVar	   *relation = NULL;
	List		   *reloids = NIL;
	ListCell	   *lc;
	bool			missing_ok = false;

	if (!spock_include_ddl_repset)
		return;

	if (!extract_ddl_target(parsetree, &relation, &reloid, &missing_ok))
		return;

	node = get_local_node(false, true);
	if (!node)
		return;

	if (OidIsValid(reloid))
		targetrel = RelationIdGetRelation(reloid);
	else
		targetrel = table_openrv_extended(relation, AccessShareLock, missing_ok);

	/*
	 * If the relation doesn't exist (concurrent drop, or missing_ok hit),
	 * quietly exit. The core already produced an INFO message.
	 */
	if (targetrel == NULL)
		return;

	reloid = RelationGetRelid(targetrel);

	if (targetrel->rd_rel->relkind == RELKIND_PARTITIONED_TABLE)
		reloids = find_all_inheritors(reloid, NoLock, NULL);
	else
		reloids = lappend_oid(reloids, reloid);
	table_close(targetrel, NoLock);

	foreach(lc, reloids)
		apply_repset_policy_for_reloid(node, lfirst_oid(lc));
}

/*
 * extract_ddl_target
 *		Parse-tree dispatch: decide whether this DDL targets a table that
 *		auto-DDL should auto-manage, and if so, fill in the target outputs.
 *
 * Returns true if *relation or *reloid identifies a target the caller should
 * process. Returns false otherwise; in the CreateSchema and EXPLAIN ANALYZE
 * cases this also recurses back into add_ddl_to_repset() for each contained
 * statement.
 *
 * On a true return:
 *	*relation	- RangeVar of the target, or NULL if *reloid is set
 *	*reloid		- pre-resolved oid (currently only the
 *				  ALTER INDEX ... ATTACH PARTITION path)
 *	*missing_ok	- whether table_openrv_extended should tolerate a missing rel
 */
static bool
extract_ddl_target(Node *parsetree, RangeVar **relation, Oid *reloid,
				   bool *missing_ok)
{
	switch (nodeTag(parsetree))
	{
		case T_AlterTableStmt:
			{
				AlterTableStmt *atstmt = (AlterTableStmt *) parsetree;

				if (atstmt->objtype == OBJECT_TABLE)
					*relation = atstmt->relation;
				else if (atstmt->objtype == OBJECT_INDEX)
				{
					ListCell *cell;

					/*
					 * ALTER INDEX ... ATTACH PARTITION may complete a
					 * partitioned primary key, so re-evaluate the partitioned
					 * table that owns the index.
					 */
					foreach(cell, atstmt->cmds)
					{
						AlterTableCmd *cmd = (AlterTableCmd *) lfirst(cell);

						if (cmd->subtype == AT_AttachPartition)
						{
							Relation indrel;

							indrel = relation_openrv(atstmt->relation,
													 AccessShareLock);
							*reloid = IndexGetRelation(RelationGetRelid(indrel),
													   false);
							table_close(indrel, NoLock);
						}
					}

					if (!OidIsValid(*reloid))
						return false;
				}
				else
					return false;

				*missing_ok = atstmt->missing_ok;
				return true;
			}

		case T_CreateStmt:
			*relation = castNode(CreateStmt, parsetree)->relation;
			return true;

		case T_CreateTableAsStmt:
			if (castNode(CreateTableAsStmt, parsetree)->objtype != OBJECT_TABLE)
				return false;
			*relation = castNode(CreateTableAsStmt, parsetree)->into->rel;
			return true;

		case T_CreateSchemaStmt:
			{
				CreateSchemaStmt *cstmt = (CreateSchemaStmt *) parsetree;
				ListCell   *cell;

				foreach(cell, cstmt->schemaElts)
				{
					if (nodeTag(lfirst(cell)) == T_CreateStmt)
						add_ddl_to_repset(lfirst(cell));
				}
				return false;
			}

		case T_ExplainStmt:
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

				return false;
			}

		default:
			/* only tables are added to repset. */
			return false;
	}
}

/*
 * apply_repset_policy_for_reloid
 *		Repset routing for a single concrete relation oid.
 *
 *	- UNLOGGED/TEMP	-> evict from every repset, done.
 *	- PK or replica identity present -> 'default' repset.
 *	- No PK/RI -> 'default_insert_only'.
 */
static void
apply_repset_policy_for_reloid(SpockLocalNode *node, Oid reloid)
{
	Relation		targetrel;
	SpockRepSet	   *repset;

	targetrel = RelationIdGetRelation(reloid);

	/* UNLOGGED and TEMP relations cannot be part of replication set. */
	if (!RelationNeedsWAL(targetrel))
	{
		remove_table_from_repsets(node->node->id, reloid, false);
		table_close(targetrel, NoLock);
		return;
	}

	/*
	 * Force index list build so rd_pkindex and rd_replidindex are populated
	 * before we read them below.
	 */
	if (targetrel->rd_indexvalid == 0)
		RelationGetIndexList(targetrel);

	/* Choose default vs default_insert_only based on PK/RI presence. */
	if (OidIsValid(targetrel->rd_pkindex) || OidIsValid(targetrel->rd_replidindex))
	{
		repset = get_replication_set_by_name(node->node->id,
											 DEFAULT_REPSET_NAME, false);
		/* will be added to 'default' below; clear any prior membership */
		remove_table_from_repsets(node->node->id, reloid, false);
	}
	else
	{
		repset = get_replication_set_by_name(node->node->id,
											 DEFAULT_INSONLY_REPSET_NAME, false);
		/* no PK: only evict from repsets that need UPDATE/DELETE */
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

/*
 * Quick precheck if auto-ddl may proceed further.
 *
 * Must be trivial and does not call anything that may need a transaction.
 */
static bool
autoddl_can_proceed(Node *parsetree, ProcessUtilityContext context,
					NodeTag toplevel_stmt)
{
	if (spock_replication_repair_mode)

		/*
		 * Repair mode means that nothing happened in this state should be
		 * decoded and sent to any subscriber.
		 */
		return false;

	/* Only process DDL statements */
	if (GetCommandLogLevel(parsetree) != LOGSTMT_DDL)
		return false;

	/* If DDL replication is disabled, do nothing */
	if (!spock_enable_ddl_replication)
		return false;

	/* If we are already processing a queued DDL, do nothing */
	if (in_spock_queue_ddl_command || in_spock_replicate_ddl_command)
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
	 * Allow DDL from functions except for CREATE|DROP EXTENSION and CREATE
	 * SCHEMA
	 */
	if (context == PROCESS_UTILITY_QUERY && allow_ddl_from_functions)
	{
		if (toplevel_stmt != T_CreateExtensionStmt &&
			toplevel_stmt != T_CreateSchemaStmt &&
			!(toplevel_stmt == T_DropStmt &&
			  castNode(DropStmt, parsetree)->removeType == OBJECT_EXTENSION))
			return true;

		return false;
	}

	/* In all other cases, disallow DDL replication. */
	return false;
}
