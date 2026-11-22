/*-------------------------------------------------------------------------
 *
 * spock_toast_internal.h
 *		Definitions shared by the TOAST divergence code
 *
 * spock_toast_suspect_record() (spock_toast_detect.c) records rows whose TOAST
 * columns may have diverged in spock.toast_suspect.  Helpers it uses that
 * later code shares are in spock_toast_util.c.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_TOAST_INTERNAL_H
#define SPOCK_TOAST_INTERNAL_H

/*
 * The search_path the TOAST divergence code runs its own SQL under.  A
 * function or operator someone created in another schema on the session's
 * path could otherwise be called in place of the built-in one, as whatever
 * user runs the SQL.  pg_temp is named last so a temporary table cannot
 * stand in for a catalog.
 */
#define TOAST_SEARCH_PATH "pg_catalog, pg_temp"

/* spock_toast_util.c */
extern const char *const toast_pinned_output[][2];
extern bool run_in_subxact(void (*fn) (void *arg), void *arg, char **errmsg);

#endif							/* SPOCK_TOAST_INTERNAL_H */
