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
#include "access/xact.h"
#include "catalog/namespace.h"
#include "replication/slot.h"
#include "replication/walsender.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/snapmgr.h"

#include "spock_recovery.h"
#include "spock_common.h"
#include "spock_node.h"
#include "spock_apply.h"
#include "spock.h"

/* Forward declarations */
extern void create_progress_entry(Oid target_node_id, Oid remote_node_id, TimestampTz remote_commit_ts);
extern void update_progress_entry(Oid target_node_id, Oid remote_node_id, TimestampTz remote_commit_ts,
								 XLogRecPtr remote_lsn, XLogRecPtr remote_insert_lsn,
								 TimestampTz last_updated_ts, bool updated_by_decode);

/* External function declarations */
extern void create_progress_entry(Oid target_node_id, Oid remote_node_id, TimestampTz remote_commit_ts);
extern void update_progress_entry(Oid target_node_id, Oid remote_node_id, TimestampTz remote_commit_ts,
								 XLogRecPtr remote_lsn, XLogRecPtr remote_insert_lsn,
								 TimestampTz last_updated_ts, bool updated_by_decode);

/* Global recovery coordinator in shared memory */
SpockRecoveryCoordinator *SpockRecoveryCtx = NULL;

/* Static function declarations */
static void spock_recovery_shmem_startup(void);
static SpockRecoverySlotData *find_recovery_slot(Oid local_node_id, Oid remote_node_id);
static SpockRecoverySlotData *allocate_recovery_slot(void);
static void initialize_recovery_slot(SpockRecoverySlotData *slot, 
									Oid local_node_id, Oid remote_node_id);

/* Previous shared memory hooks */
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
 * Initialize recovery slots shared memory
 */
void
spock_recovery_shmem_init(void)
{
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
	/* TODO: Get actual max_worker_processes value */
	max_recovery_slots = 100; /* Conservative estimate */

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
 */
char *
get_recovery_slot_name(Oid local_node_id, Oid remote_node_id)
{
	char *slot_name = palloc(NAMEDATALEN);
	
	snprintf(slot_name, NAMEDATALEN, RECOVERY_SLOT_NAME_FORMAT,
			 local_node_id, remote_node_id);
	
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
		ReplicationSlotCreate(slot_name, true, RS_PERSISTENT, false, false, false);
		slot->active = true;
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
	/* TODO: Implement timestamp-based fast-forward */
	elog(LOG, "Advancing recovery slot '%s' to timestamp " INT64_FORMAT,
		 slot_name, target_ts);
	
	/* This will be implemented in Phase 2 */
	return true;
}

/*
 * Clone a recovery slot for rescue operations
 */
char *
clone_recovery_slot(const char *source_slot, XLogRecPtr target_lsn)
{
	char	   *clone_name;
	TimestampTz current_time = GetCurrentTimestamp();
	
	/* Generate unique clone name */
	clone_name = psprintf("%s_clone_%ld", source_slot, current_time);
	
	elog(LOG, "Cloning recovery slot '%s' to '%s' at LSN %X/%X",
		 source_slot, clone_name, 
		 (uint32) (target_lsn >> 32), (uint32) target_lsn);
	
	/* TODO: Implement actual slot cloning logic */
	/* This will be implemented in Phase 2 */
	
	return clone_name;
}

/*
 * Initiate recovery process for a failed node
 */
bool
initiate_node_recovery(Oid failed_node_id)
{
	elog(LOG, "Initiating recovery for failed node %u", failed_node_id);
	
	/* TODO: Implement recovery orchestration */
	/* This will be implemented in Phase 3 */
	
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
 */
void
create_recovery_progress_entry(Oid target_node_id,
							  Oid remote_node_id,
							  TimestampTz remote_commit_ts,
							  const char *recovery_slot_name)
{
	/* TODO: Extend progress table to include recovery slot fields */
	/* For now, create standard progress entry */
	create_progress_entry(target_node_id, remote_node_id, remote_commit_ts);
	
	elog(DEBUG1, "Created recovery progress entry for nodes %u -> %u with slot '%s'",
		 target_node_id, remote_node_id, recovery_slot_name);
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
	/* TODO: Update enhanced progress table with recovery information */
	/* For now, update standard progress entry */
	update_progress_entry(target_node_id, remote_node_id, remote_commit_ts,
						 remote_lsn, remote_insert_lsn, last_updated_ts,
						 updated_by_decode);
	
	elog(DEBUG2, "Updated recovery progress entry for nodes %u -> %u, min_unack_ts=" INT64_FORMAT,
		 target_node_id, remote_node_id, min_unacknowledged_ts);
}
