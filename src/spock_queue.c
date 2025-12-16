/*-------------------------------------------------------------------------
 *
 * spock_queue.c
 *		spock queue and connection catalog manipulation functions
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
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
#include "spock_compat.h"

#define CATALOG_QUEUE	"queue"

#define Natts_queue					5
#define Anum_queue_queued_at		1
#define Anum_queue_role				2
#define Anum_queue_replication_sets	3
#define Anum_queue_message_type		4
#define Anum_queue_message			5

typedef struct QueueTuple
{
	TimestampTz queued_at;
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

	role = GetUserNameFromId(roleoid, false);

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
