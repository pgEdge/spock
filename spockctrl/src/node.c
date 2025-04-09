#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include "dbconn.h"
#include "node.h"
#include "logger.h"
#include "util.h"
#include "conf.h"

static int node_spock_version(int argc, char *argv[]);
static int node_pg_version(int argc, char *argv[]);
static int node_status(int argc, char *argv[]);
static int node_gucs(int argc, char *argv[]);

int handle_node_create_command(int argc, char *argv[]);
int handle_node_drop_command(int argc, char *argv[]);
int handle_node_add_interface_command(int argc, char *argv[]);
int handle_node_drop_interface_command(int argc, char *argv[]);

static void print_node_spock_version_help(void);
static void print_node_pg_version_help(void);
static void print_node_status_help(void);
static void print_node_gucs_help(void);
static void print_node_create_help(void);
static void print_node_drop_help(void);
static void print_node_add_interface_help(void);
static void print_node_drop_interface_help(void);

int get_pg_version(const char *conninfo, char *pg_version);

extern int verbose;

void
print_node_help(void)
{
    printf("Usage: spockctrl node <subcommand> [options]\n");
    printf("Subcommands:\n");
    printf("  spock-version    Show Spock version\n");
    printf("  pg-version       Show PostgreSQL version\n");
    printf("  status           Show node status\n");
    printf("  gucs             Show node GUCs\n");
    printf("  create           Create a node\n");
    printf("  drop             Drop a node\n");
    printf("  add-interface    Add an interface to a node\n");
    printf("  drop-interface   Drop an interface from a node\n");
}

int
handle_node_command(int argc, char *argv[])
{
    int i;
    if (argc < 2)
    {
        log_error("No subcommand provided for node.");
        print_node_help();
        return EXIT_FAILURE;
    }

    if (strcmp(argv[0], "--help") == 0)
    {
        print_node_help();
        return EXIT_SUCCESS;
    }

    struct {
        const char *cmd;
        int (*func)(int, char *[]);
    } commands[] = {
        {"spock-version", node_spock_version},
        {"pg-version", node_pg_version},
        {"status", node_status},
        {"gucs", node_gucs},
        {"create", handle_node_create_command},
        {"drop", handle_node_drop_command},
        {"add-interface", handle_node_add_interface_command},
        {"drop-interface", handle_node_drop_interface_command},
    };

    for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++)
    {
        if (strcmp(argv[1], commands[i].cmd) == 0)
        {
            commands[i].func(argc, &argv[0]);
            return EXIT_SUCCESS;
        }
    }

    log_error("Unknown subcommand for node...");
    print_node_help();
    return EXIT_FAILURE;
}

int
node_spock_version(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *db = "postgres";
    const char *node = NULL;
    char conninfo[256];

    static struct option long_options[] = {
        {"db", required_argument, 0, 'd'},
        {"node", required_argument, 0, 'n'},
        {"config", required_argument, 0, 'c'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    while ((c = getopt_long(argc, argv, "d:n:h:c", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'd':
                db = optarg;
                break;
            case 'n':
                node = optarg;
                break;
            case 'c':
                break;    
            case 'h':
                print_node_spock_version_help();
                return EXIT_SUCCESS;
            default:
                print_node_spock_version_help();
                return EXIT_FAILURE;
        }
    }

    if (node == NULL)
    {
        log_error("Node name is required.");
        print_node_spock_version_help();
        return EXIT_FAILURE;
    }
    snprintf(conninfo, sizeof(conninfo), "dbname=%s", db);
    return EXIT_SUCCESS;
}

int
node_pg_version(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *db = "postgres";
    const char *node = NULL;
    char conninfo[256];
    char pg_version[256];
    static struct option long_options[] = {
        {"db", required_argument, 0, 'd'},
        {"node", required_argument, 0, 'n'},
        {"config", required_argument, 0, 'c'}, 
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    while ((c = getopt_long(argc, argv, "d:n:h:c", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'd':
                db = optarg;
                break;
            case 'n':
                node = optarg;
                break;
            case 'h':
                print_node_pg_version_help();
                return EXIT_SUCCESS;
            case 'c':
                break;    
            default:
                print_node_pg_version_help();
                return EXIT_FAILURE;
        }
    }

    if (node == NULL)
    {
        log_error("Node name is required...");
        print_node_pg_version_help();
        return EXIT_FAILURE;
    }

    snprintf(conninfo, sizeof(conninfo), "dbname=%s", db);
    if (get_pg_version(conninfo, pg_version) != 0)
    {
        log_error("Failed to get PostgreSQL version for node %s", node);
        return EXIT_FAILURE;
    }
    log_info("PostgreSQL version for node %s: %s\n", node, pg_version);
    return EXIT_SUCCESS;
}

int
node_status(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *db = "postgres";
    const char *node = NULL;
    char conninfo[256];

    static struct option long_options[] = {
        {"db", required_argument, 0, 'd'},
        {"node", required_argument, 0, 'n'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    while ((c = getopt_long(argc, argv, "d:n:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'd':
                db = optarg;
                break;
            case 'n':
                node = optarg;
                break;
            case 'h':
                print_node_status_help();
                return EXIT_SUCCESS;
            default:
                print_node_status_help();
                return EXIT_FAILURE;
        }
    }

    if (node == NULL)
    {
        log_error("Node name is required.");
        print_node_status_help();
        return EXIT_FAILURE;
    }

    snprintf(conninfo, sizeof(conninfo), "dbname=%s", db);
    return EXIT_SUCCESS;
}

int
node_gucs(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *db = "postgres";
    const char *node = NULL;
    char conninfo[256];

    static struct option long_options[] = {
        {"db", required_argument, 0, 'd'},
        {"node", required_argument, 0, 'n'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    while ((c = getopt_long(argc, argv, "d:n:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'd':
                db = optarg;
                break;
            case 'n':
                node = optarg;
                break;
            case 'h':
                print_node_gucs_help();
                return EXIT_SUCCESS;
            default:
                print_node_gucs_help();
                return EXIT_FAILURE;
        }
    }

    if (node == NULL)
    {
        log_error("Node name is required.");
        print_node_gucs_help();
        return EXIT_FAILURE;
    }

    snprintf(conninfo, sizeof(conninfo), "dbname=%s", db);
    return EXIT_SUCCESS;
}

int
handle_node_create_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node_name", required_argument, 0, 'n'},
        {"dsn", required_argument, 0, 'd'},
        {"location", optional_argument, 0, 'l'},
        {"country", optional_argument, 0, 'c'},
        {"info", optional_argument, 0, 'i'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node_name = NULL;
    char *dsn = NULL;
    char *location = NULL;
    char *country = NULL;
    char *info = NULL;
    const char *conninfo;
    PGconn *conn;
    PGresult *res;
    char sql[2048];
    int option_index = 0;
    int c;

    /* Parse command-line arguments */
    while ((c = getopt_long(argc, argv, "n:d:l:c:i:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node_name = optarg;
                break;
            case 'd':
                dsn = optarg;
                break;
            case 'l':
                location = optarg;
                break;
            case 'c':
                country = optarg;
                break;
            case 'i':
                info = optarg;
                break;
            case 'h':
                print_node_create_help();
                return EXIT_SUCCESS;
            default:
                print_node_create_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node_name || !dsn)
    {
        log_error("Missing required arguments: --node_name and --dsn are mandatory.");
        print_node_create_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node_name);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node_name);
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Prepare SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.node_create("
             "node_name := '%s', "
             "dsn := '%s', "
             "location := %s%s%s, "
             "country := %s%s%s, "
             "info := %s%s%s::jsonb);",
             node_name,
             dsn,
             location ? "'" : "NULL", location ? location : "", location ? "'" : "NULL",
             country ? "'" : "NULL", country ? country : "", country ? "'" : "NULL",
             info ? "'\"" : "NULL", info ? info : "", info ? "\"'" : "NULL");

    log_info("SQL: %s", sql);

    /* Execute SQL query */
    res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    /* Check for NULL result */
    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }
    /* Clean up */
    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int
handle_node_drop_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node_name", required_argument, 0, 'n'},
        {"ifexists", no_argument, 0, 'e'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node_name = NULL;
    int ifexists = 0;
    const char *conninfo;
    PGconn *conn;
    PGresult *res;
    char sql[1024];
    int option_index = 0;
    int c;

    /* Parse command-line arguments */
    while ((c = getopt_long(argc, argv, "n:eh", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node_name = optarg;
                break;
            case 'e':
                ifexists = 1;
                break;
            case 'h':
                print_node_drop_help();
                return EXIT_SUCCESS;
            default:
                print_node_drop_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node_name)
    {
        log_error("Missing required argument: --node_name is mandatory.");
        print_node_drop_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node_name);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node_name);
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Prepare SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.node_drop("
             "node_name := '%s', "
             "ifexists := %s);",
             node_name,
             ifexists ? "true" : "false");


    /* Execute SQL query */
    res = PQexec(conn, sql);
    log_info("SQL: %s", sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    /* Check for NULL result */
    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    /* Clean up */
    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int
handle_node_add_interface_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node_name", required_argument, 0, 'n'},
        {"interface_name", required_argument, 0, 'i'},
        {"dsn", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node_name = NULL;
    char *interface_name = NULL;
    char *dsn = NULL;
    const char *conninfo;
    PGconn *conn;
    PGresult *res;
    char sql[1024];
    int option_index = 0;
    int c;

    /* Parse command-line arguments */
    while ((c = getopt_long(argc, argv, "n:i:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node_name = optarg;
                break;
            case 'i':
                interface_name = optarg;
                break;
            case 'd':
                dsn = optarg;
                break;
            case 'h':
                print_node_add_interface_help();
                return EXIT_SUCCESS;
            default:
                print_node_add_interface_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node_name || !interface_name || !dsn)
    {
        log_error("Missing required arguments: --node_name, --interface_name, and --dsn are mandatory.");
        print_node_add_interface_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node_name);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node_name);
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Prepare SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.node_add_interface("
             "node_name := '%s', "
             "interface_name := '%s', "
             "dsn := '%s');",
             node_name,
             interface_name,
             dsn);

    log_info("SQL: %s", sql);

    /* Execute SQL query */
    res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    /* Check for NULL result */
    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    /* Clean up */
    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int
handle_node_drop_interface_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node_name", required_argument, 0, 'n'},
        {"interface_name", required_argument, 0, 'i'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node_name = NULL;
    char *interface_name = NULL;
    const char *conninfo;
    PGconn *conn;
    PGresult *res;
    char sql[1024];
    int option_index = 0;
    int c;

    /* Parse command-line arguments */
    while ((c = getopt_long(argc, argv, "n:i:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node_name = optarg;
                break;
            case 'i':
                interface_name = optarg;
                break;
            case 'h':
                print_node_drop_interface_help();
                return EXIT_SUCCESS;
            default:
                print_node_drop_interface_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node_name || !interface_name)
    {
        log_error("Missing required arguments: --node_name and --interface_name are mandatory.");
        print_node_drop_interface_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node_name);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node_name);
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Prepare SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.node_drop_interface("
             "node_name := '%s', "
             "interface_name := '%s');",
             node_name,
             interface_name);

    log_info("SQL: %s", sql);

    /* Execute SQL query */
    res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    /* Check for NULL result */
    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    /* Clean up */
    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

static void
print_node_spock_version_help(void)
{
    printf("Usage: spockctrl node spock-version --db=[dbname] --node=[node_name]\n");
    printf("Show Spock version\n");
    printf("Options:\n");
    printf("  --db                  Database name (optional, default: postgres)\n");
    printf("  --node                Node name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_pg_version_help(void)
{
    printf("Usage: spockctrl node pg-version --db=[dbname] --node=[node_name]\n");
    printf("Show PostgreSQL version\n");
    printf("Options:\n");
    printf("  --db                  Database name (optional, default: postgres)\n");
    printf("  --node                Node name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_status_help(void)
{
    printf("Usage: spockctrl node status --db=[dbname] --node=[node_name]\n");
    printf("Show node status\n");
    printf("Options:\n");
    printf("  --db                  Database name (optional, default: postgres)\n");
    printf("  --node                Node name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_gucs_help(void)
{
    printf("Usage: spockctrl node gucs --db=[dbname] --node=[node_name]\n");
    printf("Show node GUCs\n");
    printf("Options:\n");
    printf("  --db                  Database name (optional, default: postgres)\n");
    printf("  --node                Node name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_create_help(void)
{
    printf("Usage: spockctrl node create --node_name=[node_name] --dsn=[dsn] [options]\n");
    printf("Create a node\n");
    printf("Options:\n");
    printf("  --node_name           Node name (required)\n");
    printf("  --dsn                 Data source name (required)\n");
    printf("  --location            Location of the node (optional)\n");
    printf("  --country             Country of the node (optional)\n");
    printf("  --info                Additional info about the node (optional)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_drop_help(void)
{
    printf("Usage: spockctrl node drop --node_name=[node_name] [options]\n");
    printf("Drop a node\n");
    printf("Options:\n");
    printf("  --node_name           Node name (required)\n");
    printf("  --ifexists            Drop node only if it exists (optional)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_add_interface_help(void)
{
    printf("Usage: spockctrl node add-interface --node_name=[node_name] --interface_name=[interface_name] --dsn=[dsn]\n");
    printf("Add an interface to a node\n");
    printf("Options:\n");
    printf("  --node_name           Node name (required)\n");
    printf("  --interface_name      Interface name (required)\n");
    printf("  --dsn                 Data source name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_drop_interface_help(void)
{
    printf("Usage: spockctrl node drop-interface --node_name=[node_name] --interface_name=[interface_name]\n");
    printf("Drop an interface from a node\n");
    printf("Options:\n");
    printf("  --node_name           Node name (required)\n");
    printf("  --interface_name      Interface name (required)\n");
    printf("  --help                Show this help message\n");
}

int
get_pg_version(const char *conninfo, char *pg_version)
{
    PGconn *conn;
    PGresult *res;
    char sql[256] = "SELECT version();";

    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to database with conninfo: %s", conninfo);
        return EXIT_FAILURE;
    }

    res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("Failed to execute query: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }
    log_info("SQL: %s", sql);
    
    snprintf(pg_version, 256, "\n%s", PQgetvalue(res, 0, 0));
    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}
