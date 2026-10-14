# readonly-all-never-commits-remote-txn — No remote transaction commits while readonly=all is in effect

## Synthesis note

Merged from `readonly-all-never-commits-remote-txn` (F8) and
`readonly-all-blocks-apply-commit` (F6). Same SUT-side check:
`AlwaysOrUnreachable(spock_readonly != READONLY_ALL)` just before
`CommitTransactionCommand()` in `handle_commit`. F8 adds a separate message for
the sync worker's COPY commit and a workload cross-check (remote-origin ledger
rows stop growing after a settle time). F6 found the concrete path that can
reach the commit with the value set: a config reload inside
`wait_for_previous_transaction` (called from `handle_commit`, `handle_sql`,
`handle_relation` after the per-message check), mostly reachable with slot
groups. Both chose `AlwaysOrUnreachable`; no conflict.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (assertion type vs v1), implementability); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v2/slot-groups (unreachable in v1) · Faults: readonly toggles, thread pause

- Moved to `v2/slot-groups`: without slot groups `required_commit_ts` is 0 and `wait_for_previous_transaction` breaks out on its first check with no `CHECK_FOR_INTERRUPTS` or `ProcessConfigFile` call (`src/spock_apply.c:301-312`), so a reload cannot land there. Added companion `Sometimes("handle_commit reached with spock.readonly=all")` so a vacuous pass is visible.

## Open questions

- Is committing the one remote transaction already in flight when the worker observes `all` acceptable? `(needs human input)`
- Is the sync worker's COPY (initial or table sync) meant to be blocked by readonly=all? `(needs human input)`

Resolved (see Investigation Log): the readonly FATAL in `replication_handler`
is unreachable at HEAD, so it is a guard only. The single path by which a
remote transaction commits after the worker has the value is the reload
inside `wait_for_previous_transaction`.

## Notes from investigation that change the instrumentation

- The **sync-worker COPY assertion** ("sync worker committed COPY while
  spock.readonly=all") should be left out until the second question is
  answered. At HEAD, a COPY session whose user is a superuser is exempt by
  design (`e1aa238f`; docs: "Superusers may still perform write
  operations"). The resync comment that says COPY FROM "is blocked"
  predates that change. If the harness DSN user is a superuser, the
  assertion would fire on behaviour the docs allow.
- The docs' description of `all` mode ("each worker raises a FATAL and
  exits, and the manager restarts it once read-only is cleared") is stale.
  The worker `break`s and stays connected. The `AlwaysOrUnreachable` at
  `handle_commit` is the right check either way.
- The workload cross-check (remote-origin ledger rows stop growing after a
  settle time) stays valid. A transaction left open across the `break` is
  aborted at the next idle-timeout or connection error, not committed.

## Source: `readonly-all-never-commits-remote-txn` (F8 Lifecycle)

### Why this property

Spock claims (`docs/managing/read_only.md:5-9, 73-83`, S8) that
`spock.readonly = all` stops the apply workers as well as non-superuser
sessions, and that "replication resumes from where it left off, provided the
upstream replication slot still retains the necessary WAL".

How it is implemented (code-checked):

- GUC `spock.readonly` is `PGC_SUSET` (`src/spock.c:1421-1428`); apply workers
  see a change only after SIGHUP + `ProcessConfigFile` in their loops
  (`src/spock_apply.c:3503`, `:3600`, and `:316` in
  `wait_for_previous_transaction`).
- Inner loop (`:3610-3631`): if `READONLY_ALL`, `break` before reading the
  next message; if `xact_had_exception`, wait 1 s and `continue` instead.
  A remote transaction can be left open (locks held) across the break.
- `replication_handler` (`:2981-2983`) FATALs if a message is handled in
  readonly=all. As noted in `exception-replay-only-after-recorded-error`, this
  looks unreachable with default slot names because no reload happens between
  the loop check and the handler.
- Local sessions: `spock_ropost_parse_analyze` / `spock_roExecutorStart`
  (`src/spock_readonly.c:82-140`) set `XactReadOnly` only for
  **non-superusers**. Superuser sessions keep writing. The workload must write
  through a non-superuser role to test the local part.
- Table resync is refused in readonly (`check_readonly_for_resync`,
  `src/spock_functions.c:~1241-1260`), but initial sync / sync workers in
  CATCHUP go through `apply_work` and the same loop check; COPY in the sync
  worker runs as superuser and is not blocked by the hooks.

Mid-transaction state: an apply worker that stopped mid-transaction keeps
locks on rows the remote transaction touched until `apply_idle_timeout`
(nothing is read, so `last_receive_timestamp` stops) raises a connection-class
error, aborts, clears the marker and restarts; the new worker breaks again
before its first message.

### Invariant and assertions

- SUT-side (missing, no existing assertions):
  `AlwaysOrUnreachable(spock_readonly != READONLY_ALL)` with message
  "apply committed a remote transaction while spock.readonly=all", immediately
  before `CommitTransactionCommand()` in `handle_commit()`. AlwaysOrUnreachable
  because the commit path is reached constantly, but the property only says
  something when readonly=all is in effect in that process; the check must
  hold on every evaluation. The same check, with its own message
  ("sync worker committed COPY while spock.readonly=all"), in the sync worker's
  COPY commit path, because initial sync is not obviously covered by the loop
  check.
- Workload cross-check: after `ALTER SYSTEM SET spock.readonly='all'` +
  `pg_reload_conf()` and a settle time of a few seconds, the count of ledger
  rows from other origins on that node does not grow while readonly is on
  (Always). The settle time makes this weaker than the SUT check; keep both.
- Workload (Always): non-superuser INSERT on the readonly node fails with
  25006 while readonly is `local` or `all`.

### Antithesis angle

Toggle readonly at random times relative to remote transactions (inside a
large one, during an exception replay in the conflict variant, during
add_node's initial sync on n4, during a table resync's CATCHUP).

### Fault requirements

None beyond timing; partitions and pauses add the "idle timeout while
readonly" path.

### Original open-question notes (detail for the combined list above)
- Is initial sync (COPY into n4) meant to be blocked by readonly=all? Docs
  talk about apply only. If not, the sync-worker assertion should be dropped.
- Is the readonly FATAL in `replication_handler` reachable at all in the
  default config? Code reading says no; if it is reachable it leaves a stale
  exception marker (L5).

## Source: `readonly-all-blocks-apply-commit` (F6 Security)

### Claim being tested

`docs/managing/read_only.md:9`: in `all` mode "Non-superuser local sessions
and apply workers are blocked from writing." `src/spock_readonly.c:6-8`: "In
the 'ALL' mode it prevents the database from being modified by spock apply
workers as well."

### Mechanism (code-checked)

The apply worker checks its in-process `spock_readonly` value at two places:
- at the loop top, right after `ProcessConfigFile` (`src/spock_apply.c:3600-3630`);
- at the start of every message in `replication_handler` (`:2981`). This is FATAL.

However, `wait_for_previous_transaction()` (`:295-337`) also calls
`ProcessConfigFile` while it waits. It is called:
- from `handle_commit` (`:936`), after the per-message check for 'C' and
  before `CommitTransactionCommand()`;
- from `handle_sql` (`:2770`), before queued DDL runs;
- from `handle_relation` (`:1404`).

If a reload arrives while the worker waits there (it waits only when
`required_commit_ts` from the 'L' message differs from the group's
`prev_remote_ts`: slot groups, or a missed predecessor, see L10/L30), the
worker picks up `READONLY_ALL` and then commits the remote transaction, or runs
the queued DDL, anyway.

Sync workers: the COPY session is a separate libpq backend. If its user is a
superuser, the readonly hooks never block it (see
`readonly-toggle-resumes-without-loss`).

### Property

Once an apply worker's own `spock_readonly` value is `all`, it does not commit
a remote transaction. SUT-side **AlwaysOrUnreachable** (missing), placed in
`handle_commit` just before `CommitTransactionCommand()`:

```
AlwaysOrUnreachable(spock_readonly != READONLY_ALL,
  "apply worker never commits a remote transaction while its readonly=all is in effect")
```

`AlwaysOrUnreachable` because, as long as the per-message FATAL works, commit
should never be reached with the value set. The assertion only reports if
some path, such as a reload inside a wait, gets there.

A workload-side check is weaker: after `pg_reload_conf()` plus a settle delay
longer than one message cycle (or `pg_stat_activity` showing the apply backend
has restarted), `pg_replication_origin_status.remote_lsn` for every origin on
that node does not advance while `all` holds. It cannot see exactly when the
worker noticed the change, so it needs a settle delay. Use the SUT-side
assertion as the main check.

### Antithesis angle

The window is a reload landing while the worker is blocked in
`wait_for_previous_transaction`. It needs slot groups or an ordering wait. The
standard topology rarely reaches it (no `_<digit>` names). A second
configuration with slot-group names (deployment-topology Open Questions) makes
it reachable. Thread pausing and CPU throttling stretch the wait.

### Confidence

Medium-low that it fires in the default topology. Medium that it is reachable
with slot groups. Whether committing the one transaction that was already in
flight counts as a violation needs a human answer.

### Original open-question notes (detail for the combined list above)
- Is it acceptable for the one in-flight remote transaction to commit after the
  worker observed `all`? If yes, change the assertion to "no remote
  transaction whose BEGIN was processed after the worker observed `all`
  commits", which the FATAL in `replication_handler` already guarantees. Then
  this property only guards against regressions. `(needs human input)`
- Should the sync worker's COPY count as an "apply worker write"? If yes, add a
  matching assertion in `copy_table_data` before `PQputCopyEnd`.

### Investigation Log

_Entries carried over from `readonly-all-blocks-apply-commit`:_

#### Can the in-process readonly value change between the per-message check and commit?
- Examined: `src/spock_apply.c` every `ProcessConfigFile` call (`:316-320`, `:3503-3507`, `:3600-3604`), callers of `wait_for_previous_transaction` (`:936`, `:1404`, `:2770`).
- Found: yes, through `wait_for_previous_transaction` when it actually waits.
- Not found: whether the wait happens in a plain 3-node mesh with no slot groups. `prev_remote_ts` is described as "seems do nothing at the moment" (`include/spock_group.h:100`).
- Conclusion: reachable at least with slot groups. Whether it matters needs a human answer.

_Investigation pass (G4, HEAD 69d9228f):_

#### Is the readonly FATAL in `replication_handler` reachable at all with default slot names?

- Examined: every `ProcessConfigFile` call in the apply worker
  (`src/spock_apply.c:319`, `:3506`, `:3603`; no others in `src/` reach
  the apply path; `spock_failover_slots.c` is a separate worker), the inner
  loop's `continue` / `break` paths (`:3590-3800`), the replay branch
  (`apply_replay_mode` is checked after the readonly test).
- Found: each message, whether streamed or replayed, is handled only after
  the loop-top check at `:3610`, which follows the last possible reload in
  that iteration. A reload inside `wait_for_previous_transaction` happens in
  the middle of handling message N; message N+1 then hits the loop-top check
  and `break`s. So `spock_readonly == READONLY_ALL` is never true on entry
  to `replication_handler`, with or without slot groups.
- Conclusion: resolved: unreachable at HEAD. It is a guard only. (If a
  future change made it reachable, it would leave the exception marker
  behind, L5.)

#### Is the sync worker's COPY meant to be blocked by readonly=all?

- Examined: `src/spock_functions.c:1236-1265`, `git show 7d21b807`
  (2026-03-03), `git show e1aa238f` (2026-03-04), `src/spock_sync.c:1269-1273,
  1402` (COPY through `target_if->dsn`), `docs/managing/read_only.md`.
- Found: the "is blocked" comment was correct for the pre-rework hooks
  (which blocked every role) and has been stale since the next day. At HEAD
  a superuser DSN user's COPY passes. The docs exempt superusers and do not
  mention sync. A sync worker's catch-up phase runs `apply_work` and stops
  at the loop-top check like apply.
- Conclusion: `(needs human input)`. Instrumentation note above: leave the
  sync COPY assertion out for now.

#### Is committing the one in-flight remote transaction acceptable?

- Examined: `docs/managing/read_only.md` (both the table and "Behavior of
  `all` mode"), `src/spock_readonly.c:6-8`, `include/spock_readonly.h`,
  `tests/regress/sql/read_only.sql:270-300`.
- Found: the docs say workers "stop consuming inbound WAL" and (stale)
  "raise a FATAL". Neither says what happens to a transaction whose BEGIN was
  already processed. The regression test checks only that the slot does not
  advance afterwards.
- Conclusion: still `(needs human input)`. Code facts: the commit can only
  happen through the reload inside `wait_for_previous_transaction`, which
  waits only when `required_commit_ts` differs from the group's
  `prev_remote_ts` (slot groups or a missed predecessor, L10/L30).
