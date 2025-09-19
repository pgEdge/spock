/*-------------------------------------------------------------------------
 *
 * spock_recovery.h
 * 		Recovery Slots for catastrophic node failure handling
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_RECOVERY_H
#define SPOCK_RECOVERY_H

#include "postgres.h"
#include "access/xlogdefs.h"
#include "utils/timestamp.h"

/* Recovery slot naming convention */
#define RECOVERY_SLOT_PREFIX "spock_"
#define RECOVERY_SLOT_SUFFIX "_recovery_"

/*
 * Enhanced progress tracking structure for Recovery Slots
 * This extends the existing ProgressTuple to include recovery slot metadata
 */
typedef struct RecoveryProgressTuple
{
	Oid			node_id;
	Oid			remote_node_id;
	TimestampTz	remote_commit_ts;
	XLogRecPtr	remote_lsn;
	XLogRecPtr	remote_insert_lsn;
	TimestampTz	last_updated_ts;
	bool		updated_by_decode;
	
	/* Recovery slot specific fields */
	char		recovery_slot_name[NAMEDATALEN];
	TimestampTz	min_unacknowledged_ts;
	XLogRecPtr	recovery_slot_lsn;
	bool		recovery_active;
} RecoveryProgressTuple;

/*
 * Shared memory structure for tracking recovery slots across all nodes
 */
typedef struct SpockRecoverySlotData
{
	Oid			local_node_id;
	Oid			remote_node_id;
	char		slot_name[NAMEDATALEN];
	XLogRecPtr	restart_lsn;
	XLogRecPtr	confirmed_flush_lsn;
	TimestampTz	min_unacknowledged_ts;
	bool		active;
	bool		in_recovery;
	pg_atomic_uint32 recovery_generation;

	/* Enhanced recovery tracking fields */
	TimestampTz	last_recovery_ts;
	XLogRecPtr	recovery_session_id;
} SpockRecoverySlotData;

/*
 * Recovery coordination data in shared memory
 */
typedef struct SpockRecoveryCoordinator
{
	LWLock	   *lock;
	int			max_recovery_slots;
	int			num_recovery_slots;
	SpockRecoverySlotData slots[FLEXIBLE_ARRAY_MEMBER];
} SpockRecoveryCoordinator;

/* Recovery slot management functions */
extern void spock_recovery_shmem_init(void);
extern Size spock_recovery_shmem_size(int max_recovery_slots);

extern bool create_recovery_slot(Oid local_node_id, Oid remote_node_id);
extern void drop_recovery_slot(Oid local_node_id, Oid remote_node_id);
extern char *get_recovery_slot_name(Oid local_node_id, Oid remote_node_id);

extern void update_recovery_slot_progress(const char *slot_name, 
										 TimestampTz commit_ts, 
										 XLogRecPtr lsn);

extern TimestampTz get_min_unacknowledged_timestamp(Oid failed_node_id);
extern XLogRecPtr get_recovery_slot_restart_lsn(const char *slot_name);

extern bool advance_recovery_slot_to_timestamp(const char *slot_name, 
											   TimestampTz target_ts);

/* Recovery orchestration functions */
extern bool initiate_node_recovery(Oid failed_node_id);
extern char *clone_recovery_slot(const char *source_slot, XLogRecPtr target_lsn);
extern void cleanup_recovery_slots(Oid failed_node_id);

/* Progress table enhancement functions */
extern void create_recovery_progress_entry(Oid target_node_id,
										   Oid remote_node_id,
										   TimestampTz remote_commit_ts,
										   const char *recovery_slot_name);

extern void update_recovery_progress_entry(Oid target_node_id,
										   Oid remote_node_id,
										   TimestampTz remote_commit_ts,
										   XLogRecPtr remote_lsn,
										   XLogRecPtr remote_insert_lsn,
										   TimestampTz last_updated_ts,
										   bool updated_by_decode,
										   TimestampTz min_unacknowledged_ts);

/* Slot lifecycle management functions */
extern void maintain_recovery_slots(void);
extern bool advance_recovery_slot(Oid local_node_id, Oid remote_node_id, XLogRecPtr target_lsn);

/* Global recovery coordinator */
extern SpockRecoveryCoordinator *SpockRecoveryCtx;

#endif /* SPOCK_RECOVERY_H */
