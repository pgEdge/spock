/*-------------------------------------------------------------------------
 *
 * spock_rpc.c
 *				Remote calls
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "lib/stringinfo.h"

#include "nodes/makefuncs.h"

#include "catalog/pg_type.h"

#include "storage/lock.h"

#include "utils/rel.h"
#include "utils/builtins.h"

#include "spock_relcache.h"
#include "spock_repset.h"
#include "spock_rpc.h"
#include "spock.h"
#include "spock_compat.h"

#define atooid(x)  ((Oid) strtoul((x), NULL, 10))

/*
 * Build a comma-separated list of SQL literals from a List of C strings.
 *
 * Used to construct ARRAY[...] payloads for IN/ANY/ALL clauses.  Each
 * element is run through PQescapeLiteral so the publisher's SQL parser
 * sees a properly-quoted literal.  An empty input list produces an empty
 * buffer; callers wanting a syntactically-valid empty array must wrap the
 * result, e.g. "ARRAY[%s]::text[]".
 *
 * PQescapeLiteral allocates with libpq's allocator, not palloc; the
 * returned buffer is freed with PQfreemem after we copy it into the
 * StringInfo.  Without this we'd leak ~30 bytes per element into the
 * backend's libc heap, which adds up across long-lived backends that
 * sync many subscriptions.
 */
static void
append_string_list_as_literals(StringInfo buf, PGconn *conn, List *items)
{
	ListCell   *lc;
	bool		first = true;

	foreach(lc, items)
	{
		const char *s = (const char *) lfirst(lc);
		char	   *escaped;

		if (first)
			first = false;
		else
			appendStringInfoChar(buf, ',');
		escaped = PQescapeLiteral(conn, s, strlen(s));
		appendStringInfoString(buf, escaped);
		PQfreemem(escaped);
	}
}

/*
 * Fetch list of tables that are grouped in specified replication sets.
 *
 * skip_schemas, if non-NIL, is applied as a publisher-side filter so the
 * caller doesn't have to wade through rows it would discard.  Passing NIL
 * means "return everything in the named repsets" — backward-compatible with
 * the original two-argument shape.
 *
 * Rows are returned sorted by (nspname, relname).  This is a documented
 * invariant the structure-sync caller relies on for O(1) schema-dedup via
 * a tail compare; do not drop the ORDER BY without auditing callers.
 */
List *
spock_get_remote_repset_tables(PGconn *conn, List *replication_sets,
							   List *skip_schemas)
{
	PGresult   *res;
	int			i;
	List	   *tables = NIL;
	StringInfoData query;
	StringInfoData repsetarr;
	StringInfoData skiparr;

	initStringInfo(&repsetarr);
	append_string_list_as_literals(&repsetarr, conn, replication_sets);

	initStringInfo(&skiparr);
	append_string_list_as_literals(&skiparr, conn, skip_schemas);

	initStringInfo(&query);
	appendStringInfo(&query,
					 "SELECT i.relid, i.nspname, i.relname, i.att_list,"
					 "       i.has_row_filter, i.relkind, i.relispartition"
					 "  FROM (SELECT DISTINCT relid FROM spock.tables WHERE set_name = ANY(ARRAY[%s])) t,"
					 "       LATERAL spock.repset_show_table(t.relid, ARRAY[%s]) i"
					 " WHERE i.nspname <> ALL(ARRAY[%s]::text[])"
					 " ORDER BY i.nspname, i.relname",
					 repsetarr.data, repsetarr.data, skiparr.data);

	res = PQexec(conn, query.data);
	/* TODO: better error message? */
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		elog(ERROR, "could not get table list: %s", PQresultErrorMessage(res));

	for (i = 0; i < PQntuples(res); i++)
	{
		SpockRemoteRel *remoterel = palloc0(sizeof(SpockRemoteRel));

		remoterel->relid = atooid(PQgetvalue(res, i, 0));
		remoterel->nspname = pstrdup(PQgetvalue(res, i, 1));
		remoterel->relname = pstrdup(PQgetvalue(res, i, 2));
		if (!parsePGArray(PQgetvalue(res, i, 3), &remoterel->attnames,
						  &remoterel->natts))
			elog(ERROR, "could not parse column list for table");
		remoterel->hasRowFilter = (strcmp(PQgetvalue(res, i, 4), "t") == 0);
		remoterel->relkind = PQgetvalue(res, i, 5)[0];
		remoterel->ispartition = (strcmp(PQgetvalue(res, i, 6), "t") == 0);

		tables = lappend(tables, remoterel);
	}

	PQclear(res);

	return tables;
}

/*
 * Like above but for one table.
 */
SpockRemoteRel *
spock_get_remote_repset_table(PGconn *conn, RangeVar *rv,
							  List *replication_sets)
{
	SpockRemoteRel *remoterel = palloc0(sizeof(SpockRemoteRel));
	PGresult   *res;
	ListCell   *lc;
	bool		first = true;
	StringInfoData query;
	StringInfoData repsetarr;
	StringInfoData relname;

	initStringInfo(&relname);
	appendStringInfo(&relname, "%s.%s",
					 PQescapeIdentifier(conn, rv->schemaname, strlen(rv->schemaname)),
					 PQescapeIdentifier(conn, rv->relname, strlen(rv->relname)));

	initStringInfo(&repsetarr);
	foreach(lc, replication_sets)
	{
		char	   *repset_name = lfirst(lc);

		if (first)
			first = false;
		else
			appendStringInfoChar(&repsetarr, ',');

		appendStringInfo(&repsetarr, "%s",
						 PQescapeLiteral(conn, repset_name, strlen(repset_name)));
	}

	initStringInfo(&query);
	appendStringInfo(&query,
					 "SELECT i.relid, i.nspname, i.relname, i.att_list,"
					 "       i.has_row_filter, i.relkind, i.relispartition"
					 "  FROM spock.repset_show_table(%s::regclass, ARRAY[%s]) i",
					 PQescapeLiteral(conn, relname.data, relname.len),
					 repsetarr.data);

	res = PQexec(conn, query.data);
	/* TODO: better error message? */
	if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1)
		elog(ERROR, "could not get table list: %s", PQresultErrorMessage(res));

	remoterel->relid = atooid(PQgetvalue(res, 0, 0));
	remoterel->nspname = pstrdup(PQgetvalue(res, 0, 1));
	remoterel->relname = pstrdup(PQgetvalue(res, 0, 2));
	if (!parsePGArray(PQgetvalue(res, 0, 3), &remoterel->attnames,
					  &remoterel->natts))
		elog(ERROR, "could not parse column list for table");
	remoterel->hasRowFilter = (strcmp(PQgetvalue(res, 0, 4), "t") == 0);
	remoterel->relkind = PQgetvalue(res, 0, 5)[0];
	remoterel->ispartition = (strcmp(PQgetvalue(res, 0, 6), "t") == 0);

	PQclear(res);

	return remoterel;
}


/*
 * Is the remote slot active?.
 */
bool
spock_remote_slot_active(PGconn *conn, const char *slot_name)
{
	PGresult   *res;
	const char *values[1];
	Oid			types[1] = {TEXTOID};
	bool		ret;

	values[0] = slot_name;

	res = PQexecParams(conn,
					   "SELECT plugin, active "
					   "FROM pg_catalog.pg_replication_slots "
					   "WHERE slot_name = $1",
					   1, types, values, NULL, NULL, 0);

	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		ereport(ERROR,
				(errmsg("getting remote slot info failed"),
				 errdetail("SELECT FROM pg_catalog.pg_replication_slots failed with: %s",
						   PQerrorMessage(conn))));
	}

	/* Slot not found return false */
	if (PQntuples(res) == 0)
	{
		PQclear(res);
		return false;
	}

	/* Slot found, validate that it's spock slot */
	if (PQgetisnull(res, 0, 0))
		elog(ERROR, "Unexpectedly null field %s", PQfname(res, 0));

	if (strcmp("spock_output", PQgetvalue(res, 0, 0)) != 0 &&
		strcmp("spock", PQgetvalue(res, 0, 0)) != 0)
		ereport(ERROR,
				(errmsg("slot %s is not spock slot", slot_name)));

	ret = (strcmp(PQgetvalue(res, 0, 1), "t") == 0);

	PQclear(res);

	return ret;
}

/*
 * Drops replication slot on remote node that has been used by the local node.
 */
void
spock_drop_remote_slot(PGconn *conn, const char *slot_name)
{
	PGresult   *res;
	const char *values[1];
	Oid			types[1] = {TEXTOID};

	values[0] = slot_name;

	/* Check if the slot exists */
	res = PQexecParams(conn,
					   "SELECT plugin "
					   "FROM pg_catalog.pg_replication_slots "
					   "WHERE slot_name = $1",
					   1, types, values, NULL, NULL, 0);

	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		ereport(ERROR,
				(errmsg("getting remote slot info failed"),
				 errdetail("SELECT FROM pg_catalog.pg_replication_slots failed with: %s",
						   PQerrorMessage(conn))));
	}

	/* Slot not found return false */
	if (PQntuples(res) == 0)
	{
		PQclear(res);
		return;
	}

	/* Slot found, validate that it's spock slot */
	if (PQgetisnull(res, 0, 0))
		elog(ERROR, "Unexpectedly null field %s", PQfname(res, 0));

	if (strcmp("spock_output", PQgetvalue(res, 0, 0)) != 0 &&
		strcmp("spock", PQgetvalue(res, 0, 0)) != 0)
		ereport(ERROR,
				(errmsg("slot %s is not spock slot", slot_name)));

	PQclear(res);

	res = PQexecParams(conn, "SELECT pg_drop_replication_slot($1)",
					   1, types, values, NULL, NULL, 0);

	/* And finally, drop the slot. */
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
	{
		ereport(ERROR,
				(errmsg("remote slot drop failed"),
				 errdetail("SELECT pg_drop_replication_slot() failed with: %s",
						   PQerrorMessage(conn))));
	}

	PQclear(res);
}

/*
 * Read replication info about remote connection
 */
SpockNode *
spock_remote_node_info(PGconn *conn, char **sysid, char **dbname, char **replication_sets)
{
	SpockNode  *node = (SpockNode *) palloc0(sizeof(SpockNode));
	PGresult   *res;

	res = PQexec(conn, "SELECT * FROM spock.node_info()");
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		elog(ERROR, "could not fetch remote node info: %s\n", PQerrorMessage(conn));

	/* No nodes found? */
	if (PQntuples(res) == 0)
		elog(ERROR, "the remote database is not configured as a spock node.\n");

	if (PQntuples(res) > 1)
		elog(ERROR, "the remote database has multiple nodes configured. That is not supported with current version of spock.\n");

	node->id = atooid(PQgetvalue(res, 0, 0));
	node->name = pstrdup(PQgetvalue(res, 0, 1));
	if (sysid)
		*sysid = pstrdup(PQgetvalue(res, 0, 2));
	if (dbname)
		*dbname = pstrdup(PQgetvalue(res, 0, 3));
	if (replication_sets)
		*replication_sets = pstrdup(PQgetvalue(res, 0, 4));
	if (!PQgetisnull(res, 0, 5))
		node->location = pstrdup(PQgetvalue(res, 0, 5));
	if (!PQgetisnull(res, 0, 6))
		node->country = pstrdup(PQgetvalue(res, 0, 6));
	if (!PQgetisnull(res, 0, 7))
		node->info = DatumGetJsonb(DirectFunctionCall1(jsonb_in,
													   CStringGetDatum(PQgetvalue(res, 0, 7))));

	PQclear(res);
	return node;
}


/*
 * spock_get_repset_excluded_tables
 *		Return relations in the given schemas that are NOT in the replication
 *		set — sibling tables, matviews, views, and foreign tables that would
 *		otherwise ride along on the broad "include schema" rule in the
 *		filter file.
 *
 * Enumerates relkind IN ('r','p','f','m','v') so pg_dump's "include
 * schema S" doesn't silently carry along non-replicated relations of any
 * dump-able kind.
 *
 * Caller must have set the connection's snapshot to the slot's exported
 * snapshot before calling (the structure-sync caller does this via the
 * same origin_conn that fed spock_get_remote_repset_tables).  Empty
 * `schemas` or `repset_tables` is a legitimate input (a subscription
 * being initialised against a publisher that has no replicated tables
 * yet) and short-circuits to an empty result — see fastpath below.
 *
 * Returns a List of palloc'd SpockRemoteRelId pointers in
 * CurrentMemoryContext.
 */
List *
spock_get_repset_excluded_tables(PGconn *conn, List *schemas,
								 List *repset_tables)
{
	PGresult   *res;
	StringInfoData query;
	StringInfoData schemaarr;
	List	   *result = NIL;
	ListCell   *lc;
	bool		first;
	int			i;

	/*
	 * Fastpath when there are no schemas to look in.  With no input
	 * schemas, the answer is trivially NIL — and the release-build SQL
	 * would degenerate to "ANY(ARRAY[])" over pg_class, also returning
	 * nothing, just less informatively.  Defensively short-circuit.
	 *
	 * Note: an empty `repset_tables` is NOT a fastpath here.  It means
	 * "every dump-able relation in `schemas` should be excluded" —
	 * used by the scaffold-mode caller in build_filter_file_repset_driven()
	 * when R is empty but the publisher has user schemas to scaffold.
	 * In that case the NOT EXISTS anti-join below is omitted and the
	 * SELECT returns every relation in `schemas`.
	 */
	if (list_length(schemas) == 0)
		return NIL;

	/* Build the schema-name array literal. */
	initStringInfo(&schemaarr);
	appendStringInfoString(&schemaarr, "ARRAY[");
	first = true;
	foreach(lc, schemas)
	{
		const char *nspname = (const char *) lfirst(lc);
		char	   *escaped;

		if (!first)
			appendStringInfoChar(&schemaarr, ',');
		first = false;

		escaped = PQescapeLiteral(conn, nspname, strlen(nspname));
		appendStringInfoString(&schemaarr, escaped);
		PQfreemem(escaped);
	}
	appendStringInfoString(&schemaarr, "]::text[]");

	/*
	 * Anti-join the dump-able relations in the included schemas against R
	 * inlined as a VALUES set.  Genuinely huge repsets get hash-anti-joined
	 * on the publisher side so the per-table cost stays bounded.
	 *
	 * When repset_tables is empty (scaffold mode), we skip the NOT EXISTS
	 * clause entirely — the SELECT then returns every dump-able relation
	 * in `schemas` because there's nothing to anti-join against.  Callers
	 * use that result to emit "exclude table" lines for every table in
	 * scaffold-mode schemas.
	 */
	initStringInfo(&query);
	appendStringInfo(&query,
		"SELECT n.nspname, c.relname\n"
		"  FROM pg_catalog.pg_class c\n"
		"  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace\n"
		" WHERE n.nspname = ANY(%s)\n"
		"   AND c.relkind IN ('r','p','f','m','v')",
		schemaarr.data);

	if (list_length(repset_tables) > 0)
	{
		appendStringInfoString(&query,
			"\n   AND NOT EXISTS (\n"
			"         SELECT 1 FROM (VALUES ");

		first = true;
		foreach(lc, repset_tables)
		{
			SpockRemoteRel *rel = (SpockRemoteRel *) lfirst(lc);
			char	   *esc_ns;
			char	   *esc_rel;

			if (!first)
				appendStringInfoChar(&query, ',');
			first = false;

			esc_ns = PQescapeLiteral(conn, rel->nspname, strlen(rel->nspname));
			esc_rel = PQescapeLiteral(conn, rel->relname, strlen(rel->relname));
			appendStringInfo(&query, "(%s,%s)", esc_ns, esc_rel);
			PQfreemem(esc_ns);
			PQfreemem(esc_rel);
		}

		appendStringInfoString(&query,
			") AS r(s, t)\n"
			"         WHERE r.s = n.nspname AND r.t = c.relname\n"
			"       )");
	}

	res = PQexec(conn, query.data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		elog(ERROR, "could not enumerate excluded tables: %s",
			 PQresultErrorMessage(res));

	for (i = 0; i < PQntuples(res); i++)
	{
		SpockRemoteRelId *rid = palloc0(sizeof(SpockRemoteRelId));

		rid->nspname = pstrdup(PQgetvalue(res, i, 0));
		rid->relname = pstrdup(PQgetvalue(res, i, 1));
		result = lappend(result, rid);
	}

	PQclear(res);
	return result;
}


/*
 * spock_get_remote_user_schemas
 *		Enumerate non-system, non-spock-internal schemas on the publisher.
 *
 *		Used by build_filter_file_repset_driven() when R is empty (the
 *		operator created the subscription without any tables in the
 *		named repsets).  The result becomes the scaffold-mode S_R: the
 *		caller writes "include schema" lines for these names plus
 *		"exclude table" lines for every relation in them, so pg_dump
 *		emits the publisher's schema scaffold (types, functions,
 *		sequences, ACLs, comments) without any tables.
 *
 *		The publisher-side WHERE clause hard-excludes:
 *		  - System schemas matching `pg_%`
 *		  - `information_schema`
 *		  - `spock`, `lolor`, `snowflake` (the static skip set duplicated
 *		    in src/spock_node.c — kept in sync by inspection)
 *		Plus any per-subscription `skip_schemas` the caller forwards.
 *
 *		Returns a List of palloc'd C strings (nspname) in
 *		CurrentMemoryContext, sorted by nspname for deterministic filter
 *		file output across runs.
 */
List *
spock_get_remote_user_schemas(PGconn *conn, List *skip_schemas)
{
	PGresult   *res;
	int			i;
	List	   *schemas = NIL;
	StringInfoData query;
	StringInfoData skiparr;

	Assert(conn != NULL);

	initStringInfo(&skiparr);
	append_string_list_as_literals(&skiparr, conn, skip_schemas);

	initStringInfo(&query);
	appendStringInfo(&query,
		"SELECT n.nspname\n"
		"  FROM pg_catalog.pg_namespace n\n"
		" WHERE n.nspname NOT LIKE 'pg\\_%%' ESCAPE '\\'\n"
		"   AND n.nspname <> 'information_schema'\n"
		"   AND n.nspname NOT IN ('spock','lolor','snowflake')\n"
		"   AND n.nspname <> ALL(ARRAY[%s]::text[])\n"
		" ORDER BY n.nspname",
		skiparr.data);

	res = PQexec(conn, query.data);
	if (PQresultStatus(res) != PGRES_TUPLES_OK)
		elog(ERROR, "could not enumerate publisher user schemas: %s",
			 PQresultErrorMessage(res));

	for (i = 0; i < PQntuples(res); i++)
		schemas = lappend(schemas, pstrdup(PQgetvalue(res, i, 0)));

	PQclear(res);
	return schemas;
}
