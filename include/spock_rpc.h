/*-------------------------------------------------------------------------
 *
 * spock_rpc.h
 *				Remote calls
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_RPC_H
#define SPOCK_RPC_H

#include "libpq-fe.h"
#include "spock_node.h"

extern List *spock_get_remote_repset_tables(PGconn *conn,
											List *replication_sets,
											List *skip_schemas);
extern SpockRemoteRel *spock_get_remote_repset_table(PGconn *conn,
													 RangeVar *rv, List *replication_sets);

/*
 * Minimal schema-qualified relation identity, used by structure sync to
 * carry (nspname, relname) pairs returned by the publisher.
 */
typedef struct SpockRemoteRelId
{
	char	   *nspname;
	char	   *relname;
} SpockRemoteRelId;

extern List *spock_get_repset_excluded_tables(PGconn *conn,
											  List *schemas,
											  List *repset_tables);

extern List *spock_get_remote_user_schemas(PGconn *conn,
										   List *skip_schemas);

extern bool spock_remote_slot_active(PGconn *conn, const char *slot_name);
extern void spock_drop_remote_slot(PGconn *conn, const char *slot_name);
extern SpockNode *spock_remote_node_info(PGconn *conn, char **sysid,
										 char **dbname, char **replication_sets);

#endif							/* SPOCK_RPC_H */
