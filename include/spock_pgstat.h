/*-------------------------------------------------------------------------
 *
 * spock_pgstat.h
 *		helpers over the custom cumulative statistics kinds of spock
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_PGSTAT_H
#define SPOCK_PGSTAT_H

#include "postgres.h"

#if PG_VERSION_NUM >= 180000

#include "pgstat.h"
#include "utils/pgstat_internal.h"

/*
 * Called for every entry of a kind with a copy of its data.  Runs while
 * the shared hash is being scanned, so it only collects.
 */
typedef void (*SpockPgstatCallback) (const PgStat_HashKey *key,
									 const void *data, void *arg);

extern void spock_pgstat_foreach(PgStat_Kind kind, SpockPgstatCallback cb,
								 void *arg);
extern long spock_pgstat_count(PgStat_Kind kind, Oid dboid);
extern bool spock_pgstat_seed(PgStat_Kind kind, Oid dboid, uint64 objid,
							  const void *data, Size len);
extern void spock_pgstat_drop_all(PgStat_Kind kind);

#endif							/* PG_VERSION_NUM >= 180000 */

#endif							/* SPOCK_PGSTAT_H */
