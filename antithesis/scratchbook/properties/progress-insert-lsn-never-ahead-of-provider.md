# progress-insert-lsn-never-ahead-of-provider

## Summary

`spock.progress.remote_insert_lsn` (and `received_lsn`) on subscriber S for
provider P are positions in P's WAL. They must never be ahead of any WAL
position P has actually reached. This is a cheap, workload-side, cross-node
check that catches framing errors in the protocol 4 / 5 header handling
(where `remote_insert_lsn` comes from), including the replay misparse in
`proto5-replay-reparses-startup-message`, which writes `53016D61/785F7072`.

## Where the value comes from (code-checked)

- v5: every 'w' message from the publisher starts with
  `GetXLogWriteRecPtr()` (`spock_write_begin`, `spock_write_commit`,
  `spock_write_rel`, ... in `src/spock_proto_native.c`, e.g. `:112, 221, 250`).
  The subscriber reads it in `apply_work()` when
  `spock_apply_get_proto_version() >= 5` (`src/spock_apply.c:3747-3750`).
- v4: only COMMIT carries it, at the end of the message
  (`src/spock_proto_native.c:264-265`; reader `:732-735`); for other
  messages `last_inserted = last_received`.
- 5.0.x publishers send `GetXLogInsertRecPtr()` at the end of COMMIT
  (`git show v5.0.9:src/spock_proto_native.c`, `spock_write_commit`).
- Stored by `UpdateWorkerStats` -> `spock_group_progress_update_ptr`; the
  shared entry keeps the max (`src/spock_group.c:~335-340`). It is copied to a
  new node by `read_peer_progress` / the pre-6.0 fallback query during
  add_node (`src/spock_sync.c:779-830`), and dumped to `resource.dat`.
- Keepalives ('k') update `received_lsn` with the walsender's end position.

So any byte-offset mistake in the header, on either the stream or replay path,
shows up here as a value that P never reached.

## Invariant and check

Workload, per ordered pair (P, S), during any check point (not only at
quiesce):

1. Read on S: `SELECT remote_insert_lsn, received_lsn FROM spock.progress p
   JOIN spock.node n ON n.node_id = p.remote_node_id WHERE n.node_name = 'P'`.
2. Then read on P: `pg_current_wal_insert_lsn()`; keep `maxP` = the highest
   value ever observed on P during the run.
3. `Always(remote_insert_lsn <= maxP && received_lsn <= maxP,
   "subscriber's recorded provider LSNs are never ahead of the provider's WAL")`.

Why `Always`: there is no legitimate state where S has heard of a WAL position
P never wrote. Why `maxP` and not P's current value: after a node termination
P can lose written-but-unflushed WAL and come back with a lower insert LSN,
while S keeps the max it saw; comparing to the highest observed value avoids a
false positive from that, but still catches absurd values like the misparse.
If P was never reachable since S recorded a value, skip the check (no `maxP`
yet).

## Scope / false positives

- A provider that loses WAL in a crash could have sent S a write pointer that
  P never re-reached and the workload never observed. Rare; the margin can be
  widened (e.g. compare with `maxP` taken after the run settles, at quiesce).
  The misparse value is about 5.9e18, so even a generous margin works.
- After add_node, the new node's entries for third nodes X come from the
  source's progress for X; still X's LSN space, so check against X.
- `spock.progress` has one row per (dbid, node_id, remote_node_id); two subs to
  the same provider share it (sut-analysis L16).

## Instrumentation (missing)

- Workload-side `Always` above is the main check.
- Optional SUT-side: in `UpdateWorkerStats`, `Always(last_inserted <= last_received || last_inserted is from a v4 COMMIT, ...)`
  is tempting but wrong: v5 sends `GetXLogWriteRecPtr()` which can be ahead of
  the 'w' header's end LSN. Prefer the cross-node workload check.

## Fault requirements

None of its own. It is a passive oracle that fires when other faults
(reconnects + data errors) reach the framing bug.

## Investigation update (2026-10-13)

`received_lsn` stays within P's flushed WAL in normal running, so both
columns stay in the check. Its sources:

- 'w' headers: for logical walsenders `WalSndPrepareWrite` sends the same
  record LSN as dataStart and walEnd (PG18 `walsender.c:1571-1572`); Spock
  takes the max of both (`src/spock_apply.c:3709-3718`). These are LSNs of
  records P has decoded, so already flushed on P.
- Keepalives: `WalSndKeepalive` sends `sentPtr` unless a write pointer is
  given (`walsender.c:4116-4125`); `sentPtr` is the end of the last decoded
  record (`:3487`) or, right after `START_REPLICATION`, the slot's
  `confirmed_flush` (`:1526`). The explicit-pointer case (`:1721`) passes
  the current record LSN.
- Worker start: `reconcile_progress_with_origin` may seed it with the
  origin's `remote_lsn` (`src/spock_progress_recovery.c:197-200, 226-229`),
  also a P LSN that P already sent.

The one indirect path above P's WAL is the startup keepalive echoing
`confirmed_flush`, which is whatever the subscriber last reported; a bogus
report (for example from a misparse) would come back as `received_lsn`.
That is a defect either way, so it is fine for this check to fire.

`remote_insert_lsn` under v5 is `GetXLogWriteRecPtr()`: written, not
necessarily flushed. A process kill keeps written WAL in the OS page cache,
so P comes back at or past it; only a lost page cache (VM-level loss) can
push P below it. The `maxP` rule already covers what the workload observed.

Promoted standbys are not in the planned topology; that question is out of
scope and removed.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (coverage-balance F8); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: reconnect plus a data error (see `proto5-replay-reparses-startup-message`)

- Priority note: lowered from P1 in evaluation: `spock.progress` is monitoring in steady state, and the only known cause is the protocol-5 replay misparse; this runs as that property's workload consequence check and as a passive guard on v4 links.
- Kept as its own property (it is also a passive guard for v4 COMMIT-suffix parsing in mixed-version runs) but lowered to P2 and described as the consequence check of `proto5-replay-reparses-startup-message`.

## Open questions

- None.

### Investigation Log

#### Can `received_lsn` legitimately exceed P's insert LSN?

- Examined: PG18 `walsender.c` (`WalSndPrepareWrite` :1560-1575,
  `WalSndKeepalive` :4116-4130, `StartLogicalReplication` :1520-1530,
  `XLogSendLogical` :3450-3530, `WalSndUpdateProgress` :1700-1725);
  `src/spock_apply.c:3700-3780`; `src/spock_progress_recovery.c:153-275`.
- Found: every source is a P LSN already decoded/sent or the slot's
  confirmed position.
- Not found: a legitimate path above P's WAL.
- Conclusion: resolved; keep both columns.

#### Should the comparison account for a promoted standby?

- Examined: planned topology in the catalog (no physical standbys in v1).
- Conclusion: out of scope for v1; removed.
