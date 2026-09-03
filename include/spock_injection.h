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

#endif							/* SPOCK_INJECTION_H */
