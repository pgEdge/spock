/*-------------------------------------------------------------------------
 *
 * spock_toast_conn.c
 *		Connections to the winning nodes for verify and repair
 *
 * One libpq connection per winning node, with the text-output settings pinned
 * so a value hashes the same on both nodes.  Waits on a connection keep the
 * backend responsive to interrupts.  The repair worker keeps its connections
 * cached from one pass to the next.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/commit_ts.h"
#include "miscadmin.h"
#include "storage/latch.h"
#include "utils/wait_event.h"

#include "libpq-fe.h"

#include "spock.h"
#include "spock_node.h"
#include "spock_toast_divergence.h"
#include "spock_toast_internal.h"
#include "spock_worker.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

/*
 * The column hash depends on session text-output settings (bytea_output,
 * DateStyle, IntervalStyle, extra_float_digits, TimeZone for timestamptz, and
 * lc_monetary for money), so the same value could come out hashing
 * differently here and on the winner and be wrongly confirmed or wrongly
 * flagged as differing.  Both sides of the comparison pin the same settings
 * before hashing anything.
 *
 * On the local side, spock.toast_divergence_verify() carries these as
 * function-level SET clauses in the extension script
 * (sql/spock--6.0.0--6.1.0.sql).
 * PostgreSQL applies them on entry and restores the caller's own values on
 * exit, error included, so there is nothing to set or undo here in the C
 * code.  On the remote side, this string is sent once per connection to the
 * winning node, below in verify_conn_get().
 *
 * spock_connect() already forces DateStyle, IntervalStyle and
 * extra_float_digits on the peer, the way it does for every replication
 * connection, so only the other three are left to set here.
 *
 * The string also pins search_path, as the function's SET clauses do
 * locally, so the queries sent to the winner cannot call a function or
 * operator another user created there in place of a built-in one.
 */
#define PIN_OUTPUT_SETTINGS_SQL \
	"SET search_path = " TOAST_SEARCH_PATH "; " \
	"SET bytea_output = 'hex'; " \
	"SET TimeZone = 'UTC'; " \
	"SET lc_monetary = 'C'"

/*
 * Connections the repair worker keeps between passes, one per winner
 * subscription, so a worker that runs a pass every few hundred
 * milliseconds does not reconnect to every winner each time.  The cells
 * live in TopMemoryContext.  During a pass, verify_conn_get() lends a
 * cached handle to the pass's own VerifyConn cell, and the pass may close
 * it there on an error; conn_cache_return() then reconciles the two at the
 * end of the pass, so the cache never holds a handle the pass closed.
 * spock.toast_divergence_verify() does not use the cache.
 */
typedef struct CachedConn
{
	Oid			subid;
	PGconn	   *conn;
	TimestampTz opened_at;
} CachedConn;

static List *conn_cache = NIL;

/* Ask the winner to cancel conn's running query; a failure is ignored. */
void
conn_cancel(PGconn *conn)
{
	PGcancel   *cancel = PQgetCancel(conn);
	char		errbuf[256];

	if (cancel != NULL)
	{
		(void) PQcancel(cancel, errbuf, sizeof(errbuf));
		PQfreeCancel(cancel);
	}
}

/*
 * PQgetResult() that waits on the latch and the socket rather than inside
 * libpq, so a query cancel, statement_timeout or termination of this
 * backend, and SIGTERM in the repair worker, are acted on while the winner
 * is still working.  The query on the winner is cancelled first.
 */
PGresult *
conn_get_result(PGconn *conn)
{
	while (PQisBusy(conn))
	{
		int			rc;

		rc = WaitLatchOrSocket(MyLatch,
							   WL_LATCH_SET | WL_SOCKET_READABLE | WL_EXIT_ON_PM_DEATH,
							   PQsocket(conn), -1L);
		if (rc & WL_LATCH_SET)
		{
			ResetLatch(MyLatch);
			if (QueryCancelPending || ProcDiePending || got_SIGTERM)
			{
				conn_cancel(conn);
				CHECK_FOR_INTERRUPTS();
				if (got_SIGTERM)
					ereport(ERROR,
							(errcode(ERRCODE_ADMIN_SHUTDOWN),
							 errmsg("cancelled the query on the winning node to shut down")));
			}
			CHECK_FOR_INTERRUPTS();
		}
		if ((rc & WL_SOCKET_READABLE) && !PQconsumeInput(conn))
			break;
	}
	return PQgetResult(conn);
}

/* PQexec() through conn_get_result(): the last result, NULL if not sent. */
static PGresult *
conn_exec(PGconn *conn, const char *sql)
{
	PGresult   *last = NULL;
	PGresult   *res;

	if (!PQsendQuery(conn, sql))
		return NULL;
	while ((res = conn_get_result(conn)) != NULL)
	{
		if (last != NULL)
			PQclear(last);
		last = res;
	}
	return last;
}

/*
 * Look the subscription up and open the connection to its origin.  Both steps
 * report failure with ereport(ERROR), so this runs through run_in_subxact():
 * one bad winner_subid or one unreachable origin must become a failed entry,
 * not abort the whole call.  vc->conn is set as soon as the connection exists
 * so that the caller closes it if a later step throws or sets vc->error.
 */
static void
verify_conn_cb(void *arg)
{
	VerifyConn *vc = (VerifyConn *) arg;
	SpockSubscription *sub;
	PGresult   *res;

	if (!OidIsValid(vc->subid))
	{
		vc->error = pstrdup("the winning change was forwarded by another node and cannot be verified against it");
		return;
	}

	/* Raises "subscription %u not found" if it was dropped. */
	sub = get_subscription(vc->subid);

	vc->conn = spock_connect(sub->origin_if->dsn, sub->name, "toastdiv");

	res = conn_exec(vc->conn, PIN_OUTPUT_SETTINGS_SQL);
	if (PQresultStatus(res) != PGRES_COMMAND_OK)
	{
		/* A connection that cannot be pinned is no use for comparing. */
		vc->error = psprintf("could not pin output settings on the origin of subscription %s: %s",
							 sub->name, PQerrorMessage(vc->conn));
		PQclear(res);
		return;
	}
	PQclear(res);

	/*
	 * The repair worker's queries on the winner give up on a lock as its
	 * local ones do (spock.toast_divergence_lock_timeout), so a table locked
	 * there for long, as by VACUUM FULL, fails its own entries instead of
	 * holding up every repair.  The worker closes its cached connections
	 * when the setting is reloaded.  verify() leaves it to the caller's
	 * statement_timeout.
	 */
	if (vc->for_repair)
	{
		char	   *sql = psprintf("SET lock_timeout = %d",
								   spock_toast_divergence_lock_timeout);

		res = conn_exec(vc->conn, sql);
		pfree(sql);
		if (PQresultStatus(res) != PGRES_COMMAND_OK)
		{
			vc->error = psprintf("could not set lock_timeout on the origin of subscription %s: %s",
								 sub->name, PQerrorMessage(vc->conn));
			PQclear(res);
			return;
		}
		PQclear(res);
	}

	/*
	 * The winner's commit timestamp decides the repair and stamps it, and
	 * reading it raises an error when the setting is off.  Refuse the
	 * connection once rather than fail every query on it.
	 */
	res = conn_exec(vc->conn, "SHOW track_commit_timestamp");
	if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1 ||
		strcmp(PQgetvalue(res, 0, 0), "on") != 0)
	{
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
			vc->error = psprintf("could not read track_commit_timestamp on the origin of subscription %s: %s",
								 sub->name, PQerrorMessage(vc->conn));
		else
			vc->error = psprintf("track_commit_timestamp is off on the origin of subscription %s",
								 sub->name);
		PQclear(res);
		return;
	}
	PQclear(res);
}

static CachedConn *
conn_cache_find(Oid subid)
{
	ListCell   *lc;

	foreach(lc, conn_cache)
	{
		CachedConn *cc = (CachedConn *) lfirst(lc);

		if (cc->subid == subid)
			return cc;
	}
	return NULL;
}

static void
conn_cache_add(Oid subid, PGconn *conn)
{
	MemoryContext oldcxt = MemoryContextSwitchTo(TopMemoryContext);
	CachedConn *cc = palloc(sizeof(CachedConn));

	cc->subid = subid;
	cc->conn = conn;
	cc->opened_at = GetCurrentTimestamp();
	conn_cache = lappend(conn_cache, cc);
	MemoryContextSwitchTo(oldcxt);
}

/* Forget a cached handle; close it too when close_conn is set. */
static void
conn_cache_forget(CachedConn *cc, bool close_conn)
{
	if (close_conn)
		PQfinish(cc->conn);
	conn_cache = list_delete_ptr(conn_cache, cc);
	pfree(cc);
}

/*
 * Before a pass: close connections past spock.toast_divergence_conn_lifetime,
 * and any the other side closed while it sat idle.  PQconsumeInput() reads
 * whatever is waiting on the socket without a round trip and reports a
 * connection that has gone away.
 */
void
conn_cache_prune(void)
{
	TimestampTz now = GetCurrentTimestamp();
	ListCell   *lc;

	foreach(lc, conn_cache)
	{
		CachedConn *cc = (CachedConn *) lfirst(lc);

		if (TimestampDifferenceExceeds(cc->opened_at, now,
									   spock_toast_divergence_conn_lifetime * 1000) ||
			!PQconsumeInput(cc->conn) ||
			PQstatus(cc->conn) != CONNECTION_OK ||
			PQtransactionStatus(cc->conn) != PQTRANS_IDLE)
		{
			PQfinish(cc->conn);
			pfree(cc);
			conn_cache = foreach_delete_current(conn_cache, lc);
		}
	}
}

/*
 * After a failed query: if the connection itself is broken, close it and
 * keep err (copied into cxt) as the reason, so later entries for the same
 * winner fail at once instead of each paying for a round trip.
 */
void
conn_drop_if_broken(VerifyConn *vc, const char *err, MemoryContext cxt)
{
	if (PQstatus(vc->conn) == CONNECTION_OK)
		return;
	vc->error = MemoryContextStrdup(cxt, err);
	PQfinish(vc->conn);
	vc->conn = NULL;
}

/*
 * After a pass: keep each connection the pass used if it is still idle and
 * healthy, and the pass did not end in an error that may have left a query
 * running on it.  A cell whose handle the pass already closed (conn NULL)
 * just drops out of the cache.
 */
void
conn_cache_return(List *conns, bool pass_ok)
{
	ListCell   *lc;

	foreach(lc, conns)
	{
		VerifyConn *vc = (VerifyConn *) lfirst(lc);
		CachedConn *cc = conn_cache_find(vc->subid);

		if (vc->conn == NULL)
		{
			if (cc != NULL)
				conn_cache_forget(cc, false);
			continue;
		}

		if (!pass_ok || spock_toast_divergence_conn_lifetime <= 0 ||
			PQstatus(vc->conn) != CONNECTION_OK ||
			PQtransactionStatus(vc->conn) != PQTRANS_IDLE)
		{
			if (cc != NULL)
				conn_cache_forget(cc, false);
			PQfinish(vc->conn);
			vc->conn = NULL;
		}
	}
}

/* Close every cached connection; the repair worker calls this on exit. */
void
toast_divergence_close_cached_conns(void)
{
	while (conn_cache != NIL)
		conn_cache_forget((CachedConn *) linitial(conn_cache), true);
}

/*
 * The connection to use for subid this call, added to *conns.  With
 * use_cache (the repair worker), a cached connection is lent and a new one
 * is cached; verify() opens its own.
 */
VerifyConn *
verify_conn_get(List **conns, Oid subid, bool use_cache)
{
	ListCell   *lc;
	VerifyConn *vc;
	char	   *errmsg;

	foreach(lc, *conns)
	{
		vc = (VerifyConn *) lfirst(lc);
		if (vc->subid == subid)
			return vc;
	}

	/*
	 * On the list before anything can throw, so the connection it is about to
	 * hold is closed however this call ends: by verify_conns_close() for
	 * verify(), or kept or closed by conn_cache_return() for the worker.
	 */
	vc = palloc0(sizeof(VerifyConn));
	vc->subid = subid;
	vc->for_repair = use_cache;
	*conns = lappend(*conns, vc);

	if (use_cache)
	{
		CachedConn *cc = conn_cache_find(subid);

		if (cc != NULL)
		{
			vc->conn = cc->conn;
			return vc;
		}
	}

	if (!run_in_subxact(verify_conn_cb, vc, &errmsg))
		vc->error = errmsg;
	if (vc->error != NULL)
	{
		if (vc->conn != NULL)
			PQfinish(vc->conn);
		vc->conn = NULL;
	}
	else if (use_cache)
		conn_cache_add(subid, vc->conn);

	return vc;
}

void
verify_conns_close(List *conns)
{
	ListCell   *lc;

	foreach(lc, conns)
	{
		VerifyConn *vc = (VerifyConn *) lfirst(lc);

		if (vc->conn == NULL)
			continue;
		/*
		 * A query still out would otherwise run on after the call returns.
		 * PQcancel() connects to the winner without a timeout, so with the
		 * winner unreachable this can wait out the kernel's connect timeout,
		 * as conn_get_result()'s own cancel can.
		 */
		if (PQtransactionStatus(vc->conn) == PQTRANS_ACTIVE)
			conn_cancel(vc->conn);
		PQfinish(vc->conn);
	}
}
