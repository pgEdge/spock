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
#include "storage/lwlock.h"

#define RECOVERY_SLOT_PREFIX "spk_recovery_"
#define RECOVERY_SLOT_NAME_FORMAT RECOVERY_SLOT_PREFIX "%s"

/*
 * Single recovery slot structure for the entire cluster
 * ONE recovery slot that tracks unacknowledged transactions from ALL nodes
 */
typedef struct SpockRecoverySlotData
{
	char		slot_name[NAMEDATALEN];		/* PostgreSQL logical replication slot name */
	XLogRecPtr	restart_lsn;				/* Earliest WAL position needed for recovery */
	XLogRecPtr	confirmed_flush_lsn;		/* Latest acknowledged WAL position */
	TimestampTz	min_unacknowledged_ts;		/* Oldest transaction not acknowledged by ANY remote */
	bool		active;						/* Whether slot is actively being used */
	bool		in_recovery;				/* Whether slot is currently in recovery process */
	pg_atomic_uint32 recovery_generation;	/* Atomic counter preventing stale operations */
} SpockRecoverySlotData;

/*
 * Recovery coordination data in shared memory
 */
typedef struct SpockRecoveryCoordinator
{
	LWLock	   *lock;
	SpockRecoverySlotData recovery_slot;	/* Single recovery slot for entire cluster */
} SpockRecoveryCoordinator;

/* Recovery slot management functions */
extern void spock_recovery_shmem_init(void);
extern Size spock_recovery_shmem_size(void);

extern bool create_recovery_slot(const char *database_name);
extern void drop_recovery_slot(void);
extern char *get_recovery_slot_name(const char *database_name);

extern void update_recovery_slot_progress(const char *slot_name, XLogRecPtr lsn, TimestampTz commit_ts);

extern TimestampTz get_min_unacknowledged_timestamp(Oid local_node_id, Oid remote_node_id);
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

/* Global recovery coordinator */
extern SpockRecoveryCoordinator *SpockRecoveryCtx;

/* SQL wrapper functions for recovery operations */
extern Datum spock_drop_node_with_recovery_sql(PG_FUNCTION_ARGS);
extern Datum spock_quick_health_check_sql(PG_FUNCTION_ARGS);

/* C function declarations for recovery logic */
extern bool spock_manual_recover_data(Oid source_node_id, Oid target_node_id, 
						TimestampTz from_ts, TimestampTz to_ts);
extern bool spock_verify_cluster_consistency(void);
extern void spock_list_recovery_recommendations(void);

#endif /* SPOCK_RECOVERY_H */
