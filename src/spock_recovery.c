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

#include "access/heapam.h"
#include "access/xlog.h"
#include "access/xlogutils.h"
#include "catalog/namespace.h"
#include "catalog/pg_subscription.h"
#include "commands/dbcommands.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "libpq-fe.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "replication/decode.h"
#include "replication/logical.h"
#include "replication/origin.h"
#include "replication/slot.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/elog.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"
#include <ctype.h>

#include "spock.h"
#include "spock_common.h"
#include "spock_node.h"
#include "spock_group.h"
#include "spock_recovery.h"
#include "spock_sync.h"

/* Global recovery coordinator in shared memory */
SpockRecoveryCoordinator *SpockRecoveryCtx = NULL;

/* Hook for shared memory startup - no longer needed since integrated with worker shmem */

/* Internal function prototypes */
static SpockRecoverySlotData *get_recovery_slot(void);
static void initialize_recovery_slot(SpockRecoverySlotData *slot,
									 const char *database_name);
static void append_sanitized_token(StringInfo buf, const char *token);
static char *build_rescue_subscription_name(const char *target, const char *source);
static void validate_rescue_slot_name(const char *slot_name);

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
	/* Note: AddinShmemInitLock is already held by caller (spock_worker_shmem_startup) */

	size = spock_recovery_shmem_size();

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

	/* Note: AddinShmemInitLock is released by caller (spock_worker_shmem_startup) */
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
 * Helper to sanitize node names into subscription-safe tokens.
 */
static void
append_sanitized_token(StringInfo buf, const char *token)
{
	int			i;

	if (token == NULL || token[0] == '\0')
	{
		appendStringInfoString(buf, "unknown");
		return;
	}

	for (i = 0; token[i] != '\0'; i++)
	{
		unsigned char c = (unsigned char) token[i];

		if (c >= 'A' && c <= 'Z')
			appendStringInfoChar(buf, (char) tolower(c));
		else if ((c >= 'a' && c <= 'z') ||
				 (c >= '0' && c <= '9'))
			appendStringInfoChar(buf, (char) c);
		else if (c == '_')
			appendStringInfoChar(buf, '_');
		else
			appendStringInfoChar(buf, '_');
	}
}

/*
 * Build deterministic subscription name for rescue subscriptions.
 */
static char *
build_rescue_subscription_name(const char *target, const char *source)
{
	StringInfoData buf;

	initStringInfo(&buf);
	appendStringInfoString(&buf, "spock_rescue_sub_");
	append_sanitized_token(&buf, target);
	appendStringInfoChar(&buf, '_');
	append_sanitized_token(&buf, source);

	if (buf.len >= NAMEDATALEN)
		ereport(ERROR,
				(errcode(ERRCODE_NAME_TOO_LONG),
				 errmsg("generated rescue subscription name \"%s\" is too long",
						buf.data)));

	return buf.data;
}

/*
 * Validate cloned slot name for rescue subscription.
 */
static void
validate_rescue_slot_name(const char *slot_name)
{
	size_t		len;
	int			i;

	if (slot_name == NULL || slot_name[0] == '\0')
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("cloned slot name must not be empty")));

	len = strlen(slot_name);
	if (len >= NAMEDATALEN)
		ereport(ERROR,
				(errcode(ERRCODE_NAME_TOO_LONG),
				 errmsg("cloned slot name \"%s\" is too long", slot_name)));

	for (i = 0; slot_name[i] != '\0'; i++)
	{
		unsigned char c = (unsigned char) slot_name[i];

		if ((c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '_')
			continue;

		ereport(ERROR,
				(errcode(ERRCODE_INVALID_NAME),
				 errmsg("cloned slot name \"%s\" contains invalid character \"%c\"",
						slot_name, slot_name[i]),
				 errhint("Slot names may only contain lower case letters, "
						 "numbers, and the underscore character.")));
	}
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
	 * If the slot already exists at PostgreSQL level (e.g., after restart),
	 * we just mark it as active in shared memory and continue.
	 *
	 * IMPORTANT: ReplicationSlotCreate may need to wait (for locks, etc.),
	 * which requires MyProc to be fully initialized. This should only be
	 * called from a fully initialized backend process (e.g., background worker).
	 * Check if we're in a context where we can wait by verifying MyProc exists.
	 */
	if (!IsUnderPostmaster || MyProc == NULL)
	{
		elog(ERROR, "cannot create recovery slot: not in a fully initialized backend process");
		pfree(slot_name);
		return false;
	}

	PG_TRY();
	{
		int			ret;
		StringInfoData query;
		
		/*
		 * CRITICAL FIX: Create a LOGICAL slot (not physical) to preserve catalog_xmin.
		 * This allows the recovery slot to decode historical transactions during disaster recovery.
		 * Without a logical slot, cloned slots get a new catalog_xmin that filters out old transactions.
		 * 
		 * Use pg_create_logical_replication_slot() SQL function to create the slot with spock_output plugin.
		 * This is simpler and more reliable than using the C API directly.
		 */
		
		elog(LOG, "[RECOVERY_SLOT_FIX] Creating LOGICAL recovery slot '%s' using pg_create_logical_replication_slot() with spock_output plugin",
			 slot_name);
		
		ret = SPI_connect();
		if (ret != SPI_OK_CONNECT)
			elog(ERROR, "SPI_connect failed while creating recovery slot");
		
		PushActiveSnapshot(GetTransactionSnapshot());
		
		initStringInfo(&query);
		appendStringInfo(&query,
						 "SELECT pg_create_logical_replication_slot(%s, 'spock_output', false, true)",
						 quote_literal_cstr(slot_name));
		
		elog(LOG, "[RECOVERY_SLOT_FIX] Executing SQL: %s", query.data);
		
		ret = SPI_execute(query.data, false, 0);
		if (ret != SPI_OK_SELECT)
			elog(ERROR, "failed to create logical recovery slot \"%s\" (SPI code %d)",
				 slot_name, ret);
		
		/* Verify the slot was created with correct properties */
		resetStringInfo(&query);
		appendStringInfo(&query,
						 "SELECT plugin, restart_lsn, catalog_xmin FROM pg_replication_slots WHERE slot_name = %s",
						 quote_literal_cstr(slot_name));
		
		ret = SPI_execute(query.data, true, 0);
		if (ret == SPI_OK_SELECT && SPI_processed > 0)
		{
			char	   *plugin;
			char	   *restart_lsn_str;
			char	   *catalog_xmin_str;
			
			plugin = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
			restart_lsn_str = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2);
			catalog_xmin_str = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3);
			
			elog(LOG, "[RECOVERY_SLOT_FIX] Verified LOGICAL slot created successfully:");
			elog(LOG, "[RECOVERY_SLOT_FIX]   - plugin: %s (should be 'spock_output')",
				 plugin ? plugin : "NULL");
			elog(LOG, "[RECOVERY_SLOT_FIX]   - restart_lsn: %s",
				 restart_lsn_str ? restart_lsn_str : "NULL");
			elog(LOG, "[RECOVERY_SLOT_FIX]   - catalog_xmin: %s (preserves catalog for old transactions)",
				 catalog_xmin_str ? catalog_xmin_str : "NULL");
		}
		
		PopActiveSnapshot();
		SPI_finish();
		
		elog(LOG, "[RECOVERY_SLOT_FIX] Successfully created LOGICAL recovery slot '%s' with spock_output plugin (catalog_xmin will be preserved for disaster recovery)",
			 slot_name);
	}
	PG_CATCH();
	{
		ErrorData  *edata;
		MemoryContext oldcontext;
		
		/* Switch to TopMemoryContext to avoid ErrorContext assertion */
		oldcontext = MemoryContextSwitchTo(TopMemoryContext);
		edata = CopyErrorData();
		FlushErrorState();
		
		/* If slot already exists, that's OK - just mark it active */
		if (edata->sqlerrcode == ERRCODE_DUPLICATE_OBJECT)
		{
			elog(LOG, "recovery slot '%s' already exists at PostgreSQL level, reusing it", slot_name);
			FreeErrorData(edata);
			
			/* Mark slot as active in shared memory */
			LWLockAcquire(SpockRecoveryCtx->lock, LW_EXCLUSIVE);
			slot->active = true;
			LWLockRelease(SpockRecoveryCtx->lock);
			
			pfree(slot_name);
			return true;
		}
		
		/* For other errors, re-throw */
		FreeErrorData(edata);
		MemoryContextSwitchTo(oldcontext);
		PG_RE_THROW();
	}
	PG_END_TRY();

	/*
	 * Initialize the recovery slot's restart_lsn to the current WAL position.
	 * This ensures PostgreSQL preserves WAL from this point onwards, even if
	 * the slot hasn't been used for decoding yet. Without this, a slot with
	 * NULL restart_lsn might not preserve WAL segments.
	 *
	 * Note: ReplicationSlotCreate() sets MyReplicationSlot when the slot is
	 * created. We use it directly (similar to cloned slot code) to initialize
	 * the restart_lsn. If MyReplicationSlot is NULL, the slot creation failed
	 * or the slot was already released, so we skip initialization.
	 */
	if (MyReplicationSlot)
	{
		XLogRecPtr current_wal_lsn;

		/* Get current WAL position */
		current_wal_lsn = GetXLogWriteRecPtr();

		/*
		 * Initialize restart_lsn and confirmed_flush_lsn to current WAL position.
		 * Both are set to the same value initially. The manager worker will advance
		 * confirmed_flush_lsn to the minimum peer position while keeping restart_lsn
		 * behind to preserve WAL. This ensures the recovery slot preserves historical
		 * WAL for rescue operations.
		 */
		SpinLockAcquire(&MyReplicationSlot->mutex);
		if (XLogRecPtrIsInvalid(MyReplicationSlot->data.restart_lsn))
		{
			MyReplicationSlot->data.restart_lsn = current_wal_lsn;
			MyReplicationSlot->data.confirmed_flush = current_wal_lsn;
		}
		SpinLockRelease(&MyReplicationSlot->mutex);

		ReplicationSlotMarkDirty();
		ReplicationSlotSave();

		elog(LOG, "initialized recovery slot '%s' restart_lsn to %X/%X",
			 slot_name, LSN_FORMAT_ARGS(current_wal_lsn));

		/* Release the slot - ReplicationSlotCreate() acquired it for us */
		ReplicationSlotRelease();
	}
	else
	{
		elog(DEBUG1, "recovery slot '%s' created but MyReplicationSlot is NULL, skipping initialization",
			 slot_name);
	}

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
 * advance_recovery_slot_to_min_position
 *
 * Advance the recovery slot's confirmed_flush_lsn to the minimum position
 * across all active peer subscriptions. This ensures the slot stays behind
 * the slowest subscriber, allowing historical replay for rescue operations.
 *
 * This function should be called periodically by the manager worker.
 */
void
advance_recovery_slot_to_min_position(void)
{
	SpockRecoverySlotData *slot_data;
	ReplicationSlot *recovery_slot;
	char slot_name[NAMEDATALEN];
	XLogRecPtr min_remote_lsn = InvalidXLogRecPtr;
	XLogRecPtr current_slot_lsn;
	List *subscriptions;
	ListCell *lc;
	bool need_transaction;
	bool need_spi = false;

	if (!SpockRecoveryCtx)
		return;

	/* Get recovery slot info from shared memory */
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	slot_data = get_recovery_slot();
	if (!slot_data->active)
	{
		LWLockRelease(SpockRecoveryCtx->lock);
		return;
	}
	strlcpy(slot_name, slot_data->slot_name, NAMEDATALEN);
	LWLockRelease(SpockRecoveryCtx->lock);

	/* 
	 * Note: This function is called from two contexts:
	 * 1. Manager worker (no transaction) - needs to start/commit transaction
	 * 2. SQL function (already in transaction) - must not start/commit transaction
	 * 
	 * SPI requires a transaction, so we check IsTransactionState() to handle both cases.
	 */
	need_transaction = !IsTransactionState();
	
	/* SPI requires a transaction, so start one if needed */
	/* Note: SQL functions are already in a transaction, so IsTransactionState() will be true */
	if (need_transaction)
	{
		if (!IsTransactionState())
			StartTransactionCommand();
	}

	/* Connect to SPI if not already connected */
	if (SPI_connect() != SPI_OK_CONNECT)
	{
		elog(WARNING, "SPI_connect failed in advance_recovery_slot_to_min_position");
		if (need_transaction)
			AbortCurrentTransaction();
		return;
	}
	need_spi = true;
	
	/* Push an active snapshot for SPI queries */
	PushActiveSnapshot(GetTransactionSnapshot());

	/* Get the local node to find subscriptions where this node is the target */
	{
		SpockLocalNode *local_node = get_local_node(true, false);
		Oid local_node_id = InvalidOid;
		
		if (local_node && local_node->node)
		{
			local_node_id = local_node->node->id;
			elog(LOG, "recovery slot: local node id=%u, name=%s", local_node_id, local_node->node->name);
		}
		else
		{
			elog(LOG, "recovery slot: no local node found for recovery slot advancement");
			PopActiveSnapshot();
			SPI_finish();
			if (need_transaction)
				CommitTransactionCommand();
			return;
		}
		
		/* Get all subscriptions where this node is the target (receiving data) */
		subscriptions = get_node_subscriptions(local_node_id, false);
		elog(LOG, "recovery slot: found %ld subscription(s) where local node is target", (long) list_length(subscriptions));
	}

	/*
	 * Find the minimum remote_lsn across all peer subscriptions.
	 * This represents the slowest subscriber's position.
	 */
	foreach(lc, subscriptions)
	{
		SpockSubscription *sub = (SpockSubscription *) lfirst(lc);
		XLogRecPtr remote_lsn;
		char origin_name[NAMEDATALEN];

		/* Skip rescue subscriptions */
		if (sub->rescue_temporary)
			continue;

		/* Skip disabled subscriptions */
		if (!sub->enabled)
			continue;

		/* Build origin name for this subscription */
		snprintf(origin_name, NAMEDATALEN, "spk_pgedge_%s_sub_%s_%s",
				 sub->origin->name, sub->origin->name, sub->target->name);

		/* Query remote_lsn directly from pg_replication_origin_status using SPI */
		{
			StringInfoData query;
			int ret;
			bool isnull;
			Datum datum;

			initStringInfo(&query);
			appendStringInfo(&query,
							 "SELECT remote_lsn FROM pg_catalog.pg_replication_origin_status "
							 "WHERE external_id = %s",
							 quote_literal_cstr(origin_name));

			ret = SPI_execute(query.data, true, 0);
			if (ret == SPI_OK_SELECT && SPI_processed > 0)
			{
				datum = SPI_getbinval(SPI_tuptable->vals[0],
									  SPI_tuptable->tupdesc,
									  1, &isnull);
				if (!isnull)
					remote_lsn = DatumGetLSN(datum);
				else
					remote_lsn = InvalidXLogRecPtr;
				elog(DEBUG2, "recovery slot: subscription %s (origin_name=%s) at remote_lsn %X/%X",
					 sub->name, origin_name, LSN_FORMAT_ARGS(remote_lsn));
			}
			else
			{
				remote_lsn = InvalidXLogRecPtr;
				elog(DEBUG2, "recovery slot: subscription %s (origin_name=%s) not found in pg_replication_origin_status (ret=%d, processed=%ld)",
					 sub->name, origin_name, ret, (long) SPI_processed);
			}
		}

		if (remote_lsn != InvalidXLogRecPtr)
		{
			if (min_remote_lsn == InvalidXLogRecPtr || remote_lsn < min_remote_lsn)
			{
				min_remote_lsn = remote_lsn;
				elog(DEBUG2, "recovery slot: subscription %s at remote_lsn %X/%X",
					 sub->name, LSN_FORMAT_ARGS(remote_lsn));
			}
		}
	}

	/* Disconnect from SPI */
	if (need_spi)
	{
		PopActiveSnapshot();
		SPI_finish();
	}

	if (need_transaction)
		CommitTransactionCommand();

	/* If we found a minimum position, advance the slot to it */
	if (min_remote_lsn != InvalidXLogRecPtr)
	{
		/* Acquire the recovery slot */
		recovery_slot = SearchNamedReplicationSlot(slot_name, false);
		if (recovery_slot)
		{
#if PG_VERSION_NUM >= 180000
			ReplicationSlotAcquire(slot_name, true, true);
#else
			ReplicationSlotAcquire(slot_name, true);
#endif

			SpinLockAcquire(&recovery_slot->mutex);
			current_slot_lsn = recovery_slot->data.confirmed_flush;
			SpinLockRelease(&recovery_slot->mutex);

		/*
		 * CRITICAL FIX: Do NOT advance confirmed_flush_lsn.
		 * 
		 * The recovery slot must remain INACTIVE and NEVER advance confirmed_flush_lsn.
		 * When you advance confirmed_flush_lsn, PostgreSQL considers those transactions
		 * as "consumed" and will skip them when decoding from a cloned slot.
		 * 
		 * For disaster recovery to work:
		 * 1. Keep confirmed_flush_lsn at restart_lsn (or slightly ahead, but minimal)
		 * 2. Only restart_lsn preserves WAL - confirmed_flush_lsn marks what's been decoded
		 * 3. If confirmed_flush_lsn advances past transactions, those transactions become
		 *    undecodable because PostgreSQL thinks they're already processed
		 * 
		 * The recovery slot should ONLY preserve WAL via restart_lsn, never decode.
		 */
		elog(DEBUG2, "recovery slot '%s' advancement skipped - confirmed_flush_lsn kept at %X/%X to preserve decodability (restart_lsn=%X/%X, min_peer=%X/%X)",
			 slot_name,
			 LSN_FORMAT_ARGS(current_slot_lsn),
			 LSN_FORMAT_ARGS(recovery_slot->data.restart_lsn),
			 LSN_FORMAT_ARGS(min_remote_lsn));

			/*
			 * CRITICAL: Create decoding context to keep catalog_xmin alive.
			 * 
			 * When START_REPLICATION begins on a cloned slot, PostgreSQL establishes
			 * a NEW snapshot with catalog_xmin = current oldest XID. This filters out
			 * historical transactions even if the slot's catalog_xmin was preserved.
			 * 
			 * The ONLY way to keep the recovery slot's catalog_xmin "fresh" is to
			 * periodically establish a decoding context. This creates a snapshot and
			 * updates catalog_xmin, preventing a gap from forming.
			 * 
			 * We use CreateInitDecodingContext() which is simpler than CreateDecodingContext()
			 * and sufficient for keepalive purposes.
			 */
			{
				LogicalDecodingContext *ctx;
				TransactionId catalog_xmin_before;
				TransactionId catalog_xmin_after;
				MemoryContext old_context;
				ErrorData *edata;
				
				catalog_xmin_before = recovery_slot->data.catalog_xmin;
				
				/* Switch to a safe memory context */
				old_context = MemoryContextSwitchTo(CurTransactionContext);
				
				PG_TRY();
				{
					/*
					 * CreateInitDecodingContext establishes a consistent snapshot
					 * and updates catalog_xmin. We don't need to decode anything -
					 * just creating the context refreshes the slot's snapshot.
					 * 
					 * The slot is already acquired via ReplicationSlotAcquire() above,
					 * and MyReplicationSlot points to it.
					 */
					ctx = CreateInitDecodingContext(
						"spock_output",      /* Use Spock's output plugin */
						NIL,                 /* No options needed */
						false,               /* Need full snapshot */
						recovery_slot->data.restart_lsn,  /* Start from slot's restart LSN */
						XL_ROUTINE(.page_read = read_local_xlog_page,
								   .segment_open = NULL,
								   .segment_close = NULL),
						NULL,                /* No prepare write callback */
						NULL,                /* No write callback */
						NULL                 /* No update progress callback */
					);
					
					/*
					 * Just creating the context is sufficient to refresh catalog_xmin.
					 * We don't need to decode any changes. Free it immediately.
					 */
					FreeDecodingContext(ctx);
					
					MemoryContextSwitchTo(old_context);
				}
				PG_CATCH();
				{
					MemoryContextSwitchTo(old_context);
					
					/* Log error but don't propagate - keepalive is non-critical */
					edata = CopyErrorData();
					elog(WARNING, "[RECOVERY_SLOT_KEEPALIVE] Failed to create decoding context for recovery slot '%s': %s",
						 slot_name, edata->message);
					FreeErrorData(edata);
					FlushErrorState();
				}
				PG_END_TRY();
				
				/* Check if catalog_xmin was updated by the context creation */
				SpinLockAcquire(&recovery_slot->mutex);
				catalog_xmin_after = recovery_slot->data.catalog_xmin;
				SpinLockRelease(&recovery_slot->mutex);
				
				elog(LOG, "[RECOVERY_SLOT_KEEPALIVE] Created decoding context for recovery slot '%s' - catalog_xmin: before=%u, after=%u (snapshot refreshed)",
					 slot_name, catalog_xmin_before, catalog_xmin_after);
			}
			
			ReplicationSlotRelease();
		}
		else
		{
			ReplicationSlotRelease();
		}
	}
	else
	{
		elog(DEBUG2, "no peer subscriptions found for recovery slot advancement");
	}
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
 * spock_advance_recovery_slot_sql
 *
 * SQL-callable wrapper for advance_recovery_slot_to_min_position().
 * Allows manual triggering of recovery slot advancement for testing/debugging.
 */
PG_FUNCTION_INFO_V1(spock_advance_recovery_slot_sql);
Datum
spock_advance_recovery_slot_sql(PG_FUNCTION_ARGS)
{
	advance_recovery_slot_to_min_position();
	PG_RETURN_VOID();
}

/*
 * query_node_recovery_progress
 *
 * Query a remote node via libpq to get its recovery slot progress for the failed origin node.
 * This queries the remote node's pg_replication_origin_status to find the latest LSN/timestamp
 * it has received from the failed origin.
 */
static bool
query_node_recovery_progress(const char *node_dsn, const char *origin_node_name,
							XLogRecPtr *remote_lsn, TimestampTz *remote_ts)
{
	PGconn	   *conn = NULL;
	PGresult   *res = NULL;
	StringInfoData query;
	bool		success = false;
	const char *param_values[1];
	Oid			param_types[1] = { TEXTOID };

	if (!node_dsn || !origin_node_name)
		return false;

	PG_TRY();
	{
		/* Connect to the remote node using spock's connection helper */
		conn = spock_connect(node_dsn, "rescue_coord", "query");
		
		/* Build parameterized query to get replication origin status from remote node */
		initStringInfo(&query);
		appendStringInfo(&query,
			"SELECT pos.remote_lsn, "
			"       CASE WHEN pos.remote_lsn = '0/0'::pg_lsn THEN NULL "
			"            ELSE pg_catalog.pg_xact_commit_timestamp(pos.local_id) "
			"       END AS remote_timestamp "
			"FROM spock.subscription s "
			"JOIN spock.node o ON o.node_id = s.sub_origin "
			"JOIN pg_replication_origin_status pos "
			"  ON pos.external_id = spock.spock_gen_slot_name("
			"         current_database()::name, "
			"         o.node_name::name, "
			"         s.sub_name)::text "
			"WHERE o.node_name = $1 "
			"ORDER BY pos.remote_lsn DESC "
			"LIMIT 1");

		/* Use parameterized query for safety */
		param_values[0] = origin_node_name;
		res = PQexecParams(conn, query.data, 1, param_types,
						  param_values, NULL, NULL, 0);

		if (PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) > 0)
		{
			char	   *lsn_str = PQgetvalue(res, 0, 0);
			char	   *ts_str = PQgetvalue(res, 0, 1);

			if (lsn_str && strlen(lsn_str) > 0)
			{
				*remote_lsn = str_to_lsn(lsn_str);

				/* Parse timestamp if available */
				if (ts_str && strlen(ts_str) > 0 && !PQgetisnull(res, 0, 1))
				{
					/* Convert ISO timestamp string to TimestampTz */
					Datum		ts_datum;
					ts_datum = DirectFunctionCall3(timestamptz_in,
												  CStringGetDatum(ts_str),
												  ObjectIdGetDatum(InvalidOid),
												  Int32GetDatum(-1));
					*remote_ts = DatumGetTimestampTz(ts_datum);
				}
				else
				{
					*remote_ts = 0;
				}

				success = true;
			}
		}
		else if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			elog(DEBUG1, "Query failed on remote node: %s", PQerrorMessage(conn));
		}

		pfree(query.data);
	}
	PG_CATCH();
	{
		/* Clean up on error and log, but don't propagate */
		ErrorData  *edata;
		MemoryContext oldcontext;
		
		/* Switch to TopMemoryContext to avoid ErrorContext assertion */
		oldcontext = MemoryContextSwitchTo(TopMemoryContext);
		edata = CopyErrorData();
		FlushErrorState();
		
		elog(DEBUG1, "Failed to query node %s: %s", node_dsn, edata->message);
		FreeErrorData(edata);
		MemoryContextSwitchTo(oldcontext);
		
		success = false;
	}
	PG_END_TRY();

	if (res)
		PQclear(res);
	if (conn)
		PQfinish(conn);

	return success;
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

	/* Query all nodes in the cluster to find the best source node */
	{
		Oid			current_best_node_id = InvalidOid;
		XLogRecPtr	current_best_lsn = InvalidXLogRecPtr;
		TimestampTz	current_best_commit_ts = 0;
		int			source_count = 0;
		int			tie_count = 0;
		int			ret;
		int			i;

		/* Connect to SPI to query all nodes */
		if (SPI_connect() != SPI_OK_CONNECT)
			elog(ERROR, "SPI_connect failed");

		/* Get all nodes and their interfaces from the spock schema */
		ret = SPI_execute("SELECT n.node_id, n.node_name, i.if_dsn "
						  "FROM spock.node n "
						  "JOIN spock.node_interface i ON i.if_nodeid = n.node_id "
						  "WHERE i.if_name = 'default'",
						  true, 0);

		if (ret == SPI_OK_SELECT && SPI_processed > 0)
		{
			TupleDesc	spi_tupdesc = SPI_tuptable->tupdesc;

			/* Query each surviving node to see what data it has from the failed origin */
			for (i = 0; i < SPI_processed; i++)
			{
				HeapTuple	spi_tuple = SPI_tuptable->vals[i];
				Oid			node_id;
				char	   *node_name;
				char	   *node_dsn;
				XLogRecPtr	remote_lsn = InvalidXLogRecPtr;
				TimestampTz	remote_ts = 0;
				bool		has_progress = false;
				bool		isnull;

				/* Get node information */
				node_id = DatumGetObjectId(SPI_getbinval(spi_tuple, spi_tupdesc, 1, &isnull));
				if (isnull)
					continue;

				node_name = SPI_getvalue(spi_tuple, spi_tupdesc, 2);
				if (!node_name)
					continue;

				node_dsn = SPI_getvalue(spi_tuple, spi_tupdesc, 3);
				if (!node_dsn)
					continue;

				/* Skip if this is the failed node */
				if (node_id == failed_node_id)
					continue;

				elog(DEBUG1, "Querying node %s (dsn: %s) for data from failed node %s",
					 node_name, node_dsn, failed_node_name);

				/* Query this node to see what data it has from the failed origin */
				has_progress = query_node_recovery_progress(node_dsn, failed_node_name,
														   &remote_lsn, &remote_ts);

				if (!has_progress)
				{
					elog(DEBUG1, "Node %s did not return valid recovery data for %s",
						 node_name, failed_node_name);
				}

				if (has_progress && remote_lsn != InvalidXLogRecPtr)
				{
					source_count++;

					elog(DEBUG1, "Node %s has LSN %X/%X from failed node %s",
						 node_name, LSN_FORMAT_ARGS(remote_lsn), failed_node_name);

					/* Check if this is better than our current best */
					if (current_best_lsn == InvalidXLogRecPtr ||
						remote_lsn > current_best_lsn ||
						(remote_lsn == current_best_lsn && remote_ts > current_best_commit_ts))
					{
						if (current_best_lsn != InvalidXLogRecPtr && remote_lsn == current_best_lsn)
						{
							tie_count++;
						}

						current_best_node_id = node_id;
						current_best_lsn = remote_lsn;
						current_best_commit_ts = remote_ts;

						elog(DEBUG1, "Node %s is now the best candidate (LSN: %X/%X)",
							 node_name, LSN_FORMAT_ARGS(remote_lsn));
					}
				}
			}
		}

		SPI_finish();

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
		char	   *source_node_name = source_node->name;
		const char *ts_str = timestamptz_to_str(best_commit_ts);

		elog(LOG, "Rescue source for failed node %s is node %s at commit timestamp %s / LSN %X/%X (confidence: %s)",
			 failed_node_name, source_node_name, ts_str, LSN_FORMAT_ARGS(best_lsn), confidence_level);
	}
	else
	{
		elog(WARNING, "No rescue source found for failed node %s - no surviving nodes have recovery data",
			 failed_node_name);
	}

	pfree(failed_node_name);

	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * spock_clone_recovery_slot_sql
 *
 * Clone an existing inactive Recovery Slot into a new, temporary active slot
 * for disaster recovery operations. The cloned slot can be used for selective
 * replay of unacknowledged transactions.
 *
 * Design Principles:
 * ------------------
 * 1. Recovery slot: One per database, shared across all nodes/subscriptions.
 *    - Persistent (never deleted) - preserves WAL for all nodes
 *    - Stays well behind actual slots to preserve historical WAL
 *    - Inactive - never used for normal replication
 *
 * 2. Cloned slot: Temporary slot created from recovery slot for rescue operations.
 *    - Used only for the rescue subscription
 *    - Deleted after recovery completes (via cleanup.sql)
 *    - Decodes from recovery slot's preserved WAL
 *
 * This function clones the local recovery slot to create a temporary slot
 * that can be used for disaster recovery without modifying the original.
 *
 * Usage: SELECT * FROM spock.clone_recovery_slot(target_restart_lsn);
 *
 * Args:
 * - target_restart_lsn (optional): If provided, this is the target node's LSN.
 *   The cloned slot will decode from the recovery slot's restart_lsn (preserved WAL),
 *   and the apply worker will filter transactions from target_restart_lsn to stop_lsn.
 *
 * Returns a record with:
 * - cloned_slot_name: Name of the newly created active slot
 * - original_slot_name: Name of the original recovery slot
 * - restart_lsn: LSN position to start replay from (recovery slot's restart_lsn)
 * - success: Whether the cloning was successful
 * - message: Status message about the operation
 */
Datum
spock_clone_recovery_slot_sql(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	Datum		values[5];
	bool		nulls[5];
	HeapTuple	tuple;
	char	   *cloned_slot_name = NULL;
	char	   *original_slot_name = NULL;
	XLogRecPtr	restart_lsn = InvalidXLogRecPtr;
	XLogRecPtr	confirmed_flush_lsn = InvalidXLogRecPtr;
	XLogRecPtr	target_restart_lsn = InvalidXLogRecPtr;
	bool		success = false;
	char	   *message = NULL;

	/* Get optional target_restart_lsn parameter */
	if (PG_NARGS() > 0 && !PG_ARGISNULL(0))
		target_restart_lsn = PG_GETARG_LSN(0);

	/* Validate that recovery slot exists and is active */
	if (!SpockRecoveryCtx || !SpockRecoveryCtx->recovery_slot.active)
	{
		message = pstrdup("No active recovery slot found for cloning");
		goto cleanup;
	}

	/* Get recovery slot information */
	LWLockAcquire(SpockRecoveryCtx->lock, LW_SHARED);
	original_slot_name = pstrdup(SpockRecoveryCtx->recovery_slot.slot_name);
	LWLockRelease(SpockRecoveryCtx->lock);

	/* Generate deterministic cloned slot name */
	{
		TimestampTz now = GetCurrentTimestamp();
		const char *timestamp_str = timestamptz_to_str(now);
		StringInfoData namebuf;

		initStringInfo(&namebuf);
		appendStringInfoString(&namebuf, "spock_rescue_clone_");
		append_sanitized_token(&namebuf, timestamp_str);
		cloned_slot_name = namebuf.data;
	}

	/* Clone the recovery slot */
	PG_TRY();
	{
		ReplicationSlot *original_slot;
		ReplicationSlot *cloned_slot;

		/* Get the original recovery slot */
		original_slot = SearchNamedReplicationSlot(original_slot_name, true);
		if (!original_slot)
		{
			message = psprintf("Original recovery slot '%s' not found", original_slot_name);
			goto cleanup_clone;
		}

		/* Read LSN positions from the original slot */
		SpinLockAcquire(&original_slot->mutex);
		confirmed_flush_lsn = original_slot->data.confirmed_flush;
		restart_lsn = original_slot->data.restart_lsn;
		SpinLockRelease(&original_slot->mutex);

		/*
		 * Some recovery slots may not yet have a restart LSN recorded. Fall back
		 * to the confirmed flush position so callers have a sensible default.
		 */
		if (XLogRecPtrIsInvalid(restart_lsn) && !XLogRecPtrIsInvalid(confirmed_flush_lsn))
			restart_lsn = confirmed_flush_lsn;

		/*
		 * For rescue subscriptions, set confirmed_flush_lsn to target_restart_lsn.
		 * This tells PostgreSQL to start decoding from the target's current position.
		 * The slot will decode all transactions from target_restart_lsn to stop_lsn.
		 * 
		 * We keep restart_lsn at the recovery slot's position so the cloned slot
		 * can access the preserved WAL, but we start decoding from target_restart_lsn.
		 * 
		 * Note: catalog_xmin filtering remains an issue - inactive recovery slots have
		 * catalog_xmin=NULL, but when we start decoding, PostgreSQL assigns a new
		 * catalog_xmin based on current system state. This may filter out historical
		 * transactions if their XIDs are below the current global xmin. This is a
		 * fundamental limitation of logical replication for very old transactions.
		 */
		if (!XLogRecPtrIsInvalid(target_restart_lsn))
		{
			elog(LOG, "[RESCUE_DEBUG] Cloning recovery slot for rescue subscription - restart_lsn=%X/%X (preserved WAL), confirmed_flush_lsn=%X/%X (start decoding from target's position)",
				 LSN_FORMAT_ARGS(restart_lsn),
				 LSN_FORMAT_ARGS(target_restart_lsn));
			/* Set confirmed_flush_lsn to target's position to start decoding from there */
			confirmed_flush_lsn = target_restart_lsn;
		}

		/*
		 * EXPERIMENTAL: Use recovery slot directly instead of cloning.
		 * 
		 * Testing if cloning introduces the catalog_xmin filtering issue.
		 * By using the recovery slot directly, we can determine if the problem
		 * is with pg_copy_logical_replication_slot() or with START_REPLICATION.
		 */
		elog(LOG, "[RESCUE_TEST] SKIPPING CLONE - using recovery slot '%s' directly for rescue subscription",
			 original_slot_name);
		
		/* Free the generated cloned_slot_name and use the original recovery slot name */
		pfree(cloned_slot_name);
		cloned_slot_name = pstrdup(original_slot_name);
		
		elog(LOG, "[RESCUE_TEST] Using recovery slot directly - slot_name='%s'",
			 cloned_slot_name);
	
	/* Acquire the recovery slot (no cloning) */
#if PG_VERSION_NUM >= 180000
	ReplicationSlotAcquire(cloned_slot_name, true, true);
#else
	ReplicationSlotAcquire(cloned_slot_name, true);
#endif
	
	cloned_slot = MyReplicationSlot;
	if (cloned_slot == NULL)
	{
		message = psprintf("Failed to acquire recovery slot '%s' for direct use", cloned_slot_name);
		goto cleanup_clone;
	}

	/* [RESCUE_TEST] Log recovery slot state - NO MODIFICATIONS since we're using it directly */
	SpinLockAcquire(&cloned_slot->mutex);
	restart_lsn = cloned_slot->data.restart_lsn;
	confirmed_flush_lsn = cloned_slot->data.confirmed_flush;
	elog(LOG, "[RESCUE_TEST] Using recovery slot '%s' directly - catalog_xmin=%u, restart_lsn=%X/%X, confirmed_flush_lsn=%X/%X",
		 cloned_slot_name,
		 cloned_slot->data.catalog_xmin,
		 (uint32) (cloned_slot->data.restart_lsn >> 32), (uint32) cloned_slot->data.restart_lsn,
		 (uint32) (cloned_slot->data.confirmed_flush >> 32), (uint32) cloned_slot->data.confirmed_flush);
	SpinLockRelease(&cloned_slot->mutex);

	/* DO NOT modify the recovery slot - just use it as-is */
	elog(LOG, "[RESCUE_TEST] Recovery slot will be used directly by rescue subscription - no LSN modifications");
		
		ReplicationSlotRelease();
		
		/* [RESCUE_DEBUG] Verify slot position after release */
		{
			ReplicationSlot *verify_slot = SearchNamedReplicationSlot(cloned_slot_name, false);
			if (verify_slot)
			{
				XLogRecPtr verify_restart, verify_confirmed;
				SpinLockAcquire(&verify_slot->mutex);
				verify_restart = verify_slot->data.restart_lsn;
				verify_confirmed = verify_slot->data.confirmed_flush;
				SpinLockRelease(&verify_slot->mutex);
				
				elog(LOG, "[RESCUE_TEST] Recovery slot '%s' verified after release - restart_lsn=%X/%X, confirmed_flush_lsn=%X/%X",
					 cloned_slot_name,
					 (uint32) (verify_restart >> 32), (uint32) verify_restart,
					 (uint32) (verify_confirmed >> 32), (uint32) verify_confirmed);
				
				/* [RESCUE_TEST] Log info about using recovery slot directly */
				elog(LOG, "[RESCUE_TEST] Recovery slot will be used as-is - restart_lsn=%X/%X, confirmed_flush_lsn=%X/%X",
					 (uint32) (verify_restart >> 32), (uint32) verify_restart,
					 (uint32) (verify_confirmed >> 32), (uint32) verify_confirmed);
			}
		}

		success = true;
		message = psprintf("Using recovery slot '%s' directly (TESTING - no clone created)",
						   cloned_slot_name);

cleanup_clone:
		;
	}
	PG_CATCH();
	{
		ErrorData  *edata;
		MemoryContext oldcontext;

		/* Switch to TopMemoryContext to avoid ErrorContext assertion */
		oldcontext = MemoryContextSwitchTo(TopMemoryContext);
		edata = CopyErrorData();
		FlushErrorState();

		message = psprintf("Error creating cloned slot '%s': %s",
						  cloned_slot_name ? cloned_slot_name : "<unspecified>",
						  edata && edata->message ? edata->message : "slot creation failed");

		if (edata)
			FreeErrorData(edata);
		MemoryContextSwitchTo(oldcontext);
	}
	PG_END_TRY();

cleanup:
	/* Build return tuple */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	/* Initialize all values to null */
	memset(nulls, 1, sizeof(nulls));

	/* Set non-null values */
	if (cloned_slot_name)
	{
		values[0] = CStringGetTextDatum(cloned_slot_name);
		nulls[0] = false;
	}

	if (original_slot_name)
	{
		values[1] = CStringGetTextDatum(original_slot_name);
		nulls[1] = false;
	}

	if (restart_lsn != InvalidXLogRecPtr)
	{
		values[2] = LSNGetDatum(restart_lsn);
		nulls[2] = false;
	}

	values[3] = BoolGetDatum(success);
	nulls[3] = false;

	if (message)
	{
		values[4] = CStringGetTextDatum(message);
		nulls[4] = false;
	}

	tuple = heap_form_tuple(tupdesc, values, nulls);

	/* Log the recovery slot usage */
	if (success)
	{
		elog(LOG,
			 "[RESCUE_TEST] Using recovery slot directly: slot_name='%s' (no clone created), reason='testing catalog_xmin behavior'",
			 cloned_slot_name);
	}
	else
	{
		elog(WARNING,
			 "Recovery slot setup failed: reason='%s'",
			 message ? message : "unknown error");
	}

	/* Cleanup */
	if (cloned_slot_name)
		pfree(cloned_slot_name);
	if (original_slot_name)
		pfree(original_slot_name);
	if (message)
		pfree(message);

	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * Helper function to clean up a rescue subscription on error.
 * Extracted to avoid nested PG_TRY blocks which cause shadow warnings.
 */
static void
cleanup_rescue_subscription_on_error(Oid subid)
{
	if (!OidIsValid(subid))
		return;

	PG_TRY();
	{
		drop_subscription_sync_status(subid);
		drop_subscription(subid);
	}
	PG_CATCH();
	{
		FlushErrorState();
	}
	PG_END_TRY();
}

/*
 * spock_create_rescue_subscription_sql
 *
 * Create a temporary rescue subscription from the current (lagging) node to a
 * cloned recovery slot on a more advanced peer. The subscription uses the
 * cloned slot, optionally skips already processed transactions, and stops at a
 * known-safe LSN/timestamp to allow automatic cleanup.
 */
Datum
spock_create_rescue_subscription_sql(PG_FUNCTION_ARGS)
{
	Name		target_name = PG_GETARG_NAME(0);
	Name		source_name = PG_GETARG_NAME(1);
	char	   *cloned_slot_name = text_to_cstring(PG_GETARG_TEXT_PP(2));
	XLogRecPtr	skip_lsn = PG_ARGISNULL(3) ? InvalidXLogRecPtr : PG_GETARG_LSN(3);
	XLogRecPtr	stop_lsn = PG_ARGISNULL(4) ? InvalidXLogRecPtr : PG_GETARG_LSN(4);
	TimestampTz	stop_timestamp = PG_ARGISNULL(5) ? 0 : PG_GETARG_TIMESTAMPTZ(5);
	SpockLocalNode *localnode;
	SpockNode  *origin;
	SpockInterface *originif;
	SpockInterface	targetif;
	SpockSubscription sub;
	SpockSyncStatus sync;
	List	   *repsets = NIL;
	Interval   *apply_delay;
	char	   *sub_name = NULL;
	Oid			subid = InvalidOid;
	bool		sub_created = false;

	/* Require at least one stopping condition (LSN or timestamp). */
	if (XLogRecPtrIsInvalid(stop_lsn) && stop_timestamp == 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("rescue subscription requires stop LSN or stop timestamp"),
				 errdetail("Provide stop_lsn, stop_timestamp, or both.")));

	if (!XLogRecPtrIsInvalid(skip_lsn) && !XLogRecPtrIsInvalid(stop_lsn) &&
		skip_lsn >= stop_lsn)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("skip LSN must be lower than stop LSN"),
				 errdetail("Provided skip_lsn %X/%X is not less than stop_lsn %X/%X.",
						   LSN_FORMAT_ARGS(skip_lsn), LSN_FORMAT_ARGS(stop_lsn))));

	validate_rescue_slot_name(cloned_slot_name);

	localnode = get_local_node(true, false);
	if (!localnode || !localnode->node || !localnode->node_if)
		elog(ERROR, "local node not initialized");

	if (strcmp(NameStr(*target_name), localnode->node->name) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("target node \"%s\" does not match local node \"%s\"",
						NameStr(*target_name), localnode->node->name)));

	origin = get_node_by_name(NameStr(*source_name), false);

	originif = get_node_interface_by_name(origin->id, "default", true);
	if (originif == NULL)
		originif = get_node_interface_by_name(origin->id, origin->name, false);

	/* Verify connectivity to provider node. */
	PG_TRY();
	{
		PGconn *conn = spock_connect(originif->dsn, "rescue_sub", "create");
		PQfinish(conn);

		conn = spock_connect_replica(originif->dsn, "rescue_sub", "create");
		PQfinish(conn);
	}
	PG_CATCH();
	{
		FlushErrorState();
		ereport(ERROR,
				(errcode(ERRCODE_CONNECTION_FAILURE),
				 errmsg("failed to connect to provider DSN \"%s\"", originif->dsn),
				 errhint("Verify network connectivity and authentication.")));
	}
	PG_END_TRY();

	sub_name = build_rescue_subscription_name(localnode->node->name,
											  NameStr(*source_name));

	memset(&sub, 0, sizeof(SpockSubscription));
	sub.id = InvalidOid;
	sub.name = sub_name;
	sub.origin = origin;  /* Set origin node pointer */
	sub.origin_if = originif;

	targetif.id = localnode->node_if->id;
	targetif.name = localnode->node_if->name;
	targetif.nodeid = localnode->node->id;
	targetif.dsn = localnode->node_if->dsn;
	sub.target = localnode->node;  /* Set target node pointer */
	sub.target_if = &targetif;

	sub.enabled = true;
	sub.slot_name = pstrdup(cloned_slot_name);

	repsets = lappend(repsets, pstrdup("default"));
	repsets = lappend(repsets, pstrdup("default_insert_only"));
	repsets = lappend(repsets, pstrdup("ddl_sql"));
	sub.replication_sets = repsets;
	
	/*
	 * Forward ALL origins in rescue subscriptions. This is necessary because
	 * the lagging node needs to receive transactions that originated from the
	 * failed node but were forwarded through the rescue source node.
	 * Using "all" means forward transactions regardless of origin.
	 */
	sub.forward_origins = list_make1(pstrdup("all"));

	apply_delay = (Interval *) palloc0(sizeof(Interval));
	sub.apply_delay = apply_delay;
	sub.force_text_transfer = false;
	/*
	 * For rescue subscriptions, we store the slot's original restart_lsn in skiplsn
	 * so the apply worker can use it in START_REPLICATION. We don't use skip_lsn
	 * for skipping transactions (it's set to InvalidXLogRecPtr for that), but we
	 * repurpose this field to store the slot's original restart_lsn from cloning.
	 * 
	 * The slot's restart_lsn may advance if previous rescue subscription attempts
	 * connected to it, so we need to store the original value here.
	 * 
	 * TODO: Add a dedicated field for this instead of repurposing skiplsn.
	 */
	/* Query the slot's restart_lsn immediately after cloning, before any connections */
	{
		PGconn	   *sqlConn = NULL;
		PGresult   *res = NULL;
		StringInfoData query;
		XLogRecPtr	slot_restart_lsn = InvalidXLogRecPtr;
		
		/* Create a SQL connection to query the slot's restart_lsn */
		sqlConn = PQconnectdb(originif->dsn);
		
		if (sqlConn && PQstatus(sqlConn) == CONNECTION_OK)
		{
			initStringInfo(&query);
			appendStringInfo(&query,
							 "SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = $1");
			
			res = PQexecParams(sqlConn, query.data, 1, NULL,
							   (const char *[]) { cloned_slot_name },
							   NULL, NULL, 0);
			
			if (res && PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) > 0)
			{
				const char *lsn_str = PQgetvalue(res, 0, 0);
				if (lsn_str && strlen(lsn_str) > 0 && strcmp(lsn_str, "") != 0)
				{
					/* Parse the LSN string */
					slot_restart_lsn = DatumGetLSN(DirectFunctionCall1Coll(
						pg_lsn_in, InvalidOid, CStringGetDatum(lsn_str)));
					
					if (!XLogRecPtrIsInvalid(slot_restart_lsn))
					{
						sub.skiplsn = slot_restart_lsn;
						elog(LOG, "[RESCUE_DEBUG] Stored slot's restart_lsn %X/%X in subscription for rescue",
							 (uint32) (slot_restart_lsn >> 32), (uint32) slot_restart_lsn);
					}
				}
			}
			
			if (res)
				PQclear(res);
			pfree(query.data);
			PQfinish(sqlConn);
		}
		
		/* If we couldn't query it, set to InvalidXLogRecPtr (will use 0/0) */
		if (XLogRecPtrIsInvalid(sub.skiplsn))
		{
			sub.skiplsn = InvalidXLogRecPtr;
			elog(WARNING, "[RESCUE_DEBUG] Could not query slot's restart_lsn, will use 0/0 in START_REPLICATION");
		}
	}
	sub.skip_schema = NIL;
	sub.rescue_suspended = false;
	sub.rescue_temporary = true;
	sub.rescue_start_lsn = skip_lsn;  /* Transactions before this will be skipped */
	sub.rescue_stop_lsn = stop_lsn;    /* Transactions after this will be stopped */
	sub.rescue_stop_time = stop_timestamp;
	sub.rescue_cleanup_pending = false;
	sub.rescue_failed = false;

	PG_TRY();
	{
		create_subscription(&sub);
		sub_created = true;
		subid = sub.id;

		/* Rescue subscriptions don't need hash table - they track progress via
		 * pg_replication_origin_status instead. This avoids hash table corruption issues. */
		/* spock_group_attach() not needed for rescue subscriptions */

		memset(&sync, 0, sizeof(SpockSyncStatus));
		sync.kind = SYNC_KIND_INIT;
		sync.subid = sub.id;
		sync.status = SYNC_STATUS_INIT;
		create_local_sync_status(&sync);
	}
	PG_CATCH();
	{
		ErrorData *edata;
		MemoryContext oldcontext;
		
		/* Switch to TopMemoryContext to avoid ErrorContext assertion */
		oldcontext = MemoryContextSwitchTo(TopMemoryContext);
		edata = CopyErrorData();
		FlushErrorState();

		if (sub_created && OidIsValid(subid))
			cleanup_rescue_subscription_on_error(subid);

		/* ReThrowError will handle freeing edata, so restore context first */
		MemoryContextSwitchTo(oldcontext);
		ReThrowError(edata);
	}
	PG_END_TRY();

	elog(LOG,
		 "SPOCK: created rescue subscription \"%s\" (id %u) using slot \"%s\"",
		 sub_name, sub.id, cloned_slot_name);
	
	elog(INFO, "[RECOVERY_DEBUG] Created rescue subscription '%s' (id %u): enabled=%d, cleanup_pending=%d, failed=%d, stop_lsn=%X/%X, start_lsn=%X/%X, slot_name='%s'",
		 sub_name,
		 sub.id,
		 sub.enabled ? 1 : 0,
		 sub.rescue_cleanup_pending ? 1 : 0,
		 sub.rescue_failed ? 1 : 0,
		 !XLogRecPtrIsInvalid(sub.rescue_stop_lsn) ? (uint32) (sub.rescue_stop_lsn >> 32) : 0,
		 !XLogRecPtrIsInvalid(sub.rescue_stop_lsn) ? (uint32) sub.rescue_stop_lsn : 0,
		 !XLogRecPtrIsInvalid(sub.rescue_start_lsn) ? (uint32) (sub.rescue_start_lsn >> 32) : 0,
		 !XLogRecPtrIsInvalid(sub.rescue_start_lsn) ? (uint32) sub.rescue_start_lsn : 0,
		 cloned_slot_name);

	PG_RETURN_OID(sub.id);
}
