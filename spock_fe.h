/*-------------------------------------------------------------------------
 *
 * spock_fe.h
 *              spock replication plugin
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *              spock_fe.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_FE_H
#define SPOCK_FE_H

extern int find_other_exec_version(const char *argv0, const char *target,
								   uint32 *version, char *retpath);

extern char *pgl_get_connstr(char *connstr, char *dbname, char *options, char **errmsg);

#endif /* SPOCK_FE_H */
