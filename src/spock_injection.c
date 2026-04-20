/*-------------------------------------------------------------------------
 *
 * spock_injection.c
 *		Unconditional random delay for Spock worker start/finish sites.
 *
 * spock_random_delay() is compiled in only when SPOCK_RANDOM_DELAYS is set
 * in the environment at build time (make SPOCK_RANDOM_DELAYS=1).  It sleeps
 * for a random duration in [1, SPOCK_INJ_MAX_DELAY_MS] ms.
 *
 * On PG17+ without SPOCK_RANDOM_DELAYS, SPOCK_WORKER_DELAY() expands to
 * INJECTION_POINT("spock-worker-delay") instead -- attach a callback via
 * the core injection_points module when needed.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#ifdef SPOCK_RANDOM_DELAYS

#include "common/pg_prng.h"
#include "port.h"

#include "spock_injection.h"

/* Maximum random delay, in milliseconds. */
#define SPOCK_INJ_MAX_DELAY_MS	100

/*
 * spock_random_delay
 *		Sleep for a random duration in [1, SPOCK_INJ_MAX_DELAY_MS] ms.
 *
 * Uses the global PostgreSQL PRNG so the sequence is reproducible when the
 * seed is fixed, which helps in deterministic test scenarios.
 */
void
spock_random_delay(void)
{
	long	delay_ms = 1 + (long) (pg_prng_uint64(&pg_global_prng_state) %
								   SPOCK_INJ_MAX_DELAY_MS);

	elog(LOG, "Spock random delay: sleeping %ld ms", delay_ms);
	pg_usleep(delay_ms * 1000L);
}

#endif							/* SPOCK_RANDOM_DELAYS */
