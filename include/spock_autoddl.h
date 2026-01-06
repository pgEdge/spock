/*-------------------------------------------------------------------------
 *
 * spock_autoddl.h
 * 		spock autoddl replication support
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_AUTODDL_H
#define SPOCK_AUTODDL_H

#include "postgres.h"

#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "tcop/utility.h"

/*
 * Central entry from ProcessUtility on origin/subscriber.
 * Decides if/how to replicate and performs enqueue via existing API.
 * Returns true if we queued the statement on the origin.
 */
void		spock_autoddl_process(PlannedStmt *pstmt,
								  const char *queryString,
								  ProcessUtilityContext context,
								  NodeTag toplevel_stmt);
void		add_ddl_to_repset(Node *parsetree);

#endif							/* SPOCK_AUTODDL_H */
