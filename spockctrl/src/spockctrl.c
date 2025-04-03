/*-------------------------------------------------------------------------
 *
 * spockctrl.c
 *      main entry point for spockctrl command-line tool
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <getopt.h>
#include <libpq-fe.h>
#include "logger.h"
#include "node.h"
#include "repset.h"
#include "conf.h"
#include "sub.h"
#include "sql.h"
#include "workflow.h"

#define VERSION "1.0.0"
#define CONFIG_FILE "spockctrl.json"
#define DEFAULT_FORMAT "table"

static void print_help(void);
char *format = DEFAULT_FORMAT;
int verbose = 0;

static void
print_help(void)
{
    printf("Usage: spockctrl [command] [subcommand] [subcommand options] [main options]\n");
    printf("Commands:\n");
    printf("  repset     Replication set management commands\n");
    printf("  sub        Subscription management commands\n");
    printf("  node       Node management commands\n");
    printf("  sql        Execute SQL commands\n");
    printf("  help       Display this help message\n");
    printf("  version    Display the version information\n");
    printf("\n");
    printf("Main Options:\n");
    printf("  -v, --verbose       Enable verbose mode (levels: 0, 1, 2, 3)\n");
    printf("  -f, --format        Specify output format (json or table)\n");
    printf("  -c, --config        Specify the configuration file (required)\n");
    printf("  -h, --help          Show this help message\n");
}

int
main(int argc, char *argv[])
{
    char *config_file = CONFIG_FILE;
    char *workflow_file = NULL;
    const char *command;
    Workflow *workflow = NULL;

    if (argc < 2)
    {
        print_help();
        return 0;
    }
    command = argv[1];

    if (strcmp(command, "--version") == 0)
    {
        printf("spockctrl version %s\n", VERSION);
        return EXIT_SUCCESS;
    }

    for (int i = 1; i < argc; i++)
    {
        if (strncmp(argv[i], "--config=", 9) == 0)
        {
            config_file = argv[i] + 9;
        }
        else if (strcmp(argv[i], "-c") == 0)
        {
            if (i + 1 < argc)
            {
                config_file = argv[++i];
            }
            else
            {
                log_error("Option -c requires an argument.");
                print_help();
                return EXIT_FAILURE;
            }
        }
        else if (strcmp(argv[i], "-w") == 0)
        {
            if (i + 1 < argc)
            {
                workflow_file = argv[++i];
            }
        }
        else if (strncmp(argv[i], "--workflow=", 11) == 0)
        {
            workflow_file = argv[i] + 11;
        }
        else if (strcmp(argv[i], "-f") == 0)
        {
            if (i + 1 < argc)
            {
                format = argv[++i];
            }
            else
            {
                log_error("Option -f requires an argument.");
                print_help();
                return EXIT_FAILURE;
            }
        }
        else if (strncmp(argv[i], "--format=", 9) == 0)
        {
            format = argv[i] + 9;
        }
        else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0)
        {
            if (i + 1 < argc)
            {
                verbose = atoi(argv[++i]);
                if (verbose < 0 || verbose > 3)
                {
                    log_error("Invalid verbose level specified. Supported levels are: 0, 1, 2, 3");
                    print_help();
                    return EXIT_FAILURE;
                }
            }
            else
            {
                log_error("Option -v/--verbose requires an argument.");
                print_help();
                return EXIT_FAILURE;
            }
        }
    }
    if (verbose >= 1)
    {
        current_log_level = LOG_LEVEL_WARNING;
        log_warning("Verbose mode enabled. Level: %d", verbose);
    }
    if (verbose >= 2)
    {
        current_log_level = LOG_LEVEL_INFO;
        log_info("Log messages will be displayed.");
    }
    if (verbose == 3)
    {
        current_log_level = LOG_LEVEL_DEBUG0;
        log_debug0("Debug mode enabled.");
    }
    if (verbose == 4)
    {
        current_log_level = LOG_LEVEL_DEBUG1;
        log_debug1("Debug mode enabled.");
    }


    if (strcmp(format, "json") != 0 && strcmp(format, "table") != 0)
    {
        log_error("Invalid format specified. Supported formats are: json or table");
        print_help();
        return EXIT_FAILURE;
    }

    if (load_config(config_file) != 0)
    {
        log_error("Failed to load configuration file: %s", config_file);
        return EXIT_FAILURE;
    }

    if (workflow_file != NULL)
    {
        log_info("Loading workflow file: %s", workflow_file);
        workflow = load_workflow(workflow_file);
        if (workflow == NULL)
        {
            log_error("Failed to load workflow file: %s", workflow_file);
            return EXIT_FAILURE;
        }
        run_workflow(workflow);
        return EXIT_SUCCESS;
    }

    struct {
        const char *name;
        int (*handler)(int, char **);
    } commands[] = {
        {"repset", handle_repset_command},
        {"sub", handle_sub_command},
        {"node", handle_node_command},
        {"sql", handle_sql_exec_command},
        {NULL, NULL}
    };

    for (int i = 0; commands[i].name != NULL; i++)
    {
        if (strcasecmp(command, commands[i].name) == 0)
        {
            return commands[i].handler(argc - 1, &argv[1]);
        }
    }

    print_help();
    return EXIT_FAILURE;
}