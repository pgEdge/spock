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

#define SPOCK_VERSION "6.0.0-devel"
#define SPOCK_VERSION_NUM 60000

#define EXTENSION_NAME "spock"
#define SPOCK_SECLABEL_PROVIDER "spock"

#define REPLICATION_ORIGIN_ALL	"all"

/* define prefix for the MESSAGE callback */
#define SPOCK_MESSAGE_PREFIX	"Spock"

/* Min allowed value for restart_delay_default GUC */
#define SPOCK_RESTART_MIN_DELAY 1

extern bool spock_synchronous_commit;
extern char *spock_temp_directory;
extern bool spock_use_spi;
extern bool spock_batch_inserts;
extern char *spock_extra_connection_options;
extern bool spock_ch_stats;
extern bool spock_deny_ddl;
extern bool spock_enable_ddl_replication;
extern bool spock_include_ddl_repset;
extern bool allow_ddl_from_functions;
extern int	restart_delay_default;
extern int	restart_delay_on_exception;
extern int	spock_replay_queue_size;	/* Deprecated - no longer used */
extern bool check_all_uc_indexes;
extern bool	spock_enable_quiet_mode;

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
extern void spock_auto_replicate_ddl(const char *query, List *replication_sets,
									 Oid roleoid, Node *stmt);

/* spock_readonly.c */
void		spock_roExecutorStart(QueryDesc *queryDesc, int eflags);
void		spock_ropost_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate);

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
