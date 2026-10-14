# mixed-version-add-node-loses-nothing

## Summary

Since f8f78b2e / adfd708b / 40c7b39a (September 2026), ZODAN `add_node` lets a
6.0 node join a cluster whose nodes run 5.0.9+ or a mix of 5.0.x and 6.0, and
the release notes / tutorial claim add_node "ensures no data is missed or
duplicated" (sut-analysis S13). The mixed path uses different code than the
single-version path at three points. Property: an add_node of a 6.0 node into
a cluster containing at least one 5.0.x node, under writes on all existing
nodes and faults, either fails visibly or leaves the new node with exactly
the union of committed rows (ledger exactly-once), same as in a 6.0-only
cluster. **Needs a mixed-version topology.**

## Mixed-only code paths (code-checked)

1. **Peer progress read on a pre-6.0 provider.**
   `spock_create_slot_and_read_progress` (`src/spock_sync.c:650-866`) probes
   the provider's catalog with
   `to_regprocedure('spock.read_peer_progress(text,oid,oid)')` (`:683-698`)
   and, when absent, reads the 5.x `spock.progress` table directly
   (`:789-803`): `JOIN spock.progress p ... JOIN pg_replication_origin o ...
   LEFT JOIN pg_replication_origin_status ros`. Resume LSN =
   `COALESCE(ros.remote_lsn, '0/0')`; other columns come from a table
   "flushed at most once a second" (comment `:779-787`; 5.0.11
   `flush_progress_if_needed`, 1 s throttle). The probe was changed from the
   library version to the catalog in adfd708b because a provider on the 6.0
   binary with the extension not yet updated "said 60000 and then failed".
2. **Single-table resync reader** `adjust_progress_info()` picks
   `remote_lsn` vs `remote_commit_lsn` by column existence (adfd708b: it used
   6.0 ordinals on a 5.x table and "read the wrong fields").
3. **ZODAN Phase 3 catch-up poll** picks the column by the source's
   `extversion` (`samples/Z0DAN/zodan.sql:1920-1960`,
   `spock.progress_lsn_column`, `:104-115`). On a 5.x source it polls a table
   that lags up to ~1 s, which only delays. Timeout raises (`:1963-1972`),
   so it fails visibly.
4. **Version rule** (`check_spock_version_compatibility`, `zodan.sql:121-215`):
   all nodes >= 5.0.9; new node >= every existing major.minor. This is a
   deterministic gate, not an Antithesis target.

The 6.0 sync worker also calls `spock.pause_apply_workers()` on the 5.x
provider (`src/spock_sync.c:704`). That function exists from 5.0.7
(`sql/spock--5.0.6--5.0.7.sql`). **Correction (investigation):** the pause
fix dcbba6bb *was* backported, as 2503b2c1, and is in v5.0.11; a
`merge-base --is-ancestor` check on the 6.0 hash misses cherry-picks. The
5.0.11 / v5_STABLE `spock_pause_apply_workers`, `spock_resume_apply_workers`
and the worker-side `maybe_pause_for_slot_creation` are the same code as HEAD
(whitespace-only diff). So the L4 holes (self-resume after
`spock.pause_timeout` clearing the global flag, xid-less window, one flag for
all callers) apply the same way on a 5.x provider; a loss found through the
pause window is a bug in the shared design, not a 5.x-only one. The related
zodan/sync fixes b7fc7022, f38da44a and a9bc8652 are also on v5.0.11 (as
1ce82763, c7c4ee22, 334a71dd).

## Things that look safer on the 5.x path

- 5.0.11 creates the progress row at `sub_create` time
  (`create_progress_entry`, `git show v5.0.11:src/spock_functions.c:588`), so
  the INNER JOIN that can drop a peer on 6.0 (shmem entry missing after a
  restart, sut-analysis L4 "Related") is less likely to drop a peer on a 5.x
  provider.
- The resume LSN comes from `pg_replication_origin_status` on both paths, so
  its meaning is the same.

## Things that look riskier

- **Window between binary upgrade and `ALTER EXTENSION UPDATE`.** A provider
  running the 6.0 binary with a 5.x catalog takes the "pre-6.0" path. The 6.0
  binary does not write the old table, so its rows are frozen at upgrade time.
  Resume LSN is still from `ros`, but a peer subscription created after the
  binary swap has no table row and is dropped by the JOIN; ZODAN Phase 7 then
  falls back to `pg_current_wal_lsn()` for that peer (NOTICE only), which is
  the known loss pattern. The manager runs `ALTER EXTENSION spock UPDATE` at
  start (`spock_manage_extension`, `src/spock.c:560-612`), so the window is
  short unless the update fails or the manager is slow.
- 5.x apply on existing nodes keeps 5.x crash bookkeeping (no 2f9a686c), so
  "src applied X up to LSN" can mean something slightly different after a
  5.x node restart.
- Three fixes in two weeks in exactly this path, and the only test
  (`099_zodan_mixed_version`, nightly) has no faults and checks row counts
  rather than per-row exactly-once.

## Invariant

- `Always` (workload, after add_node returns success and the cluster is
  quiesced): every ledger row committed on any existing node during the add is
  present exactly once on the new node, and the new node has no row absent
  elsewhere. Same oracle as the single-version add-node property, with the
  versions of source and peers in the assertion details.
- `Sometimes(add_node succeeded while the source ran 5.0.x)` and
  `Sometimes(add_node succeeded while a non-source peer ran 5.0.x)`: both
  mixed layouts were exercised (the chain and pair layouts of 099).
- `Unreachable` (SUT-side, missing): the sync worker logs
  "SPOCK cswp provider has read_peer_progress: no" and then gets zero peer
  rows while the provider has enabled subscriptions from other nodes. Zero
  rows is legitimate only when the provider has no other peers.

## Antithesis angle

Faults during the add: pause the 5.x provider during slot creation (L4 on 5.x
pause code), kill or partition a 5.x peer between Phase 3 and Phase 7,
restart the source between its binary swap and the extension update.

## Fault requirements

Process pause, partitions, node termination; a node-level way to switch
binaries for the upgrade-window case.

## Is it worth a mixed topology?

Yes, more than the plain mixed mesh: this is new code (Sept 2026) on the
highest-risk feature (add_node), and customers are told to use it to start an
upgrade. It shares the setup cost with `mixed-version-mesh-applies-exactly-once`
(n1 on 5.0.11, n4 joins on 6.0). Second configuration, after the
single-version harness is green.

## Resolved questions (see Investigation Log)

- 5.x pause implementation: identical to HEAD's (see correction above). Loss
  through the pause window is attributed to the shared pause design whichever
  version the provider runs.
- In-core `attach_node` (3c7ed175): only on `origin/zodan-in-core-node`, not
  an ancestor of HEAD. Out of scope. It does reuse the `spock_sync.c`
  peer-progress code, so this property's sync-worker checks would apply if it
  is merged.

## Open questions

- Is adding a node supported while some existing node runs the 6.0 binary
  with a 5.x catalog (before its `ALTER EXTENSION UPDATE` finishes)? If not,
  drop that scenario. `(needs human input)`

### Investigation Log

#### Which 5.x pause implementation is on v5_STABLE, and does it have the L4 issues?

- Examined: `git show v5.0.11:` and `origin/v5_STABLE:` `src/spock_functions.c`
  (`spock_pause_apply_workers`, `spock_resume_apply_workers`) and
  `src/spock_apply.c` (`maybe_pause_for_slot_creation`), diffed against HEAD;
  `git log origin/v5_STABLE --grep` for the subjects of dcbba6bb, b7fc7022,
  f38da44a, a9bc8652, 986ad069; `merge-base --is-ancestor` of the found
  hashes against `v5.0.11`.
- Found: pause/resume and the worker-side wait are the same code (only
  whitespace differs). dcbba6bb is on v5 as 2503b2c1; b7fc7022 as 1ce82763;
  f38da44a as c7c4ee22; a9bc8652 as 334a71dd; all in v5.0.11. 986ad069
  (end_lsn for remote_commit_lsn) has no v5 equivalent, which fits 5.x
  keeping its own progress table.
- Not found: any 5.x-only pause change.
- Conclusion: resolved. Same L4 holes on both versions; the earlier note in
  this file that the pause fixes are missing from v5_STABLE was wrong (the
  ancestor check cannot see cherry-picks).

#### Is joining a new node while some node is in the "6.0 binary, 5.x catalog" state supported?

- Examined: `check_spock_version_compatibility` `samples/Z0DAN/zodan.sql:121-215`;
  `spock_manage_extension` `src/spock.c:560-612` and its call in the manager
  `src/spock_manager.c:211-214`; `docs/upgrading_spock.md`;
  `docs/spock_release_notes.md` "Upgrading" and "Rolling upgrade" sections;
  output-plugin startup checks `src/spock_output_plugin.c:463-480`.
- Found: zodan reads `pg_extension.extversion`, so a node in that state is
  treated as 5.x and the add proceeds; nothing in zodan, the sync worker or the
  walsender compares the library version with the catalog version (the
  output plugin only LOGs a client/server version difference). The upgrade
  doc tells operators to verify each node's version before moving on, but
  says nothing about add_node during the window. The window normally lasts
  until the manager's first transaction commits.
- Not found: any doc or code that forbids or handles it.
- Conclusion: `(needs human input)`: the team must say whether this is a
  supported state; code neither blocks nor handles it.

#### Does in-core `attach_node` share these paths?

- Examined: `git branch -a --contains 3c7ed175`, `merge-base --is-ancestor
  3c7ed175 HEAD`, `git grep` of `read_peer_progress` /
  `spock_create_slot_and_read_progress` on that branch.
- Found: only on `origin/zodan-in-core-node`; not on HEAD. The branch's
  `src/spock_sync.c` and `src/spock_zodan.c` use the same peer-progress read.
- Conclusion: resolved, out of scope at HEAD.
