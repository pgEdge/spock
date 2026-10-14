# sync-standby-hold-freezes-provider-confirmed-flush

Surfaced by evaluation gap (c), item 8 (wildcard W8, coverage-balance F6,
lead L9). Code checked at 69d9228f.

## What the property says

When a subscriber has `synchronous_standby_names` set, the apply worker is
meant to hold back flush feedback for each applied transaction until the
subscriber's sync standby has flushed the local commit
(`src/spock_apply.c:3120-3140`, header comment of
`append_feedback_position`). If the standby never confirms anything, the
provider's `confirmed_flush_lsn` for that subscription's slot must never
move past the position it had when the holds began.

The cheap way to test it needs no standby container: set
`synchronous_standby_names = 'phantom'` on one subscriber. Nothing named
`phantom` ever connects, so `WalSndCtl->lsn[SYNC_REP_WAIT_FLUSH]` stays put
and correct code never releases a hold.

## Mechanisms that break it (code-checked, not run)

1. **send_feedback overwrite (L9).** `send_feedback()`
   (`src/spock_apply.c:3237-3277`) calls `get_feedback_position()` (no hold
   released, positions unchanged) and then `get_flush_position()`. The
   `lsn_mapping` list holds every applied transaction (pushed in
   `handle_commit`, `:1103-1109`) and is drained as soon as the local WAL is
   flushed. Once it is empty `get_flush_position` returns true and
   `flushpos = writepos = recvpos` (latest received). The reply carries that
   flush position and the provider advances `confirmed_flush_lsn`. The hold
   list is ignored.
2. **Worker restart.** On every apply worker start, `spock_apply_main`
   sends `request_initial_status_update(streamConn, origin_startpos)`
   (`:4751-4778`, function at `:3353-3375`) with write = flush = apply =
   the replication origin's position. The hold list is in process memory
   and is lost on restart, so anything applied before the restart is
   confirmed at once, standby or not. Any reconnect reaches this: a
   partition, an idle-timeout reconnect, a walsender kill, `sub_disable` /
   `sub_enable`, a subscriber restart. A fix to (1) alone leaves this path.

Both lead to the same loss on failover: the provider frees WAL and will not
resend transactions the promoted standby lacks (see
`promoted-subscriber-standby-has-every-confirmed-txn`).

## Workload and oracle design

Config variant `v2/phantom-sync-standby` (no extra container):

- On one subscriber S (for example n2): `synchronous_standby_names =
  'phantom'`, and `synchronous_commit = local` as the server default so
  that client and Spock background transactions on S do not block on sync
  rep. The apply worker uses `spock.synchronous_commit` (default off), so it
  does not wait. Avoid ZODAN `add_node` and DDL that runs on S in this
  variant unless their sessions also use `local`.
- Set the GUC (reload) after setup and after one barrier. Then, on S, read
  the subscription origin's `remote_lsn` from `pg_replication_origin_status`
  (origin named after the slot) and keep it as `R0`: everything up to `R0`
  was applied before the holds began.
- During the run (writes on P, faults on), poll S's origin `remote_lsn` and
  record `E` = the first observed value above `R0`. `E` is at or after the
  end of the first transaction applied under a hold, so correct code keeps
  the provider's `confirmed_flush_lsn` below it (keepalive-only advances over
  WAL that carried nothing for S stay below the first applied commit). Poll
  `confirmed_flush_lsn` of P's slot for `sub_P_S` repeatedly.
  `Always("provider slot of a subscriber with an unconfirmed sync standby
  stays below its first held transaction")`: `confirmed_flush_lsn < E`.
  Sound with sparse polling: a later `E` only weakens the check.
- Companions: `Sometimes("subscriber with phantom sync standby applied a
  provider transaction")` (S's ledger shows rows from P committed after the
  freeze, so the check is not vacuous); `Sometimes("apply worker of the
  held subscription reconnected")` (reaches mechanism 2).
- Note that the provider holding WAL for the frozen slot grows WAL; keep
  the variant short or cap the write rate. `max_slot_wal_keep_size` must be
  unlimited or the slot is invalidated (which would itself be a different
  finding).
- Turning the setting back off should release everything: optional
  liveness check that `confirmed_flush_lsn` then catches up within a bound.

Expected result at HEAD: fails on the first feedback after the local WAL
flush (mechanism 1), deterministic. Reproduce it in TAP first; the
Antithesis run then adds mechanism 2 and keeps checking it under faults
once (1) is fixed.

## Fault requirements

- None for mechanism 1.
- Partitions, walsender/apply worker kills, node restarts for mechanism 2.

## Instrumentation

All missing. Workload-side check only. The SUT-side check (2) in
`feedback-never-confirms-undurable-apply` ("flushpos < remote_end for every
held sync-standby entry") covers mechanism 1 from the inside but cannot
see mechanism 2 (holds are gone after restart).

## Second-pass refinements (2026-10-13)

From the second evaluation pass on the gap-fill properties; see `evaluation/synthesis.md` "Second pass (gap-fill)".

- Placement: mechanism 1 (L9, `flushpos = recvpos` once `lsn_mapping`
  drains) is deterministic in the phantom configuration. Expected to fire
  deterministically — confirm with TAP first (TAP
  `020_sync_standby_feedback_lsn.pl` already exercises this area; extend it),
  then keep the Antithesis variant for mechanism 2 (restart path), which
  needs partitions, walsender kills and restarts.
- Overlap: check (2) of `feedback-never-confirms-undurable-apply` is the
  SUT-side detector for mechanism 1; this property is the workload-side
  outcome check for both mechanisms. Kept separate.

## Open questions

- Is `synchronous_standby_names` with no connected standby a configuration
  the team considers meaningful? Also: should Spock, after a restart, hold
  feedback until the sync standby's flush LSN passes the origin's
  `local_lsn` (what a fix would look like)? Decides whether mechanism 2 is
  a bug or out of scope. `(needs human input)`
- Keepalive replies with an empty `lsn_mapping` report the provider's
  `sentPtr` as flushed, which legitimately moves `confirmed_flush` over WAL
  that carried nothing for S. The oracle uses the first held transaction's
  end (`E`) instead of a frozen value for that reason; confirm with the team
  that confirming filtered-out WAL ahead of a held transaction is never
  possible in correct code. `(partial: by stream order a keepalive's
  sentPtr is past every earlier sent transaction, so after one held
  transaction any keepalive-based confirm passes it; that is mechanism 1)`

### Investigation Log

#### Is the hold gated only on SYNC_STANDBY_DEFINED, so a phantom name enables it?

- Examined: `handle_commit` `:1059-1060`, `send_feedback` `:3253`,
  `get_feedback_position` `:3187-3234`.
- Found: both gates test `WalSndCtl->sync_standbys_status &
  SYNC_STANDBY_DEFINED` only; the release test compares the local commit
  LSN with `WalSndCtl->lsn[SYNC_REP_WAIT_FLUSH]`, which no standby moves.
- Conclusion: the phantom setup turns on the hold path and correct code
  would never release.

#### Does a restarted worker confirm positions the standby has not flushed?

- Examined: `spock_apply_main` `:4682-4778`; `request_initial_status_update`.
- Found: the start position (origin progress, durable locally only) is sent
  as flush with no sync-standby check.
- Conclusion: second mechanism confirmed by code reading.
