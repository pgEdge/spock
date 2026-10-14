# Investigation summary: group G8

Sources: Spock HEAD 69d9228f, PG18 tree at ~/dev/pgedge/postgresql (REL_18_STABLE),
Antithesis docs via `snouty docs`. Details in each evidence file's Investigation Log.

Cross-cutting finding: Antithesis `ANTITHESIS_STOP_FAULTS` quiet periods do NOT
stop clock skips (backward jumps possible, stacking). Any bounded-time check in a
quiet period must detect or tolerate clock jumps.

## fast-shutdown-completes-within-bound
- resolved: bound = `wal_sender_timeout + 60 s` measured on postmaster exit (core walsender waits for receiver flush until wal_sender_timeout; pg_ctl's 60 s is only its client wait); pg_dump/pg_restore get SIGTERM at postmaster shutdown (setsid per child + `kill(-pid)`; exec_cmd keeps the group), so L32 is not a shutdown hang — it still affects Spock's own `kill(pid)` worker kills.
- remaining: none
- property changed?: yes — bound fixed to wal_sender_timeout + 60 s on postmaster exit (use `pg_ctl -t` or poll PID); harness must keep wal_sender_timeout non-zero; pg_dump scenario becomes coverage, not a suspected hang.
- invalidated?: no

## crashed-node-returns-to-streaming
- resolved: none fully (new facts: supervisor static restart 5 s, dynamic workers forgotten and rebuilt; slot-active window short for in-container crash-restart, wal_sender_timeout for container kill; restarted containers may change IP so DSNs need hostnames).
- remaining:
  - What recovery bound does the team expect? `(needs human input)`
  - Is a node that fails to start on a full replication-state array a Spock bug or a sizing error? `(partial: extra states come from L1's node-id origin states, which sizing.md does not budget and SQL cannot drop; steady 3-node mesh fits in 10, node churn accumulates them; harness should use the documented value)`
  - Does Antithesis node termination keep fsynced PGDATA writes? `(needs human input)`
- property changed?: no (prose refinement only)
- invalidated?: no

## mesh-barriers-complete-after-partition-heal
- resolved: wal_sender_timeout is a harness choice with no Spock correctness effect → use 60 s; post-heal slot-active wait usually shorter than wal_sender_timeout (timeout counts from last reply; stale walsender gets a TCP reset on its next send).
- remaining:
  - What recovery bound does the team consider acceptable after a partition heals? `(needs human input)`
- property changed?: no (barrier re-run on clock jump now required, not optional)
- invalidated?: no

## apply-worker-restarted-within-bound-after-exit
- resolved: bgworker exit notify is reliable after attach (postmaster SIGUSR1 to bgw_notify_pid → default procsignal handler → SetLatch; manager crash sets subscriptions_changed first), so no 180 s wait. New narrow gap: a manager dying before `spock_worker_attach` never sets subscriptions_changed and is not restarted until another change. Correction: clean apply exits are restarted at once (postmaster wakes the manager), not on the next timer tick.
- remaining:
  - Is a restart delayed by the size of a backward clock step acceptable? `(needs human input)`
- property changed?: yes — prose/table correction (clean exit = immediate restart); "clock is stable" cannot be arranged by the harness, workload must detect clock jumps; suggest `Reachable("manager exited before attach")` marker.
- invalidated?: no

## sub-show-status-reflects-apply-state
- resolved: FAILED table state is table-scoped by design (commit 6a063b22; sub-level is a named follow-up) → mismatch 3 moved out of this property (sub_show_table printing `unknown` for p/f is a separate display gap). Docs table was written "derived from the C source" (84edbd74), so the "being applied normally" wording is a gloss.
- remaining:
  - Is `replicating` meant to mean "worker exists and initial sync done" (code) or "changes are being applied" (docs)? `(needs human input)`
- property changed?: yes — scope narrowed (FAILED-table mismatch removed).
- invalidated?: no

## convergence-check-runs-after-faults
- resolved: quiet periods are workload-controlled (`ANTITHESIS_STOP_FAULTS <s>`, plus eventually_/finally_ terminal pauses) → driver sizes its own pause; timeouts are retried/skipped here, the liveness failure is owned by mesh-barriers-complete-after-partition-heal.
- remaining: none
- property changed?: no (prose refinement: driver requests its own pause; clock skips continue in pauses)
- invalidated?: no

## forwarded-origin-advance-no-double-apply
- resolved: supported user flow (sub_mgmt.md "Origin Forwarding", v6.0 release notes, TAP 015), not a ZODAN helper; advance cannot be atomic with PG's origin API (standalone XLOG_REPLORIGIN_SET; before-commit would lose data) → at most one replayed transaction per C crash is a documented limit (401197ab message, code comment).
- remaining: none
- property changed?: yes — invariant split into AlwaysOrUnreachable "nothing missing", "duplicates <= C crashes", "no duplicates without a crash"; duplicates must be attributed to sub_A_C because L1 can cause B-path duplicates; switch order constrained by enforce_forwarding_exclusivity.
- invalidated?: no (the strict "never applied again" claim is replaced by the documented at-least-once bound)
