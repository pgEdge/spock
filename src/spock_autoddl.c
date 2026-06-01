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

/*
 * Classification of a post-execution ALTER TABLE with respect to the
 * table's primary key / replica identity. apply_repset_policy_for_reloid()
 * runs after the DDL has executed, so post-state is read from the relcache
 * and combined with parse-tree intent. "PKRI" covers PK and replica
 * identity since either is sufficient for UPDATE/DELETE replication.
 */
typedef enum AlterPkRiChange
{
	PKRI_UNCHANGED = 0,
	PKRI_ADDED,
	PKRI_DROPPED
} AlterPkRiChange;

static void remove_table_from_repsets(Oid nodeid, Oid reloid,
									  bool only_for_update);
static bool autoddl_can_proceed(Node *parsetree, ProcessUtilityContext context,
								NodeTag toplevel_stmt);
static bool extract_ddl_target(Node *parsetree, RangeVar **relation,
							   Oid *reloid, bool *missing_ok,
							   bool *check_alter_stickiness);
static void apply_repset_policy_for_reloid(SpockLocalNode *node, Oid reloid,
										   AlterTableStmt *atstmt,
										   bool check_alter_stickiness);
static AlterPkRiChange classify_alter_pkri_change(AlterTableStmt *atstmt,
												  Relation targetrel);
static void classify_repset_membership(Oid nodeid, Oid reloid,
									   bool *in_any_upd_del,
									   bool *in_any_custom);

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
	bool			check_alter_stickiness = false;
	AlterTableStmt *atstmt;

	if (!spock_include_ddl_repset)
		return;

	if (!extract_ddl_target(parsetree, &relation, &reloid, &missing_ok,
							&check_alter_stickiness))
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

	atstmt = check_alter_stickiness ? (AlterTableStmt *) parsetree : NULL;

	foreach(lc, reloids)
		apply_repset_policy_for_reloid(node, lfirst_oid(lc), atstmt,
									   check_alter_stickiness);
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
 *	*relation				- RangeVar of the target, or NULL if *reloid is set
 *	*reloid					- pre-resolved oid (currently only the
 *							  ALTER INDEX ... ATTACH PARTITION path)
 *	*missing_ok				- whether table_openrv_extended should tolerate a
 *							  missing relation
 *	*check_alter_stickiness	- true for plain ALTER TABLE; the caller will
 *							  apply ALTER stickiness rules in the per-reloid
 *							  policy
 */
static bool
extract_ddl_target(Node *parsetree, RangeVar **relation, Oid *reloid,
				   bool *missing_ok, bool *check_alter_stickiness)
{
	switch (nodeTag(parsetree))
	{
		case T_AlterTableStmt:
			{
				AlterTableStmt *atstmt = (AlterTableStmt *) parsetree;

				if (atstmt->objtype == OBJECT_TABLE)
				{
					*relation = atstmt->relation;
					*check_alter_stickiness = true;
				}
				else if (atstmt->objtype == OBJECT_INDEX)
				{
					ListCell *cell;

					/*
					 * ALTER INDEX ... ATTACH PARTITION may complete a
					 * partitioned primary key, so always re-evaluate (no
					 * stickiness check).
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
 *	atstmt is the originating ALTER TABLE statement, or NULL if this DDL was
 *	not an ALTER TABLE. check_alter_stickiness must match: it is true iff
 *	atstmt is non-NULL and ALTER stickiness rules should be applied.
 *
 * Decision tree:
 *	- UNLOGGED/TEMP	-> evict from every repset, done.
 *	- ALTER with no PK/RI change -> leave membership alone (sticky).
 *	- ALTER that adds/drops PK on a table in a custom repset:
 *		- PK dropped + custom repset replicates UPD/DEL: WARNING, fall through
 *		  and move to default_insert_only (replication would break otherwise).
 *		- PK added on a custom repset: NOTICE and leave membership alone.
 *		- Otherwise: leave membership alone.
 *	- Else (CREATE, CREATE TABLE AS, ATTACH PARTITION, ALTER with no custom
 *	  repset, or fall-through from the PK-dropped safety net):
 *		- PK or replica identity present -> 'default' repset.
 *		- No PK/RI -> 'default_insert_only'.
 */
static void
apply_repset_policy_for_reloid(SpockLocalNode *node, Oid reloid,
							   AlterTableStmt *atstmt,
							   bool check_alter_stickiness)
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
	 * Force index list build so rd_pkindex and rd_replidindex reflect the
	 * post-ALTER state before we read them below.
	 */
	if (targetrel->rd_indexvalid == 0)
		RelationGetIndexList(targetrel);

	/*
	 * ALTER TABLE stickiness.
	 *
	 *	PKRI_UNCHANGED	- leave membership entirely alone.
	 *	PKRI_DROPPED	- any UPD/DEL repset (default or custom) now has a
	 *					  table without a PK/RI and would produce broken
	 *					  replication. Emit WARNING when a custom membership
	 *					  is affected, then fall through and let the routing
	 *					  block evict from UPD/DEL repsets and place the
	 *					  table in default_insert_only. If the table is only
	 *					  in insert-only repsets (custom and/or
	 *					  default_insert_only), there is nothing to fix —
	 *					  stay sticky.
	 *	PKRI_ADDED		- tables in any custom repset stay sticky (operator
	 *					  intent) and get a NOTICE; tables that are only
	 *					  default-managed fall through to standard routing
	 *					  (e.g. move from default_insert_only to default).
	 */
	if (check_alter_stickiness)
	{
		AlterPkRiChange pkchange;
		bool			in_any_upd_del;
		bool			in_any_custom;

		pkchange = classify_alter_pkri_change(atstmt, targetrel);

		if (pkchange == PKRI_UNCHANGED)
		{
			table_close(targetrel, NoLock);
			return;
		}

		classify_repset_membership(node->node->id, reloid,
								   &in_any_upd_del, &in_any_custom);

		if (pkchange == PKRI_DROPPED)
		{
			if (in_any_upd_del)
			{
				/*
				 * One or more UPD/DEL memberships need the now-missing
				 * PK/RI. Loud-warn only when a custom membership is in
				 * play, since pure default-routed tables already produce
				 * an INFO from the standard remove+add flow.
				 */
				if (in_any_custom)
					ereport(WARNING,
							(errmsg("table \"%s\" lost its primary key while in a replication set that replicates UPDATE/DELETE; moving to \"%s\"",
									get_rel_name(reloid),
									DEFAULT_INSONLY_REPSET_NAME)));
				/* fall through to the remove+add path below */
			}
			else if (in_any_custom)
			{
				/*
				 * Only insert-only memberships (custom and/or
				 * default_insert_only). Nothing replicates UPD/DEL so the
				 * missing PK is harmless. Sticky.
				 */
				table_close(targetrel, NoLock);
				return;
			}
			/* else: no custom, no UPD/DEL — fall through */
		}
		else	/* PKRI_ADDED */
		{
			if (in_any_custom)
			{
				ereport(NOTICE,
						(errmsg("table \"%s\" gained a primary key while in a custom replication set; leaving membership unchanged",
								get_rel_name(reloid)),
						 errhint("Move the table to \"%s\" manually if full UPDATE/DELETE replication is desired.",
								 DEFAULT_REPSET_NAME)));
				/* sticky: respect the operator's custom placement */
				table_close(targetrel, NoLock);
				return;
			}
			/* else: only default-managed — fall through to standard routing */
		}
	}

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
 * classify_alter_pkri_change
 *		Determine, given the AlterTableStmt and the post-execution relcache
 *		state, whether this ALTER added a primary key / replica identity,
 *		dropped one, or left PK/RI unchanged.
 *
 * Called after standard utility processing, so targetrel reflects the new
 * state. Parse-tree intent narrows ambiguity (e.g. AT_DropConstraint may
 * have targeted a UNIQUE, not the PK — but if the post-state still has a
 * PK, we know the PK was not dropped).
 */
static AlterPkRiChange
classify_alter_pkri_change(AlterTableStmt *atstmt, Relation targetrel)
{
	ListCell   *cell;
	bool		has_add_pkri_cmd = false;
	bool		has_drop_pkri_candidate = false;
	bool		post_has_pk_or_ri;

	post_has_pk_or_ri = OidIsValid(targetrel->rd_pkindex) ||
		OidIsValid(targetrel->rd_replidindex);

	foreach(cell, atstmt->cmds)
	{
		AlterTableCmd *cmd = (AlterTableCmd *) lfirst(cell);

		switch (cmd->subtype)
		{
			case AT_AddConstraint:
			case AT_AddIndexConstraint:
				if (cmd->def && IsA(cmd->def, Constraint))
				{
					Constraint *con = (Constraint *) cmd->def;

					if (con->contype == CONSTR_PRIMARY)
						has_add_pkri_cmd = true;
				}
				break;
			case AT_ReplicaIdentity:
				/*
				 * Could be adding or removing RI; let the post-state
				 * disambiguate.
				 */
				has_add_pkri_cmd = true;
				has_drop_pkri_candidate = true;
				break;
			case AT_DropConstraint:
			case AT_DropColumn:
				has_drop_pkri_candidate = true;
				break;
			default:
				break;
		}
	}

	if (post_has_pk_or_ri && has_add_pkri_cmd)
		return PKRI_ADDED;
	if (!post_has_pk_or_ri && has_drop_pkri_candidate)
		return PKRI_DROPPED;
	return PKRI_UNCHANGED;
}

/*
 * classify_repset_membership
 *		Single-pass classification of a table's current repset membership.
 *
 *	in_any_upd_del	- true if the table is in any repset (default or custom)
 *					  that replicates UPDATE or DELETE. Such repsets require
 *					  a PK / replica identity to function.
 *	in_any_custom	- true if the table is in at least one user-defined
 *					  (non-default) repset. Signals that ALTER stickiness
 *					  should respect the operator's manual placement.
 *
 * Combining both questions into one walk avoids re-fetching the membership
 * list in the stickiness path.
 */
static void
classify_repset_membership(Oid nodeid, Oid reloid,
						   bool *in_any_upd_del,
						   bool *in_any_custom)
{
	List	   *repsets = get_table_replication_sets(nodeid, reloid);
	ListCell   *lc;

	*in_any_upd_del = false;
	*in_any_custom = false;

	foreach(lc, repsets)
	{
		SpockRepSet *rs = (SpockRepSet *) lfirst(lc);
		bool		is_default;

		is_default = (strcmp(rs->name, DEFAULT_REPSET_NAME) == 0 ||
					  strcmp(rs->name, DEFAULT_INSONLY_REPSET_NAME) == 0);

		if (!is_default)
			*in_any_custom = true;

		if (rs->replicate_update || rs->replicate_delete)
			*in_any_upd_del = true;

		if (*in_any_upd_del && *in_any_custom)
			break;	/* both flags are now in their terminal state */
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
