/*-------------------------------------------------------------------------
 *
 * spock_change_log.c
 *      JSON change-log output controlled by spock.apply_change_logging GUC.
 *
 *      Called from the apply worker after each successful DML or DDL has
 *      been applied locally.  Emits a single JSON object per change at
 *      LOG level so the operator can correlate replayed changes with
 *      origin / commit_ts.
 *
 * Copyright (c) 2022-2025, pgEdge, Inc.
 * Copyright (c) 2020-2022, OSCG-Partners
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/relation.h"
#include "lib/stringinfo.h"
#include "nodes/bitmapset.h"
#include "replication/origin.h"
#include "utils/builtins.h"
#include "utils/json.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/timestamp.h"

#include "spock.h"
#include "spock_proto_native.h"
#include "spock_relcache.h"
#include "spock_change_log.h"

/*
 * Append a Datum as a JSON value.  Always emits text-quoted form (after
 * type-output conversion); NULL becomes JSON null.  Quoting every value
 * keeps the output type-stable across PostgreSQL versions and avoids
 * having to track per-type numeric vs string distinctions.
 */
static void
append_json_value(StringInfo buf, Oid typid, Datum value, bool isnull)
{
	Oid			typoutput;
	bool		typisvarlena;
	char	   *str;

	if (isnull)
	{
		appendStringInfoString(buf, "null");
		return;
	}

	getTypeOutputInfo(typid, &typoutput, &typisvarlena);
	str = OidOutputFunctionCall(typoutput, value);
	escape_json(buf, str);
	pfree(str);
}

/*
 * Append a row as a JSON object.  If pk_only is true, only the columns
 * that participate in the relation's primary key are emitted.
 */
static void
append_row_json(StringInfo buf, SpockRelation *rel,
				SpockTupleData *tup, bool pk_only)
{
	Bitmapset  *pk_atts = NULL;
	int			i;
	bool		first = true;

	appendStringInfoChar(buf, '{');

	/*
	 * Build the set of local attnums that are part of the primary key
	 * index.  We deliberately use NoLock here - the apply worker
	 * already holds a row-level lock on the user relation, and we are
	 * only inspecting the in-memory index metadata.
	 */
	if (pk_only && OidIsValid(rel->idxoid))
	{
		Relation	idx;

		idx = relation_open(rel->idxoid, NoLock);
		if (idx->rd_index != NULL)
		{
			int			natts = idx->rd_index->indnatts;
			int			j;

			for (j = 0; j < natts; j++)
			{
				AttrNumber	a = idx->rd_index->indkey.values[j];

				if (a > 0)
					pk_atts = bms_add_member(pk_atts, a);
			}
		}
		relation_close(idx, NoLock);
	}

	for (i = 0; i < rel->natts; i++)
	{
		AttrNumber	local_attno;

		/*
		 * SpockTupleData is indexed by remote attnum (0..natts-1).
		 * rel->attmap (when set) maps remote -> local 0-based.  When
		 * attmap is NULL the columns are 1:1 and the local attnum is
		 * simply i + 1.
		 */
		local_attno = (rel->attmap != NULL) ? rel->attmap[i] + 1 : i + 1;

		if (pk_only)
		{
			if (pk_atts == NULL || !bms_is_member(local_attno, pk_atts))
				continue;
		}

		if (!first)
			appendStringInfoChar(buf, ',');
		first = false;

		escape_json(buf, rel->attnames[i]);
		appendStringInfoChar(buf, ':');
		append_json_value(buf, rel->attrtypes[i],
						  tup->values[i], tup->nulls[i]);
	}

	if (pk_atts != NULL)
		bms_free(pk_atts);

	appendStringInfoChar(buf, '}');
}

/*
 * Append the common (action, schema, table, origin, commit_ts) header
 * fields used by both DML and DDL records.  origin_name may be NULL.
 */
static void
append_change_log_header(StringInfo buf, const char *action,
						 const char *nspname, const char *relname,
						 const char *origin_name)
{
	appendStringInfoString(buf, "\"action\":");
	escape_json(buf, action);

	if (nspname != NULL)
	{
		appendStringInfoString(buf, ",\"schema\":");
		escape_json(buf, nspname);
	}
	if (relname != NULL)
	{
		appendStringInfoString(buf, ",\"table\":");
		escape_json(buf, relname);
	}
	if (origin_name != NULL)
	{
		appendStringInfoString(buf, ",\"origin\":");
		escape_json(buf, origin_name);
	}
	if (replorigin_session_origin_timestamp != 0)
	{
		appendStringInfo(buf, ",\"commit_ts\":\"%s\"",
						 timestamptz_to_str(replorigin_session_origin_timestamp));
	}
}

/*
 * Log a DML change.  Called by the apply worker AFTER a successful
 * INSERT/UPDATE/DELETE.  No-op when spock.apply_change_logging = 'none'.
 *
 *   action  - "INSERT", "UPDATE", or "DELETE"
 *   rel     - target SpockRelation (must not be NULL)
 *   oldtup  - old-row tuple data (UPDATE/DELETE), may be NULL
 *   newtup  - new-row tuple data (INSERT/UPDATE), may be NULL
 *   origin_name - origin node name, may be NULL
 */
void
spock_log_apply_change(const char *action,
					   SpockRelation *rel,
					   SpockTupleData *oldtup,
					   SpockTupleData *newtup,
					   const char *origin_name)
{
	StringInfoData buf;
	SpockTupleData *pk_src;

	if (spock_apply_change_logging == SPOCK_APPLY_CHANGE_LOG_NONE)
		return;
	if (rel == NULL)
		return;

	initStringInfo(&buf);
	appendStringInfoChar(&buf, '{');

	append_change_log_header(&buf, action, rel->nspname, rel->relname,
							 origin_name);

	/* primary key - take it from the new tuple for INSERT/UPDATE, else old */
	pk_src = (newtup != NULL) ? newtup : oldtup;
	if (pk_src != NULL)
	{
		appendStringInfoString(&buf, ",\"pk\":");
		append_row_json(&buf, rel, pk_src, true /* pk_only */);
	}

	if (spock_apply_change_logging == SPOCK_APPLY_CHANGE_LOG_VERBOSE)
	{
		if (oldtup != NULL)
		{
			appendStringInfoString(&buf, ",\"old\":");
			append_row_json(&buf, rel, oldtup, false);
		}
		if (newtup != NULL)
		{
			appendStringInfoString(&buf, ",\"new\":");
			append_row_json(&buf, rel, newtup, false);
		}
	}

	appendStringInfoChar(&buf, '}');

	ereport(LOG,
			(errmsg_internal("spock apply change: %s", buf.data)));

	pfree(buf.data);
}

/*
 * Log a DDL change.  Called by the apply worker after extracting the SQL
 * text from a queued DDL message.  No-op when apply_change_logging = 'none'
 * (DDL is logged in both 'key_only' and 'verbose' modes, per the spec).
 */
void
spock_log_apply_ddl(const char *sql, const char *origin_name)
{
	StringInfoData buf;

	if (spock_apply_change_logging == SPOCK_APPLY_CHANGE_LOG_NONE)
		return;
	if (sql == NULL)
		return;

	initStringInfo(&buf);
	appendStringInfoChar(&buf, '{');

	append_change_log_header(&buf, "DDL", NULL, NULL, origin_name);

	appendStringInfoString(&buf, ",\"sql\":");
	escape_json(&buf, sql);

	appendStringInfoChar(&buf, '}');

	ereport(LOG,
			(errmsg_internal("spock apply change: %s", buf.data)));

	pfree(buf.data);
}
