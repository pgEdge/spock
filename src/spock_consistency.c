/*-------------------------------------------------------------------------
 *
 * spock_consistency.c
 *		spock table consistency check and repair helper functions
 *
 * Copyright (c) 2022-2024, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/genam.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/sysattr.h"
#include "access/xact.h"

#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/pg_constraint.h"
#include "catalog/pg_index.h"
#include "catalog/pg_type.h"

#include "executor/spi.h"

#include "funcapi.h"

#include "miscadmin.h"

#include "nodes/bitmapset.h"
#include "nodes/makefuncs.h"

#include "parser/parse_coerce.h"
#include "parser/parse_collate.h"
#include "parser/parse_expr.h"
#include "parser/parse_relation.h"

#include "utils/acl.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"
#include "utils/typcache.h"
#include "utils/syscache.h"
#include "utils/typcache.h"

/* Function declarations */
PG_FUNCTION_INFO_V1(spock_get_table_info);
PG_FUNCTION_INFO_V1(spock_get_primary_key_columns);
PG_FUNCTION_INFO_V1(spock_get_all_columns);
PG_FUNCTION_INFO_V1(spock_fetch_table_rows);
PG_FUNCTION_INFO_V1(spock_fetch_table_rows_batch);
PG_FUNCTION_INFO_V1(spock_get_changed_columns);
PG_FUNCTION_INFO_V1(spock_generate_delete_sql);
PG_FUNCTION_INFO_V1(spock_generate_upsert_sql);
PG_FUNCTION_INFO_V1(spock_check_subscription_health);
PG_FUNCTION_INFO_V1(spock_check_table_health);

/* External GUC variables */
extern int spock_diff_batch_size;
extern int spock_diff_max_rows;
extern int spock_repair_batch_size;
extern bool spock_repair_fire_triggers;
extern bool spock_diff_include_timestamps;
extern int spock_health_check_timeout_ms;
extern int spock_health_check_replication_lag_threshold_mb;
extern bool spock_health_check_enabled;

/* Helper structure for table metadata */
typedef struct TableMetadata
{
	char	   *schema;
	char	   *table;
	char	  **pk_cols;
	int			pk_col_count;
	char	  **all_cols;
	int			all_col_count;
	Oid		   *col_types;
} TableMetadata;

/* Forward declarations for internal helpers */
static TableMetadata *get_table_metadata(Oid reloid);
static void free_table_metadata(TableMetadata *tm);
static char *spock_quote_ident(const char *ident);
static char *spock_quote_literal(const char *str);

/*
 * spock_get_table_info - Get comprehensive table metadata
 */
Datum
spock_get_table_info(PG_FUNCTION_ARGS)
{
	Oid			reloid = PG_GETARG_OID(0);
	TupleDesc	tupdesc;
	Datum		values[5];
	bool		nulls[5] = {false, false, false, false, false};
	HeapTuple	tuple;
	TableMetadata *tm;
	Datum	   *pk_datums;
	Datum	   *all_datums;
	Datum	   *type_datums;
	int			i;

	/* Build output tuple descriptor */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in context that cannot accept type record")));

	tm = get_table_metadata(reloid);

	/* schema_name */
	values[0] = CStringGetTextDatum(tm->schema);

	/* table_name */
	values[1] = CStringGetTextDatum(tm->table);

	/* primary_key_cols */
	pk_datums = (Datum *) palloc(sizeof(Datum) * tm->pk_col_count);
	for (i = 0; i < tm->pk_col_count; i++)
		pk_datums[i] = CStringGetTextDatum(tm->pk_cols[i]);
	values[2] = PointerGetDatum(construct_array(pk_datums, tm->pk_col_count,
												TEXTOID, -1, false, TYPALIGN_INT));

	/* all_cols */
	all_datums = (Datum *) palloc(sizeof(Datum) * tm->all_col_count);
	for (i = 0; i < tm->all_col_count; i++)
		all_datums[i] = CStringGetTextDatum(tm->all_cols[i]);
	values[3] = PointerGetDatum(construct_array(all_datums, tm->all_col_count,
												TEXTOID, -1, false, TYPALIGN_INT));

	/* col_types */
	type_datums = (Datum *) palloc(sizeof(Datum) * tm->all_col_count);
	for (i = 0; i < tm->all_col_count; i++)
	{
		char	   *typename = format_type_be(tm->col_types[i]);
		type_datums[i] = CStringGetTextDatum(typename);
	}
	values[4] = PointerGetDatum(construct_array(type_datums, tm->all_col_count,
												TEXTOID, -1, false, TYPALIGN_INT));

	tuple = heap_form_tuple(tupdesc, values, nulls);
	free_table_metadata(tm);

	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * spock_get_primary_key_columns - Get primary key column names
 */
Datum
spock_get_primary_key_columns(PG_FUNCTION_ARGS)
{
	Oid			reloid = PG_GETARG_OID(0);
	TableMetadata *tm;
	Datum	   *datums;
	ArrayType  *result;
	int			i;

	tm = get_table_metadata(reloid);

	if (tm->pk_col_count == 0)
	{
		free_table_metadata(tm);
		PG_RETURN_ARRAYTYPE_P(construct_empty_array(TEXTOID));
	}

	datums = (Datum *) palloc(sizeof(Datum) * tm->pk_col_count);
	for (i = 0; i < tm->pk_col_count; i++)
		datums[i] = CStringGetTextDatum(tm->pk_cols[i]);

	result = construct_array(datums, tm->pk_col_count,
							 TEXTOID, -1, false, TYPALIGN_INT);
	free_table_metadata(tm);

	PG_RETURN_ARRAYTYPE_P(result);
}

/*
 * spock_get_all_columns - Get all column names
 */
Datum
spock_get_all_columns(PG_FUNCTION_ARGS)
{
	Oid			reloid = PG_GETARG_OID(0);
	TableMetadata *tm;
	Datum	   *datums;
	ArrayType  *result;
	int			i;

	tm = get_table_metadata(reloid);

	datums = (Datum *) palloc(sizeof(Datum) * tm->all_col_count);
	for (i = 0; i < tm->all_col_count; i++)
		datums[i] = CStringGetTextDatum(tm->all_cols[i]);

	result = construct_array(datums, tm->all_col_count,
							 TEXTOID, -1, false, TYPALIGN_INT);
	free_table_metadata(tm);

	PG_RETURN_ARRAYTYPE_P(result);
}

/*
 * spock_fetch_table_rows - Fetch all rows from a table with metadata
 */
Datum
spock_fetch_table_rows(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	MemoryContext oldcontext;

	if (SRF_IS_FIRSTCALL())
	{
		Oid			reloid = PG_GETARG_OID(0);
		text	   *filter_text = PG_ARGISNULL(1) ? NULL : PG_GETARG_TEXT_PP(1);
		char	   *filter = filter_text ? text_to_cstring(filter_text) : NULL;
		TableMetadata *tm;
		StringInfoData query;
		TupleDesc	ret_tupdesc;
		int			ret;
		SPITupleTable *tuptable;
		uint64		proc;

		funcctx = SRF_FIRSTCALL_INIT();

		/* Build tuple descriptor for spock.table_row */
		if (get_call_result_type(fcinfo, NULL, &ret_tupdesc) != TYPEFUNC_COMPOSITE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("function returning record called in context that cannot accept type record"),
					 errhint("Try calling the function in FROM clause.")));

		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

		/* Get table metadata */
		tm = get_table_metadata(reloid);

		/* Build query to fetch rows */
		initStringInfo(&query);
		appendStringInfo(&query, "SELECT ");

		/* Add PK columns as array */
		appendStringInfo(&query, "ARRAY[");
		for (int i = 0; i < tm->pk_col_count; i++)
		{
			if (i > 0)
				appendStringInfo(&query, ", ");
			appendStringInfo(&query, "%s::text", spock_quote_ident(tm->pk_cols[i]));
		}
		appendStringInfo(&query, "]::text[] as pk_values, ");

		/* Add all columns as array */
		appendStringInfo(&query, "ARRAY[");
		for (int i = 0; i < tm->all_col_count; i++)
		{
			if (i > 0)
				appendStringInfo(&query, ", ");
			appendStringInfo(&query, "%s::text", spock_quote_ident(tm->all_cols[i]));
		}
		appendStringInfo(&query, "]::text[] as all_values");

		/* Add metadata columns if enabled */
		if (spock_diff_include_timestamps)
		{
			appendStringInfo(&query, ", pg_xact_commit_timestamp(xmin) as commit_ts");
			appendStringInfo(&query, ", COALESCE((SELECT node_name FROM spock.node WHERE node_id = "
							 "(to_json(spock.xact_commit_timestamp_origin(xmin))->>'roident')::oid), 'local') as node_origin");
		}
		else
		{
			appendStringInfo(&query, ", NULL::timestamptz as commit_ts");
			appendStringInfo(&query, ", NULL::text as node_origin");
		}

		appendStringInfo(&query, " FROM %s.%s",
						 spock_quote_ident(tm->schema),
						 spock_quote_ident(tm->table));

		/* Add filter if provided */
		if (filter)
			appendStringInfo(&query, " WHERE %s", filter);

		/* Order by PK */
		if (tm->pk_col_count > 0)
		{
			appendStringInfo(&query, " ORDER BY ");
			for (int i = 0; i < tm->pk_col_count; i++)
			{
				if (i > 0)
					appendStringInfo(&query, ", ");
				appendStringInfo(&query, "%s", spock_quote_ident(tm->pk_cols[i]));
			}
		}

		/* Execute query via SPI */
		ret = SPI_connect();
		if (ret != SPI_OK_CONNECT)
			elog(ERROR, "SPI_connect failed: %d", ret);

		ret = SPI_execute(query.data, true, 0);
		if (ret != SPI_OK_SELECT)
			elog(ERROR, "SPI_execute failed: %d", ret);

		/* Store results in function context */
		tuptable = SPI_tuptable;
		proc = SPI_processed;

		/* Use the expected return type descriptor */
		funcctx->tuple_desc = BlessTupleDesc(ret_tupdesc);
		funcctx->max_calls = proc;
		funcctx->user_fctx = tuptable;

		free_table_metadata(tm);
		if (filter)
			pfree(filter);
		MemoryContextSwitchTo(oldcontext);
	}

	funcctx = SRF_PERCALL_SETUP();

	if (funcctx->call_cntr < funcctx->max_calls)
	{
		SPITupleTable *tuptable = (SPITupleTable *) funcctx->user_fctx;
		HeapTuple	src_tuple = tuptable->vals[funcctx->call_cntr];
		HeapTuple	dst_tuple;
		Datum		values[4];
		bool		nulls[4];
		TupleDesc	src_tupdesc = tuptable->tupdesc;
		TupleDesc	dst_tupdesc = funcctx->tuple_desc;
		int			i;

		/* Extract values from source tuple and build destination tuple */
		/* Map columns: pk_values, all_values, commit_ts, node_origin */
		for (i = 0; i < dst_tupdesc->natts; i++)
		{
			int			src_attnum = i + 1;
			
			if (src_attnum <= src_tupdesc->natts)
			{
				values[i] = SPI_getbinval(src_tuple, src_tupdesc, src_attnum, &nulls[i]);
			}
			else
			{
				nulls[i] = true;
				values[i] = (Datum) 0;
			}
		}

		dst_tuple = heap_form_tuple(dst_tupdesc, values, nulls);
		SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(dst_tuple));
	}
	else
	{
		SPI_finish();
		SRF_RETURN_DONE(funcctx);
	}
}

/*
 * spock_fetch_table_rows_batch - Fetch rows in batches
 * (For now, same as spock_fetch_table_rows; can be optimized later with cursors)
 */
Datum
spock_fetch_table_rows_batch(PG_FUNCTION_ARGS)
{
	return spock_fetch_table_rows(fcinfo);
}

/*
 * spock_get_changed_columns - Get list of changed column names
 */
Datum
spock_get_changed_columns(PG_FUNCTION_ARGS)
{
	ArrayType  *local_arr = PG_GETARG_ARRAYTYPE_P(0);
	ArrayType  *remote_arr = PG_GETARG_ARRAYTYPE_P(1);
	ArrayType  *cols_arr = PG_GETARG_ARRAYTYPE_P(2);
	Datum	   *local_datums;
	Datum	   *remote_datums;
	Datum	   *col_datums;
	bool	   *local_nulls;
	bool	   *remote_nulls;
	bool	   *col_nulls;
	int			local_count;
	int			remote_count;
	int			col_count;
	Datum	   *result_datums;
	int			result_count = 0;
	ArrayType  *result;
	int			i;

	/* Deconstruct arrays */
	deconstruct_array(local_arr, TEXTOID, -1, false, TYPALIGN_INT,
					  &local_datums, &local_nulls, &local_count);
	deconstruct_array(remote_arr, TEXTOID, -1, false, TYPALIGN_INT,
					  &remote_datums, &remote_nulls, &remote_count);
	deconstruct_array(cols_arr, TEXTOID, -1, false, TYPALIGN_INT,
					  &col_datums, &col_nulls, &col_count);

	if (local_count != remote_count || local_count != col_count)
		ereport(ERROR,
				(errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
				 errmsg("array size mismatch: local=%d, remote=%d, cols=%d",
						local_count, remote_count, col_count)));

	result_datums = (Datum *) palloc(sizeof(Datum) * col_count);

	/* Compare values and collect changed column names */
	for (i = 0; i < col_count; i++)
	{
		bool		changed = false;
		char	   *local_str = NULL;
		char	   *remote_str = NULL;

		if (local_nulls[i] != remote_nulls[i])
			changed = true;
		else if (!local_nulls[i])
		{
			local_str = TextDatumGetCString(local_datums[i]);
			remote_str = TextDatumGetCString(remote_datums[i]);

			if (strcmp(local_str, remote_str) != 0)
				changed = true;
		}

		if (changed && !col_nulls[i])
		{
			/* Copy the column name text datum properly */
			char	   *col_str = TextDatumGetCString(col_datums[i]);
			result_datums[result_count++] = CStringGetTextDatum(col_str);
			pfree(col_str);
		}

		/* Free allocated strings */
		if (local_str)
			pfree(local_str);
		if (remote_str)
			pfree(remote_str);
	}

	if (result_count == 0)
		result = construct_empty_array(TEXTOID);
	else
		result = construct_array(result_datums, result_count,
								 TEXTOID, -1, false, TYPALIGN_INT);

	PG_RETURN_ARRAYTYPE_P(result);
}

/*
 * spock_generate_delete_sql - Generate DELETE statement
 */
Datum
spock_generate_delete_sql(PG_FUNCTION_ARGS)
{
	Oid			reloid = PG_GETARG_OID(0);
	ArrayType  *pk_arr = PG_GETARG_ARRAYTYPE_P(1);
	TableMetadata *tm;
	Datum	   *pk_datums;
	bool	   *pk_nulls;
	int			pk_count;
	StringInfoData sql;
	int			i;

	tm = get_table_metadata(reloid);

	deconstruct_array(pk_arr, TEXTOID, -1, false, TYPALIGN_INT,
					  &pk_datums, &pk_nulls, &pk_count);

	if (pk_count != tm->pk_col_count)
		ereport(ERROR,
				(errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
				 errmsg("PK value count mismatch: expected %d, got %d",
						tm->pk_col_count, pk_count)));

	initStringInfo(&sql);
	appendStringInfo(&sql, "DELETE FROM %s.%s WHERE ",
					 spock_quote_ident(tm->schema),
					 spock_quote_ident(tm->table));

	for (i = 0; i < pk_count; i++)
	{
		char	   *pk_value;

		if (i > 0)
			appendStringInfo(&sql, " AND ");

		pk_value = TextDatumGetCString(pk_datums[i]);
		appendStringInfo(&sql, "%s = %s",
						 spock_quote_ident(tm->pk_cols[i]),
						 spock_quote_literal(pk_value));
	}

	free_table_metadata(tm);

	PG_RETURN_TEXT_P(cstring_to_text(sql.data));
}

/*
 * spock_generate_upsert_sql - Generate INSERT...ON CONFLICT statement
 */
Datum
spock_generate_upsert_sql(PG_FUNCTION_ARGS)
{
	Oid			reloid = PG_GETARG_OID(0);
	ArrayType  *pk_arr = PG_GETARG_ARRAYTYPE_P(1);
	ArrayType  *val_arr = PG_GETARG_ARRAYTYPE_P(2);
	bool		insert_only = PG_GETARG_BOOL(3);
	TableMetadata *tm;
	Datum	   *pk_datums;
	Datum	   *val_datums;
	bool	   *pk_nulls;
	bool	   *val_nulls;
	int			pk_count;
	int			val_count;
	StringInfoData sql;
	int			i;

	tm = get_table_metadata(reloid);

	deconstruct_array(pk_arr, TEXTOID, -1, false, TYPALIGN_INT,
					  &pk_datums, &pk_nulls, &pk_count);
	deconstruct_array(val_arr, TEXTOID, -1, false, TYPALIGN_INT,
					  &val_datums, &val_nulls, &val_count);

	if (val_count != tm->all_col_count)
		ereport(ERROR,
				(errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
				 errmsg("value count mismatch: expected %d, got %d",
						tm->all_col_count, val_count)));

	initStringInfo(&sql);

	/* INSERT clause */
	appendStringInfo(&sql, "INSERT INTO %s.%s (",
					 spock_quote_ident(tm->schema),
					 spock_quote_ident(tm->table));

	for (i = 0; i < tm->all_col_count; i++)
	{
		if (i > 0)
			appendStringInfo(&sql, ", ");
		appendStringInfo(&sql, "%s", spock_quote_ident(tm->all_cols[i]));
	}

	appendStringInfo(&sql, ") VALUES (");

	for (i = 0; i < val_count; i++)
	{
		char	   *value;

		if (i > 0)
			appendStringInfo(&sql, ", ");

		if (val_nulls[i])
			appendStringInfo(&sql, "NULL");
		else
		{
			value = TextDatumGetCString(val_datums[i]);
			appendStringInfo(&sql, "%s", spock_quote_literal(value));
		}
	}

	appendStringInfo(&sql, ")");

	/* ON CONFLICT clause */
	appendStringInfo(&sql, " ON CONFLICT (");
	for (i = 0; i < tm->pk_col_count; i++)
	{
		if (i > 0)
			appendStringInfo(&sql, ", ");
		appendStringInfo(&sql, "%s", spock_quote_ident(tm->pk_cols[i]));
	}
	appendStringInfo(&sql, ")");

	if (insert_only)
	{
		appendStringInfo(&sql, " DO NOTHING");
	}
	else
	{
		bool		first = true;

		appendStringInfo(&sql, " DO UPDATE SET ");

		for (i = 0; i < tm->all_col_count; i++)
		{
			bool		is_pk = false;

			/* Skip PK columns in UPDATE */
			for (int j = 0; j < tm->pk_col_count; j++)
			{
				if (strcmp(tm->all_cols[i], tm->pk_cols[j]) == 0)
				{
					is_pk = true;
					break;
				}
			}

			if (!is_pk)
			{
				if (!first)
					appendStringInfo(&sql, ", ");
				appendStringInfo(&sql, "%s = EXCLUDED.%s",
								 spock_quote_ident(tm->all_cols[i]),
								 spock_quote_ident(tm->all_cols[i]));
				first = false;
			}
		}
	}

	free_table_metadata(tm);

	PG_RETURN_TEXT_P(cstring_to_text(sql.data));
}

/*
 * spock_check_subscription_health - Check subscription health status
 */
Datum
spock_check_subscription_health(PG_FUNCTION_ARGS)
{
	/* Placeholder - returns empty set for now */
	/* Full implementation would query spock.subscription and worker status */
	PG_RETURN_NULL();
}

/*
 * spock_check_table_health - Check table health (PK, size, bloat, etc)
 */
Datum
spock_check_table_health(PG_FUNCTION_ARGS)
{
	/* Placeholder - returns empty set for now */
	/* Full implementation would check table structure and statistics */
	PG_RETURN_NULL();
}

/*
 * Internal helper: get_table_metadata
 */
static TableMetadata *
get_table_metadata(Oid reloid)
{
	Relation	rel;
	TupleDesc	tupdesc;
	Oid			pk_index_oid;
	Relation	pk_index_rel;
	TableMetadata *tm;
	int			i;
	int			natts;

	tm = (TableMetadata *) palloc0(sizeof(TableMetadata));

	rel = table_open(reloid, AccessShareLock);
	tupdesc = RelationGetDescr(rel);
	natts = tupdesc->natts;

	/* Get schema and table name */
	tm->schema = get_namespace_name(RelationGetNamespace(rel));
	tm->table = pstrdup(RelationGetRelationName(rel));

	/* Get all columns */
	tm->all_col_count = 0;
	tm->all_cols = (char **) palloc(sizeof(char *) * natts);
	tm->col_types = (Oid *) palloc(sizeof(Oid) * natts);

	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute attr = TupleDescAttr(tupdesc, i);

		if (attr->attisdropped)
			continue;

		tm->all_cols[tm->all_col_count] = pstrdup(NameStr(attr->attname));
		tm->col_types[tm->all_col_count] = attr->atttypid;
		tm->all_col_count++;
	}

	/* Get primary key columns */
	pk_index_oid = RelationGetPrimaryKeyIndex(rel, false);
	if (OidIsValid(pk_index_oid))
	{
		pk_index_rel = index_open(pk_index_oid, AccessShareLock);
		tm->pk_col_count = pk_index_rel->rd_index->indnatts;
		tm->pk_cols = (char **) palloc(sizeof(char *) * tm->pk_col_count);

		for (i = 0; i < tm->pk_col_count; i++)
		{
			int			attno = pk_index_rel->rd_index->indkey.values[i];
			Form_pg_attribute attr = TupleDescAttr(tupdesc, attno - 1);
			tm->pk_cols[i] = pstrdup(NameStr(attr->attname));
		}

		index_close(pk_index_rel, AccessShareLock);
	}
	else
	{
		tm->pk_col_count = 0;
		tm->pk_cols = NULL;
	}

	table_close(rel, AccessShareLock);

	return tm;
}

/*
 * Internal helper: free_table_metadata
 */
static void
free_table_metadata(TableMetadata *tm)
{
	int			i;

	if (tm->schema)
		pfree(tm->schema);
	if (tm->table)
		pfree(tm->table);

	if (tm->pk_cols)
	{
		for (i = 0; i < tm->pk_col_count; i++)
			if (tm->pk_cols[i])
				pfree(tm->pk_cols[i]);
		pfree(tm->pk_cols);
	}

	if (tm->all_cols)
	{
		for (i = 0; i < tm->all_col_count; i++)
			if (tm->all_cols[i])
				pfree(tm->all_cols[i]);
		pfree(tm->all_cols);
	}

	if (tm->col_types)
		pfree(tm->col_types);

	pfree(tm);
}

/*
 * Internal helper: spock_quote_ident
 */
static char *
spock_quote_ident(const char *ident)
{
	return pstrdup(quote_identifier(ident));
}

/*
 * Internal helper: spock_quote_literal
 */
static char *
spock_quote_literal(const char *str)
{
	return pstrdup(quote_literal_cstr(str));
}
