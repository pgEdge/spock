/*-------------------------------------------------------------------------
 *
 * spock_antithesis.h
 *		Antithesis assertions for Spock, written with the fallback SDK
 *
 * Antithesis has no C SDK, so assertions are written as JSONL lines to
 * $ANTITHESIS_OUTPUT_DIR/sdk.jsonl (the "fallback SDK").  Every assertion
 * must be declared once at startup and evaluated at its call site; both
 * messages carry the same id.  Declaration happens in _PG_init, which runs
 * once in the postmaster.
 *
 * Built only with "make ANTITHESIS=1".  Without it every macro below
 * compiles to nothing.
 *
 * To add an assertion:
 *   1. Add a SPOCK_ANT_ASSERTION() line to SPOCK_ANT_CATALOG below.  The
 *      message is the property name shown in the Antithesis report; keep it
 *      a constant, unique, human-readable string.  file and function name
 *      the call site.  The declaration and the evaluation both report that
 *      location, so they match even though the declaration is written from
 *      _PG_init.
 *   2. Call SPOCK_ANT_REACHABLE / SPOCK_ANT_ALWAYS / SPOCK_ANT_SOMETIMES /
 *      SPOCK_ANT_UNREACHABLE with the matching enum value.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_ANTITHESIS_H
#define SPOCK_ANTITHESIS_H

/*
 * SPOCK_ANT_ASSERTION(id, kind, message, file, function)
 *
 * kind is one of REACHABLE, UNREACHABLE, ALWAYS, ALWAYS_OR_UNREACHABLE,
 * SOMETIMES.
 */
#define SPOCK_ANT_CATALOG \
	SPOCK_ANT_ASSERTION(SPOCK_ANT_MANAGER_STARTED, REACHABLE, \
						"spock manager worker started", \
						"src/spock_manager.c", "spock_manager_main") \
	SPOCK_ANT_ASSERTION(SPOCK_ANT_SHUTDOWN_DRAIN_TIMED_OUT, SOMETIMES, \
						"supervisor shutdown drain timed out with apply workers still attached", \
						"src/spock.c", "spock_supervisor_on_exit")

#ifdef USE_ANTITHESIS

typedef enum SpockAntKind
{
	SPOCK_ANT_KIND_REACHABLE,
	SPOCK_ANT_KIND_UNREACHABLE,
	SPOCK_ANT_KIND_ALWAYS,
	SPOCK_ANT_KIND_ALWAYS_OR_UNREACHABLE,
	SPOCK_ANT_KIND_SOMETIMES
} SpockAntKind;

typedef enum SpockAntId
{
#define SPOCK_ANT_ASSERTION(id, kind, message, file, function) id,
	SPOCK_ANT_CATALOG
#undef SPOCK_ANT_ASSERTION
	SPOCK_ANT_NUM_ASSERTIONS
} SpockAntId;

extern void spock_antithesis_init(void);
extern void spock_antithesis_eval(SpockAntId id, bool condition,
								  const char *details_json);

/*
 * details_json is NULL or a complete JSON object, e.g. "{\"slot\":3}".
 * It is copied verbatim into the message.
 */
#define SPOCK_ANT_ALWAYS(id, cond, details_json) \
	spock_antithesis_eval((id), (cond), (details_json))
#define SPOCK_ANT_SOMETIMES(id, cond, details_json) \
	spock_antithesis_eval((id), (cond), (details_json))
#define SPOCK_ANT_REACHABLE(id, details_json) \
	spock_antithesis_eval((id), true, (details_json))
#define SPOCK_ANT_UNREACHABLE(id, details_json) \
	spock_antithesis_eval((id), false, (details_json))

#else							/* !USE_ANTITHESIS */

#define spock_antithesis_init() ((void) 0)
#define SPOCK_ANT_ALWAYS(id, cond, details_json) ((void) 0)
#define SPOCK_ANT_SOMETIMES(id, cond, details_json) ((void) 0)
#define SPOCK_ANT_REACHABLE(id, details_json) ((void) 0)
#define SPOCK_ANT_UNREACHABLE(id, details_json) ((void) 0)

#endif							/* USE_ANTITHESIS */

#endif							/* SPOCK_ANTITHESIS_H */
