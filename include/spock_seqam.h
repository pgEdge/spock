/*-------------------------------------------------------------------------
 *
 * spock_seqam.h
 *		Distributed sequence access methods for Spock.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_SEQAM_H
#define SPOCK_SEQAM_H

#include "postgres.h"
#include "catalog/pg_sequence.h"
#include "port/atomics.h"
#include "storage/lwlock.h"
#include "utils/relcache.h"

/*
 * Catalog name and column positions for spock.sequence_kind.
 *
 * Keep these in sync with sql/spock--*.sql.
 */
#define CATALOG_SEQUENCE_KIND			"sequence_kind"
#define Natts_sequence_kind				2
#define Anum_sequence_kind_seqoid		1
#define Anum_sequence_kind_kind			2

/*
 * Registered methods.  Identifiers are stable across versions and serve as
 * the on-disk encoding of the `kind` column when we eventually move it from
 * text to a more compact form.
 */
typedef enum SpockSeqAmKind
{
	SPOCK_SEQAM_LOCAL = 0,			/* fall through to in-core nextval */
	SPOCK_SEQAM_SNOWFLAKE = 1
} SpockSeqAmKind;

/*
 * Per-method dispatch table.  Filled in by spock_seqam_register_methods()
 * at extension load and never mutated after that.
 *
 * Methods that have no per-sequence init/cleanup (snowflake) can leave the
 * init / cleanup pointers NULL.
 */
typedef struct SpockSeqAmMethod
{
	const char	   *name;			/* "snowflake", "local", ... */
	SpockSeqAmKind	kind;

	/*
	 * Hot-path nextval.  Receives the sequence OID, the
	 * pg_sequence catalog row, and a slot in shared memory owned by this
	 * (seqoid, method) pair.  Returns the value to use; must not fail under
	 * normal conditions, must elog(ERROR) on hard failures.
	 */
	int64		  (*nextval) (Oid seqoid,
							  Form_pg_sequence seqform,
							  struct SpockSeqShmemSlot *slot);

	/*
	 * Optional: initialize per-sequence shared-memory state when a
	 * sequence is first assigned to this method.  Runs under
	 * SpockSeqShmem->lock in EXCLUSIVE mode.
	 */
	void		  (*init_slot) (struct SpockSeqShmemSlot *slot,
								Oid seqoid,
								Form_pg_sequence seqform);
} SpockSeqAmMethod;

/*
 * Per-sequence shared-memory slot.
 *
 * Slots are allocated lazily on first managed nextval() for a sequence and
 * persist for the lifetime of the postmaster.  The maximum number of
 * concurrently-managed sequences is bounded by spock.max_managed_sequences
 * (GUC, PGC_POSTMASTER, default 1024).
 *
 * The Snowflake method uses packed_state to hold the most recently emitted
 * (timestamp_ms, counter) pair, packed as:
 *
 *     bit 63        : reserved, always 0 (keeps the int64 non-negative)
 *     bits 62..22   : 41-bit timestamp milliseconds since SPOCK_SNOWFLAKE_EPOCH_MS
 *     bits 21..12   : 10-bit node id  (set by nextval, derived from snowflake_node_id GUC)
 *     bits 11..0    : 12-bit per-millisecond counter
 *
 * Per-call CAS on this single 64-bit word handles both clock skew (we never
 * regress) and same-millisecond contention (atomic counter advance).
 */
typedef struct SpockSeqShmemSlot
{
	Oid				seqoid;			/* sequence OID; InvalidOid if free */
	SpockSeqAmKind	kind;
	pg_atomic_uint64 packed_state;	/* method-specific atomic state */
} SpockSeqShmemSlot;

typedef struct SpockSeqShmem
{
	LWLock		   *alloc_lock;		/* protects slot allocation, not hot path */
	int				nslots;			/* spock.max_managed_sequences */
	int				nallocated;		/* current allocation high-water mark */
	SpockSeqShmemSlot slots[FLEXIBLE_ARRAY_MEMBER];
} SpockSeqShmem;

extern SpockSeqShmem *SpockSeqShmemCtx;

/*
 * GUC-controlled bounds and defaults.  Defined in spock_seqam.c.
 */
extern int spock_seqam_max_managed_sequences;
extern int spock_seqam_default_kind;	/* enum SpockSeqAmKind */
extern int spock_snowflake_node_id;		/* 0 .. 1023, 0 means "derive from spock.node" */

/*
 * Snowflake layout constants.
 *
 * Bit allocation is fixed.  PGD chose the same split for SnowflakeId and the
 * mathematics of (4096 values / node / ms) are sufficient for any OLTP
 * workload; making it configurable is a footgun.
 */
#define SPOCK_SNOWFLAKE_TIMESTAMP_BITS	41
#define SPOCK_SNOWFLAKE_NODE_BITS		10
#define SPOCK_SNOWFLAKE_COUNTER_BITS	12

#define SPOCK_SNOWFLAKE_NODE_SHIFT		SPOCK_SNOWFLAKE_COUNTER_BITS
#define SPOCK_SNOWFLAKE_TIMESTAMP_SHIFT	(SPOCK_SNOWFLAKE_NODE_BITS + SPOCK_SNOWFLAKE_COUNTER_BITS)

#define SPOCK_SNOWFLAKE_COUNTER_MASK	((UINT64CONST(1) << SPOCK_SNOWFLAKE_COUNTER_BITS) - 1)
#define SPOCK_SNOWFLAKE_NODE_MASK		(((UINT64CONST(1) << SPOCK_SNOWFLAKE_NODE_BITS) - 1) \
										 << SPOCK_SNOWFLAKE_NODE_SHIFT)
#define SPOCK_SNOWFLAKE_TIMESTAMP_MASK	(((UINT64CONST(1) << SPOCK_SNOWFLAKE_TIMESTAMP_BITS) - 1) \
										 << SPOCK_SNOWFLAKE_TIMESTAMP_SHIFT)

#define SPOCK_SNOWFLAKE_MAX_NODE_ID		((1 << SPOCK_SNOWFLAKE_NODE_BITS) - 1)

/*
 * 2026-01-01 00:00:00 UTC as Unix milliseconds.  The 41-bit ms timestamp
 * field thus runs out around 2095.  Do not change this constant after a
 * cluster has generated any snowflake values, or every previously emitted
 * value will appear to be from a different era and may compare incorrectly
 * with newly generated ones.
 */
#define SPOCK_SNOWFLAKE_EPOCH_MS		INT64CONST(1767225600000)

/*
 * Module entry points.
 *
 * spock_seqam_init() is called from _PG_init().  It registers the nextval
 * hook, sets up shared-memory requests via the existing
 * spock_shmem_request() chain, and registers the per-backend lookup-cache
 * invalidation callback.
 *
 * spock_seqam_shmem_request() and spock_seqam_shmem_startup() mirror the
 * existing per-subsystem helpers in spock_shmem.c.  They are called from
 * inside spock_shmem_request() / spock_shmem_startup().
 */
extern void spock_seqam_init(void);
extern void spock_seqam_shmem_request(void);
extern void spock_seqam_shmem_startup(bool found);

/*
 * Drop hook callback.  Invoked from src/spock_executor.c:spock_object_access
 * on OAT_DROP of a RELKIND_SEQUENCE relation.  Deletes the spock.sequence_kind
 * row (if any) and clears the per-sequence shared-memory slot so the entry
 * is reusable and a future sequence with the same OID does not inherit
 * stale state.
 */
extern void spock_seqam_drop_sequence_record(Oid seqoid);

/*
 * SQL-callable, registered from sql/spock--*.sql.
 */
extern Datum spock_alter_sequence_set_kind(PG_FUNCTION_ARGS);
extern Datum spock_convert_all_sequences(PG_FUNCTION_ARGS);
extern Datum spock_seq_hook_available(PG_FUNCTION_ARGS);
extern Datum spock_seq_snowflake_decode(PG_FUNCTION_ARGS);

#endif							/* SPOCK_SEQAM_H */
