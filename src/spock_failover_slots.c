/*-------------------------------------------------------------------------
 *
 * spock_failover_slot.c
 *          Postgres Failover Slots
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 2023, EnterpriseDB Corporation.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <dirent.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include "funcapi.h"
#include "miscadmin.h"
#include "pgstat.h"

#include "access/genam.h"
#include "access/table.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "access/xlogrecovery.h"
#include "access/xlogutils.h"
#include "catalog/indexing.h"
#include "catalog/pg_database.h"

#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"

#include "replication/decode.h"
#include "replication/logical.h"
#include "replication/slot.h"
#include "replication/snapbuild.h"
#include "replication/walreceiver.h"
#include "replication/walsender.h"
#if PG_VERSION_NUM >= 170000
#include "replication/slotsync.h"
#endif

#include "storage/ipc.h"
#include "storage/procarray.h"

#include "tcop/tcopprot.h"

#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/fmgrprotos.h"
#include "utils/guc.h"
#include "utils/inval.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/varlena.h"

#include "libpq-fe.h"
#include "libpq/auth.h"
#include "libpq/libpq.h"

#include "spock_common.h"
#include "spock_shmem.h"

/* Defaults (milliseconds) for the tunable worker intervals below. */
#define WORKER_NAP_TIME_DEFAULT 1000
#define WORKER_WAIT_FEEDBACK_DEFAULT 10000

/*
 * PostgreSQL 19 replaced ReplicationSlot.active_pid (an int pid, 0 when the
 * slot is unused) with active_proc (a ProcNumber, INVALID_PROC_NUMBER when
 * unused).  SlotIsActive() hides that difference.
 */
#if PG_VERSION_NUM >= 190000
#define SlotIsActive(s) ((s)->active_proc != INVALID_PROC_NUMBER)
#else
#define SlotIsActive(s) ((s)->active_pid != 0)
#endif

typedef struct RemoteSlot
{
	char	   *name;
	char	   *plugin;
	char	   *database;
	bool		two_phase;
	XLogRecPtr	restart_lsn;
	XLogRecPtr	confirmed_lsn;
	TransactionId catalog_xmin;

	/*
	 * restart_lsn is lowered to the oldest restart_lsn of all synchronized
	 * slots before a slot is synchronized.  This is the slot's own value,
	 * capped at the WAL received, used to check that the local copy can
	 * satisfy it.
	 */
	XLogRecPtr	own_restart_lsn;
} RemoteSlot;

typedef enum FailoverSlotFilterKey
{
	FAILOVERSLOT_FILTER_NAME = 1,
	FAILOVERSLOT_FILTER_NAME_LIKE,
	FAILOVERSLOT_FILTER_PLUGIN
} FailoverSlotFilterKey;

typedef struct FailoverSlotFilter
{
	FailoverSlotFilterKey key;
	char	   *val;			/* eg: test_decoding */
} FailoverSlotFilter;

/* Used for physical-before-logical ordering */
static char *standby_slot_names_raw;
static char *standby_slot_names_string = NULL;
static List *pg_standby_slot_names = NIL;
static int	standby_slots_min_confirmed;

#if PG_VERSION_NUM < 180000
static XLogRecPtr standby_slot_names_oldest_flush_lsn = InvalidXLogRecPtr;
#endif

/* Slots to sync */
static char *spock_failover_slots_dsn;
static char *spock_failover_slot_names;
static char *spock_failover_slot_names_str = NULL;
static List *spock_failover_slot_names_list = NIL;
static bool spock_failover_slots_drop = true;

/*
 * Whether a synchronized slot that was invalidated on the standby is dropped
 * and created again from the primary.  Off leaves it as it is and reports
 * it once.
 */
static bool spock_failover_slots_recreate_invalidated = true;
static char *spock_failover_slots_database = NULL;

/*
 * How long the worker sleeps between slot-sync passes, and the shorter retry
 * used while it is still waiting for the standby to receive/feedback WAL.
 * Both are in milliseconds and settable at runtime (SIGHUP).  A smaller
 * naptime narrows the window in which the standby's synced slots lag the
 * primary, at the cost of more frequent sync passes.
 */
static int	spock_failover_slots_naptime = WORKER_NAP_TIME_DEFAULT;
static int	spock_failover_slots_feedback_naptime = WORKER_WAIT_FEEDBACK_DEFAULT;

void		spock_init_failover_slot(void);

PGDLLEXPORT void spock_failover_slots_main(Datum main_arg);

static bool
check_failover_slot_names(char **newval, void **extra, GucSource source)
{
	List	   *namelist = NIL;
	char	   *rawname = pstrdup(*newval);
	bool		valid;

	valid = SplitIdentifierString(rawname, ',', &namelist);

	if (!valid)
		GUC_check_errdetail("List syntax is invalid.");

	pfree(rawname);
	list_free(namelist);

	return valid;
}

static void
assign_failover_slot_names(const char *newval, void *extra)
{
	MemoryContext old_ctx;
	List	   *slot_names_list = NIL;
	ListCell   *lc;

	/* cleanup memory to prevent leaking or SET/config reload */
	if (spock_failover_slot_names_str)
		pfree(spock_failover_slot_names_str);
	if (spock_failover_slot_names_list)
	{
		foreach(lc, spock_failover_slot_names_list)
		{
			FailoverSlotFilter *filter = lfirst(lc);

			/* val was pointer to spock_failover_slot_names_str */
			pfree(filter);
		}
		list_free(spock_failover_slot_names_list);
	}

	spock_failover_slot_names_list = NIL;

	/* Allocate memory in long lasting context. */
	old_ctx = MemoryContextSwitchTo(TopMemoryContext);

	spock_failover_slot_names_str = pstrdup(newval);
	SplitIdentifierString(spock_failover_slot_names_str, ',', &slot_names_list);

	foreach(lc, slot_names_list)
	{
		char	   *raw_val = lfirst(lc);
		char	   *key = strtok(raw_val, ":");
		FailoverSlotFilter *filter = palloc(sizeof(FailoverSlotFilter));

		filter->val = strtok(NULL, ":");

		/* Default key is name */
		if (!filter->val)
		{
			filter->val = key;
			filter->key = FAILOVERSLOT_FILTER_NAME;
		}
		else if (strcmp(key, "name") == 0)
			filter->key = FAILOVERSLOT_FILTER_NAME;
		else if (strcmp(key, "name_like") == 0)
			filter->key = FAILOVERSLOT_FILTER_NAME_LIKE;
		else if (strcmp(key, "plugin") == 0)
			filter->key = FAILOVERSLOT_FILTER_PLUGIN;
		else
			ereport(
					ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg(
							"unrecognized synchronize_failover_slot_names key \"%s\"",
							key)));

		/* Check that there was just one ':' */
		if (strtok(NULL, ":"))
			ereport(
					ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg(
							"unrecognized synchronize_failover_slot_names format")));

		spock_failover_slot_names_list =
			lappend(spock_failover_slot_names_list, filter);
	}

	/* Clean the temporary list, but not the contents. */
	list_free(slot_names_list);
	MemoryContextSwitchTo(old_ctx);
}

static bool
check_standby_slot_names(char **newval, void **extra, GucSource source)
{
	List	   *namelist = NIL;
	char	   *rawname = pstrdup(*newval);
	bool		valid;

	valid = SplitIdentifierString(rawname, ',', &namelist);

	if (!valid)
		GUC_check_errdetail("List syntax is invalid.");

	pfree(rawname);
	list_free(namelist);

	return valid;
}

static void
assign_standby_slot_names(const char *newval, void *extra)
{
	MemoryContext old_ctx;

	if (standby_slot_names_string)
		pfree(standby_slot_names_string);
	if (pg_standby_slot_names)
		list_free(pg_standby_slot_names);

#if PG_VERSION_NUM < 180000

	/*
	 * We must invalidate our idea of the oldest lsn in all the named slots if
	 * we might have changed the list.
	 */
	standby_slot_names_oldest_flush_lsn = InvalidXLogRecPtr;
#endif

	old_ctx = MemoryContextSwitchTo(TopMemoryContext);
	standby_slot_names_string = pstrdup(newval);
	(void) SplitIdentifierString(standby_slot_names_string, ',',
								 &pg_standby_slot_names);
	(void) MemoryContextSwitchTo(old_ctx);
}

/*
 * Get failover slots from upstream
 */
#if PG_VERSION_NUM < 180000
static List *
remote_get_primary_slot_info(PGconn *conn, List *slot_filter)
{
	PGresult   *res;
	int			i;
	char	   *op = "";
	List	   *slots = NIL;
	ListCell   *lc;
	StringInfoData query;

	initStringInfo(&query);
	appendStringInfoString(
						   &query,
						   "SELECT slot_name, plugin, database, two_phase, catalog_xmin, restart_lsn, confirmed_flush_lsn"
						   "  FROM pg_catalog.pg_replication_slots"
						   " WHERE database IS NOT NULL AND (");

	foreach(lc, slot_filter)
	{
		FailoverSlotFilter *filter = lfirst(lc);

		switch (filter->key)
		{
			case FAILOVERSLOT_FILTER_NAME:
				appendStringInfo(&query, " %s slot_name OPERATOR(pg_catalog.=) ", op);
				append_escaped_literal(&query, conn, filter->val);
				break;
			case FAILOVERSLOT_FILTER_NAME_LIKE:
				appendStringInfo(&query, " %s slot_name LIKE ", op);
				append_escaped_literal(&query, conn, filter->val);
				break;
			case FAILOVERSLOT_FILTER_PLUGIN:
				appendStringInfo(&query, " %s plugin OPERATOR(pg_catalog.=) ", op);
				append_escaped_literal(&query, conn, filter->val);
				break;
			default:
				Assert(0);
				elog(ERROR, "unrecognized slot filter key %u", filter->key);
		}

		op = "OR";
	}

	appendStringInfoString(&query, ")");

	res = PQexec(conn, query.data);
	pfree(query.data);

	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		elog(ERROR, "could not fetch slot information from provider: %s\n",
			 res != NULL ? PQresultErrorMessage(res) : PQerrorMessage(conn));

	for (i = 0; i < PQntuples(res); i++)
	{
		RemoteSlot *slot = palloc0(sizeof(RemoteSlot));

		slot->name = pstrdup(PQgetvalue(res, i, 0));
		slot->plugin = pstrdup(PQgetvalue(res, i, 1));
		slot->database = pstrdup(PQgetvalue(res, i, 2));
		parse_bool(PQgetvalue(res, i, 3), &slot->two_phase);
		slot->catalog_xmin = !PQgetisnull(res, i, 4) ?
			atoi(PQgetvalue(res, i, 4)) :
			InvalidTransactionId;
		slot->restart_lsn =
			!PQgetisnull(res, i, 5) ?
			DatumGetLSN(DirectFunctionCall1(
											pg_lsn_in, CStringGetDatum(PQgetvalue(res, i, 5)))) :
			InvalidXLogRecPtr;
		slot->confirmed_lsn =
			!PQgetisnull(res, i, 6) ?
			DatumGetLSN(DirectFunctionCall1(
											pg_lsn_in, CStringGetDatum(PQgetvalue(res, i, 6)))) :
			InvalidXLogRecPtr;

		slots = lappend(slots, slot);
	}

	PQclear(res);

	return slots;
}

static XLogRecPtr
remote_get_physical_slot_lsn(PGconn *conn, const char *slot_name)
{
	PGresult   *res;
	XLogRecPtr	lsn;
	StringInfoData query;

	initStringInfo(&query);
	appendStringInfoString(&query,
						   "SELECT restart_lsn"
						   "  FROM pg_catalog.pg_replication_slots"
						   " WHERE slot_name OPERATOR(pg_catalog.=) ");
	append_escaped_literal(&query, conn, slot_name);
	res = PQexec(conn, query.data);

	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		elog(ERROR, "could not fetch slot information from provider: %s\n",
			 res != NULL ? PQresultErrorMessage(res) : PQerrorMessage(conn));

	if (PQntuples(res) != 1)
		elog(ERROR, "physical slot %s not found on primary", slot_name);

	if (PQgetisnull(res, 0, 0))
		lsn = InvalidXLogRecPtr;
	else
		lsn = DatumGetLSN(DirectFunctionCall1(
											  pg_lsn_in, CStringGetDatum(PQgetvalue(res, 0, 0))));

	PQclear(res);

	return lsn;
}

/*
 * Can't use get_database_oid from dbcommands.c because it does not work
 * without db connection.
 */
static Oid
get_database_oid(const char *dbname)
{
	HeapTuple	tuple;
	Relation	relation;
	SysScanDesc scan;
	ScanKeyData key[1];
	Oid			dboid = InvalidOid;

	/*
	 * form a scan key
	 */
	ScanKeyInit(&key[0], Anum_pg_database_datname, BTEqualStrategyNumber,
				F_NAMEEQ, CStringGetDatum(dbname));

	/*
	 * Open pg_database and fetch a tuple.  Force heap scan if we haven't yet
	 * built the critical shared relcache entries (i.e., we're starting up
	 * without a shared relcache cache file).
	 */
	relation = table_open(DatabaseRelationId, AccessShareLock);
	scan = systable_beginscan(relation, DatabaseNameIndexId,
							  criticalSharedRelcachesBuilt, NULL, 1, key);

	tuple = systable_getnext(scan);

	/* Must copy tuple before releasing buffer */
	if (HeapTupleIsValid(tuple))
	{
		Form_pg_database datForm = (Form_pg_database) GETSTRUCT(tuple);

		dboid = datForm->oid;
	}
	else
		ereport(ERROR, (errcode(ERRCODE_UNDEFINED_DATABASE),
						errmsg("database \"%s\" does not exist", dbname)));

	/* all done */
	systable_endscan(scan);
	table_close(relation, AccessShareLock);

	return dboid;
}

/*
 * Fill connection string info based on config.
 *
 * This is slightly complicated because we default to primary_conninfo if
 * user didn't explicitly set anything and we might need to request explicit
 * database name override, that's why we need dedicated function for this.
 *
 * Returns false if no connection string is available yet, which only happens
 * on the primary_conninfo path; connstr is left untouched in that case and the
 * caller must not try to connect.  See the comment on that path below.
 */
static bool
make_sync_failover_slots_dsn(StringInfo connstr, char *db_name)
{
	char		conninfo[MAXCONNINFO];

	if (spock_failover_slots_dsn && strlen(spock_failover_slots_dsn) > 0)
	{
		if (db_name)
			appendStringInfo(connstr, "%s dbname=%s", spock_failover_slots_dsn,
							 db_name);
		else
			appendStringInfoString(connstr, spock_failover_slots_dsn);

		return true;
	}

	/*
	 * Fall back to the walreceiver's connection string. The field might be
	 * legitimately empty for as long as a connection attempt is in flight.
	 * WalReceiverMain() clears conninfo before calling walrcv_connect() and
	 * only fills it in once the connection is fully established, so this
	 * happens on every walreceiver start and restart -- not merely in a
	 * narrow window while the standby comes up.
	 */
	Assert(WalRcv);

	SpinLockAcquire(&WalRcv->mutex);
	strlcpy(conninfo, (char *) WalRcv->conninfo, sizeof(conninfo));
	SpinLockRelease(&WalRcv->mutex);

	if (conninfo[0] == '\0')
		return false;

	appendStringInfo(connstr, "%s dbname=%s", conninfo,
					 db_name ? db_name : "postgres");

	return true;
}

/*
 * Connect to remote pg server
 */
static PGconn *
remote_connect(const char *connstr, const char *appname)
{
#define CONN_PARAM_ARRAY_SIZE 8
	int			i = 0;
	PGconn	   *conn;
	const char *keys[CONN_PARAM_ARRAY_SIZE];
	const char *vals[CONN_PARAM_ARRAY_SIZE];
	StringInfoData s;

	initStringInfo(&s);
	appendStringInfoString(&s, connstr);

	keys[i] = "dbname";
	vals[i] = connstr;
	i++;
	keys[i] = "application_name";
	vals[i] = appname;
	i++;
	keys[i] = "connect_timeout";
	vals[i] = "30";
	i++;
	keys[i] = "keepalives";
	vals[i] = "1";
	i++;
	keys[i] = "keepalives_idle";
	vals[i] = "20";
	i++;
	keys[i] = "keepalives_interval";
	vals[i] = "20";
	i++;
	keys[i] = "keepalives_count";
	vals[i] = "5";
	i++;
	keys[i] = NULL;
	vals[i] = NULL;

	Assert(i <= CONN_PARAM_ARRAY_SIZE);

	/*
	 * We use the expand_dbname parameter to process the connection string (or
	 * URI), and pass some extra options.
	 */
	conn = PQconnectdbParams(keys, vals, /* expand_dbname = */ true);
	if (PQstatus(conn) != CONNECTION_OK)
	{
		ereport(ERROR,
				(errmsg("could not connect to the postgresql server: %s",
						PQerrorMessage(conn)),
				 errdetail("dsn was: %s", s.data)));
	}

	resetStringInfo(&s);

	elog(DEBUG2, "established connection to remote backend with pid %d",
		 PQbackendPID(conn));

	return conn;
}


/*
 * Is the slot invalidated?  Caller must hold the slot's mutex.
 */
static bool
slot_is_invalidated(ReplicationSlot *s)
{
#if PG_VERSION_NUM >= 160000
	return s->data.invalidated != RS_INVAL_NONE;
#else
	/*
	 * PG15 records the old restart_lsn in invalidated_at and clears
	 * restart_lsn.  Only invalidated_at is tested: a worker without this fix
	 * advanced such copies and gave them a valid restart_lsn again.  The
	 * standby may have removed the WAL at that position while the copy was
	 * invalidated, and a valid restart_lsn holds back the cutoff that
	 * InvalidateObsoleteReplicationSlots() compares it with, so a later
	 * restartpoint need not invalidate the copy again.  Nothing clears
	 * invalidated_at short of dropping the slot.
	 */
	return !XLogRecPtrIsInvalid(s->data.invalidated_at);
#endif
}

/*
 * A copy holds the primary's positions, but not the snapshot the primary
 * saved at its restart_lsn in pg_logical/snapshots, which physical
 * replication does not carry.  Decoding from such a copy after a promotion
 * has to build a snapshot from scratch, and a transaction that commits
 * before that snapshot is consistent is never sent.  PostgreSQL 17's slot
 * sync avoids this by decoding the standby's own WAL in fast-forward mode,
 * which saves snapshots locally and moves restart_lsn only to positions
 * that have one, and by persisting a new copy only once decoding has found
 * a consistent snapshot.  Do the same where the standby can decode.
 */

/*
 * Why the copy's WAL cannot be decoded on this standby, or NULL if it can.
 */
static const char *
local_decoding_unavailable(ReplicationSlot *slot)
{
#if PG_VERSION_NUM < 160000
	return "PostgreSQL 15 cannot decode WAL on a standby";
#else
	if (wal_level < WAL_LEVEL_LOGICAL)
		return "wal_level on the standby is lower than logical";
	if (!OidIsValid(MyDatabaseId))
		return "spock.failover_slots_database is not set";
#if PG_VERSION_NUM >= 170000
	{
		bool		synced;

		SpinLockAcquire(&slot->mutex);
		synced = slot->data.synced;
		SpinLockRelease(&slot->mutex);
		if (synced)
			return "the slot was created by native slot sync, which "
				"PostgreSQL does not let other processes decode on a standby";
	}
#else
	if (slot->data.database != MyDatabaseId)
		return "the slot is not in the database named by "
			"spock.failover_slots_database, which PostgreSQL 16 requires";
#endif
	return NULL;
#endif
}

/*
 * Slots reported because their copy cannot be decoded on the standby, or
 * because decoding has not reached a consistent snapshot.  Each is reported
 * once, and again only after it has left that state.
 */
static List *undecodable_warned = NIL;
static List *inconsistent_warned = NIL;

static bool warning_due(List **warned, const char *name, bool in_state);

/* What apply_remote_position() found out about the copy's snapshot */
typedef enum CopySnapshotState
{
	COPY_SNAPSHOT_CONSISTENT,	/* decoding can start from a saved snapshot */
	COPY_SNAPSHOT_INCONSISTENT, /* decoding has no consistent snapshot yet */
	COPY_SNAPSHOT_UNCHECKED		/* not checked: cannot decode here, or
								 * nothing new to decode on a persistent copy */
} CopySnapshotState;

#if PG_VERSION_NUM >= 160000
/* Has this standby saved a snapshot at lsn? */
static bool
local_snapshot_exists(XLogRecPtr lsn)
{
#if PG_VERSION_NUM >= 170000
	return SnapBuildSnapshotExists(lsn);
#else
	char		path[MAXPGPATH];
	struct stat stat_buf;

	snprintf(path, sizeof(path), "pg_logical/snapshots/%X-%X.snap",
			 LSN_FORMAT_ARGS(lsn));
	if (stat(path, &stat_buf) == 0)
		return true;
	if (errno != ENOENT)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not stat file \"%s\": %m", path)));
	return false;
#endif
}

/*
 * Decode the acquired copy's WAL on the standby in fast-forward mode up to
 * moveto, and return whether decoding has a consistent snapshot.  On PG16
 * this is LogicalSlotAdvanceAndCheckSnapState() from PG17.
 */
static bool
advance_copy_locally(XLogRecPtr moveto)
{
#if PG_VERSION_NUM >= 170000
	bool		consistent;

	LogicalSlotAdvanceAndCheckSnapState(moveto, &consistent);
	return consistent;
#else
	LogicalDecodingContext *ctx;
	ResourceOwner old_resowner = CurrentResourceOwner;
	bool		consistent = false;

	PG_TRY();
	{
		ctx = CreateDecodingContext(InvalidXLogRecPtr,
									NIL,
									true,	/* fast_forward */
									XL_ROUTINE(.page_read = read_local_xlog_page,
											   .segment_open = wal_segment_open,
											   .segment_close = wal_segment_close),
									NULL, NULL, NULL);

		XLogBeginRead(ctx->reader, MyReplicationSlot->data.restart_lsn);

		/* invalidate non-timetravel entries */
		InvalidateSystemCaches();

		while (ctx->reader->EndRecPtr < moveto)
		{
			char	   *errm = NULL;
			XLogRecord *record;

			record = XLogReadRecord(ctx->reader, &errm);
			if (errm)
				elog(ERROR, "could not find record while advancing replication slot: %s",
					 errm);

			if (record)
				LogicalDecodingProcessRecord(ctx, ctx->reader);

			CHECK_FOR_INTERRUPTS();
		}

		consistent = DecodingContextReady(ctx);

		/* Decoding can clobber CurrentResourceOwner, as in core */
		CurrentResourceOwner = old_resowner;

		if (ctx->reader->EndRecPtr != InvalidXLogRecPtr)
		{
			LogicalConfirmReceivedLocation(moveto);
			ReplicationSlotMarkDirty();
		}

		FreeDecodingContext(ctx);

		InvalidateSystemCaches();
	}
	PG_CATCH();
	{
		/* clear all timetravel entries */
		InvalidateSystemCaches();

		PG_RE_THROW();
	}
	PG_END_TRY();

	return consistent;
#endif
}
#endif							/* PG_VERSION_NUM >= 160000 */

/*
 * Move the acquired copy to the remote slot's position, which the caller
 * has checked the copy can satisfy, and report whether it has a consistent
 * snapshot, that is, whether it can serve a subscriber after a promotion
 * without skipping transactions.  Where the standby cannot decode, the
 * positions are copied as they are and the slot reported once.
 */
static CopySnapshotState
apply_remote_position(RemoteSlot *remote_slot)
{
	const char *reason = local_decoding_unavailable(MyReplicationSlot);
	XLogRecPtr	restart_lsn = remote_slot->restart_lsn;
	CopySnapshotState state = COPY_SNAPSHOT_UNCHECKED;

	if (reason)
	{
		if (warning_due(&undecodable_warned, remote_slot->name, true))
			ereport(WARNING,
					(errmsg("replication slot \"%s\" is synchronized without a "
							"consistent snapshot on the standby",
							remote_slot->name),
					 errdetail("%s.", reason),
					 errhint("After a promotion, transactions that commit before "
							 "decoding reaches a consistent point may not be sent.")));
	}
#if PG_VERSION_NUM >= 160000
	else if (local_snapshot_exists(remote_slot->own_restart_lsn))
	{
		/* Decoding can start from the snapshot saved there */
		restart_lsn = remote_slot->own_restart_lsn;
		state = COPY_SNAPSHOT_CONSISTENT;
	}
	else
	{
		bool		pending = MyReplicationSlot->data.persistency != RS_PERSISTENT;
		XLogRecPtr	moveto;

		/* Read only WAL that has been replayed, as core's slot advance does */
		moveto = Min(remote_slot->confirmed_lsn, GetXLogReplayRecPtr(NULL));

		/* Nothing new to decode; a pending copy stays pending */
		if (moveto <= MyReplicationSlot->data.confirmed_flush ||
			moveto <= MyReplicationSlot->data.restart_lsn)
			return pending ? COPY_SNAPSHOT_INCONSISTENT : COPY_SNAPSHOT_UNCHECKED;

		return advance_copy_locally(moveto) ?
			COPY_SNAPSHOT_CONSISTENT : COPY_SNAPSHOT_INCONSISTENT;
	}
#endif

	LogicalConfirmReceivedLocation(remote_slot->confirmed_lsn);
	LogicalIncreaseXminForSlot(remote_slot->confirmed_lsn,
							   remote_slot->catalog_xmin);
	LogicalIncreaseRestartDecodingForSlot(remote_slot->confirmed_lsn,
										  restart_lsn);
	return state;
}

/*
 * Slots whose invalidated copy the worker has warned about and left alone.
 * The warning is issued once, not on every pass: on PG17 a synced slot
 * stays in that state until promotion.  Returns true when the warning for
 * this slot is due; a slot no longer in that state is forgotten.
 */
static List *invalidated_warned = NIL;

/*
 * Track one kind of once-only warning: returns true when the warning for a
 * slot in that state is due, and forgets a slot no longer in it.
 */
static bool
warning_due(List **warned_list, const char *name, bool in_state)
{
	ListCell   *lc;
	MemoryContext oldcxt;

	foreach(lc, *warned_list)
	{
		char	   *warned = (char *) lfirst(lc);

		if (strcmp(warned, name) != 0)
			continue;
		if (!in_state)
		{
			*warned_list = foreach_delete_current(*warned_list, lc);
			pfree(warned);
		}
		return false;
	}

	if (!in_state)
		return false;

	oldcxt = MemoryContextSwitchTo(TopMemoryContext);
	*warned_list = lappend(*warned_list, pstrdup(name));
	MemoryContextSwitchTo(oldcxt);
	return true;
}

static bool
invalidated_warning_due(const char *name, bool left_alone)
{
	return warning_due(&invalidated_warned, name, left_alone);
}

/*
 * Forget warned slots the primary no longer has, so a name does not stay
 * on the list for the life of the worker.
 */
static void
warned_list_prune(List **warned_list, List *remote_slots)
{
	ListCell   *lc;

	foreach(lc, *warned_list)
	{
		char	   *warned = (char *) lfirst(lc);
		ListCell   *rc;
		bool		present = false;

		foreach(rc, remote_slots)
		{
			if (strcmp(((RemoteSlot *) lfirst(rc))->name, warned) == 0)
			{
				present = true;
				break;
			}
		}
		if (!present)
		{
			*warned_list = foreach_delete_current(*warned_list, lc);
			pfree(warned);
		}
	}
}

static void
invalidated_warned_prune(List *remote_slots)
{
	warned_list_prune(&invalidated_warned, remote_slots);
	warned_list_prune(&undecodable_warned, remote_slots);
	warned_list_prune(&inconsistent_warned, remote_slots);
}

/*
 * Synchronize one logical replication slot's state from the master to this
 * standby, creating it if necessary.
 *
 * Note that this only works safely because we know for sure that this is
 * executed on standby where primary has another slot which reserves resources
 * at the position to which we are moving the local slot to.
 *
 * This standby uses a physical replication slot to connect to the master so it
 * can send the xmin and catalog_xmin separately over hot_standby_feedback. Our
 * physical slot on the master ensures the master's catalog_xmin never goes
 * below ours after the initial setup period.
 */
static void
synchronize_one_slot(RemoteSlot *remote_slot)
{
	int			i;
	bool		found = false;
	bool		invalidated = false;
	bool		active = false;
	bool		synced = false;

	if (!RecoveryInProgress())
	{
		/* Should only happen when promotion occurs at the same time we sync */
		ereport(
				WARNING,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg(
						"attempted to sync slot from master when not in recovery")));
		return;
	}

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());

	/* Search for the named slot locally */
	LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
	for (i = 0; i < max_replication_slots; i++)
	{
		ReplicationSlot *s = &ReplicationSlotCtl->replication_slots[i];

		/* Not in use, not interesting. */
		if (!s->in_use)
			continue;

		if (strcmp(NameStr(s->data.name), remote_slot->name) == 0)
		{
			found = true;
			/* A pending copy is held by this process */
			active = SlotIsActive(s) && s->active_pid != MyProcPid;
			SpinLockAcquire(&s->mutex);
			invalidated = slot_is_invalidated(s);
#if PG_VERSION_NUM >= 170000
			synced = s->data.synced;
#endif
			SpinLockRelease(&s->mutex);
			break;
		}
	}
	LWLockRelease(ReplicationSlotControlLock);

	/*
	 * The local copy was invalidated, for example because the primary removed
	 * catalog rows it still needed.  Advancing its metadata would make it
	 * look healthy while it can never be used after promotion, so drop it and
	 * create it again from the primary below.
	 *
	 * Leave it alone while a walsender holds it, and on PG17 when it was
	 * created by native slot sync, since ReplicationSlotDrop() refuses to
	 * drop a synced slot on a standby.
	 */
	if (found && invalidated && (active || synced))
	{
		if (invalidated_warning_due(remote_slot->name, true))
			elog(WARNING,
				 "replication slot \"%s\" is invalidated but %s, "
				 "not synchronizing it",
				 remote_slot->name,
				 active ? "in use" : "owned by native slot sync");
		PopActiveSnapshot();
		CommitTransactionCommand();
		return;
	}
	/*
	 * With spock.failover_slots_recreate_invalidated off the copy is left as
	 * it is and reported once, so it can be looked at before it is dropped.
	 * It is recreated on the first pass after the setting is turned on.
	 */
	if (found && invalidated && !spock_failover_slots_recreate_invalidated)
	{
		if (invalidated_warning_due(remote_slot->name, true))
			elog(WARNING,
				 "replication slot \"%s\" is invalidated on the standby, "
				 "not recreating it: spock.failover_slots_recreate_invalidated is off",
				 remote_slot->name);
		PopActiveSnapshot();
		CommitTransactionCommand();
		return;
	}
	invalidated_warning_due(remote_slot->name, false);

	/*
	 * Remote slot exists locally, acquire and move. There's a race here where
	 * the slot could've been dropped since we checked, but we'll just ERROR
	 * out in `ReplicationSlotAcquire` and retry next loop so it's harmless.
	 * The same happens if a walsender takes the slot first; the worker then
	 * exits and is restarted after bgw_restart_time.
	 *
	 * Moving the slot this way does not do logical decoding. We're not
	 * processing WAL, we're just updating the slot metadata.
	 */
	if (found)
	{
		bool		now_invalidated;

#if PG_VERSION_NUM >= 180000
		ReplicationSlotAcquire(remote_slot->name, true, true);
#else
		ReplicationSlotAcquire(remote_slot->name, true);
#endif

		/*
		 * A restartpoint can invalidate the copy between the lookup above and
		 * the acquire.  Advancing it would hide that, so leave it as it is;
		 * the next pass handles it like any other invalidated copy.
		 */
		SpinLockAcquire(&MyReplicationSlot->mutex);
		now_invalidated = slot_is_invalidated(MyReplicationSlot);
		SpinLockRelease(&MyReplicationSlot->mutex);
		if (now_invalidated && !invalidated)
		{
			ReplicationSlotRelease();
			PopActiveSnapshot();
			CommitTransactionCommand();
			return;
		}

		/*
		 * Drop the invalidated copy while it is acquired, so no walsender can
		 * take it between the check and the drop.  ReplicationSlotDropAcquired()
		 * is not exported before PG17, but releasing an ephemeral slot drops
		 * it, so mark the copy ephemeral and release it.  If removing its
		 * directory fails, the drop only warns and the copy is back after a
		 * server restart, to be recreated again.
		 */
		if (invalidated)
		{
			elog(WARNING,
				 "replication slot \"%s\" is invalidated on the standby, "
				 "recreating it from the primary",
				 remote_slot->name);
			SpinLockAcquire(&MyReplicationSlot->mutex);
			MyReplicationSlot->data.persistency = RS_EPHEMERAL;
			SpinLockRelease(&MyReplicationSlot->mutex);
			ReplicationSlotRelease();
			found = false;
		}
	}

	if (found)
	{
		bool		pending;
		CopySnapshotState state;

		/* A temporary copy is one this worker has not made persistent yet */
		SpinLockAcquire(&MyReplicationSlot->mutex);
		pending = MyReplicationSlot->data.persistency == RS_TEMPORARY;
		SpinLockRelease(&MyReplicationSlot->mutex);

		/*
		 * We can't satisfy this remote slot's requirements with our
		 * known-safe local restart_lsn, catalog_xmin and xmin.
		 *
		 * Without local decoding this shouldn't happen for existing slots
		 * unless someone else messed with our physical replication slot on
		 * the master.  Local decoding moves restart_lsn and catalog_xmin to
		 * where the standby saved a snapshot, which can be ahead of the
		 * primary, so there it is routine.  For a pending copy it is
		 * expected.  Either way, try again on the next pass.
		 */
		if (remote_slot->own_restart_lsn < MyReplicationSlot->data.restart_lsn ||
			(TransactionIdIsValid(remote_slot->catalog_xmin) &&
			 TransactionIdPrecedes(remote_slot->catalog_xmin,
								   MyReplicationSlot->data.catalog_xmin)))
		{
			if (!pending)
				elog(local_decoding_unavailable(MyReplicationSlot) ? WARNING : DEBUG1,
					 "not synchronizing slot %s; synchronization would move it backward",
					 remote_slot->name);

			ReplicationSlotRelease();
			PopActiveSnapshot();
			CommitTransactionCommand();
			return;
		}

		/*
		 * A pending copy is made persistent only once it has a consistent
		 * snapshot; until then it could skip transactions after a promotion.
		 * A persistent copy without one, for example one copied before
		 * local decoding was turned on while a long transaction was open on
		 * the primary, is reported once until it gets one.
		 */
		state = apply_remote_position(remote_slot);
		if (state == COPY_SNAPSHOT_INCONSISTENT && pending)
		{
			elog(DEBUG1,
				 "replication slot \"%s\" has no consistent snapshot on the standby yet",
				 remote_slot->name);
			ReplicationSlotMarkDirty();
			ReplicationSlotRelease();
			PopActiveSnapshot();
			CommitTransactionCommand();
			return;
		}
		if (state != COPY_SNAPSHOT_UNCHECKED &&
			warning_due(&inconsistent_warned, remote_slot->name,
						state == COPY_SNAPSHOT_INCONSISTENT))
			ereport(WARNING,
					(errmsg("replication slot \"%s\" has no consistent snapshot on the standby",
							remote_slot->name),
					 errdetail("Decoding from its restart_lsn has not reached a consistent "
							   "point, usually because a transaction older than that is "
							   "still open on the primary."),
					 errhint("A promotion now could skip transactions committed shortly "
							 "before it.  The worker keeps decoding and reports nothing "
							 "more once the slot is consistent.")));
		ReplicationSlotMarkDirty();
		if (pending)
		{
			ReplicationSlotPersist();
			elog(LOG, "created replication slot \"%s\" on the standby",
				 remote_slot->name);
		}
		else
			ReplicationSlotSave();

		elog(
			 DEBUG2,
			 "synchronized existing slot %s to lsn (%X/%X) and catalog xmin (%u)",
			 remote_slot->name, (uint32) (remote_slot->restart_lsn >> 32),
			 (uint32) (remote_slot->restart_lsn), remote_slot->catalog_xmin);
	}

	/*
	 * Otherwise create the local slot and initialize it to the state of the
	 * upstream slot. There's a race here where the slot could've been
	 * concurrently created, but we'll just ERROR out and retry so it's
	 * harmless.
	 */
	else
	{
		TransactionId xmin_horizon = InvalidTransactionId;
		ReplicationSlot *slot;

		/*
		 * We have to create the slot to reserve its name and resources, but
		 * don't want it to persist if we fail.
		 *
		 * The slot is temporary: if the primary's slot is behind it, this
		 * worker keeps holding it across passes instead of waiting here, and
		 * makes it persistent once the primary has caught up (see the found
		 * branch above).  Waiting would stop the sync of every other slot.
		 * The worker drops it if sync stops or the standby is promoted
		 * first, and so does its exit.
		 */
#if PG_VERSION_NUM >= 170000
		ReplicationSlotCreate(remote_slot->name, true, RS_TEMPORARY,
							  remote_slot->two_phase,
							  false,
							  false);
#else
		ReplicationSlotCreate(remote_slot->name, true, RS_TEMPORARY,
							  remote_slot->two_phase);
#endif
		slot = MyReplicationSlot;

		SpinLockAcquire(&slot->mutex);
		slot->data.database = get_database_oid(remote_slot->database);
		strlcpy(NameStr(slot->data.plugin), remote_slot->plugin, NAMEDATALEN);
		SpinLockRelease(&slot->mutex);

		/*
		 * Stop our physical slot from advancing past the position needed by
		 * the new remote slot by making its reservations locally effective.
		 * It's OK if we can't guarantee their safety yet, the slot isn't
		 * visible to anyone else at this point.
		 */
		ReplicationSlotReserveWal();

		/*
		 * On PG16 and earlier standbys, ReplicationSlotReserveWal() may set
		 * restart_lsn to InvalidXLogRecPtr (zero) or to a value that is below
		 * the standby's recovery redo pointer — the oldest WAL position the
		 * standby actually has from the pg_basebackup checkpoint.
		 *
		 * When restart_lsn is zero, the unsigned comparison below
		 * (remote_slot->own_restart_lsn < slot->data.restart_lsn) is always
		 * FALSE for any real remote LSN, so the slot is never kept pending.
		 * When restart_lsn is a small but non-zero value (less than the redo
		 * pointer), the comparison still fails to fire for remote
		 * slots that require WAL older than what the standby has.  In both
		 * cases we end up persisting a slot with the remote's restart_lsn,
		 * which the standby cannot satisfy, causing an immediate PANIC
		 * ("required WAL not available") and an infinite crash loop on the
		 * next startup.
		 *
		 * Fix: always ensure restart_lsn is at least as high as the recovery
		 * redo pointer (GetRedoRecPtr), which is set from the basebackup
		 * checkpoint and represents the guaranteed minimum WAL floor on this
		 * standby.  Any remote slot that requires WAL older than that then
		 * correctly stays pending until the primary's slot passes it.
		 */
		{
			XLogRecPtr	old_lsn = MyReplicationSlot->data.restart_lsn;
			XLogRecPtr	redo_lsn = GetRedoRecPtr();

			if (!XLogRecPtrIsInvalid(redo_lsn) && redo_lsn > old_lsn)
			{
				SpinLockAcquire(&slot->mutex);
				slot->data.restart_lsn = redo_lsn;
				SpinLockRelease(&slot->mutex);
				elog(DEBUG1,
					 "spock_failover_slots: bumped restart_lsn from %X/%X to"
					 " redo pointer %X/%X for new slot \"%s\"",
					 LSN_FORMAT_ARGS(old_lsn),
					 LSN_FORMAT_ARGS(redo_lsn), remote_slot->name);
			}
		}

		/*
		 * Compute the safe xmin horizon and seed the new slot.
		 *
		 * Before, this section held ReplicationSlotControlLock LW_EXCLUSIVE +
		 * ProcArrayLock LW_EXCLUSIVE while calling
		 * ReplicationSlotsComputeRequiredXmin(true) (the "locks already held"
		 * form).  That serialised this worker against every other caller of
		 * ReplicationSlotControlLock LW_SHARED — including the SHARED
		 * acquire that PG core itself does from ReplicationSlotRelease() and
		 * ReplicationSlotDropPtr() via
		 * ReplicationSlotsComputeRequiredXmin(false).  On PG17+, where these
		 * helpers can be invoked indirectly later in this same function (and
		 * from other concurrent slot operations), the resulting contention on
		 * the standby manifested as a pile-up: the spock_failover_slots
		 * worker hangs in LWLockAcquire(ReplicationSlotControlLock,
		 * LW_SHARED) and every backend trying to initialise queues behind it.
		 *
		 * Fix: take ProcArrayLock LW_SHARED briefly to read the proc array,
		 * update the slot fields under the slot's SpinLock, then let
		 * ReplicationSlotsComputeRequiredXmin(false) acquire its own short
		 * SHARED RSCL the way every PG-core call site does.  Per the comment
		 * in PG core's ReplicationSlotsComputeRequiredXmin: "Concurrent
		 * invocation may cause the computed slot xmin to regress.  However,
		 * this is harmless..."
		 */
		LWLockAcquire(ProcArrayLock, LW_SHARED);
		xmin_horizon = GetOldestSafeDecodingTransactionId(true);
		LWLockRelease(ProcArrayLock);

		SpinLockAcquire(&slot->mutex);
		slot->effective_catalog_xmin = xmin_horizon;
		slot->data.catalog_xmin = xmin_horizon;
		SpinLockRelease(&slot->mutex);

		ReplicationSlotsComputeRequiredXmin(false);

		/*
		 * Our xmin and/or catalog_xmin may be > that required by one or more
		 * of the slots we are trying to sync from the master, and/or we don't
		 * have enough retained WAL for the slot's restart_lsn.
		 *
		 * If we persist the slot locally in that state it'll make a false
		 * promise we can't satisfy.
		 *
		 * This can happen if this replica is fairly new or has only recently
		 * started failover slot sync, and after a copy was recreated.  Keep
		 * the slot pending and check again on the next pass.
		 */
		if (remote_slot->own_restart_lsn < MyReplicationSlot->data.restart_lsn ||
			(TransactionIdIsValid(remote_slot->catalog_xmin) &&
			 TransactionIdPrecedes(remote_slot->catalog_xmin,
								   MyReplicationSlot->data.catalog_xmin)))
		{
			elog(LOG,
				 "waiting for remote slot %s lsn (%X/%X) and catalog xmin (%u) to pass local slot lsn (%X/%X) and catalog xmin (%u)",
				 remote_slot->name, LSN_FORMAT_ARGS(remote_slot->own_restart_lsn),
				 remote_slot->catalog_xmin,
				 LSN_FORMAT_ARGS(MyReplicationSlot->data.restart_lsn),
				 MyReplicationSlot->data.catalog_xmin);
			ReplicationSlotRelease();
			PopActiveSnapshot();
			CommitTransactionCommand();
			return;
		}

		/*
		 * We can locally satisfy requirements of remote slot's current
		 * position now. Apply the new position if any and make it persistent
		 * once it has a consistent snapshot; until then keep it pending.
		 */
		if (apply_remote_position(remote_slot) == COPY_SNAPSHOT_INCONSISTENT)
		{
			ReplicationSlotMarkDirty();
			ReplicationSlotRelease();
			PopActiveSnapshot();
			CommitTransactionCommand();
			return;
		}
		ReplicationSlotMarkDirty();

		ReplicationSlotPersist();
		elog(LOG, "created replication slot \"%s\" on the standby",
			 remote_slot->name);

		elog(DEBUG1,
			 "synchronized new slot %s to lsn (%X/%X) and catalog xmin (%u)",
			 remote_slot->name, (uint32) (remote_slot->restart_lsn >> 32),
			 (uint32) (remote_slot->restart_lsn), remote_slot->catalog_xmin);
	}

	ReplicationSlotRelease();
	PopActiveSnapshot();
	CommitTransactionCommand();
}

/*
 * Drop the pending copies: temporary slots held by this process that are
 * not caught up with the primary and cannot serve a subscriber after a
 * promotion.  Called whenever the worker is not synchronizing.
 */
static void
drop_pending_copies(void)
{
#if PG_VERSION_NUM >= 170000
	ReplicationSlotCleanup(false);
#else
	ReplicationSlotCleanup();
#endif
}

/*
 * Synchronize the slot states from master to standby.
 *
 * This logic emulates the "failover slots" behaviour unsuccessfully proposed
 * for 9.6 using the PostgreSQL 10 features "catalog xmin in hot standby
 * feedback" and "logical decoding follows timeline switches".
 *
 * This is only called in recovery from main loop of manager and only in PG10+
 * because in older versions the manager worker uses
 * bgw_start_time = BgWorkerStart_RecoveryFinished.
 *
 * We could technically synchronize slot positions even on older versions of
 * PostgreSQL but since logical decoding can't go over the timeline switch
 * before PG10, it's pointless to have slots synchronized. Also, older versions
 * can't keep catalog_xmin separate from xmin in hot standby feedback, so
 * sending the feedback we need to preserve our catalog_xmin could cause severe
 * table bloat on the master.
 *
 * This runs periodically. That's safe when the slots on the master already
 * exist locally because we have their resources reserved via hot standby
 * feedback. New subscriptions can't move that position backwards... but we
 * won't immediately know they exist when the master creates them. So there's a
 * window after each new subscription is created on the master where failover
 * to this standby will break that subscription.
 */
static long
synchronize_failover_slots(long sleep_time)
{
	List	   *slots;
	ListCell   *lc;
	PGconn	   *conn;
	XLogRecPtr	safe_lsn;
	XLogRecPtr	lsn = InvalidXLogRecPtr;
	static bool was_lsn_safe = false;
	bool		is_lsn_safe = false;
	StringInfoData connstr;

	if (!WalRcv || !HotStandbyActive() ||
		list_length(spock_failover_slot_names_list) == 0)
	{
		drop_pending_copies();
		return sleep_time;
	}

	/*
	 * Sync requires hot_standby_feedback; skip when off so the worker keeps
	 * running without error. After user sets hot_standby_feedback on and
	 * reloads, the next cycle will run sync.
	 */
	if (!hot_standby_feedback)
		return sleep_time;
	if (WalRcv->slotname[0] == '\0')
		elog(
			 ERROR,
			 "cannot synchronize replication slot positions because primary_slot_name is not set");

	elog(DEBUG1, "starting replication slot synchronization from primary");

	initStringInfo(&connstr);
	if (!make_sync_failover_slots_dsn(&connstr, NULL /* Use default db name */ ))
	{
		/* Nothing to connect with yet.  Nap and retry later. */
		elog(DEBUG1, "no connection string for the primary yet, "
			 "deferring replication slot synchronization");
		pfree(connstr.data);
		return sleep_time;
	}

	conn = remote_connect(connstr.data, "spock_failover_slots");

	/*
	 * Do not synchronize WAL decoder slots on a physical standy.
	 *
	 * WAL decoder slots are used to produce LCRs. These LCRs are not
	 * synchronized on a physical standby after initial backup and hence are
	 * not included in the base backup. Thus WAL decoder slots, if
	 * synchronized on physical standby, do not reflect the status of LCR
	 * directory as they do on primary.
	 *
	 * There are other slots whose WAL senders use LCRs. These other slots are
	 * synchronized and used after promotion. Since the WAL decoder slots are
	 * ahead of these other slots, the WAL decoder when started after
	 * promotion might miss LCRs required by WAL senders of the other slots.
	 * This would cause data inconsistency after promotion.
	 *
	 * Hence do not synchronize WAL decoder slot. Those will be created after
	 * promotion
	 */
	slots = remote_get_primary_slot_info(conn, spock_failover_slot_names_list);
	safe_lsn = remote_get_physical_slot_lsn(conn, WalRcv->slotname);

	/*
	 * Delete locally-existing slots that don't exist on the master.
	 */
	for (;;)
	{
		int			i;
		char	   *dropslot = NULL;

		LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
		for (i = 0; i < max_replication_slots; i++)
		{
			ReplicationSlot *s = &ReplicationSlotCtl->replication_slots[i];
			bool		active;
			bool		pending;
			bool		found = false;

			/* A pending copy is held by this process */
			pending = s->active_pid == MyProcPid;
			active = SlotIsActive(s) && !pending;

			/* Only check inactive slots. */
			if (!s->in_use || active)
				continue;

			/* Only check for logical slots. */
			if (SlotIsPhysical(s))
				continue;

			/* Try to find slot in slots returned by primary. */
			foreach(lc, slots)
			{
				RemoteSlot *remote_slot = lfirst(lc);

				if (strcmp(NameStr(s->data.name), remote_slot->name) == 0)
				{
					found = true;
					break;
				}
			}

			/*
			 * Not found, should be dropped if synchronize_failover_slots_drop
			 * is enabled.  A pending copy is not a usable slot, so it is
			 * dropped either way.
			 */
			if (!found && (spock_failover_slots_drop || pending))
			{
				dropslot = pstrdup(NameStr(s->data.name));
				break;
			}
		}
		LWLockRelease(ReplicationSlotControlLock);

		if (dropslot)
		{
			elog(WARNING, "dropping replication slot \"%s\"", dropslot);
			ReplicationSlotDrop(dropslot, false);
			pfree(dropslot);
		}
		else
			break;
	}

	/*
	 * Prune here rather than after the synchronization below: when the
	 * primary has dropped its last matching slot we return just below, and a
	 * name left on the warned list would then suppress the warning if the
	 * primary ever reused it.  An empty remote list correctly clears them
	 * all.
	 */
	invalidated_warned_prune(slots);

	if (!list_length(slots))
	{
		PQfinish(conn);
		return sleep_time;
	}

	/* Find oldest restart_lsn still needed by any failover slot. */
	foreach(lc, slots)
	{
		RemoteSlot *remote_slot = lfirst(lc);

		if (lsn == InvalidXLogRecPtr || remote_slot->restart_lsn < lsn)
			lsn = remote_slot->restart_lsn;
	}

	/*
	 * We need the WAL flush position both for the latestWalEnd/lsn check and
	 * for capping confirmed_lsn inside the slot loop.  Read it once here so
	 * we use a consistent value throughout.
	 *
	 * On PostgreSQL builds with --enable-cassert,
	 * LogicalConfirmReceivedLocation asserts that the LSN passed to it is not
	 * InvalidXLogRecPtr.  If GetWalRcvFlushRecPtr returns 0 (which can happen
	 * in the brief window after the WAL receiver starts but before it has
	 * flushed its first page), capping confirmed_lsn to 0 and then passing 0
	 * to LogicalConfirmReceivedLocation will trip that assertion and SIGABRT
	 * the bgworker, causing a postmaster cluster reset on every loop
	 * iteration. Guard by returning early when the flush position is not yet
	 * valid.
	 */
	{
		XLogRecPtr	receivePtr = GetWalRcvFlushRecPtr(NULL, NULL);

		if (safe_lsn == InvalidXLogRecPtr ||
			WalRcv->latestWalEnd == InvalidXLogRecPtr ||
			XLogRecPtrIsInvalid(receivePtr))
		{
			ereport(
					WARNING,
					(errmsg(
							"cannot synchronize replication slot positions yet because feedback was not sent yet")));
			was_lsn_safe = false;
			PQfinish(conn);
			return Min(sleep_time, spock_failover_slots_feedback_naptime);
		}
		else if (WalRcv->latestWalEnd < lsn)
		{
			ereport(
					WARNING,
					(errmsg(
							"requested slot synchronization point %X/%X is ahead of the standby position %X/%X, not synchronizing slots",
							(uint32) (lsn >> 32), (uint32) (lsn),
							(uint32) (WalRcv->latestWalEnd >> 32),
							(uint32) (WalRcv->latestWalEnd))));
			was_lsn_safe = false;
			PQfinish(conn);
			return Min(sleep_time, spock_failover_slots_feedback_naptime);
		}

		foreach(lc, slots)
		{
			RemoteSlot *remote_slot = lfirst(lc);

			/*
			 * If we haven't received WAL for a remote slot's current
			 * confirmed_flush_lsn our local copy shouldn't reflect a
			 * confirmed position in the future. Cap it at the position we
			 * really received.
			 *
			 * Because the client will use a replication origin to track its
			 * position, in most cases it'll still fast-forward to the new
			 * confirmed position even if that skips over a gap of WAL we
			 * never received from the provider before failover. We can't
			 * detect or prevent that as the same fast forward is normal when
			 * we lost slot state in a provider crash after subscriber
			 * committed but before we saved the new confirmed flush lsn. The
			 * master will also fast forward the slot over irrelevant changes
			 * and then the subscriber will update its confirmed_flush_lsn in
			 * response to master standby status updates.
			 *
			 * receivePtr is guaranteed non-zero here (checked above).
			 */
			if (remote_slot->confirmed_lsn > receivePtr)
				remote_slot->confirmed_lsn = receivePtr;

			/*
			 * For simplicity we always move restart_lsn of all slots to the
			 * restart_lsn needed by the furthest-behind master slot.  Whether
			 * the local copy can satisfy the slot is checked against its own
			 * restart_lsn, so one slot that lags does not hold back the
			 * others.
			 */
			remote_slot->own_restart_lsn = Min(remote_slot->restart_lsn,
											   receivePtr);
			if (remote_slot->restart_lsn > lsn)
				remote_slot->restart_lsn = lsn;

			/*
			 * Skip slots whose primary confirmed_flush_lsn is still
			 * InvalidXLogRecPtr (no consumer feedback yet).
			 * LogicalConfirmReceivedLocation asserts the LSN is not invalid;
			 * passing 0 aborts the bgworker and triggers a postmaster cluster
			 * reset on --enable-cassert builds.
			 */
			if (XLogRecPtrIsInvalid(remote_slot->confirmed_lsn))
			{
				elog(DEBUG1,
					 "spock_failover_slots: deferring slot \"%s\":"
					 " no confirmed_flush_lsn on primary yet",
					 remote_slot->name);
				continue;
			}

			synchronize_one_slot(remote_slot);
		}
	}

	PQfinish(conn);

	if (!was_lsn_safe && is_lsn_safe)
		elog(LOG, "slot synchronization from primary now active");

	was_lsn_safe = is_lsn_safe;

	return sleep_time;
}
/*
 * Connect to spock.failover_slots_database if set: decoding a copy on the
 * standby needs a database connection, and on PG16 the slot's own
 * database.  Otherwise connect only to the shared catalogs (we only read
 * pg_database).
 */
static void
failover_slots_connect(void)
{
#if PG_VERSION_NUM >= 160000
	const char *dbname = spock_failover_slots_database;

	if (dbname && dbname[0])
	{
		if (!spock_failover_slots_db_connecting())
		{
			/*
			 * A missing database makes the connection FATAL.  The flag then
			 * stays set, so the restarted worker connects without a database
			 * and slot sync goes on, without the snapshot check, until the
			 * server is restarted with a corrected setting.
			 */
			spock_set_failover_slots_db_connecting(true);
			BackgroundWorkerInitializeConnection(dbname, NULL, 0);
			spock_set_failover_slots_db_connecting(false);
			return;
		}
		ereport(WARNING,
				(errmsg("spock_failover_slots worker is not connecting to database \"%s\"",
						dbname),
				 errdetail("An earlier attempt to connect to it failed."),
				 errhint("Correct spock.failover_slots_database and restart the server.")));
	}
#endif
	BackgroundWorkerInitializeConnection(NULL, NULL, 0);
}
#endif							/* PG_VERSION_NUM < 180000 */

void
spock_failover_slots_main(Datum main_arg)
{
#if PG_VERSION_NUM >= 180000
	/*
	 * PostgreSQL 18 has native logical slot synchronization via
	 * sync_replication_slots = on.  This worker is not registered on PG18, so
	 * this entry point should never be reached.
	 */
	elog(ERROR, "spock_failover_slots_main: not supported on PostgreSQL 18+");
#else
	/* Establish signal handlers. */
	pqsignal(SIGUSR1, procsignal_sigusr1_handler);
	pqsignal(SIGTERM, die);
	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	BackgroundWorkerUnblockSignals();

	/* Make it easy to identify our processes. */
	SetConfigOption("application_name", MyBgworkerEntry->bgw_name,
					PGC_SU_BACKEND, PGC_S_OVERRIDE);

	elog(LOG, "starting spock_failover_slots replica worker");

	failover_slots_connect();

	/* Main wait loop. */
	while (true)
	{
		int			rc;
		long		sleep_time = spock_failover_slots_naptime;

		CHECK_FOR_INTERRUPTS();

		/*
		 * On standby, run sync only when hot_standby_feedback is on;
		 * otherwise use long nap so we never elog(ERROR) for
		 * hot_standby_feedback off.
		 *
		 * On PG17+, yield entirely to PostgreSQL's native slotsync worker
		 * when sync_replication_slots = on is configured.
		 * IsSyncingReplicationSlots() is process-local and would always be
		 * false here; instead we check the exported sync_replication_slots
		 * GUC variable directly — if the DBA has enabled the native worker,
		 * we must not compete with it.
		 */
		if (RecoveryInProgress() && hot_standby_feedback
#if PG_VERSION_NUM >= 170000
			&& !sync_replication_slots
#endif
			)
			sleep_time = synchronize_failover_slots(spock_failover_slots_naptime);
		else
		{
			/*
			 * Not synchronizing: after a promotion, with hot_standby_feedback
			 * off, or with native slot sync on PG17, where pending copies
			 * would also block it.  Pending copies cannot serve a subscriber
			 * after a promotion, so drop them.
			 */
			drop_pending_copies();
			sleep_time = (long) spock_failover_slots_naptime * 10;
		}

		rc =
			WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					  sleep_time, PG_WAIT_EXTENSION);

		ResetLatch(MyLatch);

		/* Emergency bailout if postmaster has died. */
		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		/* Reload the config if needed. */
		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
		}
	}
#endif							/* PG_VERSION_NUM < 180000 */
}

#if PG_VERSION_NUM < 180000
static bool
list_member_str(List *l, const char *str)
{
	ListCell   *lc;

	foreach(lc, l)
		if (strcmp((const char *) lfirst(lc), str) == 0)
		return true;
	return false;
}


/*
 * Check whether we want to actually wait for pg_standby_slot_names
 */
static bool
skip_standby_slot_names(XLogRecPtr commit_lsn)
{
	static List *cached_standby_slot_names = NIL;

	if (pg_standby_slot_names != cached_standby_slot_names)
	{
		if (MyReplicationSlot)
		{
			if (list_member_str(pg_standby_slot_names,
								NameStr(MyReplicationSlot->data.name)))
			{
				standby_slots_min_confirmed = 0;
				elog(
					 DEBUG1,
					 "found my slot in spock_failover_slots.pg_standby_slot_names, no need to wait for confirmations");
			}
		}

		cached_standby_slot_names = pg_standby_slot_names;
	}

	/*
	 * If we already know all slots of interest satisfy the requirement we can
	 * skip checks entirely. The assignment hook for
	 * spock_failover_slots.pg_standby_slot_names invalidates the cache.
	 */
	if (standby_slot_names_oldest_flush_lsn >= commit_lsn ||
		standby_slots_min_confirmed == 0 ||
		list_length(pg_standby_slot_names) == 0)
		return true;

	return false;
}

/*
 * Wait until the nominated set of standbys, if any, have flushed past the
 * specified lsn. Standbys are identified by slot name, not application_name
 * like in synchronous_standby_names.
 *
 * confirmed_flush_lsn is used for physical slots, restart_lsn for logical
 * slots.
 *
 */
static void
wait_for_standby_confirmation(XLogRecPtr commit_lsn)
{
	XLogRecPtr	flush_pos = InvalidXLogRecPtr;
	TimestampTz wait_start = GetCurrentTimestamp();

	if (skip_standby_slot_names(commit_lsn))
		return;

	while (1)
	{
		int			i;
		int			wait_slots_remaining;
		XLogRecPtr	oldest_flush_pos = InvalidXLogRecPtr;
		int			rc;

		if (standby_slots_min_confirmed == -1)
		{
			/*
			 * Default spock_failover_slots.standby_slots_min_confirmed (-1)
			 * is to wait for all entries in
			 * spock_failover_slots.pg_standby_slot_names.
			 */
			wait_slots_remaining = list_length(pg_standby_slot_names);
		}
		else
		{
			/*
			 * spock_failover_slots.standby_slots_min_confirmed cannot wait
			 * for more slots than are named in the
			 * spock_failover_slots.pg_standby_slot_names.
			 */
			wait_slots_remaining = Min(standby_slots_min_confirmed,
									   list_length(pg_standby_slot_names));
		}

		Assert(wait_slots_remaining > 0 &&
			   wait_slots_remaining <= list_length(pg_standby_slot_names));

		LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
		for (i = 0; i < max_replication_slots; i++)
		{
			ReplicationSlot *s = &ReplicationSlotCtl->replication_slots[i];

			if (!s->in_use)
				continue;

			if (!list_member_str(pg_standby_slot_names, NameStr(s->data.name)))
				continue;

			SpinLockAcquire(&s->mutex);

			if (s->data.database == InvalidOid)

				/*
				 * Physical slots advance restart_lsn on flush and ignore
				 * confirmed_flush_lsn
				 */
				flush_pos = s->data.restart_lsn;
			else
				/* For logical slots we must wait for commit and flush */
				flush_pos = s->data.confirmed_flush;

			SpinLockRelease(&s->mutex);

			/* We want to find out the min(flush pos) over all named slots */
			if (oldest_flush_pos == InvalidXLogRecPtr ||
				oldest_flush_pos > flush_pos)
				oldest_flush_pos = flush_pos;

			if (flush_pos >= commit_lsn && wait_slots_remaining > 0)
				wait_slots_remaining--;
		}
		LWLockRelease(ReplicationSlotControlLock);

		if (wait_slots_remaining == 0)
		{
			/*
			 * If the oldest slot pos across all named slots advanced, update
			 * the cache so we can skip future calls. It'll be invalidated if
			 * the GUCs change.
			 */
			if (standby_slot_names_oldest_flush_lsn < oldest_flush_pos)
				standby_slot_names_oldest_flush_lsn = oldest_flush_pos;

			return;
		}

		/*
		 * Ideally we'd be able to ask these walsenders to wake us if they
		 * advance past the point of interest, but that'll require some core
		 * patching. For now, poll.
		 *
		 * We don't test for postmaster death here because it turns out to be
		 * really slow. The postmaster should kill us, we'll notice when we
		 * time out, and it's not a long sleep.
		 *
		 * TODO some degree of backoff on sleeps?
		 */
		rc =
			WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					  100L, PG_WAIT_EXTENSION);

		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		ResetLatch(MyLatch);

		CHECK_FOR_INTERRUPTS();

		if (wal_sender_timeout > 0 &&
			GetCurrentTimestamp() >
			TimestampTzPlusMilliseconds(wait_start, wal_sender_timeout))
		{
			ereport(
					COMMERROR,
					(errmsg(
							"terminating walsender process due to spock_failover_slots.pg_standby_slot_names replication timeout")));
			proc_exit(0);
		}

		/*
		 * The user might clear bdr.standby_slot_name or change it to a new
		 * standby. If we don't notice, we'll keep looping indefinitely here,
		 * so we have to check for config changes.
		 */
		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);

			if (skip_standby_slot_names(commit_lsn))
				return;
		}
	}
}

/*
 * Hackery to inject ourselves into walsender's logical stream starts here
 */
static const PQcommMethods *OldPqCommMethods;

static void
socket_comm_reset(void)
{
	OldPqCommMethods->comm_reset();
}

static int
socket_flush(void)
{
	return OldPqCommMethods->flush();
}

static int
socket_flush_if_writable(void)
{
	return OldPqCommMethods->flush_if_writable();
}

static bool
socket_is_send_pending(void)
{
	return OldPqCommMethods->is_send_pending();
}


static int
socket_putmessage(char msgtype, const char *s, size_t len)
{
	return OldPqCommMethods->putmessage(msgtype, s, len);
}

static void
socket_putmessage_noblock(char msgtype, const char *s, size_t len)
{
	if (msgtype == 'd' && len >= 17)
	{
		if (s[0] == 'w')
		{
			XLogRecPtr	lsn;

			/*
			 * Extract the lsn from the wal message, and convert it from
			 * network byte order.
			 */
			memcpy(&lsn, &s[1], sizeof(XLogRecPtr));
			lsn = pg_ntoh64(lsn);
			/* Wait for the lsn */
			wait_for_standby_confirmation(lsn);
		}
	}

	OldPqCommMethods->putmessage_noblock(msgtype, s, len);
}


static const
PQcommMethods PqCommSocketMethods = {
	socket_comm_reset, socket_flush, socket_flush_if_writable,
	socket_is_send_pending, socket_putmessage, socket_putmessage_noblock
};

static ClientAuthentication_hook_type original_client_auth_hook = NULL;

static void
attach_to_walsender(Port *port, int status)
{
	/*
	 * Any other plugins which use ClientAuthentication_hook.
	 */
	if (original_client_auth_hook)
		original_client_auth_hook(port, status);

	if (am_db_walsender)
	{
		OldPqCommMethods = PqCommMethods;
		PqCommMethods = &PqCommSocketMethods;
	}
}
#endif							/* PG_VERSION_NUM < 180000 */

/*
 * spock_slot_enable_failover
 *
 * SQL-callable maintenance helper used by the 5.0.12 -> 6.0.0 upgrade.
 *
 * PostgreSQL 17+ can synchronize a logical replication slot to a physical
 * standby (natively on 18 via sync_replication_slots, and on 17 when that GUC
 * is enabled), but only slots whose "failover" flag is set are synchronized.
 * Slots created by spock 6.0.0 already set the flag at CREATE time (see
 * ensure_replication_slot_snapshot() in spock_sync.c), but slots created by
 * earlier releases predate that logic.  This function marks every existing
 * spock logical slot as failover-enabled so it participates in slot sync.
 *
 * There is no SQL to alter the flag on an existing slot -- the walsender
 * ALTER_REPLICATION_SLOT command and pg_create_logical_replication_slot()'s
 * failover argument are the only in-tree ways to set it -- so we flip it here
 * the same way ReplicationSlotAlter() does, but acquiring the slot with
 * nowait = true so a busy walsender never blocks the upgrade transaction.
 *
 * Behaviour:
 *   - no-op (returns 0) on PostgreSQL 16 and older, where the flag doesn't exist;
 *   - no-op on a standby, where failover cannot be enabled;
 *   - skips slots that are already enabled, temporary, synced from a primary,
 *     invalidated, or currently held by a walsender (a NOTICE is emitted for
 *     active slots so the operator can rerun after pausing replication);
 *   - returns the number of slots whose failover flag was turned on.
 */
PG_FUNCTION_INFO_V1(spock_slot_enable_failover);
Datum
spock_slot_enable_failover(PG_FUNCTION_ARGS)
{
	int			n_enabled = 0;
#if PG_VERSION_NUM >= 170000
	int			i;
	List	   *targets = NIL;
	ListCell   *lc;
	MemoryContext caller_ctx = CurrentMemoryContext;

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to call spock.slot_enable_failover()")));

	/* Failover can only be enabled on a primary. */
	if (RecoveryInProgress())
	{
		ereport(NOTICE,
				(errmsg("spock: not enabling slot failover on a standby server")));
		PG_RETURN_INT32(0);
	}

	/*
	 * Collect the names of spock's persistent logical slots that don't yet
	 * have the failover flag set and aren't currently in use.  We only read
	 * shared slot state under the control lock here; the actual acquire/alter
	 * happens afterwards because ReplicationSlotAcquire() must not run while
	 * ReplicationSlotControlLock is held.
	 */
	LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
	for (i = 0; i < max_replication_slots; i++)
	{
		ReplicationSlot *s = &ReplicationSlotCtl->replication_slots[i];

		if (!s->in_use)
			continue;
		/* logical slots only (physical slots have no database) */
		if (s->data.database == InvalidOid)
			continue;
		/* spock's own slots only */
		if (strcmp(NameStr(s->data.plugin), "spock_output") != 0)
			continue;
		/* only persistent slots can carry the failover flag */
		if (s->data.persistency != RS_PERSISTENT)
			continue;
		/* already enabled */
		if (s->data.failover)
			continue;
		/* never touch a slot being synced from a primary */
		if (s->data.synced)
			continue;
		/* an invalidated slot cannot be altered or reused */
		if (s->data.invalidated != RS_INVAL_NONE)
			continue;
		/* skip slots held by a walsender so we never block the upgrade */
		if (SlotIsActive(s))
		{
			ereport(NOTICE,
					(errmsg("spock: replication slot \"%s\" is active; "
							"rerun spock.slot_enable_failover() after pausing replication",
							NameStr(s->data.name))));
			continue;
		}

		targets = lappend(targets, pstrdup(NameStr(s->data.name)));
	}
	LWLockRelease(ReplicationSlotControlLock);

	foreach(lc, targets)
	{
		char	   *slot_name = (char *) lfirst(lc);

		/*
		 * Isolate each slot in a subtransaction so a race (the slot turning
		 * active or being dropped after our scan) is skipped with a WARNING
		 * instead of aborting the whole upgrade.
		 */
		BeginInternalSubTransaction("spock_slot_enable_failover");
		PG_TRY();
		{
#if PG_VERSION_NUM >= 180000
			ReplicationSlotAcquire(slot_name, true, true);
#else
			ReplicationSlotAcquire(slot_name, true);
#endif
			SpinLockAcquire(&MyReplicationSlot->mutex);
			MyReplicationSlot->data.failover = true;
			SpinLockRelease(&MyReplicationSlot->mutex);
			ReplicationSlotMarkDirty();
			ReplicationSlotSave();
			ReplicationSlotRelease();

			ReleaseCurrentSubTransaction();
			MemoryContextSwitchTo(caller_ctx);
			n_enabled++;

			ereport(NOTICE,
					(errmsg("spock: enabled failover on replication slot \"%s\"",
							slot_name)));
		}
		PG_CATCH();
		{
			ErrorData  *edata;

			MemoryContextSwitchTo(caller_ctx);
			edata = CopyErrorData();
			FlushErrorState();

			/* release the slot if we acquired it before failing */
			if (MyReplicationSlot != NULL)
				ReplicationSlotRelease();

			RollbackAndReleaseCurrentSubTransaction();
			MemoryContextSwitchTo(caller_ctx);

			ereport(WARNING,
					(errmsg("spock: could not enable failover on replication slot \"%s\": %s",
							slot_name, edata->message)));
			FreeErrorData(edata);
		}
		PG_END_TRY();
	}
#else
	ereport(NOTICE,
			(errmsg("spock: replication slot failover requires PostgreSQL 17 or newer; nothing to do")));
#endif

	PG_RETURN_INT32(n_enabled);
}

void
spock_init_failover_slot(void)
{
#if PG_VERSION_NUM < 180000
	BackgroundWorker bgw;
#endif
	DefineCustomStringVariable(
							   "spock.pg_standby_slot_names",
							   "list of names of slot that must confirm changes before they're sent by the decoding plugin",
							   "List of physical replication slots that must confirm durable "
							   "flush of a given lsn before commits up to that lsn may be "
							   "replicated to logical peers by the output plugin. "
							   "Imposes ordering of physical replication before logical "
							   "replication.",
							   &standby_slot_names_raw, "", PGC_SIGHUP, GUC_LIST_INPUT,
							   check_standby_slot_names, assign_standby_slot_names, NULL);


	DefineCustomIntVariable(
							"spock.standby_slots_min_confirmed",
							"Number of slots from spock_failover_slots.pg_standby_slot_names that must confirm lsn",
							"Modifies behaviour of spock_failover_slots.pg_standby_slot_names so to allow "
							"logical replication of a transaction after at least "
							"spock_failover_slots.standby_slots_min_confirmed physical peers have confirmed "
							"the transaction as durably flushed. "
							"The value -1 (default) means all entries in spock_failover_slots.pg_standby_slot_names"
							"must confirm the write. The value 0 causes "
							"spock_failover_slots.standby_slots_min_confirmedto be effectively ignored.",
							&standby_slots_min_confirmed, -1, -1, 100, PGC_SIGHUP, 0, NULL, NULL,
							NULL);

	DefineCustomStringVariable(
							   "spock.synchronize_slot_names",
							   "list of slots to synchronize from primary to physical standby", "",
							   &spock_failover_slot_names, "name_like:%%",
							   PGC_SIGHUP,	/* Sync ALL slots by default */
							   GUC_LIST_INPUT, check_failover_slot_names, assign_failover_slot_names,
							   NULL);


	DefineCustomBoolVariable(
							 "spock.drop_extra_slots",
							 "whether to drop extra slots on standby that don't match spock_failover_slots.synchronize_slot_names",
							 NULL, &spock_failover_slots_drop, true, PGC_SIGHUP, 0, NULL, NULL, NULL);

	DefineCustomStringVariable(
							   "spock.primary_dsn",
							   "connection string to the primary server for synchronization logical slots on standby",
							   "if empty, uses the defaults to primary_conninfo",
							   &spock_failover_slots_dsn, "", PGC_SIGHUP, GUC_SUPERUSER_ONLY, NULL, NULL,
							   NULL);

	DefineCustomIntVariable(
							"spock.failover_slots_naptime",
							"time the failover slot worker sleeps between slot synchronization passes",
							"A smaller value keeps the standby's synchronized slots closer to the "
							"primary, at the cost of more frequent sync passes.",
							&spock_failover_slots_naptime, WORKER_NAP_TIME_DEFAULT,
							1, 3600000,
							PGC_SIGHUP, GUC_UNIT_MS, NULL, NULL, NULL);

	DefineCustomIntVariable(
							"spock.failover_slots_feedback_naptime",
							"shorter retry interval used while waiting for standby WAL feedback",
							"The worker retries this often (instead of failover_slots_naptime) while "
							"the standby has not yet received or fed back the WAL a slot needs.",
							&spock_failover_slots_feedback_naptime, WORKER_WAIT_FEEDBACK_DEFAULT,
							1, 3600000,
							PGC_SIGHUP, GUC_UNIT_MS, NULL, NULL, NULL);

	DefineCustomBoolVariable(
							"spock.failover_slots_recreate_invalidated",
							"whether the failover slot worker recreates a synchronized slot that was invalidated on the standby",
							"When off, an invalidated copy is left as it is and reported once.  It cannot "
							"serve a subscriber after a promotion until the setting is turned on and the "
							"copy is recreated from the primary.",
							&spock_failover_slots_recreate_invalidated, true,
							PGC_SIGHUP, 0, NULL, NULL, NULL);

	DefineCustomStringVariable(
							   "spock.failover_slots_database",
							   "database the failover slot worker connects to, to check that slot copies have a consistent snapshot",
							   "On PostgreSQL 16 and 17 the worker decodes each copy's WAL on the standby so the copy "
							   "can serve a subscriber after a promotion without skipping transactions.  That needs "
							   "a database connection; on PostgreSQL 16 it must be the database the slots are in.  "
							   "When empty, copies are synchronized without that check.",
							   &spock_failover_slots_database, "",
							   PGC_POSTMASTER, 0, NULL, NULL, NULL);

	if (IsBinaryUpgrade)
		return;

#if PG_VERSION_NUM >= 180000
	/*----------
	 * PostgreSQL 18 natively synchronizes logical replication slots to
	 * physical standbys via sync_replication_slots = on (slotsync worker)
	 * and provides synchronized_standby_slots for walsender hold-back.
	 * Spock's failover slot worker is not needed on PG18+.
	 *
	 * To enable slot synchronization on PG18, set in postgresql.conf:
	 *   sync_replication_slots = on
	 *   primary_conninfo = '...'
	 */
	elog(LOG, "spock: skipping failover slot worker on PostgreSQL 18+ "
		 "(use sync_replication_slots = on instead)");
#else

	memset(&bgw, 0, sizeof(bgw));
	bgw.bgw_flags =
		BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	bgw.bgw_start_time = BgWorkerStart_ConsistentState;
	snprintf(bgw.bgw_library_name, BGW_MAXLEN, "spock");
	snprintf(bgw.bgw_function_name, BGW_MAXLEN, "spock_failover_slots_main");
	snprintf(bgw.bgw_name, BGW_MAXLEN, "spock_failover_slots worker");
	bgw.bgw_restart_time = 60;

	RegisterBackgroundWorker(&bgw);

	/* Install Hooks */
	original_client_auth_hook = ClientAuthentication_hook;
	ClientAuthentication_hook = attach_to_walsender;
#endif							/* PG_VERSION_NUM < 180000 */
}
