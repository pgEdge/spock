---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Property discovery — Focus 4: Protocol Contracts

Lens: what the provider promises the subscriber on the wire, what the
subscriber promises the provider through feedback, and what the SQL API
promises callers (barriers, sync waits, status, exception/resolution tables).

## Category: Stream and feedback contracts

The output plugin and apply worker talk a binary protocol over a walsender
connection; the only thing flowing back is the standby status update. A broken
rule here turns directly into skipped or duplicated transactions.

### feedback-never-confirms-undurable-apply — Feedback never confirms a transaction the subscriber has not made durable

| | |
|---|---|
| **Type** | Safety |
| **Property** | The flush position the apply worker reports to the provider never reaches the end LSN of a provider transaction whose local commit on the subscriber (or its sync standby) is not yet durable. |
| **Invariant** | SUT-side `Always` in `send_feedback()` before sending: `flushpos < remote_end` for every `lsn_mapping` entry with `local_end > GetFlushRecPtr()` and for every still-held sync-standby entry. Second SUT-side `Always` in `request_initial_status_update()` (and the first empty-mapping feedback of a process): the session origin's `local_lsn <= GetFlushRecPtr()`. Companion `Sometimes`: "apply worker restarted while its origin local_lsn was unflushed". `Always` because each report must satisfy the rule; one bad report is enough to lose data. |
| **Antithesis Angle** | Graceful apply-worker exit (terminate backend, `sub_disable`/`sub_enable`, provider disconnect) followed within the async-commit flush delay by subscriber node kill; slow I/O/CPU widen the window. The new worker reports `flush = origin_startpos` read with `replorigin_session_get_progress(false)` (no flush), so the provider confirms a transaction that crash recovery then loses. L9 (sync-standby hold overwritten) is the same rule with a standby container. |
| **Why It Matters** | A violation is permanent silent loss: the provider will never resend, and no exception row exists. Same family as 5f654e34 (confirmed_flush ahead of durable state). |

**Open Questions:**

- Is there any WAL flush between the old worker's last commit and the new worker's initial report? `(partial: none found in spock start path; stock PG worker has the same empty-mapping feedback)`
- Is `flush = recvpos` with an empty mapping right after a worker restart accepted (as in stock PG), limiting the fix to the explicit initial report?

Confidence: medium (mechanism read in code and stock PG18 source; reachability not yet shown)
Evidence file: properties/feedback-never-confirms-undurable-apply.md

### apply-stream-framing-and-lsn-order — Apply stream follows the protocol grammar and LSN order

| | |
|---|---|
| **Type** | Safety |
| **Property** | On every replication connection the subscriber sees STARTUP first, then transactions framed as BEGIN, ORIGIN, changes, COMMIT with matching commit LSN and commit time, strictly increasing end LSN, and no transaction starting below the origin's recorded progress. |
| **Invariant** | Seven SUT-side assertions with distinct messages in the apply worker: `Always` first message is STARTUP; `Always` no BEGIN inside an open remote txn; `Always` ORIGIN precedes the first change; `Always` COMMIT commit_lsn == BEGIN commit_lsn and end_lsn > commit_lsn; `Always` end_lsn strictly increases per connection; `Always` BEGIN commit_lsn >= origin progress; `Reachable` non-transactional sync_event before first BEGIN. `Always` because each is a per-message rule. |
| **Antithesis Angle** | Walsender kills mid-decode, provider restarts, drops between BEGIN and COMMIT, reconnect while the old walsender holds the slot, CPU pauses in the output plugin: each forces a new connection and startup sequence where framing assumptions are tested. |
| **Why It Matters** | A missing ORIGIN stamps commits with the previous transaction's node id (wrong LUW decisions, echo); a re-delivered transaction double-applies (delta columns); a non-STARTUP first message under v5 is misparsed and lands in the exception path (fdd9587e). Several of these rules are not checked at all today. |

**Open Questions:**

- Is any legitimate re-delivery below origin progress possible (for example after ZODAN's paired origin/slot advance)?
- Is the fact that `handle_begin` does not reset `replorigin_session_origin` relied on anywhere?

Confidence: medium (rules are clear from code; no known violation under v1 naming)
Evidence file: properties/apply-stream-framing-and-lsn-order.md

## Category: Coordination API contracts

`sync_event` / `wait_for_sync_event` and the sync-wait functions are what
callers (including ZODAN and this harness) use to decide that replication has
caught up.

### sync-event-barrier-implies-visible — A satisfied sync barrier means the provider's earlier commits are visible

| | |
|---|---|
| **Type** | Safety |
| **Property** | When `wait_for_sync_event(P, lsn)` returns true on S, a new snapshot on S sees every effect of every P-originated transaction that committed before `sync_event()` was called on P, or `spock.exception_log` names that transaction. |
| **Invariant** | Workload-side `Always` after each successful barrier: all ledger rows recorded as committed on P before the call are present on S, or explained by an exception_log row. Separate message for rows written inside a `sync_event(true)` caller's own transaction. Companion `Sometimes`: "transactional barrier satisfied in the same apply transaction as ledger rows". |
| **Antithesis Angle** | Thread pauses of the apply worker between WAL insert and procarray update (origin `remote_lsn` is advanced in `RecordTransactionCommit` before the commit is visible); concurrent commits on P between a transactional marker and its own commit, which move S's origin past the marker before the marker's transaction arrives; TRANSDISCARD exceptions interleaved with barriers. |
| **Why It Matters** | Every convergence check, ZODAN phase and operator script trusts this barrier. A barrier that returns early makes correct data look lost or lets add_node move on before data arrived (fix dcbba6bb was this shape). |

**Open Questions:**

- Is "origin reached" the whole contract, or must the transaction be visible? `(needs human input)`
- Is the DML of the transaction that calls `sync_event(true)` meant to be covered? `(needs human input)`
- Barrier timeouts must exceed `apply_idle_timeout + restart_delay_default`; any lower value turns liveness into false failures.

Confidence: high for the property being worth checking; medium that it fires (the transactional-with-DML case is easy to reach, but intent is unclear)
Evidence file: properties/sync-event-barrier-implies-visible.md

### sync-event-barrier-survives-subscriber-restart — A satisfied barrier stays satisfied after the subscriber restarts

| | |
|---|---|
| **Type** | Safety |
| **Property** | Once a barrier (P, lsn) has returned true on S, the subscription origin's `remote_lsn` does not come back below `lsn` after S restarts, so re-checking the barrier succeeds without new traffic from P. |
| **Invariant** | Workload-side `Always`: after S's postmaster start time changes and with P's writers paused for that pair, `wait_for_sync_event(P, highest_satisfied_lsn, timeout => T)` returns true. Alternative message on the raw value: "subscription origin remote_lsn never goes backwards across restart". Companion `Sometimes`: "subscriber restarted after a marker was applied and before the next provider transaction". |
| **Antithesis Angle** | Node termination of S between checkpoints. Non-transactional markers and empty transactions advance the origin in shared memory only (L18); normal commits are redone against the node-id origin, not the subscription origin (L1). Feedback has already moved P's `confirmed_flush` past the marker, so P never resends. |
| **Why It Matters** | The check phase of the harness and ZODAN's catch-up waits hang (with the default `timeout = 0`, forever) or report false lag after a crash; L1 also implies duplicate apply. |

**Open Questions:**

- Is subscriber-side durability of marker progress part of the contract? `(needs human input)`
- Does L1 reproduce on the patched PG18 build?

Confidence: medium (L18 mechanism is code-checked; L1 is agreed by three focuses but not run)
Evidence file: properties/sync-event-barrier-survives-subscriber-restart.md

### sync-wait-functions-honor-contract — sub_wait_for_sync / table_wait_for_sync return only when synced and do not wait silently on a terminal failure

| | |
|---|---|
| **Type** | Safety |
| **Property** | When `sub_wait_for_sync` or `table_wait_for_sync` returns normally the copied data is present; and they are never still waiting once the subscription has been disabled by a failed initial sync or a table is FAILED. |
| **Invariant** | Two workload-side `Always` messages: (1) on normal return after a quiesced `sub_resync_table` (or a direct `sub_create` with data sync), every provider ledger row from the resync start is on S; (2) when a call hits the workload's `statement_timeout`, NOT (`sub_enabled = false` or any table in `'f'`). |
| **Antithesis Angle** | Partition or provider kill during COPY or table catch-up: initial sync in `s/d/c` disables the sub but leaves the status, so `sub_wait_for_sync` loops forever (it never reads `sub_enabled`); a sync worker dying with an error leaves the table in `p/d/w/u` (L12). ZODAN itself replaced the C wait with a bounded loop citing "rare hangs". |
| **Why It Matters** | Scripts that call these functions without their own timeout hang with no error, and the matching `sub_show_status` row says `replicating`. A false "done" would hide missing rows. |

**Open Questions:**

- Should `sub_wait_for_sync` raise when the subscription has been disabled by a failed initial sync? `(needs human input)`
- Will the workload use `sub_create(..., synchronize_data := true)` outside ZODAN?

Confidence: medium (hang path code-checked and acknowledged in ZODAN; return-correctness has no known defect)
Evidence file: properties/sync-wait-functions-honor-contract.md

### sub-show-status-reflects-apply-state — sub_show_status "replicating" is truthful within a bound

| | |
|---|---|
| **Type** | Safety |
| **Property** | `sub_show_status()` does not keep reporting `replicating` for a subscription whose provider has unapplied changes for it beyond the documented detection bound, and reports `disabled` once a subscription has been disabled for longer than the worker exit delay. |
| **Invariant** | Workload-side `Always`: during a barrier wait with timeout B (B > `apply_idle_timeout + restart_delay_default + connect_timeout + margin`), if the barrier times out, not every status sample may have been `replicating`. Second message: `sub_enabled = false` in two samples at least `restart_delay_default + 5 s` apart implies the later status is `disabled`. |
| **Antithesis Angle** | Faults that leave the worker alive but stuck: silent partitions, SIGSTOP of the provider, a sync worker that died in CATCHUP (L12), pauses (L4), blocking libpq calls where SIGTERM is not seen. The status is computed only from "worker has a proc" plus the sub-level sync row. |
| **Why It Matters** | Docs say `replicating` means "changes from the provider are being applied normally"; ZODAN and operators gate on it. A false `replicating` hides silent per-table drift. |

**Open Questions:**

- Which meaning of `replicating` is intended: "worker exists and initial sync done" (code) or "changes are being applied" (docs)? `(needs human input)`
- Should a FAILED table change the subscription-level status?

Confidence: medium (mismatch is certain from code; whether it is a bug depends on intent)
Evidence file: properties/sub-show-status-reflects-apply-state.md

## Category: Audit tables

`spock.exception_log` and `spock.resolutions` are the record of what Spock
dropped or decided. The harness's "explained divergence" oracle depends on
them being right.

### exception-log-matches-discarded-transactions — exception_log is an accurate and complete record of discarded transactions

| | |
|---|---|
| **Type** | Safety |
| **Property** | Under TRANSDISCARD, every `exception_log` row names a real transaction from its `remote_origin` and one of its changes; each discarded transaction is logged completely, with exactly one root-cause row, and none of its changes are visible on that node. |
| **Invariant** | Workload-side `Always` (three messages): row names a real transaction (matching the workload's `(node, xid, commit ts, write set)` record); discarded transaction logged completely and applied nowhere on that node; exactly one root-cause entry per discarded transaction. Companion `Sometimes(transaction discarded under TRANSDISCARD)`. |
| **Antithesis Angle** | Data errors (documented `update_missing` ordering, deliberate constraint violations) mixed with graceful exits during replay (L7), sync workers sharing the marker (L15), transient errors misread as data faults (Pattern A) and missing ORIGIN messages. |
| **Why It Matters** | Repair (ACE) and operators use the table to find what was dropped. Rows that name the wrong transaction, miss rows, or exist for applied transactions all mislead repair. |

**Open Questions:**

- Compare `remote_xid` as 32-bit?
- Are changes for relations missing on the subscriber logged with a NULL table name?

Confidence: medium
Evidence file: properties/exception-log-matches-discarded-transactions.md

### resolutions-rows-match-applied-outcome — spock.resolutions rows describe the conflict that happened and the LUW decision taken

| | |
|---|---|
| **Type** | Safety |
| **Property** | Each `spock.resolutions` row names the real remote writer and local version, and its `conflict_resolution` agrees with the documented last-update-wins and tiebreaker rule given the recorded timestamps. |
| **Invariant** | Workload-side `Always` (four messages): remote side names the real writer (and `remote_tuple` matches for `insert_exists`); local side names the real local version; decision follows LUW with the tie rule; `delete_missing` rows have no local tuple. Non-delta tables only. |
| **Antithesis Angle** | Asymmetric latency and partitions create insert/insert and delete/update races; clock jitter produces equal timestamps; node restarts reset the logical clock. None should make the recorded row disagree with the decision. |
| **Why It Matters** | Resolutions are the only persistent trace of resolved conflicts. Note that update/update conflicts (including remote updates thrown away because the local row is newer) are, by design, never written to either table, so oracles must not expect them. |

**Open Questions:**

- Is it intended that a losing remote UPDATE is recorded nowhere except the server log? `(needs human input)`
- Are delta-apply tables in scope for the local-side check?

Confidence: medium (low chance of a pure recording bug; value is in the cross-checks and the documented gap)
Evidence file: properties/resolutions-rows-match-applied-outcome.md

## Category: Wire format and value fidelity

### unchanged-toast-column-no-hybrid-rows — A remote UPDATE that wins never leaves a mix of winner and loser columns

| | |
|---|---|
| **Type** | Safety |
| **Property** | After quiescence, every row equals the full post-image of the update named in its version column; no node holds a row whose small columns come from one update and whose out-of-line column comes from another. |
| **Invariant** | Workload-side `Always` on a `toast_luw(id, ver, small, big STORAGE EXTERNAL)` table where each update sets `ver` and only one of `small`/`big` and records its post-image via `RETURNING`: on every node `(ver, small, md5(big))` equals the recorded post-image for `ver`. Companion SUT-side `Sometimes` (missing): "remote UPDATE with an unchanged TOAST column won a conflict against a different local version". |
| **Antithesis Angle** | Concurrent updates of the same rows from two nodes, one touching only the small column; latency or short partitions between pairs. The provider sends `'u'` for unchanged out-of-line values and the subscriber fills them from its local row (`slot_modify_data`) even when the remote version wins LUW. |
| **Why It Matters** | Breaks the documented whole-row LUW claim and causes permanent divergence with nothing in `exception_log` or `resolutions`. The oracle is immune to L2/L3 winner changes, so a firing is specific to this mechanism. |

**Open Questions:**

- Is the merged row on remote-wins with an unchanged TOAST column known and accepted? `(needs human input)`
- Does `REPLICA IDENTITY FULL` or `log_old_value` change what is sent for the large column?

Confidence: medium-high on mechanism (walked through code on both sides); not yet reproduced
Evidence file: properties/unchanged-toast-column-no-hybrid-rows.md

### replicated-values-identical-across-transfer-modes — Values are equal on every node regardless of transfer mode and session settings

| | |
|---|---|
| **Type** | Safety |
| **Property** | A replicated value is equal on every node whatever the transfer encoding (internal binary, send/recv, text) and whatever DateStyle, TimeZone, IntervalStyle and float settings each node runs with. |
| **Invariant** | Workload-side `Always`: insert-only table with node-unique keys and many types (timestamptz, timetz, interval, float NaN/-0/Infinity, numeric NaN, multibyte text, bytea, jsonb, arrays, enum, composite); nodes configured with different DateStyle/TimeZone/IntervalStyle; at least one subscription per node with `force_text_transfer`; after quiescence `md5(row_to_json)` computed under fixed settings matches on all nodes. |
| **Antithesis Angle** | Mostly a configuration-space property; reconnects and provider restarts re-run startup negotiation, which decides binary vs text per connection. |
| **Why It Matters** | A wrongly converted value applies cleanly and is never noticed. 34d473dc/f21e71bc show the team already found one such class and fixed it by pinning settings; TimeZone and `lc_monetary` are still not pinned. |

**Open Questions:**

- Is `money` across nodes with different `lc_monetary` supported? `(needs human input)`
- Will the v1 harness actually vary DateStyle/TimeZone per node?

Confidence: low (no known defect; regression guard)
Evidence file: properties/replicated-values-identical-across-transfer-modes.md

---

## Areas examined

- Output plugin: `pg_decode_begin_txn`, `pg_decode_commit_txn` (incl. the
  `end_lsn - MyWalSenderIdx` used only for `SyncRepWaitForLSN`; the wire
  carries the real `end_lsn`), `pg_decode_message`, startup negotiation and
  `forward_changeset_origins` (always true) — `src/spock_output_plugin.c`.
- Wire encoding: `spock_write_begin/commit/origin/commit_order`, tuple writer
  `'n'/'u'/'i'/'b'/'t'`, `decide_datum_transfer`, `spock_read_*`
  (`src/spock_proto_native.c`).
- Apply: `replication_handler`, `handle_begin/origin/commit_order/commit/message/startup`,
  `apply_work` receive loop (`'w'` v5 prefix, `'k'` keepalive), `send_feedback`,
  `get_flush_position`, sync-standby hold, `request_initial_status_update`,
  `spock_apply_main` start position (`src/spock_apply.c`).
- Stock PG18 source (scratch copy): `RecordTransactionCommit` ordering,
  `replorigin_session_get_progress`, `logicalmsg_decode`, `LogLogicalMessage`,
  `WalSndPrepareWrite`, `ProcessStandbyReplyMessage`, `ctx->write_location`
  per callback.
- SQL API: `spock_create_sync_event`, `wait_for_sync_event` (SQL),
  `spock_wait_for_sync_complete`, `spock_show_subscription_status`,
  `sync_status_to_string` (`src/spock_functions.c`, `sql/spock--6.0.0.sql`).
- Audit tables: `spock_report_conflict`, `spock_conflict_log_table`,
  `conflict_resolve_by_timestamp`, `get_tuple_origin`
  (`src/spock_conflict.c`); `log_insert_exception`,
  `add_entry_to_exception_log`, `should_log_exception`.
- Docs: `docs/monitoring/spock_sync_event.md`, `docs/conflict_types.md`,
  `spock_sub_show_status.md`, `docs/internals-doc/OUTPUT.md`; commits
  34d473dc, f21e71bc, 85688477, 2f9a686c, dd0cef7d.
- Not turned into properties: protocol v4/v5 mixed-version streams (needs a
  second build; out of v1 scope — the `S`-first assertion still covers the
  version switch); JSON output encoding (not used by Spock subscribers);
  slot-group `L` message ordering (L10/L30, avoided by naming in v1);
  `wait_slot_confirm_lsn` (no timeout, blocked by dead slots; liveness, other
  focus).

## Assumptions affecting multiple properties

1. Stock PG behaviour checked in a PG18 source copy applies unchanged to the
   pgEdge-patched build: `replorigin_session_advance` inside
   `RecordTransactionCommit` before `ProcArrayEndTransaction`;
   `replorigin_session_get_progress(false)` does not flush; the walsender
   confirms any `'r'` flush position; non-transactional logical messages are
   decoded at record-read time with `message_lsn = endptr`. The patch lists do
   not touch these functions. (feedback, both barrier properties, framing)
2. Replication-origin shared state survives an apply worker exit but not a
   postmaster restart. (feedback, barrier-survives-restart)
3. The workload can record per transaction `(node, xid, commit ts, write set)`
   and keep insert-only ledgers keyed by `(origin_node, seq)`; most workload-side
   checks join on these. (barrier, exception_log, resolutions)
4. v1 runs `exception_behaviour = transdiscard` with `save_resolutions = on`,
   lowercase names without `_<digit>` endings, default `forward_origins`.
   (exception_log, resolutions, framing)
5. Barrier and sync-wait timeouts used by the workload exceed the documented
   detection bound (`apply_idle_timeout` lowered per the topology, plus
   `restart_delay_default` and `connect_timeout`); otherwise the safety checks
   would fire on expected slow recovery.
