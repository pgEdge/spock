/*-------------------------------------------------------------------------
 *
 * spock_output_plugin.h
 *		spock output plugin
 *
 * Copyright (c) 2021-2022, OSCG Partners, LLC
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_OUTPUT_PLUGIN_H
#define SPOCK_OUTPUT_PLUGIN_H

#include "nodes/pg_list.h"
#include "nodes/primnodes.h"

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

	/* List of origin names */
    List	   *forward_origins;
	/* List of SpockRepSet */
	List	   *replication_sets;
	RangeVar   *replicate_only_table;
} SpockOutputData;

#endif /* SPOCK_OUTPUT_PLUGIN_H */
