/*-------------------------------------------------------------------------
 *
 * spock_injection.h
 *		Injection point support for the Spock extension.
 *
 * Three named injection points are defined:
 *
 *   SPOCK_WORKER_DELAY()          – subscriber side, at apply-worker
 *                                    start/finish sites
 *                                    ('spock-worker-delay').
 *   SPOCK_OUTPUT_TXN_STALL()      – provider side, right after a
 *                                    transaction's BEGIN has been sent to
 *                                    the subscriber ('spock-output-txn-
 *                                    stall'). Lets a test simulate the
 *                                    walsender going quiet mid-transaction
 *                                    (slow decode, network stall) without
 *                                    an unconditional sleep or an ad-hoc
 *                                    getenv()/marker-file hook wired into
 *                                    production output-plugin code.
 *   SPOCK_FORWARDED_APPLY_ERROR() – subscriber side, right before a
 *                                    forwarded-origin row change is applied
 *                                    to the heap ('spock-forwarded-apply-
 *                                    error'). Lets a test attach an
 *                                    'error'-mode injection point (core's
 *                                    injection_points extension) to force
 *                                    an error-class exception on a
 *                                    forwarded transaction, e.g. during a
 *                                    bidirectional-join catchup, to verify
 *                                    the transaction aborts rather than
 *                                    silently committing with a missing
 *                                    row.
 *
 *   SPOCK_RANDOM_DELAYS defined  – the two DELAY/STALL points call
 *                                   spock_random_delay() directly, firing
 *                                   unconditionally with no runtime setup;
 *                                   SPOCK_FORWARDED_APPLY_ERROR() is a
 *                                   no-op (a random sleep does not serve
 *                                   this point's error-injection purpose).
 *   USE_INJECTION_POINTS defined – all three expand to INJECTION_POINT();
 *                                   the core injection_points module can
 *                                   attach to any of them when needed.
 *                                   Requires --enable-injection-points.
 *   neither defined              – all three compile to nothing.
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
#define SPOCK_FORWARDED_APPLY_ERROR()	((void) 0)

#elif defined(USE_INJECTION_POINTS)

#include "utils/injection_point.h"

#if PG_VERSION_NUM >= 180000
#define SPOCK_WORKER_DELAY()		INJECTION_POINT("spock-worker-delay", NULL)
#define SPOCK_OUTPUT_TXN_STALL()	INJECTION_POINT("spock-output-txn-stall", NULL)
#define SPOCK_FORWARDED_APPLY_ERROR()	INJECTION_POINT("spock-forwarded-apply-error", NULL)
#else
#define SPOCK_WORKER_DELAY()		INJECTION_POINT("spock-worker-delay")
#define SPOCK_OUTPUT_TXN_STALL()	INJECTION_POINT("spock-output-txn-stall")
#define SPOCK_FORWARDED_APPLY_ERROR()	INJECTION_POINT("spock-forwarded-apply-error")
#endif

#else

#define SPOCK_WORKER_DELAY()		((void) 0)
#define SPOCK_OUTPUT_TXN_STALL()	((void) 0)
#define SPOCK_FORWARDED_APPLY_ERROR()	((void) 0)

#endif							/* SPOCK_RANDOM_DELAYS / USE_INJECTION_POINTS */

#endif							/* SPOCK_INJECTION_H */
