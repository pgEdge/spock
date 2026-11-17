/*-------------------------------------------------------------------------
 *
 * spock_startup.c
 *		Startup gate: keep sessions off a restarted node until the apply
 *		workers have caught up with their providers
 *
 * Each apply worker catches up in rounds: it reads the provider's WAL
 * position and applies up to it.  The round's length bounds the lag.  A
 * subscription has caught up when the provider did not move during a round,
 * or when a round after the first took no longer than the lag setting.
 * The database's manager owns the gate and opens it.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <sys/stat.h>

#include "access/xact.h"
#include "access/xlog.h"
#include "catalog/pg_authid.h"
#include "commands/extension.h"
#include "funcapi.h"
#include "libpq-fe.h"
#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "port/atomics.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/hsearch.h"
#include "utils/pg_lsn.h"
#include "utils/timestamp.h"

#include "spock.h"
#include "spock_monitor.h"
#include "spock_node.h"
#include "spock_readonly.h"
#include "spock_startup.h"
#include "spock_sync.h"
#include "spock_worker.h"

#define SPOCK_STARTUP_TRANCHE_NAME	"spock startup gate"

/* How long to wait before asking the provider for its position again. */
#define SPOCK_STARTUP_RETRY_MS		5000

/* With spock.startup_drain_timeout = -1, failed connects before set aside. */
#define SPOCK_STARTUP_MAX_CONNECT_FAILURES	3

typedef enum SpockStartupGateState
{
	STARTUP_GATE_UNKNOWN = 0,	/* the manager has not decided yet */
	STARTUP_GATE_DRAINING,
	STARTUP_GATE_OPEN
} SpockStartupGateState;

typedef enum SpockStartupGateReason
{
	STARTUP_REASON_NONE = 0,
	STARTUP_REASON_DRAINED,
	STARTUP_REASON_TIMEOUT,
	STARTUP_REASON_MANUAL,
	STARTUP_REASON_DISABLED,
	STARTUP_REASON_NOT_APPLICABLE
} SpockStartupGateReason;

typedef enum SpockStartupSubState
{
	STARTUP_SUB_PENDING = 0,	/* no round started yet */
	STARTUP_SUB_CATCHING_UP,
	STARTUP_SUB_CAUGHT_UP,
	STARTUP_SUB_REMOVED,		/* disabled or dropped during the drain */
	STARTUP_SUB_SET_ASIDE		/* provider unreachable, not waited for */
} SpockStartupSubState;

/* One gate per database.  Entries are never removed. */
typedef struct SpockStartupGate
{
	Oid			dboid;			/* hash key, must be first */
	SpockStartupGateState state;
	SpockStartupGateReason reason;
	TimestampTz started_at;		/* start of the drain */
	TimestampTz opened_at;
	pg_atomic_uint64 rejected;	/* statements turned away */
} SpockStartupGate;

typedef struct SpockStartupSubKey
{
	Oid			dboid;
	Oid			subid;
} SpockStartupSubKey;

/*
 * Drain progress of one subscription.  Entries are never removed, so the
 * apply worker can keep a pointer to its own.
 */
typedef struct SpockStartupSub
{
	SpockStartupSubKey key;		/* hash key, must be first */
	SpockStartupSubState state;
	int			round;
	XLogRecPtr	target;			/* provider position the round has to reach */
	TimestampTz round_start;
	int64		last_round_us;	/* length of the last finished round, or -1 */
	int			connect_failures;	/* failed connects in a row */
	pg_atomic_uint64 received;	/* last position seen by the worker */
} SpockStartupSub;

typedef struct SpockStartupShared
{
	LWLock	   *lock;			/* protects the two hash tables */
	bool		armed;			/* set once at postmaster start */
	bool		full;			/* a database found no free gate entry */
	bool		listed;			/* the supervisor has started its managers */
	TimestampTz armed_at;
} SpockStartupShared;

/* GUCs */
int			spock_startup_max_lag = 0;
int			spock_startup_drain_timeout = 0;

static SpockStartupShared *SpockStartup = NULL;
static HTAB *SpockStartupGateHash = NULL;
static HTAB *SpockStartupSubHash = NULL;

/* Set once this session no longer has to look at the gate. */
static bool startup_gate_passed = false;

/* Apply worker state */
static SpockStartupGate *MyStartupGate = NULL;
static SpockStartupSub *MyStartupSub = NULL;
static XLogRecPtr my_round_target = InvalidXLogRecPtr;
static TimestampTz my_round_start = 0;
static TimestampTz my_next_try = 0;

PG_FUNCTION_INFO_V1(spock_startup_gate_open);
PG_FUNCTION_INFO_V1(spock_get_startup_status);

static const char *
startup_gate_state_name(SpockStartupGateState state)
{
	switch (state)
	{
		case STARTUP_GATE_UNKNOWN:
			return "unknown";
		case STARTUP_GATE_DRAINING:
			return "draining";
		case STARTUP_GATE_OPEN:
			return "open";
	}
	return "unknown";
}

static const char *
startup_gate_reason_name(SpockStartupGateReason reason)
{
	switch (reason)
	{
		case STARTUP_REASON_NONE:
			break;
		case STARTUP_REASON_DRAINED:
			return "drained";
		case STARTUP_REASON_TIMEOUT:
			return "timeout";
		case STARTUP_REASON_MANUAL:
			return "manual";
		case STARTUP_REASON_DISABLED:
			return "disabled";
		case STARTUP_REASON_NOT_APPLICABLE:
			return "not applicable";
	}
	return NULL;
}

static const char *
startup_sub_state_name(SpockStartupSubState state)
{
	switch (state)
	{
		case STARTUP_SUB_PENDING:
			return "pending";
		case STARTUP_SUB_CATCHING_UP:
			return "catching up";
		case STARTUP_SUB_CAUGHT_UP:
			return "caught up";
		case STARTUP_SUB_REMOVED:
			return "removed";
		case STARTUP_SUB_SET_ASIDE:
			return "set aside";
	}
	return "pending";
}

/*
 * Request shared memory.  Called from the central spock_shmem_request().
 */
void
spock_startup_shmem_request(int nworkers)
{
	Size		size;

	size = MAXALIGN(sizeof(SpockStartupShared));
	size = add_size(size, hash_estimate_size(nworkers,
											 sizeof(SpockStartupGate)));
	size = add_size(size, hash_estimate_size(nworkers,
											 sizeof(SpockStartupSub)));
	RequestAddinShmemSpace(size);

	RequestNamedLWLockTranche(SPOCK_STARTUP_TRANCHE_NAME, 1);
}

/*
 * Initialize or attach the shared memory structures.  Called from the
 * central spock_shmem_startup() with AddinShmemInitLock held.
 */
void
spock_startup_shmem_startup(bool found)
{
	HASHCTL		hctl;
	bool		is_found;
	int			nworkers = SpockCtx->total_workers;

	Assert(LWLockHeldByMeInMode(AddinShmemInitLock, LW_EXCLUSIVE));

	SpockStartup = ShmemInitStruct("spock startup gate",
								   sizeof(SpockStartupShared), &is_found);
	if (!is_found)
	{
		struct stat st;

		SpockStartup->lock =
			&((GetNamedLWLockTranche(SPOCK_STARTUP_TRANCHE_NAME)[0]).lock);
		SpockStartup->armed_at = GetCurrentTimestamp();
		SpockStartup->full = false;
		SpockStartup->listed = false;

		/* A standby has nothing to drain, now or after promotion. */
		SpockStartup->armed = spock_startup_max_lag > 0 &&
			stat(STANDBY_SIGNAL_FILE, &st) != 0 &&
			stat(RECOVERY_SIGNAL_FILE, &st) != 0;
	}

	MemSet(&hctl, 0, sizeof(hctl));
	hctl.keysize = sizeof(Oid);
	hctl.entrysize = sizeof(SpockStartupGate);
	SpockStartupGateHash = ShmemInitHash("spock startup gate hash",
										 nworkers, nworkers, &hctl,
										 HASH_ELEM | HASH_BLOBS);

	MemSet(&hctl, 0, sizeof(hctl));
	hctl.keysize = sizeof(SpockStartupSubKey);
	hctl.entrysize = sizeof(SpockStartupSub);
	SpockStartupSubHash = ShmemInitHash("spock startup subscription hash",
										nworkers, nworkers, &hctl,
										HASH_ELEM | HASH_BLOBS);
}

static inline bool
startup_gate_armed(void)
{
	return SpockStartup != NULL && SpockStartup->armed;
}

/*
 * Find the gate of this database.  The caller holds the lock.
 */
static SpockStartupGate *
startup_gate_find(void)
{
	Oid			dboid = MyDatabaseId;

	return (SpockStartupGate *) hash_search(SpockStartupGateHash, &dboid,
											HASH_FIND, NULL);
}

/*
 * Find or create the gate of this database.  The caller holds the lock in
 * exclusive mode.  Returns NULL if the table is full.
 */
static SpockStartupGate *
startup_gate_enter(void)
{
	Oid			dboid = MyDatabaseId;
	SpockStartupGate *gate;
	bool		found;

	gate = (SpockStartupGate *) hash_search(SpockStartupGateHash, &dboid,
											HASH_ENTER_NULL, &found);
	if (gate != NULL && !found)
	{
		gate->state = STARTUP_GATE_UNKNOWN;
		gate->reason = STARTUP_REASON_NONE;
		gate->started_at = 0;
		gate->opened_at = 0;
		pg_atomic_init_u64(&gate->rejected, 0);
	}

	return gate;
}

/*
 * Open the gate of this database, unless it is open already.  Returns true
 * if this call opened it.
 */
static bool
startup_gate_set_open(SpockStartupGateReason reason)
{
	SpockStartupGate *gate;
	bool		opened = false;

	LWLockAcquire(SpockStartup->lock, LW_EXCLUSIVE);
	gate = startup_gate_enter();
	if (gate != NULL && gate->state != STARTUP_GATE_OPEN)
	{
		gate->state = STARTUP_GATE_OPEN;
		gate->reason = reason;
		gate->opened_at = GetCurrentTimestamp();
		opened = true;
	}
	LWLockRelease(SpockStartup->lock);

	return opened;
}

/*
 * Is this statement one a driver or a pooler sends to set a session up?
 * They do not touch table data, so they pass a closed gate.
 */
static bool
startup_setup_stmt(Node *utilityStmt)
{
	if (utilityStmt == NULL)
		return false;

	return IsA(utilityStmt, TransactionStmt) ||
		IsA(utilityStmt, VariableSetStmt) ||
		IsA(utilityStmt, VariableShowStmt) ||
		IsA(utilityStmt, DiscardStmt);
}

/*
 * Does this statement pass the gate whatever its state?
 */
static bool
startup_stmt_exempt(Node *utilityStmt)
{
	/* Checked first: this may run in an aborted transaction. */
	if (startup_setup_stmt(utilityStmt))
		return true;

	/* Operators, peers and monitoring are not held back. */
	return spock_startup_max_lag <= 0 || superuser() ||
		has_rolreplication(GetUserId()) ||
		has_privs_of_role(GetUserId(), ROLE_PG_MONITOR);
}

/*
 * Has the drain that started at since run out of time?
 */
static bool
startup_timed_out(TimestampTz since)
{
	return spock_startup_drain_timeout > 0 &&
		TimestampDifferenceExceeds(since, GetCurrentTimestamp(),
								   spock_startup_drain_timeout);
}

/*
 * State of this database's gate as a session sees it, and the time its
 * timeout counts from.
 */
static SpockStartupGateState
startup_gate_state(SpockStartupGate **gate_out, TimestampTz *since)
{
	SpockStartupGate *gate;
	SpockStartupGateState state = STARTUP_GATE_UNKNOWN;
	bool		managed;

	*since = SpockStartup->armed_at;

	LWLockAcquire(SpockStartup->lock, LW_SHARED);
	gate = startup_gate_find();
	if (gate != NULL)
		state = gate->state;
	else if (SpockStartup->full)
		state = STARTUP_GATE_OPEN;
	if (state == STARTUP_GATE_DRAINING)
		*since = gate->started_at;
	LWLockRelease(SpockStartup->lock);

	*gate_out = gate;
	if (gate != NULL || state == STARTUP_GATE_OPEN || !SpockStartup->listed)
		return state;

	/* No manager will report for a database Spock arrived in later. */
	LWLockAcquire(SpockCtx->lock, LW_SHARED);
	managed = (spock_manager_find(MyDatabaseId) != NULL);
	LWLockRelease(SpockCtx->lock);

	return managed ? state : STARTUP_GATE_OPEN;
}

/*
 * Is the gate of this database open for good?  A database without Spock
 * has nothing to wait for.
 */
static bool
startup_database_open(SpockStartupGate **gate, TimestampTz *since)
{
	*gate = NULL;
	*since = 0;

	if (!OidIsValid(get_extension_oid(EXTENSION_NAME, true)))
		return true;

	return startup_gate_state(gate, since) == STARTUP_GATE_OPEN;
}

/*
 * Fail the statement if the gate of this database is closed.  utilityStmt
 * is NULL unless called at parse analysis for a utility statement.
 */
void
spock_startup_gate_check(Node *utilityStmt)
{
	SpockStartupGate *gate;
	TimestampTz since;

	if (startup_gate_passed)
		return;

	/* Only client sessions are held back. */
	if (!startup_gate_armed() || MyBackendType != B_BACKEND)
	{
		startup_gate_passed = true;
		return;
	}

	if (startup_stmt_exempt(utilityStmt))
		return;

	if (startup_database_open(&gate, &since))
	{
		startup_gate_passed = true;
		return;
	}

	/* Do not depend on the manager to open the gate on timeout. */
	if (startup_timed_out(since))
		return;

	if (gate != NULL)
		pg_atomic_fetch_add_u64(&gate->rejected, 1);

	ereport(ERROR,
			(errcode(ERRCODE_CANNOT_CONNECT_NOW),
			 errmsg("spock node is catching up with its peers after a restart"),
			 errhint("Retry later, or connect to another node.")));
}

/*
 * Called by the supervisor once it has registered the managers.
 */
void
spock_startup_supervisor_listed(void)
{
	if (!startup_gate_armed() || SpockStartup->listed)
		return;

	LWLockAcquire(SpockStartup->lock, LW_EXCLUSIVE);
	SpockStartup->listed = true;
	LWLockRelease(SpockStartup->lock);
}

/*
 * Subscriptions the gate waits for: the enabled ones that were replicating
 * before the restart.  With spock.readonly = all nothing is applied, so
 * nothing can drain.
 */
static List *
startup_tracked_subscriptions(void)
{
	SpockLocalNode *node;
	List	   *subs;
	List	   *subids = NIL;
	ListCell   *lc;

	node = get_local_node(false, true);
	if (node == NULL || spock_startup_max_lag <= 0 ||
		spock_readonly == READONLY_ALL)
		return NIL;

	subs = get_node_subscriptions(node->node->id, false);
	foreach(lc, subs)
	{
		SpockSubscription *sub = (SpockSubscription *) lfirst(lc);
		SpockSyncStatus *sync;

		if (!sub->enabled)
			continue;

		sync = get_subscription_sync_status(sub->id, true);
		if (sync != NULL && sync->status == SYNC_STATUS_READY)
			subids = lappend_oid(subids, sub->id);
	}

	return subids;
}

/*
 * Create the drain entry of one subscription.  The caller holds the lock
 * in exclusive mode.
 */
static bool
startup_sub_track(Oid subid)
{
	SpockStartupSubKey key;
	SpockStartupSub *sub;
	bool		found;

	MemSet(&key, 0, sizeof(key));
	key.dboid = MyDatabaseId;
	key.subid = subid;

	sub = (SpockStartupSub *) hash_search(SpockStartupSubHash, &key,
										  HASH_ENTER_NULL, &found);
	if (sub == NULL)
		return false;

	sub->state = STARTUP_SUB_PENDING;
	sub->round = 0;
	sub->target = InvalidXLogRecPtr;
	sub->round_start = 0;
	sub->last_round_us = -1;
	sub->connect_failures = 0;
	pg_atomic_init_u64(&sub->received, InvalidXLogRecPtr);

	return true;
}

/*
 * Close the gate of this database for subids, or open it if there are
 * none.  Returns NULL if the gate table is full.
 */
static SpockStartupGate *
startup_gate_arm(List *subids, bool *draining)
{
	SpockStartupGate *gate;
	ListCell   *lc;

	*draining = false;

	LWLockAcquire(SpockStartup->lock, LW_EXCLUSIVE);
	gate = startup_gate_enter();
	if (gate == NULL)
		SpockStartup->full = true;
	else if (gate->state == STARTUP_GATE_UNKNOWN)
	{
		foreach(lc, subids)
		{
			if (startup_sub_track(lfirst_oid(lc)))
				*draining = true;
		}

		if (*draining)
		{
			gate->state = STARTUP_GATE_DRAINING;
			gate->started_at = GetCurrentTimestamp();
		}
		else
		{
			gate->state = STARTUP_GATE_OPEN;
			gate->reason = STARTUP_REASON_NOT_APPLICABLE;
			gate->opened_at = GetCurrentTimestamp();
		}
	}
	LWLockRelease(SpockStartup->lock);

	return gate;
}

/*
 * Decide what the gate of this database waits for.  Called once by the
 * manager at its start.
 */
void
spock_startup_manager_begin(void)
{
	SpockStartupGate *gate;
	bool		draining;
	int			nsubs;

	if (!startup_gate_armed())
		return;

	/* A restarted manager keeps what the first one decided. */
	LWLockAcquire(SpockStartup->lock, LW_SHARED);
	gate = startup_gate_find();
	LWLockRelease(SpockStartup->lock);
	if (gate != NULL)
		return;

	StartTransactionCommand();
	{
		List	   *subids = startup_tracked_subscriptions();

		nsubs = list_length(subids);
		gate = startup_gate_arm(subids, &draining);
	}
	CommitTransactionCommand();

	if (gate == NULL)
		ereport(WARNING,
				(errmsg("spock startup gate table is full, the gate of this database stays open")));
	else if (draining)
	{
		ereport(LOG,
				(errmsg("spock startup drain started, waiting for %d subscription(s)",
						nsubs)));
		spock_monitor_record_event(SPOCK_EVENT_STARTUP_DRAIN_STARTED,
								   InvalidOid, InvalidXLogRecPtr,
								   "waiting for %d subscription(s)", nsubs);
	}
}

/*
 * Is the gate of this database draining?  If so, also return when the
 * drain started.
 */
static bool
startup_draining_since(TimestampTz *started_at)
{
	SpockStartupGate *gate;
	bool		draining;

	LWLockAcquire(SpockStartup->lock, LW_SHARED);
	gate = startup_gate_find();
	draining = (gate != NULL && gate->state == STARTUP_GATE_DRAINING);
	if (draining)
		*started_at = gate->started_at;
	LWLockRelease(SpockStartup->lock);

	return draining;
}

static SpockSubscription *
startup_find_enabled(List *subs, Oid subid)
{
	ListCell   *lc;

	foreach(lc, subs)
	{
		SpockSubscription *s = (SpockSubscription *) lfirst(lc);

		if (s->id == subid && s->enabled)
			return s;
	}

	return NULL;
}

/*
 * With a timeout of -1, a provider the worker cannot reach is set aside.
 */
static bool
startup_sub_unreachable(SpockStartupSub *sub)
{
	return sub->state == STARTUP_SUB_SET_ASIDE ||
		(spock_startup_drain_timeout < 0 &&
		 sub->connect_failures >= SPOCK_STARTUP_MAX_CONNECT_FAILURES);
}

static void
startup_append_name(StringInfo buf, const char *name)
{
	appendStringInfo(buf, "%s\"%s\"", buf->len > 0 ? ", " : "", name);
}

/*
 * Drop the subscriptions that are gone and list the ones still behind and
 * the ones set aside.  Returns how many are still behind.
 */
static int
startup_drain_scan(List *subs, StringInfo behind, StringInfo set_aside)
{
	HASH_SEQ_STATUS seq;
	SpockStartupSub *sub;
	int			pending = 0;

	LWLockAcquire(SpockStartup->lock, LW_EXCLUSIVE);
	hash_seq_init(&seq, SpockStartupSubHash);
	while ((sub = (SpockStartupSub *) hash_seq_search(&seq)) != NULL)
	{
		SpockSubscription *cur;

		if (sub->key.dboid != MyDatabaseId ||
			sub->state == STARTUP_SUB_REMOVED ||
			sub->state == STARTUP_SUB_CAUGHT_UP)
			continue;

		cur = startup_find_enabled(subs, sub->key.subid);
		if (cur == NULL)
			sub->state = STARTUP_SUB_REMOVED;
		else if (startup_sub_unreachable(sub))
		{
			sub->state = STARTUP_SUB_SET_ASIDE;
			startup_append_name(set_aside, cur->name);
		}
		else
		{
			pending++;
			startup_append_name(behind, cur->name);
		}
	}
	LWLockRelease(SpockStartup->lock);

	return pending;
}

static void
startup_open_disabled(void)
{
	if (!startup_gate_set_open(STARTUP_REASON_DISABLED))
		return;

	ereport(LOG,
			(errmsg("spock startup gate opened: spock.max_lag_for_availability_on_startup was set to 0")));
	spock_monitor_record_event(SPOCK_EVENT_STARTUP_DRAIN_COMPLETED,
							   InvalidOid, InvalidXLogRecPtr, "switched off");
}

static void
startup_open_drained(const char *set_aside)
{
	if (!startup_gate_set_open(STARTUP_REASON_DRAINED))
		return;

	if (set_aside[0] != '\0')
	{
		ereport(WARNING,
				(errmsg("spock startup gate opened without waiting for unreachable providers"),
				 errdetail("Subscriptions set aside: %s.", set_aside)));
		spock_monitor_record_event(SPOCK_EVENT_STARTUP_DRAIN_COMPLETED,
								   InvalidOid, InvalidXLogRecPtr,
								   "set aside: %s", set_aside);
		return;
	}

	ereport(LOG,
			(errmsg("spock startup gate opened: all subscriptions have caught up")));
	spock_monitor_record_event(SPOCK_EVENT_STARTUP_DRAIN_COMPLETED,
							   InvalidOid, InvalidXLogRecPtr,
							   "all subscriptions have caught up");
}

static void
startup_open_timed_out(const char *behind)
{
	if (!startup_gate_set_open(STARTUP_REASON_TIMEOUT))
		return;

	ereport(WARNING,
			(errmsg("spock startup gate opened on timeout"),
			 errdetail("Subscriptions that have not caught up: %s.", behind)));
	spock_monitor_record_event(SPOCK_EVENT_STARTUP_DRAIN_TIMED_OUT,
							   InvalidOid, InvalidXLogRecPtr,
							   "not caught up: %s", behind);
}

/*
 * Open the gate if the drain is over.  Called by the manager on every
 * wakeup; returns true while the drain is still running.
 */
bool
spock_startup_manager_check(void)
{
	SpockLocalNode *node;
	List	   *subs = NIL;
	StringInfoData behind;
	StringInfoData set_aside;
	TimestampTz started_at = 0;
	bool		draining = true;

	if (!startup_gate_armed() || !startup_draining_since(&started_at))
		return false;

	if (spock_startup_max_lag <= 0)
	{
		startup_open_disabled();
		return false;
	}

	StartTransactionCommand();

	node = get_local_node(false, true);
	if (node != NULL)
		subs = get_node_subscriptions(node->node->id, false);

	initStringInfo(&behind);
	initStringInfo(&set_aside);

	if (startup_drain_scan(subs, &behind, &set_aside) == 0)
	{
		startup_open_drained(set_aside.data);
		draining = false;
	}
	else if (startup_timed_out(started_at))
	{
		startup_open_timed_out(behind.data);
		draining = false;
	}

	CommitTransactionCommand();

	return draining;
}

/*
 * Read the provider's WAL flush position, or InvalidXLogRecPtr on failure.
 * The walsender sends flushed WAL only, so the insert position could be a
 * target the stream never reaches.
 */
static XLogRecPtr
startup_fetch_provider_lsn(void)
{
	PGconn	   *conn = NULL;
	PGresult   *res;
	XLogRecPtr	lsn = InvalidXLogRecPtr;
	MemoryContext oldctx = CurrentMemoryContext;

	PG_TRY();
	{
		conn = spock_connect(MySubscription->origin_if->dsn,
							 MySubscription->name, "startup");
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(oldctx);
		FlushErrorState();
		conn = NULL;
	}
	PG_END_TRY();

	if (conn == NULL)
		return InvalidXLogRecPtr;

	res = PQexec(conn,
				 "SELECT (pg_catalog.pg_current_wal_flush_lsn() - '0/0')::text");
	if (PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) == 1)
	{
		char	   *end;
		uint64		bytes = strtou64(PQgetvalue(res, 0, 0), &end, 10);

		if (*end == '\0')
			lsn = (XLogRecPtr) bytes;
	}
	PQclear(res);
	PQfinish(conn);

	return lsn;
}

/*
 * Find the drain entry of this worker's subscription, if the gate of its
 * database is still waiting for it.
 */
static SpockStartupSub *
startup_sub_find(SpockStartupGate **gate_out)
{
	SpockStartupSubKey key;
	SpockStartupGate *gate;
	SpockStartupSub *sub = NULL;

	MemSet(&key, 0, sizeof(key));
	key.dboid = MyDatabaseId;
	key.subid = MySubscription->id;

	LWLockAcquire(SpockStartup->lock, LW_SHARED);
	gate = startup_gate_find();
	if (gate != NULL && gate->state == STARTUP_GATE_DRAINING)
		sub = (SpockStartupSub *) hash_search(SpockStartupSubHash, &key,
											  HASH_FIND, NULL);
	if (sub != NULL &&
		sub->state != STARTUP_SUB_PENDING &&
		sub->state != STARTUP_SUB_CATCHING_UP)
		sub = NULL;
	LWLockRelease(SpockStartup->lock);

	if (gate_out != NULL)
		*gate_out = gate;
	return sub;
}

/*
 * Count a connect attempt to the provider.  spock_startup_apply_attach()
 * clears the count once the connection is up.
 */
void
spock_startup_apply_connecting(void)
{
	SpockStartupSub *sub;

	if (!startup_gate_armed())
		return;

	sub = startup_sub_find(NULL);
	if (sub == NULL)
		return;

	LWLockAcquire(SpockStartup->lock, LW_EXCLUSIVE);
	sub->connect_failures++;
	LWLockRelease(SpockStartup->lock);
}

/*
 * Find out whether this apply worker takes part in the startup drain.
 * Called once the worker is connected to its provider.
 */
void
spock_startup_apply_attach(void)
{
	MyStartupGate = NULL;
	MyStartupSub = NULL;
	my_round_target = InvalidXLogRecPtr;
	my_next_try = 0;

	if (!startup_gate_armed())
		return;

	MyStartupSub = startup_sub_find(&MyStartupGate);
	if (MyStartupSub == NULL)
		return;

	LWLockAcquire(SpockStartup->lock, LW_EXCLUSIVE);
	MyStartupSub->connect_failures = 0;
	LWLockRelease(SpockStartup->lock);
}

/*
 * Start a round that has to reach target.  The round is timed from now.
 */
static void
startup_round_begin(XLogRecPtr target)
{
	TimestampTz now = GetCurrentTimestamp();

	my_round_target = target;
	my_round_start = now;

	LWLockAcquire(SpockStartup->lock, LW_EXCLUSIVE);
	MyStartupSub->state = STARTUP_SUB_CATCHING_UP;
	MyStartupSub->round++;
	MyStartupSub->target = target;
	MyStartupSub->round_start = now;
	LWLockRelease(SpockStartup->lock);
}

/*
 * Start a round at the provider's current position.  Returns false if the
 * position could not be read; the next try is then a few seconds away.
 */
static bool
startup_round_try_begin(void)
{
	TimestampTz now = GetCurrentTimestamp();
	XLogRecPtr	provider;

	if (now < my_next_try)
		return false;

	provider = startup_fetch_provider_lsn();
	if (provider == InvalidXLogRecPtr)
	{
		ereport(LOG,
				(errmsg("SPOCK %s: could not read the provider WAL position for the startup drain, will retry",
						MySubscription->name)));
		my_next_try = TimestampTzPlusMilliseconds(now, SPOCK_STARTUP_RETRY_MS);
		return false;
	}

	startup_round_begin(provider);
	return true;
}

/*
 * Caught up if the provider stood still during the round, or if a round
 * after the first took no longer than the lag setting.
 */
static bool
startup_round_caught_up(XLogRecPtr provider, int round, int64 round_us)
{
	if (provider != InvalidXLogRecPtr && provider <= my_round_target)
		return true;

	return round >= 2 && round_us <= (int64) spock_startup_max_lag * 1000;
}

/*
 * End the round that reached its target, and start the next one if the
 * subscription has not caught up.
 */
static void
startup_round_end(void)
{
	int64		round_us = GetCurrentTimestamp() - my_round_start;
	XLogRecPtr	provider = startup_fetch_provider_lsn();
	bool		caught_up;
	int			round;

	LWLockAcquire(SpockStartup->lock, LW_EXCLUSIVE);
	round = MyStartupSub->round;
	caught_up = startup_round_caught_up(provider, round, round_us);
	MyStartupSub->last_round_us = round_us;
	if (caught_up)
		MyStartupSub->state = STARTUP_SUB_CAUGHT_UP;
	LWLockRelease(SpockStartup->lock);

	ereport(LOG,
			(errmsg("SPOCK %s: startup drain round %d reached %X/%X in %ld ms%s",
					MySubscription->name, round,
					LSN_FORMAT_ARGS(my_round_target),
					(long) (round_us / 1000),
					caught_up ? ", caught up" : "")));

	my_round_target = InvalidXLogRecPtr;
	if (caught_up)
		MyStartupSub = NULL;
	else if (provider != InvalidXLogRecPtr)
		startup_round_begin(provider);
}

/*
 * Advance the startup drain of this apply worker.  Called from the apply
 * loop with the last position received from the provider.
 */
void
spock_startup_apply_progress(XLogRecPtr last_received, bool in_remote_xact)
{
	if (MyStartupSub == NULL)
		return;

	/* The gate was opened in some other way, stop measuring. */
	if (MyStartupGate->state != STARTUP_GATE_DRAINING ||
		MyStartupSub->state == STARTUP_SUB_SET_ASIDE)
	{
		MyStartupSub = NULL;
		return;
	}

	if (my_round_target == InvalidXLogRecPtr && !startup_round_try_begin())
		return;

	pg_atomic_write_u64(&MyStartupSub->received, last_received);

	/* The round ends once everything up to the target has been applied. */
	if (!in_remote_xact && last_received >= my_round_target)
		startup_round_end();
}

/*
 * spock.startup_gate_open(): open this database's gate by hand.  Returns
 * true if the gate was closed.
 */
Datum
spock_startup_gate_open(PG_FUNCTION_ARGS)
{
	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to open the spock startup gate")));

	if (!startup_gate_armed())
		PG_RETURN_BOOL(false);

	if (!startup_gate_set_open(STARTUP_REASON_MANUAL))
		PG_RETURN_BOOL(false);

	ereport(LOG,
			(errmsg("spock startup gate opened by spock.startup_gate_open()")));
	spock_monitor_record_event(SPOCK_EVENT_STARTUP_DRAIN_COMPLETED,
							   InvalidOid, InvalidXLogRecPtr,
							   "opened by spock.startup_gate_open()");

	PG_RETURN_BOOL(true);
}

static Datum
startup_interval_datum(int64 usecs)
{
	Interval   *result = (Interval *) palloc0(sizeof(Interval));

	result->time = usecs;

	return IntervalPGetDatum(result);
}

/* Columns of spock.get_startup_status() */
enum
{
	SS_DATABASE_ID = 0,
	SS_SUBSCRIPTION_ID,
	SS_GATE_STATE,
	SS_GATE_REASON,
	SS_DRAIN_STARTED,
	SS_GATE_OPENED,
	SS_TIMEOUT_LEFT,
	SS_REJECTED,
	SS_DRAIN_STATE,
	SS_ROUND,
	SS_TARGET_LSN,
	SS_RECEIVED_LSN,
	SS_ROUND_STARTED,
	SS_LAST_ROUND_TIME,
	SS_NUM_COLUMNS
};

/*
 * Fill the gate columns of a spock.get_startup_status() row.
 */
static void
startup_status_gate(SpockStartupGate *gate, TimestampTz now,
					Datum *values, bool *nulls)
{
	const char *reason = startup_gate_reason_name(gate->reason);

	values[SS_DATABASE_ID] = ObjectIdGetDatum(gate->dboid);
	values[SS_GATE_STATE] =
		CStringGetTextDatum(startup_gate_state_name(gate->state));

	nulls[SS_GATE_REASON] = (reason == NULL);
	if (reason != NULL)
		values[SS_GATE_REASON] = CStringGetTextDatum(reason);

	nulls[SS_DRAIN_STARTED] = (gate->started_at == 0);
	values[SS_DRAIN_STARTED] = TimestampTzGetDatum(gate->started_at);
	nulls[SS_GATE_OPENED] = (gate->opened_at == 0);
	values[SS_GATE_OPENED] = TimestampTzGetDatum(gate->opened_at);

	nulls[SS_TIMEOUT_LEFT] = !(gate->state == STARTUP_GATE_DRAINING &&
							   spock_startup_drain_timeout > 0);
	if (!nulls[SS_TIMEOUT_LEFT])
	{
		int64		left = (int64) spock_startup_drain_timeout * 1000 -
			(now - gate->started_at);

		values[SS_TIMEOUT_LEFT] = startup_interval_datum(Max(left, 0));
	}

	values[SS_REJECTED] =
		Int64GetDatum((int64) pg_atomic_read_u64(&gate->rejected));
}

/*
 * Fill the subscription columns of a row, or make them NULL when sub is
 * NULL.
 */
static void
startup_status_sub(SpockStartupSub *sub, Datum *values, bool *nulls)
{
	XLogRecPtr	received;

	if (sub == NULL)
	{
		nulls[SS_SUBSCRIPTION_ID] = true;
		nulls[SS_DRAIN_STATE] = true;
		nulls[SS_ROUND] = true;
		nulls[SS_TARGET_LSN] = true;
		nulls[SS_RECEIVED_LSN] = true;
		nulls[SS_ROUND_STARTED] = true;
		nulls[SS_LAST_ROUND_TIME] = true;
		return;
	}

	received = pg_atomic_read_u64(&sub->received);

	values[SS_SUBSCRIPTION_ID] = ObjectIdGetDatum(sub->key.subid);
	values[SS_DRAIN_STATE] =
		CStringGetTextDatum(startup_sub_state_name(sub->state));
	values[SS_ROUND] = Int32GetDatum(sub->round);

	nulls[SS_TARGET_LSN] = (sub->target == InvalidXLogRecPtr);
	values[SS_TARGET_LSN] = LSNGetDatum(sub->target);
	nulls[SS_RECEIVED_LSN] = (received == InvalidXLogRecPtr);
	values[SS_RECEIVED_LSN] = LSNGetDatum(received);
	nulls[SS_ROUND_STARTED] = (sub->round_start == 0);
	values[SS_ROUND_STARTED] = TimestampTzGetDatum(sub->round_start);

	nulls[SS_LAST_ROUND_TIME] = (sub->last_round_us < 0);
	if (sub->last_round_us >= 0)
		values[SS_LAST_ROUND_TIME] = startup_interval_datum(sub->last_round_us);
}

/*
 * spock.get_startup_status(): one row per tracked subscription, or one row
 * with NULL subscription columns for a gate that tracks none.
 */
Datum
spock_get_startup_status(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	HASH_SEQ_STATUS gseq;
	SpockStartupGate *gate;
	TimestampTz now = GetCurrentTimestamp();

	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == SS_NUM_COLUMNS);

	if (!startup_gate_armed())
		return (Datum) 0;

	LWLockAcquire(SpockStartup->lock, LW_SHARED);

	hash_seq_init(&gseq, SpockStartupGateHash);
	while ((gate = (SpockStartupGate *) hash_seq_search(&gseq)) != NULL)
	{
		Datum		values[SS_NUM_COLUMNS] = {0};
		bool		nulls[SS_NUM_COLUMNS] = {0};
		HASH_SEQ_STATUS sseq;
		SpockStartupSub *sub;
		bool		any = false;

		startup_status_gate(gate, now, values, nulls);

		hash_seq_init(&sseq, SpockStartupSubHash);
		while ((sub = (SpockStartupSub *) hash_seq_search(&sseq)) != NULL)
		{
			if (sub->key.dboid != gate->dboid)
				continue;

			startup_status_sub(sub, values, nulls);
			tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
								 values, nulls);
			any = true;
		}

		if (!any)
		{
			startup_status_sub(NULL, values, nulls);
			tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
								 values, nulls);
		}
	}

	LWLockRelease(SpockStartup->lock);

	return (Datum) 0;
}
