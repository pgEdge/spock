/*-------------------------------------------------------------------------
 *
 * spock_exception_handler.c
 *		spock exception handling and related catalog manipulation functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "miscadmin.h"

#include "libpq/libpq-be.h"

#include "access/commit_ts.h"
#include "access/xact.h"

#include "commands/dbcommands.h"
#include "common/hashfn.h"

#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/pg_type.h"

#include "nodes/makefuncs.h"
#include "postmaster/interrupt.h"

#include "storage/ipc.h"
#include "storage/proc.h"
#include "storage/procsignal.h"
#include "storage/procarray.h"

#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"
#include "utils/lsyscache.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"
#include "utils/builtins.h"
#include "replication/origin.h"
#include "replication/slot.h"

#include "pgstat.h"

#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_conflict.h"
#include "spock_relcache.h"
#include "spock_exception_handler.h"
#include "spock_jsonb_utils.h"

#define Natts_exception_table 16
#define Anum_exception_log_remote_origin 1
#define Anum_exception_log_remote_commit_ts 2
#define Anum_exception_log_command_counter 3
#define Anum_exception_log_retry_errored_at 4
#define Anum_exception_log_remote_xid 5
#define Anum_exception_log_local_origin 6
#define Anum_exception_log_local_commit_ts 7
#define Anum_exception_log_schema 8
#define Anum_exception_log_table 9
#define Anum_exception_log_operation 10
#define Anum_exception_log_local_tup 11
#define Anum_exception_log_remote_old_tup 12
#define Anum_exception_log_remote_new_tup 13
#define Anum_exception_log_ddl_statement 14
#define Anum_exception_log_ddl_user 15
#define Anum_exception_log_error_message 16


#define CATALOG_EXCEPTION_LOG "exception_log"

SpockExceptionLog *exception_log_ptr = NULL;
int			exception_behaviour = TRANSDISCARD;
int			exception_logging = LOG_ALL;
int			exception_command_counter = 0;


/*
 * Add an entry to the error log.
 */
void
add_entry_to_exception_log(Oid remote_origin, TimestampTz remote_commit_ts,
						   TransactionId remote_xid,
						   Oid local_origin, TimestampTz local_commit_ts,
						   SpockRelation *targetrel,
						   HeapTuple localtup, SpockTupleData *remoteoldtup,
						   SpockTupleData *remotenewtup,
						   char *ddl_statement, char *ddl_user,
						   const char *operation,
						   char *error_message)
{
	RangeVar   *rv;
	Relation	rel;
	TupleDesc	tupDesc;
	TupleDesc	targetTupDesc = NULL;
	HeapTuple	tup;
	Datum		values[Natts_exception_table];
	bool		nulls[Natts_exception_table];
	char	   *schema = (targetrel == NULL) ? "" : targetrel->nspname;
	char	   *table = (targetrel == NULL) ? "" : targetrel->relname;

	char	   *str_local_tup;
	char	   *str_remote_old_tup;
	char	   *str_remote_new_tup;

	/* Get the tuple descriptors */
	rv = makeRangeVar(EXTENSION_NAME, CATALOG_EXCEPTION_LOG, -1);
	rel = table_openrv(rv, RowExclusiveLock);
	tupDesc = RelationGetDescr(rel);
	if (targetrel != NULL)
		targetTupDesc = RelationGetDescr(targetrel->rel);

	/* Convert the three (possible) tuples into json strings */
	if (localtup != NULL && localtup->t_data != NULL)
		str_local_tup = heap_tuple_to_json_cstring(&localtup,
												   targetTupDesc);
	else
		str_local_tup = NULL;

	if (remoteoldtup != NULL)
		str_remote_old_tup = spock_tuple_to_json_cstring(remoteoldtup,
														 targetTupDesc);
	else
		str_remote_old_tup = NULL;

	if (remotenewtup != NULL)
		str_remote_new_tup = spock_tuple_to_json_cstring(remotenewtup,
														 targetTupDesc);
	else
		str_remote_new_tup = NULL;

	/* Form a tuple. */
	memset(nulls, 0, sizeof(nulls));
	memset(values, 0, sizeof(values));

	values[Anum_exception_log_remote_origin - 1] = ObjectIdGetDatum(remote_origin);
	values[Anum_exception_log_remote_commit_ts - 1] = TimestampTzGetDatum(remote_commit_ts);
	values[Anum_exception_log_command_counter - 1] = exception_command_counter;
	values[Anum_exception_log_remote_xid - 1] = TransactionIdGetDatum(remote_xid);
	if (ddl_statement == NULL)
	{
		if (str_local_tup != NULL)
		{
			values[Anum_exception_log_local_origin - 1] = local_origin;
			values[Anum_exception_log_local_commit_ts - 1] = local_commit_ts;
		}
		else
		{
			nulls[Anum_exception_log_local_origin - 1] = true;
			nulls[Anum_exception_log_local_commit_ts - 1] = true;
		}
		values[Anum_exception_log_schema - 1] = CStringGetTextDatum(schema);
		values[Anum_exception_log_table - 1] = CStringGetTextDatum(table);
		values[Anum_exception_log_operation - 1] = CStringGetTextDatum(operation);
		if (str_local_tup != NULL)
			values[Anum_exception_log_local_tup - 1] = DirectFunctionCall1(jsonb_in, CStringGetDatum(str_local_tup));
		else
			nulls[Anum_exception_log_local_tup - 1] = true;
		if (str_remote_old_tup != NULL)
			values[Anum_exception_log_remote_old_tup - 1] = DirectFunctionCall1(jsonb_in, CStringGetDatum(str_remote_old_tup));
		else
			nulls[Anum_exception_log_remote_old_tup - 1] = true;
		if (str_remote_new_tup != NULL)
			values[Anum_exception_log_remote_new_tup - 1] = DirectFunctionCall1(jsonb_in, CStringGetDatum(str_remote_new_tup));
		else
			nulls[Anum_exception_log_remote_new_tup - 1] = true;
		nulls[Anum_exception_log_ddl_statement - 1] = true;
		nulls[Anum_exception_log_ddl_user - 1] = true;
	}
	else
	{
		nulls[Anum_exception_log_local_origin - 1] = true;
		nulls[Anum_exception_log_local_commit_ts - 1] = true;
		nulls[Anum_exception_log_schema - 1] = true;
		nulls[Anum_exception_log_table - 1] = true;
		values[Anum_exception_log_operation - 1] = CStringGetTextDatum("DDL");
		nulls[Anum_exception_log_local_tup - 1] = true;
		nulls[Anum_exception_log_remote_old_tup - 1] = true;
		nulls[Anum_exception_log_remote_new_tup - 1] = true;
		values[Anum_exception_log_ddl_statement - 1] = CStringGetTextDatum(ddl_statement);
		values[Anum_exception_log_ddl_user - 1] = CStringGetTextDatum(ddl_user);
	}

	/*
	 * The error_message column of the spock.exception_log table is marked as NOT NULL,
	 * but we don't always have a valid error message.
	 */
	if (error_message == NULL)
		values[Anum_exception_log_error_message - 1] = CStringGetTextDatum("unknown");
	else
		values[Anum_exception_log_error_message - 1] = CStringGetTextDatum(error_message);
	values[Anum_exception_log_retry_errored_at - 1] = TimestampTzGetDatum(GetCurrentTimestamp());

	tup = heap_form_tuple(tupDesc, values, nulls);

	/* Insert the tuple to the catalog. */
	CatalogTupleInsert(rel, tup);

	/* Cleanup. */
	heap_freetuple(tup);
	table_close(rel, RowExclusiveLock);

	/* Reset the error stack to empty. */
	FlushErrorState();

	CommandCounterIncrement();
}

/*
 * spock_disable_subscription
 *
 * Disable the current subscription due to exception_behaviour == SUB_DISABLE.
 *
 * This function is invoked when the configured exception handling behavior is
 * SUB_DISABLE, meaning the subscription must be suspended instead of skipping
 * or retrying the failing transaction.
 */
void
spock_disable_subscription(SpockSubscription *sub,
						   RepOriginId remote_origin,
						   TransactionId remote_xid,
						   XLogRecPtr lsn,
						   TimestampTz ts)
{
	char errmsg[1024];
	bool started_tx = false;

	Assert(exception_behaviour == SUB_DISABLE);

	if (!IsTransactionState())
	{
		StartTransactionCommand();
		started_tx = true;
	}

	PushActiveSnapshot(GetTransactionSnapshot());

	sub->enabled = false;
	alter_subscription(sub);

	// cppcheck-suppress format
	snprintf(errmsg, sizeof(errmsg),
				"disabling subscription %s due to exception(s) - "
				"skip_lsn = %X/%X",
				sub->name,
				LSN_FORMAT_ARGS(lsn));
	exception_command_counter++;
	add_entry_to_exception_log(remote_origin,
								ts,
								remote_xid,
								0, 0,
								NULL, NULL, NULL, NULL,
								NULL, NULL,
								"SUB_DISABLE",
								errmsg);

	elog(WARNING, "SPOCK %s: disabling subscription due to"
					" exceptions - origin_lsn=%X/%X",
			sub->name,
			LSN_FORMAT_ARGS(lsn));

	PopActiveSnapshot();
	if (started_tx)
		CommitTransactionCommand();
}
