/*-------------------------------------------------------------------------
 *
 * spock_pgstat.c
 *		helpers over the custom cumulative statistics kinds of spock
 *
 * The cumulative statistics system keeps variable-numbered entries in a
 * shared hash that it only exposes one entry at a time.  The monitoring
 * views list every entry of a kind, the reset functions drop them, and
 * the on-disk copy recreates them after a crash, so this is where the
 * hash is walked for the kinds spock registers.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#if PG_VERSION_NUM >= 180000

#include "lib/dshash.h"
#include "utils/dsa.h"
#include "utils/memutils.h"

#include "spock_pgstat.h"

/*
 * Call cb for every entry of a kind, with a copy of its data taken under
 * the entry lock.  A partition of the shared hash stays locked for the
 * scan, so cb only collects what it is given, into memory it has already.
 */
void
spock_pgstat_foreach(PgStat_Kind kind, SpockPgstatCallback cb, void *arg)
{
	dshash_seq_status hstat;
	PgStatShared_HashEntry *p;
	Size		len = pgstat_get_kind_info(kind)->shared_data_len;
	char	   *buf = palloc(len);

	dshash_seq_init(&hstat, pgStatLocal.shared_hash, false);
	while ((p = dshash_seq_next(&hstat)) != NULL)
	{
		PgStatShared_Common *header;

		if (p->key.kind != kind || p->dropped)
			continue;

		header = dsa_get_address(pgStatLocal.dsa, p->body);
		LWLockAcquire(&header->lock, LW_SHARED);
		/* nosemgrep */
		memcpy(buf, pgstat_get_entry_data(kind, header), len);
		LWLockRelease(&header->lock);

		cb(&p->key, buf, arg);
	}
	dshash_seq_term(&hstat);

	pfree(buf);
}

/* The number of entries of a kind, in one database or in all for InvalidOid. */
static void
spock_pgstat_count_cb(const PgStat_HashKey *key, const void *data, void *arg)
{
	long	   *count = arg;

	(*count)++;
}

long
spock_pgstat_count(PgStat_Kind kind, Oid dboid)
{
	dshash_seq_status hstat;
	PgStatShared_HashEntry *p;
	long		count = 0;

	if (!OidIsValid(dboid))
	{
		spock_pgstat_foreach(kind, spock_pgstat_count_cb, &count);
		return count;
	}

	dshash_seq_init(&hstat, pgStatLocal.shared_hash, false);
	while ((p = dshash_seq_next(&hstat)) != NULL)
	{
		if (p->key.kind == kind && p->key.dboid == dboid && !p->dropped)
			count++;
	}
	dshash_seq_term(&hstat);

	return count;
}

/*
 * Create the entry of a kind with the given data, unless it exists.  Used
 * to put back what the on-disk copy has after a crash, when the
 * statistics system starts empty; after a clean restart it restored its
 * own file and the entry is left alone.  Returns whether it was created.
 */
bool
spock_pgstat_seed(PgStat_Kind kind, Oid dboid, uint64 objid,
				  const void *data, Size len)
{
	PgStat_EntryRef *ref;
	bool		created = false;

	Assert(len == pgstat_get_kind_info(kind)->shared_data_len);

	ref = pgstat_get_entry_ref(kind, dboid, objid, true, &created);
	if (ref == NULL || !created)
		return false;

	(void) pgstat_lock_entry(ref, false);
	/* nosemgrep */
	memcpy(pgstat_get_entry_data(kind, ref->shared_stats), data, len);
	pgstat_unlock_entry(ref);

	return true;
}

/* Drop every entry of a kind, in all databases. */
typedef struct SpockPgstatKeys
{
	PgStat_HashKey *keys;
	int			count;
	int			room;
} SpockPgstatKeys;

/*
 * Runs under a partition lock of the statistics hash, where an allocation
 * must not fail: the array is sized beforehand, and a key that does not
 * fit is left for the next call.
 */
static void
spock_pgstat_collect_cb(const PgStat_HashKey *key, const void *data, void *arg)
{
	SpockPgstatKeys *keys = arg;

	if (keys->count < keys->room)
		keys->keys[keys->count++] = *key;
}

void
spock_pgstat_drop_all(PgStat_Kind kind)
{
	SpockPgstatKeys keys;
	int			not_freed = 0;
	int			i;

	keys.room = spock_pgstat_count(kind, InvalidOid) + 64;
	keys.count = 0;
	keys.keys = palloc(keys.room * sizeof(PgStat_HashKey));

	/* Collect first: dropping while scanning would modify the hash. */
	spock_pgstat_foreach(kind, spock_pgstat_collect_cb, &keys);

	for (i = 0; i < keys.count; i++)
	{
		bool		freed;

#if PG_VERSION_NUM >= 190000
		/* An entry dropped by someone else meanwhile is not an error. */
		freed = pgstat_drop_entry(kind, keys.keys[i].dboid, keys.keys[i].objid,
								  true);
#else
		freed = pgstat_drop_entry(kind, keys.keys[i].dboid, keys.keys[i].objid);
#endif
		if (!freed)
			not_freed++;
	}

	/* Entries other backends still reference go once they let go. */
	if (not_freed > 0)
		pgstat_request_entry_refs_gc();

	pfree(keys.keys);
}

#endif							/* PG_VERSION_NUM >= 180000 */
