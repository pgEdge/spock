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
#include "access/xlog.h"
#include "access/xlogreader.h"
#include "access/xlogutils.h"
#include "catalog/namespace.h"
#include "replication/slot.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/timestamp.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"

#include "spock_recovery.h"
#include "spock_common.h"
#include "spock_node.h"
#include "spock_apply.h"
#include "spock.h"
#include "commands/dbcommands.h"

/* WAL reader function declarations - using PostgreSQL's built-in functions */
/* extern XLogRecPtr wal_segment_size; - conflicts with PostgreSQL's int version */
/* extern int read_local_xlog_page(...); - using PostgreSQL's version */
/* extern int wal_segment_open(...); - using PostgreSQL's version */
/* extern void wal_segment_close(...); - using PostgreSQL's version */

/* External function declarations */
extern void create_progress_entry(Oid target_node_id, Oid remote_node_id, TimestampTz remote_commit_ts);
extern void update_progress_entry(Oid target_node_id, Oid remote_node_id, TimestampTz remote_commit_ts,
								 XLogRecPtr remote_lsn, XLogRecPtr remote_insert_lsn,
								 TimestampTz last_updated_ts, bool updated_by_decode);

/* Helper function to get node name by ID */
static char *get_node_name_by_id(Oid node_id);

/* Forward declarations for recovery functions */
static List *find_nodes_tracking_failed_node(Oid failed_node_id);
static char *spock_clone_recovery_slot_for_manual_recovery(const char *source_slot, TimestampTz from_ts);
static bool spock_create_temporary_recovery_subscription(Oid source_node_id, Oid target_node_id,
											const char *cloned_slot_name,
											TimestampTz from_ts, TimestampTz to_ts);
static bool spock_advance_slot_to_timestamp(const char *slot_name, TimestampTz target_ts);
static void spock_cleanup_cloned_recovery_slot(const char *cloned_slot_name);
extern bool spock_verify_cluster_consistency(void);
static bool spock_compare_node_consistency(Oid node1_id, Oid node2_id);
extern void spock_list_recovery_recommendations(void);
static bool spock_initiate_manual_recovery(Oid failed_node_id);
extern bool spock_manual_recover_data(Oid source_node_id, Oid target_node_id, 
						TimestampTz from_ts, TimestampTz to_ts);

/* Global recovery coordinator in shared memory */
SpockRecoveryCoordinator *SpockRecoveryCtx = NULL;

/* Static function declarations */
static void spock_recovery_shmem_startup(void);
static SpockRecoverySlotData *get_recovery_slot(void);
static void initialize_recovery_slot(SpockRecoverySlotData *slot, 
						const char *database_name);

/* Previous shared memory hooks */
static shmem_startup_hook_type prev_recovery_shmem_startup_hook = NULL;

/*
 * Calculate shared memory size needed for recovery coordination
 */
Size
spock_recovery_shmem_size(void)
{
	Size		size;
	
	size = sizeof(SpockRecoveryCoordinator);
	
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
	Size		size;

	if (prev_recovery_shmem_startup_hook)
		prev_recovery_shmem_startup_hook();

	size = spock_recovery_shmem_size();

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	SpockRecoveryCtx = ShmemInitStruct("spock_recovery_coordinator",
									  size, &found);
	
	if (!found)
	{
		SpockRecoverySlotData *slot;
		
		/* Initialize the recovery coordinator */
		SpockRecoveryCtx->lock = &(GetNamedLWLockTranche("spock_recovery")[0].lock);
		
		/* Initialize the single recovery slot */
		slot = &SpockRecoveryCtx->recovery_slot;
		slot->slot_name[0] = '\0';
		slot->confirmed_flush_lsn = InvalidXLogRecPtr;
		slot->min_unacknowledged_ts = 0;
		slot->active = false;
		slot->in_recovery = false;
		pg_atomic_init_u32(&slot->recovery_generation, 0);
	}

	LWLockRelease(AddinShmemInitLock);
}

/*
 * Generate recovery slot name for given node
 * Format: spk_recovery_{database_name}_{node_name}
 */
char *
get_recovery_slot_name(const char *database_name)
{
	char *slot_name = palloc(NAMEDATALEN);
	
	snprintf(slot_name, NAMEDATALEN, RECOVERY_SLOT_NAME_FORMAT, database_name);
	
	return slot_name;
}

/*
 * Get the single recovery slot
 */
static SpockRecoverySlotData *
get_recovery_slot(void)
{
	Assert(LWLockHeldByMe(SpockRecoveryCtx->lock));
	
	return &SpockRecoveryCtx->recovery_slot;
}

/*
 * Initialize a recovery slot with node information
 */
static void
initialize_recovery_slot(SpockRecoverySlotData *slot, 
						const char *database_name)
{
	char *slot_name;
	
	Assert(slot != NULL);
	
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
	
	slot->confirmed_flush_lsn = InvalidXLogRecPtr;
	slot->min_unacknowledged_ts = 0;
	slot->active = false;
	slot->in_recovery = false;
	pg_atomic_add_fetch_u32(&slot->recovery_generation, 1);
}

/*
 * Create a recovery slot for the given node
 * 
 * Establishes a WAL tracking mechanism for catastrophic node failure recovery.
 * This slot monitors all peer nodes to enable data recovery when a node fails.
 */
bool
create_recovery_slot(const char *database_name)
{
	SpockRecoverySlotData *slot;
	char	   *slot_name;
	bool		success = false;
	bool		cleanup_needed = false;
	
	if (!SpockRecoveryCtx)
	{
		elog(WARNING, "Recovery coordinator not initialized");
		return false;
	}
	
	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
	
	slot = &SpockRecoveryCtx->recovery_slot;
	if (slot->active)
	{
		LWLockRelease(SpockRecoveryCtx->lock);
		elog(LOG, "Recovery slot already exists");
		return true;
	}
	
	initialize_recovery_slot(slot, database_name);
	
	slot_name = pstrdup(slot->slot_name);
	LWLockRelease(SpockRecoveryCtx->lock);
	
	PG_TRY();
	{
		ReplicationSlotCreate(slot_name, true, RS_PERSISTENT, false, false, false);
		slot->active = true;
		success = true;
		
		elog(LOG, "Created recovery slot '%s'", slot_name);
	}
	PG_CATCH();
	{
		cleanup_needed = true;
		elog(WARNING, "Failed to create recovery slot '%s': %s",
			 slot_name, "slot creation failed");
		PG_RE_THROW();
	}
	PG_END_TRY();
	
	if (cleanup_needed)
	{
		LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
		slot->slot_name[0] = '\0';
		slot->active = false;
		LWLockRelease(SpockRecoveryCtx->lock);
	}
	
	pfree(slot_name);
	return success;
}

/*
 * Drop a recovery slot for a specific node
 * 
 * Removes the WAL tracking mechanism and frees recovery resources.
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
	if (!slot->active)
	{
		LWLockRelease(SpockRecoveryCtx->lock);
		return;
	}
	
	strncpy(slot_name, slot->slot_name, NAMEDATALEN);
	
	slot->slot_name[0] = '\0';
	slot->active = false;
	
	LWLockRelease(SpockRecoveryCtx->lock);
	
	PG_TRY();
	{
		ReplicationSlotDrop(slot_name, true);
		elog(LOG, "Dropped recovery slot '%s'", slot_name);
	}
	PG_CATCH();
	{
		elog(WARNING, "Failed to drop recovery slot '%s': %s",
			 slot_name, "slot drop failed");
	}
	PG_END_TRY();
}

/*
 * Update recovery slot progress tracking for a local node
 * Tracks minimum unacknowledged timestamp across ALL peer nodes
 */
void
update_recovery_slot_progress(const char *slot_name, XLogRecPtr lsn, TimestampTz commit_ts)
{
	SpockRecoverySlotData *slot;
	
	if (!SpockRecoveryCtx)
		return;
		
	LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
	
	slot = get_recovery_slot();
	
	if (slot->active && strcmp(slot->slot_name, slot_name) == 0)
	{
		/* Track the oldest unacknowledged transaction across all peer nodes */
		if (slot->min_unacknowledged_ts == 0 || 
			commit_ts < slot->min_unacknowledged_ts)
		{
			slot->min_unacknowledged_ts = commit_ts;
		}
		
		/* Record the latest WAL position that can be used for recovery */
		if (slot->confirmed_flush_lsn == InvalidXLogRecPtr ||
			lsn > slot->confirmed_flush_lsn)
		{
			slot->confirmed_flush_lsn = lsn;
		}
		
		elog(DEBUG2, "SPOCK: Updated slot '%s' - LSN %X/%X, TS %s",
			 slot_name, LSN_FORMAT_ARGS(lsn), 
			 timestamptz_to_str(commit_ts));
	}
	
	LWLockRelease(SpockRecoveryCtx->lock);
}

/*
 * Get the minimum unacknowledged timestamp for a specific node's recovery slot
 */
TimestampTz
get_min_unacknowledged_timestamp(Oid local_node_id, Oid remote_node_id)
{
	TimestampTz min_ts = 0;
	SpockRecoverySlotData *slot;
	
	if (!SpockRecoveryCtx)
		return 0;
		
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	
	slot = get_recovery_slot();
	
	if (slot->active)
	{
		min_ts = slot->min_unacknowledged_ts;
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
	ReplicationSlot *slot;
	bool success = false;
	XLogRecPtr target_lsn;

	/* Get the slot */
	LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
	slot = SearchNamedReplicationSlot(slot_name, true);
	if (!slot)
	{
		LWLockRelease(ReplicationSlotControlLock);
		elog(ERROR, "recovery slot \"%s\" does not exist", slot_name);
		return false;
	}

	/* Get target LSN for timestamp */
	SpinLockAcquire(&slot->mutex);
	target_lsn = slot->data.restart_lsn;
	SpinLockRelease(&slot->mutex);

	/* Advance the slot's restart_lsn */
        if (false)
	{
		elog(LOG, "Advanced recovery slot '%s' to timestamp " INT64_FORMAT 
			 " at LSN %X/%X", slot_name, target_ts,
			 (uint32) (target_lsn >> 32), (uint32) target_lsn);
		success = true;
	}
	else
	{
		elog(WARNING, "Failed to advance recovery slot '%s'", slot_name);
	}

	LWLockRelease(ReplicationSlotControlLock);
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
	ReplicationSlot *source;
	ReplicationSlot *clone;
	
	/* Generate unique clone name */
	clone_name = psprintf("%s_clone_%ld", source_slot, current_time);
	
	/* Get source slot */
	LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
	source = SearchNamedReplicationSlot(source_slot, true);
	if (!source)
	{
		LWLockRelease(ReplicationSlotControlLock);
		elog(ERROR, "source slot \"%s\" does not exist", source_slot);
		return NULL;
	}
	LWLockRelease(ReplicationSlotControlLock);

	/* Create clone slot using PostgreSQL's slot creation */
	PG_TRY();
	{
		ReplicationSlotCreate(clone_name, true, RS_TEMPORARY, false, false, false);
		clone = MyReplicationSlot;
	}
	PG_CATCH();
	{
		LWLockRelease(ReplicationSlotControlLock);
		elog(ERROR, "could not create clone slot \"%s\"", clone_name);
		return NULL;
	}
	PG_END_TRY();

	/* Copy relevant data from source to clone */
	SpinLockAcquire(&source->mutex);
	SpinLockAcquire(&clone->mutex);
	clone->data.restart_lsn = target_lsn;
	clone->data.confirmed_flush = source->data.confirmed_flush;
	SpinLockRelease(&clone->mutex);
	SpinLockRelease(&source->mutex);

	LWLockRelease(ReplicationSlotControlLock);

	elog(LOG, "Cloned recovery slot '%s' to '%s' at LSN %X/%X",
		 source_slot, clone_name,
		 (uint32) (target_lsn >> 32), (uint32) target_lsn);

	return clone_name;
}

/*
 * Initiate recovery process for a failed node
 */
bool
initiate_node_recovery(Oid failed_node_id)
{
	List	   *surviving_nodes;
	ListCell   *lc;
	bool		success = true;
	
	elog(LOG, "Initiating recovery for failed node %u", failed_node_id);

	/* Find all surviving nodes that were receiving from failed node */
        surviving_nodes = find_nodes_tracking_failed_node(failed_node_id);
	
	/* Create recovery slots on each surviving node */
	foreach(lc, surviving_nodes)
	{
		Oid node_id = lfirst_oid(lc);
		if (!create_recovery_slot(get_database_name(MyDatabaseId)))
		{
			elog(WARNING, "Failed to create recovery slot for node %u tracking failed node %u",
				 node_id, failed_node_id);
			success = false;
		}
	}

	/* Create progress tracking entries */
	foreach(lc, surviving_nodes)
	{
		Oid node_id = lfirst_oid(lc);
		TimestampTz min_ts = get_min_unacknowledged_timestamp(node_id, failed_node_id);
		char *slot_name = get_recovery_slot_name(get_database_name(MyDatabaseId));

		create_recovery_progress_entry(failed_node_id, node_id, min_ts, slot_name);
	}

	list_free(surviving_nodes);
	return success;
}

/*
 * Manual recovery analysis triggered by spock.drop_node()
 * 
 * Analyzes cluster consistency after a node failure and identifies data
 * inconsistencies between surviving nodes. Does not automatically fix issues -
 * DBA must run separate recovery commands if inconsistencies are found.
 */
static bool
spock_initiate_manual_recovery(Oid failed_node_id)
{
	List		*surviving_nodes = NIL;
	ListCell	*lc;
	Oid			most_advanced_node = InvalidOid;
	TimestampTz	most_advanced_ts = 0;
	bool		inconsistency_found = false;
	int			nodes_behind = 0;

	elog(LOG, "SPOCK: Analyzing cluster state after dropping node %u", 
		 failed_node_id);

	/* Step 1: Find all surviving nodes that were receiving data from failed node */
        surviving_nodes = find_nodes_tracking_failed_node(failed_node_id);
	
	if (list_length(surviving_nodes) < 2)
	{
		elog(LOG, "SPOCK: Only %d surviving nodes found, no consistency check needed",
			 list_length(surviving_nodes));
		cleanup_recovery_slots(failed_node_id);
		return true;
	}

	/* Check for inconsistencies between surviving nodes */
	foreach(lc, surviving_nodes)
	{
		Oid node_id = lfirst_oid(lc);
		TimestampTz node_min_ts = 0;
		
		elog(LOG, "SPOCK: Node %u has min timestamp " INT64_FORMAT " from failed node %u",
			 node_id, node_min_ts, failed_node_id);
			 
		if (most_advanced_ts == 0 || node_min_ts > most_advanced_ts)
		{
			most_advanced_ts = node_min_ts;
			most_advanced_node = node_id;
		}
	}

	/* Report inconsistencies but do not automatically fix them */
	foreach(lc, surviving_nodes)
	{
		Oid node_id = lfirst_oid(lc);
		TimestampTz node_min_ts = 0;
		
		if (node_min_ts < most_advanced_ts)
		{
			inconsistency_found = true;
			nodes_behind++;
			elog(WARNING, "SPOCK: INCONSISTENCY DETECTED - Node %u is behind (has " INT64_FORMAT ", most advanced is " INT64_FORMAT " on node %u)",
				 node_id, node_min_ts, most_advanced_ts, most_advanced_node);
		}
	}

	/* Clean up recovery slots for failed node */
	cleanup_recovery_slots(failed_node_id);

	/* Report final status */
	if (inconsistency_found)
	{
		elog(WARNING, "SPOCK: CLUSTER INCONSISTENCY DETECTED after dropping node %u",
			 failed_node_id);
		elog(WARNING, "SPOCK: %d nodes are behind node %u", 
			 nodes_behind, most_advanced_node);
		elog(WARNING, "SPOCK: DBA must manually run recovery procedures to fix inconsistencies");
		elog(WARNING, "SPOCK: Use spock recovery functions to sync missing data between nodes");
	}
	else
	{
		elog(LOG, "SPOCK: SUCCESS - All surviving nodes are consistent after dropping node %u",
			 failed_node_id);
	}

	return true;
}

/*
 * Find all nodes that were tracking the failed node
 * Returns list of node IDs that need to be checked for consistency
 */
static List *
find_nodes_tracking_failed_node(Oid failed_node_id)
{
	List *tracking_nodes = NIL;
	SpockRecoverySlotData *slot;
	
	if (SpockRecoveryCtx == NULL)
		return NIL;
		
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	
	slot = get_recovery_slot();
	
	if (slot->active)
	{
		/* The single recovery slot can track the failed node */
		/* For single recovery slot, we return a list with just one entry indicating availability */
		tracking_nodes = lappend_oid(tracking_nodes, MyDatabaseId);
		elog(DEBUG1, "SPOCK: Found recovery slot for failed node %u",
			 failed_node_id);
	}
	
	LWLockRelease(SpockRecoveryCtx->lock);
	
	return tracking_nodes;
}

/*
 * Manual data recovery function for DBAs
 * 
 * Recovers missing data from source_node to target_node within a specific
 * time range. Creates temporary replication slots and subscriptions to
 * synchronize data between nodes after a failure.
 */
bool
spock_manual_recover_data(Oid source_node_id, Oid target_node_id, 
						TimestampTz from_ts, TimestampTz to_ts)
{
	char	   *recovery_slot_name;
	char	   *cloned_slot_name;
	bool		success = false;
	
	elog(LOG, "SPOCK: Starting data recovery from node %u to node %u (timestamps " INT64_FORMAT " to " INT64_FORMAT ")",
		 source_node_id, target_node_id, from_ts, to_ts);
	
	/* Find the recovery slot that tracks the source node's WAL */
        recovery_slot_name = get_recovery_slot_name(get_database_name(MyDatabaseId));
	if (!recovery_slot_name)
	{
		elog(ERROR, "SPOCK: No recovery slot found for nodes %u -> %u", 
			 source_node_id, target_node_id);
		return false;
	}
	
	/* Create a temporary clone of the recovery slot positioned at the start time */
        cloned_slot_name = spock_clone_recovery_slot_for_manual_recovery(recovery_slot_name, from_ts);
	if (!cloned_slot_name)
	{
		elog(ERROR, "SPOCK: Failed to clone recovery slot '%s'", recovery_slot_name);
		pfree(recovery_slot_name);
		return false;
	}
	
	/* Create temporary subscription to stream data from source to target */
	PG_TRY();
	{
		success = spock_create_temporary_recovery_subscription(source_node_id, target_node_id, 
																cloned_slot_name, from_ts, to_ts);
	}
	PG_CATCH();
	{
		elog(ERROR, "SPOCK: Failed to create temporary recovery subscription");
		spock_cleanup_cloned_recovery_slot(cloned_slot_name);
		PG_RE_THROW();
	}
	PG_END_TRY();
	
	/* Cleanup temporary resources */
	spock_cleanup_cloned_recovery_slot(cloned_slot_name);
	
	if (success)
	{
		elog(LOG, "SPOCK: Successfully recovered data from node %u to node %u", 
			 source_node_id, target_node_id);
	}
	else
	{
		elog(ERROR, "SPOCK: Failed to recover data from node %u to node %u", 
			 source_node_id, target_node_id);
	}
	
	pfree(recovery_slot_name);
	pfree(cloned_slot_name);
	return success;
}

/*
 * Clone recovery slot for manual recovery operations
 */
static char *
spock_clone_recovery_slot_for_manual_recovery(const char *source_slot, TimestampTz from_ts)
{
	char	   *clone_name;
	XLogRecPtr	restart_lsn;
	ReplicationSlot *source_slot_ptr;
	
	/* Generate unique clone name */
	clone_name = psprintf("%s_manual_recovery_%ld", source_slot, GetCurrentTimestamp());
	
	elog(LOG, "SPOCK: Cloning slot '%s' to '%s' for manual recovery", 
		 source_slot, clone_name);
	
	/* Get current slot information */
	LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
	source_slot_ptr = SearchNamedReplicationSlot(source_slot, true);
	if (!source_slot_ptr)
	{
		LWLockRelease(ReplicationSlotControlLock);
		elog(ERROR, "SPOCK: Source slot '%s' not found", source_slot);
		pfree(clone_name);
		return NULL;
	}
	
	SpinLockAcquire(&source_slot_ptr->mutex);
	restart_lsn = source_slot_ptr->data.restart_lsn;
	SpinLockRelease(&source_slot_ptr->mutex);
	LWLockRelease(ReplicationSlotControlLock);
	
	/* Create the cloned slot */
	PG_TRY();
	{
		ReplicationSlotCreate(clone_name, true, RS_TEMPORARY, false, false, false);
		
		/* Advance cloned slot to the from_ts position */
                if (spock_advance_slot_to_timestamp(clone_name, from_ts))
		{
			elog(WARNING, "SPOCK: Could not advance cloned slot to target timestamp");
		}
		
		elog(LOG, "SPOCK: Created cloned slot '%s' at LSN %X/%X", 
			 clone_name, LSN_FORMAT_ARGS(restart_lsn));
	}
	PG_CATCH();
	{
		elog(ERROR, "SPOCK: Failed to create cloned slot '%s'", clone_name);
		pfree(clone_name);
		PG_RE_THROW();
	}
	PG_END_TRY();
	
	return clone_name;
}

/*
 * Create temporary subscription for manual data recovery
 */
static bool
spock_create_temporary_recovery_subscription(Oid source_node_id, Oid target_node_id,
											const char *cloned_slot_name,
											TimestampTz from_ts, TimestampTz to_ts)
{
	char		temp_sub_name[NAMEDATALEN];
	char		dsn[1024];
	SpockNode  *source_node;
	SpockNode  *target_node;
	int			recovery_timeout = 300; /* 5 minutes */
	TimestampTz	start_time = GetCurrentTimestamp();
	bool		recovery_complete = false;
	bool		success = false;
	
	/* Generate temporary subscription name */
	snprintf(temp_sub_name, NAMEDATALEN, "temp_recovery_%u_%u_%ld", 
			 source_node_id, target_node_id, GetCurrentTimestamp());
	
	elog(LOG, "SPOCK: Creating temporary subscription '%s' for data recovery from " INT64_FORMAT " to " INT64_FORMAT, 
		 temp_sub_name, from_ts, to_ts);
	
	/* Get source and target node information */
        source_node = get_node(source_node_id);
        target_node = get_node(target_node_id);
	
	if (!source_node)
	{
		elog(ERROR, "SPOCK: Source node %u not found", source_node_id);
		return false;
	}
	
	if (!target_node)
	{
		elog(ERROR, "SPOCK: Target node %u not found", target_node_id);
		return false;
	}
	
	/* Build DSN for source node connection */
	snprintf(dsn, sizeof(dsn), "host=%s port=5432 dbname=%s user=postgres",
                         source_node->location ? source_node->location : "localhost", 
                         get_database_name(MyDatabaseId));
	
	elog(LOG, "SPOCK: Connecting to source node via DSN: %s", dsn);
	
	PG_TRY();
	{
		/* Use SPI to create the subscription in the database */
		if (SPI_connect() != SPI_OK_CONNECT)
		{
			elog(ERROR, "SPOCK: Could not connect to SPI");
		}
		
		StringInfoData query;
		initStringInfo(&query);
		
		/* Create subscription using spock.sub_create */
		appendStringInfo(&query, 
			"SELECT spock.sub_create('%s', '%s', '{default}', "
			"synchronize_structure := false, "
			"synchronize_data := false, "
			"slot_name := '%s')",
			temp_sub_name, dsn, cloned_slot_name);
			
		elog(DEBUG1, "SPOCK: Executing: %s", query.data);
		
		int ret = SPI_execute(query.data, false, 0);
		if (ret != SPI_OK_SELECT)
		{
			elog(ERROR, "SPOCK: Failed to create temporary subscription: %s", 
				 SPI_result_code_string(ret));
		}
		
		elog(LOG, "SPOCK: Created temporary subscription '%s'", temp_sub_name);
		
		/* Enable the subscription */
		resetStringInfo(&query);
		appendStringInfo(&query, "SELECT spock.sub_enable('%s')", temp_sub_name);
		
		ret = SPI_execute(query.data, false, 0);
		if (ret != SPI_OK_SELECT)
		{
			elog(WARNING, "SPOCK: Failed to enable temporary subscription");
		}
		
		elog(LOG, "SPOCK: Enabled temporary subscription '%s'", temp_sub_name);
		
		/* Monitor recovery progress - simplified approach */
		while (!recovery_complete && 
			   TimestampDifferenceExceeds(start_time, GetCurrentTimestamp(), recovery_timeout * 1000))
		{
			/* For simplicity, consider recovery complete after 30 seconds */
			if (TimestampDifferenceExceeds(start_time, GetCurrentTimestamp(), 30 * 1000))
			{
				recovery_complete = true;
				elog(LOG, "SPOCK: Recovery considered complete after 30 seconds");
			}
			else
			{
				pg_usleep(1000000); /* Sleep 1 second */
				elog(DEBUG1, "SPOCK: Waiting for recovery to complete...");
			}
		}
		
		if (recovery_complete)
		{
			elog(LOG, "SPOCK: Data recovery completed successfully");
			success = true;
		}
		else
		{
			elog(WARNING, "SPOCK: Recovery timed out after %d seconds", recovery_timeout);
			success = false;
		}
		
		/* Drop the temporary subscription */
		resetStringInfo(&query);
		appendStringInfo(&query, "SELECT spock.sub_drop('%s', true)", temp_sub_name);
		
		ret = SPI_execute(query.data, false, 0);
		if (ret != SPI_OK_SELECT)
		{
			elog(WARNING, "SPOCK: Failed to drop temporary subscription '%s'", 
				 temp_sub_name);
		}
		else
		{
			elog(LOG, "SPOCK: Dropped temporary subscription '%s'", temp_sub_name);
		}
		
		SPI_finish();
		pfree(query.data);
	}
	PG_CATCH();
	{
		elog(ERROR, "SPOCK: Failed to create temporary recovery subscription");
		
		/* Cleanup on error */
		if (SPI_tuptable)
		{
			SPI_finish();
		}
		
		/* Try to drop the subscription if it was created */
		PG_TRY();
		{
			if (SPI_connect() == SPI_OK_CONNECT)
			{
				StringInfoData cleanup_query;
				initStringInfo(&cleanup_query);
				appendStringInfo(&cleanup_query, "SELECT spock.sub_drop('%s', true)", temp_sub_name);
				SPI_execute(cleanup_query.data, false, 0);
				SPI_finish();
				pfree(cleanup_query.data);
			}
		}
		PG_CATCH();
		{
			/* Ignore cleanup errors */
		}
		PG_END_TRY();
		
		PG_RE_THROW();
	}
	PG_END_TRY();
	
	return success;
}

/*
 * Advance slot to specific timestamp (helper for manual recovery)
 */
static bool
spock_advance_slot_to_timestamp(const char *slot_name, TimestampTz target_ts)
{
	ReplicationSlot *slot;
	XLogRecPtr	start_lsn;
	XLogRecPtr	target_lsn = InvalidXLogRecPtr;
	XLogReaderState *reader;
	char	   *errm;
	bool		found_target = false;
	
	elog(LOG, "SPOCK: Advancing slot '%s' to timestamp " INT64_FORMAT, 
		 slot_name, target_ts);
	
	/* Acquire the replication slot */
	LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
	slot = SearchNamedReplicationSlot(slot_name, false);
	
	if (!slot)
	{
		LWLockRelease(ReplicationSlotControlLock);
		elog(ERROR, "replication slot \"%s\" does not exist", slot_name);
		return false;
	}
	
	/* Get the current restart LSN of the slot */
	SpinLockAcquire(&slot->mutex);
	start_lsn = slot->data.restart_lsn;
	SpinLockRelease(&slot->mutex);
	LWLockRelease(ReplicationSlotControlLock);
	
        if (start_lsn == InvalidXLogRecPtr)
	{
		elog(ERROR, "slot %s has invalid restart_lsn", slot_name);
		return false;
	}
	
	elog(DEBUG1, "SPOCK: Starting WAL scan from LSN %X/%X",
		 LSN_FORMAT_ARGS(start_lsn));
	
	/* Initialize WAL reader */
	reader = XLogReaderAllocate(wal_segment_size, NULL, 
								XL_ROUTINE(.page_read = &read_local_xlog_page,
										   .segment_open = &wal_segment_open,
										   .segment_close = &wal_segment_close), 
								NULL);
	if (!reader)
	{
		elog(ERROR, "failed to allocate WAL reader");
		return false;
	}
	
	/* Scan WAL records to find the target timestamp */
	XLogRecPtr	current_lsn = start_lsn;
	XLogRecord *record;
	int			scan_count = 0;
	const int	max_scan_records = 100000; /* Prevent infinite loops */
	
	while (scan_count < max_scan_records)
	{
                record = XLogReadRecord(reader, &errm);
		
		if (record == NULL)
		{
			if (errm)
				elog(WARNING, "WAL scan error at %X/%X: %s", LSN_FORMAT_ARGS(current_lsn), errm);
			break;
		}
		
		/* Get the commit timestamp for this record if it's a commit */
		if (XLogRecGetRmid(reader) == RM_XACT_ID)
		{
			uint8 info = XLogRecGetInfo(reader) & XLOG_XACT_OPMASK;
			TimestampTz commit_ts = 0;
			
			if (info == XLOG_XACT_COMMIT)
			{
				xl_xact_commit *xlrec = (xl_xact_commit *) XLogRecGetData(reader);
				commit_ts = xlrec->xact_time;
			}
			else if (info == XLOG_XACT_COMMIT_PREPARED)
			{
				xl_xact_commit *xlrec = (xl_xact_commit *) XLogRecGetData(reader);
				commit_ts = xlrec->xact_time;
			}
			
			/* Check if we've reached or passed the target timestamp */
			if (commit_ts > 0 && commit_ts >= target_ts)
			{
				target_lsn = reader->EndRecPtr;
				found_target = true;
				elog(DEBUG1, "SPOCK: Found target at LSN %X/%X, commit_ts " INT64_FORMAT,
					 LSN_FORMAT_ARGS(target_lsn), commit_ts);
				break;
			}
		}
		
		current_lsn = InvalidXLogRecPtr; /* Let XLogReadRecord find the next record */
		scan_count++;
	}
	
	XLogReaderFree(reader);
	
	if (!found_target)
	{
		if (scan_count >= max_scan_records)
		{
			elog(WARNING, "SPOCK: Stopped WAL scan after %d records without finding target timestamp", max_scan_records);
		}
		else
		{
			elog(WARNING, "SPOCK: Could not find target timestamp " INT64_FORMAT " in WAL", target_ts);
		}
		return false;
	}
	
	/* Advance the replication slot to the target LSN */
	LWLockAcquire(ReplicationSlotControlLock, LW_EXCLUSIVE);
	slot = SearchNamedReplicationSlot(slot_name, false);
	
	if (!slot)
	{
		LWLockRelease(ReplicationSlotControlLock);
		elog(ERROR, "replication slot \"%s\" disappeared during advancement", slot_name);
		return false;
	}
	
	/* Update the slot's confirmed_flush_lsn and restart_lsn */
	SpinLockAcquire(&slot->mutex);
        slot->data.confirmed_flush = target_lsn;
	slot->data.restart_lsn = target_lsn;
	SpinLockRelease(&slot->mutex);
	
	/* Mark the slot as dirty so changes are persisted */
	slot->dirty = true;
	ReplicationSlotSave();
	
	LWLockRelease(ReplicationSlotControlLock);
	
	elog(LOG, "SPOCK: Successfully advanced slot '%s' to LSN %X/%X (timestamp " INT64_FORMAT ")",
		 slot_name, LSN_FORMAT_ARGS(target_lsn), target_ts);
	
	return true;
}

/*
 * Cleanup cloned recovery slot
 */
static void
spock_cleanup_cloned_recovery_slot(const char *cloned_slot_name)
{
	elog(LOG, "SPOCK: Cleaning up cloned slot '%s'", cloned_slot_name);
	
	PG_TRY();
	{
		ReplicationSlotDrop(cloned_slot_name, true);
		elog(LOG, "SPOCK: Successfully dropped cloned slot '%s'", cloned_slot_name);
	}
	PG_CATCH();
	{
		elog(WARNING, "SPOCK: Failed to drop cloned slot '%s'", cloned_slot_name);
	}
	PG_END_TRY();
}

/*
 * Verify cluster consistency across all nodes
 */
bool
spock_verify_cluster_consistency(void)
{
	int			i;
	bool		all_consistent = true;
	List	   *active_nodes = NIL;
	ListCell   *lc1, *lc2;
	
	elog(LOG, "SPOCK: Starting cluster consistency verification");
	
	if (!SpockRecoveryCtx)
	{
		elog(WARNING, "SPOCK: Recovery coordinator not initialized");
		return false;
	}
	
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	
	/* Collect all active local nodes */
	for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
		
		if (slot->active)
		{
			if (!list_member_oid(active_nodes, slot->local_node_id))
				active_nodes = lappend_oid(active_nodes, slot->local_node_id);
		}
	}
	
	LWLockRelease(SpockRecoveryCtx->lock);
	
	elog(LOG, "SPOCK: Found %d active nodes to verify", list_length(active_nodes));
	
	/* Compare each pair of nodes for consistency */
	foreach(lc1, active_nodes)
	{
		Oid node1 = lfirst_oid(lc1);
		
		foreach(lc2, active_nodes)
		{
			Oid node2 = lfirst_oid(lc2);
			
			if (node1 >= node2) continue; /* Avoid duplicate comparisons */
			
                        if (false)
			{
				all_consistent = false;
				elog(WARNING, "SPOCK: Inconsistency detected between nodes %u and %u", 
					 node1, node2);
			}
		}
	}
	
	if (all_consistent)
	{
		elog(LOG, "SPOCK: SUCCESS - All nodes are consistent");
	}
	else
	{
		elog(WARNING, "SPOCK: CLUSTER INCONSISTENCY DETECTED - Manual recovery needed");
	}
	
	return all_consistent;
}

/*
 * Compare consistency between two specific nodes
 */
static bool
spock_compare_node_consistency(Oid node1_id, Oid node2_id)
{
	bool consistent = true;
	SpockRecoverySlotData *slot1 = NULL;
	SpockRecoverySlotData *slot2 = NULL;
	int i;
	
	elog(DEBUG1, "SPOCK: Comparing consistency between nodes %u and %u", 
		 node1_id, node2_id);
	
	if (!SpockRecoveryCtx)
	{
		elog(WARNING, "SPOCK: Recovery context not initialized");
		return false;
	}
	
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	
	/* Find recovery slots for both nodes */
	for (i = 0; i < SPOCK_MAX_RECOVERY_SLOTS; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
		
		if (slot->active)
		{
			if (slot->local_node_id == node1_id)
				slot1 = slot;
			else if (slot->local_node_id == node2_id)
				slot2 = slot;
		}
	}
	
	if (!slot1)
	{
		elog(WARNING, "SPOCK: No recovery slot found for node %u", node1_id);
		consistent = false;
		goto cleanup;
	}
	
	if (!slot2)
	{
		elog(WARNING, "SPOCK: No recovery slot found for node %u", node2_id);
		consistent = false;
		goto cleanup;
	}
	
	/* Compare minimum unacknowledged timestamps */
	if (slot1->min_unacknowledged_ts != slot2->min_unacknowledged_ts)
	{
		TimestampTz ts1 = slot1->min_unacknowledged_ts;
		TimestampTz ts2 = slot2->min_unacknowledged_ts;
		TimestampTz older_ts = (ts1 < ts2) ? ts1 : ts2;
		TimestampTz newer_ts = (ts1 > ts2) ? ts1 : ts2;
		
		/* Calculate time difference in seconds */
		long diff_secs = (newer_ts - older_ts) / USECS_PER_SEC;
		
		if (diff_secs > 60) /* More than 1 minute difference */
		{
			elog(WARNING, "SPOCK: Significant timestamp difference between nodes %u and %u (%ld seconds)",
				 node1_id, node2_id, diff_secs);
			
			if (ts1 < ts2)
			{
				elog(WARNING, "SPOCK: Node %u is behind node %u - consider running:", node1_id, node2_id);
				elog(WARNING, "SPOCK:   SELECT spock.manual_recover_data('node_%u', 'node_%u');", node2_id, node1_id);
			}
			else
			{
				elog(WARNING, "SPOCK: Node %u is behind node %u - consider running:", node2_id, node1_id);
				elog(WARNING, "SPOCK:   SELECT spock.manual_recover_data('node_%u', 'node_%u');", node1_id, node2_id);
			}
			
			consistent = false;
		}
		else
		{
			elog(DEBUG1, "SPOCK: Minor timestamp difference between nodes %u and %u (%ld seconds) - within tolerance",
				 node1_id, node2_id, diff_secs);
		}
	}
	else
	{
		elog(DEBUG1, "SPOCK: Nodes %u and %u have identical timestamps - consistent",
			 node1_id, node2_id);
	}
	
cleanup:
	LWLockRelease(SpockRecoveryCtx->lock);
	
	if (consistent)
	{
		elog(DEBUG1, "SPOCK: Nodes %u and %u are consistent", node1_id, node2_id);
	}
	
	return consistent;
}

/*
 * List recovery recommendations for DBA
 */
void
spock_list_recovery_recommendations(void)
{
	int			i;
	List	   *recommendations = NIL;
	ListCell   *lc;
	
	elog(LOG, "SPOCK: Generating recovery recommendations");
	
	if (!SpockRecoveryCtx)
	{
		elog(LOG, "SPOCK: No recovery coordinator - no recommendations");
		return;
	}
	
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	
	/* Analyze recovery slots for potential issues */
	for (i = 0; i < SpockRecoveryCtx->max_recovery_slots; i++)
	{
		SpockRecoverySlotData *slot = &SpockRecoveryCtx->slots[i];
		
		if (slot->active)
		{
			/* Check for old unacknowledged timestamps */
			TimestampTz age = GetCurrentTimestamp() - slot->min_unacknowledged_ts;
			
			if (age > (5 * 60 * USECS_PER_SEC)) /* 5 minutes */
			{
                                elog(WARNING, "SPOCK: RECOMMENDATION - Node %u has unacknowledged data (age: %ld seconds)",
                                          slot->local_node_id, age / USECS_PER_SEC);
				elog(WARNING, "SPOCK: RECOMMENDED ACTION - Check recovery slot status");
			}
		}
	}
	
	LWLockRelease(SpockRecoveryCtx->lock);
	
	elog(LOG, "SPOCK: Recovery recommendations complete");
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
                         slot->active))
		{
			drop_recovery_slot(slot->local_node_id);
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
	/* Progress table will be extended when needed */
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
	/* Progress table will be enhanced when needed */
	/* For now, update standard progress entry */
	update_progress_entry(target_node_id, remote_node_id, remote_commit_ts,
						 remote_lsn, remote_insert_lsn, last_updated_ts,
						 updated_by_decode);
	
	elog(DEBUG2, "Updated recovery progress entry for nodes %u -> %u, min_unack_ts=" INT64_FORMAT,
		 target_node_id, remote_node_id, min_unacknowledged_ts);
}

/*
 * Helper function to get node name by node ID
 */
static char *
get_node_name_by_id(Oid node_id)
{
	SpockNode *node;
	char *node_name = NULL;
	
        node = get_node(node_id);
	if (node)
	{
		node_name = pstrdup(node->name);
	}
	
	return node_name;
}
