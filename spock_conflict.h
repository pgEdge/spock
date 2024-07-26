/*-------------------------------------------------------------------------
 *
 * spock_conflict.h
 *		spock conflict detection and resolution
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_CONGLICT_H
#define SPOCK_CONGLICT_H

#include "nodes/execnodes.h"

#include "utils/guc.h"

#include "spock_proto_native.h"

/* conflict log table */
#define CATALOG_LOGTABLE "resolutions"
#define SPOCK_LOG_TABLE_COLS 16

extern TransactionId remote_xid;

typedef enum SpockConflictResolution
{
	SpockResolution_ApplyRemote,
	SpockResolution_KeepLocal,
	SpockResolution_Skip
} SpockConflictResolution;

typedef enum
{
	SPOCK_RESOLVE_ERROR,
	SPOCK_RESOLVE_APPLY_REMOTE,
	SPOCK_RESOLVE_KEEP_LOCAL,
	SPOCK_RESOLVE_LAST_UPDATE_WINS,
	SPOCK_RESOLVE_FIRST_UPDATE_WINS
} SpockResolveOption;

extern int spock_conflict_resolver;
extern int spock_conflict_log_level;
extern bool	spock_save_resolutions;

typedef enum SpockConflictType
{
	CONFLICT_INSERT_INSERT,
	CONFLICT_UPDATE_UPDATE,
	CONFLICT_UPDATE_DELETE,
	CONFLICT_DELETE_DELETE
} SpockConflictType;

extern bool spock_tuple_find_replidx(ResultRelInfo *relinfo,
										 SpockTupleData *tuple,
										 TupleTableSlot *oldslot,
										 Oid *idxrelid);

extern Oid spock_tuple_find_conflict(ResultRelInfo *relinfo,
										 SpockTupleData *tuple,
										 TupleTableSlot *oldslot);

extern bool get_tuple_origin(SpockRelation *rel, HeapTuple local_tuple,
							 ItemPointer tid, TransactionId *xmin,
							 RepOriginId *local_origin, TimestampTz *local_ts);

extern bool try_resolve_conflict(Relation rel, HeapTuple localtuple,
								 HeapTuple remotetuple, HeapTuple *resulttuple,
								 RepOriginId local_origin, TimestampTz local_ts,
								 SpockConflictResolution *resolution);


extern void spock_report_conflict(SpockConflictType conflict_type,
						  SpockRelation *rel,
						  HeapTuple localtuple,
						  SpockTupleData *oldkey,
						  HeapTuple remotetuple,
						  HeapTuple applytuple,
						  SpockConflictResolution resolution,
						  TransactionId local_tuple_xid,
						  bool found_local_origin,
						  RepOriginId local_tuple_origin,
						  TimestampTz local_tuple_timestamp,
						  Oid conflict_idx_id,
						  bool has_before_triggers);

extern void spock_conflict_log_table(SpockConflictType conflict_type,
						  SpockRelation *rel,
						  HeapTuple localtuple,
						  SpockTupleData *oldkey,
						  HeapTuple remotetuple,
						  HeapTuple applytuple,
						  SpockConflictResolution resolution,
						  TransactionId local_tuple_xid,
						  bool found_local_origin,
						  RepOriginId local_tuple_origin,
						  TimestampTz local_tuple_timestamp,
						  Oid conflict_idx_id,
						  bool has_before_triggers);
extern Oid get_conflict_log_table_oid(void);
extern Oid get_conflict_log_seq(void);
extern bool spock_conflict_resolver_check_hook(int *newval, void **extra,
									   GucSource source);

extern void tuple_to_stringinfo(StringInfo s, TupleDesc tupdesc,
	HeapTuple tuple);

#endif /* SPOCK_CONGLICT_H */
