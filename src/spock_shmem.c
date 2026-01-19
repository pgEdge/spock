/*-------------------------------------------------------------------------
 *
 * spock_shmem.c
 *		Centralized shared memory initialization for Spock
 *
 * This module provides a single entry point for all Spock shared memory
 * initialization. It registers one set of hooks and coordinates the
 * initialization of all subsystems.
 *
 * Design goals:
 * - Register only one shmem_request_hook and shmem_startup_hook
 * - Acquire AddinShmemInitLock only once during startup
 * - Provide clear ownership and control over initialization order
 * - Support crash recovery by allowing subsystems to reset local pointers
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"

#include "spock_shmem.h"
#include "spock_worker.h"
#include "spock_group.h"
#include "spock_output_plugin.h"

/* Previous hook values for chaining */
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

/* Forward declarations of local functions */
static void spock_shmem_request(void);
static void spock_shmem_startup(void);
static void spock_on_shmem_exit(int code, Datum arg);

/*
 * spock_shmem_init
 *
 * Main entry point for Spock shared memory initialization.
 * Called from _PG_init() to register a single set of hooks.
 *
 * This function:
 * 1. Saves previous hook values for proper chaining
 * 2. Registers our unified request and startup hooks
 * 3. Resets local pointers in all subsystems (for crash recovery)
 */
void
spock_shmem_init(void)
{
	/*
	 * Clean global shared variable pointer. Subsystem-specific pointers
	 * are cleaned on 'shmem_startup' in corresponding subsystems.
	 */
	SpockCtx = NULL;

	/* Save previous hooks for chaining */
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = spock_shmem_request;

	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = spock_shmem_startup;
}

/*
 * Accumulate shared memory estimations for structures used by multiple
 * subsystems.
 */
static Size
spock_ctx_shmem_size(int nworkers)
{
	Size	num_bytes = 0;

	num_bytes = offsetof(SpockContext, workers);
	num_bytes = add_size(num_bytes,
						 sizeof(SpockWorker) * nworkers);

	return num_bytes;
}

/*
 * spock_shmem_request
 *
 * Unified shared memory request hook.
 * Chains to any previous hook, then requests memory for all Spock subsystems.
 *
 * NOTE: since max_worker_processes may be changed only on postmaster start, it
 * looks safe to rely on it here.
 */
static void
spock_shmem_request(void)
{
	/* Chain to previous hook first */
	if (prev_shmem_request_hook != NULL)
		prev_shmem_request_hook();

	if (max_worker_processes <= 0)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("spock requires worker processes to be enabled")));

	RequestAddinShmemSpace(spock_ctx_shmem_size(max_worker_processes));

	/* Request shared memory for worker subsystem */
	spock_worker_shmem_request(max_worker_processes);

	/* Request shared memory for output plugin subsystem */
	spock_output_plugin_shmem_request(max_worker_processes);

	/* Request shmem for Apply Group */
	spock_group_shmem_request(max_worker_processes);

	/* For SpockCtx->lock */
	RequestNamedLWLockTranche("spock context lock", 1);
}

/*
 * spock_shmem_startup
 *
 * Unified shared memory startup hook.
 * Chains to any previous hook, then initializes all Spock subsystems
 * while holding AddinShmemInitLock exactly once.
 */
static void
spock_shmem_startup(void)
{
	int		nworkers = max_worker_processes;
	bool	found;

	Assert(nworkers > 0);

	/*
	 * XXX:
	 * Do we have tests on 0, 1, etc workers allowed?
	 */

	/* Chain to previous hook first */
	if (prev_shmem_startup_hook != NULL)
		prev_shmem_startup_hook();

	/* Register shmem exit callback (only in postmaster) */
	if (!IsUnderPostmaster)
		on_shmem_exit(spock_on_shmem_exit, (Datum) 0);

	/*
	 * Acquire AddinShmemInitLock once for all subsystem initialization.
	 * This avoids multiple lock acquisitions and potential race conditions.
	 */
	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	SpockCtx = ShmemInitStruct("spock_context",
							   spock_ctx_shmem_size(nworkers), &found);
	if (!found)
	{
		/* First time - initialize the structure */
		SpockCtx->lock = &((GetNamedLWLockTranche("spock context lock")[0]).lock);
		SpockCtx->supervisor = NULL;
		SpockCtx->subscriptions_changed = false;
		SpockCtx->total_workers = nworkers;
		memset(SpockCtx->workers, 0,
			   sizeof(SpockWorker) * SpockCtx->total_workers);
	}

	/* Initialize worker subsystem shared memory structures */
	spock_worker_shmem_startup(found);

	/* Initialize output plugin subsystem shared memory structures */
	spock_output_plugin_shmem_startup(found);

	/* Initialize spock_group's shared memory. */
	spock_group_shmem_startup(found);

	LWLockRelease(AddinShmemInitLock);
}

/*
 * spock_on_shmem_exit
 *
 * Called on postmaster's shared memory exit.
 * Currently dumps apply group data for persistence.
 */
static void
spock_on_shmem_exit(int code, Datum arg)
{
	/* Only dump data if exiting cleanly */
	if (code != 0)
		return;

	elog(DEBUG1, "spock_on_shmem_exit: dumping apply group data");
	spock_group_resource_dump();
}
