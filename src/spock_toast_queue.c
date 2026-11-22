/*-------------------------------------------------------------------------
 *
 * spock_toast_queue.c
 *		Reading and updating spock.toast_suspect entries
 *
 * read_entries() reads a batch of entries together with what the local catalog
 * says about each entry's table, columns and key, and hashes the suspect
 * columns of each entry's local row.  suspect_mark() and suspect_delete()
 * record an outcome, guarded so an entry detected again since it was read is
 * left alone.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/commit_ts.h"
#include "catalog/pg_namespace.h"
#include "catalog/pg_operator.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "utils/guc.h"
#include "utils/builtins.h"
#include "utils/json.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"
#include "utils/typcache.h"

#include "spock.h"
#include "spock_common.h"
#include "spock_conflict.h"
#include "spock_toast_internal.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

/*
 * The batch reads' view of an entry's key, kc: ok is true when every key in
 * s.pkey still names a live column of the table, and each other column is
 * used only then.  A key column that was renamed or dropped would otherwise
 * leave a WHERE that matches some other row, and comparing that row could
 * clear an entry that had really diverged.
 *
 * The key columns' names, types, type OIDs and values, in attnum order;
 * entry_key_clauses() builds the SQL that matches the row from them.
 */
#define KEY_COLUMNS_LATERAL \
	"  LEFT JOIN LATERAL ( " \
	"    SELECT count(*) = (SELECT count(*) FROM jsonb_object_keys(s.pkey)) AS ok, " \
	"           array_agg(a.attname::text ORDER BY a.attnum) AS names, " \
	"           array_agg(format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum) AS types, " \
	"           array_agg(e.value ORDER BY a.attnum) AS vals, " \
	"           array_agg(a.atttypid ORDER BY a.attnum) AS typids " \
	"      FROM jsonb_each_text(s.pkey) e " \
	"      JOIN pg_attribute a ON a.attrelid = s.relid " \
	"       AND a.attname = e.key AND NOT a.attisdropped) kc ON true "

/*
 * Settling an entry: both of these match on the detect_count and
 * detected_at the batch read, and report whether they found the row.
 *
 * The apply worker's upsert bumps detect_count and puts the entry back in
 * 'suspect' whenever it detects the row again.  A settlement computed from
 * hashes read before that happened would overwrite, or delete outright,
 * a detection it knows nothing about, so an entry re-detected (or cleared by
 * the operator) while this call was comparing is left alone and picked up by
 * the next run.
 *
 * Neither waits for a lock on the entry.  An apply worker that detects the
 * row again holds it until its whole remote transaction commits, and
 * waiting here would hold every entry settled so far against other apply
 * workers for that long, and could deadlock with the same transaction.  A
 * locked entry is being detected again, so it is skipped like one that was.
 */
/*
 * Input/output for one grouped local-hash SPI call, run through
 * run_in_subxact() so a bad row (e.g. a value whose output function errors)
 * fails just that query instead of aborting the rest of the batch read.
 */
typedef struct GroupHashArg
{
	/* in */
	const char *sql;
	const char *json_param;
	int			ncols;
	Oid			relid;			/* the query runs as this table's owner */
	MemoryContext destcxt;		/* where the results must outlive SPI_finish */

	/* out, allocated in destcxt */
	int			nrows;
	char	  **pkey;			/* nrows entries: the row's __pkey__ text */
	char	 ***hash;			/* nrows x ncols: COLUMN_HASH_SQL, or NULL */
	int64	   *est_bytes;
} GroupHashArg;

/*
 * The columns of the read_entries() query, for SPI_getvalue() and
 * SPI_getbinval().  Keep them in the order of its select list.
 */
typedef enum EntryColumn
{
	EC_RELID = 1,
	EC_PKEY,
	EC_WINNER_SUBID,
	EC_SUB_ENABLED,
	EC_WINNER_NODE_ID,
	EC_TABLE_EXISTS,
	EC_QUALNAME,
	EC_KEY_NAMES,
	EC_COLNAMES,
	EC_COLTYPES,
	EC_ATTNUMS,
	EC_DETECT_COUNT,
	EC_KEY_TYPES,
	EC_KEY_VALUES,
	EC_KEY_TYPIDS,
	EC_STATE,
	EC_STORED_PTRS,
	EC_FIRST_WINNER_TS,
	EC_WINNER_NODE_NAME,
	EC_SUB_EXISTS,
	EC_REASON,
	EC_DETECTED_AT
} EntryColumn;

/* $1 to $4 of ENTRY_AS_READ_SQL: the entry as the batch read it. */
void
entry_guard_values(const RepairEntry *e, Datum *values)
{
	values[0] = ObjectIdGetDatum(e->relid);
	values[1] = CStringGetTextDatum(e->pkey);
	values[2] = Int32GetDatum(e->detect_count);
	values[3] = TimestampTzGetDatum(e->detected_at);
}

bool
suspect_mark(const RepairEntry *e, const char *state, const char *error,
			 const char *differing, const char *winner_ts,
			 const char *winner_origin)
{
	Oid			argtypes[9] = {ENTRY_GUARD_TYPES, TEXTOID, TEXTOID, TEXTOID,
	TEXTOID, TEXTOID};
	Datum		values[9];
	char		nulls[9] = "         ";
	int			ret;

	entry_guard_values(e, values);
	values[4] = CStringGetTextDatum(state);
	if (error)
		values[5] = CStringGetTextDatum(error);
	else
		nulls[5] = 'n';
	if (differing)
		values[6] = CStringGetTextDatum(differing);
	else
		nulls[6] = 'n';
	if (winner_ts)
		values[7] = CStringGetTextDatum(winner_ts);
	else
		nulls[7] = 'n';
	if (winner_origin)
		values[8] = CStringGetTextDatum(winner_origin);
	else
		nulls[8] = 'n';

	/*
	 * verified_at is set on every mark, the failed ones included: the batch
	 * is ordered by it, so an entry that just failed goes to the back of the
	 * queue instead of being retried ahead of entries never tried at all.
	 */
	ret = SPI_execute_with_args(
								"UPDATE spock.toast_suspect SET state = $5, last_error = $6, "
								"  differing = CASE WHEN state = $5 THEN coalesce($7::int2[], differing) "
								"    ELSE $7::int2[] END, verified_at = now(), "
								"  winner_ts = coalesce($8::timestamptz, winner_ts), "
								"  winner_origin = coalesce($9::oid, winner_origin) "
								"WHERE (relid, pkey) IN (" ENTRY_AS_READ_SQL ")",
								9, argtypes, values, nulls, false, 0);
	if (ret != SPI_OK_UPDATE)
		elog(ERROR, "SPI_execute_with_args failed updating spock.toast_suspect: %d", ret);

	return SPI_processed > 0;
}

bool
suspect_delete(const RepairEntry *e)
{
	Oid			argtypes[4] = {ENTRY_GUARD_TYPES};
	Datum		values[4];
	int			ret;

	entry_guard_values(e, values);
	ret = SPI_execute_with_args("DELETE FROM spock.toast_suspect "
								"WHERE (relid, pkey) IN (" ENTRY_AS_READ_SQL ")",
								4, argtypes, values, NULL, false, 0);
	if (ret != SPI_OK_DELETE)
		elog(ERROR, "SPI_execute_with_args failed deleting from spock.toast_suspect: %d", ret);

	return SPI_processed > 0;
}

static void
group_hash_cb(void *arg)
{
	GroupHashArg *a = (GroupHashArg *) arg;
	UserContext ucxt;
	Oid			argtypes[1] = {TEXTOID};
	Datum		argvals[1];
	int			nestlevel;
	int			ret;
	uint64		r;

	argvals[0] = CStringGetTextDatum(a->json_param);
	/* owner_enter(): the subtransaction abort restores. */
	nestlevel = owner_enter(table_owner(a->relid), &ucxt);
	ret = SPI_execute_with_args(a->sql, 1, argtypes, argvals, NULL, true, 0);
	owner_leave(&ucxt, nestlevel);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute_with_args failed hashing local rows: %d", ret);

	a->nrows = SPI_processed;
	if (a->nrows > 0)
	{
		/*
		 * Switched to destcxt: SPI_getvalue() allocates in the current
		 * context, so this is enough to make the copies outlive SPI_finish()
		 * without a separate pstrdup.
		 */
		MemoryContext oldcxt = MemoryContextSwitchTo(a->destcxt);
		int			c;

		a->pkey = palloc(a->nrows * sizeof(char *));
		a->hash = palloc(a->nrows * sizeof(char **));
		a->est_bytes = palloc(a->nrows * sizeof(int64));
		for (r = 0; r < (uint64) a->nrows; r++)
		{
			HeapTuple	row = SPI_tuptable->vals[r];
			TupleDesc	desc = SPI_tuptable->tupdesc;
			bool		isnull;

			a->pkey[r] = SPI_getvalue(row, desc, 1);
			a->hash[r] = palloc(a->ncols * sizeof(char *));
			for (c = 0; c < a->ncols; c++)
				a->hash[r][c] = SPI_getvalue(row, desc, 2 + c);
			a->est_bytes[r] = DatumGetInt64(SPI_getbinval(row, desc, 2 + a->ncols, &isnull));
			if (isnull)
				a->est_bytes[r] = 0;
		}
		MemoryContextSwitchTo(oldcxt);
	}
	SPI_freetuptable(SPI_tuptable);
}

/*
 * Whether entry b can share a's batched query: the same table, key columns
 * and suspect columns.  a must have a usable key.
 */
bool
same_shape(const RepairEntry *a, const RepairEntry *b)
{
	int			c;

	if (a->relid != b->relid || a->ncols != b->ncols ||
		b->pkjoin == NULL || b->pkcols_text == NULL ||
		strcmp(a->pkjoin, b->pkjoin) != 0 ||
		strcmp(a->pkcols_text, b->pkcols_text) != 0)
		return false;
	for (c = 0; c < a->ncols; c++)
		if (strcmp(a->colnames[c], b->colnames[c]) != 0)
			return false;
	return true;
}

/*
 * Whether the entry has what a batched query needs: a live table, suspect
 * columns left, and a key that fully matches live columns.
 */
bool
entry_usable(const RepairEntry *e)
{
	return e->table_exists && e->ncols > 0 && e->qualname != NULL &&
		e->where_clause != NULL && e->pkjoin != NULL &&
		e->pkcols_text != NULL && strcmp(e->pkey, "{}") != 0;
}

/*
 * Whether the batch read hashes the entry's local row.  Not for one the
 * repair worker can only leave waiting or delete (its winner subscription
 * disabled, dropped or never known): hashing it on every pass would read
 * its large values for nothing.
 */
static bool
entry_needs_hash(const RepairEntry *e, bool for_repair)
{
	if (!entry_usable(e))
		return false;
	if (for_repair && (!e->sub_enabled || (OidIsValid(e->subid) && !e->sub_exists)))
		return false;
	return true;
}

/*
 * Append one entry's row of a batched query's $1 array: "k", its key object
 * (already jsonb text, values as JSON strings), and "__pkey__", a copy of
 * that text, so a returned row can be matched back to its entry.  For the
 * winner fetch, also "__wts__", the entry's oldest winner timestamp, and
 * "h0".."hN", its local hashes, null for a NULL column.  The key is nested
 * so that no key column name can clash with these fields (KEY_FROM_PARAM).
 */
void
append_key_object(StringInfo buf, const RepairEntry *e, bool for_fetch)
{
	appendStringInfoString(buf, "{\"k\":");
	appendStringInfoString(buf, e->pkey);
	appendStringInfoString(buf, ",\"__pkey__\":");
	escape_json(buf, e->pkey);
	if (for_fetch)
	{
		int			c;

		appendStringInfoString(buf, ",\"__wts__\":");
		escape_json(buf, e->first_winner_ts);
		for (c = 0; c < e->ncols; c++)
		{
			appendStringInfo(buf, ",\"h%d\":", c);
			if (e->local_hash[c] != NULL)
				escape_json(buf, e->local_hash[c]);
			else
				appendStringInfoString(buf, "null");
		}
	}
	appendStringInfoChar(buf, '}');
}

/*
 * Hash the local rows of n same-shape entries (same_shape()) with one query,
 * matching a jsonb array of their keys against the table with
 * jsonb_to_recordset(), and record on each entry what it found.  Returns
 * false, with *errmsg set and the entries untouched, if the query failed.
 */
static bool
hash_local_rows(RepairEntry **group, int n, MemoryContext destcxt,
				char **errmsg)
{
	RepairEntry *base = group[0];
	StringInfoData sql;
	StringInfoData params;
	GroupHashArg harg;
	bool		ok;
	int			c,
				j,
				r;

	initStringInfo(&sql);
	appendStringInfoString(&sql, "SELECT x.__pkey__");
	for (c = 0; c < base->ncols; c++)
		appendStringInfo(&sql, ", " COLUMN_HASH_SQL " AS h%d", base->colnames[c], c);
	appendStringInfoString(&sql, ", (0::bigint");
	for (c = 0; c < base->ncols; c++)
		appendStringInfo(&sql, " + coalesce(pg_column_size(t.%s), 0)::bigint", base->colnames[c]);
	appendStringInfo(&sql,
					 ") AS est_bytes FROM jsonb_to_recordset($1::jsonb) AS x(k jsonb, __pkey__ text) "
					 KEY_FROM_PARAM " JOIN %s t ON %s",
					 base->pkcols_text, base->qualname, base->pkjoin);

	initStringInfo(&params);
	appendStringInfoChar(&params, '[');
	for (j = 0; j < n; j++)
	{
		if (j > 0)
			appendStringInfoChar(&params, ',');
		append_key_object(&params, group[j], false);
	}
	appendStringInfoChar(&params, ']');

	memset(&harg, 0, sizeof(harg));
	harg.sql = sql.data;
	harg.json_param = params.data;
	harg.ncols = base->ncols;
	harg.relid = base->relid;
	harg.destcxt = destcxt;

	ok = run_in_subxact(group_hash_cb, &harg, errmsg);
	if (ok)
	{
		for (j = 0; j < n; j++)
			group[j]->local = LOCAL_MISSING;
		for (r = 0; r < harg.nrows; r++)
		{
			CHECK_FOR_INTERRUPTS();
			for (j = 0; j < n; j++)
			{
				RepairEntry *e = group[j];

				if (strcmp(e->pkey, harg.pkey[r]) != 0)
					continue;

				/*
				 * The key came from a replica identity index, so a second row
				 * means the table's key is no longer what it was recorded
				 * under.  Comparing either row could settle the entry
				 * wrongly.
				 */
				if (e->local == LOCAL_FOUND)
					e->local = LOCAL_MULTI;
				else if (e->local == LOCAL_MISSING)
				{
					e->local = LOCAL_FOUND;
					e->local_hash = harg.hash[r];
					e->est_bytes = harg.est_bytes[r];
				}
				break;
			}
		}
	}
	pfree(sql.data);
	pfree(params.data);
	return ok;
}

/*
 * The elements of a text[] as C strings in the current memory context.  A
 * NULL element is an error unless nulls_ok, and comes back as NULL.
 */
static char **
text_array_cstrings(Datum array, bool nulls_ok, int *n)
{
	Datum	   *elems;
	bool	   *nulls = NULL;
	char	  **out;
	int			i;

	deconstruct_array(DatumGetArrayTypeP(array), TEXTOID, -1, false,
					  TYPALIGN_INT, &elems, nulls_ok ? &nulls : NULL, n);
	out = palloc(*n * sizeof(char *));
	for (i = 0; i < *n; i++)
		out[i] = (nulls && nulls[i]) ? NULL : TextDatumGetCString(elems[i]);
	return out;
}

/*
 * The equality operator of a key column's type, schema-qualified, as
 * OPERATOR(schema.name), or NULL if the type has none.  The queries run with
 * only pg_catalog on the search_path (TOAST_SEARCH_PATH), where a plain =
 * would not find the operator of a type defined elsewhere, such as citext,
 * and would compare the values as some other type.  This is the operator of
 * the type's default btree operator class, which a plain = finds on an
 * ordinary search_path.
 *
 * *operand_cast is set to a cast, such as "::public.citext", that both
 * operands must carry, or to "".  An operator outside pg_catalog lives in a
 * schema other roles may be able to create in, and OPERATOR(schema.name)
 * still takes an exact match on the operands' own types first: for a key of
 * a domain over citext, a "=" someone created on the domain would be called
 * instead of citext's.  Casting both operands to the operator's declared
 * type leaves only the operator that type's owner created.  An operator
 * class takes its column types as they are stored, so the cast is a
 * relabeling and the column's index is still used.
 */
static char *
key_eq_operator(Oid typid, char **operand_cast)
{
	TypeCacheEntry *tce = lookup_type_cache(typid, TYPECACHE_EQ_OPR);
	HeapTuple	tp;
	Form_pg_operator op;
	char	   *result;

	*operand_cast = "";
	if (!OidIsValid(tce->eq_opr))
		return NULL;
	tp = SearchSysCache1(OPEROID, ObjectIdGetDatum(tce->eq_opr));
	if (!HeapTupleIsValid(tp))
		elog(ERROR, "cache lookup failed for operator %u", tce->eq_opr);
	op = (Form_pg_operator) GETSTRUCT(tp);
	if (op->oprnamespace != PG_CATALOG_NAMESPACE)
	{
		Oid			argtype = op->oprleft;

		/* a polymorphic operator takes the domain's base type as it is */
		if (argtype != op->oprright || get_typtype(argtype) == TYPTYPE_PSEUDO)
			argtype = getBaseType(typid);
		if (argtype != typid)
			*operand_cast = psprintf("::%s", format_type_be_qualified(argtype));
	}
	result = psprintf("OPERATOR(%s.%s)",
					  quote_identifier(get_namespace_name(op->oprnamespace)),
					  NameStr(op->oprname));
	ReleaseSysCache(tp);
	return result;
}

/*
 * Build e's key clauses from the key columns of one row of the
 * read_entries() query (KEY_COLUMNS_LATERAL).  They are left NULL, so
 * entry_usable() is false, if the key no longer fully matches live columns
 * or a key type has no equality operator.
 *
 * where_clause matches the row by literal values, for queries built per
 * row.  pkjoin and pkcols_text are for the batched queries, which match
 * rows against the key objects of $1 read as k(pkcols_text)
 * (KEY_FROM_PARAM).  Key values are stored as JSON strings
 * (build_pkey_json()), and jsonb_to_record() hands a JSON string to a jsonb
 * column, or a domain over jsonb, as a jsonb string, not the value it
 * spells, so every key column is read as text and pkjoin casts it to its
 * own type.
 */
static void
entry_key_clauses(RepairEntry *e, HeapTuple row, TupleDesc desc)
{
	bool		isnull;
	Datum		d = SPI_getbinval(row, desc, EC_KEY_NAMES, &isnull);
	char	  **names;
	char	  **types;
	char	  **vals;
	Datum	   *typids;
	StringInfoData where;
	StringInfoData join;
	StringInfoData cols;
	int			n,
				i;

	if (isnull)
		return;
	names = text_array_cstrings(d, false, &n);
	types = text_array_cstrings(SPI_getbinval(row, desc, EC_KEY_TYPES, &isnull),
								false, &n);
	vals = text_array_cstrings(SPI_getbinval(row, desc, EC_KEY_VALUES, &isnull),
							   true, &n);
	deconstruct_array(DatumGetArrayTypeP(SPI_getbinval(row, desc, EC_KEY_TYPIDS, &isnull)),
					  OIDOID, sizeof(Oid), true, TYPALIGN_INT, &typids, NULL, &n);

	initStringInfo(&where);
	initStringInfo(&join);
	initStringInfo(&cols);
	for (i = 0; i < n; i++)
	{
		const char *col = quote_identifier(names[i]);
		char	   *cast;
		char	   *eq = key_eq_operator(DatumGetObjectId(typids[i]), &cast);

		if (eq == NULL)
			return;
		if (i > 0)
		{
			appendStringInfoString(&where, " AND ");
			appendStringInfoString(&join, " AND ");
			appendStringInfoChar(&cols, ',');
		}
		appendStringInfo(&where, "%s%s %s %s::%s%s", col, cast, eq,
						 vals[i] ? quote_literal_cstr(vals[i]) : "NULL", types[i],
						 cast);
		appendStringInfo(&join, "t.%s%s %s k.%s::%s%s", col, cast, eq, col,
						 types[i], cast);
		appendStringInfo(&cols, "%s text", col);
	}
	e->where_clause = where.data;
	e->pkjoin = join.data;
	e->pkcols_text = cols.data;
}

/*
 * Fill e from one row of the read_entries() query.  The current context is
 * the caller's destcxt, where SPI_getvalue() and TextDatumGetCString()
 * allocate, so the strings outlive SPI_finish() without a copy.
 */
static void
entry_from_tuple(RepairEntry *e, HeapTuple row, TupleDesc desc)
{
	bool		isnull;
	Datum		d;
	Datum	   *elems;
	int			n,
				i;

	e->relid = DatumGetObjectId(SPI_getbinval(row, desc, EC_RELID, &isnull));
	e->pkey = SPI_getvalue(row, desc, EC_PKEY);
	e->subid = DatumGetObjectId(SPI_getbinval(row, desc, EC_WINNER_SUBID, &isnull));
	e->sub_enabled = DatumGetBool(SPI_getbinval(row, desc, EC_SUB_ENABLED, &isnull));
	d = SPI_getbinval(row, desc, EC_WINNER_NODE_ID, &isnull);
	e->winner_node_id = isnull ? InvalidOid : DatumGetObjectId(d);
	e->table_exists = DatumGetBool(SPI_getbinval(row, desc, EC_TABLE_EXISTS, &isnull));
	e->qualname = SPI_getvalue(row, desc, EC_QUALNAME);

	/* names, types and attnums are NULL together or all of length n */
	d = SPI_getbinval(row, desc, EC_COLNAMES, &isnull);
	if (!isnull)
	{
		e->colnames = text_array_cstrings(d, false, &n);
		e->ncols = n;
		e->coltypes = text_array_cstrings(SPI_getbinval(row, desc, EC_COLTYPES, &isnull),
										  false, &n);
		deconstruct_array(DatumGetArrayTypeP(SPI_getbinval(row, desc, EC_ATTNUMS, &isnull)),
						  INT2OID, 2, true, TYPALIGN_SHORT, &elems, NULL, &n);
		e->attnums = palloc(n * sizeof(int16));
		for (i = 0; i < n; i++)
			e->attnums[i] = DatumGetInt16(elems[i]);
	}
	e->detect_count = DatumGetInt32(SPI_getbinval(row, desc, EC_DETECT_COUNT, &isnull));
	/* fetch_wave() runs without SPI, so the entry carries the clauses. */
	entry_key_clauses(e, row, desc);
	e->orig_state = SPI_getvalue(row, desc, EC_STATE);

	/*
	 * Aligned with colnames: both list the live suspect columns in attnum
	 * order.  An entry without pointers (written before they were recorded,
	 * or by hand) gets all NULLs.
	 */
	if (e->ncols > 0)
	{
		e->stored_ptr = palloc0(e->ncols * sizeof(char *));
		d = SPI_getbinval(row, desc, EC_STORED_PTRS, &isnull);
		if (!isnull)
		{
			char	  **ptrs = text_array_cstrings(d, true, &n);

			for (i = 0; i < n && i < e->ncols; i++)
				e->stored_ptr[i] = ptrs[i];
		}
	}
	e->first_winner_ts = SPI_getvalue(row, desc, EC_FIRST_WINNER_TS);
	e->winner_node_name = SPI_getvalue(row, desc, EC_WINNER_NODE_NAME);
	e->sub_exists = DatumGetBool(SPI_getbinval(row, desc, EC_SUB_EXISTS, &isnull));
	e->reason = SPI_getvalue(row, desc, EC_REASON);
	d = SPI_getbinval(row, desc, EC_DETECTED_AT, &isnull);
	e->detected_at = isnull ? 0 : DatumGetTimestampTz(d);
}

/*
 * Hash the local rows of the entries that need it, in batches: entries are
 * grouped by table and suspect-column set (normally one group per table, but
 * two entries for the same table can carry different sets if different
 * UPDATEs left different TOAST columns unchanged), and each group's rows are
 * read with one query.  An entry outside any group
 * (table gone, no usable key, or no suspect columns left) stays
 * LOCAL_UNREAD.
 */
static void
hash_entries(RepairEntry *entries, int n, bool for_repair,
			 MemoryContext destcxt)
{
	bool	   *grouped = palloc0(n * sizeof(bool));
	RepairEntry **group = palloc(n * sizeof(RepairEntry *));
	int			i,
				j;

	for (i = 0; i < n; i++)
	{
		int			ngroup = 0;
		char	   *errmsg;
		bool		multi;

		if (grouped[i])
			continue;
		grouped[i] = true;
		if (!entry_needs_hash(&entries[i], for_repair))
			continue;

		group[ngroup++] = &entries[i];
		for (j = i + 1; j < n; j++)
		{
			if (!grouped[j] && entry_needs_hash(&entries[j], for_repair) &&
				same_shape(&entries[i], &entries[j]))
			{
				grouped[j] = true;
				group[ngroup++] = &entries[j];
			}
		}

		if (hash_local_rows(group, ngroup, destcxt, &errmsg))
			continue;

		/*
		 * One row can fail the whole group's query, say with a stored value
		 * its type's output function rejects.  Read each row alone then, so
		 * only that row's entry fails.  Not after a lock timeout, which is
		 * about the table: each row would wait it out again.
		 */
		multi = ngroup > 1 && last_subxact_errcode != ERRCODE_LOCK_NOT_AVAILABLE;
		for (j = 0; j < ngroup; j++)
		{
			if (multi &&
				hash_local_rows(&group[j], 1, destcxt, &errmsg))
				continue;
			group[j]->local = LOCAL_ERROR;
			group[j]->local_err = MemoryContextStrdup(destcxt, errmsg);
		}
	}
	pfree(grouped);
	pfree(group);
}

/*
 * Read up to max_rows entries into an array allocated in destcxt, and hash
 * each entry's local row the same way the winner will hash its own, so the
 * winner fetch can compare hashes there and send back only the columns that
 * differ.  Must be called inside a transaction with SPI connected.
 *
 * With for_repair (the worker), entries in state 'suspect' and 'confirmed'
 * are read, those the pass can act on first: a dropped table or winner
 * subscription (deleted) or an enabled winner subscription.  The rest only
 * wait, so they fill what is left of a batch and cannot keep the worker from
 * the entries behind them.  A batch of only waiting entries settles nothing,
 * and the worker then sleeps rather than reading them again at once.
 * verify() reads only 'suspect' entries.  Either way, entries never tried
 * come first, and suspect_mark() stamps verified_at on every attempt, so an
 * entry that keeps failing goes to the back of the queue and cannot hold up
 * the rest.
 *
 * The SQL fragments (qualified table name, column lists, WHERE clause and
 * join from the key) are built here from the local catalog.  Spock requires
 * the same table and column names on every node, so they are valid on the
 * winner too.  format('%I', ...) errors on a NULL argument, and
 * c.relname/n.nspname are NULL once the table is gone, so qualname is
 * wrapped in a CASE.  The column lists exclude dropped columns, whose
 * pg_attribute row survives with a placeholder name that a query naming it
 * would fail to find; they all use the same filter so they stay aligned.
 * The key fragments are all or nothing (KEY_COLUMNS_LATERAL).
 */
RepairEntry *
read_entries(int max_rows, bool for_repair, MemoryContext destcxt,
			 int *nentries)
{
	RepairEntry *entries = NULL;
	Oid			argtypes[3] = {INT4OID, TEXTOID, BOOLOID};
	Datum		argvals[3];
	int			ret;
	uint64		r;
	int			nestlevel;

	*nentries = 0;

	/*
	 * format_type() leaves a type unqualified when it is visible on the
	 * search_path, and the types it names are used on the winner, whose
	 * session has another one.  With only pg_catalog on the path, every
	 * other type comes out schema-qualified.  The callers already run under
	 * TOAST_SEARCH_PATH; it is set here too because the type names this
	 * returns go to the winner.
	 */
	nestlevel = NewGUCNestLevel();
	(void) set_config_option("search_path", TOAST_SEARCH_PATH,
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);

	argvals[0] = Int32GetDatum(max_rows);
	argvals[1] = CStringGetTextDatum(for_repair ? "confirmed" : "suspect");
	argvals[2] = BoolGetDatum(for_repair);
	ret = SPI_execute_with_args(
								"SELECT s.relid, s.pkey::text, s.winner_subid, "
								"       coalesce(sub.sub_enabled, false) AS sub_enabled, "
								"       sub.sub_origin AS winner_node_id, "
								"       c.oid IS NOT NULL AS table_exists, "
								"       CASE WHEN c.oid IS NOT NULL "
								"            THEN format('%I.%I', n.nspname, c.relname) END AS qualname, "
								"       CASE WHEN kc.ok THEN kc.names END AS key_names, "
								"       cols.names, cols.types, cols.attnums, "
								"       s.detect_count, "
								"       CASE WHEN kc.ok THEN kc.types END AS key_types, "
								"       CASE WHEN kc.ok THEN kc.vals END AS key_values, "
								"       CASE WHEN kc.ok THEN kc.typids END AS key_typids, "
								"       s.state, "
								"       (SELECT array_agg(s.toast_ptrs[i] ORDER BY s.attnums[i]) "
								"          FROM generate_subscripts(s.attnums, 1) i "
								"          JOIN pg_attribute a ON a.attrelid = s.relid "
								"           AND a.attnum = s.attnums[i] AND NOT a.attisdropped) AS stored_ptrs, "
								"       to_json(coalesce(s.first_winner_ts, s.winner_ts)) #>> '{}' "
								"         AS first_winner_ts, "
								"       wn.node_name AS winner_node_name, "
								"       sub.sub_id IS NOT NULL AS sub_exists, "
								"       s.reason, "
								"       s.detected_at "
								"  FROM spock.toast_suspect s "
								"  LEFT JOIN pg_class c ON c.oid = s.relid "
								"  LEFT JOIN pg_namespace n ON n.oid = c.relnamespace "
								KEY_COLUMNS_LATERAL
								"  LEFT JOIN LATERAL ( "
								"    SELECT array_agg(quote_ident(a.attname) ORDER BY a.attnum) AS names, "
								"           array_agg(format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum) AS types, "
								"           array_agg(a.attnum ORDER BY a.attnum) AS attnums "
								"      FROM pg_attribute a WHERE a.attrelid = s.relid "
								"       AND a.attnum = ANY (s.attnums) AND NOT a.attisdropped) cols ON true "
								"  LEFT JOIN spock.subscription sub ON sub.sub_id = s.winner_subid "
								"  LEFT JOIN spock.node wn ON wn.node_id = sub.sub_origin "
								" WHERE s.state IN ('suspect', $2) "
								" ORDER BY ($3 AND (c.oid IS NULL OR coalesce(sub.sub_enabled, false) "
								"           OR (s.winner_subid <> 0 AND sub.sub_id IS NULL))) DESC, "
								"          s.verified_at NULLS FIRST, s.detected_at "
								" LIMIT $1",
								3, argtypes, argvals, NULL, true, 0);
	AtEOXact_GUC(true, nestlevel);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute_with_args failed reading spock.toast_suspect: %d", ret);

	if (SPI_processed > 0)
	{
		MemoryContext oldcxt = MemoryContextSwitchTo(destcxt);

		entries = palloc0(SPI_processed * sizeof(RepairEntry));
		for (r = 0; r < SPI_processed; r++)
			entry_from_tuple(&entries[r], SPI_tuptable->vals[r],
							 SPI_tuptable->tupdesc);
		*nentries = SPI_processed;
		MemoryContextSwitchTo(oldcxt);
		hash_entries(entries, *nentries, for_repair, destcxt);
	}

	return entries;
}
