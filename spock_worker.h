/*-------------------------------------------------------------------------
 *
 * spock_worker.h
 *              spock worker helper functions
 *
 * Copyright (c) 2021-2022, OSCG Partners, LLC
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_WORKER_H
#define SPOCK_WORKER_H

#include "storage/lock.h"

#include "spock.h"

#define SPOCK_STATS_COLS	8

typedef enum {
	SPOCK_WORKER_NONE,		/* Unused slot. */
	SPOCK_WORKER_MANAGER,	/* Manager. */
	SPOCK_WORKER_APPLY,		/* Apply. */
	SPOCK_WORKER_SYNC		/* Special type of Apply that synchronizes
								 * one table. */
} SpockWorkerType;

typedef struct SpockApplyWorker
{
	Oid			subid;				/* Subscription id for apply worker. */
	bool		sync_pending;		/* Is there new synchronization info pending?. */
	XLogRecPtr	replay_stop_lsn;	/* Replay should stop here if defined. */
} SpockApplyWorker;

typedef struct SpockSyncWorker
{
	SpockApplyWorker	apply; /* Apply worker info, must be first. */
	NameData	nspname;	/* Name of the schema of table to copy if any. */
	NameData	relname;	/* Name of the table to copy if any. */
} SpockSyncWorker;

typedef struct SpockWorker {
	SpockWorkerType	worker_type;

	/* Generation counter incremented at each registration */
	uint16 generation;

	/* Pointer to proc array. NULL if not running. */
	PGPROC *proc;

	/* Time at which worker crashed (normally 0). */
	TimestampTz	crashed_at;

	/* Database id to connect to. */
	Oid		dboid;

	/* Type-specific worker info */
	union
	{
		SpockApplyWorker apply;
		SpockSyncWorker sync;
	} worker;

} SpockWorker;

typedef struct SpockContext {
	/* Write lock for the entire context. */
	LWLock	   *lock;

	/* Access lock for the Conflict Tracking Hash. */
	LWLock	   *cth_lock;

	/* Counter for entries in Conflict Tracking Hash */
	int			cth_count;

	/* Supervisor process. */
	PGPROC	   *supervisor;

	/* Signal that subscription info have changed. */
	bool		subscriptions_changed;

	/* Background workers. */
	int			total_workers;
	SpockWorker  workers[FLEXIBLE_ARRAY_MEMBER];
} SpockContext;

typedef struct spockHashKey
{
	/* hash key */
	Oid			dboid;
	Oid			relid;
} spockHashKey;

/*
 * statistics counters to keep in hashtable.
 */
typedef struct spockCounters
{
	/* stats counters */
	int64	n_tup_ins;
	int64	n_tup_upd;
	int64	n_tup_del;

	TimestampTz	last_reset;
} spockCounters;

typedef struct spockStatsEntry
{
	spockHashKey key;			/* hash key */

	Oid		nodeid;
	char	slot_name[NAMEDATALEN];
	char	schemaname[NAMEDATALEN];
	char	relname[NAMEDATALEN];

	spockCounters	counters;		/* stat counters */
	slock_t	mutex;
} spockStatsEntry;

typedef enum spockStatsType
{
	INSERT_STATS,
	UPDATE_STATS,
	DELETE_STATS
} spockStatsType;

extern HTAB				   *SpockHash;
extern HTAB				   *SpockConflictHash;
extern SpockContext		   *SpockCtx;
extern SpockWorker		   *MySpockWorker;
extern SpockApplyWorker	   *MyApplyWorker;
extern SpockSubscription   *MySubscription;

extern volatile sig_atomic_t got_SIGTERM;

extern void handle_sigterm(SIGNAL_ARGS);

extern void spock_subscription_changed(Oid subid, bool kill);

extern void spock_worker_shmem_init(void);

extern int spock_worker_register(SpockWorker *worker);
extern void spock_worker_attach(int slot, SpockWorkerType type);

extern SpockWorker *spock_manager_find(Oid dboid);
extern SpockWorker *spock_apply_find(Oid dboid, Oid subscriberid);
extern List *spock_apply_find_all(Oid dboid);

extern SpockWorker *spock_sync_find(Oid dboid, Oid subid,
											const char *nspname, const char *relname);
extern List *spock_sync_find_all(Oid dboid, Oid subscriberid);

extern SpockWorker *spock_get_worker(int slot);
extern bool spock_worker_running(SpockWorker *w);
extern void spock_worker_kill(SpockWorker *worker);

extern const char * spock_worker_type_name(SpockWorkerType type);
extern void handle_sub_counters(Relation relation, spockStatsType typ, int ntup);
extern void handle_pr_counters(Relation relation, char *slotname, Oid nodeid, spockStatsType typ, int ntup);

#endif /* SPOCK_WORKER_H */
