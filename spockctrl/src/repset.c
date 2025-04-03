#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <getopt.h>
#include "repset.h"
#include "logger.h"

// Function declarations
int handle_repset_create_command(int argc, char *argv[]);
int handle_repset_alter_command(int argc, char *argv[]);
int handle_repset_drop_command(int argc, char *argv[]);
int handle_repset_add_table_command(int argc, char *argv[]);
int handle_repset_remove_table_command(int argc, char *argv[]);
int handle_repset_add_partition_command(int argc, char *argv[]);
int handle_repset_remove_partition_command(int argc, char *argv[]);
int handle_repset_list_tables_command(int argc, char *argv[]);

static void repset_create(int argc, char *argv[]);
static void repset_alter(int argc, char *argv[]);
static void repset_drop(int argc, char *argv[]);
static void repset_add_table(int argc, char *argv[]);
static void repset_remove_table(int argc, char *argv[]);
static void repset_add_partition(int argc, char *argv[]);
static void repset_remove_partition(int argc, char *argv[]);
static void repset_list_tables(int argc, char *argv[]);

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
    if (argc < 4)
    {
        log_error("No subcommand or node provided for repset.");
        print_repset_help();
        return EXIT_FAILURE;
    }

    if (strcmp(argv[2], "--help") == 0)
    {
        print_repset_help();
        return EXIT_SUCCESS;
    }

    if (strcmp(argv[2], "create") == 0)
    {
        return handle_repset_create_command(argc, argv);
    }
    else if (strcmp(argv[2], "alter") == 0)
    {
        return handle_repset_alter_command(argc, argv);
    }
    else if (strcmp(argv[2], "drop") == 0)
    {
        return handle_repset_drop_command(argc, argv);
    }
    else if (strcmp(argv[2], "add-table") == 0)
    {
        return handle_repset_add_table_command(argc, argv);
    }
    else if (strcmp(argv[2], "remove-table") == 0)
    {
        return handle_repset_remove_table_command(argc, argv);
    }
    else if (strcmp(argv[2], "add-partition") == 0)
    {
        return handle_repset_add_partition_command(argc, argv);
    }
    else if (strcmp(argv[2], "remove-partition") == 0)
    {
        return handle_repset_remove_partition_command(argc, argv);
    }
    else if (strcmp(argv[2], "list-tables") == 0)
    {
        return handle_repset_list_tables_command(argc, argv);
    }
    else
    {
        log_error("Unknown subcommand for repset.");
        print_repset_help();
        return EXIT_FAILURE;
    }
}

int
handle_repset_create_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"set_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"replicate_insert", required_argument, 0, 'i'},
        {"replicate_update", required_argument, 0, 'u'},
        {"replicate_delete", required_argument, 0, 'e'},
        {"replicate_truncate", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "n:s:d:i:u:e:t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_repset_create_help();
                return EXIT_SUCCESS;
            // Handle other options here
            default:
                break;
        }
    }

    if (argc < 5)
    {
        log_error("Insufficient arguments for repset create.");
        return EXIT_FAILURE;
    }
    repset_create(argc, argv);
    return EXIT_SUCCESS;
}

int
handle_repset_alter_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"set_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"replicate_insert", required_argument, 0, 'i'},
        {"replicate_update", required_argument, 0, 'u'},
        {"replicate_delete", required_argument, 0, 'e'},
        {"replicate_truncate", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "n:s:d:i:u:e:t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_repset_alter_help();
                return EXIT_SUCCESS;
            // Handle other options here
            default:
                break;
        }
    }

    if (argc < 5)
    {
        log_error("Insufficient arguments for repset alter.");
        return EXIT_FAILURE;
    }
    repset_alter(argc, argv);
    return EXIT_SUCCESS;
}

int
handle_repset_drop_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"set_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "n:s:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_repset_drop_help();
                return EXIT_SUCCESS;
            // Handle other options here
            default:
                break;
        }
    }

    if (argc < 5)
    {
        log_error("Insufficient arguments for repset drop.");
        return EXIT_FAILURE;
    }
    repset_drop(argc, argv);
    return EXIT_SUCCESS;
}

int
handle_repset_add_table_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"replication_set", required_argument, 0, 'r'},
        {"table", required_argument, 0, 'a'},
        {"db", required_argument, 0, 'd'},
        {"synchronize_data", required_argument, 0, 'y'},
        {"columns", required_argument, 0, 'c'},
        {"row_filter", required_argument, 0, 'f'},
        {"include_partitions", required_argument, 0, 'p'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "n:r:a:d:y:c:f:p:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_repset_add_table_help();
                return EXIT_SUCCESS;
            // Handle other options here
            default:
                break;
        }
    }

    if (argc < 5)
    {
        log_error("Insufficient arguments for repset add-table.");
        return EXIT_FAILURE;
    }
    repset_add_table(argc, argv);
    return EXIT_SUCCESS;
}

int
handle_repset_remove_table_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"replication_set", required_argument, 0, 'r'},
        {"table", required_argument, 0, 'a'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "n:r:a:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_repset_remove_table_help();
                return EXIT_SUCCESS;
            // Handle other options here
            default:
                break;
        }
    }

    if (argc < 5)
    {
        log_error("Insufficient arguments for repset remove-table.");
        return EXIT_FAILURE;
    }
    repset_remove_table(argc, argv);
    return EXIT_SUCCESS;
}

int
handle_repset_add_partition_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"parent_table", required_argument, 0, 'b'},
        {"db", required_argument, 0, 'd'},
        {"partition", required_argument, 0, 'q'},
        {"row_filter", required_argument, 0, 'f'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "n:b:d:q:f:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_repset_add_partition_help();
                return EXIT_SUCCESS;
            // Handle other options here
            default:
                break;
        }
    }

    if (argc < 5)
    {
        log_error("Insufficient arguments for repset add-partition.");
        return EXIT_FAILURE;
    }
    repset_add_partition(argc, argv);
    return EXIT_SUCCESS;
}

int
handle_repset_remove_partition_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"parent_table", required_argument, 0, 'b'},
        {"db", required_argument, 0, 'd'},
        {"partition", required_argument, 0, 'q'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "n:b:d:q:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_repset_remove_partition_help();
                return EXIT_SUCCESS;
            // Handle other options here
            default:
                break;
        }
    }

    if (argc < 5)
    {
        log_error("Insufficient arguments for repset remove-partition.");
        return EXIT_FAILURE;
    }
    repset_remove_partition(argc, argv);
    return EXIT_SUCCESS;
}

int
handle_repset_list_tables_command(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"node", required_argument, 0, 'n'},
        {"schema", required_argument, 0, 'm'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "n:m:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'h':
                print_repset_list_tables_help();
                return EXIT_SUCCESS;
            // Handle other options here
            default:
                break;
        }
    }

    if (argc < 5)
    {
        log_error("Insufficient arguments for repset list-tables.");
        return EXIT_FAILURE;
    }
    repset_list_tables(argc, argv);
    return EXIT_SUCCESS;
}

void
print_repset_create_help(void)
{
    printf("Usage: spockctrl repset create db [OPTIONS]\n");
    printf("Create a new replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --set_name            Name of the replication set (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --replicate_insert    Replicate insert operations (required)\n");
    printf("  --replicate_update    Replicate update operations (required)\n");
    printf("  --replicate_delete    Replicate delete operations (required)\n");
    printf("  --replicate_truncate  Replicate truncate operations (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_alter_help(void)
{
    printf("Usage: spockctrl repset alter db [OPTIONS]\n");
    printf("Alter an existing replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --set_name            Name of the replication set (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --replicate_insert    Replicate insert operations (required)\n");
    printf("  --replicate_update    Replicate update operations (required)\n");
    printf("  --replicate_delete    Replicate delete operations (required)\n");
    printf("  --replicate_truncate  Replicate truncate operations (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_drop_help(void)
{
    printf("Usage: spockctrl repset drop db [OPTIONS]\n");
    printf("Drop a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --set_name            Name of the replication set (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_add_table_help(void)
{
    printf("Usage: spockctrl repset add-table db [OPTIONS]\n");
    printf("Add a table to a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --replication_set     Name of the replication set (required)\n");
    printf("  --table               Name of the table (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --synchronize_data    Synchronize data (required)\n");
    printf("  --columns             Columns to replicate (required)\n");
    printf("  --row_filter          Row filter (required)\n");
    printf("  --include_partitions  Include partitions (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_remove_table_help(void)
{
    printf("Usage: spockctrl repset remove-table db [OPTIONS]\n");
    printf("Remove a table from a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --replication_set     Name of the replication set (required)\n");
    printf("  --table               Name of the table (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_add_partition_help(void)
{
    printf("Usage: spockctrl repset add-partition db [OPTIONS]\n");
    printf("Add a partition to a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --parent_table        Name of the parent table (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --partition           Name of the partition (required)\n");
    printf("  --row_filter          Row filter (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_remove_partition_help(void)
{
    printf("Usage: spockctrl repset remove-partition db [OPTIONS]\n");
    printf("Remove a partition from a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --parent_table        Name of the parent table (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --partition           Name of the partition (required)\n");
    printf("  --help                Show this help message\n");
}

void
print_repset_list_tables_help(void)
{
    printf("Usage: spockctrl repset list-tables db [OPTIONS]\n");
    printf("List tables in a replication set\n");
    printf("Options:\n");
    printf("  --node                Name of the node (required)\n");
    printf("  --schema              Schema name (required)\n");
    printf("  --db                  Database name (required)\n");
    printf("  --help                Show this help message\n");
}

void
repset_create(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"set_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"replicate_insert", required_argument, 0, 'i'},
        {"replicate_update", required_argument, 0, 'u'},
        {"replicate_delete", required_argument, 0, 'e'},
        {"replicate_truncate", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *set_name = NULL;
    char *db = NULL;
    char *replicate_insert = NULL;
    char *replicate_update = NULL;
    char *replicate_delete = NULL;
    char *replicate_truncate = NULL;

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "s:d:i:u:e:t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 's':
                set_name = optarg;
                break;
            case 'd':
                db = optarg;
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
                return;
            default:
                print_repset_create_help();
                return;
        }
    }

    if (!set_name || !db || !replicate_insert || !replicate_update || !replicate_delete || !replicate_truncate)
    {
        log_error("Missing required arguments for repset create.");
        return;
    }

    char *sql = make_spock_query("repset_create", "'%s', '%s', '%s', '%s', '%s'",
                                 set_name, replicate_insert, replicate_update, replicate_delete, replicate_truncate);
    if (sql)
    {
        printf("Executing SQL: %s\n", sql);
        // Execute the SQL command using your preferred method
        free(sql);
    }
}

void
repset_alter(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"set_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"replicate_insert", required_argument, 0, 'i'},
        {"replicate_update", required_argument, 0, 'u'},
        {"replicate_delete", required_argument, 0, 'e'},
        {"replicate_truncate", required_argument, 0, 't'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *set_name = NULL;
    char *db = NULL;
    char *replicate_insert = NULL;
    char *replicate_update = NULL;
    char *replicate_delete = NULL;
    char *replicate_truncate = NULL;

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "s:d:i:u:e:t:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 's':
                set_name = optarg;
                break;
            case 'd':
                db = optarg;
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
                return;
            default:
                print_repset_alter_help();
                return;
        }
    }

    if (!set_name || !db || !replicate_insert || !replicate_update || !replicate_delete || !replicate_truncate)
    {
        log_error("Missing required arguments for repset alter.");
        return;
    }

    char *sql = make_spock_query("repset_alter", "'%s', '%s', '%s', '%s', '%s'",
                                 set_name, replicate_insert, replicate_update, replicate_delete, replicate_truncate);
    if (sql)
    {
        printf("Executing SQL: %s\n", sql);
        // Execute the SQL command using your preferred method
        free(sql);
    }
}

void
repset_drop(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"set_name", required_argument, 0, 's'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *set_name = NULL;
    char *db = NULL;

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "s:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 's':
                set_name = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'h':
                print_repset_drop_help();
                return;
            default:
                print_repset_drop_help();
                return;
        }
    }

    if (!set_name || !db)
    {
        log_error("Missing required arguments for repset drop.");
        return;
    }

    char *sql = make_spock_query("repset_drop", "'%s'", set_name);
    if (sql)
    {
        printf("Executing SQL: %s\n", sql);
        // Execute the SQL command using your preferred method
        free(sql);
    }
}

void
repset_add_table(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"replication_set", required_argument, 0, 'r'},
        {"table", required_argument, 0, 'a'},
        {"db", required_argument, 0, 'd'},
        {"synchronize_data", required_argument, 0, 'y'},
        {"columns", required_argument, 0, 'c'},
        {"row_filter", required_argument, 0, 'f'},
        {"include_partitions", required_argument, 0, 'p'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *replication_set = NULL;
    char *table = NULL;
    char *db = NULL;
    char *synchronize_data = NULL;
    char *columns = NULL;
    char *row_filter = NULL;
    char *include_partitions = NULL;

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "r:a:d:y:c:f:p:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'r':
                replication_set = optarg;
                break;
            case 'a':
                table = optarg;
                break;
            case 'd':
                db = optarg;
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
                return;
            default:
                print_repset_add_table_help();
                return;
        }
    }

    if (!replication_set || !table || !db || !synchronize_data || !columns || !row_filter || !include_partitions)
    {
        log_error("Missing required arguments for repset add-table.");
        return;
    }

    char *sql = make_spock_query("repset_add_table", "'%s', '%s', '%s', '%s', '%s', '%s'",
                                 replication_set, table, synchronize_data, columns, row_filter, include_partitions);
    if (sql)
    {
        printf("Executing SQL: %s\n", sql);
        // Execute the SQL command using your preferred method
        free(sql);
    }
}

void
repset_remove_table(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"replication_set", required_argument, 0, 'r'},
        {"table", required_argument, 0, 'a'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *replication_set = NULL;
    char *table = NULL;
    char *db = NULL;

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "r:a:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'r':
                replication_set = optarg;
                break;
            case 'a':
                table = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'h':
                print_repset_remove_table_help();
                return;
            default:
                print_repset_remove_table_help();
                return;
        }
    }

    if (!replication_set || !table || !db)
    {
        log_error("Missing required arguments for repset remove-table.");
        return;
    }

    char *sql = make_spock_query("repset_remove_table", "'%s', '%s'", replication_set, table);
    if (sql)
    {
        printf("Executing SQL: %s\n", sql);
        // Execute the SQL command using your preferred method
        free(sql);
    }
}

void
repset_add_partition(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"parent_table", required_argument, 0, 'b'},
        {"db", required_argument, 0, 'd'},
        {"partition", required_argument, 0, 'q'},
        {"row_filter", required_argument, 0, 'f'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *parent_table = NULL;
    char *db = NULL;
    char *partition = NULL;
    char *row_filter = NULL;

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "b:d:q:f:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'b':
                parent_table = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'q':
                partition = optarg;
                break;
            case 'f':
                row_filter = optarg;
                break;
            case 'h':
                print_repset_add_partition_help();
                return;
            default:
                print_repset_add_partition_help();
                return;
        }
    }

    if (!parent_table || !db || !partition || !row_filter)
    {
        log_error("Missing required arguments for repset add-partition.");
        return;
    }

    char *sql = make_spock_query("repset_add_partition", "'%s', '%s', '%s'",
                                 parent_table, partition, row_filter);
    if (sql)
    {
        printf("Executing SQL: %s\n", sql);
        // Execute the SQL command using your preferred method
        free(sql);
    }
}

void
repset_remove_partition(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"parent_table", required_argument, 0, 'b'},
        {"db", required_argument, 0, 'd'},
        {"partition", required_argument, 0, 'q'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *parent_table = NULL;
    char *db = NULL;
    char *partition = NULL;

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "b:d:q:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'b':
                parent_table = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'q':
                partition = optarg;
                break;
            case 'h':
                print_repset_remove_partition_help();
                return;
            default:
                print_repset_remove_partition_help();
                return;
        }
    }

    if (!parent_table || !db || !partition)
    {
        log_error("Missing required arguments for repset remove-partition.");
        return;
    }

    char *sql = make_spock_query("repset_remove_partition", "'%s', '%s'", parent_table, partition);
    if (sql)
    {
        printf("Executing SQL: %s\n", sql);
        // Execute the SQL command using your preferred method
        free(sql);
    }
}

void
repset_list_tables(int argc, char *argv[])
{
    static struct option long_options[] = {
        {"schema", required_argument, 0, 'm'},
        {"db", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    char *schema = NULL;
    char *db = NULL;

    int option_index = 0;
    int c;
    while ((c = getopt_long(argc, argv, "m:d:h", long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'm':
                schema = optarg;
                break;
            case 'd':
                db = optarg;
                break;
            case 'h':
                print_repset_list_tables_help();
                return;
            default:
                print_repset_list_tables_help();
                return;
        }
    }

    if (!schema || !db)
    {
        log_error("Missing required arguments for repset list-tables.");
        return;
    }

    char condition[256];
    snprintf(condition, sizeof(condition), "nspname = '%s' AND relname = '%s'", schema, db);

    char *sql = make_select_query("spock.TABLES", "*", condition);
    if (sql)
    {
        printf("Executing SQL: %s\n", sql);
        // Execute the SQL command using your preferred method
        free(sql);
    }
}