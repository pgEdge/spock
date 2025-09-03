/*-------------------------------------------------------------------------
 *
 * spock_apply.h
 * 		spock apply functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_APPLY_H
#define SPOCK_APPLY_H

#include "storage/condition_variable.h"

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

/* my_exception_log_index belongs here, and not in the exception handler
 * since it's specific to each apply worker.
 */
extern int my_exception_log_index;

extern void wait_for_previous_transaction(void);
extern void awake_transaction_waiters(void);

extern void create_progress_entry(Oid target_node_id,
								Oid remote_node_id,
								TimestampTz remote_commit_ts);
extern TimestampTz get_progress_entry_ts(Oid target_node_id,
								Oid remote_node_id,
								XLogRecPtr *lsn,
								XLogRecPtr *remote_insert_lsn,
								bool *missing);
extern void get_apply_group_entry(Oid dbid,
								RepOriginId replorigin,
								int *indexPtr,
								bool *foundPtr);

extern void update_progress_entry(Oid target_node_id,
								Oid remote_node_id,
								TimestampTz remote_commit_ts,
								XLogRecPtr remote_lsn,
								XLogRecPtr remote_insert_lsn,
								TimestampTz last_updated_ts,
								bool updated_by_decode);

extern void spock_apply_group_shmem_init(void);

#endif /* SPOCK_APPLY_H */
