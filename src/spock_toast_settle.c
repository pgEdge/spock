/*-------------------------------------------------------------------------
 *
 * spock_toast_settle.c
 *		Settling one entry against the winning node's row
 *
 * A repair is a delayed re-application of the winner's row through the same
 * conflict rule the apply worker uses.  For one confirmed entry, in its own
 * transaction, with the winner's current values for the suspect columns and
 * the origin and commit timestamp of the winner's row already fetched: lock
 * the local row and read its origin and commit timestamp, point the origin
 * session globals at the winner, and let try_resolve_conflict() decide.  If the winner wins,
 * UPDATE the columns that still differ; the transaction commits stamped with
 * the winner row's timestamp and origin, and spock.repair_mode(true) keeps
 * the output plugin from replicating it back.
 *
 * One top-level transaction per entry: a transaction has one commit
 * timestamp and one origin, and each entry needs its own.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/commit_ts.h"
#include "access/detoast.h"
#include "access/xact.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/resowner.h"

#include "spock.h"
#include "spock_common.h"
#include "spock_conflict.h"
#include "spock_toast_internal.h"
#include "spock_toast_stamp.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

/*
 * The local row as settle_one() read it under its row lock, per suspect
 * column: the value as text (only for a column the winner's differs in;
 * see settle_one()) and whether it is NULL.  Then the row's commit origin
 * and timestamp.
 */
typedef struct LocalRow
{
	char	  **val;
	bool	   *null;
	RepOriginId origin;
	TimestampTz ts;
} LocalRow;

/*
 * Origin and commit timestamp of a local row from its xmin, the way
 * get_tuple_origin() reads them for the apply worker.  A frozen or
 * bootstrap xid reads as no origin and timestamp zero, so the winner's row
 * wins.  Only the repair worker calls this, and it runs only with
 * track_commit_timestamp on, which cannot change without a restart.
 */
static void
local_row_origin(const char *xmin_text, RepOriginId *origin, TimestampTz *ts)
{
	TransactionId xmin = (TransactionId) strtoul(xmin_text, NULL, 10);

	*origin = InvalidRepOriginId;
	*ts = 0;

	if (!TransactionIdIsNormal(xmin))
		return;
	if (!TransactionIdGetCommitTsData(xmin, ts, origin))
	{
		*origin = InvalidRepOriginId;
		*ts = 0;
	}
}

/*
 * Delete the entry, if it is still the one the batch read, and report
 * outcome; an entry locked or recorded again since is left waiting.
 */
RepairOutcome
settle_drop(RepairEntry *e, RepairOutcome outcome)
{
	if (!suspect_delete(e))
		return REPAIR_WAITING;
	return outcome;
}

/*
 * UPDATE the local row, setting each column with write[i] to the winner's
 * value (text form, remote_val).
 */
static void
write_columns(RepairEntry *e, const bool *write, char **remote_val,
			  const bool *remote_null)
{
	UserContext ucxt;
	StringInfoData q;
	Oid		   *argtypes = palloc(e->ncols * sizeof(Oid));
	Datum	   *values = palloc(e->ncols * sizeof(Datum));
	char	   *nulls = palloc(e->ncols);
	int			n = 0;
	int			i;
	int			nestlevel;
	int			ret;

	initStringInfo(&q);
	appendStringInfo(&q, "UPDATE %s SET ", e->qualname);
	for (i = 0; i < e->ncols; i++)
	{
		if (!write[i])
			continue;
		if (n > 0)
			appendStringInfoString(&q, ", ");
		appendStringInfo(&q, "%s = $%d::%s", e->colnames[i], n + 1, e->coltypes[i]);
		argtypes[n] = TEXTOID;
		if (remote_null[i])
		{
			values[n] = (Datum) 0;
			nulls[n] = 'n';
		}
		else
		{
			values[n] = CStringGetTextDatum(remote_val[i]);
			nulls[n] = ' ';
		}
		n++;
	}
	appendStringInfo(&q, " WHERE %s", e->where_clause);

	nestlevel = owner_enter(table_owner(e->relid), &ucxt);
	ret = SPI_execute_with_args(q.data, n, argtypes, values, nulls, false, 0);
	owner_leave(&ucxt, nestlevel);
	if (ret != SPI_OK_UPDATE)
		elog(ERROR, "SPI failed repairing the row: %d", ret);
	if (SPI_processed != 1)
		elog(ERROR, "repair UPDATE changed " UINT64_FORMAT " rows, expected 1",
			 (uint64) SPI_processed);
}

/*
 * Rewrite the row setting column col to itself.  The new row version gets
 * the calling (sub)transaction's stamp, while the TOAST value keeps its
 * chunks: PostgreSQL reuses an out-of-line value whose pointer is unchanged.
 */
static void
self_assign(RepairEntry *e, int col)
{
	char	   *q = psprintf("UPDATE %s SET %s = %s WHERE %s", e->qualname,
							 e->colnames[col], e->colnames[col], e->where_clause);
	int			ret = spi_execute_as_owner(e->relid, q, 0);

	if (ret != SPI_OK_UPDATE)
		elog(ERROR, "SPI_execute failed restamping the row: %d", ret);
	if (SPI_processed != 1)
		elog(ERROR, "restamping UPDATE changed " UINT64_FORMAT " rows, expected 1",
			 (uint64) SPI_processed);
	pfree(q);
}

/*
 * Run write_columns() in a subtransaction stamped (ts, nodeid), so what it
 * writes carries that commit timestamp and origin after the top-level
 * commit.  No PG_TRY: an
 * error aborts the whole settle transaction, which unwinds this too.  The
 * caller's handler must use AbortOutOfAnyTransaction(): called inside a
 * subtransaction, AbortCurrentTransaction() can abort just that level and
 * leave the top-level transaction aborted but open.
 */
static void
write_stamped(RepairEntry *e, const bool *write, char **remote_val,
			  const bool *remote_null, TimestampTz ts, RepOriginId nodeid)
{
	MemoryContext oldcxt = CurrentMemoryContext;
	ResourceOwner oldowner = CurrentResourceOwner;

	BeginInternalSubTransaction("spock_toast_repair");
	MemoryContextSwitchTo(oldcxt);
	write_columns(e, write, remote_val, remote_null);
	toast_stamp_set_subxact_commit_ts(ts, nodeid);
	ReleaseCurrentSubTransaction();
	MemoryContextSwitchTo(oldcxt);
	CurrentResourceOwner = oldowner;
}

/*
 * Write the winner's values for the columns in write[], each stamped with
 * the winner's version stamp for that value (stamp[], text form), one
 * subtransaction per distinct stamp.  So every node that holds this version
 * holds it under the same stamp, and the next cross-node update finds them
 * equal.  A column without a usable winner stamp is stamped with this node
 * and the current time: no other node ever applied that write, so it can
 * never match anything; stamping it with the winner row's stamp instead
 * would name an update that did not write this value, and two nodes
 * repaired from different values under that row stamp would then match.
 *
 * Returns the first column written, for the caller's restamping of the row.
 */
static int
write_with_value_stamps(RepairEntry *e, const bool *write, char **remote_val,
						const bool *remote_null, char **stamp)
{
	bool	   *done = palloc0(e->ncols * sizeof(bool));
	bool	   *group = palloc(e->ncols * sizeof(bool));
	int			first = -1;
	int			i,
				j;

	for (i = 0; i < e->ncols; i++)
	{
		SpockToastStamp st;
		bool		have;

		if (!write[i] || done[i])
			continue;
		if (first < 0)
			first = i;
		have = toast_stamp_from_text(stamp[i], &st);

		memset(group, 0, e->ncols * sizeof(bool));
		for (j = i; j < e->ncols; j++)
		{
			SpockToastStamp sj;
			bool		have_j;

			if (!write[j] || done[j])
				continue;
			have_j = toast_stamp_from_text(stamp[j], &sj);
			if (have_j != have ||
				(have && (sj.nodeid != st.nodeid || sj.ts != st.ts)))
				continue;
			group[j] = true;
			done[j] = true;
		}
		if (have)
			write_stamped(e, group, remote_val, remote_null, st.ts,
						  (RepOriginId) st.nodeid);
		else
			write_stamped(e, group, remote_val, remote_null,
						  GetCurrentTimestamp(), InvalidRepOriginId);
	}
	pfree(done);
	pfree(group);
	return first;
}

/* Whether a local and a remote column value differ (text forms). */
static inline bool
values_differ(bool lnull, const char *lval, bool rnull, const char *rval)
{
	return lnull != rnull || (!lnull && strcmp(lval, rval) != 0);
}

/* Keep this transaction's writes out of replication. */
static void
enable_repair_mode(void)
{
	/*
	 * What spock.repair_mode(true) does, without its monitor event, which
	 * every repaired row would add.
	 */
	(void) skip_wal_records_decoding(true);
}

/* Nothing this process writes from here on carries a foreign origin. */
void
clear_origin_globals(void)
{
	replorigin_session_origin = InvalidRepOriginId;
	replorigin_session_origin_timestamp = 0;
	replorigin_session_origin_lsn = InvalidXLogRecPtr;
}

/* suspect_mark() for a repair entry, as read by the batch. */
void
entry_mark(RepairEntry *e, const char *state, const char *error)
{
	(void) suspect_mark(e, state, error,
						NULL, NULL, NULL);
}

/*
 * Lock the local row FOR NO KEY UPDATE and read it into *lr: xmin, and
 * the suspect columns as text.  Returns how many rows the key matched;
 * *lr is filled only when that is 1.
 *
 * A column the fetch found equal on the winner is read only as NULL or not,
 * an empty string standing in for its text: every use below compares it
 * with itself, so the large value is not converted for nothing.
 *
 * When another column is about to be written, an equal column is read as
 * its hash instead, to check it has not been written here since the
 * fetch: the row then takes the winner's stamp, and a value written in
 * between would be left under it, never to be recorded again.
 */
static uint64
lock_local_row(RepairEntry *e, WinnerRow *w, bool any_diff, LocalRow *lr)
{
	StringInfoData q;
	char	   *xmin_text;
	int			ret;
	int			i;

	initStringInfo(&q);
	appendStringInfoString(&q, "SELECT xmin::text");
	for (i = 0; i < e->ncols; i++)
	{
		if (w->present && !w->diff[i] && any_diff)
			appendStringInfo(&q, ", " COLUMN_HASH_SQL, e->colnames[i]);
		else if (w->present && !w->diff[i])
			appendStringInfo(&q, ", CASE WHEN %s IS NOT NULL THEN '' END", e->colnames[i]);
		else
			appendStringInfo(&q, ", %s::text", e->colnames[i]);
	}
	appendStringInfo(&q, " FROM %s t WHERE %s FOR NO KEY UPDATE",
					 e->qualname, e->where_clause);
	ret = spi_execute_as_owner(e->relid, q.data, 2);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute failed locking the local row: %d", ret);
	if (SPI_processed != 1)
		return SPI_processed;
	xmin_text = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
	lr->val = palloc(e->ncols * sizeof(char *));
	lr->null = palloc(e->ncols * sizeof(bool));
	for (i = 0; i < e->ncols; i++)
	{
		lr->val[i] = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, i + 2);
		lr->null[i] = (lr->val[i] == NULL);
	}
	local_row_origin(xmin_text, &lr->origin, &lr->ts);
	return 1;
}

/*
 * Whether a column the fetch found equal on the winner was written here
 * since.  lock_local_row() reads such a column as its hash when another
 * column is about to be written; the row then takes the winner's stamp, and
 * a value written in between would be left under it, never to be recorded
 * again.
 */
static bool
equal_columns_changed(RepairEntry *e, WinnerRow *w, const LocalRow *lr)
{
	int			i;

	for (i = 0; i < e->ncols; i++)
	{
		if (w->diff[i])
			continue;
		if ((lr->val[i] == NULL) != (e->local_hash[i] == NULL) ||
			(lr->val[i] != NULL && strcmp(lr->val[i], e->local_hash[i]) != 0))
			return true;
	}
	return false;
}

/*
 * Settle one confirmed entry inside the current transaction, given the
 * winner's row data already fetched into *w.  On return the caller commits
 * (the origin globals hold the stamp the written row needs, and are clear
 * when nothing was written) or the caller sees an ERROR and aborts.
 *
 * The local row is locked FOR NO KEY UPDATE for the whole transaction, so
 * an apply worker updating the same row waits for our commit and then sees
 * our row.  A re-detection that committed before the lock was taken has
 * already raised detect_count, so the guarded updates and delete below
 * leave that entry for the next pass.
 */
RepairOutcome
settle_one(RepairEntry *e, WinnerRow *w)
{
	Oid			local_nodeid = cached_local_nodeid();
	uint64		nrows;
	LocalRow	lr;
	char	  **remote_val;
	bool	   *remote_null;
	bool	   *write;
	int			i,
				ndiff = 0;
	bool		apply;
	HeapTuple	dummy;
	SpockConflictResolution resolution;
	bool		any_diff = false;

	if (w->present)
		for (i = 0; i < e->ncols; i++)
			any_diff |= w->diff[i];

	nrows = lock_local_row(e, w, any_diff, &lr);
	if (nrows == 0)
		return settle_drop(e, REPAIR_DROPPED);
	if (nrows > 1)
	{
		entry_mark(e, e->orig_state, "key matched more than one local row");
		return REPAIR_FAILED;
	}

	if (any_diff && equal_columns_changed(e, w, &lr))
	{
		entry_mark(e, e->orig_state,
				   "the row changed here after it was compared with the winner; compared again on the next pass");
		return REPAIR_WAITING;
	}

	if (!w->present)
	{
		entry_mark(e, "remote_missing", NULL);
		return REPAIR_REMOTE_MISSING;
	}

	/*
	 * Columns the fetch marked as not differing stand in for the local value:
	 * they carry nothing to write and must not count toward ndiff.
	 *
	 * Trusting w->diff[i] == false (the column matched at fetch time) is safe
	 * even though the hash it was compared against was taken in an earlier
	 * transaction: the row was re-read just above under FOR NO KEY UPDATE. A
	 * remote-wins apply on the row since the hash was taken bumps
	 * detect_count (re-detection), which makes this guarded settle a no-op. A
	 * local write does not bump it, but it gives the local row a newer commit
	 * timestamp, so the conflict rule below keeps the local row, and the
	 * write itself replicates the changed column normally.  Either way a
	 * stale "matches" here cannot leave a divergence.
	 */
	remote_val = palloc(e->ncols * sizeof(char *));
	remote_null = palloc(e->ncols * sizeof(bool));
	for (i = 0; i < e->ncols; i++)
	{
		if (!w->diff[i])
		{
			remote_null[i] = lr.null[i];
			remote_val[i] = lr.val[i];
		}
		else
		{
			remote_null[i] = (w->val[i] == NULL);
			remote_val[i] = w->val[i];
		}
	}

	/*
	 * The winner's copy of this row is our own update, which reached the
	 * winner with the suspect column unchanged.  Our row is the whole truth
	 * for this version and the winner has recorded its own suspect: its
	 * conflict rule sees our origin on both its row and ours, takes the
	 * same-origin shortcut and repairs toward us.  Nothing to write here.
	 *
	 * try_resolve_conflict() cannot answer this one: both rows carry the same
	 * commit timestamp (the winner applied our transaction), and the
	 * tiebreaker would compare this node against itself.
	 *
	 * That holds only while the winner's row is not newer than ours.  A
	 * winner's row can carry our node id from an older write forwarded to it
	 * while it is newer along another path, so a newer winner row, or a local
	 * row whose timestamp cannot be read, goes to the conflict rule below,
	 * whose same-origin rule applies the newer row.  It also assumes the
	 * winner has spock.toast_divergence_detection on; with it off the winner
	 * records nothing of its own, a known limit.
	 *
	 * It covers only the columns our update wrote.  A suspect column our
	 * update left alone still holds the value that lost, and keeps it here.
	 */
	if (OidIsValid(local_nodeid) && w->origin == (RepOriginId) local_nodeid &&
		lr.ts != 0 && timestamptz_cmp_internal(w->ts, lr.ts) <= 0)
		return settle_drop(e, REPAIR_DROPPED);

	/*
	 * Hand the decision to the conflict rule, exactly as the apply worker
	 * would for a row that had just arrived from the winner.  It reads the
	 * remote side from the session globals and does not touch the relation or
	 * tuple arguments, so those are NULL; the caller resets the globals.
	 */
	replorigin_session_origin = w->origin;
	replorigin_session_origin_timestamp = w->ts;
	replorigin_session_origin_lsn = InvalidXLogRecPtr;

	/*
	 * The winner no longer keeps its row's commit timestamp: the row is older
	 * than the winner's commit timestamp horizon, and the conflict rule would
	 * keep the local row whatever it holds.  A local row last written by the
	 * winner node holds the winner's change or an older one, so the winner's
	 * row is at least as new and is applied.  Otherwise this node cannot
	 * tell which row is newer, and the entry is dropped with a warning
	 * naming the row rather than retried on every pass.
	 */
	if (w->ts == 0)
		apply = (lr.origin == (RepOriginId) e->winner_node_id);
	else
		apply = try_resolve_conflict(NULL, NULL, NULL, &dummy,
									 lr.origin, lr.ts, &resolution);
	if (!apply)
	{
		/*
		 * The local row is newer, so it stays as it is, and so does any
		 * suspect column its update left alone, though that column may
		 * still hold the value that lost.
		 */
		clear_origin_globals();
		if (w->ts == 0)
			ereport(WARNING,
					(errmsg("SPOCK toast repair: dropped the entry for row %s of %s unrepaired: the winning node no longer keeps its row's commit timestamp",
							e->pkey, e->qualname),
					 errhint("Compare the row with ACE.")));
		return settle_drop(e, REPAIR_DROPPED);
	}

	/* Which columns still differ?  Only those are written. */
	write = palloc(e->ncols * sizeof(bool));
	for (i = 0; i < e->ncols; i++)
	{
		write[i] = values_differ(lr.null[i], lr.val[i],
								 remote_null[i], remote_val[i]);
		if (write[i])
			ndiff++;
	}
	if (ndiff == 0)
	{
		/* The winner stamp is for a written repair only. */
		clear_origin_globals();
		return settle_drop(e, REPAIR_DROPPED);
	}

	enable_repair_mode();

	/*
	 * The values get their own version stamps in subtransactions, then one
	 * rewrite of the row in the top-level transaction gives the row the
	 * winner row's stamp (set in the origin globals above) while the chunks
	 * keep theirs.  A winner row with no readable commit timestamp (frozen)
	 * stays that old, as conflict resolution treats it: a 0 here would be
	 * replaced by the current time at commit, and the repaired row could then
	 * beat a change still on the way.
	 */
	if (replorigin_session_origin_timestamp == 0)
		replorigin_session_origin_timestamp = 1;
	self_assign(e, write_with_value_stamps(e, write, remote_val,
										   remote_null, w->stamp));

	/*
	 * The row is written; drop the entry in the same transaction.  If the
	 * guarded delete finds a newer detect_count (a re-detection committed
	 * between the batch read and the row lock), the entry stays for the next
	 * pass.
	 */
	return settle_drop(e, REPAIR_REPAIRED);
}
