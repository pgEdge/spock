/*-------------------------------------------------------------------------
 *
 * spock_seqam_snowflake.c
 *		Snowflake distributed sequence access method for Spock.
 *
 * Generates int8 sequence values with the layout:
 *
 *     bit 63        : reserved, always 0 (sign bit, keeps values non-negative)
 *     bits 62..22   : 41-bit timestamp in milliseconds since
 *                     SPOCK_SNOWFLAKE_EPOCH_MS
 *     bits 21..12   : 10-bit node id (0..1023)
 *     bits 11..0    : 12-bit per-millisecond counter (0..4095)
 *
 * Uniqueness across a Spock cluster is guaranteed by the embedded node id:
 * the operator must ensure spock.snowflake_node_id is distinct on every
 * node.  Within a node, uniqueness is guaranteed by a single
 * pg_atomic_compare_exchange_u64() on a packed (timestamp_ms, counter)
 * word held in shared memory, per sequence.
 *
 * Clock-skew handling: the packed state holds the *most recent* (ts, ctr)
 * pair the sequence has produced.  If the wall clock regresses (NTP step,
 * VM migration), we keep emitting from the last observed timestamp and
 * advance only the counter.  We never emit a value whose timestamp is
 * lower than one we have already emitted.  A WARNING is logged on the
 * first regression per backend per minute.
 *
 * Counter exhaustion (4096 values per millisecond per node): we advance
 * to ts+1 and reset the counter.  Under sustained > 4M nextval()/s per
 * node this would push our notion of time ahead of the wall clock
 * indefinitely, which is fine; if the workload subsides, the clock
 * catches up and the timestamp field re-syncs.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "catalog/pg_sequence.h"
#include "miscadmin.h"
#include "port/atomics.h"
#include "utils/timestamp.h"

#include "spock_node.h"
#include "spock_seqam.h"


/*
 * Per-backend node id cache.
 *
 * Resolved on first call from spock.snowflake_node_id (GUC) if non-zero,
 * otherwise from spock.node_id (catalog).  Storing the result lets the
 * hot path skip the catalog lookup on every nextval() call.
 *
 * 0 is a sentinel for "unresolved", so the GUC's range is documented as
 * 0..1023 with 0 meaning "derive from spock.node".  If both sources yield
 * 0, that is a configuration error: the function ereports.
 */
static int32 SnowflakeBackendNodeId = -1;

/*
 * Rate-limit clock-skew WARNING emission: one per backend per minute.
 */
static TimestampTz SnowflakeLastSkewWarning = 0;
#define SNOWFLAKE_SKEW_WARN_INTERVAL_US	INT64CONST(60000000)	/* 60 s */


/*
 * Resolve the node id once per backend and cache it.
 */
static int32
snowflake_resolve_node_id(void)
{
	if (SnowflakeBackendNodeId >= 0)
		return SnowflakeBackendNodeId;

	if (spock_snowflake_node_id > 0)
	{
		SnowflakeBackendNodeId = spock_snowflake_node_id;
		return SnowflakeBackendNodeId;
	}

	/*
	 * Fall back to spock.node_id of the local Spock node.  If Spock has
	 * not been initialised, we cannot proceed safely -- an unconfigured
	 * node would silently produce values colliding with whatever node
	 * happens to also map to (0 or unset).  Refuse loudly.
	 */
	{
		SpockLocalNode *ln = get_local_node(false, true);

		if (ln != NULL && ln->node != NULL && ln->node->id != 0)
		{
			/*
			 * spock.node.id is a 32-bit OID.  Snowflake only has room for
			 * 10 bits, so map the low bits.  Operators that need
			 * deterministic mapping should set spock.snowflake_node_id
			 * explicitly.
			 */
			SnowflakeBackendNodeId =
				(int32) (ln->node->id & SPOCK_SNOWFLAKE_MAX_NODE_ID);

			if (SnowflakeBackendNodeId == 0)
				ereport(ERROR,
						(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
						 errmsg("spock.node.id %u maps to snowflake node 0",
								(unsigned) ln->node->id),
						 errhint("Set spock.snowflake_node_id explicitly "
								 "to a value between 1 and 1023.")));
			return SnowflakeBackendNodeId;
		}
	}

	ereport(ERROR,
			(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
			 errmsg("snowflake sequences require a configured node id"),
			 errhint("Set spock.snowflake_node_id (1..1023) before using "
					 "snowflake-managed sequences.")));
}


/*
 * Current wall-clock time in milliseconds since SPOCK_SNOWFLAKE_EPOCH_MS.
 *
 * GetCurrentTimestamp() returns TimestampTz, microseconds since
 * 2000-01-01 00:00:00 UTC.  Unix-epoch ms = us/1000 + 946684800000.
 */
static int64
snowflake_now_ms_since_epoch(void)
{
	TimestampTz now = GetCurrentTimestamp();
	int64		unix_ms;

	unix_ms = (now / INT64CONST(1000)) + INT64CONST(946684800000);
	return unix_ms - SPOCK_SNOWFLAKE_EPOCH_MS;
}


/*
 * Bit-pack helpers for the shared state (ts_ms << 12 | counter).
 *
 * Note these are different from the *output value* layout, which also
 * embeds node_id.  The shared state has no need for node_id (it is a
 * per-backend constant) so we omit it and save 10 bits of contention.
 */
#define SF_STATE_TS_SHIFT		SPOCK_SNOWFLAKE_COUNTER_BITS
#define SF_STATE_CTR_MASK		SPOCK_SNOWFLAKE_COUNTER_MASK
#define SF_STATE_TS_MASK		(((UINT64CONST(1) << SPOCK_SNOWFLAKE_TIMESTAMP_BITS) - 1) \
								 << SF_STATE_TS_SHIFT)

static inline uint64
sf_pack(int64 ts, int32 ctr)
{
	return ((uint64) ts << SF_STATE_TS_SHIFT) | ((uint64) ctr);
}

static inline void
sf_unpack(uint64 packed, int64 *ts, int32 *ctr)
{
	*ctr = (int32) (packed & SF_STATE_CTR_MASK);
	*ts = (int64) ((packed & SF_STATE_TS_MASK) >> SF_STATE_TS_SHIFT);
}


/*
 * Per-sequence slot initialization.  Called under
 * SpockSeqShmemCtx->alloc_lock by spock_seqam.c:seqam_locate_slot().
 */
void
spock_seqam_snowflake_init_slot(SpockSeqShmemSlot *slot,
								Oid seqoid,
								Form_pg_sequence seqform)
{
	(void) seqoid;
	(void) seqform;

	pg_atomic_init_u64(&slot->packed_state, 0);
}


/*
 * The hot path.
 *
 * Single pg_atomic_compare_exchange_u64() loop.  No LWLock, no catalog
 * access, no MemoryContext allocation.  Suitable to be called from any
 * backend including parallel workers.
 *
 * Assert at entry that ts_ms cannot overflow the 41-bit field; we still
 * have decades of headroom but a defensive check is cheap.
 */
int64
spock_seqam_snowflake_nextval(Oid seqoid,
							  Form_pg_sequence seqform,
							  SpockSeqShmemSlot *slot)
{
	int32		node_id = snowflake_resolve_node_id();
	int64		now_ms;
	int64		new_ts;
	int32		new_ctr;
	uint64		cur_packed;
	uint64		new_packed;
	bool		skew_warned_this_call = false;

	(void) seqoid;
	(void) seqform;

	Assert(slot != NULL);
	Assert(node_id >= 1 && node_id <= SPOCK_SNOWFLAKE_MAX_NODE_ID);

	now_ms = snowflake_now_ms_since_epoch();
	if (now_ms < 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_EXCEPTION),
				 errmsg("system clock is before the spock snowflake epoch"),
				 errdetail("System clock indicates a time earlier than "
						   "2026-01-01 UTC.  Snowflake sequences cannot "
						   "produce values until the clock is correct.")));

	if (((uint64) now_ms) >> SPOCK_SNOWFLAKE_TIMESTAMP_BITS)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("snowflake timestamp field overflowed"),
				 errdetail("The 41-bit timestamp field exhausted around "
						   "the year 2095.  Snowflake sequences can no "
						   "longer produce monotonically increasing "
						   "values; a new epoch is required.")));

	for (;;)
	{
		int64		cur_ts;
		int32		cur_ctr;

		cur_packed = pg_atomic_read_u64(&slot->packed_state);
		sf_unpack(cur_packed, &cur_ts, &cur_ctr);

		if (now_ms > cur_ts)
		{
			/* Normal forward path: time advanced, reset counter. */
			new_ts = now_ms;
			new_ctr = 0;
		}
		else
		{
			/*
			 * Either we are within the same millisecond as the last emit
			 * (very high call rate) or the wall clock regressed.  Either
			 * way: do not regress; use cur_ts and bump the counter.
			 */
			new_ts = cur_ts;
			new_ctr = cur_ctr + 1;

			if (new_ctr > (int32) SPOCK_SNOWFLAKE_COUNTER_MASK)
			{
				/*
				 * Counter exhausted in this millisecond.  Advance the
				 * timestamp by one ms and reset the counter.  We are now
				 * synthesising a future timestamp; the wall clock will
				 * catch up.
				 */
				new_ts = cur_ts + 1;
				new_ctr = 0;
			}

			if (now_ms < cur_ts && !skew_warned_this_call)
			{
				TimestampTz now_us = GetCurrentTimestamp();

				if (now_us - SnowflakeLastSkewWarning >=
					SNOWFLAKE_SKEW_WARN_INTERVAL_US)
				{
					ereport(WARNING,
							(errmsg("spock snowflake: wall clock regressed by " INT64_FORMAT " ms",
									cur_ts - now_ms),
							 errdetail("Continuing from the last observed "
									   "timestamp.  No duplicate values "
									   "will be emitted.")));
					SnowflakeLastSkewWarning = now_us;
					skew_warned_this_call = true;
				}
			}
		}

		new_packed = sf_pack(new_ts, new_ctr);

		if (pg_atomic_compare_exchange_u64(&slot->packed_state,
										   &cur_packed, new_packed))
			break;

		/* CAS lost; retry with the updated cur_packed. */
		CHECK_FOR_INTERRUPTS();
	}

	/*
	 * Compose the output value with the node id slotted in.
	 */
	return (int64)
		(((uint64) new_ts << SPOCK_SNOWFLAKE_TIMESTAMP_SHIFT) |
		 ((uint64) node_id << SPOCK_SNOWFLAKE_NODE_SHIFT) |
		 (uint64) new_ctr);
}
