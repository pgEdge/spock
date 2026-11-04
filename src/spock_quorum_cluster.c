/*-------------------------------------------------------------------------
 *
 * spock_quorum_cluster.c
 *		Quorum providers for the in-database cluster managers.
 *
 * pgraft and pgBully expose the same cluster-manager API, differing in the
 * schema it lives under and in how a member is identified:
 *
 *		<schema>.get_cluster_status()	node_id, term, leader_id, state, ...
 *		<schema>.is_leader()
 *		pgraft.get_nodes_from_raft()	JSON: id, name, address, active
 *		pgbully.peers()					node_id, conninfo, reachable, ...
 *
 * So they remain two providers, selected by distinct values of
 * spock.quorum_provider, but share one implementation here, parameterised
 * by a few SQL fragments, rather than two near-identical files drifting
 * apart.
 *
 * Identity.  Both managers speak in integer node ids and Spock speaks in
 * node names, and neither manager's key/value store can carry the mapping,
 * because both accept writes on the leader only.  The mapping is therefore
 * read, never written:
 *
 *	- pgraft names its members (pgraft.name, listed in initial_cluster), and
 *	  publishes the names.  Give the pgraft member the same name as the
 *	  Spock node and nothing else is needed.
 *	- pgBully members are PostgreSQL connection strings, and Spock already
 *	  holds one for every node in spock.node_interface.  A peer is matched
 *	  to a node by host and port, parsed by libpq on both sides.
 *
 * Liveness.  pgBully reports per-peer reachability and the time it last
 * heard from each peer.  pgraft reports raft's own view of which followers
 * are active, which only the leader has; a follower reports every member
 * live, which under the fail-safe rules is the reading that releases
 * nothing.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <signal.h>

#include "libpq-fe.h"
#include "miscadmin.h"

#include "access/xact.h"
#include "executor/spi.h"
#include "utils/builtins.h"
#include "utils/elog.h"
#include "utils/memutils.h"
#include "utils/resowner.h"
#include "utils/timeout.h"
#include "utils/timestamp.h"

#include "spock.h"
#include "spock_node.h"
#include "spock_quorum.h"

/* How a member row names its node. */
typedef enum ClusterIdentity
{
	CLUSTER_IDENTITY_NAME,		/* the row carries the Spock node name */
	CLUSTER_IDENTITY_CONNINFO	/* the row carries a libpq connection string */
} ClusterIdentity;

/*
 * What differs between the two backends.  Everything else below is shared.
 */
typedef struct ClusterApiConfig
{
	const char *schema;			/* "pgraft" or "pgbully" */
	ClusterIdentity identity;

	/* Function signatures that must exist for the backend to be usable. */
	const char *required[4];

	/*
	 * A SELECT yielding one row per member with the columns node_id
	 * (integer), name (text or NULL), conninfo (text or NULL), live (boolean)
	 * and seen (timestamptz or NULL).  It may refer to the CTE s, which holds
	 * this node's id and whether it leads.
	 */
	const char *members_sql;

	/*
	 * SQL scalar subquery yielding whether this node can reach a majority of
	 * the members, or the literal NULL for a backend that cannot say.
	 */
	const char *majority_expr;

	/* Set once startup() has confirmed the extension is present. */
	bool		available;

	/* This node's Spock name. */
	char	   *self_name;
} ClusterApiConfig;

/*
 * pgraft publishes its members as JSON, with raft's "active" flag.  Raft
 * tracks activity only on the leader, so the flag is used there and every
 * member is reported live elsewhere.
 */
static ClusterApiConfig cfg_pgraft = {
	.schema = "pgraft",
	.identity = CLUSTER_IDENTITY_NAME,
	.required = {"pgraft.get_cluster_status()", "pgraft.is_leader()",
	"pgraft.get_nodes_from_raft()", NULL},
	.members_sql =
	"SELECT (e ->> 'id')::integer AS node_id, e ->> 'name' AS name,"
	"       NULL::text AS conninfo,"
	"       CASE WHEN s.is_leader THEN coalesce((e ->> 'active')::boolean, true)"
	"            ELSE true END AS live,"
	"       NULL::timestamptz AS seen"
	"  FROM s, (SELECT pgraft.get_nodes_from_raft()::jsonb AS j) r,"
	"       LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r.j) = 'array'"
	"                                         THEN r.j ELSE '[]'::jsonb END) e",
	.majority_expr = "NULL::boolean",
	.available = false,
	.self_name = NULL
};

/*
 * pgBully's peer table carries real reachability.  Coalesced to true,
 * because a peer pgBully has not yet formed an opinion about must not read
 * as dead: "no opinion" is not evidence of failure and must never license
 * an eviction.  The majority check counts this node as reachable from
 * itself.
 */
static ClusterApiConfig cfg_pgbully = {
	.schema = "pgbully",
	.identity = CLUSTER_IDENTITY_CONNINFO,
	.required = {"pgbully.get_cluster_status()", "pgbully.is_leader()",
	"pgbully.peers()", NULL},
	.members_sql =
	"SELECT p.node_id, NULL::text AS name, p.conninfo,"
	"       coalesce(p.reachable, true) AS live, p.last_seen AS seen"
	"  FROM pgbully.peers() p",
	.majority_expr =
	"(SELECT count(*) FILTER (WHERE q.reachable OR q.is_self) * 2 > count(*)"
	"   FROM pgbully.peers() q)",
	.available = false,
	.self_name = NULL
};

/*
 * Every consult below runs inside an internal subtransaction.
 *
 * Catching an error with PG_TRY and FlushErrorState() alone is not enough:
 * the surrounding transaction stays aborted, and the caller's next command
 * fails with "current transaction is aborted".  These providers are consulted
 * from spock.quorum_status(), inside whatever transaction the operator is
 * already in, so that would turn a merely unreachable backend into a broken
 * session.  A subtransaction is the only way to catch an error and carry on.
 */
typedef struct ClusterSpiScope
{
	MemoryContext oldcxt;
	ResourceOwner oldowner;
} ClusterSpiScope;

static void
cluster_spi_begin(ClusterSpiScope *scope)
{
	scope->oldcxt = CurrentMemoryContext;
	scope->oldowner = CurrentResourceOwner;

	BeginInternalSubTransaction(NULL);
}

/* Put back what the caller had, whichever way the consult ended. */
static void
cluster_spi_end(ClusterSpiScope *scope)
{
	MemoryContextSwitchTo(scope->oldcxt);
	CurrentResourceOwner = scope->oldowner;
}

/*
 * The deadline.
 *
 * statement_timeout cannot do this job: its timer is armed when a client
 * statement starts, so changing the GUC from inside a function changes
 * nothing for the statement already running, and a background worker has no
 * client statement at all.  A private timeout is armed around each consult
 * instead.  Its handler raises the same cancel a statement timeout would,
 * which the subtransaction catches.
 */
static TimeoutId deadline_id = MAX_TIMEOUTS;
static volatile sig_atomic_t deadline_fired = false;

static void
deadline_handler(void)
{
	deadline_fired = true;
	kill(MyProcPid, SIGINT);
}

static void
deadline_start(void)
{
	if (deadline_id == MAX_TIMEOUTS)
		deadline_id = RegisterTimeout(USER_TIMEOUT, deadline_handler);
	deadline_fired = false;
	enable_timeout_after(deadline_id, spock_quorum_timeout);
}

/*
 * Disarm.  Returns true when the deadline fired.  If it fired after the
 * query had already completed, the cancel it raised is still pending and
 * would abort the caller's next statement for no reason, so it is withdrawn.
 */
static bool
deadline_stop(void)
{
	disable_timeout(deadline_id, false);
	if (!deadline_fired)
		return false;
	deadline_fired = false;
	QueryCancelPending = false;
	return true;
}

/* Copy the error text somewhere that outlives the subtransaction. */
static void
cluster_capture_error(ClusterSpiScope *scope, char **errdetail)
{
	ErrorData  *edata;

	MemoryContextSwitchTo(scope->oldcxt);
	edata = CopyErrorData();
	FlushErrorState();
	*errdetail = pstrdup(edata->message);
	FreeErrorData(edata);
}

/* Replace whatever the cancel said with why it happened. */
static void
cluster_deadline_error(char **errdetail)
{
	*errdetail = psprintf("the cluster manager did not answer within %d ms",
						  spock_quorum_timeout);
}

/* A boolean as SPI renders it, cast to text or not. */
static bool
sql_true(const char *v)
{
	return v != NULL && (strcmp(v, "t") == 0 || strcmp(v, "true") == 0);
}

/*
 * Run a query yielding one text value, returning NULL rather than throwing.
 *
 * The backend is a separate extension that may be absent, mid-upgrade, or
 * erroring, and a provider is contractually forbidden from raising.
 */
static char *
cluster_one_text(const char *sql, char **errdetail)
{
	volatile bool ok = true;
	char	   *volatile result = NULL;
	ClusterSpiScope scope;

	*errdetail = NULL;
	cluster_spi_begin(&scope);
	deadline_start();

	PG_TRY();
	{
		if (SPI_connect() != SPI_OK_CONNECT)
			ok = false;
		else
		{
			if (SPI_execute(sql, true, 1) == SPI_OK_SELECT &&
				SPI_processed >= 1)
			{
				char	   *raw = SPI_getvalue(SPI_tuptable->vals[0],
											   SPI_tuptable->tupdesc, 1);

				/* Copied out before SPI_finish frees the context it lives in. */
				if (raw != NULL)
				{
					MemoryContext old = MemoryContextSwitchTo(scope.oldcxt);

					result = pstrdup(raw);
					MemoryContextSwitchTo(old);
				}
			}
			else
				ok = false;
			SPI_finish();
		}
		ReleaseCurrentSubTransaction();
	}
	PG_CATCH();
	{
		cluster_capture_error(&scope, errdetail);
		RollbackAndReleaseCurrentSubTransaction();
		ok = false;
	}
	PG_END_TRY();

	cluster_spi_end(&scope);

	if (deadline_stop() && !ok)
		cluster_deadline_error(errdetail);

	if (!ok)
	{
		if (*errdetail == NULL)
			*errdetail = pstrdup("query against the cluster manager failed");
		return NULL;
	}
	return result;
}

static bool
cluster_startup(ClusterApiConfig *cfg, char **errdetail)
{
	SpockLocalNode *local;
	MemoryContext old;
	StringInfoData sql;
	char	   *present;
	int			i;

	local = get_local_node(false, true);
	if (local == NULL)
	{
		*errdetail = pstrdup("no local spock node");
		return false;
	}

	if (cfg->self_name != NULL)
		pfree(cfg->self_name);
	old = MemoryContextSwitchTo(TopMemoryContext);
	cfg->self_name = pstrdup(local->node->name);
	MemoryContextSwitchTo(old);

	initStringInfo(&sql);
	appendStringInfoString(&sql, "SELECT (true");
	for (i = 0; cfg->required[i] != NULL; i++)
		appendStringInfo(&sql, " AND to_regprocedure(%s) IS NOT NULL",
						 quote_literal_cstr(cfg->required[i]));
	appendStringInfoString(&sql, ")::text");

	present = cluster_one_text(sql.data, errdetail);
	if (present == NULL)
		return false;
	if (!sql_true(present))
	{
		*errdetail = psprintf("the %s extension is not installed in this database",
							  cfg->schema);
		return false;
	}

	cfg->available = true;
	return true;
}

/*
 * Nothing to renew: both managers track their own members, and the identity
 * mapping is read rather than published.
 */
static bool
cluster_refresh(ClusterApiConfig *cfg, char **errdetail)
{
	if (!cfg->available)
	{
		*errdetail = psprintf("the %s provider is not started", cfg->schema);
		return false;
	}
	return true;
}

/*
 * Host and port of a libpq connection string, parsed by libpq itself so
 * that URIs, quoting and defaults come out the same way they would for a
 * connection.  Returns false when the string does not parse.
 */
static bool
conninfo_host_port(const char *conninfo, char **host, int *port)
{
	PQconninfoOption *opts = PQconninfoParse(conninfo, NULL);
	PQconninfoOption *o;
	const char *h = NULL;
	const char *p = NULL;

	if (opts == NULL)
		return false;

	for (o = opts; o->keyword != NULL; o++)
	{
		if (o->val == NULL || o->val[0] == '\0')
			continue;
		if (strcmp(o->keyword, "host") == 0)
			h = o->val;
		else if (strcmp(o->keyword, "hostaddr") == 0 && h == NULL)
			h = o->val;
		else if (strcmp(o->keyword, "port") == 0)
			p = o->val;
	}

	*host = pstrdup(h ? h : "");
	*port = p ? atoi(p) : DEF_PGPORT;
	PQconninfoFree(opts);
	return true;
}

/* One Spock node interface, reduced to what a peer can be matched on. */
typedef struct ClusterInterface
{
	char	   *node_name;
	char	   *host;
	int			port;
} ClusterInterface;

/* The Spock node behind a connection string, or NULL. */
static char *
node_for_conninfo(List *interfaces, const char *conninfo)
{
	ListCell   *lc;
	char	   *host;
	int			port;

	if (conninfo == NULL || !conninfo_host_port(conninfo, &host, &port))
		return NULL;

	foreach(lc, interfaces)
	{
		ClusterInterface *iface = (ClusterInterface *) lfirst(lc);

		if (iface->port == port && pg_strcasecmp(iface->host, host) == 0)
			return iface->node_name;
	}
	return NULL;
}

/* What one reading collects, allocated before PG_TRY so it needs no volatile. */
typedef struct ClusterCollected
{
	bool		have_row;
	int			self_id;
	char	   *leader_id;		/* "0" when nobody leads */
	bool		is_leader;
	char	   *majority;		/* "t" / "f" / NULL when the backend cannot
								 * say */
	List	   *interfaces;		/* ClusterInterface *, conninfo identity only */
	List	   *rows;			/* ClusterRow * */
} ClusterCollected;

typedef struct ClusterRow
{
	int			node_id;
	char	   *name;
	char	   *conninfo;
	bool		live;
	TimestampTz seen;
} ClusterRow;

/* A column as text, copied into the caller's context, or NULL. */
static char *
spi_text(HeapTuple tup, TupleDesc desc, int col, MemoryContext cxt)
{
	char	   *v = SPI_getvalue(tup, desc, col);
	MemoryContext old;
	char	   *copy;

	if (v == NULL)
		return NULL;
	old = MemoryContextSwitchTo(cxt);
	copy = pstrdup(v);
	MemoryContextSwitchTo(old);
	return copy;
}

/*
 * One reading, from one statement.
 *
 * Quorum, leadership, the leader's name and the membership all come from a
 * single SELECT, so they describe one moment.  Within it:
 *
 * A leader is elected only from within a majority, so a leader id that is
 * set is the proof of quorum the backend offers.  It is weaker than it
 * looks: a follower keeps the last leader it knew until its election timeout
 * expires, so an isolated node can go on reporting a leader for a bounded
 * window.  Where the backend can also say whether a majority of peers is
 * reachable (pgBully), that is required too.
 *
 * leader_id is coalesced because the two backends differ on how they say
 * "nobody": pgraft reports 0 and pgBully reports NULL.
 *
 * A member that cannot be named is skipped rather than reported under its
 * integer id: a name matching no spock.node row is worse than no row at
 * all, because it looks like an answer.
 */
static bool
cluster_read(ClusterApiConfig *cfg, SpockQuorumReading *reading,
			 char **errdetail)
{
	volatile bool ok = true;
	ClusterSpiScope scope;
	ClusterCollected *c;
	char	   *sql;
	ListCell   *lc;
	char	   *leader_name = NULL;
	int			leader_id;

	*errdetail = NULL;

	if (!cfg->available)
	{
		*errdetail = psprintf("the %s provider is not started", cfg->schema);
		return false;
	}

	c = palloc0(sizeof(ClusterCollected));

	sql = psprintf(
				   "WITH s AS (SELECT c.node_id, coalesce(c.leader_id, 0) AS leader_id,"
				   "                  %s.is_leader() AS is_leader, %s AS majority"
				   "             FROM %s.get_cluster_status() c),"
				   "     m AS (%s)"
				   " SELECT s.node_id::text, s.leader_id::text, s.is_leader::text,"
				   "        s.majority::text, m.node_id::text, m.name, m.conninfo,"
				   "        m.live::text, m.seen::text"
				   "   FROM s LEFT JOIN m ON true",
				   cfg->schema, cfg->majority_expr, cfg->schema, cfg->members_sql);

	cluster_spi_begin(&scope);
	deadline_start();

	PG_TRY();
	{
		if (SPI_connect() != SPI_OK_CONNECT)
			ok = false;
		else
		{
			/*
			 * Spock's own view of its nodes, for matching connection strings.
			 * Local catalogs, so reading them in a separate statement costs
			 * nothing in consistency.
			 */
			if (cfg->identity == CLUSTER_IDENTITY_CONNINFO &&
				SPI_execute("SELECT n.node_name, i.if_dsn"
							"  FROM spock.node n"
							"  JOIN spock.node_interface i ON i.if_nodeid = n.node_id",
							true, 0) == SPI_OK_SELECT)
			{
				TupleDesc	desc = SPI_tuptable->tupdesc;
				uint64		i;

				for (i = 0; i < SPI_processed; i++)
				{
					HeapTuple	tup = SPI_tuptable->vals[i];
					char	   *name = SPI_getvalue(tup, desc, 1);
					char	   *dsn = SPI_getvalue(tup, desc, 2);
					MemoryContext old;
					ClusterInterface *iface;

					if (name == NULL || dsn == NULL)
						continue;

					old = MemoryContextSwitchTo(scope.oldcxt);
					iface = palloc0(sizeof(ClusterInterface));
					iface->node_name = pstrdup(name);
					if (conninfo_host_port(dsn, &iface->host, &iface->port))
						c->interfaces = lappend(c->interfaces, iface);
					MemoryContextSwitchTo(old);
				}
			}

			if (SPI_execute(sql, true, 0) == SPI_OK_SELECT)
			{
				TupleDesc	desc = SPI_tuptable->tupdesc;
				uint64		i;

				for (i = 0; i < SPI_processed; i++)
				{
					HeapTuple	tup = SPI_tuptable->vals[i];
					char	   *member_id = SPI_getvalue(tup, desc, 5);
					MemoryContext old;

					if (!c->have_row)
					{
						char	   *v;

						c->have_row = true;
						v = SPI_getvalue(tup, desc, 1);
						c->self_id = v ? atoi(v) : 0;
						c->leader_id = spi_text(tup, desc, 2, scope.oldcxt);
						if (c->leader_id == NULL)
							c->leader_id = "0";
						v = SPI_getvalue(tup, desc, 3);
						c->is_leader = sql_true(v);
						c->majority = spi_text(tup, desc, 4, scope.oldcxt);
					}

					if (member_id == NULL)
						continue;

					old = MemoryContextSwitchTo(scope.oldcxt);
					{
						ClusterRow *row = palloc0(sizeof(ClusterRow));
						char	   *live = SPI_getvalue(tup, desc, 8);
						char	   *seen = SPI_getvalue(tup, desc, 9);

						row->node_id = atoi(member_id);
						row->name = spi_text(tup, desc, 6, scope.oldcxt);
						row->conninfo = spi_text(tup, desc, 7, scope.oldcxt);
						row->live = (live == NULL || sql_true(live));

						/*
						 * Carry the backend's own last-contact time when it
						 * has one.  SQL NULL stays 0, which the struct
						 * documents as "not tracked".
						 */
						row->seen = (seen == NULL) ? 0 :
							DatumGetTimestampTz(DirectFunctionCall3(timestamptz_in,
																	CStringGetDatum(seen),
																	ObjectIdGetDatum(InvalidOid),
																	Int32GetDatum(-1)));
						c->rows = lappend(c->rows, row);
					}
					MemoryContextSwitchTo(old);
				}
			}
			else
				ok = false;
			SPI_finish();
		}
		ReleaseCurrentSubTransaction();
	}
	PG_CATCH();
	{
		cluster_capture_error(&scope, errdetail);
		RollbackAndReleaseCurrentSubTransaction();
		ok = false;
	}
	PG_END_TRY();

	cluster_spi_end(&scope);

	if (deadline_stop() && !ok)
		cluster_deadline_error(errdetail);

	if (!ok)
	{
		if (*errdetail == NULL)
			*errdetail = psprintf("could not read the %s cluster state", cfg->schema);
		return false;
	}
	if (!c->have_row)
	{
		*errdetail = psprintf("%s.get_cluster_status() returned no row", cfg->schema);
		return false;
	}

	leader_id = atoi(c->leader_id);
	if (leader_id == 0 ||
		(c->majority != NULL && !sql_true(c->majority)))
	{
		reading->quorum = SPOCK_QUORUM_NO;
		return true;
	}

	reading->quorum = SPOCK_QUORUM_YES;
	reading->leader = c->is_leader ? SPOCK_QUORUM_YES : SPOCK_QUORUM_NO;
	reading->members = NIL;

	foreach(lc, c->rows)
	{
		ClusterRow *row = (ClusterRow *) lfirst(lc);
		char	   *name;
		SpockQuorumMember *m;

		if (row->node_id == c->self_id)
			name = cfg->self_name;
		else if (cfg->identity == CLUSTER_IDENTITY_NAME)
			name = row->name;
		else
			name = node_for_conninfo(c->interfaces, row->conninfo);

		if (name == NULL)
			continue;

		if (row->node_id == leader_id)
			leader_name = name;

		m = palloc0(sizeof(SpockQuorumMember));
		m->name = pstrdup(name);
		m->live = row->live;
		m->voting = true;
		m->last_seen = row->seen;
		reading->members = lappend(reading->members, m);
	}

	reading->leader_name = leader_name;
	return true;
}

/* --- per-backend callback tables -------------------------------------- */

#define CLUSTER_PROVIDER_SHIMS(tag, cfgvar) \
static bool tag##_startup(char **e) { return cluster_startup(&cfgvar, e); } \
static void tag##_shutdown(void) { cfgvar.available = false; } \
static bool tag##_refresh(char **e) { return cluster_refresh(&cfgvar, e); } \
static bool tag##_read(SpockQuorumReading *r, char **e) \
	{ return cluster_read(&cfgvar, r, e); }

CLUSTER_PROVIDER_SHIMS(pgraft, cfg_pgraft)
CLUSTER_PROVIDER_SHIMS(pgbully, cfg_pgbully)

const SpockQuorumProvider spock_quorum_provider_pgraft = {
	.name = "pgraft",
	.startup = pgraft_startup,
	.shutdown = pgraft_shutdown,
	.refresh = pgraft_refresh,
	.read = pgraft_read
};

const SpockQuorumProvider spock_quorum_provider_pgbully = {
	.name = "pgbully",
	.startup = pgbully_startup,
	.shutdown = pgbully_shutdown,
	.refresh = pgbully_refresh,
	.read = pgbully_read
};
