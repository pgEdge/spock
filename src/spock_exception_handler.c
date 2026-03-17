/*-------------------------------------------------------------------------
 *
 * spock_exception_handler.c
 *		spock exception handling and related catalog manipulation functions
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

#include "funcapi.h"
#include "storage/fd.h"
#include "utils/json.h"

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

#define DISCARDFILE_DIR "pg_spock"
#define DISCARDFILE_FMT DISCARDFILE_DIR "/discard_%u.log"

/* File format version — written as a 4-byte header, checked on read */
#define DISCARDFILE_VERSION 1

/* JSON field names — keep in sync between discardfile_write and discard_read */
#define DF_XID				"xid"
#define DF_NODE				"node_name"
#define DF_LOG_TIME			"log_time"
#define DF_RELNAME			"relname"
#define DF_LOCAL_ORIGIN		"local_origin"
#define DF_REMOTE_ORIGIN	"remote_origin"
#define DF_OPERATION		"operation"
#define DF_OLD_TUPLE		"old_tuple"
#define DF_REMOTE_TUPLE		"remote_tuple"
#define DF_REMOTE_XID		"remote_xid"

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

	Assert(IsTransactionState());

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
	 * The error_message column of the spock.exception_log table is marked as
	 * NOT NULL, but we don't always have a valid error message.
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
	char		errmsg[1024];
	bool		started_tx = false;

	Assert(exception_behaviour == SUB_DISABLE);

	if (!IsTransactionState())
	{
		StartTransactionCommand();
		started_tx = true;
	}

	PushActiveSnapshot(GetTransactionSnapshot());

	sub->enabled = false;
	alter_subscription(sub);

	/* cppcheck-suppress format */
	snprintf(errmsg, sizeof(errmsg),
			 "disabling subscription %s due to exception(s) - skip_lsn = %X/%X",
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

/*
 * Get the path to the DISCARDFILE for the current database.
 * The caller must provide a buffer of at least MAXPGPATH bytes.
 */
static void
discardfile_path(char *path)
{
	snprintf(path, MAXPGPATH, DISCARDFILE_FMT, MyDatabaseId);
}

/*
 * Ensure the pg_spock directory exists under PGDATA.
 */
static void
discardfile_ensure_dir(void)
{
	char		dirpath[MAXPGPATH];

	snprintf(dirpath, MAXPGPATH, "%s", DISCARDFILE_DIR);
	(void) MakePGDirectory(dirpath);
}

/*
 * Append a single record to the DISCARDFILE.
 *
 * This function is safe to call outside a transaction — it does not access
 * catalog tables.  Each call writes one binary length-prefixed record: a
 * 32-bit native-endian length header (the StringInfoData.len field, which is
 * a signed int) followed by exactly that many bytes of JSON payload.  Readers
 * must parse the length header first to determine where each record ends.
 *
 * Locking: acquires SpockCtx->discard_file_lock in exclusive mode to
 * serialize concurrent writes from different apply workers.
 *
 * Memory leaking. Being executed on a per-row basis it should be executed
 * inside a short living memory context - consider multiple potential memory
 * allocations inside a JSON code.
 *
 * Returns true on success, false if the record could not be written
 * (a WARNING is emitted in that case).
 */
bool
discardfile_write(const char *node_name, SpockRelation *rel, Oid remote_origin,
				  Oid local_origin, const char *operation,
				  SpockTupleData *oldtup, SpockTupleData *newtup,
				  TransactionId remote_xid)
{
	char			path[MAXPGPATH];
	StringInfoData	buf;
	char		   *old_json = NULL;
	char		   *new_json = NULL;
	int				fd;
	TupleDesc		tupdesc = RelationGetDescr(rel->rel);

	Assert(SpockCtx != NULL);

	/* Serialize tuples to JSON before taking the lock */
	if (oldtup != NULL && tupdesc != NULL)
		old_json = spock_tuple_to_json_cstring(oldtup, tupdesc);
	if (newtup != NULL && tupdesc != NULL)
		new_json = spock_tuple_to_json_cstring(newtup, tupdesc);

	/* Build the JSON record. Field names use DF_* defines from above. */
	initStringInfo(&buf);
	appendStringInfo(&buf, "{\"" DF_XID "\": %u", remote_xid);

	appendStringInfoString(&buf, ", \"" DF_NODE "\": ");
	escape_json(&buf, node_name ? node_name : "");

	appendStringInfoString(&buf, ", \"" DF_LOG_TIME "\": ");
	escape_json(&buf, timestamptz_to_str(GetCurrentTimestamp()));

	appendStringInfoString(&buf, ", \"" DF_RELNAME "\": ");
	escape_json(&buf, quote_qualified_identifier(rel->nspname, rel->relname));

	appendStringInfo(&buf, ", \"" DF_LOCAL_ORIGIN "\": %u", local_origin);

	appendStringInfo(&buf, ", \"" DF_REMOTE_ORIGIN "\": %u", remote_origin);

	appendStringInfoString(&buf, ", \"" DF_OPERATION "\": ");
	escape_json(&buf, operation ? operation : "");

	if (old_json != NULL)
		appendStringInfo(&buf, ", \"" DF_OLD_TUPLE "\": %s", old_json);

	if (new_json != NULL)
		appendStringInfo(&buf, ", \"" DF_REMOTE_TUPLE "\": %s", new_json);

	appendStringInfo(&buf, ", \"" DF_REMOTE_XID "\": %u}", remote_xid);

	/* Write under lock: [uint32 length][json data] */
	LWLockAcquire(SpockCtx->discard_file_lock, LW_EXCLUSIVE);

	discardfile_ensure_dir();
	discardfile_path(path);

	fd = OpenTransientFile(path, O_WRONLY | O_CREAT | O_APPEND | PG_BINARY);
	if (fd < 0)
	{
		LWLockRelease(SpockCtx->discard_file_lock);
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("could not open discard file \"%s\": %m", path)));
		pfree(buf.data);
		return false;
	}

	/* Write version header if this is a new file */
	if (lseek(fd, 0, SEEK_END) == 0)
	{
		uint32	version = DISCARDFILE_VERSION;

		if (write(fd, &version, sizeof(version)) != sizeof(version))
		{
			CloseTransientFile(fd);
			LWLockRelease(SpockCtx->discard_file_lock);
			ereport(WARNING,
					(errcode_for_file_access(),
					 errmsg("could not write discard file header \"%s\": %m",
							path)));
			pfree(buf.data);
			return false;
		}
	}

	if (write(fd, &buf.len, sizeof(buf.len)) != sizeof(buf.len) ||
		write(fd, buf.data, buf.len) != buf.len)
	{
		CloseTransientFile(fd);
		LWLockRelease(SpockCtx->discard_file_lock);
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("could not write to discard file \"%s\": %m",
						path)));
		pfree(buf.data);
		return false;
	}

	CloseTransientFile(fd);
	LWLockRelease(SpockCtx->discard_file_lock);

	return true;
}

/*
 * SQL-callable function: spock.discard_read()
 *
 * Returns the contents of the current database's DISCARDFILE as a set of
 * single-column jsonb records. Users extract fields in SQL, e.g.:
 *
 *   SELECT rec->>'node_name', rec->>'operation', rec->'remote_tuple'
 *   FROM spock.discard_read() AS rec;
 *
 * TODO: pass through the code scrupulously and decide on safe reading and error
 * processing. Too much for a single commit, though.
 */
PG_FUNCTION_INFO_V1(spock_discard_read);
Datum
spock_discard_read(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	char		path[MAXPGPATH];
	int			fd;
	int			reclen;

	InitMaterializedSRF(fcinfo, MAT_SRF_USE_EXPECTED_DESC | MAT_SRF_BLESS);

	discardfile_path(path);

	if (SpockCtx == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("spock shared memory context is not initialized")));

	/*
	 * Acquire the discard-file lock in shared mode so that concurrent
	 * writers (which take LW_EXCLUSIVE) cannot produce a partial record
	 * while we are reading.
	 */
	LWLockAcquire(SpockCtx->discard_file_lock, LW_SHARED);

	fd = OpenTransientFile(path, O_RDONLY | PG_BINARY);
	if (fd < 0)
	{
		LWLockRelease(SpockCtx->discard_file_lock);
		if (errno == ENOENT)
			PG_RETURN_VOID();
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open discard file \"%s\": %m", path)));
	}

	/* Validate file format version */
	{
		uint32	version;

		if (read(fd, &version, sizeof(version)) != sizeof(version))
		{
			CloseTransientFile(fd);
			LWLockRelease(SpockCtx->discard_file_lock);
			PG_RETURN_VOID();	/* empty file */
		}
		if (version != DISCARDFILE_VERSION)
		{
			CloseTransientFile(fd);
			LWLockRelease(SpockCtx->discard_file_lock);
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("unsupported discard file version %u (expected %u)",
							version, DISCARDFILE_VERSION)));
		}
	}

	while (read(fd, &reclen, sizeof(reclen)) == sizeof(reclen))
	{
		Datum		value;
		bool		null = false;
		char	   *rec;

		rec = palloc(reclen + 1);
		if (read(fd, rec, reclen) != reclen)
		{
			pfree(rec);
			/*
			 * In case of crash and semi-written file this option allows us to
			 * use all the records have written before the failed operation.
			 */
			ereport(WARNING,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("truncated record in discard file \"%s\"",
							path)));
			break;
		}
		rec[reclen] = '\0';

		value = DirectFunctionCall1(jsonb_in, CStringGetDatum(rec));

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
							 &value, &null);
		pfree(rec);
	}

	CloseTransientFile(fd);
	LWLockRelease(SpockCtx->discard_file_lock);

	PG_RETURN_VOID();
}
