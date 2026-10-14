# insert-race-resolved-not-discarded

## What led here

Concurrency focus (F3 note `discovery/03-concurrency.md` F2; sut-analysis lead
L6a). Only one discovery focus found it, so the synthesis marks it "[F3 only]".
Re-read for this property at HEAD 69d9228f; the mechanism is present as
described. Not run.

## Code path

- `spock_apply_heap_insert` (`src/spock_apply_heap.c:837`).
  1. `FindReplTupleInLocalRel(...)` (`:879`), which ends up in
     `SpockRelationFindReplTupleByIndex` (`src/spock_common.c:334-480`). It uses
     a dirty snapshot (`InitDirtySnapshot`, `:395`); if it sees an in-progress
     inserter it waits (`XactLockTableWait`, `:428`) and retries. So a writer
     that already has its index entry in place is handled.
  2. If not found: `ExecSimpleRelationInsert` (`:~925`). No retry, no
     `ON CONFLICT`. Source comment at `:873-876`:
     `TODO: do we need a retry finding a tuple? Also do we need
     wait_for_previous_transaction() call here?`
- The window is between step 1 returning "not found" and step 2 inserting the
  index entry. A second writer that inserts the same key inside that window
  makes step 2's unique check wait for it and then raise **23505
  unique_violation**.
- Who can be the second writer:
  - another apply worker on the same node (a different upstream) applying an
    INSERT of the same key;
  - a local client session.
- `apply_work` `PG_CATCH` (`src/spock_apply.c:3867-4133`): only connection
  class codes, 40P01, 55P03 and class 53 are retried (`:3920-3990`). 23505
  falls through to the "first data error" branch: `AbortOutOfAnyTransaction()`
  (`:4065`), log `caught initial exception` (`:4068`), replay under
  `spock.exception_behaviour`.
  - TRANSDISCARD (default): replay read-only, each row of the upstream
    transaction written to `spock.exception_log`, origin advanced past the
    transaction. **The whole upstream transaction is dropped on this node.**
  - SUB_DISABLE: subscription disabled.
- Same shape for `update_exists` (`src/spock_apply_heap.c:731-745`): an UPDATE
  whose new key collides with a row inserted concurrently. The v1 workload does
  not update key columns, so this variant is out of scope unless added on
  purpose.

## What should happen instead

Documented conflict handling (`docs/conflict_types.md:46-49`): `insert_exists`
is resolved by last-update-wins and applied as an UPDATE. A re-lookup after the
23505 would turn the race into exactly that. Today the outcome depends on
timing: the same pair of writes is resolved if the second writer was already
visible at lookup time, and discarded if it arrived a few microseconds later.

## Failure scenario (3-node mesh)

1. Workload inserts key K on n1 and, at about the same time, on n2 (or on n3
   itself, as a local write).
2. n3's apply workers for n1 and n2 both look up K, both miss.
3. Worker A inserts and commits; worker B's insert waits on A, then gets 23505.
4. B's whole transaction (possibly many other rows) is logged to
   `exception_log` and dropped on n3. n1 and n2 resolved the conflict by LUW.
5. If B's transaction also carried other, conflict-free rows, those rows are
   missing on n3 for good. If B's version of K was the LUW winner, n3 keeps the
   loser.

## Invariant

- Workload-side `Always`: in a run whose only conflicts are same-primary-key
  INSERTs (one unique index per table: the PK), no row in
  `spock.exception_log` on any node has `error_message` matching
  `duplicate key value violates unique constraint`. Checked after each
  quiescent barrier. `Always` because any such row means a resolvable conflict
  was turned into a dropped transaction.
- Workload-side `Always` (convergence companion): per-row comparison of the
  insert-race table across nodes after quiescence; every key holds the same
  `(node, seq)` payload on all nodes.
- Suggested SUT-side assertion (**missing**, no instrumentation exists):
  `Unreachable("apply insert lost unique-key race to concurrent writer")` in
  `apply_work` `PG_CATCH` when `edata->sqlerrcode == ERRCODE_UNIQUE_VIOLATION`
  and the failing action is an INSERT on a relation whose only unique index is
  the replica-identity index (so legitimate multi-unique-index collisions,
  which the workload excludes anyway, do not trip it).
- Suggested SUT-side `Sometimes("apply insert found row inserted by concurrent
  upstream")` in `spock_apply_heap_insert` when `found` is true **and** the
  local tuple's origin (from `get_tuple_origin`) is a different remote node than
  the current remote origin. Shows the workload is producing real cross-upstream
  same-key traffic, which makes the `Unreachable` meaningful.

## Fault / timing requirements

- No faults strictly needed; it is a timing race. Thread pausing / CPU
  modulation widens the lookup-to-insert window.
- Network latency changes so the two upstream streams arrive at n3 at the same
  time; `spock.output_delay` can also align arrival.
- Workload: many concurrent same-key inserts from at least two nodes, keys drawn
  from a small shared pool, plus some local inserts on the third node.
- Must be the only conflict type in the checked table: no deletes (no
  tombstones, §12), no cross-node update-after-insert (update_missing, §12).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW9, coverage-balance F12); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: latency, thread pause

- Evaluation note (2026-10-13): the window ends at the unique check inside core `ExecSimpleRelationInsert`, which thread pausing does not reach while core is uninstrumented; latency and CPU modulation are the drivers. Optional SUT-side `Sometimes("update_missing retry found the row on a later attempt")` (L6c: the retry wait returns at once) shows whether the retries ever help; if never, that is a documentation finding.

## Open questions

- Is the TRANSDISCARD-on-race outcome an accepted limit, or should the INSERT
  path retry as `insert_exists` (as the TODO suggests)? If accepted, this
  property becomes a documented-limit check and should be downgraded to
  `Sometimes` (to measure how often it happens) instead of `Always`. If not
  accepted, it stays `Always` and is a real bug finder. `(needs human input)`
- How wide is the window in practice? `(partial: by code reading it runs from
  the end of the dirty-snapshot index scan to the unique check inside
  `ExecInsertIndexTuples`, so it covers the heap insert, BEFORE ROW triggers
  and constraint checks; nothing serialises apply workers of different
  upstreams outside slot groups; not yet seen in a run)`

## Resolved

- **`spock.check_all_uc_indexes=on` has the same gap.** `FindReplTupleByUCIndex`
  runs after the replica-identity lookup misses (`src/spock_apply_heap.c:885-892`),
  then the same unguarded `ExecSimpleRelationInsert` follows (`:906-921`). A
  race on any unique index gives 23505 the same way. Out of v1 scope; no
  property change.

### Investigation Log

#### Is the TRANSDISCARD-on-race outcome an accepted limit?

- Examined: `src/spock_apply_heap.c:837-930` (insert path and the TODO),
  `:725-770` (UPDATE path: 23505 only reported as `update_exists`, then
  rethrown), grep for `ERRCODE_UNIQUE_VIOLATION` in `src/` (only that UPDATE
  site), `src/spock_apply.c:3916-3994` (classifier), `docs/conflict_types.md`,
  `git log -S "do we need a retry finding a tuple"` (present since the source
  tree restructure d0498a2c; older history not in this repo).
- Found: no code anywhere turns a 23505 on the insert path into an
  `insert_exists` resolution; the TODO shows the authors knew of the gap. Docs
  promise last-update-wins for `insert_exists` with no timing caveat.
- Not found: any doc or commit saying the race is accepted.
- Conclusion: `(needs human input)`.

#### How wide is the window in practice?

- Examined: `spock_apply_heap_insert` (`:879-921`), `SpockRelationFindReplTupleByIndex`
  (`src/spock_common.c:395-430`), `wait_for_previous_transaction` (dormant
  unless slot groups).
- Found: lookup and insert are separate steps with no lock held on the key in
  between; the unique check waits for the other inserter and then raises 23505
  if it committed. Apply workers for different upstreams run in parallel.
- Not found: run evidence of how often it happens.
- Conclusion: partial; needs a run (the suggested `Sometimes` marker will show
  it).

#### Does check_all_uc_indexes change the gap?

- Examined: `src/spock_apply_heap.c:885-921`.
- Found: same find-then-insert sequence, no retry.
- Conclusion: resolved; same gap, out of v1 scope.
