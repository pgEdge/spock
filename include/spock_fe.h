/*-------------------------------------------------------------------------
 *
 * spock_fe.h
 *              spock replication plugin
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_FE_H
#define SPOCK_FE_H

extern int	find_other_exec_version(const char *argv0, const char *target,
									uint32 *version, char *retpath);

extern char *spk_get_connstr(char *connstr, char *dbname, char *options, char **errmsg);

#endif							/* SPOCK_FE_H */
