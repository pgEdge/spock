/*-------------------------------------------------------------------------
 *
 * dbconn.c
 *      database connection and utility functions
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <libpq-fe.h>
#include "logger.h"
#include "util.h"
#include "dbconn.h"

/* Connect to the database */
PGconn *
connectdb(const char *conninfo)
{
    PGconn *conn;

    /* Make a connection to the database */
    conn = PQconnectdb(conninfo);

    /* Check to see that the backend connection was successfully made */
    if (PQstatus(conn) != CONNECTION_OK)
    {
        log_error("Connection to database failed\n %s", PQerrorMessage(conn));
        PQfinish(conn);
        return NULL;
    }

    return conn;
}

/* Disconnect from the database */
void
disconnectdb(PGconn *conn)
{
    PQfinish(conn);
}

/* Run an SQL command */
int
run_sql(PGconn *conn, const char *sql)
{
    PGresult *res;

    res = PQexec(conn, sql);

    /* Check for successful command execution */
    if (PQresultStatus(res) != PGRES_COMMAND_OK)
    {
        log_error("SQL command failed: %s", PQerrorMessage(conn));
        PQclear(res);
        return 1;
    }

    /* Clear result */
    PQclear(res);
    return 0;
}

/* Run an SQL query and process the results with a callback function */
int
run_sql_query(PGconn *conn, const char *sql, void (*cb)(PGresult *, int, int))
{
    PGresult *res;
    int       rows;
    int       cols;

    res = PQexec(conn, sql);

    /* Check for successful command execution */
    if (PQresultStatus(res) != PGRES_TUPLES_OK)
    {
        log_error("SELECT command did not return tuples properly: %s", PQerrorMessage(conn));
        PQclear(res);
        return 1;
    }

    /* Get the number of rows and columns */
    rows = PQntuples(res);
    cols = PQnfields(res);

    /* Call the callback function */
    cb(res, rows, cols);

    /* Clear result */
    PQclear(res);
    return 0;
}

/* Get an integer value from the result set */
int
pg_getint(PGresult *res, int row, int col)
{
    if (PQgetisnull(res, row, col))
    {
        return 0;
    }
    return atoi(PQgetvalue(res, row, col));
}

/* Get a string value from the result set */
const char *
pg_getstring(PGresult *res, int row, int col)
{
    if (PQgetisnull(res, row, col))
    {
        return NULL;
    }
    return PQgetvalue(res, row, col);
}

/* Get a boolean value from the result set */
int
pg_getbool(PGresult *res, int row, int col)
{
    if (PQgetisnull(res, row, col))
    {
        return 0;
    }
    return (PQgetvalue(res, row, col)[0] == 't');
}