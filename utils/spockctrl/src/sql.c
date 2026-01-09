/*-------------------------------------------------------------------------
 *
 * sql.c
 * 		spockctrl SQL execution utilities
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <getopt.h>
#include <stdbool.h>
#include <libpq-fe.h>
#include <regex.h>
#include "dbconn.h"
#include "conf.h"
#include "sub.h"
#include "logger.h"
#include "sql.h"
#include "util.h"


void
print_sql_help(void)
{
	printf("Usage: spockctrl sql [options]\n");
	printf("Options:\n");
	printf("  --sql      SQL statement to execute (required, must be in single or double quotes)\n");
	printf("  --node     Name of the node (optional)\n");
	printf("  --help     Show this help message\n");
	printf("\nNote: --sql must be enclosed in single or double quotes, e.g. --sql='SELECT 1' or --sql=\"SELECT 1\"\n");
}

int
handle_sql_exec_command(int argc, char *argv[])
{
	static struct option long_options[] = {
		{"node", required_argument, 0, 'n'},
		{"sql", required_argument, 0, 's'},
		{"help", no_argument, 0, 'h'},
		{"ignore-errors", no_argument, 0, 'i'},
		{0, 0, 0, 0}
	};

	char	   *node_name = NULL;
	char	   *sql_stmt = NULL;
	int			option_index = 0;
	int			c = 0;
	const char *conninfo = NULL;
	PGconn	   *conn = NULL;
	PGresult   *res = NULL;
	char		out_filename[256];
	FILE	   *outf = NULL;
	int			nrows;
	int			ncols;
	int			row;
	int			col;
	bool		ignore_errors = false;
	char	   *sub_sql;

	optind = 1;
	while ((c = getopt_long(argc, argv, "n:s:hi", long_options, &option_index)) != -1)
	{
		switch (c)
		{
			case 'n':
				node_name = optarg;
				break;
			case 's':
				sql_stmt = optarg;
				break;
			case 'h':
				print_sql_help();
				return EXIT_SUCCESS;
			case 'i':
				ignore_errors = true;
				break;
			default:
				print_sql_help();
				return EXIT_FAILURE;
		}
	}
	if (!sql_stmt)
	{
		log_error("SQL statement is required.");
		print_sql_help();
		return EXIT_FAILURE;
	}

	sub_sql = substitute_sql_vars(sql_stmt);
	if (sub_sql == NULL || strlen(sub_sql) == 0)
		sub_sql = (char *) sql_stmt;

	conninfo = get_postgres_coninfo(node_name);
	if (conninfo == NULL)
	{
		log_error("Failed to get connection info for node '%s'.", node_name ? node_name : "(default)");
		print_sql_help();
		return ignore_errors ? EXIT_SUCCESS : EXIT_FAILURE;
		/* Handle ignore - errors */
	}

	conn = PQconnectdb(conninfo);
	if (!conn || PQstatus(conn) != CONNECTION_OK)
	{
		log_error("Connection to database failed: %s", conn ? PQerrorMessage(conn) : "NULL connection");
		if (conn)
			PQfinish(conn);
		return ignore_errors ? EXIT_SUCCESS : EXIT_FAILURE;
		/* Handle ignore - errors */
	}

	res = PQexec(conn, sub_sql);
	if (res == NULL || (PQresultStatus(res) != PGRES_COMMAND_OK && PQresultStatus(res) != PGRES_TUPLES_OK))
	{
		if (!ignore_errors)
			log_error("Failed to execute SQL: %s", conn != NULL ? PQerrorMessage(conn) : "NULL connection");
		if (res != NULL)
			PQclear(res);
		PQfinish(conn);
		return ignore_errors ? EXIT_SUCCESS : EXIT_FAILURE;
		/* Handle ignore - errors */
	}

	/* Prepare output file name */
	snprintf(out_filename, sizeof(out_filename), "%s.out", node_name ? node_name : "default");
	outf = fopen(out_filename, "w");
	if (!outf)
	{
		log_error("Could not open output file '%s' for writing.", out_filename);
		PQclear(res);
		PQfinish(conn);
		return ignore_errors ? EXIT_SUCCESS : EXIT_FAILURE;
		/* Handle ignore - errors */
	}

	if (PQresultStatus(res) == PGRES_TUPLES_OK)
	{
		nrows = PQntuples(res);
		ncols = PQnfields(res);

		/* Print column headers */
		for (col = 0; col < ncols; col++)
		{
			log_debug0("%s%s", PQfname(res, col), (col < ncols - 1) ? "\t" : "\n");
		}

		/* Print rows and write to file as key=value pairs */
		for (row = 0; row < nrows; row++)
		{
			for (col = 0; col < ncols; col++)
			{
				log_debug0("%s=%s%s", PQfname(res, col), PQgetvalue(res, row, col), (col < ncols - 1) ? "\t" : "\n");
				fprintf(outf, "%s=%s%s", PQfname(res, col), PQgetvalue(res, row, col), (col < ncols - 1) ? "\t" : "\n");
			}
		}
	}
	else if (PQresultStatus(res) == PGRES_COMMAND_OK)
	{
		log_debug0("result=%s\n", PQcmdStatus(res));
	}
	else
	{
		log_debug0("result=success\n");
	}

	fclose(outf);
	PQclear(res);
	PQfinish(conn);
	return EXIT_SUCCESS;
}

void
print_sql_exec_help(void)
{
	/* No longer used, but keep for compatibility if referenced elsewhere */
	print_sql_help();
}
