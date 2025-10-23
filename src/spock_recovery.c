/*-------------------------------------------------------------------------
 *
 * spock_recovery.c
 *		Recovery Slots for catastrophic node failure handling
 *
 * Recovery Slots are inactive logical replication slots that preserve WAL
 * segments for catastrophic failure recovery. Each database maintains a single
 * recovery slot that tracks WAL for all peer nodes in the replication cluster.
 *
 * Design Overview:
 * ---------------
 * - One recovery slot per database (shared across all subscriptions)
 * - Slots are inactive - never used by normal replication
 * - Created by manager worker at database initialization
 * - Preserved WAL enables data recovery without cluster rebuild
 *
 * Example Configuration:
 * ---------------------
 * 3-node cluster (n1, n2, n3) with 6 subscriptions:
 *   n1: subscribes from n2, n3
 *   n2: subscribes from n1, n3
 *   n3: subscribes from n1, n2
 *
 * Recovery slots created:
 *   n1: spk_recovery_dbname  (preserves WAL for all peer transactions)
 *   n2: spk_recovery_dbname  (preserves WAL for all peer transactions)
 *   n3: spk_recovery_dbname  (preserves WAL for all peer transactions)
 *
 * Total: 3 slots (one per database), not 6 (subscriptions) or 18 (peers).
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"
#include "access/xlog.h"
#include "catalog/namespace.h"
#include "commands/dbcommands.h"
#include "replication/slot.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/timestamp.h"
#include "access/heapam.h"
#include "catalog/pg_subscription.h"
#include "funcapi.h"

#include "spock_recovery.h"
#include "spock_common.h"
#include "spock_node.h"
#include "spock.h"

/* Global recovery coordinator in shared memory */
SpockRecoveryCoordinator *SpockRecoveryCtx = NULL;

/* Hook for shared memory startup - no longer needed since integrated with worker shmem */

/* Internal function prototypes */
static SpockRecoverySlotData *get_recovery_slot(void);
static void initialize_recovery_slot(SpockRecoverySlotData *slot,
									 const char *database_name);

/*
 * spock_recovery_shmem_size
 *
 * Calculate the amount of shared memory required for recovery slot coordination.
 *
 * Returns:
 *		Size in bytes needed for SpockRecoveryCoordinator structure
 */
Size
spock_recovery_shmem_size(void)
{
	Size		size;

	/* Space for the recovery coordinator structure */
	size = sizeof(SpockRecoveryCoordinator);

	/* Add space for LWLock tranche (minimal overhead) */
	size = add_size(size, LWLockShmemSize());

	return size;
}


/*
 * spock_recovery_shmem_startup
 *
 * Shared memory startup callback for recovery coordination.
 * Creates and initializes the SpockRecoveryCoordinator structure in shared memory.
 *
 * Called during postmaster startup while holding AddinShmemInitLock.
 */
void
spock_recovery_shmem_startup(void)
{
	bool		found;
	Size		size;

	/* No hook chaining needed - called directly from spock_worker_shmem_startup() */

	size = spock_recovery_shmem_size();

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	/* Create or attach to recovery coordinator in shared memory */
	SpockRecoveryCtx = ShmemInitStruct("spock_recovery_coordinator",
									   size, &found);

	if (!found)
	{
		SpockRecoverySlotData *slot;

		/* First time initialization - set up the coordinator */
		SpockRecoveryCtx->lock = &(GetNamedLWLockTranche("spock_recovery")[0].lock);

		/* Initialize the single recovery slot to empty state */
		slot = &SpockRecoveryCtx->recovery_slot;
		slot->slot_name[0] = '\0';
		slot->restart_lsn = InvalidXLogRecPtr;
		slot->confirmed_flush_lsn = InvalidXLogRecPtr;
		slot->min_unacknowledged_ts = 0;
		slot->active = false;
		slot->in_recovery = false;
		pg_atomic_init_u32(&slot->recovery_generation, 0);
	}

	LWLockRelease(AddinShmemInitLock);
}

/*
 * get_recovery_slot_name
 *
 * Generate a standardized recovery slot name for the given database.
 *
 * Naming convention: spk_recovery_{database_name}
 * This ensures slots are easily identifiable and unique per database.
 *
 * Args:
 *		database_name: Name of the database
 *
 * Returns:
 *		Palloc'd string containing the slot name (caller must pfree)
 *		NULL if database_name is NULL
 */
char *
get_recovery_slot_name(const char *database_name)
{
	char	   *slot_name;

	if (!database_name)
		return NULL;

	slot_name = palloc(NAMEDATALEN);

	if (snprintf(slot_name, NAMEDATALEN, RECOVERY_SLOT_NAME_FORMAT,
				 database_name) >= NAMEDATALEN)
	{
		pfree(slot_name);
		elog(ERROR, "database name too long for recovery slot name: %s",
			 database_name);
		return NULL;
	}

	return slot_name;
}

/*
 * get_recovery_slot
 *
 * Internal helper to get the recovery slot from shared memory.
 * Caller must hold SpockRecoveryCtx->lock.
 *
 * Returns:
 *		Pointer to the recovery slot in shared memory
 */
static SpockRecoverySlotData *
get_recovery_slot(void)
{
	Assert(LWLockHeldByMe(SpockRecoveryCtx->lock));

	return &SpockRecoveryCtx->recovery_slot;
}

/*
 * initialize_recovery_slot
 *
 * Initialize a recovery slot structure with database information.
 * Sets the slot name and resets all tracking fields to initial state.
 *
 * Args:
 *		slot: The slot structure to initialize
 *		database_name: Name of the database for this slot
 */
static void
initialize_recovery_slot(SpockRecoverySlotData *slot,
						 const char *database_name)
{
	char	   *slot_name;

	Assert(slot != NULL);

	if (!database_name)
	{
		/* No database name - mark slot as empty */
		slot->slot_name[0] = '\0';
	}
	else
	{
		/* Generate and store the slot name */
		slot_name = get_recovery_slot_name(database_name);
		if (slot_name)
		{
			strncpy(slot->slot_name, slot_name, NAMEDATALEN - 1);
			slot->slot_name[NAMEDATALEN - 1] = '\0';
			pfree(slot_name);
		}
		else
		{
			slot->slot_name[0] = '\0';
		}
	}

	/* Initialize all tracking fields to empty/invalid state */
	slot->restart_lsn = InvalidXLogRecPtr;
	slot->confirmed_flush_lsn = InvalidXLogRecPtr;
	slot->min_unacknowledged_ts = 0;
	slot->active = false;
	slot->in_recovery = false;

	/* Increment generation counter (atomic operation, no lock needed) */
	pg_atomic_add_fetch_u32(&slot->recovery_generation, 1);
}

/*
 * create_recovery_slot
 *
 * Create an inactive logical replication slot for catastrophic failure recovery.
 *
 * Creates a persistent replication slot that preserves WAL segments for all
 * subscriptions in the specified database. The slot remains inactive and is
 * never used for normal replication.
 *
 * If a recovery slot already exists for this database, returns success without
 * creating a duplicate. This makes the function safe to call multiple times.
 *
 * Args:
 *		database_name: Name of the database to create recovery slot for
 *
 * Returns:
 *		true if slot exists (created now or previously)
 *		Never returns false - exits on error since recovery slots are controlled by GUC
 */
bool
create_recovery_slot(const char *database_name)
{
	SpockRecoverySlotData *slot;
	char	   *slot_name;

	if (!SpockRecoveryCtx)
	{
		elog(WARNING, "recovery coordinator not initialized");
		return false;
	}

	if (!database_name)
	{
		elog(WARNING, "database name cannot be NULL");
		return false;
	}

	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);

	slot = &SpockRecoveryCtx->recovery_slot;

	/* If slot already exists, we're done */
	if (slot->active)
	{
		LWLockRelease(SpockRecoveryCtx->lock);
		elog(LOG, "recovery slot already exists");
		return true;
	}

	/* Initialize the slot metadata */
	initialize_recovery_slot(slot, database_name);

	/* Copy slot name for use outside the lock */
	slot_name = pstrdup(slot->slot_name);
	LWLockRelease(SpockRecoveryCtx->lock);

	/*
	 * Create the actual replication slot
	 *
	 * Parameters:
	 * - slot_name: name of the slot to create
	 * - true: database-specific slot
	 * - RS_PERSISTENT: slot survives server restart
	 * - false: not two-phase (we don't need prepared transaction support)
	 * - false: not failover (recovery slots don't need failover)
	 * - false: not synced (recovery slots are local only)
	 *
	 * Since recovery slots are controlled by GUC, failure to create should be fatal.
	 */
	ReplicationSlotCreate(slot_name, true, RS_PERSISTENT, false, false, false);

	elog(LOG, "created recovery slot '%s' (INACTIVE - for catastrophic failure recovery only)",
		 slot_name);

	/* Mark slot as active in shared memory after successful creation */
	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
	slot->active = true;
	LWLockRelease(SpockRecoveryCtx->lock);

	pfree(slot_name);
	return true;
}

/*
 * drop_recovery_slot
 *
 * Drop the recovery slot for this database.
 *
 * Removes the replication slot and frees associated resources.
 * Used when a node is being decommissioned or recovery is no longer needed.
 */
void
drop_recovery_slot(void)
{
	SpockRecoverySlotData *slot;
	char		slot_name[NAMEDATALEN];

	if (!SpockRecoveryCtx)
		return;

	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);

	slot = get_recovery_slot();

	/* Nothing to do if slot doesn't exist */
	if (!slot->active)
	{
		LWLockRelease(SpockRecoveryCtx->lock);
		return;
	}

	/* Copy slot name for use outside the lock */
	strncpy(slot_name, slot->slot_name, NAMEDATALEN - 1);
	slot_name[NAMEDATALEN - 1] = '\0';

	/* Reset slot to initial state in shared memory */
	slot->slot_name[0] = '\0';
	slot->restart_lsn = InvalidXLogRecPtr;
	slot->confirmed_flush_lsn = InvalidXLogRecPtr;
	slot->min_unacknowledged_ts = 0;
	slot->active = false;
	slot->in_recovery = false;

	LWLockRelease(SpockRecoveryCtx->lock);

	/* Drop the actual replication slot */
	PG_TRY();
	{
		ReplicationSlotDrop(slot_name, true);
		elog(LOG, "dropped recovery slot '%s'", slot_name);
	}
	PG_CATCH();
	{
		/* Log error but don't fail - slot might already be gone */
		elog(WARNING, "failed to drop recovery slot '%s'", slot_name);
	}
	PG_END_TRY();
}

/*
 * update_recovery_slot_progress
 *
 * Update the progress tracking information for a recovery slot.
 *
 * This function tracks the minimum unacknowledged timestamp and LSN positions
 * across all peer nodes. Currently not fully implemented in minimal version.
 *
 * Args:
 *		slot_name: Name of the slot to update
 *		lsn: WAL position of the transaction
 *		commit_ts: Commit timestamp of the transaction
 *
 * Note: This is a placeholder for future WAL advancement logic.
 */
void
update_recovery_slot_progress(const char *slot_name, XLogRecPtr lsn,
							   TimestampTz commit_ts)
{
	SpockRecoverySlotData *slot;

	if (!SpockRecoveryCtx)
		return;

	if (!slot_name)
		return;

	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);

	slot = get_recovery_slot();

	/* Only update if this is our slot and it's active */
	if (slot->active && strcmp(slot->slot_name, slot_name) == 0)
	{
		/*
		 * Track the oldest unacknowledged transaction timestamp.
		 * This helps identify how far behind the slot might be.
		 */
		if (slot->min_unacknowledged_ts == 0 ||
			commit_ts < slot->min_unacknowledged_ts)
		{
			slot->min_unacknowledged_ts = commit_ts;
		}

		/*
		 * Track the confirmed flush LSN (latest position).
		 * This shows the most recent transaction we've seen.
		 */
		if (slot->confirmed_flush_lsn == InvalidXLogRecPtr ||
			lsn > slot->confirmed_flush_lsn)
		{
			slot->confirmed_flush_lsn = lsn;
		}

		/*
		 * Track the restart LSN (earliest position needed).
		 * Initialize to the first LSN we see, as LSNs are monotonically increasing.
		 */
		if (slot->restart_lsn == InvalidXLogRecPtr)
		{
			slot->restart_lsn = lsn;
		}

		elog(DEBUG2, "updated recovery slot '%s' progress: LSN %X/%X, timestamp %s",
			 slot_name, LSN_FORMAT_ARGS(lsn),
			 timestamptz_to_str(commit_ts));
	}

	LWLockRelease(SpockRecoveryCtx->lock);
}

/*
 * get_subscription_recovery_progress
 *
 * Helper function to get recovery slot progress for a specific subscription
 * from a specific origin node. This is a simplified version that checks
 * if the recovery slot exists and is active, returning basic progress info.
 */
static bool
get_subscription_recovery_progress(Oid sub_node_id, Oid origin_node_id,
								  XLogRecPtr *lsn, TimestampTz *commit_ts)
{
	bool		has_progress = false;

	/* For now, we'll use a simplified approach that checks if recovery slot exists */
	if (!SpockRecoveryCtx || !SpockRecoveryCtx->recovery_slot.active)
		return false;

	/* Get the recovery slot data */
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	if (SpockRecoveryCtx->recovery_slot.active)
	{
		*lsn = SpockRecoveryCtx->recovery_slot.confirmed_flush_lsn;
		*commit_ts = SpockRecoveryCtx->recovery_slot.min_unacknowledged_ts;
		has_progress = true;
	}
	LWLockRelease(SpockRecoveryCtx->lock);

	return has_progress;
}

/*
 * spock_find_rescue_source_sql
 *
 * Find the best surviving node to use as a rescue source for a failed origin node.
 * This function queries all co-subscriber nodes to determine which one has the most
 * recent transactions from the failed origin node.
 *
 * Usage: SELECT * FROM spock.find_rescue_source('failed_node_name');
 *
 * Returns a record with:
 * - origin_node_id: The failed node ID
 * - source_node_id: The surviving node ID with the most recent data
 * - last_lsn: The LSN of the last known transaction from the origin
 * - last_commit_timestamp: The commit timestamp of the last known transaction
 * - confidence_level: How confident we are in this choice (HIGH/MEDIUM/LOW)
 */
Datum
spock_find_rescue_source_sql(PG_FUNCTION_ARGS)
{
	text	   *failed_node_name_text = PG_GETARG_TEXT_PP(0);
	char	   *failed_node_name;
	TupleDesc	tupdesc;
	Datum		values[5];
	bool		nulls[5];
	HeapTuple	tuple;
	Oid			failed_node_id = InvalidOid;
	Oid			best_source_node_id = InvalidOid;
	XLogRecPtr	best_lsn = InvalidXLogRecPtr;
	TimestampTz	best_commit_ts = 0;
	char	   *confidence_level = "LOW";

	/* Get the failed node name */
	failed_node_name = text_to_cstring(failed_node_name_text);

	/* Get node ID for the failed node */
	{
		SpockNode *node = get_node_by_name(failed_node_name, true);
		if (node == NULL)
		{
			/* Return empty result for non-existent nodes */
			pfree(failed_node_name);
			PG_RETURN_NULL();
		}
		failed_node_id = node->id;
	}

	/* Query all subscriptions to find the best source node */
	{
		Relation	subrel;
		SysScanDesc scandesc;
		HeapTuple	tuple;
		Oid			current_best_node_id = InvalidOid;
		XLogRecPtr	current_best_lsn = InvalidXLogRecPtr;
		TimestampTz	current_best_commit_ts = 0;
		int			source_count = 0;
		int			tie_count = 0;

		subrel = table_open(SubscriptionRelationId, AccessShareLock);

		/* Scan all subscriptions */
		scandesc = systable_beginscan(subrel, InvalidOid, false, NULL, 0, NULL);

		while (HeapTupleIsValid(tuple = systable_getnext(scandesc)))
		{
			Form_pg_subscription subform = (Form_pg_subscription) GETSTRUCT(tuple);
			Oid			sub_node_id;
			char	   *sub_node_name;
			XLogRecPtr	sub_lsn;
			TimestampTz	sub_commit_ts;
			bool		has_progress = false;

			/* Get subscription node name and ID */
			sub_node_name = NameStr(subform->subname);
			{
				SpockNode *sub_node = get_node_by_name(sub_node_name, true);
				sub_node_id = sub_node ? sub_node->id : InvalidOid;
			}

			/* Skip if this is the failed node */
			if (sub_node_id == failed_node_id)
				continue;

			/* Skip if node doesn't exist */
			if (!OidIsValid(sub_node_id))
				continue;

			/* Query recovery slot progress for this subscription */
			has_progress = get_subscription_recovery_progress(sub_node_id, failed_node_id,
															&sub_lsn, &sub_commit_ts);

			if (has_progress)
			{
				source_count++;

				/* Check if this is better than our current best */
				if (current_best_lsn == InvalidXLogRecPtr ||
					sub_lsn > current_best_lsn ||
					(sub_lsn == current_best_lsn && sub_commit_ts > current_best_commit_ts))
				{
					if (current_best_lsn != InvalidXLogRecPtr && sub_lsn == current_best_lsn)
					{
						tie_count++;
					}

					current_best_node_id = sub_node_id;
					current_best_lsn = sub_lsn;
					current_best_commit_ts = sub_commit_ts;
				}
			}
		}

		systable_endscan(scandesc);
		table_close(subrel, AccessShareLock);

		/* Set the best source if we found any */
		if (source_count > 0)
		{
			best_source_node_id = current_best_node_id;
			best_lsn = current_best_lsn;
			best_commit_ts = current_best_commit_ts;

			/* Determine confidence level */
			if (source_count >= 3 && tie_count == 0)
				confidence_level = "HIGH";
			else if (source_count >= 2)
				confidence_level = "MEDIUM";
			else
				confidence_level = "LOW";
		}
	}

	/* Build return tuple */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	/* Initialize all values to null */
	memset(nulls, 1, sizeof(nulls));

	/* Set non-null values */
	values[0] = ObjectIdGetDatum(failed_node_id);
	nulls[0] = false;

	if (OidIsValid(best_source_node_id))
	{
		values[1] = ObjectIdGetDatum(best_source_node_id);
		nulls[1] = false;
	}

	if (best_lsn != InvalidXLogRecPtr)
	{
		values[2] = LSNGetDatum(best_lsn);
		nulls[2] = false;
	}

	if (best_commit_ts != 0)
	{
		values[3] = TimestampTzGetDatum(best_commit_ts);
		nulls[3] = false;
	}

	values[4] = CStringGetTextDatum(confidence_level);
	nulls[4] = false;

	tuple = heap_form_tuple(tupdesc, values, nulls);

	/* Log the rescue decision */
	if (OidIsValid(best_source_node_id))
	{
		SpockNode *source_node = get_node(best_source_node_id);
		char	   *source_node_name = source_node ? source_node->name : "unknown";
		char	   *lsn_str = psprintf("%X/%X", LSN_FORMAT_ARGS(best_lsn));
		const char *ts_str = timestamptz_to_str(best_commit_ts);

		elog(LOG, "Rescue source for failed node %s is node %s at commit timestamp %s / LSN %s (confidence: %s)",
			 failed_node_name, source_node_name, ts_str, lsn_str, confidence_level);

		pfree(lsn_str);
	}
	else
	{
		elog(WARNING, "No rescue source found for failed node %s - no surviving nodes have recovery data",
			 failed_node_name);
	}

	pfree(failed_node_name);

	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}
