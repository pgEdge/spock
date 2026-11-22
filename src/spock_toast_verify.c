/*-------------------------------------------------------------------------
 *
 * spock_toast_verify.c
 *		spock.toast_divergence_verify()
 *
 * Checks suspect entries against the winning node without changing any
 * user row: an entry whose columns match is deleted, and one that differs
 * is confirmed with the columns that differ.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/commit_ts.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "utils/builtins.h"

#include "spock_toast_divergence.h"
#include "spock_toast_internal.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

PG_FUNCTION_INFO_V1(spock_toast_divergence_verify);

typedef struct ToastVerifyCounts
{
	int			cleared;
	int			confirmed;
	int			remote_missing;
	int			failed;
} ToastVerifyCounts;

/*
 * Write one entry's verify outcome, counting it if the guarded write still
 * found the entry (suspect_mark()).
 */
static void
verify_settle(RepairEntry *e, WinnerRow *w, ToastVerifyCounts *counts)
{
	StringInfoData diff;
	int			c;

	switch (w->status)
	{
		case WINNER_DROP:
			if (suspect_delete(e))
				counts->cleared++;
			return;
		case WINNER_FAIL:
			if (suspect_mark(e, e->orig_state,
							 w->err, NULL, NULL, NULL))
				counts->failed++;
			return;
		case WINNER_SETTLE:
			break;
		default:
			elog(ERROR, "unexpected winner fetch status %d in verify", w->status);
	}

	if (!w->present)
	{
		if (suspect_mark(e, "remote_missing",
						 NULL, NULL, NULL, NULL))
			counts->remote_missing++;
		return;
	}

	initStringInfo(&diff);
	for (c = 0; c < e->ncols; c++)
		if (w->diff[c])
			appendStringInfo(&diff, "%s%d", diff.len == 0 ? "{" : ",",
							 e->attnums[c]);
	if (diff.len == 0)
	{
		if (suspect_delete(e))
			counts->cleared++;
		return;
	}
	appendStringInfoChar(&diff, '}');

	/*
	 * The winner row's current commit timestamp and origin replace the
	 * entry's.
	 */
	if (suspect_mark(e, "confirmed", NULL,
					 diff.data,
					 w->ts == 0 ? NULL :
					 DatumGetCString(DirectFunctionCall1(timestamptz_out,
														 TimestampTzGetDatum(w->ts))),
					 w->origin == InvalidRepOriginId ? NULL :
					 psprintf("%u", (unsigned int) w->origin)))
		counts->confirmed++;
}

/*
 * spock.toast_divergence_verify(max_rows)
 *
 * Check up to max_rows pending suspects against the node that won, without
 * repairing anything: one batched read hashes the local rows, and one
 * query per winner and table shape asks which columns differ.  Equal
 * hashes delete the entry, a difference confirms it and records which
 * columns differ and the winner row's current commit timestamp and origin,
 * a row missing on the winner is marked remote_missing and left, a row
 * missing here is deleted, and an entry that cannot be checked keeps its
 * state with last_error set.
 *
 * Every outcome is decided before any is written.  Writing marks the
 * spock.toast_suspect row, and the apply worker's upsert of the same key
 * waits on that until the caller's transaction ends, so the writes come
 * last, in one short pass after the remote round trips.
 *
 * Text-output settings are pinned by the SQL function's SET clauses.
 */
Datum
spock_toast_divergence_verify(PG_FUNCTION_ARGS)
{
	int32		max_rows = PG_GETARG_INT32(0);
	TupleDesc	tupdesc;
	Datum		result[4];
	bool		resnulls[4] = {false, false, false, false};
	ToastVerifyCounts counts = {0};
	MemoryContext cxt,
				rowscxt,
				oldcxt;
	RepairEntry *entries;
	RepairEntry **ptrs;
	WinnerRow  *rows;
	int			n,
				i;
	List	   *volatile conns = NIL;

	if (max_rows < 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("max_rows must not be negative")));

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	if (!track_commit_timestamp)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("TOAST divergence verification requires track_commit_timestamp = on")));

	/* fetch_wave() keeps the connection cells in the parent of rows' context. */
	cxt = AllocSetContextCreate(CurrentMemoryContext, "toast verify",
								ALLOCSET_DEFAULT_SIZES);
	rowscxt = AllocSetContextCreate(cxt, "toast verify rows",
									ALLOCSET_DEFAULT_SIZES);

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed in spock_toast_divergence_verify");

	PG_TRY();
	{
		entries = read_entries(max_rows, cxt, &n);
		if (n > 0)
		{
			oldcxt = MemoryContextSwitchTo(cxt);
			ptrs = palloc(n * sizeof(RepairEntry *));
			for (i = 0; i < n; i++)
				ptrs[i] = &entries[i];
			rows = MemoryContextAllocZero(rowscxt, n * sizeof(WinnerRow));
			fetch_wave(ptrs, n, (List **) &conns, rows);
			MemoryContextSwitchTo(oldcxt);

			for (i = 0; i < n; i++)
				verify_settle(&entries[i], &rows[i], &counts);
		}
	}
	PG_FINALLY();
	{
		verify_conns_close(conns);
	}
	PG_END_TRY();

	SPI_finish();
	MemoryContextDelete(cxt);

	tupdesc = BlessTupleDesc(tupdesc);
	result[0] = Int32GetDatum(counts.cleared);
	result[1] = Int32GetDatum(counts.confirmed);
	result[2] = Int32GetDatum(counts.remote_missing);
	result[3] = Int32GetDatum(counts.failed);
	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, result, resnulls)));
}
