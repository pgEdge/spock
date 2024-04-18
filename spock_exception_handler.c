
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

#define Natts_exception_table 11
#define Anum_exception_log_node_id 1
#define Anum_exception_log_commit_ts 2
#define Anum_exception_log_remote_xid 3
#define Anum_exception_log_schema 4
#define Anum_exception_log_table 5
#define Anum_exception_log_local_tuple 6
#define Anum_exception_log_remote_old_tuple 7
#define Anum_exception_log_remote_new_tuple 8
#define Anum_exception_log_operation 9
#define Anum_exception_log_message 10
#define Anum_exception_log_retry_errored_at 11

#define CATALOG_EXCEPTION_LOG "exception_log"

SpockExceptionLog *exception_log_ptr = NULL;
int			exception_log_behaviour = TRANSDISCARD;

static void spock_tuple_to_stringinfo(StringInfo s, TupleDesc tupdesc, SpockTupleData *tuple);

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
	Jsonb	   *localtup_json;
	Jsonb	   *remoteoldtup_json;
	Jsonb	   *remotenewtup_json;
	char	   *schema = targetrel->nspname;
	char	   *table = targetrel->relname;


	rv = makeRangeVar(EXTENSION_NAME, CATALOG_EXCEPTION_LOG, -1);
	rel = table_openrv(rv, RowExclusiveLock);
	tupDesc = RelationGetDescr(rel);
	targetTupDesc = RelationGetDescr(targetrel->rel);

	/*
	 * FIXME: This decision will change and grow more complex as other columns
	 * are added to the error table
	 */
	if (localtup != NULL)
	{
		elog(DEBUG1, "SpockErrorLog: localtup is not NULL.");
		localtup_json = spock_tuple_data_to_jsonb(localtup, targetTupDesc);
	}
	if (remoteoldtup != NULL)
	{
		elog(DEBUG1, "SpockErrorLog: remoteoldtup is not NULL.");
		remoteoldtup_json = spock_tuple_data_to_jsonb(remoteoldtup, targetTupDesc);
	}
	if (remotenewtup != NULL)
	{
		elog(DEBUG1, "SpockErrorLog: remotenewtup is not NULL.");
		remotenewtup_json = spock_tuple_data_to_jsonb(remotenewtup, targetTupDesc);
		/* Convert local_jsonb to string and print it */
		elog(DEBUG1, "SpockErrorLog: local_jsonb is (%s)", JsonbToCString(NULL, &remotenewtup_json->root, VARSIZE(remotenewtup_json)));
	}

	/* Form a tuple. */
	memset(nulls, 0, sizeof(nulls));
	memset(values, 0, sizeof(values));

	values[Anum_exception_log_node_id - 1] = ObjectIdGetDatum(nodeid);
	values[Anum_exception_log_commit_ts - 1] = TimestampTzGetDatum(commit_ts);
	values[Anum_exception_log_remote_xid - 1] = TransactionIdGetDatum(remote_xid);
	values[Anum_exception_log_schema - 1] = CStringGetTextDatum(schema);
	values[Anum_exception_log_table - 1] = CStringGetTextDatum(table);

	if (localtup != NULL)
		values[Anum_exception_log_local_tuple - 1] = PointerGetDatum(localtup_json);
	else
	{
		values[Anum_exception_log_local_tuple - 1] = (Datum) 0;
		nulls[Anum_exception_log_local_tuple - 1] = true;
	}
	if (remoteoldtup != NULL)
		values[Anum_exception_log_remote_old_tuple - 1] = PointerGetDatum(remoteoldtup_json);
	else
	{
		values[Anum_exception_log_remote_old_tuple - 1] = (Datum) 0;
		nulls[Anum_exception_log_remote_old_tuple - 1] = true;
	}

	if (remotenewtup != NULL)
		values[Anum_exception_log_remote_new_tuple - 1] = PointerGetDatum(remotenewtup_json);
	else
	{
		values[Anum_exception_log_remote_new_tuple - 1] = (Datum) 0;
		nulls[Anum_exception_log_remote_new_tuple - 1] = true;
	}

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
 * Convert a SpockTupleData to a string.
 */
static void
spock_tuple_to_stringinfo(StringInfo s, TupleDesc tupdesc, SpockTupleData *tuple)
{
	int			natt;
	bool		first = true;

	static const int MAX_CONFLICT_LOG_ATTR_LEN = 40;

	/* print all columns individually */
	for (natt = 0; natt < tupdesc->natts; natt++)
	{
		Form_pg_attribute attr; /* the attribute itself */
		Oid			typid;		/* type of current attribute */
		HeapTuple	type_tuple; /* information about a type */
		Form_pg_type type_form;
		Oid			typoutput;	/* output function */
		bool		typisvarlena;
		Datum		origval;	/* possibly toasted Datum */
		Datum		val = PointerGetDatum(NULL);	/* definitely detoasted
													 * Datum */
		char	   *outputstr = NULL;
		bool		isnull = false; /* column is null? */

		attr = TupleDescAttr(tupdesc, natt);

		/*
		 * don't print dropped columns, we can't be sure everything is
		 * available for them
		 */
		if (attr->attisdropped)
			continue;

		/*
		 * Don't print system columns
		 */
		if (attr->attnum < 0)
			continue;

		typid = attr->atttypid;

		/* gather type name */
		type_tuple = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typid));
		if (!HeapTupleIsValid(type_tuple))
			elog(ERROR, "cache lookup failed for type %u", typid);
		type_form = (Form_pg_type) GETSTRUCT(type_tuple);

		/* print attribute name */
		if (first)
			first = false;
		else
			appendStringInfoChar(s, ' ');

		appendStringInfoString(s, NameStr(attr->attname));

		/* print attribute type */
		appendStringInfoChar(s, '[');
		appendStringInfoString(s, NameStr(type_form->typname));
		appendStringInfoChar(s, ']');

		/* query output function */
		getTypeOutputInfo(typid,
						  &typoutput, &typisvarlena);

		ReleaseSysCache(type_tuple);

		if (!tuple->nulls[natt])
		{
			origval = tuple->values[natt];
			elog(DEBUG1, "SpockErrorLog: Inside spock_tuple_to_stringinfo. \
			origval is NOT NULL");
		}
		else
		{
			isnull = true;
			elog(DEBUG1, "SpockErrorLog: Inside spock_tuple_to_stringinfo. \
			origval is NULL");
		}

		if (isnull)
			outputstr = "(null)";
		else if (typisvarlena && VARATT_IS_EXTERNAL_ONDISK(origval))
			outputstr = "(unchanged-toast-datum)";
		else if (typisvarlena)
			val = PointerGetDatum(PG_DETOAST_DATUM(origval));
		else
			val = origval;

		if (outputstr == NULL)
		{
			outputstr = OidOutputFunctionCall(typoutput, val);
			elog(DEBUG1, "SpockErrorLog: Inside spock_tuple_to_stringinfo. \
			outputstr is (%s)", outputstr);
		}

		/*
		 * Abbreviate the Datum if it's too long. This may make it
		 * syntatically invalid, but it's not like we're writing out a valid
		 * ROW(...) as it is.
		 */
		if (strlen(outputstr) > MAX_CONFLICT_LOG_ATTR_LEN)
			strcpy(&outputstr[MAX_CONFLICT_LOG_ATTR_LEN - 5], "...");

		appendStringInfoChar(s, ':');
		appendStringInfoString(s, outputstr);
	}
}
