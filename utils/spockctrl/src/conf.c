/*-------------------------------------------------------------------------
 *
 * conf.c
 *      configuration file parsing and access functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jansson.h>
#include <stdbool.h>
#include "conf.h"
#include "logger.h"

static Config config;

/* Function to parse the JSON configuration file */
int
load_config(const char *filename)
{
	json_t		   *root = NULL;
	json_error_t	error;
	json_t		   *global = NULL;
	json_t		   *raled = NULL;
	json_t		   *log = NULL;
	json_t		   *spock_nodes = NULL;
	json_t		   *postgres;

    /* Load the JSON file */
    root = json_load_file(filename, 0, &error);
    if (!root)
    {
        log_error("Error loading JSON file: %s", error.text);
        return -1;
    }

    /* Parse global.raled */
    global = json_object_get(root, "global");
    if (!global)
    {
        log_error("Error: global object not found in JSON file");
        goto exit_err;
    }

    raled = json_object_get(global, "spock");
    if (!raled)
    {
        log_error("Error: spock object not found in global");
        goto exit_err;
    }


    config.raled.cluster_name = strdup(json_string_value(json_object_get(raled, "cluster_name")));
    if (!config.raled.cluster_name)
    {
        log_error("Error: memory allocation failed for cluster_name");
        goto exit_err;
    }

    config.raled.version = strdup(json_string_value(json_object_get(raled, "version")));
    if (!config.raled.version)
    {
        log_error("Error: memory allocation failed for version");
        goto exit_err;
    }

    /* Parse global.log */
    log = json_object_get(global, "log");
    if (!log)
    {
        log_error("Error: log object not found in global");
        goto exit_err;
    }

    config.log.log_level = strdup(json_string_value(json_object_get(log, "log_level")));
    if (!config.log.log_level)
    {
        log_error("Error: memory allocation failed for log_level");
        goto exit_err;
    }

    config.log.log_destination = strdup(json_string_value(json_object_get(log, "log_destination")));
    if (!config.log.log_destination)
    {
        log_error("Error: memory allocation failed for log_destination");
        goto exit_err;
    }

    config.log.log_file = strdup(json_string_value(json_object_get(log, "log_file")));
    if (!config.log.log_file)
    {
        log_error("Error: memory allocation failed for log_file");
        goto exit_err;
    }

    /* Parse spock-nodes */
    spock_nodes = json_object_get(root, "spock-nodes");
    if (!spock_nodes)
    {
        log_error("Error: spock-nodes array not found in JSON file");
        goto exit_err;
    }

    config.spock_node_count = json_array_size(spock_nodes);
    config.spock_nodes = malloc(config.spock_node_count * sizeof(SpockNodeConfig));
    if (!config.spock_nodes)
    {
        log_error("Error: memory allocation failed for spock_nodes");
        goto exit_err;
    }

    for (int i = 0; i < config.spock_node_count; i++)
    {
        json_t *node = json_array_get(spock_nodes, i);
        config.spock_nodes[i].node_name = strdup(json_string_value(json_object_get(node, "node_name")));
        if (!config.spock_nodes[i].node_name)
        {
            log_error("Error: memory allocation failed for node_name");
            goto exit_err;
        }

		postgres = json_object_get(node, "postgres");
        if (!postgres)
        {
            log_error("Error: postgres object not found in node");
            goto exit_err;
        }

        config.spock_nodes[i].postgres.postgres_ip = strdup(json_string_value(json_object_get(postgres, "postgres_ip")));
        if (!config.spock_nodes[i].postgres.postgres_ip)
        {
            log_error("Error: memory allocation failed for postgres_ip");
            goto exit_err;
        }

        config.spock_nodes[i].postgres.postgres_port = json_integer_value(json_object_get(postgres, "postgres_port"));

        config.spock_nodes[i].postgres.postgres_user = strdup(json_string_value(json_object_get(postgres, "postgres_user")));
        if (!config.spock_nodes[i].postgres.postgres_user)
        {
            log_error("Error: memory allocation failed for postgres_user");
            goto exit_err;
        }

        config.spock_nodes[i].postgres.postgres_password = strdup(json_string_value(json_object_get(postgres, "postgres_password")));
        if (!config.spock_nodes[i].postgres.postgres_password)
        {
            log_error("Error: memory allocation failed for postgres_password");
            goto exit_err;
        }

        // Parse postgres_db
        config.spock_nodes[i].postgres.postgres_db = strdup(json_string_value(json_object_get(postgres, "postgres_db")));
        if (!config.spock_nodes[i].postgres.postgres_db)
        {
            log_error("Error: memory allocation failed for postgres_db");
            goto exit_err;
        }
    }

    /* Free the JSON root object */
    json_decref(root);
    return 0;

exit_err:

    if (config.raled.cluster_name) free(config.raled.cluster_name);
    if (config.raled.version) free(config.raled.version);
    if (config.log.log_level) free(config.log.log_level);
    if (config.log.log_destination) free(config.log.log_destination);
    if (config.log.log_file) free(config.log.log_file);

    if (config.spock_nodes)
    {
        for (int i = 0; i < config.spock_node_count; i++)
        {
            if (config.spock_nodes[i].node_name) free(config.spock_nodes[i].node_name);
            if (config.spock_nodes[i].postgres.postgres_ip) free(config.spock_nodes[i].postgres.postgres_ip);
            if (config.spock_nodes[i].postgres.postgres_user) free(config.spock_nodes[i].postgres.postgres_user);
            if (config.spock_nodes[i].postgres.postgres_password) free(config.spock_nodes[i].postgres.postgres_password);
            if (config.spock_nodes[i].postgres.postgres_db) free(config.spock_nodes[i].postgres.postgres_db);
        }
        free(config.spock_nodes);
    }

    if (root) json_decref(root);

    return -1;
}

/* Function to free the allocated memory for the configuration */
void
free_config(void)
{
    free(config.raled.cluster_name);
    free(config.raled.version);
    free(config.log.log_level);
    free(config.log.log_destination);
    free(config.log.log_file);

    for (int i = 0; i < config.spock_node_count; i++)
    {
        free(config.spock_nodes[i].node_name);
        free(config.spock_nodes[i].postgres.postgres_ip);
        free(config.spock_nodes[i].postgres.postgres_user);
        free(config.spock_nodes[i].postgres.postgres_password);
        free(config.spock_nodes[i].postgres.postgres_db);
    }

    free(config.spock_nodes);
}

/* Function to get the PostgreSQL IP for a given node name */
const char *
get_postgres_ip(const char *node_name)
{
    for (int i = 0; i < config.spock_node_count; i++)
    {
        if (strcmp(config.spock_nodes[i].node_name, node_name) == 0)
        {
            return config.spock_nodes[i].postgres.postgres_ip;
        }
    }
    return NULL;
}

/* Function to get the PostgreSQL port for a given node name */
int
get_postgres_port(const char *node_name)
{
    for (int i = 0; i < config.spock_node_count; i++)
    {
        if (strcmp(config.spock_nodes[i].node_name, node_name) == 0)
        {
            return config.spock_nodes[i].postgres.postgres_port;
        }
    }
    return -1;
}

/* Function to get the PostgreSQL user for a given node name */
const char *
get_postgres_user(const char *node_name)
{
    for (int i = 0; i < config.spock_node_count; i++)
    {
        if (strcmp(config.spock_nodes[i].node_name, node_name) == 0)
        {
            return config.spock_nodes[i].postgres.postgres_user;
        }
    }
    return NULL;
}

/* Function to get the PostgreSQL password for a given node name */
const char *
get_postgres_password(const char *node_name)
{
    for (int i = 0; i < config.spock_node_count; i++)
    {
        if (strcmp(config.spock_nodes[i].node_name, node_name) == 0)
        {
            return config.spock_nodes[i].postgres.postgres_password;
        }
    }
    return NULL;
}

/* Function to get the PostgreSQL db for a given node name */
const char *
get_postgres_db(const char *node_name)
{
    for (int i = 0; i < config.spock_node_count; i++)
    {
        if (strcmp(config.spock_nodes[i].node_name, node_name) == 0)
        {
            return config.spock_nodes[i].postgres.postgres_db;
        }
    }
    return NULL;
}

const char *
get_postgres_coninfo(const char *node_name)
{
	bool		found = false;
	const char *ip;
	int			port;
	const char *user;
	const char *password;
	const char *db;
	char	   *coninfo;

    for (int i = 0; i < config.spock_node_count; i++)
    {
        if (strcmp(config.spock_nodes[i].node_name, node_name) == 0)
        {
            found = true;
        }
    }
    if (!found)
    {
        log_error("Error: node '%s' not found in configuration", node_name);
        return NULL;
    }

	ip = get_postgres_ip(node_name);
	port = get_postgres_port(node_name);
	user = get_postgres_user(node_name);
	password = get_postgres_password(node_name);
	db = get_postgres_db(node_name);

    if (!ip)
    {
        log_error("Error: IP address not found for node '%s'", node_name);
        return NULL;
    }
    if (port == -1)
    {
        log_error("Error: Port not found for node '%s'", node_name);
        return NULL;
    }
    if (!user)
    {
        log_error("Error: User not found for node '%s'", node_name);
        return NULL;
    }
    if (!password)
    {
        log_error("Error: Password not found for node '%s'", node_name);
        return NULL;
    }
    if (!db)
    {
        log_error("Error: Database not found for node '%s'", node_name);
        return NULL;
    }

    coninfo = malloc(256);
    if (!coninfo)
    {
        log_error("Error: memory allocation failed for connection info");
        return NULL;
    }
    snprintf(coninfo, 256, "host=%s port=%d user=%s password=%s dbname=%s", ip, port, user, password, db);
    return coninfo;
}