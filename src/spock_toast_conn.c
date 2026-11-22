/*-------------------------------------------------------------------------
 *
 * spock_toast_conn.c
 *		Connections to the winning nodes for verify
 *
 * One libpq connection per winning node, with the text-output settings pinned
 * so a value hashes the same on both nodes.  Waits on a connection keep the
 * backend responsive to interrupts.
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

/* Ask the winner to cancel conn's running query; a failure is ignored. */
static void
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
 * backend, and SIGTERM in a background worker (got_SIGTERM), are acted on
 * while the winner is still working.  The query on the winner is cancelled
 * first.
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
	 * The winner fetch reads the row's commit timestamp, and reading it
	 * raises an error when the setting is off.  Refuse the connection once
	 * rather than fail every query on it.
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

/* The connection to use for subid this call, added to *conns. */
VerifyConn *
verify_conn_get(List **conns, Oid subid)
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
	 * hold is closed however this call ends, by verify_conns_close().
	 */
	vc = palloc0(sizeof(VerifyConn));
	vc->subid = subid;
	*conns = lappend(*conns, vc);

	if (!run_in_subxact(verify_conn_cb, vc, &errmsg))
		vc->error = errmsg;
	if (vc->error != NULL && vc->conn != NULL)
	{
		PQfinish(vc->conn);
		vc->conn = NULL;
	}

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
