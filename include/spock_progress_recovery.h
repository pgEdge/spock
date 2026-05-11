/*-------------------------------------------------------------------------
 *
 * spock_progress_recovery.h
 * 		apply-worker startup state setup for spock.progress
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_PROGRESS_RECOVERY_H
#define SPOCK_PROGRESS_RECOVERY_H

#include "access/xlog.h"

extern void spock_init_progress_state(XLogRecPtr origin_lsn);

#endif							/* SPOCK_PROGRESS_RECOVERY_H */
