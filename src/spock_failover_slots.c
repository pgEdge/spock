/*-------------------------------------------------------------------------
 *
 * spock_failover_slot.c
 *          Postgres Failover Slots
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
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
#include "access/xlogrecovery.h"
#include "catalog/indexing.h"
#include "catalog/pg_database.h"

#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"

#include "replication/decode.h"
#include "replication/logical.h"
#include "replication/slot.h"
#include "replication/walreceiver.h"
#include "replication/walsender.h"

#include "storage/ipc.h"
#include "storage/procarray.h"

#include "tcop/tcopprot.h"

#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/fmgrprotos.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/varlena.h"

#include "libpq-fe.h"
#include "libpq/auth.h"
#include "libpq/libpq.h"

#define WORKER_NAP_TIME 60000L
#define WORKER_WAIT_FEEDBACK 10000L

typedef struct RemoteSlot
{
	char	   *name;
	char	   *plugin;
	char	   *database;
	bool		two_phase;
	XLogRecPtr	restart_lsn;
	XLogRecPtr	confirmed_lsn;
	TransactionId catalog_xmin;
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
static XLogRecPtr standby_slot_names_oldest_flush_lsn = InvalidXLogRecPtr;

/* Slots to sync */
static char *spock_failover_slots_dsn;
static char *spock_failover_slot_names;
static char *spock_failover_slot_names_str = NULL;
static List *spock_failover_slot_names_list = NIL;
static bool spock_failover_slots_drop = true;

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

	/*
	 * We must invalidate our idea of the oldest lsn in all the named slots if
	 * we might have changed the list.
	 */
	standby_slot_names_oldest_flush_lsn = InvalidXLogRecPtr;

	old_ctx = MemoryContextSwitchTo(TopMemoryContext);
	standby_slot_names_string = pstrdup(newval);
	(void) SplitIdentifierString(standby_slot_names_string, ',',
								 &pg_standby_slot_names);
	(void) MemoryContextSwitchTo(old_ctx);
}

/*
 * Get failover slots from upstream
 */
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
				appendStringInfo(
								 &query, " %s slot_name OPERATOR(pg_catalog.=) %s", op,
								 PQescapeLiteral(conn, filter->val, strlen(filter->val)));
				break;
			case FAILOVERSLOT_FILTER_NAME_LIKE:
				appendStringInfo(
								 &query, " %s slot_name LIKE %s", op,
								 PQescapeLiteral(conn, filter->val, strlen(filter->val)));
				break;
			case FAILOVERSLOT_FILTER_PLUGIN:
				appendStringInfo(
								 &query, " %s plugin OPERATOR(pg_catalog.=) %s", op,
								 PQescapeLiteral(conn, filter->val, strlen(filter->val)));
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
	appendStringInfo(&query,
					 "SELECT restart_lsn"
					 "  FROM pg_catalog.pg_replication_slots"
					 " WHERE slot_name OPERATOR(pg_catalog.=) %s",
					 PQescapeLiteral(conn, slot_name, strlen(slot_name)));
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
 */
static void
make_sync_failover_slots_dsn(StringInfo connstr, char *db_name)
{
	if (spock_failover_slots_dsn && strlen(spock_failover_slots_dsn) > 0)
	{
		if (db_name)
			appendStringInfo(connstr, "%s dbname=%s", spock_failover_slots_dsn,
							 db_name);
		else
			appendStringInfoString(connstr, spock_failover_slots_dsn);
	}
	else
	{
		Assert(WalRcv);
		appendStringInfo(connstr, "%s dbname=%s", WalRcv->conninfo,
						 db_name ? db_name : "postgres");
	}
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
 * Wait for remote slot to pass locally reserved position.
 *
 * Wait until the slot named in 'remote_slot' on the host at 'conn' has all its
 * requirements satisfied by the local slot 'slot' by polling 'conn'. This
 * relies on us having already reserved the WAL for the old position of
 * `remote_slot` so `slot` can't continue to advance.
 */
static bool
wait_for_primary_slot_catchup(ReplicationSlot *slot, RemoteSlot *remote_slot)
{
	List	   *slots;
	PGconn	   *conn;
	StringInfoData connstr;
	TimestampTz cb_wait_start =
		0;						/* first invocation should happen immediately */

	elog(
		 LOG,
		 "waiting for remote slot %s lsn (%X/%X) and catalog xmin (%u) to pass local slot lsn (%X/%X) and catalog xmin (%u)",
		 remote_slot->name, (uint32) (remote_slot->restart_lsn >> 32),
		 (uint32) (remote_slot->restart_lsn), remote_slot->catalog_xmin,
		 (uint32) (slot->data.restart_lsn >> 32),
		 (uint32) (slot->data.restart_lsn), slot->data.catalog_xmin);

	initStringInfo(&connstr);

	/*
	 * Append the dbname of the remote slot. We don't use a generic db like
	 * postgres here because plugin callback bellow might want to invoke
	 * extension functions.
	 */
	make_sync_failover_slots_dsn(&connstr, remote_slot->database);

	conn = remote_connect(connstr.data, "spock_failover_slots");
	pfree(connstr.data);

	for (;;)
	{
		RemoteSlot *new_slot;
		int			rc;
		FailoverSlotFilter *filter = palloc(sizeof(FailoverSlotFilter));
		XLogRecPtr	receivePtr;

		CHECK_FOR_INTERRUPTS();

		if (!RecoveryInProgress())
		{
			/*
			 * The remote slot didn't pass the locally reserved position at
			 * the time of local promotion, so it's not safe to use.
			 */
			ereport(
					WARNING,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg(
							"replication slot sync wait for slot %s interrupted by promotion",
							remote_slot->name)));
			PQfinish(conn);
			return false;
		}

		filter->key = FAILOVERSLOT_FILTER_NAME;
		filter->val = remote_slot->name;
		slots = remote_get_primary_slot_info(conn, list_make1(filter));

		if (!list_length(slots))
		{
			/* Slot on provider vanished */
			PQfinish(conn);
			return false;
		}

		receivePtr = GetWalRcvFlushRecPtr(NULL, NULL);

		Assert(list_length(slots) == 1);

		new_slot = linitial(slots);
		if (new_slot->restart_lsn > receivePtr)
			new_slot->restart_lsn = receivePtr;
		if (new_slot->confirmed_lsn > receivePtr)
			new_slot->confirmed_lsn = receivePtr;

		if (new_slot->restart_lsn >= slot->data.restart_lsn &&
			TransactionIdFollowsOrEquals(new_slot->catalog_xmin,
										 MyReplicationSlot->data.catalog_xmin))
		{
			remote_slot->restart_lsn = new_slot->restart_lsn;
			remote_slot->confirmed_lsn = new_slot->confirmed_lsn;
			remote_slot->catalog_xmin = new_slot->catalog_xmin;
			PQfinish(conn);
			return true;
		}

		/*
		 * Invoke any callbacks that will help move the slots along
		 */
		if (TimestampDifferenceExceeds(
									   cb_wait_start, GetCurrentTimestamp(),
									   Min(wal_retrieve_retry_interval * 5, PG_WAIT_EXTENSION)))
		{
			if (cb_wait_start > 0)
				elog(
					 LOG,
					 "still waiting for remote slot %s lsn (%X/%X) and catalog xmin (%u) to pass local slot lsn (%X/%X) and catalog xmin (%u)",
					 remote_slot->name, (uint32) (new_slot->restart_lsn >> 32),
					 (uint32) (new_slot->restart_lsn), new_slot->catalog_xmin,
					 (uint32) (slot->data.restart_lsn >> 32),
					 (uint32) (slot->data.restart_lsn),
					 slot->data.catalog_xmin);

			cb_wait_start = GetCurrentTimestamp();
		}

		rc =
			WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					  wal_retrieve_retry_interval, PG_WAIT_EXTENSION);

		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);


		ResetLatch(MyLatch);
	}
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
			break;
		}
	}
	LWLockRelease(ReplicationSlotControlLock);

	/*
	 * Remote slot exists locally, acquire and move. There's a race here where
	 * the slot could've been dropped since we checked, but we'll just ERROR
	 * out in `ReplicationSlotAcquire` and retry next loop so it's harmless.
	 *
	 * Moving the slot this way does not do logical decoding. We're not
	 * processing WAL, we're just updating the slot metadata.
	 */
	if (found)
	{
#if PG_VERSION_NUM >= 180000
		ReplicationSlotAcquire(remote_slot->name, true, true);
#else
		ReplicationSlotAcquire(remote_slot->name, true);
#endif

		/*
		 * We can't satisfy this remote slot's requirements with our
		 * known-safe local restart_lsn, catalog_xmin and xmin.
		 *
		 * This shouldn't happen for existing slots unless someone else messed
		 * with our physical replication slot on the master.
		 */
		if (remote_slot->restart_lsn < MyReplicationSlot->data.restart_lsn ||
			TransactionIdPrecedes(remote_slot->catalog_xmin,
								  MyReplicationSlot->data.catalog_xmin))
		{
			elog(
				 WARNING,
				 "not synchronizing slot %s; synchronization would move it backward",
				 remote_slot->name);

			ReplicationSlotRelease();
			PopActiveSnapshot();
			CommitTransactionCommand();
			return;
		}

		LogicalConfirmReceivedLocation(remote_slot->confirmed_lsn);
		LogicalIncreaseXminForSlot(remote_slot->confirmed_lsn,
								   remote_slot->catalog_xmin);
		LogicalIncreaseRestartDecodingForSlot(remote_slot->confirmed_lsn,
											  remote_slot->restart_lsn);
		ReplicationSlotMarkDirty();
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
		 */
#if PG_VERSION_NUM >= 170000
		ReplicationSlotCreate(remote_slot->name, true, RS_EPHEMERAL,
							  remote_slot->two_phase,
							  false,
							  false);
#else
		ReplicationSlotCreate(remote_slot->name, true, RS_EPHEMERAL,
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

		LWLockAcquire(ProcArrayLock, LW_EXCLUSIVE);
		xmin_horizon = GetOldestSafeDecodingTransactionId(true);
		slot->effective_catalog_xmin = xmin_horizon;
		slot->data.catalog_xmin = xmin_horizon;
		ReplicationSlotsComputeRequiredXmin(true);
		LWLockRelease(ProcArrayLock);

		/*
		 * Our xmin and/or catalog_xmin may be > that required by one or more
		 * of the slots we are trying to sync from the master, and/or we don't
		 * have enough retained WAL for the slot's restart_lsn.
		 *
		 * If we persist the slot locally in that state it'll make a false
		 * promise we can't satisfy.
		 *
		 * This can happen if this replica is fairly new or has only recently
		 * started failover slot sync.
		 *
		 * TODO: Don't stop synchronization of other slots for this, we can't
		 * add timeout because that could result in some slots never being
		 * synchronized as they will always be behind the physical slot.
		 */
		if (remote_slot->restart_lsn < MyReplicationSlot->data.restart_lsn ||
			TransactionIdPrecedes(remote_slot->catalog_xmin,
								  MyReplicationSlot->data.catalog_xmin))
		{
			if (!wait_for_primary_slot_catchup(MyReplicationSlot, remote_slot))
			{
				/*
				 * Provider slot didn't catch up to locally reserved position
				 */
				ReplicationSlotRelease();
				PopActiveSnapshot();
				CommitTransactionCommand();
				return;
			}
		}

		/*
		 * We can locally satisfy requirements of remote slot's current
		 * position now. Apply the new position if any and make it persistent.
		 */
		LogicalConfirmReceivedLocation(remote_slot->confirmed_lsn);
		LogicalIncreaseXminForSlot(remote_slot->confirmed_lsn,
								   remote_slot->catalog_xmin);
		LogicalIncreaseRestartDecodingForSlot(remote_slot->confirmed_lsn,
											  remote_slot->restart_lsn);
		ReplicationSlotMarkDirty();

		ReplicationSlotPersist();

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
		return sleep_time;

	/* XXX should these be errors or just soft return like above? */
	if (!hot_standby_feedback)
		elog(
			 ERROR,
			 "cannot synchronize replication slot positions because hot_standby_feedback is off");
	if (WalRcv->slotname[0] == '\0')
		elog(
			 ERROR,
			 "cannot synchronize replication slot positions because primary_slot_name is not set");

	elog(DEBUG1, "starting replication slot synchronization from primary");

	initStringInfo(&connstr);
	make_sync_failover_slots_dsn(&connstr, NULL /* Use default db name */ );
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
			bool		found = false;

			active = (s->active_pid != 0);

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
			 * is enabled.
			 */
			if (!found && spock_failover_slots_drop)
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

	if (safe_lsn == InvalidXLogRecPtr ||
		WalRcv->latestWalEnd == InvalidXLogRecPtr)
	{
		ereport(
				WARNING,
				(errmsg(
						"cannot synchronize replication slot positions yet because feedback was not sent yet")));
		was_lsn_safe = false;
		PQfinish(conn);
		return Min(sleep_time, WORKER_WAIT_FEEDBACK);
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
		return Min(sleep_time, WORKER_WAIT_FEEDBACK);
	}

	foreach(lc, slots)
	{
		RemoteSlot *remote_slot = lfirst(lc);
		XLogRecPtr	receivePtr;

		/*
		 * If we haven't received WAL for a remote slot's current
		 * confirmed_flush_lsn our local copy shouldn't reflect a confirmed
		 * position in the future. Cap it at the position we really received.
		 *
		 * Because the client will use a replication origin to track its
		 * position, in most cases it'll still fast-forward to the new
		 * confirmed position even if that skips over a gap of WAL we never
		 * received from the provider before failover. We can't detect or
		 * prevent that as the same fast forward is normal when we lost slot
		 * state in a provider crash after subscriber committed but before we
		 * saved the new confirmed flush lsn. The master will also fast
		 * forward the slot over irrelevant changes and then the subscriber
		 * will update its confirmed_flush_lsn in response to master standby
		 * status updates.
		 */
		receivePtr = GetWalRcvFlushRecPtr(NULL, NULL);
		if (remote_slot->confirmed_lsn > receivePtr)
			remote_slot->confirmed_lsn = receivePtr;

		/*
		 * For simplicity we always move restart_lsn of all slots to the
		 * restart_lsn needed by the furthest-behind master slot.
		 */
		if (remote_slot->restart_lsn > lsn)
			remote_slot->restart_lsn = lsn;

		synchronize_one_slot(remote_slot);
	}

	PQfinish(conn);

	if (!was_lsn_safe && is_lsn_safe)
		elog(LOG, "slot synchronization from primary now active");

	was_lsn_safe = is_lsn_safe;

	return sleep_time;
}

void
spock_failover_slots_main(Datum main_arg)
{
	/* Establish signal handlers. */
	pqsignal(SIGUSR1, procsignal_sigusr1_handler);
	pqsignal(SIGTERM, die);
	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	BackgroundWorkerUnblockSignals();

	/* Make it easy to identify our processes. */
	SetConfigOption("application_name", MyBgworkerEntry->bgw_name,
					PGC_SU_BACKEND, PGC_S_OVERRIDE);

	elog(LOG, "starting spock_failover_slots replica worker");

	/* Setup connection to pinned catalogs (we only ever read pg_database). */
	BackgroundWorkerInitializeConnection(NULL, NULL, 0);

	/* Main wait loop. */
	while (true)
	{
		int			rc;
		long		sleep_time = WORKER_NAP_TIME;

		CHECK_FOR_INTERRUPTS();

		if (RecoveryInProgress())
			sleep_time = synchronize_failover_slots(WORKER_NAP_TIME);
		else
			sleep_time = WORKER_NAP_TIME * 10;

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
}

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

void
spock_init_failover_slot(void)
{
	BackgroundWorker bgw;

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


	if (IsBinaryUpgrade)
		return;

	/* Run the worker. */
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
}
