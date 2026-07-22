/*-------------------------------------------------------------------------
 *
 * spock.h
 *              spock replication extension
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_H
#define SPOCK_H

#include "storage/s_lock.h"
#include "postmaster/bgworker.h"
#include "utils/array.h"
#include "access/xlogdefs.h"
#include "parser/analyze.h"
#include "executor/executor.h"

#include "libpq-fe.h"

#include "spock_fe.h"
#include "spock_node.h"

#define SPOCK_VERSION "6.0.0"
#define SPOCK_VERSION_NUM 60000

#define EXTENSION_NAME "spock"

#define REPLICATION_ORIGIN_ALL	"all"

/* define prefix for the MESSAGE callback */
#define SPOCK_MESSAGE_PREFIX	"Spock"

/* Min allowed value for restart_delay_default GUC */
#define SPOCK_RESTART_MIN_DELAY 1

extern bool spock_synchronous_commit;
extern char *spock_temp_directory;
extern bool spock_use_spi;
extern char *spock_extra_connection_options;
extern bool spock_ch_stats;
extern bool spock_deny_ddl;
extern bool spock_enable_ddl_replication;
extern bool spock_include_ddl_repset;
extern bool allow_ddl_from_functions;
extern int	restart_delay_default;
extern int	restart_delay_on_exception;
extern int	spock_replay_queue_size;
extern int	spock_pause_timeout;
extern int	spock_read_retry_count;
extern bool check_all_uc_indexes;
extern bool	spock_enable_quiet_mode;
extern int	log_origin_change;
extern int	spock_apply_idle_timeout;
extern int	spock_log_verbosity;
extern int	spock_apply_change_logging;

/*
 * spock.log_verbosity - controls the verbosity of spock-specific log output.
 *
 * Spock's own DEBUG1/DEBUG2 messages are silent by default because PostgreSQL's
 * log_min_messages typically defaults to WARNING or NOTICE.  Customer Success
 * needs to crank up spock detail when debugging an issue without flipping
 * log_min_messages globally (which floods the logs with non-spock output).
 *
 * PostgreSQL has only a single, global log threshold (log_min_messages), so we
 * cannot give spock a lower "minimum level" of its own: a DEBUG1/DEBUG2 message
 * emitted below log_min_messages is discarded by errstart() before it is ever
 * built.  Instead this GUC *promotes* spock's own debug messages up to LOG,
 * which is always written to the server log under any normal log_min_messages
 * setting.  The level controls how much detail is promoted:
 *
 *   normal - no promotion; DEBUG1/DEBUG2 keep their native (silent) levels.
 *   debug1 - promote SPOCK_DEBUG1 messages to LOG (DEBUG2 stays silent).
 *   debug2 - promote both SPOCK_DEBUG1 and SPOCK_DEBUG2 messages to LOG.
 */
typedef enum SpockLogVerbosity
{
	SPOCK_LOG_VERBOSITY_NORMAL = 0,
	SPOCK_LOG_VERBOSITY_DEBUG1,
	SPOCK_LOG_VERBOSITY_DEBUG2
} SpockLogVerbosity;

/*
 * spock.apply_change_logging - controls JSON change logging by the apply worker.
 *
 *   none     - default; no extra logging.
 *   key_only - log {action, schema, table, primary_key, origin, commit_ts}
 *              for each DML change.  DDL is also logged with its SQL text.
 *   verbose  - all of the above, plus old/new row data for DML.
 */
typedef enum SpockApplyChangeLogging
{
	SPOCK_APPLY_CHANGE_LOG_NONE = 0,
	SPOCK_APPLY_CHANGE_LOG_KEY_ONLY,
	SPOCK_APPLY_CHANGE_LOG_VERBOSE
} SpockApplyChangeLogging;

/*
 * Route every spock-specific DEBUG1/DEBUG2 ereport through these macros so
 * spock.log_verbosity can promote them to LOG without recompiling.  Each macro
 * promotes to LOG only once spock.log_verbosity is at or above that message's
 * tier; otherwise the message keeps its native (and normally silent) level.
 * Used as `ereport(SPOCK_DEBUG1, (errmsg("...")));`
 */
#define SPOCK_DEBUG1 \
	((spock_log_verbosity >= SPOCK_LOG_VERBOSITY_DEBUG1) ? LOG : DEBUG1)
#define SPOCK_DEBUG2 \
	((spock_log_verbosity >= SPOCK_LOG_VERBOSITY_DEBUG2) ? LOG : DEBUG2)

extern char *shorten_hash(const char *str, int maxlen);
extern void gen_slot_name(Name slot_name, char *dbname,
						  const char *provider_name,
						  const char *subscriber_name);

extern List *textarray_to_list(ArrayType *textarray);
extern bool parsePGArray(const char *atext, char ***itemarray, int *nitems);

extern Oid	get_spock_table_oid(const char *table);

extern void spock_execute_sql_command(char *cmdstr, char *role,
									  bool isTopLevel);

extern PGconn *spock_connect(const char *connstring, const char *connname,
							 const char *suffix);
extern PGconn *spock_connect_replica(const char *connstring,
									 const char *connname,
									 const char *suffix);
extern void spock_identify_system(PGconn *streamConn, uint64 *sysid,
								  TimeLineID *timeline, XLogRecPtr *xlogpos,
								  Name *dbname);
extern void spock_start_replication(PGconn *streamConn,
									const char *slot_name,
									XLogRecPtr start_pos,
									const char *forward_origins,
									const char *replication_sets,
									const char *replicate_only_table,
									bool force_text_transfer);

extern void spock_manage_extension(void);

extern void apply_work(PGconn *streamConn);

extern bool synchronize_sequences(void);
extern void synchronize_sequence(Oid seqoid);
extern void spock_create_sequence_state_record(Oid seqoid);
extern void spock_drop_sequence_state_record(Oid seqoid);
extern int64 sequence_get_last_value(Oid seqoid);

extern bool in_spock_replicate_ddl_command;
extern bool in_spock_queue_ddl_command;
extern bool spock_auto_replicate_ddl(const char *query, List *replication_sets,
									 Oid roleoid, Node *stmt);
extern bool spock_schema_is_ddl_local(const char *nspname);
extern bool name_in_list(List *names, const char *name);

/* spock_readonly.c */
void		spock_roExecutorStart(QueryDesc *queryDesc, int eflags);
#if PG_VERSION_NUM >= 190000
void		spock_ropost_parse_analyze(ParseState *pstate, Query *query, const JumbleState *jstate);
#else
void		spock_ropost_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate);
#endif

#include "utils/memdebug.h"

/*
 * PostgreSQL exposes stubs for some Valgrind macros, but there are some
 * others we use that aren't supported by Pg proper yet.
 */
#ifndef USE_VALGRIND
#define VALGRIND_CHECK_VALUE_IS_DEFINED(v) do{} while(0)
#define VALGRIND_DO_LEAK_CHECK do{} while(0)
#define VALGRIND_DO_ADDED_LEAK_CHECK do{} while(0)
#define VALGRIND_DO_CHANGED_LEAK_CHECK do{} while(0)
#define VALGRIND_DO_QUICK_LEAK_CHECK do{} while(0)
#define VALGRIND_DISABLE_ERROR_REPORTING do {} while (0)
#define VALGRIND_ENABLE_ERROR_REPORTING do {} while (0)

/*
 * Gives us some error checking when no-op'd. spock uses this to report
 * the worker type, etc, prefixed by SPOCK:, in the Valgrind logs. We
 * need to stub it out if we aren't using valgrind.
 */
pg_attribute_printf(1, 2) pg_attribute_unused() static inline void
VALGRIND_PRINTF(const char *format,...)
{
}

#endif

extern void spock_init_failover_slot(void);

#endif							/* SPOCK_H */
