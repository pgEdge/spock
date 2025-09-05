/*-------------------------------------------------------------------------
 *
 * util.c
 *      utility functions for spockctrl
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

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
#include <regex.h>

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

void
trim_newline(char *str)
{
    char *p = strchr(str, '\n');
    if (p) *p = '\0';
}

int
get_value_from_outfile(const char *node, const char *key, char *value, size_t value_sz)
{
    char    filename[256];
    FILE   *f;
    char    line[1024];
    snprintf(filename, sizeof(filename), "%s.out", node);
    f = fopen(filename, "r");
    if (!f)
        return -1;
    while (fgets(line, sizeof(line), f))
    {
        char   *eq = strchr(line, '=');
        if (!eq)
            continue;
        *eq = '\0';
        trim_newline(eq + 1);
        if (strcmp(line, key) == 0)
        {
            snprintf(value, value_sz - 1, "%s", eq + 1);
            fclose(f);
            return 0;
        }
    }
    fclose(f);
    return -1;
}

#define BUF_SZ          32768
#define NODE_MAX        128
#define KEY_MAX         128
#define VAL_MAX         4096
#define ESC_MAX         8192

static void
escape_quotes(const char *src, char *dst, size_t dst_sz)
{
	const char *p = src;
	char       *d = dst;
	while (*p && (size_t)(d - dst) < dst_sz - 2)
	{
		if (*p == '\'')
			*d++ = '\'';
		*d++ = *p++;
	}
	*d = '\0';
}

char *
substitute_sql_vars(const char *sql_stmt)
{
	static char buf[BUF_SZ];
	regex_t         re;
	const char     *pat = "\\$([A-Za-z0-9_]+)\\.([A-Za-z0-9_]+)";
	regmatch_t      m[3];
	const char     *src  = sql_stmt;
	char           *dst  = buf;
	size_t          left = sizeof(buf);
	char            node[NODE_MAX];
	char            key[KEY_MAX];
	char            val[VAL_MAX];
	char            esc[ESC_MAX];

	buf[0] = '\0';
	if (regcomp(&re, pat, REG_EXTENDED) != 0)
		return NULL;

	while (*src && left > 1)
	{
		int rc = regexec(&re, src, 3, m, 0);
		if (rc != 0)
		{
			size_t rem = strlen(src);
			if (rem >= left)
				rem = left - 1;
			memcpy(dst, src, rem);
			dst[rem] = '\0';
			break;
		}

		/* copy text before match */
		size_t pre = (size_t) m[0].rm_so;
		if (pre >= left)
			pre = left - 1;
		memcpy(dst, src, pre);
		dst   += pre;
		left -= pre;

		/* parse identifiers */
		int nlen = m[1].rm_eo - m[1].rm_so;
		int klen = m[2].rm_eo - m[2].rm_so;
		if (nlen >= NODE_MAX || klen >= KEY_MAX)
			goto fail;
		memcpy(node, src + m[1].rm_so, nlen); node[nlen] = '\0';
		memcpy(key,  src + m[2].rm_so, klen); key[klen]  = '\0';
		if (get_value_from_outfile(node, key, val, sizeof(val)) != 0)
			goto fail;
		escape_quotes(val, esc, sizeof(esc));

		/* detect if placeholder is already enclosed in single quotes */
		int quoted = (m[0].rm_so > 0 && src[m[0].rm_so - 1] == '\'' &&
				    src[m[0].rm_eo]     == '\'');

		if (!quoted)
		{
			if (left < strlen(esc) + 3)
				goto fail;
			*dst++ = '\''; left--;              /* opening quote */
			snprintf(dst, BUF_SZ, "%s", esc);
			left -= strlen(esc);
			dst  += strlen(esc);
			*dst++ = '\''; left--;              /* closing quote */
			src += m[0].rm_eo;                   /* continue after match */
		}
		else
		{
			/* opening quote already copied in pre‑text */
			if (left <= strlen(esc) + 1)
				goto fail;
			strcpy(dst, esc);
			left -= strlen(esc);
			dst  += strlen(esc);
			*dst++ = '\''; left--;              /* replicate closing quote */
			src += m[0].rm_eo + 1;              /* skip placeholder + quote */
		}
	}

	regfree(&re);
	return buf;

fail:
	regfree(&re);
	return NULL;
}
