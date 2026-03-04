/*-------------------------------------------------------------------------
 * spock_readonly.c
 *    Spock readonly related functions
 *
 * Spock readonly functions allow setting the database to read-only mode,
 * preventing INSERT, UPDATE, DELETE, and DDL operations.
 * In the 'ALL' mode it prevents the database from being modified by spock
 * apply workers as well.
 * This code employs the transaction_read_only GUC to disable attempts
 * to execute DML or DDL commands.
 *
 * This file is part of pgEdge, Inc. open source project, licensed under
 * the PostgreSQL license. For license terms, see the LICENSE file.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
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

#include "spock_readonly.h"
#include "spock.h"

/* GUC variable */
int			spock_readonly = READONLY_OFF;


PG_FUNCTION_INFO_V1(spockro_terminate_active_transactions);

/*
 * Terminate active transactions
 */
Datum
spockro_terminate_active_transactions(PG_FUNCTION_ARGS)
{
	VirtualTransactionId *tvxid;
	int			nvxids;
	int			i;
	pid_t		pid;

	elog(LOG, "spock: terminating all active transactions ...");

	tvxid = GetCurrentVirtualXIDs(InvalidTransactionId, false, true, 0, &nvxids);
	for (i = 0; i < nvxids; i++)
	{
		pid = CancelVirtualTransaction(tvxid[i], PROCSIG_RECOVERY_CONFLICT_SNAPSHOT);
		elog(LOG, "spock: PID %d signalled", pid);
	}
	PG_RETURN_BOOL(true);
}

void
spock_ropost_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate)
{
	/*
	 * If spock.readonly is set, enforce Postgres core restriction for the
	 * following query. We actively employ the fact that the core uses the
	 * XactReadOnly value directly, not through the GetConfigOption function.
	 * Also, we use this fact here to identify if XactReadOnly has been changed
	 * by Spock or by external tools.
	 */
	if (spock_readonly >= READONLY_LOCAL && !superuser())
		XactReadOnly = true;
	else if (XactReadOnly)
	{
		const char *value =
						GetConfigOption("transaction_read_only", false, false);

		if (strcmp(value, "off") == 0)
			/* Spock imposed read-only. Restore the original state. */
			XactReadOnly = false;
	}
	else
	{
		/* XactReadOnly is already false, nothing to restore. */
	}
}

void
spock_roExecutorStart(QueryDesc *queryDesc, int eflags)
{
	/*
	 * Let's do the same job as at parse analysis hook.
	 *
	 * In some cases parse analysis and planning may be skipped on repeated
	 * execution (remember SPI plan for example). So, additional control makes
	 * sense here.
	 */
	if (spock_readonly >= READONLY_LOCAL && !superuser())
		XactReadOnly = true;
	else if (XactReadOnly)
	{
		const char *value =
						GetConfigOption("transaction_read_only", false, false);

		if (strcmp(value, "off") == 0)
			/* Spock imposed read-only. Restore the original state. */
			XactReadOnly = false;
	}
	else
	{
		/* XactReadOnly is already false, nothing to restore. */
	}
}
