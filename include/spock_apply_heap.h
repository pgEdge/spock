/*-------------------------------------------------------------------------
 *
 * spock_apply_heap.h
 * 		spock apply functions using heap api
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_APPLY_HEAP_H
#define SPOCK_APPLY_HEAP_H

#include "spock_relcache.h"
#include "spock_proto_native.h"

extern void spock_apply_heap_begin(void);
extern void spock_apply_heap_commit(void);

extern void spock_apply_heap_insert(SpockRelation *rel,
									SpockTupleData *newtup);
extern void spock_apply_heap_update(SpockRelation *rel,
									SpockTupleData *oldtup,
									SpockTupleData *newtup);
extern void spock_apply_heap_delete(SpockRelation *rel,
									SpockTupleData *oldtup);


#endif							/* SPOCK_APPLY_HEAP_H */
