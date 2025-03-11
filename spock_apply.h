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

typedef struct ApplyExecutionData
{
	EState	   *estate;			/* executor state, used to track resources */

	SpockRelation *targetRel;	/* replication target rel */
	ResultRelInfo *targetRelInfo;	/* ResultRelInfo for same */
} ApplyExecutionData;

typedef struct ApplyState
{
	bool	state_cleaned;
	bool	clear_remoteslot;
	bool	clear_localslot;

	TupleTableSlot *remoteslot;
	TupleTableSlot *localslot;
	ApplyExecutionData *edata;
	EPQState	epqstate;
} ApplyState;

typedef void (*spock_apply_begin_fn) (void);
typedef void (*spock_apply_commit_fn) (void);

typedef void (*spock_apply_insert_fn) (SpockRelation *rel,
									   SpockTupleData *newtup,
									   ApplyState *astate);
typedef void (*spock_apply_update_fn) (SpockRelation *rel,
									   SpockTupleData *oldtup,
									   SpockTupleData *newtup,
									   ApplyState *astate);
typedef void (*spock_apply_delete_fn) (SpockRelation *rel,
									   SpockTupleData *oldtup,
									   ApplyState *astate);

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
								bool *missing);

extern void spock_apply_group_shmem_init(void);
extern void finish_edata(ApplyExecutionData *edata);

#endif /* SPOCK_APPLY_H */
