/*-------------------------------------------------------------------------
 *
 * repset.c
 *      replication set management and command handling functions
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "dbconn.h"
#include <libpq-fe.h>
#include <getopt.h>
#include "repset.h"
#include "conf.h"
#include "logger.h"

static void print_repset_create_help(void);
static void print_repset_alter_help(void);
static void print_repset_drop_help(void);
static void print_repset_add_table_help(void);
static void print_repset_remove_table_help(void);
static void print_repset_add_partition_help(void);
static void print_repset_remove_partition_help(void);
static void print_repset_list_tables_help(void);

void
print_repset_help(void)
{
    printf("Usage: spockctrl repset <subcommand> [options]\n");
    printf("Subcommands:\n");
    printf("  create            Create a new replication set\n");
    printf("  alter             Alter an existing replication set\n");
    printf("  drop              Drop a replication set\n");
    printf("  add-table         Add a table to a replication set\n");
    printf("  remove-table      Remove a table from a replication set\n");
    printf("  add-partition     Add a partition to a replication set\n");
    printf("  remove-partition  Remove a partition from a replication set\n");
    printf("  list-tables       List tables in a replication set\n");
}

int
handle_repset_command(int argc, char *argv[])
{
    int i;
	struct {
		const char *cmd;
		int			(*func)(int, char *[]);
	} commands[] = {
		{"create", handle_repset_create_command},
		{"alter", handle_repset_alter_command},
		{"drop", handle_repset_drop_command},
		{"add-table", handle_repset_add_table_command},
		{"remove-table", handle_repset_remove_table_command},
		{"add-partition", handle_repset_add_partition_command},
		{"remove-partition", handle_repset_remove_partition_command},
		{"list-tables", handle_repset_list_tables_command}
	};

    if (argc < 3)
    {
        log_error("No subcommand provided for repset.");
        print_repset_help();
        return EXIT_FAILURE;
    }

    if (strcmp(argv[2], "--help") == 0)
    {
        print_repset_help();
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
    log_error("Unknown subcommand for repset...");
    print_repset_help();
    return EXIT_FAILURE;
}

int
handle_repset_create_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"set_name", required_argument, 0, 's'},
        {"replicate_insert", required_argument, 0, 'i'},
        {"replicate_update", required_argument, 0, 'u'},
        {"replicate_delete", required_argument, 0, 'e'},
        {"replicate_truncate", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *set_name = NULL;
    char *replicate_insert = NULL;
    char *replicate_update = NULL;
    char *replicate_delete = NULL;
    char *replicate_truncate = NULL;
    const char *conninfo = NULL;
    char *conninfo_allocated = NULL;
    int option_index = 0;
    int c;
	PGconn	   *conn;
	PGresult   *res;
	char		sql[2048];

    optind = 1;

    while ((c = getopt_long(argc, argv, "n:s:i:u:e:t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                set_name = optarg;
                break;
            case 'i':
                replicate_insert = optarg;
                break;
            case 'u':
                replicate_update = optarg;
                break;
            case 'e':
                replicate_delete = optarg;
                break;
            case 't':
                replicate_truncate = optarg;
                break;
            case 'h':
                print_repset_create_help();
                return EXIT_SUCCESS;
            default:
                print_repset_create_help();
                return EXIT_FAILURE;
        }
    }

    if (!node || !set_name || !replicate_insert || !replicate_update || !replicate_delete || !replicate_truncate)
    {
        log_error("Missing required arguments for repset create.");
        print_repset_create_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        free(conninfo_allocated); // Free allocated memory
        return EXIT_FAILURE;
    }

    snprintf(sql, sizeof(sql),
             "SELECT spock.repset_create("
             "set_name := '%s', "
             "replicate_insert := '%s', "
             "replicate_update := '%s', "
             "replicate_delete := '%s', "
             "replicate_truncate := '%s');",
             set_name, replicate_insert, replicate_update, replicate_delete, replicate_truncate);

    log_debug0("SQL: %s", sql);

	res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        free(conninfo_allocated); // Free allocated memory
        return EXIT_FAILURE;
    }

    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        free(conninfo_allocated); // Free allocated memory
        return EXIT_FAILURE;
    }

    PQclear(res);
    PQfinish(conn);
    free(conninfo_allocated); // Free allocated memory
    return EXIT_SUCCESS;
}

int
handle_repset_alter_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"set_name", required_argument, 0, 's'},
        {"replicate_insert", required_argument, 0, 'i'},
        {"replicate_update", required_argument, 0, 'u'},
        {"replicate_delete", required_argument, 0, 'e'},
        {"replicate_truncate", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *set_name = NULL;
    char *replicate_insert = NULL;
    char *replicate_update = NULL;
    char *replicate_delete = NULL;
    char *replicate_truncate = NULL;
    const char *conninfo = NULL;
    char *conninfo_allocated = NULL;

    int option_index = 0;
    int c;
	PGconn	   *conn;
	PGresult   *res;
	char		sql[2048];

    while ((c = getopt_long(argc, argv, "n:s:i:u:e:t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                set_name = optarg;
                break;
            case 'i':
                replicate_insert = optarg;
                break;
            case 'u':
                replicate_update = optarg;
                break;
            case 'e':
                replicate_delete = optarg;
                break;
            case 't':
                replicate_truncate = optarg;
                break;
            case 'h':
                print_repset_alter_help();
                return EXIT_SUCCESS;
            default:
                print_repset_alter_help();
                return EXIT_FAILURE;
        }
    }

    if (!node || !set_name || !replicate_insert || !replicate_update || !replicate_delete || !replicate_truncate)
    {
        log_error("Missing required arguments for repset alter.");
        print_repset_alter_help();
        return EXIT_FAILURE;
    }
    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        free(conninfo_allocated); // Free allocated memory
        return EXIT_FAILURE;
    }

    snprintf(sql, sizeof(sql),
             "SELECT spock.repset_alter("
             "set_name := '%s', "
             "replicate_insert := '%s', "
             "replicate_update := '%s', "
             "replicate_delete := '%s', "
             "replicate_truncate := '%s');",
             set_name, replicate_insert, replicate_update, replicate_delete, replicate_truncate);

    log_debug0("SQL: %s", sql);

	res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        free(conninfo_allocated);
        return EXIT_FAILURE;
    }

    PQclear(res);
    PQfinish(conn);
    free(conninfo_allocated);
    return EXIT_SUCCESS;
}

int
handle_repset_drop_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"set_name", required_argument, 0, 's'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *set_name = NULL;
    const char *conninfo = NULL;

    int option_index = 0;
    int c;
	PGconn	   *conn;
	PGresult   *res;
	char		sql[2048];

    optind = 1;
    while ((c = getopt_long(argc, argv, "n:s:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 's':
                set_name = optarg;
                break;
            case 'h':
                print_repset_drop_help();
                return EXIT_SUCCESS;
            default:
                print_repset_drop_help();
                return EXIT_FAILURE;
        }
    }

    if (!node || !set_name)
    {
        log_error("Missing required arguments for repset drop.");
        print_repset_drop_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

    conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    snprintf(sql, sizeof(sql),
             "SELECT spock.repset_drop("
             "set_name := '%s');",
             set_name);

    log_debug0("SQL: %s", sql);

	res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int
handle_repset_add_table_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"replication_set", required_argument, 0, 'r'},
        {"table", required_argument, 0, 'a'},
        {"synchronize_data", required_argument, 0, 'y'},
        {"columns", required_argument, 0, 'c'},
        {"row_filter", required_argument, 0, 'f'},
        {"include_partitions", required_argument, 0, 'p'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *replication_set = NULL;
    char *table = NULL;
    char *synchronize_data = NULL;
    char *columns = NULL;
    char *row_filter = NULL;
    char *include_partitions = NULL;
    const char *conninfo = NULL;

    int option_index = 0;
    int c;
	PGconn	   *conn;
	PGresult   *res;
	char		sql[2048];

    while ((c = getopt_long(argc, argv, "n:r:a:y:c:f:p:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 'r':
                replication_set = optarg;
                break;
            case 'a':
                table = optarg;
                break;
            case 'y':
                synchronize_data = optarg;
                break;
            case 'c':
                columns = optarg;
                break;
            case 'f':
                row_filter = optarg;
                break;
            case 'p':
                include_partitions = optarg;
                break;
            case 'h':
                print_repset_add_table_help();
                return EXIT_SUCCESS;
            default:
                print_repset_add_table_help();
                return EXIT_FAILURE;
        }
    }

    if (!node || !replication_set || !table || !synchronize_data || !columns || !row_filter || !include_partitions)
    {
        log_error("Missing required arguments for repset add-table.");
        print_repset_add_table_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

	conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    snprintf(sql, sizeof(sql),
             "SELECT spock.repset_add_table("
             "replication_set := '%s', "
             "table := '%s', "
             "synchronize_data := '%s', "
             "columns := '%s', "
             "row_filter := '%s', "
             "include_partitions := '%s');",
             replication_set, table, synchronize_data, columns, row_filter, include_partitions);

    log_debug0("SQL: %s", sql);

	res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int
handle_repset_remove_table_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"replication_set", required_argument, 0, 'r'},
        {"table", required_argument, 0, 'a'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *replication_set = NULL;
    char *table = NULL;
    const char *conninfo = NULL;

    int option_index = 0;
    int c;
	PGconn	   *conn;
	PGresult   *res;
	char		sql[2048];

    while ((c = getopt_long(argc, argv, "n:r:a:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 'r':
                replication_set = optarg;
                break;
            case 'a':
                table = optarg;
                break;
            case 'h':
                print_repset_remove_table_help();
                return EXIT_SUCCESS;
            default:
                print_repset_remove_table_help();
                return EXIT_FAILURE;
        }
    }

    if (!node || !replication_set || !table)
    {
        log_error("Missing required arguments for repset remove-table.");
        print_repset_remove_table_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

	conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    snprintf(sql, sizeof(sql),
             "SELECT spock.repset_remove_table("
             "replication_set := '%s', "
             "table := '%s');",
             replication_set, table);

    log_debug0("SQL: %s", sql);

	res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int
handle_repset_add_partition_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"parent_table", required_argument, 0, 'b'},
        {"partition", required_argument, 0, 'q'},
        {"row_filter", required_argument, 0, 'f'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *parent_table = NULL;
    char *partition = NULL;
    char *row_filter = NULL;
    const char *conninfo = NULL;

    int option_index = 0;
    int c;
	PGconn	   *conn;
	PGresult   *res;
	char		sql[2048];

    while ((c = getopt_long(argc, argv, "n:b:q:f:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 'b':
                parent_table = optarg;
                break;
            case 'q':
                partition = optarg;
                break;
            case 'f':
                row_filter = optarg;
                break;
            case 'h':
                print_repset_add_partition_help();
                return EXIT_SUCCESS;
            default:
                print_repset_add_partition_help();
                return EXIT_FAILURE;
        }
    }

    if (!node || !parent_table || !partition || !row_filter)
    {
        log_error("Missing required arguments for repset add-partition.");
        print_repset_add_partition_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

	conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    snprintf(sql, sizeof(sql),
             "SELECT spock.repset_add_partition("
             "parent_table := '%s', "
             "partition := '%s', "
             "row_filter := '%s');",
             parent_table, partition, row_filter);

    log_debug0("SQL: %s", sql);

	res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int
handle_repset_remove_partition_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"parent_table", required_argument, 0, 'b'},
        {"partition", required_argument, 0, 'q'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *parent_table = NULL;
    char *partition = NULL;
    const char *conninfo = NULL;

    int option_index = 0;
    int c;
	PGconn	   *conn;
	PGresult   *res;
	char		sql[2048];

    while ((c = getopt_long(argc, argv, "n:b:q:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 'b':
                parent_table = optarg;
                break;
            case 'q':
                partition = optarg;
                break;
            case 'h':
                print_repset_remove_partition_help();
                return EXIT_SUCCESS;
            default:
                print_repset_remove_partition_help();
                return EXIT_FAILURE;
        }
    }

    if (!node || !parent_table || !partition)
    {
        log_error("Missing required arguments for repset remove-partition.");
        print_repset_remove_partition_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

	conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    snprintf(sql, sizeof(sql),
             "SELECT spock.repset_remove_partition("
             "parent_table := '%s', "
             "partition := '%s');",
             parent_table, partition);

    log_debug0("SQL: %s", sql);

	res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int
handle_repset_list_tables_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"schema", required_argument, 0, 'm'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *node = NULL;
    char *schema = NULL;
    const char *conninfo = NULL;

    int option_index = 0;
    int c;
	PGconn	   *conn;
	PGresult   *res;
	char		sql[2048];
	char		condition[256];

    while ((c = getopt_long(argc, argv, "n:m:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'n':
                node = optarg;
                break;
            case 'm':
                schema = optarg;
                break;
            case 'h':
                print_repset_list_tables_help();
                return EXIT_SUCCESS;
            default:
                print_repset_list_tables_help();
                return EXIT_FAILURE;
        }
    }

    if (!node || !schema)
    {
        log_error("Missing required arguments for repset list-tables.");
        print_repset_list_tables_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node);
        return EXIT_FAILURE;
    }

	conn = connectdb(conninfo);
    if (conn == NULL)
    {
        log_error("Failed to connect to the database.");
        return EXIT_FAILURE;
    }

    snprintf(condition, sizeof(condition), "nspname = '%s' AND relname = '%s'", schema, node);

    snprintf(sql, sizeof(sql),
             "SELECT * FROM spock.TABLES WHERE %s;", condition);

    log_debug0("SQL: %s", sql);

	res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    if (PQntuples(res) == 0 || PQgetvalue(res, 0, 0) == NULL)
    {
        log_error("SQL function returned NULL for query: %s", sql);
        PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

void
print_repset_create_help(void)
{
    printf("Usage: spockctrl repset create [OPTIONS]\n");
    printf("Create a new replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --set_name            Name of the replication set (required)\n");
    printf("  --replicate_insert    Replicate insert operations (required)\n");
    printf("  --replicate_update    Replicate update operations (required)\n");
    printf("  --replicate_delete    Replicate delete operations (required)\n");
    printf("  --replicate_truncate  Replicate truncate operations (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_alter_help(void)
{
    printf("Usage: spockctrl repset alter [OPTIONS]\n");
    printf("Alter an existing replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --set_name            Name of the replication set (required)\n");
    printf("  --replicate_insert    Replicate insert operations (required)\n");
    printf("  --replicate_update    Replicate update operations (required)\n");
    printf("  --replicate_delete    Replicate delete operations (required)\n");
    printf("  --replicate_truncate  Replicate truncate operations (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_drop_help(void)
{
    printf("Usage: spockctrl repset drop [OPTIONS]\n");
    printf("Drop a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --set_name            Name of the replication set (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_add_table_help(void)
{
    printf("Usage: spockctrl repset add-table [OPTIONS]\n");
    printf("Add a table to a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --replication_set     Name of the replication set (required)\n");
    printf("  --table               Name of the table (required)\n");
    printf("  --synchronize_data    Synchronize data (required)\n");
    printf("  --columns             Columns to replicate (required)\n");
    printf("  --row_filter          Row filter (required)\n");
    printf("  --include_partitions  Include partitions (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_remove_table_help(void)
{
    printf("Usage: spockctrl repset remove-table [OPTIONS]\n");
    printf("Remove a table from a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --replication_set     Name of the replication set (required)\n");
    printf("  --table               Name of the table (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_add_partition_help(void)
{
    printf("Usage: spockctrl repset add-partition [OPTIONS]\n");
    printf("Add a partition to a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --parent_table        Name of the parent table (required)\n");
    printf("  --partition           Name of the partition (required)\n");
    printf("  --row_filter          Row filter (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_remove_partition_help(void)
{
    printf("Usage: spockctrl repset remove-partition [OPTIONS]\n");
    printf("Remove a partition from a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --parent_table        Name of the parent table (required)\n");
    printf("  --partition           Name of the partition (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_list_tables_help(void)
{
    printf("Usage: spockctrl repset list-tables [OPTIONS]\n");
    printf("List tables in a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --schema              Schema name (required)\n");
    printf("  --help                Show this help message\n");
}