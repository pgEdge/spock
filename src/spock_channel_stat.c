/*-------------------------------------------------------------------------
 *
 * spock_channel_stat.c
 *		per-table replication counters in the cumulative statistics system
 *
 * On PostgreSQL 18 and later the counters behind spock.channel_table_stats
 * (rows inserted, updated and deleted, conflicts and delta-apply conflicts
 * per subscription and table) are kept by the cumulative statistics
 * system under a kind of their own, instead of the fixed-size hash in
 * shared memory that spock_worker.c uses on older servers.  There is no
 * limit on the number of tables counted and no lock per row.
 *
 * The rows of a transaction are tallied in process-local memory and added
 * to the shared entries when the transaction commits: by the apply worker
 * after its local commit, and by the walsender in the output plugin's
 * commit callback.  A transaction that is discarded or rolled back adds
 * nothing.  The pending entry machinery of pgstat is not used because a
 * walsender runs every callback inside a transaction and never reaches
 * pgstat_report_stat(), so its pending counts would only be flushed when
 * it exits.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#if PG_VERSION_NUM >= 180000

#include "miscadmin.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"

#include "spock_channel_stat.h"

/*
 * Kind id of the channel counters.  Spock's ids are registered on the
 * PostgreSQL wiki page CustomCumulativeStats: 29 for the conflict counters
 * of spock_conflict_stat.c, 31 for these.
 */
#define SPOCK_PGSTAT_KIND_CHANNEL	31

/* Shared memory wrapper of one entry. */
typedef struct Spock_Stat_Channel
{
	PgStatShared_Common header;
	Spock_Stat_ChannelEntry stats;
} Spock_Stat_Channel;

/* Counts of this process not yet added to the shared entries. */
typedef struct SpockChannelPendingKey
{
	Oid			subid;
	Oid			relid;
} SpockChannelPendingKey;

typedef struct SpockChannelPending
{
	SpockChannelPendingKey key;
	int64		counter[SPOCK_STATS_NUM_COUNTERS];
} SpockChannelPending;

static HTAB *SpockChannelPendingHash = NULL;
static bool spock_channel_pending_dirty = false;

static void spock_stat_channel_reset_timestamp_cb(PgStatShared_Common *header,
												  TimestampTz ts);

static const PgStat_KindInfo spock_channel_stat = {
	.name = "spock_channel_stat",
	.fixed_amount = false,
	.write_to_file = true,

	.shared_size = sizeof(Spock_Stat_Channel),
	.shared_data_off = offsetof(Spock_Stat_Channel, stats),
	.shared_data_len = sizeof(((Spock_Stat_Channel *) 0)->stats),

	/* No pending entries: the counts are added at commit, see above. */
	.pending_size = 0,

	.reset_timestamp_cb = spock_stat_channel_reset_timestamp_cb,
};

void
spock_stat_register_channel_stat(void)
{
	pgstat_register_kind(SPOCK_PGSTAT_KIND_CHANNEL, &spock_channel_stat);
}

static void
spock_stat_channel_reset_timestamp_cb(PgStatShared_Common *header,
									  TimestampTz ts)
{
	((Spock_Stat_Channel *) header)->stats.stat_reset_timestamp = ts;
}

/*
 * Count ntup rows of one kind for a table, in this process, until the
 * transaction commits.
 */
void
spock_stat_channel_count(Oid subid, Oid relid, spockStatsType type, int ntup)
{
	SpockChannelPendingKey key;
	SpockChannelPending *pending;
	bool		found;

	Assert(type >= 0 && type < SPOCK_STATS_NUM_COUNTERS);

	if (SpockChannelPendingHash == NULL)
	{
		HASHCTL		hctl;

		memset(&hctl, 0, sizeof(hctl));
		hctl.keysize = sizeof(SpockChannelPendingKey);
		hctl.entrysize = sizeof(SpockChannelPending);
		hctl.hcxt = TopMemoryContext;
		SpockChannelPendingHash = hash_create("spock channel counters", 64,
											  &hctl,
											  HASH_ELEM | HASH_BLOBS |
											  HASH_CONTEXT);
	}

	memset(&key, 0, sizeof(key));
	key.subid = subid;
	key.relid = relid;

	pending = hash_search(SpockChannelPendingHash, &key, HASH_ENTER, &found);
	if (!found)
		memset(pending->counter, 0, sizeof(pending->counter));
	pending->counter[type] += ntup;
	spock_channel_pending_dirty = true;
}

/*
 * Add the counts of the transaction that just committed to the shared
 * entries, creating those that do not exist yet.
 */
void
spock_stat_channel_flush(void)
{
	HASH_SEQ_STATUS seq;
	SpockChannelPending *pending;

	if (!spock_channel_pending_dirty)
		return;

	hash_seq_init(&seq, SpockChannelPendingHash);
	while ((pending = hash_seq_search(&seq)) != NULL)
	{
		PgStat_EntryRef *ref;
		Spock_Stat_Channel *shent;
		bool		any = false;
		int			i;

		for (i = 0; i < SPOCK_STATS_NUM_COUNTERS; i++)
			any |= pending->counter[i] != 0;
		if (!any)
			continue;

		ref = pgstat_get_entry_ref(SPOCK_PGSTAT_KIND_CHANNEL, MyDatabaseId,
								   SPOCK_CHANNEL_OBJID(pending->key.subid,
													   pending->key.relid),
								   true, NULL);
		shent = (Spock_Stat_Channel *) ref->shared_stats;

		(void) pgstat_lock_entry(ref, false);
		for (i = 0; i < SPOCK_STATS_NUM_COUNTERS; i++)
			shent->stats.counter[i] += pending->counter[i];
		pgstat_unlock_entry(ref);

		memset(pending->counter, 0, sizeof(pending->counter));
	}

	spock_channel_pending_dirty = false;
}

/*
 * Forget the counts of a transaction that did not commit.
 */
void
spock_stat_channel_discard(void)
{
	HASH_SEQ_STATUS seq;
	SpockChannelPending *pending;

	if (!spock_channel_pending_dirty)
		return;

	hash_seq_init(&seq, SpockChannelPendingHash);
	while ((pending = hash_seq_search(&seq)) != NULL)
		memset(pending->counter, 0, sizeof(pending->counter));

	spock_channel_pending_dirty = false;
}

void
spock_stat_channel_foreach(SpockPgstatCallback cb, void *arg)
{
	spock_pgstat_foreach(SPOCK_PGSTAT_KIND_CHANNEL, cb, arg);
}

long
spock_stat_channel_entries(Oid dboid)
{
	return spock_pgstat_count(SPOCK_PGSTAT_KIND_CHANNEL, dboid);
}

void
spock_stat_channel_drop_all(void)
{
	spock_pgstat_drop_all(SPOCK_PGSTAT_KIND_CHANNEL);
}

bool
spock_stat_channel_seed(Oid dboid, Oid subid, Oid relid,
						const Spock_Stat_ChannelEntry *stats)
{
	return spock_pgstat_seed(SPOCK_PGSTAT_KIND_CHANNEL, dboid,
							 SPOCK_CHANNEL_OBJID(subid, relid),
							 stats, sizeof(Spock_Stat_ChannelEntry));
}

#endif							/* PG_VERSION_NUM >= 180000 */
