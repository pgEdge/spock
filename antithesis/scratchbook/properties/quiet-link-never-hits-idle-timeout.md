# quiet-link-never-hits-idle-timeout

Surfaced by evaluation gap (c), item 6 (wildcard W1). Code checked at
69d9228f and patched PG18 `walsender.c` / `reorderbuffer.c`.

## What the property says

On a link where neither end and the network between them has a fault, and
the wall clock does not jump, the apply worker never raises "no data
received for N seconds, reconnecting (spock.apply_idle_timeout)". The idle
timeout is meant as a safety net for a hung walsender
(`src/spock_apply.c:3527-3546`), not something healthy links trip.

## Mechanism

- Subscriber: `last_receive_timestamp` is reset only when `PQgetCopyData`
  returns a message (`:3686`). The check runs only when the wait returned
  `WL_TIMEOUT` (`:3548-3562`, 1 s wait at `:3492-3495`). Spock sends
  feedback only after it receives something and only if positions moved
  (`send_feedback` non-forced, `:3842`), or when the provider asks
  (`'k'` with reply requested).
- Provider (stock walsender, patched PG18): `WalSndKeepaliveIfNecessary`
  (`walsender.c:4117-4146`) pings with reply requested once
  `wal_sender_timeout / 2` has passed since the last reply. In
  `WalSndWaitForWal` (`:1909-1912`) it also sends a no-reply keepalive when
  `sentPtr` moved past the client's flush, which happens whenever WAL that
  is filtered out for this subscriber is read (for example commits applied
  from other nodes). During replay of a large transaction the reorder
  buffer calls `update_progress_txn` every 100 changes
  (`reorderbuffer.c:2598-2602`) which ends in the same keepalive test, and
  sent changes are themselves messages.
- So on a quiet mesh (no writes anywhere, as in the workload's quiet
  periods) the gap between messages is about `wal_sender_timeout / 2` plus
  up to a second of loop latency. If `spock.apply_idle_timeout` is not
  clearly larger, every quiet link reconnects, restarts after
  `restart_delay_default`, and the provider decodes again from
  `restart_lsn`.
- An earlier harness plan had `apply_idle_timeout` about 30 s with
  `wal_sender_timeout` 60 s: the gap equals the timeout, and the property
  would fire in every quiet period. The evaluation already fixed the
  harness: `deployment-topology.md` and catalog Assumption 4 now set
  `wal_sender_timeout = 60s` with `spock.apply_idle_timeout = 120s`, which
  is above `wal_sender_timeout / 2 + 30 s` (60 s), so the main
  configuration should pass. The documented-defaults variant (5 min /
  300 s) also passes (gap 150 s). Checked consistent on 2026-10-13.
- Docs recommend `wal_sender_timeout = '5min'` with `apply_idle_timeout =
  300` (`docs/configuring.md:227-252`): gap 150 s, fine. A user with
  `wal_sender_timeout` of 10 min gets churn; Spock does not warn.

"Large transactions retried forever" (gap item 6b): with the keepalive
paths above, a long decode or replay still produces a keepalive every
`wal_sender_timeout / 2`. Under a config where `apply_idle_timeout`
is above that, no livelock path was found in code. With
`apply_idle_timeout <= wal_sender_timeout / 2` the same reasoning shows
the livelock W1 describes is possible (every replay longer than the idle
timeout with no sent change in a stretch is cut off and restarted).

## Workload and oracle

- Harness rule: `apply_idle_timeout >= wal_sender_timeout / 2 + 30 s`.
  The main configuration (60 s / 120 s) meets it; the documented-defaults
  variant (5 min / 300 s) meets it too, so findings cannot be called
  "unsupported config".
- In each quiet period (`ANTITHESIS_STOP_FAULTS`), start a window
  `apply_idle_timeout` seconds after the period begins (earlier faults may
  have left a legit idle stretch) and end it when the period ends. Detect
  clock jumps (monotonic vs wall clock, Assumption 8) and drop the window if
  one happened.
- Scan each node's server log for the idle-timeout message inside the
  window, or poll `spock.sub_show_status` / worker pids and count apply
  worker restarts. `Unreachable("apply worker hit the idle timeout on a
  link with no fault and no clock jump")`.
- Companion `Sometimes("transaction of at least N changes applied on every
  peer")` so large replays (and update_progress keepalives) are really
  exercised; with a filtered table (in no subscribed repset) variant if
  the workload has one.
- Workload also keeps some quiet periods with zero writes anywhere, the
  case where only `wal_sender_timeout / 2` pings flow.

## Fault requirements

Faults stop in the windows checked. Earlier faults (pauses, partitions,
kills) create the reconnect states that the window must not inherit. Clock
jumps must be detected and excluded (a forward jump makes the idle check
fire by design).

## Instrumentation

Missing. Optional SUT-side `Sometimes("idle-timeout reconnect taken")`
next to the ereport at `:3555-3560` so triage can tell how often it fires
in fault windows.

## Second-pass refinements (2026-10-13)

From the second evaluation pass on the gap-fill properties; see `evaluation/synthesis.md` "Second pass (gap-fill)".

- Priority lowered from P2 to P3: the harness timeouts now meet the rule
  (60 s / 120 s, and 5 min / 300 s in the documented-defaults variant), so
  this is a guard against regressions and unknown stalls on healthy links,
  not a known failure.

## Open questions

- Should Spock reject or warn when `apply_idle_timeout <=
  wal_sender_timeout / 2`, or send its own periodic status message (as
  stock PG's `wal_receiver_status_interval` does) so the provider's
  keepalive cadence does not decide the subscriber's timer? `(needs human input)`
- Could a subscriber that is slow to work through buffered data delay its
  reply to a keepalive past `wal_sender_timeout`, so that the walsender
  times out during a large transaction and restarts it every time? Not
  traced; stock PG apply has the same shape. Matters for "large
  transactions eventually apply" under CPU throttling.

### Investigation Log

#### Does Spock guard against `apply_idle_timeout <= wal_sender_timeout / 2`?

- Examined: GUC definition of `spock.apply_idle_timeout` (`src/spock.c`),
  idle check `src/spock_apply.c:3548-3562`, `docs/configuring.md:227-252`.
- Found: no check hook, no warning, no periodic status message from the
  subscriber; the docs pair 5 min with 300 s without stating the rule.
- Conclusion: `(needs human input)`; the harness sets values that meet the
  rule, and the property guards against regressions and other stalls.

#### Are the harness timeouts consistent with the rule?

- Examined: `deployment-topology.md` (Timeouts, Configurations), catalog
  Assumption 4.
- Found: both say 60 s / 120 s, plus a 5 min / 300 s variant.
- Conclusion: resolved; the 30 s figure in this file's first draft was stale
  and has been corrected.
