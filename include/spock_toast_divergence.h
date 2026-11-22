/*-------------------------------------------------------------------------
 *
 * spock_toast_divergence.h
 *		Detection and verification of TOAST column divergence
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_TOAST_DIVERGENCE_H
#define SPOCK_TOAST_DIVERGENCE_H

#include "executor/tuptable.h"
#include "fmgr.h"
#include "replication/origin.h"
#include "utils/timestamp.h"

#include "spock_proto_native.h"
#include "spock_relcache.h"

extern void spock_toast_suspect_record(SpockRelation *rel,
									   TupleTableSlot *newslot,
									   SpockTupleData *newtup,
									   bool local_origin_found,
									   RepOriginId local_origin,
									   TimestampTz local_ts);
extern Datum spock_toast_divergence_verify(PG_FUNCTION_ARGS);

#endif							/* SPOCK_TOAST_DIVERGENCE_H */
