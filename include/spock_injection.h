/*-------------------------------------------------------------------------
 *
 * spock_injection.h
 *		Injection point support for the Spock extension.
 *
 * Two named injection points are defined, one per side of the wire:
 *
 *   SPOCK_WORKER_DELAY()      – subscriber side, at apply-worker
 *                                start/finish sites ('spock-worker-delay').
 *   SPOCK_OUTPUT_TXN_STALL()  – provider side, right after a transaction's
 *                                BEGIN has been sent to the subscriber
 *                                ('spock-output-txn-stall'). Lets a test
 *                                simulate the walsender going quiet
 *                                mid-transaction (slow decode, network
 *                                stall) without an unconditional sleep or
 *                                an ad-hoc getenv()/marker-file hook wired
 *                                into production output-plugin code.
 *
 *   SPOCK_RANDOM_DELAYS defined  – both call spock_random_delay() directly;
 *                                   fires unconditionally, no runtime setup.
 *   USE_INJECTION_POINTS defined – both expand to INJECTION_POINT(); the
 *                                   core injection_points module can
 *                                   attach to either name when needed.
 *                                   Requires --enable-injection-points.
 *   neither defined              – both compile to nothing.
 *
 * A third, independent point is a boolean check rather than a fire site:
 *
 *   SPOCK_CONFLICT_TIE_FORCED()  – true once a test attaches to
 *                                  'spock-conflict-force-tie' (any action;
 *                                  only presence is checked). Used to force
 *                                  every timestamp-based conflict
 *                                  resolution into the tiebreaker branch on
 *                                  demand, since two independently-
 *                                  committed transactions on different
 *                                  nodes landing in the exact same commit-
 *                                  timestamp tick is otherwise a race no
 *                                  test can control. Needs core's
 *                                  IS_INJECTION_POINT_ATTACHED(), added in
 *                                  PG18; always false on 15-17 or without
 *                                  --enable-injection-points.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_INJECTION_H
#define SPOCK_INJECTION_H

#ifdef SPOCK_RANDOM_DELAYS

extern void spock_random_delay(void);
#define SPOCK_WORKER_DELAY()		spock_random_delay()
#define SPOCK_OUTPUT_TXN_STALL()	spock_random_delay()

#elif defined(USE_INJECTION_POINTS)

#include "utils/injection_point.h"

#if PG_VERSION_NUM >= 180000
#define SPOCK_WORKER_DELAY()		INJECTION_POINT("spock-worker-delay", NULL)
#define SPOCK_OUTPUT_TXN_STALL()	INJECTION_POINT("spock-output-txn-stall", NULL)
#else
#define SPOCK_WORKER_DELAY()		INJECTION_POINT("spock-worker-delay")
#define SPOCK_OUTPUT_TXN_STALL()	INJECTION_POINT("spock-output-txn-stall")
#endif

#else

#define SPOCK_WORKER_DELAY()		((void) 0)
#define SPOCK_OUTPUT_TXN_STALL()	((void) 0)

#endif							/* SPOCK_RANDOM_DELAYS / USE_INJECTION_POINTS */

#if defined(USE_INJECTION_POINTS) && PG_VERSION_NUM >= 180000
#include "utils/injection_point.h"	/* safe to re-include, has its own guard */
#define SPOCK_CONFLICT_TIE_FORCED() IS_INJECTION_POINT_ATTACHED("spock-conflict-force-tie")
#else
#define SPOCK_CONFLICT_TIE_FORCED() (false)
#endif

#endif							/* SPOCK_INJECTION_H */
