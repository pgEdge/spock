/*-------------------------------------------------------------------------
 *
 * spock_group_slot.c
 *		Group replication slot subsystem.
 *
 * Thin C layer: slot naming, the per-database worker that drives the SQL
 * tick, and node create/drop hooks. All safety logic lives in the
 * spock.group_slot_* SQL functions so it is durable and survives restarts.
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

/* Build the slot name; sanitize to [a-z0-9_] like gen_slot_name(). */
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

/* Fill out_name for the local node; false when there is no local node. */
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

/* SQL: spock.local_group_slot_name() -> name (NULL when not a spock node). */
Datum
spock_local_group_slot_name_sql(PG_FUNCTION_ARGS)
{
	Name		out_name = (Name) palloc0(NAMEDATALEN);

	if (!spock_build_local_group_slot_name(out_name))
		PG_RETURN_NULL();

	PG_RETURN_NAME(out_name);
}

/*
 * Seed group-slot metadata for a freshly created local node. The physical
 * slot is created later by the worker: a logical slot cannot be created in a
 * transaction that has already written. No-op when the feature is disabled.
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

	/* User catalog table: no ON CONFLICT, so guard with NOT EXISTS. */
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
 * Tear down the local group slot and metadata. Only called from
 * spock_drop_node(); ordinary cleanup never matches the "spkgrp_" prefix.
 * Tolerant of a missing metadata table and an active slot.
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

/* One tick: run the SQL orchestrator, catching errors so the worker lives. */
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

/* Worker entry point. One per database, started by the manager. */
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

		/* Turned off at runtime: exit; the manager restarts us if re-enabled. */
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
