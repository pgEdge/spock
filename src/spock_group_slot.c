/*-------------------------------------------------------------------------
 *
 * spock_group_slot.c
 *		Group replication slot subsystem (BDR/PGD-style group slots).
 *
 * This module provides:
 *   - Deterministic naming for the per-database group slot
 *     (spock.local_group_slot_name()).
 *   - A node-initialization hook that seeds durable group-slot metadata.
 *   - A per-database background worker that periodically drives the SQL-side
 *     "tick" which recomputes the group-safe horizon and, when every required
 *     member has fresh progress for the current membership generation and no
 *     blocker exists, advances the inactive group slot.
 *   - Deliberate teardown of the group slot when the local node is dropped.
 *
 * All safety decisions (safe/freeze LSN computation, membership-generation
 * gating, blocked-reason recording, advancement and repair) are implemented
 * in SQL (spock.group_slot_* functions) so that they are durable and
 * auditable in catalog tables and survive restarts without relying on shared
 * memory.  This C module is deliberately thin: it owns naming, scheduling and
 * lifecycle only.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"

#include "libpq/libpq-be.h"

#include "access/xact.h"
#include "commands/dbcommands.h"
#include "executor/spi.h"
#include "postmaster/interrupt.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/resowner.h"

#include "pgstat.h"

#include "spock.h"
#include "spock_node.h"
#include "spock_worker.h"
#include "spock_group_slot.h"

PG_FUNCTION_INFO_V1(spock_local_group_slot_name_sql);

/*
 * Build a group slot name from a database name and node name into the
 * supplied Name buffer.  The result only contains characters valid in a
 * replication slot name ([a-z0-9_]); any other character is replaced with an
 * underscore, matching gen_slot_name()'s behaviour.
 */
static void
build_group_slot_name(Name out_name, const char *dbname, const char *nodename)
{
	char	   *cp;

	memset(NameStr(*out_name), 0, NAMEDATALEN);
	snprintf(NameStr(*out_name), NAMEDATALEN,
			 "%s%s_%s",
			 SPOCK_GROUP_SLOT_PREFIX,
			 shorten_hash(dbname, 20),
			 shorten_hash(nodename, 20));
	NameStr(*out_name)[NAMEDATALEN - 1] = '\0';

	for (cp = NameStr(*out_name); *cp; cp++)
	{
		if (!((*cp >= 'a' && *cp <= 'z') ||
			  (*cp >= '0' && *cp <= '9') ||
			  (*cp == '_')))
			*cp = '_';
	}
}

/*
 * spock_build_local_group_slot_name
 *
 * Fill out_name with the deterministic group slot name for the current
 * database and local node.  Returns false when there is no local node.
 */
bool
spock_build_local_group_slot_name(Name out_name)
{
	SpockLocalNode *local;
	char	   *dbname;

	local = get_local_node(false, true);
	if (local == NULL)
		return false;

	dbname = get_database_name(MyDatabaseId);
	build_group_slot_name(out_name, dbname, local->node->name);
	return true;
}

/*
 * SQL: spock.local_group_slot_name() -> name
 *
 * Returns NULL when the current database is not configured as a Spock node.
 */
Datum
spock_local_group_slot_name_sql(PG_FUNCTION_ARGS)
{
	Name		out_name = (Name) palloc0(NAMEDATALEN);

	if (!spock_build_local_group_slot_name(out_name))
		PG_RETURN_NULL();

	PG_RETURN_NAME(out_name);
}

/*
 * spock_group_slot_init_local
 *
 * Seed durable group-slot metadata for a freshly created local node.  Called
 * from spock_create_node() while a transaction is open.  Does not create the
 * physical slot here: a logical replication slot cannot be created in a
 * transaction that has already performed writes, so the actual slot is
 * created by the background worker on its next tick (see
 * spock.group_slot_ensure()).
 *
 * No-op when the feature is disabled.
 */
void
spock_group_slot_init_local(Oid node_id)
{
	SpockNode  *node;
	NameData	slotname;
	char	   *dbname;
	Oid			argtypes[3];
	Datum		values[3];
	int			rc;

	if (!spock_group_slots_enabled)
		return;

	node = get_node(node_id, true);
	if (node == NULL)
		return;

	dbname = get_database_name(MyDatabaseId);
	build_group_slot_name(&slotname, dbname, node->name);

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		elog(WARNING, "spock group slot: SPI_connect failed during node init");
		return;
	}

	argtypes[0] = OIDOID;
	values[0] = ObjectIdGetDatum(node_id);
	argtypes[1] = OIDOID;
	values[1] = ObjectIdGetDatum(MyDatabaseId);
	argtypes[2] = NAMEOID;
	values[2] = NameGetDatum(&slotname);

	/*
	 * The metadata table is a user catalog table, which does not support ON
	 * CONFLICT, so guard the insert with an existence check.
	 */
	rc = SPI_execute_with_args(
		"INSERT INTO spock.group_slot_state (node_id, dboid, slot_name) "
		"SELECT $1, $2, $3 "
		" WHERE NOT EXISTS (SELECT 1 FROM spock.group_slot_state WHERE node_id = $1)",
		3, argtypes, values, NULL, false, 0);

	if (rc != SPI_OK_INSERT && rc != SPI_OK_INSERT_RETURNING)
		elog(WARNING, "spock group slot: metadata seed failed (rc=%d)", rc);

	SPI_finish();
}

/*
 * spock_group_slot_drop_local
 *
 * Deliberately tear down the local group slot and its metadata.  Called from
 * spock_drop_node() when the local node itself is being removed.  This is the
 * only path that removes a group slot; normal subscription/node cleanup never
 * touches it because the "spkgrp_" prefix does not match the "spk_.*" pattern
 * used to bulk-drop per-subscription slots.
 *
 * Tolerant of a missing metadata table (older extension) and of an active
 * slot (skipped rather than erroring).
 */
void
spock_group_slot_drop_local(void)
{
	int			rc;

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		elog(WARNING, "spock group slot: SPI_connect failed during node drop");
		return;
	}

	rc = SPI_execute(
		"DO $$ "
		"BEGIN "
		"  IF to_regclass('spock.group_slot_state') IS NULL THEN RETURN; END IF; "
		"  PERFORM pg_drop_replication_slot(s.slot_name) "
		"     FROM pg_replication_slots s "
		"     JOIN spock.group_slot_state g ON g.slot_name = s.slot_name "
		"    WHERE g.node_id = (SELECT node_id FROM spock.local_node) "
		"      AND NOT s.active; "
		"  DELETE FROM spock.group_slot_state "
		"   WHERE node_id = (SELECT node_id FROM spock.local_node); "
		"END $$;",
		false, 0);

	if (rc != SPI_OK_UTILITY && rc != SPI_OK_SELECT)
		elog(WARNING, "spock group slot: teardown failed (rc=%d)", rc);

	SPI_finish();
}

/*
 * Run a single maintenance tick by invoking the SQL orchestration function.
 * Errors are caught and logged so that a transient failure (for example a
 * momentarily missing slot mid-repair) does not tear down the worker.
 */
static void
spock_group_slot_do_tick(void)
{
	MemoryContext tickctx = CurrentMemoryContext;

	PG_TRY();
	{
		StartTransactionCommand();
		SPI_connect();
		PushActiveSnapshot(GetTransactionSnapshot());
		pgstat_report_activity(STATE_RUNNING,
							   "spock.group_slot_worker_tick()");

		SPI_execute("SELECT spock.group_slot_worker_tick()", false, 0);

		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();
		pgstat_report_activity(STATE_IDLE, NULL);
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		MemoryContextSwitchTo(tickctx);
		edata = CopyErrorData();

		AbortOutOfAnyTransaction();
		FlushErrorState();

		ereport(WARNING,
				(errmsg("spock group slot maintenance tick failed: %s",
						edata->message),
				 errhint("The group slot horizon was not advanced this cycle; "
						 "it will be retried on the next tick.")));
		FreeErrorData(edata);
		pgstat_report_activity(STATE_IDLE, NULL);
	}
	PG_END_TRY();
}

/*
 * Background worker entry point.  One per Spock database, started by the
 * manager only while spock.group_slots_enabled is on and a local node exists.
 */
void
spock_group_slot_main(Datum main_arg)
{
	int			slot = DatumGetInt32(main_arg);

	spock_worker_attach(slot, SPOCK_WORKER_GROUP_SLOT);

	CurrentResourceOwner = ResourceOwnerCreate(NULL, "spock group slot");

	elog(LOG, "starting spock group slot worker for database %s",
		 MyProcPort && MyProcPort->database_name ? MyProcPort->database_name : "?");

	while (!got_SIGTERM)
	{
		int			rc;
		long		timeout_ms;

		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
		}

		/*
		 * If the feature was turned off at runtime, exit cleanly.  The manager
		 * will not restart us while it stays off, and will start a fresh
		 * worker if it is turned back on.
		 */
		if (!spock_group_slots_enabled)
		{
			elog(LOG, "spock group slot worker exiting: feature disabled");
			proc_exit(0);
		}

		spock_group_slot_do_tick();

		timeout_ms = (long) spock_group_slots_worker_interval * 1000L;
		if (timeout_ms < 1000L)
			timeout_ms = 1000L;

		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   timeout_ms);

		ResetLatch(&MyProc->procLatch);

		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		CHECK_FOR_INTERRUPTS();
	}

	proc_exit(0);
}
