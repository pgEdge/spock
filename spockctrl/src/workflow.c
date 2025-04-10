#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jansson.h>
#include "workflow.h"
#include "node.h"
#include "sub.h"
#include "logger.h"
#include "util.h"

/* Function declarations */
static int prepare_arguments(Step *step, char *argv[], int max_args, const char *default_db);
static int parse_step(json_t *step_json, Step *step);
static int parse_spock_step(json_t *spock, Step *step);
static int parse_sql_step(json_t *sql, Step *step);
static int parse_shell_step(json_t *shell, Step *step);
static int parse_steps(json_t *steps_json, Step **steps, int *step_count);
static int parse_success_failure_steps(json_t *json, Step *success_step, Step *failure_step);
static int execute_step(Step *step, int step_index);

int
handle_spock_command(Step *step);

/* Helper function to prepare arguments */
static int prepare_arguments(Step *step, char *argv[], int max_args, const char *default_db)
{
    int argc = 0;

    argv[argc++] = "spockctrl";
    argv[argc] = malloc(256); /* Allocate memory for the string */
    if (argv[argc] == NULL)
    {
        log_error("Error: could not allocate memory for argument");
        return -1;
    }
    snprintf(argv[argc++], 256, "--node=%s", step->node);

    /* Add the step arguments */
    for (int i = 0; step->args[i] != NULL && argc < max_args - 1; i++)
    {
        argv[argc++] = step->args[i];
    }
    argv[argc] = NULL; /* Null-terminate the array */

    return argc; /* Return the argument count */
}

Workflow *
load_workflow(const char *json_file_path)
{
    Workflow *workflow;
    json_t *json;
    json_t *steps;

    /* Load the JSON file */
    json = load_json_file(json_file_path);
    if (!json)
    {
        return NULL;
    }

    /* Allocate memory for the workflow structure */
    workflow = (Workflow *) malloc(sizeof(Workflow));
    if (workflow == NULL)
    {
        log_error("Error: could not allocate memory for workflow");
        json_decref(json);
        return NULL;
    }

    /* Get the workflow name */
    workflow->workflow_name = get_json_string_value(json, "workflow_name");
    if (!workflow->workflow_name)
    {
        json_decref(json);
        free(workflow);
        return NULL;
    }

    /* Get the description */
    workflow->description = get_json_string_value(json, "description");
    if (!workflow->description)
    {
        json_decref(json);
        free(workflow->workflow_name);
        free(workflow);
        return NULL;
    }

    /* Get the steps */
    steps = get_json_array(json, "steps");
    if (!steps)
    {
        json_decref(json);
        free(workflow->workflow_name);
        free(workflow->description);
        free(workflow);
        return NULL;
    }

    if (parse_steps(steps, &workflow->steps, &workflow->step_count) != 0)
    {
        json_decref(json);
        free(workflow->workflow_name);
        free(workflow->description);
        free(workflow);
        return NULL;
    }

    if (parse_success_failure_steps(json, &workflow->success_step, &workflow->failure_step) != 0)
    {
        json_decref(json);
        free_workflow(workflow);
        return NULL;
    }

    json_decref(json);
    return workflow;
}

static int
parse_spock_step(json_t *spock, Step *step)
{
    json_t *command, *description, *args, *node, *name;
    int j;

    step->type = STEP_TYPE_SPOCK;

    /* Get the step name */
    name = json_object_get(spock, "name");
    if (name && json_is_string(name))
    {
        step->name = strdup(json_string_value(name));
    }
    else
    {
        step->name = NULL; /* Default to NULL if not provided */
    }

    /* Get the step command */
    command = json_object_get(spock, "command");
    if (!json_is_string(command))
    {
        log_error("Error: spock step command is not a string");
        return -1;
    }
    step->command = strdup(json_string_value(command));

    /* Get the step description */
    description = json_object_get(spock, "description");
    if (!json_is_string(description))
    {
        log_error("Error: spock step description is not a string");
        return -1;
    }
    step->description = strdup(json_string_value(description));

    /* Get the step args */
    args = json_object_get(spock, "args");
    if (!json_is_array(args))
    {
        log_error("Error: spock step args is not an array");
        return -1;
    }
    for (j = 0; j < MAX_ARGS; j++)
    {
        json_t *arg = json_array_get(args, j);
        step->args[j] = arg ? strdup(json_string_value(arg)) : NULL;
    }

    /* Get the node field */
    node = json_object_get(spock, "node");
    if (node && json_is_string(node))
    {
        step->node = strdup(json_string_value(node));
    }
    else
    {
        step->node = NULL; /* Default to NULL if not provided */
    }

    return 0;
}

static int
parse_sql_step(json_t *sql, Step *step)
{
    json_t *command, *description, *name;

    step->type = STEP_TYPE_SQL;

    /* Get the step name */
    name = json_object_get(sql, "name");
    if (name && json_is_string(name))
    {
        step->name = strdup(json_string_value(name));
    }
    else
    {
        step->name = NULL; /* Default to NULL if not provided */
    }

    /* Get the SQL command */
    command = json_object_get(sql, "command");
    if (!json_is_string(command))
    {
        log_error("Error: sql step command is not a string");
        return -1;
    }
    step->command = strdup(json_string_value(command));

    /* Get the step description */
    description = json_object_get(sql, "description");
    if (!json_is_string(description))
    {
        log_error("Error: sql step description is not a string");
        return -1;
    }
    step->description = strdup(json_string_value(description));

    return 0;
}

static int
parse_shell_step(json_t *shell, Step *step)
{
    json_t *command, *description, *name;

    step->type = STEP_TYPE_SHELL;

    /* Get the step name */
    name = json_object_get(shell, "name");
    if (name && json_is_string(name))
    {
        step->name = strdup(json_string_value(name));
    }
    else
    {
        step->name = NULL; /* Default to NULL if not provided */
    }

    /* Get the shell command */
    command = json_object_get(shell, "command");
    if (!json_is_string(command))
    {
        log_error("Error: shell step command is not a string");
        return -1;
    }
    step->command = strdup(json_string_value(command));

    /* Get the step description */
    description = json_object_get(shell, "description");
    if (!json_is_string(description))
    {
        log_error("Error: shell step description is not a string");
        return -1;
    }
    step->description = strdup(json_string_value(description));

    return 0;
}

static int
parse_step(json_t *step_json, Step *step)
{
    json_t *spock, *sql, *shell, *on_success, *on_failure;

    /* Check for spock step */
    spock = json_object_get(step_json, "spock");
    if (spock && json_is_object(spock))
    {
        if (parse_spock_step(spock, step) != 0)
            return -1;
    }
    /* Check for sql step */
    else if ((sql = json_object_get(step_json, "sql")) && json_is_object(sql))
    {
        if (parse_sql_step(sql, step) != 0)
            return -1;
    }
    /* Check for shell step */
    else if ((shell = json_object_get(step_json, "shell")) && json_is_object(shell))
    {
        if (parse_shell_step(shell, step) != 0)
            return -1;
    }
    else
    {
        log_error("Error: unknown step type");
        return -1;
    }

    /* Get the step on_success */
    on_success = json_object_get(step_json, "on_success");
    if (on_success && json_is_object(on_success))
    {
        step->on_success = strdup(json_dumps(on_success, JSON_COMPACT));
    }
    else
    {
        step->on_success = NULL; /* Default to NULL if not provided or invalid */
    }

    /* Get the step on_failure */
    on_failure = json_object_get(step_json, "on_failure");
    if (on_failure && json_is_object(on_failure))
    {
        step->on_failure = strdup(json_dumps(on_failure, JSON_COMPACT));
    }
    else
    {
        step->on_failure = NULL; /* Default to NULL if not provided or invalid */
    }

    return 0;
}

static int
parse_steps(json_t *steps_json, Step **steps, int *step_count)
{
    int i;

    *step_count = json_array_size(steps_json);
    *steps = (Step *) malloc(*step_count * sizeof(Step));
    if (*steps == NULL)
    {
        log_error("Error: could not allocate memory for steps");
        return -1;
    }

    for (i = 0; i < *step_count; i++)
    {
        json_t *step_json = json_array_get(steps_json, i);
        if (parse_step(step_json, &(*steps)[i]) != 0)
        {
            return -1;
        }
    }

    return 0;
}

static int
parse_success_failure_steps(json_t *json, Step *success_step, Step *failure_step)
{
    json_t *success_step_json;
    json_t *failure_step_json;
    int j;

    success_step_json = json_object_get(json, "success_step");
    if (success_step_json && json_is_object(success_step_json) && json_object_size(success_step_json) > 0)
    {
        success_step->name = strdup(json_string_value(json_object_get(success_step_json, "name")));
        success_step->description = strdup(json_string_value(json_object_get(success_step_json, "description")));
        success_step->command = strdup(json_string_value(json_object_get(success_step_json, "command")));
        for (j = 0; j < MAX_ARGS; j++)
        {
            json_t *arg = json_array_get(json_object_get(success_step_json, "args"), j);
            success_step->args[j] = arg ? strdup(json_string_value(arg)) : NULL;
        }
        for (j = 0; j < MAX_OPTIONS; j++)
        {
            json_t *option = json_array_get(json_object_get(success_step_json, "options"), j);
            success_step->options[j] = option ? strdup(json_string_value(option)) : NULL;
        }
    }
    else
    {
        /* Initialize success_step as empty */
        success_step->name = NULL;
        success_step->description = NULL;
        success_step->command = NULL;
        for (j = 0; j < MAX_ARGS; j++)
        {
            success_step->args[j] = NULL;
        }
        for (j = 0; j < MAX_OPTIONS; j++)
        {
            success_step->options[j] = NULL;
        }
    }

    failure_step_json = json_object_get(json, "failure_step");
    if (failure_step_json && json_is_object(failure_step_json) && json_object_size(failure_step_json) > 0)
    {
        failure_step->name = strdup(json_string_value(json_object_get(failure_step_json, "name")));
        failure_step->description = strdup(json_string_value(json_object_get(failure_step_json, "description")));
        failure_step->command = strdup(json_string_value(json_object_get(failure_step_json, "command")));
        for (j = 0; j < MAX_ARGS; j++)
        {
            json_t *arg = json_array_get(json_object_get(failure_step_json, "args"), j);
            failure_step->args[j] = arg ? strdup(json_string_value(arg)) : NULL;
        }
        for (j = 0; j < MAX_OPTIONS; j++)
        {
            json_t *option = json_array_get(json_object_get(failure_step_json, "options"), j);
            failure_step->options[j] = option ? strdup(json_string_value(option)) : NULL;
        }
    }
    else
    {
        /* Initialize failure_step as empty */
        failure_step->name = NULL;
        failure_step->description = NULL;
        failure_step->command = NULL;
        for (j = 0; j < MAX_ARGS; j++)
        {
            failure_step->args[j] = NULL;
        }
        for (j = 0; j < MAX_OPTIONS; j++)
        {
            failure_step->options[j] = NULL;
        }
    }

    return 0;
}

void
free_workflow(Workflow *workflow)
{
    int i, j;

    free(workflow->workflow_name);
    free(workflow->description);

    for (i = 0; i < workflow->step_count; i++)
    {
        Step *step = &workflow->steps[i];
        free(step->name);
        free(step->description);
        free(step->command);
        for (j = 0; j < MAX_ARGS; j++)
        {
            free(step->args[j]);
        }
        for (j = 0; j < MAX_OPTIONS; j++)
        {
            free(step->options[j]);
        }
        free(step->on_success);
        free(step->on_failure);
    }
    free(workflow->steps);

    free(workflow->success_step.name);
    free(workflow->success_step.description);
    free(workflow->success_step.command);
    for (j = 0; j < MAX_ARGS; j++)
    {
        free(workflow->success_step.args[j]);
    }
    for (j = 0; j < MAX_OPTIONS; j++)
    {
        free(workflow->success_step.options[j]);
    }

    free(workflow->failure_step.name);
    free(workflow->failure_step.description);
    free(workflow->failure_step.command);
    for (j = 0; j < MAX_ARGS; j++)
    {
        free(workflow->failure_step.args[j]);
    }
    for (j = 0; j < MAX_OPTIONS; j++)
    {
        free(workflow->failure_step.options[j]);
    }
}

int
run_workflow(Workflow *workflow)
{
    int i;

    for (i = 0; i < workflow->step_count; i++)
    {
        Step *step = &workflow->steps[i];

        int step_result = execute_step(step, i);

        /* Log step result */
        if (step_result == 0)
        {
            log_msg("[Step - %d] %s [OK]", i + 1, step->description);
        }
        else
        {
            log_error("[Step - %d] %s [FAILED]", i + 1, step->description);
            //return -1; /* Stop execution on failure */
        }

        /* Handle on_success and on_failure (currently placeholders) */
        if (step->on_success && strlen(step->on_success) > 0)
        {
            log_info("On success: %s", step->on_success);
        }
        if (step->on_failure && strlen(step->on_failure) > 0)
        {
            log_info("On failure: %s", step->on_failure);
        }
    }

    return 0;
}

static int
execute_step(Step *step, int step_index)
{
    /* Prepare arguments for the command */
    if (step->type == STEP_TYPE_SPOCK)
    {
        return handle_spock_command(step);
    }
    else if (step->type == STEP_TYPE_SQL)
    {
        //return handle_sql_command(argc, argv);
    }
    else if (step->type == STEP_TYPE_SHELL)
    {
        //return handle_shell_command(argc, argv);
    }
    return 0;
}
int
handle_spock_command(Step *step)
{
    char *argv[MAX_ARGS + 1];
    int argc;

    /* Prepare arguments for the command */
    if ((argc = prepare_arguments(step, argv, MAX_ARGS + 1, NULL)) < 0)
    {
        log_error("Failed to prepare arguments");
        return -1;
    }

    /* Debug: Print the prepared arguments */
    for (int i = 0; i < argc; i++)
    {
        log_debug1("Argument[%d]: %s", i, argv[i]);
    }

    /* Handle specific commands */
    if (strcmp(step->command, "CREATE NODE") == 0)
    {
        return handle_node_create_command(argc, argv);
    }
    else if (strcmp(step->command, "CREATE SUBSCRIPTION") == 0)
    {
        return handle_sub_create_command(argc, argv);
    }
    else if (strcmp(step->command, "DROP SUBSCRIPTION") == 0)
    {
        return handle_sub_drop_command(argc, argv);
    }
    else if (strcmp(step->command, "DROP NODE") == 0)
    {
        return handle_node_drop_command(argc, argv);
    }
    else
    {
        log_error("Unknown command: %s", step->command);
        return -1;
    }
}
