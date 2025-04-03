#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jansson.h>
#include "workflow.h"
#include "logger.h"

static int parse_step(json_t *step_json, Step *step);
static int parse_steps(json_t *steps_json, Step **steps, int *step_count);
static int parse_success_failure_steps(json_t *json, Step *success_step, Step *failure_step);

Workflow *
load_workflow(const char *json_file_path)
{
    Workflow *workflow;
    json_error_t error;
    json_t *json;
    json_t *workflow_name;
    json_t *description;
    json_t *steps;
    FILE *file;
    char *json_content;
    long file_size;

    /* Open the JSON file */
    file = fopen(json_file_path, "r");
    if (file == NULL)
    {
        log_error("Error: could not open JSON file: %s", json_file_path);
        return NULL;
    }

    /* Get the file size */
    fseek(file, 0, SEEK_END);
    file_size = ftell(file);
    fseek(file, 0, SEEK_SET);

    /* Allocate memory for the JSON content */
    json_content = (char *) malloc(file_size + 1);
    if (json_content == NULL)
    {
        log_error("Error: could not allocate memory for JSON content");
        fclose(file);
        return NULL;
    }

    /* Read the JSON content */
    fread(json_content, 1, file_size, file);
    json_content[file_size] = '\0';
    fclose(file);

    /* Allocate memory for the workflow structure */
    workflow = (Workflow *) malloc(sizeof(Workflow));
    if (workflow == NULL)
    {
        log_error("Error: could not allocate memory for workflow");
        free(json_content);
        return NULL;
    }

    /* Parse the JSON content */
    json = json_loads(json_content, 0, &error);
    free(json_content);
    if (!json)
    {
        log_error("Error parsing JSON: %s", error.text);
        free(workflow);
        return NULL;
    }

    /* Get the workflow name */
    workflow_name = json_object_get(json, "workflow_name");
    if (!json_is_string(workflow_name))
    {
        log_error("Error: workflow_name is not a string");
        json_decref(json);
        free(workflow);
        return NULL;
    }
    workflow->workflow_name = strdup(json_string_value(workflow_name));

    /* Get the description */
    description = json_object_get(json, "description");
    if (!json_is_string(description))
    {
        log_error("Error: description is not a string");
        json_decref(json);
        free(workflow->workflow_name);
        free(workflow);
        return NULL;
    }
    workflow->description = strdup(json_string_value(description));

    /* Get the steps */
    steps = json_object_get(json, "steps");
    if (!json_is_array(steps))
    {
        log_error("Error: steps is not an array");
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
parse_step(json_t *step_json, Step *step)
{
    json_t *name;
    json_t *description;
    json_t *command;
    json_t *args;
    json_t *options;
    json_t *on_success;
    json_t *on_failure;
    int j;

    /* Get the step name */
    name = json_object_get(step_json, "name");
    if (!json_is_string(name))
    {
        log_error("Error: step name is not a string");
        return -1;
    }
    step->name = strdup(json_string_value(name));

    /* Get the step description */
    description = json_object_get(step_json, "description");
    if (!json_is_string(description))
    {
        log_error("Error: step description is not a string");
        return -1;
    }
    step->description = strdup(json_string_value(description));

    /* Get the step command */
    command = json_object_get(step_json, "command");
    if (!json_is_string(command))
    {
        log_error("Error: step command is not a string");
        return -1;
    }
    step->command = strdup(json_string_value(command));

    /* Get the step args */
    args = json_object_get(step_json, "args");
    if (!json_is_array(args))
    {
        log_error("Error: step args is not an array");
        return -1;
    }
    for (j = 0; j < MAX_ARGS; j++)
    {
        json_t *arg = json_array_get(args, j);
        step->args[j] = arg ? strdup(json_string_value(arg)) : NULL;
    }

    /* Get the step options */
    options = json_object_get(step_json, "options");
    if (!json_is_array(options))
    {
        log_error("Error: step options is not an array");
        return -1;
    }
    for (j = 0; j < MAX_OPTIONS; j++)
    {
        json_t *option = json_array_get(options, j);
        step->options[j] = option ? strdup(json_string_value(option)) : NULL;
    }

    /* Get the step on_success */
    on_success = json_object_get(step_json, "on_success");
    if (!json_is_string(on_success))
    {
        log_error("Error: step on_success is not a string");
        return -1;
    }
    step->on_success = strdup(json_string_value(on_success));

    /* Get the step on_failure */
    on_failure = json_object_get(step_json, "on_failure");
    if (!json_is_string(on_failure))
    {
        log_error("Error: step on_failure is not a string");
        return -1;
    }
    step->on_failure = strdup(json_string_value(on_failure));

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
    if (!json_is_object(success_step_json))
    {
        log_error("Error: success_step is not an object");
        return -1;
    }
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

    failure_step_json = json_object_get(json, "failure_step");
    if (!json_is_object(failure_step_json))
    {
        log_error("Error: failure_step is not an object");
        return -1;
    }
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
        log_info("Running step: %s", step->name);
        /* Here you would add the actual execution logic for each step */
    }
    return 0;
}