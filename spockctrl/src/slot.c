/*-------------------------------------------------------------------------
 *
 * slot.c
 *      replication slot management and command handling functions
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
#include "slot.h"

void print_slot_create_help(void);
void print_slot_drop_help(void);
void print_slot_enable_help(void);
void print_slot_disable_help(void);

void print_slot_help(void)
{
    printf("Usage: spockctrl slot <subcommand> [options]\n");
    printf("Subcommands:\n");
    printf("  create   Create a replication slot\n");
    printf("  drop     Drop a replication slot\n");
    printf("  enable   Enable a replication slot\n");
    printf("  disable  Disable a replication slot\n");
    printf("  --help   Show this help message\n");
}

int handle_slot_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    struct {
        const char *cmd;
        int (*func)(int, char *[]);
    } commands[] = {
        {"create", handle_slot_create_command},
        {"drop", handle_slot_drop_command},
        {"enable", handle_slot_enable_command},
        {"disable", handle_slot_disable_command},
    };

    int option_index = 0;
    int c;

    if (argc < 2) {
        log_error("No subcommand provided for slot.");
        print_slot_help();
        return EXIT_FAILURE;
    }

    for (size_t i = 0; i < sizeof(commands)/sizeof(commands[0]); i++) {
        if (strcmp(argv[1], commands[i].cmd) == 0)
            return commands[i].func(argc, argv);
    }

    while ((c = getopt_long(argc, argv, "h", long_options, &option_index)) != -1) {
        switch (c) {
            case 'h':
                print_slot_help();
                return EXIT_SUCCESS;
            default:
                print_slot_help();
                return EXIT_FAILURE;
        }
    }

    log_error("Unknown subcommand for slot.");
    print_slot_help();
    return EXIT_FAILURE;
}

int handle_slot_create_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node",      required_argument, 0, 'n'},
        {"slot",      required_argument, 0, 's'},
        {"plugin",    required_argument, 0, 'p'},
        {"temporary", no_argument,       0, 't'},
        {"help",      no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    char   *slot_name   = NULL;
    char   *node_name   = NULL;
    char   *plugin_name = "spock_output";
    int     temporary   = 0;
    int     option_index= 0;
    int     c           = 0;
    const char *conninfo= NULL;
    PGconn *conn        = NULL;
    char    query[512];
    PGresult *res       = NULL;

    optind = 1;
    while ((c = getopt_long(argc, argv, "n:s:p:th", long_options, &option_index)) != -1) {
        switch (c) {
            case 'n':
                node_name = optarg;
                break;
            case 's':
                slot_name = optarg;
                break;
            case 'p':
                plugin_name = optarg;
                break;
            case 't':
                temporary = 1;
                break;
            case 'h':
                print_slot_create_help();
                return EXIT_SUCCESS;
            default:
                print_slot_create_help();
                return EXIT_FAILURE;
        }
    }

    if (!slot_name) {
        log_error("Slot name is required for create.");
        print_slot_create_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node_name);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node_name ? node_name : "(default)");
        print_slot_create_help();
        return EXIT_FAILURE;
    }

    conn = PQconnectdb(conninfo);
    if (!conn || PQstatus(conn) != CONNECTION_OK)
    {
        log_error("Connection to database failed: %s", conn ? PQerrorMessage(conn) : "NULL connection");
        if (conn) PQfinish(conn);
        return EXIT_FAILURE;
    }
    /* Build the SQL query */
    snprintf(query, sizeof(query),
             "SELECT pg_create_logical_replication_slot("
             "slot_name := '%s', "
             "plugin := '%s', "
             "temporary := %s);",
             slot_name,
             plugin_name,
             temporary ? "true" : "false");

    res = PQexec(conn, query);
    if (!res || PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("Failed to create replication slot: %s", conn ? PQerrorMessage(conn) : "NULL connection");
        log_error("SQL: %s", query);
        if (res) PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }
    PQclear(res);
    PQfinish(conn);
    return EXIT_SUCCESS;
}

int handle_slot_drop_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"slot", required_argument, 0, 's'},
        {"help", no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    char   *slot_name    = NULL;
    char   *node_name    = NULL;
    int     option_index = 0;
    int     c            = 0;
    const char *conninfo = NULL;
    PGconn *conn         = NULL;
    char    query[256];
    PGresult *res        = NULL;

    optind = 2;
    while ((c = getopt_long(argc, argv, "s:h", long_options, &option_index)) != -1) {
        switch (c) {
            case 's':
                slot_name = optarg;
                break;
            case 'h':
                print_slot_drop_help();
                return EXIT_SUCCESS;
            default:
                print_slot_drop_help();
                return EXIT_FAILURE;
        }
    }

    if (!slot_name) {
        log_error("Slot name is required for drop.");
        print_slot_drop_help();
        return EXIT_FAILURE;
    }

    conninfo = get_postgres_coninfo(node_name);
    if (conninfo == NULL)
    {
        log_error("Failed to get connection info for node '%s'.", node_name ? node_name : "(default)");
        print_slot_drop_help();
        return EXIT_FAILURE;
    }

    conn = PQconnectdb(conninfo);
    if (!conn || PQstatus(conn) != CONNECTION_OK)
    {
        log_error("Connection to database failed: %s", conn ? PQerrorMessage(conn) : "NULL connection");
        if (conn) PQfinish(conn);
        return EXIT_FAILURE;
    }

    snprintf(query, sizeof(query),
             "SELECT pg_drop_replication_slot('%s');",
             slot_name);

    res = PQexec(conn, query);
    if (!res || PQresultStatus(res) != PGRES_COMMAND_OK)
    {
        log_error("Failed to drop replication slot: %s", conn ? PQerrorMessage(conn) : "NULL connection");
        if (res) PQclear(res);
        PQfinish(conn);
        return EXIT_FAILURE;
    }

    printf("Replication slot dropped: %s\n", slot_name);

    PQclear(res);
    PQfinish(conn);

    return EXIT_SUCCESS;
}

int handle_slot_enable_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"slot", required_argument, 0, 's'},
        {"help", no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    char   *slot_name    = NULL;
    int     option_index = 0;
    int     c            = 0;

    optind = 2;
    while ((c = getopt_long(argc, argv, "s:h", long_options, &option_index)) != -1) {
        switch (c) {
            case 's':
                slot_name = optarg;
                break;
            case 'h':
                print_slot_enable_help();
                return EXIT_SUCCESS;
            default:
                print_slot_enable_help();
                return EXIT_FAILURE;
        }
    }

    if (!slot_name) {
        log_error("Slot name is required for enable.");
        print_slot_enable_help();
        return EXIT_FAILURE;
    }

    printf("Enabling replication slot: %s (no-op, not implemented)\n", slot_name);
    return EXIT_SUCCESS;
}

int handle_slot_disable_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"slot", required_argument, 0, 's'},
        {"help", no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    char   *slot_name    = NULL;
    int     option_index = 0;
    int     c            = 0;

    optind = 2;
    while ((c = getopt_long(argc, argv, "s:h", long_options, &option_index)) != -1) {
        switch (c) {
            case 's':
                slot_name = optarg;
                break;
            case 'h':
                print_slot_disable_help();
                return EXIT_SUCCESS;
            default:
                print_slot_disable_help();
                return EXIT_FAILURE;
        }
    }

    if (!slot_name) {
        log_error("Slot name is required for disable.");
        print_slot_disable_help();
        return EXIT_FAILURE;
    }

    printf("Disabling replication slot: %s (no-op, not implemented)\n", slot_name);
    return EXIT_SUCCESS;
}

void print_slot_create_help(void)
{
    printf("Usage: spockctrl slot create --node <node_name> --slot <slot_name> [--plugin <plugin_name>] [--temporary]\n");
    printf("Create a replication slot\n");
    printf("Options:\n");
    printf("  --node       Name of the node (optional)\n");
    printf("  --slot       Name of the replication slot (required)\n");
    printf("  --plugin     Output plugin to use (default: test_decoding)\n");
    printf("  --temporary  Create a temporary slot (optional)\n");
    printf("  --help       Show this help message\n");
}

void print_slot_drop_help(void)
{
    printf("Usage: spockctrl slot drop --slot <slot_name>\n");
    printf("Drop a replication slot\n");
    printf("Options:\n");
    printf("  --slot     Name of the replication slot (required)\n");
    printf("  --help     Show this help message\n");
}

void print_slot_enable_help(void)
{
    printf("Usage: spockctrl slot enable --slot <slot_name>\n");
    printf("Enable a replication slot (no-op)\n");
    printf("Options:\n");
    printf("  --slot     Name of the replication slot (required)\n");
    printf("  --help     Show this help message\n");
}

void print_slot_disable_help(void)
{
    printf("Usage: spockctrl slot disable --slot <slot_name>\n");
    printf("Disable a replication slot (no-op)\n");
    printf("Options:\n");
    printf("  --slot     Name of the replication slot (required)\n");
    printf("  --help     Show this help message\n");
}
