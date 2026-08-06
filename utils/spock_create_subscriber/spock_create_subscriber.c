/* -------------------------------------------------------------------------
 *
 * spock_create_subscriber.c
 *		Initialize a new spock subscriber from a physical base backup
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 * -------------------------------------------------------------------------
 */

/* dirent.h on port/win32_msvc expects MAX_PATH to be defined */
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include <dirent.h>
#include <fcntl.h>
#include <locale.h>
#include <pwd.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>

/* Note the order is important for debian here. */
#if !defined(pg_attribute_printf)

/* GCC and XLC support format attributes */
#if defined(__GNUC__) || defined(__IBMC__)
#define pg_attribute_format_arg(a) __attribute__((format_arg(a)))
#define pg_attribute_printf(f,a) __attribute__((format(PG_PRINTF_ATTRIBUTE, f, a)))
#else
#define pg_attribute_format_arg(a)
#define pg_attribute_printf(f,a)
#endif

#endif

#include "libpq-fe.h"
#include "postgres_fe.h"
#include "pqexpbuffer.h"

#include "getopt_long.h"

#include "miscadmin.h"

#include "access/timeline.h"
#include "access/xlog_internal.h"
#include "catalog/pg_control.h"
#include "common/controldata_utils.h"
#include "common/file_utils.h"
#include "common/jsonapi.h"
#include "common/logging.h"
#include "mb/pg_wchar.h"
#include "port.h"

#include "spock_fe.h"

#define MAX_APPLY_DELAY 86400

typedef struct RemoteInfo {
	Oid			nodeid;
	char	   *node_name;
	char	   *sysid;
	char	   *dbname;
	char	   *replication_sets;
	TimeLineID	timeline_id;	/* current TLI, for detecting a data_dir
								 * left over from an already-promoted
								 * earlier attempt (see check_data_dir()) */
} RemoteInfo;

typedef struct PeerNodeInfo
{
	char	   *node_name;
	char	   *dsn;
	char	   *slot_name;          /* from spock.spock_gen_slot_name() */
	char	   *sub_name;           /* "sub_<subscriber>_<peer>" */
	bool		disabled_sub_created;
	bool		slot_created;
	bool		reverse_sub_created;
} PeerNodeInfo;

typedef struct BidirectionalState
{
	bool		enabled;
	int			num_peers;
	PeerNodeInfo *peers;
	int			stall_timeout;      /* default 600s */
	int			max_wait;           /* default 0 = unbounded */
	char	   *source_slot_name;
	char	   *source_origin_name;
	char	   *source_restore_lsn; /* recovery target LSN; consumed by the
									 * disabled-first catchup sub_create */
	char	   *node_dsn;       /* DSN registered via spock.node_create();
								 * the address peers use to connect back to
								 * this node.  Derived from --subscriber-dsn. */
	char	   *node_sysid;     /* n3's system_identifier; lets --cleanup
								 * confirm node_dsn still reaches this node
								 * before dropping subscriptions there. */
	bool		cleanup_mode;
	bool		force_cleanup;      /* --force: also remove the data directory
									 * on --cleanup, not just remote state */
	char	   *manifest_path;
} BidirectionalState;

/*
 * Replication-set / table-membership / sequence state captured from the
 * source's catalog before DROP EXTENSION spock removes it.  Utility-side
 * memory only; never written to the manifest.
 */
typedef struct RepsetCapture
{
	char	   *set_name;
	bool		replicate_insert;
	bool		replicate_update;
	bool		replicate_delete;
	bool		replicate_truncate;
} RepsetCapture;

typedef struct RepsetTableCapture
{
	char	   *set_name;
	char	   *qualified_table;   /* rts.set_reloid::regclass */
	char	   *columns;           /* rts.set_att_list, NULL if all columns */
	char	   *row_filter;        /* pg_get_expr(...), NULL if none */
} RepsetTableCapture;

typedef struct SequenceCapture
{
	char	   *set_name;
	char	   *qualified_seq;
	int64		last_value;
	bool		is_called;
} SequenceCapture;

typedef struct CatalogCapture
{
	RepsetCapture *repsets;
	int			num_repsets;
	RepsetTableCapture *tables;
	int			num_tables;
	SequenceCapture *sequences;
	int			num_sequences;
} CatalogCapture;

typedef enum {
	VERBOSITY_NORMAL,
	VERBOSITY_VERBOSE,
	VERBOSITY_DEBUG
} VerbosityLevelEnum;

static char		   *argv0 = NULL;
static const char  *progname;
static char		   *data_dir = NULL;
static char			pid_file[MAXPGPATH];
static time_t		start_time;
static VerbosityLevelEnum	verbosity = VERBOSITY_NORMAL;

/* defined as static so that die() can close them */
static PGconn		*subscriber_conn = NULL;
static PGconn		*provider_conn = NULL;

static void signal_handler(int sig);
static void usage(void);
static void die(const char *fmt,...)
pg_attribute_printf(1, 2);
static void print_msg(VerbosityLevelEnum level, const char *fmt,...)
pg_attribute_printf(2, 3);
static PGresult *debug_exec(PGconn *conn, const char *query);

static int run_pg_ctl(const char *arg);
static void validate_extra_basebackup_args(const char *args);
static void run_basebackup(const char *provider_connstr, const char *data_dir,
	const char *extra_basebackup_args);
static char *reset_subscriber_sysid(const char *data_dir);
static void run_pg_resetwal(const char *data_dir);
static void wait_postmaster_connection(const char *connstr);
static void wait_primary_connection(const char *connstr, int stall_timeout, int max_wait);
static void wait_postmaster_shutdown(void);

static char *validate_replication_set_input(char *replication_sets);

static void remove_unwanted_data(PGconn *conn);
static void initialize_replication_origin(PGconn *conn, char *origin_name, char *remote_lsn);
static char *create_restore_point(PGconn *conn, char *restore_point_name);
static char *initialize_replication_slot(PGconn *conn, char *dbname,
							char *provider_node_name, char *subscription_name,
							bool drop_slot_if_exists);
static void spock_subscribe(PGconn *conn, char *subscriber_name,
								char *subscriber_dsn,
								char *provider_connstr,
								char *replication_sets,
								int apply_delay,
								bool force_text_transfer);

static RemoteInfo *get_remote_info(PGconn* conn);

static bool extension_exists(PGconn *conn, const char *extname);
static void install_extension(PGconn *conn, const char *extname);

static void ensure_trailing_newline(const char *path);
static void initialize_data_dir(char *data_dir, char *connstr,
					char *postgresql_conf, char *postgresql_auto_conf,
					char *pg_hba_conf, char *extra_basebackup_args);
static bool check_data_dir(char *data_dir, RemoteInfo *remoteinfo);
static void check_reused_data_dir_is_safe(const char *data_dir, RemoteInfo *remoteinfo);

static char *read_sysid(const char *data_dir);

static void WriteRecoveryConf(PQExpBuffer contents);
static void CopyConfFile(char *fromfile, char *tofile, bool append);

static char *get_connstr_dbname(char *connstr);
static char *get_connstr(char *connstr, char *dbname);
static char *PQconninfoParamsToConnstr(const char *const * keywords, const char *const * values);
static void appendPQExpBufferConnstrValue(PQExpBuffer buf, const char *str);

static bool file_exists(const char *path);
static char *expand_tilde(char *path);
static bool is_pg_dir(const char *path);
static void copy_file(char *fromfile, char *tofile, bool append);
static char *find_other_exec_or_die(const char *argv0, const char *target);
static bool postmaster_is_alive(pid_t pid);
static long get_pgpid(void);
static char **get_database_list(char *databases, int *n_databases);
static char *generate_restore_point_name(void);

static int discover_peer_nodes(PGconn *source_conn, const char *source_node_name,
								const char *subscriber_name, const char *dbname,
								PeerNodeInfo **peers_out);
static void check_preconditions(PGconn *source_conn, const char *source_node_name,
								PeerNodeInfo *peers, int num_peers);
static void check_spock_version_at_least_6(PGconn *conn, const char *node_label);
static void check_mesh_edges(PGconn *conn, const char *this_node_name,
							 char **all_names, int total_nodes);
static void check_peer_identity(PGconn *peer_conn, const char *expected_name);
static void check_replication_set_equivalence(PGconn *source_conn,
											  const char *source_node_name,
											  PeerNodeInfo *peers, int num_peers);
static void write_manifest(BidirectionalState *state, const char *subscriber_name,
							const char *dbname, const char *source_dsn);
static bool read_manifest(const char *manifest_path, BidirectionalState *state,
						   char **subscriber_name_out, char **dbname_out,
						   char **source_dsn_out);
static bool cleanup_partial_state(BidirectionalState *state, const char *subscriber_name,
								  const char *dbname, const char *source_dsn,
								  bool force_rm_datadir);
static void stop_postgres_in_data_dir(void);
static bool remove_data_dir_if_forced(bool force);
static bool check_sysid_matches(PGconn *conn, const char *expected_sysid);
static void append_json_string(PQExpBuffer buf, const char *str);

static void check_single_spock_database(PGconn *conn, const char *base_prov_connstr,
										const char *current_dbname);
static void check_no_native_subscriptions(PGconn *conn);
static void capture_catalog_state(PGconn *conn, Oid source_nodeid,
								  CatalogCapture *capture);
static void remove_unwanted_data_bidir(PGconn *conn, CatalogCapture *capture);
static void restore_replication_sets(PGconn *conn, CatalogCapture *capture);
static void verify_replication_sets_restored(PGconn *conn, CatalogCapture *capture);
static void create_catchup_subscription(PGconn *subscriber_conn, const char *source_sub_name,
					const char *source_dsn, const char *replication_sets,
					const char *source_slot_name, const char *source_restore_lsn);
static void create_disabled_peer_subscriptions(PGconn *subscriber_conn, PeerNodeInfo *peers,
					int num_peers, const char *replication_sets);
static char *get_catchup_target_lsn(const char *source_dsn);
static void wait_for_catchup(PGconn *subscriber_conn, const char *source_sub_name,
					const char *source_slot_name, const char *target_lsn,
					int stall_timeout, int max_wait);
static void set_readonly_local(PGconn *conn);
static Oid	get_local_node_id(PGconn *conn);

static PGconn *
connectdb(const char *connstr)
{
	PGconn *conn;

	conn = PQconnectdb(connstr);
	if (PQstatus(conn) != CONNECTION_OK)
		die(_("Connection to database failed: %s, connection string was: %s\n"), PQerrorMessage(conn), connstr);

	return conn;
}

void signal_handler(int sig)
{
	if (sig == SIGINT || sig == SIGTERM)
	{
		die(_("\nCanceling...\n"));
	}
}

/*
 * Append str to buf with JSON string escaping applied, without the
 * surrounding quotes (the caller supplies those).  Control characters
 * below 0x20 are emitted as \uXXXX.  jsonapi.h provides a JSON parser but
 * no encoder, so this is a small local encoder in the same style as
 * src/bin/pg_combinebackup/write_manifest.c.
 */
static void
append_json_string(PQExpBuffer buf, const char *str)
{
	const char *p;

	for (p = str; *p; p++)
	{
		switch (*p)
		{
			case '\b':	appendPQExpBufferStr(buf, "\\b");  break;
			case '\f':	appendPQExpBufferStr(buf, "\\f");  break;
			case '\n':	appendPQExpBufferStr(buf, "\\n");  break;
			case '\r':	appendPQExpBufferStr(buf, "\\r");  break;
			case '\t':	appendPQExpBufferStr(buf, "\\t");  break;
			case '"':	appendPQExpBufferStr(buf, "\\\""); break;
			case '\\':	appendPQExpBufferStr(buf, "\\\\"); break;
			default:
				if ((unsigned char) *p < 0x20)
					appendPQExpBuffer(buf, "\\u%04x", (unsigned char) *p);
				else
					appendPQExpBufferChar(buf, *p);
				break;
		}
	}
}

/*
 * Query the source for all peer nodes in the multi-master cluster.
 * Returns the peer count; *peers_out is set to a pg_malloc0'd array.  For
 * each peer, sub_name is derived as "sub_<subscriber_name>_<peer_name>"
 * and slot_name is obtained via spock.spock_gen_slot_name() on the source.
 */
static int
discover_peer_nodes(PGconn *source_conn, const char *source_node_name,
					const char *subscriber_name, const char *dbname,
					PeerNodeInfo **peers_out)
{
	static const char *discover_sql =
		"SELECT DISTINCT n.node_name, ni.if_dsn"
		" FROM spock.subscription s"
		" JOIN spock.node n ON s.sub_origin = n.node_id"
		" JOIN spock.node_interface ni ON ni.if_id = s.sub_origin_if"
		" WHERE n.node_name != $1"
		" ORDER BY n.node_name";
	const char *paramValues[3];
	PGresult   *res;
	PGresult   *slot_res;
	int			npeers;
	PeerNodeInfo *peers;
	int			i;

	paramValues[0] = source_node_name;
	print_msg(VERBOSITY_DEBUG, _("  > %s [$1=%s]\n"), discover_sql, source_node_name);
	res = PQexecParams(source_conn, discover_sql,
					   1, NULL, paramValues, NULL, NULL, 0);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		die(_("could not discover peer nodes: %s"),
			PQerrorMessage(source_conn));

	npeers = PQntuples(res);
	if (npeers == 0)
	{
		PQclear(res);
		die(_("no peer nodes found; source does not appear to be part of a "
			  "multi-master cluster"));
	}

	peers = pg_malloc0(npeers * sizeof(PeerNodeInfo));

	for (i = 0; i < npeers; i++)
	{
		PQExpBuffer sub_name_buf = createPQExpBuffer();

		peers[i].node_name = pg_strdup(PQgetvalue(res, i, 0));
		peers[i].dsn = pg_strdup(PQgetvalue(res, i, 1));

		appendPQExpBuffer(sub_name_buf, "sub_%s_%s",
						  subscriber_name, peers[i].node_name);
		peers[i].sub_name = pg_strdup(sub_name_buf->data);
		destroyPQExpBuffer(sub_name_buf);

		paramValues[0] = dbname;
		paramValues[1] = peers[i].node_name;
		paramValues[2] = peers[i].sub_name;
		print_msg(VERBOSITY_DEBUG,
				  _("  > SELECT spock.spock_gen_slot_name($1::name, $2::name, "
					"$3::name) [$1=%s, $2=%s, $3=%s]\n"),
				  dbname, peers[i].node_name, peers[i].sub_name);
		slot_res = PQexecParams(source_conn,
								"SELECT spock.spock_gen_slot_name"
								"($1::name, $2::name, $3::name)",
								3, NULL, paramValues, NULL, NULL, 0);
		if (PQresultStatus(slot_res) != PGRES_TUPLES_OK)
			die(_("could not generate slot name for peer \"%s\": %s"),
				peers[i].node_name, PQerrorMessage(source_conn));

		peers[i].slot_name = pg_strdup(PQgetvalue(slot_res, 0, 0));
		PQclear(slot_res);

		print_msg(VERBOSITY_VERBOSE,
				  _("  discovered peer: %s (slot: %s)\n"),
				  peers[i].node_name, peers[i].slot_name);
	}

	PQclear(res);
	*peers_out = peers;
	return npeers;
}

/*
 * Verify Spock version on conn (the source or a peer): an old apply
 * worker would advance the wrong-named origin, so this must be checked
 * everywhere up front, not just on the source.
 */
static void
check_spock_version_at_least_6(PGconn *conn, const char *node_label)
{
	PGresult   *res;

	res = debug_exec(conn, "SELECT extversion FROM pg_extension WHERE extname = 'spock'");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not query Spock extension version on \"%s\": %s"),
			node_label, PQerrorMessage(conn));
	}
	if (PQntuples(res) == 0)
	{
		PQclear(res);
		die(_("Spock extension is not installed on \"%s\""), node_label);
	}
	{
		const char *ver = PQgetvalue(res, 0, 0);
		int			major = 0;

		/*
		 * die() exits immediately -- ver points inside res, so it must
		 * not be PQclear()'d first (that would be a use-after-free when
		 * die()'s own formatting reads ver).
		 */
		if (sscanf(ver, "%d.", &major) < 1)
			die(_("could not parse Spock version \"%s\" on \"%s\""), ver, node_label);
		if (major < 6)
			die(_("Spock version %s on \"%s\" is too old for bidirectional "
				  "join; require >= 6.0.0"), ver, node_label);
	}
	PQclear(res);
}

/*
 * Validate the actual directed subscription graph from one node's own
 * catalog, not just a count: exactly one healthy (status = 'replicating')
 * subscription from every other node in the set, no self-reference, no
 * edge from outside the set, and no duplicate edge from the same origin
 * regardless of status.
 */
static void
check_mesh_edges(PGconn *conn, const char *this_node_name,
				 char **all_names, int total_nodes)
{
	PGresult   *res;
	bool	   *healthy;
	int		   *edge_count;
	int			i;

	/*
	 * spock.sub_show_status() (not raw sub_enabled) so "enabled" also
	 * means "actually replicating" -- a worker that's down or still
	 * initializing must not satisfy the mesh.
	 */
	res = debug_exec(conn, "SELECT provider_node, status FROM spock.sub_show_status()");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not check subscription topology on \"%s\": %s"),
			this_node_name, PQerrorMessage(conn));
	}

	healthy = pg_malloc0(total_nodes * sizeof(bool));
	edge_count = pg_malloc0(total_nodes * sizeof(int));

	for (i = 0; i < PQntuples(res); i++)
	{
		const char *origin_name = PQgetvalue(res, i, 0);
		const char *status = PQgetvalue(res, i, 1);
		int			idx = -1;
		int			k;

		if (strcmp(origin_name, this_node_name) == 0)
			die(_("node \"%s\" has a subscription whose origin is itself; "
				  "corrupt or misconfigured topology"), this_node_name);

		for (k = 0; k < total_nodes; k++)
		{
			if (strcmp(all_names[k], origin_name) == 0)
			{
				idx = k;
				break;
			}
		}
		if (idx == -1)
			die(_("node \"%s\" has a subscription from \"%s\", which is not "
				  "part of the discovered node set; partial-mesh or "
				  "unknown-node topologies are not supported"),
				this_node_name, origin_name);

		/*
		 * Count regardless of status: an extra disabled duplicate from
		 * the same origin is still a duplicate edge.
		 */
		edge_count[idx]++;
		if (edge_count[idx] > 1)
			die(_("node \"%s\" has more than one subscription from \"%s\" "
				  "(status \"%s\"); duplicate edges are not supported"),
				this_node_name, origin_name, status);

		if (strcmp(status, "replicating") == 0)
			healthy[idx] = true;
	}
	PQclear(res);

	for (i = 0; i < total_nodes; i++)
	{
		if (strcmp(all_names[i], this_node_name) == 0)
			continue;		/* skip self */
		if (!healthy[i])
		{
			pg_free(healthy);
			pg_free(edge_count);
			die(_("node \"%s\" has no healthy (status = 'replicating') "
				  "subscription from \"%s\"; full-mesh topology of live "
				  "replication is required for bidirectional join"),
				this_node_name, all_names[i]);
		}
	}
	pg_free(healthy);
	pg_free(edge_count);
}

/*
 * Confirm the peer identifies itself as the name it was discovered
 * under, so a node-name collision or wrong DSN can't silently validate
 * the mesh against the wrong node.
 */
static void
check_peer_identity(PGconn *peer_conn, const char *expected_name)
{
	PGresult   *res;

	res = debug_exec(peer_conn, "SELECT node_name FROM spock.node_info()");
	if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1)
	{
		PQclear(res);
		die(_("could not verify identity of peer \"%s\": %s"),
			expected_name, PQerrorMessage(peer_conn));
	}
	if (strcmp(PQgetvalue(res, 0, 0), expected_name) != 0)
	{
		char *actual_name = pg_strdup(PQgetvalue(res, 0, 0));

		PQclear(res);
		die(_("peer discovered as \"%s\" identifies itself as \"%s\" once "
			  "connected; node-name/identity mismatch, refusing to trust "
			  "this topology\n"), expected_name, actual_name);
	}
	PQclear(res);
}

/*
 * Build a canonical, comparable fingerprint of one replication set as
 * defined by its owning node: operation flags, each member table (sorted,
 * with column list, row filter, and schema), then each member sequence
 * (sorted).  Scoped by node_id since spock.replication_set is keyed
 * UNIQUE(set_nodeid, set_name) -- a set replicated via DDL becomes the
 * replaying node's own row, not an echo.  selected_filter restricts this
 * to sets actually referenced by a subscription's sub_replication_sets,
 * since unused/scratch repsets can legitimately differ between nodes.
 */
typedef struct RepsetFingerprintEntry
{
	char	   *set_name;
	char	   *fingerprint;
} RepsetFingerprintEntry;

static void
compute_repset_fingerprints(PGconn *conn, Oid node_id, const char *selected_filter,
							RepsetFingerprintEntry **out, int *nout)
{
	PGresult   *res;
	RepsetFingerprintEntry *entries;
	int			n;
	int			i;
	PQExpBuffer query = createPQExpBuffer();

	printfPQExpBuffer(query,
					  "SELECT set_name, replicate_insert, replicate_update,"
					  " replicate_delete, replicate_truncate"
					  " FROM spock.replication_set WHERE set_nodeid = %u"
					  " AND (%s)"
					  " ORDER BY set_name", node_id, selected_filter);
	res = debug_exec(conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		destroyPQExpBuffer(query);
		die(_("could not fingerprint replication sets: %s\n"), PQerrorMessage(conn));
	}

	n = PQntuples(res);
	entries = pg_malloc0(n * sizeof(RepsetFingerprintEntry));

	for (i = 0; i < n; i++)
	{
		PQExpBuffer fp = createPQExpBuffer();
		PGresult   *tres;
		PGresult   *sres;
		int			j;

		entries[i].set_name = pg_strdup(PQgetvalue(res, i, 0));
		appendPQExpBuffer(fp, "flags=%s%s%s%s;",
						  PQgetvalue(res, i, 1)[0] == 't' ? "i" : "",
						  PQgetvalue(res, i, 2)[0] == 't' ? "u" : "",
						  PQgetvalue(res, i, 3)[0] == 't' ? "d" : "",
						  PQgetvalue(res, i, 4)[0] == 't' ? "t" : "");

		printfPQExpBuffer(query,
						  "SELECT rts.set_reloid::regclass::text, rts.set_att_list,"
						  " pg_get_expr(rts.set_row_filter, rts.set_reloid)"
						  " FROM spock.replication_set_table rts"
						  " JOIN spock.replication_set rs ON rts.set_id = rs.set_id"
						  " WHERE rs.set_nodeid = %u AND rs.set_name = %s"
						  " ORDER BY rts.set_reloid::regclass::text",
						  node_id,
						  PQescapeLiteral(conn, entries[i].set_name, strlen(entries[i].set_name)));
		tres = debug_exec(conn, query->data);
		if (PQresultStatus(tres) != PGRES_TUPLES_OK)
		{
			PQclear(tres);
			PQclear(res);
			destroyPQExpBuffer(query);
			destroyPQExpBuffer(fp);
			die(_("could not fingerprint table memberships for set \"%s\": %s\n"),
				entries[i].set_name, PQerrorMessage(conn));
		}

		for (j = 0; j < PQntuples(tres); j++)
		{
			const char *qualified_table = PQgetvalue(tres, j, 0);
			PGresult   *cres;
			PQExpBuffer schema_query = createPQExpBuffer();
			int			k;

			appendPQExpBuffer(fp, "tbl=%s|cols=%s|filter=%s|schema=(",
							  qualified_table,
							  PQgetisnull(tres, j, 1) ? "*" : PQgetvalue(tres, j, 1),
							  PQgetisnull(tres, j, 2) ? "-" : PQgetvalue(tres, j, 2));

			/*
			 * Schema fingerprint: relation kind and replica identity,
			 * then per-column name, type, typmod (varchar(10) vs
			 * varchar(100) is otherwise invisible), collation,
			 * nullability, and generated/identity status -- so a
			 * divergent column or relation definition is caught even if
			 * repset membership itself matches.
			 */
			printfPQExpBuffer(schema_query,
							  "SELECT relkind::text, relreplident::text"
							  " FROM pg_class WHERE oid = %s::regclass",
							  PQescapeLiteral(conn, qualified_table, strlen(qualified_table)));
			cres = debug_exec(conn, schema_query->data);
			if (PQresultStatus(cres) != PGRES_TUPLES_OK || PQntuples(cres) != 1)
			{
				PQclear(cres);
				PQclear(tres);
				PQclear(res);
				destroyPQExpBuffer(schema_query);
				destroyPQExpBuffer(query);
				destroyPQExpBuffer(fp);
				die(_("could not fingerprint relation kind of \"%s\": %s\n"),
					qualified_table, PQerrorMessage(conn));
			}
			appendPQExpBuffer(fp, "relkind=%s|replident=%s|",
							  PQgetvalue(cres, 0, 0), PQgetvalue(cres, 0, 1));
			PQclear(cres);

			printfPQExpBuffer(schema_query,
							  "SELECT a.attname, a.atttypid::regtype::text, a.atttypmod,"
							  " a.attnotnull, a.attidentity, a.attgenerated,"
							  " COALESCE(co.collname, '')"
							  " FROM pg_attribute a"
							  " LEFT JOIN pg_collation co ON co.oid = a.attcollation"
							  " WHERE a.attrelid = %s::regclass AND a.attnum > 0"
							  " AND NOT a.attisdropped ORDER BY a.attnum",
							  PQescapeLiteral(conn, qualified_table, strlen(qualified_table)));
			cres = debug_exec(conn, schema_query->data);
			destroyPQExpBuffer(schema_query);
			if (PQresultStatus(cres) != PGRES_TUPLES_OK)
			{
				PQclear(cres);
				PQclear(tres);
				PQclear(res);
				destroyPQExpBuffer(query);
				destroyPQExpBuffer(fp);
				die(_("could not fingerprint schema of \"%s\": %s\n"),
					qualified_table, PQerrorMessage(conn));
			}
			for (k = 0; k < PQntuples(cres); k++)
				appendPQExpBuffer(fp, "%s%s:%s:%s:notnull=%s:ident=%s:gen=%s:coll=%s",
								  k > 0 ? "," : "",
								  PQgetvalue(cres, k, 0),
								  PQgetvalue(cres, k, 1),
								  PQgetvalue(cres, k, 2),
								  PQgetvalue(cres, k, 3),
								  PQgetvalue(cres, k, 4),
								  PQgetvalue(cres, k, 5),
								  PQgetvalue(cres, k, 6));
			appendPQExpBufferStr(fp, ");");
			PQclear(cres);
		}
		PQclear(tres);

		printfPQExpBuffer(query,
						  "SELECT rss.set_seqoid::regclass::text"
						  " FROM spock.replication_set_seq rss"
						  " JOIN spock.replication_set rs ON rss.set_id = rs.set_id"
						  " WHERE rs.set_nodeid = %u AND rs.set_name = %s"
						  " ORDER BY rss.set_seqoid::regclass::text",
						  node_id,
						  PQescapeLiteral(conn, entries[i].set_name, strlen(entries[i].set_name)));
		sres = debug_exec(conn, query->data);
		if (PQresultStatus(sres) != PGRES_TUPLES_OK)
		{
			PQclear(sres);
			PQclear(res);
			destroyPQExpBuffer(query);
			destroyPQExpBuffer(fp);
			die(_("could not fingerprint sequence memberships for set \"%s\": %s\n"),
				entries[i].set_name, PQerrorMessage(conn));
		}
		for (j = 0; j < PQntuples(sres); j++)
			appendPQExpBuffer(fp, "seq=%s;", PQgetvalue(sres, j, 0));
		PQclear(sres);

		entries[i].fingerprint = pg_strdup(fp->data);
		destroyPQExpBuffer(fp);
	}
	PQclear(res);
	destroyPQExpBuffer(query);

	*out = entries;
	*nout = n;
}

static void
free_repset_fingerprints(RepsetFingerprintEntry *entries, int n)
{
	int			i;

	for (i = 0; i < n; i++)
	{
		pg_free(entries[i].set_name);
		pg_free(entries[i].fingerprint);
	}
	pg_free(entries);
}

/*
 * Return a comma-separated list of every replication set actually
 * referenced by conn's own subscriptions (sub_replication_sets), rather
 * than every set that happens to exist locally.  A --bidirectional join
 * uses this to make the joining node inherit the sets already in use by
 * the cluster it's joining, instead of accepting a separately specified
 * list that could diverge from what check_replication_set_equivalence()
 * (just below, via the identical query) validates.  Caller frees the
 * result.
 */
static char *
get_source_mesh_replication_sets(PGconn *conn)
{
	PGresult   *res;
	PQExpBuffer	list;
	char	   *result;
	int			i;

	res = debug_exec(conn,
				 "SELECT DISTINCT s FROM spock.subscription,"
				 " unnest(sub_replication_sets) AS s ORDER BY 1");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not determine the cluster's replication sets: %s\n"),
			PQerrorMessage(conn));
	}
	if (PQntuples(res) == 0)
	{
		PQclear(res);
		die(_("no subscription references any replication set; cannot "
			  "determine which replication sets to use\n"));
	}

	list = createPQExpBuffer();
	for (i = 0; i < PQntuples(res); i++)
		appendPQExpBuffer(list, "%s%s", i > 0 ? "," : "", PQgetvalue(res, i, 0));
	PQclear(res);

	result = pg_strdup(list->data);
	destroyPQExpBuffer(list);
	return result;
}

/*
 * Build a SQL boolean expression ("set_name IN (...)") over the union of
 * every replication set actually referenced by conn's own subscriptions
 * (sub_replication_sets), rather than every set that happens to exist
 * locally.  Caller frees the result.
 */
static char *
build_selected_set_name_filter(PGconn *conn)
{
	PGresult   *res;
	PQExpBuffer	filter;
	char	   *result;
	int			i;

	res = debug_exec(conn,
				 "SELECT DISTINCT s FROM spock.subscription,"
				 " unnest(sub_replication_sets) AS s ORDER BY 1");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not determine selected replication sets: %s\n"), PQerrorMessage(conn));
	}
	if (PQntuples(res) == 0)
	{
		PQclear(res);
		die(_("no subscription references any replication set; cannot "
			  "verify replication-set equivalence\n"));
	}

	filter = createPQExpBuffer();
	appendPQExpBufferStr(filter, "set_name IN (");
	for (i = 0; i < PQntuples(res); i++)
	{
		char *name = PQgetvalue(res, i, 0);

		appendPQExpBuffer(filter, "%s%s", i > 0 ? ", " : "",
						  PQescapeLiteral(conn, name, strlen(name)));
	}
	appendPQExpBufferStr(filter, ")");
	PQclear(res);

	result = pg_strdup(filter->data);
	destroyPQExpBuffer(filter);
	return result;
}

/*
 * The forwarding path (peer -> source -> n3) and the future direct path
 * (peer -> n3) must select exactly the same changes, or a change omitted
 * on one path is lost once the direct subscription takes over.  Compare
 * every selected replication set's fingerprint between the source and
 * each peer; reject any mismatch or missing/extra set on either side.
 */
static void
check_replication_set_equivalence(PGconn *source_conn, const char *source_node_name,
								  PeerNodeInfo *peers, int num_peers)
{
	Oid			source_nodeid = get_local_node_id(source_conn);
	char	   *selected_filter = build_selected_set_name_filter(source_conn);
	RepsetFingerprintEntry *source_fps;
	int			num_source_fps;
	int			i;

	compute_repset_fingerprints(source_conn, source_nodeid, selected_filter,
								&source_fps, &num_source_fps);

	for (i = 0; i < num_peers; i++)
	{
		PGconn	   *peer_conn;
		Oid			peer_nodeid;
		RepsetFingerprintEntry *peer_fps;
		int			num_peer_fps;
		int			j;

		peer_conn = PQconnectdb(peers[i].dsn);
		if (PQstatus(peer_conn) != CONNECTION_OK)
			die(_("cannot connect to peer \"%s\": %s"),
				peers[i].node_name, PQerrorMessage(peer_conn));

		peer_nodeid = get_local_node_id(peer_conn);
		compute_repset_fingerprints(peer_conn, peer_nodeid, selected_filter,
									&peer_fps, &num_peer_fps);

		/*
		 * die() exits immediately, so none of the branches below free
		 * source_fps/peer_fps before calling it -- freeing first and then
		 * still reading source_fps[j]/peer_fps[j] in the same die() call's
		 * arguments would be a use-after-free (the process is about to
		 * exit anyway; nothing else in this file frees before die() either).
		 */
		for (j = 0; j < num_source_fps; j++)
		{
			int			k;
			bool		found = false;

			for (k = 0; k < num_peer_fps; k++)
			{
				if (strcmp(source_fps[j].set_name, peer_fps[k].set_name) != 0)
					continue;
				found = true;
				if (strcmp(source_fps[j].fingerprint, peer_fps[k].fingerprint) != 0)
					die(_("replication set \"%s\" differs between the source "
						  "and peer \"%s\" (membership, flags, columns, row "
						  "filter, or schema) -- the forwarding path and a "
						  "future direct peer subscription would not select "
						  "the same changes, risking permanently lost data "
						  "on cutover. Reconcile the definitions before "
						  "retrying.\n"),
						source_fps[j].set_name, peers[i].node_name);
				break;
			}
			if (!found)
				die(_("replication set \"%s\" exists on the source but not "
					  "on peer \"%s\"\n"), source_fps[j].set_name, peers[i].node_name);
		}
		for (j = 0; j < num_peer_fps; j++)
		{
			int			k;
			bool		found = false;

			for (k = 0; k < num_source_fps; k++)
				if (strcmp(peer_fps[j].set_name, source_fps[k].set_name) == 0)
				{
					found = true;
					break;
				}
			if (!found)
				die(_("replication set \"%s\" exists on peer \"%s\" but not "
					  "on the source\n"), peer_fps[j].set_name, peers[i].node_name);
		}

		free_repset_fingerprints(peer_fps, num_peer_fps);
		PQfinish(peer_conn);
	}

	free_repset_fingerprints(source_fps, num_source_fps);
	pg_free(selected_filter);
	(void) source_node_name;
}

/*
 * Verify that the source cluster and all peers meet the requirements for
 * a bidirectional join: Spock >= 6.0.0 on every node, track_commit_timestamp
 * on, no pending DDL, an actual full-mesh subscription graph (not just a
 * count), replication-set/schema equivalence across the source and every
 * peer, and peer connectivity.
 */
static void
check_preconditions(PGconn *source_conn, const char *source_node_name,
					PeerNodeInfo *peers, int num_peers)
{
	PGresult   *res;
	int			i;
	int			total_nodes = num_peers + 1;
	char	  **all_names = pg_malloc(total_nodes * sizeof(char *));

	all_names[0] = pg_strdup(source_node_name);
	for (i = 0; i < num_peers; i++)
		all_names[i + 1] = pg_strdup(peers[i].node_name);

	check_spock_version_at_least_6(source_conn, "source");

	/* track_commit_timestamp must be on at the source */
	res = debug_exec(source_conn, "SHOW track_commit_timestamp");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		die(_("could not check track_commit_timestamp: %s"),
			PQerrorMessage(source_conn));
	if (strcmp(PQgetvalue(res, 0, 0), "on") != 0)
		die(_("track_commit_timestamp must be on for bidirectional join (source)"));
	PQclear(res);

	/*
	 * All outbound replication caught up to the source's current WAL
	 * position -- i.e. nothing (DDL or data) still in flight to an
	 * existing peer.  spock.queue's row count is not a usable signal here:
	 * queue_message() (spock_queue.c) only ever inserts into it, so its
	 * count is monotonically non-decreasing and is never zero on any node
	 * that has replicated so much as a single DDL statement.
	 */
	res = debug_exec(source_conn,
				 "SELECT COUNT(*) FROM pg_replication_slots"
				 " WHERE slot_type = 'logical' AND plugin = 'spock_output'"
				 " AND (confirmed_flush_lsn IS NULL"
				 "      OR confirmed_flush_lsn < pg_current_wal_lsn())");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		die(_("could not check replication slot lag: %s"),
			PQerrorMessage(source_conn));
	if (strcmp(PQgetvalue(res, 0, 0), "0") != 0)
		die(_("source has unreplicated changes pending to an existing peer; "
			  "wait for replication to drain before joining"));
	PQclear(res);

	/* Full-mesh directed-graph check, from the source's own perspective. */
	check_mesh_edges(source_conn, source_node_name, all_names, total_nodes);

	/*
	 * Per-peer: connectivity, Spock version, track_commit_timestamp, and
	 * the full-mesh directed-graph check from each peer's own perspective
	 * (a mesh that's only complete as seen from the source is not a mesh).
	 */
	for (i = 0; i < num_peers; i++)
	{
		PGconn	   *peer_conn;

		print_msg(VERBOSITY_VERBOSE,
				  _("  checking peer %s ...\n"), peers[i].node_name);

		peer_conn = PQconnectdb(peers[i].dsn);
		if (PQstatus(peer_conn) != CONNECTION_OK)
			die(_("cannot connect to peer \"%s\": %s"),
				peers[i].node_name, PQerrorMessage(peer_conn));

		check_peer_identity(peer_conn, peers[i].node_name);
		check_spock_version_at_least_6(peer_conn, peers[i].node_name);

		res = debug_exec(peer_conn, "SHOW track_commit_timestamp");
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			/*
			 * die() exits immediately -- PQerrorMessage() needs peer_conn
			 * still open, so PQfinish() must not run first (that would be
			 * a use-after-free when die()'s own formatting reads it).
			 */
			PQclear(res);
			die(_("could not check track_commit_timestamp on peer \"%s\": %s"),
				peers[i].node_name, PQerrorMessage(peer_conn));
		}
		if (strcmp(PQgetvalue(res, 0, 0), "on") != 0)
		{
			PQclear(res);
			PQfinish(peer_conn);
			die(_("track_commit_timestamp must be on for bidirectional join "
				  "(peer \"%s\")"), peers[i].node_name);
		}
		PQclear(res);

		check_mesh_edges(peer_conn, peers[i].node_name, all_names, total_nodes);

		PQfinish(peer_conn);
	}

	/* Replication-set & schema equivalence: run once the mesh is sound. */
	check_replication_set_equivalence(source_conn, source_node_name, peers, num_peers);

	for (i = 0; i < total_nodes; i++)
		pg_free(all_names[i]);
	pg_free(all_names);

	print_msg(VERBOSITY_NORMAL, _("Preconditions verified.\n"));
}

/*
 * The physical-backup path runs once per data directory, so it requires
 * exactly one spock-configured database on the source instance.  Checked
 * against actual spock configuration, not --databases/--provider-dsn,
 * since the instance can host other unrelated databases.  Fails closed:
 * any database we cannot inspect aborts the run rather than being
 * treated as spock-free.  datallowconn is not used to skip databases --
 * a database with connections disabled can still hold spock catalog
 * state -- only true templates are excluded.
 */
static void
check_single_spock_database(PGconn *conn, const char *base_prov_connstr,
							const char *current_dbname)
{
	PGresult   *res;
	int			i;
	PQExpBuffer	others = createPQExpBuffer();
	int			other_count = 0;

	res = debug_exec(conn, "SELECT datname FROM pg_database WHERE NOT datistemplate");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not list databases on source: %s\n"), PQerrorMessage(conn));
	}

	for (i = 0; i < PQntuples(res); i++)
	{
		char	   *dbname = PQgetvalue(res, i, 0);
		char	   *db_connstr;
		PGconn	   *db_conn;
		PGresult   *ext_res;
		PGresult   *node_res;

		if (strcmp(dbname, current_dbname) == 0)
			continue;

		db_connstr = get_connstr((char *) base_prov_connstr, dbname);
		db_conn = PQconnectdb(db_connstr);
		if (PQstatus(db_conn) != CONNECTION_OK)
		{
			char *errmsg = pg_strdup(PQerrorMessage(db_conn));

			PQfinish(db_conn);
			PQclear(res);
			die(_("--bidirectional requires proving no other database on the "
				  "source has spock configured, but could not connect to "
				  "\"%s\" to check: %s\n"), dbname, errmsg);
		}

		ext_res = debug_exec(db_conn, "SELECT 1 FROM pg_extension WHERE extname = 'spock'");
		if (PQresultStatus(ext_res) != PGRES_TUPLES_OK)
		{
			char *errmsg = pg_strdup(PQerrorMessage(db_conn));

			PQclear(ext_res);
			PQfinish(db_conn);
			PQclear(res);
			die(_("--bidirectional requires proving no other database on the "
				  "source has spock configured, but could not query \"%s\": "
				  "%s\n"), dbname, errmsg);
		}

		if (PQntuples(ext_res) > 0)
		{
			node_res = debug_exec(db_conn, "SELECT 1 FROM spock.local_node");
			if (PQresultStatus(node_res) != PGRES_TUPLES_OK)
			{
				char *errmsg = pg_strdup(PQerrorMessage(db_conn));

				PQclear(node_res);
				PQclear(ext_res);
				PQfinish(db_conn);
				PQclear(res);
				die(_("--bidirectional requires proving no other database on "
					  "the source has spock configured, but could not query "
					  "spock.local_node in \"%s\": %s\n"), dbname, errmsg);
			}

			if (PQntuples(node_res) > 0)
			{
				appendPQExpBuffer(others, "%s%s", other_count ? ", " : "", dbname);
				other_count++;
			}
			PQclear(node_res);
		}
		PQclear(ext_res);
		PQfinish(db_conn);
	}
	PQclear(res);

	if (other_count > 0)
		die(_("--bidirectional requires exactly one spock-configured database "
			  "on the source instance; also found spock configured on: %s\n"),
			others->data);

	destroyPQExpBuffer(others);
}

/*
 * A physical base backup copies native (non-spock) logical subscriptions
 * too, which DROP EXTENSION spock doesn't touch.  Once n3 is promoted and
 * restarted, an enabled native subscription would start consuming from
 * its provider as a second, unintended consumer.  pg_subscription is a
 * shared catalog, so one query sees every database's rows.
 */
static void
check_no_native_subscriptions(PGconn *conn)
{
	PGresult   *res;

	res = debug_exec(conn,
				 "SELECT s.subname, d.datname"
				 " FROM pg_subscription s"
				 " JOIN pg_database d ON d.oid = s.subdbid"
				 " WHERE s.subenabled");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not check for native logical subscriptions on the "
			  "source instance: %s\n"), PQerrorMessage(conn));
	}

	if (PQntuples(res) > 0)
	{
		PQExpBuffer	list = createPQExpBuffer();
		int			i;

		for (i = 0; i < PQntuples(res); i++)
			appendPQExpBuffer(list, "\n  - %s (database %s)",
							  PQgetvalue(res, i, 0), PQgetvalue(res, i, 1));

		PQclear(res);
		die(_("--bidirectional requires no enabled native (non-spock) logical "
			  "subscriptions anywhere on the source instance -- a physical "
			  "backup would copy them, and they would start consuming on "
			  "the new node as an unintended second consumer once "
			  "promoted: %s\nDisable or drop these subscriptions before "
			  "retrying.\n"), list->data);
	}
	PQclear(res);
}

/*
 * Write the bidirectional state manifest to state->manifest_path
 * atomically (write to .tmp, then rename).  The manifest is a simple
 * hand-formatted JSON file, with string values escaped by
 * append_json_string().
 */
static void
write_manifest(BidirectionalState *state, const char *subscriber_name,
			   const char *dbname, const char *source_dsn)
{
	PQExpBuffer	buf = createPQExpBuffer();
	char		tmp_path[MAXPGPATH];
	int			i;

	snprintf(tmp_path, MAXPGPATH, "%s.tmp", state->manifest_path);

	appendPQExpBufferStr(buf, "{\n");
	appendPQExpBufferStr(buf, "    \"version\": 1,\n");

	appendPQExpBufferStr(buf, "    \"subscriber_name\": \"");
	append_json_string(buf, subscriber_name);
	appendPQExpBufferStr(buf, "\",\n");

	appendPQExpBufferStr(buf, "    \"dbname\": \"");
	append_json_string(buf, dbname);
	appendPQExpBufferStr(buf, "\",\n");

	appendPQExpBufferStr(buf, "    \"source_dsn\": \"");
	append_json_string(buf, source_dsn);
	appendPQExpBufferStr(buf, "\",\n");

	appendPQExpBufferStr(buf, "    \"source_slot_name\": \"");
	if (state->source_slot_name)
		append_json_string(buf, state->source_slot_name);
	appendPQExpBufferStr(buf, "\",\n");

	appendPQExpBufferStr(buf, "    \"source_origin_name\": \"");
	if (state->source_origin_name)
		append_json_string(buf, state->source_origin_name);
	appendPQExpBufferStr(buf, "\",\n");

	appendPQExpBufferStr(buf, "    \"source_restore_lsn\": \"");
	if (state->source_restore_lsn)
		append_json_string(buf, state->source_restore_lsn);
	appendPQExpBufferStr(buf, "\",\n");

	appendPQExpBufferStr(buf, "    \"node_dsn\": \"");
	if (state->node_dsn)
		append_json_string(buf, state->node_dsn);
	appendPQExpBufferStr(buf, "\",\n");

	appendPQExpBufferStr(buf, "    \"node_sysid\": \"");
	if (state->node_sysid)
		append_json_string(buf, state->node_sysid);
	appendPQExpBufferStr(buf, "\",\n");

	appendPQExpBufferStr(buf, "    \"peers\": [\n");
	for (i = 0; i < state->num_peers; i++)
	{
		PeerNodeInfo *p = &state->peers[i];
		bool		 last = (i == state->num_peers - 1);

		appendPQExpBufferStr(buf, "        {\n");

		appendPQExpBufferStr(buf, "            \"node_name\": \"");
		append_json_string(buf, p->node_name);
		appendPQExpBufferStr(buf, "\",\n");

		appendPQExpBufferStr(buf, "            \"peer_dsn\": \"");
		append_json_string(buf, p->dsn);
		appendPQExpBufferStr(buf, "\",\n");

		appendPQExpBufferStr(buf, "            \"sub_name_on_n3\": \"");
		append_json_string(buf, p->sub_name);
		appendPQExpBufferStr(buf, "\",\n");

		appendPQExpBufferStr(buf, "            \"peer_slot_name\": \"");
		append_json_string(buf, p->slot_name);
		appendPQExpBufferStr(buf, "\",\n");

		appendPQExpBuffer(buf, "            \"disabled_sub_created\": %s,\n",
						  p->disabled_sub_created ? "true" : "false");
		appendPQExpBuffer(buf, "            \"slot_created\": %s,\n",
						  p->slot_created ? "true" : "false");
		appendPQExpBuffer(buf, "            \"reverse_sub_created\": %s\n",
						  p->reverse_sub_created ? "true" : "false");

		appendPQExpBufferStr(buf, last ? "        }\n" : "        },\n");
	}
	appendPQExpBufferStr(buf, "    ]\n");
	appendPQExpBufferStr(buf, "}\n");

	/*
	 * The manifest can embed a password (source_dsn, node_dsn), so create
	 * with mode 0600 up front, not a post-hoc chmod.  O_EXCL|O_NOFOLLOW
	 * refuses to write through a pre-existing file or planted symlink,
	 * except a leftover .tmp from a previous crashed run.
	 */
	{
		int			fd;
		ssize_t		written;

		fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
		if (fd < 0 && errno == EEXIST)
		{
			if (unlink(tmp_path) != 0)
				die(_("could not remove stale manifest temp file \"%s\": %s"),
					tmp_path, strerror(errno));
			fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
		}
		if (fd < 0)
			die(_("could not create manifest file \"%s\": %s"),
				tmp_path, strerror(errno));

		written = write(fd, buf->data, buf->len);
		if (written < 0 || (size_t) written != buf->len)
		{
			close(fd);
			unlink(tmp_path);
			die(_("could not write manifest file \"%s\": %s"),
				tmp_path, strerror(errno));
		}

		/*
		 * fsync, rename, then fsync the directory -- a crash right after
		 * this returns must not lose the only cleanup record for the
		 * source slot created just before it.
		 */
		if (fsync(fd) != 0)
		{
			close(fd);
			unlink(tmp_path);
			die(_("could not fsync manifest file \"%s\": %s"),
				tmp_path, strerror(errno));
		}
		if (close(fd) != 0)
		{
			unlink(tmp_path);
			die(_("could not close manifest file \"%s\": %s"),
				tmp_path, strerror(errno));
		}
		if (rename(tmp_path, state->manifest_path) != 0)
			die(_("could not rename manifest to \"%s\": %s"),
				state->manifest_path, strerror(errno));

		/*
		 * fsync_parent_path() already treats "filesystem doesn't support
		 * directory fsync" as success internally, so a nonzero return
		 * here is a genuine failure that can orphan the source slot
		 * after a crash.  Fatal, like the durability steps above.
		 */
		if (fsync_parent_path(state->manifest_path) != 0)
			die(_("could not fsync directory containing \"%s\": %s\n"),
				state->manifest_path, strerror(errno));
	}

	destroyPQExpBuffer(buf);
}

/*
 * Semantic-action state for read_manifest().  Passed as void *semstate to all
 * pg_parse_json callbacks; tracks nesting depth and accumulates field values.
 */
typedef struct ManifestParseState
{
	/* outputs written by scalar callback */
	char	  **subscriber_name_out;
	char	  **dbname_out;
	char	  **source_dsn_out;
	BidirectionalState *bidir;

	/* parser context */
	int			depth;			/* object/array nesting depth */
	bool		in_peers;		/* inside the top-level "peers" array */
	bool		in_peer_obj;	/* inside one peer object */
	char	   *cur_field;		/* current object field name (owned by us) */

	/* per-peer accumulator, flushed on each object_end inside peers */
	char	   *peer_node_name;
	char	   *peer_dsn;
	char	   *peer_sub_name;
	char	   *peer_slot_name;
	bool		peer_disabled_sub_created;
	bool		peer_slot_created;
	bool		peer_reverse_sub_created;
	int			peer_capacity;
} ManifestParseState;

static JsonParseErrorType
manifest_object_start(void *st)
{
	ManifestParseState *s = (ManifestParseState *) st;

	s->depth++;
	if (s->in_peers && s->depth == 3)
		s->in_peer_obj = true;
	return JSON_SUCCESS;
}

static JsonParseErrorType
manifest_object_end(void *st)
{
	ManifestParseState *s = (ManifestParseState *) st;

	if (s->in_peer_obj && s->depth == 3)
	{
		int			i = s->bidir->num_peers;

		if (i >= s->peer_capacity)
		{
			s->peer_capacity = (s->peer_capacity > 0) ? s->peer_capacity * 2 : 4;
			s->bidir->peers = pg_realloc(s->bidir->peers,
										 s->peer_capacity * sizeof(PeerNodeInfo));
		}
		s->bidir->peers[i].node_name = s->peer_node_name;
		s->bidir->peers[i].dsn = s->peer_dsn;
		s->bidir->peers[i].sub_name = s->peer_sub_name;
		s->bidir->peers[i].slot_name = s->peer_slot_name;
		s->bidir->peers[i].disabled_sub_created = s->peer_disabled_sub_created;
		s->bidir->peers[i].slot_created = s->peer_slot_created;
		s->bidir->peers[i].reverse_sub_created = s->peer_reverse_sub_created;
		s->bidir->num_peers++;
		s->peer_node_name = s->peer_dsn = s->peer_sub_name = s->peer_slot_name = NULL;
		s->peer_disabled_sub_created = s->peer_slot_created = s->peer_reverse_sub_created = false;
		s->in_peer_obj = false;
	}
	s->depth--;
	return JSON_SUCCESS;
}

static JsonParseErrorType
manifest_array_start(void *st)
{
	ManifestParseState *s = (ManifestParseState *) st;

	s->depth++;
	if (s->depth == 2 && s->cur_field != NULL &&
		strcmp(s->cur_field, "peers") == 0)
		s->in_peers = true;
	return JSON_SUCCESS;
}

static JsonParseErrorType
manifest_array_end(void *st)
{
	ManifestParseState *s = (ManifestParseState *) st;

	if (s->in_peers && s->depth == 2)
		s->in_peers = false;
	s->depth--;
	return JSON_SUCCESS;
}

static JsonParseErrorType
manifest_ofield_start(void *st, char *fname, bool isnull)
{
	ManifestParseState *s = (ManifestParseState *) st;

	(void) isnull;
	pg_free(s->cur_field);
	s->cur_field = pg_strdup(fname);
	pg_free(fname);				/* callback owns the token */
	return JSON_SUCCESS;
}

static JsonParseErrorType
manifest_scalar(void *st, char *token, JsonTokenType tokentype)
{
	ManifestParseState *s = (ManifestParseState *) st;

	if (s->cur_field == NULL)
	{
		pg_free(token);
		return JSON_SUCCESS;
	}

	/*
	 * Per-peer creation-state flags are JSON booleans, not strings --
	 * handle them before the string-only fields below (which free and
	 * ignore anything that isn't JSON_TOKEN_STRING).
	 */
	if (s->in_peer_obj && tokentype != JSON_TOKEN_STRING)
	{
		bool	value = (tokentype == JSON_TOKEN_TRUE);

		if (strcmp(s->cur_field, "disabled_sub_created") == 0)
			s->peer_disabled_sub_created = value;
		else if (strcmp(s->cur_field, "slot_created") == 0)
			s->peer_slot_created = value;
		else if (strcmp(s->cur_field, "reverse_sub_created") == 0)
			s->peer_reverse_sub_created = value;
		pg_free(token);
		return JSON_SUCCESS;
	}

	if (tokentype != JSON_TOKEN_STRING)
	{
		pg_free(token);
		return JSON_SUCCESS;
	}

	if (!s->in_peer_obj)
	{
		/* top-level scalar fields */
		if (strcmp(s->cur_field, "subscriber_name") == 0)
			*s->subscriber_name_out = token;
		else if (strcmp(s->cur_field, "dbname") == 0)
			*s->dbname_out = token;
		else if (strcmp(s->cur_field, "source_dsn") == 0)
			*s->source_dsn_out = token;
		else if (strcmp(s->cur_field, "source_slot_name") == 0)
			s->bidir->source_slot_name = token;
		else if (strcmp(s->cur_field, "source_origin_name") == 0)
			s->bidir->source_origin_name = token;
		else if (strcmp(s->cur_field, "source_restore_lsn") == 0)
			s->bidir->source_restore_lsn = token;
		else if (strcmp(s->cur_field, "node_dsn") == 0)
			s->bidir->node_dsn = token;
		else if (strcmp(s->cur_field, "node_sysid") == 0)
			s->bidir->node_sysid = token;
		else
			pg_free(token);
	}
	else
	{
		/* per-peer scalar fields */
		if (strcmp(s->cur_field, "node_name") == 0)
			s->peer_node_name = token;
		else if (strcmp(s->cur_field, "peer_dsn") == 0)
			s->peer_dsn = token;
		else if (strcmp(s->cur_field, "sub_name_on_n3") == 0)
			s->peer_sub_name = token;
		else if (strcmp(s->cur_field, "peer_slot_name") == 0)
			s->peer_slot_name = token;
		else
			pg_free(token);
	}
	return JSON_SUCCESS;
}

/*
 * Read the bidirectional manifest from manifest_path.  Returns false if
 * the file does not exist (nothing to clean up); dies if it exists but
 * cannot be read or is malformed.  On success, sets *subscriber_name_out,
 * *dbname_out, *source_dsn_out, and populates state->peers[].
 *
 * Uses pg_parse_json (common/jsonapi.h) for JSON lexing, so string
 * quoting, escape sequences, and nesting are handled correctly.
 */
static bool
read_manifest(const char *manifest_path, BidirectionalState *state,
			  char **subscriber_name_out, char **dbname_out,
			  char **source_dsn_out)
{
	struct stat			st;
	char			   *content;
	FILE			   *f;
	JsonLexContext	   *lex;
	JsonSemAction		sem;
	ManifestParseState	pstate;
	JsonParseErrorType	result;

	if (stat(manifest_path, &st) != 0)
		return false;

	content = pg_malloc(st.st_size + 1);
	f = fopen(manifest_path, "r");
	if (f == NULL)
		die(_("could not open manifest file \"%s\": %s"),
			manifest_path, strerror(errno));

	if ((size_t) fread(content, 1, st.st_size, f) != (size_t) st.st_size)
	{
		fclose(f);
		die(_("could not read manifest file \"%s\": %s"),
			manifest_path, strerror(errno));
	}
	content[st.st_size] = '\0';
	fclose(f);

	memset(&pstate, 0, sizeof(pstate));
	pstate.subscriber_name_out = subscriber_name_out;
	pstate.dbname_out = dbname_out;
	pstate.source_dsn_out = source_dsn_out;
	pstate.bidir = state;

	memset(&sem, 0, sizeof(sem));
	sem.semstate = &pstate;
	sem.object_start = manifest_object_start;
	sem.object_end = manifest_object_end;
	sem.array_start = manifest_array_start;
	sem.array_end = manifest_array_end;
	sem.object_field_start = manifest_ofield_start;
	sem.scalar = manifest_scalar;

	lex = makeJsonLexContextCstringLen(NULL, content, st.st_size,
									  PG_UTF8, true);
	result = pg_parse_json(lex, &sem);
	pg_free(content);
	pg_free(pstate.cur_field);

	if (result != JSON_SUCCESS)
	{
		char *detail = json_errdetail(result, lex);

		freeJsonLexContext(lex);
		die(_("manifest file \"%s\" is malformed: %s"), manifest_path, detail);
	}
	freeJsonLexContext(lex);

	if (!*subscriber_name_out || !*dbname_out || !*source_dsn_out)
		die(_("manifest file \"%s\" is malformed or missing required fields"),
			manifest_path);

	return true;
}

/*
 * If data_dir holds a running postmaster, stop it (fast mode) and wait
 * for shutdown.  No-op if data_dir is unset, doesn't exist, or has no
 * postmaster.pid.
 */
static void
stop_postgres_in_data_dir(void)
{
	struct stat	st;

	if (data_dir == NULL || !data_dir[0] || !file_exists(data_dir))
		return;

	snprintf(pid_file, MAXPGPATH, "%s/postmaster.pid", data_dir);
	if (stat(pid_file, &st) == 0)
	{
		print_msg(VERBOSITY_NORMAL,
				  _("  stopping postgres in %s ...\n"), data_dir);
		run_pg_ctl("stop -m fast");
		wait_postmaster_shutdown();
	}
}

/*
 * If data_dir exists, remove it when force is true (stopping postgres in
 * it first, defensively, in case the caller hasn't already); if force is
 * false, leave it in place with a hint.  Returns false only when removal
 * was attempted and actually failed; a missing data_dir, an unset one,
 * or force being false are all "nothing to report" and return true.
 */
static bool
remove_data_dir_if_forced(bool force)
{
	if (data_dir == NULL || !data_dir[0] || !file_exists(data_dir))
		return true;

	if (!force)
	{
		print_msg(VERBOSITY_NORMAL,
				  _("  data directory %s was left in place; pass --force "
					"to remove it, or clean it up manually.\n"), data_dir);
		return true;
	}

	stop_postgres_in_data_dir();

	print_msg(VERBOSITY_NORMAL,
			  _("  removing data directory %s ...\n"), data_dir);
	if (!rmtree(data_dir, true))
	{
		print_msg(VERBOSITY_NORMAL,
				  _("warning: could not fully remove data directory "
					"%s; remove it manually\n"), data_dir);
		return false;
	}

	return true;
}

/*
 * Check whether conn's system_identifier (from pg_control_system())
 * matches expected_sysid.  Any failure to confirm -- query error, no
 * row, or an outright mismatch -- returns false.
 */
static bool
check_sysid_matches(PGconn *conn, const char *expected_sysid)
{
	PGresult   *res;
	bool		matches;

	res = debug_exec(conn, "SELECT system_identifier FROM pg_control_system()");
	if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1)
	{
		PQclear(res);
		return false;
	}
	matches = strcmp(PQgetvalue(res, 0, 0), expected_sysid) == 0;
	PQclear(res);
	return matches;
}

/*
 * Idempotently remove bidirectional join state from all reachable nodes.
 * Connects to the subscriber (n3) itself, the source, and each peer;
 * drops n3's own catchup/disabled-peer subscriptions, replication slots,
 * and reverse subscriptions created during a previous join attempt.
 * spock.sub_drop() on n3 kills that subscription's local apply worker and
 * drops the matching remote slot on its origin itself, so n3 never needs
 * to be stopped just to release a slot it holds open elsewhere.
 * Connectivity and drop failures are logged as warnings, not fatal, so
 * cleanup attempts every remaining resource -- but each failure is
 * tracked, and the function returns true only if every recorded resource
 * was confirmed gone.  The manifest/sidecar record (the only way to
 * retry) is removed only on a true return; an incomplete cleanup keeps
 * it and the caller exits non-zero.
 */
static bool
cleanup_partial_state(BidirectionalState *state, const char *subscriber_name,
					  const char *dbname, const char *source_dsn,
					  bool force_rm_datadir)
{
	PGconn	   *source_conn;
	PGconn	   *n3_conn;
	PGresult   *res;
	PQExpBuffer	query = createPQExpBuffer();
	int			i;
	bool		fully_cleaned = true;

	print_msg(VERBOSITY_NORMAL,
			  _("Cleaning up partial bidirectional join state ...\n"));

	/*
	 * Drop any subscriptions this run created on n3 itself: the catchup
	 * subscription to the source and any disabled peer subscriptions.  A
	 * freshly-provisioned n3 has no other legitimate spock.subscription
	 * rows, so it's safe to drop everything found -- but only once
	 * node_sysid confirms node_dsn still reaches that same n3, since a
	 * manifest can outlive the node it describes (DNS change, load
	 * balancer, reused port).  node_dsn is only set once node_create()
	 * has run, so its absence just means there's nothing on n3 yet.
	 */
	if (state->node_dsn && state->node_dsn[0])
	{
		n3_conn = PQconnectdb(state->node_dsn);
		if (PQstatus(n3_conn) != CONNECTION_OK)
		{
			print_msg(VERBOSITY_NORMAL,
					  _("warning: cannot connect to subscriber \"%s\"; its "
						"subscription(s) may still exist: %s\n"),
					  subscriber_name, PQerrorMessage(n3_conn));
			fully_cleaned = false;
			PQfinish(n3_conn);
		}
		else if (!state->node_sysid || !state->node_sysid[0] ||
				 !check_sysid_matches(n3_conn, state->node_sysid))
		{
			print_msg(VERBOSITY_NORMAL,
					  _("warning: node_dsn for subscriber \"%s\" cannot be "
						"confirmed to still identify the node this run "
						"created (missing or mismatched system identifier); "
						"refusing to drop subscriptions there. Investigate "
						"manually.\n"), subscriber_name);
			fully_cleaned = false;
			PQfinish(n3_conn);
		}
		else
		{
			res = debug_exec(n3_conn, "SELECT sub_name FROM spock.subscription");
			if (PQresultStatus(res) == PGRES_TUPLES_OK)
			{
				for (i = 0; i < PQntuples(res); i++)
				{
					char	   *sub_name = PQgetvalue(res, i, 0);
					PGresult   *drop_res;

					printfPQExpBuffer(query, "SELECT spock.sub_drop(%s, true)",
									  PQescapeLiteral(n3_conn, sub_name, strlen(sub_name)));
					drop_res = debug_exec(n3_conn, query->data);
					if (PQresultStatus(drop_res) == PGRES_TUPLES_OK)
						print_msg(VERBOSITY_NORMAL,
								  _("  dropped subscriber subscription %s\n"),
								  sub_name);
					else
					{
						print_msg(VERBOSITY_NORMAL,
								  _("warning: could not drop subscriber "
									"subscription %s: %s\n"),
								  sub_name, PQerrorMessage(n3_conn));
						fully_cleaned = false;
					}
					PQclear(drop_res);
				}
			}
			else
			{
				print_msg(VERBOSITY_NORMAL,
						  _("warning: could not list subscriptions on "
							"subscriber \"%s\": %s\n"),
						  subscriber_name, PQerrorMessage(n3_conn));
				fully_cleaned = false;
			}
			PQclear(res);
			PQfinish(n3_conn);
		}
	}

	/*
	 * Stop n3's postmaster unconditionally (not gated by --force, which
	 * only governs removing the data directory).  check_data_dir() and
	 * check_reused_data_dir_is_safe() explicitly support resuming a join
	 * into this same data_dir after a failed attempt, and that resume
	 * path (main(), the "start -l ..." pg_ctl call before catchup) assumes
	 * postgres is not already running here; leaving it up after
	 * `--cleanup` would make the very next retry fail outright.  The
	 * subscription drops above already ran while n3 was still reachable,
	 * so this is just shutdown, not a substitute for them.
	 */
	stop_postgres_in_data_dir();

	source_conn = PQconnectdb(source_dsn);
	if (PQstatus(source_conn) != CONNECTION_OK)
	{
		if (state->source_slot_name && state->source_slot_name[0])
		{
			print_msg(VERBOSITY_NORMAL,
					  _("warning: cannot connect to source node; slot %s "
						"may still exist: %s\n"),
					  state->source_slot_name, PQerrorMessage(source_conn));
			fully_cleaned = false;
		}
		PQfinish(source_conn);
		source_conn = NULL;
	}

	/* Drop source replication slot if it was created */
	if (source_conn && state->source_slot_name && state->source_slot_name[0])
	{
		printfPQExpBuffer(query,
						  "SELECT pg_drop_replication_slot(slot_name)"
						  " FROM pg_replication_slots"
						  " WHERE slot_name = '%s'",
						  state->source_slot_name);
		res = debug_exec(source_conn, query->data);
		if (PQresultStatus(res) == PGRES_TUPLES_OK)
		{
			if (PQntuples(res) > 0)
				print_msg(VERBOSITY_NORMAL,
						  _("  dropped source slot %s\n"),
						  state->source_slot_name);
		}
		else
		{
			print_msg(VERBOSITY_NORMAL,
					  _("warning: could not drop source slot %s: %s\n"),
					  state->source_slot_name, PQerrorMessage(source_conn));
			fully_cleaned = false;
		}
		PQclear(res);
	}

	/* Per-peer: drop slot and any reverse subscription */
	for (i = 0; i < state->num_peers; i++)
	{
		PeerNodeInfo *peer = &state->peers[i];
		PGconn	   *peer_conn;
		char		reverse_sub[NAMEDATALEN];

		if (!peer->dsn || !peer->dsn[0])
			continue;

		/*
		 * Only attempt to drop -- and only require connectivity for --
		 * resources this run actually recorded as created.  Slot/sub names
		 * are deterministic, not per-run unique, so --cleanup must not
		 * touch a same-named resource from an unrelated join, nor report
		 * "incomplete" over a peer that was never touched.
		 */
		if (!peer->slot_created && !peer->reverse_sub_created)
			continue;

		peer_conn = PQconnectdb(peer->dsn);
		if (PQstatus(peer_conn) != CONNECTION_OK)
		{
			print_msg(VERBOSITY_NORMAL,
					  _("warning: cannot connect to peer \"%s\"; its slot/"
						"subscription may still exist: %s\n"),
					  peer->node_name, PQerrorMessage(peer_conn));
			fully_cleaned = false;
			PQfinish(peer_conn);
			continue;
		}

		if (peer->slot_created && peer->slot_name && peer->slot_name[0])
		{
			printfPQExpBuffer(query,
							  "SELECT pg_drop_replication_slot(slot_name)"
							  " FROM pg_replication_slots"
							  " WHERE slot_name = '%s'",
							  peer->slot_name);
			res = debug_exec(peer_conn, query->data);
			if (PQresultStatus(res) == PGRES_TUPLES_OK)
			{
				if (PQntuples(res) > 0)
					print_msg(VERBOSITY_NORMAL,
							  _("  dropped peer slot %s on %s\n"),
							  peer->slot_name, peer->node_name);
			}
			else
			{
				print_msg(VERBOSITY_NORMAL,
						  _("warning: could not drop peer slot %s on %s: %s\n"),
						  peer->slot_name, peer->node_name,
						  PQerrorMessage(peer_conn));
				fully_cleaned = false;
			}
			PQclear(res);
		}

		/*
		 * Drop the reverse subscription (peer -> new subscriber) only if
		 * this run recorded having created it.  The sub_drop second
		 * argument is ifexists=true, so an absent subscription is not an
		 * error -- only an actual query failure counts against
		 * fully_cleaned.
		 */
		if (peer->reverse_sub_created)
		{
			snprintf(reverse_sub, sizeof(reverse_sub), "sub_%s_%s",
					 peer->node_name, subscriber_name);
			printfPQExpBuffer(query,
							  "SELECT spock.sub_drop(%s, true)",
							  PQescapeLiteral(peer_conn, reverse_sub, strlen(reverse_sub)));
			res = debug_exec(peer_conn, query->data);
			if (PQresultStatus(res) != PGRES_TUPLES_OK)
			{
				print_msg(VERBOSITY_NORMAL,
						  _("warning: could not drop reverse subscription %s on "
							"%s: %s\n"),
						  reverse_sub, peer->node_name, PQerrorMessage(peer_conn));
				fully_cleaned = false;
			}
			PQclear(res);
		}

		PQfinish(peer_conn);
		print_msg(VERBOSITY_NORMAL,
				  _("  cleaned up peer %s\n"), peer->node_name);
	}

	if (source_conn)
		PQfinish(source_conn);

	destroyPQExpBuffer(query);

	/*
	 * The data directory a partial run may have created via basebackup.
	 * Never touch it without --force.
	 */
	if (!remove_data_dir_if_forced(force_rm_datadir))
		fully_cleaned = false;

	if (!fully_cleaned)
	{
		print_msg(VERBOSITY_NORMAL,
				  _("Cleanup incomplete: some resource(s) above could not be "
					"confirmed removed. Keeping the manifest/sidecar record "
					"so --cleanup can be retried.\n"));
		return false;
	}

	/*
	 * Every remote/local resource above was confirmed gone; now remove the
	 * retry record(s) themselves.  An unexpected removal failure here
	 * (anything but ENOENT, i.e. already gone) must also flip
	 * fully_cleaned -- otherwise the caller reports success and exits 0
	 * while a stale record that still references now-removed resources
	 * lingers on disk, which a later --cleanup could misread as current.
	 */
	if (state->manifest_path && state->manifest_path[0])
	{
		if (unlink(state->manifest_path) == 0)
			print_msg(VERBOSITY_NORMAL,
					  _("  removed manifest %s\n"), state->manifest_path);
		else if (errno != ENOENT)
		{
			print_msg(VERBOSITY_NORMAL,
					  _("warning: could not remove manifest %s: %s\n"),
					  state->manifest_path, strerror(errno));
			fully_cleaned = false;
		}
	}

	/*
	 * Also remove any pending-cleanup sidecar, even if it wasn't the file
	 * that drove this cleanup: a stale one left behind by an earlier run
	 * whose own sidecar-unlink failed could otherwise be misread as
	 * current by a later --cleanup once the manifest above is gone,
	 * reporting resources as still-pending that were, in fact, already
	 * confirmed removed here.
	 */
	if (data_dir != NULL && data_dir[0])
	{
		char	sidecar_path[MAXPGPATH];

		snprintf(sidecar_path, MAXPGPATH, "%s.spock_bidir_pending.json", data_dir);
		if (unlink(sidecar_path) == 0)
			print_msg(VERBOSITY_NORMAL,
					  _("  removed pending sidecar %s\n"), sidecar_path);
		else if (errno != ENOENT)
		{
			print_msg(VERBOSITY_NORMAL,
					  _("warning: could not remove pending sidecar %s: %s\n"),
					  sidecar_path, strerror(errno));
			fully_cleaned = false;
		}
	}

	if (!fully_cleaned)
	{
		print_msg(VERBOSITY_NORMAL,
				  _("Cleanup incomplete: the manifest or sidecar record could "
					"not be removed even though every resource it tracked "
					"was confirmed gone. Retry --cleanup to remove the "
					"stale record.\n"));
		return false;
	}

	print_msg(VERBOSITY_NORMAL, _("Cleanup complete.\n"));
	return true;
}


int
main(int argc, char **argv)
{
	int	i;
	int	c;
	PQExpBuffer recoveryconfcontents = createPQExpBuffer();
	RemoteInfo *remote_info;
	char	   *remote_lsn;
	bool		stop = false;
	bool		drop_slot_if_exists = false;
	int			optindex;
	char	   *subscriber_name = NULL;
	char	   *base_sub_connstr = NULL;
	char	   *base_prov_connstr = NULL;
	char	   *replication_sets = NULL;
	char       *databases = NULL;
	char	   *postgresql_conf = NULL,
			   *postgresql_auto_conf = NULL,
			   *pg_hba_conf = NULL,
			   *recovery_conf = NULL;
	int			apply_delay = 0;
	bool		force_text_transfer = false;
	char	  **slot_names;
	char       *sub_connstr;
	char       *prov_connstr;
	char      **database_list = { NULL };
	int         n_databases = 1;
	int         dbnum;
	bool		use_existing_data_dir = false;
	int			pg_ctl_ret,
				logfd;
	char	   *restore_point_name = NULL;
	char	   *extra_basebackup_args = NULL;
	BidirectionalState bidir = {0};
	char		bidir_manifest_path[MAXPGPATH] = {0};
	char		bidir_pending_path[MAXPGPATH] = {0};
	CatalogCapture capture = {0};

	static struct option long_options[] = {
		{"subscriber-name", required_argument, NULL, 'n'},
		{"pgdata", required_argument, NULL, 'D'},
		{"provider-dsn", required_argument, NULL, 1},
		{"subscriber-dsn", required_argument, NULL, 2},
		{"replication-sets", required_argument, NULL, 3},
		{"postgresql-conf", required_argument, NULL, 4},
		{"hba-conf", required_argument, NULL, 5},
		{"recovery-conf", required_argument, NULL, 6},
		{"stop", no_argument, NULL, 's'},
		{"drop-slot-if-exists", no_argument, NULL, 7},
		{"apply-delay", required_argument, NULL, 8},
		{"databases", required_argument, NULL, 9},
		{"extra-basebackup-args", required_argument, NULL, 10},
		{"text-types", no_argument, NULL, 11},
		{"bidirectional", no_argument, NULL, 12},
		{"stall-timeout", required_argument, NULL, 13},
		{"max-wait", required_argument, NULL, 14},
		{"cleanup", no_argument, NULL, 15},
		{"force", no_argument, NULL, 16},
		{"postgresql-auto-conf", required_argument, NULL, 17},
		{NULL, 0, NULL, 0}
	};

	argv0 = argv[0];
	progname = get_progname(argv[0]);
	pg_logging_init(argv[0]);
	start_time = time(NULL);
	signal(SIGINT, signal_handler);
	signal(SIGTERM, signal_handler);

	/* check for --help */
	if (argc > 1)
	{
		for (i = 1; i < argc; i++)
		{
			if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-?") == 0)
			{
				usage();
				exit(0);
			}
		}
	}

	/* Option parsing and validation */
	while ((c = getopt_long(argc, argv, "D:n:sv", long_options, &optindex)) != -1)
	{
		switch (c)
		{
			case 'D':
				data_dir = expand_tilde(pg_strdup(optarg));
				break;
			case 'n':
				subscriber_name = pg_strdup(optarg);
				break;
			case 1:
				base_prov_connstr = pg_strdup(optarg);
				break;
			case 2:
				base_sub_connstr = pg_strdup(optarg);
				break;
			case 3:
				replication_sets = validate_replication_set_input(pg_strdup(optarg));
				break;
			case 4:
				{
					postgresql_conf = expand_tilde(pg_strdup(optarg));
					if (postgresql_conf != NULL && !file_exists(postgresql_conf))
						die(_("The specified postgresql.conf file does not exist."));
					break;
				}
			case 5:
				{
					pg_hba_conf = expand_tilde(pg_strdup(optarg));
					if (pg_hba_conf != NULL && !file_exists(pg_hba_conf))
						die(_("The specified pg_hba.conf file does not exist."));
					break;
				}
			case 6:
				{
					recovery_conf = expand_tilde(pg_strdup(optarg));
					if (recovery_conf != NULL && !file_exists(recovery_conf))
						die(_("The specified recovery configuration file does not exist."));
					break;
				}
			case 'v':
				verbosity++;
				break;
			case 's':
				stop = true;
				break;
			case 7:
				drop_slot_if_exists = true;
				break;
			case 8:
				{
					char *endptr;
					apply_delay = (int) strtol(optarg, &endptr, 10);
					if (*endptr != '\0' || endptr == optarg)
						die(_("--apply-delay requires an integer value\n"));
				}
				break;
			case 9:
				databases = pg_strdup(optarg);
				break;
			case 10:
				extra_basebackup_args = pg_strdup(optarg);
				validate_extra_basebackup_args(extra_basebackup_args);
				break;
			case 11:
				force_text_transfer = true;
				break;
			case 12:
				bidir.enabled = true;
				break;
			case 13:
				bidir.stall_timeout = atoi(optarg);
				if (bidir.stall_timeout <= 0)
					die(_("--stall-timeout must be a positive integer"));
				break;
			case 14:
				bidir.max_wait = atoi(optarg);
				if (bidir.max_wait < 0)
					die(_("--max-wait must be a non-negative integer"));
				break;
			case 15:
				bidir.cleanup_mode = true;
				break;
			case 16:
				bidir.force_cleanup = true;
				break;
			case 17:
				{
					postgresql_auto_conf = expand_tilde(pg_strdup(optarg));
					if (postgresql_auto_conf != NULL && !file_exists(postgresql_auto_conf))
						die(_("The specified postgresql.auto.conf file does not exist."));
					break;
				}
			default:
				fprintf(stderr, _("Unknown option\n"));
				fprintf(stderr, _("Try \"%s --help\" for more information.\n"), progname);
				exit(1);
		}
	}

	/*
	 * Sanity checks
	 */

	if (data_dir == NULL)
	{
		fprintf(stderr, _("No data directory specified\n"));
		fprintf(stderr, _("Try \"%s --help\" for more information.\n"), progname);
		exit(1);
	}
	else if (subscriber_name == NULL && !bidir.cleanup_mode)
	{
		fprintf(stderr, _("No subscriber name specified\n"));
		fprintf(stderr, _("Try \"%s --help\" for more information.\n"), progname);
		exit(1);
	}

	if (bidir.cleanup_mode && !bidir.enabled)
		die(_("--cleanup requires --bidirectional.\n"));

	if (bidir.force_cleanup && !bidir.cleanup_mode)
		die(_("--force requires --cleanup.\n"));

	if (!bidir.cleanup_mode && (!base_prov_connstr || !strlen(base_prov_connstr)))
		die(_("Provider connection string must be specified.\n"));
	if (!bidir.cleanup_mode &&
		(!base_sub_connstr || !strlen(base_sub_connstr)))
		die(_("Subscriber connection string must be specified: --subscriber-dsn "
			  "is used both for the tool's own connection to the newly "
			  "created node and, with --bidirectional, as the externally-"
			  "reachable address registered via spock.node_create() for "
			  "peers to connect back to it.\n"));

	if (apply_delay < 0)
		die(_("Apply delay cannot be negative.\n"));

	if (apply_delay > MAX_APPLY_DELAY)
		die(_("Apply delay cannot be more than %d.\n"), MAX_APPLY_DELAY);

	if (bidir.enabled)
	{
		/*
		 * n3 is joining an existing mesh, so its subscriptions must select
		 * exactly what the mesh already replicates; replication_sets is
		 * derived from the source's own subscriptions below instead.
		 */
		if (replication_sets != NULL)
			die(_("--replication-sets cannot be combined with --bidirectional; "
				  "the joining node's replication sets are detected "
				  "automatically from the cluster it is joining.\n"));
	}
	else if (!replication_sets || !strlen(replication_sets))
		replication_sets = "default,default_insert_only,ddl_sql";

	/* Build the manifest path from --pgdata */
	if (bidir.enabled || bidir.cleanup_mode)
	{
		snprintf(bidir_manifest_path, MAXPGPATH,
				 "%s/spock_bidirectional_manifest.json", data_dir);
		bidir.manifest_path = bidir_manifest_path;
		/*
		 * Sidecar path for the source slot orphan-protection record (see
		 * the write near source-slot creation below) -- lives next to, not
		 * inside, data_dir, since data_dir must still be empty when this is
		 * first written (pg_basebackup requires an empty target directory).
		 */
		snprintf(bidir_pending_path, MAXPGPATH,
				 "%s.spock_bidir_pending.json", data_dir);
		if (bidir.stall_timeout == 0)
			bidir.stall_timeout = 600;
	}

	/* --cleanup: read manifest, remove partial state, exit */
	if (bidir.cleanup_mode)
	{
		char *sub_name = NULL;
		char *db = NULL;
		char *src_dsn = NULL;

		if (read_manifest(bidir.manifest_path, &bidir, &sub_name, &db, &src_dsn))
			exit(cleanup_partial_state(&bidir, sub_name, db, src_dsn,
										bidir.force_cleanup) ? 0 : 1);

		/*
		 * No full manifest -- basebackup may never have completed.  Fall
		 * back to the pending-cleanup sidecar written right after source
		 * slot creation, so a slot orphaned by a failed/interrupted backup
		 * is still reachable by --cleanup.
		 */
		if (read_manifest(bidir_pending_path, &bidir, &sub_name, &db, &src_dsn))
			/* cleanup_partial_state() removes the sidecar itself on success. */
			exit(cleanup_partial_state(&bidir, sub_name, db, src_dsn,
										bidir.force_cleanup) ? 0 : 1);

		/*
		 * Neither record exists -- there's no slot/subscription bookkeeping
		 * to act on, e.g. because the run died before the pending sidecar
		 * was even written.  But an orphaned data_dir can still be sitting
		 * there from that attempt, and --force is an explicit instruction
		 * to remove it: don't leave it behind just because there was
		 * nothing to read.
		 */
		if (bidir.force_cleanup && data_dir != NULL && data_dir[0] &&
			file_exists(data_dir))
		{
			fprintf(stderr,
					_("No manifest found at %s or %s; no slot/subscription "
					  "state to clean up, but --force was given -- removing "
					  "data directory %s.\n"),
					bidir.manifest_path, bidir_pending_path, data_dir);
			exit(remove_data_dir_if_forced(true) ? 0 : 1);
		}

		fprintf(stderr, _("No manifest found at %s or %s; nothing to clean up.\n"),
				bidir.manifest_path, bidir_pending_path);
		exit(0);
	}

	/* Init random numbers used for slot suffixes, etc */
	srand(time(NULL));

	/* Parse database list or connection string. */
	if (databases != NULL)
	{
		database_list = get_database_list(databases, &n_databases);
	}
	else
	{
		char *dbname = get_connstr_dbname(base_prov_connstr);

		if (!dbname)
			die(_("Either provider connection string must contain database "
				  "name or --databases option must be specified.\n"));

		n_databases = 1;
		database_list = palloc(n_databases * sizeof(char *));
		database_list[0] = dbname;
	}

	/*
	 * Single database only: all join state is per-database, and the
	 * physical-backup/recovery path operates on one data directory.
	 * Reject a multi-database request rather than silently joining only
	 * database_list[0]. Separate from check_single_spock_database()
	 * below, which checks the instance for spock on other databases.
	 */
	if (bidir.enabled && n_databases > 1)
		die(_("--bidirectional supports a single database only; "
			  "%d were named via --databases/--provider-dsn.\n"),
			n_databases);

	slot_names = palloc(n_databases * sizeof(char *));

	/*
	 * Check connection strings for validity before doing anything
	 * expensive.
	 */
	for (dbnum = 0; dbnum < n_databases; dbnum++)
	{
		char *db = database_list[dbnum];

		prov_connstr = get_connstr(base_prov_connstr, db);
		if (!prov_connstr || !strlen(prov_connstr))
			die(_("Provider connection string is not valid.\n"));

		if (!bidir.enabled)
		{
			sub_connstr = get_connstr(base_sub_connstr, db);
			if (!sub_connstr || !strlen(sub_connstr))
				die(_("Subscriber connection string is not valid.\n"));
		}
	}

	/*
	 * Create log file where new postgres instance will log to while being
	 * initialized.
	 */
	logfd = open("spock_create_subscriber_postgres.log", O_CREAT | O_RDWR,
				 S_IRUSR | S_IWUSR);
	if (logfd == -1)
	{
		die(_("Creating spock_create_subscriber_postgres.log failed: %s"),
			strerror(errno));
	}
	/* Safe to close() unchecked, we didn't write */
	(void) close(logfd);

	/* Let's start the real work... */
	print_msg(VERBOSITY_NORMAL, _("%s: starting ...\n"), progname);

	for (dbnum = 0; dbnum < n_databases; dbnum++)
	{
		char *db = database_list[dbnum];

		prov_connstr = get_connstr(base_prov_connstr, db);
		if (!prov_connstr || !strlen(prov_connstr))
			die(_("Provider connection string is not valid.\n"));

		/* Read the remote server indetification. */
		print_msg(VERBOSITY_NORMAL,
				  _("Getting information for database %s ...\n"), db);
		provider_conn = connectdb(prov_connstr);
		remote_info = get_remote_info(provider_conn);

		/*
		 * --bidirectional: discover peers, verify preconditions, then
		 * continue into the physical-backup pipeline below using the
		 * "sub_<subscriber>_<source>" slot naming convention.  Manifest
		 * write is deferred until after the basebackup; see the comment
		 * there.
		 */
		if (bidir.enabled)
		{
			PQExpBuffer	sub_name_buf = createPQExpBuffer();
			char	   *source_sub_name;

			/*
			 * Inherit the replication sets already in use by the cluster
			 * being joined, rather than accept a separately specified
			 * list -- see the die() near the top of main() that rejects
			 * --replication-sets together with --bidirectional.
			 */
			replication_sets = get_source_mesh_replication_sets(provider_conn);
			print_msg(VERBOSITY_VERBOSE,
					  _("Replication sets inherited from the existing "
						"cluster: %s\n"), replication_sets);

			bidir.num_peers = discover_peer_nodes(provider_conn,
												  remote_info->node_name,
												  subscriber_name, db,
												  &bidir.peers);
			{
				int	pi;

				for (pi = 0; pi < bidir.num_peers; pi++)
					print_msg(VERBOSITY_DEBUG,
							  _("Discovered peer \"%s\" (dsn \"%s\", slot \"%s\")\n"),
							  bidir.peers[pi].node_name, bidir.peers[pi].dsn,
							  bidir.peers[pi].slot_name);
			}
			check_preconditions(provider_conn, remote_info->node_name,
								bidir.peers, bidir.num_peers);
			check_single_spock_database(provider_conn, base_prov_connstr, db);
			check_no_native_subscriptions(provider_conn);
			use_existing_data_dir = check_data_dir(data_dir, remote_info);
			if (use_existing_data_dir)
				check_reused_data_dir_is_safe(data_dir, remote_info);

			appendPQExpBuffer(sub_name_buf, "sub_%s_%s",
							  subscriber_name, remote_info->node_name);
			source_sub_name = pg_strdup(sub_name_buf->data);
			destroyPQExpBuffer(sub_name_buf);

			print_msg(VERBOSITY_NORMAL,
					  _("Creating source replication slot in database %s ...\n"), db);
			print_msg(VERBOSITY_DEBUG,
					  _("Creating replication slot on source \"%s\" for future "
						"subscription \"%s\"\n"), remote_info->node_name, source_sub_name);
			bidir.source_slot_name = initialize_replication_slot(provider_conn,
																 remote_info->dbname,
																 remote_info->node_name,
																 source_sub_name,
																 drop_slot_if_exists);
			print_msg(VERBOSITY_DEBUG, _("Source replication slot created: \"%s\"\n"),
					  bidir.source_slot_name);
			bidir.source_origin_name = pg_strdup(bidir.source_slot_name);
			pg_free(source_sub_name);

			/*
			 * Persist a pending-cleanup record now, before the base backup
			 * even starts: the source slot above already exists on the
			 * remote node, and a failed/interrupted backup would otherwise
			 * orphan it with nothing for --cleanup to find (the real
			 * manifest can't be written yet -- data_dir must stay empty for
			 * pg_basebackup).  Superseded and removed once the real
			 * manifest is written below.
			 */
			bidir.manifest_path = bidir_pending_path;
			write_manifest(&bidir, subscriber_name, db, base_prov_connstr);
			bidir.manifest_path = bidir_manifest_path;

			PQfinish(provider_conn);
			provider_conn = NULL;
			break;				/* single-database only, enforced above */
		}

		/* only need to do this piece once */

		if (dbnum == 0)
		{
			use_existing_data_dir = check_data_dir(data_dir, remote_info);

			if (use_existing_data_dir)
				check_reused_data_dir_is_safe(data_dir, remote_info);
		}

		/*
		 * Create replication slots on remote node.
		 */
		print_msg(VERBOSITY_NORMAL,
				  _("Creating replication slot in database %s ...\n"), db);
		slot_names[dbnum] = initialize_replication_slot(provider_conn,
														remote_info->dbname,
														remote_info->node_name,
														subscriber_name,
														drop_slot_if_exists);
		PQfinish(provider_conn);
		provider_conn = NULL;
	}

	/*
	 * Create basebackup or use existing one
	 */
	prov_connstr = get_connstr(base_prov_connstr, database_list[0]);
	sub_connstr = get_connstr(base_sub_connstr, database_list[0]);

	if (!use_existing_data_dir)
		print_msg(VERBOSITY_DEBUG,
				  _("Taking a physical base backup from \"%s\" into \"%s\"\n"),
				  prov_connstr, data_dir);
	else
		print_msg(VERBOSITY_DEBUG,
				  _("Reusing existing data directory \"%s\" (already a basebackup "
					"of this source)\n"), data_dir);
	initialize_data_dir(data_dir,
						use_existing_data_dir ? NULL : prov_connstr,
						postgresql_conf, postgresql_auto_conf, pg_hba_conf,
						extra_basebackup_args);
	snprintf(pid_file, MAXPGPATH, "%s/postmaster.pid", data_dir);

	/*
	 * Manifest write is deferred until here: pg_basebackup requires an
	 * empty target directory, and a manifest file in data_dir earlier
	 * would make it look non-empty.  The pending-cleanup sidecar written
	 * right after source slot creation covers the gap between then and
	 * now; it's superseded by the real manifest and removed below.
	 */
	if (bidir.enabled)
	{
		write_manifest(&bidir, subscriber_name, database_list[0], base_prov_connstr);
		if (unlink(bidir_pending_path) != 0 && errno != ENOENT)
			print_msg(VERBOSITY_NORMAL,
					  _("warning: could not remove superseded pending sidecar "
						"%s: %s\n"), bidir_pending_path, strerror(errno));
		print_msg(VERBOSITY_NORMAL,
				  _("Bidirectional plumbing complete: %d peer(s) discovered, "
					"source slot created, manifest written to %s.\n"),
				  bidir.num_peers, bidir.manifest_path);
	}

	restore_point_name = generate_restore_point_name();

	print_msg(VERBOSITY_NORMAL, _("Creating restore point \"%s\" on remote node ...\n"),
		restore_point_name);
	provider_conn = connectdb(prov_connstr);
	remote_lsn = create_restore_point(provider_conn, restore_point_name);
	PQfinish(provider_conn);
	provider_conn = NULL;

	/*
	 * Get subscriber db to consistent state (for lsn after slot creation).
	 */
	print_msg(VERBOSITY_NORMAL,
			  _("Bringing subscriber node to the restore point ...\n"));
	if (recovery_conf)
	{
		CopyConfFile(recovery_conf, "postgresql.auto.conf", true);
	}
	else
	{
		appendPQExpBuffer(recoveryconfcontents, "primary_conninfo = '%s'\n",
								escape_single_quotes_ascii(prov_connstr));
	}
	appendPQExpBuffer(recoveryconfcontents, "recovery_target_name = '%s'\n", restore_point_name);
	appendPQExpBuffer(recoveryconfcontents, "recovery_target_inclusive = true\n");
	appendPQExpBuffer(recoveryconfcontents, "recovery_target_action = promote\n");
	WriteRecoveryConf(recoveryconfcontents);

	free(restore_point_name);
	restore_point_name = NULL;

	/*
	 * Start subscriber node with spock disabled, and wait until it starts
	 * accepting connections which means it has caught up to the restore point.
	 *
	 * TODO: for --bidirectional this node should be network-quarantined
	 * (private socket/listen address, or a restrictive pg_hba.conf) from
	 * this first startup through the end of the join -- spock.readonly =
	 * 'local' (set later) blocks writes but not reads or peer probes.  Not
	 * implemented: --subscriber-dsn must be directly reachable, and the
	 * tool's own connections use that same DSN throughout, so restricting
	 * listen_addresses here would also lock the tool itself out.
	 */
	pg_ctl_ret = run_pg_ctl("start -l \"spock_create_subscriber_postgres.log\" -o \"-c shared_preload_libraries=''\"");
	if (pg_ctl_ret != 0)
		die(_("Postgres startup for restore point catchup failed with %d. See spock_create_subscriber_postgres.log."), pg_ctl_ret);

	wait_primary_connection(sub_connstr,
							 bidir.enabled ? bidir.stall_timeout : 0,
							 bidir.enabled ? bidir.max_wait : 0);

	/*
	 * Clean any per-node data that were copied by pg_basebackup.
	 */
	print_msg(VERBOSITY_VERBOSE,
			  _("Removing old spock configuration ...\n"));

	if (bidir.enabled)
	{
		Oid			source_nodeid;
		char	   *expected_sysid;

		/*
		 * Give n3 its own permanent identity now, right after promotion
		 * and before any catalog mutation: a physical backup preserves
		 * the source's system identifier, which risks stray WAL from one
		 * cluster being mistaken for the other's, and until reset makes
		 * system_identifier useless for proving a connection actually
		 * reaches n3 rather than the source.
		 */
		print_msg(VERBOSITY_NORMAL,
				  _("Assigning a new system identifier to the subscriber node...\n"));
		pg_ctl_ret = run_pg_ctl("stop");
		if (pg_ctl_ret != 0)
			die(_("Postgres stop before resetting system identifier failed with %d."), pg_ctl_ret);
		wait_postmaster_shutdown();

		{
			sigset_t	block_set,
						old_set;

			/*
			 * Neither step below is safe to interrupt -- both write
			 * pg_control/WAL directly, and signal_handler() -> die() is
			 * not async-signal-safe.  A signal landing mid-write could
			 * corrupt pg_control with no repair short of --cleanup
			 * --force.  Block both signals across this pair of calls;
			 * any that arrives is deferred until right after.
			 */
			sigemptyset(&block_set);
			sigaddset(&block_set, SIGINT);
			sigaddset(&block_set, SIGTERM);
			sigprocmask(SIG_BLOCK, &block_set, &old_set);

			expected_sysid = reset_subscriber_sysid(data_dir);
			run_pg_resetwal(data_dir);

			sigprocmask(SIG_SETMASK, &old_set, NULL);
		}

		pg_ctl_ret = run_pg_ctl("start -l \"spock_create_subscriber_postgres.log\" -o \"-c shared_preload_libraries=''\"");
		if (pg_ctl_ret != 0)
			die(_("Postgres startup after resetting system identifier failed with %d."), pg_ctl_ret);
		wait_postmaster_connection(sub_connstr);

		subscriber_conn = connectdb(sub_connstr);

		/*
		 * --subscriber-dsn is expected to point directly at this node;
		 * verify that cheaply before running anything destructive, rather
		 * than trusting it silently.  Now that n3 has just been given its
		 * own system identifier above, a straightforward comparison is a
		 * valid proof the connection reaches n3 and not the source or any
		 * other server -- unlike before the reset, nothing else could
		 * share it.
		 */
		{
			PGresult   *sysid_res = debug_exec(subscriber_conn, "SELECT system_identifier FROM pg_control_system()");
			bool		mismatch;

			if (PQresultStatus(sysid_res) != PGRES_TUPLES_OK || PQntuples(sysid_res) != 1)
			{
				PQclear(sysid_res);
				die(_("could not verify --subscriber-dsn connects to this node: %s\n"),
					PQerrorMessage(subscriber_conn));
			}
			mismatch = strcmp(PQgetvalue(sysid_res, 0, 0), expected_sysid) != 0;
			PQclear(sysid_res);
			if (mismatch)
				die(_("--subscriber-dsn does not connect to the node at \"%s\": "
					  "system identifier mismatch. This can happen if the DSN "
					  "routes to the source node or another server; refusing "
					  "to run catalog operations against it.\n"), data_dir);
		}

		/*
		 * Persist n3's own system identifier so --cleanup can re-verify
		 * node_dsn still reaches this same node later, rather than trusting
		 * a possibly stale manifest to still point at the right server.
		 */
		bidir.node_sysid = expected_sysid;

		/* Capture repset/table/sequence state before the catalog strip. */
		source_nodeid = get_local_node_id(subscriber_conn);
		print_msg(VERBOSITY_DEBUG,
				  _("Capturing replication-set/table/sequence membership for local "
					"node id %u before dropping the spock extension\n"), source_nodeid);
		capture_catalog_state(subscriber_conn, source_nodeid, &capture);
		print_msg(VERBOSITY_DEBUG,
				  _("Captured %d replication set(s), %d table membership(s), "
					"%d sequence(s)\n"),
				  capture.num_repsets, capture.num_tables, capture.num_sequences);

		/* Drop all origins, then guarded DROP EXTENSION. */
		print_msg(VERBOSITY_DEBUG,
				  _("Dropping replication origins and the spock extension (checking "
					"pg_depend first for non-spock objects CASCADE would collaterally "
					"drop)\n"));
		remove_unwanted_data_bidir(subscriber_conn, &capture);

		PQfinish(subscriber_conn);
		subscriber_conn = NULL;
	}
	else
	{
		for (dbnum = 0; dbnum < n_databases; dbnum++)
		{
			char *db = database_list[dbnum];

			sub_connstr = get_connstr(base_sub_connstr, db);

			if (!sub_connstr || !strlen(sub_connstr))
				die(_("Subscriber connection string is not valid.\n"));

			subscriber_conn = connectdb(sub_connstr);
			remove_unwanted_data(subscriber_conn);
			PQfinish(subscriber_conn);
			subscriber_conn = NULL;
		}
	}

	/* Stop Postgres so we can start it again with spock (shared_preload_libraries) loaded. */
	pg_ctl_ret = run_pg_ctl("stop");
	if (pg_ctl_ret != 0)
		die(_("Postgres stop after restore point catchup failed with %d. See spock_create_subscriber_postgres.log."), pg_ctl_ret);
	wait_postmaster_shutdown();

	/*
	 * Start the node again, now with spock active so that we can start the
	 * logical replication.  This is final start, so don't log to to special log
	 * file anymore.
	 */
	print_msg(VERBOSITY_NORMAL,
			  _("Initializing spock on the subscriber node:\n"));

	pg_ctl_ret = run_pg_ctl("start");
	if (pg_ctl_ret != 0)
		die(_("Postgres restart with spock enabled failed with %d."), pg_ctl_ret);
	wait_postmaster_connection(bidir.enabled ? sub_connstr : base_sub_connstr);

	if (bidir.enabled)
	{
		char *db = database_list[0];

		subscriber_conn = connectdb(sub_connstr);

		print_msg(VERBOSITY_VERBOSE,
				  _("Creating spock extension for database %s...\n"), db);
		install_extension(subscriber_conn, "spock");

		/*
		 * Create the local node, then immediately go read-only -- no
		 * window where n3 is reachable/writable before that lands.  No
		 * origin creation here; the catchup subscription creates it
		 * later.
		 *
		 * dsn is --subscriber-dsn (sub_connstr) -- the externally-reachable
		 * address other nodes use to connect back, not a separate
		 * --node-dsn option.
		 */
		print_msg(VERBOSITY_NORMAL, _("Creating local Spock node \"%s\"...\n"),
				  subscriber_name);
		print_msg(VERBOSITY_DEBUG, _("Registering node \"%s\" with dsn \"%s\"\n"),
				  subscriber_name, sub_connstr);
		{
			PQExpBuffer nodequery = createPQExpBuffer();
			PGresult   *res;

			printfPQExpBuffer(nodequery,
							  "SELECT spock.node_create(node_name := %s, dsn := %s)",
							  PQescapeLiteral(subscriber_conn, subscriber_name,
											  strlen(subscriber_name)),
							  PQescapeLiteral(subscriber_conn, sub_connstr,
											  strlen(sub_connstr)));
			res = debug_exec(subscriber_conn, nodequery->data);
			if (PQresultStatus(res) != PGRES_TUPLES_OK)
			{
				PQclear(res);
				die(_("could not create local node: %s\n"),
					PQerrorMessage(subscriber_conn));
			}
			PQclear(res);
			destroyPQExpBuffer(nodequery);
		}

		print_msg(VERBOSITY_NORMAL, _("Setting spock.readonly = 'local'...\n"));
		set_readonly_local(subscriber_conn);

		/* Restore what was captured before the catalog strip. */
		print_msg(VERBOSITY_NORMAL, _("Restoring replication set state...\n"));
		print_msg(VERBOSITY_DEBUG,
				  _("Restoring %d replication set(s), %d table membership(s), "
					"%d sequence(s) onto node \"%s\"\n"),
				  capture.num_repsets, capture.num_tables, capture.num_sequences,
				  subscriber_name);
		restore_replication_sets(subscriber_conn, &capture);

		bidir.source_restore_lsn = pg_strdup(remote_lsn);
		bidir.node_dsn = sub_connstr;
		write_manifest(&bidir, subscriber_name, db, base_prov_connstr);

		{
			PQExpBuffer sub_name_buf = createPQExpBuffer();
			char	   *source_sub_name;
			char	   *target_lsn;

			appendPQExpBuffer(sub_name_buf, "sub_%s_%s",
							  subscriber_name, remote_info->node_name);
			source_sub_name = pg_strdup(sub_name_buf->data);
			destroyPQExpBuffer(sub_name_buf);

			print_msg(VERBOSITY_NORMAL, _("Creating catchup subscription to the source...\n"));
			print_msg(VERBOSITY_DEBUG,
					  _("Creating subscription \"%s\" to source \"%s\" using slot "
						"\"%s\", forward_origins={all}, enabled=false\n"),
					  source_sub_name, prov_connstr, bidir.source_slot_name);
			create_catchup_subscription(subscriber_conn, source_sub_name, prov_connstr,
										replication_sets, bidir.source_slot_name,
										bidir.source_restore_lsn);
			print_msg(VERBOSITY_DEBUG,
					  _("Subscription \"%s\" created, origin advanced to %s, and "
						"enabled\n"), source_sub_name, bidir.source_restore_lsn);

			print_msg(VERBOSITY_NORMAL, _("Creating disabled peer subscriptions...\n"));
			create_disabled_peer_subscriptions(subscriber_conn, bidir.peers,
											   bidir.num_peers, replication_sets);

			/*
			 * Persist disabled_sub_created for every peer now, not just at
			 * the top of this block -- a crash during the (possibly long)
			 * catchup wait below must not leave --cleanup reading a stale
			 * manifest that still shows every peer's disabled subscription
			 * as not-yet-created.
			 */
			write_manifest(&bidir, subscriber_name, db, base_prov_connstr);

			print_msg(VERBOSITY_NORMAL, _("Getting catchup target from the source...\n"));
			target_lsn = get_catchup_target_lsn(prov_connstr);
			print_msg(VERBOSITY_DEBUG, _("Catchup target LSN: %s\n"), target_lsn);

			print_msg(VERBOSITY_NORMAL, _("Waiting for catchup to the source...\n"));
			print_msg(VERBOSITY_DEBUG,
					  _("Waiting for subscription \"%s\" (origin \"%s\") to reach "
						"LSN %s\n"), source_sub_name, bidir.source_slot_name, target_lsn);
			wait_for_catchup(subscriber_conn, source_sub_name, bidir.source_slot_name,
							 target_lsn, bidir.stall_timeout, bidir.max_wait);

			pg_free(target_lsn);
			pg_free(source_sub_name);
		}

		PQfinish(subscriber_conn);
		subscriber_conn = NULL;

		print_msg(VERBOSITY_NORMAL,
				  _("Bidirectional join: catchup complete. Node \"%s\" has caught "
					"up to the source and forward-tracked every peer's origin; "
					"ready for the next phase.\n"),
				  subscriber_name);
	}
	else
	{
		for (dbnum = 0; dbnum < n_databases; dbnum++)
		{
			char *db = database_list[dbnum];

			sub_connstr = get_connstr(base_sub_connstr, db);
			prov_connstr = get_connstr(base_prov_connstr, db);

			subscriber_conn = connectdb(sub_connstr);

			/* Create the extension. */
			print_msg(VERBOSITY_VERBOSE,
					  _("Creating spock extension for database %s...\n"), db);
			install_extension(subscriber_conn, "spock");

			/*
			 * Create the identifier which is setup with the position to which we
			 * already caught up using physical replication.
			 */
			print_msg(VERBOSITY_VERBOSE,
					  _("Creating replication origin for database %s...\n"), db);
			initialize_replication_origin(subscriber_conn, slot_names[dbnum], remote_lsn);

			/*
			 * And finally add the node to the cluster.
			 */
			print_msg(VERBOSITY_NORMAL, _("Creating subscriber %s for database %s...\n"),
					  subscriber_name, db);
			print_msg(VERBOSITY_VERBOSE, _("Replication sets: %s\n"), replication_sets);

			spock_subscribe(subscriber_conn, subscriber_name, sub_connstr,
								prov_connstr, replication_sets, apply_delay,
								force_text_transfer);

			PQfinish(subscriber_conn);
			subscriber_conn = NULL;
		}
	}

	/* If user does not want the node to be running at the end, stop it. */
	if (stop)
	{
		print_msg(VERBOSITY_NORMAL, _("Stopping the subscriber node ...\n"));
		pg_ctl_ret = run_pg_ctl("stop");
		if (pg_ctl_ret != 0)
			die(_("Stopping postgres after successful subscribtion failed with %d."), pg_ctl_ret);
		wait_postmaster_shutdown();
	}

	print_msg(VERBOSITY_NORMAL, _("All done\n"));

	return 0;
}


/*
 * Print help.
 */
static void
usage(void)
{
	printf(_("%s create new spock subscriber from basebackup of provider.\n\n"), progname);
	printf(_("Usage:\n"));
	printf(_("  %s [OPTION]...\n"), progname);
	printf(_("\nGeneral options:\n"));
	printf(_("  -D, --pgdata=DIRECTORY      data directory to be used for new node,\n"));
	printf(_("                              can be either empty/non-existing directory,\n"));
	printf(_("                              or directory populated using\n"));
	printf(_("                              pg_basebackup -X stream command\n"));
	printf(_("  --databases                 optional list of databases to replicate\n"));
	printf(_("  -n, --subscriber-name=NAME  name of the newly created subscriber\n"));
	printf(_("  --subscriber-dsn=CONNSTR    connection string to the newly created subscriber;\n"));
	printf(_("                              with --bidirectional, also the externally-\n"));
	printf(_("                              reachable address peers use to connect back\n"));
	printf(_("                              to this node once joined (required)\n"));
	printf(_("  --provider-dsn=CONNSTR      connection string to the provider\n"));
	printf(_("  --replication-sets=SETS     comma separated list of replication set names\n"));
	printf(_("  --apply-delay=DELAY         apply delay in seconds (by default 0)\n"));
	printf(_("  --drop-slot-if-exists       drop replication slot of conflicting name\n"));
	printf(_("  -s, --stop                  stop the server once the initialization is done\n"));
	printf(_("  -v                          increase logging verbosity; repeatable --\n"));
	printf(_("                              -v -v also traces every query this tool\n"));
	printf(_("                              runs, with its result status\n"));
	printf(_("  --extra-basebackup-args     additional arguments to pass to pg_basebackup.\n"));
	printf(_("                              Safe options: -T, -c, --xlogdir/--waldir\n"));
	printf(_("  --text-types               transfer column values as text rather than binary\n"));
	printf(_("                              (use when provider and subscriber differ in type\n"));
	printf(_("                              representation or endianness)\n"));
	printf(_("\nConfiguration files override:\n"));
	printf(_("  --hba-conf              path to the new pg_hba.conf\n"));
	printf(_("  --postgresql-conf       path to the new postgresql.conf\n"));
	printf(_("  --postgresql-auto-conf  settings to override in postgresql.auto.conf\n"));
	printf(_("  --recovery-conf         path to the template recovery configuration\n"));
	printf(_("\nBidirectional join (joins an existing multi-master cluster):\n"));
	printf(_("  --bidirectional         enable bidirectional join plumbing\n"));
	printf(_("  --stall-timeout=SECS    once PostgreSQL accepts connections, seconds of no\n"));
	printf(_("                          replay progress before giving up (default 600); does\n"));
	printf(_("                          not bound PostgreSQL's own startup\n"));
	printf(_("  --max-wait=SECS         hard ceiling on post-connection catchup wait, seconds\n"));
	printf(_("                          (default: unbounded); does not bound PostgreSQL's own\n"));
	printf(_("                          startup\n"));
	printf(_("  --cleanup               idempotently remove partial join state and exit;\n"));
	printf(_("                          stops postgres if it is running in --pgdata\n"));
	printf(_("  --force                 with --cleanup, also remove the data directory\n"));
	printf(_("\nDuring the join, this node must be network-quarantined (private address /\n"));
	printf(_("restrictive pg_hba.conf) by the operator -- via --hba-conf/--postgresql-conf --\n"));
	printf(_("until the join completes; the tool does not manage this for you.\n"));
}

/*
 * Print error and exit.
 */
static void
die(const char *fmt,...)
{
	va_list argptr;
	va_start(argptr, fmt);
	vfprintf(stderr, fmt, argptr);
	va_end(argptr);

	if (subscriber_conn)
		PQfinish(subscriber_conn);
	if (provider_conn)
		PQfinish(provider_conn);

	if (get_pgpid())
	{
		if (!run_pg_ctl("stop -s"))
		{
			fprintf(stderr, _("WARNING: postgres seems to be running, but could not be stopped\n"));
		}
	}

	exit(1);
}

/*
 * Print message to stdout and flush
 */
static void
print_msg(VerbosityLevelEnum level, const char *fmt,...)
{
	if (verbosity >= level)
	{
		va_list argptr;
		va_start(argptr, fmt);
		vfprintf(stdout, fmt, argptr);
		va_end(argptr);
		fflush(stdout);
	}
}

/*
 * PQexec() wrapper that logs the query text at VERBOSITY_DEBUG (-v -v)
 * before running it, and the resulting status/row count after -- a
 * drop-in replacement so every query this tool issues is traceable
 * without a separate print_msg() call at each site.  Callers still do
 * their own PQresultStatus()/die() handling on the result exactly as
 * with a plain PQexec() call.
 */
static PGresult *
debug_exec(PGconn *conn, const char *query)
{
	PGresult   *res;

	print_msg(VERBOSITY_DEBUG, _("  > %s\n"), query);
	res = PQexec(conn, query);
	if (verbosity >= VERBOSITY_DEBUG)
	{
		if (PQresultStatus(res) == PGRES_TUPLES_OK)
			print_msg(VERBOSITY_DEBUG, _("  < %s (%d row(s))\n"),
					  PQresStatus(PQresultStatus(res)), PQntuples(res));
		else
			print_msg(VERBOSITY_DEBUG, _("  < %s\n"),
					  PQresStatus(PQresultStatus(res)));
	}

	return res;
}


/*
 * Start pg_ctl with given argument(s) - used to start/stop postgres
 *
 * Returns the exit code reported by pg_ctl.  If pg_ctl exits due to a
 * signal this call will die and not return.
 */
static int
run_pg_ctl(const char *arg)
{
	int			 ret;
	PQExpBuffer  cmd = createPQExpBuffer();
	char		*exec_path = find_other_exec_or_die(argv0, "pg_ctl");

	appendPQExpBuffer(cmd, "\"%s\" %s -D \"%s\"", exec_path, arg, data_dir);

	/* Run pg_ctl in silent mode unless we run in debug mode. */
	if (verbosity < VERBOSITY_DEBUG)
		appendPQExpBuffer(cmd, " -s");

	print_msg(VERBOSITY_DEBUG, _("Running pg_ctl: %s.\n"), cmd->data);
	ret = system(cmd->data);

	destroyPQExpBuffer(cmd);

	if (WIFEXITED(ret))
		return WEXITSTATUS(ret);
	else if (WIFSIGNALED(ret))
		die(_("pg_ctl exited with signal %d"), WTERMSIG(ret));
	else
		die(_("pg_ctl exited for an unknown reason (system() returned %d)"), ret);

	return -1;
}


/*
 * Reject --extra-basebackup-args values containing shell control
 * characters. The args are appended to a system() command string, so
 * semicolons, pipes, backticks, and similar metacharacters would allow
 * arbitrary command injection.
 */
static void
validate_extra_basebackup_args(const char *args)
{
	const char *p;

	for (p = args; *p; p++)
	{
		if (*p == ';' || *p == '|' || *p == '&' || *p == '`' ||
			*p == '$' || *p == '(' || *p == ')' ||
			*p == '<' || *p == '>' || *p == '{' || *p == '}' ||
			*p == '\n' || *p == '\r')
			die(_("--extra-basebackup-args contains unsafe shell characters\n"));
	}
}

/*
 * Run pg_basebackup to create the copy of the origin node.
 */
static void
run_basebackup(const char *provider_connstr, const char *data_dir,
	const char *extra_basebackup_args)
{
	int			 ret;
	PQExpBuffer  cmd = createPQExpBuffer();
	char		*exec_path = find_other_exec_or_die(argv0, "pg_basebackup");

	/*
	 * -c fast forces an immediate checkpoint.  Without it, pg_basebackup
	 * requests the default "spread" checkpoint, which paces itself against
	 * checkpoint_timeout (5 minutes by default) regardless of how little
	 * data needs flushing -- an unpredictable, unnecessary stall for a
	 * tool whose entire job is this one backup.
	 */
	appendPQExpBuffer(cmd, "\"%s\" -D \"%s\" -d \"%s\" -X s -c fast -P", exec_path, data_dir, provider_connstr);

	/* Run pg_basebackup in verbose mode if we are running in verbose mode. */
	if (verbosity >= VERBOSITY_VERBOSE)
		appendPQExpBuffer(cmd, " -v");

	if (extra_basebackup_args != NULL)
		appendPQExpBuffer(cmd, " %s", extra_basebackup_args);

	print_msg(VERBOSITY_DEBUG, _("Running pg_basebackup: %s.\n"), cmd->data);
	ret = system(cmd->data);

	destroyPQExpBuffer(cmd);

	if (WIFEXITED(ret) && WEXITSTATUS(ret) == 0)
		return;
	if (WIFEXITED(ret))
		die(_("pg_basebackup failed with exit status %d, cannot continue.\n"), WEXITSTATUS(ret));
	else if (WIFSIGNALED(ret))
		die(_("pg_basebackup exited with signal %d, cannot continue"), WTERMSIG(ret));
	else
		die(_("pg_basebackup exited for an unknown reason (system() returned %d)"), ret);
}

/*
 * Ensure path ends with a newline, appending one if it doesn't.  Used
 * after copying in a user-supplied config-file fragment that gets more
 * content appended after it later (postgresql.auto.conf, where
 * primary_conninfo is appended once recovery is configured) -- without
 * this, a fragment file missing its own trailing newline would merge
 * with whatever comes after it into one malformed setting.
 */
static void
ensure_trailing_newline(const char *path)
{
	int			fd;
	off_t		size;
	char		last = '\0';

	fd = open(path, O_RDWR | PG_BINARY);
	if (fd < 0)
		die(_("could not open \"%s\": %s\n"), path, strerror(errno));

	size = lseek(fd, 0, SEEK_END);
	if (size < 0)
		die(_("could not seek in \"%s\": %s\n"), path, strerror(errno));

	if (size > 0)
	{
		if (lseek(fd, -1, SEEK_CUR) < 0 || read(fd, &last, 1) != 1)
			die(_("could not read \"%s\": %s\n"), path, strerror(errno));

		if (last != '\n' && write(fd, "\n", 1) != 1)
			die(_("could not write to \"%s\": %s\n"), path, strerror(errno));
	}

	close(fd);
}

/*
 * Init the datadir
 *
 * This function can either ensure provided datadir is a postgres datadir,
 * or create it using pg_basebackup.
 *
 * In any case, new postresql.conf and pg_hba.conf will be copied to the
 * datadir if they are provided.
 */
static void
initialize_data_dir(char *data_dir, char *connstr,
					char *postgresql_conf, char *postgresql_auto_conf,
					char *pg_hba_conf, char *extra_basebackup_args)
{
	if (connstr)
	{
		print_msg(VERBOSITY_NORMAL,
				  _("Creating base backup of the remote node...\n"));
		run_basebackup(connstr, data_dir, extra_basebackup_args);
	}

	if (postgresql_conf)
		CopyConfFile(postgresql_conf, "postgresql.conf", false);
	if (postgresql_auto_conf)
	{
		char		auto_conf_path[MAXPGPATH];
		FILE	   *f;

		/*
		 * postgresql.auto.conf is copied verbatim from the source by
		 * pg_basebackup, and is loaded after postgresql.conf and wins
		 * on conflicts -- most of it (tuning, spock GUCs) is exactly
		 * what should carry over to this node, but a setting like port
		 * or listen_addresses may need to differ. Append rather than
		 * replace, so this node's overrides win (same-file, later
		 * setting wins) while everything else inherited stays in effect.
		 * A marker line makes any resulting duplicate settings obvious
		 * to whoever next reads the file.
		 */
		snprintf(auto_conf_path, sizeof(auto_conf_path), "%s/postgresql.auto.conf", data_dir);
		f = fopen(auto_conf_path, "a");
		if (f == NULL)
			die(_("could not open \"%s\": %s\n"), auto_conf_path, strerror(errno));
		fprintf(f, "# --- appended by spock_create_subscriber (--postgresql-auto-conf); "
				"later settings override the inherited ones above ---\n");
		fclose(f);

		CopyConfFile(postgresql_auto_conf, "postgresql.auto.conf", true);

		/*
		 * primary_conninfo is appended to this same file later, in
		 * WriteRecoveryConf(); if the override's last line lacks a
		 * trailing newline, that append would merge onto it instead of
		 * landing on its own line.
		 */
		ensure_trailing_newline(auto_conf_path);
	}
	if (pg_hba_conf)
		CopyConfFile(pg_hba_conf, "pg_hba.conf", false);
}

/*
 * This function checks if provided datadir is clone of the remote node
 * described by the remote info, or if it's emtpy directory that can be used
 * as new datadir.
 */
static bool
check_data_dir(char *data_dir, RemoteInfo *remoteinfo)
{
	/* Run basebackup as needed. */
	switch (pg_check_dir(data_dir))
	{
		case 0:		/* Does not exist */
		case 1:		/* Exists, empty */
				return false;
		case 2:
		case 3:		/* Exists, not empty */
		case 4:
			{
				if (!is_pg_dir(data_dir))
					die(_("Directory \"%s\" exists but is not valid postgres data directory.\n"),
						data_dir);
				return true;
			}
		case -1:	/* Access problem */
			die(_("Could not access directory \"%s\": %s.\n"),
				data_dir, strerror(errno));
	}

	/* Unreachable */
	die(_("Unexpected result from pg_check_dir() call"));
	return false;
}

/*
 * Called whenever check_data_dir() approves reusing an existing
 * data_dir.  The sysid check alone doesn't catch every unsafe reuse: if
 * an earlier attempt already reached promotion (recovery_target_action =
 * promote) before failing or being interrupted, but before
 * reset_subscriber_sysid() ran, the sysid still matches, yet this
 * data_dir's own timeline has advanced past whatever the source has.
 * Re-entering recovery against the source at that point can never
 * succeed: the source has no way to supply WAL for a timeline it never
 * had, so streaming fails permanently with "highest timeline N of the
 * primary is behind recovery timeline M" and this tool would otherwise
 * wait forever for WAL that will never arrive.  Refuse reuse instead.
 */
static void
check_reused_data_dir_is_safe(const char *data_dir, RemoteInfo *remoteinfo)
{
	char	   *local_sysid = read_sysid(data_dir);
	bool		mismatch = strcmp(remoteinfo->sysid, local_sysid) != 0;
	ControlFileData *cf;
	bool		crc_ok;

	free(local_sysid);
	if (mismatch)
		die(_("Subscriber data directory is not basebackup of remote node.\n"));

	cf = get_controlfile(data_dir, &crc_ok);
	if (!crc_ok)
		die(_("control file of \"%s\" appears to be corrupt\n"), data_dir);
	if (cf->checkPointCopy.ThisTimeLineID > remoteinfo->timeline_id)
		die(_("data directory \"%s\" is already on timeline %u, past the "
			  "source's current timeline %u -- it was already promoted by "
			  "an earlier, incomplete attempt and can never resume "
			  "recovery from this source again; run --cleanup --force and "
			  "retry with a fresh base backup\n"),
			data_dir, cf->checkPointCopy.ThisTimeLineID, remoteinfo->timeline_id);
	pg_free(cf);
}

/*
 * Initialize replication slots
 */
static char *
initialize_replication_slot(PGconn *conn, char *dbname,
							char *provider_node_name, char *subscription_name,
							bool drop_slot_if_exists)
{
	PQExpBufferData		query;
	char			   *slot_name;
	PGresult		   *res;

	/* Generate the slot name. */
	initPQExpBuffer(&query);
	printfPQExpBuffer(&query,
					  "SELECT spock.spock_gen_slot_name(%s, %s, %s)",
					  PQescapeLiteral(conn, dbname, strlen(dbname)),
					  PQescapeLiteral(conn, provider_node_name,
									  strlen(provider_node_name)),
					  PQescapeLiteral(conn, subscription_name,
									  strlen(subscription_name)));

	res = debug_exec(conn, query.data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		die(_("Could generate slot name: %s"), PQerrorMessage(conn));

	slot_name = pstrdup(PQgetvalue(res, 0, 0));

	PQclear(res);
	resetPQExpBuffer(&query);

	/* Check if the current slot exists. */
	printfPQExpBuffer(&query,
					  "SELECT 1 FROM pg_catalog.pg_replication_slots WHERE slot_name = %s",
					  PQescapeLiteral(conn, slot_name, strlen(slot_name)));

	res = debug_exec(conn, query.data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		die(_("Could not fetch existing slot information: %s"), PQerrorMessage(conn));

	/* Drop the existing slot when asked for it or error if it already exists. */
	if (PQntuples(res) > 0)
	{
		PQclear(res);
		resetPQExpBuffer(&query);

		if (!drop_slot_if_exists)
			die(_("Slot %s already exists, drop it or use --drop-slot-if-exists to drop it automatically.\n"),
				slot_name);

		print_msg(VERBOSITY_VERBOSE,
				  _("Droping existing slot %s ...\n"), slot_name);

		printfPQExpBuffer(&query,
						  "SELECT pg_catalog.pg_drop_replication_slot(%s)",
						  PQescapeLiteral(conn, slot_name, strlen(slot_name)));

		res = debug_exec(conn, query.data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
			die(_("Could not drop existing slot %s: %s"), slot_name,
				PQerrorMessage(conn));
	}

	PQclear(res);
	resetPQExpBuffer(&query);

	/* And finally, create the slot. */
	appendPQExpBuffer(&query, "SELECT pg_create_logical_replication_slot(%s, '%s');",
					  PQescapeLiteral(conn, slot_name, strlen(slot_name)),
					  "spock_output");

	res = debug_exec(conn, query.data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		die(_("Could not create replication slot, status %s: %s\n"),
			 PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}

	PQclear(res);
	termPQExpBuffer(&query);

	return slot_name;
}

/*
 * Read replication info about remote connection
 *
 * TODO: unify with spock_remote_node_info in spock_rpc
 */
static RemoteInfo *
get_remote_info(PGconn* conn)
{
	RemoteInfo		    *ri = (RemoteInfo *)pg_malloc0(sizeof(RemoteInfo));
	PGresult	   *res;

	if (!extension_exists(conn, "spock"))
		die(_("The remote node is not configured as a spock provider.\n"));

	res = debug_exec(conn, "SELECT node_id, node_name, sysid, dbname, replication_sets FROM spock.node_info()");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		die(_("could not fetch remote node info: %s\n"), PQerrorMessage(conn));

	/* No nodes found? */
	if (PQntuples(res) == 0)
		die(_("The remote database is not configured as a spock node.\n"));

	if (PQntuples(res) > 1)
		die(_("The remote database has multiple nodes configured. That is not supported with current version of spock.\n"));

#define atooid(x)  ((Oid) strtoul((x), NULL, 10))

	ri->nodeid = atooid(PQgetvalue(res, 0, 0));
	ri->node_name = pstrdup(PQgetvalue(res, 0, 1));
	ri->sysid = pstrdup(PQgetvalue(res, 0, 2));
	ri->dbname = pstrdup(PQgetvalue(res, 0, 3));
	ri->replication_sets = pstrdup(PQgetvalue(res, 0, 4));

	PQclear(res);

	res = debug_exec(conn, "SELECT timeline_id FROM pg_control_checkpoint()");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		die(_("could not fetch remote node's current timeline: %s\n"), PQerrorMessage(conn));
	ri->timeline_id = (TimeLineID) strtoul(PQgetvalue(res, 0, 0), NULL, 10);
	PQclear(res);

	return ri;
}

/*
 * Check if extension exists.
 */
static bool
extension_exists(PGconn *conn, const char *extname)
{
	PQExpBuffer		query = createPQExpBuffer();
	PGresult	   *res;
	bool			ret;

	printfPQExpBuffer(query, "SELECT 1 FROM pg_catalog.pg_extension WHERE extname = %s;",
					  PQescapeLiteral(conn, extname, strlen(extname)));
	res = debug_exec(conn, query->data);

	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("Could not read extension info: %s\n"), PQerrorMessage(conn));
	}

	ret = PQntuples(res) == 1;

	PQclear(res);
	destroyPQExpBuffer(query);

	return ret;
}

/*
 * Create extension.
 */
static void
install_extension(PGconn *conn, const char *extname)
{
	PQExpBuffer		query = createPQExpBuffer();
	PGresult	   *res;

	printfPQExpBuffer(query, "CREATE EXTENSION IF NOT EXISTS %s;",
					  PQescapeIdentifier(conn, extname, strlen(extname)));
	res = debug_exec(conn, query->data);

	if (PQresultStatus(res) != PGRES_COMMAND_OK)
	{
		PQclear(res);
		die(_("Could not install %s extension: %s\n"), extname, PQerrorMessage(conn));
	}

	PQclear(res);
	destroyPQExpBuffer(query);
}

/*
 * Clean all the data that was copied from remote node but we don't
 * want it here (currently shared security labels and replication identifiers).
 */
static void
remove_unwanted_data(PGconn *conn)
{
	PGresult		   *res;

	/*
	 * Remove replication identifiers (9.4 will get them removed by dropping
	 * the extension later as we emulate them there).
	 */
	res = debug_exec(conn, "SELECT pg_replication_origin_drop(external_id) FROM pg_replication_origin_status;");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("Could not remove existing replication origins: %s\n"), PQerrorMessage(conn));
	}
	PQclear(res);

	res = debug_exec(conn, "DROP EXTENSION spock CASCADE;");
	if (PQresultStatus(res) != PGRES_COMMAND_OK)
	{
		die(_("Could not clean the spock extension, status %s: %s\n"),
			 PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}
	PQclear(res);
}

/*
 * Return the connected node's own local node id, from spock.local_node --
 * a plain catalog table, so it works even with spock's shared memory not
 * loaded (e.g. before DROP EXTENSION, while spock is disabled).
 */
static Oid
get_local_node_id(PGconn *conn)
{
	PGresult   *res;
	Oid			nodeid;

	res = debug_exec(conn, "SELECT node_id FROM spock.local_node");
	if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1)
	{
		PQclear(res);
		die(_("could not determine source local node id: %s\n"),
			PQerrorMessage(conn));
	}
	nodeid = (Oid) strtoul(PQgetvalue(res, 0, 0), NULL, 10);
	PQclear(res);
	return nodeid;
}

/* Capture replication set definitions owned by the source node. */
static void
capture_repsets(PGconn *conn, Oid source_nodeid, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;

	printfPQExpBuffer(query,
					  "SELECT set_name, replicate_insert, replicate_update,"
					  " replicate_delete, replicate_truncate"
					  " FROM spock.replication_set"
					  " WHERE set_nodeid = %u",
					  source_nodeid);
	res = debug_exec(conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not capture replication set definitions: %s\n"),
			PQerrorMessage(conn));
	}

	capture->num_repsets = PQntuples(res);
	capture->repsets = pg_malloc0(capture->num_repsets * sizeof(RepsetCapture));
	for (i = 0; i < capture->num_repsets; i++)
	{
		capture->repsets[i].set_name = pg_strdup(PQgetvalue(res, i, 0));
		capture->repsets[i].replicate_insert = (PQgetvalue(res, i, 1)[0] == 't');
		capture->repsets[i].replicate_update = (PQgetvalue(res, i, 2)[0] == 't');
		capture->repsets[i].replicate_delete = (PQgetvalue(res, i, 3)[0] == 't');
		capture->repsets[i].replicate_truncate = (PQgetvalue(res, i, 4)[0] == 't');
	}
	PQclear(res);

	destroyPQExpBuffer(query);
}

/* Capture table memberships across all of the source's replication sets. */
static void
capture_repset_tables(PGconn *conn, Oid source_nodeid, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;

	printfPQExpBuffer(query,
					  "SELECT rs.set_name, rts.set_reloid::regclass AS qualified_table,"
					  " rts.set_att_list AS columns,"
					  " pg_get_expr(rts.set_row_filter, rts.set_reloid) AS row_filter"
					  " FROM spock.replication_set_table rts"
					  " JOIN spock.replication_set rs ON rts.set_id = rs.set_id"
					  " WHERE rs.set_nodeid = %u",
					  source_nodeid);
	res = debug_exec(conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not capture replication set table memberships: %s\n"),
			PQerrorMessage(conn));
	}

	capture->num_tables = PQntuples(res);
	capture->tables = pg_malloc0(capture->num_tables * sizeof(RepsetTableCapture));
	for (i = 0; i < capture->num_tables; i++)
	{
		capture->tables[i].set_name = pg_strdup(PQgetvalue(res, i, 0));
		capture->tables[i].qualified_table = pg_strdup(PQgetvalue(res, i, 1));
		capture->tables[i].columns = PQgetisnull(res, i, 2) ? NULL :
			pg_strdup(PQgetvalue(res, i, 2));
		capture->tables[i].row_filter = PQgetisnull(res, i, 3) ? NULL :
			pg_strdup(PQgetvalue(res, i, 3));
	}
	PQclear(res);

	destroyPQExpBuffer(query);
}

/*
 * Capture sequences and the sets they belong to (a sequence can be in more
 * than one set, so this is captured per-membership like table rows, not
 * deduplicated by sequence), plus each sequence's current value.
 */
static void
capture_repset_sequences(PGconn *conn, Oid source_nodeid, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;

	printfPQExpBuffer(query,
					  "SELECT rs.set_name, rss.set_seqoid::regclass"
					  " FROM spock.replication_set_seq rss"
					  " JOIN spock.replication_set rs ON rss.set_id = rs.set_id"
					  " WHERE rs.set_nodeid = %u",
					  source_nodeid);
	res = debug_exec(conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not capture replicated sequence list: %s\n"),
			PQerrorMessage(conn));
	}

	capture->num_sequences = PQntuples(res);
	capture->sequences = pg_malloc0(capture->num_sequences * sizeof(SequenceCapture));
	for (i = 0; i < capture->num_sequences; i++)
	{
		PQExpBuffer seq_query = createPQExpBuffer();
		PGresult   *seq_res;

		capture->sequences[i].set_name = pg_strdup(PQgetvalue(res, i, 0));
		capture->sequences[i].qualified_seq = pg_strdup(PQgetvalue(res, i, 1));

		/*
		 * Read last_value/is_called directly off the sequence relation
		 * (standard technique) rather than pg_sequence_last_value(), which
		 * conflates "never called" with is_called=false and loses the
		 * distinction setval()'s third argument needs to restore exactly.
		 */
		printfPQExpBuffer(seq_query, "SELECT last_value, is_called FROM %s",
						  capture->sequences[i].qualified_seq);
		seq_res = debug_exec(conn, seq_query->data);
		if (PQresultStatus(seq_res) != PGRES_TUPLES_OK)
		{
			PQclear(seq_res);
			destroyPQExpBuffer(seq_query);
			die(_("could not read sequence state for \"%s\": %s\n"),
				capture->sequences[i].qualified_seq, PQerrorMessage(conn));
		}

		capture->sequences[i].last_value = strtoll(PQgetvalue(seq_res, 0, 0), NULL, 10);
		capture->sequences[i].is_called = (PQgetvalue(seq_res, 0, 1)[0] == 't');

		PQclear(seq_res);
		destroyPQExpBuffer(seq_query);
	}
	PQclear(res);

	destroyPQExpBuffer(query);
}

/*
 * Capture replication-set definitions, table memberships, and sequence
 * state from the local catalog before DROP EXTENSION removes it -- this
 * reflects what was replicated at backup time, unlike querying the live
 * source afterward.  Utility-side memory only; never written to the
 * manifest.
 */
static void
capture_catalog_state(PGconn *conn, Oid source_nodeid, CatalogCapture *capture)
{
	memset(capture, 0, sizeof(*capture));

	capture_repsets(conn, source_nodeid, capture);
	capture_repset_tables(conn, source_nodeid, capture);
	capture_repset_sequences(conn, source_nodeid, capture);

	print_msg(VERBOSITY_VERBOSE,
			  _("Captured %d replication set(s), %d table membership(s), "
				"%d sequence(s) before catalog strip.\n"),
			  capture->num_repsets, capture->num_tables, capture->num_sequences);
}

/*
 * Bidirectional-mode catalog strip: drop ALL replication origins (not
 * just ones with a status row, unlike remove_unwanted_data()), then
 * guard DROP EXTENSION ... CASCADE with a one-hop pg_depend inventory --
 * any non-spock object depending on a spock member would otherwise be
 * silently collaterally dropped.
 */
static void
remove_unwanted_data_bidir(PGconn *conn, CatalogCapture *capture)
{
	PGresult   *res;

	(void) capture;			/* must already be populated before this runs */

	/*
	 * Drop all replication origins copied by the basebackup.
	 * pg_replication_origin is a cluster-wide (not per-database) catalog,
	 * so this is scoped to spock's own "spk_..." naming convention
	 * (gen_slot_name(), shared with slot names) rather than dropping every
	 * row -- an unrelated database on the same instance with its own
	 * (non-spock) logical replication would otherwise lose its origins too.
	 */
	res = debug_exec(conn,
				 "SELECT pg_replication_origin_drop(roname)"
				 " FROM pg_replication_origin"
				 " WHERE roname LIKE 'spk\\_%' ESCAPE '\\'");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not remove existing replication origins: %s\n"),
			PQerrorMessage(conn));
	}
	PQclear(res);

	/* Guard against CASCADE collaterally dropping user objects. */
	res = debug_exec(conn,
				 "WITH spock_ext AS ("
				 "  SELECT oid FROM pg_extension WHERE extname = 'spock'"
				 "), ext_members AS ("
				 "  SELECT classid, objid FROM pg_depend, spock_ext"
				 "  WHERE refclassid = 'pg_extension'::regclass"
				 "    AND refobjid = spock_ext.oid"
				 "    AND deptype = 'e'"
				 "), spock_members AS ("
				 /*
				  * Extension members proper (tables, views, functions, ...)
				  * plus anything with an INTERNAL ('i') or AUTO ('a')
				  * dependency on one of them -- a view's own rules use 'i',
				  * while a table's own constraints (CHECK, FK, ...) use
				  * 'a'; both are linked to their owning relation this way,
				  * not directly to the extension, but are just as much
				  * spock's own objects.
				  */
				 "  SELECT classid, objid FROM ext_members"
				 "  UNION"
				 "  SELECT d.classid, d.objid FROM pg_depend d"
				 "  JOIN ext_members m ON d.refclassid = m.classid AND d.refobjid = m.objid"
				 "  WHERE d.deptype IN ('i', 'a')"
				 ")"
				 "SELECT DISTINCT pg_describe_object(d.classid, d.objid, d.objsubid)"
				 " FROM pg_depend d"
				 " JOIN spock_members m ON d.refclassid = m.classid AND d.refobjid = m.objid"
				 " WHERE d.deptype = 'n'"
				 "   AND NOT EXISTS ("
				 "     SELECT 1 FROM spock_members m2"
				 "     WHERE m2.classid = d.classid AND m2.objid = d.objid)");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not inventory spock extension dependents: %s\n"),
			PQerrorMessage(conn));
	}
	if (PQntuples(res) > 0)
	{
		PQExpBuffer	list = createPQExpBuffer();
		int			i;

		for (i = 0; i < PQntuples(res); i++)
			appendPQExpBuffer(list, "\n  - %s", PQgetvalue(res, i, 0));

		PQclear(res);
		die(_("cannot drop the spock extension: the following object(s) "
			  "depend on it and would be collaterally dropped by CASCADE:%s\n"
			  "Resolve these dependencies manually before retrying; v1 does "
			  "not attempt to recreate them.\n"),
			list->data);
	}
	PQclear(res);

	res = debug_exec(conn, "DROP EXTENSION spock CASCADE;");
	if (PQresultStatus(res) != PGRES_COMMAND_OK)
	{
		die(_("Could not clean the spock extension, status %s: %s\n"),
			 PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}
	PQclear(res);
}

/*
 * Immediately after node_create, make the new node read-only to
 * non-superuser clients -- there must be no window where n3 is
 * reachable/writable before this lands.
 */
static void
set_readonly_local(PGconn *conn)
{
	PGresult   *res;

	res = debug_exec(conn, "ALTER SYSTEM SET spock.readonly = 'local'");
	if (PQresultStatus(res) != PGRES_COMMAND_OK)
	{
		die(_("could not set spock.readonly: status %s: %s\n"),
			 PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}
	PQclear(res);

	res = debug_exec(conn, "SELECT pg_reload_conf()");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		die(_("could not reload configuration after setting spock.readonly: %s\n"),
			PQerrorMessage(conn));
	}
	PQclear(res);
}

/*
 * Restore the replication-set definitions, table memberships, and
 * sequence state captured before the catalog strip, now that
 * node_create() has given this node an identity again.  Without this,
 * n3 would accept incoming changes but send nothing back once peers
 * create reverse subscriptions later.
 */
static void
restore_repsets(PGconn *conn, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;

	for (i = 0; i < capture->num_repsets; i++)
	{
		RepsetCapture *s = &capture->repsets[i];
		bool		builtin = (strcmp(s->set_name, "default") == 0 ||
							  strcmp(s->set_name, "default_insert_only") == 0 ||
							  strcmp(s->set_name, "ddl_sql") == 0);

		if (builtin)
			printfPQExpBuffer(query,
							  "SELECT spock.repset_alter("
							  "set_name := %s, "
							  "replicate_insert := %s, "
							  "replicate_update := %s, "
							  "replicate_delete := %s, "
							  "replicate_truncate := %s)",
							  PQescapeLiteral(conn, s->set_name, strlen(s->set_name)),
							  s->replicate_insert ? "true" : "false",
							  s->replicate_update ? "true" : "false",
							  s->replicate_delete ? "true" : "false",
							  s->replicate_truncate ? "true" : "false");
		else
			printfPQExpBuffer(query,
							  "SELECT spock.repset_create("
							  "set_name := %s, "
							  "replicate_insert := %s, "
							  "replicate_update := %s, "
							  "replicate_delete := %s, "
							  "replicate_truncate := %s)",
							  PQescapeLiteral(conn, s->set_name, strlen(s->set_name)),
							  s->replicate_insert ? "true" : "false",
							  s->replicate_update ? "true" : "false",
							  s->replicate_delete ? "true" : "false",
							  s->replicate_truncate ? "true" : "false");
		res = debug_exec(conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not %s replication set \"%s\": %s\n"),
				builtin ? "alter" : "recreate", s->set_name, PQerrorMessage(conn));
		}
		PQclear(res);
	}

	destroyPQExpBuffer(query);
}

/*
 * Restore table memberships for all sets.  Named arguments are required:
 * repset_add_table's 3rd positional argument is synchronize_data, not the
 * column list, so a positional call would misfire.
 *
 * include_partitions := false: the capture already has a separate row per
 * partition.  Restoring the parent with include_partitions := true would
 * re-add every child, violating the (set_id, set_reloid) primary key
 * against the child's own captured row.
 */
static void
restore_repset_tables(PGconn *conn, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;

	for (i = 0; i < capture->num_tables; i++)
	{
		RepsetTableCapture *t = &capture->tables[i];

		printfPQExpBuffer(query,
						  "SELECT spock.repset_add_table("
						  "set_name := %s, "
						  "relation := %s, "
						  "synchronize_data := false, "
						  "columns := %s, "
						  "row_filter := %s, "
						  "include_partitions := false)",
						  PQescapeLiteral(conn, t->set_name, strlen(t->set_name)),
						  PQescapeLiteral(conn, t->qualified_table, strlen(t->qualified_table)),
						  t->columns ? PQescapeLiteral(conn, t->columns, strlen(t->columns)) : "NULL",
						  t->row_filter ? PQescapeLiteral(conn, t->row_filter, strlen(t->row_filter)) : "NULL");
		res = debug_exec(conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not add table \"%s\" to replication set \"%s\": %s\n"),
				t->qualified_table, t->set_name, PQerrorMessage(conn));
		}
		PQclear(res);
	}

	destroyPQExpBuffer(query);
}

/*
 * Restore each sequence's replication-set membership, then its value, so
 * n3 both publishes it and resumes it exactly.
 */
static void
restore_repset_sequences(PGconn *conn, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;

	for (i = 0; i < capture->num_sequences; i++)
	{
		SequenceCapture *sq = &capture->sequences[i];

		printfPQExpBuffer(query,
						  "SELECT spock.repset_add_seq("
						  "set_name := %s, relation := %s, "
						  "synchronize_data := false)",
						  PQescapeLiteral(conn, sq->set_name, strlen(sq->set_name)),
						  PQescapeLiteral(conn, sq->qualified_seq, strlen(sq->qualified_seq)));
		res = debug_exec(conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not add sequence \"%s\" to replication set \"%s\": %s\n"),
				sq->qualified_seq, sq->set_name, PQerrorMessage(conn));
		}
		PQclear(res);

		printfPQExpBuffer(query, "SELECT setval(%s, " INT64_FORMAT ", %s)",
						  PQescapeLiteral(conn, sq->qualified_seq, strlen(sq->qualified_seq)),
						  sq->last_value,
						  sq->is_called ? "true" : "false");
		res = debug_exec(conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not restore sequence state for \"%s\": %s\n"),
				sq->qualified_seq, PQerrorMessage(conn));
		}
		PQclear(res);
	}

	destroyPQExpBuffer(query);
}

static void
restore_replication_sets(PGconn *conn, CatalogCapture *capture)
{
	/*
	 * 1.  Recreate custom sets.  The three built-in sets already exist from
	 * node_create(), so apply the captured flags to them via
	 * repset_alter() instead, since the source may have altered them.
	 */
	restore_repsets(conn, capture);

	/* 2.  Restore table memberships for all sets. */
	restore_repset_tables(conn, capture);

	/* 3.  Restore each sequence's replication-set membership and value. */
	restore_repset_sequences(conn, capture);

	print_msg(VERBOSITY_VERBOSE,
			  _("Restored %d replication set(s), %d table membership(s), "
				"%d sequence(s).\n"),
			  capture->num_repsets, capture->num_tables, capture->num_sequences);

	verify_replication_sets_restored(conn, capture);
}

/*
 * Verify the four replication-set flags landed correctly -- a bug in
 * restore_repsets()'s argument binding would otherwise pass verification
 * with wrong flags on the clone.
 */
static void
verify_repsets_restored(PGconn *conn, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;

	for (i = 0; i < capture->num_repsets; i++)
	{
		RepsetCapture *s = &capture->repsets[i];

		printfPQExpBuffer(query,
						  "SELECT replicate_insert, replicate_update,"
						  " replicate_delete, replicate_truncate"
						  " FROM spock.replication_set WHERE set_name = %s",
						  PQescapeLiteral(conn, s->set_name, strlen(s->set_name)));
		res = debug_exec(conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1)
		{
			PQclear(res);
			die(_("replication set restore verification failed: set \"%s\" "
				  "not found after restore\n"), s->set_name);
		}

		if (strcmp(PQgetvalue(res, 0, 0), s->replicate_insert ? "t" : "f") != 0 ||
			strcmp(PQgetvalue(res, 0, 1), s->replicate_update ? "t" : "f") != 0 ||
			strcmp(PQgetvalue(res, 0, 2), s->replicate_delete ? "t" : "f") != 0 ||
			strcmp(PQgetvalue(res, 0, 3), s->replicate_truncate ? "t" : "f") != 0)
		{
			char	   *got_insert = pg_strdup(PQgetvalue(res, 0, 0));
			char	   *got_update = pg_strdup(PQgetvalue(res, 0, 1));
			char	   *got_delete = pg_strdup(PQgetvalue(res, 0, 2));
			char	   *got_truncate = pg_strdup(PQgetvalue(res, 0, 3));

			PQclear(res);
			die(_("replication set restore verification failed: flags for set "
				  "\"%s\" do not match capture (expected i=%s/u=%s/d=%s/t=%s, "
				  "got i=%s/u=%s/d=%s/t=%s)\n"),
				s->set_name,
				s->replicate_insert ? "t" : "f", s->replicate_update ? "t" : "f",
				s->replicate_delete ? "t" : "f", s->replicate_truncate ? "t" : "f",
				got_insert, got_update, got_delete, got_truncate);
		}
		PQclear(res);
	}

	destroyPQExpBuffer(query);
}

/*
 * Verify table memberships: per-row column-list/row_filter round-trip,
 * plus an aggregate COUNT(*) to catch an accidental double-add.  n3 is
 * brand-new here, so an unqualified COUNT(*) is safe.
 */
static void
verify_repset_tables_restored(PGconn *conn, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;
	int			count;

	for (i = 0; i < capture->num_tables; i++)
	{
		RepsetTableCapture *t = &capture->tables[i];
		char	   *columns;
		char	   *row_filter;

		printfPQExpBuffer(query,
						  "SELECT rts.set_att_list,"
						  " pg_get_expr(rts.set_row_filter, rts.set_reloid)"
						  " FROM spock.replication_set_table rts"
						  " JOIN spock.replication_set rs ON rts.set_id = rs.set_id"
						  " WHERE rs.set_name = %s AND rts.set_reloid::regclass::text = %s",
						  PQescapeLiteral(conn, t->set_name, strlen(t->set_name)),
						  PQescapeLiteral(conn, t->qualified_table, strlen(t->qualified_table)));
		res = debug_exec(conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1)
		{
			PQclear(res);
			die(_("replication set restore verification failed: table \"%s\" "
				  "not found in set \"%s\" after restore\n"),
				t->qualified_table, t->set_name);
		}

		columns = PQgetisnull(res, 0, 0) ? NULL : pg_strdup(PQgetvalue(res, 0, 0));
		row_filter = PQgetisnull(res, 0, 1) ? NULL : pg_strdup(PQgetvalue(res, 0, 1));
		PQclear(res);

		if ((columns == NULL) != (t->columns == NULL) ||
			(columns && strcmp(columns, t->columns) != 0))
			die(_("replication set restore verification failed: column list for "
				  "table \"%s\" in set \"%s\" does not match capture "
				  "(expected %s, got %s)\n"),
				t->qualified_table, t->set_name,
				t->columns ? t->columns : "NULL", columns ? columns : "NULL");

		if ((row_filter == NULL) != (t->row_filter == NULL) ||
			(row_filter && strcmp(row_filter, t->row_filter) != 0))
			die(_("replication set restore verification failed: row_filter for "
				  "table \"%s\" in set \"%s\" does not re-parse identically "
				  "(expected %s, got %s)\n"),
				t->qualified_table, t->set_name,
				t->row_filter ? t->row_filter : "NULL",
				row_filter ? row_filter : "NULL");
	}

	printfPQExpBuffer(query,
					  "SELECT COUNT(*) FROM spock.replication_set_table");
	res = debug_exec(conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not verify table membership count: %s\n"), PQerrorMessage(conn));
	}
	count = atoi(PQgetvalue(res, 0, 0));
	PQclear(res);
	if (count != capture->num_tables)
		die(_("replication set restore verification failed: expected %d table "
			  "membership(s), found %d\n"), capture->num_tables, count);

	destroyPQExpBuffer(query);
}

/*
 * Verify sequence memberships: per-sequence membership, plus an aggregate
 * COUNT(*) to catch an accidental double-add.
 */
static void
verify_repset_sequences_restored(PGconn *conn, CatalogCapture *capture)
{
	PQExpBuffer query = createPQExpBuffer();
	PGresult   *res;
	int			i;
	int			count;

	for (i = 0; i < capture->num_sequences; i++)
	{
		SequenceCapture *sq = &capture->sequences[i];

		printfPQExpBuffer(query,
						  "SELECT COUNT(*) FROM spock.replication_set_seq rss"
						  " JOIN spock.replication_set rs ON rss.set_id = rs.set_id"
						  " WHERE rs.set_name = %s AND rss.set_seqoid::regclass::text = %s",
						  PQescapeLiteral(conn, sq->set_name, strlen(sq->set_name)),
						  PQescapeLiteral(conn, sq->qualified_seq, strlen(sq->qualified_seq)));
		res = debug_exec(conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not verify sequence membership for \"%s\": %s\n"),
				sq->qualified_seq, PQerrorMessage(conn));
		}
		count = atoi(PQgetvalue(res, 0, 0));
		PQclear(res);
		if (count != 1)
			die(_("replication set restore verification failed: sequence \"%s\" "
				  "not a member of set \"%s\" after restore\n"),
				sq->qualified_seq, sq->set_name);
	}

	printfPQExpBuffer(query, "SELECT COUNT(*) FROM spock.replication_set_seq");
	res = debug_exec(conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not verify sequence membership count: %s\n"), PQerrorMessage(conn));
	}
	count = atoi(PQgetvalue(res, 0, 0));
	PQclear(res);
	if (count != capture->num_sequences)
		die(_("replication set restore verification failed: expected %d sequence "
			  "membership(s), found %d\n"), capture->num_sequences, count);

	destroyPQExpBuffer(query);
}

/*
 * Round-trip check: compare what actually landed against the capture,
 * rather than trusting that each individual repset_add_table()/
 * repset_add_seq() call succeeding means the final state matches.
 * Catches per-row drift (a column list or row_filter that didn't
 * re-parse identically) and aggregate drift (an accidental double-add).
 */
static void
verify_replication_sets_restored(PGconn *conn, CatalogCapture *capture)
{
	verify_repsets_restored(conn, capture);
	verify_repset_tables_restored(conn, capture);
	verify_repset_sequences_restored(conn, capture);

	print_msg(VERBOSITY_VERBOSE,
			  _("Verified replication set restore matches capture exactly.\n"));
}

/*
 * Create n3's subscription to the source disabled-first (enabled :=
 * false) -- sub_create() sets SYNC_STATUS_READY and creates the local
 * replication origin atomically, with no apply worker and no INIT
 * window, before this advances that origin to source_restore_lsn and
 * enables it.
 */
static void
create_catchup_subscription(PGconn *subscriber_conn, const char *source_sub_name,
							const char *source_dsn, const char *replication_sets,
							const char *source_slot_name, const char *source_restore_lsn)
{
	PQExpBuffer query = createPQExpBuffer();
	PQExpBuffer repsets = createPQExpBuffer();
	PGresult   *res;
	PGconn	   *source_conn;

	/* Re-confirm the source slot is still there before relying on it. */
	source_conn = connectdb(source_dsn);
	printfPQExpBuffer(query, "SELECT 1 FROM pg_replication_slots WHERE slot_name = %s",
					  PQescapeLiteral(source_conn, source_slot_name, strlen(source_slot_name)));
	res = debug_exec(source_conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not check source replication slot \"%s\": %s\n"),
			source_slot_name, PQerrorMessage(source_conn));
	}
	if (PQntuples(res) != 1)
	{
		PQclear(res);
		die(_("source replication slot \"%s\" is missing on the source; "
			  "cannot start catchup\n"), source_slot_name);
	}
	PQclear(res);
	PQfinish(source_conn);

	printfPQExpBuffer(repsets, "{%s}", replication_sets);
	printfPQExpBuffer(query,
					  "SELECT spock.sub_create("
					  "subscription_name := %s, provider_dsn := %s, "
					  "replication_sets := %s, "
					  "synchronize_structure := false, "
					  "synchronize_data := false, "
					  "forward_origins := '{all}', "
					  "enabled := false)",
					  PQescapeLiteral(subscriber_conn, source_sub_name, strlen(source_sub_name)),
					  PQescapeLiteral(subscriber_conn, source_dsn, strlen(source_dsn)),
					  PQescapeLiteral(subscriber_conn, repsets->data, repsets->len));
	res = debug_exec(subscriber_conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not create catchup subscription \"%s\": %s\n"),
			source_sub_name, PQerrorMessage(subscriber_conn));
	}
	PQclear(res);

	printfPQExpBuffer(query, "SELECT pg_replication_origin_advance(%s, %s)",
					  PQescapeLiteral(subscriber_conn, source_slot_name, strlen(source_slot_name)),
					  PQescapeLiteral(subscriber_conn, source_restore_lsn, strlen(source_restore_lsn)));
	res = debug_exec(subscriber_conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not advance catchup origin to the recovery point: %s\n"),
			PQerrorMessage(subscriber_conn));
	}
	PQclear(res);

	/*
	 * Confirm forward_origins landed as '{all}' -- otherwise forwarded peer
	 * changes are silently dropped during catchup instead of reaching n3.
	 */
	printfPQExpBuffer(query, "SELECT forward_origins FROM spock.sub_show_status(%s)",
					  PQescapeLiteral(subscriber_conn, source_sub_name, strlen(source_sub_name)));
	res = debug_exec(subscriber_conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1)
	{
		PQclear(res);
		die(_("could not verify forward_origins on \"%s\": %s\n"),
			source_sub_name, PQerrorMessage(subscriber_conn));
	}
	if (strcmp(PQgetvalue(res, 0, 0), "{all}") != 0)
	{
		char *got = pg_strdup(PQgetvalue(res, 0, 0));

		PQclear(res);
		die(_("catchup subscription \"%s\" has forward_origins = %s, expected "
			  "{all}; forwarded peer changes would be silently dropped\n"),
			source_sub_name, got);
	}
	PQclear(res);

	printfPQExpBuffer(query, "SELECT spock.sub_enable(%s)",
					  PQescapeLiteral(subscriber_conn, source_sub_name, strlen(source_sub_name)));
	res = debug_exec(subscriber_conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		PQclear(res);
		die(_("could not enable catchup subscription \"%s\": %s\n"),
			source_sub_name, PQerrorMessage(subscriber_conn));
	}
	PQclear(res);

	destroyPQExpBuffer(query);
	destroyPQExpBuffer(repsets);
}

/*
 * Pre-create a disabled subscription to every peer on n3, giving each a
 * local named origin (sub_create(enabled := false), same mechanism as
 * the catchup subscription) without creating anything on the peer
 * itself -- no remote slot, no apply worker.  Forwarding through the
 * catchup subscription is what advances these origins; the direct peer
 * subscriptions stay disabled until a later phase.
 */
static void
create_disabled_peer_subscriptions(PGconn *subscriber_conn, PeerNodeInfo *peers,
								   int num_peers, const char *replication_sets)
{
	PQExpBuffer query = createPQExpBuffer();
	PQExpBuffer repsets = createPQExpBuffer();
	int			i;

	printfPQExpBuffer(repsets, "{%s}", replication_sets);

	for (i = 0; i < num_peers; i++)
	{
		PeerNodeInfo *peer = &peers[i];
		PGresult   *res;

		print_msg(VERBOSITY_DEBUG,
				  _("Creating disabled subscription \"%s\" to peer \"%s\" (dsn "
					"\"%s\"); its origin will be \"%s\"\n"),
				  peer->sub_name, peer->node_name, peer->dsn, peer->slot_name);
		printfPQExpBuffer(query,
						  "SELECT spock.sub_create("
						  "subscription_name := %s, provider_dsn := %s, "
						  "replication_sets := %s, "
						  "synchronize_structure := false, "
						  "synchronize_data := false, "
						  "enabled := false)",
						  PQescapeLiteral(subscriber_conn, peer->sub_name, strlen(peer->sub_name)),
						  PQescapeLiteral(subscriber_conn, peer->dsn, strlen(peer->dsn)),
						  PQescapeLiteral(subscriber_conn, repsets->data, repsets->len));
		res = debug_exec(subscriber_conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not create disabled subscription \"%s\" to peer \"%s\": %s\n"),
				peer->sub_name, peer->node_name, PQerrorMessage(subscriber_conn));
		}
		PQclear(res);

		printfPQExpBuffer(query, "SELECT 1 FROM pg_replication_origin WHERE roname = %s",
						  PQescapeLiteral(subscriber_conn, peer->slot_name, strlen(peer->slot_name)));
		res = debug_exec(subscriber_conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not verify replication origin for peer \"%s\": %s\n"),
				peer->node_name, PQerrorMessage(subscriber_conn));
		}
		if (PQntuples(res) != 1)
		{
			PQclear(res);
			die(_("expected replication origin \"%s\" for peer \"%s\" was not "
				  "created\n"), peer->slot_name, peer->node_name);
		}
		PQclear(res);

		peer->disabled_sub_created = true;
	}

	destroyPQExpBuffer(query);
	destroyPQExpBuffer(repsets);
}

/*
 * A single spock.sync_event() on the source is the catchup target -- it
 * flushes durably before returning, so the LSN is guaranteed to arrive
 * at n3 via the replication stream with no per-peer flush needed.
 * Caller must free the result.
 */
static char *
get_catchup_target_lsn(const char *source_dsn)
{
	PGconn	   *source_conn;
	PGresult   *res;
	char	   *target_lsn;

	source_conn = connectdb(source_dsn);
	res = debug_exec(source_conn, "SELECT spock.sync_event()");
	if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1)
	{
		PQclear(res);
		die(_("could not get catchup target LSN: %s\n"), PQerrorMessage(source_conn));
	}
	target_lsn = pg_strdup(PQgetvalue(res, 0, 0));
	PQclear(res);
	PQfinish(source_conn);

	return target_lsn;
}

/*
 * Wait for n3's catchup subscription to reach target_lsn.  Progress
 * watchdog, not a flat wall-clock timeout -- reset the stall clock
 * whenever remote_lsn advances at all, since a legitimately large
 * catchup can take hours (same shape as wait_primary_connection(), which
 * does this for WAL replay).  Aborts immediately, without waiting out
 * the timeout, if the subscription's own status reports 'disabled' --
 * the signal an unresolvable apply exception leaves behind under
 * spock.exception_behaviour = 'sub_disable'; catchup must not be allowed
 * to silently stall forever behind a stopped apply worker.
 */
static void
wait_for_catchup(PGconn *subscriber_conn, const char *source_sub_name,
				 const char *source_slot_name, const char *target_lsn,
				 int stall_timeout, int max_wait)
{
	PQExpBuffer query = createPQExpBuffer();
	time_t		start_time = time(NULL);
	time_t		last_progress_time = start_time;
	char	   *last_lsn = NULL;

	print_msg(VERBOSITY_VERBOSE, "Waiting for catchup to reach %s...", target_lsn);

	for (;;)
	{
		PGresult   *res;
		bool		reached;

		printfPQExpBuffer(query,
						  "SELECT (remote_lsn >= %s::pg_lsn), remote_lsn::text"
						  " FROM pg_replication_origin_status WHERE external_id = %s",
						  PQescapeLiteral(subscriber_conn, target_lsn, strlen(target_lsn)),
						  PQescapeLiteral(subscriber_conn, source_slot_name, strlen(source_slot_name)));
		res = debug_exec(subscriber_conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not check catchup progress: %s\n"), PQerrorMessage(subscriber_conn));
		}

		reached = PQntuples(res) == 1 && !PQgetisnull(res, 0, 0) &&
				  PQgetvalue(res, 0, 0)[0] == 't';
		if (reached)
		{
			PQclear(res);
			break;
		}

		if (PQntuples(res) == 1 && !PQgetisnull(res, 0, 1))
		{
			char *cur_lsn = PQgetvalue(res, 0, 1);

			if (!last_lsn || strcmp(cur_lsn, last_lsn) != 0)
			{
				pg_free(last_lsn);
				last_lsn = pg_strdup(cur_lsn);
				last_progress_time = time(NULL);
			}
		}
		PQclear(res);

		/*
		 * spock.sub_show_status() is the same primitive check_mesh_edges()
		 * relies on for subscription health; 'disabled' here means the
		 * apply worker hit an unresolvable exception and
		 * spock.exception_behaviour disabled it -- catchup cannot recover
		 * from that on its own, so abort now rather than waiting out
		 * stall_timeout/max_wait behind a subscription that will never
		 * move again.
		 */
		printfPQExpBuffer(query, "SELECT status FROM spock.sub_show_status(%s)",
						  PQescapeLiteral(subscriber_conn, source_sub_name, strlen(source_sub_name)));
		res = debug_exec(subscriber_conn, query->data);
		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			PQclear(res);
			die(_("could not check catchup subscription status: %s\n"),
				PQerrorMessage(subscriber_conn));
		}
		if (PQntuples(res) == 1 && strcmp(PQgetvalue(res, 0, 0), "disabled") == 0)
		{
			PQclear(res);
			die(_("catchup subscription \"%s\" was disabled during catchup, "
				  "likely by an unresolvable apply exception; this is a hard "
				  "join failure -- run --cleanup and retry\n"), source_sub_name);
		}
		PQclear(res);

		if (stall_timeout > 0 && (time(NULL) - last_progress_time) >= stall_timeout)
			die(_("catchup appears stalled: no origin progress for %d second(s) "
				  "(--stall-timeout)\n"), stall_timeout);

		if (max_wait > 0 && (time(NULL) - start_time) >= max_wait)
			die(_("timed out after %d second(s) waiting for catchup to "
				  "complete (--max-wait)\n"), max_wait);

		pg_usleep(1000000);		/* 1 sec */
		print_msg(VERBOSITY_VERBOSE, ".");
	}

	pg_free(last_lsn);
	destroyPQExpBuffer(query);
	print_msg(VERBOSITY_VERBOSE, "\n");
}

/*
 * Initialize new remote identifier to specific position.
 */
static void
initialize_replication_origin(PGconn *conn, char *origin_name, char *remote_lsn)
{
	PGresult   *res;
	PQExpBuffer query = createPQExpBuffer();

	printfPQExpBuffer(query, "SELECT pg_replication_origin_create(%s)",
						PQescapeLiteral(conn, origin_name, strlen(origin_name)));

	res = debug_exec(conn, query->data);

	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		die(_("Could not create replication origin \"%s\": status %s: %s\n"),
			origin_name,
			PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}
	PQclear(res);

	if (remote_lsn)
	{
		printfPQExpBuffer(query, "SELECT pg_replication_origin_advance(%s, '%s')",
							PQescapeLiteral(conn, origin_name, strlen(origin_name)),
							remote_lsn);

		res = debug_exec(conn, query->data);

		if (PQresultStatus(res) != PGRES_TUPLES_OK)
		{
			die(_("Could not advance replication origin \"%s\": status %s: %s\n"),
				origin_name,
				PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
		}
		PQclear(res);
	}

	destroyPQExpBuffer(query);
}


/*
 * Create remote restore point which will be used to get into synchronized
 * state through physical replay.
 */
static char *
create_restore_point(PGconn *conn, char *restore_point_name)
{
	PQExpBuffer  query = createPQExpBuffer();
	PGresult	*res;
	char		*remote_lsn = NULL;

	printfPQExpBuffer(query, "SELECT pg_create_restore_point(%s)",
					  PQescapeLiteral(conn, restore_point_name, strlen(restore_point_name)));
	res = debug_exec(conn, query->data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		die(_("Could not create restore point, status %s: %s\n"),
			 PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}
	remote_lsn = pstrdup(PQgetvalue(res, 0, 0));

	PQclear(res);
	destroyPQExpBuffer(query);

	return remote_lsn;
}

static void
spock_subscribe(PGconn *conn, char *subscriber_name, char *subscriber_dsn,
					char *provider_dsn, char *replication_sets,
					int apply_delay, bool force_text_transfer)
{
	PQExpBufferData		query;
	PQExpBufferData		repsets;
	PGresult		   *res;

	initPQExpBuffer(&query);
	printfPQExpBuffer(&query,
					  "SELECT spock.node_create(node_name := %s, dsn := %s);",
					  PQescapeLiteral(conn, subscriber_name, strlen(subscriber_name)),
					  PQescapeLiteral(conn, subscriber_dsn, strlen(subscriber_dsn)));

	res = debug_exec(conn, query.data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		die(_("Could not create local node, status %s: %s\n"),
			 PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}
	PQclear(res);

	resetPQExpBuffer(&query);
	initPQExpBuffer(&repsets);

	printfPQExpBuffer(&repsets, "{%s}", replication_sets);
	printfPQExpBuffer(&query,
					  "SELECT spock.sub_create("
					  "subscription_name := %s, provider_dsn := %s, "
					  "replication_sets := %s, "
					  "apply_delay := '%d seconds'::interval, "
					  "synchronize_structure := false, "
					  "synchronize_data := false, "
					  "force_text_transfer := '%s');",
					  PQescapeLiteral(conn, subscriber_name, strlen(subscriber_name)),
					  PQescapeLiteral(conn, provider_dsn, strlen(provider_dsn)),
					  PQescapeLiteral(conn, repsets.data, repsets.len),
					  apply_delay, (force_text_transfer ? "t" : "f"));

	res = debug_exec(conn, query.data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		die(_("Could not create subscription, status %s: %s\n"),
			 PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}
	PQclear(res);

	res = debug_exec(conn, "UPDATE spock.local_sync_status SET sync_status = 'r'"
					   " WHERE sync_status != 'r'");
	if (PQresultStatus(res) != PGRES_COMMAND_OK)
	{
		die(_("Could not update subscription, status %s: %s\n"),
			 PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
	}

	PQclear(res);

	termPQExpBuffer(&repsets);
	termPQExpBuffer(&query);
}


/*
 * Validates input of the replication sets and returns normalized data.
 */
static char *
validate_replication_set_input(char *replication_sets)
{
	char	   *name;
	PQExpBuffer	retbuf = createPQExpBuffer();
	char	   *ret;
	bool		first = true;

	if (!replication_sets)
		return NULL;

	name = strtok(replication_sets, " ,");
	while (name != NULL)
	{
		const char *cp;

		if (strlen(name) == 0)
			die(_("Replication set name \"%s\" is too short\n"), name);

		if (strlen(name) >= NAMEDATALEN)
			die(_("Replication set name \"%s\" is too long\n"), name);

		for (cp = name; *cp; cp++)
		{
			if (!((*cp >= 'a' && *cp <= 'z')
				  || (*cp >= '0' && *cp <= '9')
				  || (*cp == '_')
				  || (*cp == '-')))
			{
				die(_("Replication set name \"%s\" contains invalid character\n"),
					name);
			}
		}

		if (first)
			first = false;
		else
			appendPQExpBufferStr(retbuf, ", ");
		appendPQExpBufferStr(retbuf, name);

		name = strtok(NULL, " ,");
	}

	ret = pg_strdup(retbuf->data);
	destroyPQExpBuffer(retbuf);

	return ret;
}

static char *
get_connstr_dbname(char *connstr)
{
	PQconninfoOption *conn_opts = NULL;
	PQconninfoOption *conn_opt;
	char	   *err_msg = NULL;
	char	   *ret = NULL;

	conn_opts = PQconninfoParse(connstr, &err_msg);
	if (conn_opts == NULL)
	{
		die(_("Invalid connection string: %s\n"), err_msg);
	}

	for (conn_opt = conn_opts; conn_opt->keyword != NULL; conn_opt++)
	{
		if (strcmp(conn_opt->keyword, "dbname") == 0)
		{
			ret = pstrdup(conn_opt->val);
			break;
		}
	}

	PQconninfoFree(conn_opts);

	return ret;
}


/*
 * Build connection string from individual parameter.
 *
 * dbname can be specified in connstr parameter
 */
static char *
get_connstr(char *connstr, char *dbname)
{
	char		*ret;
	int			argcount = 4;	/* dbname, host, user, port */
	int			i;
	const char **keywords;
	const char **values;
	PQconninfoOption *conn_opts = NULL;
	PQconninfoOption *conn_opt;
	char	   *err_msg = NULL;

	/*
	 * Merge the connection info inputs given in form of connection string
	 * and options
	 */
	i = 0;
	if (connstr &&
		(strncmp(connstr, "postgresql://", 13) == 0 ||
		 strncmp(connstr, "postgres://", 11) == 0 ||
		 strchr(connstr, '=') != NULL))
	{
		conn_opts = PQconninfoParse(connstr, &err_msg);
		if (conn_opts == NULL)
		{
			die(_("Invalid connection string: %s\n"), err_msg);
		}

		for (conn_opt = conn_opts; conn_opt->keyword != NULL; conn_opt++)
		{
			if (conn_opt->val != NULL && conn_opt->val[0] != '\0')
				argcount++;
		}

		keywords = pg_malloc0((argcount + 1) * sizeof(*keywords));
		values = pg_malloc0((argcount + 1) * sizeof(*values));

		for (conn_opt = conn_opts; conn_opt->keyword != NULL; conn_opt++)
		{
			/* If db* parameters were provided, we'll fill them later. */
			if (dbname && strcmp(conn_opt->keyword, "dbname") == 0)
				continue;

			if (conn_opt->val != NULL && conn_opt->val[0] != '\0')
			{
				keywords[i] = conn_opt->keyword;
				values[i] = conn_opt->val;
				i++;
			}
		}
	}
	else
	{
		keywords = pg_malloc0((argcount + 1) * sizeof(*keywords));
		values = pg_malloc0((argcount + 1) * sizeof(*values));

		/*
		 * If connstr was provided but it's not in connection string format and
		 * the dbname wasn't provided then connstr is actually dbname.
		 */
		if (connstr && !dbname)
			dbname = connstr;
	}

	if (dbname)
	{
		keywords[i] = "dbname";
		values[i] = dbname;
		i++;
	}

	ret = PQconninfoParamsToConnstr(keywords, values);

	/* Connection ok! */
	pg_free(values);
	pg_free(keywords);
	if (conn_opts)
		PQconninfoFree(conn_opts);

	return ret;
}


/*
 * Reads the pg_control file of the existing data dir.
 */
static char *
read_sysid(const char *data_dir)
{
	ControlFileData *cf;
	bool		crc_ok;
	char	   *res = (char *) pg_malloc0(33);

	/*
	 * get_controlfile() validates the control file's CRC; a torn or
	 * corrupted control file must be rejected here rather than silently
	 * misread, since this result feeds directly into check_data_dir()'s
	 * "is this really a basebackup of the expected node" safety check.
	 */
	cf = get_controlfile(data_dir, &crc_ok);
	if (!crc_ok)
		die(_("control file of \"%s\" appears to be corrupt\n"), data_dir);

	snprintf(res, 33, UINT64_FORMAT, cf->system_identifier);
	pg_free(cf);
	return res;
}

/*
 * Assign data_dir a fresh system identifier, since a physical clone
 * otherwise keeps the source's -- risking stray WAL from one cluster
 * being mistaken for the other's, and leaving system_identifier useless
 * for proving --subscriber-dsn actually reaches this node.  Called with
 * the subscriber stopped, right after promotion and before any catalog
 * mutation.
 *
 * pg_resetwal alone does NOT do this: it only regenerates
 * system_identifier when it can't read an existing control file at all
 * (verified empirically against a valid, cleanly-shut-down cluster).
 * The identifier is overwritten directly in the control file here;
 * pg_resetwal is run afterward (run_pg_resetwal()) only to relabel the
 * existing WAL segments to match.
 *
 * Returns the new identifier as a string (caller must free()), matching
 * read_sysid()'s convention.
 */
static char *
reset_subscriber_sysid(const char *data_dir)
{
	ControlFileData *cf;
	bool		crc_ok;
	struct timeval tv;
	char	   *result = (char *) pg_malloc0(33);

	cf = get_controlfile(data_dir, &crc_ok);
	if (!crc_ok)
		die(_("control file of \"%s\" appears to be corrupt\n"), data_dir);

	/* Same formula used to assign a system identifier at initdb time. */
	gettimeofday(&tv, NULL);
	cf->system_identifier = ((uint64) tv.tv_sec) << 32;
	cf->system_identifier |= ((uint64) tv.tv_usec) << 12;
	cf->system_identifier |= getpid() & 0xFFF;

	update_controlfile(data_dir, cf, true);

	snprintf(result, 33, UINT64_FORMAT, cf->system_identifier);
	pg_free(cf);

	return result;
}

/*
 * Relabel data_dir's existing WAL segments to match the system
 * identifier reset_subscriber_sysid() just wrote to the control file
 * (see that function's comment for why both steps are needed).  Must
 * run after reset_subscriber_sysid(), with the subscriber stopped.
 */
static void
run_pg_resetwal(const char *data_dir)
{
	int			 ret;
	PQExpBuffer  cmd = createPQExpBuffer();
	char		*exec_path = find_other_exec_or_die(argv0, "pg_resetwal");

	appendPQExpBuffer(cmd, "\"%s\" -D \"%s\"", exec_path, data_dir);

	print_msg(VERBOSITY_DEBUG, _("Running pg_resetwal: %s.\n"), cmd->data);
	ret = system(cmd->data);

	destroyPQExpBuffer(cmd);

	if (WIFEXITED(ret) && WEXITSTATUS(ret) == 0)
		return;
	if (WIFEXITED(ret))
		die(_("pg_resetwal failed with exit status %d, cannot continue.\n"), WEXITSTATUS(ret));
	else if (WIFSIGNALED(ret))
		die(_("pg_resetwal exited with signal %d, cannot continue"), WTERMSIG(ret));
	else
		die(_("pg_resetwal exited for an unknown reason (system() returned %d)"), ret);
}

/*
 * Write contents of recovery.conf or postgresql.auto.conf
 */
static void
WriteRecoveryConf(PQExpBuffer contents)
{
	char		filename[MAXPGPATH];
	FILE	   *cf;

	snprintf(filename, sizeof(filename), "%s/postgresql.auto.conf", data_dir);

	cf = fopen(filename, "a");
	if (cf == NULL)
	{
		die(_("%s: could not create file \"%s\": %s\n"), progname, filename, strerror(errno));
	}

	if (fwrite(contents->data, contents->len, 1, cf) != 1)
	{
		die(_("%s: could not write to file \"%s\": %s\n"),
				progname, filename, strerror(errno));
	}

	fclose(cf);

	{
		snprintf(filename, sizeof(filename), "%s/standby.signal", data_dir);
		cf = fopen(filename, "w");
		if (cf == NULL)
		{
			die(_("%s: could not create file \"%s\": %s\n"), progname, filename, strerror(errno));
		}

		fclose(cf);
	}
}

/*
 * Copy file to data
 */
static void
CopyConfFile(char *fromfile, char *tofile, bool append)
{
	char		filename[MAXPGPATH];

	snprintf(filename, sizeof(filename), "%s/%s", data_dir, tofile);

	print_msg(VERBOSITY_DEBUG, _("Copying \"%s\" to \"%s\".\n"),
			  fromfile, filename);
	copy_file(fromfile, filename, append);
}


/*
 * Convert PQconninfoOption array into conninfo string
 */
static char *
PQconninfoParamsToConnstr(const char *const * keywords, const char *const * values)
{
	PQExpBuffer	 retbuf = createPQExpBuffer();
	char		*ret;
	int			 i = 0;

	for (i = 0; keywords[i] != NULL; i++)
	{
		if (i > 0)
			appendPQExpBufferChar(retbuf, ' ');
		appendPQExpBuffer(retbuf, "%s=", keywords[i]);
		appendPQExpBufferConnstrValue(retbuf, values[i]);
	}

	ret = pg_strdup(retbuf->data);
	destroyPQExpBuffer(retbuf);

	return ret;
}

/*
 * Escape connection info value
 */
static void
appendPQExpBufferConnstrValue(PQExpBuffer buf, const char *str)
{
	const char *s;
	bool		needquotes;

	/*
	 * If the string is one or more plain ASCII characters, no need to quote
	 * it.  An empty string must default to needing quotes -- an unquoted
	 * empty value doesn't parse as empty, it swallows the entire next
	 * "keyword=value" token.
	 */
	needquotes = true;
	for (s = str; *s; s++)
	{
		if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') ||
			  (*s >= '0' && *s <= '9') || *s == '_' || *s == '.'))
		{
			needquotes = true;
			break;
		}
		needquotes = false;
	}

	if (needquotes)
	{
		appendPQExpBufferChar(buf, '\'');
		while (*str)
		{
			/* ' and \ must be escaped by to \' and \\ */
			if (*str == '\'' || *str == '\\')
				appendPQExpBufferChar(buf, '\\');

			appendPQExpBufferChar(buf, *str);
			str++;
		}
		appendPQExpBufferChar(buf, '\'');
	}
	else
		appendPQExpBufferStr(buf, str);
}


/*
 * Find the pgport and try a connection
 */
static void
wait_postmaster_connection(const char *connstr)
{
	PGPing		res;
	long		pmpid = 0;

	print_msg(VERBOSITY_VERBOSE, "Waiting for PostgreSQL to accept connections ...");

	/* First wait for Postmaster to come up. */
	for (;;)
	{
		if ((pmpid = get_pgpid()) != 0 &&
			postmaster_is_alive((pid_t) pmpid))
			break;

		pg_usleep(1000000);		/* 1 sec */
		print_msg(VERBOSITY_VERBOSE, ".");
	}

	/* Now wait for Postmaster to either accept connections or die. */
	for (;;)
	{
		res = PQping(connstr);
		if (res == PQPING_OK)
			break;
		else if (res == PQPING_NO_ATTEMPT)
			break;

		/*
		 * Check if the process is still alive.  This covers cases where the
		 * postmaster successfully created the pidfile but then crashed without
		 * removing it.
		 */
		if (!postmaster_is_alive((pid_t) pmpid))
			break;

		/* No response; wait */
		pg_usleep(1000000);		/* 1 sec */
		print_msg(VERBOSITY_VERBOSE, ".");
	}

	print_msg(VERBOSITY_VERBOSE, "\n");
}


/*
 * Wait for PostgreSQL to leave recovery/standby mode.
 *
 * stall_timeout/max_wait (seconds; 0 = disabled) bound replay catchup,
 * but only once PostgreSQL first accepts connections -- they don't bound
 * server startup itself.  stall_timeout tracks pg_last_wal_replay_lsn()
 * as a progress signal and fires only when replay stalls, not on total
 * elapsed time, so a slow multi-GB catchup can still run.  max_wait is a
 * separate hard ceiling on total post-connection wait time.  The
 * unidirectional path passes 0/0 for unbounded waiting.
 */
static void
wait_primary_connection(const char *connstr, int stall_timeout, int max_wait)
{
	bool		ispri = false;
	PGconn		*conn = NULL;
	PGresult	*res;
	time_t		start_time = time(NULL);
	time_t		last_progress_time = start_time;
	char	   *last_lsn = NULL;

	wait_postmaster_connection(connstr);

	print_msg(VERBOSITY_VERBOSE, "Waiting for PostgreSQL to become primary...");

	while (!ispri)
	{
		if (!conn || PQstatus(conn) != CONNECTION_OK)
		{
			if (conn)
				PQfinish(conn);
			wait_postmaster_connection(connstr);
			conn = connectdb(connstr);
		}

		res = debug_exec(conn, "SELECT pg_is_in_recovery()");
		if (PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) == 1 && *PQgetvalue(res, 0, 0) == 'f')
		{
			ispri = true;
			PQclear(res);
			break;
		}
		PQclear(res);

		if (stall_timeout > 0)
		{
			PGresult   *lsn_res = debug_exec(conn, "SELECT pg_last_wal_replay_lsn()");

			if (PQresultStatus(lsn_res) == PGRES_TUPLES_OK && PQntuples(lsn_res) == 1 &&
				!PQgetisnull(lsn_res, 0, 0))
			{
				char *cur_lsn = PQgetvalue(lsn_res, 0, 0);

				if (!last_lsn || strcmp(cur_lsn, last_lsn) != 0)
				{
					pg_free(last_lsn);
					last_lsn = pg_strdup(cur_lsn);
					last_progress_time = time(NULL);
				}
			}
			PQclear(lsn_res);

			if ((time(NULL) - last_progress_time) >= stall_timeout)
			{
				PQfinish(conn);
				die(_("recovery appears stalled: no WAL replay progress for "
					  "%d second(s) (--stall-timeout)\n"), stall_timeout);
			}
		}

		if (max_wait > 0 && (time(NULL) - start_time) >= max_wait)
		{
			PQfinish(conn);
			die(_("timed out after %d second(s) waiting for recovery to "
				  "complete (--max-wait)\n"), max_wait);
		}

		pg_usleep(1000000);		/* 1 sec */
		print_msg(VERBOSITY_VERBOSE, ".");
	}

	pg_free(last_lsn);
	PQfinish(conn);
	print_msg(VERBOSITY_VERBOSE, "\n");
}

/*
 * Wait for postmaster to die
 */
static void
wait_postmaster_shutdown(void)
{
	long		pid;
	int			waited = 0;
	const int	max_wait_secs = 60;

	print_msg(VERBOSITY_VERBOSE, "Waiting for PostgreSQL to shutdown ...");

	for (;;)
	{
		pid = get_pgpid();
		if (pid == 0)
			break;

		/*
		 * A hard-killed postmaster can leave its pidfile behind (it's only
		 * removed on a normal exit) -- without this check a stale pidfile
		 * hangs here forever.  Mirrors the same postmaster_is_alive() check
		 * wait_postmaster_connection() already does on the start side.
		 */
		if (!postmaster_is_alive((pid_t) pid))
			break;

		if (++waited >= max_wait_secs)
			die(_("timed out after %d second(s) waiting for PostgreSQL to "
				  "shut down\n"), max_wait_secs);

		pg_usleep(1000000);		/* 1 sec */
		print_msg(VERBOSITY_NORMAL, ".");
	}

	print_msg(VERBOSITY_VERBOSE, "\n");
}

static bool
file_exists(const char *path)
{
	struct stat statbuf;

	if (stat(path, &statbuf) != 0)
		return false;

	return true;
}

/*
 * Replace a leading "~" or "~username" with that user's home directory,
 * in place.  Shell tilde expansion never happens for a quoted argument,
 * so a path like "~/n3.auto.conf" otherwise reaches file_exists()
 * literally and fails.  get_home_path() (port.h, already linked)
 * resolves "~"/"~/..." for the current user; getpwnam() handles
 * "~user"/"~user/...".
 */
static char *
expand_tilde(char *path)
{
	char	   *slash;
	char		home[MAXPGPATH];
	char	   *result;

	if (path == NULL || path[0] != '~')
		return path;

	slash = strchr(path, '/');

	if (slash == path + 1 || path[1] == '\0')
	{
		if (!get_home_path(home))
			return path;
	}
	else
	{
		char		username[MAXPGPATH];
		struct passwd *pw;
		size_t		len = slash ? (size_t) (slash - (path + 1)) : strlen(path + 1);

		if (len >= sizeof(username))
			return path;
		memcpy(username, path + 1, len);
		username[len] = '\0';

		pw = getpwnam(username);
		if (pw == NULL)
			return path;
		strlcpy(home, pw->pw_dir, sizeof(home));
	}

	result = psprintf("%s%s", home, slash ? slash : "");
	pg_free(path);
	return result;
}

static bool
is_pg_dir(const char *path)
{
	struct stat statbuf;
	char		version_file[MAXPGPATH];

	if (stat(path, &statbuf) != 0)
		return false;

	snprintf(version_file, MAXPGPATH, "%s/PG_VERSION", path);
	if (stat(version_file, &statbuf) != 0 && errno == ENOENT)
	{
		return false;
	}

	return true;
}

/*
 * copy one file
 */
static void
copy_file(char *fromfile, char *tofile, bool append)
{
	char	   *buffer;
	int			srcfd;
	int			dstfd;
	int			nbytes;

#define COPY_BUF_SIZE (8 * BLCKSZ)

	buffer = pg_malloc(COPY_BUF_SIZE);

	/*
	 * Open the files
	 */
	srcfd = open(fromfile, O_RDONLY | PG_BINARY, 0);
	if (srcfd < 0)
		die(_("could not open file \"%s\""), fromfile);

	dstfd = open(tofile, O_RDWR | O_CREAT | (append ? O_APPEND : O_TRUNC) | PG_BINARY,
							  S_IRUSR | S_IWUSR);
	if (dstfd < 0)
		die(_("could not create file \"%s\""), tofile);

	/*
	 * Do the data copying.
	 */
	for (;;)
	{
		nbytes = read(srcfd, buffer, COPY_BUF_SIZE);
		if (nbytes < 0)
			die(_("could not read file \"%s\""), fromfile);
		if (nbytes == 0)
			break;
		errno = 0;
		if ((int) write(dstfd, buffer, nbytes) != nbytes)
		{
			/* if write didn't set errno, assume problem is no disk space */
			if (errno == 0)
				errno = ENOSPC;
			die(_("could not write to file \"%s\""), tofile);
		}
	}

	if (close(dstfd))
		die(_("could not close file \"%s\""), tofile);

	/* we don't care about errors here */
	close(srcfd);

	pg_free(buffer);
}


static char *
find_other_exec_or_die(const char *argv0, const char *target)
{
	int			ret;
	char	   *found_path;
	uint32		bin_version;

	found_path = pg_malloc(MAXPGPATH);

	ret = find_other_exec_version(argv0, target, &bin_version, found_path);

	if (ret < 0)
	{
		char		full_path[MAXPGPATH];

		if (find_my_exec(argv0, full_path) < 0)
			strlcpy(full_path, progname, sizeof(full_path));

		if (ret == -1)
			die(_("The program \"%s\" is needed by %s "
						   "but was not found in the\n"
						   "same directory as \"%s\".\n"
						   "Check your installation.\n"),
						 target, progname, full_path);
		else
			die(_("The program \"%s\" was found by \"%s\"\n"
						   "but was not the same version as %s.\n"
						   "Check your installation.\n"),
						 target, full_path, progname);
	}
	else
	{
		char		full_path[MAXPGPATH];

		if (find_my_exec(argv0, full_path) < 0)
			strlcpy(full_path, progname, sizeof(full_path));

		if (bin_version / 100 != PG_VERSION_NUM / 100)
			die(_("The program \"%s\" was found by \"%s\"\n"
						   "but was not the same version as %s.\n"
						   "Check your installation.\n"),
						 target, full_path, progname);

	}

	return found_path;
}

static bool
postmaster_is_alive(pid_t pid)
{
	/*
	 * Test to see if the process is still there.  Note that we do not
	 * consider an EPERM failure to mean that the process is still there;
	 * EPERM must mean that the given PID belongs to some other userid, and
	 * considering the permissions on $PGDATA, that means it's not the
	 * postmaster we are after.
	 *
	 * Don't believe that our own PID or parent shell's PID is the postmaster,
	 * either.  (Windows hasn't got getppid(), though.)
	 */
	if (pid == getpid())
		return false;
#ifndef WIN32
	if (pid == getppid())
		return false;
#endif
	if (kill(pid, 0) == 0)
		return true;
	return false;
}

static long
get_pgpid(void)
{
	FILE	   *pidf;
	long		pid;

	pidf = fopen(pid_file, "r");
	if (pidf == NULL)
	{
		return 0;
	}
	if (fscanf(pidf, "%ld", &pid) != 1)
	{
		fclose(pidf);
		return 0;
	}
	fclose(pidf);
	return pid;
}

static char **
get_database_list(char *databases, int *n_databases)
{
	char *c;
	char **result;
	int num = 1;
	for (c = databases; *c; c++ )
		if (*c == ',')
			num++;
	*n_databases = num;
	result = palloc(num * sizeof(char *));
	num = 0;
	/* clone the argument so we don't destroy it with strtok*/
	databases = pstrdup(databases);
	c = strtok(databases, ",");
	while (c != NULL)
	{
		result[num] = pstrdup(c);
		num++;
		c = strtok(NULL,",");
	}
	pfree(databases);
	return result;
}

static char *
generate_restore_point_name(void)
{
	char *rpn = malloc(NAMEDATALEN);
	if (rpn == NULL)
		die(_("out of memory\n"));
	snprintf(rpn, NAMEDATALEN, "spock_create_subscriber_%lx", random());
	return rpn;
}
