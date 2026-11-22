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
#include "utils/datum.h"
#include "utils/resowner.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif

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
 * see settle_one()), whether it is NULL, its version stamp, its raw size
 * when stored out of line (-1 otherwise), and whether its TOAST pointer is
 * still the one recorded at detection.  Then the row's commit origin and
 * timestamp.
 */
typedef struct LocalRow
{
	char	  **val;
	bool	   *null;
	char	  **stamp;
	int32	   *rawsize;
	bool	   *kept;
	RepOriginId origin;
	TimestampTz ts;
} LocalRow;

/* Input for heal_columns_cb(), run through run_in_subxact(). */
typedef struct HealArg
{
	RepairEntry *e;
	WinnerRow  *w;
	const LocalRow *lr;
} HealArg;

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
 * Read the columns with write[i] from the local row as stored, for
 * write_columns() to write back as new values.  An out-of-line value is
 * fetched without decompressing it, so the copy keeps the exact stored bytes
 * (compressed or not, and with the same compression method) whatever the
 * column's settings are now; text output and input could re-encode it.
 * The copies stay in the current memory context.
 *
 * A column with a typmod (varchar(n), numeric(p,s), arrays of them) still
 * passes through its length-coercion function, which detoasts the value.
 * The value is unchanged, but an array rebuilt that way can come out with a
 * different raw size than the winner's stamp names, so the next cross-node
 * update records the row again: an extra check, never a wrong match.
 */
static void
copy_local_columns(RepairEntry *e, const bool *write, Oid *argtypes,
				   Datum *values, char *nulls)
{
	StringInfoData q;
	int		   *col = palloc(e->ncols * sizeof(int));
	int			n = 0;
	int			i;
	int			ret;

	initStringInfo(&q);
	appendStringInfoString(&q, "SELECT ");
	for (i = 0; i < e->ncols; i++)
	{
		if (!write[i])
			continue;
		appendStringInfo(&q, "%s%s", n > 0 ? ", " : "", e->colnames[i]);
		col[n++] = i;
	}
	appendStringInfo(&q, " FROM %s WHERE %s", e->qualname, e->where_clause);
	ret = spi_execute_as_owner(e->relid, q.data, 2);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute failed reading the local row: %d", ret);
	if (SPI_processed != 1)
		elog(ERROR, "reading the local row found " UINT64_FORMAT " rows, expected 1",
			 (uint64) SPI_processed);

	for (i = 0; i < n; i++)
	{
		bool		isnull;
		Datum		d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
									  i + 1, &isnull);

		argtypes[i] = SPI_gettypeid(SPI_tuptable->tupdesc, i + 1);
		nulls[i] = isnull ? 'n' : ' ';
		if (isnull)
			values[i] = (Datum) 0;
		else if (TupleDescAttr(SPI_tuptable->tupdesc, i)->attlen != -1)
			elog(ERROR, "column %s is not a varlena", e->colnames[col[i]]);
		else if (VARATT_IS_EXTERNAL(DatumGetPointer(d)))
			values[i] = PointerGetDatum(detoast_external_attr((struct varlena *)
															  DatumGetPointer(d)));
		else
			values[i] = datumCopy(d, false, -1);
	}
	SPI_freetuptable(SPI_tuptable);
	pfree(col);
	pfree(q.data);
}

/*
 * UPDATE the local row, setting each column with write[i] to the winner's
 * value (text form, remote_val).  With remote_val NULL, each such column is
 * set instead to a new copy of its own stored bytes (copy_local_columns()),
 * so it gets new TOAST chunks under the calling (sub)transaction's stamp;
 * healing uses this.
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

	if (remote_val == NULL)
		copy_local_columns(e, write, argtypes, values, nulls);

	initStringInfo(&q);
	appendStringInfo(&q, "UPDATE %s SET ", e->qualname);
	for (i = 0; i < e->ncols; i++)
	{
		if (!write[i])
			continue;
		if (n > 0)
			appendStringInfoString(&q, ", ");
		if (remote_val == NULL)
		{
			/* argtypes, values and nulls set by copy_local_columns() */
			appendStringInfo(&q, "%s = $%d", e->colnames[i], n + 1);
			n++;
			continue;
		}
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
	if (remote_val == NULL)
	{
		/*
		 * A generic plan keeps $n a parameter.  A custom plan would fold it
		 * into a constant, and makeConst() decompresses varlena constants.
		 * plan_cache_mode overrides CURSOR_OPT_GENERIC_PLAN when set to
		 * force_custom_plan, so it is pinned for this statement too.
		 */
		SPIPlanPtr	plan = SPI_prepare_cursor(q.data, n, argtypes,
											  CURSOR_OPT_GENERIC_PLAN);

		if (plan == NULL)
			elog(ERROR, "SPI_prepare_cursor failed: %d", SPI_result);
		/* owner_leave() rolls this back */
		(void) set_config_option("plan_cache_mode", "force_generic_plan",
								 PGC_USERSET, PGC_S_SESSION,
								 GUC_ACTION_SAVE, true, 0, false);
		ret = SPI_execute_plan(plan, values, nulls, false, 0);
		SPI_freeplan(plan);
	}
	else
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
 * Run write_columns() (or, with col >= 0, self_assign(col)) in a
 * subtransaction stamped (ts, nodeid), so what it writes carries that
 * commit timestamp and origin after the top-level commit.  No PG_TRY: an
 * error aborts the whole settle transaction, which unwinds this too.  The
 * caller's handler must use AbortOutOfAnyTransaction(): called inside a
 * subtransaction, AbortCurrentTransaction() can abort just that level and
 * leave the top-level transaction aborted but open.
 */
static void
write_stamped(RepairEntry *e, const bool *write, char **remote_val,
			  const bool *remote_null, int col, TimestampTz ts,
			  RepOriginId nodeid)
{
	MemoryContext oldcxt = CurrentMemoryContext;
	ResourceOwner oldowner = CurrentResourceOwner;

	BeginInternalSubTransaction("spock_toast_repair");
	MemoryContextSwitchTo(oldcxt);
	if (col >= 0)
		self_assign(e, col);
	else
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
			write_stamped(e, group, remote_val, remote_null, -1, st.ts,
						  (RepOriginId) st.nodeid);
		else
			write_stamped(e, group, remote_val, remote_null, -1,
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

/*
 * The entry is being dropped because the values agree, but detection saw
 * different version stamps (typically after the initial sync, CLUSTER or
 * VACUUM FULL on one node, which rewrite values under a new transaction).
 * Rewrite each such value with the winner's current version stamp, so the
 * false mismatch does not come back on the next cross-node update.
 *
 * A column is healed when its value equals the winner's (w->diff false), its
 * TOAST pointer is still the one recorded at detection (kept), the winner
 * sent a stamp that differs from the local one, and the winner's raw size
 * equals the local value's.  The equality was decided from a hash taken
 * before the row was locked; the unchanged pointer is what shows the column
 * was not written since, so the value compared is the value healed.  Without
 * it, a value written in between would get the winner's stamp for another
 * value: a wrong match.  The pointer also rules out inline values, which
 * have no chunks to stamp and would be rewritten on every pass.
 *
 * The value written is a copy of its own stored bytes (write_columns() with
 * no remote values), a new datum, so it gets new chunks; a self-assignment
 * would keep the old ones.  Copying the bytes, not going through the text
 * form, keeps exactly what was compared, whatever the column's compression
 * setting or the type's text output.  Then the row is rewritten under its
 * own current stamp, never the entry's winner stamp: the row may have
 * changed since detection, and moving its timestamp back could let an
 * older change win.
 *
 * verify() never heals.  heal_columns() runs this in a subtransaction.
 */
static void
heal_columns_now(RepairEntry *e, WinnerRow *w, const LocalRow *lr)
{
	bool	   *heal;
	bool		any = false;
	int			first;
	int			i;

	if (e->reason == NULL ||
		(strcmp(e->reason, "stamp_mismatch") != 0 &&
		 strcmp(e->reason, "no_local_stamp") != 0))
		return;

	heal = palloc0(e->ncols * sizeof(bool));
	for (i = 0; i < e->ncols; i++)
	{
		SpockToastStamp st;

		if (w->diff[i] || lr->null[i] || !lr->kept[i])
			continue;
		if (!toast_stamp_from_text(w->stamp[i], &st) ||
			st.rawsize != lr->rawsize[i])
			continue;
		if (lr->stamp[i] != NULL && strcmp(lr->stamp[i], w->stamp[i]) == 0)
			continue;
		heal[i] = true;
		any = true;
	}
	if (!any)
	{
		pfree(heal);
		return;
	}

	enable_repair_mode();
	first = write_with_value_stamps(e, heal, NULL, lr->null, w->stamp);
	write_stamped(e, NULL, NULL, NULL, first, lr->ts, lr->origin);
	pfree(heal);
}

static void
heal_columns_cb(void *arg)
{
	HealArg    *h = (HealArg *) arg;

	heal_columns_now(h->e, h->w, h->lr);
}

/*
 * heal_columns_now() in a subtransaction.  The values agree, so the entry
 * is dropped either way: a table that rejects the rewrite (a trigger that
 * raises, say) must not keep the entry failing on every pass.  The false
 * mismatch then comes back at the row's next cross-node update.
 */
static void
heal_columns(RepairEntry *e, WinnerRow *w, const LocalRow *lr)
{
	HealArg		h;
	char	   *err;

	h.e = e;
	h.w = w;
	h.lr = lr;
	if (!run_in_subxact(heal_columns_cb, &h, &err))
		ereport(LOG,
				(errmsg("SPOCK toast repair: could not restamp the equal values of a row of relation %u: %s",
						e->relid, err)));
}

/* Nothing this process writes from here on carries a foreign origin. */
void
clear_origin_globals(void)
{
	replorigin_session_origin = InvalidRepOriginId;
	replorigin_session_origin_timestamp = 0;
	replorigin_session_origin_lsn = InvalidXLogRecPtr;
}

/*
 * Lock the entry's row and check it still has the detect_count the batch
 * read.  An entry locked by another transaction, an apply worker detecting
 * the row again, counts as changed.
 */
static bool
entry_unchanged(RepairEntry *e)
{
	Oid			argtypes[4] = {ENTRY_GUARD_TYPES};
	Datum		values[4];
	int			ret;

	entry_guard_values(e, values);
	ret = SPI_execute_with_args(ENTRY_AS_READ_SQL, 4, argtypes, values, NULL,
								false, 1);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute_with_args failed locking a TOAST suspect: %d", ret);
	return SPI_processed == 1;
}

/* suspect_mark() for a repair entry, as read by the batch. */
void
entry_mark(RepairEntry *e, const char *state, const char *error)
{
	(void) suspect_mark(e, state, error,
						NULL, NULL, NULL);
}

/* Whether this node has a subscription from node origin. */
static bool
subscribes_to(RepOriginId origin)
{
	Oid			argtypes[2] = {OIDOID, OIDOID};
	Datum		values[2];
	int			ret;

	values[0] = ObjectIdGetDatum((Oid) origin);
	values[1] = ObjectIdGetDatum((Oid) cached_local_nodeid());
	ret = SPI_execute_with_args("SELECT 1 FROM spock.subscription "
								"WHERE sub_origin = $1 AND sub_target = $2",
								2, argtypes, values, NULL, true, 1);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute_with_args failed reading spock.subscription: %d", ret);
	return SPI_processed > 0;
}

/*
 * Point the entry at node origin: its subscription, origin and ts as
 * the winner's, so the next pass compares with that node; why says what
 * led there.  The caller passes the node that wrote the newer local row.
 * first_winner_ts is kept, so a node waiting on this entry still waits.
 * Without a subscription from that node (its changes are forwarded), the
 * entry keeps its state with an error saying so, and nothing is written.
 * An entry locked, or recorded again, since the batch read is left for
 * the next pass.
 */
static RepairOutcome
retarget_entry(RepairEntry *e, RepOriginId origin, TimestampTz ts,
			   const char *why)
{
	Oid			argtypes[8] = {ENTRY_GUARD_TYPES, OIDOID, TIMESTAMPTZOID, OIDOID,
	TEXTOID};
	Datum		values[8];
	int			ret;

	entry_guard_values(e, values);
	values[4] = ObjectIdGetDatum((Oid) origin);
	values[5] = TimestampTzGetDatum(ts);
	values[6] = ObjectIdGetDatum((Oid) cached_local_nodeid());
	values[7] = CStringGetTextDatum(psprintf("%s; compared with node %u next",
											 why, (unsigned int) origin));

	ret = SPI_execute_with_args(
								"UPDATE spock.toast_suspect t SET "
								"  winner_subid = sub.sub_id, winner_origin = $5, "
								"  winner_ts = $6, verified_at = now(), "
								"  last_error = $8 "
								"FROM (SELECT sub_id FROM spock.subscription "
								"      WHERE sub_origin = $5 AND sub_target = $7 "
								"      ORDER BY sub_enabled DESC, sub_id LIMIT 1) sub "
								"WHERE (t.relid, t.pkey) IN (" ENTRY_AS_READ_SQL ")",
								8, argtypes, values, NULL, false, 0);
	if (ret != SPI_OK_UPDATE)
		elog(ERROR, "SPI_execute_with_args failed updating spock.toast_suspect: %d", ret);
	if (SPI_processed == 0 && !subscribes_to(origin))
		entry_mark(e, e->orig_state,
				   psprintf("%s, and this node does not subscribe to node %u; compare the row with ACE",
							why, (unsigned int) origin));
	return REPAIR_WAITING;
}

/*
 * The local row is newer than the winner's, so the row as a whole stays.
 * But a suspect column whose TOAST pointer is the one recorded at detection
 * was not written here since: it still holds the value that lost to the
 * winner, carried forward by a newer local update that left it alone.  Give
 * those columns the winner's value, and drop the entry.
 *
 * Without this, the newer local update reaches the other nodes with the
 * column unchanged, they repair toward this node, and the whole cluster ends
 * up on the losing value.
 *
 * The write keeps the row's own commit timestamp and origin: it runs in a
 * subtransaction whose commit-timestamp entry is overridden with the row's
 * timestamp and origin, the way the apply worker stamps a forced delta
 * apply.  Stamping it with the winner's older timestamp instead would make
 * the row look older than the update other nodes already hold, and a change
 * still in flight could then resolve differently here than there.
 */
static RepairOutcome
repair_kept_columns(RepairEntry *e, WinnerRow *w, const LocalRow *lr,
					char **remote_val, const bool *remote_null)
{
	bool	   *write = palloc0(e->ncols * sizeof(bool));
	int			nwrite = 0;
	int			first;
	int			i;

	clear_origin_globals();

	for (i = 0; i < e->ncols; i++)
	{
		if (lr->kept[i] &&
			values_differ(lr->null[i], lr->val[i], remote_null[i], remote_val[i]))
		{
			write[i] = true;
			nwrite++;
		}
	}
	if (nwrite == 0)
	{
		heal_columns(e, w, lr);
		return settle_drop(e, REPAIR_DROPPED);
	}

	/*
	 * A newer row written by a third node is not proof that the kept column
	 * holds a losing value: that node may have written its update after
	 * taking a newer value for the column itself, and this node then holds
	 * the right one.  Nothing here tells the two apart, so compare with the
	 * node that wrote the row instead, on the next pass.
	 */
	if (lr->ts != 0 && lr->origin != InvalidRepOriginId &&
		lr->origin != (RepOriginId) cached_local_nodeid() &&
		lr->origin != w->origin)
		return retarget_entry(e, lr->origin, lr->ts,
							  psprintf("the newer row came from node %u",
									   (unsigned int) lr->origin));

	enable_repair_mode();

	/*
	 * The values get their own version stamps first, then the row is
	 * rewritten under its own stamp, keeping those chunks.
	 */
	first = write_with_value_stamps(e, write, remote_val, remote_null,
									w->stamp);
	write_stamped(e, NULL, NULL, NULL, first, lr->ts, lr->origin);

	return settle_drop(e, REPAIR_REPAIRED);
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
	/* The stored values, for their TOAST pointers and stamps, read in C. */
	for (i = 0; i < e->ncols; i++)
		appendStringInfo(&q, ", %s", e->colnames[i]);
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
	lr->kept = palloc(e->ncols * sizeof(bool));
	lr->stamp = palloc(e->ncols * sizeof(char *));
	lr->rawsize = palloc(e->ncols * sizeof(int32));
	for (i = 0; i < e->ncols; i++)
	{
		char	   *ptr;
		Datum		raw;
		bool		rawnull;

		lr->val[i] = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, i + 2);
		lr->null[i] = (lr->val[i] == NULL);

		/* Not written here since detection: see repair_kept_columns(). */
		ptr = NULL;
		lr->stamp[i] = NULL;
		raw = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
							e->ncols + i + 2, &rawnull);
		if (!rawnull &&
			TupleDescAttr(SPI_tuptable->tupdesc, e->ncols + i + 1)->attlen == -1)
		{
			SpockToastStamp st;

			ptr = toast_pointer_text(raw);
			if (toast_stamp_read(raw, cached_local_nodeid(), &st))
				lr->stamp[i] = toast_stamp_to_text(&st);
		}
		lr->kept[i] = (ptr != NULL && e->stored_ptr != NULL &&
					   e->stored_ptr[i] != NULL &&
					   strcmp(ptr, e->stored_ptr[i]) == 0);
		lr->rawsize[i] = ptr != NULL ? (int32) toast_raw_datum_size(raw) : -1;
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
 * How repair converges with three or more nodes.
 *
 * Each node repairs only its own rows, toward the node its entry names, and
 * decides from three things: the winner's row, the local row, and whether
 * the winner still holds an older entry of its own for the row.
 *
 *   1. The winner's row wins the conflict rule: the suspect columns that
 *      differ take the winner's values (settle_one()).
 *   2. The local row is newer: it stays.  A suspect column whose TOAST
 *      pointer is still the one recorded at detection was not written since
 *      and holds the losing value, so it takes the winner's
 *      (repair_kept_columns()).  If the newer row was written by a node
 *      other than this one and other than the writer of the winner's row,
 *      that node may have taken a newer value for the column first, so the
 *      entry is pointed at it and compared with it on the next pass
 *      (retarget_entry()).
 *   3. The winner holds an entry for the row with an older first_winner_ts:
 *      its value may be one that lost an older conflict, so this entry
 *      waits until the winner has repaired (WINNER_PENDING).  Only strictly
 *      older entries count, so two nodes never wait on each other.
 *
 * first_winner_ts is the oldest winner timestamp an entry has had.
 * Re-detection and retargeting keep it, so a later change cannot cut a wait
 * short.
 *
 * Not handled, and listed in the docs; each leaves this node on a losing
 * value until the row is detected again or ACE finds it:
 *
 *   - The node an entry is pointed at lost the same change and has not
 *     repaired yet: the values compare equal and the entry is removed.
 *   - The local and winner rows come from the same third node (the same
 *     update, or an older one on the winner), and the winner lost the
 *     column to a change this node holds: rule 1 or 2 copies its value.
 *   - Two nodes lost the same change with different values: their entries
 *     are the same age, so neither waits.
 *   - A table rewrite here between detection and repair gives the column a
 *     new TOAST pointer, and rule 2 then takes it as written here.
 *
 * Pointing the entry at the third node in the second case would only move
 * the risk: that node can hold a losing value of its own, with an entry of
 * the same age (the state n3 is in during 054 case (e)).
 */

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

	/*
	 * The winner's row was fetched before the local row was locked.  If the
	 * apply worker detected the row again in between, from another winner,
	 * that fetch is stale, and a write from it could give the row a value
	 * that has since lost.  Now that the row is locked no new detection can
	 * land, so check the entry is still the one read; the apply worker locks
	 * the same two rows in the same order.
	 */
	if (!entry_unchanged(e))
	{
		clear_origin_globals();
		return REPAIR_WAITING;
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
	 * stale "matches" here cannot leave a divergence.  Healing does write on
	 * a "matches", so it also requires the column's TOAST pointer to be the
	 * one recorded at detection (heal_columns()).
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
	 * update left alone still holds the value that lost while the winner kept
	 * its own; repair_kept_columns() gives it the winner's value, and the
	 * winner's entry then clears on equal hashes.
	 */
	if (OidIsValid(local_nodeid) && w->origin == (RepOriginId) local_nodeid &&
		lr.ts != 0 && timestamptz_cmp_internal(w->ts, lr.ts) <= 0)
		return repair_kept_columns(e, w, &lr, remote_val, remote_null);

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
	 * row is at least as new and is applied.  Otherwise the local row stays,
	 * as when it is newer, and the columns it kept from detection take the
	 * winner's value.
	 */
	if (w->ts == 0)
		apply = (lr.origin == (RepOriginId) e->winner_node_id);
	else
		apply = try_resolve_conflict(NULL, NULL, NULL, &dummy,
									 lr.origin, lr.ts, &resolution);
	if (!apply)
	{
		/*
		 * The local row is newer, so it stays.  Suspect columns written here
		 * since detection hold the newest value and are left alone; the rest
		 * still hold the value that lost and take the winner's.
		 */
		return repair_kept_columns(e, w, &lr, remote_val, remote_null);
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
		/*
		 * The winner stamp is for a written repair only: this drop writes at
		 * most a heal, which carries its own stamps.
		 */
		clear_origin_globals();
		heal_columns(e, w, &lr);
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
