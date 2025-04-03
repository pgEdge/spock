#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <getopt.h>
#include "logger.h"
#include "node.h"
#include "repset.h"
#include "conf.h"
#include "sub.h"
#include "workflow.h"

#define VERSION "1.0.0"
#define CONFIG_FILE "spockctrl.json"

static void print_help(void);

static void
print_help(void)
{
    printf("Usage: spockctrl [command] [subcommand] [subcommand options] [main options]\n");
    printf("Commands:\n");
    printf("  repset     Replication set management commands\n");
    printf("  sub        Subscription management commands\n");
    printf("  node       Node management commands\n");
    printf("  help       Display this help message\n");
    printf("  version    Display the version information\n");
    printf("\n");
    printf("Main Options:\n");
    printf("  -v, --verbose       Enable verbose mode\n");
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
    }

    log_info("Loading configuration file: %s", config_file);
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
        {NULL, NULL}
    };

    for (int i = 0; commands[i].name != NULL; i++)
    {
        if (strcmp(command, commands[i].name) == 0)
        {
            return commands[i].handler(argc - 1, &argv[1]);
        }
    }
    print_help();
    return EXIT_FAILURE;
}