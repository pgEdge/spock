/*-------------------------------------------------------------------------
 *
 * spock_toast_fetch.c
 *		Fetching the winning node's rows for a batch of entries
 *
 * Entries are grouped by winner, table and key and column shape; each group is
 * one query on the winner that compares the winner's column hashes with the
 * local ones carried in its parameter.  Groups on different winners run at the
 * same time.  On the winner the query runs as the table's owner, through
 * spock.toast_read_as_owner().  For a repair it also returns each value that
 * differs.
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
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif

#include "libpq-fe.h"

#include "spock.h"
#include "spock_common.h"
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
						 WinnerRow *rows, bool for_repair, bool retry,
						 MemoryContext rescxt, MemoryContext conncxt);

/*
 * spock.toast_read_as_owner(rel regclass, query text, param jsonb,
 *							 nstamp integer)
 *
 * Run query, a read of rel sent by a node checking its TOAST suspects
 * against this one, with param as $1, as rel's owner, and return its rows.
 * The query casts columns to text and matches keys with their types' casts
 * and operators, all of which the owner of a type can define.  Run as the
 * connecting role, often a superuser, that code would run with the role's
 * rights, so it runs here as the table's owner, as the repair worker's own
 * reads do: in a GUC nest level of its own (owner_enter()), and with
 * SECURITY_RESTRICTED_OPERATION for an owner who cannot SET ROLE back to
 * the caller.  The function's own SET clause is not enough: a plain SET in
 * code the query runs would outlast the function, and the caller's
 * connection is kept for later fetches.
 * The owner's row level security settings apply, so policies only under
 * FORCE ROW LEVEL SECURITY.
 *
 * The caller must be a member of the owner's role.  On PostgreSQL 15 that
 * is the same as being able to SET ROLE to it; from 16 a membership can
 * lack the SET option, and SwitchToUntrustedUser() then refuses the switch
 * itself.  Either way this gives the caller nothing SET ROLE would not.
 *
 * The last nstamp columns of the query are values of the table's columns:
 * their version stamps (spock.toast_stamp() text) are returned in their
 * place, read after switching back, since the owner may have no rights on
 * schema spock.  Every other column must already have the type the column
 * definition list of the call gives it.
 */
PG_FUNCTION_INFO_V1(spock_toast_read_as_owner);
Datum
spock_toast_read_as_owner(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);
	char	   *query = text_to_cstring(PG_GETARG_TEXT_PP(1));
	int			nstamp = PG_GETARG_INT32(3);
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	Oid			argtypes[1] = {JSONBOID};
	Datum		args[1];
	TupleDesc	outdesc;
	TupleDesc	spidesc;
	SpockLocalNode *local_node;
	uint32		local_nodeid;
	UserContext ucxt;
	Oid			owner;
	int			nestlevel;
	Datum	   *values;
	bool	   *nulls;
	uint64		r;
	int			natts;
	int			ret;
	int			i;

	InitMaterializedSRF(fcinfo, MAT_SRF_USE_EXPECTED_DESC);
	outdesc = rsinfo->setDesc;
	natts = outdesc->natts;
	if (nstamp < 0 || nstamp > natts)
		elog(ERROR, "nstamp %d is out of range for %d result columns", nstamp, natts);

	if (!SearchSysCacheExists1(RELOID, ObjectIdGetDatum(relid)))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_TABLE),
				 errmsg("relation with OID %u does not exist", relid)));
	owner = table_owner(relid);
	if (!is_member_of_role(GetUserId(), owner))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("SPOCK: permission denied to read table \"%s\" as its owner",
						get_rel_name(relid)),
				 errdetail("Only members of the table owner's role may.")));

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed in spock_toast_read_as_owner");
	args[0] = PG_GETARG_DATUM(2);
	nestlevel = owner_enter(owner, &ucxt);
	ret = SPI_execute_with_args(query, 1, argtypes, args, NULL, true, 0);
	owner_leave(&ucxt, nestlevel);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "spock_toast_read_as_owner: the query is not a SELECT");

	spidesc = SPI_tuptable->tupdesc;
	if (spidesc->natts != natts)
		elog(ERROR, "the query returns %d columns, the column definition list has %d",
			 spidesc->natts, natts);
	for (i = 0; i < natts; i++)
	{
		Oid			want = TupleDescAttr(outdesc, i)->atttypid;

		if (i >= natts - nstamp ? want != TEXTOID :
			want != TupleDescAttr(spidesc, i)->atttypid)
			elog(ERROR, "result column %d has the wrong type", i + 1);
	}

	local_node = get_local_node(false, true);
	local_nodeid = local_node ? local_node->node->id : 0;
	values = palloc(natts * sizeof(Datum));
	nulls = palloc(natts * sizeof(bool));
	for (r = 0; r < SPI_processed; r++)
	{
		HeapTuple	tup = SPI_tuptable->vals[r];

		for (i = 0; i < natts; i++)
		{
			Datum		d = SPI_getbinval(tup, spidesc, i + 1, &nulls[i]);

			if (i >= natts - nstamp)
			{
				SpockToastStamp stamp;

				if (!nulls[i] && TupleDescAttr(spidesc, i)->attlen == -1 &&
					toast_stamp_read(d, local_nodeid, &stamp))
					d = CStringGetTextDatum(toast_stamp_to_text(&stamp));
				else
					nulls[i] = true;
			}
			else if (!nulls[i] && TupleDescAttr(spidesc, i)->attlen == -1 &&
					 VARATT_IS_EXTERNAL(DatumGetPointer(d)))
			{
				/* Do not hand a TOAST pointer out of the function. */
				d = PointerGetDatum(detoast_external_attr((struct varlena *) DatumGetPointer(d)));
			}
			values[i] = d;
		}
		tuplestore_putvalues(rsinfo->setResult, outdesc, values, nulls);
	}
	SPI_finish();
	return (Datum) 0;
}

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
 * (WINNER_SETTLE) are grouped and queried; the rest the fused pass settles
 * directly.
 */
static void
classify_entries(RepairEntry **entries, int n, WinnerRow *rows,
				 bool for_repair)
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

		/*
		 * The winner subscription was dropped, typically because its node
		 * left the cluster: there is nothing left to repair from, and the
		 * entry would otherwise wait forever and count toward the cap.
		 * Entries that never had one (forwarded changes) are kept for the
		 * user.  verify() reports both as failed (verify_conn_cb()).
		 */
		else if (for_repair && OidIsValid(e->subid) && !e->sub_exists)
			w->status = WINNER_ORPHAN;
		else if (for_repair && !e->sub_enabled)
			w->status = WINNER_WAIT;

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
 * __pkey__, per suspect column cN_diff and cN_val, then ts, origin, and
 * per suspect column cN_stamp.
 *
 * The read hashes each column once, in a lateral subquery that OFFSET 0
 * keeps the planner from pulling up (it would copy the hash into each
 * use), and returns a value only when its hash differs, so a row that
 * has already converged costs the winner its hashes alone.
 *
 * Without for_repair (verify()) the values and the stamps come back NULL and
 * are not computed: verify() needs only the diff flags.
 */
static char *
build_fetch_sql(const RepairEntry *base, bool for_repair)
{
	StringInfoData inner;
	StringInfoData sql;
	int			c;

	/*
	 * The read of the table, which the winner runs as the table's owner
	 * (spock.toast_read_as_owner()): per suspect column a diff flag (the
	 * winner's hash differs from the local one carried in the key row) and,
	 * for a repair, the value as text when it differs; the row's xmin; and
	 * for a repair each column itself, whose version stamp comes back in
	 * its place.  Identifiers and types come from the local catalog via the
	 * entry; only the keys and hashes cross as the one jsonb parameter.
	 */
	initStringInfo(&inner);
	appendStringInfoString(&inner, "SELECT x.__pkey__");
	for (c = 0; c < base->ncols; c++)
	{
		appendStringInfo(&inner, ", d.d%d", c);
		if (for_repair)
			appendStringInfo(&inner, ", CASE WHEN d.d%d THEN t.%s::text END",
							 c, base->colnames[c]);
	}
	appendStringInfoString(&inner, ", t.xmin::text");
	if (for_repair)
	{
		for (c = 0; c < base->ncols; c++)
			appendStringInfo(&inner, ", t.%s", base->colnames[c]);
	}
	appendStringInfoString(&inner,
						   " FROM jsonb_to_recordset($1::jsonb) AS x(k jsonb, __pkey__ text");
	for (c = 0; c < base->ncols; c++)
		appendStringInfo(&inner, ", h%d text", c);
	appendStringInfo(&inner, ") " KEY_FROM_PARAM " JOIN %s t ON %s",
					 base->pkcols_text, base->qualname, base->pkjoin);
	appendStringInfoString(&inner, " CROSS JOIN LATERAL (SELECT ");
	for (c = 0; c < base->ncols; c++)
		appendStringInfo(&inner, "%s(" COLUMN_HASH_SQL " IS DISTINCT FROM x.h%d) AS d%d",
						 c > 0 ? ", " : "", base->colnames[c], c, c);
	appendStringInfoString(&inner, " OFFSET 0) d");

	/*
	 * The rest runs as the connecting role, on what the read returned: the
	 * row's commit timestamp and origin come from its xmin.
	 */
	initStringInfo(&sql);
	appendStringInfoString(&sql, "SELECT __pkey__");
	for (c = 0; c < base->ncols; c++)
	{
		if (for_repair)
			appendStringInfo(&sql, ", c%d_diff, c%d_raw AS c%d_val", c, c, c);
		else
			appendStringInfo(&sql, ", c%d_diff, NULL::text AS c%d_val", c, c);
	}
	appendStringInfoString(&sql, ", ts, origin");
	for (c = 0; c < base->ncols; c++)
	{
		if (for_repair)
			appendStringInfo(&sql, ", c%d_stamp", c);
		else
			appendStringInfo(&sql, ", NULL::text AS c%d_stamp", c);
	}
	appendStringInfoString(&sql,
						   " FROM (SELECT q.*"
						   ", (spock.xact_commit_timestamp_origin(q.xmin::xid)).timestamp::text AS ts"
						   ", (spock.xact_commit_timestamp_origin(q.xmin::xid)).roident::text AS origin");
	appendStringInfo(&sql, " FROM spock.toast_read_as_owner(%s::regclass, %s, $1::jsonb, %d) AS q(__pkey__ text",
					 quote_literal_cstr(base->qualname), quote_literal_cstr(inner.data),
					 for_repair ? base->ncols : 0);
	for (c = 0; c < base->ncols; c++)
	{
		appendStringInfo(&sql, ", c%d_diff boolean", c);
		if (for_repair)
			appendStringInfo(&sql, ", c%d_raw text", c);
	}
	appendStringInfoString(&sql, ", xmin text");
	if (for_repair)
	{
		for (c = 0; c < base->ncols; c++)
			appendStringInfo(&sql, ", c%d_stamp text", c);
	}
	appendStringInfoString(&sql, ")) q");
	pfree(inner.data);
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
				   List **conns, MemoryContext conncxt, bool for_repair,
				   bool retry, int *ngroups)
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

		g->sql = build_fetch_sql(base, for_repair);

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

			g->vc = verify_conn_get(conns, base->subid, for_repair);
			MemoryContextSwitchTo(oldcxt);
		}
		if (g->vc->conn == NULL)
			group_fail(g, rows, g->vc->error ? g->vc->error :
					   "winner connection unavailable");
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
	int			tsidx = 1 + 2 * ncols;
	int			oidx = 2 + 2 * ncols;
	int			sidx = 3 + 2 * ncols;
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
		w->val = MemoryContextAlloc(rescxt, ncols * sizeof(char *));
		w->stamp = MemoryContextAlloc(rescxt, ncols * sizeof(char *));
		for (c = 0; c < ncols; c++)
		{
			const char *d = PQgetvalue(res, t, 1 + 2 * c);

			w->stamp[c] = PQgetisnull(res, t, sidx + c) ? NULL :
				MemoryContextStrdup(rescxt, PQgetvalue(res, t, sidx + c));
			w->diff[c] = (d[0] == 't');
			if (w->diff[c] && !PQgetisnull(res, t, 2 + 2 * c))
				w->val[c] = MemoryContextStrdup(rescxt,
												PQgetvalue(res, t, 2 + 2 * c));
			else
				w->val[c] = NULL;
		}

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
		 * its own node id is the origin to use; the apply worker already
		 * stamped the losing local row with that same node id, so the
		 * conflict rule's same-origin shortcut needs the two to match.  A
		 * row whose origin can no longer be read (its commit timestamp is
		 * gone) is given the winner's node id too: nothing says which node
		 * wrote it, and settle_one() handles such a row on its own.
		 */
		if (w->origin == InvalidRepOriginId)
			w->origin = (RepOriginId) e->winner_node_id;
	}
}

void
fetch_wave(RepairEntry **entries, int n, List **conns, WinnerRow *rows,
		   bool for_repair)
{
	MemoryContext rescxt = GetMemoryChunkContext(rows);
	MemoryContext conncxt = MemoryContextGetParent(rescxt);
	int			attempt;

	classify_entries(entries, n, rows, for_repair);

	/*
	 * A group's query can fail for one entry's sake, for example a key value
	 * the winner cannot read.  Such a group's entries are fetched again one
	 * at a time in a second attempt, so the failure stays with that entry.
	 */
	for (attempt = 0; attempt < 2; attempt++)
		fetch_groups(entries, n, conns, rows, for_repair, attempt > 0,
					 rescxt, conncxt);
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
 * Holds no row locks; the per-entry settle that follows takes the lock.
 * Results (the WinnerRow arrays and values) are allocated in the context
 * rows[] came from (the caller's per-wave context), and the connection
 * cells, which must outlive the wave, in its parent (the per-pass context).
 */
static void
fetch_groups(RepairEntry **entries, int n, List **conns, WinnerRow *rows,
			 bool for_repair, bool retry, MemoryContext rescxt,
			 MemoryContext conncxt)
{
	FetchGroup *groups;
	int			ngroups;
	int			first_pending = 0;
	int			gi;

	groups = build_fetch_groups(entries, n, rows, conns, conncxt, for_repair,
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
