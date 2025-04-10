#include "util.h"
#include "logger.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pwd.h>
#include <ctype.h>
#include <stdarg.h>
#include <jansson.h>

int is_valid_json(const char *json_str)
{
    if (!json_str || strlen(json_str) == 0)
    {
        log_error("Invalid JSON: Input is empty or NULL.");
        return 0;
    }

    json_error_t error;
    json_t *json = json_loads(json_str, JSON_DECODE_ANY, &error);
    if (!json)
    {
        log_error("Invalid JSON: %s (line %d, column %d, position %d). Input: '%s'", 
                  error.text, error.line, error.column, error.position, json_str);
        return 0;
    }
    json_decref(json);
    return 1;
}

/* Function to parse a JSON file into a json_t object */
json_t *load_json_file(const char *file_path)
{
    json_error_t error;
    json_t *json = json_load_file(file_path, 0, &error);
    if (!json)
    {
        log_error("Error loading JSON file: %s (line %d, column %d).", error.text, error.line, error.column);
        return NULL;
    }
    return json;
}

/* Function to parse a JSON string into a json_t object */
json_t *parse_json_string(const char *json_str)
{
    json_error_t error;
    json_t *json = json_loads(json_str, 0, &error);
    if (!json)
    {
        log_error("Error parsing JSON string: %s (line %d, column %d).", error.text, error.line, error.column);
        return NULL;
    }
    return json;
}

/* Function to safely get a string value from a JSON object */
char *get_json_string_value(json_t *json, const char *key)
{
    json_t *value = json_object_get(json, key);
    if (!json_is_string(value))
    {
        log_error("Error: Key '%s' is not a string in JSON object.", key);
        return NULL;
    }
    return strdup(json_string_value(value));
}

/* Function to safely get an array from a JSON object */
json_t *get_json_array(json_t *json, const char *key)
{
    json_t *array = json_object_get(json, key);
    if (!json_is_array(array))
    {
        log_error("Error: Key '%s' is not an array in JSON object.", key);
        return NULL;
    }
    return array;
}

/* Function to get the current timestamp */
char *
get_current_timestamp(void)
{
    time_t     now = time(NULL);
    struct tm *t = localtime(&now);
    static char timestamp[20];

    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", t);
    return timestamp;
}

/* Function to get the current user */
char *
get_current_user(void)
{
    struct passwd *pw = getpwuid(getuid());
    return pw ? pw->pw_name : "unknown";
}

/* Function to trim whitespace from a string */
char *
trim_whitespace(char *str)
{
    char *end;

    /* Trim leading space */
    while (isspace((unsigned char) *str)) str++;

    if (*str == 0)  /* All spaces? */
        return str;

    /* Trim trailing space */
    end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char) *end)) end--;

    /* Write new null terminator */
    *(end + 1) = '\0';

    return str;
}

/* Function to convert a string to lowercase */
char *
str_to_lower(char *str)
{
    for (char *p = str; *p; ++p)
    {
        *p = tolower((unsigned char) *p);
    }
    return str;
}

/* Function to convert a string to uppercase */
char *
str_to_upper(char *str)
{
    for (char *p = str; *p; ++p)
    {
        *p = toupper((unsigned char) *p);
    }
    return str;
}

char *
make_sql(const char *format, ...)
{
    va_list args;
    va_start(args, format);

    char *sql = malloc(1024);
    if (sql == NULL)
    {
        va_end(args);
        return NULL;
    }

    vsnprintf(sql, 1024, format, args);
    va_end(args);

    return sql;
}

/* Function to create a PostgreSQL SELECT query */
char *
make_select_query(const char *table, const char *columns, const char *condition)
{
    return make_sql("SELECT %s FROM %s WHERE %s;", columns, table, condition);
}

/* Function to create a Spock-specific query with variable parameters */
char *
make_spock_query(const char *command, const char *params_format, ...)
{
    char *query = malloc(1024);
    if (!query)
    {
        log_error("Memory allocation failed for Spock query.");
        return NULL;
    }

    va_list args;
    va_start(args, params_format);
    vsnprintf(query, 1024, params_format, args);
    va_end(args);

    char *final_query = malloc(1024);
    if (!final_query)
    {
        log_error("Memory allocation failed for final Spock query.");
        free(query);
        return NULL;
    }
    snprintf(final_query, 1024, "SELECT spock.%s(%s);", command, query);
    free(query);
    return final_query;
}