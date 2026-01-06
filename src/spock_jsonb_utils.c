/*-------------------------------------------------------------------------
 *
 * spock_jsonb_utils.c
 * 		spock JSONB utility functions
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
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

#include "executor/spi.h"

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
#include "utils/json.h"
#include "utils/jsonb.h"
#include "utils/jsonfuncs.h"
#include "utils/typcache.h"
#include "utils/attoptcache.h"

#include "parser/parse_coerce.h"

#include "replication/origin.h"
#include "replication/slot.h"

#include "pgstat.h"

#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_conflict.h"
#include "spock_relcache.h"
#include "spock_jsonb_utils.h"


/*
 * Convert one Datum to CString containing valid Json
 *
 * This may be optimized to use a direct call of to_json(ANYELEMENT)
 * via the fmgr. However, this is not performance critical enough to
 * develop this now because due to ANYELEMENT this involves the
 * executor and not just the fmgr.
 */
static char *
datum_to_json_cstring(Datum val, Oid type, bool isnull)
{
	char	   *query = "SELECT pg_catalog.to_json($1)::text";
	Oid			argtypes[1];
	Datum		values[1];
	Datum		resval;
	char	   *result;
	bool		resnull;
	int			rc;

	/* Return a 'null' string if called with a NULL value */
	if (isnull)
		return "null";

	/* Setup call arguments for SPI_execute_with_args() */
	argtypes[0] = type;
	values[0] = val;

	/* Execute the SPI query */
	rc = SPI_execute_with_args(query, 1, argtypes, values, NULL, true, 0);
	if (rc != SPI_OK_SELECT)
		elog(ERROR, "datum_to_json_cstring: SPI query '%s' returned %d",
			 query, rc);
	if (SPI_processed != 1)
		elog(ERROR, "datum_to_json_cstring: query returned " UINT64_FORMAT " tupes - "
			 "expected 1", SPI_processed);

	/* Get the binary text datum */
	resval = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
						   1, &resnull);

	/* If for any reason to_json() returned NULL we convert to 'null' string */
	if (resnull)
	{
		SPI_freetuptable(SPI_tuptable);
		return "null";
	}

	/* Convert the result to CString, cleanup and return result */
	result = DatumGetCString(DirectFunctionCall1(textout, resval));
	SPI_freetuptable(SPI_tuptable);
	return result;
}

static inline char *
name_to_json_cstring(Name name)
{
	return datum_to_json_cstring(NameGetDatum(name), NAMEOID, false);
}

char *
spock_tuple_to_json_cstring(SpockTupleData *tuple, TupleDesc tupleDesc)
{
	int			natt;
	Oid			typid;
	int			rc;

	StringInfoData s;
	bool		add_comma = false;

	initStringInfo(&s);
	appendStringInfoString(&s, "[");

	/* Connect to SPI, every call to convert a datum to json needs it */
	rc = SPI_connect();
	if (rc != SPI_OK_CONNECT)
		elog(ERROR, "datum_to_json_cstring: SPI_connect returned %d", rc);

	/* print all columns individually */
	for (natt = 0; natt < tupleDesc->natts; natt++)
	{
		Form_pg_attribute attr; /* the attribute itself */
		HeapTuple	type_tuple; /* information about a type */
		Form_pg_type type_form;

		attr = TupleDescAttr(tupleDesc, natt);

		/*
		 * don't print dropped columns, we can't be sure everything is
		 * available for them
		 */
		if (attr->attisdropped || attr->attgenerated)
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
		ReleaseSysCache(type_tuple);

		/* Assemble the attributes of the tuple */
		if (add_comma)
			appendStringInfoString(&s, ", ");
		else
			add_comma = true;
		appendStringInfo(&s, "{\"attname\": %s, ",
						 name_to_json_cstring(&attr->attname));
		appendStringInfo(&s, "\"atttype\": %s, ",
						 name_to_json_cstring(&type_form->typname));
		appendStringInfo(&s, "\"value\": %s}",
						 datum_to_json_cstring(tuple->values[natt],
											   type_form->oid,
											   tuple->nulls[natt]));

	}

	/* Cleanup SPI */
	SPI_finish();

	/* Terminate the json string and return the result */
	appendStringInfoString(&s, "]");
	return s.data;
}

char *
heap_tuple_to_json_cstring(HeapTuple *tuple, TupleDesc tupleDesc)
{
	int			natt;
	bool		add_comma = false;
	StringInfoData s;
	int			rc;

	initStringInfo(&s);
	appendStringInfo(&s, "[");

	/* Connect to SPI, every call to convert a datum to json needs it */
	rc = SPI_connect();
	if (rc != SPI_OK_CONNECT)
		elog(ERROR, "datum_to_json_cstring: SPI_connect returned %d", rc);

	/* print all columns individually */
	for (natt = 0; natt < tupleDesc->natts; natt++)
	{
		Form_pg_attribute attr; /* the attribute itself */
		Oid			typid;		/* type of current attribute */
		HeapTuple	type_tuple; /* information about a type */
		Form_pg_type type_form;
		Datum		origval = PointerGetDatum(NULL);	/* possibly toasted
														 * Datum */
		bool		isnull = false; /* column is null? */

		attr = TupleDescAttr(tupleDesc, natt);

		/*
		 * don't print dropped columns, we can't be sure everything is
		 * available for them
		 */
		if (attr->attisdropped || attr->attgenerated)
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
		ReleaseSysCache(type_tuple);

		/* Assemble the attributes of the tuple */
		if (add_comma)
			appendStringInfoString(&s, ", ");
		else
			add_comma = true;
		appendStringInfo(&s, "{\"attname\": %s, ",
						 name_to_json_cstring(&attr->attname));
		appendStringInfo(&s, "\"atttype\": %s, ",
						 name_to_json_cstring(&type_form->typname));
		origval = heap_getattr(*tuple, natt + 1, tupleDesc, &isnull);
		appendStringInfo(&s, "\"value\": %s}",
						 datum_to_json_cstring(origval,
											   type_form->oid,
											   isnull));
	}

	/* Cleanup SPI */
	SPI_finish();

	appendStringInfoString(&s, "]");
	return s.data;
}
