/*-------------------------------------------------------------------------
 *
 * spock_injection.h
 *		Injection point support for the Spock extension.
 *
 * Four named injection points are defined:
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
 *   SPOCK_FORWARDED_APPLY_ERROR() – subscriber side, right before a
 *                                forwarded-origin row change is applied
 *                                to the heap ('spock-forwarded-apply-
 *                                error'). Lets a test attach an
 *                                'error'-mode injection point (core's
 *                                injection_points extension) to force
 *                                an error-class exception on a
 *                                forwarded transaction, e.g. during a
 *                                bidirectional-join catchup, to verify
 *                                the transaction aborts rather than
 *                                silently committing with a missing
 *                                row.
 *
 *   SPOCK_RANDOM_DELAYS defined  – the worker and output-plugin points call
 *                                   spock_random_delay() directly; fires
 *                                   unconditionally, no runtime setup.  The
 *                                   INSERT point stays a no-op here: it sits
 *                                   on the per-row apply path rather than at
 *                                   a worker or transaction boundary, and a
 *                                   sleep averaging 50 ms on every applied
 *                                   row puts the regression suite hours past
 *                                   any sensible timeout.  The same goes for
 *                                   SPOCK_FORWARDED_APPLY_ERROR(), which is
 *                                   also a no-op: a random sleep does not
 *                                   serve an error-injection point.
 *   USE_INJECTION_POINTS defined – all expand to INJECTION_POINT(); the
 *                                   core injection_points module can
 *                                   attach to any name when needed.
 *                                   Requires --enable-injection-points.
 *   neither defined              – all compile to nothing.
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
/* Per-row: delaying here would take the suite hours.  See above. */
#define SPOCK_INSERT_CONFLICT_STALL()	((void) 0)
#define SPOCK_FORWARDED_APPLY_ERROR()	((void) 0)

#elif defined(USE_INJECTION_POINTS)

#include "utils/injection_point.h"

#if PG_VERSION_NUM >= 180000
#define SPOCK_WORKER_DELAY()		INJECTION_POINT("spock-worker-delay", NULL)
#define SPOCK_OUTPUT_TXN_STALL()	INJECTION_POINT("spock-output-txn-stall", NULL)
#define SPOCK_INSERT_CONFLICT_STALL()	\
	INJECTION_POINT("spock-insert-conflict-stall", NULL)
#define SPOCK_FORWARDED_APPLY_ERROR()	INJECTION_POINT("spock-forwarded-apply-error", NULL)
#else
#define SPOCK_WORKER_DELAY()		INJECTION_POINT("spock-worker-delay")
#define SPOCK_OUTPUT_TXN_STALL()	INJECTION_POINT("spock-output-txn-stall")
#define SPOCK_INSERT_CONFLICT_STALL()	\
	INJECTION_POINT("spock-insert-conflict-stall")
#define SPOCK_FORWARDED_APPLY_ERROR()	INJECTION_POINT("spock-forwarded-apply-error")
#endif

#else

#define SPOCK_WORKER_DELAY()		((void) 0)
#define SPOCK_OUTPUT_TXN_STALL()	((void) 0)
#define SPOCK_INSERT_CONFLICT_STALL()	((void) 0)
#define SPOCK_FORWARDED_APPLY_ERROR()	((void) 0)

#endif							/* SPOCK_RANDOM_DELAYS / USE_INJECTION_POINTS */

#if defined(USE_INJECTION_POINTS) && PG_VERSION_NUM >= 180000
#include "utils/injection_point.h"	/* safe to re-include, has its own guard */
#define SPOCK_CONFLICT_TIE_FORCED() IS_INJECTION_POINT_ATTACHED("spock-conflict-force-tie")
#else
#define SPOCK_CONFLICT_TIE_FORCED() (false)
#endif

#endif							/* SPOCK_INJECTION_H */
