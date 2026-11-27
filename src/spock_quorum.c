/*-------------------------------------------------------------------------
 *
 * spock_quorum.c
 *		Provider dispatch and the fail-safe rules around it.
 *
 * Nothing outside this file calls a provider directly.  Every question goes
 * through a wrapper here, and every wrapper turns an unusable answer into
 * the conservative one.  That is the whole point of the indirection: a
 * caller cannot forget to handle UNKNOWN, because it never sees it.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "funcapi.h"
#include "miscadmin.h"

#include "access/htup_details.h"
#include "access/xact.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

#include "spock.h"
#include "spock_node.h"
#include "spock_quorum.h"

PG_FUNCTION_INFO_V1(spock_quorum_status_sql);
PG_FUNCTION_INFO_V1(spock_quorum_members_sql);

/*
 * The provider in force for this process.  Resolved at startup rather than
 * read from the GUC per call: swapping providers underneath a half-finished
 * decision is not a state worth supporting.
 */
static const SpockQuorumProvider *active = NULL;
static bool active_started = false;

/* The GUC value the active provider was resolved from. */
static int	active_provider_id = -1;

/* Diagnostics for spock.quorum_status(); never load-bearing. */
static char *last_error = NULL;
static TimestampTz last_consulted = 0;

/*
 * One reading per tick, cached.
 *
 * Efficiency is the lesser reason.  The real one is consistency: a tick
 * that asked the provider once per question could see quorum held for the
 * first question and lost by the fourth, and then decide against a cluster
 * state that never existed at any single instant.  The provider takes one
 * reading, and everything in the tick is decided against it.
 */
static bool snap_valid = false;
static SpockQuorumAnswer snap_quorum = SPOCK_QUORUM_UNKNOWN;
static SpockQuorumAnswer snap_leader = SPOCK_QUORUM_UNKNOWN;
static List *snap_members = NIL;
static char *snap_leader_name = NULL;
static MemoryContext snap_ctx = NULL;

static bool snapshot_take(void);
static void spock_quorum_invalidate(void);

/*
 * Record why the most recent consult failed.  Kept in TopMemoryContext
 * because the caller's context may be reset underneath us, and the string
 * has to outlive the tick that produced it to be worth anything to an
 * operator.  Returns true when the text changed, so a caller can log a new
 * problem without repeating an old one on every tick.
 */
static bool
note_error(const char *detail)
{
	MemoryContext old;
	bool		changed;

	if (detail == NULL)
		changed = (last_error != NULL);
	else
		changed = (last_error == NULL || strcmp(last_error, detail) != 0);

	if (!changed)
		return false;

	if (last_error != NULL)
	{
		pfree(last_error);
		last_error = NULL;
	}

	if (detail == NULL)
		return true;

	old = MemoryContextSwitchTo(TopMemoryContext);
	last_error = pstrdup(detail);
	MemoryContextSwitchTo(old);
	return true;
}

/* Resolve the GUC to a provider table. */
static const SpockQuorumProvider *
provider_for(int id)
{
	switch ((SpockQuorumProviderId) id)
	{
		case SPOCK_QUORUM_PROVIDER_NONE:
			return &spock_quorum_provider_none;
		case SPOCK_QUORUM_PROVIDER_ETCD:
			return &spock_quorum_provider_etcd;
		case SPOCK_QUORUM_PROVIDER_PGRAFT:
			return &spock_quorum_provider_pgraft;
		case SPOCK_QUORUM_PROVIDER_PGBULLY:
			return &spock_quorum_provider_pgbully;
	}
	return &spock_quorum_provider_none;
}

/*
 * Drop the cached reading.  Called at the top of each tick, and by the
 * status functions so an operator always sees a fresh answer rather than
 * whatever the last tick happened to observe.
 */
static void
spock_quorum_invalidate(void)
{
	snap_valid = false;
	snap_quorum = SPOCK_QUORUM_UNKNOWN;
	snap_leader = SPOCK_QUORUM_UNKNOWN;
	snap_members = NIL;
	snap_leader_name = NULL;
	if (snap_ctx != NULL)
		MemoryContextReset(snap_ctx);
}

void
spock_quorum_startup(void)
{
	char	   *detail = NULL;

	if (snap_ctx == NULL)
		snap_ctx = AllocSetContextCreate(TopMemoryContext,
										 "spock quorum snapshot",
										 ALLOCSET_SMALL_SIZES);

	spock_quorum_invalidate();
	active = provider_for(spock_quorum_provider);
	active_provider_id = spock_quorum_provider;
	active_started = false;

	/*
	 * etcd is shared by whoever points at it, and the key prefix is the only
	 * thing separating one cluster's members from another's.  Refuse rather
	 * than fall back to a default: a wrong answer here mixes two clusters'
	 * membership, which is far worse than having no answer.  The in-database
	 * managers are one per cluster by construction and need no prefix.
	 */
	if (spock_quorum_provider == SPOCK_QUORUM_PROVIDER_ETCD &&
		(spock_quorum_cluster_id == NULL || spock_quorum_cluster_id[0] == '\0'))
	{
		if (note_error("spock.quorum_cluster_id is not set"))
			ereport(WARNING,
					(errmsg("spock quorum: provider \"%s\" needs spock.quorum_cluster_id",
							active->name),
					 errhint("Set it to a value unique to this cluster.")));
		return;
	}

	if (active->startup(&detail))
	{
		active_started = true;
		note_error(NULL);
		return;
	}

	/*
	 * Startup failed.  Stay on the provider so the status view still reports
	 * what was configured and why it is not working, but leave it unstarted
	 * so every question below short-circuits to the conservative answer. The
	 * next consult tries again.
	 */
	if (note_error(detail ? detail : "provider startup failed"))
		ereport(WARNING,
				(errmsg("spock quorum: provider \"%s\" failed to start: %s",
						active->name, last_error),
				 errhint("Spock continues with no quorum information.")));
}

void
spock_quorum_shutdown(void)
{
	if (active != NULL && active_started)
		active->shutdown();
	active = NULL;
	active_started = false;
}

/*
 * Renew whatever registration the provider needs.  Called at the top of each
 * tick, before any question is asked, so a lease that has lapsed is refused
 * rather than answered from stale state.
 */
void
spock_quorum_refresh(void)
{
	char	   *detail = NULL;

	if (active == NULL || !active_started)
		return;

	spock_quorum_invalidate();

	if (!active->refresh(&detail))
	{
		/*
		 * Registration could not be renewed, so this node may already have
		 * been dropped from the provider's view.  Asking about quorum now
		 * could return YES from a position the cluster no longer counts, and
		 * would overwrite the reason the refresh failed.  Close the tick's
		 * reading as UNKNOWN instead, so every question answers
		 * conservatively until the next refresh.
		 */
		note_error(detail ? detail : "refresh failed");
		snap_valid = true;
		return;
	}

	note_error(NULL);

	/*
	 * Take the tick's single reading now, so everything decided below this
	 * point sees one consistent picture of the cluster.
	 */
	(void) snapshot_take();
}

/*
 * Resolve the provider on first use, and again whenever the configuration
 * moved or the last startup failed.
 *
 * A consuming worker calls spock_quorum_startup() explicitly, but the status
 * functions can be called from any backend, and a status view reporting
 * "none" merely because nothing had initialised the layer would be actively
 * misleading.  The provider is PGC_SIGHUP, and a worker restarts on one,
 * but a long-lived backend does not, so it has to notice a change itself.
 * A failed startup (no cluster id yet, an extension not installed yet) is
 * retried on the next consult rather than remembered for the life of the
 * backend.
 */
static bool
spock_quorum_ensure_started(void)
{
	if (active != NULL && active_provider_id != spock_quorum_provider)
		spock_quorum_shutdown();

	if (active == NULL || !active_started)
		spock_quorum_startup();

	return active != NULL && active_started;
}

/*
 * Take one reading, if this tick has not already.
 *
 * Members are copied into snap_ctx: the provider allocates them in whatever
 * context is current, which for a worker is reset between ticks, and the
 * snapshot has to outlive that.
 */
static bool
snapshot_take(void)
{
	SpockQuorumReading reading;
	char	   *detail = NULL;

	if (!spock_quorum_ensure_started())
		return false;
	if (snap_valid)
		return true;

	memset(&reading, 0, sizeof(reading));
	reading.quorum = SPOCK_QUORUM_UNKNOWN;
	reading.leader = SPOCK_QUORUM_UNKNOWN;

	if (!active->read(&reading, &detail))
	{
		/* No reading.  Every answer this tick is UNKNOWN. */
		note_error(detail ? detail : "provider returned no reading");
		snap_valid = true;
		return true;
	}

	note_error(NULL);
	snap_quorum = reading.quorum;
	if (snap_quorum != SPOCK_QUORUM_UNKNOWN)
		last_consulted = GetCurrentTimestamp();

	/*
	 * Leadership and membership are only kept while quorum is held.  A
	 * partitioned minority can still believe it leads and can still see some
	 * peers; acting on either is the failure this layer exists to prevent, so
	 * there is nothing to learn from them.
	 */
	if (snap_quorum == SPOCK_QUORUM_YES)
	{
		MemoryContext old = MemoryContextSwitchTo(snap_ctx);
		ListCell   *lc;

		snap_leader = reading.leader;

		/*
		 * The leader is held to the same test as the members below: a name
		 * Spock does not know is not reported, whichever provider supplied
		 * it, so a dropped node cannot be named as leader.
		 */
		if (reading.leader_name != NULL &&
			get_node_by_name(reading.leader_name, true) != NULL)
			snap_leader_name = pstrdup(reading.leader_name);

		foreach(lc, reading.members)
		{
			SpockQuorumMember *src = (SpockQuorumMember *) lfirst(lc);
			SpockQuorumMember *cp;

			/*
			 * Keep only the members Spock knows.  A node removed with
			 * spock.node_drop() can linger in the quorum system (an etcd key
			 * until its lease lapses, a pgraft or pgBully mapping for good),
			 * and must stop counting the moment Spock forgets it.
			 */
			if (src->name == NULL ||
				get_node_by_name(src->name, true) == NULL)
				continue;

			cp = palloc0(sizeof(SpockQuorumMember));
			cp->name = pstrdup(src->name);
			cp->live = src->live;
			cp->voting = src->voting;
			cp->last_seen = src->last_seen;
			snap_members = lappend(snap_members, cp);
		}
		MemoryContextSwitchTo(old);
	}

	snap_valid = true;
	return true;
}

bool
spock_quorum_have_quorum(void)
{
	if (!snapshot_take())
		return false;
	return snap_quorum == SPOCK_QUORUM_YES;
}

bool
spock_quorum_is_leader(void)
{
	if (!snapshot_take())
		return false;

	/* snapshot_take only keeps leadership while quorum is held. */
	return snap_quorum == SPOCK_QUORUM_YES && snap_leader == SPOCK_QUORUM_YES;
}

List *
spock_quorum_members(void)
{
	if (!snapshot_take())
		return NIL;
	return snap_members;
}

SpockQuorumAnswer
spock_quorum_member_live(const char *node_name)
{
	ListCell   *lc;

	if (node_name == NULL || !snapshot_take())
		return SPOCK_QUORUM_UNKNOWN;

	/*
	 * Liveness is only trustworthy from inside a quorum.  Without one this
	 * node may be the isolated party, and its opinion about who else is
	 * reachable says more about its own connectivity than about the cluster.
	 */
	if (snap_quorum != SPOCK_QUORUM_YES)
		return SPOCK_QUORUM_UNKNOWN;

	foreach(lc, snap_members)
	{
		SpockQuorumMember *m = (SpockQuorumMember *) lfirst(lc);

		if (strcmp(m->name, node_name) == 0)
			return m->live ? SPOCK_QUORUM_YES : SPOCK_QUORUM_NO;
	}

	/*
	 * The quorum system has never heard of this node.  That is not evidence
	 * that it is down, it may simply not be registered, so it is not grounds
	 * for releasing anything.
	 */
	return SPOCK_QUORUM_UNKNOWN;
}

const char *
spock_quorum_provider_name(void)
{
	return active != NULL ? active->name : "none";
}

const char *
spock_quorum_last_error(void)
{
	return last_error;
}

TimestampTz
spock_quorum_last_consulted(void)
{
	return last_consulted;
}

/*
 * spock.quorum_status()
 *
 * Anything able to move the WAL horizon has to be inspectable before it is
 * allowed to.  A fresh reading is taken: an operator running this is asking
 * about now, not about whatever the last tick happened to see.
 */
Datum
spock_quorum_status_sql(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	Datum		values[6];
	bool		nulls[6];
	HeapTuple	tuple;

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");
	tupdesc = BlessTupleDesc(tupdesc);

	memset(nulls, 0, sizeof(nulls));

	spock_quorum_invalidate();
	(void) snapshot_take();

	values[0] = CStringGetTextDatum(spock_quorum_provider_name());

	if (active == NULL || !active_started)
	{
		nulls[1] = true;		/* has_quorum */
		nulls[2] = true;		/* is_leader */
		nulls[3] = true;		/* leader */
	}
	else
	{
		if (snap_quorum == SPOCK_QUORUM_UNKNOWN)
			nulls[1] = true;
		else
			values[1] = BoolGetDatum(snap_quorum == SPOCK_QUORUM_YES);

		/*
		 * Reported through the same rule the rest of Spock acts on: without
		 * quorum, leadership is not something this node may act on, so
		 * showing the provider's raw opinion here would describe a decision
		 * Spock would never make.
		 */
		if (snap_quorum != SPOCK_QUORUM_YES ||
			snap_leader == SPOCK_QUORUM_UNKNOWN)
			nulls[2] = true;
		else
			values[2] = BoolGetDatum(snap_leader == SPOCK_QUORUM_YES);

		if (snap_leader_name != NULL)
			values[3] = CStringGetTextDatum(snap_leader_name);
		else
			nulls[3] = true;
	}

	if (last_consulted == 0)
		nulls[4] = true;
	else
		values[4] = TimestampTzGetDatum(last_consulted);

	if (last_error == NULL)
		nulls[5] = true;
	else
		values[5] = CStringGetTextDatum(last_error);

	tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * spock.quorum_members()
 *
 * The membership the layer would act on: the provider's view, restricted to
 * nodes in spock.node, from a fresh reading.  Empty without quorum.
 */
Datum
spock_quorum_members_sql(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext per_query_ctx;
	MemoryContext oldcontext;
	ListCell   *lc;

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("materialize mode required, but it is not allowed in this context")));
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
	oldcontext = MemoryContextSwitchTo(per_query_ctx);
	tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;
	MemoryContextSwitchTo(oldcontext);

	spock_quorum_invalidate();
	(void) snapshot_take();

	foreach(lc, snap_members)
	{
		SpockQuorumMember *m = (SpockQuorumMember *) lfirst(lc);
		Datum		values[4];
		bool		nulls[4];

		memset(nulls, 0, sizeof(nulls));
		values[0] = CStringGetTextDatum(m->name);
		values[1] = BoolGetDatum(m->live);
		values[2] = BoolGetDatum(m->voting);
		if (m->last_seen == 0)
			nulls[3] = true;
		else
			values[3] = TimestampTzGetDatum(m->last_seen);

		tuplestore_putvalues(tupstore, tupdesc, values, nulls);
	}

	return (Datum) 0;
}

/* ---------------------------------------------------------------------- *
 * The 'none' provider.
 *
 * Not a stub: it is the default, and it is what every other provider
 * degrades to.  Its reading is UNKNOWN rather than NO so that callers which
 * distinguish the two (the status view, the logs) report "no information"
 * instead of asserting a negative it has no basis for.
 * ---------------------------------------------------------------------- */

static bool
none_startup(char **errdetail)
{
	return true;
}

static void
none_shutdown(void)
{
}

static bool
none_refresh(char **errdetail)
{
	return true;
}

static bool
none_read(SpockQuorumReading *reading, char **errdetail)
{
	reading->quorum = SPOCK_QUORUM_UNKNOWN;
	reading->leader = SPOCK_QUORUM_UNKNOWN;
	reading->leader_name = NULL;
	reading->members = NIL;
	return true;
}

const SpockQuorumProvider spock_quorum_provider_none = {
	.name = "none",
	.startup = none_startup,
	.shutdown = none_shutdown,
	.refresh = none_refresh,
	.read = none_read
};
