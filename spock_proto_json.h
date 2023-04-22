/*-------------------------------------------------------------------------
 *
 * spock_proto_json.h
 *		spock protocol, json implementation
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_PROTO_JSON_H
#define SPOCK_PROTO_JSON_H

#include "spock_output_plugin.h"

#include "lib/stringinfo.h"
#include "nodes/pg_list.h"

#include "spock_output_proto.h"

extern void spock_json_write_begin(StringInfo out, SpockOutputData *data,
								 ReorderBufferTXN *txn);
extern void spock_json_write_commit(StringInfo out, SpockOutputData *data,
								 ReorderBufferTXN *txn, XLogRecPtr commit_lsn);
extern void spock_json_write_insert(StringInfo out, SpockOutputData *data,
								 Relation rel, HeapTuple newtuple,
								 Bitmapset *att_list);
extern void spock_json_write_update(StringInfo out, SpockOutputData *data,
								 Relation rel, HeapTuple oldtuple,
								 HeapTuple newtuple, Bitmapset *att_list);
extern void spock_json_write_delete(StringInfo out, SpockOutputData *data,
								 Relation rel, HeapTuple oldtuple,
								 Bitmapset *att_list);
extern void json_write_startup_message(StringInfo out, List *msg);

#endif /* SPOCK_PROTO_JSON_H */
