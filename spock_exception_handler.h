#include "postgres.h"

#include "miscadmin.h"

#include "libpq/libpq-be.h"

#include "access/commit_ts.h"
#include "access/xact.h"

#include "commands/dbcommands.h"
#include "common/hashfn.h"

#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/pg_type.h"

#include "nodes/makefuncs.h"
#include "postmaster/interrupt.h"

#include "storage/ipc.h"
#include "storage/proc.h"
#include "storage/procsignal.h"
#include "storage/procarray.h"

#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"
#include "utils/builtins.h"
#include "replication/origin.h"
#include "replication/slot.h"

#include "pgstat.h"

#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_conflict.h"
#include "spock_relcache.h"


typedef struct SpockExceptionLog
{
	NameData	slot_name;
	XLogRecPtr	commit_lsn;
	HeapTuple	local_tuple;
} SpockExceptionLog;

typedef enum SpockExceptionBehaviour
{
	DISCARD,
	TRANSDISCARD,
	SUB_DISABLE
} SpockExceptionBehaviour;

typedef enum SpockExceptionLogging
{
	LOG_NONE,
	LOG_DISCARD,
	LOG_ALL
} SpockExceptionLogging;

extern SpockExceptionLog   *exception_log_ptr;
extern int					exception_behaviour;
extern int					exception_logging;
extern int					exception_command_counter;

extern void add_entry_to_exception_log(Oid remote_origin,
									   TimestampTz remote_commit_ts,
									   TransactionId remote_xid,
									   Oid local_origin,
									   TimestampTz local_commit_ts,
									   SpockRelation *targetrel,
									   HeapTuple localtup,
									   SpockTupleData *remoteoldtup,
									   SpockTupleData *remotenewtup,
									   char *ddl_statement, char *ddl_user,
									   char *operation,
									   char *error_message);
