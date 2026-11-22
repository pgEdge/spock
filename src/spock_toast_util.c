/*-------------------------------------------------------------------------
 *
 * spock_toast_util.c
 *		Helpers shared by the TOAST divergence code
 *
 * Helpers the TOAST divergence code shares: running one step in a
 * subtransaction, so an error settles only that step (run_in_subxact()).
 * It also holds the text-output settings pinned while a row's key is
 * rendered (toast_pinned_output).
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "utils/resowner.h"

#include "spock.h"
#include "spock_toast_internal.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

/*
 * The text-output settings pinned while a row's key is rendered, so the
 * stored key reads back as the same row whatever the session's own
 * settings, as {name, value} pairs ending in NULLs.
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

/*
 * Run fn(arg) inside a subtransaction so an error in it settles just the one
 * thing being done (recording one detection) rather than aborting the
 * caller's transaction.  Callers use *arg both to pass fn its input and to
 * get results back; anything fn wants to keep must be in *arg before it
 * returns.
 *
 * This switches back to the caller's memory context before calling fn, so
 * what fn palloc's is not freed when the subtransaction ends.
 *
 * On success, returns true.  On error, the subtransaction is rolled back,
 * *errmsg is set to the caught message (palloc'd in the caller's context),
 * and this returns false.
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

		*errmsg = pstrdup(edata->message ? edata->message : "unknown error");
		FreeErrorData(edata);
		return false;
	}
	PG_END_TRY();

	return true;
}
