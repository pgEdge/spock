# exception-log-slots-never-exhausted

## Summary

Spock keeps one shared-memory "exception log" entry per **subscription name**
(`exception_log_ptr[]`, `max_worker_processes` entries, allocated in
`src/spock_worker.c:872` as the separate shmem struct `"spock_exception_log"`).
Entries are claimed on the first BEGIN an apply worker sees and are **never
released** — not on `sub_drop`, not on `remove_node`. Only a postmaster
(crash-)restart clears them. After `max_worker_processes` distinct subscription
names have applied at least one transaction since the last postmaster start,
the next new subscription hits the "no free slot" branch. Code reading shows
that branch turns a capacity limit into a node-wide hang.

Lead L14 in `sut-analysis.md`; six discovery focuses agreed on the leak, F8 on
the hang. Re-checked against HEAD 69d9228f for this property.

## Code path (HEAD 69d9228f)

- `handle_begin` (`src/spock_apply.c:658`).
  - First BEGIN after worker start: scans for an entry whose `slot_name` equals
    `MySubscription->name` (`:722-743`).
  - Not found: `LWLockAcquire(SpockCtx->lock, LW_EXCLUSIVE)` (`:762`), rescans,
    remembers the first entry with empty `slot_name`.
  - None free: `elog(ERROR, "SPOCK %s: unable to find an empty exception log slot.")`
    (`:786-790`) **while still holding `SpockCtx->lock`**. A bare elog, so
    SQLSTATE XX000.
  - The claim: `namestrcpy(&new_elog_entry->slot_name, ...)` with the comment
    `TODO: What happens if a subscription is dropped? Memory leak` (`:797-806`).
- `clear_exception_log_entry` (`:386-395`) resets `commit_lsn`, `local_tuple`,
  message and action, but **not `slot_name`**, so the claim is never undone.
- `my_exception_log_index` starts at `-1` (`:120`) and is only set on a
  successful find or claim (`:735, 773, 814`).
- `apply_work` `PG_CATCH` (`:3867-4133`). XX000 is not connection-class, not
  40P01/55P03, not class 53, and `use_try_block` was just set false (`:756`), so
  it takes the "first data error" branch:
  - `AbortOutOfAnyTransaction()` (`:4065`). No transaction is open at BEGIN, so
    this does not run `AbortTransaction`, which means **`LWLockReleaseAll` is
    not called** and `SpockCtx->lock` stays held.
  - Then writes `exception_log_ptr[my_exception_log_index].initial_error_message`
    and `.failed_action` with index `-1` (`:4075-4100`). That is an
    out-of-bounds write into the shared memory just before the
    `"spock_exception_log"` struct. `snprintf` writes only the message plus
    its NUL (about 70-100 bytes, not the full 1024-byte field), starting
    about 1032 bytes before the array, and `failed_action = 1` lands 8 bytes
    before it. On PG18 that memory is the tail of `SpockCtx->workers[]` (see
    the Investigation Log).
  - `first_begin_at_startup = true` (`:4121`), replay starts, and the replayed
    BEGIN calls `handle_begin` again. That reaches `LWLockAcquire(SpockCtx->lock,
    LW_EXCLUSIVE)` a second time **in the same process**. PG LWLocks cannot be
    taken twice, so the worker waits on itself for ever.
- `SpockCtx->lock` is taken SHARED for every applied row (`handle_stats_counter`,
  `src/spock_worker.c:~944`), by the manager, by worker attach/detach, by
  `sub_show_status`, `pause_apply_workers` and shutdown. Once one apply worker
  holds it EXCLUSIVE for ever, **all replication on the node stops**, admin
  calls hang, and fast shutdown can block. LWLock waits cannot be interrupted, so
  SIGTERM does not help. Only SIGKILL (crash restart) recovers.

### Second way to reach the same branch: a claim race (found 2026-10-13)

The "no free slot" ERROR is checked **before** the "found my name in the
locked rescan" result is used (`:784-790` comes before `:793`). Entries are
never freed and a claim always takes the first empty entry, so every entry
below a claimed one is in use. If the locked rescan finds this subscription's
name (another worker with the same name claimed it between our unlocked scan
and our `LWLockAcquire`), `free_slot_index` is still `-1`, and the worker
raises "unable to find an empty exception log slot" **with plenty of free
entries left**, while holding `SpockCtx->lock`.

- Who shares a name: the apply worker and any table-sync worker of the same
  subscription (`spock_sync.c:2002-2016` keeps `MySubscription->name`; the
  sync worker runs `apply_work` for catch-up, `:2084`).
- The window: both must take their first BEGIN at about the same time and
  both must miss each other in the unlocked scan. Example: an apply worker
  that has not applied anything yet (idle provider, or just after a restart)
  and a `sub_resync_table` / `sub_add_table` sync worker entering catch-up.
- On this path `my_exception_log_index` was already set to the found entry,
  so there is no out-of-bounds write. The PG_CATCH path still leaves
  `SpockCtx->lock` held (no transaction open, see the log). On replay the
  unlocked scan now finds the entry, so the worker does not self-deadlock in
  `handle_begin`; it self-deadlocks on the next `LWLockAcquire(SpockCtx->lock,
  LW_SHARED)` in `handle_stats_counter` (`spock_worker.c:948`, on by default
  through `spock.channel_counters`), and every other process that needs the
  lock waits behind it. Same node-wide hang.

So the `Unreachable` assertion below can fire for two reasons: leaked entries
(capacity) and this race (below capacity). Both are defects.

## How the workload reaches it

- Each node accumulates one entry per distinct subscription name that applied
  a transaction since its postmaster started. ZODAN names subscriptions
  `sub_<provider>_<subscriber>` (`spock.gen_sub_name`). Each add/remove cycle of
  a spare node under a **new node name** adds one entry on every existing node.
  Re-adding under the same name reuses the entry. Apply and sync workers of one
  subscription share an entry (same name).
- With `max_worker_processes=32` that needs about 30 fresh-name cycles without a
  restart of that node. A config variant with a small `max_worker_processes`
  (for example 10; supervisor + manager + 3 apply + 1 sync + parallel workers
  still fit) gets there in about 7 cycles.
- Same-named subscriptions in two databases share one entry (not a leak, but the
  two can overwrite each other's marker; out of scope for one-DB v1).

## Property

While the number of live subscriptions on a node is below
`max_worker_processes`, the "unable to find an empty exception log slot" branch
is never reached. And any apply worker that does raise an ERROR in
`handle_begin` must not leave `SpockCtx->lock` held.

## Assertions (all missing; no Antithesis instrumentation exists)

1. SUT-side `Unreachable("exception log slot table full")` placed just before
   the `elog(ERROR)` at `src/spock_apply.c:~788`, for the case where the locked
   rescan did **not** find our own name. This is the main assertion. The
   workload keeps live subscriptions below `max_worker_processes`, so reaching
   it means leaked entries are using up the space.
2. SUT-side `Unreachable("exception log claim raised no-free-slot although own entry was found")`
   at the same line, for the case `slot_found && free_slot_index == -1`. This is
   the claim race described above. Keep it a separate message so a hit points
   at the race, not at the leak.
3. SUT-side `AlwaysOrUnreachable(my_exception_log_index >= 0, "exception
   marker index valid in PG_CATCH")` at `src/spock_apply.c:~4074`, before the
   `initial_error_message` write. It catches the out-of-bounds write directly,
   whatever caused it.
4. SUT-side `AlwaysOrUnreachable(!LWLockHeldByMe(SpockCtx->lock), "apply
   PG_CATCH does not keep SpockCtx->lock")` at the end of the "first data
   error" branch, just before `need_replay = true` (`:~4130`). This checks the
   second half of the property for any cause.
5. Workload-side liveness check (part of the general reconnect property,
   repeated here): after each add/remove cycle, `sync_event` from every node
   reaches every other node within the liveness bound. A node hang shows up as
   every barrier into or out of that node timing out.

`Unreachable` fits (1) and (2) because, with live subscriptions under
capacity, the state should never happen at all. It is not a progress claim.

## Fault requirements

None are needed for the leak. This is a churn and capacity problem. Faults do
not reset the slots unless they crash-restart the postmaster (SIGKILL of any
backend), which **clears** them. So node kills make it harder to reach. Use a
run phase or a variant with no kills on at least one node during the churn
loop.

The race (assertion 2) needs a table resync or add-table on a subscription
whose apply worker has not yet applied a transaction since its postmaster
started: for example right after a node restart, issue `sub_resync_table`
while provider traffic resumes. Thread-timing exploration does the rest.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (TAP territory), implementability CW8 and property finding); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 (race route); v2/small-capacity with node kills off (capacity route) · Faults: table resyncs right after a restart (race); fresh-name subscription churn (capacity)

- Evaluation note (2026-10-13): slots are claimed per subscription name, so the capacity route uses throwaway subscriptions with fresh names (`sub_create`, one write, wait, `sub_drop`) about `max_worker_processes` times on one node without a restart, not ZODAN node churn; a TAP loop reaches it faster, so confirm there first. The race route (apply and sync workers of one subscription claiming at their first BEGIN together, below capacity) is real timing and stays in v1; it may become its own property (gap-fill decision).

## Open questions

- Apply and sync workers of one subscription share one entry, and
  `handle_begin` writes `commit_lsn` on every BEGIN (`:877-878`); a mismatch
  also clears the other worker's recorded failure (`:871`). Can that make a
  restarted apply worker miss its exception-handling entry (an error loop
  instead of the configured exception behaviour), or enter it for a
  transaction that did not fail? `(partial: overwrite and clear confirmed in code; effect on the classifier not traced)`

### Investigation Log

#### Does any path clear `slot_name`?

- Examined: every write to `exception_log_ptr[...]` in `src/` (grep), and
  `clear_exception_log_entry`.
- Found: `slot_name` is written only at `:804` (claim). Clearing resets the
  other fields only. `sub_drop` (`src/spock_functions.c:762-870`) does not
  touch the array.
- Conclusion: the leak is real at HEAD.

#### Does the error branch really keep the LWLock?

- Examined: `handle_begin` `:762-816`; `apply_work` PG_CATCH `:4040-4125`;
  stock `AbortOutOfAnyTransaction` behaviour in TBLOCK_DEFAULT/TRANS_DEFAULT
  (no AbortTransaction, so no LWLockReleaseAll).
- Not verified: that no transaction is open when `handle_begin` runs (a
  transaction is normally started by `begin_replication_step` on the first
  change). If one were open, `AbortTransaction` would release the lock and only
  the out-of-bounds write would remain.
- Conclusion: `(partial: mechanism present in code; not run)`.
- 2026-10-13 follow-up: resolved by the next entry. No transaction is open, so
  the lock is kept.

#### Is a transaction ever open when `handle_begin` runs?

- Examined: `apply_work` loop (`src/spock_apply.c:3456-3866`),
  `replication_handler` dispatch (`:2976-2997`), `handle_commit` (`:911-1260`),
  `begin_replication_step` (`:600-620`), `spock_cleanup_resolutions` call site
  (`:3571-3584`), and PG18 `AbortOutOfAnyTransaction`
  (`~/dev/pgedge/postgresql` REL_18_STABLE, `xact.c`) and `LWLockAcquire`
  (`lwlock.c`).
- Found: the local transaction is started lazily by `begin_replication_step`
  on the first change, after BEGIN. `handle_commit` commits it inside
  `if (IsTransactionState())` (`:968-1058`) and, for skipped transactions,
  starts and commits its own. `spock_cleanup_resolutions` runs only when
  `!IsTransactionState()` and manages its own transaction. `handle_begin` calls
  nothing that starts one. So at BEGIN the state is TBLOCK_DEFAULT /
  TRANS_DEFAULT, where PG18 `AbortOutOfAnyTransaction` does nothing ("Not in a
  transaction, do nothing") and `LWLockReleaseAll` is not reached. PG18
  `LWLockAcquire` has no check for a lock already held by the same process; it
  just queues and sleeps. It also does `HOLD_INTERRUPTS()`, which the
  `PG_CATCH` path never undoes, so the worker also ignores SIGTERM.
- Not found: any code path that leaves a local transaction open across a
  remote COMMIT.
- Conclusion: resolved. The node-wide hang is real by code reading (not run).

#### What sits immediately before `"spock_exception_log"` in shared memory on PG18?

- Examined: `spock_shmem_startup` (`src/spock_shmem.c:141-176`),
  `spock_worker_shmem_startup` (`src/spock_worker.c:843-892`),
  `spock_ctx_shmem_size` (`spock_shmem.c:75-84`), struct layouts in
  `include/spock_worker.h` and `include/spock_exception_handler.h:54-61`, PG18
  `ShmemAllocRaw` (`shmem.c:203`, `CACHELINEALIGN`, `PG_CACHE_LINE_SIZE` 128).
- Found: inside one `shmem_startup_hook` call, holding `AddinShmemInitLock`,
  Spock allocates `"spock_context"` (`SpockContext` header plus
  `SpockWorker workers[max_worker_processes]`) and then immediately
  `"spock_exception_log"`. Allocations are rounded up to 128 bytes, so index
  `-1` (1112 bytes per entry) points into the last ~1 KB of the `"spock_context"`
  block: the padding (0-127 bytes) and the last few `SpockWorker` entries
  (about 208 bytes each by field sizes). `snprintf` writes the message (about
  70-100 bytes) about 1032 bytes before the array, so it lands in one of the
  last ~5 worker slots; `failed_action = 1` lands 8 bytes before the array (the
  padding or the last worker slot). `find_empty_worker_slot` hands out the
  lowest free slot first (`spock_worker.c:107-114`), so the high slots are
  usually unused; garbage in an unused slot's `worker_type` makes it look
  taken (and possibly confuses code that switches on the type).
- Not found: exact byte offsets (did not compile a layout probe; reading only).
- Conclusion: resolved. The write corrupts Spock's own worker table, most
  likely unused slots, so it is mostly silent. The hang is the visible symptom.
  Assertion 3 stays useful because it catches the write directly.

#### Is reusing a subscription name after `sub_drop` expected to inherit the old marker?

- Examined: `handle_begin` slot-found branch (`:828-878`),
  `clear_exception_log_entry` (`:386-395`), `gen_sub_name` usage in ZODAN.
- Found: the entry is reused, but the inherited `commit_lsn` only matters if
  the new subscription's first BEGIN carries the **same** commit LSN. Any other
  LSN takes case 3: clear the entry and apply normally. `commit_lsn` is the
  last BEGIN the old subscription saw. A re-created subscription with the same
  name has the same provider (the name encodes it) and a new slot whose start
  point is after every commit the old one decoded, so the LSNs cannot match.
  Two databases with the same subscription name are the only exception, and
  they are out of scope.
- Conclusion: resolved. No stale replay from name reuse. The related, real
  sharing effect is between apply and sync workers of a live subscription;
  kept as a new open question.

#### New finding: the locked rescan can raise "no free slot" when it found its own entry

- Examined: `handle_begin` `:752-816`; `spock_sync_main` (`spock_sync.c:2002-2084`).
- Found: see "Second way to reach the same branch" above. The ERROR test at
  `:786` runs before the `slot_found` result is used, and every entry below a
  claimed one is in use, so finding our name in the locked rescan always
  means `free_slot_index == -1`.
- Conclusion: a separate defect that reaches the same hang below capacity.
  Added assertion 2.
