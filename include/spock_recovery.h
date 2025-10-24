/*-------------------------------------------------------------------------
 *
 * spock_recovery.h
 *		Recovery Slots for catastrophic node failure handling
 *
 * Recovery Slots are inactive logical replication slots that preserve WAL
 * segments for catastrophic failure recovery. Each database maintains one
 * recovery slot shared across all subscriptions.
 *
 * Slot Design:
 *   - One slot per database (not per subscription or peer node)
 *   - Inactive - never used for normal replication
 *   - Preserves WAL for all peer transactions
 *   - Enables recovery without cluster rebuild
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_RECOVERY_H
#define SPOCK_RECOVERY_H

#include "postgres.h"
#include "access/xlogdefs.h"
#include "utils/timestamp.h"
#include "storage/lwlock.h"
#include "port/atomics.h"

/*
 * Recovery slot naming convention: spk_recovery_{database_name}
 *
 * This format ensures slots are easily identifiable and unique per database.
 */
#define RECOVERY_SLOT_NAME_FORMAT "spk_recovery_%s"

/*
 * SpockRecoverySlotData
 *
 * Shared memory structure for a database recovery slot.
 * Tracks an inactive replication slot used for catastrophic failure recovery.
 */
typedef struct SpockRecoverySlotData
{
	char		slot_name[NAMEDATALEN];		/* Name of the recovery slot */
	XLogRecPtr	restart_lsn;				/* Earliest LSN needed for recovery */
	XLogRecPtr	confirmed_flush_lsn;		/* Latest flushed LSN */
	TimestampTz	min_unacknowledged_ts;		/* Oldest unacknowledged transaction timestamp */
	bool		active;						/* Is the slot created and active? */
	bool		in_recovery;				/* Currently being used for recovery? */
	pg_atomic_uint32 recovery_generation;	/* Generation counter for slot recreation */
} SpockRecoverySlotData;

/*
 * SpockRecoveryCoordinator
 *
 * Shared memory coordinator for database recovery slot management.
 * Coordinates access to the single recovery slot for this database.
 */
typedef struct SpockRecoveryCoordinator
{
	LWLock				   *lock;			/* Protects access to recovery slot */
	SpockRecoverySlotData	recovery_slot;	/* Single recovery slot for this database */
} SpockRecoveryCoordinator;

/* Global recovery coordinator in shared memory */
extern SpockRecoveryCoordinator *SpockRecoveryCtx;

/*
 * Shared memory management functions
 */
extern Size spock_recovery_shmem_size(void);
extern void spock_recovery_shmem_startup(void);

/*
 * Recovery slot management functions
 */
extern char *get_recovery_slot_name(const char *database_name);
extern bool create_recovery_slot(const char *database_name);
extern void drop_recovery_slot(void);
extern void update_recovery_slot_progress(const char *slot_name,
										  XLogRecPtr lsn,
										  TimestampTz commit_ts);

/*
 * Rescue coordinator functions
 */
extern Datum spock_find_rescue_source_sql(PG_FUNCTION_ARGS);

#endif							/* SPOCK_RECOVERY_H */
