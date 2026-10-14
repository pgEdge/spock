# progress-reconcile-anomaly-unreachable

## What the property says

When an apply worker starts, `reconcile_progress_with_origin()` compares the
`SpockGroupHash` entry (loaded from `resource.dat` or left over in shared
memory) with the subscription's replication origin LSN. Without operator
intervention, the entry must never be **ahead** of the origin. The
`RECONCILE_FILE_ANOMALY` branch must not be reached in a run where the
workload never calls `pg_replication_origin_advance` / `sub_alter_skiplsn` by
hand.

## Code

`src/spock_progress_recovery.c:153-275`:

- entry absent -> seed from origin (`RECONCILE_FILE_ABSENT`)
- `remote_commit_lsn == origin_lsn` -> `IN_SYNC`
- `remote_commit_lsn < origin_lsn` -> `STALE`, clear timestamps (expected
  after a crash: the file is from the last clean shutdown)
- `remote_commit_lsn > origin_lsn` -> `ANOMALY`, WARNING "file LSN %X/%X ahead
  of origin %X/%X; trusting origin", values discarded. The comment says the
  likely causes are "operator intervention on the replication origin ... or
  filesystem corruption".

So the code's own model says ANOMALY means something outside normal
operation moved the origin backwards. Ways it can happen with no operator:

1. **L1 regression of the origin on crash, combined with an entry that was
   written after the last checkpoint and survived.** Shared memory is wiped by
   a crash restart, so the entry must come from `resource.dat`. The file is
   written at clean shutdown (after which the shutdown checkpoint makes the
   origin at least as new), at add_node force-set, and at table-sync COPY end
   (`spock_group_progress_force_set_list`, sut-analysis 2.6). A force-set
   during a running node followed by a crash before the next checkpoint can
   leave file > origin if the force-set entry's key is the same as a live
   subscription's key and its LSN is above what the origin's last checkpoint
   held. Not traced through every force-set caller. The most likely concrete
   case is on the joining node n4: Phase 5 force-sets entries for keys
   (n4, X) and dumps `resource.dat`; the disabled `sub_n4_X` origins are only
   advanced in Phase 7. If n4 crashes in between and an apply worker for
   (n4, X) starts before Phase 7 runs (retry after a partial add_node, or the
   sub enabled by hand), the file is ahead of the origin. Entries are never
   deleted (`src/spock_group.c:41-42`), so a stale entry from a failed add_node
   also survives `remove_node` and meets a re-created subscription with the
   same key.
2. **Same-worker restart without a crash** (SIGTERM, ERROR): shared memory
   survives, the entry holds the last `handle_commit` LSN (`end_lsn`), and the
   origin in memory is at least that. Should be IN_SYNC. If anything advanced
   the shared entry but not the origin (for example `UpdateWorkerStats` or a
   commit whose origin advance was skipped under SUB_DISABLE replay,
   `src/spock_apply.c:996-1009`), ANOMALY results. The SUB_DISABLE case
   looks real: `handle_commit` keeps `replorigin_session_origin_lsn` at the
   BEGIN `commit_lsn` for a SUB_DISABLE replay, but the progress update below
   it uses `.remote_commit_lsn = end_lsn` — it is never reached in that path
   because the `elog(ERROR)` for SUB_DISABLE comes first. Checked: no ANOMALY
   from this path.
3. **Two subscriptions to the same provider share one entry** (key has no
   subscription id, L16). The second one's origin can be behind the first
   one's entry. Not in the v1 topology (one sub per provider per node).

So in v1 only (1) is a candidate. The value of the property is that it is
cheap and catches any future path that moves an origin backwards.

## Assertions

- **SUT-side (missing, no existing assertions):** in the ANOMALY branch,
  `Unreachable("progress entry ahead of replication origin at apply start",
  {sub, file_lsn, origin_lsn})`. Unreachable: the code itself calls this an
  anomaly.
- **Workload-side alternative:** scan node logs for "ahead of origin ...
  trusting origin" and fail on a hit (`Unreachable` with the same meaning).

## Fault requirements

- Node termination soon after add_node (force-set path) or after a table
  resync completes; large `checkpoint_timeout`.
- Single apply-worker kills (SIGTERM) for path 2.

## Open questions

- Does the v1 workload run table resyncs (`spock.sub_resync_table`, or
  `repset_add_table` with sync)? If yes, the ANOMALY branch is reachable with
  no operator action (path 4 below) and the `Unreachable` must either exclude
  those timelines or be accepted as a finding about `spock.progress`
  accuracy. `(partial: path confirmed in code; workload choice not made yet)`

## Findings (2026-10-13)

- **Role of `spock.progress`.** In C it never decides where replication
  starts: the apply worker starts from the replication origin
  (`replorigin_session_get_progress`, `src/spock_apply.c:4749-4751`), and
  ANOMALY always trusts the origin. It *is* a correctness input for ZODAN
  add_node: Phase 3 waits on src's `remote_commit_lsn` for each peer
  (`samples/Z0DAN/zodan.sql:1925-1975`) and Phase 7 places each peer's slot
  and n4's origin from n4's row (`:2637-2662`). The design spec calls the
  force-set rows "deduplication state ... not just monitoring"
  (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:130`).
  So an ANOMALY hit is not data loss by itself (origin wins), but it shows a
  row that disagreed with the origin, and on n4 such a row is what Phase 7
  would have used.
- **Force-set writes live keys.** `peer_progress_from_row` builds keys
  `(MyDatabaseId, MySubscription->target->id = n4, X)`
  (`src/spock_sync.c:526-528`), exactly the key of n4's `sub_<X>_<n4>`
  worker. So path (1) is possible in principle.
- **Concrete no-operator paths found:**
  1. *Re-add / retried add with a peer left out of `read_peer_progress`.*
     Phase 3 drops and recreates n4's origin for `sub_<X>_<n4>` (0/0), but
     the progress row from the earlier attempt survives (never deleted,
     `ensure_entry` keeps it). Phase 7 reads the stale LSN, skips both
     advances, and when Phase 9 enables the sub the worker sees row > origin
     -> ANOMALY. Ties to `zodan-readd-node-progress-not-stale`.
  2. *Phase 7 "already at or beyond" with a non-zero force-set row.* Same
     shape (origin left at 0/0, row non-zero). Normally prevented because
     Phase 3 makes src apply X past a sync_event committed after the slot,
     so the force-set LSN is above the slot's `restart_lsn`.
  3. *Crash on n4 between force-set and Phase 7.* Kills the add_node session
     (it runs on n4), so this only matters for the retry, which is case 1.
  4. *Table resync on any node.* `copy_tables_data` ->
     `read_provider_progress` -> `spock_group_progress_update_list`
     (`src/spock_sync.c:580-630, 1296-1309`) writes the **provider's**
     progress for each peer X into the subscriber's live (target, X) row
     (max by commit ts) and dumps `resource.dat`. If the subscriber is
     behind the provider on X, its row is now ahead of its own origin. Any
     restart of the subscriber's X worker before it catches up (error,
     disable/enable, crash, which reloads the file) gives ANOMALY. The code
     comment there says "this machinery serves information goals only".
- Path 2 in the original text (SUB_DISABLE) was already ruled out; path 3
  (two subs to one provider) stays out of v1.
- Property unchanged in form (`Unreachable`); its value is higher than "pure
  regression guard" because paths 1 and 4 are live. Priority depends on the
  open question above.

### Investigation Log

#### Is `spock.progress` correctness state or monitoring?

- Examined: `src/spock_group.c:1-45` (header; no "monitoring only" wording
  at HEAD, it describes persistence and reconcile), `src/spock_apply.c:4740-4770`,
  `src/spock_sync.c:1300-1309` (comment "serves information goals only"),
  ZODAN Phase 3/7, the design spec line 130, grep of `src/` for readers of
  `remote_commit_lsn`.
- Found: C uses it for monitoring and for `wait_for_previous_transaction`
  timestamps; ZODAN uses it to wait (Phase 3) and to place slots (Phase 7).
- Conclusion: resolved. Monitoring for steady-state replication,
  coordination state for add_node. ANOMALY is a warning sign, not loss.

#### Which keys does force-set write?

- Examined: `src/spock_sync.c:518-575` (`peer_progress_from_row`),
  `:1736` (force-set call), `src/spock_group.c:755-825`.
- Found: (db, n4, X) for each peer X returned by src, the same key as n4's
  live `sub_<X>_<n4>`. Table-sync `update_list` writes (db, target, X) on
  existing nodes too.
- Conclusion: resolved. Path (1) is possible; two more concrete paths found
  (re-add/retry, table resync).
