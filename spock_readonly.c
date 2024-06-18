/*-------------------------------------------------------------------------
 * spock_readonly.c
 *    Spock readonly related functions
 *
 * Spock readonly functions allow setting the entire cluster to read-only mode,
 * preventing INSERT, UPDATE, DELETE, and DDL operations. This file is part of
 * pgEdge, Inc. open source project, licensed under the PostgreSQL license.
 *
 * This file is part of pgEdge, Inc. open source project, licensed under
 * the PostgreSQL license. For license terms, see the LICENSE file.
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Copyright (c) 2020, Pierre Forstmann.
 *-------------------------------------------------------------------------
*/

#include "postgres.h"
#include "fmgr.h"
#include "access/xact.h"
#include "miscadmin.h"
#include "parser/analyze.h"
#include "storage/ipc.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "tcop/utility.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/elog.h"
#include "executor/executor.h"

#include "spock.h"

/* GUC variable */
bool spock_readonly = false;


PG_FUNCTION_INFO_V1(spockro_terminate_active_transactions);

/*
 * Terminate active transactions
 */
Datum
spockro_terminate_active_transactions(PG_FUNCTION_ARGS)
{
	VirtualTransactionId *tvxid;
	int nvxids;
	int i;
	pid_t pid;

	elog(LOG, "spock: terminating all active transactions ...");

	tvxid = GetCurrentVirtualXIDs(InvalidTransactionId, false, true, 0, &nvxids);
	for (i = 0; i < nvxids; i++)
	{
		pid = CancelVirtualTransaction(tvxid[i], PROCSIG_RECOVERY_CONFLICT_SNAPSHOT);
		elog(LOG, "spock: PID %d signalled", pid);
	}
	PG_RETURN_BOOL(true);
}

/*
 * Get cluster read-only status
 */
static bool
spockro_get_readonly_internal(void)
{
    return spock_readonly && !superuser();
}

void
spock_ropost_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate)
{
    bool command_is_ro = false;
	switch (query->commandType)
	{
		case CMD_SELECT:
			command_is_ro = true;
			break;
		case CMD_UTILITY:
			if (IsA(query->utilityStmt, TransactionStmt) &&
				((TransactionStmt *) query->utilityStmt)->kind == TRANS_STMT_ROLLBACK)
			{
				command_is_ro = true;
			}
			else
			{
				switch (nodeTag(query->utilityStmt))
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
			break;
		default:
			command_is_ro = false;
			break;
	}
	if (spockro_get_readonly_internal() && !command_is_ro)
		ereport(ERROR, (errmsg("spock: invalid statement for a read-only cluster")));
}

void
spock_roExecutorStart(QueryDesc *queryDesc, int eflags)
{
	bool command_is_ro = false;
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
}
