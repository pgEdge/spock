/*-------------------------------------------------------------------------
 *
 * spock_apply.c
 * 		spock apply logic
 *
 * Copyright (c) 2022-2023, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "miscadmin.h"
#include "libpq-fe.h"
#include "pgstat.h"

#include "access/htup_details.h"
#include "access/xact.h"

#include "catalog/namespace.h"

#include "commands/async.h"
#include "commands/dbcommands.h"
#include "commands/sequence.h"
#include "commands/tablecmds.h"
#include "commands/trigger.h"

#include "executor/executor.h"

#include "libpq/pqformat.h"

#include "mb/pg_wchar.h"

#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"

#include "optimizer/planner.h"

#ifdef XCP
#include "pgxc/pgxcnode.h"
#endif

#include "replication/origin.h"
#include "replication/reorderbuffer.h"
#include "replication/walsender.h"

#include "rewrite/rewriteHandler.h"

#include "storage/ipc.h"
#include "storage/lmgr.h"
#include "storage/proc.h"

#include "tcop/pquery.h"
#include "tcop/utility.h"

#include "utils/builtins.h"

#if PG_VERSION_NUM < 150000
#include "utils/int8.h"
#else
#include "utils/builtins.h"
#endif

#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"
#if PG_VERSION_NUM >= 160000
#include "utils/usercontext.h"
#endif

#include "spock_conflict.h"
#include "spock_executor.h"
#include "spock_node.h"
#include "spock_queue.h"
#include "spock_relcache.h"
#include "spock_repset.h"
#include "spock_rpc.h"
#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_apply.h"
#include "spock_apply_heap.h"
#include "spock_apply_spi.h"
#include "spock.h"


PGDLLEXPORT void spock_apply_main(Datum main_arg);

static bool			in_remote_transaction = false;
static XLogRecPtr	remote_origin_lsn = InvalidXLogRecPtr;
static RepOriginId	remote_origin_id = InvalidRepOriginId;
static TimeOffset	apply_delay = 0;

static Oid			QueueRelid = InvalidOid;

static List		   *SyncingTables = NIL;

SpockApplyWorker	   *MyApplyWorker = NULL;
SpockSubscription	   *MySubscription = NULL;

static PGconn	   *applyconn = NULL;

typedef struct SpockApplyFunctions
{
	spock_apply_begin_fn	on_begin;
	spock_apply_commit_fn	on_commit;
	spock_apply_insert_fn	do_insert;
	spock_apply_update_fn	do_update;
	spock_apply_delete_fn	do_delete;
	spock_apply_can_mi_fn	can_multi_insert;
	spock_apply_mi_add_tuple_fn	multi_insert_add_tuple;
	spock_apply_mi_finish_fn	multi_insert_finish;
} SpockApplyFunctions;

static SpockApplyFunctions apply_api =
{
	.on_begin = spock_apply_heap_begin,
	.on_commit = spock_apply_heap_commit,
	.do_insert = spock_apply_heap_insert,
	.do_update = spock_apply_heap_update,
	.do_delete = spock_apply_heap_delete,
	.can_multi_insert = spock_apply_heap_can_mi,
	.multi_insert_add_tuple = spock_apply_heap_mi_add_tuple,
	.multi_insert_finish = spock_apply_heap_mi_finish
};

/* Number of tuples inserted after which we switch to multi-insert. */
#define MIN_MULTI_INSERT_TUPLES 5
static SpockRelation   *last_insert_rel = NULL;
static int					last_insert_rel_cnt = 0;
static bool					use_multi_insert = false;

/*
 * A message counter for the xact, for debugging. We don't send
 * the remote change LSN with messages, so this aids identification
 * of which change causes an error.
 */
static uint32			xact_action_counter;

typedef struct SPKFlushPosition
{
	dlist_node node;
	XLogRecPtr local_end;
	XLogRecPtr remote_end;
} SPKFlushPosition;

dlist_head lsn_mapping = DLIST_STATIC_INIT(lsn_mapping);

typedef struct ApplyExecState
{
	EState			   *estate;
	EPQState		   epqstate;
	ResultRelInfo	   *resultRelInfo;
	TupleTableSlot	   *slot;
} ApplyExecState;

struct ActionErrCallbackArg
{
	const char * action_name;
	SpockRelation *rel;
	bool is_ddl_or_drop;
};

struct ActionErrCallbackArg errcallback_arg;
TransactionId remote_xid;

static void multi_insert_finish(void);

static void handle_queued_message(HeapTuple msgtup, bool tx_just_started);
static void handle_startup_param(const char *key, const char *value);
static bool parse_bool_param(const char *key, const char *value);
static void process_syncing_tables(XLogRecPtr end_lsn);
static void start_sync_worker(Name nspname, Name relname);

/*
 * Check if given relation is in process of being synchronized.
 *
 * TODO: performance
 */
static bool
should_apply_changes_for_rel(const char *nspname, const char *relname)
{
	if (list_length(SyncingTables) > 0)
	{
		ListCell	   *lc;

		foreach (lc, SyncingTables)
		{
			SpockSyncStatus	   *sync = (SpockSyncStatus *) lfirst(lc);

			if (namestrcmp(&sync->nspname, nspname) == 0 &&
				namestrcmp(&sync->relname, relname) == 0 &&
				(sync->status != SYNC_STATUS_READY &&
				 !(sync->status == SYNC_STATUS_SYNCDONE &&
				   sync->statuslsn <= replorigin_session_origin_lsn)))
				return false;
		}
	}

	return true;
}

/*
 * Prepare apply state details for errcontext or direct logging.
 *
 * This callback could be invoked at all sorts of weird times
 * so it should assume as little as psosible about the invoking
 * context.
 */
static void
format_action_description(
	StringInfo si,
	const char * action_name,
	SpockRelation *rel,
	bool is_ddl_or_drop)
{
	appendStringInfoString(si, "apply ");
	appendStringInfoString(si,
		action_name == NULL ? "(unknown action)" : action_name);

	if (rel != NULL && 
		rel->nspname != NULL
		&& rel->relname != NULL
		&& !is_ddl_or_drop)
	{
		appendStringInfo(si, " from remote relation %s.%s",
				rel->nspname, rel->relname);
	}

	appendStringInfo(si,
			" in commit before %X/%X, xid %u committed at %s (action #%u)",
			(uint32)(replorigin_session_origin_lsn>>32),
			(uint32)replorigin_session_origin_lsn,
			remote_xid,
			timestamptz_to_str(replorigin_session_origin_timestamp),
			xact_action_counter);

	if (replorigin_session_origin != InvalidRepOriginId)
	{
		appendStringInfo(si, " from node replorigin %u",
			replorigin_session_origin);
	}

	if (remote_origin_id != InvalidRepOriginId)
	{
		appendStringInfo(si, " forwarded from commit %X/%X on node %u",
				(uint32)(remote_origin_lsn>>32),
				(uint32)remote_origin_lsn,
				remote_origin_id);
	}
}

static void
action_error_callback(void *arg)
{
	StringInfoData si;
	initStringInfo(&si);

	format_action_description(&si,
		errcallback_arg.action_name,
		errcallback_arg.rel,
		errcallback_arg.is_ddl_or_drop);

	errcontext("%s", si.data);
	pfree(si.data);
}

static bool
ensure_transaction(void)
{
	if (IsTransactionState())
	{
		if (CurrentMemoryContext != MessageContext)
			MemoryContextSwitchTo(MessageContext);
		return false;
	}

	/*
	 * spock doesn't have "statements" as such, so we'll report one
	 * statement per applied transaction. We must set the statement start time
	 * because StartTransaction() uses it to initialize the transaction cached
	 * timestamp used by current_timestamp. If we don't set it, every xact will
	 * get the same current_timestamp. See 2ndQuadrant/spock_internal#148
	 */
	SetCurrentStatementStartTimestamp();

	StartTransactionCommand();
	apply_api.on_begin();
	MemoryContextSwitchTo(MessageContext);

	return true;
}

static void
handle_begin(StringInfo s)
{
	XLogRecPtr		commit_lsn;
	TimestampTz		commit_time;

	xact_action_counter = 1;
	errcallback_arg.action_name = "BEGIN";

	spock_read_begin(s, &commit_lsn, &commit_time, &remote_xid);

	replorigin_session_origin_timestamp = commit_time;
	replorigin_session_origin_lsn = commit_lsn;
	remote_origin_id = InvalidRepOriginId;

	VALGRIND_PRINTF("SPOCK_APPLY: begin %u\n", remote_xid);

	/* don't want the overhead otherwise */
	if (apply_delay > 0)
	{
		TimestampTz		current;
		current = GetCurrentIntegerTimestamp();

		/* ensure no weirdness due to clock drift */
		if (current > replorigin_session_origin_timestamp)
		{
			long		sec;
			int			usec;

			current = TimestampTzPlusMilliseconds(current,
												  -apply_delay);

			TimestampDifference(current, replorigin_session_origin_timestamp,
								&sec, &usec);
			/* FIXME: deal with overflow? */
			pg_usleep(usec + (sec * USECS_PER_SEC));
		}
	}

	in_remote_transaction = true;

	pgstat_report_activity(STATE_RUNNING, NULL);
}

/*
 * Handle COMMIT message.
 */
static void
handle_commit(StringInfo s)
{
	XLogRecPtr		commit_lsn;
	XLogRecPtr		end_lsn;
	TimestampTz		commit_time;

	errcallback_arg.action_name = "COMMIT";
	xact_action_counter++;

	spock_read_commit(s, &commit_lsn, &end_lsn, &commit_time);

	Assert(commit_time == replorigin_session_origin_timestamp);

	if (IsTransactionState())
	{
		SPKFlushPosition *flushpos;

		multi_insert_finish();

		apply_api.on_commit();

		/* We need to write end_lsn to the commit record. */
		replorigin_session_origin_lsn = end_lsn;

		CommitTransactionCommand();
		MemoryContextSwitchTo(TopMemoryContext);

		/* Track commit lsn  */
		flushpos = (SPKFlushPosition *) palloc(sizeof(SPKFlushPosition));
		flushpos->local_end = XactLastCommitEnd;
		flushpos->remote_end = end_lsn;

		dlist_push_tail(&lsn_mapping, &flushpos->node);
		MemoryContextSwitchTo(MessageContext);
	}

	/*
	 * If the xact isn't from the immediate upstream, advance the slot of the
	 * node it originally came from so we start replay of that node's change
	 * data at the right place.
	 *
	 * This is only necessary when we're streaming data from one peer (A) that
	 * in turn receives from other peers (B, C), and we plan to later switch to
	 * replaying directly from B and/or C, no longer receiving forwarded xacts
	 * from A. When we do the switchover we need to know the right place at
	 * which to start replay from B and C. We don't actually do that yet, but
	 * we'll want to be able to do cascaded initialisation in future, so it's
	 * worth keeping track.
	 *
	 * A failure can occur here (see #79) if there's a cascading
	 * replication configuration like:
	 *
	 * X--> Y -> Z
	 * |         ^
	 * |         |
	 * \---------/
	 *
	 * where the direct and indirect connections from X to Z use different
	 * replication sets so as not to conflict, and where Y and Z are on the
	 * same PostgreSQL instance. In this case our attempt to advance the
	 * replication identifier here will ERROR because it's already in use
	 * for the direct connection from X to Z. So don't do that.
	 */
	if (remote_origin_id != InvalidRepOriginId &&
		remote_origin_id != replorigin_session_origin)
	{
		Relation replorigin_rel;
		elog(DEBUG3, "SPOCK %s: advancing origin oid %u for forwarded "
					 "row to %X/%X",
			MySubscription->name,
			remote_origin_id,
			(uint32)(XactLastCommitEnd>>32), (uint32)XactLastCommitEnd);

		replorigin_rel = table_open(ReplicationOriginRelationId, RowExclusiveLock);
		replorigin_advance(remote_origin_id, remote_origin_lsn,
						   XactLastCommitEnd, false, false /* XXX ? */);
		table_close(replorigin_rel, RowExclusiveLock);
	}

	in_remote_transaction = false;

	/*
	 * Stop replay if we're doing limited replay and we've replayed up to the
	 * last record we're supposed to process.
	 */
	if (MyApplyWorker->replay_stop_lsn != InvalidXLogRecPtr
			&& MyApplyWorker->replay_stop_lsn <= end_lsn)
	{
		ereport(LOG,
				(errmsg("SPOCK %s: %s finished processing; replayed "
						"to %X/%X of required %X/%X",
						MySubscription->name,
						MySpockWorker->worker_type == SPOCK_WORKER_SYNC ? "sync" : "apply",
						(uint32)(end_lsn>>32), (uint32)end_lsn,
						(uint32)(MyApplyWorker->replay_stop_lsn >>32),
						(uint32)MyApplyWorker->replay_stop_lsn)));

		/*
		 * If this is sync worker, update syncing table state to done.
		 */
		if (MySpockWorker->worker_type == SPOCK_WORKER_SYNC)
		{
			StartTransactionCommand();
			set_table_sync_status(MyApplyWorker->subid,
							  NameStr(MySpockWorker->worker.sync.nspname),
							  NameStr(MySpockWorker->worker.sync.relname),
							  SYNC_STATUS_SYNCDONE, end_lsn);
			CommitTransactionCommand();
		}

		/*
		 * Flush all writes so the latest position can be reported back to the
		 * sender.
		 */
		XLogFlush(GetXLogWriteRecPtr());

		/*
		 * Disconnect.
		 *
		 * This needs to happen before the spock_sync_worker_finish()
		 * call otherwise slot drop will fail.
		 */
		PQfinish(applyconn);

		/*
		 * If this is sync worker, finish it.
		 */
		if (MySpockWorker->worker_type == SPOCK_WORKER_SYNC)
			spock_sync_worker_finish();

		/* Stop gracefully */
		proc_exit(0);
	}

	VALGRIND_PRINTF("SPOCK_APPLY: commit %u\n", remote_xid);

	xact_action_counter = 0;
	remote_xid = InvalidTransactionId;

	process_syncing_tables(end_lsn);

	/*
	 * Ensure any pending signals/self-notifies are sent out.
	 *
	 * Note that there is a possibility that this will result in an ERROR,
	 * which will result in the apply worker being killed and restarted. As
	 * the notification queues have already been flushed, the same error won't
	 * occur again, however if errors continue, they will dramatically slow
	 * down - but not stop - replication.
	 *
	 * For PG15 and above, such notifications are sent at transaction commit.
	 * (This is also true of previous version branches that received a fix[1]
	 * but where ProcessCompletedNotifies() was converted to a no-op routine
	 * to avoid breaking ABI.)
	 *
	 * [1] -- Discussion: https://www.postgresql.org/message-id/flat/153243441449.1404.2274116228506175596@wrigleys.postgresql.org
	 */
#if PG_VERSION_NUM < 150000
	ProcessCompletedNotifies();
#endif

    pgstat_report_activity(STATE_IDLE, NULL);
}

/*
 * Handle ORIGIN message.
 */
static void
handle_origin(StringInfo s)
{
	char		   *origin;

	/*
	 * ORIGIN message can only come inside remote transaction and before
	 * any actual writes.
	 */
	if (!in_remote_transaction || IsTransactionState())
		elog(ERROR, "SPOCK %s: ORIGIN message sent out of order",
			 MySubscription->name);

	/* We have to start transaction here so that we can work with origins. */
	ensure_transaction();

	origin = spock_read_origin(s, &remote_origin_lsn);
	remote_origin_id = replorigin_by_name(origin, true);
}

/*
 * Handle RELATION message.
 *
 * Note we don't do validation against local schema here. The validation is
 * posponed until first change for given relation comes.
 */
static void
handle_relation(StringInfo s)
{
	multi_insert_finish();

	(void) spock_read_rel(s);
}

static void
handle_insert(StringInfo s)
{
	SpockTupleData	newtup;
	SpockRelation  *rel;
#if PG_VERSION_NUM >= 160000
	UserContext		ucxt;
#endif
	bool			started_tx = ensure_transaction();

	PushActiveSnapshot(GetTransactionSnapshot());

	errcallback_arg.action_name = "INSERT";
	xact_action_counter++;

	rel = spock_read_insert(s, RowExclusiveLock, &newtup);
	errcallback_arg.rel = rel;

	/* If in list of relations which are being synchronized, skip. */
	if (!should_apply_changes_for_rel(rel->nspname, rel->relname))
	{
		spock_relation_close(rel, NoLock);
		PopActiveSnapshot();
		CommandCounterIncrement();
		return;
	}

	/* Make sure that any user-supplied code runs as the table owner. */
	SwitchToUntrustedUser(rel->rel->rd_rel->relowner, &ucxt);

	/* Handle multi_insert capabilities. */
	if (use_multi_insert)
	{
		if (rel != last_insert_rel)
		{
			multi_insert_finish();
			/* Fall through to normal insert. */
		}
		else
		{
			apply_api.multi_insert_add_tuple(rel, &newtup);
			last_insert_rel_cnt++;
			return;
		}
	}
	else if (spock_batch_inserts &&
			 RelationGetRelid(rel->rel) != QueueRelid &&
			 apply_api.can_multi_insert &&
			 apply_api.can_multi_insert(rel))
	{
		if (rel != last_insert_rel)
		{
			last_insert_rel = rel;
			last_insert_rel_cnt = 0;
		}
		else if (last_insert_rel_cnt++ >= MIN_MULTI_INSERT_TUPLES)
		{
			use_multi_insert = true;
			last_insert_rel_cnt = 0;
		}
	}

	/* Normal insert. */
	apply_api.do_insert(rel, &newtup);

	/* if INSERT was into our queue, process the message. */
	if (RelationGetRelid(rel->rel) == QueueRelid)
	{
		HeapTuple		ht;
		LockRelId		lockid = rel->rel->rd_lockInfo.lockRelId;
		Relation		qrel;

		multi_insert_finish();

		MemoryContextSwitchTo(MessageContext);

		ht = heap_form_tuple(RelationGetDescr(rel->rel),
							 newtup.values, newtup.nulls);

		LockRelationIdForSession(&lockid, RowExclusiveLock);
		RestoreUserContext(&ucxt);
		spock_relation_close(rel, NoLock);

		PopActiveSnapshot();
		CommandCounterIncrement();

		apply_api.on_commit();

		handle_queued_message(ht, started_tx);

		heap_freetuple(ht);

		qrel = table_open(QueueRelid, RowExclusiveLock);

		UnlockRelationIdForSession(&lockid, RowExclusiveLock);

		table_close(qrel, NoLock);

		apply_api.on_begin();
		MemoryContextSwitchTo(MessageContext);

//		if (oldxid != GetTopTransactionId())
//			CommitTransactionCommand();
	}
	else
	{
		RestoreUserContext(&ucxt);
		spock_relation_close(rel, NoLock);

		PopActiveSnapshot();
		CommandCounterIncrement();
	}
}

static void
multi_insert_finish(void)
{
	if (use_multi_insert && last_insert_rel_cnt)
	{
		const char *old_action = errcallback_arg.action_name;
		SpockRelation *old_rel = errcallback_arg.rel;
		errcallback_arg.action_name = "multi INSERT";
		errcallback_arg.rel = last_insert_rel;

		apply_api.multi_insert_finish(last_insert_rel);
		spock_relation_close(last_insert_rel, NoLock);
		use_multi_insert = false;
		last_insert_rel = NULL;
		last_insert_rel_cnt = 0;

		errcallback_arg.rel = old_rel;
		errcallback_arg.action_name = old_action;
	}
}

static void
handle_update(StringInfo s)
{
	SpockTupleData	oldtup;
	SpockTupleData	newtup;
	SpockRelation  *rel;
#if PG_VERSION_NUM >= 160000
	UserContext		ucxt;
#endif
	bool			hasoldtup;

	errcallback_arg.action_name = "UPDATE";
	xact_action_counter++;

	ensure_transaction();

	multi_insert_finish();

	PushActiveSnapshot(GetTransactionSnapshot());

	rel = spock_read_update(s, RowExclusiveLock, &hasoldtup, &oldtup,
								&newtup);
	errcallback_arg.rel = rel;

	/* If in list of relations which are being synchronized, skip. */
	if (!should_apply_changes_for_rel(rel->nspname, rel->relname))
	{
		spock_relation_close(rel, NoLock);
		PopActiveSnapshot();
		CommandCounterIncrement();
		return;
	}

	/* Make sure that any user-supplied code runs as the table owner. */
	SwitchToUntrustedUser(rel->rel->rd_rel->relowner, &ucxt);

	apply_api.do_update(rel, hasoldtup ? &oldtup : &newtup, &newtup);

	RestoreUserContext(&ucxt);
	spock_relation_close(rel, NoLock);

	PopActiveSnapshot();
	CommandCounterIncrement();
}

static void
handle_delete(StringInfo s)
{
	SpockTupleData	oldtup;
	SpockRelation  *rel;
#if PG_VERSION_NUM >= 160000
	UserContext		ucxt;
#endif

	memset(&errcallback_arg, 0, sizeof(struct ActionErrCallbackArg));
	xact_action_counter++;

	ensure_transaction();

	multi_insert_finish();

	PushActiveSnapshot(GetTransactionSnapshot());

	rel = spock_read_delete(s, RowExclusiveLock, &oldtup);
	errcallback_arg.rel = rel;

	/* If in list of relations which are being synchronized, skip. */
	if (!should_apply_changes_for_rel(rel->nspname, rel->relname))
	{
		spock_relation_close(rel, NoLock);
		PopActiveSnapshot();
		CommandCounterIncrement();
		return;
	}

	/* Make sure that any user-supplied code runs as the table owner. */
	SwitchToUntrustedUser(rel->rel->rd_rel->relowner, &ucxt);

	apply_api.do_delete(rel, &oldtup);

	RestoreUserContext(&ucxt);
	spock_relation_close(rel, NoLock);

	PopActiveSnapshot();
	CommandCounterIncrement();
}

inline static bool
getmsgisend(StringInfo msg)
{
	return msg->cursor == msg->len;
}

static void
handle_startup(StringInfo s)
{
	uint8 msgver = pq_getmsgbyte(s);
	if (msgver != 1)
		elog(ERROR, "SPOCK %s: Expected startup message version 1, but got %u",
			 MySubscription->name, msgver);

	/*
	 * The startup message consists of null-terminated strings as key/value
	 * pairs. The first entry is always the format identifier.
	 */
	do {
		const char *k, *v;

		k = pq_getmsgstring(s);
		if (strlen(k) == 0)
			ereport(ERROR,
					(errcode(ERRCODE_PROTOCOL_VIOLATION),
					 errmsg("SPOCK %s: invalid startup message: key has "
							"zero length",
							MySubscription->name)));

		if (getmsgisend(s))
			ereport(ERROR,
					(errcode(ERRCODE_PROTOCOL_VIOLATION),
					 errmsg("SPOCK %s: invalid startup message: key '%s' "
							"has no following value",
							MySubscription->name, k)));

		/* It's OK to have a zero length value */
		v = pq_getmsgstring(s);

		handle_startup_param(k, v);
	} while (!getmsgisend(s));
}

static bool
parse_bool_param(const char *key, const char *value)
{
	bool result;

	if (!parse_bool(value, &result))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("SPOCK %s: couldn't parse value '%s' for key '%s' "
						"as boolean",
						MySubscription->name, value, key)));

	return result;
}

static void
handle_startup_param(const char *key, const char *value)
{
	elog(DEBUG2, "SPOCK %s: apply got spock startup msg param  %s=%s",
		 MySubscription->name, key, value);

	if (strcmp(key, "pg_version") == 0)
		elog(DEBUG1, "SPOCK %s: upstream Pg version is %s",
			 MySubscription->name, value);

	if (strcmp(key, "encoding") == 0)
	{
		int encoding = pg_char_to_encoding(value);

		if (encoding != GetDatabaseEncoding())
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("SPOCK %s: expected encoding=%s from upstream "
							"but got %s",
							MySubscription->name,
							GetDatabaseEncodingName(), value)));
	}

	if (strcmp(key, "forward_changeset_origins") == 0)
	{
		bool fwd = parse_bool_param(key, value);
		/* FIXME: Store this somewhere */
		elog(DEBUG1, "SPOCK %s: changeset origin forwarding enabled: %s",
			 MySubscription->name, fwd ? "t" : "f");
	}

	/*
	 * We just ignore a bunch of parameters here because we specify what we
	 * require when we send our params to the upstream. It's required to ERROR
	 * if it can't match what we asked for. It may send the startup message
	 * first, but it'll be followed by an ERROR if it does. There's no need
	 * to check params we can't do anything about mismatches of, like protocol
	 * versions and type sizes.
	 */
}

static RangeVar *
parse_relation_message(Jsonb *message)
{
	JsonbIterator  *it;
	JsonbValue		v;
	int				r;
	int				level = 0;
	char		   *key = NULL;
	char		  **parse_res = NULL;
	char		   *nspname = NULL;
	char		   *relname = NULL;

	/* Parse and validate the json message. */
	if (!JB_ROOT_IS_OBJECT(message))
		elog(ERROR, "SPOCK %s: malformed message in queued message tuple: "
					"root is not object",
			 MySubscription->name);

	it = JsonbIteratorInit(&message->root);
	while ((r = JsonbIteratorNext(&it, &v, false)) != WJB_DONE)
	{
		if (level == 0 && r != WJB_BEGIN_OBJECT)
			elog(ERROR, "SPOCK %s: root element needs to be an object",
				 MySubscription->name);
		else if (level == 0 && r == WJB_BEGIN_OBJECT)
		{
			level++;
		}
		else if (level == 1 && r == WJB_KEY)
		{
			if (strncmp(v.val.string.val, "schema_name", v.val.string.len) == 0)
				parse_res = &nspname;
			else if (strncmp(v.val.string.val, "table_name", v.val.string.len) == 0)
				parse_res = &relname;
			else
				elog(ERROR, "SPOCK %s: unexpected key: %s",
					 MySubscription->name,
					 pnstrdup(v.val.string.val, v.val.string.len));

			key = v.val.string.val;
		}
		else if (level == 1 && r == WJB_VALUE)
		{
			if (!key)
				elog(ERROR, "SPOCK %s: in wrong state when parsing key",
					 MySubscription->name);

			if (v.type != jbvString)
				elog(ERROR, "SPOCK %s: unexpected type for key '%s': %u",
					 MySubscription->name, key, v.type);

			*parse_res = pnstrdup(v.val.string.val, v.val.string.len);
		}
		else if (level == 1 && r != WJB_END_OBJECT)
		{
			elog(ERROR, "SPOCK %s: unexpected content: %u at level %d",
				 MySubscription->name, r, level);
		}
		else if (r == WJB_END_OBJECT)
		{
			level--;
			parse_res = NULL;
			key = NULL;
		}
		else
			elog(ERROR, "SPOCK %s: unexpected content: %u at level %d",
				 MySubscription->name, r, level);

	}

	/* Check if we got both schema and table names. */
	if (!nspname)
		elog(ERROR, "SPOCK %s: missing schema_name in relation message",
			 MySubscription->name);

	if (!relname)
		elog(ERROR, "SPOCK %s: missing table_name in relation message",
			 MySubscription->name);

	return makeRangeVar(nspname, relname, -1);
}

/*
 * Handle TRUNCATE message comming via queue table.
 */
static void
handle_truncate(QueuedMessage *queued_message)
{
	RangeVar	   *rv;

	/*
	 * If table doesn't exist locally, it can't be subscribed.
	 *
	 * TODO: should we error here?
	 */
	rv = parse_relation_message(queued_message->message);

	/* If in list of relations which are being synchronized, skip. */
	if (!should_apply_changes_for_rel(rv->schemaname, rv->relname))
		return;

	truncate_table(rv->schemaname, rv->relname);
}

/*
 * Handle TABLESYNC message comming via queue table.
 */
static void
handle_table_sync(QueuedMessage *queued_message)
{
	RangeVar			   *rv;
	MemoryContext			oldcontext;
	SpockSyncStatus	   *oldsync;
	SpockSyncStatus	   *newsync;

	rv = parse_relation_message(queued_message->message);

	oldsync = get_table_sync_status(MyApplyWorker->subid, rv->schemaname,
									rv->relname, true);

	if (oldsync)
	{
		elog(INFO, "SPOCK %s: table sync came from queue for table %s.%s "
				   "which already being synchronized, skipping",
			 MySubscription->name,
			 rv->schemaname, rv->relname);

		return;
	}

	/* Keep the lists persistent. */
	oldcontext = MemoryContextSwitchTo(TopMemoryContext);
	newsync = palloc0(sizeof(SpockSyncStatus));
	MemoryContextSwitchTo(oldcontext);

	newsync->kind = SYNC_KIND_DATA;
	newsync->subid = MyApplyWorker->subid;
	newsync->status = SYNC_STATUS_INIT;
	namestrcpy(&newsync->nspname, rv->schemaname);
	namestrcpy(&newsync->relname, rv->relname);
	create_local_sync_status(newsync);

	oldcontext = MemoryContextSwitchTo(TopMemoryContext);
	MemoryContextSwitchTo(oldcontext);

	MyApplyWorker->sync_pending = true;
}

/*
 * Handle SEQUENCE message comming via queue table.
 */
static void
handle_sequence(QueuedMessage *queued_message)
{
	Jsonb		   *message = queued_message->message;
	JsonbIterator  *it;
	JsonbValue		v;
	int				r;
	int				level = 0;
	char		   *key = NULL;
	char		  **parse_res = NULL;
	char		   *nspname = NULL;
	char		   *relname = NULL;
	char		   *last_value_raw = NULL;
	int64			last_value;
	Oid				nspoid;
	Oid				reloid;

	/* Parse and validate the json message. */
	if (!JB_ROOT_IS_OBJECT(message))
		elog(ERROR, "SPOCK %s: malformed message in queued message tuple: "
					"root is not object",
			 MySubscription->name);

	it = JsonbIteratorInit(&message->root);
	while ((r = JsonbIteratorNext(&it, &v, false)) != WJB_DONE)
	{
		if (level == 0 && r != WJB_BEGIN_OBJECT)
			elog(ERROR, "SPOCK %s: root element needs to be an object",
				 MySubscription->name);
		else if (level == 0 && r == WJB_BEGIN_OBJECT)
		{
			level++;
		}
		else if (level == 1 && r == WJB_KEY)
		{
			if (strncmp(v.val.string.val, "schema_name", v.val.string.len) == 0)
				parse_res = &nspname;
			else if (strncmp(v.val.string.val, "sequence_name", v.val.string.len) == 0)
				parse_res = &relname;
			else if (strncmp(v.val.string.val, "last_value", v.val.string.len) == 0)
				parse_res = &last_value_raw;
			else
				elog(ERROR, "SPOCK %s: unexpected key: %s",
					 MySubscription->name,
					 pnstrdup(v.val.string.val, v.val.string.len));

			key = v.val.string.val;
		}
		else if (level == 1 && r == WJB_VALUE)
		{
			if (!key)
				elog(ERROR, "SPOCK %s: in wrong state when parsing key",
					 MySubscription->name);

			if (v.type != jbvString)
				elog(ERROR, "SPOCK %s: unexpected type for key '%s': %u",
					 MySubscription->name, key, v.type);

			*parse_res = pnstrdup(v.val.string.val, v.val.string.len);
		}
		else if (level == 1 && r != WJB_END_OBJECT)
		{
			elog(ERROR, "SPOCK %s: unexpected content: %u at level %d",
				 MySubscription->name, r, level);
		}
		else if (r == WJB_END_OBJECT)
		{
			level--;
			parse_res = NULL;
			key = NULL;
		}
		else
			elog(ERROR, "SPOCK %s: unexpected content: %u at level %d",
				 MySubscription->name, r, level);

	}

	/* Check if we got both schema and table names. */
	if (!nspname)
		elog(ERROR, "SPOCK %s: missing schema_name in sequence message",
			 MySubscription->name);

	if (!relname)
		elog(ERROR, "SPOCK %s: missing table_name in sequence message",
			 MySubscription->name);

	if (!last_value_raw)
		elog(ERROR, "SPOCK %s: missing last_value in sequence message",
			 MySubscription->name);

	nspoid = get_namespace_oid(nspname, false);
	reloid = get_relname_relid(relname, nspoid);
#if PG_VERSION_NUM < 150000
	scanint8(last_value_raw, false, &last_value);
#else
	last_value = pg_strtoint64(last_value_raw);
#endif

	DirectFunctionCall2(setval_oid, ObjectIdGetDatum(reloid),
						Int64GetDatum(last_value));
}
/*
 * Handle SQL message comming via queue table.
 */
static void
handle_sql(QueuedMessage *queued_message, bool tx_just_started)
{
	JsonbIterator *it;
	JsonbValue	v;
	int			r;
	char	   *sql;

	/* Validate the json and extract the SQL string from it. */
	if (!JB_ROOT_IS_SCALAR(queued_message->message))
		elog(ERROR, "SPOCK %s: malformed message in queued message tuple: "
					"root is not scalar",
			 MySubscription->name);

	it = JsonbIteratorInit(&queued_message->message->root);
	r = JsonbIteratorNext(&it, &v, false);
	if (r != WJB_BEGIN_ARRAY)
		elog(ERROR, "SPOCK %s: malformed message in queued message tuple, "
					"item type %d expected %d",
			 MySubscription->name, r, WJB_BEGIN_ARRAY);

	r = JsonbIteratorNext(&it, &v, false);
	if (r != WJB_ELEM)
		elog(ERROR, "SPOCK %s: malformed message in queued message tuple, "
					"item type %d expected %d",
			 MySubscription->name, r, WJB_ELEM);

	if (v.type != jbvString)
		elog(ERROR, "SPOCK %s: malformed message in queued message tuple, "
					"expected value type %d got %d",
			 MySubscription->name, jbvString, v.type);

	sql = pnstrdup(v.val.string.val, v.val.string.len);

	r = JsonbIteratorNext(&it, &v, false);
	if (r != WJB_END_ARRAY)
		elog(ERROR, "SPOCK %s: malformed message in queued message tuple, "
					"item type %d expected %d",
			 MySubscription->name, r, WJB_END_ARRAY);

	r = JsonbIteratorNext(&it, &v, false);
	if (r != WJB_DONE)
		elog(ERROR, "SPOCK %s: malformed message in queued message tuple, "
					"item type %d expected %d",
			 MySubscription->name, r, WJB_DONE);

	in_spock_queue_command = true;
	/* Run the extracted SQL. */
	spock_execute_sql_command(sql, queued_message->role, tx_just_started);
	in_spock_queue_command = false;
}

/*
 * Handles messages comming from the queue.
 */
static void
handle_queued_message(HeapTuple msgtup, bool tx_just_started)
{
	QueuedMessage  *queued_message;
	const char	   *old_action_name;

	old_action_name = errcallback_arg.action_name;
	errcallback_arg.is_ddl_or_drop = true;

	queued_message = queued_message_from_tuple(msgtup);

	switch (queued_message->message_type)
	{
		case QUEUE_COMMAND_TYPE_SQL:
			errcallback_arg.action_name = "QUEUED_SQL";
			handle_sql(queued_message, tx_just_started);
			break;
		case QUEUE_COMMAND_TYPE_TRUNCATE:
			errcallback_arg.action_name = "QUEUED_TRUNCATE";
			handle_truncate(queued_message);
			break;
		case QUEUE_COMMAND_TYPE_TABLESYNC:
			errcallback_arg.action_name = "QUEUED_TABLESYNC";
			handle_table_sync(queued_message);
			break;
		case QUEUE_COMMAND_TYPE_SEQUENCE:
			errcallback_arg.action_name = "QUEUED_SEQUENCE";
			handle_sequence(queued_message);
			break;
		default:
			elog(ERROR, "SPOCK %s: unknown message type '%c'",
				 MySubscription->name,
				 queued_message->message_type);
	}

	errcallback_arg.action_name = old_action_name;
	errcallback_arg.is_ddl_or_drop = false;
}

static void
replication_handler(StringInfo s)
{
	ErrorContextCallback errcallback;
	char action = pq_getmsgbyte(s);

	memset(&errcallback_arg, 0, sizeof(struct ActionErrCallbackArg));
	errcallback.callback = action_error_callback;
	errcallback.arg = &errcallback_arg;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	Assert(CurrentMemoryContext == MessageContext);

	switch (action)
	{
		/* BEGIN */
		case 'B':
			handle_begin(s);
			break;
		/* COMMIT */
		case 'C':
			handle_commit(s);
			break;
		/* ORIGIN */
		case 'O':
			handle_origin(s);
			break;
		/* RELATION */
		case 'R':
			handle_relation(s);
			break;
		/* INSERT */
		case 'I':
			handle_insert(s);
			break;
		/* UPDATE */
		case 'U':
			handle_update(s);
			break;
		/* DELETE */
		case 'D':
			handle_delete(s);
			break;
		/* STARTUP MESSAGE */
		case 'S':
			handle_startup(s);
			break;
		default:
			elog(ERROR, "SPOCK %s: unknown action of type %c",
				 MySubscription->name, action);
	}

	Assert(CurrentMemoryContext == MessageContext);

	if (error_context_stack == &errcallback)
		error_context_stack = errcallback.previous;

	if (action == 'C')
	{
		/*
		 * We clobber MessageContext on commit. It doesn't matter much when we
		 * do it so long as we do so periodically, to prevent the context from
		 * growing too much. We might want to clean it up even 'n'th message
		 * too, but that adds testing burden and isn't done for now.
		 */
		MemoryContextReset(MessageContext);
	}
}

/*
 * Figure out which write/flush positions to report to the walsender process.
 *
 * We can't simply report back the last LSN the walsender sent us because the
 * local transaction might not yet be flushed to disk locally. Instead we
 * build a list that associates local with remote LSNs for every commit. When
 * reporting back the flush position to the sender we iterate that list and
 * check which entries on it are already locally flushed. Those we can report
 * as having been flushed.
 *
 * Returns true if there's no outstanding transactions that need to be
 * flushed.
 */
static bool
get_flush_position(XLogRecPtr *write, XLogRecPtr *flush)
{
	dlist_mutable_iter iter;
#if PG_VERSION_NUM < 150000
	XLogRecPtr	local_flush = GetFlushRecPtr();
#else
	XLogRecPtr	local_flush = GetFlushRecPtr(NULL);
#endif
	*write = InvalidXLogRecPtr;
	*flush = InvalidXLogRecPtr;

	dlist_foreach_modify(iter, &lsn_mapping)
	{
		SPKFlushPosition *pos =
			dlist_container(SPKFlushPosition, node, iter.cur);

		*write = pos->remote_end;

		if (pos->local_end <= local_flush)
		{
			*flush = pos->remote_end;
			dlist_delete(iter.cur);
			pfree(pos);
		}
		else
		{
			/*
			 * Don't want to uselessly iterate over the rest of the list which
			 * could potentially be long. Instead get the last element and
			 * grab the write position from there.
			 */
			pos = dlist_tail_element(SPKFlushPosition, node,
									 &lsn_mapping);
			*write = pos->remote_end;
			return false;
		}
	}

	return dlist_is_empty(&lsn_mapping);
}

/*
 * Send a Standby Status Update message to server.
 *
 * 'recvpos' is the latest LSN we've received data to, force is set if we need
 * to send a response to avoid timeouts.
 */
static bool
send_feedback(PGconn *conn, XLogRecPtr recvpos, int64 now, bool force)
{
	static StringInfo	reply_message = NULL;

	static XLogRecPtr last_recvpos = InvalidXLogRecPtr;
	static XLogRecPtr last_writepos = InvalidXLogRecPtr;
	static XLogRecPtr last_flushpos = InvalidXLogRecPtr;

	XLogRecPtr writepos;
	XLogRecPtr flushpos;

	/* It's legal to not pass a recvpos */
	if (recvpos < last_recvpos)
		recvpos = last_recvpos;

	if (get_flush_position(&writepos, &flushpos))
	{
		/*
		 * No outstanding transactions to flush, we can report the latest
		 * received position. This is important for synchronous replication.
		 */
		flushpos = writepos = recvpos;
	}

	if (writepos < last_writepos)
		writepos = last_writepos;

	if (flushpos < last_flushpos)
		flushpos = last_flushpos;

	/* if we've already reported everything we're good */
	if (!force &&
		writepos == last_writepos &&
		flushpos == last_flushpos)
		return true;

	if (!reply_message)
	{
		MemoryContext	oldcontext = MemoryContextSwitchTo(TopMemoryContext);
		reply_message = makeStringInfo();
		MemoryContextSwitchTo(oldcontext);
	}
	else
		resetStringInfo(reply_message);

	pq_sendbyte(reply_message, 'r');
	pq_sendint64(reply_message, recvpos);		/* write */
	pq_sendint64(reply_message, flushpos);		/* flush */
	pq_sendint64(reply_message, writepos);		/* apply */
	pq_sendint64(reply_message, now);			/* sendTime */
	pq_sendbyte(reply_message, false);			/* replyRequested */

	elog(DEBUG2, "SPOCK %s: sending feedback (force %d) to recv %X/%X, "
				 "write %X/%X, flush %X/%X",
		 MySubscription->name, force,
		 (uint32) (recvpos >> 32), (uint32) recvpos,
		 (uint32) (writepos >> 32), (uint32) writepos,
		 (uint32) (flushpos >> 32), (uint32) flushpos
		);

	if (PQputCopyData(conn, reply_message->data, reply_message->len) <= 0 ||
		PQflush(conn))
	{
		ereport(ERROR,
				(errcode(ERRCODE_CONNECTION_FAILURE),
				 errmsg("SPOCK %s: could not send feedback packet: %s",
						MySubscription->name, PQerrorMessage(conn))));
		return false;
	}

	if (recvpos > last_recvpos)
		last_recvpos = recvpos;
	if (writepos > last_writepos)
		last_writepos = writepos;
	if (flushpos > last_flushpos)
		last_flushpos = flushpos;

	return true;
}

/*
 * Apply main loop.
 */
void
apply_work(PGconn *streamConn)
{
	int			fd;
	char	   *copybuf = NULL;
	XLogRecPtr	last_received = InvalidXLogRecPtr;
	TimestampTz	last_receive_timestamp = GetCurrentTimestamp();

	applyconn = streamConn;
	fd = PQsocket(applyconn);

	/* Init the MessageContext which we use for easier cleanup. */
	MessageContext = AllocSetContextCreate(TopMemoryContext,
										   "MessageContext",
										   ALLOCSET_DEFAULT_SIZES);

	MemoryContextSwitchTo(MessageContext);

	/* mark as idle, before starting to loop */
	pgstat_report_activity(STATE_IDLE, NULL);
	Assert(CurrentMemoryContext == MessageContext);

	while (!got_SIGTERM)
	{
		int			rc;
		int			r;

		/*
		 * Background workers mustn't call usleep() or any direct equivalent:
		 * instead, they may wait on their process latch, which sleeps as
		 * necessary, but is awakened if postmaster dies.  That way the
		 * background process goes away immediately in an emergency.
		 */
		rc = WaitLatchOrSocket(&MyProc->procLatch,
							   WL_SOCKET_READABLE | WL_LATCH_SET |
							   WL_TIMEOUT | WL_POSTMASTER_DEATH,
							   fd, 1000L);

		ResetLatch(&MyProc->procLatch);

		CHECK_FOR_INTERRUPTS();

		Assert(CurrentMemoryContext == MessageContext);

		/* emergency bailout if postmaster has died */
		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		if (rc & WL_SOCKET_READABLE)
			PQconsumeInput(applyconn);

		if (PQstatus(applyconn) == CONNECTION_BAD)
		{
			elog(ERROR, "SPOCK %s: connection to other side has died",
				 MySubscription->name);
		}

		/*
		 * The walsender is supposed to ping us for a status update
		 * every wal_sender_timeout / 2 milliseconds. If we don't get
		 * those, we assume that we have lost the connection.
		 *
		 * Note: keepalive configuration is supposed to cover this but
		 * is apparently unreliable.
		 */
		if (rc & WL_TIMEOUT)
		{
			TimestampTz		timeout;

			timeout = TimestampTzPlusMilliseconds(last_receive_timestamp,
												  (wal_sender_timeout * 3) / 2);
			if (GetCurrentTimestamp() > timeout)
			{
				elog(ERROR, "SPOCK %s: terminating apply due to missing "
							"walsender ping",
					 MySubscription->name);
			}
		}

		Assert(CurrentMemoryContext == MessageContext);

		for (;;)
		{
			if (got_SIGTERM)
				break;

			/* We must not have fallen out of MessageContext by accident */
			Assert(CurrentMemoryContext == MessageContext);

			Assert(copybuf == NULL);
			r = PQgetCopyData(applyconn, &copybuf, 1);

			if (r == -1)
			{
				elog(ERROR, "SPOCK %s: data stream ended",
					 MySubscription->name);
			}
			else if (r == -2)
			{
				elog(ERROR, "SPOCK %s: could not read COPY data: %s",
					 MySubscription->name,
					 PQerrorMessage(applyconn));
			}
			else if (r < 0)
				elog(ERROR, "SPOCK %s: invalid COPY status %d",
					 MySubscription->name, r);
			else if (r == 0)
			{
				/* need to wait for new data */
				break;
			}
			else
			{
				int c;
				StringInfoData s;

				last_receive_timestamp = GetCurrentTimestamp();

				/*
				 * We're using a StringInfo to wrap existing data here, as a
				 * cursor. We init it manually to avoid a redundant allocation.
				 */
				memset(&s, 0, sizeof(StringInfoData));
				s.data = copybuf;
				s.len = r;
				s.maxlen = -1;
				s.cursor = 0;

				c = pq_getmsgbyte(&s);

				if (c == 'w')
				{
					XLogRecPtr	start_lsn;
					XLogRecPtr	end_lsn;

					start_lsn = pq_getmsgint64(&s);
					end_lsn = pq_getmsgint64(&s);
					pq_getmsgint64(&s); /* sendTime */

					if (last_received < start_lsn)
						last_received = start_lsn;

					if (last_received < end_lsn)
						last_received = end_lsn;

					replication_handler(&s);
				}
				else if (c == 'k')
				{
					XLogRecPtr endpos;
					bool reply_requested;

					endpos = pq_getmsgint64(&s);
					/* timestamp = */ pq_getmsgint64(&s);
					reply_requested = pq_getmsgbyte(&s);

					send_feedback(applyconn, endpos,
								  GetCurrentTimestamp(),
								  reply_requested);

					if (last_received < endpos)
						last_received = endpos;
				}
				/* other message types are purposefully ignored */

				/* copybuf is malloc'd not palloc'd */
				if (copybuf != NULL)
				{
					PQfreemem(copybuf);
					copybuf = NULL;
				}
			}

			/* We must not have fallen out of MessageContext by accident */
			Assert(CurrentMemoryContext == MessageContext);
		}

		/* confirm all writes at once */
		send_feedback(applyconn, last_received, GetCurrentTimestamp(), false);

		if (!in_remote_transaction)
			process_syncing_tables(last_received);
		
		/* We must not have switched out of MessageContext by mistake */
		Assert(CurrentMemoryContext == MessageContext);

		/* Cleanup the memory. */
		MemoryContextResetAndDeleteChildren(MessageContext);

		/*
		 * Only do a leak check if we're between txns; we don't want lots of
		 * noise due to resources that only exist in a txn.
		 */
		if (!IsTransactionState())
		{
			VALGRIND_DO_ADDED_LEAK_CHECK;
		}
	}
}

/*
 * Add context to the errors produced by spock_execute_sql_command().
 */
static void
execute_sql_command_error_cb(void *arg)
{
	errcontext("during execution of queued SQL statement: %s", (char *) arg);
}

/*
 * Execute an SQL command. This can be multiple multiple queries.
 */
void
spock_execute_sql_command(char *cmdstr, char *role, bool isTopLevel)
{
	const char *save_debug_query_string = debug_query_string;
	List	   *commands;
	ListCell   *command_i;
#ifdef PGXC
	List	   *commandSourceQueries;
	ListCell   *commandSourceQuery_i;
#endif
	MemoryContext oldcontext;
	ErrorContextCallback errcallback;

	oldcontext = MemoryContextSwitchTo(MessageContext);

	errcallback.callback = execute_sql_command_error_cb;
	errcallback.arg = cmdstr;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	debug_query_string = cmdstr;

	/*
	 * XL distributes individual statements using just executing them as plain
	 * SQL query and can't handle multistatements this way so we need to get
	 * individual statements using API provided by XL itself.
	 */
#ifdef PGXC
	commands = pg_parse_query_get_source(cmdstr, &commandSourceQueries);
#else
	commands = pg_parse_query(cmdstr);
#endif

	MemoryContextSwitchTo(oldcontext);

	/*
	 * Do a limited amount of safety checking against CONCURRENTLY commands
	 * executed in situations where they aren't allowed. The sender side should
	 * provide protection, but better be safe than sorry.
	 */
	isTopLevel = isTopLevel && (list_length(commands) == 1);

#ifdef PGXC
	forboth(command_i, commands, commandSourceQuery_i, commandSourceQueries)
#else
	foreach(command_i, commands)
#endif
	{
		List	   *plantree_list;
		List	   *querytree_list;
		RawStmt	   *command = (RawStmt *) lfirst(command_i);
		CommandTag	commandTag;
		Portal		portal;
		int			save_nestlevel;
		DestReceiver *receiver;

#ifdef PGXC
		cmdstr = (char *) lfirst(commandSourceQuery_i);
		errcallback.arg = cmdstr;
#endif

		/* temporarily push snapshot for parse analysis/planning */
		PushActiveSnapshot(GetTransactionSnapshot());

		oldcontext = MemoryContextSwitchTo(MessageContext);

		/*
		 * Set the current role to the user that executed the command on the
		 * origin server.
		 */
		save_nestlevel = NewGUCNestLevel();
		SetConfigOption("role", role, PGC_INTERNAL, PGC_S_OVERRIDE);

		commandTag = CreateCommandTag(command);

		/* check if it's a DDL statement. we only do this for in_spock_replicate_ddl_command */
		if (in_spock_replicate_ddl_command &&
			GetCommandLogLevel(command->stmt) != LOGSTMT_DDL)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					errmsg("spock.replicate_ddl() cannot execute %s statement",
							GetCommandTagName(commandTag))));
		}

		querytree_list = pg_analyze_and_rewrite(
			command,
			cmdstr,
			NULL, 0);

		plantree_list = pg_plan_queries(
			querytree_list, cmdstr, 0, NULL);

		PopActiveSnapshot();

		portal = CreatePortal("spock", true, true);
		PortalDefineQuery(portal, NULL,
						  cmdstr,
						  commandTag,
						  plantree_list, NULL);
		PortalStart(portal, NULL, 0, InvalidSnapshot);

		receiver = CreateDestReceiver(DestNone);

		(void) PortalRun(portal, FETCH_ALL,
						 isTopLevel,
						 receiver, receiver,
						 NULL);
		(*receiver->rDestroy) (receiver);

		PortalDrop(portal, false);

		CommandCounterIncrement();

		/*
		 * Restore the GUC variables we set above.
		 */
		AtEOXact_GUC(true, save_nestlevel);

		MemoryContextSwitchTo(oldcontext);
	}

	/* protect against stack resets during CONCURRENTLY processing */
	if (error_context_stack == &errcallback)
		error_context_stack = errcallback.previous;

	debug_query_string = save_debug_query_string;
}

/*
 * Load list of tables currently pending sync.
 *
 * Must be inside transaction.
 */
static void
reread_unsynced_tables(Oid subid)
{
	MemoryContext	saved_ctx;
	List		   *unsynced_tables;
	ListCell	   *lc;

	/* Cleanup first. */
	list_free_deep(SyncingTables);
	SyncingTables = NIL;

	/* Read new state. */
	unsynced_tables = get_unsynced_tables(subid);
	saved_ctx = MemoryContextSwitchTo(TopMemoryContext);
	foreach (lc, unsynced_tables)
	{
		SpockSyncStatus	   *sync = palloc(sizeof(SpockSyncStatus));
		memcpy(sync, lfirst(lc), sizeof(SpockSyncStatus));
		SyncingTables = lappend(SyncingTables, sync);
	}

	MemoryContextSwitchTo(saved_ctx);
}

static void
process_syncing_tables(XLogRecPtr end_lsn)
{
	ListCell	   *lc;

	Assert(CurrentMemoryContext == MessageContext);
	Assert(!IsTransactionState());

	/* First check if we need to update the cached information. */
	if (MyApplyWorker->sync_pending)
	{
		StartTransactionCommand();
		MyApplyWorker->sync_pending = false;
		reread_unsynced_tables(MyApplyWorker->subid);
		CommitTransactionCommand();
		MemoryContextSwitchTo(MessageContext);
	}

	/* Process currently pending sync tables. */
	if (list_length(SyncingTables) > 0)
	{
#if PG_VERSION_NUM < 130000
		ListCell	   *prev = NULL;
		ListCell	   *next;
#endif

#if PG_VERSION_NUM >= 130000
		foreach(lc, SyncingTables)
#else
		for (lc = list_head(SyncingTables); lc; lc = next)
#endif
		{
			SpockSyncStatus	   *sync = (SpockSyncStatus *) lfirst(lc);
			SpockSyncStatus	   *newsync;

#if PG_VERSION_NUM < 130000
			/* We might delete the cell so advance it now. */
			next = lnext(lc);
#endif

			StartTransactionCommand();
			newsync = get_table_sync_status(MyApplyWorker->subid,
										 NameStr(sync->nspname),
										 NameStr(sync->relname), true);

			/*
			 * TODO: what to do here? We don't really want to die,
			 * but this can mean many things, for now we just assume table is
			 * not relevant for us anymore and leave fixing to the user.
			 *
			 * The reason why this part happens in transaction is that the
			 * memory allocated for sync info will get automatically cleaned
			 * afterwards.
			 */
			if (!newsync)
			{
				sync->status = SYNC_STATUS_READY;
				sync->statuslsn = InvalidXLogRecPtr;
			}
			else
				memcpy(sync, newsync, sizeof(SpockSyncStatus));
			CommitTransactionCommand();
			MemoryContextSwitchTo(MessageContext);

			if (sync->status == SYNC_STATUS_SYNCWAIT)
			{
				SpockWorker *worker;

				LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
				worker = spock_sync_find(MyDatabaseId,
											 MyApplyWorker->subid,
											 NameStr(sync->nspname),
											 NameStr(sync->relname));

				if (spock_worker_running(worker) &&
					end_lsn >= worker->worker.apply.replay_stop_lsn)
				{
					worker->worker.apply.replay_stop_lsn = end_lsn;
					sync->status = SYNC_STATUS_CATCHUP;

					StartTransactionCommand();
					set_table_sync_status(MyApplyWorker->subid,
										  NameStr(sync->nspname),
										  NameStr(sync->relname),
										  sync->status,
										  sync->statuslsn);
					CommitTransactionCommand();
					MemoryContextSwitchTo(MessageContext);

					if (spock_worker_running(worker))
						SetLatch(&worker->proc->procLatch);
					LWLockRelease(SpockCtx->lock);

					if (wait_for_sync_status_change(MyApplyWorker->subid,
													NameStr(sync->nspname),
													NameStr(sync->relname),
													SYNC_STATUS_SYNCDONE,
													&sync->statuslsn))
						sync->status = SYNC_STATUS_SYNCDONE;
				}
				else
					LWLockRelease(SpockCtx->lock);
			}

			if (sync->status == SYNC_STATUS_SYNCDONE &&
				end_lsn >= sync->statuslsn)
			{
				sync->status = SYNC_STATUS_READY;
				sync->statuslsn = end_lsn;

				StartTransactionCommand();
				set_table_sync_status(MyApplyWorker->subid,
									  NameStr(sync->nspname),
									  NameStr(sync->relname),
									  sync->status,
									  sync->statuslsn);
				CommitTransactionCommand();
				MemoryContextSwitchTo(MessageContext);
			}

			/* Ready? Remove it from local cache. */
			if (sync->status == SYNC_STATUS_READY)
			{
#if PG_VERSION_NUM >= 130000
				SyncingTables = foreach_delete_current(SyncingTables, lc);
#else
				SyncingTables = list_delete_cell(SyncingTables, lc, prev);
#endif
				pfree(sync);
			}
			else
			{
#if PG_VERSION_NUM < 130000
				prev = lc;
#endif
			}
		}
	}

	/*
	 * If there are still pending tables for synchronization, launch the sync
	 * worker.
	 */
	foreach (lc, SyncingTables)
	{
		List		   *workers;
		ListCell	   *wlc;
		int				nworkers = 0;
		SpockSyncStatus	   *sync = (SpockSyncStatus *) lfirst(lc);

		if (sync->status == SYNC_STATUS_SYNCDONE || sync->status == SYNC_STATUS_READY)
			continue;

		LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
		workers = spock_sync_find_all(MyDatabaseId, MyApplyWorker->subid);
		foreach (wlc, workers)
		{
			SpockWorker	   *worker = (SpockWorker *) lfirst(wlc);

			if (spock_worker_running(worker))
				nworkers++;
		}
		LWLockRelease(SpockCtx->lock);

		if (nworkers < 1)
		{
			start_sync_worker(&sync->nspname, &sync->relname);
			break;
		}
	}

	Assert(CurrentMemoryContext == MessageContext);
}

static void
start_sync_worker(Name nspname, Name relname)
{
	SpockWorker			worker;

	/* Start the sync worker. */
	memset(&worker, 0, sizeof(SpockWorker));
	worker.worker_type = SPOCK_WORKER_SYNC;
	worker.dboid = MySpockWorker->dboid;
	worker.worker.apply.subid = MyApplyWorker->subid;
	worker.worker.apply.sync_pending = false; /* Makes no sense for sync worker. */

	/* Tell the worker to stop at current position. */
	worker.worker.sync.apply.replay_stop_lsn = replorigin_session_origin_lsn;
	memcpy(&worker.worker.sync.nspname, nspname, sizeof(NameData));
	memcpy(&worker.worker.sync.relname, relname, sizeof(NameData));

	(void) spock_worker_register(&worker);
}

static inline TimeOffset
interval_to_timeoffset(const Interval *interval)
{
	TimeOffset	span;

	span = interval->time;

#ifdef HAVE_INT64_TIMESTAMP
	span += interval->month * INT64CONST(30) * USECS_PER_DAY;
	span += interval->day * INT64CONST(24) * USECS_PER_HOUR;
#else
	span += interval->month * ((double) DAYS_PER_MONTH * SECS_PER_DAY);
	span += interval->day * ((double) HOURS_PER_DAY * SECS_PER_HOUR);
#endif

	return span;
}

void
spock_apply_main(Datum main_arg)
{
	int				slot = DatumGetInt32(main_arg);
	PGconn		   *streamConn;
	RepOriginId		originid;
	XLogRecPtr		origin_startpos;
	MemoryContext	saved_ctx;
	char		   *repsets;
	char		   *origins;

	/* Setup shmem. */
	spock_worker_attach(slot, SPOCK_WORKER_APPLY);
	Assert(MySpockWorker->worker_type == SPOCK_WORKER_APPLY);
	MyApplyWorker = &MySpockWorker->worker.apply;

	/* Attach to dsm segment. */
	Assert(CurrentResourceOwner == NULL);
	CurrentResourceOwner = ResourceOwnerCreate(NULL, "spock apply");

	/* Load correct apply API. */
	if (spock_use_spi)
	{
		if (spock_conflict_resolver != SPOCK_RESOLVE_ERROR)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("SPOCK %s: spock.use_spi can only be used when "
							"spock.conflict_resolution is set to 'error'",
							MySubscription->name)));

		apply_api.on_begin = spock_apply_spi_begin;
		apply_api.on_commit = spock_apply_spi_commit;
		apply_api.do_insert = spock_apply_spi_insert;
		apply_api.do_update = spock_apply_spi_update;
		apply_api.do_delete = spock_apply_spi_delete;
		apply_api.can_multi_insert = spock_apply_spi_can_mi;
		apply_api.multi_insert_add_tuple = spock_apply_spi_mi_add_tuple;
		apply_api.multi_insert_finish = spock_apply_spi_mi_finish;
	}

	/* Setup synchronous commit according to the user's wishes */
	SetConfigOption("synchronous_commit",
					spock_synchronous_commit ? "local" : "off",
					PGC_BACKEND, PGC_S_OVERRIDE);	/* other context? */

	/* Run as replica session replication role. */
	SetConfigOption("session_replication_role", "replica",
					PGC_SUSET, PGC_S_OVERRIDE);	/* other context? */

	/*
	 * Disable function body checks during replay. That's necessary because a)
	 * the creator of the function might have had it disabled b) the function
	 * might be search_path dependant and we don't fix the contents of
	 * functions.
	 */
	SetConfigOption("check_function_bodies", "off",
					PGC_INTERNAL, PGC_S_OVERRIDE);

	/* Load the subscription. */
	StartTransactionCommand();
	saved_ctx = MemoryContextSwitchTo(TopMemoryContext);
	MySubscription = get_subscription(MyApplyWorker->subid);
	MemoryContextSwitchTo(saved_ctx);

#ifdef XCP
	/*
	 * When runnin under XL, initialise the XL executor so that the datanode
	 * and coordinator information is initialised properly.
	 */
	InitMultinodeExecutor(false);
#endif
	CommitTransactionCommand();

	elog(LOG, "SPOCK %s: starting apply worker", MySubscription->name);

	/* Set apply delay if any. */
	if (MySubscription->apply_delay)
		apply_delay =
			interval_to_timeoffset(MySubscription->apply_delay) / 1000;

	/* If the subscription isn't initialized yet, initialize it. */
	spock_sync_subscription(MySubscription);

	elog(DEBUG1, "SPOCK %s: connecting to provider %s, dsn %s",
		 MySubscription->name,
		 MySubscription->origin->name, MySubscription->origin_if->dsn);

	/*
	 * Cache the queue relation id.
	 * TODO: invalidation
	 */
	StartTransactionCommand();
	QueueRelid = get_queue_table_oid();

	originid = replorigin_by_name(MySubscription->slot_name, false);
	elog(DEBUG2, "SPOCK %s: setting up replication origin %s (oid %u)",
		 MySubscription->name,
		 MySubscription->slot_name, originid);
	replorigin_session_setup(originid);
	replorigin_session_origin = originid;
	origin_startpos = replorigin_session_get_progress(false);

	/* Start the replication. */
	streamConn = spock_connect_replica(MySubscription->origin_if->dsn,
										   MySubscription->slot_name, NULL);

	repsets = stringlist_to_identifierstr(MySubscription->replication_sets);
	origins = stringlist_to_identifierstr(MySubscription->forward_origins);

	/*
	 * IDENTIFY_SYSTEM sets up some internal state on walsender so call it even
	 * if we don't (yet) want to use any of the results.
     */
	spock_identify_system(streamConn, NULL, NULL, NULL, NULL);

	spock_start_replication(streamConn, MySubscription->slot_name,
								origin_startpos, origins, repsets, NULL,
								MySubscription->force_text_transfer);
	pfree(repsets);

	CommitTransactionCommand();

	/*
	 * Do an initial leak check with reporting off; we don't want to see
	 * these results, just the later output from ADDED leak checks.
	 */
	VALGRIND_DISABLE_ERROR_REPORTING;
	VALGRIND_DO_LEAK_CHECK;
	VALGRIND_ENABLE_ERROR_REPORTING;

	apply_work(streamConn);

	PQfinish(streamConn);

	/* We should only get here if we received sigTERM */
	proc_exit(0);
}
