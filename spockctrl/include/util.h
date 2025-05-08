#ifndef UTIL_H
#define UTIL_H

#include <stdarg.h>
#include <jansson.h>

/* JSON utility functions */
int is_valid_json(const char *json_str);
json_t *load_json_file(const char *file_path);
json_t *parse_json_string(const char *json_str);
char *get_json_string_value(json_t *json, const char *key);
json_t *get_json_array(json_t *json, const char *key);

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

/* Function to create a Spock-specific query with variable parameters */
void trim_newline(char *str);

/* Function to substitute SQL variables with values from node.out */
int get_value_from_outfile(const char *node, const char *key, char *value, size_t value_sz);

/* Function to substitute SQL variables in a statement */
char *substitute_sql_vars(const char *sql_stmt);

#endif /* UTIL_H */
