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