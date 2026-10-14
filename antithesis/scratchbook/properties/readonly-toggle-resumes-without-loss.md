# readonly-toggle-resumes-without-loss — readonly on/off cycles lose and duplicate nothing

## Synthesis note

Merged from `readonly-toggle-resumes-without-loss` (F8) and
`readonly-all-toggle-loses-and-duplicates-nothing` (F6). Same outcome check
(shared ledger oracle, delta totals, no exception rows, all subs enabled after
readonly windows end) for the documented maintenance procedure. F8 adds the
`apply_idle_timeout` reconnect chain under readonly (fixed in `8dcfbcd5`) and
markers at the readonly `break`; F6 adds toggles during in-process exception
replay and during add_node pauses, and the FATAL-path marker. Readonly=all
windows must stay shorter than slot WAL retention. Both chose `Always`.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW2, implementability CW6); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: readonly toggles (ALTER SYSTEM + reload), partition, node kill

- Evaluation note (2026-10-13): "no unexpected exception rows" means none outside the expected-exception registry. Any non-superuser DDL during readonly=local phases is kept out of this template until `readonly-local-keeps-inbound-ddl-flowing` is fixed.

## Open questions

- Is a sync worker's COPY meant to be blocked by readonly=all? `(needs human input)`
  (At HEAD it is not blocked when the target DSN user is a superuser; the
  comment at `src/spock_functions.c:1241-1247` predates the hook rework that
  exempted superusers. For this property only the end state matters, so the
  answer does not change the check.)

Resolved (see Investigation Log): the readonly FATAL is unreachable, and the
exits that do happen under readonly=all clear the exception marker; the
reconnect churn is a side effect, harmless to this property's outcome check.

## Findings that refine the mechanism (from investigation)

- **Docs vs code.** `docs/managing/read_only.md` ("Behavior of `all` mode")
  says each apply worker "raises a FATAL and exits, and the manager restarts
  it once read-only is cleared". The code does not do that: the worker
  `break`s out of the inner loop, stays connected, and keeps sending
  feedback (`src/spock_apply.c:3610-3631`, feedback at the end of the outer
  loop). The regression test asserts this ("apply worker should gently
  wait", same walsender PID, `tests/regress/sql/read_only.sql:270-300`).
  The docs are stale; the property checks the documented outcome (lossless
  resume), which does not depend on which of the two happens.
- **Walsender timeout (step 4 below) does not happen.** While stopped, the
  outer loop still reaches `send_feedback(...)` each iteration (≤ 1 s) when
  not in replay, so the provider's `wal_sender_timeout` is not hit. The only
  restart is the apply-side `apply_idle_timeout`.
- **Side lead (not a property here, unverified at runtime):** while stopped,
  the outer loop calls `PQconsumeInput` whenever the socket is readable but
  never `PQgetCopyData`, so libpq's input buffer keeps growing with whatever
  the walsender streams, until the idle-timeout reconnect frees it. Memory
  use grows with provider write volume times `apply_idle_timeout`.

## Source: `readonly-toggle-resumes-without-loss` (F8 Lifecycle)

### Why this property

Second half of S8: after `spock.readonly` goes back to `off`, replication
"resumes from where it left off" (`docs/managing/read_only.md:73-83`). The
resume path goes through several lifecycle events (see
`readonly-all-never-commits-remote-txn` for the code):

1. readonly=all: loop `break`s, possibly mid-transaction with locks held;
2. `apply_idle_timeout` (300 s default, lower in the harness) fires because no
   message is read -> connection-class ERROR (`src/spock_apply.c:~3548-3561`,
   tagged since `8dcfbcd5`) -> `clear_transient_exception_state` -> rethrow ->
   origin not advanced -> restart after `restart_delay_default`;
3. restarted worker reconnects, breaks before its first message, repeats (2);
4. ~~meanwhile the provider walsender may time out (`wal_sender_timeout`) on
   the silent connection -> CONNECTION_BAD on the apply side -> restart;~~
   *(Corrected: the stopped worker still sends feedback every outer-loop
   iteration, so the walsender does not time out. Network faults can still
   cause CONNECTION_BAD.)*
5. readonly=off + reload -> worker reads, provider resends from the origin.

Each restart in (2)-(4) is a mid-transaction exit; the marker-clearing paths
from `ed0a9945` and `db380dd8` must hold for every one. `8dcfbcd5` (HEAD~4)
fixed exactly step (2) being classified as a data exception: before it, the
idle timeout raised XX000 and went to the exception path. That is a recent
regression target.

Documented limit: if readonly=all lasts longer than the provider retains WAL
for the slot, resume fails. The harness keeps readonly windows short and
`max_slot_wal_keep_size` unlimited, so that limit is out of scope.

### Invariant and assertions

- Workload (Always, at quiescence after readonly is back to off on every
  node): ledger exactly-once on every node; delta counters equal committed
  increments; `spock.exception_log` has no new rows; every subscription
  enabled. Always: the docs promise lossless resume.
- SUT-side (missing, no existing assertions):
  `Sometimes(in_remote_transaction)` with message
  "apply loop stopped for readonly=all inside a remote transaction" at the
  `break` in the readonly branch (`src/spock_apply.c:~3630`). Confirms the
  mid-transaction case was reached.
- SUT-side (missing): `Reachable("apply idle timeout fired while readonly=all")`
  at the idle-timeout ereport when `spock_readonly == READONLY_ALL`.

### Antithesis angle

Random readonly windows (0.5 s to longer than `apply_idle_timeout`) on random
nodes, overlapping with partitions, provider restarts and large transactions.

### Fault requirements

Set `spock.apply_idle_timeout` to 120 s (the harness value since the 2026-10-13 evaluation; it must stay above `wal_sender_timeout / 2`) so step (2) happens inside a run.
Network faults and process pause for steps (4).

### Original open-question notes (detail for the combined list above)
- Should readonly=all also stop the walsender side or the provider's
  `sync_event` handling? Not claimed; no change to this property.
- Is the reconnect churn every `apply_idle_timeout` intended? It is visible
  in logs but not harmful by itself; the property only checks the outcome.

## Source: `readonly-all-toggle-loses-and-duplicates-nothing` (F6 Security)

### Claim being tested

`docs/managing/read_only.md:73-83`: in `all` mode "apply workers detect the
setting and stop consuming inbound WAL ... When the mode is switched back to
`off` or `local`, replication resumes from where it left off, provided the
upstream replication slot still retains the necessary WAL." (sut-analysis S8,
L31; 04-safety P8.1.) This property is the "resume without loss or
duplication" half. The "blocks commits" half is
`readonly-all-never-commits-remote-txn`.

### Mechanism (code-checked)

The apply worker reaches readonly=all along these paths:

1. **Loop top, between messages** (`src/spock_apply.c:3600-3630`): reload,
   then if `READONLY_ALL`:
   - if `xact_had_exception`, sleep 1 s and `continue` (it stays inside the
     replay with an open transaction);
   - otherwise `break` without reading more. If a remote transaction is open
     (the worker is between 'B' and 'C'), it stays open, holding locks, until
     the outer loop or `apply_idle_timeout` ends the connection (L31).
2. **Per message** (`replication_handler`, `:2981-2983`): `elog(FATAL)` if the
   in-process value is `READONLY_ALL`. *(Investigation: unreachable at HEAD;
   every message passes the loop-top check after the last reload. Kept here
   as the description of the guard.)* FATAL skips the PG_CATCH classifier and
   goes through `proc_exit` -> `spock_apply_worker_shmem_exit` (the d286f3df
   fix clears `replorigin_session_origin*`). The open transaction is aborted
   by the FATAL. The origin must stay at the last committed remote end LSN.
3. **Reload inside `wait_for_previous_transaction`** (`:316-320`, called from
   `handle_commit` `:936`, `handle_relation` `:1404`, `handle_sql` `:2770`).
   This happens after the per-message check, so a transaction can still commit
   with the new value in effect. See `readonly-all-never-commits-remote-txn`.
4. **Exception replay** under `xact_had_exception`: the worker spins with the
   transaction open. Exception-log writes may still happen once readonly is
   cleared.
5. **Table sync / resync**: `check_readonly_for_resync`
   (`src/spock_functions.c:1250-1265`) refuses `sub_resync_table` when readonly
   is not off. That check runs in the caller's backend only. A sync worker that
   is already running, or one started after the check, does its COPY through
   a libpq session on the subscriber as the DSN user
   (`src/spock_sync.c:917-955, 1176-1245`). If that user is a superuser, the
   readonly hooks let it through. Its catch-up phase uses the apply code and
   hits the FATAL. Sync-worker death then leads to sut-analysis L12/L13.

The respawned worker resumes from
`replorigin_session_get_progress()`, and the provider re-sends from
max(requested, slot `confirmed_flush`). Loss happens only if feedback has
reported a flush position past a transaction that never committed locally.
Duplication happens only if the origin is behind a committed transaction.

### Property

After any number of readonly `off -> all -> off` (or `-> local`) changes on any
node, done at random times relative to replication traffic and faults, every
committed ledger row is present exactly once on every node after quiescence.
Workload-side **Always**, using the shared ledger oracle. Additional checks:
- no `exception_log` row on the toggled node that was not caused by a
  workload-caused conflict (FATAL must not be misclassified);
- no subscription disabled.

Keep readonly=all shorter than slot WAL retention (workload boundary §12).

Possible SUT-side assertions (all **missing**):
- `Reachable("apply worker FATAL on readonly=all inside an open remote transaction")`
  at `:2981` when `in_remote_transaction`;
- `Reachable("readonly=all observed while xact_had_exception")` at `:3612`.

### Antithesis angle

- When the reload lands: before 'B', between rows, right before 'C', during
  replay, during table-sync catch-up, while ZODAN add_node is pausing apply
  workers.
- Kill or partition while the node is read-only and the provider keeps
  writing: the slot holds WAL; check that the restart resumes correctly.
- Combine with process pause of the provider so an apply transaction sits
  open when the change lands.

### Confidence

Medium. The documented resume path is plausible. The exposed edges are path 4
(replay plus readonly) and path 5 (sync), which go through code with bugs
already recorded (L5, L12).

### Original open-question notes (detail for the combined list above)
- Is a sync worker's COPY meant to be blocked by `readonly=all`? The comment at
  `src/spock_functions.c:1241-1247` says subscriber COPY FROM "is blocked", but
  for a superuser DSN user the hooks exempt it. If it is meant to be blocked,
  a readonly toggle during sync breaks the "all" claim. If not, the comment is
  wrong and the property only needs the data to end up correct.
- After the FATAL, does `spock_apply_worker_shmem_exit` leave any exception
  marker that makes the next start treat the transaction as failed? (Shared
  with L5; owned by the classifier properties.)

### Investigation Log

#### Does the FATAL exit on readonly=all leave an exception marker that misclassifies the transaction on restart?

- Examined: `src/spock_apply.c` every `ProcessConfigFile` call (`:319`,
  `:3506`, `:3603`), the inner loop (`:3590-3800`), `replication_handler`
  (`:2975-2985`), `handle_begin` exception-log lookup (`:660-860`),
  `clear_transient_exception_state` (`:418-436`), `apply_work` PG_CATCH
  connection branch (`:3912-3943`), the SIGTERM path (`:4140-4160`),
  `spock_apply_worker_shmem_exit` (`:2305-2324`).
- Found: the FATAL cannot be reached. After every reload the next message
  must pass the loop-top check (`:3610`), which `break`s first. The only
  reload between that check and a handler is inside
  `wait_for_previous_transaction`, and it affects the *current* message
  (see `readonly-all-never-commits-remote-txn`), not the FATAL. If a FATAL
  did happen mid-transaction, the marker *would* stay (FATAL skips PG_CATCH
  and the shmem-exit callback clears only the session origin). The exits
  that really happen under readonly=all are the idle-timeout ERROR
  (connection class) and network loss, which call
  `clear_transient_exception_state`, and SIGTERM, which calls it at the end of
  `apply_work`. During replay (`use_try_block`) the marker is kept on
  purpose.
- Conclusion: resolved: no misclassification from readonly=all at HEAD. The
  "no exception_log row on the toggled node" check stays as a guard.

#### Is a sync worker's COPY meant to be blocked by readonly=all?

- Examined: `src/spock_functions.c:1236-1265` (`check_readonly_for_resync`
  and its comment), `git show 7d21b807` (2026-03-03, added that check and
  comment), `git show e1aa238f` (2026-03-04, hooks now exempt superusers),
  `src/spock_sync.c:1269-1273, 1402` (COPY via `target_if->dsn`),
  `src/spock_readonly.c:82-137`, `docs/managing/read_only.md`.
- Found: the "COPY FROM ... is blocked" comment was written one day before
  the hook rework, when the hooks blocked every writing statement for every
  role. Since `e1aa238f` a COPY session whose user is a superuser is not
  blocked. The sync worker's COPY uses a libpq session as the target DSN
  user. The docs say superusers are exempt in both modes and talk only about
  "apply workers" for `all`.
- Not found: any statement of whether initial/table sync should pause under
  `all`.
- Conclusion: `(needs human input)`. By the docs, a superuser COPY is
  allowed; the resync comment is stale. The outcome check here is unaffected.

#### Is the reconnect churn every `apply_idle_timeout` while readonly=all intended?

- Examined: `git show e1aa238f` ("When READONLY_ALL is active, the worker
  sends keepalive feedback but skips applying new transactions"),
  `git log -S spock_apply_idle_timeout` (`2535c3fa`, same day, separate
  change), `tests/regress/sql/read_only.sql:270-300` ("should gently wait
  (not crash or flood logs)"), `src/spock_apply.c:3403, 3686`
  (`last_receive_timestamp` is updated only when a message is read).
- Found: the readonly design means for the worker to stay alive. The idle
  timeout came in through a separate change and counts time since the last
  message *read*, which the stopped worker never does, so it fires every
  `apply_idle_timeout` and the worker restarts (paced at
  `restart_delay_default`, then breaks again before its first message). The
  regression test waits only about 5 s, well below the 300 s default, so it
  cannot see this.
- Conclusion: resolved for this property: the churn is an unplanned
  interaction, not a design goal, and does not affect the outcome check.
  Keep the `Reachable("apply idle timeout fired while readonly=all")`
  marker so runs show the path was exercised.
