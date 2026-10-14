# promoted-subscriber-standby-has-every-confirmed-txn

Surfaced by evaluation gap (c), item 8 (coverage-balance F6, claim S9,
lead L9). Code checked at 69d9228f.

## What the property says

A subscriber node S with a physical synchronous standby S' fails, and S' is
promoted. Every provider transaction that the provider's slot for S had
confirmed (its `confirmed_flush_lsn` passed it) before the failure is
present on S' after S' resumes replication. Put plainly: failing over a
subscriber to its sync standby loses no replicated rows.

## Why it is at risk

- Spock claims the sync-standby hold exists for exactly this
  (`src/spock_apply.c:3120-3140`: "if we tell the publisher we have flushed
  the change it may advance its slot past changes that a fail-over of THIS
  node would lose").
- Two code-confirmed ways to confirm too early (see
  `sync-standby-hold-freezes-provider-confirmed-flush`): `send_feedback()`
  overwrites the hold with `recvpos` once `lsn_mapping` drains (L9), and a
  restarted apply worker confirms its origin position with no standby check
  (`request_initial_status_update`, `:3353`, `:4778`).
- Loss path: S applies provider transaction T with `synchronous_commit=off`
  (Spock's default for apply), reports T flushed, provider advances its slot
  past T. S dies before S' has T's local commit. S' is promoted; its copy of
  the subscription origin is before T. The apply worker on S' asks to start
  at that origin LSN, but a logical slot never goes back before
  `confirmed_flush_lsn`, so decoding resumes after T. T is never applied on
  S'. No error, no exception row.
- Related claims under S9 (`docs/logical_slot_failover.md:5,165`): Spock
  creates provider slots with `(FAILOVER)` on PG17+
  (`src/spock_sync.c:416-428`) so that the promoted node keeps the slots
  other nodes use to subscribe to it. That provider-side part is a second
  check in the same topology (rows S originated and other nodes received
  must exist on S').

## Topology `v2/standby`

- n1, n2, n3 mesh plus n2s: physical streaming standby of n2 with
  `synchronous_standby_names = 'n2s'` on n2, `hot_standby = on`,
  `sync_replication_slots = on` and `synchronized_standby_slots` on n2 for
  the provider-side check (PG18 native slot sync; the Spock failover-slots
  worker is only for PG<18).
- Clients on n2 use `synchronous_commit = on` (so their own commits are on
  n2s before they return).
- Failover action (test command): stop or kill n2, promote n2s, point the
  other nodes' subscriptions to n2 at n2s (`spock.sub_alter_interface` or a
  DNS alias that moves to n2s), let n2s's apply workers start.

## Oracle

- Before failover, keep sampling on n1 and n3 the `confirmed_flush_lsn` of
  their slots for n2's subscriptions, and record, per ledger transaction
  from n1/n3, its commit LSN on the origin (or a marker-row LSN bound).
- After promotion and a barrier from n1 and n3 to n2s:
  `Always("promoted subscriber standby has every provider transaction its
  provider had confirmed")`: every n1/n3 ledger row whose origin commit is
  at or before the last sampled `confirmed_flush_lsn` is on n2s. Simpler,
  stronger form: every committed n1/n3 ledger row reaches n2s (the provider
  resends anything not confirmed), which is
  `committed-ledger-row-reaches-every-node` evaluated with n2s in place of n2.
- Provider side: `Always("rows n2 originated and peers received exist on
  the promoted standby")` for rows committed on n2 with
  `synchronous_commit=on`.
- `Sometimes("subscriber standby promoted while its provider slot was ahead
  of the standby's replay position")` to show the dangerous state was
  reached (compare the provider's last sampled confirmed LSN with n2s's
  origin `remote_lsn` right after promotion).

## Fault requirements

- Pause n2s (process pause) so it lags, keep providers writing, then kill
  n2 and promote. Network latency between n2 and n2s does the same.
- Worker restarts on n2 before the failover reach the restart mechanism.

## Instrumentation

All missing; workload-side checks only. Optional SUT-side check lives in
`feedback-never-confirms-undurable-apply` (held-entry test).

## Open questions

- Is subscriber failover to a sync standby a supported scenario, and how
  should other nodes be pointed to the promoted node (interface change, DNS,
  ZODAN)? `(needs human input)` — docs cover provider failover slots, not a
  documented subscriber failover runbook; decides the failover action.
- Does a promoted standby start Spock workers cleanly (shared memory,
  `resource.dat`, progress) with the same node id? Not read in depth;
  if not, the property cannot run until it does.
- Expected to fail at HEAD if the provider confirmed past what n2s had
  (L9). Since `sync-standby-hold-freezes-provider-confirmed-flush` finds
  the same cause without a sixth container, run that first; this property
  then checks the end-to-end claim after a fix.

### Investigation Log

#### Does a logical slot restart before confirmed_flush if asked?

- Examined: patched PG18 `src/backend/replication/logical/logical.c:558-577`
  (`CreateDecodingContext`: a start LSN below `confirmed_flush` is logged
  "has been already streamed, forwarding to" and moved up to it); Spock passes `origin_startpos` as the start point
  (`src/spock_apply.c:4751-4769`).
- Found: the provider streams from `max(start, confirmed_flush)`, so a
  transaction confirmed but missing on the promoted node is skipped.
- Conclusion: loss path stands; not run.

#### Is subscriber failover to a standby documented?

- Examined: `docs/logical_slot_failover.md`, `docs/configuring.md`
  ("Logical Slot Failover (HA Standby)"), `docs/troubleshooting.md`.
- Found: provider-side failover slots (`sync_replication_slots`) are
  documented; nothing describes promoting a subscriber's standby or
  repointing peers to it.
- Conclusion: `(needs human input)`; the failover action and the repoint
  step need the team's runbook.
