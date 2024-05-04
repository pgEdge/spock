
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
#include "spock_exception_handler.h"
#include "spock_jsonb_utils.h"

#define Natts_exception_table 10
#define Anum_exception_log_id 1
#define Anum_exception_log_node_id 2
#define Anum_exception_log_commit_ts 3
#define Anum_exception_log_remote_xid 4
#define Anum_exception_log_schema 5
#define Anum_exception_log_table 6
#define Anum_exception_log_exception_context 7
#define Anum_exception_log_operation 8
#define Anum_exception_log_message 9
#define Anum_exception_log_retry_errored_at 10

#define CATALOG_EXCEPTION_LOG "exception_log"

SpockExceptionLog *exception_log_ptr = NULL;
int			exception_log_behaviour = TRANSDISCARD;

static Oid	get_exception_log_table_oid(void);
static Oid	get_exception_log_seq(void);

/*
 * Add an entry to the error log.
 */
void
add_entry_to_exception_log(Oid nodeid, TimestampTz commit_ts, TransactionId remote_xid,
						   SpockRelation *targetrel, HeapTuple localtup, SpockTupleData *remoteoldtup,
						   SpockTupleData *remotenewtup, char *action, char *error_message)
{
	RangeVar   *rv;
	Relation	rel;
	TupleDesc	tupDesc;
	TupleDesc	targetTupDesc;
	HeapTuple	tup;
	Datum		values[Natts_exception_table];
	bool		nulls[Natts_exception_table];
	Datum		context_val;
	char	   *schema = targetrel->nspname;
	char	   *table = targetrel->relname;

	StringInfoData	s;
	char		   *str_local_tup;
	char		   *str_remote_old_tup;
	char		   *str_remote_new_tup;

	/* Get the tuple descriptors */
	rv = makeRangeVar(EXTENSION_NAME, CATALOG_EXCEPTION_LOG, -1);
	rel = table_openrv(rv, RowExclusiveLock);
	tupDesc = RelationGetDescr(rel);
	targetTupDesc = RelationGetDescr(targetrel->rel);

	/* Convert the three (possible) tuples into json strings */
	if (localtup != NULL && localtup->t_data != NULL)
		str_local_tup = heap_tuple_to_json_cstring(&localtup,
												   targetTupDesc);
	else
		str_local_tup = pstrdup("null");

	if (remoteoldtup != NULL)
		str_remote_old_tup = spock_tuple_to_json_cstring(remoteoldtup,
														 targetTupDesc);
	else
		str_remote_old_tup = pstrdup("null");

	if (remotenewtup != NULL)
		str_remote_new_tup = spock_tuple_to_json_cstring(remotenewtup,
														 targetTupDesc);
	else
		str_remote_new_tup = pstrdup("null");

	/* Assemble the overall context string */
	initStringInfo(&s);
	appendStringInfoString(&s, "{\"local_tup\": ");
	appendStringInfoString(&s, str_local_tup);
	appendStringInfoString(&s, ", \"remote_old_tup\": ");
	appendStringInfoString(&s, str_remote_old_tup);
	appendStringInfoString(&s, ", \"remote_new_tup\": ");
	appendStringInfoString(&s, str_remote_new_tup);
	appendStringInfoString(&s, "}");

	/* Convert the context into a jsonb Datum */
	context_val = DirectFunctionCall1(jsonb_in, CStringGetDatum(s.data));

	/* Form a tuple. */
	memset(nulls, 0, sizeof(nulls));
	memset(values, 0, sizeof(values));

	values[Anum_exception_log_id - 1] = DirectFunctionCall1(nextval_oid, get_exception_log_seq());
	values[Anum_exception_log_node_id - 1] = ObjectIdGetDatum(nodeid);
	values[Anum_exception_log_commit_ts - 1] = TimestampTzGetDatum(commit_ts);
	values[Anum_exception_log_remote_xid - 1] = TransactionIdGetDatum(remote_xid);
	values[Anum_exception_log_schema - 1] = CStringGetTextDatum(schema);
	values[Anum_exception_log_table - 1] = CStringGetTextDatum(table);
	values[Anum_exception_log_exception_context - 1] = context_val;
	values[Anum_exception_log_operation - 1] = CStringGetTextDatum(action);
	values[Anum_exception_log_message - 1] = CStringGetTextDatum(error_message);
	values[Anum_exception_log_retry_errored_at - 1] = TimestampTzGetDatum(GetCurrentTimestamp());

	tup = heap_form_tuple(tupDesc, values, nulls);

	/* Insert the tuple to the catalog. */
	CatalogTupleInsert(rel, tup);

	/* Cleanup. */
	heap_freetuple(tup);
	table_close(rel, RowExclusiveLock);

	elog(LOG, "SpockErrorLog: Inserted tuple into exception_log table.");

	CommandCounterIncrement();
}

/*
 * Get (cached) oid of the conflict log table.
 */
static Oid
get_exception_log_table_oid(void)
{
	static Oid	logtableoid = InvalidOid;

	if (logtableoid == InvalidOid)
		logtableoid = get_spock_table_oid(CATALOG_EXCEPTION_LOG);

	return logtableoid;
}

/*
 * Get (cached) oid of the conflict log sequence, which is created
 * implicitly.
 */
static Oid
get_exception_log_seq(void)
{
	static Oid	seqoid = InvalidOid;

	if (seqoid == InvalidOid)
	{
		Oid			reloid;

		reloid = get_exception_log_table_oid();
		seqoid = getIdentitySequence(reloid, 0, false);
	}

	return seqoid;
}
