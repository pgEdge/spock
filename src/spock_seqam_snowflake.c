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
 * Uniqueness across a Spock cluster is guaranteed by the embedded node id,
 * derived from spock.node.id (10 low bits).  Operators must pick node
 * names whose hashes don't collide on the low 10 bits.  Within a node,
 * uniqueness is guaranteed by the buffer lock on the sequence's heap
 * page held while we read (ts, ctr) from last_value and write the new
 * value back.
 *
 * Persistence: the (ts, ctr) state lives in the sequence's heap tuple
 * (last_value), so crash recovery is the same as for a stock PostgreSQL
 * sequence: replay of XLOG_SEQ_LOG restores last_value, and the next
 * nextval() reads it.  No DSA, no shmem slot.  The cost is one WAL record
 * and one exclusive buffer lock per call -- the explicit trade for
 * crash-safety and ~1000 lines of subsystem code.
 *
 * Clock-skew handling: we keep the *most recent* (ts, ctr) pair in
 * last_value (with the node_id bits masked off for interpretation).  If
 * the wall clock regresses (NTP step, VM migration), we keep emitting
 * from the last observed timestamp and advance only the counter.  We
 * never emit a value whose timestamp is lower than one we have already
 * emitted.  A WARNING is logged on the first regression per backend per
 * minute.
 *
 * Counter exhaustion (4096 values per millisecond per node): we advance
 * to ts+1 and reset the counter.  Under sustained > 4M nextval()/s per
 * node this would push our notion of time ahead of the wall clock
 * indefinitely, which is fine; if the workload subsides, the clock
 * catches up and the timestamp field re-syncs.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "access/xloginsert.h"
#include "catalog/pg_sequence.h"
#include "commands/sequence.h"			/* xl_seq_rec, XLOG_SEQ_LOG */
#include "miscadmin.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "storage/lmgr.h"
#include "utils/rel.h"
#include "utils/timestamp.h"

#include "spock_node.h"
#include "spock_seqam.h"


/*
 * Per-backend node id cache.
 *
 * Resolved on first call from spock.node (the local Spock node) and
 * masked to the snowflake field width.  Storing the result lets the hot
 * path skip the catalog lookup on every nextval() call.
 *
 * -1 is the "unresolved" sentinel; once we resolve, the cached value is
 * 1..1023 (zero is reserved).
 */
static int32 SnowflakeBackendNodeId = -1;

/*
 * Rate-limit clock-skew WARNING emission: one per backend per minute.
 */
static TimestampTz SnowflakeLastSkewWarning = 0;
#define SNOWFLAKE_SKEW_WARN_INTERVAL_US	INT64CONST(60000000)	/* 60 s */


/*
 * Resolve the node id once per backend and cache it.
 *
 * Derives from the local Spock node: spock.node.id is a 16-bit value
 * (hash_any(name) & 0xffff at node_create); we mask it to the snowflake
 * field's 10 bits.  Two nodes whose names hash to the same low-10-bit
 * value silently collide cluster-wide -- operators are responsible for
 * picking names with distinct low-10-bit hashes across peer nodes.
 *
 * Errors if Spock has not been initialised (no spock.node row) or if
 * the derived id is 0 (reserved).
 */
static int32
snowflake_resolve_node_id(void)
{
	SpockLocalNode *ln;

	if (SnowflakeBackendNodeId >= 0)
		return SnowflakeBackendNodeId;

	ln = get_local_node(false, true);
	if (ln == NULL || ln->node == NULL || ln->node->id == InvalidOid)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("snowflake sequences require a configured Spock node"),
				 errhint("Run spock.node_create() before using snowflake-managed sequences.")));

	SnowflakeBackendNodeId =
		(int32) (ln->node->id & SPOCK_SNOWFLAKE_MAX_NODE_ID);

	if (SnowflakeBackendNodeId == 0)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
				 errmsg("Spock node \"%s\" hashes to snowflake node 0", ln->node->name),
				 errhint("Rename the Spock node; node id 0 is reserved.")));

	return SnowflakeBackendNodeId;
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
 * Bit-unpack helper for the (ts_ms, counter) pair we recover from
 * last_value.  Layout matches the snowflake output but with the 10
 * node_id bits masked off by the caller: the node_id is a per-backend
 * constant and is composed back into the *output* value at emit time.
 */
#define SF_STATE_TS_SHIFT		SPOCK_SNOWFLAKE_COUNTER_BITS
#define SF_STATE_CTR_MASK		SPOCK_SNOWFLAKE_COUNTER_MASK
#define SF_STATE_TS_MASK		(((UINT64CONST(1) << SPOCK_SNOWFLAKE_TIMESTAMP_BITS) - 1) \
								 << SF_STATE_TS_SHIFT)

static inline void
sf_unpack(uint64 packed, int64 *ts, int32 *ctr)
{
	*ctr = (int32) (packed & SF_STATE_CTR_MASK);
	*ts = (int64) ((packed & SF_STATE_TS_MASK) >> SF_STATE_TS_SHIFT);
}


/*
 * Locate the sequence tuple in the relation's first (and only) block and
 * return a pointer into the pinned, exclusive-locked buffer.  Mirrors the
 * static read_seq_tuple() helper in src/backend/commands/sequence.c, which
 * is not exposed to extensions.
 *
 * TODO(seqam-merge): drop in favour of the public helper when Paquier's
 * SeqAM patch lands.
 *
 * Caller releases the buffer via UnlockReleaseBuffer().
 */
static Form_pg_sequence_data
snowflake_lock_seq_tuple(Relation rel, Buffer *buf, HeapTupleData *tupout)
{
	Page		page;
	ItemId		lp;

	*buf = ReadBuffer(rel, 0);
	LockBuffer(*buf, BUFFER_LOCK_EXCLUSIVE);

	page = BufferGetPage(*buf);

	/*
	 * Validate the page's special-area magic.  Catches a future core
	 * change to sequence page layout that would otherwise let us write
	 * over the wrong tuple.
	 */
	{
		SpockSequencePageMagic *sm;

		sm = (SpockSequencePageMagic *) PageGetSpecialPointer(page);
		if (sm->magic != SPOCK_SEQUENCE_PAGE_MAGIC)
			elog(ERROR, "bad magic number in sequence \"%s\": %08X",
				 RelationGetRelationName(rel), sm->magic);
	}

	/* A sequence page carries exactly one tuple at FirstOffsetNumber. */
	Assert(PageGetMaxOffsetNumber(page) == FirstOffsetNumber);

	lp = PageGetItemId(page, FirstOffsetNumber);
	Assert(ItemIdIsNormal(lp));

	tupout->t_data = (HeapTupleHeader) PageGetItem(page, lp);
	tupout->t_len = ItemIdGetLength(lp);

	/*
	 * Pre-PG-12 SELECT FOR UPDATE on a sequence could leave a non-frozen
	 * xmax behind.  Modern core declines such locks but the bug class is
	 * cheap to defend against; if a tuple carries one, clear it.  Hint-
	 * level update -- no WAL needed.
	 */
	Assert(!(tupout->t_data->t_infomask & HEAP_XMAX_IS_MULTI));
	if (HeapTupleHeaderGetRawXmax(tupout->t_data) != InvalidTransactionId)
	{
		HeapTupleHeaderSetXmax(tupout->t_data, InvalidTransactionId);
		tupout->t_data->t_infomask &= ~HEAP_XMAX_COMMITTED;
		tupout->t_data->t_infomask |= HEAP_XMAX_INVALID;
		MarkBufferDirtyHint(*buf, true);
	}

	return (Form_pg_sequence_data) GETSTRUCT(tupout);
}


/*
 * The hot path.  Reads the current (ts, ctr) from last_value, composes the
 * new (ts, ctr) using the same clock-skew / counter-exhaustion logic as the
 * shmem-CAS variant did, writes it back, and emits one XLOG_SEQ_LOG record.
 *
 * Called from nextval_internal() via Spock's dispatcher.  Parallel-mode is
 * impossible here -- nextval_internal() PreventCommandIfParallelMode's
 * before our hook fires.
 *
 * Two timestamp-overflow checks: one against the wall clock (top of
 * function), one against the synthesised timestamp inside the loop (the
 * synthesised value can drift past the wall clock under counter
 * exhaustion).  Both ereport(ERROR) -- a wrapped 41-bit field would
 * silently break monotonicity.
 */
int64
spock_seqam_snowflake_nextval(Relation rel,
							  int64 incby, int64 maxv, int64 minv,
							  int64 cache, bool cycle,
							  int64 *last)
{
	int32		node_id = snowflake_resolve_node_id();
	int64		value;
	int64		now_ms;
	int64		cur_ts;
	int32		cur_ctr;
	int64		new_ts;
	int32		new_ctr;
	uint64		cur_packed;
	Buffer		buf;
	Page		page;
	HeapTupleData seqdatatuple;
	Form_pg_sequence_data seq;

	(void) maxv;
	(void) minv;
	(void) cache;
	(void) cycle;

	Assert(node_id >= 1 && node_id <= SPOCK_SNOWFLAKE_MAX_NODE_ID);

	now_ms = snowflake_now_ms_since_epoch();
	if (now_ms < 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_EXCEPTION),
				 errmsg("system clock is before the Spock snowflake epoch"),
				 errdetail("System clock indicates a time earlier than "
						   "2023-01-01 UTC.  Snowflake sequences cannot "
						   "produce values until the clock is correct.")));

	if (((uint64) now_ms) >> SPOCK_SNOWFLAKE_TIMESTAMP_BITS)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("snowflake timestamp field exhausted"),
				 errdetail("The 41-bit timestamp field exhausted around "
						   "the year 2092.  Snowflake sequences can no "
						   "longer produce monotonically increasing "
						   "values; a new epoch is required.")));

	/*
	 * Read current state from the sequence tuple.  The buffer lock
	 * serialises us against any other backend doing the same on this
	 * sequence, so we do not need a CAS retry loop.
	 */
	seq = snowflake_lock_seq_tuple(rel, &buf, &seqdatatuple);
	page = BufferGetPage(buf);

	/*
	 * Strip the 10 node_id bits so we interpret last_value as our packed
	 * (ts, ctr).  A stock-PG last_value (small counter, e.g. 1..N) decodes
	 * to (ts=0, ctr=N), which is harmless: the first now_ms > 0 path below
	 * resets the counter.  alter_sequence_set_kind() also rewrites
	 * last_value to 0 explicitly when assigning snowflake, so we don't
	 * rely on this property.
	 */
	cur_packed = ((uint64) seq->last_value) & ~SPOCK_SNOWFLAKE_NODE_MASK;
	sf_unpack(cur_packed, &cur_ts, &cur_ctr);

	if (now_ms > cur_ts)
	{
		/* Normal forward path: time advanced, reset counter. */
		new_ts = now_ms;
		new_ctr = 0;
	}
	else
	{
		int64		candidate_ctr;

		/*
		 * Either we are within the same millisecond as the last emit
		 * (very high call rate) or the wall clock regressed.  Either
		 * way: do not regress; use cur_ts and bump the counter by the
		 * sequence's INCREMENT.
		 *
		 * Do the arithmetic in int64 so a user who ALTERs INCREMENT to
		 * a large value after the kind was set (bypassing
		 * validate_sequence_target) cannot trigger int32 overflow here.
		 * validate_sequence_target enforces 1..COUNTER_MASK at SET KIND
		 * time; this is belt-and-braces.
		 */
		new_ts = cur_ts;
		candidate_ctr = (int64) cur_ctr + incby;

		if (candidate_ctr > (int64) SPOCK_SNOWFLAKE_COUNTER_MASK)
		{
			/*
			 * Counter exhausted in this millisecond.  Advance the
			 * timestamp by one ms and reset the counter.  We are now
			 * synthesising a future timestamp; the wall clock will
			 * catch up.
			 */
			new_ts = cur_ts + 1;
			new_ctr = 0;

			/*
			 * Sustained > 4M nextval()/s/sequence/node could push the
			 * synthesised timestamp arbitrarily far into the future and
			 * ultimately overflow the 41-bit field.  Refuse the write
			 * here rather than silently wrapping.
			 */
			if (((uint64) new_ts) >> SPOCK_SNOWFLAKE_TIMESTAMP_BITS)
			{
				UnlockReleaseBuffer(buf);
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("snowflake timestamp field exhausted under saturation"),
						 errdetail("Per-millisecond counter exhaustion has pushed the "
								   "synthesised timestamp beyond the 41-bit field "
								   "(year ~2092).  Reduce sustained nextval() throughput "
								   "or assign additional snowflake-managed sequences "
								   "to spread the load.")));
			}
		}
		else
		{
			/* Safe: candidate_ctr is in [0, COUNTER_MASK], fits int32. */
			new_ctr = (int32) candidate_ctr;
		}

		if (now_ms < cur_ts)
		{
			TimestampTz now_us = GetCurrentTimestamp();

			if (now_us - SnowflakeLastSkewWarning >=
				SNOWFLAKE_SKEW_WARN_INTERVAL_US)
			{
				ereport(WARNING,
						(errmsg("wall clock regressed by " INT64_FORMAT " ms on a Spock snowflake sequence",
								cur_ts - now_ms),
						 errdetail("Continuing from the last observed "
								   "timestamp.  No duplicate values "
								   "will be emitted.")));
				SnowflakeLastSkewWarning = now_us;
			}
		}
	}

	/*
	 * Compose the output value with the node id slotted in.
	 */
	value = (int64)
		(((uint64) new_ts << SPOCK_SNOWFLAKE_TIMESTAMP_SHIFT) |
		 ((uint64) node_id << SPOCK_SNOWFLAKE_NODE_SHIFT) |
		 (uint64) new_ctr);

	Assert(value >= 0);

	/*
	 * WAL batching: we pre-log a reservation covering the next
	 * SPOCK_SNOWFLAKE_LOG_INTERVAL_MS milliseconds.  seq->log_cnt holds
	 * the next-reservation threshold (encoded as a snowflake).  Until
	 * the current value crosses it, we skip the WAL record.  On crash,
	 * replay restores the reservation, so the next nextval after
	 * recovery emits at >= the reserved value -- never a duplicate.
	 *
	 * Same idea core PG uses for stock sequence caching, in the time
	 * domain instead of count domain.
	 */
	{
		/*
		 * Compare timestamp portions only; node_id bits are nominally
		 * identical between consecutive log writes (node_id is stable
		 * per Spock node) but stripping them makes the decision immune
		 * to any future per-backend or per-something-else identity
		 * scheme.
		 */
		bool		logit;

		logit = (((uint64) value) >> SPOCK_SNOWFLAKE_TIMESTAMP_SHIFT) >=
				(((uint64) seq->log_cnt) >> SPOCK_SNOWFLAKE_TIMESTAMP_SHIFT);

		/* Force a log after a checkpoint so crash recovery sees a fresh
		 * reservation; otherwise replay would restore a pre-checkpoint
		 * state we have since advanced past. */
		if (!logit)
		{
			XLogRecPtr	redoptr = GetRedoRecPtr();

			if (PageGetLSN(page) <= redoptr)
				logit = true;
		}

		/*
		 * Compute the new threshold before entering the critical section
		 * so we can ereport(ERROR) cleanly if it would overflow the
		 * 41-bit field.  Threshold encodes (new_ts + interval, 0).
		 */
		if (logit && RelationNeedsWAL(rel))
		{
			int64		future_ts = new_ts + SPOCK_SNOWFLAKE_LOG_INTERVAL_MS;

			if (((uint64) future_ts) >> SPOCK_SNOWFLAKE_TIMESTAMP_BITS)
			{
				UnlockReleaseBuffer(buf);
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("snowflake timestamp field exhausted"),
						 errdetail("The pre-log reservation window would "
								   "push the timestamp past the 41-bit "
								   "field (year ~2092).")));
			}

			/* Acquire xid for syncrep outside the critical section. */
			GetTopTransactionId();

			START_CRIT_SECTION();
			MarkBufferDirty(buf);

			{
				xl_seq_rec	xlrec;
				XLogRecPtr	recptr;
				int64		future_value;

				future_value = (int64)
					(((uint64) future_ts << SPOCK_SNOWFLAKE_TIMESTAMP_SHIFT) |
					 ((uint64) node_id << SPOCK_SNOWFLAKE_NODE_SHIFT));

				XLogBeginInsert();
				XLogRegisterBuffer(0, buf, REGBUF_WILL_INIT);

				/*
				 * Write the FUTURE state into the tuple before
				 * XLogRegisterData captures it, so crash recovery
				 * restores the reservation.
				 */
				seq->last_value = future_value;
				seq->is_called = true;
				seq->log_cnt = future_value;

#if PG_VERSION_NUM >= 160000
				xlrec.locator = rel->rd_locator;
#else
				xlrec.node = rel->rd_node;
#endif
				XLogRegisterData(&xlrec, sizeof(xl_seq_rec));
				XLogRegisterData(seqdatatuple.t_data, seqdatatuple.t_len);

				recptr = XLogInsert(RM_SEQ_ID, XLOG_SEQ_LOG);
				PageSetLSN(page, recptr);
			}

			/* Now overwrite with the ACTUAL state for currval/lastval. */
			seq->last_value = value;
			seq->is_called = true;
			/* seq->log_cnt stays at the threshold we just logged. */

			END_CRIT_SECTION();
		}
		else
		{
			/*
			 * No WAL this call: either still within the previous
			 * reservation window, or the relation does not need WAL
			 * (temp / unlogged).  Write the actual value directly.
			 */
			START_CRIT_SECTION();
			MarkBufferDirty(buf);

			seq->last_value = value;
			seq->is_called = true;

			END_CRIT_SECTION();
		}
	}

	UnlockReleaseBuffer(buf);

	/*
	 * Snowflake does not prefetch: every nextval() must round-trip through
	 * us to compose a fresh (timestamp, counter, node_id).  Setting *last
	 * to the returned value keeps elm->last == elm->cached so the in-core
	 * CACHE fast path does not fire on the next call.
	 */
	*last = value;
	return value;
}
