/*-------------------------------------------------------------------------
 *
 * spock_worker.h
 *              spock worker helper functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_WORKER_H
#define SPOCK_WORKER_H

#include "storage/lock.h"

#include "spock.h"
#include "spock_apply.h"			/* for SpockApplyGroupData */
#include "spock_output_plugin.h"	/* for SpockOutputSlotGroup */
#include "spock_proto_native.h"

typedef enum {
	SPOCK_WORKER_NONE,		/* Unused slot. */
	SPOCK_WORKER_MANAGER,	/* Manager. */
	SPOCK_WORKER_APPLY,		/* Apply. */
	SPOCK_WORKER_SYNC		/* Special type of Apply that synchronizes
								 * one table. */
} SpockWorkerType;

typedef enum {
	SPOCK_WORKER_STATUS_NONE,		/* Unused slot. */
	SPOCK_WORKER_STATUS_IDLE,		/* Idle. */
	SPOCK_WORKER_STATUS_RUNNING,	/* Running. */
	SPOCK_WORKER_STATUS_STOPPING,	/* Stopping. */
	SPOCK_WORKER_STATUS_STOPPED,	/* Stopped. */
	SPOCK_WORKER_STATUS_FAILED,		/* Failed. */
} SpockWorkerStatus;
/*
 * Apply workers shared memory information per database per origin
 *
 * We want to be able to cleanup on proc exit. However, since MyProc may be
 * NULL during exit, we'd be using group_has_workers atomic variable when
 * decrement attached count, whereas when creating an entry to incrementing,
 * we must protect it with an LWLock to avoid race conditions..
 *
 * This strategy avoids using LWLocks for cleanup.
 */
typedef struct SpockApplyGroupData
{
	Oid dbid;
	RepOriginId replorigin;
	pg_atomic_uint32 nattached;
	TimestampTz prev_remote_ts;
	XLogRecPtr remote_lsn;
	XLogRecPtr remote_insert_lsn;
	ConditionVariable prev_processed_cv;
} SpockApplyGroupData;

typedef SpockApplyGroupData *SpockApplyGroup;

typedef struct SpockApplyWorker
{
	Oid			subid;				/* Subscription id for apply worker. */
	XLogRecPtr	replay_stop_lsn;	/* Replay should stop here if defined. */
	bool		sync_pending;		/* Is there new synchronization info pending?. */
	bool		use_try_block;		/* Should use try block for apply? */
	SpockApplyGroup apply_group;	/* Apply group to be used with parallel slots. */
	
	/* Recovery slot management */
	char		recovery_slot_name[NAMEDATALEN];	/* Recovery slot for this subscription */
	bool		recovery_mode;		/* True if in recovery mode */
	XLogRecPtr	recovery_target_lsn;	/* Target LSN for recovery */
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
	TimestampTz	terminated_at;

	/* Interval for restart delay in ms */
	int restart_delay;

	/* Database id to connect to. */
	Oid		dboid;

	/* WAL Insert location on origin */
	XLogRecPtr	remote_wal_insert_lsn;

	SpockWorkerStatus worker_status;
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

	/* Access lock for Lag Tracking Hash. */
	LWLock	   *lag_lock;

	/* Supervisor process. */
	PGPROC	   *supervisor;

	/* Signal that subscription info have changed. */
	bool		subscriptions_changed;

	/* Spock slot-group data */
	LWLock				   *slot_group_master_lock;
	int						slot_ngroups;
	SpockOutputSlotGroup   *slot_groups;

	/* Spock apply db-origin data */
	LWLock				   *apply_group_master_lock;
	int						napply_groups;
	SpockApplyGroupData	   *apply_groups;

	/* Background workers. */
	int			total_workers;
	SpockWorker  workers[FLEXIBLE_ARRAY_MEMBER];
} SpockContext;


typedef enum spockStatsType
{
	SPOCK_STATS_INSERT_COUNT = 0,
	SPOCK_STATS_UPDATE_COUNT,
	SPOCK_STATS_DELETE_COUNT,
	SPOCK_STATS_CONFLICT_COUNT,
	SPOCK_STATS_DCA_COUNT,

	SPOCK_STATS_NUM_COUNTERS = SPOCK_STATS_DCA_COUNT + 1
} spockStatsType;

typedef struct spockStatsKey
{
	/* hash key */
	Oid			dboid;		/* Database Oid */
	Oid			subid;		/* Subscription (InvalidOid for sender) */
	Oid			relid;		/* Table Oid */
} spockStatsKey;

typedef struct spockStatsEntry
{
	spockStatsKey	key;	/* hash key */

	int64			counter[SPOCK_STATS_NUM_COUNTERS];
	slock_t			mutex;
} spockStatsEntry;

extern HTAB				   *SpockHash;
extern SpockContext		   *SpockCtx;
extern SpockWorker		   *MySpockWorker;
extern SpockApplyWorker	   *MyApplyWorker;
extern SpockSubscription   *MySubscription;
extern int					spock_stats_max_entries_conf;
extern int					spock_stats_max_entries;
extern bool					spock_stats_hash_full;

#define SPOCK_STATS_MAX_ENTRIES(_nworkers) \
	(spock_stats_max_entries_conf < 0 ? (1000 * _nworkers) \
									  : spock_stats_max_entries_conf)

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
extern bool spock_worker_terminating(SpockWorker *w);
extern void spock_worker_kill(SpockWorker *worker);

extern const char * spock_worker_type_name(SpockWorkerType type);
extern void handle_stats_counter(Relation relation, Oid subid,
								spockStatsType typ, int ntup);

#endif /* SPOCK_WORKER_H */
