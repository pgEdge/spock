#ifndef WORKFLOW_H
#define WORKFLOW_H

#include <jansson.h>

#define MAX_ARGS 10
#define MAX_OPTIONS 10

typedef struct {
    char *name;
    char *description;
    char *command;
    char *args[MAX_ARGS];
    char *options[MAX_OPTIONS];
    char *on_success;
    char *on_failure;
} Step;

typedef struct {
    char *workflow_name;
    char *description;
    Step *steps;
    int step_count;
    Step success_step;
    Step failure_step;
} Workflow;

/**
 * Parses the JSON content and populates the Workflow structure.
 * 
 * @param json_content The JSON content as a string.
 * @return A pointer to the populated Workflow structure, or NULL on error.
 */
Workflow* load_workflow(const char *json_content);

/**
 * Frees the memory allocated for the Workflow structure and its steps.
 * 
 * @param workflow A pointer to the Workflow structure to be freed.
 */
void free_workflow(Workflow *workflow);

/**
 * Executes the workflow steps in sequence.
 * 
 * @param workflow A pointer to the Workflow structure to be executed.
 * @return 0 on success, non-zero on failure.
 */
int run_workflow(Workflow *workflow);

#endif /* WORKFLOW_H */