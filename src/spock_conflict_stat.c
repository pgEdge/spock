/*-------------------------------------------------------------------------
 *
 * spock_conflict_stat.c
 *		spock subscription conflict statistics
 *
 * NOTE: Unlike PostgreSQL subscription statistics, Spock statistics cannot be
 * cluster-wide because spock node ID, origin ID, and subscription ID are
 * unique only within a database.  Therefore, we use MyDatabaseId to identify
 * each statistics entry.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "funcapi.h"
#include "utils/pgstat_internal.h"

#include "spock.h"

PG_FUNCTION_INFO_V1(spock_get_subscription_stats);
PG_FUNCTION_INFO_V1(spock_reset_subscription_stats);

#if PG_VERSION_NUM >= 180000
#include "spock_conflict_stat.h"

/*
 * Kind ID reserved for statistics of spock replication conflicts.
 * TODO: see https://wiki.postgresql.org/wiki/CustomCumulativeStats to choose
 * specific value in production
 */
#define SPOCK_PGSTAT_KIND_LRCONFLICTS	28

/* Shared memory wrapper for spock subscription conflict stats */
typedef struct Spock_Stat_Subscription
{
	PgStatShared_Common		header;
	Spock_Stat_StatSubEntry	stats;
} Spock_Stat_Subscription;

/*
 * Column names for spock_get_subscription_stats(), indexed by
 * SpockConflictType.  Kept in sync with the enum via designated initializers
 * so that reordering the enum produces a compile-time error rather than
 * silently wrong output.
 */
static const char *const SpockConflictStatColNames[SPOCK_CONFLICT_NUM_TYPES] = {
	[SPOCK_CT_INSERT_EXISTS] = "confl_insert_exists",
	[SPOCK_CT_UPDATE_ORIGIN_DIFFERS] = "confl_update_origin_differs",
	[SPOCK_CT_UPDATE_EXISTS] = "confl_update_exists",
	[SPOCK_CT_UPDATE_MISSING] = "confl_update_missing",
	[SPOCK_CT_DELETE_ORIGIN_DIFFERS] = "confl_delete_origin_differs",
	[SPOCK_CT_DELETE_MISSING] = "confl_delete_missing",
};

static bool spock_stat_subscription_flush_cb(PgStat_EntryRef *entry_ref,
											 bool nowait);
static void spock_stat_subscription_reset_timestamp_cb(
													PgStatShared_Common *header,
													TimestampTz ts);

/*
 * We rely on the pgstat infrastructure here, employing spock's own conflict
 * detection algorithm with custom statistics storage.
 */

static const PgStat_KindInfo spock_conflict_stat = {
	.name = "spock_conflict_stat",
	.fixed_amount = false,
	.write_to_file = true,

	.shared_size = sizeof(Spock_Stat_Subscription),
	.shared_data_off = offsetof(Spock_Stat_Subscription, stats),
	.shared_data_len = sizeof(((Spock_Stat_Subscription *) 0)->stats),
	.pending_size = sizeof(Spock_Stat_PendingSubEntry),

	.flush_pending_cb = spock_stat_subscription_flush_cb,
	.reset_timestamp_cb = spock_stat_subscription_reset_timestamp_cb,
};

void
spock_stat_register_conflict_stat(void)
{
	pgstat_register_kind(SPOCK_PGSTAT_KIND_LRCONFLICTS, &spock_conflict_stat);
}

/*
 * Report a subscription conflict.
 */
void
spock_stat_report_subscription_conflict(Oid subid, SpockConflictType type)
{
	PgStat_EntryRef *entry_ref;
	Spock_Stat_PendingSubEntry *pending;

	if (type != SPOCK_CT_UPDATE_MISSING)
		/*
		 * Should happen only in development.  Detect it as fast as possible
		 * with the highest error level that does not crash the instance.
		 */
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("unexpected conflict type %d reported for subscription %u",
						type, subid)));

	entry_ref = pgstat_prep_pending_entry(SPOCK_PGSTAT_KIND_LRCONFLICTS,
										  MyDatabaseId, subid, NULL);
	pending = entry_ref->pending;
	pending->conflict_count[type]++;
}

/*
 * Report creating the subscription.
 */
void
spock_stat_create_subscription(Oid subid)
{
	PgStat_EntryRef *ref;

	/* Ensures that stats are dropped if transaction rolls back */
	pgstat_create_transactional(SPOCK_PGSTAT_KIND_LRCONFLICTS,
								MyDatabaseId, subid);

	/* Create and initialize the subscription stats entry */
	ref = pgstat_get_entry_ref(SPOCK_PGSTAT_KIND_LRCONFLICTS, MyDatabaseId, subid,
							   true, NULL);

	if (pg_atomic_read_u32(&ref->shared_entry->refcount) != 2)
		/*
		 * Should never happen: a new subscription stats entry should have
		 * exactly two references (the hashtable entry and our own).  A higher
		 * count means a stale entry from a previous subscription with the same
		 * OID was not properly cleaned up.
		 */
		ereport(WARNING,
				(errmsg("conflict statistics entry for subscription %u "
						"already has %u references",
						subid,
						pg_atomic_read_u32(&ref->shared_entry->refcount)),
				 errhint("This may indicate that a previous subscription with "
						 "the same OID was not fully dropped.")));

	pgstat_reset_entry(SPOCK_PGSTAT_KIND_LRCONFLICTS, MyDatabaseId, subid, 0);
}

/*
 * Report dropping the subscription.
 *
 * Ensures that stats are dropped if transaction commits.
 */
void
spock_stat_drop_subscription(Oid subid)
{
	pgstat_drop_transactional(SPOCK_PGSTAT_KIND_LRCONFLICTS,
							  MyDatabaseId, subid);
}

/*
 * Support function for the SQL-callable pgstat* functions. Returns
 * the collected statistics for one subscription or NULL.
 */
Spock_Stat_StatSubEntry *
spock_stat_fetch_stat_subscription(Oid subid)
{
	return (Spock_Stat_StatSubEntry *)
		pgstat_fetch_entry(SPOCK_PGSTAT_KIND_LRCONFLICTS, MyDatabaseId, subid);
}

/*
 * Get the subscription statistics for the given subscription. If the
 * subscription statistics is not available, return all-zeros stats.
 */
Datum
spock_get_subscription_stats(PG_FUNCTION_ARGS)
{
#define SPOCK_STAT_GET_SUBSCRIPTION_STATS_COLS	(1 + SPOCK_CONFLICT_NUM_TYPES + 1)
	Oid			subid = PG_GETARG_OID(0);
	TupleDesc	tupdesc;
	Datum		values[SPOCK_STAT_GET_SUBSCRIPTION_STATS_COLS] = {0};
	bool		nulls[SPOCK_STAT_GET_SUBSCRIPTION_STATS_COLS] = {0};
	Spock_Stat_StatSubEntry *subentry;
	Spock_Stat_StatSubEntry allzero;
	int			i = 0;
	AttrNumber	attnum = 1;

	/* Get subscription stats */
	subentry = spock_stat_fetch_stat_subscription(subid);

	/* Initialise attributes information in the tuple descriptor */
	tupdesc = CreateTemplateTupleDesc(SPOCK_STAT_GET_SUBSCRIPTION_STATS_COLS);
	TupleDescInitEntry(tupdesc, attnum++, "subid",
					   OIDOID, -1, 0);
	for (int c = 0; c < SPOCK_CONFLICT_NUM_TYPES; c++)
		TupleDescInitEntry(tupdesc, attnum++, SpockConflictStatColNames[c],
						   INT8OID, -1, 0);
	TupleDescInitEntry(tupdesc, attnum++, "stats_reset",
					   TIMESTAMPTZOID, -1, 0);
	BlessTupleDesc(tupdesc);

	if (!subentry)
	{
		/* If the subscription is not found, initialise its stats */
		memset(&allzero, 0, sizeof(Spock_Stat_StatSubEntry));
		subentry = &allzero;
	}

	/* subid */
	values[i++] = ObjectIdGetDatum(subid);

	/* conflict counts */
	for (int nconflict = 0; nconflict < SPOCK_CONFLICT_NUM_TYPES; nconflict++)
		values[i++] = Int64GetDatum(subentry->conflict_count[nconflict]);

	/* stats_reset */
	if (subentry->stat_reset_timestamp == 0)
		nulls[i] = true;
	else
		values[i] = TimestampTzGetDatum(subentry->stat_reset_timestamp);

	Assert(i + 1 == SPOCK_STAT_GET_SUBSCRIPTION_STATS_COLS);

	/* Returns the record as Datum */
	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}
#undef SPOCK_STAT_GET_SUBSCRIPTION_STATS_COLS

/* Reset subscription stats (a specific one or all of them) */
Datum
spock_reset_subscription_stats(PG_FUNCTION_ARGS)
{
	Oid			subid;

	if (PG_ARGISNULL(0))
	{
		/* Clear all subscription stats */
		pgstat_reset_of_kind(SPOCK_PGSTAT_KIND_LRCONFLICTS);
	}
	else
	{
		subid = PG_GETARG_OID(0);

		if (!OidIsValid(subid))
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("invalid subscription OID %u", subid)));
		pgstat_reset(SPOCK_PGSTAT_KIND_LRCONFLICTS, MyDatabaseId, subid);
	}

	PG_RETURN_VOID();
}

static bool
spock_stat_subscription_flush_cb(PgStat_EntryRef *entry_ref, bool nowait)
{
	Spock_Stat_PendingSubEntry *localent;
	Spock_Stat_Subscription *shsubent;

	localent = (Spock_Stat_PendingSubEntry *) entry_ref->pending;
	shsubent = (Spock_Stat_Subscription *) entry_ref->shared_stats;

	/* localent always has non-zero content */

	if (!pgstat_lock_entry(entry_ref, nowait))
		return false;

	for (int i = 0; i < SPOCK_CONFLICT_NUM_TYPES; i++)
		shsubent->stats.conflict_count[i] += localent->conflict_count[i];

	pgstat_unlock_entry(entry_ref);
	return true;
}

static void
spock_stat_subscription_reset_timestamp_cb(PgStatShared_Common *header,
										   TimestampTz ts)
{
	((Spock_Stat_Subscription *) header)->stats.stat_reset_timestamp = ts;
}

#endif /* PG_VERSION_NUM >= 180000 */

#if PG_VERSION_NUM < 180000

/*
 * XXX: implement conflict statistics gathering, if needed
 */

Datum
spock_get_subscription_stats(PG_FUNCTION_ARGS)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("spock conflict statistics require PostgreSQL 18 or later")));
	PG_RETURN_NULL(); /* unreachable; suppress compiler warning */
}

Datum
spock_reset_subscription_stats(PG_FUNCTION_ARGS)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("spock conflict statistics require PostgreSQL 18 or later")));
	PG_RETURN_NULL(); /* unreachable; suppress compiler warning */
}

#endif /* PG_VERSION_NUM < 180000 */
