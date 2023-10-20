/*-------------------------------------------------------------------------
 *
 * spock_readonly.c
 * 		spock readonly related functions
 *
 * spock_readonly functions allows to set a whole cluster read only: no
 * INSERT,UPDATE,DELETE and no DDL can be run.
 *
 * This program is open source, licensed under the PostgreSQL license.
 * For license terms, see the LICENSE file.
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Copyright (c) 2020, Pierre Forstmann.
 *
 *-------------------------------------------------------------------------
*/
#include "postgres.h"
#include "parser/analyze.h"
#include "nodes/nodes.h"
#include "storage/proc.h"
#include "access/xact.h"

#include "tcop/tcopprot.h"
#include "tcop/utility.h"
#include "utils/guc.h"
#include "utils/snapmgr.h"
#include "utils/memutils.h"

#include "storage/ipc.h"
#include "storage/spin.h"
#include "miscadmin.h"
#include "storage/procarray.h"
#include "executor/executor.h"

#include "spock_worker.h"

post_parse_analyze_hook_type prev_post_parse_analyze_hook = NULL;
ExecutorStart_hook_type prev_executor_start_hook = NULL;

/*---- Function declarations ----*/

void		spock_post_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate);
void		spock_ExecutorStart(QueryDesc *queryDesc, int eflags);

static bool spockro_get_readonly_internal();

PG_FUNCTION_INFO_V1(spockro_set_readonly);
PG_FUNCTION_INFO_V1(spockro_unset_readonly);
PG_FUNCTION_INFO_V1(spockro_get_readonly);
PG_FUNCTION_INFO_V1(spockro_terminate_active_transactions);


/*
 * get cluster databases read-only or read-write status
 */
static bool
spockro_get_readonly_internal()
{
	bool		val;

	LWLockAcquire(SpockCtx->lock, LW_SHARED);
	val = SpockCtx->cluster_is_readonly;
	LWLockRelease(SpockCtx->lock);
	return val;
}

/*
 * set cluster databases to read-only
 */
Datum
spockro_set_readonly(PG_FUNCTION_ARGS)
{
	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
	SpockCtx->cluster_is_readonly = true;
	LWLockRelease(SpockCtx->lock);

	PG_RETURN_BOOL(true);
}

/*
 * set cluster databases to read-write
 */
Datum
spockro_unset_readonly(PG_FUNCTION_ARGS)
{
	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
	SpockCtx->cluster_is_readonly = false;
	LWLockRelease(SpockCtx->lock);

	PG_RETURN_BOOL(true);
}

/*
 * get cluster databases status
 */
Datum
spockro_get_readonly(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(spockro_get_readonly_internal());
}

Datum
spockro_terminate_active_transactions(PG_FUNCTION_ARGS)
{
	VirtualTransactionId *tvxid;
	int			nvxids;
	int			i;
	pid_t		pid;

	elog(LOG, "spock: killing all transactions ...");
	tvxid = GetCurrentVirtualXIDs(InvalidTransactionId, false, true,
								  0, &nvxids);
	for (i = 0; i < nvxids; i++)
	{
		/* No adequate ProcSignalReason found */
		pid = CancelVirtualTransaction(tvxid[i],
									   PROCSIG_RECOVERY_CONFLICT_SNAPSHOT);
		elog(LOG, "spock: PID %d signalled", pid);
	}

	PG_RETURN_BOOL(true);
}

/*
 * get control at end of parse analysis
 */
void
spock_post_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate)
{
	bool		command_is_ro = false;

	switch (query->commandType)
	{
		case CMD_SELECT:
			command_is_ro = true;
			break;
		case CMD_UTILITY:

			/* allow ROLLBACK for killed transactions */
			if (strstr((pstate->p_sourcetext), "rollback") ||
				strstr((pstate->p_sourcetext), "ROLLBACK"))
			{
				elog(DEBUG1, "spock: spock_post_parse_analyze: query->querySource=%s",
					 pstate->p_sourcetext);
				command_is_ro = true;
			}
			break;
		default:
			command_is_ro = false;
			break;
	}

	if (query->commandType == CMD_UTILITY)
	{
		switch ((nodeTag(query->utilityStmt)))
		{
			case T_ExplainStmt:
			case T_VariableSetStmt:
			case T_VariableShowStmt:
			case T_PrepareStmt:
			case T_ExecuteStmt:
			case T_DeallocateStmt:
				command_is_ro = true;
				break;
			default:
				command_is_ro = false;
				break;
		}
	}

	if (spockro_get_readonly_internal() && !command_is_ro)
		ereport(ERROR, (errmsg("spock: invalid statement for a read-only cluster")));

	if (prev_post_parse_analyze_hook)
		(*prev_post_parse_analyze_hook) (pstate, query, jstate);

	/* no "standard" call for else branch */
}

/*
 * get control in ExecutorStart
 */
void
spock_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	bool		command_is_ro = false;

	switch (queryDesc->operation)
	{
		case CMD_SELECT:
			command_is_ro = true;
			break;
		case CMD_INSERT:
		case CMD_UPDATE:
		case CMD_DELETE:
		default:
			command_is_ro = false;
			break;
	}

	if (spockro_get_readonly_internal() && !command_is_ro)
		ereport(ERROR, (errmsg("spock: invalid statement for a read-only cluster")));

	if (prev_executor_start_hook)
		(*prev_executor_start_hook) (queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);
}
