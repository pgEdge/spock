/*-------------------------------------------------------------------------
 *
 * spock_worker.h
 *              spock worker helper functions
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *              spock_worker.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_WORKER_H
#define SPOCK_WORKER_H

#include "storage/lock.h"

#include "spock.h"

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
	/* Write lock. */
	LWLock	   *lock;

	/* Supervisor process. */
	PGPROC	   *supervisor;

	/* Signal that subscription info have changed. */
	bool		subscriptions_changed;

	/* Background workers. */
	int			total_workers;
	SpockWorker  workers[FLEXIBLE_ARRAY_MEMBER];
} SpockContext;

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

#endif /* SPOCK_WORKER_H */
