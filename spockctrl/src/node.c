/*-------------------------------------------------------------------------
 *
 * node.c
 *      node management and command handling functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include "dbconn.h"
#include "node.h"
#include "logger.h"
#include "util.h"
#include "conf.h"

/* Function declarations */
static int node_spock_version(int argc, char *argv[]);
static int node_pg_version(int argc, char *argv[]);
static int node_status(int argc, char *argv[]);
static int node_gucs(int argc, char *argv[]);

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

    for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++)
    {
        if (strcmp(argv[1], commands[i].cmd) == 0)
        {
            commands[i].func(argc, &argv[0]);
            return EXIT_SUCCESS;
        }
    }

    log_error("Unknown subcommand for node.");
    print_node_help();
    return EXIT_FAILURE;
}

int
node_spock_version(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *conninfo = NULL;
    char       *node = NULL;

    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"config", required_argument, 0, 'c'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    while ((c = getopt_long(argc, argv, "n:h:c", long_options, &option_index)) != -1)
    {
        switch (c)
        {
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

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}

int
node_pg_version(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *conninfo = NULL;
    const char *node = NULL;
    char        pg_version[256];

    static struct option long_options[] = {
        {"node", required_argument, 0, 't'},
        {"config", required_argument, 0, 'c'}, 
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    while ((c = getopt_long(argc, argv, "t:h:c", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 't':
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
        log_error("Node name is required.");
        print_node_pg_version_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

    if (get_pg_version(conninfo, pg_version) != 0)
    {
        log_error("Failed to get PostgreSQL version for node %s", node);
        return EXIT_FAILURE;
    }
    printf("%s\n", pg_version);
    return EXIT_SUCCESS;
}

int
node_status(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *conninfo = NULL;
    const char *node = NULL;

    static struct option long_options[] = {
        {"node", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    while ((c = getopt_long(argc, argv, "t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 't':
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

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}

int
node_gucs(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *conninfo = NULL;
    const char *node = NULL;

    static struct option long_options[] = {
        {"node", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    while ((c = getopt_long(argc, argv, "t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 't':
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

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}

int
handle_node_create_command(int argc, char *argv[])
{
    int option_index = 0;
    int c;
    const char *conninfo = NULL;
    char       *node_name = NULL;
    char       *node = NULL;
    char       *dsn = NULL;
    char       *location = NULL;
    char       *country = NULL;
    char       *info = NULL;
    PGconn     *conn = NULL;
    PGresult   *res = NULL;
    char        sql[4096];

    static struct option long_options[] = {
        {"node", required_argument, 0, 't'},
        {"node_name", required_argument, 0, 'n'},
        {"dsn", required_argument, 0, 'd'},
        {"location", optional_argument, 0, 'l'},
        {"country", optional_argument, 0, 'c'},
        {"info", optional_argument, 0, 'i'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;
    /* Parse command-line arguments */
    while ((c = getopt_long(argc, argv, "t:n:d:l:c:i:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 't':
                node = optarg;
                break;
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
                log_error("Invalid option provided.");
                print_node_create_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node)
    {
        log_error("Missing required arguments: --node are mandatory.");
        print_node_create_help();
        return EXIT_FAILURE;
    }
    
    /* Validate required arguments */
    if (!node_name || !dsn)
    {
        log_error("Missing required arguments: --node_name and --dsn are mandatory.");
        print_node_create_help();
        return EXIT_FAILURE;
    }

    /* Validate optional arguments */
    if (info && strlen(info) > 1024)
    {
        log_error("The --info parameter is too long. Maximum length is 1024 characters.");
        return EXIT_FAILURE;
    }

    /* Reformat the --info parameter if necessary */
    if (info && !is_valid_json(info))
    {
        log_error("The --info parameter is not valid JSON: '%s'", info);
        return EXIT_FAILURE;
    }

  
    if (info && !is_valid_json(info))
    {
        log_error("The --info parameter is not valid JSON: '%s'", info);
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
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

    /* Prepare quoted/NULL values for SQL */
    char location_val[512];
    char country_val[512];
    char info_val[1050];

    if (location)
        snprintf(location_val, sizeof(location_val), "'%s'", location);
    else
        snprintf(location_val, sizeof(location_val), "NULL");

    if (country)
        snprintf(country_val, sizeof(country_val), "'%s'", country);
    else
        snprintf(country_val, sizeof(country_val), "NULL");

    if (info)
        snprintf(info_val, sizeof(info_val), "'%s'", info);
    else
        snprintf(info_val, sizeof(info_val), "NULL");

    snprintf(sql, sizeof(sql),
             "SELECT spock.node_create("
             "node_name := '%s', "
             "dsn := '%s', "
             "location := %s, "
             "country := %s, "
             "info := %s::jsonb);",
             node_name,
             dsn,
             location_val,
             country_val,
             info_val);

    log_debug0("SQL: %s", sql);

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
    int option_index = 0;
    int c;
    const char *conninfo = NULL;
    char       *node_name = NULL;
    char       *node = NULL;
    int         ifexists = 0;
    PGconn     *conn = NULL;
    PGresult   *res = NULL;
    char        sql[1024];

    static struct option long_options[] = {
        {"node", required_argument, 0, 't'},
        {"node_name", required_argument, 0, 'n'},
        {"ifexists", no_argument, 0, 'e'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    optind = 1;

    /* Parse command-line arguments */
    while ((c = getopt_long(argc, argv, "t:n:eh", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 't':
                node = optarg;
                break;
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
    if (!node)
    {
        log_error("Missing required argument: --node is mandatory.");
        print_node_drop_help();
        return EXIT_FAILURE;
    }

    /* Validate required arguments */
   if (!node_name)
   {
       log_error("Missing required argument: --node_name is mandatory.");
       print_node_drop_help();
       return EXIT_FAILURE;
   }

   /* Get connection info */
   conninfo = get_postgres_coninfo(node);
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
    log_debug0("SQL: %s", sql);
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
    int option_index = 0;
    int c;
    const char *conninfo = NULL;
    char       *node_name = NULL;
    char       *node = NULL;
    char       *interface_name = NULL;
    char       *dsn = NULL;
    PGconn     *conn = NULL;
    PGresult   *res = NULL;
    char        sql[1024];

    static struct option long_options[] = {
        {"node", required_argument, 0, 't'},
        {"node_name", required_argument, 0, 'n'},
        {"interface_name", required_argument, 0, 'i'},
        {"dsn", required_argument, 0, 's'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    /* Parse command-line arguments */
    while ((c = getopt_long(argc, argv, "t:n:i:s:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 't':
                node = optarg;
                break;
            case 'n':
                node_name = optarg;
                break;

            case 'i':
                interface_name = optarg;
                break;
            case 's':
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
    if (!node_name)
    {
        log_error("Missing required argument: --node_name is mandatory.");
        print_node_add_interface_help();
        return EXIT_FAILURE;
    }

    if (!interface_name)
    {
        log_error("Missing required argument: --interface_name is mandatory.");
        print_node_add_interface_help();
        return EXIT_FAILURE;
    }

    if (!dsn)
    {
        log_error("Missing required argument: --dsn is mandatory.");
        print_node_add_interface_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
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

    log_debug0("SQL: %s", sql);

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
    int option_index = 0;
    int c;
    const char *conninfo = NULL;
    char       *node_name = NULL;
    char       *node = NULL;
    char       *interface_name = NULL;
    PGconn     *conn = NULL;
    PGresult   *res = NULL;
    char        sql[1024];

    static struct option long_options[] = {
        {"node", required_argument, 0, 't'},
        {"node_name", required_argument, 0, 'n'},
        {"interface_name", required_argument, 0, 'i'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    /* Parse command-line arguments */
    while ((c = getopt_long(argc, argv, "t:n:i:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 't':
                node = optarg;
                break;
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
    if (!node_name)
    {
        log_error("Missing required argument: --node_name is mandatory.");
        print_node_drop_interface_help();
        return EXIT_FAILURE;
    }

    if (!interface_name)
    {
        log_error("Missing required argument: --interface_name is mandatory.");
        print_node_drop_interface_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
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

    log_debug0("SQL: %s", sql);

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
    printf("Usage: spockctrl node spock-version --node=[node_name]\n");
    printf("Show Spock version.\n");
    printf("Options:\n");
    printf("  --node                Node name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_pg_version_help(void)
{
    printf("Usage: spockctrl node pg-version --node=[node_name]\n");
    printf("Show PostgreSQL version.\n");
    printf("Options:\n");
    printf("  --node                Node name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_status_help(void)
{
    printf("Usage: spockctrl node status --node=[node_name]\n");
    printf("Show node status.\n");
    printf("Options:\n");
    printf("  --node                Node name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_gucs_help(void)
{
    printf("Usage: spockctrl node gucs --node=[node_name]\n");
    printf("Show node GUCs.\n");
    printf("Options:\n");
    printf("  --node                Node name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_create_help(void)
{
    printf("Usage: spockctrl node create --node=[target_node] --node_name=[node_name] --dsn=[dsn] [options]\n");
    printf("Create a node.\n");
    printf("Options:\n");
    printf("  --node                Target node (required)\n");
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
    printf("Drop a node.\n");
    printf("Options:\n");
    printf("  --node_name           Node name (required)\n");
    printf("  --ifexists            Drop node only if it exists (optional)\n");
    printf("  --help                Show this help message\n");
}

static void
print_node_add_interface_help(void)
{
    printf("Usage: spockctrl node add-interface --node_name=[node_name] --interface_name=[interface_name] --dsn=[dsn]\n");
    printf("Add an interface to a node.\n");
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
    printf("Drop an interface from a node.\n");
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
    log_debug0("SQL: %s", sql);
    
    snprintf(pg_version, 256, "\n%s", PQgetvalue(res, 0, 0));
    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}
