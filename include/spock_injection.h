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
 *   SPOCK_INSERT_CONFLICT_STALL() – subscriber side, in the INSERT apply
 *                                path between "the lookup found no
 *                                conflicting row" and storing the tuple
 *                                ('spock-insert-conflict-stall'). A test
 *                                holds the worker there and commits the
 *                                conflicting row locally, which makes the
 *                                lookup's answer stale by the time we
 *                                store -- the situation the speculative
 *                                insertion exists to survive, and the one
 *                                a concurrent local writer produces for
 *                                real.
 *
 *   SPOCK_RANDOM_DELAYS defined  – the worker and output-plugin points call
 *                                   spock_random_delay() directly; fires
 *                                   unconditionally, no runtime setup.  The
 *                                   INSERT point stays a no-op here: it sits
 *                                   on the per-row apply path rather than at
 *                                   a worker or transaction boundary, and a
 *                                   sleep averaging 50 ms on every applied
 *                                   row puts the regression suite hours past
 *                                   any sensible timeout.
 *   USE_INJECTION_POINTS defined – all expand to INJECTION_POINT(); the
 *                                   core injection_points module can
 *                                   attach to any name when needed.
 *                                   Requires --enable-injection-points.
 *   neither defined              – all compile to nothing.
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
/* Per-row: delaying here would take the suite hours.  See above. */
#define SPOCK_INSERT_CONFLICT_STALL()	((void) 0)

#elif defined(USE_INJECTION_POINTS)

#include "utils/injection_point.h"

#if PG_VERSION_NUM >= 180000
#define SPOCK_WORKER_DELAY()		INJECTION_POINT("spock-worker-delay", NULL)
#define SPOCK_OUTPUT_TXN_STALL()	INJECTION_POINT("spock-output-txn-stall", NULL)
#define SPOCK_INSERT_CONFLICT_STALL()	\
	INJECTION_POINT("spock-insert-conflict-stall", NULL)
#else
#define SPOCK_WORKER_DELAY()		INJECTION_POINT("spock-worker-delay")
#define SPOCK_OUTPUT_TXN_STALL()	INJECTION_POINT("spock-output-txn-stall")
#define SPOCK_INSERT_CONFLICT_STALL()	\
	INJECTION_POINT("spock-insert-conflict-stall")
#endif

#else

#define SPOCK_WORKER_DELAY()		((void) 0)
#define SPOCK_OUTPUT_TXN_STALL()	((void) 0)
#define SPOCK_INSERT_CONFLICT_STALL()	((void) 0)

#endif							/* SPOCK_RANDOM_DELAYS / USE_INJECTION_POINTS */

#endif							/* SPOCK_INJECTION_H */
