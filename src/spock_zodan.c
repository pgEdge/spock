/*-------------------------------------------------------------------------
 *
 * spock_zodan.c
 *		Zero Downtime Add/Remove Node (ZODAN) orchestration.
 *
 * Implements spock.add_node() and spock.remove_node() entirely in C.  These
 * used to be PL/pgSQL procedures (samples/Z0DAN/zodan.sql, zodremove.sql) that
 * reached every other node in the cluster through the dblink extension.  The
 * orchestration is now driven from C: local work is done over SPI (calling the
 * same spock.* SQL functions), and all cross-node work is done over libpq via
 * spock_connect(), so the dblink dependency is gone.
 *
 * Both procedures are LANGUAGE c PROCEDUREs: they run non-atomically (invoked
 * via top-level CALL) and use SPI_commit() at the phase boundaries where the
 * original scripts relied on COMMIT so that apply/sync workers pick up newly
 * created or enabled subscriptions.
 *
 *		add_node must be run on the new node being added.
 *		remove_node must be run on the node being removed.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "libpq-fe.h"

#include "access/xact.h"

#include "executor/spi.h"

#include "funcapi.h"

#include "miscadmin.h"

#include "storage/latch.h"

#include "utils/resowner.h"

#include "pgstat.h"

#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"

#include "spock_node.h"

#include "spock.h"

PG_FUNCTION_INFO_V1(spock_add_node);
PG_FUNCTION_INFO_V1(spock_remove_node);

/* Replication sets used for every ZODAN-managed subscription. */
#define ZODAN_REPSETS "'{default,default_insert_only,ddl_sql}'"

/* Minimum Spock version required on every node participating in add_node. */
#define ZODAN_MIN_VERSION "5.0.9"

/*
 * A remote node and the DSN we reach it on.  Built by connecting to the source
 * node and reading spock.node JOIN spock.node_interface.
 */
typedef struct ZNode
{
	char	   *name;
	char	   *dsn;
	char	   *location;
	char	   *country;
	char	   *info;
} ZNode;

/*
 * Everything the add_node phases need, so we don't thread a dozen arguments
 * through each helper.  All strings live in the dedicated memory context
 * (see spock_add_node) so they survive the SPI_commit() calls between phases.
 */
typedef struct ZodanAddCtx
{
	char	   *src_node_name;
	char	   *src_dsn;
	char	   *new_node_name;
	char	   *new_node_dsn;
	bool		verb;
	char	   *new_node_location;
	char	   *new_node_country;
	char	   *new_node_info;		/* jsonb rendered as text */
	int			timeout_sec;

	/* Cluster snapshot fetched from the source node (all existing nodes). */
	ZNode	   *nodes;
	int			nnodes;

	MemoryContext mcxt;				/* survives SPI_commit() */
} ZodanAddCtx;

/*
 * Progress reporting.  All progress output is gated on verbose mode so a
 * normal run is quiet; only the final confirmation is emitted unconditionally
 * by the entry points.  zodan_verbose is set once per top-level call.
 */
static bool zodan_verbose = false;

#define ZNOTE(...) \
	do { if (zodan_verbose) ereport(NOTICE, (errmsg(__VA_ARGS__))); } while (0)
#define ZVERB(verb, ...) \
	do { if (zodan_verbose) ereport(NOTICE, (errmsg(__VA_ARGS__))); } while (0)

/* ------------------------------------------------------------------------
 * Small utilities
 * ------------------------------------------------------------------------ */

/*
 * Sleep for the given number of milliseconds, honoring query cancel and
 * postmaster death.  Used by the various catch-up/sync wait loops.
 */
static void
zodan_sleep_ms(long ms)
{
	int			rc;

	CHECK_FOR_INTERRUPTS();
	rc = WaitLatch(MyLatch,
				   WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
				   ms, PG_WAIT_EXTENSION);
	ResetLatch(MyLatch);
	if (rc & WL_LATCH_SET)
		CHECK_FOR_INTERRUPTS();
}

/*
 * Extract the database name from a libpq connection string.  Errors out if the
 * DSN does not name a database, matching the old extract_dbname_from_dsn().
 */
static char *
zodan_dbname_from_dsn(const char *dsn)
{
	char	   *parse_err = NULL;
	PQconninfoOption *opts;
	PQconninfoOption *o;
	char	   *dbname = NULL;

	opts = PQconninfoParse(dsn, &parse_err);
	if (opts == NULL)
	{
		char		buf[1024];

		snprintf(buf, sizeof(buf), "%s", parse_err ? parse_err : "unknown error");
		if (parse_err)
			PQfreemem(parse_err);
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("could not parse DSN \"%s\": %s", dsn, buf)));
	}

	for (o = opts; o->keyword != NULL; o++)
	{
		if (strcmp(o->keyword, "dbname") == 0 && o->val != NULL && o->val[0] != '\0')
		{
			dbname = pstrdup(o->val);
			break;
		}
	}
	PQconninfoFree(opts);

	if (dbname == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("database name must be included in the DSN string: %s",
						dsn)));
	return dbname;
}

/* Build the subscription name sub_<provider>_<subscriber>. */
static char *
zodan_gen_sub_name(const char *provider, const char *subscriber)
{
	return psprintf("sub_%s_%s", provider, subscriber);
}

/*
 * Build the replication slot name for a subscription, matching
 * spock.spock_gen_slot_name(dbname, provider_node, sub_name).
 */
static char *
zodan_gen_slot_name(const char *dsn, const char *provider_node,
					const char *sub_name)
{
	NameData	slot;
	char	   *dbname = zodan_dbname_from_dsn(dsn);

	gen_slot_name(&slot, dbname, provider_node, sub_name);
	pfree(dbname);
	return pstrdup(NameStr(slot));
}

/* Parse "5.0.10-devel" into {major, minor, patch}; ignores any suffix. */
static void
zodan_parse_version(const char *v, int *major, int *minor, int *patch)
{
	*major = *minor = *patch = 0;
	if (v == NULL)
		return;
	sscanf(v, "%d.%d.%d", major, minor, patch);
}

/* Return <0, 0, >0 comparing a.b.c to the numbers in the arguments. */
static int
zodan_version_cmp(int a1, int a2, int a3, int b1, int b2, int b3)
{
	if (a1 != b1)
		return a1 - b1;
	if (a2 != b2)
		return a2 - b2;
	return a3 - b3;
}

/* ------------------------------------------------------------------------
 * libpq (remote node) helpers -- these replace dblink()
 * ------------------------------------------------------------------------ */

/* Connect to a remote node, ERROR on failure. */
static PGconn *
zodan_connect(const char *dsn, const char *purpose)
{
	return spock_connect(dsn, "spock_zodan", purpose);
}

/*
 * Run a query on a remote node that is expected to return tuples.  Caller owns
 * the returned PGresult and must PQclear() it.  ERROR on failure.
 */
static PGresult *
zodan_remote_query(PGconn *conn, const char *sql)
{
	PGresult   *res = PQexec(conn, sql);

	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		char		msg[1024];

		snprintf(msg, sizeof(msg), "%s", PQerrorMessage(conn));
		PQclear(res);
		ereport(ERROR,
				(errmsg("remote query failed on node"),
				 errdetail("query: %s", sql),
				 errdetail("error: %s", msg)));
	}
	return res;
}

/*
 * Run a command on a remote node (COMMAND_OK or TUPLES_OK both accepted).
 * ERROR on failure.
 */
static void
zodan_remote_command(PGconn *conn, const char *sql)
{
	PGresult   *res = PQexec(conn, sql);
	ExecStatusType st = PQresultStatus(res);

	if (st != PGRES_COMMAND_OK && st != PGRES_TUPLES_OK)
	{
		char		msg[1024];

		snprintf(msg, sizeof(msg), "%s", PQerrorMessage(conn));
		PQclear(res);
		ereport(ERROR,
				(errmsg("remote command failed on node"),
				 errdetail("command: %s", sql),
				 errdetail("error: %s", msg)));
	}
	PQclear(res);
}

/*
 * Run a query on a remote node and return the first column of the first row as
 * a palloc'd string (NULL if no rows or a SQL NULL).
 */
static char *
zodan_remote_scalar(PGconn *conn, const char *sql)
{
	PGresult   *res = zodan_remote_query(conn, sql);
	char	   *ret = NULL;

	if (PQntuples(res) > 0 && !PQgetisnull(res, 0, 0))
		ret = pstrdup(PQgetvalue(res, 0, 0));
	PQclear(res);
	return ret;
}

/* ------------------------------------------------------------------------
 * SPI (local node) helpers
 * ------------------------------------------------------------------------ */

/* Execute a local command over SPI, ERROR on failure. */
static void
zodan_local_command(const char *sql)
{
	int			rc = SPI_execute(sql, false, 0);

	if (rc < 0)
		elog(ERROR, "SPI_execute failed for: %s", sql);
}

/*
 * Execute a local query over SPI and return the first column of the first row
 * as a palloc'd string in the caller's context (NULL if no rows / SQL NULL).
 *
 * read_only is false so every call takes a fresh snapshot; the wait/poll loops
 * depend on observing rows committed by the apply and sync workers while the
 * loop is running.
 */
static char *
zodan_local_scalar(const char *sql)
{
	int			rc;
	char	   *ret = NULL;

	rc = SPI_execute(sql, false, 0);
	if (rc != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute (select) failed for: %s", sql);

	if (SPI_processed > 0)
	{
		bool		isnull;
		Datum		d = SPI_getbinval(SPI_tuptable->vals[0],
									  SPI_tuptable->tupdesc, 1, &isnull);

		if (!isnull)
		{
			MemoryContext old = MemoryContextSwitchTo(CurrentMemoryContext);
			char	   *s = SPI_getvalue(SPI_tuptable->vals[0],
										 SPI_tuptable->tupdesc, 1);

			MemoryContextSwitchTo(old);
			(void) d;
			ret = s;
		}
	}
	return ret;
}

/* Convenience: local scalar as int64 (0 if NULL). */
static int64
zodan_local_count(const char *sql)
{
	char	   *s = zodan_local_scalar(sql);
	int64		v = 0;

	if (s != NULL)
	{
		v = pg_strtoint64(s);
		pfree(s);
	}
	return v;
}

/* ------------------------------------------------------------------------
 * Cluster inspection
 * ------------------------------------------------------------------------ */

/*
 * Fetch the list of all nodes known to the source cluster (from the source
 * node), storing them in ctx->nodes/ctx->nnodes in ctx->mcxt.
 */
static void
zodan_fetch_cluster_nodes(ZodanAddCtx *ctx)
{
	PGconn	   *conn;
	PGresult   *res;
	int			n;
	int			i;
	MemoryContext old;

	conn = zodan_connect(ctx->src_dsn, "nodes");
	res = zodan_remote_query(conn,
							 "SELECT n.node_name, i.if_dsn, "
							 "COALESCE(n.location,''), COALESCE(n.country,''), "
							 "COALESCE(n.info::text,'') "
							 "FROM spock.node n "
							 "JOIN spock.node_interface i ON n.node_id = i.if_nodeid "
							 "ORDER BY n.node_name");
	n = PQntuples(res);

	old = MemoryContextSwitchTo(ctx->mcxt);
	ctx->nodes = (ZNode *) palloc0(sizeof(ZNode) * Max(n, 1));
	for (i = 0; i < n; i++)
	{
		ctx->nodes[i].name = pstrdup(PQgetvalue(res, i, 0));
		ctx->nodes[i].dsn = pstrdup(PQgetvalue(res, i, 1));
		ctx->nodes[i].location = pstrdup(PQgetvalue(res, i, 2));
		ctx->nodes[i].country = pstrdup(PQgetvalue(res, i, 3));
		ctx->nodes[i].info = pstrdup(PQgetvalue(res, i, 4));
	}
	ctx->nnodes = n;
	MemoryContextSwitchTo(old);

	PQclear(res);
	PQfinish(conn);
}

/* Number of nodes that are neither the source nor the new node. */
static int
zodan_num_other_nodes(ZodanAddCtx *ctx)
{
	int			i;
	int			cnt = 0;

	for (i = 0; i < ctx->nnodes; i++)
	{
		if (strcmp(ctx->nodes[i].name, ctx->src_node_name) != 0 &&
			strcmp(ctx->nodes[i].name, ctx->new_node_name) != 0)
			cnt++;
	}
	return cnt;
}

/*
 * Check the Spock extension version on a node reachable via conn, returning
 * major/minor/patch.  ERROR if the extension is missing.
 */
static void
zodan_remote_spock_version(PGconn *conn, const char *label,
						   int *major, int *minor, int *patch)
{
	char	   *v = zodan_remote_scalar(conn,
					"SELECT extversion FROM pg_extension WHERE extname = 'spock'");

	if (v == NULL)
		ereport(ERROR,
				(errmsg("Spock extension not found on %s", label)));
	zodan_parse_version(v, major, minor, patch);
	pfree(v);
}

/* ------------------------------------------------------------------------
 * add_node phases
 * ------------------------------------------------------------------------ */

/*
 * Phase 0: verify the Spock version on the source node, the new node and every
 * existing cluster node.  All nodes must be >= ZODAN_MIN_VERSION and share the
 * same major.minor (patch differences are allowed for rolling upgrades).
 */
static void
zodan_check_versions(ZodanAddCtx *ctx)
{
	int			min1,
				min2,
				min3;
	int			s1,
				s2,
				s3;
	int			n1,
				n2,
				n3;
	PGconn	   *conn;
	int			i;

	zodan_parse_version(ZODAN_MIN_VERSION, &min1, &min2, &min3);

	ZVERB(ctx->verb, "Checking Spock version on source node");
	conn = zodan_connect(ctx->src_dsn, "ver");
	zodan_remote_spock_version(conn, "source node", &s1, &s2, &s3);
	PQfinish(conn);

	if (zodan_version_cmp(s1, s2, s3, min1, min2, min3) < 0)
		ereport(ERROR,
				(errmsg("Spock version mismatch: source node has version %d.%d.%d, "
						"but minimum required version is %s",
						s1, s2, s3, ZODAN_MIN_VERSION)));

	ZVERB(ctx->verb, "Checking Spock version on new node");
	conn = zodan_connect(ctx->new_node_dsn, "ver");
	zodan_remote_spock_version(conn, "new node", &n1, &n2, &n3);
	PQfinish(conn);

	if (zodan_version_cmp(n1, n2, n3, min1, min2, min3) < 0)
		ereport(ERROR,
				(errmsg("Spock version mismatch: new node has version %d.%d.%d, "
						"but minimum required version is %s",
						n1, n2, n3, ZODAN_MIN_VERSION)));

	if (n1 != s1 || n2 != s2)
		ereport(ERROR,
				(errmsg("Spock version mismatch: new node has version %d.%d.%d, "
						"but source version is %d.%d.%d; major.minor versions must match",
						n1, n2, n3, s1, s2, s3)));

	/* Every existing cluster node must match too. */
	for (i = 0; i < ctx->nnodes; i++)
	{
		int			c1,
					c2,
					c3;

		conn = zodan_connect(ctx->nodes[i].dsn, "ver");
		zodan_remote_spock_version(conn, ctx->nodes[i].name, &c1, &c2, &c3);
		PQfinish(conn);

		if (zodan_version_cmp(c1, c2, c3, min1, min2, min3) < 0)
			ereport(ERROR,
					(errmsg("Spock version mismatch: node %s has version %d.%d.%d, "
							"but required version is at least %s",
							ctx->nodes[i].name, c1, c2, c3, ZODAN_MIN_VERSION)));
		if (c1 != n1 || c2 != n2)
			ereport(ERROR,
					(errmsg("Spock version mismatch: new node has version %d.%d.%d, "
							"but found node %s version %d.%d.%d; major.minor must match",
							n1, n2, n3, ctx->nodes[i].name, c1, c2, c3)));
	}

	ZVERB(ctx->verb,
		  "Version check passed: source %d.%d.%d, new node %d.%d.%d",
		  s1, s2, s3, n1, n2, n3);
}

/*
 * Phase 1: verify prerequisites.  Most importantly this enforces that add_node
 * is being run on the new node (by comparing the local system identifier and
 * database name against what new_node_dsn points at).
 */
static void
zodan_verify_prerequisites(ZodanAddCtx *ctx)
{
	char	   *local_sysid;
	char	   *local_dbname;
	char	   *remote_sysid;
	char	   *remote_dbname;
	char	   *new_dbname;
	PGconn	   *conn;
	int64		cnt;

	ZNOTE("Phase 1: Validating source and new node prerequisites");

	/* add_node must be run on the new node. */
	local_sysid = zodan_local_scalar("SELECT system_identifier::text FROM pg_control_system()");
	local_dbname = zodan_local_scalar("SELECT current_database()");

	conn = zodan_connect(ctx->new_node_dsn, "prereq");
	remote_sysid = zodan_remote_scalar(conn,
					"SELECT system_identifier::text FROM pg_control_system()");
	remote_dbname = zodan_remote_scalar(conn, "SELECT current_database()");
	PQfinish(conn);

	if (local_sysid == NULL || remote_sysid == NULL ||
		strcmp(local_sysid, remote_sysid) != 0 ||
		local_dbname == NULL || remote_dbname == NULL ||
		strcmp(local_dbname, remote_dbname) != 0)
		ereport(ERROR,
				(errmsg("add_node must be run on the new node being added"),
				 errdetail("new_node_dsn (%s) does not match the current database connection",
						   ctx->new_node_dsn),
				 errhint("Connect to the new node and re-run add_node.")));

	ZVERB(ctx->verb, "    OK: add_node is running on the new node");

	/* Sanity-check the database named by the new node DSN. */
	new_dbname = zodan_dbname_from_dsn(ctx->new_node_dsn);

	/* No lolor extension / data on the new node. */
	cnt = zodan_local_count("SELECT count(*) FROM pg_tables WHERE schemaname = 'lolor'");
	if (cnt > 0)
		ereport(ERROR,
				(errmsg("database %s has the lolor extension installed or remaining lolor data",
						new_dbname)));
	ZVERB(ctx->verb, "    OK: database %s has no lolor data", new_dbname);

	/* No user tables on the new node. */
	cnt = zodan_local_count(
		"SELECT count(*) FROM pg_tables "
		"WHERE schemaname NOT IN ('information_schema','pg_catalog','pg_toast','spock') "
		"AND schemaname NOT LIKE 'pg_temp_%' "
		"AND schemaname NOT LIKE 'pg_toast_temp_%'");
	if (cnt > 0)
		ereport(ERROR,
				(errmsg("database %s on the new node has %ld user-created tables",
						new_dbname, (long) cnt),
				 errhint("The new node must be a freshly created database with no user tables.")));
	ZVERB(ctx->verb, "    OK: database %s has no user tables", new_dbname);

	/* Every source login role must exist on the new node. */
	{
		PGconn	   *src_conn = zodan_connect(ctx->src_dsn, "prereq");
		PGresult   *res;
		int			i;
		StringInfoData missing;

		initStringInfo(&missing);
		res = zodan_remote_query(src_conn,
			"SELECT rolname FROM pg_roles "
			"WHERE rolcanlogin = true "
			"AND rolname NOT IN ('postgres','rdsadmin','rdsrepladmin','rds_superuser') "
			"ORDER BY rolname");
		for (i = 0; i < PQntuples(res); i++)
		{
			char	   *rolname = PQgetvalue(res, i, 0);
			char	   *sql = psprintf(
				"SELECT count(*) FROM pg_roles WHERE rolname = '%s' AND rolcanlogin = true",
				rolname);
			int64		exists = zodan_local_count(sql);

			pfree(sql);
			if (exists == 0)
			{
				if (missing.len > 0)
					appendStringInfoString(&missing, ", ");
				appendStringInfoString(&missing, rolname);
			}
		}
		PQclear(res);
		PQfinish(src_conn);

		if (missing.len > 0)
			ereport(ERROR,
					(errmsg("new node is missing roles that exist on the source node: %s",
							missing.data),
					 errhint("Create these roles on the new node before adding it to the cluster.")));
		pfree(missing.data);
		ZVERB(ctx->verb, "    OK: new node has all source-node login roles");
	}

	/* Every existing cluster node must have only enabled subscriptions. */
	{
		int			i;

		for (i = 0; i < ctx->nnodes; i++)
		{
			PGconn	   *nconn;
			PGresult   *res;
			int			j;

			if (strcmp(ctx->nodes[i].name, ctx->new_node_name) == 0)
				continue;

			nconn = zodan_connect(ctx->nodes[i].dsn, "prereq");
			res = zodan_remote_query(nconn,
					"SELECT sub_name, sub_enabled FROM spock.subscription");
			for (j = 0; j < PQntuples(res); j++)
			{
				char	   *sub = PQgetvalue(res, j, 0);
				char	   *en = PQgetvalue(res, j, 1);

				if (en[0] != 't')
				{
					PQclear(res);
					PQfinish(nconn);
					ereport(ERROR,
							(errmsg("node %s has disabled subscription %s",
									ctx->nodes[i].name, sub),
							 errhint("All subscriptions must be enabled before adding a node.")));
				}
			}
			PQclear(res);
			PQfinish(nconn);
		}
		ZVERB(ctx->verb, "    OK: every cluster node has only enabled subscriptions");
	}

	/* The new node must not already exist locally with subs/repsets. */
	cnt = zodan_local_count(psprintf(
		"SELECT count(*) FROM spock.node WHERE node_name = '%s'", ctx->new_node_name));
	if (cnt > 0)
		ereport(ERROR, (errmsg("new node %s already exists", ctx->new_node_name)));

	cnt = zodan_local_count(
		"SELECT count(*) FROM spock.subscription");
	if (cnt > 0)
		ereport(ERROR,
				(errmsg("new node already has subscriptions; it must be a clean node")));

	ZVERB(ctx->verb, "    OK: new node %s is clean", ctx->new_node_name);

	pfree(new_dbname);
}

/*
 * Phase 2: create the new node in the local (new node's) database.  The source
 * node already exists in its own database, and the local representation of the
 * source node is created automatically by spock.sub_create() when the
 * source->new subscription is created, so we only create the new node here.
 */
static void
zodan_create_nodes(ZodanAddCtx *ctx)
{
	StringInfoData sql;

	ZNOTE("Phase 2: Creating nodes");

	/* Create the new (local) node. */
	initStringInfo(&sql);
	appendStringInfo(&sql,
					 "SELECT spock.node_create(node_name := %s, dsn := %s, "
					 "location := %s, country := %s, info := %s::jsonb)",
					 quote_literal_cstr(ctx->new_node_name),
					 quote_literal_cstr(ctx->new_node_dsn),
					 quote_literal_cstr(ctx->new_node_location),
					 quote_literal_cstr(ctx->new_node_country),
					 quote_literal_cstr(ctx->new_node_info));
	zodan_local_command(sql.data);
	pfree(sql.data);
	ZNOTE("    OK: created new node %s", ctx->new_node_name);

	/* Commit so the node rows are visible cluster-wide before we continue. */
	SPI_commit();
}

/*
 * Create a logical replication slot on a remote node if it does not already
 * exist.  On PG17+ the slot is created with failover = true, matching Spock's
 * own slot creation path.  Returns the slot's LSN as a palloc'd string, or NULL
 * if the slot already existed.
 */
static char *
zodan_remote_create_slot(PGconn *conn, const char *slot_name)
{
	char	   *exists;
	char	   *server_ver;
	int			vernum;
	StringInfoData sql;
	char	   *lsn;

	exists = zodan_remote_scalar(conn, psprintf(
		"SELECT count(*) FROM pg_replication_slots WHERE slot_name = %s",
		quote_literal_cstr(slot_name)));
	if (exists != NULL && strcmp(exists, "0") != 0)
		return NULL;

	server_ver = zodan_remote_scalar(conn, "SHOW server_version_num");
	vernum = server_ver ? atoi(server_ver) : 0;

	initStringInfo(&sql);
	if (vernum >= 170000)
		appendStringInfo(&sql,
						 "SELECT slot_name, lsn FROM pg_create_logical_replication_slot(%s, 'spock_output', false, false, true)",
						 quote_literal_cstr(slot_name));
	else
		appendStringInfo(&sql,
						 "SELECT slot_name, lsn FROM pg_create_logical_replication_slot(%s, 'spock_output')",
						 quote_literal_cstr(slot_name));

	lsn = NULL;
	{
		PGresult   *res = zodan_remote_query(conn, sql.data);

		if (PQntuples(res) > 0 && !PQgetisnull(res, 0, 1))
			lsn = pstrdup(PQgetvalue(res, 0, 1));
		PQclear(res);
	}
	pfree(sql.data);
	return lsn;
}

/*
 * Wait until the source node has applied changes from origin_node up to
 * target_lsn (observed through spock.progress.remote_commit_lsn on the source).
 * Bounded by ctx->timeout_sec.
 */
static void
zodan_wait_source_caughtup(ZodanAddCtx *ctx, const char *origin_node,
						   const char *target_lsn)
{
	PGconn	   *conn = zodan_connect(ctx->src_dsn, "catchup");
	char	   *progress_sql;
	TimestampTz start = GetCurrentTimestamp();

	progress_sql = psprintf(
		"SELECT p.remote_commit_lsn "
		"FROM spock.progress p "
		"JOIN spock.node n ON n.node_id = p.remote_node_id "
		"WHERE p.node_id = (SELECT node_id FROM spock.node_info()) "
		"AND n.node_name = %s",
		quote_literal_cstr(origin_node));

	ZVERB(ctx->verb,
		  "    - Waiting for source node %s to apply %s changes up to %s",
		  ctx->src_node_name, origin_node, target_lsn);

	for (;;)
	{
		char	   *cur = zodan_remote_scalar(conn, progress_sql);

		if (cur != NULL)
		{
			bool		reached;
			char	   *cmp = psprintf("SELECT %s::pg_lsn >= %s::pg_lsn",
									   quote_literal_cstr(cur),
									   quote_literal_cstr(target_lsn));
			char	   *r = zodan_local_scalar(cmp);

			reached = (r != NULL && r[0] == 't');
			pfree(cmp);
			if (r)
				pfree(r);
			if (reached)
			{
				pfree(cur);
				break;
			}
			pfree(cur);
		}

		if (TimestampDifferenceExceeds(start, GetCurrentTimestamp(),
									   ctx->timeout_sec * 1000))
		{
			PQfinish(conn);
			ereport(ERROR,
					(errmsg("timed out waiting for source node %s to apply %s changes through %s",
							ctx->src_node_name, origin_node, target_lsn)));
		}
		zodan_sleep_ms(500);
	}

	PQfinish(conn);
	pfree(progress_sql);
}

/*
 * Trigger a sync event on a remote node (conn) and return its LSN as a palloc'd
 * string.  transactional selects spock.sync_event(true) vs spock.sync_event().
 */
static char *
zodan_remote_sync_event(PGconn *conn, bool transactional)
{
	return zodan_remote_scalar(conn,
							   transactional
							   ? "SELECT spock.sync_event(true)"
							   : "SELECT spock.sync_event()");
}

/*
 * Wait for a sync event (origin_node / lsn) to be applied on the node reached
 * by conn, by calling spock.wait_for_sync_event() there.  ERROR on timeout.
 */
static void
zodan_remote_wait_for_sync_event(ZodanAddCtx *ctx, PGconn *conn,
								 const char *origin_node, const char *lsn)
{
	StringInfoData sql;
	char	   *ok;

	initStringInfo(&sql);
	appendStringInfo(&sql,
					 "CALL spock.wait_for_sync_event(true, %s, %s::pg_lsn, %d, true)",
					 quote_literal_cstr(origin_node),
					 quote_literal_cstr(lsn),
					 ctx->timeout_sec * 1000);
	ok = zodan_remote_scalar(conn, sql.data);
	pfree(sql.data);

	if (ok == NULL || ok[0] != 't')
		ereport(ERROR,
				(errmsg("wait_for_sync_event timed out for %s (lsn %s)",
						origin_node, lsn)));
	pfree(ok);
}

/*
 * Wait for a sync event locally (we are the new node) by polling
 * spock.progress until we have applied origin_node's changes up to lsn.
 */
static void
zodan_local_wait_for_sync_event(ZodanAddCtx *ctx, const char *origin_node,
								const char *lsn)
{
	char	   *progress_sql;
	TimestampTz start = GetCurrentTimestamp();

	progress_sql = psprintf(
		"SELECT p.remote_commit_lsn "
		"FROM spock.progress p "
		"JOIN spock.node n ON n.node_id = p.remote_node_id "
		"WHERE p.node_id = (SELECT node_id FROM spock.node_info()) "
		"AND n.node_name = %s",
		quote_literal_cstr(origin_node));

	for (;;)
	{
		char	   *cur = zodan_local_scalar(progress_sql);

		if (cur != NULL)
		{
			char	   *cmp = psprintf("SELECT %s::pg_lsn >= %s::pg_lsn",
									   quote_literal_cstr(cur),
									   quote_literal_cstr(lsn));
			char	   *r = zodan_local_scalar(cmp);
			bool		reached = (r != NULL && r[0] == 't');

			pfree(cmp);
			if (r)
				pfree(r);
			pfree(cur);
			if (reached)
				break;
		}

		if (TimestampDifferenceExceeds(start, GetCurrentTimestamp(),
									   ctx->timeout_sec * 1000))
			ereport(ERROR,
					(errmsg("timed out waiting for sync event from %s (lsn %s) on new node",
							origin_node, lsn)));
		zodan_sleep_ms(500);
	}
	pfree(progress_sql);
}

/*
 * Create a subscription.  If on_dsn is NULL the subscription is created locally
 * (on the new node) over SPI; otherwise it is created on the remote node over
 * libpq.  This mirrors the create_sub() helper in the old zodan.sql.
 */
static void
zodan_create_sub(ZodanAddCtx *ctx, const char *on_dsn, const char *sub_name,
				 const char *provider_dsn, bool sync_structure,
				 bool sync_data, bool enabled)
{
	StringInfoData sql;

	initStringInfo(&sql);
	appendStringInfo(&sql,
					 "SELECT spock.sub_create("
					 "subscription_name := %s, "
					 "provider_dsn := %s, "
					 "replication_sets := %s, "
					 "synchronize_structure := %s, "
					 "synchronize_data := %s, "
					 "forward_origins := '{}', "
					 "apply_delay := '0'::interval, "
					 "force_text_transfer := false, "
					 "enabled := %s)",
					 quote_literal_cstr(sub_name),
					 quote_literal_cstr(provider_dsn),
					 ZODAN_REPSETS,
					 sync_structure ? "true" : "false",
					 sync_data ? "true" : "false",
					 enabled ? "true" : "false");

	if (on_dsn == NULL)
	{
		zodan_local_command(sql.data);
	}
	else
	{
		PGconn	   *conn = zodan_connect(on_dsn, "subcreate");

		zodan_remote_command(conn, sql.data);
		PQfinish(conn);
	}
	pfree(sql.data);
}

/*
 * Phase 3: create disabled subscriptions and replication slots for every
 * "other" node (all cluster nodes except source and new).  For a 2-node
 * cluster this only records a sync event on the source node.
 *
 * The stored sync LSNs (for later enabling) are kept in a temp table on the
 * new node, exactly as the old zodan.sql did, so the later phases can find
 * them regardless of intervening commits.
 */
static void
zodan_create_disabled_subs_and_slots(ZodanAddCtx *ctx)
{
	int			i;

	ZNOTE("Phase 3: Creating disabled subscriptions and slots");

	zodan_local_command(
		"CREATE TEMP TABLE IF NOT EXISTS temp_sync_lsns ("
		"origin_node text PRIMARY KEY, sync_lsn text NOT NULL, slot_lsn pg_lsn)");

	if (zodan_num_other_nodes(ctx) == 0)
	{
		/* 2-node scenario: capture a source sync event for later. */
		PGconn	   *conn = zodan_connect(ctx->src_dsn, "sync");
		char	   *lsn = zodan_remote_sync_event(conn, false);

		PQfinish(conn);
		if (lsn == NULL)
			ereport(ERROR,
					(errmsg("could not trigger sync event on source node %s",
							ctx->src_node_name)));

		zodan_local_command(psprintf(
			"INSERT INTO temp_sync_lsns (origin_node, sync_lsn) VALUES (%s, %s) "
			"ON CONFLICT (origin_node) DO UPDATE SET sync_lsn = EXCLUDED.sync_lsn",
			quote_literal_cstr(ctx->src_node_name),
			quote_literal_cstr(lsn)));
		ZVERB(ctx->verb, "    - 2-node scenario: stored source sync event %s", lsn);
		pfree(lsn);
		return;
	}

	for (i = 0; i < ctx->nnodes; i++)
	{
		ZNode	   *rec = &ctx->nodes[i];
		char	   *slot_name;
		char	   *sub_name;
		char	   *slot_lsn;
		char	   *catchup_lsn;
		PGconn	   *conn;

		if (strcmp(rec->name, ctx->src_node_name) == 0 ||
			strcmp(rec->name, ctx->new_node_name) == 0)
			continue;

		slot_name = zodan_gen_slot_name(rec->dsn, rec->name,
										zodan_gen_sub_name(rec->name, ctx->new_node_name));
		sub_name = zodan_gen_sub_name(rec->name, ctx->new_node_name);

		/* Create the slot on the other node. */
		conn = zodan_connect(rec->dsn, "slot");
		slot_lsn = zodan_remote_create_slot(conn, slot_name);
		ZVERB(ctx->verb, "    OK: created replication slot %s on node %s",
			  slot_name, rec->name);

		/* Anchor a real commit past the slot so the catch-up target exists. */
		catchup_lsn = zodan_remote_sync_event(conn, true);
		PQfinish(conn);
		if (catchup_lsn == NULL)
			ereport(ERROR,
					(errmsg("could not trigger sync event on node %s", rec->name)));

		zodan_local_command(psprintf(
			"INSERT INTO temp_sync_lsns (origin_node, sync_lsn, slot_lsn) "
			"VALUES (%s, %s, %s) "
			"ON CONFLICT (origin_node) DO UPDATE "
			"SET sync_lsn = EXCLUDED.sync_lsn, slot_lsn = EXCLUDED.slot_lsn",
			quote_literal_cstr(rec->name),
			quote_literal_cstr(catchup_lsn),
			slot_lsn ? quote_literal_cstr(slot_lsn) : "NULL"));

		/* Wait until the source has applied rec's changes up to catchup_lsn. */
		zodan_wait_source_caughtup(ctx, rec->name, catchup_lsn);

		/* Drop any stale origin so the sub starts clean, then create disabled. */
		{
			PGconn	   *nconn = zodan_connect(ctx->new_node_dsn, "origin");

			zodan_remote_command(nconn, psprintf(
				"DO $x$ BEGIN "
				"IF EXISTS (SELECT 1 FROM pg_replication_origin WHERE roname = %s) THEN "
				"PERFORM pg_replication_origin_drop(%s); END IF; END $x$",
				quote_literal_cstr(slot_name), quote_literal_cstr(slot_name)));
			PQfinish(nconn);
		}

		zodan_create_sub(ctx, NULL, sub_name, rec->dsn, false, false, false);
		ZNOTE("    OK: created disabled subscription %s (provider %s)",
			  sub_name, rec->name);

		if (catchup_lsn)
			pfree(catchup_lsn);
		if (slot_lsn)
			pfree(slot_lsn);
	}

	/* Make the disabled subs and stored LSNs durable before continuing. */
	SPI_commit();
}

/*
 * Phase 4: for each other node, trigger a sync event on that node and wait for
 * the source node to apply it.
 */
static void
zodan_sync_other_nodes_wait_source(ZodanAddCtx *ctx)
{
	int			i;

	ZNOTE("Phase 4: Triggering sync events on other nodes and waiting on source");

	if (zodan_num_other_nodes(ctx) == 0)
	{
		ZVERB(ctx->verb, "    - No other nodes, skipping");
		return;
	}

	for (i = 0; i < ctx->nnodes; i++)
	{
		ZNode	   *rec = &ctx->nodes[i];
		PGconn	   *conn;
		PGconn	   *src_conn;
		char	   *lsn;

		if (strcmp(rec->name, ctx->src_node_name) == 0 ||
			strcmp(rec->name, ctx->new_node_name) == 0)
			continue;

		conn = zodan_connect(rec->dsn, "sync");
		lsn = zodan_remote_sync_event(conn, false);
		PQfinish(conn);
		if (lsn == NULL)
			ereport(ERROR, (errmsg("could not trigger sync event on node %s", rec->name)));

		src_conn = zodan_connect(ctx->src_dsn, "sync");
		zodan_remote_wait_for_sync_event(ctx, src_conn, rec->name, lsn);
		PQfinish(src_conn);
		ZVERB(ctx->verb, "    OK: sync event from %s confirmed on source", rec->name);
		pfree(lsn);
	}
}

/*
 * Phase 5: create the enabled source->new subscription (with structure and
 * data synchronization).
 */
static void
zodan_create_source_to_new_sub(ZodanAddCtx *ctx)
{
	char	   *sub_name = zodan_gen_sub_name(ctx->src_node_name, ctx->new_node_name);

	ZNOTE("Phase 5: Creating source to new node subscription");
	zodan_create_sub(ctx, NULL, sub_name, ctx->src_dsn, true, true, true);
	ZNOTE("    OK: created subscription %s", sub_name);
	SPI_commit();
}

/*
 * Phase 6: trigger a sync event on the source node and wait for the new node
 * (this node) to apply it.
 */
static void
zodan_source_sync_wait_new(ZodanAddCtx *ctx)
{
	PGconn	   *conn;
	char	   *lsn;

	ZNOTE("Phase 6: Triggering sync on source node and waiting on new node");

	conn = zodan_connect(ctx->src_dsn, "sync");
	lsn = zodan_remote_sync_event(conn, false);
	PQfinish(conn);
	if (lsn == NULL)
		ereport(ERROR,
				(errmsg("could not trigger sync event on source node %s",
						ctx->src_node_name)));

	zodan_local_wait_for_sync_event(ctx, ctx->src_node_name, lsn);
	ZVERB(ctx->verb, "    OK: sync event from source confirmed on new node");
	pfree(lsn);
}

/*
 * Wait until the source->new subscription has finished its initial COPY and is
 * READY (no pending table sync).  Bounded by ctx->timeout_sec.
 */
static void
zodan_wait_sub_ready(ZodanAddCtx *ctx, const char *sub_name)
{
	char	   *subid;
	TimestampTz start = GetCurrentTimestamp();

	subid = zodan_local_scalar(psprintf(
		"SELECT sub_id::text FROM spock.subscription WHERE sub_name = %s",
		quote_literal_cstr(sub_name)));
	if (subid == NULL)
	{
		ZVERB(ctx->verb, "    - subscription %s not found; continuing", sub_name);
		return;
	}

	for (;;)
	{
		int64		pending = zodan_local_count(psprintf(
			"SELECT count(*) FROM spock.local_sync_status "
			"WHERE sync_subid = %s AND sync_status NOT IN ('y','r')", subid));

		if (pending == 0)
		{
			ZVERB(ctx->verb, "    - subscription %s is READY", sub_name);
			break;
		}
		if (TimestampDifferenceExceeds(start, GetCurrentTimestamp(),
									   ctx->timeout_sec * 1000))
		{
			ZNOTE("    - timed out waiting for %s to become READY; continuing", sub_name);
			break;
		}
		zodan_sleep_ms(1000);
	}
	pfree(subid);
}

/*
 * Phase 7: wait for the source->new subscription to become READY.  Slot/origin
 * advancement is handled by the apply worker for the active subscription; we
 * only advance the inactive "other node" slots defensively.
 */
static void
zodan_wait_ready_and_advance(ZodanAddCtx *ctx)
{
	char	   *sub_name;
	int			i;

	ZNOTE("Phase 7: Waiting for initial sync and advancing slots");

	sub_name = zodan_gen_sub_name(ctx->src_node_name, ctx->new_node_name);
	zodan_wait_sub_ready(ctx, sub_name);

	if (zodan_num_other_nodes(ctx) == 0)
		return;

	/* Advance each other-node slot/origin to the resume point. */
	for (i = 0; i < ctx->nnodes; i++)
	{
		ZNode	   *rec = &ctx->nodes[i];
		char	   *slot_name;
		char	   *cur_lsn;
		char	   *target_lsn;
		PGconn	   *conn;

		if (strcmp(rec->name, ctx->src_node_name) == 0 ||
			strcmp(rec->name, ctx->new_node_name) == 0)
			continue;

		slot_name = zodan_gen_slot_name(rec->dsn, rec->name,
										zodan_gen_sub_name(rec->name, ctx->new_node_name));

		conn = zodan_connect(rec->dsn, "advance");
		cur_lsn = zodan_remote_scalar(conn, psprintf(
			"SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = %s",
			quote_literal_cstr(slot_name)));
		if (cur_lsn == NULL)
		{
			PQfinish(conn);
			ZVERB(ctx->verb, "    - slot %s does not exist, skipping advance", slot_name);
			continue;
		}

		/* Advance to the last commit from rec that the source had applied. */
		target_lsn = zodan_local_scalar(psprintf(
			"SELECT p.remote_commit_lsn::text "
			"FROM spock.progress p JOIN spock.node n ON n.node_id = p.remote_node_id "
			"WHERE n.node_name = %s", quote_literal_cstr(rec->name)));

		if (target_lsn != NULL)
		{
			char	   *need = psprintf("SELECT %s::pg_lsn > %s::pg_lsn",
										quote_literal_cstr(target_lsn),
										quote_literal_cstr(cur_lsn));
			char	   *r = zodan_local_scalar(need);

			if (r != NULL && r[0] == 't')
			{
				zodan_remote_command(conn, psprintf(
					"SELECT pg_replication_slot_advance(%s, %s::pg_lsn)",
					quote_literal_cstr(slot_name), quote_literal_cstr(target_lsn)));

				/* Advance the origin locally (it lives on the new node). */
				zodan_local_command(psprintf(
					"DO $x$ BEGIN "
					"IF NOT EXISTS (SELECT 1 FROM pg_replication_origin WHERE roname = %s) THEN "
					"PERFORM pg_replication_origin_create(%s); END IF; "
					"PERFORM pg_replication_origin_advance(%s, %s::pg_lsn); END $x$",
					quote_literal_cstr(slot_name), quote_literal_cstr(slot_name),
					quote_literal_cstr(slot_name), quote_literal_cstr(target_lsn)));
				ZVERB(ctx->verb, "    OK: advanced slot/origin %s to %s",
					  slot_name, target_lsn);
			}
			pfree(need);
			if (r)
				pfree(r);
			pfree(target_lsn);
		}
		PQfinish(conn);
		pfree(cur_lsn);
	}
	SPI_commit();
}

/*
 * Phase 8: enable the previously disabled subscriptions (source->new for the
 * 2-node case, other->new for the multi-node case), waiting for each stored
 * sync event first.
 */
static void
zodan_enable_disabled_subs(ZodanAddCtx *ctx)
{
	int			i;

	ZNOTE("Phase 8: Enabling disabled subscriptions");

	if (zodan_num_other_nodes(ctx) == 0)
	{
		char	   *sub_name = zodan_gen_sub_name(ctx->src_node_name, ctx->new_node_name);
		char	   *lsn;

		zodan_local_command(psprintf(
			"SELECT spock.sub_enable(subscription_name := %s, immediate := true)",
			quote_literal_cstr(sub_name)));
		SPI_commit();

		lsn = zodan_local_scalar(psprintf(
			"SELECT sync_lsn FROM temp_sync_lsns WHERE origin_node = %s",
			quote_literal_cstr(ctx->src_node_name)));
		if (lsn != NULL)
		{
			zodan_local_wait_for_sync_event(ctx, ctx->src_node_name, lsn);
			pfree(lsn);
		}
		ZNOTE("    OK: enabled subscription %s", sub_name);
		return;
	}

	for (i = 0; i < ctx->nnodes; i++)
	{
		ZNode	   *rec = &ctx->nodes[i];
		char	   *sub_name;
		char	   *lsn;

		if (strcmp(rec->name, ctx->src_node_name) == 0 ||
			strcmp(rec->name, ctx->new_node_name) == 0)
			continue;

		sub_name = zodan_gen_sub_name(rec->name, ctx->new_node_name);
		zodan_local_command(psprintf(
			"SELECT spock.sub_enable(subscription_name := %s, immediate := true)",
			quote_literal_cstr(sub_name)));
		SPI_commit();

		lsn = zodan_local_scalar(psprintf(
			"SELECT sync_lsn FROM temp_sync_lsns WHERE origin_node = %s",
			quote_literal_cstr(rec->name)));
		if (lsn != NULL)
		{
			zodan_local_wait_for_sync_event(ctx, rec->name, lsn);
			pfree(lsn);
		}
		ZNOTE("    OK: enabled subscription %s", sub_name);
	}
}

/*
 * Phase 9: create subscriptions from every existing node to the new node (so
 * the rest of the cluster receives the new node's changes).  These are created
 * on the remote nodes, with the new node as provider.
 */
static void
zodan_create_subs_to_new_node(ZodanAddCtx *ctx)
{
	int			i;

	ZNOTE("Phase 9: Creating subscriptions from other nodes to the new node");

	for (i = 0; i < ctx->nnodes; i++)
	{
		ZNode	   *rec = &ctx->nodes[i];
		char	   *sub_name;

		if (strcmp(rec->name, ctx->new_node_name) == 0)
			continue;

		sub_name = zodan_gen_sub_name(ctx->new_node_name, rec->name);
		zodan_create_sub(ctx, rec->dsn, sub_name, ctx->new_node_dsn, false, false, true);
		ZNOTE("    OK: created subscription %s on node %s", sub_name, rec->name);
	}
}

/*
 * Phase 10: create the enabled new->source subscription (for the 2-node case
 * this establishes bidirectional replication; multi-node paths already covered
 * source in Phase 9's loop, so skip if it exists).
 */
static void
zodan_create_new_to_source_sub(ZodanAddCtx *ctx)
{
	char	   *sub_name = zodan_gen_sub_name(ctx->new_node_name, ctx->src_node_name);
	int64		exists;
	PGconn	   *conn;

	ZNOTE("Phase 10: Creating new to source node subscription");

	conn = zodan_connect(ctx->src_dsn, "subcheck");
	exists = 0;
	{
		char	   *c = zodan_remote_scalar(conn, psprintf(
			"SELECT count(*) FROM spock.subscription WHERE sub_name = %s",
			quote_literal_cstr(sub_name)));

		if (c != NULL)
		{
			exists = pg_strtoint64(c);
			pfree(c);
		}
	}
	PQfinish(conn);

	if (exists > 0)
	{
		ZVERB(ctx->verb, "    - subscription %s already exists, skipping", sub_name);
		return;
	}

	zodan_create_sub(ctx, ctx->src_dsn, sub_name, ctx->new_node_dsn, false, false, true);
	ZNOTE("    OK: created subscription %s", sub_name);
}

/* ------------------------------------------------------------------------
 * remove_node phases
 * ------------------------------------------------------------------------ */

/*
 * Drop the inbound subscriptions (target as provider) on every surviving node,
 * then drop every subscription local to the target node.  Slot and origin
 * cleanup is implicit in spock.sub_drop().  Per-node errors are logged and
 * tolerated, matching the old zodremove.sql behavior.
 */
static void
zodan_remove_subscriptions(const char *target_node_name, bool verb)
{
	int			i;
	int			nnodes;
	ZNode	   *others;
	MemoryContext mcxt;
	MemoryContext old;

	/* Snapshot every node locally; the target is filtered out in C below. */
	if (SPI_execute(
			"SELECT n.node_name, i.if_dsn FROM spock.node n "
			"JOIN spock.node_interface i ON n.node_id = i.if_nodeid",
			true, 0) != SPI_OK_SELECT)
		elog(ERROR, "failed to enumerate cluster nodes");

	nnodes = SPI_processed;
	mcxt = AllocSetContextCreate(CurrentMemoryContext, "zodan_remove",
								 ALLOCSET_DEFAULT_SIZES);
	old = MemoryContextSwitchTo(mcxt);
	others = (ZNode *) palloc0(sizeof(ZNode) * Max(nnodes, 1));
	for (i = 0; i < nnodes; i++)
	{
		char	   *name = SPI_getvalue(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1);
		char	   *dsn = SPI_getvalue(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 2);

		others[i].name = name ? pstrdup(name) : NULL;
		others[i].dsn = dsn ? pstrdup(dsn) : NULL;
	}
	MemoryContextSwitchTo(old);

	/*
	 * Remote: drop each surviving node's inbound subscription from the target.
	 *
	 * Each node is handled inside its own internal subtransaction so that a
	 * failure to reach or update one node (for example a node that is down) is
	 * tolerated and does not abort the whole removal, matching the old
	 * zodremove.sql behavior.  Without the subtransaction, catching the error
	 * would leave the surrounding transaction in an aborted state.
	 */
	for (i = 0; i < nnodes; i++)
	{
		MemoryContext subctx = CurrentMemoryContext;
		ResourceOwner subowner = CurrentResourceOwner;
		PGconn	   *conn = NULL;

		if (others[i].name == NULL || others[i].dsn == NULL ||
			strcmp(others[i].name, target_node_name) == 0)
			continue;

		BeginInternalSubTransaction(NULL);
		MemoryContextSwitchTo(subctx);

		PG_TRY();
		{
			char	   *sub_name;

			conn = zodan_connect(others[i].dsn, "rmsub");
			sub_name = zodan_remote_scalar(conn, psprintf(
				"SELECT s.sub_name FROM spock.subscription s "
				"JOIN spock.node n ON n.node_id = s.sub_origin "
				"WHERE n.node_name = %s", quote_literal_cstr(target_node_name)));
			if (sub_name != NULL)
			{
				zodan_remote_command(conn, psprintf(
					"SELECT spock.sub_drop(%s, true)", quote_literal_cstr(sub_name)));
				ZNOTE("    OK: dropped subscription %s on node %s",
					  sub_name, others[i].name);
			}
			PQfinish(conn);
			conn = NULL;

			ReleaseCurrentSubTransaction();
			MemoryContextSwitchTo(subctx);
			CurrentResourceOwner = subowner;
		}
		PG_CATCH();
		{
			MemoryContextSwitchTo(subctx);
			if (conn != NULL)
				PQfinish(conn);
			RollbackAndReleaseCurrentSubTransaction();
			MemoryContextSwitchTo(subctx);
			CurrentResourceOwner = subowner;
			FlushErrorState();
			ereport(WARNING,
					(errmsg("could not drop inbound subscription on node %s; continuing",
							others[i].name)));
		}
		PG_END_TRY();
	}

	/* Local: drop every subscription on the target node. */
	if (SPI_execute("SELECT sub_name FROM spock.subscription", true, 0) != SPI_OK_SELECT)
		elog(ERROR, "failed to enumerate local subscriptions");
	{
		int			nlocal = SPI_processed;
		char	  **names = (char **) palloc0(sizeof(char *) * Max(nlocal, 1));

		for (i = 0; i < nlocal; i++)
		{
			char	   *nm = SPI_getvalue(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1);

			names[i] = nm ? pstrdup(nm) : NULL;
		}
		for (i = 0; i < nlocal; i++)
		{
			if (names[i] == NULL)
				continue;
			zodan_local_command(psprintf(
				"SELECT spock.sub_drop(%s, true)", quote_literal_cstr(names[i])));
			ZNOTE("    OK: dropped local subscription %s", names[i]);
		}
	}

	MemoryContextDelete(mcxt);
	(void) verb;
}

/* ------------------------------------------------------------------------
 * SQL entry points
 * ------------------------------------------------------------------------ */

/*
 * spock.add_node(src_node_name, src_dsn, new_node_name, new_node_dsn,
 *                verb, new_node_location, new_node_country, new_node_info,
 *                timeout_sec)
 *
 * Run on the NEW node.
 */
Datum
spock_add_node(PG_FUNCTION_ARGS)
{
	ZodanAddCtx *ctx;
	MemoryContext mcxt;
	MemoryContext old;
	bool		nonatomic;

	/* We must be able to commit between phases: require a top-level CALL. */
	nonatomic = fcinfo->context != NULL && IsA(fcinfo->context, CallContext) &&
		!((CallContext *) fcinfo->context)->atomic;
	if (!nonatomic)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TRANSACTION_TERMINATION),
				 errmsg("spock.add_node() cannot run inside a transaction block"),
				 errhint("Invoke it with a top-level CALL, not inside BEGIN/COMMIT.")));

	mcxt = AllocSetContextCreate(TopMemoryContext, "zodan_add",
								 ALLOCSET_DEFAULT_SIZES);
	old = MemoryContextSwitchTo(mcxt);
	ctx = (ZodanAddCtx *) palloc0(sizeof(ZodanAddCtx));
	ctx->mcxt = mcxt;
	ctx->src_node_name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	ctx->src_dsn = text_to_cstring(PG_GETARG_TEXT_PP(1));
	ctx->new_node_name = text_to_cstring(PG_GETARG_TEXT_PP(2));
	ctx->new_node_dsn = text_to_cstring(PG_GETARG_TEXT_PP(3));
	ctx->verb = PG_ARGISNULL(4) ? false : PG_GETARG_BOOL(4);
	ctx->new_node_location = PG_ARGISNULL(5) ? pstrdup("NY") : text_to_cstring(PG_GETARG_TEXT_PP(5));
	ctx->new_node_country = PG_ARGISNULL(6) ? pstrdup("USA") : text_to_cstring(PG_GETARG_TEXT_PP(6));
	ctx->new_node_info = PG_ARGISNULL(7) ? pstrdup("{}") :
		DatumGetCString(DirectFunctionCall1(jsonb_out, PG_GETARG_DATUM(7)));
	ctx->timeout_sec = PG_ARGISNULL(8) ? 180 : PG_GETARG_INT32(8);
	if (ctx->timeout_sec <= 0)
		ctx->timeout_sec = 180;
	MemoryContextSwitchTo(old);

	zodan_verbose = ctx->verb;

	SPI_connect_ext(SPI_OPT_NONATOMIC);

	PG_TRY();
	{
		zodan_fetch_cluster_nodes(ctx);

		zodan_check_versions(ctx);
		zodan_verify_prerequisites(ctx);
		zodan_create_nodes(ctx);
		/* Cluster snapshot may be stale after node creation; refresh. */
		zodan_fetch_cluster_nodes(ctx);
		zodan_create_disabled_subs_and_slots(ctx);
		zodan_sync_other_nodes_wait_source(ctx);
		zodan_create_source_to_new_sub(ctx);
		zodan_source_sync_wait_new(ctx);
		zodan_wait_ready_and_advance(ctx);
		zodan_enable_disabled_subs(ctx);
		zodan_create_subs_to_new_node(ctx);
		zodan_create_new_to_source_sub(ctx);

		ereport(NOTICE,
				(errmsg("add_node: node \"%s\" added to the cluster",
						ctx->new_node_name)));
	}
	PG_FINALLY();
	{
		MemoryContextDelete(mcxt);
	}
	PG_END_TRY();

	SPI_finish();
	PG_RETURN_VOID();
}

/*
 * spock.remove_node(target_node_name, target_node_dsn, verbose_mode)
 *
 * Run on the node being removed.  Order: subscriptions (incl. implicit slot and
 * origin cleanup) -> replication sets -> node.
 */
Datum
spock_remove_node(PG_FUNCTION_ARGS)
{
	char	   *target_node_name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	bool		verb = PG_ARGISNULL(2) ? true : PG_GETARG_BOOL(2);
	bool		nonatomic;
	int64		exists;

	zodan_verbose = verb;

	nonatomic = fcinfo->context != NULL && IsA(fcinfo->context, CallContext) &&
		!((CallContext *) fcinfo->context)->atomic;
	if (!nonatomic)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TRANSACTION_TERMINATION),
				 errmsg("spock.remove_node() cannot run inside a transaction block"),
				 errhint("Invoke it with a top-level CALL, not inside BEGIN/COMMIT.")));

	SPI_connect_ext(SPI_OPT_NONATOMIC);

	/* Phase 1: validate the target node exists. */
	exists = zodan_local_count(psprintf(
		"SELECT count(*) FROM spock.node WHERE node_name = %s",
		quote_literal_cstr(target_node_name)));
	if (exists == 0)
	{
		SPI_finish();
		ereport(ERROR, (errmsg("node %s does not exist", target_node_name)));
	}

	ZNOTE("Removing node %s from the cluster", target_node_name);

	/* Phase 2/3: drop subscriptions (remote inbound + all local). */
	zodan_remove_subscriptions(target_node_name, verb);
	SPI_commit();

	/* Phase 4: drop replication sets local to the target node. */
	{
		int			i;
		int			nsets;
		char	  **sets;

		if (SPI_execute("SELECT set_name FROM spock.replication_set", true, 0) != SPI_OK_SELECT)
			elog(ERROR, "failed to enumerate replication sets");
		nsets = SPI_processed;
		sets = (char **) palloc0(sizeof(char *) * Max(nsets, 1));
		for (i = 0; i < nsets; i++)
		{
			char	   *nm = SPI_getvalue(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1);

			sets[i] = nm ? pstrdup(nm) : NULL;
		}
		for (i = 0; i < nsets; i++)
		{
			if (sets[i] == NULL)
				continue;
			zodan_local_command(psprintf(
				"SELECT spock.repset_drop(%s, true)", quote_literal_cstr(sets[i])));
			ZVERB(verb, "    OK: dropped replication set %s", sets[i]);
		}
	}
	SPI_commit();

	/* Phase 5: drop the node itself. */
	exists = zodan_local_count(psprintf(
		"SELECT count(*) FROM spock.node WHERE node_name = %s",
		quote_literal_cstr(target_node_name)));
	if (exists > 0)
	{
		zodan_local_command(psprintf(
			"SELECT spock.node_drop(%s, true)", quote_literal_cstr(target_node_name)));
		ZNOTE("    OK: dropped node %s", target_node_name);
	}
	SPI_commit();

	ereport(NOTICE,
			(errmsg("remove_node: node \"%s\" removed from the cluster",
					target_node_name)));

	SPI_finish();
	PG_RETURN_VOID();
}
