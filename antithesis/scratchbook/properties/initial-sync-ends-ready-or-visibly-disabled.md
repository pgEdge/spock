# initial-sync-ends-ready-or-visibly-disabled

## Why this property

Initial sync is the most phase-heavy lifecycle in Spock and runs inside the
apply worker before streaming starts (`spock_apply_main` ->
`spock_sync_subscription`, `src/spock_apply.c:~4731`,
`src/spock_sync.c:1488-1810`). In the v1 topology it runs during ZODAN
add_node Phase 5 (`sub_create(src -> n4, synchronize_structure, synchronize_data)`).

Subscription-level status chain: `i` INIT -> (slot + snapshot, pause/resume
provider apply workers, read peer progress) -> origin created and advanced to
the slot LSN in its own committed txn (`:1675-1690`) -> `s` STRUCTURE
(pg_dump/pg_restore pre-data) -> `d` DATA (COPY per table, force-set
progress, write `resource.dat`) -> `c` CONSTRAINTS (post-data) -> `u`
CATCHUP -> `r` READY.

Restart behaviour on the next apply-worker start (`:1510-1550`,
code-checked):

- `r`: nothing to do.
- `i`, `u`: rerun (INIT drops the inactive old slot and starts again).
- anything else (`s`, `d`, `c`): `spock_disable_subscription` +
  `ereport(FATAL, "... initialization failed during nonrecoverable step (%c).
  Subscription disabled.")`.

Cleanup of the remote slot and local origin happens only through
`PG_ENSURE_ERROR_CLEANUP` (ERROR/FATAL), not on SIGKILL / postmaster crash,
and the cleanup itself needs a working provider connection
(`spock_sync_worker_cleanup`, `:1429-1468`).

So the documented outcomes are: success (READY), or a disabled subscription
plus a log line (sut-analysis V4, L13, workload boundary "interrupted initial
sync -> disabled"). Those are acceptable. What is **not** acceptable:

1. the subscription stays enabled in `i`/`s`/`d`/`c`/`u` forever after faults
   stop (a hang: blocking libpq COPY or pg_dump against a provider that came
   back; `sub_wait_for_sync` polls with no timeout);
2. a READY subscription whose tables are missing rows (that half is the data
   property in other catalog entries; here only the state machine);
3. an `s`/`d`/`c` crash that is retried as if INIT (would re-COPY into
   partly filled tables).

Also, a `sub_disable` during COPY does not stop the copy: sync code checks
`got_SIGTERM` only in the cleanup loop and in `wait_for_sync_status_change`
(`src/spock_sync.c:1437`, `:2650`). The worker finishes, reaches `apply_work`
and exits there. That is fine; the property makes sure the end state is still
one of the two allowed ones.

## Invariant and assertions

- Workload (Always, at the end of a quiet period of at least
  `spock.sync_timeout` plus `apply_idle_timeout` after add_node returned or
  raised): for every subscription on n4, either (a) `sub_enabled` and
  `spock.sub_show_status` = `replicating` with sync status `r`, or (b)
  `sub_enabled = false` and the node log or `spock.exception_log` holds the
  "nonrecoverable step" record or the add_node call raised. Never enabled and
  stuck in another sync status.
- SUT-side (missing, no existing assertions):
  `Reachable("initial sync restarted from INIT after a previous attempt")`
  in `spock_sync_subscription` when status is INIT and an origin named
  `sub->slot_name` already exists; and
  `Reachable("initial sync interrupted in nonrecoverable step; subscription disabled")`
  at the FATAL site. Two distinct outcomes, so the run shows which recovery
  paths were explored.
- SUT-side (missing): `Unreachable("initial sync COPY started with sync status past DATA")`
  at the COPY entry, guarding case 3.

## Antithesis angle

Kill n4 or the provider, partition them, or pause the provider during each
phase: slot creation (pause window, see add-node properties), pg_dump,
COPY, post-data, catch-up. Disable/enable n4's sub mid-copy.

## Fault requirements

Node termination, network partition, process pause. The n4 add_node loop
provides the workload.

## Findings from open-question investigation (HEAD 69d9228f, code read, not run)

- **Operator recovery after a nonrecoverable-step disable is drop and
  recreate.** The FATAL's hint says "fix the issue and try the setup again"
  (`src/spock_sync.c:1546-1550`). `sub_enable` alone does not recover: the sync
  status row stays `s`/`d`/`c`, so the next apply-worker start goes straight
  back into the same `default:` branch, disables the subscription again and
  exits FATAL. The workload's next step after seeing case (b) must therefore be
  `sub_drop` (or ZODAN `remove_node`) followed by a fresh `sub_create` /
  `add_node`. A workload that only re-enables will see the subscription flip
  back to disabled every time, which is still outcome (b) and not a failure.
  No user doc describes this; the hint is the only guidance.
- **pg_dump is not bounded by Spock's keepalives.** `dump_structure`
  (`src/spock_sync.c:244-296`) builds its DSN with `spk_get_connstr`
  (`src/spock_fe.c:106`), which only copies the user's DSN; the
  `connect_timeout=30` and `keepalives_idle=10/interval=5/count=3` settings are
  added only by `spock_connect` (`src/spock.c:399-411`). pg_dump is run with
  `fork` + blocking `waitpid` (`exec_cmd`, `:128-151`); Spock's SIGTERM
  handler only sets a flag and PG installs handlers with `SA_RESTART`
  (`src/port/pqsignal.c:157` in the PG tree), so `sub_disable` / `sub_drop`
  cannot interrupt it. COPY uses `spock_connect` on both ends
  (`:1269-1273`, `:1334`, `:1402`), so a dead provider is noticed in about
  10 + 5x3 = 25 s.
  Consequence for the property: a plain partition that later heals does not
  hang pg_dump (TCP resumes). A hang needs the provider side of the pg_dump
  connection to go away while the subscriber cannot see it (provider restart
  or kill during a partition, so the FIN/RST is lost). pg_dump then waits until
  OS keepalive (libpq default `keepalives=1` but with the kernel's idle time,
  typically 2 h) or `tcp_retries2` (about 15 min, only if pg_dump has unsent
  data). During that time n4's apply worker is stuck in `waitpid`, the sub
  stays enabled in status `s`, and a concurrent `sub_drop` waits on it (its
  wait loop has no timeout but is cancellable). With a quiet period of a few
  minutes the property will flag this, which is the intended finding
  (pg_dump should get the same keepalive/connect_timeout options as
  `spock_connect`). If the team wants this treated as a known limitation, the
  workload can put `keepalives_idle`/`connect_timeout` in the DSN passed to
  `add_node`; pg_dump then inherits them.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability (property finding)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: node kill, partition, pause during add_node sync

- Evaluation note (2026-10-13): the expected pg_dump hang also blocks the workload's `CALL spock.add_node`; run add_node in its own test command with a client-side timeout, and read n4's sync status from a separate session.

## Open questions

- None open. Both earlier questions were answered from code (see the
  Investigation Log). The pg_dump hang is now an expected way for the
  property to fail, not an open question.

### Investigation Log

#### What is the intended operator recovery after a nonrecoverable-step disable?

- Examined: `spock_sync_subscription` status switch
  (`src/spock_sync.c:1500-1552`), `docs/troubleshooting.md`,
  `docs/spock_functions/*`, `samples/Z0DAN/zodan.sql` error handling.
- Found: errhint "Check server errors and 'exception_log', fix the issue and
  try the setup again". Re-enabling re-enters the same branch because the
  sync-status row is unchanged, so the sub is disabled again.
- Not found: any user doc on this case; any code that resets an `s`/`d`/`c`
  status.
- Conclusion: recovery is drop + recreate (or remove_node + add_node). The
  workload does that after outcome (b). Resolved.

#### Is a hanging COPY or pg_dump bounded after a partition heals?

- Examined: `dump_structure`, `restore_structure`, `exec_cmd`
  (`src/spock_sync.c:128-360`), `spk_get_connstr` (`src/spock_fe.c:106-175`),
  `spock_connect` option list (`src/spock.c:380-430`), copy connections
  (`src/spock_sync.c:1269-1402`), PG `pqsignal` (`SA_RESTART`).
- Found: COPY connections carry keepalives (about 25 s to detect a dead peer).
  pg_dump gets only the user DSN, no keepalive tuning, no connect_timeout, and
  the parent waits with blocking `waitpid` that SIGTERM does not break.
- Not found: any timeout or watchdog around pg_dump/pg_restore.
- Conclusion: COPY is bounded; pg_dump is bounded only by OS TCP defaults
  (minutes to hours) when the provider dies unseen during a partition. The
  property keeps its Always and is expected to catch this. Resolved.
