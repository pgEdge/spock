/*-------------------------------------------------------------------------
 *
 * spock_toast_fetch.c
 *		Fetching the winning node's rows for a batch of entries
 *
 * Entries are grouped by winner, table and key and column shape; each group is
 * one query on the winner that compares the winner's column hashes with the
 * local ones carried in its parameter.  Groups on different winners run at the
 * same time.
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
#include "executor/spi.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"

#include "libpq-fe.h"

#include "spock.h"
#include "spock_node.h"
#include "spock_toast_internal.h"
#include "spock_toast_stamp.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

/*
 * One (winner, table, key/column shape) group within a wave: the entries that
 * share one hash-guarded query, and the connection that query runs on.
 */
typedef struct FetchGroup
{
	int		   *idx;			/* indexes into the wave's entries[]/rows[] */
	int			nidx;
	VerifyConn *vc;				/* winner connection (vc->conn may be NULL) */
	char	   *sql;			/* the group's hash-guarded query */
	char	   *param;			/* $1: jsonb array of keys + local hashes */
	bool		sent;			/* query dispatched, result not yet drained */
	bool		done;			/* result drained, or the group was failed */
} FetchGroup;

static void fetch_groups(RepairEntry **entries, int n, List **conns,
						 WinnerRow *rows, bool retry,
						 MemoryContext rescxt, MemoryContext conncxt);

/* Fail every entry of a group with err, and mark the group done. */
static void
group_fail(FetchGroup *g, WinnerRow *rows, char *err)
{
	int			k;

	for (k = 0; k < g->nidx; k++)
	{
		rows[g->idx[k]].status = WINNER_FAIL;
		rows[g->idx[k]].err = err;
	}
	g->done = true;
}

/*
 * Classify each entry of a wave before fetching: only the fetchable ones
 * (WINNER_SETTLE) are grouped and queried; the rest are settled without
 * asking the winner.
 */
static void
classify_entries(RepairEntry **entries, int n, WinnerRow *rows)
{
	int			i;

	for (i = 0; i < n; i++)
	{
		RepairEntry *e = entries[i];
		WinnerRow  *w = &rows[i];

		memset(w, 0, sizeof(*w));

		if (!e->table_exists || e->ncols == 0)
			w->status = WINNER_DROP;
		else if (!entry_usable(e))
		{
			w->status = WINNER_FAIL;
			w->err = "key columns not found in the local table";
		}

		/* No local row, nothing to converge: no need to ask the winner. */
		else if (e->local == LOCAL_MISSING)
			w->status = WINNER_DROP;
		else if (e->local == LOCAL_MULTI)
		{
			w->status = WINNER_FAIL;
			w->err = "key matched more than one local row";
		}
		else if (e->local == LOCAL_ERROR)
		{
			w->status = WINNER_FAIL;
			w->err = e->local_err;
		}
		else
		{
			Assert(e->local == LOCAL_FOUND);
			w->status = WINNER_SETTLE;	/* present stays false until a row
										 * comes back */
		}
	}
}

/*
 * The winner fetch for one group (fetch_wave()).  Result columns:
 * __pkey__, per suspect column cN_diff, then ts and origin.
 */
static char *
build_fetch_sql(const RepairEntry *base)
{
	StringInfoData sql;
	int			c;

	initStringInfo(&sql);

	/*
	 * The hash-guarded query: per suspect column a diff flag (the winner's
	 * hash differs from the local one carried in the key row), plus the
	 * winner row's commit timestamp and origin.  Identifiers and types come
	 * from the local catalog via the entry; only the keys and hashes cross as
	 * the one jsonb parameter.
	 */
	appendStringInfoString(&sql, "SELECT x.__pkey__");
	for (c = 0; c < base->ncols; c++)
		appendStringInfo(&sql, ", (" COLUMN_HASH_SQL " IS DISTINCT FROM x.h%d) AS c%d_diff",
						 base->colnames[c], c, c);
	appendStringInfoString(&sql,
						   ", (spock.xact_commit_timestamp_origin(t.xmin)).timestamp::text AS ts"
						   ", (spock.xact_commit_timestamp_origin(t.xmin)).roident::text AS origin");
	appendStringInfoString(&sql,
						   " FROM jsonb_to_recordset($1::jsonb) AS x(k jsonb, __pkey__ text");
	for (c = 0; c < base->ncols; c++)
		appendStringInfo(&sql, ", h%d text", c);
	appendStringInfo(&sql, ") " KEY_FROM_PARAM " JOIN %s t ON %s",
					 base->pkcols_text, base->qualname, base->pkjoin);
	return sql.data;
}

/*
 * Group a wave's WINNER_SETTLE entries, one group per (winner, table,
 * key/column shape), or with retry its WINNER_RETRY entries, one group per
 * entry, and build each group's query and parameter.  A grouped entry's
 * status becomes WINNER_SETTLE.  The connection cells outlive the wave, so they are
 * resolved in conncxt; a winner with no usable connection fails its whole
 * group now.
 */
static FetchGroup *
build_fetch_groups(RepairEntry **entries, int n, WinnerRow *rows,
				   List **conns, MemoryContext conncxt, bool retry,
				   int *ngroups)
{
	WinnerFetchStatus pick = retry ? WINNER_RETRY : WINNER_SETTLE;
	FetchGroup *groups = palloc0(n * sizeof(FetchGroup));
	bool	   *grouped = palloc0(n * sizeof(bool));
	int		   *members = palloc(n * sizeof(int));
	int			i;

	*ngroups = 0;
	for (i = 0; i < n; i++)
	{
		RepairEntry *base = entries[i];
		FetchGroup *g;
		StringInfoData params;
		int			j;

		if (grouped[i] || rows[i].status != pick)
			continue;

		g = &groups[(*ngroups)++];
		members[0] = i;
		g->nidx = 1;
		grouped[i] = true;
		rows[i].status = WINNER_SETTLE;

		for (j = i + 1; j < n && !retry; j++)
		{
			if (!grouped[j] && rows[j].status == pick &&
				entries[j]->subid == base->subid &&
				same_shape(base, entries[j]))
			{
				grouped[j] = true;
				rows[j].status = WINNER_SETTLE;
				members[g->nidx++] = j;
			}
		}
		/* Sized to the group: a retry makes one group per entry. */
		g->idx = palloc(g->nidx * sizeof(int));
		memcpy(g->idx, members, g->nidx * sizeof(int));

		g->sql = build_fetch_sql(base);

		/* $1: the group's keys and local hashes (append_key_object()). */
		initStringInfo(&params);
		appendStringInfoChar(&params, '[');
		for (j = 0; j < g->nidx; j++)
		{
			if (j > 0)
				appendStringInfoChar(&params, ',');
			append_key_object(&params, entries[g->idx[j]], true);
		}
		appendStringInfoChar(&params, ']');
		g->param = params.data;

		{
			MemoryContext oldcxt = MemoryContextSwitchTo(conncxt);

			g->vc = verify_conn_get(conns, base->subid);
			MemoryContextSwitchTo(oldcxt);
		}
		if (g->vc->conn == NULL)
			group_fail(g, rows, g->vc->error);
	}
	pfree(members);
	pfree(grouped);
	return groups;
}

/*
 * Match each row of a group's result to its entry by __pkey__ and fill its
 * WinnerRow (columns as build_fetch_sql() lists them).  Values are copied
 * into rescxt.
 */
static void
parse_winner_rows(PGresult *res, FetchGroup *g, RepairEntry **entries,
				  WinnerRow *rows, MemoryContext rescxt)
{
	int			nt = PQntuples(res);
	int			ncols = entries[g->idx[0]]->ncols;
	int			tsidx = 1 + ncols;
	int			oidx = 2 + ncols;
	int			t;
	int			k;

	for (t = 0; t < nt; t++)
	{
		const char *pk = PQgetvalue(res, t, 0);
		RepairEntry *e = NULL;
		WinnerRow  *w = NULL;
		char	   *ts_text;
		char	   *origin_text;
		int			c;

		CHECK_FOR_INTERRUPTS();
		for (k = 0; k < g->nidx; k++)
		{
			if (strcmp(entries[g->idx[k]]->pkey, pk) == 0)
			{
				e = entries[g->idx[k]];
				w = &rows[g->idx[k]];
				break;
			}
		}
		if (w == NULL)			/* a key we did not ask for */
			continue;

		/*
		 * The key matched more than one row on the winner, as after its
		 * replica identity was widened there.  Comparing either row could
		 * settle the entry wrongly, as on the local side (LOCAL_MULTI).
		 */
		if (w->status == WINNER_FAIL)
			continue;
		if (w->present)
		{
			w->status = WINNER_FAIL;
			w->err = "key matched more than one row on the winning node";
			continue;
		}

		w->present = true;
		w->diff = MemoryContextAlloc(rescxt, ncols * sizeof(bool));
		for (c = 0; c < ncols; c++)
			w->diff[c] = (PQgetvalue(res, t, 1 + c)[0] == 't');

		ts_text = PQgetisnull(res, t, tsidx) ? NULL :
			PQgetvalue(res, t, tsidx);
		origin_text = PQgetisnull(res, t, oidx) ? NULL :
			PQgetvalue(res, t, oidx);
		w->ts = ts_text == NULL ? 0 :
			DatumGetTimestampTz(DirectFunctionCall3(timestamptz_in,
													CStringGetDatum(ts_text),
													ObjectIdGetDatum(InvalidOid),
													Int32GetDatum(-1)));
		w->origin = origin_text == NULL ? InvalidRepOriginId :
			(RepOriginId) strtoul(origin_text, NULL, 10);

		/*
		 * A winner's row with roident 0 was written by the winner itself, so
		 * its own node id is the origin to record.  So is a row whose origin
		 * can no longer be read (its commit timestamp is gone): nothing says
		 * which node wrote it, and the winner stands in.
		 */
		if (w->origin == InvalidRepOriginId)
			w->origin = (RepOriginId) e->winner_node_id;
	}
}

void
fetch_wave(RepairEntry **entries, int n, List **conns, WinnerRow *rows)
{
	MemoryContext rescxt = GetMemoryChunkContext(rows);
	MemoryContext conncxt = MemoryContextGetParent(rescxt);
	int			attempt;

	classify_entries(entries, n, rows);

	/*
	 * A group's query can fail for one entry's sake, for example a key value
	 * the winner cannot read.  Such a group's entries are fetched again one
	 * at a time in a second attempt, so the failure stays with that entry.
	 */
	for (attempt = 0; attempt < 2; attempt++)
		fetch_groups(entries, n, conns, rows, attempt > 0, rescxt, conncxt);
}

/*
 * One fetch_wave() attempt: group the entries (the first attempt) or take
 * the WINNER_RETRY ones singly (the second), and run the groups' queries.
 *
 * It fetches the winner's rows for one wave of entries, one grouped
 * hash-guarded query per (winner, table, key/column shape), and fills
 * rows[i] for each entry.
 *
 * PQsendQueryParams allows one outstanding query per connection, so the
 * queries go out in send/drain rounds: each round sends at most one pending
 * group per connection, then drains them.  Different winners run their
 * queries in parallel, and a winner with several groups takes them one at a
 * time.  Results are waited for through conn_get_result(), so a cancel or
 * shutdown is acted on while a winner is still working.
 *
 * Holds no row locks.  The results (the WinnerRow arrays and values) are
 * allocated in the context rows[] came from, and the connection cells,
 * which must outlive the wave, in its parent.
 */
static void
fetch_groups(RepairEntry **entries, int n, List **conns, WinnerRow *rows,
			 bool retry, MemoryContext rescxt, MemoryContext conncxt)
{
	FetchGroup *groups;
	int			ngroups;
	int			first_pending = 0;
	int			gi;

	groups = build_fetch_groups(entries, n, rows, conns, conncxt,
								retry, &ngroups);

	/*
	 * Send/drain rounds.  Each round sends at most one pending group per
	 * connection, then drains every connection that has an outstanding query,
	 * so a winner with several groups is handled one round trip at a time
	 * while different winners run in parallel.
	 */
	for (;;)
	{
		int			nsent = 0;
		int			maxsend = list_length(*conns);

		/*
		 * Send phase: one pending group per idle connection.  Groups before
		 * first_pending are all sent or done, and the scan stops once as
		 * many queries are out as there are connections, so a retry of
		 * many single-entry groups on one winner does not rescan them all
		 * every round.
		 */
		while (first_pending < ngroups &&
			   (groups[first_pending].done || groups[first_pending].sent))
			first_pending++;
		for (gi = first_pending; gi < ngroups && nsent < maxsend; gi++)
		{
			FetchGroup *g = &groups[gi];

			if (g->done || g->sent)
				continue;

			/*
			 * A sibling group draining on this same connection may have found
			 * it broken and closed it this wave (the PQfinish + NULL below).
			 * Fail this group explicitly rather than call PQsendQueryParams
			 * on a NULL conn, which libpq tolerates but reports as the
			 * misleading "connection pointer is NULL".
			 */
			if (g->vc->conn == NULL)
			{
				group_fail(g, rows, g->vc->error ? g->vc->error :
						   "winner connection unavailable");
				continue;
			}

			if (g->vc->busy)
				continue;

			if (!PQsendQueryParams(g->vc->conn, g->sql, 1, NULL,
								   (const char *const *) &g->param,
								   NULL, NULL, 0))
			{
				char	   *err = MemoryContextStrdup(rescxt,
													  PQerrorMessage(g->vc->conn));

				group_fail(g, rows, err);
				conn_drop_if_broken(g->vc, err, conncxt);
				continue;
			}
			g->sent = true;
			g->vc->busy = true;
			nsent++;
		}

		/*
		 * Nothing new sent means every remaining group is done: a group with
		 * an idle connection would have been sent, and none can be deferred
		 * as busy when no group was sent this round.
		 */
		if (nsent == 0)
			break;

		/* Drain phase: collect every outstanding result. */
		for (gi = 0; gi < ngroups; gi++)
		{
			FetchGroup *g = &groups[gi];
			PGresult   *res;

			if (!g->sent || g->done)
				continue;

			CHECK_FOR_INTERRUPTS();

			res = conn_get_result(g->vc->conn);
			g->vc->busy = false;
			if (res == NULL || PQresultStatus(res) != PGRES_TUPLES_OK)
			{
				char	   *err = MemoryContextStrdup(rescxt,
													  PQerrorMessage(g->vc->conn));
				const char *state = res ? PQresultErrorField(res, PG_DIAG_SQLSTATE) : NULL;

				/*
				 * Retry the entries singly only on a data exception (class
				 * 22), which one row's key or value can cause, such as an
				 * enum label the winner does not have.  Anything else is
				 * about the table, the role or the connection, a lock or
				 * statement timeout included, and each entry would only
				 * fail again, or wait it out again.
				 */
				bool		again = !retry && g->nidx > 1 && state != NULL &&
					strncmp(state, "22", 2) == 0;

				if (res != NULL)
					PQclear(res);
				while ((res = conn_get_result(g->vc->conn)) != NULL)
					PQclear(res);
				if (again)
				{
					int			k;

					for (k = 0; k < g->nidx; k++)
						rows[g->idx[k]].status = WINNER_RETRY;
					g->done = true;
				}
				else
				{
					group_fail(g, rows, err);
					conn_drop_if_broken(g->vc, err, conncxt);
				}
				continue;
			}

			/*
			 * res is malloc'd by libpq, so it is cleared on an error too.
			 */
			PG_TRY();
			{
				parse_winner_rows(res, g, entries, rows, rescxt);
			}
			PG_FINALLY();
			{
				PQclear(res);
			}
			PG_END_TRY();
			while ((res = conn_get_result(g->vc->conn)) != NULL)
				PQclear(res);
			g->done = true;
		}
	}
}
