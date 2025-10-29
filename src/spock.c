/*-------------------------------------------------------------------------
 *
 * spock.c
 * 		spock initialization and common functionality
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"

#include "access/hash.h"
#include "access/htup_details.h"
#include "access/xact.h"
#include "access/xlog.h"

#include "catalog/pg_extension.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/pg_database.h"
#include "catalog/pg_type.h"

#include "commands/extension.h"

#include "executor/executor.h"

#include "mb/pg_wchar.h"

#include "nodes/nodeFuncs.h"

#include "optimizer/planner.h"

#include "parser/parse_coerce.h"

#include "replication/origin.h"
#include "replication/reorderbuffer.h"

#include "storage/ipc.h"
#include "storage/proc.h"
#include "tcop/tcopprot.h" /* debug_query_string */

#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#include "pgstat.h"

#include "spock_apply.h"
#include "spock_executor.h"
#include "spock_node.h"
#include "spock_conflict.h"
#include "spock_rmgr.h"
#include "spock_worker.h"
#include "spock_output_config.h"
#include "spock_output_plugin.h"
#include "spock_exception_handler.h"
#include "spock_readonly.h"
#include "spock.h"

PG_MODULE_MAGIC;

static const struct config_enum_entry SpockConflictResolvers[] = {
	/*
	 * Disabled until we can clearly define their desired behavior.
	 * Jan Wieck 2024-08-12
	 *
	{"error", SPOCK_RESOLVE_ERROR, false},
	{"apply_remote", SPOCK_RESOLVE_APPLY_REMOTE, false},
	{"keep_local", SPOCK_RESOLVE_KEEP_LOCAL, false},
	{"first_update_wins", SPOCK_RESOLVE_FIRST_UPDATE_WINS, false},
	*/
	{"last_update_wins", SPOCK_RESOLVE_LAST_UPDATE_WINS, false},
	{NULL, 0, false}
};

/* copied fom guc.c */
static const struct config_enum_entry server_message_level_options[] = {
	{"debug", DEBUG2, true},
	{"debug5", DEBUG5, false},
	{"debug4", DEBUG4, false},
	{"debug3", DEBUG3, false},
	{"debug2", DEBUG2, false},
	{"debug1", DEBUG1, false},
	{"info", INFO, false},
	{"notice", NOTICE, false},
	{"warning", WARNING, false},
	{"error", ERROR, false},
	{"log", LOG, false},
	{"fatal", FATAL, false},
	{"panic", PANIC, false},
	{NULL, 0, false}
};

static const struct config_enum_entry exception_behaviour_options[] = {
	{"discard", DISCARD, false},
	{"transdiscard", TRANSDISCARD, false},
	{"sub_disable", SUB_DISABLE, false},
	{NULL, 0, false}
};

static const struct config_enum_entry exception_logging_options[] = {
	{"none", LOG_NONE, false},
	{"discard", LOG_DISCARD, false},
	{"all", LOG_ALL, false},
	{NULL, 0, false}
};

static const struct config_enum_entry readonly_options[] = {
	{"off", READONLY_OFF, false},
	{"user", READONLY_USER, false},
	{"all", READONLY_ALL, false},
	{NULL, 0, false}
};

bool	spock_synchronous_commit = false;
char   *spock_temp_directory = "";
bool	spock_use_spi = false;
bool	spock_batch_inserts = true;
static char *spock_temp_directory_config;
bool	spock_ch_stats = true;
static char *spock_country_code;
bool	spock_deny_ddl = false;
bool	spock_enable_ddl_replication = false;
bool	spock_include_ddl_repset = false;
bool	allow_ddl_from_functions = false;
int		restart_delay_default;
int		restart_delay_on_exception;
int		spock_replay_queue_size;  /* Deprecated - no longer used */
bool	check_all_uc_indexes = false;

static emit_log_hook_type prev_emit_log_hook = NULL;
static Checkpoint_hook_type prev_Checkpoint_hook = NULL;

void _PG_init(void);
PGDLLEXPORT void spock_supervisor_main(Datum main_arg);
char *spock_extra_connection_options;

static PGconn * spock_connect_base(const char *connstr,
									   const char *appname,
									   const char *suffix,
									   bool replication);

/*
 * Ensure string is not longer than maxlen.
 *
 * The way we do this is we if the string is longer we return prefix from that
 * string and hash of the string which will together be exatly maxlen.
 *
 * Maxlen can't be less than 8 because hash produces uint32 which in hex form
 * can have up to 8 characters.
 */
char *
shorten_hash(const char *str, int maxlen)
{
	char   *ret;
	int		len = strlen(str);

	Assert(maxlen >= 8);

	if (len <= maxlen)
		return pstrdup(str);

	ret = (char *) palloc(maxlen + 1);
	snprintf(ret, maxlen, "%.*s%08x", maxlen - 8,
			 str, DatumGetUInt32(hash_any((unsigned char *) str, len)));
	ret[maxlen] = '\0';

	return ret;
}

/*
 * Convert text array to list of strings.
 *
 * Note: the resulting list points to the memory of the input array.
 */
List *
textarray_to_list(ArrayType *textarray)
{
	Datum		   *elems;
	int				nelems, i;
	List		   *res = NIL;

	deconstruct_array(textarray,
					  TEXTOID, -1, false, 'i',
					  &elems, NULL, &nelems);

	if (nelems == 0)
		return NIL;

	for (i = 0; i < nelems; i++)
		res = lappend(res, TextDatumGetCString(elems[i]));

	return res;
}

/*
 * Deconstruct the text representation of a 1-dimensional Postgres array
 * into individual items.
 *
 * On success, returns true and sets *itemarray and *nitems to describe
 * an array of individual strings.  On parse failure, returns false;
 * *itemarray may exist or be NULL.
 *
 * NOTE: free'ing itemarray is sufficient to deallocate the working storage.
 */
bool
parsePGArray(const char *atext, char ***itemarray, int *nitems)
{
	int			inputlen;
	char	  **items;
	char	   *strings;
	int			curitem;

	/*
	 * We expect input in the form of "{item,item,item}" where any item is
	 * either raw data, or surrounded by double quotes (in which case embedded
	 * characters including backslashes and quotes are backslashed).
	 *
	 * We build the result as an array of pointers followed by the actual
	 * string data, all in one malloc block for convenience of deallocation.
	 * The worst-case storage need is not more than one pointer and one
	 * character for each input character (consider "{,,,,,,,,,,}").
	 */
	*itemarray = NULL;
	*nitems = 0;
	inputlen = strlen(atext);
	if (inputlen < 2 || atext[0] != '{' || atext[inputlen - 1] != '}')
		return false;			/* bad input */
	items = (char **) malloc(inputlen * (sizeof(char *) + sizeof(char)));
	if (items == NULL)
		return false;			/* out of memory */
	*itemarray = items;
	strings = (char *) (items + inputlen);

	atext++;					/* advance over initial '{' */
	curitem = 0;
	while (*atext != '}')
	{
		if (*atext == '\0')
			return false;		/* premature end of string */
		items[curitem] = strings;
		while (*atext != '}' && *atext != ',')
		{
			if (*atext == '\0')
				return false;	/* premature end of string */
			if (*atext != '"')
				*strings++ = *atext++;	/* copy unquoted data */
			else
			{
				/* process quoted substring */
				atext++;
				while (*atext != '"')
				{
					if (*atext == '\0')
						return false;	/* premature end of string */
					if (*atext == '\\')
					{
						atext++;
						if (*atext == '\0')
							return false;		/* premature end of string */
					}
					*strings++ = *atext++;		/* copy quoted data */
				}
				atext++;
			}
		}
		*strings++ = '\0';
		if (*atext == ',')
			atext++;
		curitem++;
	}
	if (atext[1] != '\0')
		return false;			/* bogus syntax (embedded '}') */
	*nitems = curitem;
	return true;
}

/*
 * Get oid of our queue table.
 */
inline Oid
get_spock_table_oid(const char *table)
{
	Oid			nspoid;
	Oid			reloid;

	nspoid = get_namespace_oid(EXTENSION_NAME, false);

	reloid = get_relname_relid(table, nspoid);

	if (reloid == InvalidOid)
		elog(ERROR, "cache lookup failed for relation %s.%s",
			 EXTENSION_NAME, table);

	return reloid;
}

#define CONN_PARAM_ARRAY_SIZE 9

static PGconn *
spock_connect_base(const char *connstr, const char *appname,
					   const char *suffix, bool replication)
{
	int				i=0;
	PGconn		   *conn;
	const char	   *keys[CONN_PARAM_ARRAY_SIZE];
	const char	   *vals[CONN_PARAM_ARRAY_SIZE];
	StringInfoData s;

	initStringInfo(&s);
	appendStringInfoString(&s, spock_extra_connection_options);
	appendStringInfoChar(&s, ' ');
	appendStringInfoString(&s, connstr);

	keys[i] = "dbname";
	vals[i] = connstr;
	i++;
	keys[i] = "application_name";
	if (suffix)
	{
		char	s[NAMEDATALEN];
		snprintf(s, NAMEDATALEN,
			 "%s_%s",
			 shorten_hash(appname, NAMEDATALEN - strlen(suffix) - 2),
			 suffix);
		vals[i] = s;
	}
	else
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
	keys[i] = "replication";
	vals[i] = replication ? "database" : NULL;
	i++;
	keys[i] = NULL;
	vals[i] = NULL;

	Assert(i <= CONN_PARAM_ARRAY_SIZE);

	/*
	 * We use the expand_dbname parameter to process the connection string
	 * (or URI), and pass some extra options.
	 */
	conn = PQconnectdbParams(keys, vals, /* expand_dbname = */ true);
	if (PQstatus(conn) != CONNECTION_OK)
	{
		ereport(ERROR,
				(errmsg("could not connect to the postgresql server%s: %s",
						replication ? " in replication mode" : "",
						PQerrorMessage(conn)),
				 errdetail("dsn was: %s", s.data)));
	}

	resetStringInfo(&s);

	return conn;
}


/*
 * Make standard postgres connection, ERROR on failure.
 */
PGconn *
spock_connect(const char *connstring, const char *connname,
				  const char *suffix)
{
	return spock_connect_base(connstring, connname, suffix, false);
}

/*
 * Make replication connection, ERROR on failure.
 */
PGconn *
spock_connect_replica(const char *connstring, const char *connname,
						  const char *suffix)
{
	return spock_connect_base(connstring, connname, suffix, true);
}

/*
 * Make sure the extension is up to date.
 *
 * Called by db manager.
 */
void
spock_manage_extension(void)
{
	Relation	extrel;
	SysScanDesc scandesc;
	HeapTuple	tuple;
	ScanKeyData key[1];

	if (RecoveryInProgress())
		return;

	PushActiveSnapshot(GetTransactionSnapshot());

	/* make sure we're operating without other spock workers interfering */
	extrel = table_open(ExtensionRelationId, ShareUpdateExclusiveLock);

	ScanKeyInit(&key[0],
				Anum_pg_extension_extname,
				BTEqualStrategyNumber, F_NAMEEQ,
				CStringGetDatum(EXTENSION_NAME));

	scandesc = systable_beginscan(extrel, ExtensionNameIndexId, true,
								  NULL, 1, key);

	tuple = systable_getnext(scandesc);

	/* No extension, nothing to update. */
	if (HeapTupleIsValid(tuple))
	{
		Datum		datum;
		bool		isnull;
		char	   *extversion;

		/* Determine extension version. */
		datum = heap_getattr(tuple, Anum_pg_extension_extversion,
							 RelationGetDescr(extrel), &isnull);
		if (isnull)
			elog(ERROR, "extversion is null");
		extversion = text_to_cstring(DatumGetTextPP(datum));

		/* Only run the alter if the versions don't match. */
		if (strcmp(extversion, SPOCK_VERSION) != 0)
		{
			AlterExtensionStmt alter_stmt;

			alter_stmt.options = NIL;
			alter_stmt.extname = EXTENSION_NAME;
			ExecAlterExtensionStmt(&alter_stmt);
		}
	}

	systable_endscan(scandesc);
	table_close(extrel, NoLock);

	PopActiveSnapshot();
}

/*
 * Call IDENTIFY_SYSTEM on the connection and report its results.
 */
void
spock_identify_system(PGconn *streamConn, uint64* sysid,
							TimeLineID *timeline, XLogRecPtr *xlogpos,
							Name *dbname)
{
	PGresult	   *res;

	res = PQexec(streamConn, "IDENTIFY_SYSTEM");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		elog(ERROR, "could not send replication command \"%s\": %s",
			 "IDENTIFY_SYSTEM", PQerrorMessage(streamConn));
	}
	if (PQntuples(res) != 1 || PQnfields(res) < 4)
	{
		elog(ERROR, "could not identify system: got %d rows and %d fields, expected %d rows and at least %d fields\n",
			 PQntuples(res), PQnfields(res), 1, 4);
	}

	if (PQnfields(res) > 4)
	{
		elog(DEBUG2, "ignoring extra fields in IDENTIFY_SYSTEM response; expected 4, got %d",
			 PQnfields(res));
	}

	if (sysid != NULL)
	{
		const char *remote_sysid = PQgetvalue(res, 0, 0);
		if (sscanf(remote_sysid, UINT64_FORMAT, sysid) != 1)
			elog(ERROR, "could not parse remote sysid %s", remote_sysid);
	}

	if (timeline != NULL)
	{
		const char *remote_tlid = PQgetvalue(res, 0, 1);
		if (sscanf(remote_tlid, "%u", timeline) != 1)
			elog(ERROR, "could not parse remote tlid %s", remote_tlid);
	}

	if (xlogpos != NULL)
	{
		const char *remote_xlogpos = PQgetvalue(res, 0, 2);
		uint32 xlogpos_low, xlogpos_high;
		if (sscanf(remote_xlogpos, "%X/%X", &xlogpos_high, &xlogpos_low) != 2)
			elog(ERROR, "could not parse remote xlogpos %s", remote_xlogpos);
		*xlogpos = (((XLogRecPtr)xlogpos_high)<<32) + xlogpos_low;
	}

	if (dbname != NULL)
	{
		char *remote_dbname = PQgetvalue(res, 0, 3);
		snprintf(NameStr(**dbname), NAMEDATALEN, "%s", remote_dbname);
	}

	PQclear(res);
}

void
spock_start_replication(PGconn *streamConn, const char *slot_name,
							XLogRecPtr start_pos, const char *forward_origins,
							const char *replication_sets,
							const char *replicate_only_table,
							bool force_text_transfer)
{
	StringInfoData	command;
	PGresult	   *res;
	char		   *sqlstate;
	const char	   *want_binary = (force_text_transfer ? "0" : "1");

	initStringInfo(&command);
	appendStringInfo(&command, "START_REPLICATION SLOT \"%s\" LOGICAL %X/%X (",
					 slot_name,
					 (uint32) (start_pos >> 32),
					 (uint32) start_pos);

	/* Basic protocol info. */
	appendStringInfo(&command, "expected_encoding '%s'",
					 GetDatabaseEncodingName());
	appendStringInfo(&command, ", min_proto_version '%d'", SPOCK_PROTO_MIN_VERSION_NUM);
	appendStringInfo(&command, ", max_proto_version '%d'", SPOCK_PROTO_VERSION_NUM);
	appendStringInfo(&command, ", startup_params_format '1'");

	/* Binary protocol compatibility. */
	appendStringInfo(&command, ", \"binary.want_internal_basetypes\" '%s'", want_binary);
	appendStringInfo(&command, ", \"binary.want_binary_basetypes\" '%s'", want_binary);
	appendStringInfo(&command, ", \"binary.basetypes_major_version\" '%u'",
					 PG_VERSION_NUM/100);
	appendStringInfo(&command, ", \"binary.sizeof_datum\" '%zu'",
					 sizeof(Datum));
	appendStringInfo(&command, ", \"binary.sizeof_int\" '%zu'", sizeof(int));
	appendStringInfo(&command, ", \"binary.sizeof_long\" '%zu'", sizeof(long));
	appendStringInfo(&command, ", \"binary.bigendian\" '%d'",
#ifdef WORDS_BIGENDIAN
					 true
#else
					 false
#endif
					 );
	appendStringInfo(&command, ", \"binary.float4_byval\" '%d'",
					 server_float4_byval());
	appendStringInfo(&command, ", \"binary.float8_byval\" '%d'",
					 server_float8_byval());
	appendStringInfo(&command, ", \"binary.integer_datetimes\" '%d'",
#ifdef USE_INTEGER_DATETIMES
					 true
#else
					 false
#endif
					 );

	/* We don't care about this anymore but spock 1.x expects this. */
	appendStringInfoString(&command,
						   ", \"hooks.setup_function\" 'spock.spock_hooks_setup'");

	if (forward_origins)
		appendStringInfo(&command, ", \"spock.forward_origins\" %s",
					 quote_literal_cstr(forward_origins));

	if (replicate_only_table)
	{
		/* Send the table name we want to the upstream */
		appendStringInfoString(&command, ", \"spock.replicate_only_table\" ");
		appendStringInfoString(&command, quote_literal_cstr(replicate_only_table));
	}

	if (replication_sets)
	{
		/* Send the replication set names we want to the upstream */
		appendStringInfoString(&command, ", \"spock.replication_set_names\" ");
		appendStringInfoString(&command, quote_literal_cstr(replication_sets));
	}

	/* general info about the downstream */
	appendStringInfo(&command, ", pg_version '%u'", PG_VERSION_NUM);
	appendStringInfo(&command, ", spock_version '%s'", SPOCK_VERSION);
	appendStringInfo(&command, ", spock_version_num '%d'", SPOCK_VERSION_NUM);

	appendStringInfoChar(&command, ')');

	res = PQexec(streamConn, command.data);
	sqlstate = PQresultErrorField(res, PG_DIAG_SQLSTATE);
	if (PQresultStatus(res) != PGRES_COPY_BOTH)
		elog(FATAL, "could not send replication command \"%s\": %s\n, sqlstate: %s",
			 command.data, PQresultErrorMessage(res), sqlstate);
	PQclear(res);

	elog(LOG, "SPOCK %s: connected", MySubscription->name);
}

/*
 * Start the manager workers for every db which has a spock node.
 *
 * Note that we start workers that are not necessary here. We do this because
 * we need to check every individual database to check if there is spock
 * node setup and it's not possible to switch connections to different
 * databases within one background worker. The workers that won't find any
 * spock node setup will exit immediately during startup.
 * This behavior can cause issue where we consume all the allowed workers and
 * eventually error out even though the max_worker_processes is set high enough
 * to satisfy the actual needed worker count.
 *
 * Must be run inside a transaction.
 */
static void
start_manager_workers(void)
{
	Relation	rel;
	TableScanDesc scan;
	HeapTuple	tup;

	/* Run manager worker for every connectable database. */
	rel = table_open(DatabaseRelationId, AccessShareLock);
	scan = table_beginscan_catalog(rel, 0, NULL);

	while (HeapTupleIsValid(tup = heap_getnext(scan, ForwardScanDirection)))
	{
		Form_pg_database	pgdatabase = (Form_pg_database) GETSTRUCT(tup);
		Oid					dboid = pgdatabase->oid;
		SpockWorker		worker;

		CHECK_FOR_INTERRUPTS();

		/* Can't run workers on databases which don't allow connection. */
		if (!pgdatabase->datallowconn)
			continue;

		/* Worker already attached, nothing to do. */
		LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
		if (spock_worker_running(spock_manager_find(dboid)))
		{
			LWLockRelease(SpockCtx->lock);
			continue;
		}
		LWLockRelease(SpockCtx->lock);

		/* No record found, try running new worker. */
		elog(DEBUG1, "registering spock manager process for database %s",
			 NameStr(pgdatabase->datname));

		memset(&worker, 0, sizeof(SpockWorker));
		worker.worker_type = SPOCK_WORKER_MANAGER;
		worker.dboid = dboid;

		spock_worker_register(&worker);
	}

	table_endscan(scan);
	table_close(rel, AccessShareLock);
}

/*
 * Static bgworker used for initialization and management (our main process).
 */
void
spock_supervisor_main(Datum main_arg)
{
	/* Establish signal handlers. */
	pqsignal(SIGTERM, handle_sigterm);
	BackgroundWorkerUnblockSignals();

	/*
	 * Initialize supervisor info in shared memory.  Strictly speaking we
	 * don't need a lock here, because no other process could possibly be
	 * looking at this shared struct since they're all started by the
	 * supervisor, but let's be safe.
	 */
	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
	SpockCtx->supervisor = MyProc;
	SpockCtx->subscriptions_changed = true;
	LWLockRelease(SpockCtx->lock);

	/* Make it easy to identify our processes. */
	SetConfigOption("application_name", MyBgworkerEntry->bgw_name,
					PGC_USERSET, PGC_S_OVERRIDE);

	elog(LOG, "starting spock supervisor");

	VALGRIND_PRINTF("SPOCK: supervisor\n");

	/* Setup connection to pinned catalogs (we only ever read pg_database). */
	BackgroundWorkerInitializeConnection(NULL, NULL, 0);

	/* Main wait loop. */
	while (!got_SIGTERM)
    {
		int rc;

		CHECK_FOR_INTERRUPTS();

		if (SpockCtx->subscriptions_changed)
		{
			/*
			 * No need to lock here, since we'll take account of all sub
			 * changes up to this point, even if new ones were added between
			 * the test above and flag clear. We're just being woken up.
			 */
			SpockCtx->subscriptions_changed = false;
			StartTransactionCommand();
			start_manager_workers();
			CommitTransactionCommand();
		}

		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   180000L);

        ResetLatch(&MyProc->procLatch);

        /* emergency bailout if postmaster has died */
        if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);
	}

	VALGRIND_PRINTF("SPOCK: supervisor exit\n");
	proc_exit(0);
}

static void
spock_temp_directory_assing_hook(const char *newval, void *extra)
{
	if (strlen(newval))
	{
		spock_temp_directory = strdup(newval);
	}
	else
	{
#ifndef WIN32
		const char *tmpdir = getenv("TMPDIR");

		if (!tmpdir)
			tmpdir = "/tmp";
#else
		char		tmpdir[MAXPGPATH];
		int			ret;

		ret = GetTempPath(MAXPGPATH, tmpdir);
		if (ret == 0 || ret > MAXPGPATH)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("could not locate temporary directory: %s\n",
							!ret ? strerror(errno) : "")));
			return false;
		}
#endif

		spock_temp_directory = strdup(tmpdir);

	}

	if (spock_temp_directory == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("out of memory")));
}

/*
 * Case insensitive substring search.
 * NOTE: No memory allocations is allowed here.
 */
static char *
pg_strcasestr(const char *str, const char *substr)
{
	size_t nlen;

	if (str == NULL)
		return NULL;

    nlen = strlen(substr);

    if (nlen == 0)
        return (char *) str;

    for (const char *p = str; *p; p++)
    {
        if (pg_strncasecmp(p, substr, nlen) == 0)
            return (char *) p;
    }
    return NULL;
}

/* Replace each following symbol with 'X' until the EOL */
static void
replace_symbols(char *strpos)
{
	if (strpos == NULL)
		return;

	while (*strpos != '\0')
	{
		*strpos = 'X';
		strpos++;
	}
}

#define PSWD_KEYWORD	"password"

/*
 * Spock-specific filters on log messages.
 *
 * Remember, this function may be called in the case of severe limitations and
 * shouldn't allocate memory.
 *
 * For now, Spock must always be loaded on startup, and it guarantees that this
 * filter will be applied everywhere.
 */
static void
log_message_filter(ErrorData *edata)
{
	if (prev_emit_log_hook)
		prev_emit_log_hook(edata);

	if (!edata->output_to_client && !edata->output_to_server)
		/* Previous hook already done this job. */
		return;

	if (edata->elevel == ERROR)
	{
		char	   *strpos;
		const int	len = strlen(PSWD_KEYWORD);

		/*
		 * Password may bubble up in the error message and query string.
		 * XXX: Can it be exposed somewhere else - in the detail_log string, for
		 * example?
		 */
		strpos = pg_strcasestr(edata->message, PSWD_KEYWORD);
		if (strpos != NULL)
		{
			strpos += len;
			replace_symbols(strpos);
		}
		strpos = pg_strcasestr(debug_query_string, PSWD_KEYWORD);
		if (strpos != NULL)
		{
			strpos += len;
			replace_symbols(strpos);
		}
	}

	/*
	 * Filter messages that previously needed core patch 'pg18-020-LOG-to-DEBUG1'
	 */
	if (edata->elevel == LOG &&
		edata->sqlerrcode == ERRCODE_T_R_SERIALIZATION_FAILURE)
	{
		bool lower_output_level = false;

		if (strstr(edata->message,
				   "tuple to be locked was already moved to another partition due to concurrent update, retrying") != NULL)
		{
			edata->elevel = DEBUG1;
			lower_output_level = true;
		}
		else if (strstr(edata->message, "concurrent delete, retrying") != NULL)
		{
			edata->elevel = DEBUG1;
			lower_output_level = true;
		}

		if (lower_output_level)
		{
			/* Reconsider decision on exposing the message */
			if (log_min_messages < edata->elevel)
				edata->output_to_server = false;
			if (client_min_messages < edata->elevel)
				edata->output_to_client = false;
		}
	}
}

/*
 * Entry point for this module.
 */
void
_PG_init(void)
{
	BackgroundWorker bgw;

	if (!process_shared_preload_libraries_in_progress)
		elog(ERROR, "spock is not in shared_preload_libraries");

    DefineCustomEnumVariable("spock.conflict_resolution",
							 gettext_noop("Sets method used for conflict resolution for resolvable conflicts."),
							 NULL,
							 &spock_conflict_resolver,
							 SPOCK_RESOLVE_LAST_UPDATE_WINS,
							 SpockConflictResolvers,
							 PGC_SUSET, 0,
							 spock_conflict_resolver_check_hook,
							 NULL, NULL);

	DefineCustomEnumVariable("spock.conflict_log_level",
							 gettext_noop("Sets log level used for logging resolved conflicts."),
							 NULL,
							 &spock_conflict_log_level,
							 LOG,
							 server_message_level_options,
							 PGC_SUSET, 0,
							 NULL, NULL, NULL);

	DefineCustomEnumVariable("spock.exception_behaviour",
							 gettext_noop("Sets the behaviour on exception."),
							 NULL,
							 &exception_behaviour,
							 TRANSDISCARD,
							 exception_behaviour_options,
							 PGC_SIGHUP, 0,
							 NULL, NULL, NULL);

	DefineCustomEnumVariable("spock.exception_logging",
							 gettext_noop("Sets what is logged on exception."),
							 NULL,
							 &exception_logging,
							 LOG_ALL,
							 exception_logging_options,
							 PGC_SIGHUP, 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("spock.stats_max_entries",
							"Maximum entries for statistics",
							"Maximum number of entries that can be "
							"entered into the channel stats.",
							&spock_stats_max_entries_conf,
							-1,
							-1,
							INT_MAX,
							PGC_POSTMASTER,
							0,
							NULL,
							NULL,
							NULL);

	DefineCustomBoolVariable("spock.save_resolutions",
							 "Log conflict resolutions to spock."CATALOG_LOGTABLE" table.",
							 NULL,
							 &spock_save_resolutions,
							 false, PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("spock.synchronous_commit",
							 "spock specific synchronous commit value",
							 NULL,
							 &spock_synchronous_commit,
							 false, PGC_POSTMASTER,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("spock.use_spi",
							 "Use SPI instead of low-level API for applying changes",
							 NULL,
							 &spock_use_spi,
							 false,
							 PGC_POSTMASTER,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("spock.batch_inserts",
							 "Batch inserts if possible",
							 NULL,
							 &spock_batch_inserts,
							 true,
							 PGC_POSTMASTER,
							 0,
							 NULL, NULL, NULL);

	/* May be set only internally */
	DefineCustomBoolVariable("spock.replication_repair_mode",
							 "Switch to the repair mode",
							 NULL,
							 &spock_replication_repair_mode,
							 false, PGC_INTERNAL,
							 0,
							 NULL, NULL, NULL);

	/*
	 * We can't use the temp_tablespace safely for our dumps, because Pg's
	 * crash recovery is very careful to delete only particularly formatted
	 * files. Instead for now just allow user to specify dump storage.
	 */
	DefineCustomStringVariable("spock.temp_directory",
							   "Directory to store dumps for local restore",
							   NULL,
							   &spock_temp_directory_config,
							   "", PGC_SIGHUP,
							   0,
							   NULL,
							   spock_temp_directory_assing_hook,
							   NULL);

	DefineCustomStringVariable("spock.extra_connection_options",
							   "connection options to add to all peer node connections",
							   NULL,
							   &spock_extra_connection_options,
							   "",
							   PGC_SIGHUP,
							   0,
							   NULL, NULL, NULL);

	DefineCustomBoolVariable("spock.channel_counters",
							   "Enable spock statistics information collection",
							   NULL,
							   &spock_ch_stats,
							   true,
							   PGC_BACKEND,
							   0,
							   NULL, NULL, NULL);

	DefineCustomStringVariable("spock.country",
							   "Sets the country code",
							   NULL,
							   &spock_country_code,
							   "??", PGC_SIGHUP,
							   0,
							   NULL,
							   NULL,
							   NULL);

	DefineCustomBoolVariable("spock.deny_all_ddl",
							   "Deny All DDL statements",
							   NULL,
							   &spock_deny_ddl,
							   false,
							   PGC_SUSET,
							   0,
							   NULL, NULL, NULL);

	DefineCustomBoolVariable("spock.enable_ddl_replication",
							   "Replicate All DDL statements automatically",
							   NULL,
							   &spock_enable_ddl_replication,
							   false,
							   PGC_USERSET,
							   0,
							   NULL, NULL, NULL);

	DefineCustomBoolVariable("spock.include_ddl_repset",
							   "Add tables to the replication set while doing ddl replication",
							   NULL,
							   &spock_include_ddl_repset,
							   false,
							   PGC_USERSET,
							   0,
							   NULL, NULL, NULL);

	DefineCustomBoolVariable("spock.allow_ddl_from_functions",
							   "Allow replication of DDL statements from within functions",
							   NULL,
							   &allow_ddl_from_functions,
							   false,
							   PGC_USERSET,
							   0,
							   NULL, NULL, NULL);

	DefineCustomIntVariable("spock.restart_delay_default",
							"Default apply-worker restart delay in ms",
							NULL,
							&restart_delay_default,
							5000,
							SPOCK_RESTART_MIN_DELAY,
							INT_MAX,
							PGC_POSTMASTER,
							0,
							NULL,
							NULL,
							NULL);

	DefineCustomIntVariable("spock.restart_delay_on_exception",
							"apply-worker restart delay in ms on exception",
							NULL,
							&restart_delay_on_exception,
							0,
							0,
							INT_MAX,
							PGC_POSTMASTER,
							0,
							NULL,
							NULL,
							NULL);

	DefineCustomIntVariable("spock.exception_replay_queue_size",
							"DEPRECATED: apply-worker replay queue size (no longer used)",
							"This setting is deprecated and has no effect. "
							"The replay queue now dynamically allocates memory as needed.",
							&spock_replay_queue_size,
							4194304,
							0,
							INT_MAX,
							PGC_SIGHUP,
							0,
							NULL,
							NULL,
							NULL);

	DefineCustomEnumVariable("spock.readonly",
							 gettext_noop("Controls cluster read-only mode."),
							 NULL,
							 &spock_readonly,
							 READONLY_OFF,
							 readonly_options,
							 PGC_SUSET, 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("spock.check_all_uc_indexes",
							 gettext_noop("Check all valid unique indexes for conflict resolution on INSERT when primary or replica identity index fails."),
							 NULL,
							 &check_all_uc_indexes,
							 false,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	if (IsBinaryUpgrade)
		return;

	prev_Checkpoint_hook = Checkpoint_hook;
	Checkpoint_hook = spock_checkpoint_hook;

	/* Spock resource manager */
	spock_rmgr_init();

	/* Init workers. */
	spock_worker_shmem_init();

	/* Init output plugin shmem */
	spock_output_plugin_shmem_init();

	/* Init executor module */
	spock_executor_init();

	/* Run the supervisor. */
	memset(&bgw, 0, sizeof(bgw));
	bgw.bgw_flags =	BGWORKER_SHMEM_ACCESS |
		BGWORKER_BACKEND_DATABASE_CONNECTION;
	bgw.bgw_start_time = BgWorkerStart_RecoveryFinished;
	snprintf(bgw.bgw_library_name, BGW_MAXLEN, "%s",
			 EXTENSION_NAME);
	snprintf(bgw.bgw_function_name, BGW_MAXLEN,
			 "spock_supervisor_main");
	snprintf(bgw.bgw_name, BGW_MAXLEN,
			 "spock supervisor");
	bgw.bgw_restart_time = 5;

	RegisterBackgroundWorker(&bgw);

	spock_init_failover_slot();

	/* General-purpose message filter */
	prev_emit_log_hook = emit_log_hook;
	emit_log_hook = log_message_filter;
}
