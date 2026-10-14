# cross-pg-major-links-replicate-identically

## Summary

Spock claims PostgreSQL major upgrades can be done as a rolling upgrade "by
adding a new node with the new major PostgreSQL version, and then removing old
nodes" (`docs/spock_release_notes.md:~828-832`, v5.0 notes). During that time
the cluster has links between different PG majors. Property: on a link whose
two ends run different PG majors, every replicated row arrives with the same
value (per-column text equality) and exactly once, as on same-major links.
**Needs a mixed-PG-major topology.** Low priority.

## What changes across PG majors (code-checked)

- Datum transfer format: the subscriber asks for binary
  (`binary.want_internal_basetypes`, `binary.want_binary_basetypes`,
  `binary.basetypes_major_version = PG_VERSION_NUM/100`, sizes, endianness;
  `spock_start_replication`, `src/spock.c:706-731`). The publisher allows
  internal or binary basetypes only when the major matches
  (`check_binary_compatibility`, `src/spock_output_plugin.c:166-185`; and
  `:494-499`). So cross-major links always use text output/input
  (`decide_datum_transfer`, `src/spock_proto_native.c`), and same-major links
  use binary. That is a separate code path per link.
- Structure sync refuses a newer-major upstream
  (`upstream_version_supports_structure_sync`, `src/spock_sync.c:364-392`,
  1573-1595), so the new node must be the newer major. pg_dump/pg_restore must
  match the subscriber's major (`src/spock_sync.c:158-167`).
- Feature differences by major in the same Spock build: conflict stats only on
  PG18+ (`src/spock_conflict_stat.c:27, 295`), failover-slots worker only on
  PG15-17, `FAILOVER` slot option only when the provider is PG17+
  (`src/spock_sync.c:720, 739`), row filters need an active snapshot only
  below PG18 (`src/spock_output_plugin.c:987-1020`).
- Each PG major has its own core patch set (`patches/<major>/`); patch 025
  (logical commit clock) differs per major.

## Invariant

- `Always` (workload, at quiesce): for each replicated table, the ordered
  per-row text dump (`SELECT ... ORDER BY pk` with `::text` casts) is equal on
  nodes of different majors, and the ledger is exactly-once on cross-major
  links.
- `Sometimes(a cross-major link applied a transaction)` so the text path ran.

## Is it worth it?

Probably not in Antithesis. The risk is type text round-trips and the
procedure, both mostly deterministic; faults add little that the same-major
mesh does not already cover. `tests/run-cluster-upgrade.sh` (nightly) runs a
rolling `pg_upgrade` with an ACE diff. A cheaper way to cover the text path in
the planned single-version topology is to create one subscription with
`force_text_transfer = true` (`sub_create` option), which uses the same
publisher-side text encoding without a second PG build. Consider that
instead.

## Fault requirements

Same as the mesh ledger property.

## Resolved questions (see Investigation Log)

- Cross-major clusters are a transition state, not a design target:
  `docs/limitations.md:147-158` says "long term cross-version replication is
  not considered a design target, though it may often work", that old-to-new
  is safer than new-to-old, and that changes "valid on the provider but not
  on the subscriber are more likely". So the property only needs to hold
  during the add-node / remove-node transition, and **new-major to old-major
  links may legitimately reject a value** the old major cannot parse. Scope
  change: either restrict the equality check to old-to-new links, or keep the
  workload's column types and values to ones both majors accept, and treat an
  apply error on a new-to-old link as expected rather than a failure.
- `force_text_transfer = true` runs the same Spock code as a cross-major link.
  It only makes the subscriber send `binary.want_internal_basetypes '0'` and
  `binary.want_binary_basetypes '0'` (`src/spock.c:691, 708-709`); a
  cross-major link gets the same result because the publisher sets
  `allow_internal_basetypes` via `check_binary_compatibility` and
  `allow_binary_basetypes` only when the major matches
  (`src/spock_output_plugin.c:490-500`). Either way `decide_datum_transfer`
  (`src/spock_proto_native.c:641-671`) returns `'t'` for every column, and the
  subscriber's `'t'` branch (`:1061`) is the same. The one thing
  `force_text_transfer` cannot cover is PostgreSQL's own type text
  compatibility between two majors, which is outside Spock. Recommendation
  stands: use one `force_text_transfer` subscription in the single-version
  topology instead of a mixed-major build.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (TAP territory)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P3 · Topology: v2/mixed-pg-major · Faults: none required

- Priority note: lowered from P2 in evaluation: the risk is deterministic type round-trips; cover it with the `force_text_transfer` message in `replicated-values-mean-same-on-every-node` plus a TAP round-trip test, and run this only if the mixed-major topology is built anyway.

## Open questions

None remaining.

### Investigation Log

#### Is a cross-major cluster supported as a steady state?

- Examined: `docs/limitations.md` "PostgreSQL Version Differences";
  `docs/spock_release_notes.md:~826-832` (v5.0 rolling major-upgrade claim).
- Found: limitations doc says not a design target for the long term; safer
  old-to-new; initial schema sync only same or lower-to-higher.
- Conclusion: resolved. Transition-only; new-to-old apply errors on values
  the old major rejects are expected, which narrows the property.

#### Does `force_text_transfer` exercise the same subscriber input path as a cross-major link?

- Examined: `spock_start_replication` `src/spock.c:683-731`; uses of
  `force_text_transfer` (`src/spock_apply.c:4770`, `src/spock_sync.c:2081`,
  catalog code in `src/spock_node.c`); publisher startup
  `src/spock_output_plugin.c:485-500`; `decide_datum_transfer` and the
  subscriber's per-column format switch `src/spock_proto_native.c:641-671,
  986-1061`.
- Found: the option has no other effect than the two `want_*` flags; both
  configurations end with every column sent as `'t'` and read by the same
  branch.
- Not found: a run confirming it (reading only).
- Conclusion: resolved by code reading.
