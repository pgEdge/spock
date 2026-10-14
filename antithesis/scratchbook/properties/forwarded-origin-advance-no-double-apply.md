# forwarded-origin-advance-no-double-apply

## What the property says

In a cascade configuration (node C subscribes to B with
`forward_origins = '{all}'`, and C also has a **disabled** direct
subscription to A), when the direct A->C subscription is later enabled
(replacing the forwarding one), every A transaction already applied on C
through B is not applied again, and every A transaction not yet applied is
applied once.

This is out of the v1 mesh topology (sut-analysis §12 forbids
`forward_origins` inside a mesh). It needs a separate cascade test template.

## Why it matters

Commit 401197ab added `maybe_advance_forwarded_origin()` so the pre-created
direct subscription can start "from the right position whenever it is
enabled, instead of a full resync". Its comment
(`src/spock_apply.c:5150-5165`) admits: "a crash may lose the latest advance
and cause one transaction to be replayed, preserving at-least-once semantics.
last_update_wins handles the duplicate; delta-apply idempotency is tracked
separately." No such tracking exists in the tree. So the known gap is
delta-apply double counting (and plain-row resurrection, see
`causally-deleted-row-stays-deleted`).

## Code paths (code-checked)

- `handle_origin` -> `resolve_forwarded_origin_for_transaction`
  (`src/spock_apply.c:1301-1360`): for a forwarded transaction (origin node
  != direct provider), find the single local subscription whose provider is
  that origin and remember its origin id.
- `handle_commit`: `CommitTransactionCommand()` at `:1058`, then
  `maybe_advance_forwarded_origin(local_commit_lsn, xact_had_exception)` at
  `:1137` -> `replorigin_advance(forwarded_local_origin_id, remote_origin_lsn,
  local_lsn, go_backward=false, wal_log=true)` (`:5167-5183`). A **separate**
  WAL record after the data commit.
- Crash between the commit record and the advance record: the forwarded
  origin stays behind; when the direct subscription is enabled, A re-sends
  that transaction. Also, as in L1, the commit record itself carries the
  origin node id, so crash redo of the commit does not advance the
  subscription's slot-named origin either.
- Not advanced when `xact_had_exception` (DISCARD/TRANSDISCARD with a failed
  row): the direct subscription later re-delivers it, which applies a
  transaction the forwarding path dropped. That is arguably correct; record
  it rather than flag it.
- 2948d567: if the direct subscription's worker is running, `replorigin_advance`
  raises `ERRCODE_OBJECT_IN_USE`. `enforce_forwarding_exclusivity()`
  (`src/spock_functions.c:488`) checks catalog state, not running workers. The
  error is raised **after** the commit and leads into
  `exception-replay-never-reruns-committed-transaction`.

## Workload design (cascade template)

- Nodes A, B, C. A and B in a mesh; C subscribes to B with
  `forward_origins='{all}'`; C has `sub_A_C` created **disabled**.
- Writers on A: ledger inserts and delta-counter increments.
- Faults: kill -9 C's postmaster at random; partitions B<->C.
- Switch: disable the forwarding subscription (or clear its
  `forward_origins`), then enable `sub_A_C` (and a direct B subscription if
  needed), quiesce, barrier. Order matters: `enforce_forwarding_exclusivity()`
  (`src/spock_functions.c:487-534`) rejects enabling any subscription while
  another enabled one has forwarding active, and rejects activating
  forwarding while any other subscription is enabled. A forwarding
  subscription must be the only enabled one on C.
- Check: `AlwaysOrUnreachable` on C after the switch: delta counters equal
  committed increments and each ledger row has one apply-audit row.

## Assertion choice (revised in the investigation pass)

The original claim "not applied again" contradicts the documented
at-least-once design (see findings), so the check is split. All are
`AlwaysOrUnreachable` (they run only in runs that reach the switch):

1. "no A transaction missing on C after switching to the direct
   subscription": every committed A ledger row / increment is present on C.
2. "duplicates on C bounded by C crashes": per A transaction, extra applies
   on C <= number of C crashes that happened while the forwarding path was
   active (the design allows at most one replayed transaction per crash).
3. "no duplicates without a crash": in runs with no C crash before the
   switch, zero duplicates.

Message 2 is the documented limit; a failure of 3, or of 2 by more than one
per crash, is a bug. Caveat: L1 (`crash-redo-leaves-no-node-id-origin-state`)
can also make B re-send transactions to C after a C crash, through the
forwarding subscription, not the direct one. Those duplicates would hit
message 2 too. The workload must attribute duplicates (the apply-audit row
should record which subscription applied it) or count only those applied by
`sub_A_C`.

## SUT-side instrumentation (missing; no existing assertions)

- `Reachable("forwarded origin advanced for a pre-created subscription")` at
  the `replorigin_advance` call in `maybe_advance_forwarded_origin`, so the
  template proves the path ran.

## Findings from the investigation pass (2026-10-13)

- **This is a documented, supported user flow, not only an add-node
  helper.** `docs/spock_functions/sub_mgmt.md:101-131` ("Origin Forwarding")
  describes "a subscription to that peer created disabled ahead of time, so
  it can later start from the right position instead of a full resync",
  and the v6.0 release notes (`docs/spock_release_notes.md:163-176`) list
  cascade origin tracking. TAP `tests/tap/t/015_forward_origin_advance.pl`
  tests exactly this flow. ZODAN does not use it (`forward_origins` is
  empty throughout `samples/Z0DAN/zodan.sql` and the ZODAN tutorial).
  Priority stays as catalogued for a separate cascade template; it is not
  part of the v1 mesh.
- **The advance cannot be made atomic with the data commit using
  PostgreSQL's origin API, and the replay is a stated design limit.**
  `replorigin_advance(..., wal_log=true)` writes a standalone
  `XLOG_REPLORIGIN_SET` record that redo applies regardless of any
  transaction (PG18 `origin.c:850-870`), and a commit record carries only
  one origin id (the session origin). Writing the advance before the commit
  would turn the crash window into a lost transaction. Writing it after,
  as the code does (`handle_commit` `:1058` then `:1137`), gives at most one
  replayed transaction per crash: the same apply worker writes each commit
  record and then its advance record, and WAL is flushed in order, so only
  the newest commit can be durable without its advance. Commit 401197ab's
  message says so ("a crash may replay the latest transaction, preserving
  at-least-once semantics; delta-apply idempotency remains a separate
  follow-up"); the code comment at `src/spock_apply.c:5150-5163` matches.
  The invariant is revised above accordingly.

## Open questions

- None remaining from discovery. (Whether the one-transaction replay on
  delta columns should be fixed is a design follow-up the authors already
  named; the property now treats it as the documented limit.)

### Investigation Log

#### Is the cascade + later direct subscription a supported production flow, or only an add-node helper?

- Examined: `git show 401197ab`, `docs/spock_functions/sub_mgmt.md`,
  `docs/spock_release_notes.md`, `docs/spock_functions/functions/spock_sub_create.md`,
  `samples/Z0DAN/zodan.sql`, `docs/modify/zodan/zodan_tutorial.md`,
  `tests/tap/t/015_forward_origin_advance.pl`, `018_forward_origins.pl`.
- Found: user-facing docs describe the pre-created disabled subscription
  flow; ZODAN never uses forwarding.
- Conclusion: resolved: supported user flow (previously tagged needs human
  input; the docs answer it).

#### Should the advance be written in the same transaction as the data?

- Examined: `maybe_advance_forwarded_origin` (`src/spock_apply.c:5150-5183`),
  `handle_commit`, PG18 `origin.c` (`replorigin_advance`, `replorigin_redo`),
  PG18 `xact.c` commit record origin handling (via the L1 evidence file),
  commit 401197ab message.
- Found: not possible with the core API without risking loss; the authors
  chose at-least-once on purpose and named delta idempotency as follow-up.
- Conclusion: resolved: known limit, not a bug. Invariant split into
  "nothing missing" / "duplicates <= C crashes" / "no duplicates without a
  crash".
