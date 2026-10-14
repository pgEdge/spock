# apply-stream-framing-and-lsn-order — Apply stream follows the protocol grammar and LSN order

## Synthesis note

Merged from `apply-stream-framing-and-lsn-order` (F4) and
`startup-message-precedes-all-stream-data` (F10). F4's first assertion
("first message is STARTUP") is F10's whole property; F10 adds the version
check (`proto_version == 5` on 6.0 <-> 6.0 links) and a `Reachable` at the
`pg_decode_message` branch that sends 'S' before a sync_event (the fdd9587e
regression path). The merged property is a set of per-message SUT-side
`Always` checks with distinct messages, plus the two `Reachable` markers.
`proto5-replay-reparses-startup-message` stays separate: it is about the
replay queue re-parsing a stored 'S' entry, not the live stream order.

## Investigation update (2026-10-13)

- **Assertion 6 (BEGIN `commit_lsn` >= origin progress) has no known
  legitimate exception.** The origin holds the `end_lsn` of the last applied
  transaction (or a marker's record end). The provider restarts at
  max(origin, `confirmed_flush`) and skips a transaction when its commit
  record start is strictly below that (PG18 `snapbuild.c:306`,
  `decode.c:1296-1300`), so every re-sent transaction has `commit_lsn` >= the
  start point. ZODAN's paired advance (`samples/Z0DAN/zodan.sql` ~:2541-2559,
  :2645-2671) sets the slot and the origin to the same
  `spock.progress.remote_commit_lsn`, which is an `end_lsn`
  (`src/spock_apply.c` `handle_commit` progress update), and
  `pg_replication_origin_advance` cannot run while the apply worker holds
  the origin (PG18 `origin.c` `replorigin_advance` "already active for PID"
  error). Exception replay re-runs the same BEGIN with the origin still at
  the previous transaction's end, which also satisfies `>=`. Use `>=`, not
  `>`.
- **Nothing relies on `handle_begin` leaving `replorigin_session_origin`
  alone.** Between transactions it holds the last node id (or the slot
  roident right after start, `:4750`); the non-transactional marker path
  (`:2958`) and the empty-transaction branch (`:1123`) only need it to be
  non-Invalid, and nothing but the ORIGIN message arrives between BEGIN and
  the first change. `spock_apply_worker_shmem_exit` (`:2305-2325`) resets it
  to Invalid at exit on purpose (so `RecordTransactionAbort` does not
  advance the origin). Assertion 3 should keep testing `remote_origin_id`,
  which `handle_begin` (`:687`) and the error path (`:4123`) reset; testing
  `replorigin_session_origin` would never fail. Assertion 2 placement note:
  the error path sets `in_remote_transaction = false` (`:4110`) before
  replay, so replayed BEGINs do not trip it.
- **Only one Spock-prefixed message is sent.** `LogLogicalMessage` with
  `SPOCK_MESSAGE_PREFIX` is called in `spock_create_sync_event` and in
  `skip_wal_records_decoding` (repair mode, transactional,
  `src/spock_functions.c:3939-3960`). In `pg_decode_message`
  (`src/spock_output_plugin.c:745-835`) repair-mode messages set a flag and
  write nothing; unknown types log a WARNING and write nothing; other
  prefixes return early. Only `SPOCK_SYNC_EVENT_MSG` reaches the wire, and
  that branch sends 'S' first.
- **No protocol-version GUC exists at HEAD.** `max_proto_version` /
  `min_proto_version` come from the compile-time constants
  (`src/spock.c:702-703`, `src/spock_output_config.c:539`). The version
  assertion is valid as written; if a cap is added later, the assertion must
  read it.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (value underestimated)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: walsender kill, partition, provider restart

- Evaluation note (2026-10-13): cheap checks evaluated on every message of every timeline and guards for the other oracles: put them in the first SUT-instrumentation batch regardless of rank.

## Open questions

- None.

## Source: `apply-stream-framing-and-lsn-order` (F4 Protocol)

### Summary

The native protocol has an implied grammar per replication connection:

```
S  ( B O [L] (R | I | U | D | T | M_txn)* C  |  M_nontxn )*
```

with these value rules:

- `S` (startup) is the first Spock message on every connection; it fixes the
  protocol version (v4/v5) that decides whether every following message starts
  with an 8-byte `remote_insert_lsn`.
- Every `B` is followed by exactly one `O` before any change; `O` carries the
  true origin node id.
- `B.final_lsn` (BEGIN's `commit_lsn`) equals `C.commit_lsn`; `C.end_lsn >
  C.commit_lsn`; `B.commit_time == C.commit_time`.
- Within one connection, successive `C.end_lsn` strictly increase, and no `B`
  arrives while a transaction is open.
- The first transaction after `START_REPLICATION` has `commit_lsn >=
  origin_startpos`, and in general a new `B.commit_lsn` is never below the
  subscription origin's current `remote_lsn`. A transaction below that point
  is a re-delivery of something the subscriber has already recorded as applied.

The subscriber enforces only part of this (`handle_origin` and
`handle_commit_order` "sent out of order" ERRORs, a cassert-only `Assert` on
commit time). The rest is assumed. A violation turns into wrong origin stamps,
duplicate or skipped transactions, or a misparsed stream.

### Code paths

- Provider: `pg_decode_begin_txn` `src/spock_output_plugin.c:520-662` (sends
  `S` lazily via `send_startup_message`, then `B`, `O`, `L`; `O` is always
  sent because `forward_changeset_origins = true` at `:501`);
  `pg_decode_commit_txn` `:670-740`; non-transactional `M` path `:790-830` also
  sends `S` first (fix fdd9587e).
- Wire writers: `spock_write_begin` `src/spock_proto_native.c:215-233` (sends
  `txn->final_lsn`, commit time, xid), `spock_write_commit` `:239-266` (sends
  `commit_lsn`, `txn->end_lsn`, commit time), v5 prefix on every message.
- Subscriber: `replication_handler` `src/spock_apply.c:2976-3062`;
  `handle_begin` `:660-906` (no check for an already-open remote txn; resets
  `remote_origin_id` but **not** `replorigin_session_origin`);
  `handle_origin` `:1301-1335`; `handle_commit` `:912-1262` (reads
  `commit_lsn` but never compares it with BEGIN's; `Assert(commit_time ==
  replorigin_session_origin_timestamp)` at `:933`); proto version default is
  `SPOCK_PROTO_MIN_VERSION_NUM` (4) until `handle_startup_param` sets it
  (`src/spock_proto_native.c:45`, `src/spock_apply.c:2427-2445`); v5 prefix is
  consumed in `apply_work` at `:3747-3750`.
- Origin start: `origin_startpos = replorigin_session_get_progress(false)`
  `:4751`, passed to `START_REPLICATION`.

### Why it matters

- A missing `O` leaves `replorigin_session_origin` at the previous
  transaction's node id (or the slot roident at startup). Commit records and
  `pg_commit_ts` then carry the wrong origin, so later LUW decisions and the
  origin filter (echo prevention, S6) use the wrong node.
- A `B` re-delivered below the origin progress is a duplicate apply; delta
  columns double-count (S4/S12).
- A non-`S` first message under v5 is parsed with the wrong layout; the
  resulting ERROR is not on the connection list and goes into the exception
  path (fdd9587e was this class).
- Slot groups (L10) and the walsender skipping logic are the most likely
  producers of a gap or reordering; the v1 topology avoids slot-group names,
  so this property mostly guards against regressions and provider-side
  surprises under reconnect storms.

### Invariant and instrumentation (all missing)

Distinct SUT-side assertions (unique messages), in the apply worker:

1. `Always`: "first Spock message on a connection is STARTUP" (in
   `replication_handler`, track per-connection flag).
2. `Always`: "BEGIN never arrives inside an open remote transaction"
   (`handle_begin`: `!in_remote_transaction`).
3. `Always`: "ORIGIN precedes first change of every transaction"
   (`handle_insert/update/delete/truncate`: `remote_origin_id !=
   InvalidRepOriginId`).
4. `Always`: "COMMIT commit_lsn equals BEGIN commit_lsn and end_lsn exceeds it"
   (`handle_commit`).
5. `Always`: "COMMIT end_lsn strictly increases within a connection".
6. `Always`: "BEGIN commit_lsn is not below the origin's recorded progress"
   (`handle_begin`: `commit_lsn >= replorigin_session_get_progress(false)`).
7. `Reachable`: "non-transactional sync_event received before first BEGIN on a
   connection" (exercises the fdd9587e path).

`Always` fits because each is a per-message rule that must hold on every
evaluation. Item 6 does not catch L1 (after L1 the origin itself has rolled
back, so the re-sent transactions are above it); it catches provider-side
re-delivery and slot-group skips.

### Antithesis angle

Walsender kill mid-decode, provider restart, network drop between `B` and `C`,
reconnect races where the old walsender still holds the slot, and CPU pauses
in the output plugin. Each forces a new connection and a new startup sequence,
which is where framing bugs show up.

### Original open-question notes (detail for the combined list above)
- Is there any legitimate case where the provider re-sends a transaction whose
  `commit_lsn` is below the subscriber's origin progress (for example after
  ZODAN's `pg_replication_origin_advance` / `pg_replication_slot_advance`
  pair)? If yes, assertion 6 needs to exclude it.
- `handle_begin` does not reset `replorigin_session_origin`; is that relied on
  anywhere (for example for empty transactions)? Changes whether assertion 3
  should instead check `replorigin_session_origin` directly.

## Source: `startup-message-precedes-all-stream-data` (F10 Versions)

### Summary

The subscriber learns the negotiated protocol version only from the
publisher's startup message ('S'). Until it arrives, it parses every message
as protocol 4 (`spock_apply_proto_version` defaults to 4,
`src/spock_proto_native.c:45`). On a 6.0 <-> 6.0 link the publisher writes
protocol 5 (an 8-byte `remote_insert_lsn` before every message except 'S').
So any data message that reaches the subscriber before 'S' on a v5 link is
misparsed. The output plugin sends 'S' lazily, from two places only. Property:
on every replication connection, the first non-keepalive message the
subscriber handles is 'S', and the version the subscriber then parses with
equals the version the publisher negotiated.

### Code paths

- Publisher negotiation: `pg_decode_startup`, `src/spock_output_plugin.c:320-382`:
  rejects `client_min > 5` or `client_max < 4`; negotiated =
  `Min(5, client_max)`; version 4 requires both sides >= 5.0.0
  (`SPOCK_MIN_VERSION_NUM_FOR_MULTI_PROTO`); `spock_set_proto_version()`.
- Startup message sent only in `pg_decode_begin_txn` (`:593-594`) and in
  `pg_decode_message` for `SPOCK_SYNC_EVENT_MSG` (`:807-808`). The second one
  was added by fdd9587e after a non-transactional sync_event reached a new
  subscription before any BEGIN and "caus[ed] a protocol version mismatch that
  crashes the apply worker" (commit message).
- Other writers that could in principle come first: `pg_decode_change`,
  `pg_decode_truncate` (always after BEGIN), the `'R'` relation message
  (written from change callbacks, after BEGIN), the repair-mode messages (they
  write nothing). Slot-group skipping (`:556-570`) returns before writing.
- Subscriber: `handle_startup_param` sets the version from key
  `proto_version` (`src/spock_apply.c:2429-2448`) and logs
  "using protocol version %u from publisher". A 5.0.x publisher does not send
  `proto_version` (checked with `git show v5.0.9:src/spock_output_config.c`),
  so the default 4 is right for it.
- The publisher-side version is a static per walsender
  (`spock_negotiated_proto_version`, `src/spock_proto_native.c:44`), the
  subscriber-side one is a static per apply/sync process. Both reset with the
  process, so every reconnect renegotiates.

### Why this is a property and not just a past bug

The ordering rule is maintained by hand at each write site. Any new
callback that writes before BEGIN (a future non-transactional message type,
a change to sync_event, logical decoding of a new message kind) silently
reintroduces the fdd9587e crash for v5 links only. The fdd9587e case also
shows the trigger is timing: a sync_event right after slot creation, which
add_node does on purpose (Phase 3 `spock.sync_event(true)` right after
creating a slot; Phase 4/6 sync events).

### Invariant

- SUT-side (missing): in `apply_work()`, keep a per-connection flag
  `startup_seen`, set in `handle_startup`. Before `replication_handler` for any
  'w' message whose action byte is not 'S':
  `Always(startup_seen, "apply parses stream data only after the startup message")`.
  `Always` because this must hold for every message, not just once.
- SUT-side (missing): in `handle_startup_param` for `proto_version`:
  `Always(value == SPOCK_PROTO_VERSION_NUM when the publisher's spock_version_num >= 60000, "6.0 publisher and 6.0 subscriber negotiate protocol 5")`.
  In the single-version topology this pins that negotiation does not fall back
  to 4 (which would still work, but would mean v5-only features such as
  ORIGIN names silently switch off).
- SUT-side `Reachable` at the `pg_decode_message` branch where
  `!startup_message_sent` is true, so the fdd9587e path is known to be
  exercised (it is reached when the first thing a new slot decodes is a
  sync_event).

### Antithesis angle

The reachable trigger is "first decoded item on a fresh walsender is a
non-transactional message". Fresh walsenders happen on every reconnect;
sync_events are issued by the workload's barrier checks and by add_node.
Partitions and restarts make "reconnect, then barrier before any write" a
common interleaving.

### Fault requirements

Network partitions / restarts to force reconnects; workload sync_event calls
during quiet write periods; add_node.

### Original open-question notes (detail for the combined list above)
- Are there other non-transactional logical messages that the plugin writes
  (for example from other extensions using the "Spock" prefix)? Only
  `SPOCK_SYNC_EVENT_MSG` and repair mode were found. If a new one is added it
  must also send 'S' first.
- Is the 6.0 <-> 6.0 negotiation ever expected to pick 4 (for example, a GUC to
  cap the version during upgrades)? No such GUC exists at HEAD
  (`SPOCK_PROTO_VERSION_NUM` is a compile-time constant). If one is added, the
  second assertion must read it.

### Investigation Log

#### Is any legitimate re-delivery below the origin's progress possible?

- Examined: PG18 `snapbuild.c:306`, `decode.c:1296-1300`, `origin.c`
  `replorigin_advance` acquired_by check; `samples/Z0DAN/zodan.sql`
  :2520-2565, :2620-2675; `src/spock_apply.c` progress update in
  `handle_commit` (`remote_commit_lsn = end_lsn`), error path :4095-4130.
- Found: re-sent transactions always start at or above the restart point;
  ZODAN advances both sides to the same end LSN while the origin is unused.
- Not found: any path that resends a transaction whose `commit_lsn` is
  below the origin's `remote_lsn`.
- Conclusion: resolved; keep assertion 6 with `>=`.

#### Is `handle_begin` not resetting `replorigin_session_origin` relied on?

- Examined: every write/read of `replorigin_session_origin` in
  `src/spock_apply.c` (:521, :1123, :1332, :1374, :2322, :2958, :4750).
- Found: readers need only "not Invalid"; ORIGIN always follows BEGIN.
- Conclusion: resolved; not relied on. Assertion 3 uses `remote_origin_id`.

#### Does anything else write a Spock-prefixed non-transactional message?

- Examined: `grep LogLogicalMessage|SPOCK_MESSAGE_PREFIX src include`;
  `pg_decode_message`.
- Found: sync_event (both modes) and repair mode (transactional, never
  written to the wire).
- Conclusion: resolved; no other writer at HEAD.

#### Will a GUC cap the protocol version?

- Examined: `src/spock.c:702-703`, `src/spock_output_config.c:86-151, 539`.
- Found: constants only.
- Conclusion: resolved for HEAD; revisit only if such a GUC is added.
