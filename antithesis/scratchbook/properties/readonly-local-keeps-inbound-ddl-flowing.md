# readonly-local-keeps-inbound-ddl-flowing

## Claim being tested

`docs/managing/read_only.md:8` (and `include/spock_readonly.h:15`) says that in
`spock.readonly = local` mode "Replicated writes from apply workers are still
permitted, so inbound replication continues normally." This is sut-analysis S8.

## Mechanism (code-checked)

- The read-only mode works by forcing `XactReadOnly = true` from two hooks
  whenever `spock_readonly >= READONLY_LOCAL && !superuser()`:
  `spock_ropost_parse_analyze` (`src/spock_readonly.c:96`) and
  `spock_roExecutorStart` (`src/spock_readonly.c:123`). Both are installed
  globally (`src/spock_executor.c:337-347`) so they also run inside the apply
  worker.
- `superuser()` checks `GetUserId()`, the *current* user, not the session user.
- The apply worker is the bootstrap superuser, and plain DML apply goes through
  `ExecSimpleRelation*` (no ExecutorStart), so ordinary row changes are not
  affected.
- Queued SQL (AutoDDL and `spock.replicate_ddl()`) is different. On the
  subscriber, `handle_sql` -> `spock_execute_sql_command`
  (`src/spock_apply.c:4285`) switches identity to the role recorded in the
  `spock.queue` row: `SetUserIdAndSecContext(get_role_oid(role, false), ...)`
  (`src/spock_apply.c:4342-4344`), then calls `pg_analyze_and_rewrite`
  (`:4361`). That runs `post_parse_analyze_hook` with the recorded role as the
  current user. If that role is not a superuser, the hook sets
  `XactReadOnly = true`.
- The DDL then hits PostgreSQL's `PreventCommandIfReadOnly` and fails with
  SQLSTATE 25006 ("cannot execute CREATE TABLE in a read-only transaction").
- 25006 is not on the classifier's transient list (`src/spock_apply.c:3912-3975`:
  class 08 / 57P0x, 40P01, 55P03, class 53 only). So it takes the replay path:
  - under the default TRANSDISCARD the whole remote transaction (the DDL and
    anything else in it) is discarded and logged in `spock.exception_log`;
  - under SUB_DISABLE the subscription is disabled;
  - under DISCARD the DDL statement is skipped.
- The discarded DDL is not retried when readonly goes back to `off`. The
  schema is now different on that node, and later DML for the new or altered
  table fails too (for example "unknown column name",
  `src/spock_relcache.c:398`), so the losses keep growing.
- The role recorded in the queue is the origin's `GetUserId()` for AutoDDL
  (`spock_autoddl.c` -> `spock_auto_replicate_ddl(..., roleoid, ...)`) and the
  `role` argument for `replicate_ddl` (default `CURRENT_USER`,
  `sql/spock--6.0.0.sql:609`). In real deployments application roles that own
  their schema are usually not superusers.

A second, rarer route: an `ENABLE ALWAYS` / `ENABLE REPLICA` trigger whose
function is `SECURITY DEFINER` and owned by a non-superuser. Its statements run
as the owner, the hook sets `XactReadOnly`, and the trigger's own writes fail.

## Failure scenario

1. n1, n2, n3 replicating, no readonly.
2. Operator sets `spock.readonly = local` on n2 (ALTER SYSTEM + reload), for
   example to stop application writes during maintenance.
3. On n1 a non-superuser role (owner of the app schema) runs
   `spock.replicate_ddl('ALTER TABLE app.t ADD COLUMN c int')` during a
   quiet DDL phase.
4. n2's apply worker runs the queued SQL as that role, the hook makes the
   transaction read-only, and ALTER fails with 25006 -> TRANSDISCARD -> discarded.
5. n2 lacks the column. When readonly goes back to `off`, nothing re-sends the DDL.
   Later inserts with column `c` from n1 or n3 fail on n2 and are discarded.

## Property

While a subscriber is in `readonly=local`, every inbound replicated
transaction, including queued DDL issued by a non-superuser role, commits on
it. Workload check (Always): after the quiet period that follows a phase in
which some node was in `local` mode, (a) `spock.exception_log` on that node has
no row whose error message has SQLSTATE 25006 / "read-only transaction", and
(b) catalog checks (columns of the test tables) and ledger rows match on all
nodes.

Possible SUT-side assertion (missing; no Antithesis instrumentation exists):
in `spock_execute_sql_command`, after the hook would run,
`Always(!(XactReadOnly && spock_readonly == READONLY_LOCAL && in apply worker && !MyApplyWorker->use_try_block),
"queued SQL in apply never made read-only by readonly=local")`.

## Antithesis angle

This is mostly a fixed-order bug: it fires every time the DDL issuer is a
non-superuser and the subscriber is in `local` mode. A TAP test would catch it
more cheaply than Antithesis. Antithesis adds:
- the timing between the readonly reload, which an apply worker only sees at a
  message boundary (`src/spock_apply.c:3600-3604`) or while waiting in
  `wait_for_previous_transaction` (`:316-320`), and the arrival of the DDL;
- worker restarts, which reload the GUC at startup;
- mixing it with the other exception modes.

The workload must issue at least some DDL as a non-superuser role (the
workload boundaries already keep DDL to quiet phases, and that still applies).

## Confidence

High that the mechanism is real (each step was checked in the code, and in
the PG18 source for `PreventCommandIfReadOnly` / 25006). Medium that the
maintainers would call it a bug rather than a doc gap. The docs promise
"continues normally", so the claim as written is broken either way.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW1 and property finding, wildcard W2, implementability CW7); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 (workload must issue DDL as a non-superuser role) · Faults: none required; readonly toggles, worker restarts

- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
- Evaluation note (2026-10-13): until a fix is in the image, readonly=local phases in the main template use superuser DDL or no DDL; this property runs in its own template. After a fix it stays as a P3 regression guard (the reload-vs-DDL-arrival timing is the only Antithesis part).
- 25006 is now matched as the text "read-only transaction" with `lc_messages = 'C'`.

## Open questions

None remaining. Both earlier questions were answered (see the Investigation
Log):

- The stated intent, in the docs, in `include/spock_readonly.h` and in the
  regression test, is that `local` mode never blocks apply. No version of the
  hook ever exempted the apply worker, so the property stands as written;
  it is not narrowed to superuser-issued DDL.
- No test covers queued DDL from a non-superuser role on a `local`-mode
  subscriber. The regression test that checks "replication still works in
  local mode" issues its DDL as a superuser and before the subscriber
  switches to `local`.

### Investigation Log

#### Does the readonly hook fire inside the apply worker for queued DDL?
- Examined: `src/spock_readonly.c:84-137`, `src/spock_executor.c:337-360`,
  `src/spock_apply.c:4285-4420`, PG18 `PreventCommandIfReadOnly` path.
- Found: both hooks are global and test `superuser()` on the current user;
  `spock_execute_sql_command` switches the current user to the queued role
  before parse analysis.
- Not found: any apply-worker exemption in the hooks.
- Conclusion: the property should fail when the issuing role is not a
  superuser. Not yet confirmed by running it.

#### Is the readonly hook meant to apply to the apply worker's role switch?

- Examined: `docs/managing/read_only.md:8`, `include/spock_readonly.h`
  (comment added in `14d23326`), `git log` of `src/spock_readonly.c`,
  `git show e1aa238f` (hook rework, 2026-03-04),
  `tests/regress/sql/read_only.sql:195-219`.
- Found: the docs and the header both say that in `local` mode "replicated
  writes from apply workers are still permitted". The regression test says
  "'local' mode does not block apply workers". Before `e1aa238f` the hooks
  raised an ERROR for every non-read-only statement with no superuser test at
  all, so queued DDL in an apply worker was blocked then too (for any role).
  The rework added the `superuser()` test on the current user, which lets
  plain row apply through but not queued SQL that runs under a switched
  role. No version had an apply-worker exemption.
- Not found: any statement that apply under `local` is meant to be limited to
  superuser-issued DDL.
- Conclusion: resolved: per the stated intent, the hook is not meant to block
  apply. The property stays as written. The likely fix is an exemption for
  apply/sync workers (`MyApplyWorker != NULL`) in `local` mode; that choice
  does not change the property.

#### Do the TAP / regression tests cover readonly together with DDL from a non-superuser role?

- Examined: `grep -rl readonly tests/` ->
  `tests/regress/sql/read_only.sql`, `tests/tap/t/015_resync_readonly_origin.pl`.
- Found: `read_only.sql` creates `ro_repl_test` through `replicate_ddl` as
  `:regress_su` (a superuser) **before** setting the subscriber to `local`,
  then checks only that a later INSERT arrives. The non-superuser AutoDDL
  case in the same file runs on the *provider* in `local` mode and checks
  that the DDL is blocked there, so nothing is queued. `015` covers resync
  only.
- Not found: any test where queued SQL issued by a non-superuser role reaches
  a subscriber that is in `local` mode.
- Conclusion: resolved: not covered. A TAP test would catch this cheaply; the
  Antithesis property remains useful for timing (reload vs DDL arrival,
  worker restarts).
