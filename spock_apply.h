/*-------------------------------------------------------------------------
 *
 * spock_apply.h
 * 		spock apply functions
 *
 * Copyright (c) 2021-2022, OSCG Partners, LLC
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_APPLY_H
#define SPOCK_APPLY_H

#include "spock_relcache.h"
#include "spock_proto_native.h"

typedef void (*spock_apply_begin_fn) (void);
typedef void (*spock_apply_commit_fn) (void);

typedef void (*spock_apply_insert_fn) (SpockRelation *rel,
									   SpockTupleData *newtup);
typedef void (*spock_apply_update_fn) (SpockRelation *rel,
									   SpockTupleData *oldtup,
									   SpockTupleData *newtup);
typedef void (*spock_apply_delete_fn) (SpockRelation *rel,
									   SpockTupleData *oldtup);

typedef bool (*spock_apply_can_mi_fn) (SpockRelation *rel);
typedef void (*spock_apply_mi_add_tuple_fn) (SpockRelation *rel,
												 SpockTupleData *tup);
typedef void (*spock_apply_mi_finish_fn) (SpockRelation *rel);

#endif /* SPOCK_APPLY_H */
