/*-------------------------------------------------------------------------
 *
 * spock_rpc.h
 *				Remote calls
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
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
									List *replication_sets);
extern SpockRemoteRel *spock_get_remote_repset_table(PGconn *conn,
								  RangeVar *rv, List *replication_sets);

extern bool spock_remote_slot_active(PGconn *conn, const char *slot_name);
extern void spock_drop_remote_slot(PGconn *conn, const char *slot_name);
extern SpockNode *spock_remote_node_info(PGconn* conn, char **sysid,
								char **dbname, char **replication_sets);
extern bool spock_remote_function_exists(PGconn *conn, const char *nspname,
								 const char *proname, int nargs, char *argname);

#endif /* SPOCK_RPC_H */
