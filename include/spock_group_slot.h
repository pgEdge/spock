/*-------------------------------------------------------------------------
 *
 * spock_group_slot.h
 *		Group replication slot subsystem (BDR/PGD-style group slots).
 *
 * A group slot is a single, internally managed, inactive logical
 * replication slot per Spock database/group.  It tracks the oldest safe
 * WAL position for the whole group so that WAL required by any active or
 * relevant downstream member is retained until every required member has
 * confirmed durable progress for the current membership generation.
 *
 * The heavy decision logic lives in SQL (see spock.group_slot_* functions)
 * so that all safety decisions are durable and auditable in catalog tables.
 * This module owns the deterministic slot naming, the per-database
 * background worker that periodically drives the SQL "tick", and the
 * node-initialization hook that seeds the durable metadata.
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

/*
 * Prefix for internally managed group slots.  Deliberately does NOT match
 * the "spk_.*" pattern used to bulk-drop per-subscription slots so that
 * normal subscription/node cleanup never removes a group slot by accident.
 */
#define SPOCK_GROUP_SLOT_PREFIX "spkgrp_"

/*
 * spock.group_slots_safety_mode values.
 */
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

/*
 * Build the deterministic group slot name for the current database and
 * local node into the supplied Name buffer.  Returns false when there is no
 * local node configured yet.
 */
extern bool spock_build_local_group_slot_name(Name out_name);

/*
 * Node-initialization hook: seed durable group-slot metadata for the freshly
 * created local node.  Safe no-op when the feature is disabled.  Must be
 * called from within an open transaction (e.g. spock_create_node()).
 */
extern void spock_group_slot_init_local(Oid node_id);

/*
 * Deliberately drop the local group slot and its metadata.  Called only from
 * spock_drop_node() when the local node itself is removed.
 */
extern void spock_group_slot_drop_local(void);

/* Background worker entry point (registered per database by the manager). */
PGDLLEXPORT void spock_group_slot_main(Datum main_arg);

#endif							/* SPOCK_GROUP_SLOT_H */
