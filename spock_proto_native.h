/*-------------------------------------------------------------------------
 *
 * spock_proto_native.h
 *		spock protocol, native implementation
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_PROTO_NATIVE_H
#define SPOCK_PROTO_NATIVE_H

#include "lib/stringinfo.h"

#include "utils/timestamp.h"

#include "spock_output_plugin.h"
#include "spock_output_proto.h"
#include "spock_relcache.h"

typedef struct SpockTupleData
{
	Datum	values[MaxTupleAttributeNumber];
	bool	nulls[MaxTupleAttributeNumber];
	bool	changed[MaxTupleAttributeNumber];
} SpockTupleData;

extern void spock_write_rel(StringInfo out, SpockOutputData *data,
		Relation rel, Bitmapset *att_list);
extern void spock_write_begin(StringInfo out, SpockOutputData *data,
		ReorderBufferTXN *txn);
extern void spock_write_commit(StringInfo out, SpockOutputData *data,
		ReorderBufferTXN *txn, XLogRecPtr commit_lsn);
extern void spock_write_origin(StringInfo out, const RepOriginId origin_id,
		XLogRecPtr origin_lsn);
extern void spock_write_insert(StringInfo out, SpockOutputData *data,
		Relation rel, HeapTuple newtuple, Bitmapset *att_list);
extern void spock_write_update(StringInfo out, SpockOutputData *data,
		Relation rel, HeapTuple oldtuple, HeapTuple newtuple,
		Bitmapset *att_list);
extern void spock_write_delete(StringInfo out, SpockOutputData *data,
		Relation rel, HeapTuple oldtuple, Bitmapset *att_list);
extern void write_startup_message(StringInfo out, List *msg);
extern void spock_write_truncate(StringInfo out, int nrelids, Oid relids[],
								 bool cascade, bool restart_seqs);

extern void spock_read_begin(StringInfo in, XLogRecPtr *remote_lsn,
					  TimestampTz *committime, TransactionId *remote_xid);
extern void spock_read_commit(StringInfo in, XLogRecPtr *commit_lsn,
					   XLogRecPtr *end_lsn, TimestampTz *committime);
extern RepOriginId spock_read_origin(StringInfo in, XLogRecPtr *origin_lsn);
extern uint32 spock_read_rel(StringInfo in);
extern SpockRelation *spock_read_insert(StringInfo in, LOCKMODE lockmode,
					   SpockTupleData *newtup);
extern SpockRelation *spock_read_update(StringInfo in, LOCKMODE lockmode, bool *hasoldtup,
					   SpockTupleData *oldtup, SpockTupleData *newtup);
extern SpockRelation *spock_read_delete(StringInfo in, LOCKMODE lockmode,
												 SpockTupleData *oldtup);
extern List *spock_read_truncate(StringInfo in, bool *cascade, bool *restart_seqs);

#endif /* SPOCK_PROTO_NATIVE_H */
