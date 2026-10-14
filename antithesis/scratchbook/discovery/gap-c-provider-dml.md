# Gap (c): provider-side and less common DML paths, plus config angles

Surfaced by: evaluation gap (c) (coverage-balance F6, F11; wildcard W1, W8,
W9, W10, W11). Code checked at 69d9228f and the patched PG18 tree
(`~/dev/pgedge/postgresql`, REL_18_STABLE plus pgEdge patches). Nothing was
built or run.

Six new properties. Two gap items (2 and 4) are judged already covered or
not Antithesis risks; item 3 becomes an extension of an existing property.
Two deterministic findings are listed for TAP follow-up at the end.

## New properties

### prepared-commit-ts-matches-sent-ts — A prepared transaction's commit timestamp is the same on its origin and its peers

| | |
|---|---|
| **Type** | Safety |
| **Property** | For a transaction committed with `PREPARE TRANSACTION` / `COMMIT PREPARED`, the commit timestamp the origin stores in `pg_commit_ts` equals the commit timestamp its peers receive and store for the applied copy. |
| **Invariant** | Workload `Always("prepared transaction's commit ts on its origin equals the commit ts its peers applied")`: after a barrier, origin `pg_xact_commit_timestamp(xid)` equals each peer's `pg_xact_commit_timestamp(xmin)` of the transaction's marker row; pairs where the origin restarted in between (redo rewrites the value) or the row was overwritten are skipped. Companion `Sometimes("prepared transaction committed while the logical clock was ahead of its commit time")` (peer value greater than origin value). `Always` because any mismatch lets LUW pick different winners on different nodes. |
| **Antithesis Angle** | Patch 025's hook bumps the WAL commit time when the shared logical clock is already at or past it; `RecordTransactionCommitPrepared` (patched `twophase.c:2310-2358`) keeps its own unbumped `committs` for `pg_commit_ts`. Plain concurrent commits make microsecond bumps (so the check fires without faults); a global backward clock jump makes the bump, and so the divergence window for contested rows, as large as the jump. Thread pausing between PREPARE and COMMIT PREPARED widens it. |
| **Why It Matters** | Confirmed by code reading: the origin judges later conflicts on that row with a smaller timestamp than every peer, so nodes can keep different versions with no exception row. Application servers using XA use two-phase commit; Spock's docs say nothing about it. The catalog's LUW oracles read the origin's commit ts and would use the wrong value for these transactions. |

**Open Questions:**

- Is two-phase commit a supported client feature on Spock clusters (doc finding vs patch-025 bug)? `(needs human input)`
- Does patch 025 for PG15-17 and PG19 have the same gap? Only PG18 was read.

Priority: P1 — mechanism confirmed in the patched core, silent divergence, cheap direct check that fires without faults.
Topology: v1 + workload option (`max_prepared_transactions > 0`, some writers use 2PC)
Key faults: none for the direct check; global backward clock jump and thread pause for the contested-row divergence
Confidence: high for the mismatch (code-checked in patched PG18); medium for divergence frequency
Surfaced by: Evaluation gap c
Evidence file: properties/prepared-commit-ts-matches-sent-ts.md

### sync-standby-hold-freezes-provider-confirmed-flush — A subscriber's sync-standby hold keeps the provider slot behind unconfirmed transactions

| | |
|---|---|
| **Type** | Safety |
| **Property** | While a subscriber's synchronous standby has not flushed a transaction's local commit, the provider's `confirmed_flush_lsn` for that subscription does not pass that transaction. |
| **Invariant** | Config variant with `synchronous_standby_names = 'phantom'` (no standby ever connects) on one subscriber S. Workload records S's origin `remote_lsn` at the switch (`R0`) and `E`, the first observed value above `R0`; then `Always("provider slot of a subscriber with an unconfirmed sync standby stays below its first held transaction")`: provider `confirmed_flush_lsn < E` on every poll. Companions `Sometimes("subscriber with phantom sync standby applied a provider transaction")` and `Sometimes("apply worker of the held subscription reconnected")`. |
| **Antithesis Angle** | Two code-confirmed ways to break it: `send_feedback()` sets `flushpos = recvpos` once `lsn_mapping` drains, ignoring the hold list (L9, `src/spock_apply.c:3253-3266`, deterministic); and every apply worker start sends `request_initial_status_update(origin_startpos)` (`:4778`) with no standby check, and the in-memory hold list is gone. Partitions, idle-timeout reconnects, walsender kills and node restarts reach the second path, which a fix to the first leaves open. |
| **Why It Matters** | Claimed guarantee in the code (`:3120-3125`) and S9. A provider that confirmed past what the standby has frees that WAL, and failover of the subscriber then loses those transactions silently. Needs no sixth container. |

**Open Questions:**

- Should a restarted apply worker hold feedback until the sync standby passes the origin's `local_lsn`, i.e. is the restart path in scope? `(needs human input)`
- Can confirming filtered-out WAL ahead of a held transaction happen in correct code? `(partial: by stream order a keepalive's sentPtr is past every earlier sent transaction, so that is mechanism 1, not a false positive)`

Priority: P1 — code-confirmed loss mechanism behind a written claim; one cheap config variant; the restart path needs faults.
Topology: v2/phantom-sync-standby (v1 containers, one subscriber with a phantom `synchronous_standby_names` and `synchronous_commit = local`)
Key faults: none for L9; partitions, worker / walsender kills, node restarts for the restart path
Confidence: high (both paths code-checked; L9 deterministic, reproduce in TAP first)
Surfaced by: Evaluation gap c
Evidence file: properties/sync-standby-hold-freezes-provider-confirmed-flush.md

### promoted-subscriber-standby-has-every-confirmed-txn — Failing a subscriber over to its sync standby loses no replicated transaction

| | |
|---|---|
| **Type** | Safety |
| **Property** | After a subscriber is killed and its synchronous physical standby is promoted, every provider transaction the provider's slot had confirmed for that subscriber is present on the promoted node once it resumes replication; rows the old subscriber originated and peers received are also present. |
| **Invariant** | Workload `Always("promoted subscriber standby has every provider transaction its provider had confirmed")` after promotion and barriers from every provider to the promoted node (equivalently, `committed-ledger-row-reaches-every-node` evaluated with the promoted node). `Always("rows the failed subscriber originated and peers received exist on the promoted standby")` for its `synchronous_commit=on` client rows. `Sometimes("subscriber standby promoted while its provider slot was ahead of the standby's replay position")`. |
| **Antithesis Angle** | Pause the standby so it lags, keep providers writing, kill the subscriber primary, promote. L9 and the restart path let the provider confirm past what the standby has; a logical slot never streams from before `confirmed_flush` (`logical.c:558-577`), so those transactions are skipped for good. |
| **Why It Matters** | S9 is one of Spock's strongest written claims ("resumes ... with no data loss") and the evaluation found no standalone `v2/standby` property. This is the end-to-end user outcome behind the phantom check. |

**Open Questions:**

- Is subscriber failover a supported scenario, and how are other nodes pointed at the promoted node (`sub_alter_interface`, DNS alias)? `(needs human input)`
- Does a promoted standby start Spock workers cleanly with the same node id (shared memory, `resource.dat`, progress)?

Priority: P2 — needs a sixth container and a failover action; the phantom variant finds the same cause first.
Topology: v2/standby (n1-n3 mesh plus a sync physical standby of n2 with `sync_replication_slots = on`)
Key faults: process pause of the standby, node kill of the subscriber primary, latency between primary and standby
Confidence: medium (loss path code-checked; failover runbook unknown)
Surfaced by: Evaluation gap c
Evidence file: properties/promoted-subscriber-standby-has-every-confirmed-txn.md

### quiet-link-never-hits-idle-timeout — Links with no fault never take the idle-timeout reconnect

| | |
|---|---|
| **Type** | Safety |
| **Property** | On a link whose two nodes and network had no fault, and with no wall-clock jump, the apply worker never raises the `spock.apply_idle_timeout` "no data received" error. |
| **Invariant** | Workload `Unreachable("apply worker hit the idle timeout on a link with no fault and no clock jump")`, from a log scan (or apply-worker restart count) over windows that start `apply_idle_timeout` seconds into each quiet period and drop any window with a detected clock jump. Companion `Sometimes("transaction of at least N changes applied on every peer")` so long replays run. |
| **Antithesis Angle** | Faults before the quiet period leave reconnect states that must recover; the window checks that steady state is reached and stays quiet. The provider only pings every `wal_sender_timeout / 2` on an idle link (`walsender.c:4117-4146`), and long decodes keep that cadence via `update_progress_txn` (`reorderbuffer.c:2598-2602`), so any config with `apply_idle_timeout` at or below that churns forever, and long replays can be cut off and restarted. |
| **Why It Matters** | Reconnect churn re-decodes from `restart_lsn` and inflates every liveness bound. The current harness plan (`apply_idle_timeout` 30 s, `wal_sender_timeout` 60 s) puts the gap equal to the timeout, so this fires in every quiet period until the harness is fixed (raise the idle timeout to 90 s or more). Spock does not warn about the bad combination. |

**Open Questions:**

- Should Spock reject or warn when `apply_idle_timeout <= wal_sender_timeout / 2`, or send its own periodic status message? `(needs human input)`
- Can a subscriber slow to drain buffered data reply to a keepalive later than `wal_sender_timeout`, so the walsender cuts a large transaction off every time under CPU throttling? Not traced.

Priority: P2 — mainly a config and harness guard; no data loss, but it decides whether liveness bounds mean anything.
Topology: v1 (harness `apply_idle_timeout` >= `wal_sender_timeout / 2` + 30 s); second variant with the documented 5 min / 300 s
Key faults: faults off in the checked windows; clock jumps detected and excluded
Confidence: high for the cadence (stock walsender code read); medium that nothing else stalls messages
Surfaced by: Evaluation gap c
Evidence file: properties/quiet-link-never-hits-idle-timeout.md

### walsender-never-joins-slot-group — No walsender joins a slot group outside the slot-group config

| | |
|---|---|
| **Type** | Safety |
| **Property** | In every run except a deliberate slot-group variant, no Spock walsender joins a slot group. |
| **Invariant** | SUT-side `Unreachable("walsender joined a slot group")` in `spock_output_join_slot_group` right after the name test succeeds (`src/spock_output_plugin.c:1300-1313`); plus a setup check that no `spock_output` slot name matches `_[0-9]$`. `Unreachable` because joining splits one provider stream across subscribers with no error (L10). |
| **Antithesis Angle** | None from faults. Guards the harness: any subscriber node named like `node-1`, `db_east_1` or `N1` gives a slot name ending `_<digit>` through `gen_slot_name` (`src/spock_functions.c:3666-3687`) and ZODAN's `sub_<provider>_<subscriber>` names, which would turn every ledger check into a slot-group finding. |
| **Why It Matters** | Users pick such names without knowing; the reject fix (f6887c7a) is not on main. Zero-cost guard in every run. |

**Open Questions:**

- Will f6887c7a (reject grouped slot names) merge to main? `(needs human input)`

Priority: P3 — configuration-triggered and deterministic; a harness guard.
Topology: v1 (disabled in a deliberate v2/slot-groups variant)
Key faults: none
Confidence: high (name mapping code-checked)
Surfaced by: Evaluation gap c
Evidence file: properties/walsender-never-joins-slot-group.md

### truncate-ordered-with-same-origin-dml — TRUNCATE and nearby inserts from one origin reach every peer in order

| | |
|---|---|
| **Type** | Safety |
| **Property** | On a table written only by its owner node, after a barrier every peer's copy equals the owner's: TRUNCATE and the inserts before and after it are applied in commit order, none dropped, none applied twice in a way that changes the result. |
| **Invariant** | Workload `Always("single-owner table after TRUNCATE has the same rows on every peer as on its owner")`, comparing `(epoch, seq)` sets after the owner-to-peer barrier. Companions `Sometimes("TRUNCATE applied on a peer within a transaction that also inserted")` and `Sometimes("TRUNCATE-bearing transaction passed through exception replay")`. |
| **Antithesis Angle** | Worker exits and walsender kills during TRUNCATE-bearing transactions push them through the exception and replay paths in `handle_truncate` (`src/spock_apply.c:2135-2210`), each of which has a recent fix (940e500d, 162dc562); subscriber kills between checkpoints redeliver them (L1); reader locks make apply wait on AccessExclusiveLock; a resync of the table during faults makes apply skip the TRUNCATE and rely on the sync. |
| **Why It Matters** | TRUNCATE is banned from the workload today and no property covers the 'T' message or `pg_decode_truncate`. A single-owner table avoids the documented cross-origin ordering problem, so TRUNCATE can run under faults. A dropped TRUNCATE leaves stale rows on one node with nothing to repair them. |

**Open Questions:**

- Is a TRUNCATE-only redelivery (TRUNCATE replayed without the inserts committed after it) possible? `(partial: none found; all are in one transaction and the origin advances at commit)`

Priority: P2 — low-frequency DML kind with a recent bug history in its exception paths; no known open lead.
Topology: v1 (one `trunc_<node>` table per node, written only by that node)
Key faults: worker exit, walsender kill, node kill between checkpoints, reader lock contention
Confidence: medium (paths code-checked; no open lead)
Surfaced by: Evaluation gap c
Evidence file: properties/truncate-ordered-with-same-origin-dml.md

## Gap items judged covered or not Antithesis risks

- **Item 2, replication set changes under load.** The add/remove boundary
  is set by the decoding snapshot at the repset change's commit LSN
  (`spock.replication_set_table` is a `user_catalog_table`; changes invalidate
  `RepSetTableHash` through relcache invalidations decoded in order), so it
  does not depend on timing. `repset_add_table(..., synchronize_data)`
  queues a TABLESYNC ('A') message in the same transaction; the subscriber
  creates an INIT sync row in the same apply transaction
  (`handle_table_sync`, `src/spock_apply.c:2546-2584`) and apply skips the
  table until the sync is done (`should_apply_changes_for_rel`, `:464-481`).
  The timing-dependent part is the sync worker under faults, already owned
  by the G1 candidate `table-resync-under-faults-ends-ready` and by
  `initial-sync-ends-ready-or-visibly-disabled`. Suggest the G1 candidate
  also covers the `repset_add_table(synchronize_data := true)` entry path on
  a new single-writer table. Two deterministic findings below.
- **Item 3, DDL-then-DML ordering.** Same-origin order is guaranteed by
  queuing DDL in the same transaction; lock-timeout and deadlock errors on
  queued DDL are retried (`src/spock_apply.c:3966-3972`); the ways a DDL is
  lost (misclassified error, readonly=local, redelivery) are owned by
  existing properties. No new property. Extension below.
- **Item 4, partition-key UPDATE moves.** Decoded as DELETE on the old leaf
  plus INSERT on the new leaf (output plugin replicates leaves). A
  concurrent UPDATE of the same row elsewhere becomes `update_missing`,
  which raises an ERROR and is logged to `exception_log`
  (`src/spock_apply_heap.c:1017-1040`; `docs/conflict_types.md`
  "update_missing ... not resolvable"). That is the documented
  `update_missing` class, already scored by gap (a)'s
  `every-divergence-explained-by-spock-records` (its optional partitioned
  variant). The `src/spock.c:1085` / `src/spock_common.c:464` code only
  lowers a log level and retries the lookup, same as stock PG.

## Extensions to existing properties

- `redelivered-ddl-not-turned-into-exception`: in each DDL phase add
  same-origin pairs "ADD COLUMN, then DML that writes the new column" on a
  ledger-checked table, so a lost or doubly applied DDL shows up as missing
  DML rows on the peer, not only as a 42-class exception row.
- `feedback-never-confirms-undurable-apply`: its L9 note should name the
  second path (restart sends `origin_startpos` as flushed with no
  sync-standby check, `src/spock_apply.c:4778`); its SUT-side held-entry
  check cannot see that path because holds are lost on restart. Point to
  `sync-standby-hold-freezes-provider-confirmed-flush`.
- `luw-final-version-has-max-commit-ts` and `local-overwrite-gets-later-commit-ts`:
  if the workload uses two-phase writers, take the commit ts from a peer
  (or from the origin after a restart), not from the origin's live
  `pg_xact_commit_timestamp`, which is the unbumped value for prepared
  transactions.
- Deployment topology / catalog Assumption 4: raise `apply_idle_timeout` to
  at least `wal_sender_timeout / 2 + 30 s` (90 s with 60 s), and widen the
  liveness bounds that include it.
- Workload boundaries (§12): any two-phase writer must always finish what
  it prepares (COMMIT or ROLLBACK PREPARED, retried after restarts); an
  orphaned prepared transaction holds row locks and blocks apply on those
  rows indefinitely (stock PG behaviour).

## Deterministic findings for TAP (not Antithesis properties)

- **TRUNCATE ignores the subscription's replication sets.**
  `pg_decode_truncate` (`src/spock_output_plugin.c:1147-1196`) checks
  `get_table_replication_sets(data->local_node_id, relid)` (every set on
  the node) instead of the subscription's `data->replication_sets`, which
  inserts, updates and deletes use (`get_table_replication_info(...,
  data->replication_sets)`, `:942-943, 1054-1055`). Present since the
  truncate callback was added (e2f4405a). Effect: a subscriber receives
  TRUNCATE for a table it does not subscribe to; it truncates its own copy,
  or, if the table does not exist there, raises "Spock can't find relation"
  and under TRANSDISCARD drops the whole transaction including subscribed
  changes. Not reachable in v1 (all subscriptions use the same default
  sets).
- **Re-adding a table to a replication set with synchronize_data is
  skipped if the subscriber still has a sync status row.**
  `handle_table_sync` skips when any `local_sync_status` row exists for the
  table ("already being synchronized, skipping",
  `src/spock_apply.c:2555-2566`), including the READY row the initial sync
  writes for every table (`src/spock_sync.c:1738-1766`). Nothing removes
  that row when a table leaves a replication set (only `sub_alter_sync` and
  table drop do). Rows written while the table was out of the set are never
  copied. Same logic as pglogical; may be known.
