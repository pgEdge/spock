# no-change-applied-on-its-origin-node

## What the property says

In a default full mesh (`forward_origins='{}'` on every subscription), a
change that originated on node N is never applied back onto N by an apply
worker, and is applied on each other node by exactly the subscription that
points at N (not relayed through a third node).

## Claimed guarantee

- `pg_decode_origin_filter` (`src/spock_output_plugin.c:1201-1222`): "Never
  filter out locally originated tx's"; any transaction with a non-invalid
  origin is filtered unless `forward_origins` is non-empty (all or nothing).
- Apply-side writes carry an origin: worker start sets the slot-named origin
  (`src/spock_apply.c:4749-4750`); every ORIGIN message then switches
  `replorigin_session_origin` to the real origin node id
  (`handle_origin`, `:1331-1332`). Initial COPY sessions set the subscription
  origin too (`src/spock_sync.c:~938-948`).
- The provider writes its own node id in the ORIGIN message for local
  transactions and the stored origin for forwarded ones
  (`pg_decode_begin_txn`, `src/spock_output_plugin.c:611-633`).

So, as long as every apply write commits with a non-invalid origin and node ids
are not 0, echo cannot happen. This is sut-analysis S6.

## How it could break

- **Node id 0 or 65535 (L24)**: `node_id = hash_any(name) & 0xffff` is
  checked for collisions with existing nodes but not against 0
  (`InvalidRepOriginId`) or 65535 (`DoNotReplicateId`)
  (`src/spock_node.c:367-383`); `node_create` takes no explicit id
  (`sql/spock--6.0.0.sql:219-222`). Code-checked effects (PG18 `xact.c`):
  - id 0: `handle_origin` sets `replorigin_session_origin = 0`, so the apply
    commit record has no origin (`xact.c:5940`). Every receiving peer's
    walsender treats the applied change as local and re-sends it, stamped
    with the peer's own id (`pg_decode_begin_txn`,
    `src/spock_output_plugin.c:611-633`), to all its subscribers, including
    the origin node: one extra hop per receiving peer (the re-sent copy
    carries a non-zero origin, so it stops there), i.e. an echo onto N. Also
    `RecordTransactionCommit` skips the in-memory origin advance
    (`xact.c:1431-1468`), so the subscription from that node never shows
    progress and `wait_for_sync_event` from it should never finish.
  - id 65535: the commit record carries origin 65535, so no echo, but the same
    advance skip applies (`xact.c:1431-1432`; Spock's own explicit advances
    skip it too, `src/spock_apply.c:1123, 2958`): no progress, barriers hang,
    redelivery after any restart.
- **Apply-process writes after the origin is reset**:
  `spock_apply_worker_shmem_exit` sets `replorigin_session_origin =
  InvalidRepOriginId` (`src/spock_apply.c:2322`) before
  `ShutdownPostgres` aborts. If any path committed (rather than aborted) after
  that reset, the write would look local. Today the comment says only an abort
  follows.
- **Origin id / roident overlap**: node ids share the 16-bit space with the
  local `pg_replication_origin` roidents (`src/spock_conflict.c:400` compares
  them). Not an echo by itself, but makes the "which origin is this" checks
  ambiguous, and with L1 crash redo advances the origin whose roident equals
  the node id (see `ledger-row-applied-exactly-once-per-peer` log).
- **`forward_origins` misuse**: a non-empty value forwards every origin;
  `enforce_forwarding_exclusivity()` (`src/spock_functions.c:470-532`) allows
  it only as the single enabled sub. Out of v1 scope (workload boundaries),
  so any forwarded transaction in v1 is itself a finding.

## Oracle design

Workload side (reuse the `apply_audit` trigger table from
`ledger-row-applied-exactly-once-per-peer`):
- `Always(no apply_audit row on node N has origin_node == N)` at every check.
  This can be checked during the run, not only at quiescence.
- `Always(for every applied ledger row on S, pg_xact_commit_timestamp_origin(xmin).roident
  equals the spock node id of origin_node)` for rows not overwritten since.
  This catches an echo or relay that stamps the wrong origin.

SUT side (missing; no Antithesis assertions exist):
- In `handle_origin` after reading the id:
  `Unreachable("apply received a transaction whose origin is this node")` when
  `remote_origin_id == local node id`.
- Same place: `Unreachable("apply received origin id 0 or 65535")`.
- In `pg_decode_begin_txn` on the provider, when `forward_origins` is empty:
  `Unreachable("walsender sent a transaction with a non-local origin while
  forward_origins is empty")` (that path should be filtered before begin).

`Unreachable`/`Always` fit: echo must never happen.

## Fault requirements

None beyond normal running; restarts and reconnects exercise worker start and
exit paths (origin set and reset). Node names that hash to 0 or 65535 can be a
targeted config variant: `hashtext(name::text) & 65535` gives Spock's id
under a deterministic collation (PG18 `hashtext` calls the same `hash_any`
over the same bytes, `hashfunc.c:285-288`), so the harness can search for such
names offline. Do this only if the team says these ids should be rejected (see
Open Questions); otherwise the harness must avoid them, and the default
template should assert at setup that no node id is 0 or 65535.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (TAP territory), implementability (audit trigger)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P3 · Topology: v1 · Faults: worker restarts

- Priority note: lowered from P2 in evaluation: in v1 the real failure (node id 0 or 65535) is a configuration the harness avoids, so the id check is a setup assertion plus a small TAP test for ids 0/65535; the runtime checks stay as cheap guards.
- Evaluation note (2026-10-13): the "no apply_audit row on N has origin_node = N" check depends on the audit trigger being `ENABLE REPLICA` (see `ledger-row-applied-exactly-once-per-peer`); with `ENABLE ALWAYS` it would fire on every local write.

## Open questions

- Should node creation reject ids 0 and 65535? `(needs human input)` The code effects are confirmed (echo for 0; no origin progress and redelivery for both); only whether the team counts a name that hashes there as a supported config is open.

Resolved (see Investigation Log): an ORIGIN-less transaction cannot reach a
Spock apply worker. The native protocol always sends ORIGIN, in v5 and v6, and
Spock subscribers never ask for the json protocol.

### Investigation Log

#### Should node creation reject ids 0 and 65535?

- Examined: `create_node`, `src/spock_node.c:355-385` (hash, collision check,
  no 0/65535 check); `sql/spock--6.0.0.sql:219-222` (no id argument);
  PG18 `xact.c:1431-1468`, `:5940`; `xloginsert.c:842-846`;
  `pg_decode_origin_filter` `src/spock_output_plugin.c:1201-1222`;
  `pg_decode_begin_txn` `:600-633`; `src/spock_apply.c:1123, 2958`;
  `git log -S` for a rejection (none).
- Found: effects as listed under "How it could break". The odds are 2 in
  65536 per node name.
- Not found: any statement of intent in docs or commits.
- Conclusion: `(needs human input)` for intent; effects resolved.

#### Can the apply worker receive a transaction without an ORIGIN message?

- Examined: `pg_decode_begin_txn` `src/spock_output_plugin.c:520-633`
  (`send_replication_origin = data->forward_changeset_origins`, set to true
  unconditionally at startup, `:501`); `spock_init_api`
  `src/spock_output_proto.c:20-50` (`write_origin` is NULL only for json);
  subscriber `START_REPLICATION` options `src/spock.c:694-715` (no
  `proto_format`, so native); the v5_STABLE output plugin (same unconditional
  origin; only PG 9.4 turned it off).
- Found: every native-protocol BEGIN from a v5 or v6 provider is followed by
  ORIGIN, with the provider's own id for local transactions.
- Conclusion: resolved. The stale-`replorigin_session_origin` path
  (`handle_begin` resets only `remote_origin_id`) is not reachable between
  Spock nodes. No change to the property.
