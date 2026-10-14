# truncate-ordered-with-same-origin-dml

Surfaced by evaluation gap (c), item 1 (coverage-balance F11). Code checked
at 69d9228f.

## What the property says

On a table written by one origin only, TRUNCATE and the INSERTs around it
reach every peer in the origin's commit order: after a barrier, each
peer's copy of the table equals the origin's (the rows inserted after the
last TRUNCATE, no more, no fewer), under faults.

Today the workload bans TRUNCATE in conflict phases (sut-analysis §12) and
no property exercises the 'T' message. A single-owner table removes the
cross-origin ordering problem (TRUNCATE has no timestamp and is not part of
LUW), so TRUNCATE can stay in the workload while faults run.

## Code paths

- Provider: `pg_decode_truncate` (`src/spock_output_plugin.c:~1150-1196`)
  skips in slot-group skip mode and in repair mode, keeps relations for
  which some replication set on the node has `replicate_truncate`, sends
  'R' then one 'T' with the relids and `cascade` / `restart_seqs` flags.
- Subscriber: `handle_truncate` (`src/spock_apply.c:2135-2210`) and
  `apply_truncate` (`:2028-2130`):
  - normal path: `apply_truncate`, AccessExclusiveLock on each relation,
    partitioned tables expanded to leaves, tables still in table sync are
    skipped (`should_apply_changes_for_rel`), `ExecuteTruncateGuts` with
    DROP_RESTRICT (CASCADE is not replayed; documented in
    `docs/limitations.md:103-115`).
  - exception replay, TRANSDISCARD / SUB_DISABLE: the TRUNCATE is skipped
    and logged as "TRUNCATE" in `exception_log` (fix 940e500d).
  - exception replay, DISCARD: run in a subtransaction; on failure the
    Spock relation cache is reset (stale `->rel` handles) and only the
    TRUNCATE is discarded (fix 162dc562, TAP 031).
- Bug history in this exact function: 940e500d, 162dc562, 8faf9e97, plus the
  replay-queue use-after-free family (f84b853d). Each fix closed one
  exception-path ordering; faults that push a TRUNCATE-bearing transaction
  through replay, cancel, or restart are what would find the next one.

## Failure scenarios the property catches

- A TRUNCATE transaction dropped by a misclassified transient error on one
  peer: that peer keeps the pre-truncate rows (extra rows) and the
  exception log shows "TRUNCATE".
- A TRUNCATE applied but a following INSERT batch dropped, or the reverse
  order after a reconnect (framing / replay-queue bugs): missing rows.
- Redelivery after a subscriber crash (L1): the TRUNCATE and everything
  after it are applied again in order, which ends in the same state, so
  this property should pass there. A failure on a redelivery timeline
  points at partial redelivery (a TRUNCATE replayed without the later
  inserts, or the reverse).
- A TRUNCATE arriving while the table is in table sync on that peer is
  skipped by apply; the sync's COPY or catch-up must cover it. A resync of
  this table during faults (the implementability evaluation already asks
  for single-writer resync tables) reaches that.

## Workload and oracle

- One table per origin node, `trunc_<node>` (PK only, no FK), in the
  default replication set, written only on its owner.
- On the owner, a mix of: insert batches; `TRUNCATE trunc_<node>` alone;
  `BEGIN; TRUNCATE; INSERT ...; COMMIT`; `BEGIN; INSERT ...; TRUNCATE;
  INSERT ...; COMMIT`. Each row carries `(epoch, seq)`, where the workload
  bumps `epoch` with each TRUNCATE it commits. Unknown-outcome commits are
  settled by reading the owner.
- After the barrier from owner to every peer:
  `Always("single-owner table after TRUNCATE has the same rows on every
  peer as on its owner")` — compare the peer's ordered checksum (or
  `(epoch, seq)` set) with the owner's.
- Companions: `Sometimes("TRUNCATE applied on a peer within a transaction
  that also inserted")` (workload sees the mixed transaction's rows),
  `Sometimes("TRUNCATE-bearing transaction passed through exception replay")`
  (workload sees an `exception_log` row with operation TRUNCATE; with
  `transdiscard` this also means the peer diverged unless the whole
  transaction was consistently discarded, which the property then flags
  through `exception-log-matches-discarded-transactions`).
- Exclude `trunc_*` tables from the ledger and LUW checks (rows disappear
  by design).

## Fault requirements

Worker exit (cancel / terminate apply during a TRUNCATE-bearing
transaction), walsender kill and reconnect, subscriber node kill between
checkpoints (L1 redelivery), lock contention from workload readers that
hold AccessShareLock on the table (apply waits; lock_timeout errors are
retried per the classifier).

## Instrumentation

All missing. Optional SUT-side `Reachable` markers in `handle_truncate` for
"TRUNCATE skipped in TRANSDISCARD replay" and "TRUNCATE skipped: table in
sync" so triage can see which branch ran.

## Second-pass refinements (2026-10-13)

From the second evaluation pass on the gap-fill properties; see `evaluation/synthesis.md` "Second pass (gap-fill)".

- Workload boundary: Assumption 5 bans TRUNCATE in conflict phases; the
  `trunc_<node>` tables are single-owner and excluded from the ledger,
  delta, contested and convergence checks, so the ban stays for shared
  tables.

## Open questions

- Is a TRUNCATE-only redelivery possible (origin advanced past the
  TRUNCATE but not past later inserts of the same transaction)? No path
  found; all are in one transaction and the origin advances at commit.
  `(partial: none found; all are in one transaction and the origin advances at commit)`
- Should TRUNCATE respect the subscription's replication sets? It does not
  today (see "deterministic finding" in the gap-c discovery file). Not
  reachable in v1 because every subscription uses the same default sets.

### Investigation Log

#### Can a TRUNCATE be redelivered without the inserts after it?

- Examined: `handle_truncate` (`src/spock_apply.c:2135-2210`), origin
  advance in `handle_commit` (`:997-1009`), `pg_decode_truncate`
  (`src/spock_output_plugin.c:1147-1196`).
- Found: the TRUNCATE and the inserts after it are in one remote
  transaction; the origin moves only at that transaction's commit, so a
  redelivery resends all of it.
- Not found: a path that advances the origin between changes of one
  transaction.
- Conclusion: `(partial: none found; all are in one transaction and the origin advances at commit)`.
