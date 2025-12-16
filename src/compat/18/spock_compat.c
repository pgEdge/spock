/*-------------------------------------------------------------------------
 *
 * spock_compat.c
 *              compatibility functions (mainly with different PG versions)
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */


#include "postgres.h"

#include "access/transam.h"
#include "catalog/pg_proc.h"
#include "nodes/nodeFuncs.h"
#include "utils/lsyscache.h"

#include "spock_compat.h"

static bool
contain_mutable_or_user_functions_checker(Oid func_id, void *context)
{
	return (func_volatile(func_id) != PROVOLATILE_IMMUTABLE ||
			func_id >= FirstNormalObjectId);
}

static bool
check_simple_rowfilter_expr_walker(Node *node, ParseState *pstate)
{
	char	   *errdetail_msg = NULL;

	if (node == NULL)
		return false;

	switch (nodeTag(node))
	{
		case T_Var:
			/* System columns are not allowed. */
			if (((Var *) node)->varattno < InvalidAttrNumber)
				errdetail_msg = _("System columns are not allowed.");
			break;
		case T_OpExpr:
		case T_DistinctExpr:
		case T_NullIfExpr:
			/* OK, except user-defined operators are not allowed. */
			if (((OpExpr *) node)->opno >= FirstNormalObjectId)
				errdetail_msg = _("User-defined operators are not allowed.");
			break;
		case T_ScalarArrayOpExpr:
			/* OK, except user-defined operators are not allowed. */
			if (((ScalarArrayOpExpr *) node)->opno >= FirstNormalObjectId)
				errdetail_msg = _("User-defined operators are not allowed.");

			/*
			 * We don't need to check the hashfuncid and negfuncid of
			 * ScalarArrayOpExpr as those functions are only built for a
			 * subquery.
			 */
			break;
		case T_RowCompareExpr:
			{
				ListCell   *opid;

				/* OK, except user-defined operators are not allowed. */
				foreach(opid, ((RowCompareExpr *) node)->opnos)
				{
					if (lfirst_oid(opid) >= FirstNormalObjectId)
					{
						errdetail_msg = _("User-defined operators are not allowed.");
						break;
					}
				}
			}
			break;
		case T_Const:
		case T_FuncExpr:
		case T_BoolExpr:
		case T_RelabelType:
		case T_CollateExpr:
		case T_CaseExpr:
		case T_CaseTestExpr:
		case T_ArrayExpr:
		case T_RowExpr:
		case T_CoalesceExpr:
		case T_MinMaxExpr:
		case T_XmlExpr:
		case T_NullTest:
		case T_BooleanTest:
		case T_List:
			/* OK, supported */
			break;
		default:
			errdetail_msg = _("Only columns, constants, built-in operators, built-in data types, built-in collations, and immutable built-in functions are allowed.");
			break;
	}

	/*
	 * For all the supported nodes, if we haven't already found a problem,
	 * check the types, functions, and collations used in it.  We check List
	 * by walking through each element.
	 */
	if (!errdetail_msg && !IsA(node, List))
	{
		if (exprType(node) >= FirstNormalObjectId)
			errdetail_msg = _("User-defined types are not allowed.");
		else if (check_functions_in_node(node, contain_mutable_or_user_functions_checker,
										 pstate))
			errdetail_msg = _("User-defined or built-in mutable functions are not allowed.");
		else if (exprCollation(node) >= FirstNormalObjectId ||
				 exprInputCollation(node) >= FirstNormalObjectId)
			errdetail_msg = _("User-defined collations are not allowed.");
	}

	/*
	 * If we found a problem in this node, throw error now. Otherwise keep
	 * going.
	 */
	if (errdetail_msg)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("invalid publication WHERE expression"),
				 errdetail_internal("%s", errdetail_msg),
				 parser_errposition(pstate, exprLocation(node))));

	return expression_tree_walker(node, check_simple_rowfilter_expr_walker,
								  pstate);
}

 /*
 * Check if the row filter expression is a "simple expression".
 *
 * See check_simple_rowfilter_expr_walker for details.
 */
bool
check_simple_rowfilter_expr(Node *node, ParseState *pstate)
{
	return check_simple_rowfilter_expr_walker(node, pstate);
}
