/*-------------------------------------------------------------------------
 *
 * spock_monitor_persist.c
 *		on-disk copy of the event history and the counters
 *
 * The event ring, the subscription counters and the channel counters of
 * spock_monitor.c live in shared memory, which a restart or a crash
 * empties.  The supervisor copies them to PGDATA/spock/ every
 * spock.monitor_flush_interval, and sooner when a warning or an error is
 * recorded, and spock_monitor_shmem_startup() reads them back when shared
 * memory is initialized, so that a restart shows the history and the
 * counts of the previous run.
 *
 *   events.log      the events in id order, appended at every flush; a
 *                   record is a SpockMonitorEvent and its CRC, so a tail
 *                   torn by a crash is cut off when it is read
 *   events.log.old  the previous events.log, kept after a rotation
 *   stats.dat       a snapshot of the counters, rewritten through a
 *                   temporary file when they changed
 *
 * spock.reset_events() leaves a marker in the ring that is written to
 * the log like an event.  The restore and spock.event_log() forget the
 * events of that database before it.
 *
 * All files carry the system identifier, so a copy of the data directory
 * on another cluster is ignored.  A standby has the same identifier and
 * restores the history of the primary after a promotion.
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <sys/stat.h>
#include <unistd.h>

#include "funcapi.h"
#include "miscadmin.h"
#include "access/xlog.h"
#include "port/pg_crc32c.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/spin.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"

#include "pgstat.h"

#include "spock_group.h"
#include "spock_monitor.h"
#include "spock_worker.h"
#include "spock.h"

#include "spock_compat.h"

PG_FUNCTION_INFO_V1(spock_flush_monitor);
PG_FUNCTION_INFO_V1(spock_get_event_log);

#define SPOCK_EVENT_LOG_FILE		"events.log"
#define SPOCK_EVENT_LOG_OLD			"events.log.old"
#define SPOCK_STATS_FILE			"stats.dat"
#define SPOCK_STATS_TMPFILE			"stats.dat.tmp"

#define SPOCK_EVENT_LOG_MAGIC		0x53504b45	/* "SPKE" */
#define SPOCK_STATS_MAGIC			0x53504b53	/* "SPKS" */
#define SPOCK_MONITOR_FILE_VERSION	1

/* Flags of the event log header. */
#define SPOCK_EVENT_LOG_CLEAN_SHUTDOWN	0x0001

/* How long spock.monitor_flush() waits for the supervisor. */
#define SPOCK_MONITOR_FLUSH_WAIT_MS		60000

/* Records read from the log at a time. */
#define SPOCK_EVENT_LOG_BATCH		128

typedef struct SpockEventLogHeader
{
	uint32		magic;
	uint32		version;
	uint64		system_identifier;
	uint32		record_size;	/* sizeof(SpockEventLogRecord) */
	uint32		flags;
	TimestampTz last_flush_time;
	uint64		next_event_id;	/* of the ring at the last flush */
} SpockEventLogHeader;

typedef struct SpockEventLogRecord
{
	SpockMonitorEvent event;
	pg_crc32c	crc;			/* of the event */
} SpockEventLogRecord;

typedef struct SpockStatsFileHeader
{
	uint32		magic;
	uint32		version;
	uint64		system_identifier;
	uint32		nsubscriptions; /* SpockStatsSubRecord entries */
	uint32		nchannels;		/* SpockStatsChannelRecord entries */
	pg_crc32c	crc;			/* of everything after the header */
} SpockStatsFileHeader;

/* The fields of a SpockMonitorStatsEntry that mean something after a restart. */
typedef struct SpockStatsSubRecord
{
	SpockMonitorStatsKey key;
	int64		counter[SPOCK_MONITOR_NUM_COUNTERS];
	TimestampTz counter_time[SPOCK_MONITOR_NUM_COUNTERS];
	XLogRecPtr	last_error_lsn;
	int			last_error_sqlerrcode;
	int			last_error_pid;
	TimestampTz stats_reset;
	char		last_error_message[SPOCK_MONITOR_MESSAGE_LEN];
} SpockStatsSubRecord;

typedef struct SpockStatsChannelRecord
{
	spockStatsKey key;
	int64		counter[SPOCK_STATS_NUM_COUNTERS];
} SpockStatsChannelRecord;

int			spock_monitor_flush_interval = 5000;	/* ms */
int			spock_event_log_max_size = 65536;	/* kB */

/* State of the flusher, which is the supervisor. */
static MemoryContext flush_context = NULL;
static TimestampTz last_flush_at = 0;
static bool clean_flag_cleared = false;
static char *last_stats_image = NULL;
static Size last_stats_len = 0;
static int	flush_fd = -1;

typedef bool (*SpockEventLogCallback) (const SpockMonitorEvent *event,
									   void *arg);

static void spock_monitor_path(char *buf, const char *name);
static void spock_monitor_write_all(int fd, const void *buf, Size len,
									off_t offset, const char *path);
static void spock_monitor_read_all(int fd, void *buf, Size len,
								   off_t offset, const char *path);
static int	spock_monitor_open_event_log(off_t *size, uint64 next_event_id);
static void spock_monitor_write_log_header(int fd, uint32 flags,
										   TimestampTz now,
										   uint64 next_event_id);
static void spock_monitor_rotate_event_log(void);
static void spock_monitor_flush_events(bool shutdown, TimestampTz now);
static char *spock_monitor_stats_image(Size *len);
static void spock_monitor_flush_stats(void);
static bool spock_monitor_scan_file(const char *name,
									SpockEventLogCallback cb, void *arg,
									SpockEventLogHeader *header);
static bool spock_monitor_scan_log(SpockEventLogCallback cb, void *arg,
								   SpockEventLogHeader *header);
static int	spock_monitor_restore_stats(void);
static void spock_monitor_record_start(int nevents, int nstats,
									   bool found, bool clean,
									   TimestampTz last_flush);


/*
 * Define the GUCs.  Called from spock_monitor_init().
 */
void
spock_monitor_persist_init(void)
{
	DefineCustomIntVariable("spock.monitor_flush_interval",
							"How often the event history and the counters are written to disk.",
							"The supervisor writes the events and the counters "
							"of spock.events and spock.subscription_stats to "
							"files under the data directory at this interval, "
							"and reads them back after a restart or a crash. "
							"Zero keeps them in shared memory only.",
							&spock_monitor_flush_interval,
							5000,
							0,
							3600000,
							PGC_SIGHUP,
							GUC_UNIT_MS,
							NULL,
							NULL,
							NULL);

	DefineCustomIntVariable("spock.event_log_max_size",
							"Size at which the on-disk event log is rotated.",
							"When events.log grows past this size it is renamed "
							"to events.log.old and a new one is started, so "
							"between one and two times this size is kept.",
							&spock_event_log_max_size,
							65536,
							1024,
							INT_MAX / 1024,
							PGC_SIGHUP,
							GUC_UNIT_KB,
							NULL,
							NULL,
							NULL);
}

static void
spock_monitor_path(char *buf, const char *name)
{
	snprintf(buf, MAXPGPATH, "%s/%s/%s", DataDir, SPOCK_RES_DIRNAME, name);
}

/*
 * Write len bytes at offset, retrying short writes.  Raises on failure.
 */
static void
spock_monitor_write_all(int fd, const void *buf, Size len, off_t offset,
						const char *path)
{
	const char *p = buf;

	while (len > 0)
	{
		ssize_t		n;

		errno = 0;
		n = pg_pwrite(fd, p, len, offset);
		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not write to file \"%s\": %m", path)));
		}
		if (n == 0)
		{
			/* A zero return means the disk is full. */
			errno = ENOSPC;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not write to file \"%s\": %m", path)));
		}
		p += n;
		len -= n;
		offset += n;
	}
}

/*
 * Read exactly len bytes at offset.  Raises on an I/O error or a short
 * read; the callers check the file size first.
 */
static void
spock_monitor_read_all(int fd, void *buf, Size len, off_t offset,
					   const char *path)
{
	char	   *p = buf;

	while (len > 0)
	{
		ssize_t		n;

		errno = 0;
		n = pg_pread(fd, p, len, offset);
		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not read file \"%s\": %m", path)));
		}
		if (n == 0)
			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("could not read file \"%s\": unexpected end of file",
							path)));
		p += n;
		len -= n;
		offset += n;
	}
}


/* ----------------------------------------------------------------------
 * Writing, in the supervisor
 * ----------------------------------------------------------------------
 */

/*
 * The time the supervisor may wait before it has to flush, given the
 * timeout it would wait otherwise.
 */
long
spock_monitor_flush_timeout(long timeout)
{
	if (SpockMonitorShm == NULL || spock_monitor_flush_interval == 0)
		return timeout;
	return Min(timeout, (long) spock_monitor_flush_interval);
}

/*
 * Write the ring and the counters to disk when the interval has passed or
 * a flush was requested.  Called by the supervisor at every wakeup, and
 * with shutdown set from its exit callback, where everything is written
 * and the log is marked as cleanly closed.
 *
 * An I/O error is logged and the flush is tried again at the next
 * wakeup; it must not take the supervisor down.  The copies out of
 * shared memory are made under the locks and the files are written
 * without them.  Nothing is allocated under a lock either, but the
 * supervisor is not in a transaction, so no abort would release a lock
 * an error did leave behind; the catch block does.
 */
void
spock_monitor_flush(bool shutdown)
{
	TimestampTz now;
	MemoryContext oldcxt;

	if (SpockMonitorShm == NULL || spock_monitor_flush_interval == 0)
		return;

	now = GetCurrentTimestamp();
	if (!shutdown && clean_flag_cleared &&
		!SpockMonitorShm->flush_requested &&
		!TimestampDifferenceExceeds(last_flush_at, now,
									spock_monitor_flush_interval))
		return;

	if (flush_context == NULL)
		flush_context = AllocSetContextCreate(TopMemoryContext,
											  "spock monitor flush",
											  ALLOCSET_DEFAULT_SIZES);
	oldcxt = MemoryContextSwitchTo(flush_context);

	/* A request made while we write is served by the next flush. */
	SpockMonitorShm->flush_requested = false;

	PG_TRY();
	{
		spock_monitor_flush_events(shutdown, now);
		spock_monitor_flush_stats();

		LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);
		SpockMonitorShm->last_flush_time = now;
		SpockMonitorShm->flush_generation++;
		LWLockRelease(SpockMonitorShm->lock);
	}
	PG_CATCH();
	{
		LWLockReleaseAll();
		if (flush_fd >= 0)
		{
			CloseTransientFile(flush_fd);
			flush_fd = -1;
		}
		EmitErrorReport();
		FlushErrorState();
	}
	PG_END_TRY();

	last_flush_at = now;
	MemoryContextSwitchTo(oldcxt);
	MemoryContextReset(flush_context);
}

static void
spock_monitor_write_log_header(int fd, uint32 flags, TimestampTz now,
							   uint64 next_event_id)
{
	SpockEventLogHeader hdr;
	char		path[MAXPGPATH];

	spock_monitor_path(path, SPOCK_EVENT_LOG_FILE);

	memset(&hdr, 0, sizeof(hdr));
	hdr.magic = SPOCK_EVENT_LOG_MAGIC;
	hdr.version = SPOCK_MONITOR_FILE_VERSION;
	hdr.system_identifier = GetSystemIdentifier();
	hdr.record_size = sizeof(SpockEventLogRecord);
	hdr.flags = flags;
	hdr.last_flush_time = now;
	hdr.next_event_id = next_event_id;

	spock_monitor_write_all(fd, &hdr, sizeof(hdr), 0, path);
}

/* Is this a header of a log this server can append to? */
static bool
spock_monitor_log_header_ok(const SpockEventLogHeader *hdr)
{
	return hdr->magic == SPOCK_EVENT_LOG_MAGIC &&
		hdr->version == SPOCK_MONITOR_FILE_VERSION &&
		hdr->system_identifier == GetSystemIdentifier() &&
		hdr->record_size == sizeof(SpockEventLogRecord);
}

/*
 * Rename events.log to events.log.old.
 */
static void
spock_monitor_rotate_event_log(void)
{
	char		path[MAXPGPATH];
	char		oldpath[MAXPGPATH];

	spock_monitor_path(path, SPOCK_EVENT_LOG_FILE);
	spock_monitor_path(oldpath, SPOCK_EVENT_LOG_OLD);

	if (durable_rename(path, oldpath, LOG) != 0)
		ereport(ERROR,
				(errmsg("could not rename \"%s\" to \"%s\"", path, oldpath)));
}

/*
 * Open the event log for appending and return its size.  A missing or
 * empty file gets a header.  A file of another server, version or record
 * layout is rotated away rather than appended to, and a tail that is not
 * a whole record, left by a write that was cut short, is truncated so
 * that the records written now follow a readable one.
 */
static int
spock_monitor_open_event_log(off_t *size, uint64 next_event_id)
{
	char		dir[MAXPGPATH];
	char		path[MAXPGPATH];
	int			fd;
	off_t		len;
	bool		rotated = false;

	snprintf(dir, sizeof(dir), "%s/%s", DataDir, SPOCK_RES_DIRNAME);
	(void) pg_mkdir_p(dir, S_IRWXU);
	spock_monitor_path(path, SPOCK_EVENT_LOG_FILE);

retry:
	fd = OpenTransientFile(path, O_RDWR | O_CREAT | PG_BINARY);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\": %m", path)));
	flush_fd = fd;

	len = lseek(fd, 0, SEEK_END);
	if (len < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek to end of file \"%s\": %m", path)));

	if (len >= (off_t) sizeof(SpockEventLogHeader))
	{
		SpockEventLogHeader hdr;
		off_t		records;
		off_t		whole;

		spock_monitor_read_all(fd, &hdr, sizeof(hdr), 0, path);
		if (!spock_monitor_log_header_ok(&hdr))
		{
			if (rotated)
				ereport(ERROR,
						(errmsg("spock event log \"%s\" is not usable after rotation",
								path)));
			CloseTransientFile(fd);
			flush_fd = -1;
			ereport(LOG,
					(errmsg("spock event log \"%s\" belongs to another server or version, starting a new one",
							path)));
			spock_monitor_rotate_event_log();
			rotated = true;
			goto retry;
		}

		records = len - sizeof(SpockEventLogHeader);
		whole = records - records % sizeof(SpockEventLogRecord);
		if (whole != records)
		{
			len = sizeof(SpockEventLogHeader) + whole;
			if (ftruncate(fd, len) != 0)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not truncate file \"%s\": %m", path)));
			ereport(LOG,
					(errmsg("spock event log \"%s\" ended in a partial record, truncated",
							path)));
		}
	}
	else
	{
		/* New, or too short to hold a header: start over. */
		if (len > 0 && ftruncate(fd, 0) != 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not truncate file \"%s\": %m", path)));
		spock_monitor_write_log_header(fd, 0, GetCurrentTimestamp(),
									   next_event_id);
		len = sizeof(SpockEventLogHeader);
		clean_flag_cleared = true;
	}

	*size = len;
	return fd;
}

/*
 * Append the ring entries not yet on disk, and keep the header's flags
 * and flush time current.
 */
static void
spock_monitor_flush_events(bool shutdown, TimestampTz now)
{
	SpockEventLogRecord *recs = NULL;
	uint64		first;
	uint64		last;
	uint64		oldest;
	uint64		lost = 0;
	uint64		next_event_id;
	int			nrecs;
	int			i;
	int			fd;
	off_t		size;
	char		path[MAXPGPATH];

	spock_monitor_path(path, SPOCK_EVENT_LOG_FILE);

	LWLockAcquire(SpockMonitorShm->lock, LW_SHARED);
	oldest = SpockMonitorShm->ring_seq - SpockMonitorShm->event_count;
	first = SpockMonitorShm->flushed_seq;
	last = SpockMonitorShm->ring_seq;
	LWLockRelease(SpockMonitorShm->lock);

	if (first < oldest)
	{
		lost = oldest - first;
		first = oldest;
	}
	nrecs = (int) (last - first);

	/* Allocated outside the lock: palloc may raise. */
	if (nrecs > 0)
		recs = palloc(nrecs * sizeof(SpockEventLogRecord));

	LWLockAcquire(SpockMonitorShm->lock, LW_SHARED);

	/*
	 * The ring may have moved on since the sizes were read: entries added
	 * after "last" wait for the next flush, entries before "first" that were
	 * overwritten meanwhile are gone, and a reset may have packed the ring
	 * and moved flushed_seq up.  Only fewer entries than planned can result,
	 * so the buffer is large enough.
	 */
	oldest = SpockMonitorShm->ring_seq - SpockMonitorShm->event_count;
	if (first < SpockMonitorShm->flushed_seq)
		first = SpockMonitorShm->flushed_seq;
	if (first < oldest)
	{
		lost += oldest - first;
		first = oldest;
	}
	nrecs = first < last ? (int) (last - first) : 0;
	for (i = 0; i < nrecs; i++)
	{
		int			idx = (SpockMonitorShm->event_head +
						   (int) (first - oldest) + i) %
			SpockMonitorShm->event_capacity;

		recs[i].event = SpockMonitorShm->events[idx];
	}
	next_event_id = SpockMonitorShm->next_event_id;
	LWLockRelease(SpockMonitorShm->lock);

	for (i = 0; i < nrecs; i++)
	{
		INIT_CRC32C(recs[i].crc);
		COMP_CRC32C(recs[i].crc, &recs[i].event, sizeof(SpockMonitorEvent));
		FIN_CRC32C(recs[i].crc);
	}

	if (lost > 0)
		ereport(LOG,
				(errmsg("spock monitor: " UINT64_FORMAT " events were overwritten before they were written to the event log",
						lost)));

	fd = spock_monitor_open_event_log(&size, next_event_id);

	if (nrecs > 0)
	{
		spock_monitor_write_all(fd, recs, nrecs * sizeof(SpockEventLogRecord),
								size, path);
		size += nrecs * sizeof(SpockEventLogRecord);
	}

	/*
	 * The clean flag of the previous run is cleared by the first flush of
	 * this one, so a crash from here on reads as such.  It is set again by
	 * the shutdown flush, after the last records.  The next event id goes
	 * with it, so that ids handed out after this flush and lost in a crash
	 * are not handed out again.
	 */
	spock_monitor_write_log_header(fd,
								   shutdown ? SPOCK_EVENT_LOG_CLEAN_SHUTDOWN : 0,
								   now, next_event_id);
	clean_flag_cleared = true;

	if (pg_fsync(fd) != 0)
		ereport(data_sync_elevel(ERROR),
				(errcode_for_file_access(),
				 errmsg("could not fsync file \"%s\": %m", path)));
	if (CloseTransientFile(fd) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not close file \"%s\": %m", path)));
	flush_fd = -1;

	LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);
	if (SpockMonitorShm->flushed_seq < last)
		SpockMonitorShm->flushed_seq = last;
	LWLockRelease(SpockMonitorShm->lock);

	if (recs != NULL)
		pfree(recs);

	if (size > (off_t) spock_event_log_max_size * 1024 && !shutdown)
		spock_monitor_rotate_event_log();
}

/*
 * The counters as one block of bytes: header, subscription records,
 * channel records.
 */
static char *
spock_monitor_stats_image(Size *len)
{
	SpockStatsFileHeader *hdr;
	SpockStatsSubRecord *subs;
	SpockStatsChannelRecord *chans;
	HASH_SEQ_STATUS seq;
	SpockMonitorStatsEntry *sentry;
	spockStatsEntry *centry;
	long		nsubs_room;
	long		nchans_room;
	int			nsubs = 0;
	int			nchans = 0;
	char	   *image;
	Size		size;
	pg_crc32c	crc;

	/*
	 * Size the buffers outside the locks, with room for entries added in
	 * between; any beyond that wait for the next flush.
	 */
	LWLockAcquire(SpockMonitorShm->lock, LW_SHARED);
	nsubs_room = hash_get_num_entries(SpockMonitorStatsHash) + 16;
	LWLockRelease(SpockMonitorShm->lock);
	LWLockAcquire(SpockCtx->lock, LW_SHARED);
	nchans_room = hash_get_num_entries(SpockHash) + 64;
	LWLockRelease(SpockCtx->lock);

	size = sizeof(SpockStatsFileHeader) +
		nsubs_room * sizeof(SpockStatsSubRecord) +
		nchans_room * sizeof(SpockStatsChannelRecord);
	image = palloc0(size);
	hdr = (SpockStatsFileHeader *) image;
	subs = (SpockStatsSubRecord *) (image + sizeof(SpockStatsFileHeader));

	LWLockAcquire(SpockMonitorShm->lock, LW_SHARED);
	hash_seq_init(&seq, SpockMonitorStatsHash);
	while ((sentry = hash_seq_search(&seq)) != NULL)
	{
		SpockStatsSubRecord *rec = &subs[nsubs];

		if (sentry->dropped)
			continue;
		if (nsubs >= nsubs_room)
		{
			hash_seq_term(&seq);
			break;
		}

		rec->key = sentry->key;
		SpinLockAcquire(&sentry->mutex);
		memcpy(rec->counter, sentry->counter, sizeof(rec->counter));
		memcpy(rec->counter_time, sentry->counter_time,
			   sizeof(rec->counter_time));
		rec->last_error_lsn = sentry->last_error_lsn;
		rec->last_error_sqlerrcode = sentry->last_error_sqlerrcode;
		rec->last_error_pid = sentry->last_error_pid;
		rec->stats_reset = sentry->stats_reset;
		memcpy(rec->last_error_message, sentry->last_error_message,
			   sizeof(rec->last_error_message));
		SpinLockRelease(&sentry->mutex);
		nsubs++;
	}
	LWLockRelease(SpockMonitorShm->lock);

	chans = (SpockStatsChannelRecord *) (subs + nsubs);

	LWLockAcquire(SpockCtx->lock, LW_SHARED);
	hash_seq_init(&seq, SpockHash);
	while ((centry = hash_seq_search(&seq)) != NULL)
	{
		SpockStatsChannelRecord *rec = &chans[nchans];

		if (nchans >= nchans_room)
		{
			hash_seq_term(&seq);
			break;
		}

		rec->key = centry->key;
		SpinLockAcquire(&centry->mutex);
		memcpy(rec->counter, centry->counter, sizeof(rec->counter));
		SpinLockRelease(&centry->mutex);
		nchans++;
	}
	LWLockRelease(SpockCtx->lock);

	size = sizeof(SpockStatsFileHeader) +
		nsubs * sizeof(SpockStatsSubRecord) +
		nchans * sizeof(SpockStatsChannelRecord);

	hdr->magic = SPOCK_STATS_MAGIC;
	hdr->version = SPOCK_MONITOR_FILE_VERSION;
	hdr->system_identifier = GetSystemIdentifier();
	hdr->nsubscriptions = nsubs;
	hdr->nchannels = nchans;

	INIT_CRC32C(crc);
	COMP_CRC32C(crc, image + sizeof(SpockStatsFileHeader),
				size - sizeof(SpockStatsFileHeader));
	FIN_CRC32C(crc);
	hdr->crc = crc;

	*len = size;
	return image;
}

/*
 * Rewrite stats.dat when the counters changed since the last write.
 */
static void
spock_monitor_flush_stats(void)
{
	char	   *image;
	Size		len;
	char		tmppath[MAXPGPATH];
	char		path[MAXPGPATH];
	int			fd;

	image = spock_monitor_stats_image(&len);

	if (last_stats_image != NULL && last_stats_len == len &&
		memcmp(last_stats_image, image, len) == 0)
		return;

	spock_monitor_path(tmppath, SPOCK_STATS_TMPFILE);
	spock_monitor_path(path, SPOCK_STATS_FILE);

	fd = OpenTransientFile(tmppath, O_WRONLY | O_CREAT | O_TRUNC | PG_BINARY);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create file \"%s\": %m", tmppath)));
	flush_fd = fd;

	spock_monitor_write_all(fd, image, len, 0, tmppath);

	if (pg_fsync(fd) != 0)
		ereport(data_sync_elevel(ERROR),
				(errcode_for_file_access(),
				 errmsg("could not fsync file \"%s\": %m", tmppath)));
	if (CloseTransientFile(fd) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not close file \"%s\": %m", tmppath)));
	flush_fd = -1;

	if (durable_rename(tmppath, path, LOG) != 0)
		ereport(ERROR,
				(errmsg("could not rename \"%s\" to \"%s\"", tmppath, path)));

	if (last_stats_image != NULL)
		pfree(last_stats_image);
	last_stats_image = MemoryContextAlloc(TopMemoryContext, len);
	memcpy(last_stats_image, image, len);
	last_stats_len = len;
}


/* ----------------------------------------------------------------------
 * Reading
 * ----------------------------------------------------------------------
 */

/*
 * Call cb for every readable record of one log file, oldest first, until
 * it returns false.  Returns whether the file exists and is one of this
 * server.  A record with a bad CRC ends the scan of the file: everything
 * after it was written after a crash cut it short.
 */
static bool
spock_monitor_scan_file(const char *name, SpockEventLogCallback cb,
						void *arg, SpockEventLogHeader *header)
{
	char		path[MAXPGPATH];
	int			fd;
	off_t		len;
	off_t		offset;
	SpockEventLogHeader hdr;
	SpockEventLogRecord *batch;
	bool		keep_going = true;

	spock_monitor_path(path, name);

	fd = OpenTransientFile(path, O_RDONLY | PG_BINARY);
	if (fd < 0)
	{
		if (errno == ENOENT)
			return false;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\": %m", path)));
	}

	len = lseek(fd, 0, SEEK_END);
	if (len < (off_t) sizeof(SpockEventLogHeader))
	{
		CloseTransientFile(fd);
		return false;
	}

	spock_monitor_read_all(fd, &hdr, sizeof(hdr), 0, path);
	if (!spock_monitor_log_header_ok(&hdr))
	{
		CloseTransientFile(fd);
		ereport(LOG,
				(errmsg("spock event log \"%s\" belongs to another server or version, ignored",
						path)));
		return false;
	}
	if (header != NULL)
		*header = hdr;

	batch = palloc(SPOCK_EVENT_LOG_BATCH * sizeof(SpockEventLogRecord));
	offset = sizeof(SpockEventLogHeader);
	while (keep_going && offset + (off_t) sizeof(SpockEventLogRecord) <= len)
	{
		int			n = (int) Min((len - offset) / sizeof(SpockEventLogRecord),
								  SPOCK_EVENT_LOG_BATCH);
		int			i;

		spock_monitor_read_all(fd, batch, n * sizeof(SpockEventLogRecord),
							   offset, path);
		offset += n * sizeof(SpockEventLogRecord);

		for (i = 0; i < n; i++)
		{
			pg_crc32c	crc;

			INIT_CRC32C(crc);
			COMP_CRC32C(crc, &batch[i].event, sizeof(SpockMonitorEvent));
			FIN_CRC32C(crc);
			if (!EQ_CRC32C(crc, batch[i].crc))
			{
				ereport(LOG,
						(errmsg("spock event log \"%s\" has a damaged record at offset %lld, the rest is ignored",
								path,
								(long long) (offset - (n - i) * sizeof(SpockEventLogRecord)))));
				keep_going = false;
				break;
			}

			/* The detail must be a string whatever is on disk. */
			batch[i].event.detail[SPOCK_MONITOR_MESSAGE_LEN - 1] = '\0';

			if (!cb(&batch[i].event, arg))
			{
				keep_going = false;
				break;
			}
		}
	}

	pfree(batch);
	CloseTransientFile(fd);
	return true;
}

/*
 * Scan the rotated log, then the current one, whose header is returned.
 * Returns whether either exists.  Without a current log, as after a crash
 * between a rotation and the next flush, the rotated one's header stands
 * in: it was rewritten by the flush that rotated it.
 */
static bool
spock_monitor_scan_log(SpockEventLogCallback cb, void *arg,
					   SpockEventLogHeader *header)
{
	SpockEventLogHeader old_hdr;
	SpockEventLogHeader hdr;
	bool		found_old;
	bool		found;

	memset(&old_hdr, 0, sizeof(old_hdr));
	memset(&hdr, 0, sizeof(hdr));
	found_old = spock_monitor_scan_file(SPOCK_EVENT_LOG_OLD, cb, arg, &old_hdr);
	found = spock_monitor_scan_file(SPOCK_EVENT_LOG_FILE, cb, arg, &hdr);

	if (header != NULL)
		*header = found ? hdr : old_hdr;
	return found || found_old;
}


/* ----------------------------------------------------------------------
 * Restore at startup
 * ----------------------------------------------------------------------
 */

typedef struct SpockRestoreState
{
	uint64		max_id;			/* highest event id seen */
	int			nevents;		/* events put into the ring */
	int			nskipped;		/* duplicates and events reset away */
} SpockRestoreState;

/*
 * Drop the ring entries a reset marker of dboid refers to: those of that
 * database and those recorded outside any database, as
 * spock.reset_events() does.  Compacts in place, in ring order, which is
 * safe because an entry is only ever moved towards the head.
 */
static void
spock_monitor_ring_forget(Oid dboid)
{
	int			kept = 0;
	int			i;

	for (i = 0; i < SpockMonitorShm->event_count; i++)
	{
		int			src = (SpockMonitorShm->event_head + i) %
			SpockMonitorShm->event_capacity;
		SpockMonitorEvent *event = &SpockMonitorShm->events[src];

		if (event->dboid == dboid || !OidIsValid(event->dboid))
			continue;
		if (kept != i)
		{
			int			dst = (SpockMonitorShm->event_head + kept) %
				SpockMonitorShm->event_capacity;

			SpockMonitorShm->events[dst] = *event;
		}
		kept++;
	}
	SpockMonitorShm->event_count = kept;
}

/* Put one record of the log into the ring. */
static bool
spock_monitor_restore_cb(const SpockMonitorEvent *event, void *arg)
{
	SpockRestoreState *state = arg;

	if (event->event_type == SPOCK_EVENT_RESET_MARKER)
	{
		int			before = SpockMonitorShm->event_count;

		spock_monitor_ring_forget(event->dboid);
		state->nskipped += before - SpockMonitorShm->event_count;
		state->nevents -= before - SpockMonitorShm->event_count;
		return true;
	}

	/* Unknown to this version, or written twice after a failed flush. */
	if (event->event_type < 0 || event->event_type >= SPOCK_EVENT_NUM_TYPES ||
		event->event_id <= state->max_id)
	{
		state->nskipped++;
		return true;
	}

	state->max_id = event->event_id;
	if (SpockMonitorShm->event_count == SpockMonitorShm->event_capacity)
		state->nevents--;
	spock_monitor_ring_put(event);
	state->nevents++;
	return true;
}

/*
 * Read stats.dat into the two hash tables.  Returns the number of entries
 * restored, or -1 when there is no file.
 */
static int
spock_monitor_restore_stats(void)
{
	char		path[MAXPGPATH];
	int			fd;
	off_t		len;
	char	   *image;
	SpockStatsFileHeader *hdr;
	SpockStatsSubRecord *subs;
	SpockStatsChannelRecord *chans;
	Size		expected;
	pg_crc32c	crc;
	int			restored = 0;
	uint32		i;

	spock_monitor_path(path, SPOCK_STATS_FILE);

	fd = OpenTransientFile(path, O_RDONLY | PG_BINARY);
	if (fd < 0)
	{
		if (errno == ENOENT)
			return -1;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\": %m", path)));
	}

	len = lseek(fd, 0, SEEK_END);
	if (len < (off_t) sizeof(SpockStatsFileHeader) || len > MaxAllocSize)
	{
		CloseTransientFile(fd);
		ereport(LOG,
				(errmsg("spock counter file \"%s\" has an invalid size, ignored",
						path)));
		return -1;
	}

	image = palloc(len);
	spock_monitor_read_all(fd, image, len, 0, path);
	CloseTransientFile(fd);

	hdr = (SpockStatsFileHeader *) image;
	if (hdr->magic != SPOCK_STATS_MAGIC ||
		hdr->version != SPOCK_MONITOR_FILE_VERSION ||
		hdr->system_identifier != GetSystemIdentifier())
	{
		pfree(image);
		ereport(LOG,
				(errmsg("spock counter file \"%s\" belongs to another server or version, ignored",
						path)));
		return -1;
	}

	expected = sizeof(SpockStatsFileHeader) +
		(Size) hdr->nsubscriptions * sizeof(SpockStatsSubRecord) +
		(Size) hdr->nchannels * sizeof(SpockStatsChannelRecord);
	INIT_CRC32C(crc);
	if ((Size) len == expected)
	{
		COMP_CRC32C(crc, image + sizeof(SpockStatsFileHeader),
					len - sizeof(SpockStatsFileHeader));
	}
	FIN_CRC32C(crc);
	if ((Size) len != expected || !EQ_CRC32C(crc, hdr->crc))
	{
		pfree(image);
		ereport(LOG,
				(errmsg("spock counter file \"%s\" is damaged, ignored", path)));
		return -1;
	}

	subs = (SpockStatsSubRecord *) (image + sizeof(SpockStatsFileHeader));
	chans = (SpockStatsChannelRecord *) (subs + hdr->nsubscriptions);

	for (i = 0; i < hdr->nsubscriptions; i++)
	{
		SpockStatsSubRecord *rec = &subs[i];
		SpockMonitorStatsEntry *entry;
		bool		found;

		entry = hash_search(SpockMonitorStatsHash, &rec->key,
							HASH_ENTER_NULL, &found);
		if (entry == NULL)
		{
			ereport(LOG,
					(errmsg("spock monitor statistics table is full, %u subscription counter entries not restored",
							hdr->nsubscriptions - i)));
			break;
		}
		if (found)
			continue;

		SpinLockInit(&entry->mutex);
		memcpy(entry->counter, rec->counter, sizeof(entry->counter));
		memcpy(entry->counter_time, rec->counter_time,
			   sizeof(entry->counter_time));
		entry->last_error_lsn = rec->last_error_lsn;
		entry->last_error_sqlerrcode = rec->last_error_sqlerrcode;
		entry->last_error_pid = rec->last_error_pid;
		memcpy(entry->last_error_message, rec->last_error_message,
			   SPOCK_MONITOR_MESSAGE_LEN);
		entry->last_error_message[SPOCK_MONITOR_MESSAGE_LEN - 1] = '\0';
		entry->stats_reset = rec->stats_reset;
		entry->nattached = 0;
		entry->dropped = false;
		restored++;
	}

	for (i = 0; i < hdr->nchannels; i++)
	{
		SpockStatsChannelRecord *rec = &chans[i];
		spockStatsEntry *entry;
		bool		found;

		if (hash_get_num_entries(SpockHash) >= spock_stats_max_entries)
		{
			ereport(LOG,
					(errmsg("spock channel counter table is full, %u entries not restored",
							hdr->nchannels - i)));
			break;
		}
		entry = hash_search(SpockHash, &rec->key, HASH_ENTER_NULL, &found);
		if (entry == NULL)
			break;
		if (found)
			continue;

		SpinLockInit(&entry->mutex);
		memcpy(entry->counter, rec->counter, sizeof(entry->counter));
		restored++;
	}

	pfree(image);
	return restored;
}

/*
 * Record the start of this run as an event, saying what was found.
 */
static void
spock_monitor_record_start(int nevents, int nstats, bool found, bool clean,
						   TimestampTz last_flush)
{
	SpockMonitorEvent event;

	memset(&event, 0, sizeof(event));
	event.event_time = GetCurrentTimestamp();
	event.event_type = SPOCK_EVENT_NODE_STARTED;
	event.dboid = InvalidOid;
	event.subid = InvalidOid;
	event.pid = MyProcPid;

	if (!found)
		snprintf(event.detail, sizeof(event.detail),
				 "no event history or counters on disk");
	else if (clean)
		snprintf(event.detail, sizeof(event.detail),
				 "restored %d events and %d counter entries, "
				 "the previous run shut down cleanly at %s",
				 nevents, nstats,
				 last_flush != 0 ? timestamptz_to_str(last_flush) : "an unknown time");
	else
		snprintf(event.detail, sizeof(event.detail),
				 "restored %d events and %d counter entries, "
				 "the previous run did not shut down cleanly and what "
				 "it recorded after %s was not saved",
				 nevents, nstats,
				 last_flush != 0 ? timestamptz_to_str(last_flush) : "its last write");

	spock_monitor_ring_put(&event);
}

/*
 * Read the files of the previous run into the fresh shared memory
 * structures.  Called from spock_monitor_shmem_startup() when the
 * structures were just created, with AddinShmemInitLock held, so no
 * other process can see them yet.  Nothing here may stop the server from
 * starting: a problem with a file is logged and the file ignored.
 */
void
spock_monitor_restore(void)
{
	MemoryContext restore_context;
	MemoryContext oldcxt;
	SpockRestoreState state = {0};
	SpockEventLogHeader hdr;
	int			nstats;
	bool		clean = false;
	TimestampTz last_flush = 0;
	uint64		next_event_id = 0;
	bool		found = false;

	Assert(LWLockHeldByMe(AddinShmemInitLock));
	Assert(SpockMonitorShm != NULL && SpockMonitorStatsHash != NULL);
	Assert(SpockHash != NULL);

	if (spock_monitor_flush_interval == 0)
		return;

	restore_context = AllocSetContextCreate(CurrentMemoryContext,
											"spock monitor restore",
											ALLOCSET_DEFAULT_SIZES);
	oldcxt = MemoryContextSwitchTo(restore_context);

	PG_TRY();
	{
		nstats = spock_monitor_restore_stats();
		if (nstats >= 0)
			found = true;
		else
			nstats = 0;

		if (spock_monitor_scan_log(spock_monitor_restore_cb, &state, &hdr))
		{
			found = true;
			clean = (hdr.flags & SPOCK_EVENT_LOG_CLEAN_SHUTDOWN) != 0;
			last_flush = hdr.last_flush_time;
			next_event_id = hdr.next_event_id;
		}
		else if (state.nevents > 0 || state.nskipped > 0)
			found = true;
	}
	PG_CATCH();
	{
		EmitErrorReport();
		FlushErrorState();
		nstats = 0;
	}
	PG_END_TRY();

	MemoryContextSwitchTo(oldcxt);
	MemoryContextDelete(restore_context);

	/*
	 * Ids continue after the highest one on disk.  After a crash the previous
	 * run may have handed out ids beyond that, for events it had not written
	 * yet; it cannot have gone further than a ring's worth past its last
	 * flush without a flush being asked for, so that many are left out rather
	 * than given to new events.  Everything in the ring so far is on disk
	 * already.
	 */
	if (!clean)
		next_event_id += SpockMonitorShm->event_capacity;
	if (next_event_id < state.max_id + 1)
		next_event_id = state.max_id + 1;
	if (SpockMonitorShm->next_event_id < next_event_id)
		SpockMonitorShm->next_event_id = next_event_id;
	SpockMonitorShm->flushed_seq = SpockMonitorShm->ring_seq;

	SpockMonitorShm->restored = found;
	SpockMonitorShm->prior_shutdown_clean = clean;
	SpockMonitorShm->restored_events = state.nevents;
	SpockMonitorShm->restored_stats = nstats;
	SpockMonitorShm->restored_flush_time = last_flush;

	spock_monitor_record_start(state.nevents, nstats, found, clean,
							   last_flush);
}


/* ----------------------------------------------------------------------
 * SQL functions
 * ----------------------------------------------------------------------
 */

/*
 * spock.monitor_flush()
 *
 * Have the supervisor write the history and the counters now, and wait
 * until it has.  Returns false when the on-disk copy is turned off.
 */
Datum
spock_flush_monitor(PG_FUNCTION_ARGS)
{
	uint64		target;
	uint64		generation;
	PGPROC	   *supervisor;
	TimestampTz start;

	if (SpockCtx == NULL || SpockMonitorShm == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("spock must be loaded via shared_preload_libraries")));

	if (spock_monitor_flush_interval == 0)
		PG_RETURN_BOOL(false);

	LWLockAcquire(SpockCtx->lock, LW_SHARED);
	supervisor = SpockCtx->supervisor;
	LWLockRelease(SpockCtx->lock);
	if (supervisor == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("the spock supervisor is not running")));

	LWLockAcquire(SpockMonitorShm->lock, LW_EXCLUSIVE);
	target = SpockMonitorShm->ring_seq;
	generation = SpockMonitorShm->flush_generation;
	SpockMonitorShm->flush_requested = true;
	LWLockRelease(SpockMonitorShm->lock);

	SetLatch(&supervisor->procLatch);

	start = GetCurrentTimestamp();
	for (;;)
	{
		bool		done;
		int			rc;

		LWLockAcquire(SpockMonitorShm->lock, LW_SHARED);
		done = SpockMonitorShm->flushed_seq >= target &&
			SpockMonitorShm->flush_generation > generation;
		LWLockRelease(SpockMonitorShm->lock);
		if (done)
			break;

		if (TimestampDifferenceExceeds(start, GetCurrentTimestamp(),
									   SPOCK_MONITOR_FLUSH_WAIT_MS))
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("the spock supervisor did not write the event history within %d seconds",
							SPOCK_MONITOR_FLUSH_WAIT_MS / 1000),
					 errhint("Check the server log for an I/O error.")));

		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   100);
		ResetLatch(&MyProc->procLatch);
		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);
		CHECK_FOR_INTERRUPTS();
	}

	PG_RETURN_BOOL(true);
}

/*
 * spock.event_log(since_id, max_rows)
 *
 * The events of the current database in the on-disk log, oldest first,
 * which reach further back than the ring.  Events before the last
 * spock.reset_events() of this database are left out, as they are from
 * spock.events.
 */
typedef struct SpockEventLogScan
{
	int64		pos;			/* records seen so far */
	int64		reset_pos;		/* position of the last reset marker */
	int64		since_id;
	int			max_rows;
	int			nrows;
	uint64		max_id;
	ReturnSetInfo *rsinfo;
} SpockEventLogScan;

/* First pass: find the last reset marker of this database. */
static bool
spock_monitor_find_reset_cb(const SpockMonitorEvent *event, void *arg)
{
	SpockEventLogScan *scan = arg;

	if (event->event_type == SPOCK_EVENT_RESET_MARKER &&
		event->dboid == MyDatabaseId)
		scan->reset_pos = scan->pos;
	scan->pos++;
	return true;
}

/* Second pass: return the rows. */
static bool
spock_monitor_event_log_cb(const SpockMonitorEvent *event, void *arg)
{
	SpockEventLogScan *scan = arg;
	int64		pos = scan->pos++;

	if (pos <= scan->reset_pos)
		return true;
	if (event->event_type == SPOCK_EVENT_RESET_MARKER)
		return true;
	if (event->event_type < 0 || event->event_type >= SPOCK_EVENT_NUM_TYPES)
		return true;
	if (event->dboid != MyDatabaseId && OidIsValid(event->dboid))
		return true;
	if (event->event_id < (uint64) scan->since_id ||
		event->event_id <= scan->max_id)
		return true;

	scan->max_id = event->event_id;
	spock_monitor_event_row_put(event, scan->rsinfo);
	scan->nrows++;
	return scan->nrows < scan->max_rows;
}

Datum
spock_get_event_log(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	SpockEventLogScan scan;

	if (SpockMonitorShm == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("spock must be loaded via shared_preload_libraries")));

	InitMaterializedSRF(fcinfo, 0);

	memset(&scan, 0, sizeof(scan));
	scan.since_id = PG_ARGISNULL(0) ? 0 : PG_GETARG_INT64(0);
	scan.max_rows = PG_ARGISNULL(1) ? 1000 : PG_GETARG_INT32(1);
	scan.reset_pos = -1;
	scan.rsinfo = rsinfo;

	if (scan.max_rows <= 0)
		PG_RETURN_VOID();

	spock_monitor_scan_log(spock_monitor_find_reset_cb, &scan, NULL);
	scan.pos = 0;
	spock_monitor_scan_log(spock_monitor_event_log_cb, &scan, NULL);

	PG_RETURN_VOID();
}
