# mixed-version-mesh-applies-exactly-once

## Summary

Spock claims mixed 5.0.x / 6.0 clusters are a supported rolling-upgrade
state: "protocol negotiation (v4 for 5.0.x, v5 for 6.0+) enables zero-downtime
rolling upgrades" and "a v6.0 subscriber can apply from a v5 publisher and vice
versa" (`docs/spock_release_notes.md:24-25, 216-224`). The property: in a mesh
where some nodes run 5.0.11 and some run 6.0, the same ledger and convergence
properties used for the single-version mesh hold on every link, under the same
faults. **Needs a mixed-version topology** (two builds).

## Why the mixed state is different code, not just "the same code twice"

- Links that touch a 5.0.x node negotiate protocol 4. On the 6.0 side this
  runs the v4 branches that a 6.0-only cluster never executes:
  `spock_write_commit` puts `remote_insert_lsn` at the end of COMMIT
  (`src/spock_proto_native.c:264-265`); `spock_read_commit` reads it there
  (`:732-735`); `apply_work` sets `last_inserted = last_received` for other
  messages (`src/spock_apply.c:3747-3750`); ORIGIN carries no name
  (`:276-300`), so forwarded-origin name handling falls back.
- The 5.0.x side runs older code with different behaviour that matters for
  the oracle:
  - DELETE conflict handling: 5.0 applied a DELETE that found a row without
    timestamp resolution; 6.0 resolves it (`delete_exists`)
    (`docs/spock_release_notes.md:~155-161`). This only changes outcomes for
    delete-vs-newer-update races, which are already excluded by the
    no-tombstones boundary (sut-analysis §12). Keep them excluded.
  - Equal-timestamp tiebreak: 5.0.9 compares the local tuple's origin; 5.0.10+
    and 6.0 compare the applying node (`git show v5.0.9:src/spock_conflict.c`
    ~441-453 vs HEAD `src/spock_conflict.c:131-200`; backport 0c98c7e3 is in
    v5.0.10+). Use 5.0.11 for the old build so only the L2 issue remains.
  - Progress: 5.0.x keeps `spock.progress` as a table flushed about once a
    second with column `remote_lsn`; 6.0 uses shared memory and
    `remote_commit_lsn` (`sql/spock--5.0.11--6.0.0.sql` drops the table).
  - Which 6.0 fixes are on 5.0.11 (corrected by subject search; the earlier
    `merge-base --is-ancestor` check could not see cherry-picks):
    backported and in v5.0.11: dcbba6bb pause (2503b2c1), fdd9587e
    non-transactional sync_event (066b43da), 64ea462d tiebreak (0c98c7e3).
    Not backported: 2f9a686c (progress moved to shared memory, a 6.0 design
    change), 401197ab (forwarded-origin advance), 986ad069 (end_lsn for
    remote_commit_lsn). So 5.0.11 differs from 6.0 mainly in progress
    bookkeeping and crash recovery of it, not in pause or tiebreak.
- Tests: `014_rolling_upgrade` is commented out of `tests/tap/schedule`
  (line 38) and `099_zodan_mixed_version` runs nightly, with optional pgbench
  load and no faults. Neither checks per-row exactly-once.

## Invariant

Reuse the single-version oracles, tagged by link version so failures are
attributable:

- `Always`: every ledger row `(origin_node, seq)` committed on any node is
  present exactly once on every node after quiesce (same as
  `ledger-row-applied-exactly-once-per-peer`), with assertion details that
  include the protocol version of each link involved.
- `Always`: the per-pair barrier (`sync_event` + `wait_for_sync_event`) works
  in both directions across versions (5.0.11 has the same non-transactional
  sync_event as 6.0: `git show v5.0.11:src/spock_functions.c` ~3137).
- `Sometimes(link negotiated protocol 4 and carried a transaction that hit a conflict)`
  so the run is known to have exercised the v4 path under conflict.

## Antithesis angle

Same faults as the single-version mesh (partitions, kills, pauses). The new
thing is that each link runs one of two framings and one of two apply
implementations, so interleavings that are safe on v5 may differ on v4: for
example, `last_inserted` on v4 is only refreshed at COMMIT, and the progress
table on 5.0.x lags by up to a second.

## Is a mixed topology worth it?

- Value: the v4 code in 6.0 has no other way to run; mixed clusters are a
  documented production state during every 5.0 -> 6.0 upgrade; there were
  three fixes in this area in two weeks (f8f78b2e, adfd708b, 40c7b39a).
- Cost: a second PostgreSQL + Spock 5.0.11 build in the node image (as
  `099_zodan_mixed_version.pl` does with two install trees), and a node-level
  switch for which tree to start. The 6.0 tree has a different PG18 patch set
  from v5_STABLE (v5_STABLE also carries `pg18-035-row-filter-check` and
  `pg18-090-init_template_fix`), so each version may need its own PG build.
- Recommendation: not in the first run. Add as a second test configuration
  (n1 on 5.0.11, n2 and n3 on 6.0) once the single-version harness is green.

## Fault requirements

Same as the single-version ledger property: node termination (between
checkpoints), partitions, pauses.

## Resolved questions (see Investigation Log)

- PG patch compatibility: on PG15, PG16 and PG17 the code patches are the same
  on both branches (v5_STABLE's extra `pg17-090-init_template_fix` only
  changes `src/Makefile.global.in` for `make check`), so one PG build serves
  both Spock versions. On PG18 it does **not**: 5.0.11 calls
  `check_simple_rowfilter_expr` from the server
  (`git show v5.0.11:src/spock_functions.c:1458-1461`, under
  `PG_VERSION_NUM >= 180000`), which upstream PG keeps `static`
  (`~/dev/pg/postgresql/src/backend/commands/publicationcmds.c:594-595`);
  patch `pg18-035-row-filter-check` only exports it. PostgreSQL loads
  extension libraries with `dlopen(..., RTLD_NOW | RTLD_GLOBAL)`
  (`src/backend/utils/fmgr/dfmgr.c:239`), so 5.0.11's `spock.so` fails to
  load on a PG18 built with HEAD's patches only. HEAD moved the function
  into `src/compat/18/spock_compat.c`. Build PG18 once with v5_STABLE's patch
  set (a superset; 035 changes no behaviour) and both versions run on it.
  There is no row-filter behaviour difference to avoid.

## Open questions

- Must 5.0.9 / 5.0.10 be covered in mixed runs? zodan's floor is 5.0.9, which
  has the old equal-timestamp tiebreak (0c98c7e3 is in 5.0.10, not 5.0.9);
  an in-place upgrade to 6.0 needs 5.0.11 (only `spock--5.0.11--6.0.0.sql`
  exists). If 5.0.9 must be tested, exclude equal-ts conflicts from mixed
  runs. `(needs human input)`
- Are 5.0.x-only weaknesses (progress table and its crash handling, no
  401197ab/986ad069) accepted for the length of an upgrade, so failures on
  links where a 5.0.x node subscribes are filtered rather than reported?
  `(needs human input)`

### Investigation Log

#### Which 5.0.x release is the supported floor for mixed clusters?

- Examined: `check_spock_version_compatibility` `samples/Z0DAN/zodan.sql:121-215`
  (`min_required_version := '5.0.9'`); `ls sql/` (only
  `spock--5.0.11--6.0.0.sql` leads to 6.0); `docs/spock_release_notes.md`
  "Upgrading" ("The upgrade from 5.0.11 to 6.0.0 ...") and 5.0.10 notes
  (tiebreak fix); `merge-base --is-ancestor 0c98c7e3` against v5.0.9 (no) and
  v5.0.10 (yes).
- Found: two floors in code: 5.0.9 for a cluster made mixed by add_node,
  5.0.11 for an in-place swap. 5.0.9 has the old tiebreak.
- Not found: a statement of which older patch levels the team supports in a
  mixed cluster.
- Conclusion: `(needs human input)`; until answered, test with 5.0.11.

#### Is a 5.0.x node's lack of 6.0 fixes accepted during an upgrade?

- Examined: subject search on `origin/v5_STABLE` for 2f9a686c, dcbba6bb,
  401197ab, fdd9587e, 64ea462d, 986ad069; ancestry of the found hashes in
  v5.0.11.
- Found: pause, sync_event and tiebreak fixes are backported (the earlier
  claim that they were missing was wrong). Missing: the shared-memory progress
  redesign and its crash recovery, the forwarded-origin advance, and the
  end_lsn change.
- Not found: a team statement on whether 5.0.x-side failures during an
  upgrade count as bugs to report.
- Conclusion: `(needs human input)`. The facts narrow the 5.0.x-only gap to
  progress bookkeeping; whether to report or filter such failures is policy.

#### Does v5_STABLE Spock run on a PG built with HEAD's patches (no 035/090)?

- Examined: `patches/<15..18>/` on HEAD and `origin/v5_STABLE`; contents of
  `pg18-035-row-filter-check.diff` and `pg18-090-init_template_fix.diff`;
  `git diff` of the common 015/025/030 patches (025 and 030 identical; 015
  differs only in hunk offsets and `index` lines on PG18, plus one context
  line on PG17, i.e. a rebase onto a newer PG minor);
  `git grep check_simple_rowfilter_expr` on v5.0.11 and HEAD; local PG tree
  `~/dev/pg/postgresql` (`dfmgr.c:239`, `publicationcmds.c:594`).
- Found: see "Resolved questions". PG18 needs 035 for 5.0.11 to load at all;
  PG15-17 need nothing extra.
- Conclusion: resolved. Build PG18 with v5_STABLE's patch set for mixed runs.
