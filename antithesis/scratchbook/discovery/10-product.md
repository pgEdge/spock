# 10. Product Context — Spock (user's view)

Focus: what the product promises users, which workflows matter, what a user
would call data loss/divergence vs expected behaviour, and which documented
limitations define what an Antithesis workload must NOT do (or properties
become false positives).

All "claims" below are quoted/paraphrased from docs; they are recorded as
claims, not verified facts.

---

## Findings

### F1. What the product is, and the typical deployment shape

- Spock = multi-master (active-active) logical replication extension for
  PostgreSQL 15–19 (README.md "Prerequisites"). Requires a **patched**
  PostgreSQL (`patches/<ver>/pgNN-015-attoptions.diff`,
  `pgNN-025-logical_commit_clock.diff`, `pgNN-030-per-subtrans-commit-ts.diff`).
- One database at a time; each replicated DB is configured separately
  (docs/limitations.md "One Database at a Time").
- **Shape = full mesh.** `spock.sub_create(... forward_origins := '{}')` is the
  default (docs/spock_functions/functions/spock_sub_create.md) — a provider
  only sends changes that originated locally on it. So every node must
  subscribe directly to every other node: N nodes ⇒ N·(N-1) subscriptions,
  one apply worker per subscription, one slot per subscription on the
  provider (plus a second temporary slot per sync).
  `forward_origins = {all}` exists but may only be used when it is the single
  enabled subscription on the node (docs/spock_functions/sub_mgmt.md
  "Origin Forwarding") — i.e. cascades, not a mesh. **Workload should not use
  forwarding inside a mesh.**
- Documented examples: 2-node (getting_started.md, two_node_cluster.md),
  3-node + add 4th (zodan_tutorial.md), 5-node (catastrophic_node_failure.md).
  Config comments size for "a four-node mesh replicating one database"
  (configuring.md). The in-tree CI cluster is 3 nodes
  (tests/docker/docker-compose.yml: n1,n2,n3), built by `node_create` on n1 and
  `CALL spock.add_node(src:=n1, ...)` (Zodan) on n2/n3
  (tests/docker/entrypoint.sh), with `spock.save_resolutions=on`,
  `spock.conflict_resolution=last_update_wins`, n1 `info={"tiebreaker":"1"}`.
  This compose is a natural starting point for an Antithesis harness.
- Required config: `wal_level=logical`, `track_commit_timestamp=on`
  (mandatory for LWW; conflict_types.md says with it off conflict resolution
  is "invisible" — remote always wins), `shared_preload_libraries=spock`,
  `output_plugin_libraries` containing `spock_output` on newer minors
  (README.md), `max_active_replication_origins` on PG18+ ≥ (nodes-1)×DBs
  (getting_started.md). Recommended `wal_sender_timeout='5min'`,
  `spock.apply_idle_timeout=300` (configuring.md).
- Optional HA: each Spock node may have a physical standby; logical slots are
  synced to it (Spock worker on PG15/16(/17), native slotsync on PG17+/18+).
  Claim: "After a failover, subscribers only need to update their `host=` ...
  replication resumes from the last synchronized LSN with no data loss"
  (configuring.md, logical_slot_failover.md §5).

### F2. Critical user path (the core promise)

1. App writes to **any** node (INSERT/UPDATE/DELETE/TRUNCATE on tables in a
   replication set — `default` for PK tables, `default_insert_only` for
   no-PK tables, `ddl_sql` for replicated DDL).
2. Commit → WAL → `spock_output` decoding → walsender → apply worker on every
   peer → conflict detection/resolution → commit with origin = source node.
3. User expectation (getting_started.md "Test Replication"): "Both messages
   should appear on both nodes". `spock.sub_show_status()` should show
   `replicating`; `spock.lag_tracker` should trend to 0.
4. Conflicts (concurrent writes to the same row on different nodes) are
   resolved by **last_update_wins** on commit timestamp, with
   `spock.node.info->>'tiebreaker'` (default = node id) for equal timestamps;
   lower tiebreaker wins (conflict_types.md). Resolvable conflicts recorded in
   `spock.resolutions` (if `spock.save_resolutions=on`); non-resolvable ones
   in `spock.exception_log`.
5. Delta-apply columns (`ALTER TABLE .. ALTER COLUMN c SET
   (log_old_value=true, delta_apply_function=spock.delta_apply)`) make
   running sums converge: `local + (new - old)` (conflicts.md). Claim: the
   bank example ends at the correct total. Requires NOT NULL column.
6. After transient failures (network partition, node restart) replication is
   expected to resume by itself: catastrophic_node_failure.md "Catastrophic
   Failure vs. Network Partition" tells users with a partition to "wait for
   connectivity to return". Release notes 5.0.8/6.0 claim apply workers exit
   on upstream connection death and "the manager respawns it from the last
   durably-committed remote LSN".

**What a user considers a bug here (properties):**
- A committed write on node X that is never applied on a live, subscribed,
  healthy peer Y after faults stop and lag drains, *with nothing in
  `spock.exception_log` explaining it* ⇒ silent data loss. Several past bugs
  were exactly this (see F7).
- A change applied twice (duplicate rows on a `default_insert_only` table, or
  a delta-apply column double-counted) ⇒ duplicate apply after
  reconnect/restart.
- Nodes ending with different row values for the same key after quiescence
  when the workload only did conflict patterns that LWW is documented to
  resolve (insert/insert, update/update) ⇒ divergence.
- Delta-apply sum not equal on all nodes / not equal to the sum of all
  committed deltas ⇒ divergence.
- Subscription stuck `down`/disabled, or apply worker in a crash loop, after
  faults stop, without a data error to explain it ⇒ liveness bug.
- PANIC / assertion failure / backend crash in apply, walsender or manager.

### F3. Conflict semantics — what is "expected" divergence (do not flag)

From docs/conflict_types.md and docs/limitations.md:

| Situation | Documented outcome |
|---|---|
| insert/insert same PK on 2 nodes | `insert_exists` → LWW; INSERT turned into UPDATE of winner. Converges (claim). |
| update/update same row | `update_origin_differs` → LWW, not logged. Converges (claim). Whole-row LWW: column-level merges are NOT done (except delta-apply columns). |
| UPDATE arrives, row not present | `update_missing` → **not resolvable**, ERROR → `spock.exception_log`. Retried `spock.read_retry_count` (default 5) times first. Then `spock.exception_behaviour` decides: `transdiscard` (default: whole remote txn discarded), `discard` (only failing statement dropped; rest committed), `sub_disable` (subscription disabled; resumes at the failing txn on enable). |
| UPDATE hits a secondary UNIQUE collision | `update_exists` → not resolvable → exception_log. |
| DELETE, row missing | `delete_missing` → skip, recorded in resolutions. |
| DELETE older than local row's ts | `delete_exists` → delete skipped, local row kept. |
| frozen local tuple | local ts treated as 0 → remote always wins, not logged. |

Consequences for property design:
- **There are no tombstones.** Concurrent DELETE on n1 (t1) and UPDATE on n2
  (t2>t1): on n2 the delete loses (`delete_exists`, row kept); on n1 the
  update finds no row (`update_missing` → exception_log, txn discarded).
  Result: n1 has no row, n2 has the row. This divergence is *by design*
  and leaves an exception_log entry. Similarly, a cross-origin causal chain
  in a 3+ node mesh (n1 INSERT; n2 receives it then UPDATEs; n3 gets n2's
  stream before n1's) can produce `update_missing` on n3 — the doc says the
  row "may never have arrived due to a replication gap". With
  `transdiscard`, n3 permanently misses n2's update.
- Therefore a plain "all nodes equal" check is only valid if the workload
  either (a) avoids cross-node UPDATE/DELETE on keys whose INSERT/last
  write came from another node and may not yet be everywhere (e.g.
  per-node key ownership for UPDATE/DELETE, or only insert/insert and
  update/update conflicts on pre-seeded rows that are known to be
  everywhere), or (b) asserts the weaker "no **unexplained** divergence":
  every differing key must be covered by a `spock.exception_log` /
  `spock.resolutions` row on the lagging node. Option (b) also catches the
  historical "silently skipped transaction" bugs.
- `spock.exception_behaviour=discard` makes remote transactions
  **non-atomic** on the subscriber by design — a workload checking
  transactional atomicity across nodes must run with `transdiscard`
  (default) or `sub_disable`.
- `spock.check_all_uc_indexes` is experimental; multiple UNIQUE indexes
  per table are a documented limitation (only one unique index used for
  conflict resolution). Workload tables should have exactly one unique
  constraint (the PK).

### F4. Admin workflows (by importance)

1. **Cluster build**: `spock.node_create(node_name, dsn, ...)` on each node;
   `spock.repset_add_all_tables('default', ARRAY['public'])` or auto-DDL with
   `spock.include_ddl_repset=on`; `spock.sub_create(name, provider_dsn)` to
   every peer; `spock.sub_wait_for_sync(name)`.
2. **Add node with zero downtime — Zodan** (`samples/Z0DAN/zodan.sql`,
   `CALL spock.add_node(src_node_name, src_dsn, new_node_name,
   new_node_dsn, verb, location, country, info)`, run on the new node, uses
   dblink). Steps (zodan_tutorial.md): create node; for each non-source peer
   take `spock.sync_event()` LSN, create slot and a **disabled** subscription
   peer→new; create slots for future new→peer subs; sync other nodes to the
   source; create enabled sub source→new with `synchronize_structure/data`;
   `sync_event` on source and `wait_for_sync_event` on new; read
   `spock.lag_tracker` commit_ts for each peer, convert with
   `spock.get_lsn_from_commit_ts()`, advance the peer slot; enable the
   disabled subs; `verify_subscription_replicating()`; create new→peer subs.
   **Claims**: existing nodes keep taking writes ("zero downtime"); "This
   ensures no data is missed or duplicated"; "guaranteeing no data loss"
   (tutorial :415). Each sync wait default 180 s (`spock.sync_timeout`
   overrides). **Preconditions users are told**: new node not accessible to
   users; disable auto_ddl on all nodes; no DDL during add; identical
   users/roles and Spock config; *all nodes available for the duration*;
   on failure, clean up with `spock.remove_node` (zodremove.sql) before
   retrying. Version rule: every node ≥5.0.9, new node same or newer
   major.minor (zodan/index.md).
   ⇒ Under Antithesis: an add_node that **fails** (timeout/exception) during
   faults is acceptable; an add_node that **succeeds** but leaves the new
   node missing/duplicating rows written on any peer during the add is a
   real bug (this exact bug class was fixed twice: 5.0.7 "Fix missing data
   when adding a new node", 6.0 "Zodan: data-loss fix when adding a node
   under write load").
3. **Remove node — Zodan** `CALL spock.remove_node(target_node_name,
   target_dsn, verbose)` run on the node being removed; drops subs (from
   `spock.subscription`), repsets, registry entry. Also manual
   `spock.sub_drop` + `spock.node_drop`.
4. **Sync events** (monitoring/spock_sync_event.md): `spock.sync_event(
   transactional bool default false) RETURNS pg_lsn` on provider;
   `CALL spock.wait_for_sync_event(NULL, origin, lsn, timeout,
   wait_if_disabled)` on subscriber. Claim: `true` ⇒ "all changes up to [LSN]
   on the provider have been received and applied". This is the natural
   barrier for a workload's final consistency check (do it for every
   ordered pair of nodes). Also `spock.wait_slot_confirm_lsn(NULL,NULL)` on
   the provider.
5. **Rolling upgrade** (upgrading_spock.md, release notes 6.0): node by node
   — disable auto-DDL, stop, install new binary, restart (manager runs
   `spock_manage_extension()` to migrate schema), verify, re-enable. Mixed
   5.0.x/6.0 clusters must work during the upgrade (protocol v4 vs v5
   negotiation). In-tree TAP tests for version switching need PG18 (memory
   note). Lower priority for a first Antithesis harness (needs two builds).
6. **Catastrophic node failure** (recovery/catastrophic_node_failure.md):
   Spock itself does **not** repair a survivor that missed some of a dead
   node's transactions (full mesh, no forwarding). The documented fix is
   external (ACE `table-diff --preserve-origin <dead> --until <ts>` +
   `table-repair --recovery-mode --source-of-truth`), after
   `sub_drop`/`node_drop` of the dead node. ⇒ **Permanently killing a node
   and comparing survivors is NOT a valid convergence property** — survivor
   divergence for rows originating on the dead node is expected product
   behaviour. Kill+restart (same data dir) is fine and must converge.
7. **Physical-standby failover of a Spock node** (logical_slot_failover.md):
   claim of no data loss after promotion; 5.0.9 fixed "silently dropped
   writes after a synchronous-standby failover". Needs a standby container;
   valuable but a second-phase topology.
8. Others: `spock.sub_disable/sub_enable`, `spock.sub_resync_table`
   (truncates then copies — table empty during sync, by design),
   `spock.sub_alter_sync`, `spock.sub_alter_skiplsn` (loses data by design),
   `spock.repair_mode(true)` (suppresses outbound replication by design),
   `spock.readonly` = `local|all` (in `all` apply workers FATAL and restart
   once cleared; must resume where they left off if slot WAL retained),
   `spock.replicate_ddl(...)`, `spock.sync_seq`.

### F5. Documented limitations ⇒ workload MUST NOT do (false-positive guard)

From docs/limitations.md unless noted:
- No UPDATE/DELETE on tables without PK / valid replica identity; no
  standalone `REPLICA IDENTITY FULL` (only with delta-apply on PK tables).
- More than one UNIQUE index/constraint on replicated tables (multi-writer).
  No deferrable unique/PK (INSERT conflicts silently undetected → duplicates
  are *documented*).
- Schema changes while writes are in flight on any node: "Users must ensure
  writes are stopped on all nodes and all slots are caught up before making
  schema changes" (multi-master). Auto-DDL `DROP TABLE` "may cause
  replication issues" in 3+ node clusters; `CREATE TABLE AS` unsafe. ⇒ a
  first workload should do no DDL during faults, or DDL only in quiesced
  phases.
- Foreign keys are not enforced by apply; `TRUNCATE ... CASCADE` only
  cascades on the origin. ⇒ no FK-based invariants.
- Legacy sequences replicate periodically, not in real time; concurrent
  `serial` inserts on several nodes collide (insert_exists → LWW overwrite =
  user-visible "lost" row, but documented). ⇒ use snowflake, per-node key
  ranges, or UUIDs; never rely on `serial` across nodes.
- `TRUNCATE ... RESTART IDENTITY` may cause sequence divergence.
- UNLOGGED/TEMP tables not replicated; large objects not replicated (LOLOR).
- Volatile functions in row filters; filtered columns; partitions added
  after sync need `repset_add_partition` — avoid filters/partitions in v1.
- Do not mix Spock with native logical replication on the same DB.
- Do not modify the `spock` schema directly.
- `spock.sub_alter_skiplsn` and `spock.repair_mode` intentionally drop
  changes — don't use them in a workload that checks convergence (or
  account for them).
- Encoding must match; cross-major-version replication is "not a design
  target".
- `spock.exception_behaviour=discard` ⇒ partial remote transactions by
  design.
- Delta-apply columns must be NOT NULL.
- `spock.readonly=all` for longer than slot WAL retention requires resync.
- Zodan preconditions listed in F4.2 (no DDL, auto_ddl off, all nodes
  available, new node not serving users).

### F6. Monitoring surfaces a workload/oracle can read

- `spock.sub_show_status()` (status: `replicating`/`initializing`/`down`/
  `disabled`), `spock.subscription` (`sub_enabled`), `spock.node`.
- `spock.lag_tracker` (origin_name, receiver_name, commit_timestamp,
  commit_lsn, remote_insert_lsn, received_lsn, replication_lag_bytes,
  replication_lag) — used by Zodan to advance slots, so wrong values here
  directly cause add_node data loss.
- `spock.progress` (6.0: a view over `spock.apply_group_progress()`, backed by
  shared memory + WAL, release notes 6.0).
- `spock.resolutions` (needs `spock.save_resolutions=on`, postmaster-only),
  `spock.exception_log` (`spock.exception_logging=all` default).
- `pg_replication_slots`, `pg_stat_replication`,
  `spock.xact_commit_timestamp_origin(xid)` to read row origin/ts.
- `spock.apply_change_logging=key_only|verbose` emits per-change JSON (good
  for post-hoc oracle / triage).

### F7. Past user-visible failures (leads; cite release notes / commits)

All in docs/spock_release_notes.md; these show where users actually got hurt:
- Silent advance of replication origin past an in-flight remote txn after
  upstream connection loss → txn skipped on reconnect (5.0.8; carried to
  6.0). Mechanism: stale libpq fd / `epoll_ctl(EINVAL)` cascade; fix =
  `PG_RE_THROW` and respawn from last durable remote LSN. **Prime target for
  network-fault testing.**
- Transient provider connection loss misclassified as apply failure under
  `sub_disable` → subscription wrongly disabled (5.0.11-ish). And commit
  8dcfbcd5 "Fix spurious apply-idle-timeout misclassification as data
  exception" (HEAD~4) — same family; check with partitions/pauses.
- Zodan add_node data loss under write load (5.0.7 progress past COPY
  boundary; 6.0 resume LSN before COPY boundary — apply workers now paused
  during slot creation via flag+CV in `SpockContext`). Also Phase 9
  handshake deadlock.
- Silently dropped writes after synchronous-standby failover (wrong
  position reported to publisher) (5.0.9).
- `remote_insert_lsn` lost after crash recovery (a43f4b82); WAL recovery
  crash after apply worker failure (c4368188).
- Skip-LSN mismatch (BEGIN vs clear point); `resync_table` data loss when
  subscriber read-only (SPOC-440); re-sync truncate with WAL sending on.
- Failover-slot worker PANIC/crash loop after promotion on PG15/16; slot
  loss on promotion.
- Manager respawn loop when DBs are dropped concurrently.

### F8. Clock / timestamp product facts relevant to fault injection

- LWW uses commit timestamps, so a node with a fast clock wins conflicts.
  This is *expected* (users accept wall-clock LWW); clock skew should not be
  treated as a bug by itself. A bug would be: non-convergence (different
  winners on different nodes) under skew.
- Core patch `pgNN-025-logical_commit_clock.diff` adds a Lamport-style hook
  (`remoteTransactionStopTimestamp`, `EnsureMonotonicTransactionStopTimestamp`
  run under the WAL insert lock) to keep local commit ts monotonic and ahead
  of remote commit ts the node has applied. Clock steps backward/forward are
  therefore a direct exercise of this patch.
- Commit f21e71bc rejects peer timestamps lacking an explicit UTC offset
  (timestamps exchanged as text via `spock.progress`).
- FAQ: around a time change "spock replication needs some time (~5 minutes)
  to recover" — vague claim; a liveness property under clock jumps should
  allow a recovery window.
- **Lead (not verified):** `conflict_resolve_by_timestamp()` in
  src/spock_conflict.c:99-200, on equal timestamps, compares the tiebreaker
  of the *applying* node vs the *remote sender*, not the origin of the
  existing local tuple (comment explains this was deliberate, commit
  64ea462d). In a 3+ node mesh with two concurrent updates from n1 and n2
  carrying identical commit timestamps, the winner on n3 appears to depend on
  arrival order (n3-vs-sender comparison), while n1 and n2 compare with each
  other — which looks like it could diverge. Equal µs timestamps are rare in
  practice but plausible under Antithesis clock control or Lamport bumps.
  Worth a targeted check by the conflict-resolution agent.

---

## Areas examined

README.md; docs/index.md (titles), getting_started.md, two_node_cluster.md
(grep), configuring.md, conflicts.md, conflict_types.md, limitations.md,
FAQ.md, troubleshooting.md, recovery/catastrophic_node_failure.md (full),
modify/index.md, modify/zodan/{index,zodan_readme,zodan_tutorial}.md,
modify/add_node_pgbackrest.md (grep), monitoring/spock_sync_event.md,
monitoring/lag_tracking.md, managing/{spock_autoddl,read_only,snowflake}.md,
spock_functions/{index,sub_mgmt,node_mgmt}.md, functions/spock_sub_create.md,
functions/spock_sub_alter_skiplsn.md, upgrading_spock.md,
logical_slot_failover.md (partial), spock_release_notes.md (bug-fix
sections), samples/README.md, samples/Z0DAN listing, tests/docker
(docker-compose.yml, entrypoint.sh, run-tests.sh head, check-outputs.sh),
.github/workflows/spockbench.yml, patches/18 (025 header),
src/spock_conflict.c:95-200, git log greps.

## Assumptions

- Target topology for Antithesis v1: 3-node full mesh (like tests/docker),
  one DB, default `forward_origins='{}'`, `exception_behaviour=transdiscard`,
  `save_resolutions=on`, `track_commit_timestamp=on`, auto-DDL off during
  fault phases.
- "Network partition" and "kill + restart with same data dir" are faults
  users expect Spock to survive with automatic convergence; "permanent node
  loss" is not (needs ACE).
- Samples are "unmaintained/illustrative" per samples/README.md, yet Zodan is
  the documented node-add path and is used by CI; treat Zodan correctness as
  user-visible.

## Open Questions

1. Does the team consider DELETE-vs-UPDATE divergence (no tombstones) and
   cross-origin `update_missing` in a 3+ node mesh acceptable, or a bug?
   This decides whether the convergence property is strict or "explained by
   exception_log".
2. Is the equal-timestamp tiebreak behaviour (F8 lead) intended to converge in
   3+ node meshes?
3. Should add_node under faults be tested for "fails cleanly or succeeds
   correctly", and does `spock.remove_node` reliably clean up partial adds so
   a retry is valid?
4. What recovery window is acceptable after clock jumps (FAQ "~5 minutes")?
5. Is physical-standby failover (logical slot sync) in scope for the first
   Antithesis topology, or a later phase?
6. Rolling upgrade 5.0.x→6.0 mixed cluster: in scope (requires two builds)?
