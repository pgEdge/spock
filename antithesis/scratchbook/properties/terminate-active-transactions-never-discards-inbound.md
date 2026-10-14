# terminate-active-transactions-never-discards-inbound

## What led here

`spock.terminate_active_transactions()` (`sql/spock--6.0.0.sql:862`,
`src/spock_readonly.c:49-81`) is the read-only toolkit's way to kick out
transactions already running when an operator switches `spock.readonly` on.
It is listed in `docs/spock_functions/index.md:56` ("Terminates all active
transactions"). It does not exclude Spock's own workers.

## Mechanism (code-checked against PG 18 source)

- `GetCurrentVirtualXIDs(InvalidTransactionId, false, true, 0, &n)`: every
  backend in every database with a valid virtual xid, which includes an apply
  worker that is in the middle of a remote transaction. An idle apply worker
  has no valid vxid and is skipped.
- PG < 19: `CancelVirtualTransaction(vxid, PROCSIG_RECOVERY_CONFLICT_SNAPSHOT)`.
  PG 19: `SignalRecoveryConflictWithVirtualXID(..., RECOVERY_CONFLICT_SNAPSHOT)`.
- In the target backend (PG18 `src/backend/tcop/postgres.c`,
  `ProcessRecoveryConflictInterrupt`, around lines 3144-3225): in a top-level
  transaction and not reading a command it raises
  `ERROR 40001 "canceling statement due to conflict with recovery"`. Inside a
  subtransaction it falls through to **FATAL** 40001. This does not check
  `RecoveryInProgress()`, so it fires on a primary too.
- Apply classifier (`src/spock_apply.c` PG_CATCH, about lines 3870-3990):
  class 08 / 57P01-03 -> rethrow and restart; 40P01/55P03 -> transient retry;
  class 53 -> transient retry. **40001 is not on the list.** The comment at
  `:3951-3957` admits 40001 "takes the exception path". So:
  - ERROR path -> `AbortOutOfAnyTransaction`, in-process replay
    (`:4065-4110`) -> TRANSDISCARD discards the whole remote transaction, or
    SUB_DISABLE disables the subscription, or DISCARD skips rows;
  - in DISCARD mode the apply worker is inside a subtransaction during row
    apply, so it gets FATAL instead. The worker exits outside the classifier,
    and the shared exception marker may be left behind (sut-analysis L5).
- The provider's walsenders may also be hit if they hold a vxid while decoding.
  That ends in a reconnect, which is transient.

So the documented operator action "set readonly, then terminate active
transactions", run on a node that is still receiving replication, can make
that node permanently drop an inbound transaction. It is recorded in
`exception_log` but never re-sent.

## Failure scenario

1. Workload writes on n1 and n3. n2 applies.
2. Operator on n2: `ALTER SYSTEM SET spock.readonly='local'; SELECT pg_reload_conf(); SELECT spock.terminate_active_transactions();`
3. n2's apply worker for n1 is mid-transaction (between 'B' and 'C') -> 40001
   -> TRANSDISCARD discards that n1 transaction on n2.
4. After quiescence, ledger rows from that n1 transaction are missing on n2.

## Property

Calling `spock.terminate_active_transactions()` on a node never makes that
node discard or skip an inbound replicated transaction. Workload-side
`Always`, checked after quiescence following any call:

- no `spock.exception_log` row on that node whose `error_message` mentions
  "conflict with recovery" / 40001;
- every committed ledger row is present on every node (shared ledger
  oracle);
- no subscription has become disabled.

Exploration helper (SUT-side, **missing**):
`Sometimes(in_remote_transaction, "apply worker received recovery-conflict cancel mid-transaction")`
in the apply worker's PG_CATCH when `sqlerrcode == ERRCODE_T_R_SERIALIZATION_FAILURE`.
It confirms the dangerous interleaving is actually reached.

## Antithesis angle

Whether the cancel lands on an apply worker mid-transaction depends on timing.
Large remote transactions, CPU throttling, and pauses of the provider in the
middle of a transaction (so the apply worker sits inside an open transaction
waiting for data) widen the window. Antithesis explores where the call lands
relative to 'B'/'C' messages, and in DISCARD mode whether it lands inside the
per-row subtransaction (FATAL path).

## Workload boundary note

The workload must not set cluster-wide `default_transaction_isolation` above
READ COMMITTED (another 40001 source, admitted). With that rule kept, any
40001 in `exception_log` comes from this cancel path.

## Confidence

High on the mechanism. Medium on whether the maintainers think calling it with
replication running is supported. The docs pair it with readonly and do not
warn about it.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW1/CW2, implementability CW6 and property finding); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: test command calling the function during apply; CPU modulation

- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
- Evaluation note (2026-10-13): the function also cancels the workload's own client sessions on that node; client 57014 errors after a call are unknown-outcome commits, resolved through the marker row like lost connections. Runs in the classifier template with the cancel commands.
- "No `exception_log` row at all" changed to "none outside the expected-exception registry".

## Open questions

- Is `terminate_active_transactions()` meant to skip Spock's own workers? If
  yes, this is a bug with an easy fix (skip procs whose `backendType` is a
  bgworker or that belong to a spock worker). If no, the docs should warn, and
  the workload should call it only on nodes with `readonly=all` already
  observed (then the apply worker is not in a transaction).
  `(needs human input)` — see the log: the docs say `local` mode keeps inbound
  replication running, and the code excludes only the caller's own backend.

## Resolved

- **Walsenders hit by the same call do not cause partial apply.** A logical
  walsender that holds a vxid while decoding gets ERROR (or FATAL in a
  subtransaction) and exits. The subscriber only commits on a 'C' message,
  so a cut stream leaves the remote transaction open; `PQgetCopyData` then
  fails with `ERRCODE_CONNECTION_FAILURE`, which the classifier retries
  (`src/spock_apply.c:3916-3940`). No property change.
- **FATAL reach is wider than DISCARD mode.** Apply also opens a
  subtransaction for every delta-apply update (`BeginInternalSubTransaction("SpockDeltaApply")`,
  `src/spock_apply_heap.c:722`) in all modes, and for every row in DISCARD
  replay (`src/spock_apply.c:1661, 1835, 1968, 2192, 2795`). A signal landing
  there gives FATAL 40001 (PG18 `postgres.c:3155-3230`, fall-through to the
  session-cancel FATAL). That exit skips `PG_CATCH`, leaves the shmem marker
  set, and the resent transaction is then replayed under the policy (see
  `exception-replay-only-after-recorded-error`). So the property's oracle
  (exception_log rows / missing ledger rows) catches both the ERROR and the
  FATAL outcome; the exception_log row for the FATAL case will carry an
  empty or unrelated initial error rather than "conflict with recovery".
  Widen the workload-side match: any `exception_log` row on that node after a
  `terminate_active_transactions()` call in a conflict-free run is a
  violation, not only rows mentioning 40001.

### Investigation Log

#### Does the cancel raise ERROR or FATAL in the apply worker on a primary?
- Examined: PG 18.3 tree `~/dev/pgedge/postgresql/src/backend/tcop/postgres.c:3100-3240`, `procsignal.c:700-720`.
- Found: SNAPSHOT reason -> ERROR 40001 at top level (not in DoingCommandRead), FATAL inside a subtransaction; no recovery-in-progress guard.
- Conclusion: settled.

#### Is terminate_active_transactions() meant to skip Spock's own workers?

- Examined: `src/spock_readonly.c:49-81` (whole function),
  `GetCurrentVirtualXIDs` in PG18 `procarray.c` (skips only `MyProc`),
  `docs/managing/read_only.md` (all of it), `docs/spock_functions/index.md:56`,
  `docs/limitations.md:289-301`, `git log -S terminate_active_transactions`
  (origin: commit 14d21c48 "Initial port of pg_readonly to spock extension").
- Found: no filter on backend type; only the caller is skipped. The function
  came from pg_readonly, a single-node tool where there are no apply workers.
  `read_only.md` says `local` mode lets "inbound replication continue
  normally", which this function breaks if called in that mode. No doc pairs
  the function with any mode or warns about it.
- Not found: any statement of intent about Spock workers.
- Conclusion: `(needs human input)`. The origin (port of a single-node tool)
  suggests the worker case was never considered, but that is inference.

#### Does a recovery-conflict cancel on a walsender leave a partly sent transaction the subscriber treats as complete?

- Examined: PG18 `postgres.c:3140-3230`; Spock `src/spock_apply.c:3640-3680`
  (stream read errors) and `:3916-3940` (connection-class retry),
  `handle_commit` (only commit point).
- Found: the walsender errors out and closes the stream; the subscriber sees
  a connection error and retries. Commit happens only on 'C'.
- Conclusion: resolved, no.
