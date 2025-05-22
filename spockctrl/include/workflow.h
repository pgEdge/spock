#ifndef WORKFLOW_H
#define WORKFLOW_H

#include <jansson.h>

#define MAX_ARGS 15
#define MAX_OPTIONS 10

/* Step type constants */
#define STEP_TYPE_SPOCK 1
#define STEP_TYPE_SQL 2
#define STEP_TYPE_SHELL 3

typedef struct Step
{
    char *name;               // Name of the step
    char *node;               // Node associated with the step
    char *description;        // Description of the step
    char *command;            // Command to execute
    char *args[MAX_ARGS];     // Arguments for the command
    char *options[MAX_OPTIONS]; // Options for the command
    char *on_success;         // JSON string for on_success actions
    char *on_failure;         // JSON string for on_failure actions
    int sleep;               // Sleep time after the step
    int type;                 // Type of the step (e.g., STEP_TYPE_SPOCK, STEP_TYPE_SQL, STEP_TYPE_SHELL)
} Step;

typedef struct Workflow
{
    char *workflow_name;
    char *description;
    Step *steps;
    int step_count;
    Step success_step;
    Step failure_step;
} Workflow;

/* Function declarations */
Workflow *load_workflow(const char *json_file_path);
void free_workflow(Workflow *workflow);
int run_workflow(Workflow *workflow);

#endif /* WORKFLOW_H */