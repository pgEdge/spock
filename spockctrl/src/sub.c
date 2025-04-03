#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <getopt.h>
#include <libpq-fe.h>
#include "dbconn.h"
#include "conf.h"
#include "sub.h"
#include "logger.h"

/* Function declarations */
int handle_sub_create_command(int argc, char *argv[]);
int handle_sub_drop_command(int argc, char *argv[]);
int handle_sub_enable_command(int argc, char *argv[]);
int handle_sub_disable_command(int argc, char *argv[]);
int handle_sub_show_status_command(int argc, char *argv[]);
int handle_sub_show_table_command(int argc, char *argv[]);
int handle_sub_resync_table_command(int argc, char *argv[]);
int handle_sub_add_repset_command(int argc, char *argv[]);
int handle_sub_remove_repset_command(int argc, char *argv[]);

static void print_sub_create_help(void);
static void print_sub_drop_help(void);
static void print_sub_enable_help(void);
static void print_sub_disable_help(void);
static void print_sub_show_status_help(void);
static void print_sub_show_table_help(void);
static void print_sub_resync_table_help(void);
static void print_sub_add_repset_help(void);
static void print_sub_remove_repset_help(void);

extern Config config;

void
print_sub_help(void)
{
    printf("Subscription management commands:\n");
    printf("  sub create          Create a new subscription\n");
    printf("  sub drop            Drop a subscription\n");
    printf("  sub enable          Enable a subscription\n");
    printf("  sub disable         Disable a subscription\n");
    printf("  sub show-status     Show the status of a subscription\n");
    printf("  sub show-table      Show the table of a subscription\n");
    printf("  sub resync-table    Resync a table in a subscription\n");
    printf("  sub add-repset      Add a replication set to a subscription\n");
    printf("  sub remove-repset   Remove a replication set from a subscription\n");
}

int
handle_sub_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    int i;

    struct {
        const char *cmd;
        int min_args;
        int (*func)(int, char *[]);
    } commands[] = {
        {"create", 11, handle_sub_create_command},
        {"drop", 5, handle_sub_drop_command},
        {"enable", 6, handle_sub_enable_command},
        {"disable", 6, handle_sub_disable_command},
        {"show-status", 5, handle_sub_show_status_command},
        {"show-table", 6, handle_sub_show_table_command},
        {"resync-table", 7, handle_sub_resync_table_command},
        {"add-repset", 6, handle_sub_add_repset_command},
        {"remove-repset", 6, handle_sub_remove_repset_command},
    };

    if (argc < 2)
    {
        log_error("No subcommand provided for sub.");
        print_sub_help();
        return EXIT_FAILURE;
    }

    for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++)
    {
        if (strcmp(argv[1], commands[i].cmd) == 0)
            return commands[i].func(argc, argv);
    }

    while ((c = getopt_long(argc, argv, "h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_sub_help();
                return EXIT_SUCCESS;
            default:
                print_sub_help();
                return EXIT_FAILURE;
        }
    }

    log_error("Unknown subcommand for sub.");
    print_sub_help();
    return EXIT_FAILURE;
}

int
handle_sub_create_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"provider_dsn", required_argument, 0, 'p'},
        {"db", required_argument, 0, 'd'},
        {"replication_sets", optional_argument, 0, 'r'},
        {"synchronize_structure", optional_argument, 0, 'y'},
        {"synchronize_data", optional_argument, 0, 'z'},
        {"forward_origins", optional_argument, 0, 'f'},
        {"apply_delay", optional_argument, 0, 'a'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *provider_dsn = NULL;
    char *db = NULL;
    char *replication_sets = NULL;
    char *synchronize_structure = NULL;
    char *synchronize_data = NULL;
    char *forward_origins = NULL;
    char *apply_delay = NULL;
    const char *conninfo;
    PGconn *conn;
    char sql[2048];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:p:d:r:y:z:f:a:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'p':
                provider_dsn = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'r':
                replication_sets = optarg;
                break;
            case 'y':
                synchronize_structure = optarg;
                break;
            case 'z':
                synchronize_data = optarg;
                break;
            case 'f':
                forward_origins = optarg;
                break;
            case 'a':
                apply_delay = optarg;
                break;
            case 'h':
                print_sub_create_help();
                return EXIT_SUCCESS;
            default:
                print_sub_create_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !provider_dsn || !db)
    {
        log_error("Missing required arguments: --node, --sub_name, --provider_dsn, and --db are mandatory.");
        print_sub_create_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_create_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.sub_create("
             "subscription_name := '%s', "
             "provider_dsn := '%s', "
             "replication_sets := %s, "
             "synchronize_structure := %s, "
             "synchronize_data := %s, "
             "forward_origins := %s, "
             "apply_delay := %s, "
             "force_text_transfer := false);",
             sub_name,
             provider_dsn,
             replication_sets ? replication_sets : "ARRAY['default', 'default_insert_only', 'ddl_sql']",
             synchronize_structure ? synchronize_structure : "false",
             synchronize_data ? synchronize_data : "false",
             forward_origins ? forward_origins : "'{}'::text[]",
             apply_delay ? apply_delay : "'0'::interval");

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    run_sql(conn, sql);

    /* Close the connection */
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int
handle_sub_drop_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"ifexists", no_argument, 0, 'e'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *db = NULL;
    int ifexists = 0;
    const char *conninfo;
    PGconn *conn;
    char sql[1024];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:d:eh", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'e':
                ifexists = 1;
                break;
            case 'h':
                print_sub_drop_help();
                return EXIT_SUCCESS;
            default:
                print_sub_drop_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !db)
    {
        log_error("Missing required arguments: --node, --sub_name, and --db are mandatory.");
        print_sub_drop_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_drop_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.sub_drop("
             "subscription_name := '%s', "
             "ifexists := %s);",
             sub_name,
             ifexists ? "true" : "false");

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    run_sql(conn, sql);

    /* Close the connection */
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int
handle_sub_enable_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"immediate", required_argument, 0, 'i'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *db = NULL;
    char *immediate = NULL;
    const char *conninfo;
    PGconn *conn;
    char sql[1024];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:d:i:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'i':
                immediate = optarg;
                break;
            case 'h':
                print_sub_enable_help();
                return EXIT_SUCCESS;
            default:
                print_sub_enable_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !db || !immediate)
    {
        log_error("Missing required arguments: --node, --sub_name, --db, and --immediate are mandatory.");
        print_sub_enable_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_enable_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.sub_enable("
             "subscription_name := '%s', "
             "immediate := %s);",
             sub_name,
             immediate);

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    run_sql(conn, sql);

    /* Close the connection */
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int
handle_sub_disable_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"immediate", required_argument, 0, 'i'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *db = NULL;
    char *immediate = NULL;
    const char *conninfo;
    PGconn *conn;
    char sql[2048];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:d:i:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'i':
                immediate = optarg;
                break;
            case 'h':
                print_sub_disable_help();
                return EXIT_SUCCESS;
            default:
                print_sub_disable_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !db)
    {
        log_error("Missing required arguments: --node, --sub_name, and --db are mandatory.");
        print_sub_disable_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_disable_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.sub_disable("
             "subscription_name := '%s', "
             "immediate := %s);",
             sub_name,
             immediate ? immediate : "false");

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    run_sql(conn, sql);

    /* Close the connection */
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int
handle_sub_show_status_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *db = NULL;
    const char *conninfo;
    PGconn *conn;
    PGresult *res;
    char sql[2048];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'h':
                print_sub_show_status_help();
                return EXIT_SUCCESS;
            default:
                print_sub_show_status_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !db)
    {
        log_error("Missing required arguments: --node, --sub_name, and --db are mandatory.");
        print_sub_show_status_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_show_status_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT * FROM spock.sub_show_status("
             "subscription_name := '%s');",
             sub_name);

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    res = PQexec(conn, sql);

    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("Failed to execute query: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    /* Print the results */
    int nrows = PQntuples(res);
    int nfields = PQnfields(res);

    for (int i = 0; i < nrows; i++)
    {
        for (int j = 0; j < nfields; j++)
        {
            printf("%s: %s\n", PQfname(res, j), PQgetvalue(res, i, j));
        }
        printf("\n");
    }

    /* Clean up */
    PQclear(res);
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int
handle_sub_show_table_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"relation", required_argument, 0, 'r'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *relation = NULL;
    char *db = NULL;
    const char *conninfo;
    PGconn *conn;
    char sql[2048];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:r:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'r':
                relation = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'h':
                print_sub_show_table_help();
                return EXIT_SUCCESS;
            default:
                print_sub_show_table_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !relation || !db)
    {
        log_error("Missing required arguments: --node, --sub_name, --relation, and --db are mandatory.");
        print_sub_show_table_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_show_table_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.sub_show_table("
             "node_name := '%s', "
             "subscription_name := '%s', "
             "relation_name := '%s', "
             "database_name := '%s');",
             node,
             sub_name,
             relation,
             db);

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    run_sql(conn, sql);

    /* Close the connection */
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int
handle_sub_resync_table_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"relation", required_argument, 0, 'r'},
        {"db", required_argument, 0, 'd'},
        {"truncate", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *relation = NULL;
    char *db = NULL;
    char *truncate = NULL;
    const char *conninfo;
    PGconn *conn;
    char sql[2048];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:r:d:t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'r':
                relation = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 't':
                truncate = optarg;
                break;
            case 'h':
                print_sub_resync_table_help();
                return EXIT_SUCCESS;
            default:
                print_sub_resync_table_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !relation || !db || !truncate)
    {
        log_error("Missing required arguments: --node, --sub_name, --relation, --db, and --truncate are mandatory.");
        print_sub_resync_table_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_resync_table_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.sub_resync_table("
             "node_name := '%s', "
             "subscription_name := '%s', "
             "relation_name := '%s', "
             "database_name := '%s', "
             "truncate := %s);",
             node,
             sub_name,
             relation,
             db,
             truncate);

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    run_sql(conn, sql);

    /* Close the connection */
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int
handle_sub_add_repset_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"replication_set", required_argument, 0, 'r'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *replication_set = NULL;
    char *db = NULL;
    const char *conninfo;
    PGconn *conn;
    char sql[2048];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:r:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'r':
                replication_set = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'h':
                print_sub_add_repset_help();
                return EXIT_SUCCESS;
            default:
                print_sub_add_repset_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !replication_set || !db)
    {
        log_error("Missing required arguments: --node, --sub_name, --replication_set, and --db are mandatory.");
        print_sub_add_repset_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_add_repset_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.sub_add_repset("
             "subscription_name := '%s', "
             "replication_set := '%s');",
             sub_name,
             replication_set);

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    run_sql(conn, sql);

    /* Close the connection */
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int
handle_sub_remove_repset_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sub_name", required_argument, 0, 's'},
        {"replication_set", required_argument, 0, 'r'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *sub_name = NULL;
    char *replication_set = NULL;
    char *db = NULL;
    const char *conninfo;
    PGconn *conn;
    char sql[2048];
    int option_index = 0;
    int c;

    /* Parse command-line options */
    while ((c = getopt_long(argc, argv, "n:s:r:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                sub_name = optarg;
                break;
            case 'r':
                replication_set = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'h':
                print_sub_remove_repset_help();
                return EXIT_SUCCESS;
            default:
                print_sub_remove_repset_help();
                return EXIT_FAILURE;
        }
    }

    /* Validate required arguments */
    if (!node || !sub_name || !replication_set || !db)
    {
        log_error("Missing required arguments: --node, --sub_name, --replication_set, and --db are mandatory.");
        print_sub_remove_repset_help();
        return EXIT_FAILURE;
    }

    /* Get connection info */
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        print_sub_remove_repset_help();
        return EXIT_FAILURE;
    }

    /* Connect to the database */
    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    /* Build the SQL query */
    snprintf(sql, sizeof(sql),
             "SELECT spock.sub_remove_repset("
             "subscription_name := '%s', "
             "replication_set := '%s');",
             sub_name,
             replication_set);

    /* Execute the SQL query */
    printf("Executing SQL: %s\n", sql);
    run_sql(conn, sql);

    /* Close the connection */
    PQfinish(conn);

    return EXIT_SUCCESS;
}

static void
print_sub_create_help(void)
{
    printf("Usage: spockctrl sub create [OPTIONS]\n");
    printf("Create a new subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --provider_dsn        Provider DSN (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --replication_sets    Replication sets (optional)\n");
    printf("  --synchronize_structure Synchronize structure (optional)\n");
    printf("  --synchronize_data    Synchronize data (optional)\n");
    printf("  --forward_origins     Forward origins (optional)\n");
    printf("  --apply_delay         Apply delay (optional)\n");
    printf("  --help                Show this help message\n");
}

static void
print_sub_drop_help(void)
{
    printf("Usage: spockctrl sub drop [OPTIONS]\n");
    printf("Drop a subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_sub_enable_help(void)
{
    printf("Usage: spockctrl sub enable [OPTIONS]\n");
    printf("Enable a subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --immediate           Immediate enable (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_sub_disable_help(void)
{
    printf("Usage: spockctrl sub disable [OPTIONS]\n");
    printf("Disable a subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --db                  Database name (required)\n");
}
static void
print_sub_show_status_help(void)
{
    printf("Usage: spockctrl sub show-status [OPTIONS]\n");
    printf("Show the status of a subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_sub_show_table_help(void)
{
    printf("Usage: spockctrl sub show-table [OPTIONS]\n");
    printf("Show the table of a subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --relation            Relation name (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_sub_resync_table_help(void)
{
    printf("Usage: spockctrl sub resync-table [OPTIONS]\n");
    printf("Resync a table in a subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --relation            Relation name (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --truncate            Truncate table before resync (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_sub_add_repset_help(void)
{
    printf("Usage: spockctrl sub add-repset [OPTIONS]\n");
    printf("Add a replication set to a subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --replication_set     Replication set name (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --help                Show this help message\n");
}

static void
print_sub_remove_repset_help(void)
{
    printf("Usage: spockctrl sub remove-repset [OPTIONS]\n");
    printf("Remove a replication set from a subscription\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --sub_name            Name of the subscription (required)\n");
    printf("  --replication_set     Replication set name (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --help                Show this help message\n");
}