/*-------------------------------------------------------------------------
 *
 * spock.c
 *      spock extension command handling functions
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libpq-fe.h>
#include <getopt.h>
#include "dbconn.h"
#include "conf.h"
#include "logger.h"

extern Config config;

static void
print_spock_wait_for_sync_event_help(void)
{
	printf("Usage: spockctrl spock wait-for-sync-event [OPTIONS]\n");
	printf("Wait for a sync event to be confirmed.\n");
	printf("Options:\n");
	printf("  --node           Name of the node (required)\n");
	printf("  --origin-name    Origin name (mutually exclusive with --origin-oid)\n");
	printf("  --origin-oid     Origin OID (mutually exclusive with --origin-name)\n");
	printf("  --lsn            LSN to wait for (required)\n");
	printf("  --timeout        Timeout in seconds (optional, default 0)\n");
	printf("  --help           Show this help message\n");
}

static void
print_spock_sync_event_help(void)
{
	printf("Usage: spockctrl spock sync-event [OPTIONS]\n");
	printf("Trigger a sync event.\n");
	printf("Options:\n");
	printf("  --node           Name of the node (required)\n");
	printf("  --help           Show this help message\n");
}

int
handle_spock_wait_for_sync_event_command(int argc, char *argv[])
{
	static struct option long_options[] = {
		{"node", required_argument, 0, 'n'},
		{"origin-name", required_argument, 0, 1},
		{"origin-oid", required_argument, 0, 2},
		{"lsn", required_argument, 0, 'l'},
		{"timeout", required_argument, 0, 't'},
		{"help", no_argument, 0, 'h'},
		{0, 0, 0, 0}
	};

	char	   *node = NULL;
	char	   *origin_name = NULL;
	char	   *origin_oid = NULL;
	char	   *lsn = NULL;
	int			timeout = 0;
	int			option_index = 0;
	int			c;
	const char *conninfo = NULL;
	PGconn	   *conn = NULL;
	char		sql[512];
	PGresult   *res = NULL;
	int			result = -1;
	const char *origin_type = NULL;
	const char *origin = NULL;

	optind = 1;
	while ((c = getopt_long(argc, argv, "n:l:t:h", long_options, &option_index)) != -1)
	{
		switch (c)
		{
			case 'n':
				node = optarg;
				break;
			case 1:
				origin_name = optarg;
				break;
			case 2:
				origin_oid = optarg;
				break;
			case 'l':
				lsn = optarg;
				break;
			case 't':
				timeout = atoi(optarg);
				break;
			case 'h':
				print_spock_wait_for_sync_event_help();
				return EXIT_SUCCESS;
			default:
				print_spock_wait_for_sync_event_help();
				return EXIT_FAILURE;
		}
	}

	if (!node || !lsn || (!origin_name && !origin_oid) || (origin_name && origin_oid))
	{
		log_error("Missing required arguments: --node, --lsn, and either --origin-name or --origin-oid (but not both) are mandatory.");
		print_spock_wait_for_sync_event_help();
		return EXIT_FAILURE;
	}

	conninfo = get_postgres_coninfo(node);
	if (conninfo == NULL)
	{
		log_error("Failed to get connection info for node '%s'.", node);
		return EXIT_FAILURE;
	}

	conn = connectdb(conninfo);
	if (conn == NULL)
	{
		log_error("Failed to connect to the database.");
		return EXIT_FAILURE;
	}

	origin_type = origin_name ? "name" : "oid";
	origin = origin_name ? origin_name : origin_oid;

	if (!conn || !origin_type || !origin || !lsn)
	{
		PQfinish(conn);
		log_error("Invalid arguments for wait_for_sync_event.");
		return EXIT_FAILURE;
	}

	if (strcmp(origin_type, "name") == 0)
	{
		snprintf(sql, sizeof(sql),
				 "SELECT spock.wait_for_sync_event('%s', '%s'::pg_lsn, %d);",
				 origin,
				 lsn,
				 timeout
			);
	}
	else if (strcmp(origin_type, "oid") == 0)
	{
		snprintf(sql, sizeof(sql),
				 "SELECT spock.wait_for_sync_event(%s::oid, '%s'::pg_lsn, %d);",
				 origin,
				 lsn,
				 timeout
			);
	}
	else
	{
		PQfinish(conn);
		log_error("Invalid origin_type: %s", origin_type);
		return EXIT_FAILURE;
	}

	res = PQexec(conn, sql);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		log_error("SQL error: %s", PQerrorMessage(conn));
		PQclear(res);
		PQfinish(conn);
		return EXIT_FAILURE;
	}

	if (PQntuples(res) == 1)
	{
		const char *val = PQgetvalue(res, 0, 0);

		result = (strcmp(val, "t") == 0 || strcmp(val, "true") == 0) ? 1 : 0;
	}
	PQclear(res);
	PQfinish(conn);

	if (result == -1)
	{
		log_error("wait_for_sync_event failed.");
		return EXIT_FAILURE;
	}
	log_debug0("wait_for_sync_event returned: %s", result ? "true" : "false");
	return result ? EXIT_SUCCESS : EXIT_FAILURE;
}

int
handle_spock_sync_event_command(int argc, char *argv[])
{
	static struct option long_options[] = {
		{"node", required_argument, 0, 'n'},
		{"help", no_argument, 0, 'h'},
		{0, 0, 0, 0}
	};

	char	   *node = NULL;
	int			option_index = 0;
	int			c;
	const char *conninfo = NULL;
	PGconn	   *conn = NULL;
	char		sql[512];
	PGresult   *res = NULL;
	int			result = -1;

	optind = 1;
	while ((c = getopt_long(argc, argv, "n:h", long_options, &option_index)) != -1)
	{
		switch (c)
		{
			case 'n':
				node = optarg;
				break;
			case 'h':
				print_spock_sync_event_help();
				return EXIT_SUCCESS;
			default:
				print_spock_sync_event_help();
				return EXIT_FAILURE;
		}
	}

	if (!node)
	{
		log_error("Missing required arguments: --node is mandatory.");
		print_spock_sync_event_help();
		return EXIT_FAILURE;
	}

	conninfo = get_postgres_coninfo(node);
	if (conninfo == NULL)
	{
		log_error("Failed to get connection info for node '%s'.", node);
		return EXIT_FAILURE;
	}

	conn = connectdb(conninfo);
	if (conn == NULL)
	{
		log_error("Failed to connect to the database.");
		return EXIT_FAILURE;
	}

	if (!conn)
	{
		PQfinish(conn);
		log_error("Invalid arguments for sync_event.");
		return EXIT_FAILURE;
	}

	snprintf(sql, sizeof(sql),
			 "SELECT spock.sync_event();");

	res = PQexec(conn, sql);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		log_error("SQL error: %s", PQerrorMessage(conn));
		PQclear(res);
		PQfinish(conn);
		return EXIT_FAILURE;
	}

	if (PQntuples(res) == 1)
	{
		const char *val = PQgetvalue(res, 0, 0);

		result = (strcmp(val, "t") == 0 || strcmp(val, "true") == 0) ? 1 : 0;
	}
	PQclear(res);
	PQfinish(conn);

	if (result == -1)
	{
		log_error("sync_event failed.");
		return EXIT_FAILURE;
	}
	log_debug0("sync_event returned: %s", result ? "true" : "false");
	return EXIT_SUCCESS;
}
