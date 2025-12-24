/*-------------------------------------------------------------------------
 *
 * spock_output_plugin.h
 *		spock output plugin
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_OUTPUT_PLUGIN_H
#define SPOCK_OUTPUT_PLUGIN_H

#include "nodes/pg_list.h"
#include "nodes/primnodes.h"
#include "replication/logical.h"
#include "storage/lock.h"

/* summon cross-PG-version compatibility voodoo */
#include "spock_compat.h"

/* typedef appears in spock_output_plugin.h */
typedef struct SpockOutputData
{
	MemoryContext context;

	struct SpockProtoAPI *api;

	/* Cached node id */
	Oid			local_node_id;

	/* protocol */
	bool		allow_internal_basetypes;
	bool		allow_binary_basetypes;
	bool		forward_changeset_origins;
	int			field_datum_encoding;

	/*
	 * client info
	 *
	 * Lots of this should move to a separate shorter-lived struct used only
	 * during parameter reading, since it contains what the client asked for.
	 * Once we've processed this during startup we don't refer to it again.
	 */
	uint32		client_pg_version;
	uint32		client_max_proto_version;
	uint32		client_min_proto_version;
	const char *client_expected_encoding;
	const char *client_protocol_format;
	uint32		client_binary_basetypes_major_version;
	bool		client_want_internal_basetypes_set;
	bool		client_want_internal_basetypes;
	bool		client_want_binary_basetypes_set;
	bool		client_want_binary_basetypes;
	bool		client_binary_bigendian_set;
	bool		client_binary_bigendian;
	uint32		client_binary_sizeofdatum;
	uint32		client_binary_sizeofint;
	uint32		client_binary_sizeoflong;
	bool		client_binary_float4byval_set;
	bool		client_binary_float4byval;
	bool		client_binary_float8byval_set;
	bool		client_binary_float8byval;
	bool		client_binary_intdatetimes_set;
	bool		client_binary_intdatetimes;
	bool		client_no_txinfo;

	/* Spock version related parameters. */
	int			startup_params_format;
	const char *spock_version;
	int			spock_version_num;

	/* Protocol version negotiation */
	uint32		negotiated_proto_version;

	/* List of origin names */
	List	   *forward_origins;
	/* List of SpockRepSet */
	List	   *replication_sets;
	RangeVar   *replicate_only_table;
} SpockOutputData;

/*
 * Shared memory information per slot-group
 */
typedef struct SpockOutputSlotGroup
{
	NameData	name;
	LWLock	   *lock;
	int			nattached;
	XLogRecPtr	last_lsn;
	TimestampTz last_commit_ts;
} SpockOutputSlotGroup;

/*
 * Custom WAL messages
 */
extern bool spock_replication_repair_mode;

#define SPOCK_REPAIR_MODE_ON		1	/* Suppress subsequent DML/DDL */
#define SPOCK_REPAIR_MODE_OFF		2	/* Resume regular replication */
#define SPOCK_SYNC_EVENT_MSG		3	/* Sync event message */

typedef struct SpockWalMessageSimple
{
	int32		mtype;
} SpockWalMessageSimple;

typedef union SpockWalMessage
{
	int32		mtype;
	SpockWalMessageSimple simple;
} SpockWalMessage;

typedef struct SpockSyncEventMessage
{
	int32		mtype;

	Oid			eorigin;		/* event origin */
	NameData	ename;			/* event name */
} SpockSyncEventMessage;

extern void _PG_output_plugin_init(OutputPluginCallbacks *cb);
extern Size spock_output_plugin_shmem_size(int nworkers);

#endif							/* SPOCK_OUTPUT_PLUGIN_H */
