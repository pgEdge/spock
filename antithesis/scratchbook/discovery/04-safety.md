# 04 — Safety Guarantees (claimed invariants) — Spock @ 69d9228f

Focus: statements in docs, code comments and commit messages that promise
something "never" happens or "always" holds. Every item below is a **claim**,
quoted with its location, followed by the code mechanism behind it, the known
caveats or counter-evidence, and a testable property for Antithesis. None of
these has been verified to hold.

A key framing point first: **Spock's documentation does not claim that nodes
always converge.** Cluster-wide consistency is handed to an external tool
(ACE): `docs/recovery/catastrophic_node_failure.md:19-23` ("use the Active
Consistency Engine (ACE) ... your cluster remains consistent and
conflict-free"), `docs/troubleshooting.md:302`, `docs/FAQ.md:73`. Docs also
name several conflict types that cannot be resolved and end up as
`spock.exception_log` rows instead of being fixed (`docs/conflict_types.md:29-32`).
So a convergence property has to be **scoped** (see S1) or framed as
"no *silent* divergence" (see S2).

---

## Findings

### S1. Last-update-wins (LUW) conflict resolution gives one deterministic winner

**Claims**
- `docs/conflicts.md:60-64`: "`spock.conflict_resolution = last_update_wins` ... the version of data with newest commit timestamp is kept; note that the `track_commit_timestamp` PostgreSQL setting must also be `enabled`."
- `docs/conflict_types.md:173-176`: "**Tiebreaker:** When two rows have identical commit timestamps, Spock uses the `tiebreaker` value from the `spock.node` configuration to determine a winner. The node with the lower tiebreaker value wins. By default the tiebreaker is set to the node's unique ID."
- `docs/conflict_types.md:46-49` (insert_exists): "compares the commit timestamps of the local and remote rows. The winner's values are applied as an UPDATE to the existing row."
- `docs/conflict_types.md:150-156` (delete_exists): "one node deletes a row while another node updates it with a later timestamp ... The delete is skipped and the local (newer) row is kept."

**Mechanism**
- `src/spock_conflict.c:98-202` `conflict_resolve_by_timestamp()`: compares `replorigin_session_origin_timestamp` (the remote commit ts, set in `handle_begin`, `src/spock_apply.c:685`) with the local tuple's commit ts from `get_tuple_origin()` (`src/spock_conflict.c:217-273`, via `TransactionIdGetCommitTsData`).
- Equal timestamps: a same-origin shortcut applies remote (`:158-163`). Otherwise `loc_node = get_local_node()` and `rmt_node = get_node(remote_origin_id)`. Lower tiebreaker wins (`:187-200`).
- **Equal tiebreakers → both sides apply remote** (`:165-185`, WARNING only). That is a guaranteed divergence: each node takes the other's row. The comment says "Node creation prevents this for new nodes", but the only check at creation is on node_id (`src/spock_node.c:374-383`). A tiebreaker set by hand in `spock.node.info` (`src/spock_node.c:499-532`) is never checked for uniqueness. `spock.node` rows are also per-node local catalog rows, so if different nodes hold different `info.tiebreaker` values for the same node, tie-breaking stops being symmetric.
- `replorigin_session_origin` is overwritten per transaction with the *originating Spock node id* from the ORIGIN message (`src/spock_apply.c:1323-1334`), not the local RepOriginId. That is why `get_node(remote_origin_id)` works.
- History: the tiebreaker used to compare against the *tuple's* origin; fixed in `64ea462d` (`spock_conflict: fix spurious tiebreaker-equal WARNING in single-writer topology`).
- The GUC check hook `spock_conflict_resolver_check_hook` (`src/spock_conflict.c:801-815`) refuses LUW unless `track_commit_timestamp=on`. The `track_commit_timestamp = off` behaviour described in `docs/conflict_types.md:193-199` therefore cannot be reached with the only documented resolver (a docs/code mismatch, low impact).
- Frozen local tuples: local ts treated as 0, so remote always wins (`src/spock_conflict.c:237-250`; `docs/conflict_types.md:184-191`). Rows copied in by the initial sync are written with origin timestamp `'epoch'` (`src/spock_sync.c:944-947`, `pg_replication_origin_xact_setup('0/0','epoch')`), so they lose every LUW comparison.

**Scope limits that break convergence by design (documented)**
- `update_missing` raises ERROR (`src/spock_apply_heap.c:1018-1049`) and goes to the exception path. Under the default `transdiscard` (`src/spock_exception_handler.c:78`) the **whole remote transaction** is dropped on that node. `docs/conflict_types.md:94-96` admits the row "may never have arrived due to a replication gap". Example: n3 inserts row r, and n2 updates r after receiving it. If n1 gets n2's update before n3's insert (independent apply workers, one per provider, with no cross-origin ordering), n1 discards n2's whole transaction, then applies n3's insert. Result: lasting divergence. Under Antithesis this is easy to trigger with a partition between n1 and n3 only.
- Update vs delete races: `delete_exists` keeps the row on one node while the other node has deleted it (no tombstones). `delete_missing` followed by a late insert brings the row back.
- Deferrable unique constraints are skipped, giving possible duplicate rows (`docs/limitations.md:57-63`).
- `spock.check_all_uc_indexes` resolves only the first conflict (`docs/conflicts.md:97-104`, "experimental").

**Testable properties**
- *P1.1 (Always, scoped convergence):* workload = inserts with globally unique keys (e.g. node-prefixed), plus UPDATEs (no DELETE) of rows that already existed on every node before the run. After a quiescence barrier (`spock.sync_event()` on every node + `spock.wait_for_sync_event()` on every peer), every node has identical table contents. Faults: partitions, kill -9 of postmaster, apply-worker kill, clock skew.
- *P1.2 (Always):* for each row, the surviving version is the one whose commit (ts, tiebreaker) is largest. Check by stamping each write with `(node_name, local_seq)` in a payload column and comparing against `pg_xact_commit_timestamp_origin(xmin)` on every node.
- *P1.3 (Sometimes):* the equal-timestamp tiebreaker path is reached (`"wins over %d by tiebreaker"` LOG). It is probably hard to hit without controlling clocks.
- *P1.4 (Always):* no WARNING `"have equal tiebreaker value"` in a cluster where tiebreakers were never edited by hand.

### S2. No silent data loss / divergence: every dropped change is recorded

**Claims**
- `docs/conflict_types.md:12-15`: "Resolvable conflicts are recorded in the `spock.resolutions` table (when `spock.save_resolutions` is enabled); non-resolvable conflicts are recorded in `spock.exception_log`."
- `docs/configuring.md:191-195` (`exception_logging=all`): "record all transactions that contain one or more failed operations in the `spock.exception_log` table".
- `docs/limitations.md:309-315`: `sub_alter_skiplsn` "does not replay or repair skipped data ... permanently ignored" (an admitted loss, which is operator-driven).

**Mechanism**
- TRANSDISCARD/SUB_DISABLE replay runs the transaction read-only (`src/spock_apply.c:620-631`). The rows that would have been applied are written to `spock.exception_log` and committed in the *same* transaction that advances the origin (`src/spock_apply.c:997-1059`). So "discarded" and "logged" should be all-or-nothing.
- DISCARD commits the part of the transaction that succeeded (`docs/configuring.md:168-171`). **Remote transaction atomicity is intentionally not kept under `discard`.**

**Testable properties**
- *P2.1 (Always):* after quiescence, every row-level difference between two nodes can be traced to an `exception_log` row or a `resolutions` row (run with `spock.save_resolutions=on`). A difference with no such record is a silent-loss bug.
- *P2.2 (Always, TRANSDISCARD):* a remote transaction is either fully applied on a node or fully absent with exception_log rows for it, never partly applied. Workload: multi-row transactions with a transaction-id column; check per-xid all-or-nothing on each node.

### S3. Transient errors never discard data (connection loss, deadlock, lock timeout, resource shortage)

**Claims**
- `src/spock_apply.c:3870-3884`: "Connection-class errors must NOT enter the apply-side replay path ... With spock.exception_behaviour = transdiscard the replay path eventually logs the in-flight remote transaction's rows to spock.exception_log as if they had failed apply ... producing a 'missing row'".
- `src/spock_apply.c:3886-3897`: "The manager respawns the worker, which resumes from the last durably-committed origin LSN and re-streams the aborted txn."
- `src/spock_apply.c:3933-3949`: "Retryable local aborts must not enter the replay path either. A deadlock victim or a lock_timeout abort ... every spock.exception_behaviour loses data the provider would resend ... Retry is INDEFINITE".
- `src/spock_apply.c:3962-3976`: class 53 (disk full, OOM, too many connections) is retried "instead of discarding: human intervention, but a restarting worker rather than data loss."
- **Admitted gap** `src/spock_apply.c:3951-3957`: "Serialization errors are absent ... a cluster-wide default_transaction_isolation can still produce 40001, which then takes the exception path." So with a cluster-wide REPEATABLE READ/SERIALIZABLE setting, a serialization failure **discards** data.

**Mechanism**
- The PG_CATCH discriminator at `src/spock_apply.c:3867-3980`. It checks sqlerrcode in {08006, 08000, 08003, 57P01, 57P02, 57P03} or `PQstatus==CONNECTION_BAD`, then 40P01/55P03, then class 53.
- `clear_transient_exception_state()` (`:425-442`) removes the shared-memory `commit_lsn` marker, so the resent transaction is not mistaken for an earlier failure.
- The shared-memory exception marker is set on **every BEGIN** (`src/spock_apply.c:868-869`). Any error that is not classified as transient and happens mid-transaction is treated as a data fault.

**Bug history in exactly this area (strong lead for Antithesis):**
- `d286f3df` — origin advanced past an aborted in-flight transaction on connection loss ("Either path can silently advance origin past an aborted remote transaction so it gets skipped on reconnect").
- `f3d4935e` — deadlock/lock-timeout/57P02/57P03 used to go down the discard path.
- `ed0a9945` — a SIGTERM mid-transaction left `commit_lsn` behind, giving a spurious SUB_DISABLE on the resent transaction.
- `8dcfbcd5` — `spock.apply_idle_timeout` error was untagged (XX000), so a stalled provider "spuriously disabl[ed] the subscription (or silently discard[ed] a good transaction)". This is the latest commit before HEAD.
- `162dc562` — TRUNCATE on a missing relation caused a crash loop.
- The pattern: **any error code the discriminator does not list turns into data loss.** Candidates to probe: errors from libpq paths not tagged ERRCODE_CONNECTION_FAILURE, `statement_timeout`/`idle_in_transaction_session_timeout` (57014 / 25P03) if set cluster-wide, 40001 (admitted), out-of-shmem errors from `spock_exception_handler`, errors inside `wait_for_previous_transaction`, and the `spock.readonly=all` FATAL mid-transaction (`src/spock_apply.c:2981-2983`).

**Testable properties**
- *P3.1 (Always):* with faults limited to network partitions, process kill/pause, provider restart and local lock contention (no schema mismatch or constraint faults), `spock.exception_log` stays **empty** and no subscription is ever disabled (`spock.subscription.sub_enabled` stays true). Any exception_log row under pure infrastructure faults is a misclassification bug.
- *P3.2 (Always):* no committed provider transaction is missing on a subscriber after quiescence, under the same fault set (an exactly-once audit: per-node monotone sequence table, check no gaps and no duplicates on every peer).
- *P3.3 (Sometimes):* the log lines `"connection error during apply, exiting via rethrow"` and `"transient error (deadlock/lock timeout)"` are each reached. These are coverage signals that the risky paths actually ran.

### S4. No transaction applied twice / none lost across apply-worker crash (exactly-once on a direct subscription)

**Claims**
- `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:26`: "the apply worker already uses Postgres's native replication origins (`replorigin_session_get_progress`) to determine the resume LSN on reconnect. The correctness-critical 'where do I resume from' question is handled entirely by stock logical-replication protocol."
- `src/spock_apply.c:978-997`: "Advance the replication origin LSN to end_lsn. This LSN marks the position from which streaming will resume in case of a crash. Only update the origin LSN if there was no exception, or if the exception behavior is DISCARD or TRANSDISCARD."
- `src/spock_apply.c:1110-1126`: empty transactions advance the origin explicitly.

**Mechanism**
- The origin is advanced inside `RecordTransactionCommit` (PG core) in the same WAL commit record. That makes direct-subscription apply exactly-once *if* `replorigin_session_origin_lsn` always holds the right value. Ways it could hold the wrong value: the shmem-exit cleanup at `src/spock_apply.c:2319-2324`, the BEGIN value `commit_lsn` (`:686`) being used when an abort or SUB_DISABLE commit advances the origin (it re-sends, by design), and `src/spock_apply.c:1008`.
- Feedback to the provider (`send_feedback`, `src/spock_apply.c:3237-3322`) reports a flush position only for entries whose local commit has been flushed (`get_flush_position`, `:3082-3118`). When nothing is outstanding it reports `recvpos`.

**Explicit at-least-once caveat (forwarded origins)**
- Commit `401197ab` message: "Because the advance is logged separately after the data commit, a crash may replay the latest transaction, preserving at-least-once semantics; **delta-apply idempotency remains a separate follow-up.**" Code: `maybe_advance_forwarded_origin()` `src/spock_apply.c:5165-5183` (`replorigin_advance(..., false, true)` after `CommitTransactionCommand`). With `forward_origins='all'` plus a pre-created disabled direct subscription, a crash between the two can cause a **double apply** once the direct subscription is enabled. For plain columns LUW makes this harmless; for delta-apply columns it double-counts.

**Testable properties**
- *P4.1 (Always):* for a direct subscription, each provider transaction appears exactly once on each subscriber, under kill -9 of subscriber postmaster/apply worker and provider walsender at random points. Use an append-only ledger table with a unique (origin_node, seq) key. A duplicate key would surface as insert_exists in resolutions, so check `spock.resolutions` for `insert_exists` on the ledger table, and check for gaps.
- *P4.2 (Always):* a delta-apply counter (`x = x + 1` on every node, `log_old_value=true, delta_apply_function=spock.delta_apply`) ends equal to the total number of committed increments cluster-wide on every node. Run separately with cascades / `forward_origins` to target the 401197ab caveat.

### S5. Commit timestamps are monotonic per node (Lamport clock) — the base of LUW causality

**Claims** (`patches/18/pg18-025-logical_commit_clock.diff`, the same in 15/16/17/19)
- xact.c: "Hook function used in XactLogCommitRecord() to ensure that the commit timestamp is monotonically increasing in commit-LSN order."
- "Incoming remote commit timestamp used in our monotonically increasing logical clock ... bump our local logical clock forward in case we receive a remote transaction that appears to have happened in the future."
- **Admitted gap** (same hook): "TODO: This is not postmaster restart safe. If the local system clock is further behind other nodes than it takes for the postmaster to restart ..., local transactions will not be bumped into the future correctly."

**Mechanism**
- `EnsureMonotonicTransactionStopTimestamp` runs under `insertpos_lck` and keeps `XLogCtl->lastTransactionStopTimestamp` (shared memory only, **reset at restart**). Apply transactions push the clock to `max(clock, local xact_time, remoteTransactionStopTimestamp)` (`src/spock_apply.c:1061` sets `remoteTransactionStopTimestamp = commit_time`). Local transactions get `max(clock+1, now)`.
- Note: the commit ts stored for an *applied* transaction is the remote origin timestamp (PG core uses `replorigin_session_origin_timestamp`), and the WAL `xact_time` of apply commits is not adjusted. So "monotonic in commit-LSN order" really covers local transactions only.

**Divergence scenario implied by the TODO (high-value Antithesis target)**
Take node A with a clock behind. A applies remote T1 (ts=100), then a local T2 updates the same row with ts bumped to 101. A's postmaster restarts and the clock resets. A local T3 then updates the row with wall-clock ts 91. A keeps T3 (a local write, no conflict check). B has T2 (101) and receives T3 (91), so LUW keeps T2. **Lasting divergence** with no exception_log entry (it shows as a resolutions row on B only if `save_resolutions` is on). It also breaks causality: A's later write loses.

**Testable properties**
- *P5.1 (Always):* on each node, for local-origin commits, `pg_xact_commit_timestamp` is strictly increasing in commit LSN order, checked across postmaster restarts. Expected to fail under clock skew + restart, which would confirm the TODO.
- *P5.2 (Always):* causality. If a client on node X reads version v of a row (originating elsewhere) and then updates it on X, the update wins on every node. Check under clock skew injection + node restart.
- *P5.3:* scoped convergence (P1.1) with clock-skew faults turned **on**.

### S6. Origin filtering prevents replication loops / echo

**Claims**
- `src/spock_output_plugin.c:1199-1222` `pg_decode_origin_filter`: "Never filter out locally originated tx's"; otherwise "forward all or nothing based on the configuration option 'forward_origins'."
- `src/spock_apply.c:1323-1330`: replorigin_session_origin is set to "the real origin_id" from the ORIGIN message.
- `docs/limitations.md:194-201`: Spock's 16-bit node_id and PG RepOriginId "overlap (0-65535), which can cause ambiguity if Spock and native PostgreSQL logical replication run on the same database."

**Mechanism / risks**
- Every apply commit carries origin = originating node id (never Invalid). With empty `forward_origins` (the mesh default) nothing applied is re-sent. With `forward_origins='{all}'` everything foreign is forwarded, and any cycle (A→B→C→A all forwarding) would loop. `enforce_forwarding_exclusivity()` (`src/spock_functions.c:470-532`) blocks forwarding together with another *enabled* subscription on the same node, but its own comment says: "This catalog check cannot prevent worker races or direct catalog changes."
- Initial table copy writes with origin = the local RepOriginId of the slot-name origin (`src/spock_sync.c:918-956`), not a Spock node id. It is filtered (not Invalid), but `get_node(txn->origin_id)` in `pg_decode_begin_txn` (`src/spock_output_plugin.c:628`) would look up a RepOriginId as a node id when forwarding.
- Any write path that runs in the apply process *without* `replorigin_session_origin` set would echo back. Places to check: DDL/queue apply, exception_log/resolutions writes (spock schema, not in any repset), `cleanup_resolutions` deletes, `sync_event` markers.

**Testable properties**
- *P6.1 (Always):* in a full mesh with default `forward_origins`, each user transaction is applied on each peer exactly once (ledger as in P4.1). Echo shows up as `insert_exists`/update_origin_differs churn and duplicate ledger keys.
- *P6.2 (Always):* `spock.repair_mode(true)` … `(false)` inside one transaction: those changes never appear on any peer (`docs/managing/read_only.md:59-71`; `src/spock_output_plugin.c:776-787,1080,1164`).

### S7. Exception-handling modes behave as documented

**Claims** (`docs/configuring.md:160-184`)
- `transdiscard` (default): "discard a transaction if any operation within that transaction returns an ERROR."
- `discard`: "commit any operation (any portion of a transaction) that does not return an ERROR".
- `sub_disable`: "disable the subscription ... when the subscription is enabled, replication will resume with the transaction that caused the exception, followed by the other queued transactions".
- `src/spock_apply.c:997-1004`: "For SUB_DISABLE mode during a retry (use_try_block), do not advance the LSN even if the replay succeeded. This allows the transaction to be re-applied after the user fixes the root cause".
- `src/spock_apply.c:850-866`: a stale `use_try_block` "would replay that transaction read-only and, under TRANSDISCARD or SUB_DISABLE, discard it -- a transaction that never failed".

**Mechanism**: first failure → `AbortOutOfAnyTransaction` → replay with `use_try_block` (`src/spock_apply.c:4060+`). Failure state lives in **shared memory** (`exception_log_ptr[]`), so a postmaster restart wipes it: the transaction is tried again normally, fails again, then replays. That should be harmless, but it is a path to cover.

**Testable properties**
- *P7.1 (Always, sub_disable):* after a deliberately bad transaction (e.g. a subscriber-only CHECK constraint) the subscription becomes disabled, and `pg_replication_origin_status.remote_lsn` for it is **< the bad transaction's end LSN**. After the fault is fixed and `sub_enable` runs, the bad transaction and every later one are applied exactly once, in order.
- *P7.2 (Always, transdiscard):* the bad transaction is completely absent and later transactions are present. Exception_log has rows for it.
- *P7.3 (Always):* no good transaction is ever logged as discarded (the `acf6cdae`/`ed0a9945` class), checked with an infrastructure-only fault set, as in P3.1.

### S8. Read-only modes

**Claims** (`docs/managing/read_only.md:5-9,73-83`)
- `local`: "Non-superuser local sessions are read-only. Replicated writes from apply workers are still permitted".
- `all`: "Non-superuser local sessions and apply workers are blocked from writing ... When the mode is switched back ... replication resumes from where it left off, **provided the upstream replication slot still retains the necessary WAL**."
- Superusers are exempt in both modes and their writes replicate outbound (`:51-57`).

**Mechanism**: `spock_ropost_parse_analyze` / `spock_roExecutorStart` set `XactReadOnly` for non-superusers (`src/spock_readonly.c:96-137`). Apply workers connect as bootstrap superuser (`BackgroundWorkerInitializeConnectionByOid(dboid, InvalidOid)`, `src/spock_worker.c:390`) and use `ExecSimpleRelation*` (no ExecutorStart), so `local` does not touch them. `all` → `elog(FATAL)` per message in `replication_handler` (`src/spock_apply.c:2981-2983`), plus the loop check at `:3610`. The GUC is re-read only on `ConfigReloadPending`. Note the FATAL mid-transaction: it goes through the proc_exit path, not through the PG_CATCH classifier. Confirm that FATAL cannot advance the origin past the partly applied transaction (exit callback at `:2319-2324`).

**Testable properties**
- *P8.1 (Always):* while `spock.readonly=all` is in effect (after reload is observed), no remote transaction commits on that node (the subscriber's origin `remote_lsn` does not move). After switching to `off`, no transaction is lost or duplicated (ledger).
- *P8.2 (Always):* non-superuser DML on a `local` node always fails. A transaction already open when the mode switches is a race to explore (the hook runs per statement).

### S9. Failover-slot correctness (physical standby of a provider or subscriber)

**Claims**
- `docs/logical_slot_failover.md:5,165` and `docs/configuring.md:305-307,345-347`: "replication resumes from the last synchronized LSN with no data loss".
- `docs/configuring.md:389-394`: `spock.pg_standby_slot_names` "must confirm durable flush of a given LSN before the walsender is allowed to replicate logical changes beyond that LSN. This prevents a physical standby from falling behind a logical subscriber."
- Counter-claim in the code itself, `src/spock_failover_slots.c:1265-1276`: "in most cases it'll still fast-forward to the new confirmed position even if that skips over a gap of WAL we never received from the provider before failover. **We can't detect or prevent that**".
- Old design text `docs/internals-doc/OUTPUT.md:469-475`: "no built-in way to guarantee that the logical replication slot from the failed master hasn't replayed further than the physical streaming replica".
- Subscriber side with sync standby, `src/spock_apply.c:3120-3125`: "we cannot send feedback to the publisher the instant the apply transaction commits locally: the local commit is not yet durable until the sync standby has flushed it, and if we tell the publisher we have flushed the change it may advance its slot past changes that a fail-over of THIS node would lose."

**Possible violation of the last claim (needs confirmation, high value)**: in `send_feedback()` (`src/spock_apply.c:3255-3277`), `get_feedback_position()` sets `writepos/flushpos` from the sync-standby hold queue. Then `get_flush_position(&writepos, &flushpos)` is called right after and **overwrites both**. When `lsn_mapping` is empty it sets `flushpos = writepos = recvpos`. Also, `append_feedback_position()` itself calls `get_flush_position()` (`:3151`), which **removes** locally flushed entries from `lsn_mapping`. So the flush position reported to the publisher looks gated only by *local* flush, not by sync-standby flush. Before `5f654e34` the bug was LSN-space confusion; this is a separate concern. The TAP test `tests/tap/t/020_sync_standby_feedback_lsn.pl` may pass on timing alone.

**Testable properties**
- *P9.1 (Always):* provider with physical standby + `spock.pg_standby_slot_names` (PG15-17) or `synchronized_standby_slots` (PG17+/18). Kill the primary at random and promote the standby. Each subscriber ends with exactly the provider transactions that are present on the promoted standby: no extras (a subscriber ahead of the new primary) and none missing.
- *P9.2 (Always):* subscriber with a synchronous physical standby. Kill the subscriber primary and promote its standby. No provider transaction is missing on the promoted subscriber after catch-up (the S9 lead).
- *P9.3 (Always):* on the provider, `confirmed_flush_lsn ≤ pg_current_wal_lsn()` (the symptom check from 5f654e34).

### S10. Node-id uniqueness

**Claims**
- `src/spock_node.c:374-383`: "Detect node_id hash collisions before insertion. The id is a 16-bit hash of the node name ... A collision causes replication-origin ambiguity between the two nodes." → ERROR.
- `docs/modify/zodan/zodan_tutorial.md:275`: ZODAN "aborts to prevent duplicate node names."

**Mechanism / limits**: `hash_any(name) & 0xffff` (`src/spock_node.c:368-371`), checked only against the local `spock.node` table at insert time. Two nodes created at the same time on different hosts are compared only when one is registered on the other, via `create_node` from the subscription RPC (`src/spock_rpc.c:319`). That matters for config validation more than for Antithesis faults. Subscription ids come from a sequence (`generate_subscription_id`, `src/spock_node.c:1000-1033`).

**Property**: *P10.1 (Always):* `spock.node.node_id` is unique within each node's catalog and agrees across nodes for the same `node_name`. Mostly a setup-time check.

### S11. Sequences / Snowflake uniqueness

**Claims**
- `docs/limitations.md:117-125`: replicated sequence state "minimizes the chance of subscriber's notion of sequence's `last_value` falling behind but **does not completely eliminate the possibility**." This is a non-guarantee.
- `docs/spock_functions/functions/spock_repset_add_seq.md:24-25`: "This ensures that nextval operations remain consistent across nodes in a multi-master environment." This overclaims and contradicts limitations.md.
- `docs/managing/snowflake.md:5-8,43-55`: Snowflake "minimize[s] the risk"; "ensuring a unique transaction sequence". Snowflake is a **separate extension not in this tree**, so it is out of scope.

**Mechanism**: `src/spock_sequences.c:41-42,120-140`. The provider pushes `last_value + cache` (1000..1,000,000). This is one-way and periodic, so it does not make multi-master `nextval` unique.

**Property**: *P11.1 (Sometimes / informational):* using plain replicated sequences as PKs on several writers produces `insert_exists` conflicts. That is expected and not a bug. Do not assert uniqueness unless Snowflake is installed.

### S12. Delta-apply columns converge to the sum of deltas

**Claims**
- `docs/conflicts.md:24-34`: "local_value + (new_value - old_value) ... on a conflicting transaction, the delta-apply column will be correctly calculated and applied."
- `docs/conflicts.md:10-17`: two concurrent $1,000 withdrawals give "The correct balance is `$-1,000`".
- `docs/limitations.md:178-189`: delta columns must be NOT NULL.

**Mechanism**: `build_delta_tuple` (`src/spock_apply_heap.c:510-582`). It is called for **every** remote UPDATE, not only conflicts (`spock_handle_conflict_and_apply`, which per the comment at `:1005-1008` "is a misnomer as it is called for the normal UPDATE case, too"). If the local row wins LUW, the delta is still applied on top of the local row in a subtransaction whose commit ts is overridden to the *local* ts/origin (`SubTransactionIdSetCommitTsData`, `:774-780`, core patch `pg*-030-per-subtrans-commit-ts.diff`). INSERT-exists uses a fake old tuple of zeros (`:895-907`), so concurrent INSERTs of the same key **add up**. Old value NULL (`log_old_value` was off at the source) falls back to plain new-value overwrite (`:553-566`), which loses deltas.

**Breakers**: a remote transaction discarded on one node (TRANSDISCARD), a double apply (S4 forwarded-origin caveat), an exception replay, or a `sub_alter_skiplsn` all leave a delta-counter sum that differs between nodes.

**Properties**
- *P12.1 (Always):* `SUM(counter)` on every node equals the cluster-wide number (or amount) of committed increments, after quiescence, under process kill / partition / clock-skew faults.
- *P12.2 (Always):* the same counter value on all nodes (convergence), even with LUW ties and skew, because delta-apply ignores who wins LUW for the delta column.

### S13. Add-node (ZODAN) — no data missed or duplicated

**Claims** (`docs/modify/zodan/zodan_tutorial.md`)
- `:375-376`: "transactions will start from exactly the right position. This ensures no data is missed or duplicated."
- `:413-415`: "use this stored LSN to ensure the subscription starts from exactly this point, guaranteeing no data loss."
- `:442-444`: the slot "starts collecting changes immediately. This ensures no data is lost".
- `:615-618`: "When `wait_for_sync_event()` completes, you are guaranteed that n1 has received all changes from n2 up to and including that LSN."
- `:973-976`: "This guarantees data consistency."

**Mechanism**: `samples/Z0DAN/zodan.sql:2525-2565,2625-2675` advances peer slots and new-node origins to `spock.progress.remote_commit_lsn` (copied from the source node). If no progress entry exists it **falls back to `pg_current_wal_lsn()`** (`:2643-2647`, just a NOTICE). That would skip any peer transactions the source had not yet applied, which is silent loss. `spock.progress` accuracy after a crash relies on resource.dat + `pg_commit_ts` recovery. The design doc calls it "monitoring-level" (`spock-progress-no-checkpoint-hook-design.md:26`), yet ZODAN uses it to choose where to resume. Also `spock.get_lsn_from_commit_ts()` (`src/spock_functions.c:4304-4371`) returns NULL when it cannot answer: "Callers must check for it ... any LSN we could invent here would be one they would act on."

**Properties**
- *P13.1 (Always):* during `spock.add_node` with continuous writes on all existing nodes and faults injected (kill the source node or a peer, partition the new node), the new node ends up with exactly the union of all committed rows: no gaps, no duplicate ledger keys, and the same counter sums.
- *P13.2 (Always):* the "falling back to pg_current_wal_lsn()" NOTICE never fires while writes are in flight. If it fires, check for loss.

---

## Summary table of candidate safety properties

| ID | Property | Kind | Main fault types |
|---|---|---|---|
| P1.1 | Scoped convergence (no deletes, unique inserts) | Always (after quiescence) | partition, kill, clock skew |
| P2.1 | Every inter-node row difference has an exception_log/resolutions record | Always | all |
| P2.2 | TRANSDISCARD all-or-nothing per remote xact | Always | data faults |
| P3.1 | No exception_log / no sub disable under pure infra faults | Always | kill, partition, pause, provider restart, lock contention |
| P4.1 | Exactly-once per direct subscription | Always | kill -9 at random points |
| P4.2/P12.1 | Delta counter sum = committed increments, all nodes | Always | kill, cascade/forwarding |
| P5.1/P5.2 | Monotonic commit ts / causal LUW across restart | Always (expected to fail with skew+restart) | clock skew + restart |
| P6.1 | No echo/loop in mesh | Always | partition, kill |
| P7.1 | SUB_DISABLE keeps origin before bad xact; resume replays it | Always | data fault + kill |
| P8.1 | readonly=all stops apply; resume without loss | Always | toggle + kill |
| P9.1/P9.2 | Failover (provider or subscriber standby) loses nothing | Always | primary kill + promote |
| P13.1 | add_node under load gives exact union | Always | kill/partition during add_node |

## Areas examined
- Docs: `docs/conflicts.md`, `docs/conflict_types.md`, `docs/configuring.md` (exception GUCs, failover slot GUCs, read_retry_count), `docs/limitations.md`, `docs/managing/read_only.md`, `docs/managing/snowflake.md`, `docs/logical_slot_failover.md`, `docs/modify/zodan/zodan_tutorial.md`, `docs/spock_functions/functions/spock_sync_event.md`, `spock_repset_add_seq.md`, `docs/internals-doc/DESIGN.md`, `OUTPUT.md`, `specs/spock-progress-no-checkpoint-hook-design.md`, `plans/2026-04-30-recover-remote-commit-ts-plan.md`; grep for guarantee/never/loss/duplicate across `docs/`.
- Code: `src/spock_conflict.c` (resolver, tiebreaker, get_tuple_origin, GUC check hook); `src/spock_apply.c` (handle_begin/commit/origin, exception classifier in apply_work PG_CATCH, feedback/flush positions, forwarded-origin advance, readonly checks); `src/spock_apply_heap.c` (insert/update/delete apply, delta apply); `src/spock_output_plugin.c` (origin filter, ORIGIN message, repair mode); `src/spock_sync.c` (copy origin setup); `src/spock_node.c` (node id hash + collision check, tiebreaker parse, subscription id); `src/spock_functions.c` (forwarding exclusivity, get_lsn_from_commit_ts, resync readonly check); `src/spock_readonly.c`; `src/spock_failover_slots.c` (standby confirmation wait, slot capping comment); `src/spock_sequences.c`; `src/spock.c` GUC definitions; `src/spock_worker.c` connection role.
- Core patches: `patches/18/pg18-025-logical_commit_clock.diff`, the head of `pg18-030-per-subtrans-commit-ts.diff`.
- `samples/Z0DAN/zodan.sql` slot/origin advance.
- Git history: `64ea462d`, `5f654e34`, `d286f3df`, `f3d4935e`, `ed0a9945`, `8dcfbcd5`, `401197ab`, `162dc562`, `f21e71bc`, plus a log grep for loss/duplicate/skip/misclassification.
- Test list `tests/tap/t/*` (names only), used to see which guarantees already have targeted tests (013, 015, 016, 018, 020, 024, 025, 035/036, 046).

## Assumptions
- PG core behaviour assumed and not re-read here: `RecordTransactionCommit` stores `replorigin_session_origin_timestamp`/`replorigin_session_origin` into commit_ts and advances the session origin atomically with the commit record. `RecordTransactionAbort` also advances the session origin to `replorigin_session_origin_lsn`. Logical decoding skips transactions whose commit record starts before the requested start LSN.
- The default topology for Antithesis is a full mesh with empty `forward_origins` and the defaults: `transdiscard`, LUW, `save_resolutions=off` (turn it on for P2.1).
- I treated `samples/Z0DAN/zodan.sql` as the add_node implementation the docs describe. The `spock.add_node` procedure in `sql/` was not compared line by line.

## Open Questions
1. **Sync-standby feedback (S9/P9.2):** is the overwrite of `flushpos` by `get_flush_position()` in `send_feedback()` intended? It looks like it defeats the sync-standby hold the comment at `src/spock_apply.c:3120-3125` describes.
2. Does a `FATAL` raised from `replication_handler` under `readonly=all` mid-transaction ever advance the origin? Check the exit path versus the `d286f3df` fix that clears `replorigin_session_origin*` in `spock_apply_worker_shmem_exit`.
3. Which other sqlerrcodes can arise mid-apply from infrastructure faults (not data faults) and still reach the discard path? Candidates: 57014 statement_timeout, 25P03, 40001, XX000 from libpq helpers, errors from `wait_for_previous_transaction`.
4. Is a tiebreaker set in `spock.node.info` replicated or kept consistent across nodes? If not, tie handling can disagree between nodes.
5. Is `prev_remote_ts`/`required_commit_ts` ordering (`wait_for_previous_transaction`) active at all? The spec says "apply-group ordering is disabled". If it is disabled, there is no cross-origin ordering, which feeds the S1 `update_missing` divergence.
6. ZODAN falls back to `pg_current_wal_lsn()` when `spock.progress` has no entry. Under what crash timings can that entry be missing after a source-node crash?
7. Commit-ts monotonicity after restart (S5): does anything outside the TODO restore the logical clock at startup, for example from the last WAL commit record during recovery? The patch shows no such step.
