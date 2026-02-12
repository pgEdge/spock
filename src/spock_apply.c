/*-------------------------------------------------------------------------
 *
 * spock_apply.c
 * 		spock apply logic
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
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
#include "catalog/pg_inherits.h"
#include "catalog/catalog.h"

#include "commands/async.h"
#include "commands/dbcommands.h"
#include "commands/sequence.h"
#include "commands/tablecmds.h"

#include "executor/executor.h"

#include "libpq/pqformat.h"

#include "mb/pg_wchar.h"

#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"

#include "optimizer/planner.h"
#include "postmaster/interrupt.h"
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

#include "utils/builtins.h"

#include "utils/acl.h"
#include "utils/fmgroids.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/pg_lsn.h"
#include "utils/snapmgr.h"
#include "replication/syncrep.h"
#include "replication/walsender_private.h"

#include "spock_autoddl.h"
#include "spock_common.h"
#include "spock_conflict.h"
#include "spock_executor.h"
#include "spock_node.h"
#include "spock_proto_native.h"
#include "spock_queue.h"
#include "spock_relcache.h"
#include "spock_repset.h"
#include "spock_rpc.h"
#include "spock_sync.h"
#include "spock_worker.h"
#include "spock_apply.h"
#include "spock_apply_heap.h"
#include "spock_exception_handler.h"
#include "spock_common.h"
#include "spock_readonly.h"
#include "spock.h"


PGDLLEXPORT void spock_apply_main(Datum main_arg);

static bool in_remote_transaction = false;
static bool first_begin_at_startup = true;
static XLogRecPtr remote_origin_lsn = InvalidXLogRecPtr;
static RepOriginId remote_origin_id = InvalidRepOriginId;
static char *remote_origin_name = NULL;
static TimeOffset apply_delay = 0;
static TimestampTz required_commit_ts = 0;

/*
 * Cache for forwarded origin lookup. The remote_origin_id (Spock node ID)
 * is consistent across the cluster, so we can use it as a cache key to
 * avoid repeated slot name generation and origin lookups.
 */
static RepOriginId cached_forward_remote_id = InvalidRepOriginId;
static RepOriginId cached_forward_local_id = InvalidRepOriginId;

static Oid	QueueRelid = InvalidOid;

static List *SyncingTables = NIL;

SpockApplyWorker *MyApplyWorker = NULL;
SpockSubscription *MySubscription = NULL;
int			my_exception_log_index = -1;

static PGconn *applyconn = NULL;

typedef struct ApplyReplayEntryData ApplyReplayEntry;
struct ApplyReplayEntryData
{
	StringInfoData copydata;
	ApplyReplayEntry *next;
};
static MemoryContext ApplyReplayContext = NULL;
static ApplyReplayEntry * apply_replay_head = NULL;
static ApplyReplayEntry * apply_replay_tail = NULL;
static ApplyReplayEntry * apply_replay_next = NULL;
static int	apply_replay_bytes = 0;

/* Number of tuples inserted after which we switch to multi-insert. */
#define MIN_MULTI_INSERT_TUPLES 5
static SpockRelation *last_insert_rel = NULL;
static int	last_insert_rel_cnt = 0;
static bool use_multi_insert = false;

/*
 * A message counter for the xact, for debugging. We don't send
 * the remote change LSN with messages, so this aids identification
 * of which change causes an error.
 */
static uint32 xact_action_counter;

/*
 * Flag if trasaction had any exceptions for sub_disable handling
 * at commit time.
 */
static bool xact_had_exception = false;

typedef struct SPKFlushPosition
{
	dlist_node	node;
	XLogRecPtr	local_end;
	XLogRecPtr	remote_end;
} SPKFlushPosition;

static dlist_head lsn_mapping = DLIST_STATIC_INIT(lsn_mapping);

typedef struct ApplyExecState
{
	EState	   *estate;
	EPQState	epqstate;
	ResultRelInfo *resultRelInfo;
	TupleTableSlot *slot;
} ApplyExecState;

typedef struct ActionErrCallbackArg
{
	const char *action_name;
	SpockRelation *rel;
	bool		is_ddl_or_drop;
} ActionErrCallbackArg;

static ActionErrCallbackArg errcallback_arg;
TransactionId remote_xid;

/*
 * Structure of RemoteSyncPosition to Save the LSN in case of
 * Synchronous replica is attached
 */
typedef struct RemoteSyncPosition
{
	dlist_node	node;
	XLogRecPtr	recvpos;
	XLogRecPtr	flushpos;
	XLogRecPtr	writepos;
} RemoteSyncPosition;

/*
 * Queue of structure RemoteSyncPosition to Save the LSN in
 * case of Synchronous replica is attached
 */
static dlist_head sync_replica_lsn = DLIST_STATIC_INIT(sync_replica_lsn);

/*
 * We enable skipping all data modification changes (INSERT, UPDATE, etc.) for
 * the subscription if the remote transaction's finish LSN matches the sub_skip_lsn.
 * Once we start skipping changes, we don't stop it until we skip all changes of
 * the transaction even if spock.subscription is updated and MySubscription->skiplsn
 * gets changed or reset during that. The sub_skip_lsn is cleared after successfully
 * skipping the transaction or applying non-empty transaction. The latter prevents
 * the mistakenly specified sub_skip_lsn from being left.
 */
static XLogRecPtr skip_xact_finish_lsn = InvalidXLogRecPtr;
#define is_skipping_changes() (unlikely(!XLogRecPtrIsInvalid(skip_xact_finish_lsn)))

/*
 * Whereas MessageContext is used for the duration of a transaction,
 * ApplyOperationContext can be used for individual operations
 */
static MemoryContext ApplyOperationContext = NULL;

/* Functions for skipping changes */
static void maybe_start_skipping_changes(XLogRecPtr finish_lsn);
static void stop_skipping_changes(void);
static void clear_subscription_skip_lsn(XLogRecPtr finish_lsn);

static void multi_insert_finish(void);

static void handle_queued_message(HeapTuple msgtup, bool tx_just_started);
static void handle_startup_param(const char *key, const char *value);
static bool parse_bool_param(const char *key, const char *value);
static void process_syncing_tables(XLogRecPtr end_lsn);
static void start_sync_worker(Name nspname, Name relname);
static void spock_apply_worker_shmem_exit(int code, Datum arg);
static void spock_apply_worker_on_exit(int code, Datum arg);
static void spock_apply_worker_attach(void);
static void spock_apply_worker_detach(void);

static bool should_log_exception(bool failed);

static ApplyReplayEntry * apply_replay_entry_create(int r, char *buf);
static void apply_replay_entry_free(ApplyReplayEntry * entry);
static void apply_replay_queue_reset(void);
static void maybe_send_feedback(PGconn *applyconn, XLogRecPtr lsn_to_send,
								TimestampTz *last_receive_timestamp);
static void append_feedback_position(XLogRecPtr recvpos);
static void get_feedback_position(XLogRecPtr *recvpos, XLogRecPtr *writepos,
								  XLogRecPtr *flushpos, XLogRecPtr *max_recvpos);
static void UpdateWorkerStats(XLogRecPtr last_received, XLogRecPtr last_inserted);
static void maybe_advance_forwarded_origin(XLogRecPtr end_lsn, bool xact_had_exception);

/* Wrapper for latch for waiting for previous transaction to commit */
void
wait_for_previous_transaction(void)
{
	/*
	 * Sleep on a cv to be woken up once our the required predecessor has
	 * commited.
	 */
	for (;;)
	{
		/*
		 * If our immediate predecessor has been processed, then break this
		 * loop and process this transaction. Otherwise, wait for the
		 * predecessor to commit.
		 */
		if (apply_worker_get_prev_remote_ts() == required_commit_ts ||
			required_commit_ts == 0)
		{
			break;
		}

		CHECK_FOR_INTERRUPTS();

		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
		}

		/*
		 * The value of prev_remote_ts might be erroneous as it could have
		 * changed since we we last checked it.
		 */
		elog(DEBUG1, "SPOCK: slot-group '%s' WAIT for ts [current proccessed"
			 ", required] [" INT64_FORMAT ", " INT64_FORMAT "]",
			 MySubscription->slot_name,
			 apply_worker_get_prev_remote_ts(),
			 required_commit_ts);

		/* Latch */
		ConditionVariableTimedSleep(&MyApplyWorker->apply_group->prev_processed_cv,
									1,
									WAIT_EVENT_LOGICAL_APPLY_MAIN);
	}
	ConditionVariableCancelSleep();
}

/* Wrapper to wake up all waiters for previous transaction to commit */
void
awake_transaction_waiters(void)
{
	ConditionVariableBroadcast(&MyApplyWorker->apply_group->prev_processed_cv);
}

/*
 * This function returns true when:
 * - exception_logging is not equal to LOG_NONE, and
 *   - Subtransaction failed
 *   OR
 *   - Subtransaction succeeded, and
 *   - exception_behaviour is TRANSDISCARD | SUB_DISABLE or
 *     exception_logging is LOG_ALL
 */
static bool
should_log_exception(bool failed)
{
	if (exception_logging != LOG_NONE)
	{
		if (failed)
			return true;
		else if (exception_logging == LOG_ALL ||
				 exception_behaviour == TRANSDISCARD ||
				 exception_behaviour == SUB_DISABLE)
			return true;
	}

	return false;
}

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
		ListCell   *lc;

		foreach(lc, SyncingTables)
		{
			SpockSyncStatus *sync = (SpockSyncStatus *) lfirst(lc);

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
						  const char *action_name,
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
					 (uint32) (replorigin_session_origin_lsn >> 32),
					 (uint32) replorigin_session_origin_lsn,
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
						 (uint32) (remote_origin_lsn >> 32),
						 (uint32) remote_origin_lsn,
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

/*
 * Begin one step (one INSERT, UPDATE, etc) of a replication transaction.
 *
 * Start a transaction, if this is the first step (else we keep using the
 * existing transaction).
 * Also provide a global snapshot and ensure we run in ApplyMessageContext.
 */
static bool
begin_replication_step(void)
{
	bool		result = false;

	/*
	 * spock doesn't have "statements" as such, so we'll report one statement
	 * per applied transaction. We must set the statement start time because
	 * StartTransaction() uses it to initialize the transaction cached
	 * timestamp used by current_timestamp. If we don't set it, every xact
	 * will get the same current_timestamp. See 2ndQuadrant/spock_internal#148
	 */
	SetCurrentStatementStartTimestamp();

	if (!IsTransactionState())
	{
		StartTransactionCommand();
		spock_apply_heap_begin();
		result = true;
	}

	PushActiveSnapshot(GetTransactionSnapshot());

	return result;
}

/*
 * Finish up one step of a replication transaction.
 * Callers of begin_replication_step() must also call this.
 *
 * We don't close out the transaction here, but we should increment
 * the command counter to make the effects of this step visible.
 */
static void
end_replication_step(void)
{
	PopActiveSnapshot();

	CommandCounterIncrement();

	MemoryContextSwitchTo(MessageContext);
}

static void
handle_begin(StringInfo s)
{
	SpockExceptionLog *exception_log = NULL;
	SpockExceptionLog *new_elog_entry;
	XLogRecPtr	commit_lsn;
	TimestampTz commit_time;
	bool		slot_found = false;
	int			sub_name_len = strlen(MySubscription->name);
	char	   *slot_name;

	/*
	 * To get here we must have connected successfully and the replication
	 * stream is delivering the first transaction. At this point we switch to
	 * restart_delay_on_exception assuming that we are just replicating a
	 * transaction without exception handling.
	 */
	MySpockWorker->restart_delay = restart_delay_on_exception;

	xact_action_counter = 1;
	xact_had_exception = false;
	errcallback_arg.action_name = "BEGIN";

	spock_read_begin(s, &commit_lsn, &commit_time, &remote_xid);
	maybe_start_skipping_changes(commit_lsn);

	replorigin_session_origin_timestamp = commit_time;
	replorigin_session_origin_lsn = commit_lsn;
	remote_origin_id = InvalidRepOriginId;
	/*
	 * Free and clear remote_origin_name - it's allocated in TopMemoryContext
	 * to avoid MessageContext corruption issues.
	 */
	if (remote_origin_name != NULL)
	{
		pfree(remote_origin_name);
		remote_origin_name = NULL;
	}

	elog(DEBUG1, "SPOCK %s: current commit ts is: " INT64_FORMAT,
		 MySubscription->name,
		 replorigin_session_origin_timestamp);

	/*
	 * We either create a new shared memory struct in the error log for
	 * ourselves if it doesn't exist, or check the commit lsn of the existing
	 * entry. There are four cases here:
	 *
	 * 1. The error log is empty and we need to create a new slot anyway.
	 *
	 * 2. The error log is not empty, but we didn't find ourselves in any of
	 * the entries. We need to create a slot here as well.
	 *
	 * 3. The error log is not empty and we found our entry, but the commit
	 * lsn does not match. We simply update the commit lsn and move on. This
	 * case happens when we have not errored out previously.
	 *
	 * 4. The error log is not empty, we found our entry and the commit lsn.
	 * This would mean that we previously errored and restarted. We set the
	 * MyApplyWorker->use_try_block = true.
	 */

	if (first_begin_at_startup)
	{
		first_begin_at_startup = false;

		for (int i = 0; i <= SpockCtx->total_workers; i++)
		{
			exception_log = &exception_log_ptr[i];
			slot_name = NameStr(exception_log->slot_name);

			if (strncmp(slot_name, MySubscription->name, sub_name_len) == 0)
			{
				/* We found our slot in shared memory. */
				slot_found = true;
				my_exception_log_index = i;

				/*
				 * Break out out of the loop whether we've found the commit
				 * LSN or not since we have already found our slot
				 */
				break;
			}
		}

		if (!slot_found)
		{
			int			free_slot_index = -1;

			/*
			 * If we don't find ourselves in shared memory, then we get the
			 * pointer to the first free slot we remembered earlier, and fill
			 * in our slot name, commit_lsn and set local_tuple = NULL
			 */
			MyApplyWorker->use_try_block = false;

			/*
			 * Let's acquire an exclusive lock to ensure no changes are made
			 * by another process while we attempt to check again subscription
			 * name exists, if so, we'll take that. Otherwise, remember the
			 * first free slot index.
			 */
			LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);

			for (int i = 0; i <= SpockCtx->total_workers; i++)
			{
				exception_log = &exception_log_ptr[i];
				slot_name = NameStr(exception_log->slot_name);

				if (strncmp(slot_name, MySubscription->name, sub_name_len) == 0)
				{
					/* We found our slot in shared memory. */
					slot_found = true;
					my_exception_log_index = i;

					/*
					 * Break out out of the loop whether we've found the
					 * commit LSN or not since we have already found our slot
					 */
					break;
				}

				if (free_slot_index < 0 && strlen(slot_name) == 0)
				{
					free_slot_index = i;
				}
			}

			/* TODO: What to do if we can't find a free slot? */
			if (free_slot_index == -1)
			{
				/* no free entries found. */
				elog(ERROR, "SPOCK %s: unable to find an empty exception log slot.",
					 MySubscription->name);
			}

			/* We didn't find a slot, but we have a valid index. */
			if (!slot_found)
			{
				/*
				 * TODO: What happens if a subscription is dropped? Memory
				 * leak
				 */
				new_elog_entry = &exception_log_ptr[free_slot_index];
				namestrcpy(&new_elog_entry->slot_name, MySubscription->name);

				/*
				 * Redundant, since it's happening below. But we'll have it
				 * for now
				 */
				new_elog_entry->commit_lsn = commit_lsn;
				new_elog_entry->local_tuple = NULL;

				my_exception_log_index = free_slot_index;
			}

			/* We've occupied the free slot. Let's release the lock now. */
			LWLockRelease(SpockCtx->lock);
		}

		/*
		 * After first BEGIN, my_exception_log_index must be valid. This
		 * ensures exception handling can safely access exception_log_ptr.
		 */
		Assert(my_exception_log_index >= 0);
	}

	if (slot_found)
	{
		/*
		 * If we find our slot in shared memory, check for commit LSN
		 */
		Assert(exception_log);
		if (exception_log->commit_lsn == commit_lsn)
		{
			MyApplyWorker->use_try_block = true;

			elog(DEBUG1, "SPOCK %s: entering exception handling",
				 MySubscription->name);

			/*
			 * If we unexpectedly terminate again with error during exception
			 * handling, don't go into a fast error loop.
			 */
			MySpockWorker->restart_delay = restart_delay_default;
		}
	}

	exception_log = &exception_log_ptr[my_exception_log_index];
	exception_log->commit_lsn = commit_lsn;

	/* don't want the overhead otherwise */
	if (apply_delay > 0)
	{
		TimestampTz current;

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
	XLogRecPtr	commit_lsn;
	XLogRecPtr	end_lsn;
	TimestampTz commit_time;
	XLogRecPtr	remote_insert_lsn;

	errcallback_arg.action_name = "COMMIT";
	xact_action_counter++;

	spock_read_commit(s, &commit_lsn, &end_lsn, &commit_time, &remote_insert_lsn);

	/*
	 * For protocol version 4, remote_insert_lsn is read from the end of
	 * COMMIT message. For protocol version 5+, it's read at the beginning of
	 * all messages in apply_work.
	 */
	if (remote_insert_lsn != InvalidXLogRecPtr)
		UpdateWorkerStats(end_lsn, remote_insert_lsn);

	Assert(commit_time == replorigin_session_origin_timestamp);

	/* Wait for the previous transaction to commit */
	wait_for_previous_transaction();

	if (is_skipping_changes())
	{
		SpockExceptionLog *exception_log;

		stop_skipping_changes();

		/*
		 * Clear exception handling state since we successfully skipped the
		 * transaction. This prevents the code from treating the skipped
		 * transaction as a failure in SUB_DISABLE mode.
		 */
		if (MyApplyWorker->use_try_block)
		{
			exception_log = &exception_log_ptr[my_exception_log_index];
			exception_log->commit_lsn = InvalidXLogRecPtr;
			exception_log->initial_error_message[0] = '\0';
			MyApplyWorker->use_try_block = false;
			MySpockWorker->restart_delay = 0;

			elog(DEBUG1, "SPOCK %s: cleared exception handling state after successful skip",
				 MySubscription->name);
		}

		/*
		 * Start a new transaction to clear the subskiplsn, if not started
		 * yet.
		 */
		if (!IsTransactionState())
			StartTransactionCommand();
	}

	if (IsTransactionState())
	{
		SPKFlushPosition *flushpos;

		/*
		 * The transaction is either non-empty or skipped, so we clear the
		 * subskiplsn. Use replorigin_session_origin_lsn (BEGIN commit_lsn).
		 */
		clear_subscription_skip_lsn(replorigin_session_origin_lsn);

		multi_insert_finish();

		spock_apply_heap_commit();


		/*
		 * Advance the replication origin LSN to end_lsn. This LSN marks the
		 * position from which streaming will resume in case of a crash.
		 *
		 * Only update the origin LSN if there was no exception, or if the
		 * exception behavior is DISCARD or TRANSDISCARD. This ensures that
		 * replication resumes correctly without unintentionally skipping data
		 * after restarts or when a disabled subscription is re-enabled.
		 *
		 * Previously, due to an exception-handling change (commit:
		 * cfb1f5404d), replorigin_session_origin_lsn was being advanced even
		 * when a transaction failed. This caused the erroneous transaction to
		 * be skipped and made it unavailable when re-enabling the
		 * subscription. Skipping such transactions should be an explicit user
		 * action via spock.sub_alter_skiplsn.
		 */
		if (!xact_had_exception ||
			exception_behaviour == DISCARD ||
			exception_behaviour == TRANSDISCARD)
		{
			replorigin_session_origin_lsn = end_lsn;
		}

		/*
		 * Check if we're in TRANSDISCARD/SUB_DISABLE mode with no exceptions
		 * during replay. In this case, all DML operations were rolled back in
		 * their subtransactions (even successful retries), and we need to
		 * discard the entire transaction by aborting it instead of
		 * committing.
		 *
		 * This must be checked BEFORE committing the transaction.
		 */
		if (!xact_had_exception &&
			MyApplyWorker->use_try_block &&
			(exception_behaviour == TRANSDISCARD ||
			 exception_behaviour == SUB_DISABLE))
		{
			SpockExceptionLog *exception_log;
			char		errmsg[512];

			exception_log = &exception_log_ptr[my_exception_log_index];

			/*
			 * All operations were already rolled back in subtransactions (by
			 * RollbackAndReleaseCurrentSubTransaction in handle_insert/
			 * update/delete). Abort the parent transaction to discard it
			 * entirely.
			 */
			AbortCurrentTransaction();

			/*
			 * Start a new transaction to log the discard and update progress.
			 */
			StartTransactionCommand();
			PushActiveSnapshot(GetTransactionSnapshot());

			/*
			 * Log this transaction as discarded to the exception_log so
			 * there's an audit trail. Include the original error message if
			 * we have it.
			 */
			snprintf(errmsg, sizeof(errmsg),
					 "%s at LSN %X/%X%s%s",
					 (exception_behaviour == TRANSDISCARD)
					 ? "Transaction discarded in TRANSDISCARD mode"
					 : "Transaction failed, subscription will be disabled",
					 LSN_FORMAT_ARGS(end_lsn),
					 exception_log->initial_error_message[0] != '\0' ? ". Initial error: " : "",
					 exception_log->initial_error_message[0] != '\0' ? exception_log->initial_error_message : "");

			add_entry_to_exception_log(remote_origin_id,
									   commit_time,
									   remote_xid,
									   0, 0,
									   NULL, NULL, NULL, NULL,
									   NULL, NULL,
									   exception_log->initial_operation,
									   errmsg);

			elog(LOG, "SPOCK %s: %s", MySubscription->name, errmsg);

			/*
			 * Clear the exception state so we don't enter exception handling
			 * mode again on the next transaction.
			 */
			exception_log->commit_lsn = InvalidXLogRecPtr;
			exception_log->initial_error_message[0] = '\0';
			MySpockWorker->restart_delay = 0;
			PopActiveSnapshot();
			CommitTransactionCommand();

			/*
			 * For SUB_DISABLE mode, throw an error to trigger subscription
			 * disable in the parent PG_CATCH block. The transaction failure
			 * is already logged above.
			 */
			if (exception_behaviour == SUB_DISABLE)
			{
				elog(ERROR, "SPOCK %s: disabling subscription due to exception in SUB_DISABLE mode",
					 MySubscription->name);
			}

			/*
			 * Switch to MessageContext before continuing. The progress
			 * tracking code at transdiscard_skip_commit expects
			 * MessageContext.
			 */
			MemoryContextSwitchTo(MessageContext);

			/*
			 * Skip the normal commit path - jump to progress tracking.
			 */
			goto transdiscard_skip_commit;
		}

		/* Have the commit code adjust our logical clock if needed */
		remoteTransactionStopTimestamp = commit_time;

		CommitTransactionCommand();

		if (WalSndCtl->sync_standbys_status & SYNC_STANDBY_DEFINED)
			append_feedback_position(XactLastCommitEnd);

		remoteTransactionStopTimestamp = 0;

		MemoryContextSwitchTo(TopMemoryContext);

		if (xact_had_exception)
		{
			/*
			 * If we had exception(s) and are in SUB_DISABLE mode then the
			 * subscription got disabled earlier in the code path. We need to
			 * exit here to disconnect.
			 */
			if (exception_behaviour == SUB_DISABLE)
			{
				SpockExceptionLog *exception_log;

				exception_log = &exception_log_ptr[my_exception_log_index];
				exception_log->commit_lsn = InvalidXLogRecPtr;
				MySpockWorker->restart_delay = 0;

				elog(ERROR, "SPOCK %s: exiting because subscription disabled",
					 MySubscription->name);
			}
		}
		else if (MyApplyWorker->use_try_block &&
				 exception_log_ptr[my_exception_log_index].initial_error_message[0] != '\0')
		{
			/*
			 * In DISCARD mode with no exceptions, we don't log anything
			 * special (only operation-level failures are logged), but we
			 * should clear the saved error message to prevent it from leaking
			 * into future transactions.
			 */
			exception_log_ptr[my_exception_log_index].initial_error_message[0] = '\0';
		}

		/* Track commit lsn  */
		flushpos = (SPKFlushPosition *) palloc(sizeof(SPKFlushPosition));
		flushpos->local_end = XactLastCommitEnd;
		flushpos->remote_end = end_lsn;

		dlist_push_tail(&lsn_mapping, &flushpos->node);
		MemoryContextSwitchTo(MessageContext);
	}

	/*
	 * For forwarded transactions, advance the replication origin for the
	 * original source node. This is done outside the IsTransactionState()
	 * block because it starts its own transaction.
	 */
	maybe_advance_forwarded_origin(end_lsn, xact_had_exception);

transdiscard_skip_commit:
	/* Update the entry in the progress table. */
	elog(DEBUG1, "SPOCK %s: updating progress table for node_id %d" \
		 " and remote node id %d with remote commit ts" \
		 " to " INT64_FORMAT,
		 MySubscription->name,
		 MySubscription->target->id,
		 MySubscription->origin->id,
		 replorigin_session_origin_timestamp);

	{
		/* build new/update entry */
		SpockApplyProgress sap = {
			.key.dbid = MyDatabaseId,
			.key.node_id = MySubscription->target->id,
			.key.remote_node_id = MySubscription->origin->id,
			.remote_commit_ts = commit_time,
			.prev_remote_ts = replorigin_session_origin_timestamp,
			.remote_commit_lsn = commit_lsn,
			/* Ensure invariant: received_lsn >= remote_commit_lsn */
			.received_lsn = end_lsn,
			/*
			 * Include remote_insert_lsn for WAL persistence. This was already
			 * updated in shmem by UpdateWorkerStats() earlier (either from
			 * apply_work for protocol 5+, or from handle_commit for protocol 4).
			 * Without this, crash recovery would lose remote_insert_lsn.
			 */
			.remote_insert_lsn = MyApplyWorker->apply_group->progress.remote_insert_lsn,
			/* XXX: Could we use commit_ts value instead? */
			.last_updated_ts = GetCurrentTimestamp(),
			.updated_by_decode = true,
		};

		/* XXX: Don't care in production yet */
		Assert(sap.last_updated_ts >= sap.remote_commit_ts);

		/* WAL after commit, then to shmem */
		spock_apply_progress_add_to_wal(&sap);

		Assert(MyApplyWorker && MyApplyWorker->apply_group);

		spock_group_progress_update_ptr(MyApplyWorker->apply_group, &sap);
	}

	/* Wakeup all waiters for waiting for the previous transaction to commit */
	awake_transaction_waiters();

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
						(uint32) (end_lsn >> 32), (uint32) end_lsn,
						(uint32) (MyApplyWorker->replay_stop_lsn >> 32),
						(uint32) MyApplyWorker->replay_stop_lsn)));

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
		 * This needs to happen before the spock_sync_worker_finish() call
		 * otherwise slot drop will fail.
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

	/*
	 * This is the only place we can reset the use_try_block = false without
	 * any risk of going into the error deathloop
	 */
	MyApplyWorker->use_try_block = false;

	/* Reset the ApplyReplayContext and poiners */
	apply_replay_queue_reset();

	process_syncing_tables(end_lsn);

	pgstat_report_activity(STATE_IDLE, NULL);
}

/*
 * Handle ORIGIN message.
 */
static void
handle_origin(StringInfo s)
{
	errcallback_arg.action_name = "ORIGIN";

	/*
	 * ORIGIN message can only come inside remote transaction and before any
	 * actual writes.
	 */
	if (!in_remote_transaction || IsTransactionState())
		elog(ERROR, "SPOCK %s: ORIGIN message sent out of order",
			 MySubscription->name);

	/*
	 * Free previous origin name if any.
	 */
	if (remote_origin_name != NULL)
	{
		pfree(remote_origin_name);
		remote_origin_name = NULL;
	}

	/*
	 * Read the message and adjust the replorigin_session_origin to the real
	 * origin_id. PostgreSQL builtin logical replication uses the non-sensical
	 * roident, which is linked to the slot of the provider and has nothing to
	 * do with the actual origin of the original transaction.
	 *
	 * The origin_name is also read and stored for use in handle_commit() to
	 * advance the forwarded origin's LSN tracking.
	 */
	remote_origin_id = spock_read_origin(s, &remote_origin_lsn, &remote_origin_name);
	replorigin_session_origin = remote_origin_id;
}

/*
 * Handle LAST commit ts message.
 */
static void
handle_commit_order(StringInfo s)
{
	errcallback_arg.action_name = "COMMIT_ORDER";

	/*
	 * LAST commit ts message can only come inside remote transaction,
	 * immediately after origin information, and before any actual writes.
	 */
	if (!in_remote_transaction || IsTransactionState()
		|| replorigin_session_origin == InvalidRepOriginId)
		elog(ERROR, "SPOCK %s: LATEST commit order message sent out of order",
			 MySubscription->name);

	/*
	 * Read the message and adjust the locally maintained last commit ts. We
	 * don't need to track the origin here since we can only apply changes
	 * from one origin.
	 */
	required_commit_ts = spock_read_commit_order(s);

	elog(DEBUG1, "SPOCK: slot-group '%s' previous commit ts received: "
		 INT64_FORMAT " - commit ts " INT64_FORMAT,
		 MySubscription->slot_name,
		 required_commit_ts,
		 replorigin_session_origin_timestamp);
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
	errcallback_arg.action_name = "RELATION";

	/* Let's wait to avoid concurrent updates to spock cache */
	wait_for_previous_transaction();

	multi_insert_finish();

	(void) spock_read_rel(s);
}

static void
log_insert_exception(bool failed, char *errmsg, SpockRelation *rel,
					 SpockTupleData *oldtup, SpockTupleData *newtup,
					 const char *action_name)
{
	RepOriginId local_origin = InvalidRepOriginId;
	TimestampTz local_commit_ts = 0;
	TransactionId xmin = InvalidTransactionId;
	bool		local_origin_found = false;
	HeapTuple	localtup;

	if (!should_log_exception(failed))
		return;

	localtup = exception_log_ptr[my_exception_log_index].local_tuple;
	if (localtup != NULL)
	{
		local_origin_found = get_tuple_origin(rel, localtup,
											  &(localtup->t_self),
											  &xmin,
											  &local_origin,
											  &local_commit_ts);

		if (local_origin_found && local_origin == 0)
		{
			SpockLocalNode *local_node = get_local_node(false, false);

			local_origin = local_node->node->id;
		}
	}

	add_entry_to_exception_log(remote_origin_id,
							   replorigin_session_origin_timestamp,
							   remote_xid,
							   local_origin, local_commit_ts,
							   rel, localtup, oldtup, newtup,
							   NULL, NULL,
							   action_name,
							   errmsg);
}

static void
handle_insert(StringInfo s)
{
	SpockTupleData newtup;
	SpockRelation *rel;
	ErrorData  *edata = NULL;
	MemoryContext oldcontext;
	bool		started_tx;
	bool		failed = false;

	/*
	 * Quick return if we are skipping data modification changes.
	 */
	if (is_skipping_changes())
		return;

	oldcontext = MemoryContextSwitchTo(ApplyOperationContext);

	started_tx = begin_replication_step();

	rel = spock_read_insert(s, RowExclusiveLock, &newtup);
	if (unlikely(rel == NULL))
	{
		Assert(MyApplyWorker->use_try_block);

		/*
		 * Correctly interrupt the process: set exception flag and log the
		 * exception itself.
		 */
		xact_had_exception = true;
		exception_command_counter++;
		log_insert_exception(true, "Spock can't find relation", NULL,
							 NULL, NULL, "INSERT");
		end_replication_step();
		MemoryContextSwitchTo(oldcontext);
		MemoryContextReset(ApplyOperationContext);
		return;
	}

	errcallback_arg.action_name = "INSERT";
	errcallback_arg.rel = rel;
	xact_action_counter++;

	/* If in list of relations which are being synchronized, skip. */
	if (!should_apply_changes_for_rel(rel->nspname, rel->relname))
	{
		spock_relation_close(rel, NoLock);
		end_replication_step();
		MemoryContextSwitchTo(oldcontext);
		MemoryContextReset(ApplyOperationContext);
		return;
	}

	/*
	 * Handle multi_insert capabilities. TODO: Don't do multi- or
	 * batch-inserts when in use_try_block mode
	 */
	if (use_multi_insert && MyApplyWorker->use_try_block == false)
	{
		if (rel != last_insert_rel)
		{
			multi_insert_finish();
			/* Fall through to normal insert. */
		}
		else
		{
			spock_apply_heap_mi_add_tuple(rel, &newtup);
			last_insert_rel_cnt++;

			/*
			 * Close replication step to satisfy corresponding 'begin' routine.
			 * TODO: multi-insert code should be revised one day: it is not
			 * obvious why we push and pop transactional snapshot on each tuple
			 * as well as how command counter increment really works here in
			 * absence of actual INSERT - following update may need to refer
			 * this tuple and what's then?
			 */
			end_replication_step();

			MemoryContextSwitchTo(oldcontext);
			MemoryContextReset(ApplyOperationContext);
			return;
		}
	}
	else if (spock_batch_inserts &&
			 RelationGetRelid(rel->rel) != QueueRelid &&
			 spock_apply_heap_can_mi(rel) &&
			 MyApplyWorker->use_try_block == false)
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

	/* TODO: Handle multiple inserts */
	if (MyApplyWorker->use_try_block)
	{
		PG_TRY();
		{
			exception_command_counter++;
			BeginInternalSubTransaction(NULL);
			spock_apply_heap_insert(rel, &newtup);
		}
		PG_CATCH();
		{
			failed = true;
			RollbackAndReleaseCurrentSubTransaction();
			edata = CopyErrorData();
			xact_had_exception = true;
		}
		PG_END_TRY();

		if (!failed)
		{
			if (exception_behaviour == TRANSDISCARD ||
				exception_behaviour == SUB_DISABLE)
				RollbackAndReleaseCurrentSubTransaction();
			else
				ReleaseCurrentSubTransaction();
		}

		/*
		 * Log the exception. If this operation succeeded but we have an
		 * initial error message (from a previous attempt), use that instead
		 * of NULL to provide context for why we're logging this.
		 */
		{
			char	   *error_msg = edata ? edata->message :
				(exception_log_ptr[my_exception_log_index].initial_error_message[0] ?
				 exception_log_ptr[my_exception_log_index].initial_error_message : NULL);

			log_insert_exception(failed, error_msg, rel, NULL, &newtup, "INSERT");
		}
	}
	else
	{
		MemoryContextSwitchTo(ApplyOperationContext);
		spock_apply_heap_insert(rel, &newtup);
		MemoryContextSwitchTo(oldcontext);
	}

	/* if INSERT was into our queue, process the message. */
	if (RelationGetRelid(rel->rel) == QueueRelid)
	{
		HeapTuple	ht;
		LockRelId	lockid = rel->rel->rd_lockInfo.lockRelId;
		Relation	qrel;

		multi_insert_finish();

		MemoryContextSwitchTo(ApplyOperationContext);

		ht = heap_form_tuple(RelationGetDescr(rel->rel),
							 newtup.values, newtup.nulls);

		LockRelationIdForSession(&lockid, RowExclusiveLock);
		spock_relation_close(rel, NoLock);

		end_replication_step();

		spock_apply_heap_commit();

		handle_queued_message(ht, started_tx);

		heap_freetuple(ht);

		qrel = table_open(QueueRelid, RowExclusiveLock);

		UnlockRelationIdForSession(&lockid, RowExclusiveLock);

		table_close(qrel, NoLock);

		spock_apply_heap_begin();
		MemoryContextSwitchTo(MessageContext);
	}
	else
	{
		spock_relation_close(rel, NoLock);
		end_replication_step();
	}
	MemoryContextSwitchTo(MessageContext);
	MemoryContextReset(ApplyOperationContext);
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

		spock_apply_heap_mi_finish(last_insert_rel);
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
	SpockTupleData oldtup;
	SpockTupleData newtup;
	SpockRelation *rel;
	ErrorData  *edata = NULL;
	bool		hasoldtup;
	bool		failed = false;

	/*
	 * Quick return if we are skipping data modification changes.
	 */
	if (is_skipping_changes())
		return;

	begin_replication_step();

	errcallback_arg.action_name = "UPDATE";
	xact_action_counter++;

	multi_insert_finish();

	rel = spock_read_update(s, RowExclusiveLock, &hasoldtup, &oldtup, &newtup);
	if (unlikely(rel == NULL))
	{
		Assert(MyApplyWorker->use_try_block);

		/*
		 * Correctly interrupt the process: set exception flag and log the
		 * exception itself.
		 */
		xact_had_exception = true;
		exception_command_counter++;

		/*
		 * NOTE: Considering that the apply worker regularly reset
		 * MessageContext that contains local tuple, it make sense to
		 * centralyze management of an exception log slot.
		 */
		exception_log_ptr[my_exception_log_index].local_tuple = NULL;

		log_insert_exception(true, "Spock can't find relation", NULL,
							 NULL, NULL, "UPDATE");
		end_replication_step();
		return;
	}

	errcallback_arg.rel = rel;

	/* If in list of relations which are being synchronized, skip. */
	if (!should_apply_changes_for_rel(rel->nspname, rel->relname))
	{
		spock_relation_close(rel, NoLock);
		end_replication_step();
		return;
	}

	if (MyApplyWorker->use_try_block == true)
	{
		PG_TRY();
		{
			exception_command_counter++;
			BeginInternalSubTransaction(NULL);
			spock_apply_heap_update(rel, hasoldtup ? &oldtup : &newtup, &newtup);
		}
		PG_CATCH();
		{
			failed = true;
			RollbackAndReleaseCurrentSubTransaction();
			edata = CopyErrorData();
			xact_had_exception = true;
		}
		PG_END_TRY();

		if (!failed)
		{
			if (exception_behaviour == TRANSDISCARD ||
				exception_behaviour == SUB_DISABLE)
				RollbackAndReleaseCurrentSubTransaction();
			else
				ReleaseCurrentSubTransaction();
		}

		/*
		 * Log the exception. If this operation succeeded but we have an
		 * initial error message (from a previous attempt), use that instead
		 * of NULL to provide context for why we're logging this.
		 */
		{
			char	   *error_msg = edata ? edata->message :
				(exception_log_ptr[my_exception_log_index].initial_error_message[0] ?
				 exception_log_ptr[my_exception_log_index].initial_error_message : NULL);

			log_insert_exception(failed, error_msg, rel,
								 hasoldtup ? &oldtup : NULL, &newtup, "UPDATE");
		}
	}
	else
	{
		spock_apply_heap_update(rel, hasoldtup ? &oldtup : &newtup, &newtup);
	}

	spock_relation_close(rel, NoLock);

	end_replication_step();
}

static void
handle_delete(StringInfo s)
{
	SpockTupleData oldtup;
	SpockRelation *rel;
	ErrorData  *edata = NULL;
	bool		failed = false;

	/*
	 * Quick return if we are skipping data modification changes.
	 */
	if (is_skipping_changes())
		return;

	memset(&errcallback_arg, 0, sizeof(struct ActionErrCallbackArg));
	errcallback_arg.action_name = "DELETE";
	xact_action_counter++;

	begin_replication_step();

	multi_insert_finish();

	rel = spock_read_delete(s, RowExclusiveLock, &oldtup);
	if (unlikely(rel == NULL))
	{
		Assert(MyApplyWorker->use_try_block);

		/*
		 * Correctly interrupt the process: set exception flag and log the
		 * exception itself.
		 */
		xact_had_exception = true;
		exception_command_counter++;

		/*
		 * NOTE: Considering that the apply worker regularly reset
		 * MessageContext that contains local tuple, it make sense to
		 * centralyze management of an exception log slot.
		 */
		exception_log_ptr[my_exception_log_index].local_tuple = NULL;

		log_insert_exception(true, "Spock can't find relation", NULL,
							 NULL, NULL, "DELETE");
		end_replication_step();
		return;
	}

	errcallback_arg.rel = rel;

	/* If in list of relations which are being synchronized, skip. */
	if (!should_apply_changes_for_rel(rel->nspname, rel->relname))
	{
		spock_relation_close(rel, NoLock);
		end_replication_step();
		return;
	}

	if (MyApplyWorker->use_try_block)
	{
		PG_TRY();
		{
			exception_command_counter++;
			BeginInternalSubTransaction(NULL);
			spock_apply_heap_delete(rel, &oldtup);
		}
		PG_CATCH();
		{
			failed = true;
			RollbackAndReleaseCurrentSubTransaction();
			edata = CopyErrorData();
			xact_had_exception = true;
		}
		PG_END_TRY();

		if (!failed)
		{
			if (exception_behaviour == TRANSDISCARD ||
				exception_behaviour == SUB_DISABLE)
				RollbackAndReleaseCurrentSubTransaction();
			else
				ReleaseCurrentSubTransaction();
		}

		/*
		 * Log the exception. If this operation succeeded but we have an
		 * initial error message (from a previous attempt), use that instead
		 * of NULL to provide context for why we're logging this.
		 */
		{
			char	   *error_msg = edata ? edata->message :
				(exception_log_ptr[my_exception_log_index].initial_error_message[0] ?
				 exception_log_ptr[my_exception_log_index].initial_error_message : NULL);

			log_insert_exception(failed, error_msg, rel,
								 &oldtup, NULL, "DELETE");
		}
	}
	else
	{
		spock_apply_heap_delete(rel, &oldtup);
	}

	spock_relation_close(rel, NoLock);

	end_replication_step();
}

/*
 * Handle TRUNCATE
 */
static void
handle_truncate(StringInfo s)
{
	bool		cascade = false;
	bool		restart_seqs = false;
	List	   *remote_relids = NIL;
	List	   *remote_rels = NIL;
	List	   *rels = NIL;
	List	   *part_rels = NIL;
	List	   *relids = NIL;
	List	   *relids_logged = NIL;
	ListCell   *lc;
	LOCKMODE	lockmode = AccessExclusiveLock;

	/*
	 * Quick return if we are skipping data modification changes.
	 */
	if (is_skipping_changes())
		return;

	begin_replication_step();

	errcallback_arg.action_name = "TRUNCATE";
	remote_relids = spock_read_truncate(s, &cascade, &restart_seqs);

	foreach(lc, remote_relids)
	{
		SpockRelation *rel;
		Oid			relid = lfirst_oid(lc);

		rel = spock_relation_open(relid, lockmode);
		if (rel == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_TABLE),
					 errmsg("Spock can't find relation with oid %u", relid)));

		errcallback_arg.rel = rel;

		/* If in list of relations which are being synchronized, skip. */
		if (!should_apply_changes_for_rel(rel->nspname, rel->relname))
		{
			spock_relation_close(rel, NoLock);
			continue;
		}

		remote_rels = lappend(remote_rels, rel);
		rels = lappend(rels, rel->rel);
		relids = lappend_oid(relids, rel->reloid);
		if (RelationIsLogicallyLogged(rel->rel))
			relids_logged = lappend_oid(relids_logged, rel->reloid);

		/*
		 * Truncate partitions if we got a message to truncate a partitioned
		 * table.
		 */
		if (rel->rel->rd_rel->relkind == RELKIND_PARTITIONED_TABLE)
		{
			ListCell   *child;
			List	   *children = find_all_inheritors(rel->reloid,
													   lockmode,
													   NULL);

			foreach(child, children)
			{
				Oid			childrelid = lfirst_oid(child);
				Relation	childrel;

				if (list_member_oid(relids, childrelid))
					continue;

				/* find_all_inheritors already got lock */
				childrel = table_open(childrelid, NoLock);

				/*
				 * Ignore temp tables of other backends.  See similar code in
				 * ExecuteTruncate().
				 */
				if (RELATION_IS_OTHER_TEMP(childrel))
				{
					table_close(childrel, lockmode);
					continue;
				}

				rels = lappend(rels, childrel);
				part_rels = lappend(part_rels, childrel);
				relids = lappend_oid(relids, childrelid);
				/* Log this relation only if needed for logical decoding */
				if (RelationIsLogicallyLogged(childrel))
					relids_logged = lappend_oid(relids_logged, childrelid);
			}
		}
	}

	/*
	 * Even if we used CASCADE on the upstream primary we explicitly default
	 * to replaying changes without further cascading. This might be later
	 * changeable with a user specified option.
	 */
	ExecuteTruncateGuts(rels,
						relids,
						relids_logged,
						DROP_RESTRICT,
						restart_seqs,
						false);
	foreach(lc, remote_rels)
	{
		SpockRelation *rel = lfirst(lc);

		spock_relation_close(rel, NoLock);
	}
	foreach(lc, part_rels)
	{
		Relation	rel = lfirst(lc);

		table_close(rel, NoLock);
	}

	end_replication_step();
}

inline static bool
getmsgisend(StringInfo msg)
{
	return msg->cursor == msg->len;
}

static void
handle_startup(StringInfo s)
{
	uint8		msgver;

	errcallback_arg.action_name = "STARTUP";

	msgver = pq_getmsgbyte(s);

	if (msgver != SPOCK_STARTUP_MSG_FORMAT_FLAT)
		elog(ERROR, "SPOCK %s: Expected startup message version %u, but got %u",
			 MySubscription->name, SPOCK_STARTUP_MSG_FORMAT_FLAT, msgver);

	/*
	 * The startup message consists of null-terminated strings as key/value
	 * pairs. The first entry is always the format identifier.
	 */
	do
	{
		const char *k,
				   *v;

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

	Assert(MyApplyWorker->apply_group != NULL);

	/* Register callback for cleaning up */
	before_shmem_exit(spock_apply_worker_shmem_exit, 0);
	on_proc_exit(spock_apply_worker_on_exit, 0);
}

/*
 * Cleanup called on before_shmem_exit
 */
static void
spock_apply_worker_shmem_exit(int code, Datum arg)
{
	/*
	 * Reset replication session to avoid reuse after an error. This is done
	 * in a before_shmem_exit callback instead of on_proc_exit because the
	 * backend may also clean up the origin in certain cases, and we want to
	 * avoid duplicate cleanup.
	 */
	replorigin_session_origin = InvalidRepOriginId;
	replorigin_session_origin_lsn = InvalidXLogRecPtr;
	replorigin_session_origin_timestamp = 0;
}

/*
 * Cleanup called on proc_exit
 */
static void
spock_apply_worker_on_exit(int code, Datum arg)
{
	spock_apply_worker_detach();
}

/* Attach a worker to a group. */
static void
spock_apply_worker_attach(void)
{
	if (MyApplyWorker->apply_group != NULL)
		return;

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_EXCLUSIVE);

	/* Set the values in shared memory for this dbid-origin */
	MyApplyWorker->apply_group = spock_group_attach(MySpockWorker->dboid,
													MySubscription->target->id,
													MySubscription->origin->id);

	Assert(MyApplyWorker->apply_group != NULL);
	LWLockRelease(SpockCtx->apply_group_master_lock);
}

/* Remove a worker from it's group. */
static void
spock_apply_worker_detach(void)
{
	spock_group_detach();
}

static bool
parse_bool_param(const char *key, const char *value)
{
	bool		result;

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
		int			encoding = pg_char_to_encoding(value);

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
		bool		fwd = parse_bool_param(key, value);

		/* FIXME: Store this somewhere */
		elog(DEBUG1, "SPOCK %s: changeset origin forwarding enabled: %s",
			 MySubscription->name, fwd ? "t" : "f");
	}

	/*
	 * Extract the negotiated protocol version from the publisher. This is the
	 * protocol version the publisher decided to use based on what both sides
	 * support. The subscriber must use this version when reading messages.
	 */
	if (strcmp(key, "proto_version") == 0)
	{
		uint32		proto_version;
		char	   *endptr;

		errno = 0;
		proto_version = strtoul(value, &endptr, 10);

		if (errno != 0 || *endptr != '\0')
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("SPOCK %s: invalid proto_version value: %s",
							MySubscription->name, value)));

		/* Set the protocol version for the subscriber */
		spock_apply_set_proto_version(proto_version);

		elog(LOG, "SPOCK %s: using protocol version %u from publisher",
			 MySubscription->name, proto_version);
	}

	/*
	 * We just ignore a bunch of parameters here because we specify what we
	 * require when we send our params to the upstream. It's required to ERROR
	 * if it can't match what we asked for. It may send the startup message
	 * first, but it'll be followed by an ERROR if it does. There's no need to
	 * check params we can't do anything about mismatches of, like protocol
	 * versions and type sizes.
	 */
}

static RangeVar *
parse_relation_message(Jsonb *message)
{
	JsonbIterator *it;
	JsonbValue	v;
	int			r;
	int			level = 0;
	char	   *key = NULL;
	char	  **parse_res = NULL;
	char	   *nspname = NULL;
	char	   *relname = NULL;

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
 * Handle TABLESYNC message comming via queue table.
 */
static void
handle_table_sync(QueuedMessage *queued_message)
{
	RangeVar   *rv;
	MemoryContext oldcontext;
	SpockSyncStatus *oldsync;
	SpockSyncStatus *newsync;

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
	Jsonb	   *message = queued_message->message;
	JsonbIterator *it;
	JsonbValue	v;
	int			r;
	int			level = 0;
	char	   *key = NULL;
	char	  **parse_res = NULL;
	char	   *nspname = NULL;
	char	   *relname = NULL;
	char	   *last_value_raw = NULL;
	int64		last_value;
	Oid			nspoid;
	Oid			reloid;

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
	last_value = pg_strtoint64(last_value_raw);

	DirectFunctionCall2(setval_oid, ObjectIdGetDatum(reloid),
						Int64GetDatum(last_value));
}

/*
 * Handle SQL message comming via queue table.
 */
static void
handle_sql(QueuedMessage *queued_message, bool tx_just_started, char **sql)
{
	JsonbIterator *it;
	JsonbValue	v;
	int			r;
	MemoryContext oldctx;

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

	oldctx = MemoryContextSwitchTo(MessageContext);
	*sql = pnstrdup(v.val.string.val, v.val.string.len);
	MemoryContextSwitchTo(oldctx);

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

	/* Run the extracted SQL. */
	spock_execute_sql_command(*sql, queued_message->role, tx_just_started);
}

/*
 * Handle SQL message comming via queue table.
 */
static void
handle_sql_or_exception(QueuedMessage *queued_message, bool tx_just_started)
{
	bool		failed = false;
	char	   *sql = NULL;
	ErrorData  *edata = NULL;

	/*
	 * Start transaction before making any changes to Spock's internal state.
	 */
	begin_replication_step();
	errcallback_arg.action_name = "SQL";

	/*
	 * This is likely to be a DDL. So let's wait here before we acquire any
	 * exclusive locks that may conflict with other DDLs.
	 */
	wait_for_previous_transaction();

	if (MyApplyWorker->use_try_block)
	{
		PG_TRY();
		{
			exception_command_counter++;
			BeginInternalSubTransaction(NULL);
			handle_sql(queued_message, tx_just_started, &sql);
		}
		PG_CATCH();
		{
			failed = true;
			RollbackAndReleaseCurrentSubTransaction();
			edata = CopyErrorData();
			xact_had_exception = true;
		}
		PG_END_TRY();

		if (!failed)
		{
			/*
			 * Follow spock.exception_behavior GUC instead of restarting
			 * worker
			 */
			if (exception_behaviour == TRANSDISCARD ||
				exception_behaviour == SUB_DISABLE)
				RollbackAndReleaseCurrentSubTransaction();
			else
				ReleaseCurrentSubTransaction();
		}

		/* Let's create an exception log entry if true. */
		if (should_log_exception(failed))
		{
			/*
			 * Use current error message if operation failed, otherwise use
			 * initial_error_message for context (e.g., in DISCARD mode when
			 * SQL succeeds but we're logging it because of a previous error).
			 */
			char	   *error_msg = failed ? edata->message :
				(my_exception_log_index >= 0 &&
				 exception_log_ptr[my_exception_log_index].initial_error_message[0] != '\0' ?
				 exception_log_ptr[my_exception_log_index].initial_error_message : NULL);

			add_entry_to_exception_log(remote_origin_id,
									   replorigin_session_origin_timestamp,
									   remote_xid,
									   0, 0,
									   NULL, NULL, NULL, NULL,
									   sql, queued_message->role,
									   "SQL",
									   error_msg);
		}
	}
	else
	{
		handle_sql(queued_message, tx_just_started, &sql);
	}

	end_replication_step();
}

/*
 * Handles messages comming from the queue.
 */
static void
handle_queued_message(HeapTuple msgtup, bool tx_just_started)
{
	QueuedMessage *queued_message;
	const char *old_action_name;

	old_action_name = errcallback_arg.action_name;
	errcallback_arg.is_ddl_or_drop = true;

	queued_message = queued_message_from_tuple(msgtup);

	switch (queued_message->message_type)
	{
		case QUEUE_COMMAND_TYPE_DDL:
			in_spock_queue_ddl_command = true;
			/* fallthrough */
		case QUEUE_COMMAND_TYPE_SQL:
			errcallback_arg.action_name = "QUEUED_SQL";
			handle_sql_or_exception(queued_message, tx_just_started);
			in_spock_queue_ddl_command = false;
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
handle_message(StringInfo s)
{
	TransactionId xid;
	XLogRecPtr	lsn;
	bool		transactional;
	const char *prefix;
	const char *temp;
	int32		mtype;
	Size		sz;

	errcallback_arg.action_name = "MESSAGE";

	/* read fields */
	xid = pq_getmsgint(s, sizeof(int32));
	(void) xid;					/* unused */

	lsn = pq_getmsgint64(s);
	transactional = pq_getmsgbyte(s);
	prefix = pq_getmsgstring(s);
	if (lsn == InvalidXLogRecPtr || !transactional ||
		strcmp(prefix, SPOCK_MESSAGE_PREFIX) != 0)

		/*
		 * Should never happen. It means the protocol breach. Stop replication
		 * immediately. Do not send the instance into reboot to let
		 * applications be served.
		 */
		elog(FATAL, "incorrect spock message");

	sz = pq_getmsgint(s, sizeof(int32));
	temp = (char *) pq_getmsgbytes(s, sz);
	mtype = ((SpockWalMessageSimple *) temp)->mtype;

	switch (mtype)
	{
		case SPOCK_SYNC_EVENT_MSG:
			{
				/* consume message data */
				SpockSyncEventMessage msg;

				(void) msg;		/* unused */

				/*
				 * Do nothing. The main idea is to update the progress status.
				 * This message must be transactional. That means if we see it
				 * here, the transaction has been committed on the publisher
				 * and delivered to the subscriber (note: not exactly for
				 * streaming mode). The progress status will eventually be
				 * updated in the commit section of this transaction.
				 */
			}
			break;

		default:
			elog(ERROR, "Spock custom WAL message: unknown message type %d", mtype);
			break;
	}
}

static void
replication_handler(StringInfo s)
{
	ErrorContextCallback errcallback;
	char		action = pq_getmsgbyte(s);

	if (spock_readonly == READONLY_ALL)
		elog(ERROR, "SPOCK %s: cluster is in read-only mode, not performing replication",
			 MySubscription->name);

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
			/* LAST commit ts */
		case 'L':
			handle_commit_order(s);
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
			/* TRUNCATE */
		case 'T':
			handle_truncate(s);
			break;
			/* STARTUP MESSAGE */
		case 'S':
			handle_startup(s);
			break;
			/* GENERIC MESSAGE */
		case 'M':
			handle_message(s);
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
	XLogRecPtr	local_flush = GetFlushRecPtr(NULL);

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
 * If a synchronous replica is attached, in code we set synchronous commit off.
 * This can be dangerous because feedback might be sent before receiving
 * acknowledgment from the remote synchronous replica. To handle this,
 * a list of locally committed LSNs is maintained. Feedback is delayed
 * until acknowledgment is received from the remote synchronous replica,
 * thus avoiding blocking the transaction while ensuring data consistency.
 */
static void
append_feedback_position(XLogRecPtr recvpos)
{
	XLogRecPtr	writepos;
	XLogRecPtr	flushpos;
	RemoteSyncPosition *syncpos;
	MemoryContext oldctx;

	Assert(WalSndCtl->sync_standbys_status & SYNC_STANDBY_DEFINED);

	if (get_flush_position(&writepos, &flushpos))
	{
		/*
		 * No outstanding transactions to flush, we can report the latest
		 * received position. This is important for synchronous replication.
		 */
		flushpos = writepos = recvpos;
	}

	/* Ensure that we are allocating in the top memory context */
	oldctx = MemoryContextSwitchTo(TopMemoryContext);
	syncpos = (RemoteSyncPosition *) palloc0(sizeof(RemoteSyncPosition));
	MemoryContextSwitchTo(oldctx);

	syncpos->recvpos = recvpos;
	syncpos->writepos = writepos;
	syncpos->flushpos = flushpos;
	dlist_push_tail(&sync_replica_lsn, &syncpos->node);
	elog(DEBUG2, "SPOCK %s: appended feedback to list %X/%X, write %X/%X, flush %X/%X",
		 MySubscription->name,
		 (uint32) (recvpos >> 32), (uint32) recvpos,
		 (uint32) (writepos >> 32), (uint32) writepos,
		 (uint32) (flushpos >> 32), (uint32) flushpos
		);
}

/*
 * As we have maintained a list of LSNs that are waiting for
 * acknowledgment from the synchronous replica, we need to get the
 * feedback position from the list and send it to the Spock node attached to it.
 * This ensures that we only send feedback that is committed and acknowledged
 * by the synchronous replica.
 */
static void
get_feedback_position(XLogRecPtr *recvpos, XLogRecPtr *writepos, XLogRecPtr *flushpos, XLogRecPtr *max_recvpos)
{
	dlist_mutable_iter iter1;
	RemoteSyncPosition *syncpos;

	Assert(WalSndCtl->sync_standbys_status & SYNC_STANDBY_DEFINED);
	if (dlist_is_empty(&sync_replica_lsn))
		return;

	/* Acquire lock to update the sync position */
	LWLockAcquire(SyncRepLock, LW_EXCLUSIVE);

	/* Iterate through the wait queue and update positions */
	dlist_foreach_modify(iter1, &sync_replica_lsn)
	{
		syncpos = dlist_container(RemoteSyncPosition, node, iter1.cur);
		if (syncpos == NULL)
			break;

		if (syncpos->recvpos <= WalSndCtl->lsn[SYNC_REP_WAIT_FLUSH])
		{
			*recvpos = syncpos->recvpos;
			*writepos = syncpos->writepos;
			*flushpos = syncpos->flushpos;
			elog(DEBUG2, "SPOCK %s: received feedback %X/%X, "
				 "write %X/%X, flush %X/%X",
				 MySubscription->name,
				 (uint32) (*recvpos >> 32), (uint32) *recvpos,
				 (uint32) (*writepos >> 32), (uint32) *writepos,
				 (uint32) (*flushpos >> 32), (uint32) *flushpos
				);
			dlist_delete(iter1.cur);
			pfree(syncpos);
			syncpos = NULL;
		}
		if (syncpos != NULL)
			*max_recvpos = syncpos->recvpos;
	}
	/* Release the lock */
	LWLockRelease(SyncRepLock);
}

static bool
send_feedback(PGconn *conn, XLogRecPtr recvpos, int64 now, bool force)
{
	static StringInfo reply_message = NULL;

	static XLogRecPtr max_recvpos = InvalidXLogRecPtr;
	static XLogRecPtr last_recvpos = InvalidXLogRecPtr;
	static XLogRecPtr last_writepos = InvalidXLogRecPtr;
	static XLogRecPtr last_flushpos = InvalidXLogRecPtr;

	XLogRecPtr	writepos;
	XLogRecPtr	flushpos;

	/*
	 * In case of any syncrounoun replica is attached get the  LSN from the
	 * list
	 */
	if (WalSndCtl->sync_standbys_status & SYNC_STANDBY_DEFINED)
		get_feedback_position(&recvpos, &writepos, &flushpos, &max_recvpos);

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
		MemoryContext oldcontext = MemoryContextSwitchTo(TopMemoryContext);

		reply_message = makeStringInfo();
		MemoryContextSwitchTo(oldcontext);
	}
	else
		resetStringInfo(reply_message);

	pq_sendbyte(reply_message, 'r');
	pq_sendint64(reply_message, recvpos);	/* write */
	pq_sendint64(reply_message, flushpos);	/* flush */
	pq_sendint64(reply_message, writepos);	/* apply */
	pq_sendint64(reply_message, now);	/* sendTime */
	pq_sendbyte(reply_message, false);	/* replyRequested */

	elog(DEBUG2, "SPOCK %s: sending feedback (force %d) to recv %X/%X, "
		 "write %X/%X, flush %X/%X, max_waiting_lsn %X/%X",
		 MySubscription->name, force,
		 (uint32) (recvpos >> 32), (uint32) recvpos,
		 (uint32) (writepos >> 32), (uint32) writepos,
		 (uint32) (flushpos >> 32), (uint32) flushpos,
		 (uint32) (max_recvpos >> 32), (uint32) max_recvpos
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
 * Update frequently changing statistics of the apply group
 */
static void
UpdateWorkerStats(XLogRecPtr last_received, XLogRecPtr last_inserted)
{
	SpockApplyProgress sap = {0};

	sap.key.dbid = MyDatabaseId;
	sap.key.node_id = MySubscription->target->id;
	sap.key.remote_node_id = MySubscription->origin->id;

	sap.received_lsn = last_received;
	sap.remote_insert_lsn = last_inserted;
	spock_group_progress_update_ptr(MyApplyWorker->apply_group, &sap);
}

/*
 * Apply main loop.
 */
void
apply_work(PGconn *streamConn)
{
	int			fd;
	XLogRecPtr	last_received = InvalidXLogRecPtr;
	XLogRecPtr	last_inserted = InvalidXLogRecPtr;
	TimestampTz last_receive_timestamp = GetCurrentTimestamp();
	bool		need_replay;
	ErrorData  *edata = NULL;

	applyconn = streamConn;
	fd = PQsocket(applyconn);

	/* Init the ApplyReplayContext used to replay after an exception */
	ApplyReplayContext = AllocSetContextCreate(TopMemoryContext,
											   "ApplyReplayContext",
											   ALLOCSET_DEFAULT_SIZES);

	/* Init the MessageContext which we use for easier cleanup. */
	MessageContext = AllocSetContextCreate(TopMemoryContext,
										   "MessageContext",
										   ALLOCSET_DEFAULT_SIZES);

	/* Init the ApplyOperationContext for individual operations like DML */
	ApplyOperationContext = AllocSetContextCreate(TopMemoryContext,
												  "ApplyOperationContext",
												  ALLOCSET_DEFAULT_SIZES);

	MemoryContextSwitchTo(MessageContext);

	/* mark as idle, before starting to loop */
	pgstat_report_activity(STATE_IDLE, NULL);

	if (MyApplyWorker->apply_group == NULL)
		spock_apply_worker_attach();	/* Attach this worker. */

stream_replay:

	need_replay = false;

	PG_TRY();
	{
		while (!got_SIGTERM)
		{
			int			rc;
			int			r;

			MySpockWorker->worker_status = SPOCK_WORKER_STATUS_RUNNING;

			/*
			 * Background workers mustn't call usleep() or any direct
			 * equivalent instead, they may wait on their process latch, which
			 * sleeps as necessary, but is awakened if postmaster dies.  That
			 * way the background process goes away immediately in an
			 * emergency.
			 */
			rc = WaitLatchOrSocket(&MyProc->procLatch,
								   WL_SOCKET_READABLE | WL_LATCH_SET |
								   WL_TIMEOUT | WL_POSTMASTER_DEATH,
								   fd, 1000L);

			ResetLatch(&MyProc->procLatch);

			CHECK_FOR_INTERRUPTS();

			Assert(CurrentMemoryContext == MessageContext);

			if (ConfigReloadPending)
			{
				ConfigReloadPending = false;
				ProcessConfigFile(PGC_SIGHUP);
			}

			/* emergency bailout if postmaster has died */
			if (rc & WL_POSTMASTER_DEATH)
			{
				MySpockWorker->worker_status = SPOCK_WORKER_STATUS_STOPPED;
				proc_exit(1);
			}
			if (rc & WL_SOCKET_READABLE)
				PQconsumeInput(applyconn);

			if (PQstatus(applyconn) == CONNECTION_BAD)
			{
				MySpockWorker->worker_status = SPOCK_WORKER_STATUS_STOPPED;
				elog(ERROR, "SPOCK %s: connection to other side has died",
					 MySubscription->name);
			}

			/*
			 * The walsender is supposed to ping us for a status update every
			 * wal_sender_timeout / 2 milliseconds. If we don't get those, we
			 * assume that we have lost the connection.
			 *
			 * Note: keepalive configuration is supposed to cover this but is
			 * apparently unreliable.
			 */
			if (rc & WL_TIMEOUT)
			{
				TimestampTz timeout;

				timeout = TimestampTzPlusMilliseconds(last_receive_timestamp,
													  (wal_sender_timeout * 3) / 2);
				if (GetCurrentTimestamp() > timeout)
				{
					MySpockWorker->worker_status = SPOCK_WORKER_STATUS_STOPPED;
					elog(ERROR, "SPOCK %s: terminating apply due to missing "
						 "walsender ping",
						 MySubscription->name);
				}
			}

			Assert(CurrentMemoryContext == MessageContext);

			for (;;)
			{
				ApplyReplayEntry *entry;
				bool		queue_append;
				StringInfo	msg;
				int			c;

				if (got_SIGTERM)
					break;

				if (apply_replay_next == NULL)
				{
					char	   *buf;

					/* We are not in replay mode so receive from the stream */
					r = PQgetCopyData(applyconn, &buf, 1);

					last_receive_timestamp = GetCurrentTimestamp();

					/* Check for errors */
					if (r == -1)
					{
						if (buf != NULL)
							PQfreemem(buf);
						elog(ERROR, "SPOCK %s: data stream ended",
							 MySubscription->name);
					}
					else if (r == -2)
					{
						if (buf != NULL)
							PQfreemem(buf);
						elog(ERROR, "SPOCK %s: could not read COPY data: %s",
							 MySubscription->name,
							 PQerrorMessage(applyconn));
					}
					else if (r < 0)
					{
						if (buf != NULL)
							PQfreemem(buf);
						elog(ERROR, "SPOCK %s: invalid COPY status %d",
							 MySubscription->name, r);
					}
					else if (r == 0)
					{
						/* need to wait for new data */
						if (buf != NULL)
							PQfreemem(buf);
						break;
					}

					/*
					 * We have a valid message, create an apply queue entry
					 * but don't add it to the queue yet.
					 */
					entry = apply_replay_entry_create(r, buf);
					queue_append = true;
				}
				else
				{
					/* We are in replay mode so present the next queue entry */
					entry = apply_replay_next;
					apply_replay_next = apply_replay_next->next;
					queue_append = false;
				}

				if (ConfigReloadPending)
				{
					ConfigReloadPending = false;
					ProcessConfigFile(PGC_SIGHUP);
				}

				/* Handle the message received or replayed */
				msg = &entry->copydata;
				msg->cursor = 0;
				c = pq_getmsgbyte(msg);

				if (c == 'w')
				{
					XLogRecPtr	start_lsn;
					XLogRecPtr	end_lsn;

					start_lsn = pq_getmsgint64(msg);
					end_lsn = pq_getmsgint64(msg);
					pq_getmsgint64(msg);	/* sendTime */

					/*
					 * Call maybe_send_feedback before last_received is
					 * updated. This ordering guarantees that feedback LSN
					 * never advertises a position beyond what has actually
					 * been received and processed. Prevents skipping over
					 * unapplied changes due to premature flush LSN.
					 */
					maybe_send_feedback(applyconn, last_received,
										&last_receive_timestamp);

					if (last_received < start_lsn)
						last_received = start_lsn;

					if (last_received < end_lsn)
						last_received = end_lsn;

					/*
					 * Append the entry to the end of the replay queue if we
					 * read it from the stream. Dynamic allocation means no
					 * fixed size limit - queue grows as needed. Note:
					 * spock_replay_queue_size is deprecated and no longer
					 * checked.
					 */
					if (queue_append)
					{
						apply_replay_bytes += msg->len;

						if (apply_replay_head == NULL)
						{
							apply_replay_head = apply_replay_tail = entry;
						}
						else
						{
							apply_replay_tail->next = entry;
							apply_replay_tail = entry;
						}
					}

					/*
					 * Update statistics before applying the record to let the
					 * apply machinery to check consistency of these values.
					 *
					 * Protocol version 5+ includes remote_insert_lsn at the
					 * beginning of all messages. Protocol version 4 only
					 * includes it at the end of COMMIT messages (handled in
					 * handle_commit).
					 */
					if (spock_apply_get_proto_version() >= 5)
						last_inserted = pq_getmsgint64(msg);
					else
						last_inserted = last_received;
					UpdateWorkerStats(last_received, last_inserted);

					replication_handler(msg);

					/*
					 * Note: No overflow handling needed - dynamic allocation
					 * used
					 */
				}
				else if (c == 'k')
				{
					XLogRecPtr	endpos;
					bool		reply_requested;

					endpos = pq_getmsgint64(msg);
					 /* timestamp = */ pq_getmsgint64(msg);
					reply_requested = pq_getmsgbyte(msg);

					send_feedback(applyconn, endpos,
								  GetCurrentTimestamp(),
								  reply_requested);

					if (last_received < endpos)
						last_received = endpos;

					/*
					 * It is important to update received_lsn on a keepalive
					 * message: last_received tells us the last WAL position
					 * that was processed by the remote walsender, even if
					 * that data has never be sent to our replica. It allows
					 * Spock to maintain LSN lag statistic.
					 *
					 * NOTE: we can't change the keepalive message format, so
					 * just apply the same last_inserted. It may cause
					 * negative delta, but it seems not important.
					 */
					UpdateWorkerStats(last_received, last_inserted);

					/* We do not add 'k' messages to the replay queue */
					apply_replay_entry_free(entry);
				}
				else
				{
					/*
					 * Other message types are purposefully ignored and we
					 * don't add them to the replay queue.
					 */
					apply_replay_entry_free(entry);
				}

				/* We must not have fallen out of MessageContext by accident */
				Assert(CurrentMemoryContext == MessageContext);

				CHECK_FOR_INTERRUPTS();
			}

			if (xact_had_exception)
			{
				/*
				 * xact_had_exception implies that we are running under
				 * use_try_block == true. If this happens in SUB_DISABLE
				 * exception_behaviour, suspend the subscription here and
				 * suppress feedback.
				 */
				if (exception_behaviour == SUB_DISABLE)
				{
					spock_disable_subscription(MySubscription,
											   remote_origin_id,
											   remote_xid,
											   replorigin_session_origin_lsn,
											   replorigin_session_origin_timestamp);

					/*
					 * The subscription is now disabled, and this apply worker
					 * will exit shortly. Since the process is terminating,
					 * memory contexts and replication origin state will be
					 * cleaned up automatically, so no explicit reset is
					 * needed.
					 */
					return;
				}
			}
			else
			{
				/*
				 * If we did not encounter any exception only send feedback if
				 * exception_behaviour == DISCARD or we are not using a try
				 * block at all (default transaction mode). The reason for
				 * this is that in TRANSDISCARD or SUB_DISABLE modes this not
				 * having an exception during use_try_block would lead to
				 * silently skipping the transaction altogether.
				 */
				if (!MyApplyWorker->use_try_block ||
					exception_behaviour == DISCARD)
				{
					send_feedback(applyconn, last_received, GetCurrentTimestamp(),
								  false);
				}
			}

			if (!in_remote_transaction)
				process_syncing_tables(last_received);

			/* We must not have switched out of MessageContext by mistake */
			Assert(CurrentMemoryContext == MessageContext);

			/* Cleanup the memory. */
			MemoryContextReset(MessageContext);

			/*
			 * Only do a leak check if we're between txns; we don't want lots
			 * of noise due to resources that only exist in a txn.
			 */
			if (!IsTransactionState())
			{
				VALGRIND_DO_ADDED_LEAK_CHECK;
				pgstat_report_stat(true);
			}
		}
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(MessageContext);
		edata = CopyErrorData();

		/*
		 * use_try_block == true indicates either that an exception occurred
		 * during a DML operation, or that we were replaying previously failed
		 * actions (via need_replay).
		 *
		 * If an exception occurs during handle_commit after prior handling,
		 * we still need to ensure proper cleanup (e.g., disabling the
		 * subscription).
		 *
		 * Handle SUB_DISABLE mode for both cases: xact_had_exception means DML
		 * operations failed during exception handling, while use_try_block
		 * without xact_had_exception means an error occurred after successful
		 * retry (e.g., TRANSDISCARD throwing ERROR).
		 *
		 * Note: spock_disable_subscription() handles transaction management
		 * internally, so no need to wrap it in StartTransactionCommand().
		 */
		if (exception_behaviour == SUB_DISABLE &&
			(xact_had_exception || MyApplyWorker->use_try_block))
		{
			spock_disable_subscription(MySubscription,
									   remote_origin_id,
									   remote_xid,
									   replorigin_session_origin_lsn,
									   replorigin_session_origin_timestamp);

			/*
			 * The subscription is now disabled, and this apply worker will
			 * exit shortly. Since the process is terminating, memory contexts
			 * and replication origin state will be cleaned up automatically,
			 * so no explicit reset is needed.
			 */
			return;
		}

		/*
		 * For other exceptions with use_try_block, where xact_had_exception
		 * is false, this indicates an ERROR occurred during exception handling
		 * (e.g., connection died, CommitTransactionCommand failure during
		 * TRANSDISCARD logging, etc.).
		 *
		 * We log the error and re-throw to exit the worker. The background
		 * worker infrastructure will restart the worker automatically. This
		 * handles both transient errors (connection failures) and system
		 * errors (out of memory, disk full) uniformly.
		 */
		if (!xact_had_exception && MyApplyWorker->use_try_block)
		{
			elog(LOG, "SPOCK %s: error during exception handling: %s",
				 MySubscription->name, edata->message);
			elog(LOG, "SPOCK %s: exiting to allow worker restart",
				 MySubscription->name);
			PG_RE_THROW();
		}

		/*
		 * Note: Replay queue overflow handling removed - dynamic allocation
		 * prevents overflow. We no longer kill and restart apply workers for
		 * queue overflow. Exception handling now follows
		 * spock.exception_behavior setting.
		 */

		/*
		 * Reaching this point means that we are dealing with the first
		 * occurrence of an exception in the default, non-exception-handling
		 * mode. We need to abort the current toplevel transactions and reset
		 * cache states so that we can retry the transaction in
		 * exception-handling mode by replaying from the queue.
		 */
		AbortOutOfAnyTransaction();

		MemoryContextSwitchTo(MessageContext);
		elog(LOG, "SPOCK: caught initial exception - %s", edata->message);

		/*
		 * Save the initial exception message and operation type so we can
		 * include them in the exception_log if operations succeed on retry.
		 * Store in the exception_log structure for this transaction.
		 */
		if (exception_log_ptr != NULL)
		{
			snprintf(exception_log_ptr[my_exception_log_index].initial_error_message,
					 sizeof(exception_log_ptr[my_exception_log_index].initial_error_message),
					 "%s", edata->message);

			/*
			 * Capture the operation that caused the initial exception. Use
			 * errcallback_arg.action_name if available, otherwise "UNKNOWN".
			 */
			snprintf(exception_log_ptr[my_exception_log_index].initial_operation,
					 sizeof(exception_log_ptr[my_exception_log_index].initial_operation),
					 "%s",
					 errcallback_arg.action_name ? errcallback_arg.action_name : "UNKNOWN");
		}

		FlushErrorState();

		MemoryContextReset(MessageContext);
		MemoryContextReset(ApplyOperationContext);
		spock_relation_cache_reset();

		apply_replay_next = apply_replay_head;
		in_remote_transaction = false;
		first_begin_at_startup = true;
		remote_origin_lsn = InvalidXLogRecPtr;
		remote_origin_id = InvalidRepOriginId;
		/* Free origin name - it's in TopMemoryContext, not MessageContext */
		if (remote_origin_name != NULL)
		{
			pfree(remote_origin_name);
			remote_origin_name = NULL;
		}

		/* Don't want to use goto inside of PG_CATCH() */
		need_replay = true;
	}
	PG_END_TRY();

	if (need_replay)
	{
		MyApplyWorker->use_try_block = true;

		goto stream_replay;
	}

	elog(LOG, "SPOCK %s: falling out of apply_work() sigterm=%s",
		 MySubscription->name, (got_SIGTERM) ? "true" : "false");
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
 * Start skipping changes of the transaction if the given LSN matches the
 * LSN specified by subscription's skiplsn.
 */
static void
maybe_start_skipping_changes(XLogRecPtr finish_lsn)
{
	Assert(!is_skipping_changes());
	Assert(!in_remote_transaction);

	/*
	 * Quick return if it's not requested to skip this transaction. This
	 * function is called for every remote transaction and we assume that
	 * skipping the transaction is not used often.
	 */
	if (likely(XLogRecPtrIsInvalid(MySubscription->skiplsn) ||
			   MySubscription->skiplsn != finish_lsn))
		return;

	/* Start skipping all changes of this transaction */
	skip_xact_finish_lsn = finish_lsn;

	ereport(LOG,
			errmsg("SPOCK %s: logical replication starts skipping transaction at LSN %X/%X",
				   MySubscription->name, LSN_FORMAT_ARGS(skip_xact_finish_lsn)));
}

/*
 * Stop skipping changes by resetting skip_xact_finish_lsn if enabled.
 */
static void
stop_skipping_changes(void)
{
	if (!is_skipping_changes())
		return;

	ereport(LOG,
			(errmsg("SPOCK %s: logical replication completed skipping transaction at LSN %X/%X",
					MySubscription->name, LSN_FORMAT_ARGS(skip_xact_finish_lsn))));

	/* Stop skipping changes */
	skip_xact_finish_lsn = InvalidXLogRecPtr;
}

/*
 * Clear sub_skip_lsn of spock.subscription catalog.
 *
 * finish_lsn is the transaction's finish LSN that is used to check if the
 * sub_skip_lsn matches it. If not matched, we raise a warning when clearing the
 * sub_skip_lsn in order to inform users for cases e.g., where the user mistakenly
 * specified the wrong sub_skip_lsn.
 */
static void
clear_subscription_skip_lsn(XLogRecPtr finish_lsn)
{
	SpockSubscription *sub;
	XLogRecPtr	myskiplsn = MySubscription->skiplsn;
	bool		started_tx = false;

	if (likely(XLogRecPtrIsInvalid(myskiplsn)))
		return;

	if (!IsTransactionState())
	{
		StartTransactionCommand();
		started_tx = true;
	}

	sub = get_subscription(MySubscription->id);

	/*
	 * Clear the sub_skip_lsn. If the user has already changed sub_skip_lsn
	 * before clearing it we don't update the catalog and the replication
	 * origin state won't get advanced. So in the worst case, if the server
	 * crashes before sending an acknowledgment of the flush position the
	 * transaction will be sent again and the user needs to set subskiplsn
	 * again. We can reduce the possibility by logging a replication origin
	 * WAL record to advance the origin LSN instead but there is no way to
	 * advance the origin timestamp and it doesn't seem to be worth doing
	 * anything about it since it's a very rare case.
	 */
	if (sub->skiplsn == myskiplsn)
	{
		sub->skiplsn = LSNGetDatum(InvalidXLogRecPtr);
		alter_subscription(sub);

		if (myskiplsn != finish_lsn)
			ereport(WARNING,
					errmsg("skip-LSN of subscription \"%s\" cleared", MySubscription->name),
					errdetail("Remote transaction's finish WAL location (LSN) %X/%X did not match skip-LSN %X/%X.",
							  LSN_FORMAT_ARGS(finish_lsn),
							  LSN_FORMAT_ARGS(myskiplsn)));
		else
			ereport(WARNING,
					errmsg("skip-LSN of subscription \"%s\" cleared", MySubscription->name),
					errdetail("Remote transaction's finish WAL location (LSN) %X/%X equals skip-LSN %X/%X.",
							  LSN_FORMAT_ARGS(finish_lsn),
							  LSN_FORMAT_ARGS(myskiplsn)));
	}

	if (started_tx)
		CommitTransactionCommand();
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

	MemoryContext oldcontext;
	ErrorContextCallback errcallback;

	oldcontext = MemoryContextSwitchTo(MessageContext);

	errcallback.callback = execute_sql_command_error_cb;
	errcallback.arg = cmdstr;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	debug_query_string = cmdstr;
	commands = pg_parse_query(cmdstr);

	MemoryContextSwitchTo(oldcontext);

	/*
	 * When executing statements coming from spock.queue on subscribers, force
	 * top-level from caller, so ProcessUtility sees a top-level context.
	 */
	if (!in_spock_queue_ddl_command)
	{
		/*
		 * Do a limited amount of safety checking against CONCURRENTLY
		 * commands executed in situations where they aren't allowed. The
		 * sender side should provide protection, but better be safe than
		 * sorry.
		 */
		isTopLevel = isTopLevel && (list_length(commands) == 1);
	}

	foreach(command_i, commands)
	{
		List	   *plantree_list;
		List	   *querytree_list;
		RawStmt    *command = (RawStmt *) lfirst(command_i);
		CommandTag	commandTag;
		Portal		portal;
		int			save_nestlevel;
		DestReceiver *receiver;
		Oid			save_userid;
		int			save_sec_context;

		/* temporarily push snapshot for parse analysis/planning */
		PushActiveSnapshot(GetTransactionSnapshot());

		oldcontext = MemoryContextSwitchTo(MessageContext);

		/*
		 * Set the current role to the user that executed the command on the
		 * origin server.
		 */
		GetUserIdAndSecContext(&save_userid, &save_sec_context);
		SetUserIdAndSecContext(get_role_oid(role, false),
							   save_sec_context | SECURITY_LOCAL_USERID_CHANGE);
		save_nestlevel = NewGUCNestLevel();
		commandTag = CreateCommandTag(command);

		/*
		 * check if it's a DDL statement. we only do this for
		 * in_spock_replicate_ddl_command
		 * SECURITY LABEL command is not a DDL, just an utility one. Hence, let
		 * spock execute this command.
		 */
		if (in_spock_replicate_ddl_command &&
			GetCommandLogLevel(command->stmt) != LOGSTMT_DDL &&
			!IsA(command->stmt, SecLabelStmt))
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

		/*
		 * If we are applying queued SQL on subscriber, register newly
		 * created/altered relations explicitly here after execution. Skip
		 * variable SET commands (e.g., SET search_path).
		 */
		if (in_spock_queue_ddl_command &&
			!IsA(command->stmt, VariableSetStmt))
		{
			PlannedStmt *pstmt = linitial_node(PlannedStmt, plantree_list);

			/*
			 * By the time SQL is in the queue it has already been filtered on
			 * origin, so we can just add it to the replication set here.
			 */
			add_ddl_to_repset(pstmt->utilityStmt);
		}

		PortalDrop(portal, false);

		CommandCounterIncrement();

		/*
		 * Restore the GUC variables we set above.
		 */
		AtEOXact_GUC(true, save_nestlevel);

		/* Restore previous session privileges */
		SetUserIdAndSecContext(save_userid, save_sec_context);

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
	MemoryContext saved_ctx;
	List	   *unsynced_tables;
	ListCell   *lc;

	/* Cleanup first. */
	list_free_deep(SyncingTables);
	SyncingTables = NIL;

	/* Read new state. */
	unsynced_tables = get_unsynced_tables(subid);
	saved_ctx = MemoryContextSwitchTo(TopMemoryContext);
	foreach(lc, unsynced_tables)
	{
		SpockSyncStatus *sync = palloc(sizeof(SpockSyncStatus));

		memcpy(sync, lfirst(lc), sizeof(SpockSyncStatus));
		SyncingTables = lappend(SyncingTables, sync);
	}

	MemoryContextSwitchTo(saved_ctx);
}

static void
process_syncing_tables(XLogRecPtr end_lsn)
{
	ListCell   *lc;

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
		foreach(lc, SyncingTables)
		{
			SpockSyncStatus *sync = (SpockSyncStatus *) lfirst(lc);
			SpockSyncStatus *newsync;

			StartTransactionCommand();
			newsync = get_table_sync_status(MyApplyWorker->subid,
											NameStr(sync->nspname),
											NameStr(sync->relname), true);

			/*
			 * TODO: what to do here? We don't really want to die, but this
			 * can mean many things, for now we just assume table is not
			 * relevant for us anymore and leave fixing to the user.
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
			else if (newsync->status == SYNC_STATUS_FAILED)
			{
				/*
				 * Failed SYNC operation should be ignored until someone processes
				 * the error and changes the status.
				 */
				sync->status = SYNC_STATUS_FAILED;
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

				/*
				 * TODO: What if the SYNC worker has gone? It may be any
				 * trivial ERROR - memory allocation, or network connection,
				 * for example. We need to restart syncing process from the
				 * scratch. For now, suppose that it should be always exist in
				 * testing environment.
				 */
				Assert(spock_worker_running(worker));

				if (spock_worker_running(worker) &&
					replorigin_session_origin_lsn >= worker->worker.apply.replay_stop_lsn)
				{
					worker->worker.apply.replay_stop_lsn = replorigin_session_origin_lsn;
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
					else

						/*
						 * TODO: Here, should be a more sophisticated logic in
						 * case if worker exited on error or status record has
						 * lost.
						 */
						elog(ERROR, "a table synchronisation operation is failed");
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
				SyncingTables = foreach_delete_current(SyncingTables, lc);
				pfree(sync);
			}
		}
	}

	/*
	 * If there are still pending tables for synchronization, launch the sync
	 * worker.
	 */
	foreach(lc, SyncingTables)
	{
		List	   *workers;
		ListCell   *wlc;
		int			nworkers = 0;
		SpockSyncStatus *sync = (SpockSyncStatus *) lfirst(lc);

		if (sync->status == SYNC_STATUS_SYNCDONE || sync->status == SYNC_STATUS_READY)
			continue;

		LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);
		workers = spock_sync_find_all(MyDatabaseId, MyApplyWorker->subid);
		foreach(wlc, workers)
		{
			SpockWorker *worker = (SpockWorker *) lfirst(wlc);

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
	SpockWorker worker;

	/* Start the sync worker. */
	memset(&worker, 0, sizeof(SpockWorker));
	worker.worker_type = SPOCK_WORKER_SYNC;
	worker.dboid = MySpockWorker->dboid;
	worker.worker.apply.subid = MyApplyWorker->subid;
	worker.worker.apply.sync_pending = false;	/* Makes no sense for sync
												 * worker. */

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
	int			slot = DatumGetInt32(main_arg);
	PGconn	   *streamConn;
	RepOriginId originid;
	XLogRecPtr	origin_startpos;
	MemoryContext saved_ctx;
	char	   *repsets;
	char	   *origins;

	/* Setup shmem. */
	spock_worker_attach(slot, SPOCK_WORKER_APPLY);
	Assert(MySpockWorker->worker_type == SPOCK_WORKER_APPLY);
	MyApplyWorker = &MySpockWorker->worker.apply;

	/* Setup synchronous commit according to the user's wishes */
	SetConfigOption("synchronous_commit",
					spock_synchronous_commit ? "local" : "off",
					PGC_BACKEND, PGC_S_OVERRIDE);	/* other context? */

	/* Run as replica session replication role. */
	SetConfigOption("session_replication_role", "replica",
					PGC_SUSET, PGC_S_OVERRIDE); /* other context? */

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

	CommitTransactionCommand();

	elog(DEBUG1, "SPOCK %s: starting apply worker", MySubscription->name);

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
	 * Cache the queue relation id. TODO: invalidation
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
	 * IDENTIFY_SYSTEM sets up some internal state on walsender so call it
	 * even if we don't (yet) want to use any of the results.
	 */
	spock_identify_system(streamConn, NULL, NULL, NULL, NULL);

	spock_start_replication(streamConn, MySubscription->slot_name,
							origin_startpos, origins, repsets, NULL,
							MySubscription->force_text_transfer);
	pfree(repsets);

	CommitTransactionCommand();

	/*
	 * Do an initial leak check with reporting off; we don't want to see these
	 * results, just the later output from ADDED leak checks.
	 */
	VALGRIND_DISABLE_ERROR_REPORTING;
	VALGRIND_DO_LEAK_CHECK;
	VALGRIND_ENABLE_ERROR_REPORTING;

	/* Initialize the wait queue for replicated LSNs */
	dlist_init(&sync_replica_lsn);

	apply_work(streamConn);

	PQfinish(streamConn);

	/* We should only get here if we received sigTERM */
	proc_exit(0);
}


/* Create a new apply reply queue entry in the ApplyReplayContext */
static ApplyReplayEntry *
apply_replay_entry_create(int r, char *buf)
{
	MemoryContext oldcontext;
	ApplyReplayEntry *entry;

	Assert(r > 0);
	Assert(buf != NULL);

	oldcontext = MemoryContextSwitchTo(ApplyReplayContext);

	entry = (ApplyReplayEntry *) palloc(sizeof(ApplyReplayEntry));
	entry->copydata.len = r;
	entry->copydata.maxlen = -1;
	entry->copydata.cursor = 0;
	entry->copydata.data = buf;
	entry->next = NULL;

	MemoryContextSwitchTo(oldcontext);

	return entry;
}

/* Free on replay entry (unqueued message type or queue is overflowing) */
static void
apply_replay_entry_free(ApplyReplayEntry * entry)
{
	PQfreemem(entry->copydata.data);
	pfree(entry);
}

/* Free all queued messages and reset the apply replay queue */
static void
apply_replay_queue_reset(void)
{
	ApplyReplayEntry *entry;

	for (entry = apply_replay_head; entry != NULL; entry = entry->next)
	{
		PQfreemem(entry->copydata.data);
	}

	apply_replay_head = NULL;
	apply_replay_tail = NULL;
	apply_replay_next = NULL;
	apply_replay_bytes = 0;

	MemoryContextReset(ApplyReplayContext);
}

/*
 * Check if we should send feedback based on message count or timeout.
 * Resets internal state if feedback is sent.
 */
static void
maybe_send_feedback(PGconn *applyconn, XLogRecPtr lsn_to_send,
					TimestampTz *last_receive_timestamp)
{
	static int	w_message_count = 0;
	TimestampTz now = GetCurrentTimestamp();

	w_message_count++;

	/*
	 * Send feedback if wal_sender_timeout/2 has passed or after 10 'w'
	 * messages.
	 */
	if (TimestampDifferenceExceeds(*last_receive_timestamp, now, wal_sender_timeout / 2) ||
		w_message_count >= 10)
	{
		elog(DEBUG2, "SPOCK %s: force sending feedback after %d 'w' messages or timeout",
			 MySubscription->name, w_message_count);

		/*
		 * We need to send feedback to the walsender process to avoid remote
		 * wal_sender_timeout.
		 */
		send_feedback(applyconn, lsn_to_send, now, true);
		*last_receive_timestamp = now;
		w_message_count = 0;
	}
}

/*
 * Advance the replication origin for forwarded transactions.
 *
 * In cascade replication (A -> B -> C with forward_origins='all'), when C
 * receives transactions that originated on A (forwarded through B), we track
 * C's position relative to A by maintaining a separate replication origin.
 *
 * This enables seamless switchover: if C later subscribes directly to A,
 * the origin will already exist with the correct LSN, so C knows where to
 * start receiving from A.
 *
 * The origin is named using slot name format (spk_<db>_<source>_<subscriber>)
 * for consistency with direct subscriptions.
 *
 * We cache the remote_origin_id -> local_origin_id mapping since the Spock
 * node ID is stable across the cluster (set by commit f60484e).
 */
static void
maybe_advance_forwarded_origin(XLogRecPtr end_lsn, bool xact_had_exception)
{
	RepOriginId	forwarded_origin;

	/*
	 * Only advance for forwarded transactions (origin differs from our direct
	 * provider) that completed without exceptions.
	 */
	if (xact_had_exception ||
		remote_origin_id == InvalidRepOriginId ||
		remote_origin_id == MySubscription->origin->id ||
		remote_origin_name == NULL)
		return;

	/*
	 * Check cache first. The remote_origin_id (Spock node ID) is stable
	 * for a given source node, so we can reuse the local origin ID.
	 */
	if (remote_origin_id == cached_forward_remote_id &&
		cached_forward_local_id != InvalidRepOriginId)
	{
		forwarded_origin = cached_forward_local_id;

		elog(DEBUG2, "SPOCK %s: advancing forwarded origin (cached, oid %u) "
			 "remote_lsn %X/%X end_lsn %X/%X",
			 MySubscription->name,
			 forwarded_origin,
			 (uint32) (remote_origin_lsn >> 32), (uint32) remote_origin_lsn,
			 (uint32) (end_lsn >> 32), (uint32) end_lsn);
	}
	else
	{
		/*
		 * Cache miss - look up or create the origin. Use slot name format
		 * (spk_<db>_<provider>_<subscription>) for consistency with direct
		 * subscriptions.
		 */
		Relation	replorigin_rel;
		NameData	slot_name;
		char	   *dbname;

		StartTransactionCommand();

		dbname = get_database_name(MyDatabaseId);
		gen_slot_name(&slot_name, dbname, remote_origin_name,
					  MySubscription->name);

		elog(DEBUG2, "SPOCK %s: advancing forwarded origin '%s' (from node '%s') "
			 "remote_lsn %X/%X end_lsn %X/%X",
			 MySubscription->name,
			 NameStr(slot_name),
			 remote_origin_name,
			 (uint32) (remote_origin_lsn >> 32), (uint32) remote_origin_lsn,
			 (uint32) (end_lsn >> 32), (uint32) end_lsn);

		replorigin_rel = table_open(ReplicationOriginRelationId, RowExclusiveLock);
		forwarded_origin = replorigin_by_name(NameStr(slot_name), true);

		if (forwarded_origin == InvalidRepOriginId)
		{
			forwarded_origin = replorigin_create(NameStr(slot_name));
			elog(DEBUG2, "SPOCK %s: created replication origin '%s' (oid %u) "
				 "for forwarded transactions from node '%s'",
				 MySubscription->name, NameStr(slot_name), forwarded_origin,
				 remote_origin_name);
		}

		table_close(replorigin_rel, RowExclusiveLock);
		CommitTransactionCommand();
		MemoryContextSwitchTo(MessageContext);

		/* Update cache */
		cached_forward_remote_id = remote_origin_id;
		cached_forward_local_id = forwarded_origin;
	}

	/* Advance the origin */
	StartTransactionCommand();
	replorigin_advance(forwarded_origin, remote_origin_lsn,
					   end_lsn, false, false);
	CommitTransactionCommand();
	MemoryContextSwitchTo(MessageContext);
}
