/*-------------------------------------------------------------------------
 *
 * spock_quorum_cluster.c
 *		Quorum provider for the shared cluster-manager API.
 *
 * pgraft and pgBully now expose the same in-database interface, differing
 * only in the schema it lives under:
 *
 *		<schema>.get_cluster_status()	node_id, term, leader_id, state, ...
 *		<schema>.get_nodes()			node_id, address, port, is_leader
 *		<schema>.is_leader()
 *		<schema>.kv_put() / kv_get()	replicated key/value
 *
 * So they are one provider here, parameterised by schema name, rather than
 * two near-identical files drifting apart.  Everything a quorum decision
 * needs comes from that common surface.
 *
 * The one real difference is liveness, and it is not a matter of naming.
 * pgBully additionally publishes pgbully.peers(), which carries `reachable`
 * per peer -- the per-member liveness that Raft tracks internally to drive
 * heartbeats but that pgraft does not expose.  Where that is available it is
 * used; where it is not, every configured member is reported live.
 *
 * Reporting all-live is the safe reading rather than a pretence that nothing
 * has failed: under the fail-safe rules a live member is one that is never
 * evicted, so a caller cannot release anything on the strength of a provider
 * that has no opinion.  It does mean the quorum layer buys pgraft users
 * leadership and quorum but not eviction, until a last-contact column exists
 * upstream.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "executor/spi.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

#include "spock.h"
#include "spock_node.h"
#include "spock_quorum.h"

/*
 * What differs between the two backends.  Everything else below is shared.
 */
typedef struct ClusterApiConfig
{
	const char *schema;			/* "pgraft" or "pgbully" */

	/*
	 * SQL fragment yielding this member's liveness, evaluated against the
	 * get_nodes() row aliased `n`.  A backend with no reachability
	 * information supplies a literal true.
	 */
	const char *live_expr;

	/* Extra FROM-list text the liveness expression needs, or "". */
	const char *live_from;

	/* Set once startup() has confirmed the extension is present. */
	bool		available;

	/* This node's Spock name, published so peers can map ids to names. */
	char	   *self_name;
} ClusterApiConfig;

/*
 * pgBully joins its own peer table for real reachability.  A LEFT JOIN, and
 * coalesced to true, because a peer pgBully has not yet formed an opinion
 * about must not read as dead: "no opinion" is not evidence of failure and
 * must never license an eviction.
 */
static ClusterApiConfig cfg_pgbully = {
	.schema = "pgbully",
	.live_expr = "coalesce(p.reachable, true)",
	.live_from = " LEFT JOIN pgbully.peers() p ON p.node_id = n.node_id ",
	.available = false,
	.self_name = NULL
};

static ClusterApiConfig cfg_pgraft = {
	.schema = "pgraft",
	.live_expr = "true",
	.live_from = "",
	.available = false,
	.self_name = NULL
};

/*
 * Run a query yielding one text value, returning NULL rather than throwing.
 *
 * The backend is a separate extension that may be absent, mid-upgrade, or
 * erroring, and a provider is contractually forbidden from raising.  `ok` is
 * volatile because it is assigned in the handler and read after PG_END_TRY.
 */
static char *
cluster_one_text(const char *sql, char **errdetail)
{
	volatile bool ok = true;
	volatile bool connected = false;
	char	   *result = NULL;

	PG_TRY();
	{
		if (SPI_connect() != SPI_OK_CONNECT)
			ok = false;
		else
		{
			connected = true;
			if (SPI_execute(sql, true, 1) == SPI_OK_SELECT && SPI_processed >= 1)
			{
				char	   *raw = SPI_getvalue(SPI_tuptable->vals[0],
											   SPI_tuptable->tupdesc, 1);

				/* Copied out before SPI_finish frees the context it lives in. */
				if (raw != NULL)
				{
					MemoryContext old = MemoryContextSwitchTo(CurTransactionContext);

					result = pstrdup(raw);
					MemoryContextSwitchTo(old);
				}
			}
		}
	}
	PG_CATCH();
	{
		FlushErrorState();
		ok = false;
	}
	PG_END_TRY();

	if (connected)
		SPI_finish();

	if (!ok)
	{
		*errdetail = psprintf("query against the cluster manager failed");
		return NULL;
	}
	return result;
}

/* Prefix under which node ids are mapped to Spock node names. */
static char *
name_key_prefix(void)
{
	return psprintf("%s/nodes/", spock_quorum_cluster_id);
}

static bool
cluster_startup(ClusterApiConfig *cfg, char **errdetail)
{
	SpockLocalNode *local;
	MemoryContext old;
	char	   *present;

	local = get_local_node(false, true);
	if (local == NULL)
	{
		*errdetail = pstrdup("no local spock node");
		return false;
	}

	old = MemoryContextSwitchTo(TopMemoryContext);
	cfg->self_name = pstrdup(local->node->name);
	MemoryContextSwitchTo(old);

	present = cluster_one_text(
		psprintf("SELECT to_regprocedure('%s.get_cluster_status()') IS NOT NULL"
				 "   AND to_regprocedure('%s.is_leader()') IS NOT NULL",
				 cfg->schema, cfg->schema), errdetail);

	if (present == NULL)
		return false;
	if (strcmp(present, "t") != 0)
	{
		*errdetail = psprintf("the %s extension is not installed in this database",
							  cfg->schema);
		return false;
	}

	cfg->available = true;
	return true;
}

/*
 * Publish this node's id-to-name mapping.
 *
 * Not a heartbeat and no evidence of liveness: the replicated KV has no
 * expiry, so an entry outlives the node that wrote it.  It exists only so
 * members() and leader() can render the integer ids the cluster manager
 * speaks in as the node names the rest of Spock speaks in.
 */
static bool
cluster_refresh(ClusterApiConfig *cfg, char **errdetail)
{
	char	   *id;

	if (!cfg->available)
		return false;

	id = cluster_one_text(psprintf("SELECT node_id::text FROM %s.get_cluster_status()",
								   cfg->schema), errdetail);
	if (id == NULL)
		return false;

	return cluster_one_text(
		psprintf("SELECT %s.kv_put(%s, %s)::text",
				 cfg->schema,
				 quote_literal_cstr(psprintf("%s%s", name_key_prefix(), id)),
				 quote_literal_cstr(cfg->self_name)), errdetail) != NULL;
}

/*
 * A leader is elected only from within a majority, so a leader id that is
 * set is itself the proof of quorum.  There is no separate question to ask.
 *
 * coalesced because the two backends differ on how they say "nobody":
 * pgraft reports 0 and pgBully reports NULL.  Left bare, the comparison
 * would yield NULL for pgBully and be reported as "unknown" when what it
 * actually said was a definite "no leader, so no quorum".  Both are safe --
 * the caller treats them alike -- but only one is true.
 */
static SpockQuorumAnswer
cluster_have_quorum(ClusterApiConfig *cfg, char **errdetail)
{
	char	   *leader;

	if (!cfg->available)
		return SPOCK_QUORUM_UNKNOWN;

	leader = cluster_one_text(
		psprintf("SELECT (coalesce(leader_id, 0) <> 0)::text "
				 "  FROM %s.get_cluster_status()", cfg->schema), errdetail);

	if (leader == NULL)
		return SPOCK_QUORUM_UNKNOWN;
	return strcmp(leader, "t") == 0 ? SPOCK_QUORUM_YES : SPOCK_QUORUM_NO;
}

static SpockQuorumAnswer
cluster_is_leader(ClusterApiConfig *cfg, char **errdetail)
{
	char	   *v;

	if (!cfg->available)
		return SPOCK_QUORUM_UNKNOWN;

	v = cluster_one_text(psprintf("SELECT %s.is_leader()::text", cfg->schema),
						 errdetail);
	if (v == NULL)
		return SPOCK_QUORUM_UNKNOWN;
	return strcmp(v, "t") == 0 ? SPOCK_QUORUM_YES : SPOCK_QUORUM_NO;
}

static char *
cluster_leader(ClusterApiConfig *cfg, char **errdetail)
{
	char	   *id;

	if (!cfg->available)
		return NULL;

	id = cluster_one_text(psprintf("SELECT leader_id::text "
								   "  FROM %s.get_cluster_status()", cfg->schema),
						  errdetail);
	if (id == NULL || strcmp(id, "0") == 0)
		return NULL;

	return cluster_one_text(
		psprintf("SELECT %s.kv_get(%s)", cfg->schema,
				 quote_literal_cstr(psprintf("%s%s", name_key_prefix(), id))),
		errdetail);
}

/*
 * Membership, rendered as Spock node names, with each member's liveness
 * according to whatever the backend can attest.
 *
 * A node that has not published a name mapping yet is skipped rather than
 * reported under its integer id: a name matching no spock.node row is worse
 * than no row at all, because it looks like an answer.
 */
static List *
cluster_members(ClusterApiConfig *cfg, char **errdetail)
{
	volatile bool ok = true;
	volatile bool connected = false;
	List	   *result = NIL;
	char	   *sql;

	if (!cfg->available)
		return NIL;

	sql = psprintf(
		"SELECT k.v, (%s)::text "
		"  FROM %s.get_nodes() n %s"
		"  , LATERAL (SELECT %s.kv_get(%s || n.node_id::text) AS v) k "
		" WHERE k.v IS NOT NULL",
		cfg->live_expr, cfg->schema, cfg->live_from, cfg->schema,
		quote_literal_cstr(name_key_prefix()));

	PG_TRY();
	{
		if (SPI_connect() != SPI_OK_CONNECT)
			ok = false;
		else
		{
			connected = true;
			if (SPI_execute(sql, true, 0) == SPI_OK_SELECT)
			{
				MemoryContext caller = CurTransactionContext;
				uint64		i;

				for (i = 0; i < SPI_processed; i++)
				{
					HeapTuple	tup = SPI_tuptable->vals[i];
					TupleDesc	desc = SPI_tuptable->tupdesc;
					char	   *name = SPI_getvalue(tup, desc, 1);
					char	   *live = SPI_getvalue(tup, desc, 2);
					MemoryContext old;
					SpockQuorumMember *m;

					if (name == NULL)
						continue;

					old = MemoryContextSwitchTo(caller);
					m = palloc0(sizeof(SpockQuorumMember));
					m->name = pstrdup(name);
					m->live = (live == NULL || strcmp(live, "t") == 0);
					m->voting = true;
					m->last_seen = 0;
					result = lappend(result, m);
					MemoryContextSwitchTo(old);
				}
			}
			else
				ok = false;
		}
	}
	PG_CATCH();
	{
		FlushErrorState();
		ok = false;
	}
	PG_END_TRY();

	if (connected)
		SPI_finish();

	if (!ok)
	{
		*errdetail = psprintf("could not read %s membership", cfg->schema);
		return NIL;
	}
	return result;
}

/* --- per-backend callback tables -------------------------------------- */

#define CLUSTER_PROVIDER_SHIMS(tag, cfgvar)									\
static bool tag##_startup(char **e) { return cluster_startup(&cfgvar, e); }	\
static void tag##_shutdown(void) { cfgvar.available = false; }				\
static bool tag##_refresh(char **e) { return cluster_refresh(&cfgvar, e); }	\
static SpockQuorumAnswer tag##_have_quorum(char **e)							\
	{ return cluster_have_quorum(&cfgvar, e); }								\
static List *tag##_members(char **e) { return cluster_members(&cfgvar, e); }	\
static SpockQuorumAnswer tag##_is_leader(char **e)							\
	{ return cluster_is_leader(&cfgvar, e); }								\
static char *tag##_leader(char **e) { return cluster_leader(&cfgvar, e); }

CLUSTER_PROVIDER_SHIMS(pgraft, cfg_pgraft)
CLUSTER_PROVIDER_SHIMS(pgbully, cfg_pgbully)

const SpockQuorumProvider spock_quorum_provider_pgraft = {
	.name = "pgraft",
	.startup = pgraft_startup,
	.shutdown = pgraft_shutdown,
	.refresh = pgraft_refresh,
	.have_quorum = pgraft_have_quorum,
	.members = pgraft_members,
	.is_leader = pgraft_is_leader,
	.leader = pgraft_leader
};

const SpockQuorumProvider spock_quorum_provider_pgbully = {
	.name = "pgbully",
	.startup = pgbully_startup,
	.shutdown = pgbully_shutdown,
	.refresh = pgbully_refresh,
	.have_quorum = pgbully_have_quorum,
	.members = pgbully_members,
	.is_leader = pgbully_is_leader,
	.leader = pgbully_leader
};
