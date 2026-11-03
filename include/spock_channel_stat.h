/*-------------------------------------------------------------------------
 *
 * spock_channel_stat.h
 *		per-table replication counters in the cumulative statistics system
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_CHANNEL_STAT_H
#define SPOCK_CHANNEL_STAT_H

#include "postgres.h"

#if PG_VERSION_NUM >= 180000

#include "pgstat.h"

#include "spock_pgstat.h"
#include "spock_worker.h"

/*
 * The object id of an entry packs the subscription and the table.  The
 * provider side counts under subscription 0.
 */
#define SPOCK_CHANNEL_OBJID(subid, relid) \
	(((uint64) (subid) << 32) | (uint64) (relid))
#define SPOCK_CHANNEL_SUBID(objid)	((Oid) ((objid) >> 32))
#define SPOCK_CHANNEL_RELID(objid)	((Oid) ((objid) & 0xffffffff))

/* Shared statistics entry of one subscription and table. */
typedef struct Spock_Stat_ChannelEntry
{
	PgStat_Counter counter[SPOCK_STATS_NUM_COUNTERS];
	TimestampTz stat_reset_timestamp;
} Spock_Stat_ChannelEntry;

extern void spock_stat_register_channel_stat(void);

/* counting, in apply workers and walsenders */
extern void spock_stat_channel_count(Oid subid, Oid relid,
									 spockStatsType type, int ntup);
extern void spock_stat_channel_flush(void);
extern void spock_stat_channel_discard(void);

/* reading, resetting and restoring */
extern void spock_stat_channel_foreach(SpockPgstatCallback cb, void *arg);
extern long spock_stat_channel_entries(Oid dboid);
extern void spock_stat_channel_drop_all(void);
extern bool spock_stat_channel_seed(Oid dboid, Oid subid, Oid relid,
									const Spock_Stat_ChannelEntry *stats);

#endif							/* PG_VERSION_NUM >= 180000 */

#endif							/* SPOCK_CHANNEL_STAT_H */
