/*-------------------------------------------------------------------------
 *
 * spock_quorum.h
 *		Pluggable quorum provider interface.
 *
 * Spock does not implement consensus.  It asks an external system a small
 * number of questions and stays conservative when it cannot get an answer.
 * This header is the whole contract.
 *
 * Every provider implements the same interface -- there are no optional
 * entry points and no capability negotiation.  That is affordable because
 * the interface asks only for judgements, never for storage: Spock already
 * keeps its durable state in its own crash-safe catalogs.  Keeping shared
 * storage out is what lets a leader-election-only system such as pgBully sit
 * behind the identical interface as etcd, which has a replicated key space.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_QUORUM_H
#define SPOCK_QUORUM_H

#include "postgres.h"
#include "nodes/pg_list.h"
#include "storage/latch.h"
#include "utils/timestamp.h"

/*
 * Which provider is active.  Selected by spock.quorum_provider; the order
 * here is the order of the GUC's enum table.
 */
typedef enum SpockQuorumProviderId
{
	SPOCK_QUORUM_PROVIDER_NONE = 0,
	SPOCK_QUORUM_PROVIDER_ETCD,
	SPOCK_QUORUM_PROVIDER_PGRAFT,
	SPOCK_QUORUM_PROVIDER_PGBULLY
} SpockQuorumProviderId;

/*
 * Every answer is three-valued.  UNKNOWN is not an error code: it is the
 * honest reply when the provider is unreachable, slow, or partitioned.
 * Callers treat it exactly as they treat NO -- that is the fail-safe rule --
 * but the two are kept apart so the status view and the log can distinguish
 * a cluster that lost quorum from a provider that stopped answering.  During
 * an incident those call for different responses, and a boolean cannot tell
 * them apart.
 */
typedef enum SpockQuorumAnswer
{
	SPOCK_QUORUM_NO = 0,
	SPOCK_QUORUM_YES,
	SPOCK_QUORUM_UNKNOWN
} SpockQuorumAnswer;

/* One member, as the quorum system sees it -- not as spock.node sees it. */
typedef struct SpockQuorumMember
{
	char	   *name;			/* matches spock.node.node_name */
	bool		live;			/* reachable, in the provider's judgement */
	bool		voting;			/* counts toward a majority */
	TimestampTz last_seen;		/* 0 when the provider does not track it */
} SpockQuorumMember;

/*
 * Provider callbacks.  All of them are mandatory: a provider with nothing to
 * do in refresh() supplies a function that returns true.
 *
 * Contract for every entry point:
 *
 *	- Called only from the group-slot worker, on its own timer, inside a
 *	  transaction with a snapshot.  Never from an apply worker, a walsender,
 *	  or any path a client waits on.  A wedged provider must not be able to
 *	  stall replication.
 *	- Must respect spock.quorum_timeout.  Overrunning it is UNKNOWN, not a
 *	  reason to keep waiting.
 *	- Must not ereport(ERROR).  Return UNKNOWN/false and put a human-readable
 *	  reason in *errdetail (palloc'd in the caller's context) instead.  An
 *	  error thrown here would abort the very tick that is deciding whether it
 *	  is safe to release WAL.
 *	- Must be free of side effects, with the deliberate exception of
 *	  refresh(), which is where a provider renews whatever registration it
 *	  needs to stay visible to its peers.
 */
typedef struct SpockQuorumProvider
{
	const char *name;			/* shown in spock.quorum_status() */

	/* Called once when the worker starts, and once when it stops. */
	bool		(*startup) (char **errdetail);
	void		(*shutdown) (void);

	/*
	 * Called at the top of every worker tick.  This is where a provider
	 * renews a lease or heartbeat.  Providers whose peers track liveness for
	 * them return true without doing anything.
	 */
	bool		(*refresh) (char **errdetail);

	/* Does this node currently belong to a quorum? */
	SpockQuorumAnswer (*have_quorum) (char **errdetail);

	/*
	 * The cluster's view of its members: a List of SpockQuorumMember *, or
	 * NIL with *errdetail set.  Names with no matching spock.node row are
	 * ignored by the caller, since the quorum system may govern more than
	 * Spock does.
	 */
	List	   *(*members) (char **errdetail);

	/* Is this node the one that should act for the cluster? */
	SpockQuorumAnswer (*is_leader) (char **errdetail);

	/* Name of the current leader, or NULL when unknown. */
	char	   *(*leader) (char **errdetail);
} SpockQuorumProvider;

/* --- GUCs (defined in spock.c) ----------------------------------------- */

extern int	spock_quorum_provider;		/* SpockQuorumProviderId */
extern int	spock_quorum_timeout;		/* milliseconds */
extern char *spock_quorum_etcd_endpoints;
extern char *spock_quorum_cluster_id;

/* --- Consumed by the rest of Spock ------------------------------------- */

/*
 * These wrap the active provider and apply the fail-safe rules, so callers
 * never touch a provider directly and cannot forget to handle UNKNOWN.
 */
extern void spock_quorum_startup(void);
extern void spock_quorum_shutdown(void);
extern void spock_quorum_refresh(void);

/* True only for an unambiguous YES.  UNKNOWN and NO are both false. */
extern bool spock_quorum_have_quorum(void);
extern bool spock_quorum_is_leader(void);

/* NIL when there is no provider or the answer is unavailable. */
extern List *spock_quorum_members(void);

/*
 * Is this member live in the cluster's judgement?  UNKNOWN when there is no
 * provider, which is what keeps a default build behaving exactly as it does
 * today.
 */
extern SpockQuorumAnswer spock_quorum_member_live(const char *node_name);

/* Backing spock.quorum_status(). */
extern const char *spock_quorum_provider_name(void);
extern const char *spock_quorum_last_error(void);
extern TimestampTz spock_quorum_last_consulted(void);

/* Provider tables, each defined by its own file. */
extern const SpockQuorumProvider spock_quorum_provider_none;
extern const SpockQuorumProvider spock_quorum_provider_etcd;
extern const SpockQuorumProvider spock_quorum_provider_pgraft;
extern const SpockQuorumProvider spock_quorum_provider_pgbully;

#endif							/* SPOCK_QUORUM_H */
