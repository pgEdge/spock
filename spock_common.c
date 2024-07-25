/*-------------------------------------------------------------------------
 *
 * spock_common.c
 * 		Common code for Spock.
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "miscadmin.h"
#include "utils/guc.h"

#include "catalog/namespace.h"
#include "nodes/nodeFuncs.h"
#include "parser/parse_relation.h"

#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"

#include "spock_repset.h"
#include "spock_common.h"
#include "spock_compat.h"

/*
 * Temporarily switch to a new user ID.
 *
 * SECURITY_RESTRICTED_OPERATION is imposed and a new GUC nest level is
 * created so that any settings changes can be rolled back.
 */
void
SPKSwitchToUntrustedUser(Oid userid, UserContext *context)
{
    int     sec_context;

	/* Get the current user ID and security context. */
	GetUserIdAndSecContext(&context->save_userid,
						   &context->save_sec_context);
	sec_context = context->save_sec_context;

    /*
     * This user can SET ROLE to the target user, but not the other way
     * around, so protect ourselves against the target user by setting
     * SECURITY_RESTRICTED_OPERATION to prevent certain changes to the
     * session state. Also set up a new GUC nest level, so that we can
     * roll back any GUC changes that may be made by code running as the
     * target user, inasmuch as they could be malicious.
     */
	sec_context |= SECURITY_RESTRICTED_OPERATION;
	SetUserIdAndSecContext(userid, sec_context);
	context->save_nestlevel = NewGUCNestLevel();
}

/*
 * Switch back to the original user ID.
 *
 * If we created a new GUC nest level, also roll back any changes that were
 * made within it.
 */
void
SPKRestoreUserContext(UserContext *context)
{
	if (context->save_nestlevel != -1)
		AtEOXact_GUC(false, context->save_nestlevel);
	SetUserIdAndSecContext(context->save_userid, context->save_sec_context);
}

bool
SPKExecBRDeleteTriggers(EState *estate,
						EPQState *epqstate,
						ResultRelInfo *relinfo,
						ItemPointer tupleid,
						HeapTuple fdw_trigtuple)
{
	UserContext		ucxt;
	bool			ret;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ret = ExecBRDeleteTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple);
	RestoreUserContext(&ucxt);

	return ret;
}

void
SPKExecARDeleteTriggers(EState *estate,
						ResultRelInfo *relinfo,
						ItemPointer tupleid,
						HeapTuple fdw_trigtuple)
{
	UserContext		ucxt;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ExecARDeleteTriggers(estate, relinfo, tupleid, fdw_trigtuple);
	RestoreUserContext(&ucxt);
}

bool
SPKExecBRUpdateTriggers(EState *estate,
						EPQState *epqstate,
						ResultRelInfo *relinfo,
						ItemPointer tupleid,
						HeapTuple fdw_trigtuple,
						TupleTableSlot *slot)
{
	UserContext		ucxt;
	bool			ret;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ret = ExecBRUpdateTriggers(estate, epqstate, relinfo, tupleid, fdw_trigtuple, slot);
	RestoreUserContext(&ucxt);

	return ret;
}

void
SPKExecARUpdateTriggers(EState *estate,
						ResultRelInfo *relinfo,
						ItemPointer tupleid,
						HeapTuple fdw_trigtuple,
						TupleTableSlot *slot,
						List *recheckIndexes)
{
	UserContext		ucxt;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ExecARUpdateTriggers(estate, relinfo, tupleid, fdw_trigtuple, slot, recheckIndexes);
	RestoreUserContext(&ucxt);
}

bool
SPKExecBRInsertTriggers(EState *estate,
						ResultRelInfo *relinfo,
						TupleTableSlot *slot)
{
	UserContext		ucxt;
	bool			ret;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ret = ExecBRInsertTriggers(estate, relinfo, slot);
	RestoreUserContext(&ucxt);

	return ret;
}

void
SPKExecARInsertTriggers(EState *estate,
						ResultRelInfo *relinfo,
						TupleTableSlot *slot,
						List *recheckIndexes)
{
	UserContext		ucxt;

	SwitchToUntrustedUser(relinfo->ri_RelationDesc->rd_rel->relowner, &ucxt);
	ExecARInsertTriggers(estate, relinfo, slot, recheckIndexes);
	RestoreUserContext(&ucxt);
}

/*
 * Determine whether the given table can be replicated. The primary criteria
 * is whether the table is a temporary table. In some cases (i.e., if
 * check_in_repset is true), examine spock.replication_set_table to decide
 * whether the replication of the statement should be permitted.
 */
bool
stmt_not_replicable(RangeVar *rv, bool check_in_repset)
{
	if (rv->relpersistence == RELPERSISTENCE_TEMP)
		return true;

	if (is_temp_table(rv->relname))
		return true;

	if (check_in_repset)
	{
		char	relkind;
		Oid		relid;

		relid = RangeVarGetRelid(rv, AccessShareLock, true);
		if (OidIsValid(relid))
		{
			relkind = get_rel_relkind(relid);

			if ((relkind == RELKIND_RELATION ||
				 relkind == RELKIND_PARTITIONED_TABLE) &&
				!is_target_in_repset_table(relid))
				return true;
		}
	}

	return false;
}

/*
 * Check if the given table is a temporary table by examining the pg_temp schema.
 */
bool
is_temp_table(char *relname)
{
	HeapTuple	tuple = NULL;
	Oid			tempNspOid = InvalidOid;
	bool		temp = false;

	tempNspOid = LookupCreationNamespace("pg_temp");
	tuple = SearchSysCache2(RELNAMENSP,
							 PointerGetDatum(relname),
							 ObjectIdGetDatum(tempNspOid));
	if (!HeapTupleIsValid(tuple))
		return temp;

	temp = (((Form_pg_class) GETSTRUCT(tuple))->relpersistence == RELPERSISTENCE_TEMP);
	ReleaseSysCache(tuple);

	return temp;
}

bool
is_target_in_repset_table(Oid reloid)
{
	Oid				repset_reloid;
	Oid				repset_indoid;
	Relation		repset_rel;
	ScanKeyData		key;
	SysScanDesc		scan;
	HeapTuple		tuple;
	RepSetTableTuple	*reptuple = NULL;
	bool			exists = false;

	if (!OidIsValid(reloid))
		return exists;

	if (reloid < FirstNormalObjectId)
		return true;

	repset_reloid = get_replication_set_table_rel_oid();
	repset_rel = table_open(repset_reloid, RowExclusiveLock);
	repset_indoid = RelationGetPrimaryKeyIndex(repset_rel);

	ScanKeyInit(&key,
				Anum_repset_table_reloid,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(reloid));

	scan = systable_beginscan(repset_rel, repset_indoid, true, NULL, 1, &key);
	while (HeapTupleIsValid(tuple = systable_getnext(scan)))
	{
		reptuple = (RepSetTableTuple *) GETSTRUCT(tuple);

		if (reptuple->reloid == reloid)
		{
			exists = true;
			break;
		}
	}

	systable_endscan(scan);
	table_close(repset_rel, RowExclusiveLock);
	return exists;
}

bool
isQueryUsingTempRelation_walker(Node *node, List **reloids)
{
	if (node == NULL)
		return false;

	if (IsA(node, Query))
	{
		Query	   *query = (Query *) node;
		ListCell   *rtable;

		foreach(rtable, query->rtable)
		{
			RangeTblEntry *rte = lfirst(rtable);

			if (rte->rtekind == RTE_RELATION)
			{
				Relation	rel = table_open(rte->relid, AccessShareLock);
				char		relpersistence = rel->rd_rel->relpersistence;

				if (reloids != NULL)
					*reloids = lappend_oid(*reloids, RelationGetRelid(rel));
				table_close(rel, AccessShareLock);
				if (relpersistence == RELPERSISTENCE_TEMP)
					return true;
			}
		}

		return query_tree_walker(query,
								 isQueryUsingTempRelation_walker,
								 reloids,
								 QTW_IGNORE_JOINALIASES);
	}

	return expression_tree_walker(node,
								  isQueryUsingTempRelation_walker,
								  reloids);
}
