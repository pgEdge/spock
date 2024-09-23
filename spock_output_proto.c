/*-------------------------------------------------------------------------
 *
 * spock_proto.c
 * 		spock protocol functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "replication/reorderbuffer.h"
#include "spock_output_plugin.h"

#include "spock_output_proto.h"
#include "spock_proto_native.h"
#include "spock_proto_json.h"

SpockProtoAPI *
spock_init_api(SpockProtoType typ)
{
	SpockProtoAPI  *res = palloc0(sizeof(SpockProtoAPI));

	if (typ == SpockProtoJson)
	{
		res->write_rel = NULL;
		res->write_begin = spock_json_write_begin;
		res->write_commit = spock_json_write_commit;
		res->write_origin = NULL;
		res->write_commit_order = NULL;
		res->write_insert = spock_json_write_insert;
		res->write_update = spock_json_write_update;
		res->write_delete = spock_json_write_delete;
		res->write_startup_message = json_write_startup_message;
		res->write_truncate = NULL;
	}
	else
	{
		res->write_rel = spock_write_rel;
		res->write_begin = spock_write_begin;
		res->write_commit = spock_write_commit;
		res->write_origin = spock_write_origin;
		res->write_commit_order = spock_write_commit_order;
		res->write_insert = spock_write_insert;
		res->write_update = spock_write_update;
		res->write_delete = spock_write_delete;
		res->write_startup_message = write_startup_message;
		res->write_truncate = spock_write_truncate;
	}

	return res;
}
