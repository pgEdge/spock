/*-------------------------------------------------------------------------
 *
 * spock_monitor.h
 *		spock node monitoring: events, per-subscription activity counters
 *		and status reporting functions
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_MONITOR_H
#define SPOCK_MONITOR_H

#include "access/xlogdefs.h"
#include "datatype/timestamp.h"
#include "storage/s_lock.h"
#include "utils/elog.h"

/* Longest text kept for an event detail or an error message. */
#define SPOCK_MONITOR_MESSAGE_LEN	512

/*
 * Kinds of events kept in the shared memory event history.
 *
 * The order is also the order of the name and severity tables in
 * spock_monitor.c, so a new kind has to be added to all three places.
 */
typedef enum SpockMonitorEventType
{
	SPOCK_EVENT_NODE_CREATED = 0,
	SPOCK_EVENT_NODE_DROPPED,
	SPOCK_EVENT_SUBSCRIPTION_CREATED,
	SPOCK_EVENT_SUBSCRIPTION_DROPPED,
	SPOCK_EVENT_SUBSCRIPTION_ENABLED,
	SPOCK_EVENT_SUBSCRIPTION_DISABLED,
	SPOCK_EVENT_SUBSCRIPTION_ALTERED,
	SPOCK_EVENT_WORKER_STARTED,
	SPOCK_EVENT_WORKER_STOPPED,
	SPOCK_EVENT_WORKER_FAILED,
	SPOCK_EVENT_WORKER_ERROR,
	SPOCK_EVENT_PROVIDER_CONNECTED,
	SPOCK_EVENT_PROVIDER_DISCONNECTED,
	SPOCK_EVENT_TRANSACTION_SKIPPED,
	SPOCK_EVENT_TRANSACTION_DISCARDED,
	SPOCK_EVENT_SYNC_STARTED,
	SPOCK_EVENT_SYNC_FINISHED,
	SPOCK_EVENT_SYNC_FAILED,
	SPOCK_EVENT_SLOT_CREATED,
	SPOCK_EVENT_STREAM_STARTED,
	SPOCK_EVENT_STREAM_STOPPED,
	SPOCK_EVENT_STREAM_ERROR,
	SPOCK_EVENT_APPLY_PAUSED,
	SPOCK_EVENT_APPLY_RESUMED,
	SPOCK_EVENT_REPAIR_MODE_ENABLED,
	SPOCK_EVENT_REPAIR_MODE_DISABLED,
	SPOCK_EVENT_EXTENSION_UPGRADED,

	SPOCK_EVENT_NUM_TYPES
} SpockMonitorEventType;

/*
 * Per-subscription activity counters.  Every counter also remembers the
 * time of its last increment, which is what the "last_*" columns of
 * spock.subscription_stats report.
 */
typedef enum SpockMonitorCounter
{
	SPOCK_MONITOR_WORKER_STARTS = 0,
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
	SPOCK_MONITOR_TABLES_SYNCED,

	SPOCK_MONITOR_NUM_COUNTERS
} SpockMonitorCounter;

/* One entry of the event history ring. */
typedef struct SpockMonitorEvent
{
	uint64		event_id;		/* increases by one per event, never reused */
	TimestampTz event_time;
	SpockMonitorEventType event_type;
	Oid			dboid;			/* database of the reporting process */
	Oid			subid;			/* subscription, or InvalidOid */
	int			pid;			/* reporting process */
	int			sqlerrcode;		/* SQLSTATE of an error event, else 0 */
	XLogRecPtr	lsn;			/* origin LSN the event refers to, if any */
	char		detail[SPOCK_MONITOR_MESSAGE_LEN];
} SpockMonitorEvent;

typedef struct SpockMonitorStatsKey
{
	Oid			dboid;
	Oid			subid;
} SpockMonitorStatsKey;

/* Shared memory hash entry with the counters of one subscription. */
typedef struct SpockMonitorStatsEntry
{
	SpockMonitorStatsKey key;	/* hash key, must be first */

	int64		counter[SPOCK_MONITOR_NUM_COUNTERS];
	TimestampTz counter_time[SPOCK_MONITOR_NUM_COUNTERS];

	XLogRecPtr	last_error_lsn;
	int			last_error_sqlerrcode;
	int			last_error_pid;
	char		last_error_message[SPOCK_MONITOR_MESSAGE_LEN];

	TimestampTz stats_reset;

	/*
	 * Workers keep a pointer to their entry, so an entry is only removed
	 * once no worker is attached.  Both fields are protected by the monitor
	 * LWLock, the counters above by the spinlock.
	 */
	int			nattached;
	bool		dropped;

	slock_t		mutex;
} SpockMonitorStatsEntry;

extern int	spock_event_history_size;
extern SpockMonitorStatsEntry *MySpockMonitorStats;

/* initialization */
extern void spock_monitor_init(void);
extern void spock_monitor_shmem_request(int nworkers);
extern void spock_monitor_shmem_startup(bool found);

/* event history */
extern void spock_monitor_record_event(SpockMonitorEventType type,
									   Oid subid, XLogRecPtr lsn,
									   const char *fmt,...) pg_attribute_printf(4, 5);

/* per-subscription counters, used by apply and sync workers */
extern void spock_monitor_worker_attached(void);
extern void spock_monitor_worker_detached(bool crash);
extern void spock_monitor_count(SpockMonitorCounter counter, int64 delta);
extern void spock_monitor_message_received(int nbytes);
extern void spock_monitor_provider_connected(const char *slot_name,
											 XLogRecPtr start_lsn);
extern void spock_monitor_provider_disconnected(const char *message);
extern void spock_monitor_report_error(ErrorData *edata);
extern bool spock_monitor_is_connection_error(int sqlerrcode);

/* provider side, called by the output plugin */
extern void spock_monitor_stream_started(const char *slot_name);
extern void spock_monitor_stream_stopped(void);

/* subscription lifecycle */
extern void spock_monitor_create_subscription(Oid subid);
extern void spock_monitor_drop_subscription(Oid subid);

#endif							/* SPOCK_MONITOR_H */
