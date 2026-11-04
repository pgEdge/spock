/*-------------------------------------------------------------------------
 *
 * spock_quorum.h
 *		Pluggable quorum provider interface.
 *
 * Spock does not implement consensus.  It asks an external system a small
 * number of questions and stays conservative when it cannot get an answer.
 * This header is the whole contract.
 *
 * Every provider implements the same interface: there are no optional
 * entry points and no capability negotiation.  That is affordable because
 * the interface asks only for judgements, never for storage.  Spock keeps
 * its durable state in its own crash-safe catalogs, and keeping storage out
 * is what lets a leader-election-only system such as pgBully sit behind the
 * same interface as etcd, which has a replicated key space.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_QUORUM_H
#define SPOCK_QUORUM_H

#include "nodes/pg_list.h"
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
 * Callers treat it exactly as they treat NO, which is the fail-safe rule,
 * but the two are kept apart so the status view and the log can tell a
 * cluster that lost quorum from a provider that stopped answering.
 */
typedef enum SpockQuorumAnswer
{
	SPOCK_QUORUM_NO = 0,
	SPOCK_QUORUM_YES,
	SPOCK_QUORUM_UNKNOWN
} SpockQuorumAnswer;

/* One member, as the quorum system sees it, not as spock.node sees it. */
typedef struct SpockQuorumMember
{
	char	   *name;			/* matches spock.node.node_name */
	bool		live;			/* reachable, in the provider's judgement */
	bool		voting;			/* counts toward a majority */
	TimestampTz last_seen;		/* 0 when the provider does not track it */
} SpockQuorumMember;

/*
 * One reading of the cluster.  A provider fills it from a single request
 * (one etcd transaction, one SQL statement), so every field describes the
 * same instant.  leader, leader_name and members are only meaningful when
 * quorum is YES; the caller discards them otherwise.
 */
typedef struct SpockQuorumReading
{
	SpockQuorumAnswer quorum;	/* is this node inside a quorum */
	SpockQuorumAnswer leader;	/* is this node the leader */
	char	   *leader_name;	/* NULL when nobody leads or it is unknown */
	List	   *members;		/* SpockQuorumMember *, NIL when unknown */
} SpockQuorumReading;

/*
 * Provider callbacks.  All of them are mandatory.
 *
 * Contract for every entry point:
 *
 *	- Never from an apply worker, a walsender, or any path a client waits
 *	  on.  A wedged provider must not be able to stall replication.  Today
 *	  the only callers are spock.quorum_status() and spock.quorum_members(),
 *	  which an operator runs by hand.
 *	- Must respect spock.quorum_timeout.  Overrunning it is a failed call,
 *	  not a reason to keep waiting.  etcd applies it as an HTTP deadline;
 *	  the in-database providers arm a timeout around each query.
 *	- Must not ereport(ERROR).  Return false and put a human-readable
 *	  reason in *errdetail (palloc'd in the caller's context) instead.
 *	- Must be free of side effects, with the deliberate exception of
 *	  refresh(), which is where a provider renews whatever registration it
 *	  needs to stay visible to its peers and campaigns for leadership.
 *	- Must be called inside a transaction.  The in-database providers run
 *	  SQL, and the layer checks member names against spock.node.
 *	- A worker that calls these must keep SIGINT on StatementCancelHandler,
 *	  which is the default for a database-connected background worker, or
 *	  the in-database deadline cannot interrupt a stuck query.
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

	/*
	 * One reading of the cluster.  Returns false with *errdetail set when
	 * nothing could be obtained; the caller then treats every answer as
	 * UNKNOWN.  Member names with no matching spock.node row are dropped by
	 * the caller, since the quorum system may govern more than Spock does.
	 */
	bool		(*read) (SpockQuorumReading *reading, char **errdetail);
} SpockQuorumProvider;

/* --- GUCs (defined in spock.c) ----------------------------------------- */

extern int	spock_quorum_provider;	/* SpockQuorumProviderId */
extern int	spock_quorum_timeout;	/* milliseconds */
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
