/*-------------------------------------------------------------------------
 *
 * spock_injection.h
 *		Injection point support for the Spock extension.
 *
 * Defines SPOCK_WORKER_DELAY(), placed at worker start/finish sites:
 *
 *   SPOCK_RANDOM_DELAYS defined  – calls spock_random_delay() directly;
 *                                   fires unconditionally, no runtime setup.
 *   PG17+ without the flag       – expands to INJECTION_POINT(); the core
 *                                   injection_points module can attach to
 *                                   'spock-worker-delay' when needed.
 *   pre-PG17 without the flag    – compiles to nothing.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_INJECTION_H
#define SPOCK_INJECTION_H

#ifdef SPOCK_RANDOM_DELAYS

extern void spock_random_delay(void);
#define SPOCK_WORKER_DELAY()	spock_random_delay()

#elif PG_VERSION_NUM >= 170000

#include "utils/injection_point.h"
#define SPOCK_WORKER_DELAY()	INJECTION_POINT("spock-worker-delay", NULL)

#else

#define SPOCK_WORKER_DELAY()	((void) 0)

#endif							/* SPOCK_RANDOM_DELAYS / PG_VERSION_NUM */

#endif							/* SPOCK_INJECTION_H */
