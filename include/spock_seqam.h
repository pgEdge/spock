/*-------------------------------------------------------------------------
 *
 * spock_seqam.h
 *		Distributed sequence access methods for Spock.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_SEQAM_H
#define SPOCK_SEQAM_H

#include "postgres.h"
#include "catalog/pg_sequence.h"
#include "commands/sequence.h"			/* SeqTable, nextval_hook_type */
#include "utils/relcache.h"

/*
 * Catalog name and column positions for spock.sequence_kind.
 *
 * Keep these in sync with sql/spock--*.sql.  The table is keyed on
 * (nspname, relname); seqoid is a non-key cache column.
 */
#define CATALOG_SEQUENCE_KIND			"sequence_kind"
#define CATALOG_SEQUENCE_KIND_OID_IDX	"spock_sequence_kind_seqoid_idx"
#define Natts_sequence_kind				4
#define Anum_sequence_kind_nspname		1
#define Anum_sequence_kind_relname		2
#define Anum_sequence_kind_kind			3
#define Anum_sequence_kind_seqoid		4

/*
 * Hook entry for ALTER SEQUENCE ... RENAME and SET SCHEMA.  Called from
 * src/spock_executor.c:spock_object_access on OAT_POST_ALTER for a
 * RELKIND_SEQUENCE relation (subId == 0).  Resolves the row by seqoid via
 * the secondary index and updates (nspname, relname) if the live sequence
 * has been renamed or moved.
 */
extern void spock_seqam_relocate_sequence_record(Oid seqoid);

/*
 * Registered methods.  Identifiers are stable across versions and serve as
 * the on-disk encoding of the `kind` column when we eventually move it from
 * text to a more compact form.
 *
 * SPOCK_SEQAM_NMETHODS is a sentinel: it must remain one past the last real
 * kind so the method-table array sizes correctly when a new kind is added.
 */
typedef enum SpockSeqAmKind
{
	SPOCK_SEQAM_LOCAL = 0,			/* fall through to in-core nextval */
	SPOCK_SEQAM_SNOWFLAKE = 1,
	SPOCK_SEQAM_NMETHODS			/* leave last */
} SpockSeqAmKind;

/*
 * Per-method dispatch table.  Filled in by spock_seqam_register_methods()
 * at extension load and never mutated after that.
 */
typedef struct SpockSeqAmMethod
{
	const char	   *name;			/* "snowflake", "local", ... */
	SpockSeqAmKind	kind;

	/*
	 * Hot-path nextval.  Signature mirrors the SeqAM `nextval` callback
	 * (the in-flight Paquier patch's SequenceAmRoutine.nextval): receives
	 * the open sequence relation, the unpacked catalog options, and an
	 * IN/OUT *last for prefetch reporting.  Returns the int64 value to be
	 * used as nextval()'s result.
	 *
	 * Methods that do not prefetch (Snowflake) must set *last to the
	 * returned value so the in-core CACHE fast path stays neutral.
	 */
	int64		  (*nextval) (Relation rel,
							  int64 incby, int64 maxv, int64 minv,
							  int64 cache, bool cycle,
							  int64 *last);
} SpockSeqAmMethod;

/*
 * GUC-controlled defaults.  Defined in spock_seqam.c.
 */
extern int spock_seqam_default_kind;	/* enum SpockSeqAmKind */

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

#define SPOCK_SNOWFLAKE_MAX_NODE_ID		((1 << SPOCK_SNOWFLAKE_NODE_BITS) - 1)

/*
 * 2023-01-01 00:00:00 UTC as Unix milliseconds.  The 41-bit ms timestamp
 * field thus runs out around 2092.  Chosen to match the standalone
 * `snowflake` extension's epoch so values from both extensions decode
 * identically (same bit layout, same epoch, same node-id derivation).
 *
 * Do NOT change this constant after a cluster has generated any
 * snowflake values: every previously emitted value would appear to be
 * from a different era and could compare incorrectly with newly
 * generated ones.
 */
#define SPOCK_SNOWFLAKE_EPOCH_MS		INT64CONST(1672531200000)

/*
 * Magic word stamped in the special area of a sequence's heap page by
 * the in-core sequence machinery.  Hardcoded -- core declares the type
 * privately in src/backend/commands/sequence.c.  Validate on every read
 * to catch page-layout drift across PG major versions at buildfarm-
 * assert level.
 */
#define SPOCK_SEQUENCE_PAGE_MAGIC		0x1717

typedef struct SpockSequencePageMagic
{
	uint32		magic;
} SpockSequencePageMagic;

/*
 * Pre-log window for WAL batching, in milliseconds.  On every nextval we
 * compare the emitted value against last_logged_threshold (stored in
 * seq->log_cnt).  When we cross the threshold, we WAL-log a reservation
 * for the next SPOCK_SNOWFLAKE_LOG_INTERVAL_MS of generation.  Crash
 * recovery jumps last_value forward by at most this interval -- never
 * produces duplicates.  Same mechanism core PG uses for stock sequence
 * cache, expressed in time instead of count.
 */
#define SPOCK_SNOWFLAKE_LOG_INTERVAL_MS	30

/*
 * Module entry point.  Called from _PG_init() to register the nextval hook,
 * install GUCs and the relcache invalidation callback.
 */
extern void spock_seqam_init(void);

/*
 * Drop hook callback.  Invoked from src/spock_executor.c:spock_object_access
 * on OAT_DROP of a RELKIND_SEQUENCE relation.  Deletes the spock.sequence_kind
 * row if any.
 */
extern void spock_seqam_drop_sequence_record(Oid seqoid);

/*
 * Lookup the catalog kind for a sequence by (nspname, relname).  Returns
 * false if the catalog is missing (extension not yet installed) or if no
 * row exists for the sequence.  Used by replication paths to skip
 * managed-sequence values that must generate independently per node.
 */
extern bool spock_seqam_lookup_kind_by_name(const char *nspname,
											const char *relname,
											SpockSeqAmKind *kind_out);

/*
 * SQL-callable, registered from sql/spock--*.sql.
 */
extern Datum spock_alter_sequence_set_kind(PG_FUNCTION_ARGS);
extern Datum spock_convert_all_sequences(PG_FUNCTION_ARGS);
extern Datum spock_sequence_hook_available(PG_FUNCTION_ARGS);

/*
 * Forward declaration of the snowflake method.  Defined in
 * src/spock_seqam_snowflake.c.
 */
extern int64 spock_seqam_snowflake_nextval(Relation rel,
										   int64 incby, int64 maxv, int64 minv,
										   int64 cache, bool cycle,
										   int64 *last);

#endif							/* SPOCK_SEQAM_H */
