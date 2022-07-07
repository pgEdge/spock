/*-------------------------------------------------------------------------
 *
 * spock.h
 *              spock replication plugin
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *              spock.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_H
#define SPOCK_H

#include "storage/s_lock.h"
#include "postmaster/bgworker.h"
#include "utils/array.h"
#include "access/xlogdefs.h"
#include "executor/executor.h"

#include "libpq-fe.h"

#include "spock_fe.h"
#include "spock_node.h"

#include "spock_compat.h"

#define SPOCK_VERSION "3.0.0"
#define SPOCK_VERSION_NUM 30000

#define SPOCK_MIN_PROTO_VERSION_NUM 1
#define SPOCK_MAX_PROTO_VERSION_NUM 1

#define EXTENSION_NAME "spock"

#define REPLICATION_ORIGIN_ALL "all"

#define HAVE_REPLICATION_ORIGINS

extern bool spock_synchronous_commit;
extern char *spock_temp_directory;
extern bool spock_use_spi;
extern bool spock_batch_inserts;
extern char *spock_extra_connection_options;

extern char *shorten_hash(const char *str, int maxlen);

extern List *textarray_to_list(ArrayType *textarray);
extern bool parsePGArray(const char *atext, char ***itemarray, int *nitems);

extern Oid get_spock_table_oid(const char *table);

extern void spock_execute_sql_command(char *cmdstr, char *role,
										  bool isTopLevel);

extern PGconn *spock_connect(const char *connstring, const char *connname,
								 const char *suffix);
extern PGconn *spock_connect_replica(const char *connstring,
										 const char *connname,
										 const char *suffix);
extern void spock_identify_system(PGconn *streamConn, uint64* sysid,
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
pg_attribute_printf(1, 2) pg_attribute_unused() static inline void VALGRIND_PRINTF(const char *format, ...) {}

#endif

#endif /* SPOCK_H */
