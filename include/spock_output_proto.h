/*-------------------------------------------------------------------------
 *
 * spock_output_proto.h
 *		spock protocol
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_OUTPUT_PROTO_H
#define SPOCK_OUTPUT_PROTO_H

#include "lib/stringinfo.h"
#include "replication/reorderbuffer.h"
#include "utils/relcache.h"

#include "spock_output_plugin.h"

/*
 * Protocol capabilities
 *
 * SPOCK_PROTO_VERSION_NUM is our native protocol and the greatest version
 * we can support. SPOCK_PROTO_MIN_VERSION_NUM is the oldest version we
 * have backwards compatibility for. We negotiate protocol versions during the
 * startup handshake. See the protocol documentation for details.
 *
 * SPOCK_MIN_VERSION_NUM_FOR_MULTI_PROTO is the minimum Spock version that
 * supports multi-protocol mode (protocol versions 4 and 5). Both nodes must
 * be at least this version to use protocol version 4.
 */
#define SPOCK_PROTO_VERSION_NUM 5
#define SPOCK_PROTO_MIN_VERSION_NUM 4
#define SPOCK_MIN_VERSION_NUM_FOR_MULTI_PROTO 50000

/*
 * The startup parameter format is versioned separately to the rest of the wire
 * protocol because we negotiate the wire protocol version using the startup
 * parameters sent to us. It hopefully won't ever need to change, but this
 * field is present in case we do need to change it, e.g. to a structured json
 * object. We can look at the startup params version to see whether we can
 * understand the startup params sent by the client and to fall back to
 * reading an older format if needed.
 */
#define SPOCK_STARTUP_PARAM_FORMAT_FLAT 1

/*
 * For similar reasons to the startup params
 * (SPOCK_STARTUP_PARAM_FORMAT_FLAT) the startup reply message format is
 * versioned separately to the rest of the protocol. The client has to be able
 * to read it to find out what protocol version was selected by the upstream
 * when using the native protocol.
 */
#define SPOCK_STARTUP_MSG_FORMAT_FLAT 1

#define TRUNCATE_CASCADE		(1<<0)
#define TRUNCATE_RESTART_SEQS	(1<<1)

typedef enum SpockProtoType
{
	SpockProtoNative,
	SpockProtoJson
} SpockProtoType;

typedef void (*spock_write_commit_order_fn) (StringInfo out,
											 TimestampTz last_commit_ts);
typedef void (*spock_write_rel_fn) (StringInfo out, SpockOutputData *data,
									Relation rel, Bitmapset *att_list);

typedef void (*spock_write_begin_fn) (StringInfo out, SpockOutputData *data,
									  ReorderBufferTXN *txn);
typedef void (*spock_write_commit_fn) (StringInfo out, SpockOutputData *data,
									   ReorderBufferTXN *txn, XLogRecPtr commit_lsn);

typedef void (*spock_write_origin_fn) (StringInfo out,
									   const RepOriginId origin_id,
									   XLogRecPtr origin_lsn,
									   const char *origin_name);

typedef void (*spock_write_insert_fn) (StringInfo out, SpockOutputData *data,
									   Relation rel, HeapTuple newtuple,
									   Bitmapset *att_list);
typedef void (*spock_write_update_fn) (StringInfo out, SpockOutputData *data,
									   Relation rel, HeapTuple oldtuple,
									   HeapTuple newtuple,
									   Bitmapset *att_list);
typedef void (*spock_write_delete_fn) (StringInfo out, SpockOutputData *data,
									   Relation rel, HeapTuple oldtuple,
									   Bitmapset *att_list);

typedef void (*write_startup_message_fn) (StringInfo out, List *msg);
typedef void (*spock_write_truncate_fn) (StringInfo out, int nrelids,
										 Oid relids[], bool cascade,
										 bool restart_seqs);
typedef void (*spock_write_message_fn) (StringInfo out, TransactionId xid,
										XLogRecPtr lsn, bool transactional,
										const char *prefix, Size sz,
										const char *message);

typedef struct SpockProtoAPI
{
	spock_write_commit_order_fn write_commit_order;
	spock_write_rel_fn write_rel;
	spock_write_begin_fn write_begin;
	spock_write_commit_fn write_commit;
	spock_write_origin_fn write_origin;
	spock_write_insert_fn write_insert;
	spock_write_update_fn write_update;
	spock_write_delete_fn write_delete;
	write_startup_message_fn write_startup_message;
	spock_write_truncate_fn write_truncate;
	spock_write_message_fn write_message;
} SpockProtoAPI;

extern SpockProtoAPI *spock_init_api(SpockProtoType typ);

#endif							/* SPOCK_OUTPUT_PROTO_H */
