#ifndef DBCONN_H
#define DBCONN_H

#include <libpq-fe.h>

/* Connect to the database */
PGconn	   *connectdb(const char *conninfo);

/* Disconnect from the database */
void		disconnectdb(PGconn *conn);

/* Run an SQL command */
int			run_sql(PGconn *conn, const char *sql);

/* Run an SQL query and process the results with a callback function */
int			run_sql_query(PGconn *conn, const char *sql, void (*cb) (PGresult *, int, int));

/* Get an integer value from the result set */
int			pg_getint(PGresult *res, int row, int col);

/* Get a string value from the result set */
const char *pg_getstring(PGresult *res, int row, int col);

/* Get a boolean value from the result set */
int			pg_getbool(PGresult *res, int row, int col);

#endif							/* DBCONN_H */
