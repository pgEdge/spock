/*-------------------------------------------------------------------------
 *
 * spock_toast_util.c
 *		Helpers shared by the TOAST divergence code
 *
 * Helpers the detection, verify and repair code share: running one step in a
 * subtransaction, so an error settles only that step (run_in_subxact()), this
 * node's id (cached_local_nodeid()), and reading and writing a user table as
 * its owner (spi_execute_as_owner()).
 * It also holds the text-output settings pinned wherever values are
 * compared across nodes (toast_pinned_output).
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "executor/spi.h"
#include "utils/guc.h"
#include "utils/resowner.h"
#include "utils/syscache.h"

#include "spock.h"
#include "spock_common.h"
#include "spock_node.h"
#include "spock_toast_internal.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

/*
 * The text-output settings pinned wherever keys, values or hashes are
 * compared across nodes, as {name, value} pairs ending in NULLs.  Keep in
 * step with the SET clauses of spock.toast_divergence_verify() and
 * PIN_OUTPUT_SETTINGS_SQL in spock_toast_conn.c.
 */
const char *const toast_pinned_output[][2] = {
	{"bytea_output", "hex"},
	{"DateStyle", "ISO, MDY"},
	{"IntervalStyle", "postgres"},
	{"extra_float_digits", "3"},
	{"TimeZone", "UTC"},
	{"lc_monetary", "C"},
	{NULL, NULL}
};

/* The SQLSTATE of the error run_in_subxact() last caught. */
int			last_subxact_errcode = 0;

/*
 * Run fn(arg) inside a subtransaction so an error in it settles just the one
 * thing being done (recording one detection, or verifying one queue
 * entry) rather than aborting the caller's transaction.  Callers use *arg
 * both to pass fn its input and to get results back; anything fn wants to
 * keep must be in *arg before it returns.
 *
 * This switches back to the caller's memory context before calling fn, so
 * what fn palloc's is not freed when the subtransaction ends.  That covers
 * the strings SPI_getvalue() returns: it allocates them in the current
 * context, which inside an SPI call is SPI's procCxt, a child of
 * TopTransactionContext rather than of the subtransaction, and
 * AtEOSubXact_SPI() throws away a tuptable only when the subtransaction
 * aborts, in which case there was nothing to copy out anyway.
 *
 * On success, returns true.  On error, the subtransaction is rolled back,
 * *errmsg is set to the caught message (palloc'd in the caller's context),
 * its SQLSTATE is left in last_subxact_errcode, and this returns false.  A
 * query cancel (statement_timeout included) is not caught: it is raised
 * again after the rollback, so it stops the whole call.
 */
bool
run_in_subxact(void (*fn) (void *arg), void *arg, char **errmsg)
{
	MemoryContext oldcontext = CurrentMemoryContext;
	ResourceOwner oldowner = CurrentResourceOwner;

	*errmsg = NULL;

	BeginInternalSubTransaction("spock_toast_divergence");
	MemoryContextSwitchTo(oldcontext);

	PG_TRY();
	{
		fn(arg);
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcontext);
		CurrentResourceOwner = oldowner;
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		MemoryContextSwitchTo(oldcontext);
		edata = CopyErrorData();
		FlushErrorState();
		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcontext);
		CurrentResourceOwner = oldowner;

		if (edata->sqlerrcode == ERRCODE_QUERY_CANCELED)
			ReThrowError(edata);
		last_subxact_errcode = edata->sqlerrcode;
		*errmsg = pstrdup(edata->message ? edata->message : "unknown error");
		FreeErrorData(edata);
		return false;
	}
	PG_END_TRY();

	return true;
}

/*
 * This node's Spock node id: for mapping origin 0 in a local stamp, and for
 * the repair worker's origin decisions.  Read once per process; 0
 * until a local node exists.  Needs a transaction the first time.
 */
uint32
cached_local_nodeid(void)
{
	static uint32 nodeid = 0;

	if (nodeid == 0)
	{
		SpockLocalNode *node = get_local_node(false, true);

		if (node != NULL)
			nodeid = node->node->id;
	}
	return nodeid;
}

/*
 * The owner of relid.  Repair reads and writes of a user table run as that
 * user, as the apply worker's writes do, so code they run (casts and
 * operators of the key and column types, domain constraints, triggers
 * enabled ALWAYS or REPLICA, CHECK constraints, index expressions,
 * generated columns) does not run as the superuser the worker connects as.
 */
Oid
table_owner(Oid relid)
{
	HeapTuple	tp = SearchSysCache1(RELOID, ObjectIdGetDatum(relid));
	Oid			owner;

	if (!HeapTupleIsValid(tp))
		elog(ERROR, "cache lookup failed for relation %u", relid);
	owner = ((Form_pg_class) GETSTRUCT(tp))->relowner;
	ReleaseSysCache(tp);
	return owner;
}

/*
 * Switch to owner, a table's owner, for one statement, in a GUC nest level
 * of its own, and return that level for owner_leave(), which switches back
 * and rolls the level back.  An error in between needs neither: aborting the
 * (sub)transaction resets the user and the GUC nest level.
 *
 * SwitchToUntrustedUser() opens a nest level only for an owner who cannot
 * SET ROLE back to this user.  For one who can, such as any superuser, a
 * SET in a trigger or function the statement runs would otherwise outlast
 * it, and a SET search_path would replace TOAST_SEARCH_PATH for every later
 * statement in the session.
 */
int
owner_enter(Oid owner, UserContext *ucxt)
{
	int			nestlevel = NewGUCNestLevel();

	SwitchToUntrustedUser(owner, ucxt);
	return nestlevel;
}

void
owner_leave(UserContext *ucxt, int nestlevel)
{
	RestoreUserContext(ucxt);
	AtEOXact_GUC(false, nestlevel);
}

/* SPI_execute() as the owner of relid (owner_enter()). */
int
spi_execute_as_owner(Oid relid, const char *sql, long count)
{
	UserContext ucxt;
	int			nestlevel;
	int			ret;

	nestlevel = owner_enter(table_owner(relid), &ucxt);
	ret = SPI_execute(sql, false, count);
	owner_leave(&ucxt, nestlevel);
	return ret;
}
