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
#include "sql.h"
#include "util.h"

void print_sql_exec_help(void);
void print_sql_help(void)
{
    printf("Usage: spockctrl sql [options]\n");
    printf("Options:\n");
    printf("  --sql      SQL statement to execute (required, must be in single or double quotes)\n");
    printf("  --node     Name of the node (optional)\n");
    printf("  --help     Show this help message\n");
    printf("\nNote: --sql must be enclosed in single or double quotes, e.g. --sql='SELECT 1' or --sql=\"SELECT 1\"\n");
}

int handle_sql_exec_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"sql",  required_argument, 0, 's'},
        {"help", no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    char   *node_name    = NULL;
    char   *sql_stmt     = NULL;
    int     option_index = 0;
    int     c            = 0;
    const char *conninfo = NULL;
    PGconn *conn         = NULL;
    PGresult *res        = NULL;

    optind = 1;
    while ((c = getopt_long(argc, argv, "n:s:h", long_options, &option_index)) != -1) {
        switch (c) {
            case 'n':
                node_name = optarg;
                break;
            case 's':
                sql_stmt = optarg;
                break;
            case 'h':
                print_sql_help();
                return EXIT_SUCCESS;
            default:
                print_sql_help();
                return EXIT_FAILURE;
        }
    }

    if (!sql_stmt) 
    {
        log_error("SQL statement is required.");
        print_sql_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node_name);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node_name ? node_name : "(default)");
        print_sql_help();
        return EXIT_FAILURE;
    }

    conn = PQconnectdb(conninfo);
    if (!conn || PQstatus(conn) != CONNECTION_OK)
    {
        log_error("Connection to database failed: %s", conn ? PQerrorMessage(conn) : "NULL connection");
        if (conn) PQfinish(conn);
        return EXIT_FAILURE;
    }
    res = PQexec(conn, sql_stmt);
    if (res == NULL || (PQresultStatus(res) != PGRES_COMMAND_OK && PQresultStatus(res) != PGRES_TUPLES_OK))
    {
        log_error("Failed to execute SQL: %s", conn != NULL ? PQerrorMessage(conn) : "NULL connection");
        if (res != NULL)
            PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    if (PQresultStatus(res) == PGRES_TUPLES_OK)
    {
        int nrows = PQntuples(res);
        int ncols = PQnfields(res);
        int row, col;

        /* Print column headers */
        for (col = 0; col < ncols; col++)
        {
            printf("%s%s", PQfname(res, col), (col < ncols - 1) ? "\t" : "\n");
        }

        /* Print rows */
        for (row = 0; row < nrows; row++)
        {
            for (col = 0; col < ncols; col++)
            {
                printf("%s%s", PQgetvalue(res, row, col), (col < ncols - 1) ? "\t" : "\n");
            }
        }
    }
    else if (PQresultStatus(res) == PGRES_COMMAND_OK)
    {
        printf("SQL executed successfully: %s\n", PQcmdStatus(res));
    }
    else
    {
        printf("SQL executed successfully.\n");
    }

    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

void print_sql_exec_help(void)
{
    // No longer used, but keep for compatibility if referenced elsewhere
    print_sql_help();
}