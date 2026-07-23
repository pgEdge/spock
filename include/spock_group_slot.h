/*-------------------------------------------------------------------------
 *
 * spock_group_slot.h
 *		Group replication slot subsystem.
 *
 * One inactive logical slot per database pins WAL at the oldest position
 * still needed by the group. Decision logic lives in the spock.group_slot_*
 * SQL functions; this module owns naming, the worker, and lifecycle hooks.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_GROUP_SLOT_H
#define SPOCK_GROUP_SLOT_H

#include "postgres.h"
#include "fmgr.h"

/* Prefix must not match the "spk_.*" per-subscription cleanup pattern. */
#define SPOCK_GROUP_SLOT_PREFIX "spkgrp_"

typedef enum SpockGroupSlotSafetyMode
{
	SPOCK_GROUP_SLOT_SAFETY_STRICT = 0, /* refuse any unsafe action */
	SPOCK_GROUP_SLOT_SAFETY_REPAIR,		/* allow guarded repair actions */
	SPOCK_GROUP_SLOT_SAFETY_OFF			/* advisory only (no advancement) */
} SpockGroupSlotSafetyMode;

/* GUCs (defined in spock.c) */
extern bool spock_group_slots_enabled;
extern int	spock_group_slots_worker_interval;
extern int	spock_group_slots_staleness_timeout;
extern int	spock_group_slots_safety_mode;

/* Build the local node's slot name; false when there is no local node. */
extern bool spock_build_local_group_slot_name(Name out_name);

/* Seed metadata for a new local node; call inside an open transaction. */
extern void spock_group_slot_init_local(Oid node_id);

/* Drop the local group slot and metadata (from spock_drop_node() only). */
extern void spock_group_slot_drop_local(void);

/* Worker entry point (registered per database by the manager). */
PGDLLEXPORT void spock_group_slot_main(Datum main_arg);

#endif							/* SPOCK_GROUP_SLOT_H */
