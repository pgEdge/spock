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

/*
 * The first release whose nodes keep spock.toast_suspect.  The repair worker
 * relies on the winner having one, so detection records nothing for changes
 * from an older sender.
 */
#define SPOCK_TOAST_MIN_SENDER_VERSION_NUM 60100

extern void spock_toast_suspect_record(SpockRelation *rel,
									   TupleTableSlot *newslot,
									   SpockTupleData *newtup,
									   bool local_origin_found,
									   RepOriginId local_origin,
									   TimestampTz local_ts);
extern Datum spock_toast_divergence_verify(PG_FUNCTION_ARGS);

extern void toast_divergence_close_cached_conns(void);

#endif							/* SPOCK_TOAST_DIVERGENCE_H */
