/*-------------------------------------------------------------------------
 *
 * spock_queue.c
 *		spock queue and connection catalog manipulation functions
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/genam.h"
#include "access/hash.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/xact.h"

#include "catalog/dependency.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/objectaddress.h"
#include "catalog/pg_extension.h"
#include "catalog/pg_trigger.h"
#include "catalog/pg_type.h"

#include "commands/extension.h"

#include "executor/spi.h"

#include "miscadmin.h"

#include "nodes/makefuncs.h"

#include "parser/parse_func.h"

#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/json.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/timestamp.h"

#include "spock_common.h"
#include "spock_queue.h"
#include "spock_repset.h"
#include "spock.h"

#define CATALOG_QUEUE	"queue"

#define Natts_queue					5
#define Anum_queue_queued_at		1
#define Anum_queue_role				2
#define Anum_queue_replication_sets	3
#define Anum_queue_message_type		4
#define Anum_queue_message			5

typedef struct QueueTuple
{
	TimestampTz	queued_at;
	NameData	replication_set;
	NameData	role;
	char		message_type;
/*	json		message;*/
} QueueTuple;

/*
 * Add tuple to the queue table.
 */
void
queue_message(List *replication_sets, Oid roleoid, char message_type,
			  char *message)
{
	RangeVar   *rv;
	Relation	rel;
	TupleDesc	tupDesc;
	HeapTuple	tup;
	Datum		values[Natts_queue];
	bool		nulls[Natts_queue];
	const char *role;
	TimestampTz ts = GetCurrentTimestamp();

	role =  GetUserNameFromId(roleoid
#if PG_VERSION_NUM >= 90500
							  , false
#endif
							 );

	rv = makeRangeVar(EXTENSION_NAME, CATALOG_QUEUE, -1);
	rel = table_openrv(rv, RowExclusiveLock);
	tupDesc = RelationGetDescr(rel);

	/* Form a tuple. */
	memset(nulls, false, sizeof(nulls));

	values[Anum_queue_queued_at - 1] = TimestampTzGetDatum(ts);
	values[Anum_queue_role - 1] =
		DirectFunctionCall1(namein, CStringGetDatum(role));
	if (replication_sets)
		values[Anum_queue_replication_sets - 1] =
			PointerGetDatum(strlist_to_textarray(replication_sets));
	else
		nulls[Anum_queue_replication_sets - 1] = true;
	values[Anum_queue_message_type - 1] = CharGetDatum(message_type);
	values[Anum_queue_message - 1] =
		DirectFunctionCall1(json_in, CStringGetDatum(message));

	tup = heap_form_tuple(tupDesc, values, nulls);

	/* Insert the tuple to the catalog. */
	CatalogTupleInsert(rel, tup);

	/* Cleanup. */
	heap_freetuple(tup);
	table_close(rel, NoLock);
}


/*
 * Parse the tuple from the queue table into palloc'd QueuedMessage struct.
 *
 * The caller must have the queue table locked in at least AccessShare mode.
 */
QueuedMessage *
queued_message_from_tuple(HeapTuple queue_tup)
{
	RangeVar   *rv;
	Relation	rel;
	TupleDesc	tupDesc;
	bool		isnull;
	Datum		d;
	QueuedMessage *res;

	/* Open relation to get the tuple descriptor. */
	rv = makeRangeVar(EXTENSION_NAME, CATALOG_QUEUE, -1);
	rel = table_openrv(rv, NoLock);
	tupDesc = RelationGetDescr(rel);

	res = (QueuedMessage *) palloc(sizeof(QueuedMessage));

	d = fastgetattr(queue_tup, Anum_queue_queued_at, tupDesc, &isnull);
	Assert(!isnull);
	res->queued_at = DatumGetTimestampTz(d);

	d = fastgetattr(queue_tup, Anum_queue_role, tupDesc, &isnull);
	Assert(!isnull);
	res->role = pstrdup(NameStr(*DatumGetName(d)));

	d = fastgetattr(queue_tup, Anum_queue_replication_sets, tupDesc, &isnull);
	if (!isnull)
		res->replication_sets = textarray_to_list(DatumGetArrayTypeP(d));
	else
		res->replication_sets = NULL;

	d = fastgetattr(queue_tup, Anum_queue_message_type, tupDesc, &isnull);
	Assert(!isnull);
	res->message_type = DatumGetChar(d);

	d = fastgetattr(queue_tup, Anum_queue_message, tupDesc, &isnull);
	Assert(!isnull);
	/* Parse the json inside the message into Jsonb object. */
	res->message = DatumGetJsonb(
		DirectFunctionCall1(jsonb_in, DirectFunctionCall1(json_out, d)));

	/* Close the relation. */
	table_close(rel, NoLock);

	return res;
}

/*
 * Get (cached) oid of the queue table.
 */
Oid
get_queue_table_oid(void)
{
	static Oid	queuetableoid = InvalidOid;

	if (queuetableoid == InvalidOid)
		queuetableoid = get_spock_table_oid(CATALOG_QUEUE);

	return queuetableoid;
}


/*
 * Create a TRUNCATE trigger for a persistent table and mark
 * it tgisinternal so that it's not dumped by pg_dump.
 *
 * This is basically wrapper around CreateTrigger().
 */
void
create_truncate_trigger(Oid relid)
{
	Relation		rel;
	CreateTrigStmt *tgstmt;
	ObjectAddress	trgobj;
	ObjectAddress	extension;
	Oid				fargtypes[1];
	List		   *funcname = list_make2(makeString(EXTENSION_NAME),
									  makeString("queue_truncate"));

	/*
	 * Check for already existing trigger on the table to avoid adding
	 * duplicate ones.
	 */
	rel = table_open(relid, ShareRowExclusiveLock);
	if (rel->trigdesc)
	{
		Trigger	   *trigger = rel->trigdesc->triggers;
		int			i;
		Oid			funcoid = LookupFuncName(funcname, 0, fargtypes, false);

		for (i = 0; i < rel->trigdesc->numtriggers; i++)
		{
			if (!TRIGGER_FOR_TRUNCATE(trigger->tgtype))
				continue;

			if (trigger->tgfoid == funcoid)
			{
				table_close(rel, NoLock);
				return;
			}

			trigger++;
		}
	}
	table_close(rel, NoLock);

	tgstmt = makeNode(CreateTrigStmt);
	tgstmt->trigname = "queue_truncate_trigger";
	tgstmt->relation = NULL;
	tgstmt->funcname = funcname;
	tgstmt->args = NIL;
	tgstmt->row = false;
	tgstmt->timing = TRIGGER_TYPE_AFTER;
	tgstmt->events = TRIGGER_TYPE_TRUNCATE;
	tgstmt->columns = NIL;
	tgstmt->whenClause = NULL;
	tgstmt->isconstraint = false;
	tgstmt->deferrable = false;
	tgstmt->initdeferred = false;
	tgstmt->constrrel = NULL;

	trgobj = SPKCreateTrigger(tgstmt, NULL, RelationGetRelid(rel), InvalidOid,
							  InvalidOid, InvalidOid, true /* tgisinternal */);

	extension.classId = ExtensionRelationId;
	extension.objectId = get_extension_oid(EXTENSION_NAME, false);
	extension.objectSubId = 0;

	recordDependencyOn(&trgobj, &extension, DEPENDENCY_AUTO);

	/* Make the new trigger visible within this session */
	CommandCounterIncrement();
}

/*
 * Create columns _Spock_CommitTS_ and _Spock_CommitOrigin_
 * if they don't exist on a relation.
 */
void
create_commit_info_columns(Oid relid)
{
	Relation			rel;
	TupleDesc			tupdesc;
	const char		   *nspname;
	const char		   *relname;
	StringInfoData		query;
	bool				col_ts_exists = false;
	bool				col_origin_exists = false;

	/* Check if the columns exist already */
	rel = table_open(relid, ShareRowExclusiveLock);
	tupdesc = RelationGetDescr(rel);
	if (get_att_num_by_name(tupdesc, "_Spock_CommitTS_") > 0)
		col_ts_exists = true;
	if (get_att_num_by_name(tupdesc, "_Spock_CommitOrigin_") > 0)
		col_origin_exists = true;
	table_close(rel, NoLock);
	if (col_ts_exists && col_origin_exists)
		return;

	nspname = quote_identifier(get_namespace_name(get_rel_namespace(relid)));
	relname = quote_identifier(get_rel_name(relid));
	SPI_connect();

	/* If _Spock_CommitTS_ does not exist add it */
	if (!col_ts_exists)
	{
		initStringInfo(&query);
		appendStringInfo(&query, "ALTER TABLE %s.%s ADD COLUMN "
						 "\"_Spock_CommitTS_\" pg_catalog.timestamptz;\n",
						 nspname, relname);
		appendStringInfo(&query, "ALTER TABLE %s.%s ALTER COLUMN "
						 "\"_Spock_CommitTS_\" SET (invisible=true);",
						 nspname, relname);
		SPI_execute(query.data, false, 0);
	}

	/* If _Spock_CommitOrigin_ does not exist add it */
	if (!col_ts_exists)
	{
		initStringInfo(&query);
		appendStringInfo(&query, "ALTER TABLE %s.%s ADD COLUMN "
						 "\"_Spock_CommitOrigin_\" pg_catalog.int4;\n",
						 nspname, relname);
		appendStringInfo(&query, "ALTER TABLE %s.%s ALTER COLUMN "
						 "\"_Spock_CommitOrigin_\" SET (invisible=true);",
						 nspname, relname);
		SPI_execute(query.data, false, 0);
	}

	SPI_finish();
}
