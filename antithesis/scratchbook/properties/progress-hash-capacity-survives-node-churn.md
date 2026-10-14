# progress-hash-capacity-survives-node-churn

## Summary

`SpockGroupHash` (the shared-memory table behind `spock.progress`) has a fixed
capacity equal to `max_worker_processes` and entries are **never deleted**
(`src/spock_group.c:41-42`, "Entries are never deleted during normal
operation"). Entries are also written to `PGDATA/spock/resource.dat` and
reloaded at every postmaster start, including crash restarts, so unlike the
exception slots a restart does **not** reclaim them. Each new remote node id seen
by a node adds an entry `(dbid, local_node_id, remote_node_id)`. Node ids come
from a hash of the node name, so add/remove cycles with fresh node names grow
the table until it is full.

Lead L16 in `sut-analysis.md`.

## Code path (HEAD 69d9228f)

- Creation: `ShmemInitHash("spock group hash", nworkers, nworkers, ...,
  HASH_FIXED_SIZE | HASH_PARTITION)` with `nworkers = SpockCtx->total_workers =
  max_worker_processes` (`src/spock_group.c:137-171`, `src/spock_shmem.c:132-159`).
- Inserts with `HASH_ENTER`:
  - `spock_group_ensure_entry` from `spock_create_subscription`
    (`src/spock_functions.c:710`; `src/spock_group.c:253-288`), so a full table
    makes **`sub_create` fail**.
  - `spock_group_attach` at apply-worker start (`src/spock_apply.c:2355`;
    `src/spock_group.c:206-240`), so a full table makes **apply-worker start
    fail**, and the manager restarts it every `restart_delay_default` for ever.
  - `spock_group_progress_update` (`:395-420`), used by `resource.dat` load at
    postmaster start (`:625-700`) and by table-sync progress lists.
  - `spock_group_progress_force_set_list` (`:765-790`) from add_node.
  - `reconcile_progress_with_origin` (`src/spock_progress_recovery.c:173`),
    called from `spock_init_progress_state` at apply-worker start (before
    replication starts). A fifth site, found 2026-10-13; it has the same dead
    `entry == NULL` "SpockGroupHash is full" WARNING branch.
- The code checks for `entry == NULL` after `HASH_ENTER` and logs "SpockGroupHash
  is full". **Those checks are dead code**: in stock PG18 `dynahash.c:1085-1096`,
  `HASH_ENTER` on a shared table that cannot get a free element raises
  `ereport(ERROR, errcode(ERRCODE_OUT_OF_MEMORY), "out of shared memory")`. Only
  `HASH_ENTER_NULL` returns NULL. (Checked in a local PG18 source tree.) So:
  - In the apply worker the error is SQLSTATE 53200, class 53, and the
    classifier treats it as transient: retry every 5 s, for ever. Nothing says
    "the table is full"; the log just says "out of shared memory".
  - In `sub_create` the caller gets "out of shared memory".
  - In `resource.dat` load (postmaster `shmem_startup_hook`) an ERROR stops the
    postmaster from starting. That can only happen if the file holds more
    entries than fit, for example after `max_worker_processes` was lowered.
- Partitioned fixed-size dynahash borrows across freelists
  (`dynahash.c:1293-1300`), so usable capacity is about `nworkers` entries.

## How the workload reaches it

- On an existing node X, every distinct node name that ever subscribed to or
  from X adds an entry. In the planned topology X starts with two entries
  (the other two mesh peers). Each fresh-name join of the spare node adds one.
  With `max_worker_processes=32`, about 30 cycles. With a small-capacity config
  variant (for example `max_worker_processes=10`), about 8 cycles.
- ZODAN Phase 10 creates `new -> X` subscriptions on each X and raises an
  EXCEPTION on failure (`samples/Z0DAN/zodan.sql:2245-2265`), so add_node fails
  **visibly**. But a sub created earlier whose apply worker restarts after the
  table filled (for example after a crash restart reloaded a full
  `resource.dat`) stalls with only a log line.
- Stale entries are also fed into `spock.read_peer_progress()` and ZODAN Phase 7
  reads them. That is a separate correctness concern (L17), not this one.

## Property

Removing nodes frees progress-table capacity, or at least the table never fills
while the number of live `(local, remote)` pairs is below capacity. In
assertion terms: the out-of-shared-memory error from the progress hash is never
raised while live pairs are below `max_worker_processes`.

## Assertions (all missing)

1. SUT-side `Unreachable("spock progress hash full")`. Switch the five
   `HASH_ENTER` call sites to `HASH_ENTER_NULL` (or check
   `hash_get_num_entries` before inserting) so the existing `entry == NULL`
   branches actually run, and put the assertion in each. Use one message per
   site, since each has different effects: "...full at sub_create",
   "...full at apply attach", "...full at apply reconcile",
   "...full at resource load", "...full at force-set".
2. Workload-side check after each add/remove cycle: `SELECT count(*) FROM
   spock.progress` on each node, compared with the live pair count. Report it
   with a `Sometimes(count > live_pairs + 2, "progress hash holds stale
   entries")` so the run shows that stale entries are building up. That is a
   reachability signal, not a failure.

`Unreachable` fits (1): with fewer live pairs than capacity, a full table can
only mean leaked entries.

## Fault requirements

- None needed to fill the table. Node restarts **do not** reset it (it is
  reloaded from `resource.dat`), so kills do not hide it, unlike the exception
  slots.
- A node restart after the table is full exercises the "apply attach fails"
  path.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (TAP territory), implementability CW2/CW8 and property finding); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v2/small-capacity (fresh-name node churn; confirm with a TAP loop first) · Faults: node churn

- Evaluation note (2026-10-13): the hash is keyed by (dbid, node_id, remote_node_id), so only fresh node names grow it; subscription churn does not. Reaching about `max_worker_processes` ZODAN cycles in one Antithesis run is slow, so a TAP loop is the cheaper first check.
- `HASH_ENTER_NULL` replaced with a count check before the insert, so the instrumented build still runs the shipped error path.

## Open questions

- Is "entries are never deleted" a deliberate design decision, and is the
  expected fix "delete on node_drop / sub_drop when `nattached` is 0" or "size
  the table from something larger than `max_worker_processes`"? This decides
  whether this property is a bug report or a capacity-planning note.
  `(needs human input)`

### Investigation Log

#### Is "entries are never deleted" deliberate, and what fix is expected?

- Examined: header comment of `src/spock_group.c:11-45`; `spock_group_attach`
  / `spock_group_detach` (`:200-296`); `git log -S"Entries are never deleted"`
  (introduced in `b8f1eea9`, "Spock resource manager (#151)", 2025-10-08);
  `docs/` for any statement about `spock.progress` rows after node removal;
  `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`.
- Found: the comment ties "never deleted" to pointer stability: "pointers
  returned by spock_group_attach() are stable for the lifetime of the
  postmaster". Workers keep that pointer in shared memory
  (`MyApplyWorker->apply_group`). Each entry already has an `nattached` counter
  (`:235-239, 289-295`), so a delete gated on `nattached == 0` would be
  possible, but nothing does it. The design spec explicitly leaves the hash
  layout out of scope. No doc says stale rows are expected or how many a node
  can hold.
- Not found: any statement of intent about removed nodes, or any sizing
  guidance for the table.
- Conclusion: the never-delete rule is deliberate for pointer safety; whether
  growth with node churn is accepted is an owner decision. Tagged
  `(needs human input)`. The `Unreachable` assertions stay valid either way:
  even if growth is accepted, filling the table while live pairs are under
  capacity breaks `sub_create` and apply-worker start.

#### Does `spock.node_drop` / `remove_node` have any hook that could delete entries?

- Examined: `grep -rn HASH_REMOVE src/` (only `SpockHash` channel stats in
  `spock_functions.c:3840` and `RelMetaCache` in `spock_output_plugin.c`),
  every `SpockGroupHash` user (`spock_group.c`, `spock_progress_recovery.c`,
  `spock_rmgr.c`, `spock_functions.c:4494-4504`, `spock_apply.c`,
  `spock_sync.c`), `spock_drop_node` (`spock_functions.c:315-390`) and
  `spock_drop_subscription` (`:762-870`).
- Found: no code removes `SpockGroupHash` entries. `resource.dat` dumps write
  every entry, and loads re-insert every entry, so stale entries also survive
  clean and crash restarts. While checking, found a fifth `HASH_ENTER` site
  (`spock_progress_recovery.c:173`, apply-worker start) with the same dead
  NULL check; added to the code-path list and assertion 1.
- Conclusion: resolved. No delete path exists at HEAD.
