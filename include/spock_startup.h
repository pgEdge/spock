/*-------------------------------------------------------------------------
 *
 * spock_startup.h
 *		Startup gate: keep sessions off a restarted node until the apply
 *		workers have caught up with their providers
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_STARTUP_H
#define SPOCK_STARTUP_H

#include "access/xlogdefs.h"
#include "nodes/nodes.h"

/* GUCs, both in milliseconds; a drain timeout of -1 skips unreachable providers */
extern int	spock_startup_max_lag;
extern int	spock_startup_drain_timeout;

/* shmem setup */
extern void spock_startup_shmem_request(int nworkers);
extern void spock_startup_shmem_startup(bool found);

/* session side */
extern void spock_startup_gate_check(Node *utilityStmt);

/* supervisor and manager side */
extern void spock_startup_supervisor_listed(void);
extern void spock_startup_manager_begin(void);
extern bool spock_startup_manager_check(void);

/* apply worker side */
extern void spock_startup_apply_connecting(void);
extern void spock_startup_apply_attach(void);
extern void spock_startup_apply_progress(XLogRecPtr last_received,
										 bool in_remote_xact);

#endif							/* SPOCK_STARTUP_H */
