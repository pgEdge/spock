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
 * trim_whitespace - function to trim leading and trailing whitespace inplace
 */
char *
trim_whitespace(char *str)
{
    char *end;

    /* trim leading whitespace */
    while (isspace((unsigned char)*str))
		str++;

    if (*str == '\0')
		return str;

    /* trim trailing whitespace */
    end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char)*end))
		end--;

    *(end + 1) = '\0';
    return str;
}
