/*-------------------------------------------------------------------------
 *
 * spock_toast_repair.h
 *		Background worker that verifies and repairs TOAST divergence
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_TOAST_REPAIR_H
#define SPOCK_TOAST_REPAIR_H

#include "postgres.h"
#include "fmgr.h"

extern PGDLLEXPORT void spock_toast_repair_main(Datum main_arg);

#endif							/* SPOCK_TOAST_REPAIR_H */
