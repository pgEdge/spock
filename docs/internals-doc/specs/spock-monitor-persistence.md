# Keeping monitoring data across a crash

Issue #700 proposes to keep the event history in a `spock.events` table.
This document proposes a different layout: a node-wide, append-only event
log and a counter snapshot under `PGDATA/spock/`, written by the
supervisor, and read back when shared memory is initialized. It also
covers the second request, moving counters to the cumulative statistics
system on PostgreSQL 18, and why that does not replace the on-disk copy.

## What is lost today

Everything `spock.events`, `spock.subscription_stats` and
`spock.channel_stats` show lives in shared memory (`SpockMonitorShm`,
`SpockMonitorStatsHash` and `SpockHash`). It survives a worker restart
and is gone after:

- a clean restart of the server,
- a crash of the server,
- a crash of any backend, because the postmaster reinitializes shared
  memory and `spock_monitor_shmem_startup()` runs again with `found`
  false.

After a crash the event ids start at 1 again, the counters start at 0
and `stats_reset` is the server start time, so an operator cannot tell
a fresh node from one that lost its history.

The apply progress already has the same problem solved for its own data:
`spock_group_resource_dump()` writes `PGDATA/spock/resource.dat` on
clean shutdown and `spock_group_resource_load()` reads it back in
`spock_group_shmem_startup()`. The design below follows that pattern and
adds what resource.dat does not have: periodic writes, so a crash loses
seconds rather than everything.

## Why not a table

The table in #700 has costs that the file layout does not:

1. **It needs a database connection and a transaction per copy.** The
   supervisor has none (`BackgroundWorkerInitializeConnection(NULL, ...)`),
   so the copy has to run in each database manager. A database whose
   manager is not running, for example after `spock.node_drop()` or
   while the extension is being upgraded, stops collecting.
2. **Node-wide events have no home.** The ring is shared by all
   databases. Walsender streams, workers that fail before they connect,
   and supervisor events carry `dboid` 0 or the database of a reporting
   process that is not the one being described. A per-database table
   either drops them or copies them into every database.
3. **The copy can itself fail and generate events.** Disk full, a lock
   on the table, a long-running `VACUUM FULL`, or an error in the copy
   transaction all produce new events, and the table is still behind
   the ring by one manager wakeup, which today is up to the apply
   worker restart delay.
4. **The table is replicated unless it is excluded.** Everything in
   schema `spock` has to stay out of `repset_add_all_tables()` and out
   of auto DDL. `spock.exception_log` has that treatment already, but
   every new table is another place to get it wrong.
5. **The view becomes a table.** Dependent views, grants and
   `pg_dump` output change. A table also keeps growing until someone
   decides retention, which #700 leaves open.
6. **It still loses the tail.** Events not yet copied at the crash are
   gone, exactly as with a file, but a transaction per copy is far more
   expensive than a `write()` of 564 bytes per event, so the copy runs
   less often and the lost window is larger.

A file under `PGDATA` has none of these costs. It is written without a
transaction, from the one process that is always there, for all
databases at once, and it is never replicated. The one thing a table
gives that a file does not, ad hoc SQL over the full history, is kept
by exposing the file through a set-returning function.

## Design

### Files

All files live in `PGDATA/spock/`, the directory `resource.dat` already
uses, with mode 0600.

| File | Content | Written |
|------|---------|---------|
| `events.log` | Fixed-size event records, appended in id order. | Every flush. |
| `events.log.old` | The previous `events.log` after rotation. | On rotation. |
| `stats.dat` | Snapshot of the subscription counters and channel counters. | Every flush in which a counter changed. |
| `stats.dat.tmp` | Temporary file for the snapshot, renamed into place. | During a snapshot. |

**events.log** starts with a header: magic, format version, system
identifier, the record size, a flags word with one bit,
`CLEAN_SHUTDOWN`, the time of the last flush and the ring's next event
id at that flush. Each record is one `SpockMonitorEvent` followed by a
`pg_crc32c` of the event. The reader stops at the first short read or
bad CRC, which is how a tail torn by a crash is cut off. Records are
never rewritten, so a flush is one `write()` of the new records and one
`fsync()`.

When `events.log` grows past `spock.event_log_max_size` the supervisor
renames it to `events.log.old` with `durable_rename()` and starts a new
file. Only one old file is kept, so the retention is between one and two
times the size setting. With the default of 64 MB that is about 110,000
to 220,000 events.

**stats.dat** is written like resource.dat: header with magic, version
and system identifier, then the subscription counter entries and the
channel counter entries, to a temporary file, `fsync()`, then
`durable_rename()`. Each subscription entry stores the key, the
counters, the counter times, the last error fields and `stats_reset`. It
does not store `nattached`, `dropped` or the spinlock. Entries marked
`dropped` are not written. Each channel entry stores its key and
counters.

### Shared memory additions

`SpockMonitorShmem` gets:

- `ring_seq` and `flushed_seq`: entries put into the ring since the
  start, and how many of them the log has. Reset markers have no event
  id, so positions rather than ids say what is unflushed.
- `flush_requested`: set by `spock_monitor_append_event()` when the
  unflushed count reaches a quarter of the ring, or when the event has
  severity `warning` or `error`.
- `flush_generation` and `last_flush_time`: completed flushes, for
  `spock.monitor_flush()` to wait on, and when the last one ran.
- `restored`, `restored_events`, `restored_stats`,
  `prior_shutdown_clean`, `restored_flush_time`: filled by the restore,
  reported by `spock.node_status`.

Only `ring_seq` and `flush_requested` are new state the hot path
touches. Both are written under the ring lock the append already holds.
`SetLatch()` on the supervisor latch is async-signal-safe and does not
allocate, so it is allowed in the emit_log_hook path that records
`worker_error` and `provider_disconnected`.

The channel counter hash and the subscription counter hash do not
change.

### The flusher

The supervisor is the writer. It already owns the shutdown dump of
resource.dat, it exists exactly once per server, it has a latch other
processes can set, and it does not need a database.

Its wait loop timeout becomes
`Min(180000, spock.monitor_flush_interval)`. On every wakeup, whether
from the latch, the timeout or a subscription change, it:

1. Takes the ring lock in shared mode, copies the events with
   `event_id > flushed_event_id` into a local buffer that was allocated
   once at startup for the whole ring, reads `next_event_id`, releases
   the lock.
2. Appends the copied records to `events.log`, `fsync()`, then takes the
   lock again to set `flushed_event_id`. If the file grew past the size
   limit, rotates.
3. Takes `SpockMonitorShm->lock` shared and copies every subscription
   entry under its spinlock into a local buffer, then `SpockCtx->lock`
   shared and does the same for the channel hash. Releases both.
4. Compares the buffer to the one written last time. When they differ,
   writes `stats.dat` through the temporary file.

A snapshot of 64 subscription entries is about 50 KB, and the channel
hash is 56 bytes per entry, so the default of one flush every 5 seconds
costs one small sequential write and one `fsync()` on a busy node, and
nothing on an idle one.

On clean shutdown `spock_supervisor_on_exit()` runs one last flush, then
sets the `CLEAN_SHUTDOWN` flag in the header of `events.log` with a
`pwrite()` at offset 0 and an `fsync()`. The flag is cleared by the
first flush after a start.

### Restore

`spock_monitor_shmem_startup()` with `found` false, which runs in the
postmaster under `AddinShmemInitLock` exactly as the resource.dat load
does, reads the files back:

1. `stats.dat`, if present, with matching version and system
   identifier, fills `SpockMonitorStatsHash` with `nattached` 0 and
   `dropped` false and fills `SpockHash`. Workers attaching later find
   their entry and keep counting. A mismatch is logged as a WARNING and
   the file is ignored, as with resource.dat.
2. `events.log.old` then `events.log` are read and the last
   `event_capacity` records with a good CRC are placed into the ring in
   id order. `next_event_id` continues from the header's value, plus a
   ring's worth after a crash, since the previous run may have handed
   out ids for events it had not written yet. Ids therefore never
   repeat, and `spock.events` after a restart shows what it showed
   before.
3. One event of a new type `node_started` is appended. Its detail says
   how many events and counter entries were restored, the time of the
   last flush, and whether the previous shutdown was clean. After a
   crash the detail names the gap: "events after id 4821 (last flushed
   at 12:04:31) were not saved".

Shared memory is reinitialized after a backend crash too, so a crashed
apply worker that takes the postmaster through reinitialization keeps
its history the same way.

The files carry the system identifier, so a copy of the data directory
on another cluster is ignored. A standby made with `pg_basebackup` does
have the same identifier and restores the primary's history and
counters when it starts. That is intended: after a promotion the events
that led to it are on the new primary.

### Reset

`spock.reset_events()` keeps removing the current database's events
from the ring. In addition it puts a reset marker into the ring, which
the next flush writes to `events.log` in order with the events. The
marker is a ring entry with a reserved type `SPOCK_EVENT_RESET_MARKER`,
the database oid and no event id. The restore and the history function
drop the events of that database, and those recorded outside any
database, before the marker. `spock.events` never shows the marker.

`spock.reset_subscription_stats()` and `spock.reset_channel_stats()`
reset shared memory as today and set the supervisor latch, so the reset
reaches `stats.dat` within one flush rather than one interval.

### SQL surface

Nothing existing changes shape. New:

| Object | Purpose |
|--------|---------|
| `spock.event_log(since_id bigint DEFAULT 0, max_rows int DEFAULT 1000)` | Returns the same columns as `spock.events` from the on-disk log, oldest first, so history older than the ring is still queryable. Reads the file in the calling backend. `pg_monitor` may execute it. |
| `spock.monitor_flush()` | Sets the supervisor latch and waits until `flushed_event_id` reaches the current `next_event_id - 1`, with a timeout. For tests and for operators about to take a backup or stop the node. |
| Event type `node_started` | Severity `info`. See restore above. |
| `spock.node_status` columns `events_restored`, `prior_shutdown_clean`, `last_flush_time` | So a report shows whether history was restored and how old the on-disk copy is. |

### GUCs

| Name | Default | Context | Meaning |
|------|---------|---------|---------|
| `spock.monitor_flush_interval` | `5s` | SIGHUP | How often the supervisor writes. `0` disables writing and restoring, which gives the behaviour of today. |
| `spock.event_log_max_size` | `64MB` | SIGHUP | Size at which `events.log` is rotated. |

`spock.event_history_size` keeps its meaning: the size of the ring in
shared memory, and so the number of events restored into it.

### What a crash loses

Events recorded after the last flush. With the defaults that is at most
5 seconds of `info` events. `warning` and `error` events set the latch
when they are recorded, so they reach disk within the time the
supervisor needs to wake up, normally milliseconds. Counter increments
after the last snapshot are lost the same way. The `node_started` event
names the window, so an operator reading the history knows where the
gap is.

### Upgrade

No existing SQL object changes. The 6.0 script, and the 5.0.12 to 6.0.0
upgrade script, add the two functions and the new columns. The format
version in the file headers starts at 1. A newer spock reading an older
format converts record by record, as the resource.dat comment already
says for `SpockApplyProgress`.

### Tests

A TAP test that records events and counters, runs
`spock.monitor_flush()`, stops the node with `pg_ctl stop -m immediate`,
starts it, and checks that `spock.events` shows the same ids, that
`node_started` reports the shutdown as not clean, that
`spock.subscription_stats` continues from the old values and that
`spock.event_log()` returns events older than the ring after lowering
`spock.event_history_size`. A second case stops the node cleanly and
checks the clean flag. A third case sets
`spock.monitor_flush_interval = 0` and checks nothing is written. The
regression test for the views does not change.

### Size

About 500 lines in `spock_monitor.c` for the writer, the reader and the
two functions, 40 lines in `spock.c` for the GUCs and the supervisor
loop, SQL and documentation.

## Moving counters to cumulative statistics on PostgreSQL 18

The second request is to move the numeric counters to PostgreSQL's
cumulative statistics, as the `confl_*` counters already are through
kind 29 in `spock_conflict_stat.c`.

### What it gives and what it does not

It does **not** give crash safety. `StartupXLOG()` calls
`pgstat_discard_stats()` whenever the server starts with crash recovery
and `pgstat_restore_stats()` only after a clean shutdown
(`src/backend/access/transam/xlog.c`, around line 5798 in 18.x). Every
`pg_stat_*` view is empty after a crash, and so is anything spock keeps
there. The on-disk snapshot above is therefore still needed on 18, and
after a crash it is what seeds the spock entries in the statistics
system again.

It does give:

- no size limit on the channel counters, so `stats_hash_full` goes
  away, and no spinlock per counter increment: pending counts accumulate
  in backend-local memory and reach shared memory at
  `pgstat_report_stat()`, which the apply worker already calls;
- reset timestamps and entry lifetime handled by PostgreSQL, including
  transactional drop when a subscription is dropped and rolled back;
- clean restarts handled by PostgreSQL, as `write_to_file` is set.

It changes one visible thing: the counters lag the apply worker by up to
`PGSTAT_MIN_INTERVAL`, one second, instead of being exact at the time of
the query. The documentation has to say so.

### Why it cannot be done on 15, 16 and 17

`pgstat_register_kind()` and the custom kind range exist only in 18
(`PGSTAT_KIND_CUSTOM_MIN` in `pgstat_kind.h`). The 16 and 17 headers do
not have the function. The statistics system of 15 to 17 is not
extensible: the kinds are a fixed array compiled into the server and
the shared hash table rejects unknown kinds. There is no way for an
extension to add a kind without patching the server, and spock's
`patches/` directory is for pg_upgrade and slot handling, not for a
change of this size in every supported release. So on 15 to 17 the
counters stay in shared memory and get crash safety from the snapshot
file alone. That is the same split `spock_conflict_stat.c` already has.

### Layout on 18

Two new kinds, registered next to kind 29. The ids have to be taken from
the PostgreSQL wiki page CustomCumulativeStats and the stale comment in
`spock_conflict_stat.c` lines 30 to 33 updated to say that 29 is
registered to spock.

**Channel counters.** Kind keyed by `dboid` and
`objid = ((uint64) subid << 32) | relid`. `PgStat_HashKey.objid` is a
`uint64` in 18, so both oids fit. The pending entry holds the five
`int64` counters. `handle_stats_counter()` becomes
`pgstat_prep_pending_entry()` plus an increment. `get_channel_stats()`
cannot walk the shared statistics hash by kind in the public API, so it
keeps a list of keys: `pgstat_fetch_entry()` per subscription and
relation pair that `spock.subscription` and `spock.tables` know about,
or a walk over the shared hash under `pgstat_internal.h`, which is what
`pg_stat_statements` avoids and `spock_conflict_stat.c` already uses.
The walk is simpler and is what to do.

**Subscription counters.** Kind keyed by `dboid` and `subid`, holding
the counters that are bumped from a transaction context:
`messages_received`, `bytes_received`, `xacts_applied`,
`xacts_skipped`, `xacts_discarded`, `tables_synced`,
`provider_connects`, `provider_disconnects` and `idle_timeouts`.

The counters bumped from the error path stay in shared memory on every
version: `worker_failures`, `sync_worker_failures`, `apply_errors`,
`sync_errors`, `deadlocks`, `lock_timeouts`, `constraint_violations`
and `resource_errors`. `pgstat_prep_pending_entry()` allocates in
`TopMemoryContext`, and `spock_monitor_report_error()` runs from the
emit_log_hook and from the worker exit path, where an allocation failure
would recurse into the hook. The same holds for `worker_starts`, which
is counted before the worker has a statistics entry. The shared memory
entry also keeps `counter_time[]`, the last error fields and
`stats_reset`, which the statistics model has no place for.

So `spock.subscription_stats` on 18 joins two sources, the shared memory
entry and the statistics entry, inside `spock_get_apply_stats()`. The
view and its columns do not change.

### Re-seeding after a crash

On 18 the flusher snapshots the statistics-backed counters too, by
`pgstat_fetch_entry()` on each key it finds in shared memory. After a
crash recovery the first flush finds the statistics entries empty while
the restored shared memory copies are not, and recreates each entry
with `pgstat_get_entry_ref(..., create = true)` and a copy of the
counters under `pgstat_lock_entry()`. That is the one place spock
writes to a shared statistics entry directly; `spock_conflict_stat.c`
does the same in its flush callback.

### Order of work

1. Event log and stats snapshot, all versions. This is what answers the
   crash question and is independent of the rest.
2. Channel counters to a new kind on 18. Largest gain, smallest
   surface: one writer, one reader, one reset function.
3. Subscription counters to a new kind on 18, with the split above.
4. Documentation of restart and reset behaviour per version in
   `docs/monitoring/node_monitoring.md`.

The rough sizes in the request hold: 200 to 300 lines for the channel
counters and 150 to 250 for the subscription counters, plus the
re-seed, which is about 80 lines shared by both.
