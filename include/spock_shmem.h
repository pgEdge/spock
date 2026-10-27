/*-------------------------------------------------------------------------
 *
 * spock_shmem.h
 *		Centralized shared memory initialization for Spock
 *
 * This module provides a single entry point for shared memory hook
 * registration, ensuring that:
 * - Only one set of shmem_request_hook/shmem_startup_hook is registered
 * - AddinShmemInitLock is acquired only once during initialization
 * - All subsystems have clear ownership and initialization order
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_SHMEM_H
#define SPOCK_SHMEM_H

/*
 * Main entry point for shared memory initialization.
 * Called from _PG_init() to register a single set of hooks.
 */
extern void spock_shmem_init(void);

/*
 * Whether the failover slot worker is connecting to
 * spock.failover_slots_database; see failover_slots_connect().
 */
extern bool spock_failover_slots_db_connecting(void);
extern void spock_set_failover_slots_db_connecting(bool connecting);

#endif							/* SPOCK_SHMEM_H */
