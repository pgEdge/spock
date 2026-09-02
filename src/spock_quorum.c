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

#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"

#include "spock.h"
#include "spock_quorum.h"

PG_FUNCTION_INFO_V1(spock_quorum_status_sql);

/* GUC storage; the variables themselves are defined in spock.c. */

/*
 * The provider in force for this worker.  Resolved at startup rather than
 * read from the GUC per call: swapping providers underneath a half-finished
 * decision is not a state worth supporting, and a SIGHUP that changes the
 * provider restarts the worker anyway.
 */
static const SpockQuorumProvider *active = NULL;
static bool active_started = false;

/* Diagnostics for spock.quorum_status(); never load-bearing. */
static char *last_error = NULL;
static TimestampTz last_consulted = 0;

/*
 * One consult per tick, cached.
 *
 * Efficiency is the lesser reason.  The real one is consistency: without a
 * snapshot, deciding about five members asked the provider ten times, and
 * nothing stopped quorum from being YES for the first question and NO for
 * the fourth.  Decisions within one tick would then rest on a cluster state
 * that never existed at any single instant.  Taking one reading and deciding
 * against it is both cheaper and honest.
 */
static bool snap_valid = false;
static SpockQuorumAnswer snap_quorum = SPOCK_QUORUM_UNKNOWN;
static SpockQuorumAnswer snap_leader = SPOCK_QUORUM_UNKNOWN;
static List *snap_members = NIL;
static MemoryContext snap_ctx = NULL;

/* The GUC value the active provider was resolved from. */
static int	active_provider_id = -1;

static bool snapshot_take(void);
static void spock_quorum_invalidate(void);

/*
 * Record why the most recent consult failed.  Kept in TopMemoryContext
 * because the worker's per-tick context is reset underneath us, and this
 * string has to outlive the tick that produced it in order to be worth
 * anything to an operator.
 */
static void
note_error(const char *detail)
{
	MemoryContext old;

	if (last_error != NULL)
	{
		pfree(last_error);
		last_error = NULL;
	}

	if (detail == NULL)
		return;

	old = MemoryContextSwitchTo(TopMemoryContext);
	last_error = pstrdup(detail);
	MemoryContextSwitchTo(old);
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
 * Drop the cached reading.  Called at the top of each tick, and by the status
 * view so an operator always sees a fresh answer rather than whatever the
 * last tick happened to observe.
 */
static void
spock_quorum_invalidate(void)
{
	snap_valid = false;
	snap_quorum = SPOCK_QUORUM_UNKNOWN;
	snap_leader = SPOCK_QUORUM_UNKNOWN;
	snap_members = NIL;
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

	if (active->startup == NULL)
	{
		active_started = true;
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
	 * so every question below short-circuits to the conservative answer.
	 */
	note_error(detail ? detail : "provider startup failed");
	ereport(WARNING,
			(errmsg("spock quorum: provider \"%s\" failed to start: %s",
					active->name, last_error),
			 errhint("Spock continues with no quorum information, which is "
					 "the conservative behaviour.")));
}

void
spock_quorum_shutdown(void)
{
	if (active != NULL && active_started && active->shutdown != NULL)
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

	if (active == NULL || !active_started || active->refresh == NULL)
		return;

	spock_quorum_invalidate();

	if (active->refresh(&detail))
	{
		note_error(NULL);
		last_consulted = GetCurrentTimestamp();
	}
	else
		note_error(detail ? detail : "refresh failed");

	/*
	 * Take the tick's single reading now, so everything decided below this
	 * point sees one consistent picture of the cluster.
	 */
	(void) snapshot_take();
}

/*
 * Resolve the provider on first use.  A consuming worker calls
 * spock_quorum_startup() explicitly, but spock.quorum_status() can be called
 * from any backend, and a status view reporting "none" merely because
 * nothing had initialised the layer would be actively misleading.
 */
static bool
spock_quorum_ensure_started(void)
{
	/*
	 * Re-resolve when the GUC has moved.  The provider is PGC_SIGHUP, and a
	 * worker restarts on one, but a long-lived backend does not -- it would
	 * otherwise keep answering from the provider that was configured when it
	 * first connected, indefinitely.
	 */
	if (active != NULL && active_provider_id != spock_quorum_provider)
	{
		spock_quorum_shutdown();
		spock_quorum_startup();
	}
	else if (active == NULL)
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
	char	   *detail = NULL;
	List	   *members;

	if (!spock_quorum_ensure_started())
		return false;
	if (snap_valid)
		return true;

	snap_quorum = active->have_quorum(&detail);
	if (snap_quorum == SPOCK_QUORUM_UNKNOWN && detail != NULL)
		note_error(detail);
	else if (snap_quorum != SPOCK_QUORUM_UNKNOWN)
	{
		note_error(NULL);
		last_consulted = GetCurrentTimestamp();
	}

	/*
	 * Leadership and membership are only asked for once quorum is held.  A
	 * partitioned minority can still believe it leads and can still see some
	 * peers; acting on either is the failure this layer exists to prevent,
	 * so there is nothing to learn from asking.
	 */
	if (snap_quorum == SPOCK_QUORUM_YES)
	{
		detail = NULL;
		snap_leader = active->is_leader(&detail);

		detail = NULL;
		members = active->members(&detail);
		if (members == NIL && detail != NULL)
			note_error(detail);
		else
		{
			MemoryContext old = MemoryContextSwitchTo(snap_ctx);
			ListCell   *lc;

			foreach(lc, members)
			{
				SpockQuorumMember *src = (SpockQuorumMember *) lfirst(lc);
				SpockQuorumMember *cp = palloc0(sizeof(SpockQuorumMember));

				cp->name = pstrdup(src->name);
				cp->live = src->live;
				cp->voting = src->voting;
				cp->last_seen = src->last_seen;
				snap_members = lappend(snap_members, cp);
			}
			MemoryContextSwitchTo(old);
		}
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

	/* snapshot_take only asks about leadership while quorum is held. */
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
	 * that it is down -- it may simply not be registered -- so it is not
	 * grounds for releasing anything.
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
 * allowed to.
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

	/*
	 * Force a fresh reading.  An operator running this is asking about now,
	 * not about whatever the last tick happened to see.
	 */
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

		if (snap_quorum == SPOCK_QUORUM_YES && active->leader != NULL)
		{
			char	   *detail = NULL;
			char	   *who = active->leader(&detail);

			if (who != NULL)
				values[3] = CStringGetTextDatum(who);
			else
				nulls[3] = true;
		}
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

/* ---------------------------------------------------------------------- *
 * The 'none' provider.
 *
 * Not a stub: it is the default, and it is what every other provider
 * degrades to.  It answers UNKNOWN rather than NO so that callers which
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

static SpockQuorumAnswer
none_have_quorum(char **errdetail)
{
	return SPOCK_QUORUM_UNKNOWN;
}

static List *
none_members(char **errdetail)
{
	return NIL;
}

static SpockQuorumAnswer
none_is_leader(char **errdetail)
{
	return SPOCK_QUORUM_UNKNOWN;
}

static char *
none_leader(char **errdetail)
{
	return NULL;
}

const SpockQuorumProvider spock_quorum_provider_none = {
	.name = "none",
	.startup = none_startup,
	.shutdown = none_shutdown,
	.refresh = none_refresh,
	.have_quorum = none_have_quorum,
	.members = none_members,
	.is_leader = none_is_leader,
	.leader = none_leader
};
