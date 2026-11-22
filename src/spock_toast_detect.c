/*-------------------------------------------------------------------------
 *
 * spock_toast_detect.c
 *		Detection of TOAST column divergence
 *
 * PostgreSQL does not WAL-log a TOAST value an UPDATE left unchanged, so
 * the replicated message carries a marker instead and the apply worker
 * keeps whatever the local row holds.  When the UPDATE came from another
 * origin and won a conflict, the local value may differ from the winner's,
 * and nothing else records that.  spock_toast_suspect_record() writes such
 * rows to spock.toast_suspect.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/commit_ts.h"
#include "access/xact.h"
#include "catalog/namespace.h"
#include "executor/spi.h"
#include "utils/guc.h"
#include "utils/builtins.h"
#include "utils/json.h"
#include "utils/lsyscache.h"

#include "spock.h"
#include "spock_toast_divergence.h"
#include "spock_toast_internal.h"
#include "spock_worker.h"

/* Last: it redefines core macros such as WaitLatch() on some majors. */
#include "spock_compat.h"

/* One cap warning per apply worker per hour. */
#define CAP_WARNING_INTERVAL_USEC	(60L * 60L * USECS_PER_SEC)
static TimestampTz last_cap_warning = 0;

/* Cache suspect_table_at_cap()'s answer for this long per apply worker. */
#define CAP_PROBE_INTERVAL_USEC	(10L * USECS_PER_SEC)
static TimestampTz last_cap_probe = 0;
static bool last_at_cap = false;

/* Plans for the detection hook, prepared once per backend and kept. */
static SPIPlanPtr cap_probe_plan = NULL;
static SPIPlanPtr record_plan = NULL;
static SPIPlanPtr refresh_plan = NULL;

/* Input for suspect_record_cb(), run through run_in_subxact(). */
typedef struct SuspectRecordArg
{
	Oid			relid;
	Relation	rel;			/* the key is rendered from rel and slot */
	TupleTableSlot *slot;
	char	   *pkey;			/* set by suspect_record_cb():
								 * {"attname": "value", ...} */
	const char *attnums;		/* int2[] literal */
	RepOriginId local_origin;
	TimestampTz local_ts;
} SuspectRecordArg;

/*
 * The SET list a repeat detection applies, shared by the insert's
 * ON CONFLICT clause and the refresh at the cap in suspect_record_cb().
 */
#define SUSPECT_REFRESH_SET \
	"attnums = $3::int2[], state = 'suspect', " \
	"winner_subid = $4, winner_origin = $5, winner_ts = $6, " \
	"local_origin = $7, local_ts = $8, " \
	"detect_count = spock.toast_suspect.detect_count + 1, " \
	"detected_at = now(), verified_at = NULL, differing = NULL, last_error = $9"

/*
 * Pin fixed text-output settings for the rest of the current GUC nest
 * level, so a stored key reads back the same whatever the session's own
 * settings.  Returns the level for AtEOXact_GUC().  An error before that
 * call is fine: the (sub)transaction abort unwinds the level.
 */
static int
pin_text_output(void)
{
	int			nestlevel = NewGUCNestLevel();
	int			i;

	for (i = 0; toast_pinned_output[i][0] != NULL; i++)
		(void) set_config_option(toast_pinned_output[i][0],
								 toast_pinned_output[i][1],
								 PGC_USERSET, PGC_S_SESSION,
								 GUC_ACTION_SAVE, true, 0, false);

	return nestlevel;
}

/*
 * {"attname": "value", ...} for the columns of the replica identity index:
 * the primary key, or the index REPLICA IDENTITY USING INDEX names.  Values
 * are in the type's text output form so they can be put back into SQL.
 */
static char *
build_pkey_json(Relation rel, TupleTableSlot *slot)
{
	TupleDesc	desc = RelationGetDescr(rel);
	Bitmapset  *idattrs;
	StringInfoData s;
	int			attno = -1;
	bool		first = true;

	idattrs = RelationGetIndexAttrBitmap(rel, INDEX_ATTR_BITMAP_IDENTITY_KEY);
	if (bms_is_empty(idattrs))
	{
		bms_free(idattrs);
		return NULL;
	}

	initStringInfo(&s);
	appendStringInfoChar(&s, '{');
	while ((attno = bms_next_member(idattrs, attno)) >= 0)
	{
		AttrNumber	attnum = attno + FirstLowInvalidHeapAttributeNumber;
		Form_pg_attribute att = TupleDescAttr(desc, attnum - 1);
		bool		isnull;
		Datum		val;

		val = slot_getattr(slot, attnum, &isnull);

		if (!first)
			appendStringInfoChar(&s, ',');
		first = false;

		escape_json(&s, NameStr(att->attname));
		appendStringInfoChar(&s, ':');
		if (isnull)
			appendStringInfoString(&s, "null");
		else
		{
			Oid			outfunc;
			bool		isvarlena;
			char	   *valstr;

			getTypeOutputInfo(att->atttypid, &outfunc, &isvarlena);
			valstr = OidOutputFunctionCall(outfunc, val);
			escape_json(&s, valstr);
			pfree(valstr);
		}
	}
	appendStringInfoChar(&s, '}');
	bms_free(idattrs);

	return s.data;
}

/*
 * Prepare sql and keep the plan for the rest of the backend's life.  what
 * names the statement in an error.
 */
static SPIPlanPtr
prepare_kept_plan(const char *sql, int nargs, Oid *argtypes, const char *what)
{
	SPIPlanPtr	plan = SPI_prepare(sql, nargs, argtypes);

	if (plan == NULL)
		elog(ERROR, "SPI_prepare failed for %s: %d", what, SPI_result);
	if (SPI_keepplan(plan) != 0)
		elog(ERROR, "SPI_keepplan failed for %s", what);
	return plan;
}

/*
 * Is spock.toast_suspect already holding as many rows as the cap allows?
 *
 * The probe looks for the cap-th row (OFFSET cap - 1 LIMIT 1): that row
 * exists once the table holds at least cap rows, which is when one more
 * INSERT would push it past the cap.  It reads min(rowcount, cap) rows,
 * which is too much to run on every detection: detections happen on
 * routine cross-origin UPDATEs, not rare events, and this runs in the
 * apply hot path.  So the answer is cached for CAP_PROBE_INTERVAL_USEC.
 * The table changes slowly, and the cap is already approximate; caching
 * it just adds one more way it can be overshot, by however many
 * detections land inside one interval.
 */
static bool
suspect_table_at_cap(void)
{
	Datum		offset;
	int			ret;
	TimestampTz now;

	if (spock_toast_divergence_max_suspects <= 0)
		return false;

	now = GetCurrentTimestamp();
	if (last_cap_probe != 0 && now - last_cap_probe < CAP_PROBE_INTERVAL_USEC)
		return last_at_cap;

	if (cap_probe_plan == NULL)
	{
		Oid			argtypes[1] = {INT4OID};

		cap_probe_plan = prepare_kept_plan("SELECT 1 FROM spock.toast_suspect OFFSET $1 LIMIT 1",
										   1, argtypes, "the spock.toast_suspect cap probe");
	}
	offset = Int32GetDatum(spock_toast_divergence_max_suspects - 1);
	ret = SPI_execute_plan(cap_probe_plan, &offset, NULL, true, 1);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute failed probing spock.toast_suspect: %d", ret);

	last_at_cap = (SPI_processed > 0);
	last_cap_probe = now;

	return last_at_cap;
}

/* Render the row key under the pinned text-output settings. */
static char *
pinned_pkey_json(Relation rel, TupleTableSlot *slot)
{
	int			nestlevel = pin_text_output();
	char	   *pkey = build_pkey_json(rel, slot);

	AtEOXact_GUC(true, nestlevel);
	return pkey;
}

/* The apply worker's subscription name, for messages. */
static const char *
apply_sub_name(void)
{
	return MySubscription && MySubscription->name ? MySubscription->name : "apply";
}

/*
 * Whether spock.toast_suspect exists.  The manager updates the extension
 * before it starts apply workers, so it is missing only if that update
 * failed or the table was dropped; then nothing is recorded, with one
 * warning per apply worker instead of a failed subtransaction and a warning
 * for every row.
 */
static bool
suspect_table_exists(void)
{
	static bool warned = false;
	Oid			nsp = get_namespace_oid("spock", true);

	if (OidIsValid(nsp) && OidIsValid(get_relname_relid("toast_suspect", nsp)))
		return true;
	if (!warned)
	{
		ereport(WARNING,
				(errmsg("SPOCK %s: spock.toast_suspect does not exist; TOAST divergence is not recorded",
						apply_sub_name()),
				 errhint("The spock manager updates the extension when it starts; check the log for a failed update.")));
		warned = true;
	}
	return false;
}

/*
 * Rendering the key, the cap probe and the upsert: the parts of the
 * detection hook that run user-defined code (key output functions) or touch
 * the database.
 */
static void
suspect_record_cb(void *arg)
{
	SuspectRecordArg *a = (SuspectRecordArg *) arg;
	Oid			argtypes[9] = {OIDOID, TEXTOID, TEXTOID, OIDOID, OIDOID,
		TIMESTAMPTZOID, OIDOID, TIMESTAMPTZOID, TEXTOID};
	Datum		values[9];
	char		nulls[9];
	Oid			winner_subid = MyApplyWorker->subid;
	char	   *forward_note = NULL;
	int			nestlevel;
	int			ret;

	/*
	 * The key is read back later as SQL, so render it under pinned settings.
	 * Otherwise a date key written as '03/11/2026' under a DMY datestyle
	 * would name another row.
	 */
	a->pkey = pinned_pkey_json(a->rel, a->slot);
	if (a->pkey == NULL)
		elog(ERROR, "could not build the replica identity key of the row");

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed in spock_toast_suspect_record");

	/*
	 * The apply worker keeps the search_path of the last replicated DDL it
	 * ran, so names in the statements below could resolve to objects another
	 * user created.  The kept plans are parsed again when the path changes,
	 * so pin it for every run, not only the first.
	 */
	nestlevel = NewGUCNestLevel();
	(void) set_config_option("search_path", TOAST_SEARCH_PATH,
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0, false);

	/*
	 * A change that reached us through another node names that node's
	 * subscription, but the forwarder applied the same unchanged column and
	 * may hold a stale value itself, so it cannot be the reference.  Spock
	 * does not allow a direct subscription to the originating node while
	 * forwarding is active, so there is no better node to check against:
	 * record the entry with no winner subscription, so it is reported and
	 * never checked against the forwarder.
	 */
	if (MySubscription != NULL &&
		(Oid) replorigin_session_origin != MySubscription->origin->id)
	{
		winner_subid = InvalidOid;
		forward_note = psprintf("change from node %u was forwarded by subscription %s; "
								"it cannot be verified against the forwarding node",
								(Oid) replorigin_session_origin,
								MySubscription->name);
	}

	values[0] = ObjectIdGetDatum(a->relid);
	values[1] = CStringGetTextDatum(a->pkey);
	values[2] = CStringGetTextDatum(a->attnums);
	values[3] = ObjectIdGetDatum(winner_subid);
	values[4] = ObjectIdGetDatum((Oid) replorigin_session_origin);
	values[5] = TimestampTzGetDatum(replorigin_session_origin_timestamp);
	values[6] = ObjectIdGetDatum((Oid) a->local_origin);
	values[7] = TimestampTzGetDatum(a->local_ts);
	values[8] = forward_note ? CStringGetTextDatum(forward_note) : (Datum) 0;
	memset(nulls, ' ', sizeof(nulls));
	if (forward_note == NULL)
		nulls[8] = 'n';

	/*
	 * One row per (relation, key).  A repeat detection replaces the winner
	 * and puts the entry back in 'suspect', whatever state it was in.  This
	 * runs in the apply path, so the statements are planned once per backend
	 * and kept.
	 *
	 * At the cap no row is added, but an entry the row already has is still
	 * refreshed, so it names the newest winner.
	 */

	if (suspect_table_at_cap())
	{
		TimestampTz now = GetCurrentTimestamp();

		if (refresh_plan == NULL)
			refresh_plan = prepare_kept_plan("UPDATE spock.toast_suspect SET " SUSPECT_REFRESH_SET
											 " WHERE relid = $1 AND pkey = $2::jsonb",
											 9, argtypes, "refreshing a TOAST suspect");
		ret = SPI_execute_plan(refresh_plan, values, nulls, false, 0);
		if (ret != SPI_OK_UPDATE)
			elog(ERROR, "SPI_execute_plan failed refreshing a TOAST suspect: %d", ret);

		if (SPI_processed == 0 &&
			(last_cap_warning == 0 ||
			 now - last_cap_warning > CAP_WARNING_INTERVAL_USEC))
		{
			ereport(WARNING,
					(errmsg("spock.toast_suspect has reached the cap of %d rows; not recording more suspects",
							spock_toast_divergence_max_suspects),
					 errhint("Remove entries with spock.toast_divergence_clear(), or raise spock.toast_divergence_max_suspects.")));
			last_cap_warning = now;
		}
		AtEOXact_GUC(true, nestlevel);
		SPI_finish();
		return;
	}

	if (record_plan == NULL)
		record_plan = prepare_kept_plan("INSERT INTO spock.toast_suspect "
										"  (relid, pkey, attnums, state, winner_subid, winner_origin, winner_ts, "
										"   local_origin, local_ts, detected_at, last_error) "
										"VALUES ($1, $2::jsonb, $3::int2[], 'suspect', $4, $5, $6, $7, $8, now(), $9) "
										"ON CONFLICT (relid, pkey) DO UPDATE SET " SUSPECT_REFRESH_SET,
										9, argtypes, "recording a TOAST suspect");
	ret = SPI_execute_plan(record_plan, values, nulls, false, 0);
	if (ret != SPI_OK_INSERT)
		elog(ERROR, "SPI_execute_plan failed recording a TOAST suspect: %d", ret);

	AtEOXact_GUC(true, nestlevel);
	SPI_finish();
}

/*
 * Called from the remote-wins branch of spock_handle_conflict_and_apply(),
 * after slot_modify_data() has built the row that is about to be written.
 *
 * Records the row when every one of these holds:
 *   1. the table is not REPLICA IDENTITY FULL (a FULL table's old tuple
 *      carries every value, so nothing is kept blindly), and it has a
 *      replica identity key here to name the row by.  A table whose copy on
 *      the sender is FULL can have no such key on this node, and its rows
 *      are matched by a full scan; they are not recorded;
 *   2. (the caller found the row: this function runs only then);
 *   3. at least one column arrived unchanged, i.e. an out-of-line TOAST
 *      value the UPDATE did not touch; 'u' on the wire is emitted only
 *      for such a datum, so !changed[] needs no column-type test;
 *   4. (the remote tuple won: the caller is in that branch);
 *   5. the local row's last writer is not the sending origin.  A row last
 *      written by the same origin usually agrees with it on every column,
 *      but not always: in a mesh the sender may have taken the column from
 *      a third node whose change has not reached this node yet, and that
 *      change then loses here to the sender's newer one.  That case is not
 *      recorded;
 *   6. the local row's commit timestamp can still be read, and it was last
 *      written after the subscription was created (see below).
 *
 * Nothing is recorded with track_commit_timestamp off.
 *
 * The entry is written inside the apply transaction on purpose: an UPDATE
 * that does not commit created no divergence and its suspect must go too.
 */
void
spock_toast_suspect_record(SpockRelation *rel, TupleTableSlot *newslot,
						   SpockTupleData *newtup, bool local_origin_found,
						   RepOriginId local_origin, TimestampTz local_ts)
{
	StringInfoData attnums;
	int			i;
	bool		any = false;
	SuspectRecordArg arg;
	char	   *record_err;

	if (!spock_toast_divergence_detection)
		return;

	/*
	 * Without commit timestamps condition 5 cannot be decided, and the row
	 * cannot be compared with the winner later, so there is nothing useful
	 * to record.
	 */
	if (!track_commit_timestamp)
		return;

	/*
	 * In the transdiscard and sub_disable retry, the apply transaction is
	 * read-only and is thrown away, so nothing it does can diverge.
	 */
	if (XactReadOnly)
		return;

	/*
	 * 1.  A FULL table has no replica identity index either, so the second
	 * test covers it too; the first says why such a table is left out.
	 */
	if (rel->rel->rd_rel->relreplident == REPLICA_IDENTITY_FULL)
		return;
	if (!OidIsValid(RelationGetReplicaIndex(rel->rel)))
		return;

	/* 5 */
	if (local_origin_found && local_origin == replorigin_session_origin)
		return;

	/*
	 * 6, first: the local row's commit timestamp cannot be read.  Its last
	 * write is older than pg_commit_ts keeps, or predates a pg_upgrade,
	 * which does not carry commit timestamps over, or ran while
	 * track_commit_timestamp was off.  Like an old row below, it is not a
	 * recent local write racing this update, and recording it would put
	 * every old row's next such update in the queue, enough to fill it
	 * after an upgrade.  Missed, and documented: a write made here just
	 * before a pg_upgrade, or before track_commit_timestamp was turned on,
	 * that the sender had not applied yet.
	 */
	if (!local_origin_found)
		return;

	/*
	 * 6: the local row was last written before this subscription existed.
	 * Rows copied by the initial table sync carry an epoch commit timestamp,
	 * and data restored before replication was set up predates it too.  The
	 * divergence detected here comes from a local write racing an incoming
	 * update, and that local write is usually newer than the subscription;
	 * an older row usually differs only because of a difference that
	 * predates replication, which detection never covered (it is
	 * forward-only).  The exception, which is missed and documented: a
	 * write made here before the subscription that the sender had not yet
	 * applied when it was created, because it was still catching up.
	 * Without this,
	 * every copied row's first such update on a new node would be recorded,
	 * enough to fill the queue after joining a large table.  The same test
	 * spock.log_origin_change = since_sub_creation applies.  A subscription
	 * with no recorded creation time is not filtered.
	 */
	if (local_ts != 0 &&
		MySubscription != NULL && MySubscription->created_at != 0 &&
		local_ts < MySubscription->created_at)
		return;

	/* 3: collect the unchanged columns as an int2[] literal. */
	initStringInfo(&attnums);
	appendStringInfoChar(&attnums, '{');
	for (i = 0; i < rel->natts; i++)
	{
		int			attid = rel->attmap[i];

		if (newtup->changed[attid])
			continue;
		if (any)
			appendStringInfoChar(&attnums, ',');
		appendStringInfo(&attnums, "%d", attid + 1);
		any = true;
	}
	appendStringInfoChar(&attnums, '}');

	if (!any || !suspect_table_exists())
	{
		pfree(attnums.data);
		return;
	}

	arg.relid = RelationGetRelid(rel->rel);
	arg.rel = rel->rel;
	arg.slot = newslot;
	arg.pkey = NULL;
	arg.attnums = attnums.data;
	arg.local_origin = local_origin;
	arg.local_ts = local_ts;

	/*
	 * Everything that can fail runs in a subtransaction, and a failure is
	 * only warned about.  This hook runs in the middle of applying a
	 * replicated transaction, and with spock.exception_behaviour set to
	 * transdiscard, the default, an error escaping it would discard that
	 * whole transaction: a full disk, or a key too large for the index, must
	 * not cost the user the data being applied.  The subtransaction commits
	 * inside the apply transaction, so the entry still disappears if the
	 * apply transaction later aborts.
	 */
	if (!run_in_subxact(suspect_record_cb, &arg, &record_err))
		ereport(WARNING,
				(errmsg("could not record TOAST suspect for relation %u: %s",
						arg.relid, record_err)));

	pfree(attnums.data);
	if (arg.pkey)
		pfree(arg.pkey);
}
