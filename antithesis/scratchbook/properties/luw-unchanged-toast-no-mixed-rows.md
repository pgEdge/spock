# luw-unchanged-toast-no-mixed-rows — Conflict winners never mix in the loser's TOAST value

## Synthesis note

Merged from `luw-unchanged-toast-no-mixed-rows` (F11) and
`unchanged-toast-column-no-hybrid-rows` (F4). Same mechanism, found
independently: the provider sends unchanged out-of-line values as `'u'`
(`src/spock_proto_native.c:515-519`), and when the remote UPDATE wins LUW the
subscriber fills them from its **local** row (`slot_modify_data`,
`spock_handle_conflict_and_apply`, `src/spock_apply_heap.c:636-640`), leaving a
row that no single transaction wrote.

Oracles combined: F4 records each update's full post-image via `RETURNING` and
checks `(ver, small, md5(big))` against it; F11 writes the same `<node>:<seq>`
tag into the small column and the TOAST payload and checks they match within a
row, plus cross-node equality. Both are `Always`; the F11 tag check needs no
post-image bookkeeping, the F4 check is immune to L2/L3 winner changes. Keep
both messages. Two independent focuses reaching the same mechanism raises
confidence to high.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (TAP territory), wildcard W2); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: latency, partition (no clock or kill needed)

- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
- Evaluation note (2026-10-13): the state can be forced in TAP (disable the two subscriptions, update the TOAST column on one node and a small column on the other, re-enable). Under Antithesis it happens naturally under latency, so it stays as a P0 regression check that needs no clock or kill. P0 reflects severity.

## Open questions

- Is the partial-row merge on remote-wins with an unchanged TOAST column known and accepted? (Inherited unchanged from pglogical; not documented in either.) `(needs human input)`

Resolved (see log): `REPLICA IDENTITY FULL` and `log_old_value` do not
change the outcome (the new tuple still carries `'u'` and the subscriber
never uses the old tuple to fill it). Delta-apply columns do not add a new
kind of mix; a delta applied on top of a remote win inherits the same mixed
base row, and a delta forced on a local win uses the whole local row. Keep
delta columns out of this table anyway so the oracle stays simple.

Side lead (not verified, not part of this property): a delta column of type
`numeric` large enough to be stored out of line and left unchanged by an
UPDATE would arrive as `'u'`, and `build_delta_tuple`
(`src/spock_apply_heap.c:563,574`) would pass the `0xfbadbeef` placeholder
from `newtup->values` to `delta_apply_numeric`. Needs a >2 kB numeric, so
unlikely in practice.

## Source: `luw-unchanged-toast-no-mixed-rows` (F11 Wildcard)

### Why this property exists

Spock claims whole-row last-update-wins: "the version of data with newest
commit timestamp is kept" (`docs/conflicts.md:60-64`). The UPDATE path does
not send whole rows when a column is TOASTed and unchanged. The subscriber fills
those columns from its **local** row, even when the remote row wins the
conflict. So the "winning" row on one node can be a mix of the remote change and
a local TOAST value that the winning transaction never wrote. Nothing in
`docs/` mentions this; `docs/internals-doc/OUTPUT.md:510-517` only says that
unchanged TOAST fields are omitted from UPDATE messages.

Existing workloads (spockbench, pgbench-style scripts, TAP tests) use small
rows, so this path has probably never run under concurrent conflicting updates.

### Code path (HEAD 69d9228f)

- Provider, `src/spock_proto_native.c:515-519` (`spock_write_tuple`): any
  varlena column whose datum is `VARATT_IS_EXTERNAL_ONDISK` in the decoded new
  tuple is sent as `'u'` (unchanged). Logical decoding reassembles TOAST values
  changed by the transaction, so `'u'` means "this UPDATE did not change it".
- Subscriber, `src/spock_proto_native.c:982-985`: `'u'` leaves
  `changed[attid] = false`.
- `spock_handle_conflict_and_apply`, `src/spock_apply_heap.c:589-640`: after
  `try_resolve_conflict` returns apply-remote (`applytuple == remotetuple`), it
  calls `slot_modify_data(remoteslot, localslot, rel, newtup)`.
- `slot_modify_data`, `src/spock_apply_heap.c:338-383`: copies **every** column
  from the local slot, then overwrites only the `changed` ones. Unchanged TOAST
  columns keep the local value.

### Failure scenario (3 nodes, no faults needed beyond ordering)

Row `r(id, small, big)` starts as `(1, s0, B0)` everywhere; `big` is stored
out of line.

1. n1 at t1: `UPDATE r SET big = B1` (sends full `big`).
2. n2 at t2 > t1, before n1's change arrives: `UPDATE r SET small = s2` (sends
   `big` as `'u'`).
3. n1 receives n2's change: t2 > t1, remote wins, `big` filled from local B1 ->
   **(s2, B1)**.
4. n2 receives n1's change: t1 < t2, local wins -> **(s2, B0)**.
5. n3 ends as (s2, B1) or (s2, B0) depending on arrival order.

Final state: nodes disagree on `big`, permanently. Each node's state is the
result of a resolved conflict. These are `update_origin_differs` events, which
are never written to `spock.resolutions` (`src/spock_conflict.c:393-419`;
documented in `docs/conflict_types.md:53-73`), so no Spock table explains the
difference.

Related effect: once a node's TOAST column has diverged for any reason (for
example a TRANSDISCARD-dropped transaction), later UPDATEs that do not touch
that column never repair it, because they never carry it.

### Property

After quiescence, for every row of a table that has out-of-line TOAST
columns, all nodes hold identical values in all columns, and the row equals a
version that one transaction actually produced (checked through a per-update
version tag written into both the small and the TOAST column).

- Assertion: workload-side `Always` at each quiescent convergence check.
  Suggested messages: "toast rows identical across nodes after quiesce" and
  "toast row version tags consistent within the row".
- SUT-side (missing, no existing assertions): a `Reachable` in
  `slot_modify_data` when the remote won a conflict and at least one column was
  filled from the local slot because `changed == false` on a varlena column.
  That marks the risky branch for Antithesis exploration.

### Workload requirements

- A table `doc(id pk, tag text, blob text)` with `ALTER COLUMN blob SET STORAGE
  EXTERNAL` (or random incompressible payloads of 4 KB or more) so values really
  go out of line. Compressible values under about 2 KB stay inline and are sent
  in full, which hides the bug.
- Each update writes a version tag `<node>:<seq>` into `tag`, and optionally
  updates `blob` to a payload that embeds the same tag. Mix "tag-only" and
  "tag+blob" updates on the same keys from at least two nodes concurrently.
- Check: `tag` and the tag embedded in `blob` belong to the same version, or
  `blob` was last written by an update that `tag`'s writer saw. The simple
  version is the cross-node equality check; the stronger per-row check needs
  the harness to know which updates touched `blob`.

### Fault requirements

None strictly. Network latency or partitions between node pairs widen the
window in which two nodes update the same row before seeing each other's
change. Clock jitter changes which side wins but not whether a mix occurs.

### Scoping against expected behaviour (sut-analysis §12)

- Use primary keys, no deletes on these rows (avoids no-tombstone and
  `update_missing` cases).
- Use rows inserted before the conflict phase and replicated everywhere first
  (sync_event barrier), so `update_missing` cannot occur.
- Different winners because of clock skew are expected; **different values on
  different nodes** are not, per sut-analysis §12.

### Confidence

High that the mechanism exists (code read end to end, 'u' encoding and the
merge from `localslot` confirmed). Medium on the exact numbers needed to make it
show up (TOAST threshold, compression), which the workload controls.

### Original open-question notes (detail for the combined list above)
- Is the partial-row merge intended or known? If it is a known limitation, the
  property should still be kept but labelled as a documented-gap detector, and
  the workload may need a switch to turn TOAST tables off for the main
  convergence check. If it is not intended, it is a convergence bug with no
  log trail.
- Does `REPLICA IDENTITY FULL` change what the provider sends for unchanged
  TOAST columns? Not examined; v1 workload avoids `REPLICA IDENTITY FULL`
  anyway. If it does send them, a fix could tell users to set it on TOAST
  tables.
- With delta-apply columns in the same table, the merge also feeds
  `build_delta_tuple`; not examined further.

## Source: `unchanged-toast-column-no-hybrid-rows` (F4 Protocol)

### Summary

Spock claims whole-row last-update-wins: "the version of data with newest commit
timestamp is kept" (`docs/conflicts.md:60-64`), and every node ends with that
version. The wire format does not always carry the whole new row. For an UPDATE
that leaves a large column untouched, that column's new value is a TOAST
pointer, and the output plugin sends the marker `'u'` (unchanged) instead of the
value. The subscriber fills `'u'` columns from **its own local row**. When the
remote UPDATE wins a conflict against a different local version, the result is
a row that no node ever wrote: the winner's small columns plus the loser's large
column. Nodes then differ permanently, and nothing is logged
(`update_origin_differs` is not persisted, see
resolutions-rows-match-applied-outcome).

### Code paths

- Provider: `spock_write_tuple` `src/spock_proto_native.c:~490-530`:
  `att->attlen == -1 && VARATT_IS_EXTERNAL_ONDISK(value)` -> `'u'`. Logical
  decoding only re-assembles TOAST values that were written in the transaction,
  so an unchanged out-of-line value stays an on-disk pointer in the new tuple.
- Subscriber read: `spock_read_tuple` `:982-985`: `'u'` -> `changed[att] =
  false`.
- Merge: `slot_modify_data` `src/spock_apply_heap.c:338-385` copies the local
  row and overwrites only `changed` columns.
- Conflict path: `spock_handle_conflict_and_apply` `:589-780`; when the remote
  side wins, `slot_modify_data(remoteslot, localslot, rel, newtup)` at `:639`.
  This path runs for every remote UPDATE (`:905`, `:1009-1014`), so the merge
  always uses the local row as the base.
- The internals doc admits partial rows: "Unchanged fields can only be
  identified and omitted if they're a variable length TOASTable type and are
  big enough to get stored out-of-line" (`docs/internals-doc/OUTPUT.md:512-517`).
  No doc ties this to conflict resolution.
- Regression coverage: `tests/regress/sql/toasted.sql` is single-writer only.

### Failure scenario (lead, unconfirmed by a run)

Row k exists on n1 and n2 as `(small = s0, big = B0)`, `big` stored out of line.

1. n1: `UPDATE t SET big = B1 WHERE id = k` at ts 10. Sent with `big = B1`
   (changed, so re-assembled) and `small = s0`.
2. n2: `UPDATE t SET small = s2 WHERE id = k` at ts 20. Sent with
   `small = s2`, `big = 'u'`.
3. n1 applies n2's change: remote ts 20 > local ts 10 -> apply remote ->
   `small = s2`, `big` taken from n1's local row = B1. Row = `(s2, B1)`.
4. n2 applies n1's change: remote ts 10 < local ts 20 -> keep local. Row =
   `(s2, B0)`.

The documented winner is n2's version `(s2, B0)`. n1 holds `(s2, B1)`
forever. A third node ends with either value depending on arrival order.

### Invariant

Workload-side `Always` ("every final row equals the post-image of the update
named in its version column"):

- Table `toast_luw(id pk, ver text, small text, big text)` with
  `ALTER COLUMN big SET STORAGE EXTERNAL` (or incompressible values > 2 kB).
- Every UPDATE sets `ver = '<node>:<seq>'` plus **either** `small` **or** `big`,
  and uses `RETURNING ver, small, md5(big)` to record its post-image.
  Inserts are done once and quiesced before updates start, so no
  `update_missing`; no deletes on this table.
- After quiescence and per-pair barriers, on every node:
  `(ver, small, md5(big))` must equal the recorded post-image for `ver`.

This oracle does not depend on who wins: clock skew (L3) or tiebreak issues
(L2) choose a different winner but still leave a whole row someone wrote. Only a
mixed row fails it. A second, weaker message ("toast_luw rows identical on all
nodes") can be added, but it would also fire on L2/L3.

Companion `Sometimes`: "remote UPDATE with an unchanged TOAST column won a
conflict against a different local version" (SUT-side, in
`spock_handle_conflict_and_apply` when `apply && local origin differs && any
!newtup->changed[att]`) — missing, would mark the path as reached.

### Fault requirements

None strictly. Concurrent updates of the same rows from two nodes; latency or
short partitions between node pairs make the cross-over in steps 3-4 likely.

### Original open-question notes (detail for the combined list above)
- Is a merged row on remote-wins with an unchanged TOAST column known and
  accepted? If accepted, this belongs in the workload boundaries (sut-analysis
  §12) and the property should be dropped; if not, it is a convergence bug.
  `(needs human input)`
- Does `REPLICA IDENTITY FULL` or `log_old_value` on the large column change
  what the provider sends for it? Code reading says no (the new tuple still
  holds the pointer), but a quick test would settle it.

### Investigation Log

#### Is the partial-row merge known and accepted?

- Examined: `docs/` (conflicts, conflict_types, limitations, internals-doc
  OUTPUT.md), `tests/regress/sql/toasted.sql`, `~/dev/pglogical`
  (`pglogical_proto_native.c:407,765`).
- Found: the `'u'` encoding and fill-from-local merge come unchanged from
  pglogical. Only `docs/internals-doc/OUTPUT.md:510-517` mentions omitted
  unchanged TOAST values; nothing links it to conflict resolution. The only
  TOAST regression test is single-writer.
- Conclusion: `(needs human input)`.

#### Does `REPLICA IDENTITY FULL` or `log_old_value` change what is sent?

- Examined: `spock_write_tuple` (`src/spock_proto_native.c:500-520`),
  `spock_read_tuple` (`:975-990`), all writes to `changed[]` in `src/`
  (`grep -n "changed\["`), `slot_modify_data` (`src/spock_apply_heap.c:338-383`).
- Found: the provider decides `'u'` from the **new** tuple's datum alone
  (`VARATT_IS_EXTERNAL_ONDISK`). Replica identity only affects the old tuple
  (PostgreSQL flattens it for FULL); logical decoding only re-assembles TOAST
  values written by the transaction, so the new tuple still holds a pointer.
  On the subscriber nothing copies old-tuple values into unchanged new-tuple
  columns; `slot_modify_data` always fills them from `localslot`.
  `log_old_value` only drives `build_delta_tuple` for delta columns.
- Conclusion: resolved: no, neither setting avoids the merge. Not run.

#### Does the merge also feed `build_delta_tuple` wrongly?

- Examined: `spock_handle_conflict_and_apply` (`src/spock_apply_heap.c:589-700`),
  `build_delta_tuple` (`:510-580`), `sql/spock--6.0.0.sql:869-882`.
- Found: delta functions exist only for int2/int4/int8/float4/float8/numeric/money.
  `build_delta_tuple` sets `changed` only for delta columns; the base row is
  `remoteslot` (already merged) when remote wins, else the whole local row.
- Conclusion: resolved: no new kind of mixing; the remote-wins mix is carried
  through unchanged. Side lead on out-of-line `numeric` noted above.
