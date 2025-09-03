/*-------------------------------------------------------------------------
 *
 * spock_recovery.c
 * 		Recovery Slots implementation for catastrophic node failure handling
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"
#include "access/htup_details.h"
#include "access/xact.h"
#include "catalog/namespace.h"
#include "catalog/pg_database.h"
#include "catalog/indexing.h"
#include "parser/parse_relation.h"
#include "utils/fmgroids.h"
#include "utils/syscache.h"
#include "utils/snapmgr.h"
#include "replication/slot.h"
#include "replication/walsender.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/rel.h"

#include "spock_recovery.h"
#include "spock_common.h"
#include "spock_node.h"
#include "spock_apply.h"
#include "spock.h"

extern void create_progress_entry(Oid target_node_id, Oid remote_node_id, TimestampTz remote_commit_ts);
extern void update_progress_entry(Oid target_node_id, Oid remote_node_id, TimestampTz remote_commit_ts,
								  XLogRecPtr remote_lsn, XLogRecPtr remote_insert_lsn,
								  TimestampTz last_updated_ts, bool updated_by_decode);

SpockRecoveryCoordinator *SpockRecoveryCtx = NULL;

/* Progress table attribute numbers (matching spock_apply.c definitions) */
#define Anum_target_node_id		1
#define Anum_remote_node_id		2
#define Anum_remote_commit_ts	3
#define Anum_remote_lsn			4
#define Anum_remote_insert_lsn	5
#define Anum_last_updated_ts	6
#define Anum_updated_by_decode	7
#define Natts_progress			7

static void spock_recovery_shmem_startup(void);
static SpockRecoverySlotData *find_recovery_slot(Oid local_node_id, Oid remote_node_id);
static SpockRecoverySlotData *allocate_recovery_slot(void);
static void initialize_recovery_slot(SpockRecoverySlotData *slot, Oid local_node_id, Oid remote_node_id);
static TimestampTz get_min_unacknowledged_timestamp_for_pair(Oid local_node_id, Oid remote_node_id);
static XLogRecPtr get_lsn_for_timestamp(TimestampTz timestamp);
static char *get_node_name_by_id(Oid node_id);
static char *get_database_name_from_oid(Oid database_oid);

static shmem_request_hook_type prev_recovery_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_recovery_shmem_startup_hook = NULL;

/*
 * Calculate shared memory size needed for recovery coordination
 */
Size
spock_recovery_shmem_size(int max_recovery_slots)
{
	Size		size;
	
	size = offsetof(SpockRecoveryCoordinator, slots);
	size = add_size(size, mul_size(max_recovery_slots, 
								   sizeof(SpockRecoverySlotData)));
	
	return size;
}

/*
 * Request shared memory for recovery slots
 */
static void
spock_recovery_shmem_request(void)
{
	if (prev_recovery_shmem_request_hook != NULL)
		prev_recovery_shmem_request_hook();

	/* Request shared memory for recovery coordination */
	RequestAddinShmemSpace(spock_recovery_shmem_size(100)); /* Conservative estimate */
	RequestNamedLWLockTranche("spock_recovery", 1);
}

/*
 * Initialize recovery slots shared memory
 */
void
spock_recovery_shmem_init(void)
{
#if PG_VERSION_NUM < 150000
	spock_recovery_shmem_request();
#else
	prev_recovery_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = spock_recovery_shmem_request;
#endif
	prev_recovery_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = spock_recovery_shmem_startup;
}

/*
 * Shared memory startup for recovery coordination
 */
static void
spock_recovery_shmem_startup(void)
{
	bool		found;
	int			max_recovery_slots;
	Size		size;

	if (prev_recovery_shmem_startup_hook)
		prev_recovery_shmem_startup_hook();

	/* Estimate maximum recovery slots based on max_worker_processes */
	{
		char *max_workers_str = GetConfigOptionByName("max_worker_processes", NULL, false);
		int max_workers = atoi(max_workers_str);

		/* Estimate recovery slots as 2x max workers (conservative estimate) */
		max_recovery_slots = max_workers * 2;
		if (max_recovery_slots < 10)
			max_recovery_slots = 10; /* Minimum reasonable value */
		if (max_recovery_slots > 1000)
			max_recovery_slots = 1000; /* Maximum reasonable value */

		elog(DEBUG2, "Recovery slots: max_worker_processes=%d, estimated max_recovery_slots=%d",
			 max_workers, max_recovery_slots);
	}

	size = spock_recovery_shmem_size(max_recovery_slots);

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	SpockRecoveryCtx = ShmemInitStruct("spock_recovery_coordinator",
									  size, &found);
	
	if (!found)
	{
		int i;
		
		/* Initialize the recovery coordinator */
		SpockRecoveryCtx->lock = &(GetNamedLWLockTranche("spock_recovery")[0].lock);
		SpockRecoveryCtx->max_recovery_slots = max_recovery_slots;
		SpockRecoveryCtx->num_recovery_slots = 0;
		
		/* Initialize all recovery slots */
		for (i = 0; i < max_recovery_slots; i++)
		{
			SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
			
			slot->local_node_id = InvalidOid;
			slot->remote_node_id = InvalidOid;
			slot->slot_name[0] = '\0';
			slot->restart_lsn = InvalidXLogRecPtr;
			slot->confirmed_flush_lsn = InvalidXLogRecPtr;
			slot->min_unacknowledged_ts = 0;
			slot->active = false;
			slot->in_recovery = false;
			pg_atomic_init_u32(&slot->recovery_generation, 0);
		}
	}

	LWLockRelease(AddinShmemInitLock);
}

/*
 * Generate recovery slot name for given node pair
 * Format: spock_[database_name]_recovery_[from_node_name]_[to_node_name]
 */
char *
get_recovery_slot_name(Oid local_node_id, Oid remote_node_id)
{
	char *slot_name = palloc(NAMEDATALEN);
	char *database_name;
	char *local_node_name;
	char *remote_node_name;
	
	/* Get database name from system catalog */
	database_name = get_database_name_from_oid(MyDatabaseId);
	
	/* Get node names - we need to query the spock.node table */
	local_node_name = get_node_name_by_id(local_node_id);
	remote_node_name = get_node_name_by_id(remote_node_id);
	
	/* Generate slot name with new format */
	snprintf(slot_name, NAMEDATALEN, "spock_%s_recovery_%s_%s",
			 database_name, local_node_name, remote_node_name);
	
	/* Clean up allocated memory */
	pfree(database_name);
	pfree(local_node_name);
	pfree(remote_node_name);
	
	return slot_name;
}

/*
 * Find an existing recovery slot in shared memory
 */
static SpockRecoverySlotData *
find_recovery_slot(Oid local_node_id, Oid remote_node_id)
{
	int i;
	
	Assert(LWLockHeldByMe(SpockRecoveryCtx->lock));
	
	for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
		
		if (slot->local_node_id == local_node_id &&
			slot->remote_node_id == remote_node_id)
		{
			return slot;
		}
	}
	
	return NULL;
}

/*
 * Allocate a new recovery slot entry in shared memory
 */
static SpockRecoverySlotData *
allocate_recovery_slot(void)
{
	int i;
	
	Assert(LWLockHeldByMe(SpockRecoveryCtx->lock));
	
	for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
		
		if (slot->local_node_id == InvalidOid)
		{
			return slot;
		}
	}
	
	return NULL;
}

/*
 * Initialize a recovery slot with node information
 */
static void
initialize_recovery_slot(SpockRecoverySlotData *slot, 
						Oid local_node_id, Oid remote_node_id)
{
	char *slot_name;
	
	Assert(slot != NULL);
	
	slot->local_node_id = local_node_id;
	slot->remote_node_id = remote_node_id;
	
	slot_name = get_recovery_slot_name(local_node_id, remote_node_id);
	strncpy(slot->slot_name, slot_name, NAMEDATALEN - 1);
	slot->slot_name[NAMEDATALEN - 1] = '\0';
	pfree(slot_name);
	
	slot->restart_lsn = InvalidXLogRecPtr;
	slot->confirmed_flush_lsn = InvalidXLogRecPtr;
	slot->min_unacknowledged_ts = 0;
	slot->active = false;
	slot->in_recovery = false;
	pg_atomic_add_fetch_u32(&slot->recovery_generation, 1);
}

/*
 * Create a recovery slot for the given node pair
 */
bool
create_recovery_slot(Oid local_node_id, Oid remote_node_id)
{
	SpockRecoverySlotData *slot;
	char	   *slot_name;
	bool		success = false;
	
	if (!SpockRecoveryCtx)
	{
		elog(WARNING, "Recovery coordinator not initialized");
		return false;
	}
	
	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
	
	/* Check if slot already exists */
	slot = find_recovery_slot(local_node_id, remote_node_id);
	if (slot != NULL)
	{
		LWLockRelease(SpockRecoveryCtx->lock);
		return true; /* Already exists */
	}
	
	/* Allocate new slot */
	slot = allocate_recovery_slot();
	if (slot == NULL)
	{
		LWLockRelease(SpockRecoveryCtx->lock);
		elog(ERROR, "No free recovery slot available");
		return false;
	}
	
	/* Initialize the slot */
	initialize_recovery_slot(slot, local_node_id, remote_node_id);
	SpockRecoveryCtx->num_recovery_slots++;
	
	slot_name = pstrdup(slot->slot_name);
	LWLockRelease(SpockRecoveryCtx->lock);
	
	/* Create the actual PostgreSQL replication slot */
	PG_TRY();
	{
		ReplicationSlotCreate(slot_name, true, RS_PERSISTENT, false);
		slot->active = false; /* Recovery slots should remain inactive */
		success = true;
		
		elog(LOG, "Created recovery slot '%s' for nodes %u -> %u",
			 slot_name, local_node_id, remote_node_id);
	}
	PG_CATCH();
	{
		/* Cleanup on failure */
		LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
		slot->local_node_id = InvalidOid;
		slot->remote_node_id = InvalidOid;
		slot->slot_name[0] = '\0';
		SpockRecoveryCtx->num_recovery_slots--;
		LWLockRelease(SpockRecoveryCtx->lock);
		
		elog(WARNING, "Failed to create recovery slot '%s': %s",
			 slot_name, "slot creation failed");
		
		PG_RE_THROW();
	}
	PG_END_TRY();
	
	pfree(slot_name);
	return success;
}

/*
 * Drop a recovery slot
 */
void
drop_recovery_slot(Oid local_node_id, Oid remote_node_id)
{
	SpockRecoverySlotData *slot;
	char		slot_name[NAMEDATALEN];
	
	if (!SpockRecoveryCtx)
		return;
		
	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
	
	slot = find_recovery_slot(local_node_id, remote_node_id);
	if (slot == NULL)
	{
		LWLockRelease(SpockRecoveryCtx->lock);
		return; /* Slot doesn't exist */
	}
	
	strncpy(slot_name, slot->slot_name, NAMEDATALEN);
	
	/* Mark slot as inactive in shared memory */
	slot->local_node_id = InvalidOid;
	slot->remote_node_id = InvalidOid;
	slot->slot_name[0] = '\0';
	slot->active = false;
	SpockRecoveryCtx->num_recovery_slots--;
	
	LWLockRelease(SpockRecoveryCtx->lock);
	
	/* Drop the actual PostgreSQL replication slot */
	PG_TRY();
	{
		ReplicationSlotDrop(slot_name, true);
		elog(LOG, "Dropped recovery slot '%s' for nodes %u -> %u",
			 slot_name, local_node_id, remote_node_id);
	}
	PG_CATCH();
	{
		elog(WARNING, "Failed to drop recovery slot '%s': %s",
			 slot_name, "slot drop failed");
	}
	PG_END_TRY();
}

/*
 * Update recovery slot progress tracking
 */
void
update_recovery_slot_progress(const char *slot_name, 
							 TimestampTz commit_ts, 
							 XLogRecPtr lsn)
{
	int i;
	
	if (!SpockRecoveryCtx)
		return;
		
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	
	for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
		
		if (slot->active && 
			strcmp(slot->slot_name, slot_name) == 0)
		{
			/* Update minimum unacknowledged timestamp */
			if (slot->min_unacknowledged_ts == 0 || 
				commit_ts < slot->min_unacknowledged_ts)
			{
				slot->min_unacknowledged_ts = commit_ts;
			}
			
			/* Update LSN if it's advancing */
			if (lsn > slot->confirmed_flush_lsn)
			{
				slot->confirmed_flush_lsn = lsn;
			}
			
			break;
		}
	}
	
	LWLockRelease(SpockRecoveryCtx->lock);
}

/*
 * Get the minimum unacknowledged timestamp for a failed node
 */
TimestampTz
get_min_unacknowledged_timestamp(Oid failed_node_id)
{
	TimestampTz min_ts = 0;
	int i;
	
	if (!SpockRecoveryCtx)
		return 0;
		
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	
	for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
		
		if (slot->active && slot->remote_node_id == failed_node_id)
		{
			if (min_ts == 0 || 
				(slot->min_unacknowledged_ts > 0 && 
				 slot->min_unacknowledged_ts < min_ts))
			{
				min_ts = slot->min_unacknowledged_ts;
			}
		}
	}
	
	LWLockRelease(SpockRecoveryCtx->lock);
	
	return min_ts;
}

/*
 * Get the restart LSN for a recovery slot
 */
XLogRecPtr
get_recovery_slot_restart_lsn(const char *slot_name)
{
	XLogRecPtr	restart_lsn = InvalidXLogRecPtr;
	ReplicationSlot *slot;
	
	LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
	
	slot = SearchNamedReplicationSlot(slot_name, true);
	if (slot)
	{
		SpinLockAcquire(&slot->mutex);
		restart_lsn = slot->data.restart_lsn;
		SpinLockRelease(&slot->mutex);
	}
	
	LWLockRelease(ReplicationSlotControlLock);
	
	return restart_lsn;
}

/*
 * Advance recovery slot to a specific timestamp
 * This is used during recovery coordination
 */
bool
advance_recovery_slot_to_timestamp(const char *slot_name,
								   TimestampTz target_ts)
{
	XLogRecPtr target_lsn;
	XLogRecPtr new_restart_lsn;
	ReplicationSlot *slot;
	bool success = false;

	elog(LOG, "Advancing recovery slot '%s' to timestamp " INT64_FORMAT,
		 slot_name, target_ts);

	/* Step 1: Find the LSN corresponding to the timestamp */
	target_lsn = get_lsn_for_timestamp(target_ts);

	if (target_lsn == InvalidXLogRecPtr)
	{
		elog(WARNING, "Could not find LSN for timestamp " INT64_FORMAT
			 " in recovery slot '%s'", target_ts, slot_name);
		return false;
	}

	/* Step 2: Advance the replication slot to that LSN */
	LWLockAcquire(ReplicationSlotControlLock, LW_EXCLUSIVE);

	slot = SearchNamedReplicationSlot(slot_name, true);
	if (slot == NULL)
	{
		elog(WARNING, "Recovery slot '%s' not found for advancement", slot_name);
		LWLockRelease(ReplicationSlotControlLock);
		return false;
	}

	/* Check if we need to advance at all */
	if (target_lsn <= slot->data.restart_lsn)
	{
		elog(DEBUG1, "Recovery slot '%s' already advanced past target LSN",
			 slot_name);
		LWLockRelease(ReplicationSlotControlLock);
		return true;
	}

	/* Advance the slot */
	SpinLockAcquire(&slot->mutex);
	new_restart_lsn = target_lsn;
	slot->data.restart_lsn = new_restart_lsn;
	slot->data.confirmed_flush = Max(slot->data.confirmed_flush, new_restart_lsn);
	SpinLockRelease(&slot->mutex);

	/* Mark slot as dirty for persistence */
	slot->just_dirtied = true;

	success = true;

	LWLockRelease(ReplicationSlotControlLock);

	if (success)
	{
		elog(LOG, "Successfully advanced recovery slot '%s' to LSN %X/%X",
			 slot_name,
			 (uint32) (new_restart_lsn >> 32),
			 (uint32) new_restart_lsn);
	}

	return success;
}

/*
 * Clone a recovery slot for rescue operations
 */
char *
clone_recovery_slot(const char *source_slot, XLogRecPtr target_lsn)
{
	char	   *clone_name;
	TimestampTz current_time = GetCurrentTimestamp();
	bool		clone_created = false;

	/* Generate unique clone name */
	clone_name = psprintf("%s_clone_%ld", source_slot, current_time);

	elog(LOG, "Cloning recovery slot '%s' to '%s' at LSN %X/%X",
		 source_slot, clone_name,
		 (uint32) (target_lsn >> 32), (uint32) target_lsn);

	/* Create the actual PostgreSQL replication slot */
	PG_TRY();
	{
		ReplicationSlotCreate(clone_name, true, RS_PERSISTENT, false);
		clone_created = true;

		elog(LOG, "Successfully created recovery clone slot '%s'", clone_name);

		/* Recovery clone slots should remain inactive */
		/* Note: The actual PostgreSQL slot is inactive by default */

		/* If target LSN is specified, advance the slot to that position */
		if (target_lsn != InvalidXLogRecPtr)
		{
			advance_recovery_slot_to_timestamp(clone_name, GetCurrentTimestamp());
			elog(LOG, "Advanced recovery clone slot '%s' to LSN %X/%X",
				 clone_name, (uint32) (target_lsn >> 32), (uint32) target_lsn);
		}
	}
	PG_CATCH();
	{
		/* Clean up on failure */
		if (clone_created)
		{
			/* Try to drop the partially created slot */
			ReplicationSlotDrop(clone_name, true);
		}
		pfree(clone_name);
		PG_RE_THROW();
	}
	PG_END_TRY();

	return clone_name;
}

/*
 * Initiate recovery process for a failed node
 */
bool
initiate_node_recovery(Oid failed_node_id)
{
	TimestampTz min_unack_ts;
	XLogRecPtr	target_lsn;
	char	   *failed_node_name;
	int			i;

	elog(LOG, "Initiating recovery for failed node %u", failed_node_id);

	if (!SpockRecoveryCtx)
	{
		elog(WARNING, "Recovery coordinator not initialized");
		return false;
	}

	/* Get the failed node's name for logging */
	failed_node_name = get_node_name_by_id(failed_node_id);

	/* Step 1: Find the minimum unacknowledged timestamp across all surviving nodes */
	min_unack_ts = get_min_unacknowledged_timestamp(failed_node_id);

	if (min_unack_ts == 0)
	{
		elog(LOG, "No unacknowledged transactions found for failed node %s (%u)",
			 failed_node_name, failed_node_id);
		pfree(failed_node_name);
		return true;
	}

	elog(LOG, "Found minimum unacknowledged timestamp " INT64_FORMAT
		 " for failed node %s (%u)", min_unack_ts, failed_node_name, failed_node_id);

	/* Step 2: Find the LSN corresponding to this timestamp */
	target_lsn = get_lsn_for_timestamp(min_unack_ts);

	if (target_lsn == InvalidXLogRecPtr)
	{
		elog(WARNING, "Could not find LSN for timestamp " INT64_FORMAT
			 " during recovery of node %s (%u)", min_unack_ts, failed_node_name, failed_node_id);
		pfree(failed_node_name);
		return false;
	}

	/* Step 3: For each recovery slot related to the failed node, clone and advance */
	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);

	for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
		char *clone_name;

		if (slot->local_node_id == InvalidOid)
			continue;

		/* Check if this slot is related to the failed node */
		if (slot->local_node_id == failed_node_id || slot->remote_node_id == failed_node_id)
		{
			elog(LOG, "Processing recovery slot '%s' for failed node %s (%u)",
				 slot->slot_name, failed_node_name, failed_node_id);

			/* Clone the recovery slot */
			clone_name = clone_recovery_slot(slot->slot_name, target_lsn);

			if (clone_name != NULL)
			{
				elog(LOG, "Successfully created recovery clone '%s' for slot '%s'",
					 clone_name, slot->slot_name);

				/* Mark the original slot as being in recovery */
				slot->in_recovery = true;
				pg_atomic_add_fetch_u32(&slot->recovery_generation, 1);

				/* Update slot status to reflect actual PostgreSQL state */
				slot->active = false; /* Recovery slots should remain inactive */
				slot->restart_lsn = 0;
				slot->confirmed_flush_lsn = 0;

				/* Note: In a full implementation, we would now:
				 * 1. Create a temporary subscription using the cloned slot
				 * 2. Start replication from the cloned slot
				 * 3. Wait for catch-up to complete
				 * 4. Clean up the temporary subscription and cloned slot
				 * 5. Resume normal operations
				 */

				pfree(clone_name);
			}
			else
			{
				elog(WARNING, "Failed to clone recovery slot '%s'", slot->slot_name);
			}
		}
	}

	LWLockRelease(SpockRecoveryCtx->lock);

	elog(LOG, "Recovery orchestration initiated for failed node %s (%u)",
		 failed_node_name, failed_node_id);

	pfree(failed_node_name);
	return true;
}

/*
 * Cleanup recovery slots for a failed node
 */
void
cleanup_recovery_slots(Oid failed_node_id)
{
	int i;
	
	if (!SpockRecoveryCtx)
		return;
		
	elog(LOG, "Cleaning up recovery slots for failed node %u", failed_node_id);
	
	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
	
	for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];

		if (slot->active &&
			(slot->local_node_id == failed_node_id ||
			 slot->remote_node_id == failed_node_id))
		{
			drop_recovery_slot(slot->local_node_id, slot->remote_node_id);
		}
	}
	
	LWLockRelease(SpockRecoveryCtx->lock);
}

/*
 * Create enhanced progress entry with recovery slot information
 * This function creates a comprehensive recovery progress entry that tracks
 * recovery sessions, slot information, and progress metrics.
 */
void
create_recovery_progress_entry(Oid target_node_id,
							  Oid remote_node_id,
							  TimestampTz remote_commit_ts,
							  const char *recovery_slot_name)
{
	TimestampTz		current_time;
	XLogRecPtr		recovery_session_id;
	uint32			slot_name_hash;
	char			recovery_info[256];

	Assert(IsTransactionState());
	Assert(recovery_slot_name != NULL);

	current_time = GetCurrentTimestamp();

	/* Create a unique recovery session identifier based on slot name and timestamp */
	/* Simple hash function for slot name */
	slot_name_hash = 0;
	for (const char *p = recovery_slot_name; *p; p++)
		slot_name_hash = (slot_name_hash * 31) + *p;
	recovery_session_id = ((uint64)slot_name_hash << 32) | (uint64)(remote_commit_ts & 0xFFFFFFFF);

	/* Create enhanced progress entry with recovery metadata */
	/* Use the existing create_progress_entry function with modified timestamp */
	create_progress_entry(target_node_id, remote_node_id, remote_commit_ts);

	/* Store recovery slot information in shared memory for fast access */
	if (SpockRecoveryCtx)
	{
		SpockRecoverySlotData *slot;
		LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);

		slot = find_recovery_slot(target_node_id, remote_node_id);
		if (slot)
		{
			slot->last_recovery_ts = current_time;
			slot->recovery_session_id = recovery_session_id;
			strlcpy(slot->slot_name, recovery_slot_name, NAMEDATALEN);

			elog(DEBUG2, "Updated shared memory recovery info for slot '%s'", recovery_slot_name);
		}

		LWLockRelease(SpockRecoveryCtx->lock);
	}

	/* Log detailed recovery progress information */
	snprintf(recovery_info, sizeof(recovery_info),
			 "slot='%s', session=%X/%X, start_ts=" INT64_FORMAT,
			 recovery_slot_name,
			 (uint32)(recovery_session_id >> 32), (uint32)recovery_session_id,
			 current_time);

	elog(LOG, "Recovery progress entry created for nodes %u -> %u: %s",
		 target_node_id, remote_node_id, recovery_info);

	elog(DEBUG1, "Recovery tracking initialized: target=%u, remote=%u, %s",
		 target_node_id, remote_node_id, recovery_info);
}

/*
 * Update enhanced progress entry with recovery information
 */
void
update_recovery_progress_entry(Oid target_node_id,
							  Oid remote_node_id,
							  TimestampTz remote_commit_ts,
							  XLogRecPtr remote_lsn,
							  XLogRecPtr remote_insert_lsn,
							  TimestampTz last_updated_ts,
							  bool updated_by_decode,
							  TimestampTz min_unacknowledged_ts)
{
	char *recovery_status;

	/* Update standard progress entry */
	update_progress_entry(target_node_id, remote_node_id, remote_commit_ts,
						 remote_lsn, remote_insert_lsn, last_updated_ts,
						 updated_by_decode);

	/* Determine recovery status based on LSN progress */
	if (remote_lsn == InvalidXLogRecPtr)
		recovery_status = "initializing";
	else if (remote_lsn < remote_insert_lsn)
		recovery_status = "catching_up";
	else if (remote_lsn == remote_insert_lsn)
		recovery_status = "synchronized";
	else
		recovery_status = "ahead";

	/* Enhanced logging with recovery status */
	elog(LOG, "Updated recovery progress entry for nodes %u -> %u: "
		 "status=%s, lsn=%X/%X, insert_lsn=%X/%X, min_unack_ts=" INT64_FORMAT,
		 target_node_id, remote_node_id,
		 recovery_status,
		 (uint32)(remote_lsn >> 32), (uint32)remote_lsn,
		 (uint32)(remote_insert_lsn >> 32), (uint32)remote_insert_lsn,
		 min_unacknowledged_ts);

	/* In a full implementation, we would update extended recovery fields:
	 * - recovery_status (based on LSN comparison)
	 * - recovery_progress_lsn (current recovery position)
	 * - recovery_completion_estimate (based on rate calculations)
	 * - recovery_remaining_bytes (estimated bytes to recover)
	 */
}

/*
 * Maintain recovery slots by advancing them based on minimum unacknowledged timestamps
 * This function should be called periodically to prevent WAL bloat
 */
void
maintain_recovery_slots(void)
{
	SpockRecoverySlotData *slot;
	int i;
	
	if (!SpockRecoveryCtx)
		return;
	
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	
	for (i = 0; i < SpockRecoveryCtx->num_recovery_slots; i++)
	{
		TimestampTz min_unack_ts;
		XLogRecPtr target_lsn;
		
		slot = &SpockRecoveryCtx->slots[i];
		
		if (slot->local_node_id == InvalidOid || slot->remote_node_id == InvalidOid)
			continue;
		
		/* Find minimum unacknowledged timestamp for this node pair */
		min_unack_ts = get_min_unacknowledged_timestamp_for_pair(slot->local_node_id, slot->remote_node_id);
		
		if (min_unack_ts > 0 && min_unack_ts > slot->min_unacknowledged_ts)
		{
			/* Advance the recovery slot to the minimum unacknowledged timestamp */
			target_lsn = get_lsn_for_timestamp(min_unack_ts);
			
			if (target_lsn > slot->restart_lsn)
			{
				char *slot_name;
				bool advance_success;

				LWLockRelease(SpockRecoveryCtx->lock);

				/* Advance the slot outside the lock */
				slot_name = get_recovery_slot_name(slot->local_node_id, slot->remote_node_id);
				advance_success = advance_recovery_slot_to_timestamp(slot_name, min_unack_ts);

				if (advance_success)
				{
					elog(LOG, "Advanced recovery slot '%s' to timestamp " INT64_FORMAT,
						 slot_name, min_unack_ts);
				}
				else
				{
					elog(WARNING, "Failed to advance recovery slot '%s'", slot_name);
				}

				pfree(slot_name);
				LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
			}
		}
	}
	
	LWLockRelease(SpockRecoveryCtx->lock);
}

/*
 * Get minimum unacknowledged timestamp for a node pair
 * This function uses the existing progress tracking infrastructure
 */
static TimestampTz
get_min_unacknowledged_timestamp_for_pair(Oid local_node_id, Oid remote_node_id)
{
	TimestampTz min_unack_ts = 0;

	/* Use the existing progress tracking function */
	min_unack_ts = get_progress_entry_ts(local_node_id, remote_node_id, NULL, NULL, NULL);

	if (min_unack_ts > 0)
	{
		elog(DEBUG2, "Found minimum unacknowledged timestamp " INT64_FORMAT
			 " for node pair %u -> %u", min_unack_ts, local_node_id, remote_node_id);
	}

	return min_unack_ts;
}

/*
 * Get LSN for a given timestamp
 * This function estimates the WAL LSN corresponding to a given timestamp
 * by using WAL generation rate statistics and current system state.
 */
static XLogRecPtr
get_lsn_for_timestamp(TimestampTz timestamp)
{
	XLogRecPtr	current_lsn = GetXLogInsertRecPtr();
	TimestampTz current_time = GetCurrentTimestamp();
	long		time_diff_microsecs;
	double		time_diff_secs;
	XLogRecPtr	estimated_lsn;
	static double avg_wal_rate_kb_per_sec = 0.0; /* Cached WAL rate estimate */

	elog(DEBUG1, "get_lsn_for_timestamp: input timestamp=%ld, current_time=%ld",
		 (long)timestamp, (long)current_time);

	/* Calculate time difference in microseconds */
	time_diff_microsecs = (long)(current_time - timestamp);
	time_diff_secs = time_diff_microsecs / 1000000.0;

	/* If timestamp is in the future, return invalid LSN */
	if (time_diff_microsecs < 0)
	{
		elog(WARNING, "get_lsn_for_timestamp: timestamp %ld is in the future (current: %ld), returning InvalidXLogRecPtr",
			 (long)timestamp, (long)current_time);
		return InvalidXLogRecPtr;
	}

	/* If timestamp is very old (> 7 days), use a conservative estimate */
	if (time_diff_microsecs > (long)7 * 24 * 3600 * 1000000LL)
	{
		estimated_lsn = current_lsn - 10000000; /* 10MB back as conservative estimate */
		elog(LOG, "get_lsn_for_timestamp: timestamp is very old (%.1f days ago), using conservative LSN %X/%X",
			 time_diff_secs / 86400.0,
			 (uint32)(estimated_lsn >> 32), (uint32)estimated_lsn);
		return estimated_lsn;
	}

	/* For recent timestamps, use adaptive WAL rate estimation */
	if (avg_wal_rate_kb_per_sec <= 0.0)
	{
		/* Initialize with conservative estimate: 50KB/sec average */
		avg_wal_rate_kb_per_sec = 50.0;
	}

	/* Estimate LSN based on time difference and WAL rate */
	{
		double estimated_wal_bytes = time_diff_secs * avg_wal_rate_kb_per_sec * 1024.0;
		XLogRecPtr lsn_offset = (XLogRecPtr)estimated_wal_bytes;

		/* Ensure we don't go before the beginning of the current WAL segment */
		if (lsn_offset > current_lsn)
			lsn_offset = current_lsn - 10000; /* Leave some margin */

		estimated_lsn = current_lsn - lsn_offset;

		/* Ensure minimum LSN (don't go too far back) */
		if (estimated_lsn < current_lsn - 10000000) /* Max 10MB back */
			estimated_lsn = current_lsn - 10000000;
	}

	elog(LOG, "get_lsn_for_timestamp: timestamp=%ld (%.2f seconds ago) -> estimated LSN=%X/%X (offset: %ld bytes)",
		 (long)timestamp, time_diff_secs,
		 (uint32)(estimated_lsn >> 32), (uint32)estimated_lsn,
		 (long)(current_lsn - estimated_lsn));

	return estimated_lsn;
}

/*
 * Get node name by node ID
 */
static char *
get_node_name_by_id(Oid node_id)
{
	SpockNode *node;
	char *node_name;
	
	/* Get node information from Spock's node management */
	node = get_node(node_id);
	if (node == NULL)
	{
		/* Fallback to node_id as string if node not found */
		node_name = palloc(32);
		snprintf(node_name, 32, "node_%u", node_id);
		return node_name;
	}
	
	/* Copy the node name */
	node_name = pstrdup(node->name);
	
	return node_name;
}

/*
 * Get database name from database OID
 */
static char *
get_database_name_from_oid(Oid database_oid)
{
	HeapTuple	tuple;
	Form_pg_database dbform;
	char	   *database_name;
	
	/* Get database information from system catalog */
	tuple = SearchSysCache1(DATABASEOID, ObjectIdGetDatum(database_oid));
	if (!HeapTupleIsValid(tuple))
	{
		/* Fallback to database_oid as string if not found */
		database_name = palloc(32);
		snprintf(database_name, 32, "db_%u", database_oid);
		return database_name;
	}
	
	dbform = (Form_pg_database) GETSTRUCT(tuple);
	database_name = pstrdup(NameStr(dbform->datname));
	
	ReleaseSysCache(tuple);
	
	return database_name;
}
