/*-------------------------------------------------------------------------
 *
 * spock_monitor.c
 *		spock node monitoring
 *
 * Everything an operator needs to know about a node without reading the
 * server log is kept in shared memory and exposed through SQL functions
 * that back the spock.*_status, spock.*_stats and spock.events views:
 *
 *   - a ring of recent events (subscription enable/disable, worker start,
 *     stop and failure, provider connects, extension upgrades, ...)
 *   - per-subscription activity counters with the time of the last change
 *     and the last error message of the apply or sync worker
 *   - a snapshot of every registered spock worker and of the
 *     transactions being retried by exception handling
 *   - the per-table channel counters and the apply group progress
 *   - host, operating system and version information for reports
 *
 * The event ring and the counters are not transactional: an event is
 * recorded when the reporting code runs, whether or not its transaction
 * later commits.  Both survive worker restarts but not a postmaster
 * restart.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <stdlib.h>
#include <unistd.h>
#ifndef WIN32
#include <sys/statvfs.h>
#include <sys/utsname.h>
#endif

#include "funcapi.h"
#include "miscadmin.h"

#include "catalog/pg_type.h"
#include "replication/origin.h"
#include "replication/slot.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/shmem.h"
#include "storage/spin.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/pg_lsn.h"
#include "utils/timestamp.h"

#include "pgstat.h"

#include "spock_conflict.h"
#if PG_VERSION_NUM >= 180000
#include "spock_conflict_stat.h"
#endif
#include "spock_exception_handler.h"
#include "spock_group.h"
#include "spock_monitor.h"
#include "spock_output_plugin.h"
#include "spock_output_proto.h"
#include "spock_worker.h"
#include "spock.h"

#include "spock_compat.h"

PG_FUNCTION_INFO_V1(spock_get_events);
PG_FUNCTION_INFO_V1(spock_reset_events);
PG_FUNCTION_INFO_V1(spock_get_worker_status);
PG_FUNCTION_INFO_V1(spock_get_apply_stats);
PG_FUNCTION_INFO_V1(spock_reset_subscription_stats);
PG_FUNCTION_INFO_V1(spock_get_slot_groups);
PG_FUNCTION_INFO_V1(spock_get_monitor_summary);
PG_FUNCTION_INFO_V1(spock_get_system_info);
PG_FUNCTION_INFO_V1(spock_get_pending_exceptions);
PG_FUNCTION_INFO_V1(get_channel_stats);
PG_FUNCTION_INFO_V1(reset_channel_stats);
PG_FUNCTION_INFO_V1(get_apply_group_progress);
PG_FUNCTION_INFO_V1(spock_wait_slot_confirm_lsn);

#define SPOCK_MONITOR_TRANCHE_NAME	"spock_monitor"

/* Shared memory header of the event history. */
typedef struct SpockMonitorShmem
{
	LWLock	   *lock;			/* protects the ring below */
	TimestampTz started_at;		/* when shared memory was initialized */
	uint64		next_event_id;
	int			event_capacity;
	int			event_head;		/* index of the oldest event */
	int			event_count;
	SpockMonitorEvent events[FLEXIBLE_ARRAY_MEMBER];
} SpockMonitorShmem;

typedef enum SpockMonitorSeverity
{
	SPOCK_SEVERITY_INFO,
	SPOCK_SEVERITY_WARNING,
	SPOCK_SEVERITY_ERROR
} SpockMonitorSeverity;

typedef struct SpockMonitorEventInfo
{
	const char *name;
	SpockMonitorSeverity severity;
} SpockMonitorEventInfo;

/* Indexed by SpockMonitorEventType. */
static const SpockMonitorEventInfo SpockMonitorEventInfos[SPOCK_EVENT_NUM_TYPES] = {
	{"node_created", SPOCK_SEVERITY_INFO},
	{"node_dropped", SPOCK_SEVERITY_INFO},
	{"subscription_created", SPOCK_SEVERITY_INFO},
	{"subscription_dropped", SPOCK_SEVERITY_INFO},
	{"subscription_enabled", SPOCK_SEVERITY_INFO},
	{"subscription_disabled", SPOCK_SEVERITY_WARNING},
	{"subscription_altered", SPOCK_SEVERITY_INFO},
	{"worker_started", SPOCK_SEVERITY_INFO},
	{"worker_stopped", SPOCK_SEVERITY_INFO},
	{"worker_failed", SPOCK_SEVERITY_ERROR},
	{"worker_error", SPOCK_SEVERITY_ERROR},
	{"provider_connected", SPOCK_SEVERITY_INFO},
	{"provider_disconnected", SPOCK_SEVERITY_WARNING},
	{"transaction_skipped", SPOCK_SEVERITY_WARNING},
	{"transaction_discarded", SPOCK_SEVERITY_WARNING},
	{"sync_started", SPOCK_SEVERITY_INFO},
	{"sync_finished", SPOCK_SEVERITY_INFO},
	{"sync_failed", SPOCK_SEVERITY_ERROR},
	{"slot_created", SPOCK_SEVERITY_INFO},
	{"stream_started", SPOCK_SEVERITY_INFO},
	{"stream_stopped", SPOCK_SEVERITY_INFO},
	{"stream_error", SPOCK_SEVERITY_ERROR},
	{"apply_paused", SPOCK_SEVERITY_INFO},
	{"apply_resumed", SPOCK_SEVERITY_INFO},
	{"repair_mode_enabled", SPOCK_SEVERITY_WARNING},
	{"repair_mode_disabled", SPOCK_SEVERITY_INFO},
	{"extension_upgraded", SPOCK_SEVERITY_INFO},
};

static const char *const SpockMonitorSeverityNames[] = {
	"info",
	"warning",
	"error"
};

/* Number of subscriptions whose counters fit in shared memory. */
#define SPOCK_MONITOR_MAX_STATS(_nworkers)	Max(64, 4 * (_nworkers))

int			spock_event_history_size = 1024;

static SpockMonitorShmem *SpockMonitorShm = NULL;
static HTAB *SpockMonitorStatsHash = NULL;
static int	spock_monitor_max_stats = 0;

/* Counters entry of the subscription served by this apply or sync worker. */
SpockMonitorStatsEntry *MySpockMonitorStats = NULL;

/* Set while this walsender runs the spock output plugin. */
static bool spock_monitor_in_stream = false;
static NameData spock_monitor_stream_slot;

/* Set once a connection loss has been reported, until its rethrow is seen. */
static bool spock_monitor_disconnect_reported = false;

static Size spock_monitor_shmem_size(int nevents);
static void spock_monitor_append_event(SpockMonitorEventType type,
									   Oid subid, XLogRecPtr lsn,
									   int sqlerrcode, const char *detail,
									   bool nowait);
static SpockMonitorStatsEntry *spock_monitor_attach_stats(Oid subid);
static void spock_monitor_detach_stats(void);
static void spock_monitor_reset_stats_entry(SpockMonitorStatsEntry *entry,
											TimestampTz now);
static void spock_monitor_set_error(const char *message, XLogRecPtr lsn,
									int sqlerrcode,
									SpockMonitorCounter counter);
static void spock_monitor_format_error(ErrorData *edata, char *buf, Size len);
static const char *spock_worker_status_name(SpockWorker *worker);
static Datum timestamptz_or_null(TimestampTz ts, bool *isnull);
static void check_monitor_shmem(void);


/*
 * Define the GUCs of this module.  Called from _PG_init().
 */
void
spock_monitor_init(void)
{
	DefineCustomIntVariable("spock.event_history_size",
							"Number of recent spock events kept in shared memory.",
							"The spock.events view shows the most recent events "
							"of the node. Older events are dropped once the "
							"history is full.",
							&spock_event_history_size,
							1024,
							16,
							1048576,
							PGC_POSTMASTER,
							0,
							NULL,
							NULL,
							NULL);
}

static Size
spock_monitor_shmem_size(int nevents)
{
	Size		size;

	size = offsetof(SpockMonitorShmem, events);
	size = add_size(size, mul_size(sizeof(SpockMonitorEvent), nevents));

	return size;
}

/*
 * Request shared memory.  Called from the central spock_shmem_request().
 */
void
spock_monitor_shmem_request(int nworkers)
{
	Size		size;

	spock_monitor_max_stats = SPOCK_MONITOR_MAX_STATS(nworkers);

	size = spock_monitor_shmem_size(spock_event_history_size);
	size = add_size(size,
					hash_estimate_size(spock_monitor_max_stats,
									   sizeof(SpockMonitorStatsEntry)));
	RequestAddinShmemSpace(size);

	RequestNamedLWLockTranche(SPOCK_MONITOR_TRANCHE_NAME, 1);
}

/*
 * Initialize or attach the shared memory structures.  Called from the
 * central spock_shmem_startup() with AddinShmemInitLock held.
 */
void
spock_monitor_shmem_startup(bool found)
{
	HASHCTL		hctl;
	bool		is_found;

	Assert(LWLockHeldByMeInMode(AddinShmemInitLock, LW_EXCLUSIVE));
	Assert(SpockCtx != NULL);

	/* Reset local pointers, see spock_worker_shmem_startup(). */
	SpockMonitorShm = NULL;
	SpockMonitorStatsHash = NULL;
	MySpockMonitorStats = NULL;

	/* In case of EXEC_BACKEND we must compute it in each backend. */
	spock_monitor_max_stats = SPOCK_MONITOR_MAX_STATS(SpockCtx->total_workers);

	SpockMonitorShm = ShmemInitStruct("spock monitor",
									  spock_monitor_shmem_size(spock_event_history_size),
									  &is_found);
	Assert(found == is_found);

	if (!found)
	{
		SpockMonitorShm->lock =
			&((GetNamedLWLockTranche(SPOCK_MONITOR_TRANCHE_NAME)[0]).lock);
		SpockMonitorShm->started_at = GetCurrentTimestamp();
		SpockMonitorShm->next_event_id = 1;
		SpockMonitorShm->event_capacity = spock_event_history_size;
		SpockMonitorShm->event_head = 0;
		SpockMonitorShm->event_count = 0;
	}

	memset(&hctl, 0, sizeof(hctl));
	hctl.keysize = sizeof(SpockMonitorStatsKey);
	hctl.entrysize = sizeof(SpockMonitorStatsEntry);
	SpockMonitorStatsHash = ShmemInitHash("spock monitor stats hash",
										  spock_monitor_max_stats,
										  spock_monitor_max_stats,
										  &hctl,
										  HASH_ELEM | HASH_BLOBS |
										  HASH_FIXED_SIZE);
}


/* ----------------------------------------------------------------------
 * Event history
 * ----------------------------------------------------------------------
 */

/*
 * Append one event to the ring, dropping the oldest one when full.
 *
 * With nowait the lock is only tried, so that the error reporting path
 * can never block on it.
 */
static void
spock_monitor_append_event(SpockMonitorEventType type, Oid subid,
						   XLogRecPtr lsn, int sqlerrcode,
						   const char *detail, bool nowait)
{
	SpockMonitorEvent *event;
	int			idx;

	if (SpockMonitorShm == NULL)
		return;

	if (nowait)
	{
		if (!LWLockConditionalAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE))
			return;
	}
	else
		LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);

	if (SpockMonitorShm->event_count == SpockMonitorShm->event_capacity)
	{
		idx = SpockMonitorShm->event_head;
		SpockMonitorShm->event_head =
			(SpockMonitorShm->event_head + 1) % SpockMonitorShm->event_capacity;
	}
	else
	{
		idx = (SpockMonitorShm->event_head + SpockMonitorShm->event_count) %
			SpockMonitorShm->event_capacity;
		SpockMonitorShm->event_count++;
	}

	event = &SpockMonitorShm->events[idx];
	event->event_id = SpockMonitorShm->next_event_id++;
	event->event_time = GetCurrentTimestamp();
	event->event_type = type;
	event->dboid = MyDatabaseId;
	event->subid = subid;
	event->pid = MyProcPid;
	event->sqlerrcode = sqlerrcode;
	event->lsn = lsn;
	strlcpy(event->detail, detail, SPOCK_MONITOR_MESSAGE_LEN);

	LWLockRelease(SpockMonitorShm->lock);
}

/*
 * Record an event with a printf-style detail text.
 */
void
spock_monitor_record_event(SpockMonitorEventType type, Oid subid,
						   XLogRecPtr lsn, const char *fmt,...)
{
	char		detail[SPOCK_MONITOR_MESSAGE_LEN];
	va_list		args;

	if (SpockMonitorShm == NULL)
		return;

	va_start(args, fmt);
	vsnprintf(detail, sizeof(detail), fmt, args);
	va_end(args);

	spock_monitor_append_event(type, subid, lsn, 0, detail, false);
}


/* ----------------------------------------------------------------------
 * Per-subscription counters
 * ----------------------------------------------------------------------
 */

static void
spock_monitor_reset_stats_entry(SpockMonitorStatsEntry *entry, TimestampTz now)
{
	memset(entry->counter, 0, sizeof(entry->counter));
	memset(entry->counter_time, 0, sizeof(entry->counter_time));
	entry->last_error_lsn = InvalidXLogRecPtr;
	entry->last_error_sqlerrcode = 0;
	entry->last_error_pid = 0;
	entry->last_error_message[0] = '\0';
	entry->stats_reset = now;
}

/*
 * Attach this worker to the counters of a subscription in the current
 * database, creating the entry when needed.  Returns NULL when the hash
 * table is full.  The entry stays allocated until the worker detaches.
 */
static SpockMonitorStatsEntry *
spock_monitor_attach_stats(Oid subid)
{
	SpockMonitorStatsKey key;
	SpockMonitorStatsEntry *entry;
	bool		found;

	if (SpockMonitorStatsHash == NULL)
		return NULL;

	memset(&key, 0, sizeof(key));
	key.dboid = MyDatabaseId;
	key.subid = subid;

	LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);

	/* The hash has a fixed size, so HASH_ENTER_NULL returns NULL when full. */
	entry = hash_search(SpockMonitorStatsHash, &key, HASH_ENTER_NULL, &found);

	if (entry != NULL)
	{
		if (!found)
		{
			SpinLockInit(&entry->mutex);
			spock_monitor_reset_stats_entry(entry, 0);
			entry->nattached = 0;
			entry->dropped = false;
		}
		else if (entry->dropped)
		{
			/* The id was reused before the old worker went away. */
			SpinLockAcquire(&entry->mutex);
			spock_monitor_reset_stats_entry(entry, 0);
			SpinLockRelease(&entry->mutex);
			entry->dropped = false;
		}
		entry->nattached++;
	}

	LWLockRelease(SpockMonitorShm->lock);

	if (entry == NULL)
		elog(LOG, "spock monitor statistics table is full, "
			 "no counters for subscription %u", subid);

	return entry;
}

/*
 * Detach this worker from its counters, removing the entry when the
 * subscription was dropped meanwhile and no other worker uses it.
 */
static void
spock_monitor_detach_stats(void)
{
	SpockMonitorStatsEntry *entry = MySpockMonitorStats;

	if (entry == NULL)
		return;

	LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);
	Assert(entry->nattached > 0);
	entry->nattached--;
	if (entry->dropped && entry->nattached == 0)
		hash_search(SpockMonitorStatsHash, &entry->key, HASH_REMOVE, NULL);
	LWLockRelease(SpockMonitorShm->lock);

	MySpockMonitorStats = NULL;
}

/*
 * Add delta to a counter of the subscription this worker serves.
 */
void
spock_monitor_count(SpockMonitorCounter counter, int64 delta)
{
	SpockMonitorStatsEntry *entry = MySpockMonitorStats;

	Assert(counter >= 0 && counter < SPOCK_MONITOR_NUM_COUNTERS);

	if (entry == NULL)
		return;

	SpinLockAcquire(&entry->mutex);
	entry->counter[counter] += delta;
	entry->counter_time[counter] = GetCurrentTimestamp();
	SpinLockRelease(&entry->mutex);
}

/*
 * One data message arrived from the provider.
 */
void
spock_monitor_message_received(int nbytes)
{
	SpockMonitorStatsEntry *entry = MySpockMonitorStats;
	TimestampTz now;

	if (entry == NULL)
		return;

	now = GetCurrentTimestamp();

	SpinLockAcquire(&entry->mutex);
	entry->counter[SPOCK_MONITOR_MESSAGES_RECEIVED]++;
	entry->counter_time[SPOCK_MONITOR_MESSAGES_RECEIVED] = now;
	entry->counter[SPOCK_MONITOR_BYTES_RECEIVED] += nbytes;
	entry->counter_time[SPOCK_MONITOR_BYTES_RECEIVED] = now;
	SpinLockRelease(&entry->mutex);
}

static void
spock_monitor_set_error(const char *message, XLogRecPtr lsn, int sqlerrcode,
						SpockMonitorCounter counter)
{
	SpockMonitorStatsEntry *entry = MySpockMonitorStats;
	TimestampTz now;
	SpockMonitorCounter class_counter = SPOCK_MONITOR_NUM_COUNTERS;

	if (entry == NULL)
		return;

	/* Classes an operator acts on differently from a data error. */
	if (sqlerrcode == ERRCODE_T_R_DEADLOCK_DETECTED)
		class_counter = SPOCK_MONITOR_DEADLOCKS;
	else if (sqlerrcode == ERRCODE_LOCK_NOT_AVAILABLE)
		class_counter = SPOCK_MONITOR_LOCK_TIMEOUTS;
	else if (ERRCODE_TO_CATEGORY(sqlerrcode) == ERRCODE_INTEGRITY_CONSTRAINT_VIOLATION)
		class_counter = SPOCK_MONITOR_CONSTRAINT_VIOLATIONS;
	else if (ERRCODE_TO_CATEGORY(sqlerrcode) == ERRCODE_INSUFFICIENT_RESOURCES)
		class_counter = SPOCK_MONITOR_RESOURCE_ERRORS;

	now = GetCurrentTimestamp();

	SpinLockAcquire(&entry->mutex);
	entry->counter[counter]++;
	entry->counter_time[counter] = now;
	if (class_counter != SPOCK_MONITOR_NUM_COUNTERS)
	{
		entry->counter[class_counter]++;
		entry->counter_time[class_counter] = now;
	}
	entry->last_error_lsn = lsn;
	entry->last_error_sqlerrcode = sqlerrcode;
	entry->last_error_pid = MyProcPid;
	strlcpy(entry->last_error_message, message, SPOCK_MONITOR_MESSAGE_LEN);
	SpinLockRelease(&entry->mutex);
}

/*
 * Message, detail and context of an error on one line.  Runs inside error
 * reporting, so it writes into the caller's buffer and allocates nothing.
 */
static void
spock_monitor_format_error(ErrorData *edata, char *buf, Size len)
{
	int			n;

	n = snprintf(buf, len, "%s", edata->message);
	if (edata->detail != NULL && n >= 0 && n < len)
		n += snprintf(buf + n, len - n, " DETAIL: %s", edata->detail);
	if (edata->context != NULL && n >= 0 && n < len)
		snprintf(buf + n, len - n, " CONTEXT: %s", edata->context);
}

/*
 * Called by spock_worker_attach() once the worker is registered in shared
 * memory and connected to its database.
 */
void
spock_monitor_worker_attached(void)
{
	SpockWorker *worker = MySpockWorker;

	if (worker == NULL)
		return;

	switch (worker->worker_type)
	{
		case SPOCK_WORKER_MANAGER:
			spock_monitor_record_event(SPOCK_EVENT_WORKER_STARTED,
									   InvalidOid, InvalidXLogRecPtr,
									   "manager worker");
			break;

		case SPOCK_WORKER_APPLY:
			MySpockMonitorStats =
				spock_monitor_attach_stats(worker->worker.apply.subid);
			spock_monitor_count(SPOCK_MONITOR_WORKER_STARTS, 1);
			spock_monitor_record_event(SPOCK_EVENT_WORKER_STARTED,
									   worker->worker.apply.subid,
									   InvalidXLogRecPtr,
									   "apply worker");
			break;

		case SPOCK_WORKER_SYNC:
			MySpockMonitorStats =
				spock_monitor_attach_stats(worker->worker.apply.subid);
			spock_monitor_count(SPOCK_MONITOR_WORKER_STARTS, 1);
			spock_monitor_record_event(SPOCK_EVENT_WORKER_STARTED,
									   worker->worker.apply.subid,
									   InvalidXLogRecPtr,
									   "sync worker for table %s.%s",
									   NameStr(worker->worker.sync.nspname),
									   NameStr(worker->worker.sync.relname));
			break;

		default:
			break;
	}
}

/*
 * Called by spock_worker_detach() before the worker slot is released.
 */
void
spock_monitor_worker_detached(bool crash)
{
	SpockWorker *worker = MySpockWorker;
	Oid			subid = InvalidOid;

	if (worker == NULL)
		return;

	if (worker->worker_type == SPOCK_WORKER_APPLY ||
		worker->worker_type == SPOCK_WORKER_SYNC)
		subid = worker->worker.apply.subid;

	if (crash)
	{
		char		message[SPOCK_MONITOR_MESSAGE_LEN];

		message[0] = '\0';
		if (MySpockMonitorStats != NULL)
		{
			SpinLockAcquire(&MySpockMonitorStats->mutex);
			MySpockMonitorStats->counter[SPOCK_MONITOR_WORKER_FAILURES]++;
			MySpockMonitorStats->counter_time[SPOCK_MONITOR_WORKER_FAILURES] =
				GetCurrentTimestamp();

			/* Only an error this process raised explains this exit. */
			if (MySpockMonitorStats->last_error_pid == MyProcPid)
				strlcpy(message, MySpockMonitorStats->last_error_message,
						sizeof(message));
			SpinLockRelease(&MySpockMonitorStats->mutex);
		}

		spock_monitor_record_event(SPOCK_EVENT_WORKER_FAILED, subid,
								   InvalidXLogRecPtr,
								   "%s worker exited with error%s%s",
								   spock_worker_type_name(worker->worker_type),
								   message[0] != '\0' ? ": " : "",
								   message);
	}
	else
		spock_monitor_record_event(SPOCK_EVENT_WORKER_STOPPED, subid,
								   InvalidXLogRecPtr,
								   "%s worker exited cleanly",
								   spock_worker_type_name(worker->worker_type));

	spock_monitor_detach_stats();
}

/*
 * Connection to the provider established; streaming starts at start_lsn.
 */
void
spock_monitor_provider_connected(const char *slot_name, XLogRecPtr start_lsn)
{
	Oid			subid = InvalidOid;

	if (MySpockWorker != NULL &&
		(MySpockWorker->worker_type == SPOCK_WORKER_APPLY ||
		 MySpockWorker->worker_type == SPOCK_WORKER_SYNC))
		subid = MySpockWorker->worker.apply.subid;

	spock_monitor_count(SPOCK_MONITOR_PROVIDER_CONNECTS, 1);
	spock_monitor_record_event(SPOCK_EVENT_PROVIDER_CONNECTED, subid, start_lsn,
							   "streaming from provider %s through slot %s",
							   MySubscription ? MySubscription->origin->name : "unknown",
							   slot_name);
}

/*
 * Connection to the provider lost.  Called from the apply worker's error
 * handler with the error message.
 */
void
spock_monitor_provider_disconnected(const char *message)
{
	Oid			subid = InvalidOid;

	if (MySpockWorker != NULL &&
		(MySpockWorker->worker_type == SPOCK_WORKER_APPLY ||
		 MySpockWorker->worker_type == SPOCK_WORKER_SYNC))
		subid = MySpockWorker->worker.apply.subid;

	spock_monitor_count(SPOCK_MONITOR_PROVIDER_DISCONNECTS, 1);
	spock_monitor_record_event(SPOCK_EVENT_PROVIDER_DISCONNECTED, subid,
							   InvalidXLogRecPtr, "provider %s: %s",
							   MySubscription ? MySubscription->origin->name : "unknown",
							   message ? message : "missing error text");

	/*
	 * The caller rethrows the error and the worker exits; that report must
	 * not be counted a second time as an apply error.
	 */
	spock_monitor_disconnect_reported = true;
}

/*
 * Errors that mean the peer went away or is not ready rather than that
 * anything is wrong with the data.  apply_work() uses the same test to
 * choose its connection-loss branch; such errors are reported through
 * spock_monitor_provider_disconnected() and never count as apply errors.
 */
bool
spock_monitor_is_connection_error(int sqlerrcode)
{
	return (sqlerrcode == ERRCODE_CONNECTION_FAILURE ||
			sqlerrcode == ERRCODE_CONNECTION_EXCEPTION ||
			sqlerrcode == ERRCODE_CONNECTION_DOES_NOT_EXIST ||
			sqlerrcode == ERRCODE_ADMIN_SHUTDOWN ||
			sqlerrcode == ERRCODE_CRASH_SHUTDOWN ||
			sqlerrcode == ERRCODE_CANNOT_CONNECT_NOW);
}

/*
 * emit_log_hook entry: remember every ERROR or FATAL raised in a spock
 * worker as the last error of its subscription and as an event, and every
 * error raised in a walsender running the spock output plugin as a
 * stream_error event.
 *
 * This runs inside error reporting, so it must not allocate memory, must
 * not raise errors of its own and must not block.
 */
void
spock_monitor_report_error(ErrorData *edata)
{
	static bool in_report = false;
	SpockWorker *worker = MySpockWorker;
	char		message[SPOCK_MONITOR_MESSAGE_LEN];
	Oid			subid = InvalidOid;

	if (in_report || SpockMonitorShm == NULL)
		return;
	if (worker == NULL && !spock_monitor_in_stream)
		return;
	if (edata->elevel < ERROR || edata->elevel >= PANIC)
		return;
	if (edata->message == NULL)
		return;

	/*
	 * A peer going away or a termination by an administrator is not a
	 * fault of this node.  The apply worker reports its connection losses
	 * as provider_disconnected, and flags the rethrow that follows.
	 */
	if (spock_monitor_is_connection_error(edata->sqlerrcode) ||
		spock_monitor_disconnect_reported)
	{
		spock_monitor_disconnect_reported = false;
		return;
	}

	in_report = true;

	spock_monitor_format_error(edata, message, sizeof(message));

	if (worker == NULL)
	{
		char		detail[SPOCK_MONITOR_MESSAGE_LEN];

		snprintf(detail, sizeof(detail), "slot %s: %s",
				 NameStr(spock_monitor_stream_slot), message);
		spock_monitor_append_event(SPOCK_EVENT_STREAM_ERROR, InvalidOid,
								   InvalidXLogRecPtr, edata->sqlerrcode,
								   detail, true);
		in_report = false;
		return;
	}

	if (worker->worker_type == SPOCK_WORKER_APPLY)
	{
		subid = worker->worker.apply.subid;
		spock_monitor_set_error(message, replorigin_session_origin_lsn,
								edata->sqlerrcode, SPOCK_MONITOR_APPLY_ERRORS);
	}
	else if (worker->worker_type == SPOCK_WORKER_SYNC)
	{
		subid = worker->worker.apply.subid;
		spock_monitor_set_error(message, replorigin_session_origin_lsn,
								edata->sqlerrcode, SPOCK_MONITOR_SYNC_ERRORS);
	}

	spock_monitor_append_event(SPOCK_EVENT_WORKER_ERROR, subid,
							   replorigin_session_origin_lsn,
							   edata->sqlerrcode, message, true);

	in_report = false;
}

/*
 * The output plugin started or stopped in this walsender.  While a stream
 * is active, errors of this process are reported as stream_error events.
 */
void
spock_monitor_stream_started(const char *slot_name)
{
	namestrcpy(&spock_monitor_stream_slot, slot_name);
	spock_monitor_in_stream = true;
}

void
spock_monitor_stream_stopped(void)
{
	spock_monitor_in_stream = false;
}

/*
 * A subscription was created.  A subscription id may be reused after a
 * drop, so make sure no stale counters are left behind.
 */
void
spock_monitor_create_subscription(Oid subid)
{
	spock_monitor_drop_subscription(subid);
}

/*
 * A subscription was dropped: forget its counters.  While a worker is
 * still attached the entry is only marked, and the last worker to detach
 * removes it.
 */
void
spock_monitor_drop_subscription(Oid subid)
{
	SpockMonitorStatsKey key;
	SpockMonitorStatsEntry *entry;

	if (SpockMonitorStatsHash == NULL)
		return;

	memset(&key, 0, sizeof(key));
	key.dboid = MyDatabaseId;
	key.subid = subid;

	LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);
	entry = hash_search(SpockMonitorStatsHash, &key, HASH_FIND, NULL);
	if (entry != NULL)
	{
		if (entry->nattached > 0)
			entry->dropped = true;
		else
			hash_search(SpockMonitorStatsHash, &key, HASH_REMOVE, NULL);
	}
	LWLockRelease(SpockMonitorShm->lock);
}


/* ----------------------------------------------------------------------
 * SQL functions
 * ----------------------------------------------------------------------
 */

static Datum
timestamptz_or_null(TimestampTz ts, bool *isnull)
{
	if (ts == 0)
	{
		*isnull = true;
		return (Datum) 0;
	}

	*isnull = false;
	return TimestampTzGetDatum(ts);
}

static void
check_monitor_shmem(void)
{
	if (SpockCtx == NULL || SpockMonitorShm == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("spock must be loaded via shared_preload_libraries")));
}

/*
 * spock.get_events()
 *
 * The recorded events, oldest first.
 */
Datum
spock_get_events(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	int			i;

	enum
	{
		EV_EVENT_ID = 0,
		EV_EVENT_TIME,
		EV_EVENT_TYPE,
		EV_SEVERITY,
		EV_SQLSTATE,
		EV_DATABASE_ID,
		EV_SUBSCRIPTION_ID,
		EV_PID,
		EV_LSN,
		EV_DETAIL,
		EV_NUM_COLUMNS
	};

	SpockMonitorEvent *events;
	int			nevents;

	check_monitor_shmem();
	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == EV_NUM_COLUMNS);

	/*
	 * Copy the ring while holding the lock and format afterwards, so that
	 * workers reporting errors, which only try the lock, are not held off
	 * for the whole result.
	 */
	LWLockAcquire(SpockMonitorShm->lock, LW_SHARED);
	nevents = SpockMonitorShm->event_count;
	events = palloc(Max(nevents, 1) * sizeof(SpockMonitorEvent));
	for (i = 0; i < nevents; i++)
	{
		int			idx;

		idx = (SpockMonitorShm->event_head + i) % SpockMonitorShm->event_capacity;
		events[i] = SpockMonitorShm->events[idx];
	}
	LWLockRelease(SpockMonitorShm->lock);

	for (i = 0; i < nevents; i++)
	{
		SpockMonitorEvent *event = &events[i];
		Datum		values[EV_NUM_COLUMNS];
		bool		nulls[EV_NUM_COLUMNS] = {0};

		values[EV_EVENT_ID] = Int64GetDatum((int64) event->event_id);
		values[EV_EVENT_TIME] = TimestampTzGetDatum(event->event_time);
		values[EV_EVENT_TYPE] =
			CStringGetTextDatum(SpockMonitorEventInfos[event->event_type].name);
		values[EV_SEVERITY] =
			CStringGetTextDatum(SpockMonitorSeverityNames[SpockMonitorEventInfos[event->event_type].severity]);

		if (event->sqlerrcode != 0)
			values[EV_SQLSTATE] =
				CStringGetTextDatum(unpack_sql_state(event->sqlerrcode));
		else
			nulls[EV_SQLSTATE] = true;

		if (OidIsValid(event->dboid))
			values[EV_DATABASE_ID] = ObjectIdGetDatum(event->dboid);
		else
			nulls[EV_DATABASE_ID] = true;

		if (OidIsValid(event->subid))
			values[EV_SUBSCRIPTION_ID] = ObjectIdGetDatum(event->subid);
		else
			nulls[EV_SUBSCRIPTION_ID] = true;

		values[EV_PID] = Int32GetDatum(event->pid);

		if (!XLogRecPtrIsInvalid(event->lsn))
			values[EV_LSN] = LSNGetDatum(event->lsn);
		else
			nulls[EV_LSN] = true;

		if (event->detail[0] != '\0')
			values[EV_DETAIL] = CStringGetTextDatum(event->detail);
		else
			nulls[EV_DETAIL] = true;

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	pfree(events);

	return (Datum) 0;
}

/*
 * spock.reset_events()
 *
 * Empty the event history.  Event ids keep increasing.
 */
Datum
spock_reset_events(PG_FUNCTION_ARGS)
{
	check_monitor_shmem();

	LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);
	SpockMonitorShm->event_head = 0;
	SpockMonitorShm->event_count = 0;
	LWLockRelease(SpockMonitorShm->lock);

	PG_RETURN_VOID();
}

/*
 * Human readable state of a worker slot.
 */
static const char *
spock_worker_status_name(SpockWorker *worker)
{
	if (worker->proc == NULL)
		return worker->terminated_at != 0 ? "restart pending" : "starting";

	if (worker->worker_type == SPOCK_WORKER_MANAGER)
		return "running";

	switch (worker->worker_status)
	{
		case SPOCK_WORKER_STATUS_NONE:
			return "starting";
		case SPOCK_WORKER_STATUS_IDLE:
			return "idle";
		case SPOCK_WORKER_STATUS_RUNNING:
			return "running";
		case SPOCK_WORKER_STATUS_STOPPING:
			return "stopping";
		case SPOCK_WORKER_STATUS_STOPPED:
			return "stopped";
		case SPOCK_WORKER_STATUS_FAILED:
			return "failed";
	}

	return "unknown";
}

/*
 * spock.get_worker_status()
 *
 * One row per registered spock worker plus one for the supervisor.  Slots
 * of workers that exited with an error stay listed until the manager has
 * restarted them, with status "restart pending".
 */
Datum
spock_get_worker_status(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	int			i;

	enum
	{
		WS_WORKER_SLOT = 0,
		WS_WORKER_TYPE,
		WS_PID,
		WS_DATABASE_ID,
		WS_SUBSCRIPTION_ID,
		WS_WORKER_STATUS,
		WS_GENERATION,
		WS_TERMINATED_AT,
		WS_RESTART_DELAY,
		WS_PAUSED,
		WS_IN_EXCEPTION_HANDLING,
		WS_SYNC_PENDING,
		WS_REPLAY_STOP_LSN,
		WS_REMOTE_WAL_INSERT_LSN,
		WS_SYNC_SCHEMA_NAME,
		WS_SYNC_TABLE_NAME,
		WS_NUM_COLUMNS
	};

	check_monitor_shmem();
	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == WS_NUM_COLUMNS);

	LWLockAcquire(SpockCtx->lock, LW_SHARED);

	if (SpockCtx->supervisor != NULL)
	{
		Datum		values[WS_NUM_COLUMNS] = {0};
		bool		nulls[WS_NUM_COLUMNS];

		memset(nulls, true, sizeof(nulls));
		values[WS_WORKER_TYPE] = CStringGetTextDatum("supervisor");
		nulls[WS_WORKER_TYPE] = false;
		values[WS_PID] = Int32GetDatum(SpockCtx->supervisor->pid);
		nulls[WS_PID] = false;
		values[WS_WORKER_STATUS] = CStringGetTextDatum("running");
		nulls[WS_WORKER_STATUS] = false;

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	for (i = 0; i < SpockCtx->total_workers; i++)
	{
		SpockWorker *worker = &SpockCtx->workers[i];
		Datum		values[WS_NUM_COLUMNS] = {0};
		bool		nulls[WS_NUM_COLUMNS] = {0};

		if (worker->worker_type == SPOCK_WORKER_NONE)
			continue;

		values[WS_WORKER_SLOT] = Int32GetDatum(i);
		values[WS_WORKER_TYPE] =
			CStringGetTextDatum(spock_worker_type_name(worker->worker_type));

		if (worker->proc != NULL)
			values[WS_PID] = Int32GetDatum(worker->proc->pid);
		else
			nulls[WS_PID] = true;

		if (OidIsValid(worker->dboid))
			values[WS_DATABASE_ID] = ObjectIdGetDatum(worker->dboid);
		else
			nulls[WS_DATABASE_ID] = true;

		values[WS_WORKER_STATUS] =
			CStringGetTextDatum(spock_worker_status_name(worker));
		values[WS_GENERATION] = Int32GetDatum((int32) worker->generation);
		values[WS_TERMINATED_AT] =
			timestamptz_or_null(worker->terminated_at, &nulls[WS_TERMINATED_AT]);
		values[WS_RESTART_DELAY] = Int32GetDatum(worker->restart_delay);

		if (worker->worker_type == SPOCK_WORKER_APPLY ||
			worker->worker_type == SPOCK_WORKER_SYNC)
		{
			SpockApplyWorker *apply = &worker->worker.apply;

			values[WS_SUBSCRIPTION_ID] = ObjectIdGetDatum(apply->subid);
			values[WS_PAUSED] = BoolGetDatum(apply->paused);
			values[WS_IN_EXCEPTION_HANDLING] = BoolGetDatum(apply->use_try_block);
			values[WS_SYNC_PENDING] = BoolGetDatum(apply->sync_pending);

			if (!XLogRecPtrIsInvalid(apply->replay_stop_lsn))
				values[WS_REPLAY_STOP_LSN] = LSNGetDatum(apply->replay_stop_lsn);
			else
				nulls[WS_REPLAY_STOP_LSN] = true;

			if (!XLogRecPtrIsInvalid(worker->remote_wal_insert_lsn))
				values[WS_REMOTE_WAL_INSERT_LSN] =
					LSNGetDatum(worker->remote_wal_insert_lsn);
			else
				nulls[WS_REMOTE_WAL_INSERT_LSN] = true;
		}
		else
		{
			nulls[WS_SUBSCRIPTION_ID] = true;
			nulls[WS_PAUSED] = true;
			nulls[WS_IN_EXCEPTION_HANDLING] = true;
			nulls[WS_SYNC_PENDING] = true;
			nulls[WS_REPLAY_STOP_LSN] = true;
			nulls[WS_REMOTE_WAL_INSERT_LSN] = true;
		}

		if (worker->worker_type == SPOCK_WORKER_SYNC)
		{
			values[WS_SYNC_SCHEMA_NAME] =
				NameGetDatum(&worker->worker.sync.nspname);
			values[WS_SYNC_TABLE_NAME] =
				NameGetDatum(&worker->worker.sync.relname);
		}
		else
		{
			nulls[WS_SYNC_SCHEMA_NAME] = true;
			nulls[WS_SYNC_TABLE_NAME] = true;
		}

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	LWLockRelease(SpockCtx->lock);

	return (Datum) 0;
}

/*
 * spock.get_apply_stats()
 *
 * The activity counters of every subscription of the current database,
 * with the conflict counters of the pgstat subsystem where available.
 */
Datum
spock_get_apply_stats(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	HASH_SEQ_STATUS hash_seq;
	SpockMonitorStatsEntry *entry;
	SpockMonitorStatsEntry *entries;
	int			nentries = 0;
	int			e;

	enum
	{
		AS_DATABASE_ID = 0,
		AS_SUBSCRIPTION_ID,
		AS_WORKER_STARTS,
		AS_WORKER_FAILURES,
		AS_PROVIDER_CONNECTS,
		AS_PROVIDER_DISCONNECTS,
		AS_IDLE_TIMEOUTS,
		AS_MESSAGES_RECEIVED,
		AS_BYTES_RECEIVED,
		AS_XACTS_APPLIED,
		AS_XACTS_SKIPPED,
		AS_XACTS_DISCARDED,
		AS_APPLY_ERRORS,
		AS_SYNC_ERRORS,
		AS_DEADLOCKS,
		AS_LOCK_TIMEOUTS,
		AS_CONSTRAINT_VIOLATIONS,
		AS_RESOURCE_ERRORS,
		AS_TABLES_SYNCED,
		AS_CONFL_FIRST,
		AS_CONFL_LAST = AS_CONFL_FIRST + SPOCK_CONFLICT_NUM_TYPES - 1,
		AS_LAST_WORKER_START,
		AS_LAST_WORKER_FAILURE,
		AS_LAST_PROVIDER_CONNECT,
		AS_LAST_PROVIDER_DISCONNECT,
		AS_LAST_MESSAGE_RECEIVED,
		AS_LAST_XACT_APPLIED,
		AS_LAST_APPLY_ERROR,
		AS_LAST_SYNC_ERROR,
		AS_LAST_TABLE_SYNCED,
		AS_LAST_ERROR_MESSAGE,
		AS_LAST_ERROR_LSN,
		AS_LAST_ERROR_SQLSTATE,
		AS_LAST_ERROR_PID,
		AS_STATS_RESET,
		AS_NUM_COLUMNS
	};

	/* Counter feeding each of the plain count columns, in column order. */
	static const SpockMonitorCounter count_columns[] = {
		SPOCK_MONITOR_WORKER_STARTS,
		SPOCK_MONITOR_WORKER_FAILURES,
		SPOCK_MONITOR_PROVIDER_CONNECTS,
		SPOCK_MONITOR_PROVIDER_DISCONNECTS,
		SPOCK_MONITOR_IDLE_TIMEOUTS,
		SPOCK_MONITOR_MESSAGES_RECEIVED,
		SPOCK_MONITOR_BYTES_RECEIVED,
		SPOCK_MONITOR_XACTS_APPLIED,
		SPOCK_MONITOR_XACTS_SKIPPED,
		SPOCK_MONITOR_XACTS_DISCARDED,
		SPOCK_MONITOR_APPLY_ERRORS,
		SPOCK_MONITOR_SYNC_ERRORS,
		SPOCK_MONITOR_DEADLOCKS,
		SPOCK_MONITOR_LOCK_TIMEOUTS,
		SPOCK_MONITOR_CONSTRAINT_VIOLATIONS,
		SPOCK_MONITOR_RESOURCE_ERRORS,
		SPOCK_MONITOR_TABLES_SYNCED
	};

	/* Counter whose last change feeds each of the timestamp columns. */
	static const SpockMonitorCounter time_columns[] = {
		SPOCK_MONITOR_WORKER_STARTS,
		SPOCK_MONITOR_WORKER_FAILURES,
		SPOCK_MONITOR_PROVIDER_CONNECTS,
		SPOCK_MONITOR_PROVIDER_DISCONNECTS,
		SPOCK_MONITOR_MESSAGES_RECEIVED,
		SPOCK_MONITOR_XACTS_APPLIED,
		SPOCK_MONITOR_APPLY_ERRORS,
		SPOCK_MONITOR_SYNC_ERRORS,
		SPOCK_MONITOR_TABLES_SYNCED
	};

	StaticAssertStmt(lengthof(count_columns) == AS_CONFL_FIRST - AS_WORKER_STARTS,
					 "count column list out of sync");
	StaticAssertStmt(lengthof(time_columns) == AS_LAST_ERROR_MESSAGE - AS_LAST_WORKER_START,
					 "timestamp column list out of sync");

	check_monitor_shmem();
	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == AS_NUM_COLUMNS);

	/*
	 * Copy the entries of this database while holding the lock; the pgstat
	 * lookups and the formatting below run without it.
	 */
	LWLockAcquire(SpockMonitorShm->lock, LW_SHARED);
	entries = palloc(Max(hash_get_num_entries(SpockMonitorStatsHash), 1) *
					 sizeof(SpockMonitorStatsEntry));
	hash_seq_init(&hash_seq, SpockMonitorStatsHash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		if (entry->key.dboid != MyDatabaseId || entry->dropped)
			continue;

		SpinLockAcquire(&entry->mutex);
		memcpy(&entries[nentries], entry, sizeof(SpockMonitorStatsEntry));
		SpinLockRelease(&entry->mutex);
		nentries++;
	}
	LWLockRelease(SpockMonitorShm->lock);

	for (e = 0; e < nentries; e++)
	{
		SpockMonitorStatsEntry copy = entries[e];
		Datum		values[AS_NUM_COLUMNS] = {0};
		bool		nulls[AS_NUM_COLUMNS] = {0};
		int			col;
		int			i;

		values[AS_DATABASE_ID] = ObjectIdGetDatum(copy.key.dboid);
		values[AS_SUBSCRIPTION_ID] = ObjectIdGetDatum(copy.key.subid);

		col = AS_WORKER_STARTS;
		for (i = 0; i < lengthof(count_columns); i++)
			values[col++] = Int64GetDatum(copy.counter[count_columns[i]]);

		for (col = AS_CONFL_FIRST; col <= AS_CONFL_LAST; col++)
			nulls[col] = true;
#if PG_VERSION_NUM >= 180000
		{
			Spock_Stat_StatSubEntry *confl;

			confl = spock_stat_fetch_stat_subscription(copy.key.subid);
			for (i = 0; i < SPOCK_CONFLICT_NUM_TYPES; i++)
			{
				col = AS_CONFL_FIRST + i;
				values[col] = Int64GetDatum(confl ? confl->conflict_count[i] : 0);
				nulls[col] = false;
			}
		}
#endif

		col = AS_LAST_WORKER_START;
		for (i = 0; i < lengthof(time_columns); i++)
		{
			values[col] = timestamptz_or_null(copy.counter_time[time_columns[i]],
											  &nulls[col]);
			col++;
		}

		if (copy.last_error_message[0] != '\0')
			values[AS_LAST_ERROR_MESSAGE] =
				CStringGetTextDatum(copy.last_error_message);
		else
			nulls[AS_LAST_ERROR_MESSAGE] = true;

		if (!XLogRecPtrIsInvalid(copy.last_error_lsn))
			values[AS_LAST_ERROR_LSN] = LSNGetDatum(copy.last_error_lsn);
		else
			nulls[AS_LAST_ERROR_LSN] = true;

		if (copy.last_error_sqlerrcode != 0)
			values[AS_LAST_ERROR_SQLSTATE] =
				CStringGetTextDatum(unpack_sql_state(copy.last_error_sqlerrcode));
		else
			nulls[AS_LAST_ERROR_SQLSTATE] = true;

		if (copy.last_error_pid != 0)
			values[AS_LAST_ERROR_PID] = Int32GetDatum(copy.last_error_pid);
		else
			nulls[AS_LAST_ERROR_PID] = true;

		values[AS_STATS_RESET] =
			timestamptz_or_null(copy.stats_reset, &nulls[AS_STATS_RESET]);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	pfree(entries);

	return (Datum) 0;
}

/*
 * spock.reset_subscription_stats(subid)
 *
 * Reset the activity and conflict counters of one subscription, or of all
 * subscriptions when called with NULL.
 */
Datum
spock_reset_subscription_stats(PG_FUNCTION_ARGS)
{
	Oid			subid = InvalidOid;
	TimestampTz now = GetCurrentTimestamp();
	HASH_SEQ_STATUS hash_seq;
	SpockMonitorStatsEntry *entry;

	check_monitor_shmem();

	if (!PG_ARGISNULL(0))
	{
		subid = PG_GETARG_OID(0);

		if (!OidIsValid(subid))
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("invalid subscription OID %u", subid)));
	}

	LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);

	hash_seq_init(&hash_seq, SpockMonitorStatsHash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		if (entry->key.dboid != MyDatabaseId || entry->dropped)
			continue;
		if (OidIsValid(subid) && entry->key.subid != subid)
			continue;

		SpinLockAcquire(&entry->mutex);
		spock_monitor_reset_stats_entry(entry, now);
		SpinLockRelease(&entry->mutex);
	}

	LWLockRelease(SpockMonitorShm->lock);

#if PG_VERSION_NUM >= 180000
	spock_stat_reset_subscription_conflicts(subid);
#endif

	PG_RETURN_VOID();
}

/*
 * spock.get_slot_groups()
 *
 * Shared state of the slot groups used by parallel replication slots on
 * the provider side.
 */
Datum
spock_get_slot_groups(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	int			i;

	enum
	{
		SG_SLOT_GROUP_NAME = 0,
		SG_MEMBERS,
		SG_LAST_LSN,
		SG_LAST_COMMIT_TS,
		SG_NUM_COLUMNS
	};

	check_monitor_shmem();
	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == SG_NUM_COLUMNS);

	LWLockAcquire(SpockCtx->slot_group_master_lock, LW_SHARED);

	for (i = 0; i < SpockCtx->slot_ngroups; i++)
	{
		SpockOutputSlotGroup *group = &SpockCtx->slot_groups[i];
		Datum		values[SG_NUM_COLUMNS] = {0};
		bool		nulls[SG_NUM_COLUMNS] = {0};

		if (group->nattached <= 0)
			continue;

		LWLockAcquire(group->lock, LW_SHARED);
		values[SG_SLOT_GROUP_NAME] = NameGetDatum(&group->name);
		values[SG_MEMBERS] = Int32GetDatum(group->nattached);
		if (!XLogRecPtrIsInvalid(group->last_lsn))
			values[SG_LAST_LSN] = LSNGetDatum(group->last_lsn);
		else
			nulls[SG_LAST_LSN] = true;
		values[SG_LAST_COMMIT_TS] =
			timestamptz_or_null(group->last_commit_ts, &nulls[SG_LAST_COMMIT_TS]);
		LWLockRelease(group->lock);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	LWLockRelease(SpockCtx->slot_group_master_lock);

	return (Datum) 0;
}

/*
 * spock.get_monitor_summary()
 *
 * One row with the state of the shared memory structures of this node.
 */
Datum
spock_get_monitor_summary(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	HeapTuple	tuple;
	int			i;
	int			slots_used = 0;

	enum
	{
		MS_STARTED_AT = 0,
		MS_SUPERVISOR_PID,
		MS_WORKER_SLOTS,
		MS_WORKER_SLOTS_USED,
		MS_APPLY_PAUSED,
		MS_EVENTS_CAPACITY,
		MS_EVENTS_RETAINED,
		MS_EVENTS_RECORDED,
		MS_SUBSCRIPTION_STATS_CAPACITY,
		MS_SUBSCRIPTION_STATS_USED,
		MS_CHANNEL_STATS_CAPACITY,
		MS_CHANNEL_STATS_USED,
		MS_CHANNEL_STATS_FULL,
		MS_NUM_COLUMNS
	};

	Datum		values[MS_NUM_COLUMNS] = {0};
	bool		nulls[MS_NUM_COLUMNS] = {0};

	check_monitor_shmem();

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");
	tupdesc = BlessTupleDesc(tupdesc);
	Assert(tupdesc->natts == MS_NUM_COLUMNS);

	LWLockAcquire(SpockCtx->lock, LW_SHARED);
	for (i = 0; i < SpockCtx->total_workers; i++)
	{
		if (SpockCtx->workers[i].worker_type != SPOCK_WORKER_NONE)
			slots_used++;
	}
	if (SpockCtx->supervisor != NULL)
		values[MS_SUPERVISOR_PID] = Int32GetDatum(SpockCtx->supervisor->pid);
	else
		nulls[MS_SUPERVISOR_PID] = true;
	values[MS_WORKER_SLOTS] = Int32GetDatum(SpockCtx->total_workers);
	values[MS_WORKER_SLOTS_USED] = Int32GetDatum(slots_used);
	values[MS_APPLY_PAUSED] =
		BoolGetDatum(pg_atomic_read_u32(&SpockCtx->pause_apply) != 0);
	values[MS_CHANNEL_STATS_CAPACITY] = Int32GetDatum(spock_stats_max_entries);
	values[MS_CHANNEL_STATS_USED] =
		Int64GetDatum(SpockHash ? hash_get_num_entries(SpockHash) : 0);
	values[MS_CHANNEL_STATS_FULL] = BoolGetDatum(spock_stats_hash_full);
	LWLockRelease(SpockCtx->lock);

	LWLockAcquire(SpockMonitorShm->lock, LW_SHARED);
	values[MS_STARTED_AT] = TimestampTzGetDatum(SpockMonitorShm->started_at);
	values[MS_EVENTS_CAPACITY] = Int32GetDatum(SpockMonitorShm->event_capacity);
	values[MS_EVENTS_RETAINED] = Int32GetDatum(SpockMonitorShm->event_count);
	values[MS_EVENTS_RECORDED] =
		Int64GetDatum((int64) (SpockMonitorShm->next_event_id - 1));
	values[MS_SUBSCRIPTION_STATS_CAPACITY] = Int32GetDatum(spock_monitor_max_stats);
	values[MS_SUBSCRIPTION_STATS_USED] =
		Int32GetDatum((int32) hash_get_num_entries(SpockMonitorStatsHash));
	LWLockRelease(SpockMonitorShm->lock);

	tuple = heap_form_tuple(tupdesc, values, nulls);

	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}


/*
 * spock.get_system_info()
 *
 * One row describing the host and the server: operating system, hardware
 * size, load, free space on the data and WAL volumes, postmaster start
 * time and the PostgreSQL and spock versions.
 */
Datum
spock_get_system_info(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	HeapTuple	tuple;
	char		hostname[256];

	enum
	{
		SI_HOSTNAME = 0,
		SI_OS_NAME,
		SI_OS_RELEASE,
		SI_OS_VERSION,
		SI_ARCHITECTURE,
		SI_CPU_COUNT,
		SI_MEMORY_BYTES,
		SI_LOAD_AVERAGE_1MIN,
		SI_LOAD_AVERAGE_5MIN,
		SI_LOAD_AVERAGE_15MIN,
		SI_DATA_DIRECTORY,
		SI_DATA_DISK_TOTAL_BYTES,
		SI_DATA_DISK_FREE_BYTES,
		SI_WAL_DISK_TOTAL_BYTES,
		SI_WAL_DISK_FREE_BYTES,
		SI_POSTMASTER_PID,
		SI_POSTMASTER_START_TIME,
		SI_POSTGRES_VERSION,
		SI_POSTGRES_VERSION_NUM,
		SI_SPOCK_VERSION,
		SI_SPOCK_VERSION_NUM,
		SI_PROTOCOL_VERSION,
		SI_MIN_PROTOCOL_VERSION,
		SI_NUM_COLUMNS
	};

	Datum		values[SI_NUM_COLUMNS] = {0};
	bool		nulls[SI_NUM_COLUMNS] = {0};

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");
	tupdesc = BlessTupleDesc(tupdesc);
	Assert(tupdesc->natts == SI_NUM_COLUMNS);

	if (gethostname(hostname, sizeof(hostname)) == 0)
	{
		hostname[sizeof(hostname) - 1] = '\0';
		values[SI_HOSTNAME] = CStringGetTextDatum(hostname);
	}
	else
		nulls[SI_HOSTNAME] = true;

#ifndef WIN32
	{
		struct utsname uts;

		if (uname(&uts) == 0)
		{
			values[SI_OS_NAME] = CStringGetTextDatum(uts.sysname);
			values[SI_OS_RELEASE] = CStringGetTextDatum(uts.release);
			values[SI_OS_VERSION] = CStringGetTextDatum(uts.version);
			values[SI_ARCHITECTURE] = CStringGetTextDatum(uts.machine);
		}
		else
		{
			nulls[SI_OS_NAME] = true;
			nulls[SI_OS_RELEASE] = true;
			nulls[SI_OS_VERSION] = true;
			nulls[SI_ARCHITECTURE] = true;
		}
	}
#else
	nulls[SI_OS_NAME] = true;
	nulls[SI_OS_RELEASE] = true;
	nulls[SI_OS_VERSION] = true;
	nulls[SI_ARCHITECTURE] = true;
#endif

#ifdef _SC_NPROCESSORS_ONLN
	{
		long		ncpu = sysconf(_SC_NPROCESSORS_ONLN);

		if (ncpu > 0)
			values[SI_CPU_COUNT] = Int32GetDatum((int32) ncpu);
		else
			nulls[SI_CPU_COUNT] = true;
	}
#else
	nulls[SI_CPU_COUNT] = true;
#endif

#if defined(_SC_PHYS_PAGES) && defined(_SC_PAGESIZE)
	{
		long		pages = sysconf(_SC_PHYS_PAGES);
		long		pagesize = sysconf(_SC_PAGESIZE);

		if (pages > 0 && pagesize > 0)
			values[SI_MEMORY_BYTES] = Int64GetDatum((int64) pages * (int64) pagesize);
		else
			nulls[SI_MEMORY_BYTES] = true;
	}
#else
	nulls[SI_MEMORY_BYTES] = true;
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
	{
		double		loads[3];

		if (getloadavg(loads, 3) == 3)
		{
			values[SI_LOAD_AVERAGE_1MIN] = Float8GetDatum(loads[0]);
			values[SI_LOAD_AVERAGE_5MIN] = Float8GetDatum(loads[1]);
			values[SI_LOAD_AVERAGE_15MIN] = Float8GetDatum(loads[2]);
		}
		else
		{
			nulls[SI_LOAD_AVERAGE_1MIN] = true;
			nulls[SI_LOAD_AVERAGE_5MIN] = true;
			nulls[SI_LOAD_AVERAGE_15MIN] = true;
		}
	}
#else
	nulls[SI_LOAD_AVERAGE_1MIN] = true;
	nulls[SI_LOAD_AVERAGE_5MIN] = true;
	nulls[SI_LOAD_AVERAGE_15MIN] = true;
#endif

	values[SI_DATA_DIRECTORY] = CStringGetTextDatum(DataDir);

#ifndef WIN32
	{
		struct statvfs fs;
		char		walpath[MAXPGPATH];

		if (statvfs(DataDir, &fs) == 0)
		{
			values[SI_DATA_DISK_TOTAL_BYTES] =
				Int64GetDatum((int64) fs.f_blocks * (int64) fs.f_frsize);
			values[SI_DATA_DISK_FREE_BYTES] =
				Int64GetDatum((int64) fs.f_bavail * (int64) fs.f_frsize);
		}
		else
		{
			nulls[SI_DATA_DISK_TOTAL_BYTES] = true;
			nulls[SI_DATA_DISK_FREE_BYTES] = true;
		}

		/* pg_wal may be a symlink to another volume, so measure it apart. */
		snprintf(walpath, sizeof(walpath), "%s/pg_wal", DataDir);
		if (statvfs(walpath, &fs) == 0)
		{
			values[SI_WAL_DISK_TOTAL_BYTES] =
				Int64GetDatum((int64) fs.f_blocks * (int64) fs.f_frsize);
			values[SI_WAL_DISK_FREE_BYTES] =
				Int64GetDatum((int64) fs.f_bavail * (int64) fs.f_frsize);
		}
		else
		{
			nulls[SI_WAL_DISK_TOTAL_BYTES] = true;
			nulls[SI_WAL_DISK_FREE_BYTES] = true;
		}
	}
#else
	nulls[SI_DATA_DISK_TOTAL_BYTES] = true;
	nulls[SI_DATA_DISK_FREE_BYTES] = true;
	nulls[SI_WAL_DISK_TOTAL_BYTES] = true;
	nulls[SI_WAL_DISK_FREE_BYTES] = true;
#endif

	values[SI_POSTMASTER_PID] = Int32GetDatum((int32) PostmasterPid);
	values[SI_POSTMASTER_START_TIME] = TimestampTzGetDatum(PgStartTime);
	values[SI_POSTGRES_VERSION] = CStringGetTextDatum(PG_VERSION_STR);
	values[SI_POSTGRES_VERSION_NUM] = Int32GetDatum(PG_VERSION_NUM);
	values[SI_SPOCK_VERSION] = CStringGetTextDatum(SPOCK_VERSION);
	values[SI_SPOCK_VERSION_NUM] = Int32GetDatum(SPOCK_VERSION_NUM);
	values[SI_PROTOCOL_VERSION] = Int32GetDatum(SPOCK_PROTO_VERSION_NUM);
	values[SI_MIN_PROTOCOL_VERSION] = Int32GetDatum(SPOCK_PROTO_MIN_VERSION_NUM);

	tuple = heap_form_tuple(tupdesc, values, nulls);

	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * spock.get_pending_exceptions()
 *
 * The transactions that apply workers are currently retrying under
 * spock.exception_behaviour: one row per shared exception log slot that
 * has an error recorded, with the commit LSN of the failed transaction.
 * The slot is keyed by subscription name; a slot with an LSN but no error
 * only marks the transaction in flight and is not reported.
 */
Datum
spock_get_pending_exceptions(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	int			i;

	enum
	{
		PE_SUBSCRIPTION_NAME = 0,
		PE_COMMIT_LSN,
		PE_FAILED_ACTION,
		PE_ERROR_MESSAGE,
		PE_NUM_COLUMNS
	};

	check_monitor_shmem();
	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == PE_NUM_COLUMNS);

	if (exception_log_ptr == NULL)
		return (Datum) 0;

	LWLockAcquire(SpockCtx->lock, LW_SHARED);

	for (i = 0; i < SpockCtx->total_workers; i++)
	{
		SpockExceptionLog *entry = &exception_log_ptr[i];
		Datum		values[PE_NUM_COLUMNS] = {0};
		bool		nulls[PE_NUM_COLUMNS] = {0};

		if (NameStr(entry->slot_name)[0] == '\0' ||
			entry->initial_error_message[0] == '\0')
			continue;

		values[PE_SUBSCRIPTION_NAME] = NameGetDatum(&entry->slot_name);

		if (!XLogRecPtrIsInvalid(entry->commit_lsn))
			values[PE_COMMIT_LSN] = LSNGetDatum(entry->commit_lsn);
		else
			nulls[PE_COMMIT_LSN] = true;

		values[PE_FAILED_ACTION] = Int32GetDatum((int32) entry->failed_action);

		/* The writer does not hold a lock, so bound the copy. */
		values[PE_ERROR_MESSAGE] =
			PointerGetDatum(cstring_to_text_with_len(entry->initial_error_message,
													 strnlen(entry->initial_error_message,
															 sizeof(entry->initial_error_message))));

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	LWLockRelease(SpockCtx->lock);

	return (Datum) 0;
}


/* ----------------------------------------------------------------------
 * Channel counters and apply progress
 * ----------------------------------------------------------------------
 */

/*
 * spock.get_channel_stats()
 *
 * Per-table tuple counters of the current database.
 */
Datum
get_channel_stats(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	HASH_SEQ_STATUS hash_seq;
	spockStatsEntry *entry;
	Datum	   *values;
	bool	   *nulls;

	check_monitor_shmem();
	Assert(SpockHash != NULL);

	InitMaterializedSRF(fcinfo, 0);

	values = palloc0(sizeof(Datum) * (SPOCK_STATS_NUM_COUNTERS + 2));
	nulls = palloc0(sizeof(bool) * (SPOCK_STATS_NUM_COUNTERS + 2));

	LWLockAcquire(SpockCtx->lock, LW_SHARED);
	hash_seq_init(&hash_seq, SpockHash);

	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		int			i = 0;
		int			j;

		if (entry->key.dboid != MyDatabaseId)
			continue;

		values[i++] = ObjectIdGetDatum(entry->key.subid);
		values[i++] = ObjectIdGetDatum(entry->key.relid);

		/*
		 * The writer, handle_stats_counter(), updates the 64-bit counters
		 * under the entry mutex; take it here too to avoid torn reads.
		 */
		SpinLockAcquire(&entry->mutex);
		for (j = 0; j < SPOCK_STATS_NUM_COUNTERS; j++)
			values[i++] = Int64GetDatum(entry->counter[j]);
		SpinLockRelease(&entry->mutex);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	spock_stats_hash_full = false;

	LWLockRelease(SpockCtx->lock);

	return (Datum) 0;
}

/*
 * spock.reset_channel_stats()
 *
 * Drop all per-table counters.
 */
Datum
reset_channel_stats(PG_FUNCTION_ARGS)
{
	HASH_SEQ_STATUS hash_seq;
	spockStatsEntry *entry;

	check_monitor_shmem();
	Assert(SpockHash != NULL);

	LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE);

	hash_seq_init(&hash_seq, SpockHash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		if (hash_search(SpockHash,
						&entry->key,
						HASH_REMOVE,
						NULL) == NULL)
			elog(ERROR, "hash table corrupted");
	}

	LWLockRelease(SpockCtx->lock);
	PG_RETURN_VOID();
}

/*
 * spock.apply_group_progress()
 *
 * Replication progress of every apply group.  Timestamps that were never
 * set are returned as NULL, LSNs are returned as they are because a diff
 * against LSN 0 is a meaningful value.
 */
Datum
get_apply_group_progress(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	HASH_SEQ_STATUS it;
	SpockGroupEntry *e;

	check_monitor_shmem();

	if (!SpockGroupHash)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("spock group hash not initialized")));

	InitMaterializedSRF(fcinfo, 0);

	LWLockAcquire(SpockCtx->apply_group_master_lock, LW_SHARED);

	hash_seq_init(&it, SpockGroupHash);
	while ((e = (SpockGroupEntry *) hash_seq_search(&it)) != NULL)
	{
		SpockApplyProgress *sap = &e->progress;
		Datum		values[_GP_LAST_];
		bool		nulls[_GP_LAST_] = {0};

		Assert(OidIsValid(sap->key.dbid) && OidIsValid(sap->key.node_id) &&
			   OidIsValid(sap->key.remote_node_id));

		values[GP_DBOID] = ObjectIdGetDatum(sap->key.dbid);
		values[GP_NODE_ID] = ObjectIdGetDatum(sap->key.node_id);
		values[GP_REMOTE_NODE_ID] = ObjectIdGetDatum(sap->key.remote_node_id);

		values[GP_REMOTE_COMMIT_TS] =
			timestamptz_or_null(sap->remote_commit_ts, &nulls[GP_REMOTE_COMMIT_TS]);
		values[GP_PREV_REMOTE_TS] =
			timestamptz_or_null(sap->prev_remote_ts, &nulls[GP_PREV_REMOTE_TS]);

		values[GP_REMOTE_COMMIT_LSN] = LSNGetDatum(sap->remote_commit_lsn);
		values[GP_REMOTE_INSERT_LSN] = LSNGetDatum(sap->remote_insert_lsn);
		values[GP_RECEIVED_LSN] = LSNGetDatum(sap->received_lsn);

		values[GP_LAST_UPDATED_TS] =
			timestamptz_or_null(sap->last_updated_ts, &nulls[GP_LAST_UPDATED_TS]);

		values[GP_UPDATED_BY_DECODE] = BoolGetDatum(sap->updated_by_decode);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	LWLockRelease(SpockCtx->apply_group_master_lock);

	return (Datum) 0;
}

/*
 * spock.wait_slot_confirm_lsn(slotname, target)
 *
 * On a provider, wait until the confirmed_flush position of the named
 * slot, or of all slots when no name is given, has passed the target.
 * Without a target the latest local commit is used, or the current WAL
 * insert position when nothing has been committed yet.
 *
 * Errors are not raised for missing slots, so that the caller keeps
 * waiting across a subscription restart.  There is no timeout; use
 * statement_timeout.
 */
Datum
spock_wait_slot_confirm_lsn(PG_FUNCTION_ARGS)
{
	XLogRecPtr	target_lsn;
	Name		slot_name;
	int			i;

	if (PG_ARGISNULL(0))
		slot_name = NULL;
	else
		slot_name = PG_GETARG_NAME(0);

	if (PG_ARGISNULL(1))
	{
		if (XLogRecPtrIsInvalid(XactLastCommitEnd))
			target_lsn = GetXLogInsertRecPtr();
		else
			target_lsn = XactLastCommitEnd;
	}
	else
		target_lsn = PG_GETARG_LSN(1);

	elog(DEBUG1, "waiting for %s to pass confirmed_flush position %X/%X",
		 slot_name == NULL ? "all local slots" : NameStr(*slot_name),
		 LSN_FORMAT_ARGS(target_lsn));

	do
	{
		XLogRecPtr	oldest_confirmed_lsn = InvalidXLogRecPtr;
		int			oldest_slot_pos = -1;
		int			rc;

		LWLockAcquire(ReplicationSlotControlLock, LW_SHARED);
		for (i = 0; i < max_replication_slots; i++)
		{
			ReplicationSlot *s = &ReplicationSlotCtl->replication_slots[i];

			if (!s->in_use)
				continue;

			if (slot_name != NULL &&
				strncmp(NameStr(*slot_name), NameStr(s->data.name), NAMEDATALEN) != 0)
				continue;

			if (oldest_confirmed_lsn == InvalidXLogRecPtr ||
				(s->data.confirmed_flush != InvalidXLogRecPtr &&
				 s->data.confirmed_flush < oldest_confirmed_lsn))
			{
				oldest_confirmed_lsn = s->data.confirmed_flush;
				oldest_slot_pos = i;
			}
		}

		if (oldest_slot_pos >= 0)
			elog(DEBUG2, "oldest confirmed lsn is %X/%X on slot '%s', %u bytes left until %X/%X",
				 LSN_FORMAT_ARGS(oldest_confirmed_lsn),
				 NameStr(ReplicationSlotCtl->replication_slots[oldest_slot_pos].data.name),
				 (uint32) (target_lsn - oldest_confirmed_lsn),
				 LSN_FORMAT_ARGS(target_lsn));

		LWLockRelease(ReplicationSlotControlLock);

		if (oldest_confirmed_lsn >= target_lsn)
			break;

		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   1000);

		ResetLatch(&MyProc->procLatch);

		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		CHECK_FOR_INTERRUPTS();

	} while (1);

	PG_RETURN_VOID();
}
