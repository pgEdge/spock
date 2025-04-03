#ifndef UTIL_H
#define UTIL_H

#include <stdarg.h>

/* Function to get the current timestamp */
char *get_current_timestamp(void);

/* Function to get the current user */
char *get_current_user(void);

/* Function to trim whitespace from a string */
char *trim_whitespace(char *str);

/* Function to convert a string to lowercase */
char *str_to_lower(char *str);

/* Function to convert a string to uppercase */
char *str_to_upper(char *str);

/* Function to create a formatted SQL string */
char *make_sql(const char *format, ...);

/* Function to create a PostgreSQL SELECT query */
char *make_select_query(const char *table, const char *columns, const char *condition);

/* Function to create a Spock-specific query with variable parameters */
char *make_spock_query(const char *command, const char *params_format, ...);

#endif /* UTIL_H */
