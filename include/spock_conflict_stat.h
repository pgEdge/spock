/*-------------------------------------------------------------------------
 *
 * spock_conflict_stat.h
 *		spock subscription conflict statistics
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_CONFLICT_STAT_H
#define SPOCK_CONFLICT_STAT_H

#include "postgres.h"

#if PG_VERSION_NUM >= 180000

#include "pgstat.h"

#include "spock_conflict.h"

/* Shared memory stats entry for spock subscription conflicts */
typedef struct Spock_Stat_StatSubEntry
{
	PgStat_Counter conflict_count[SPOCK_CONFLICT_NUM_TYPES];
	TimestampTz stat_reset_timestamp;
} Spock_Stat_StatSubEntry;

/* Pending (backend-local) entry for spock subscription conflicts */
typedef struct Spock_Stat_PendingSubEntry
{
	PgStat_Counter conflict_count[SPOCK_CONFLICT_NUM_TYPES];
} Spock_Stat_PendingSubEntry;

extern void spock_stat_register_conflict_stat(void);

extern void spock_stat_report_subscription_conflict(Oid subid,
													SpockConflictType type);
extern void spock_stat_create_subscription(Oid subid);
extern void spock_stat_drop_subscription(Oid subid);
extern Spock_Stat_StatSubEntry *spock_stat_fetch_stat_subscription(Oid subid);

#endif /* PG_VERSION_NUM >= 180000 */

#endif /* SPOCK_CONFLICT_STAT_H */