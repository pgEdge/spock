/*-------------------------------------------------------------------------
 *
 * spock_change_log.h
 *      Public surface for spock.apply_change_logging output.
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_CHANGE_LOG_H
#define SPOCK_CHANGE_LOG_H

/*
 * Forward declarations only.  spock_change_log.h is included from
 * spock_apply.c right next to other spock_*.h headers, and pulling in
 * spock_proto_native.h / spock_relcache.h would also drag in
 * spock_compat.h via spock_output_plugin.h - the resulting macro
 * redefinitions then collide with commands/trigger.h declarations
 * pulled in further down the include chain (spock_common.h).
 */
struct SpockRelation;
struct SpockTupleData;

extern void spock_log_apply_change(const char *action,
								   struct SpockRelation *rel,
								   struct SpockTupleData *oldtup,
								   struct SpockTupleData *newtup,
								   const char *origin_name);

extern void spock_log_apply_ddl(const char *sql, const char *origin_name);

#endif							/* SPOCK_CHANGE_LOG_H */
