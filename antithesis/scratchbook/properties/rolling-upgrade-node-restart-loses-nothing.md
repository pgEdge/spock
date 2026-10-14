# rolling-upgrade-node-restart-loses-nothing

## Summary

Documented upgrade procedure (`docs/upgrading_spock.md`): stop one node,
install new binaries, restart; the manager "detects the version mismatch and
upgrades the extension schema" automatically (`spock_manage_extension`). The
release notes claim "zero-downtime rolling upgrades"
(`docs/spock_release_notes.md:24-25, 216-224`). Property: swapping one node's
Spock from 5.0.11 to 6.0 while the other nodes keep writing loses and
duplicates no transaction on any link, the upgraded node's catalog reaches
6.0.0, and every subscription returns to streaming with protocol 5 between
upgraded pairs and 4 otherwise. **Needs a mixed-version topology** (two builds
and a restart that switches binary).

## What runs at the swap (code-checked)

- `spock_manage_extension()` (`src/spock.c:560-612`): in the manager, takes
  `ShareUpdateExclusiveLock` on `pg_extension`, compares `extversion` with
  `SPOCK_VERSION`, runs `ExecAlterExtensionStmt` if they differ. Skipped during
  recovery. It runs in the manager's transaction; if it errors, the manager
  exits and the supervisor restarts it.
- Upgrade script `sql/spock--5.0.11--6.0.0.sql`:
  - drops the `spock.progress` **table** and `lag_tracker` view, recreates
    `spock.progress` as a view over shared memory (`apply_group_progress()`);
  - rewrites `spock.resolutions.conflict_type` names;
  - creates `spock.sub_id_generator`, `reserved_object`, new functions;
  - calls `SELECT spock.slot_enable_failover();` which changes **replication
    slots** (non-transactional) and skips slots in use with a NOTICE.
- First start of the 6.0 binary: no `PGDATA/spock/resource.dat` exists
  (5.x never wrote it), so the progress hash starts empty and
  `reconcile_progress_with_origin()` rebuilds from origins plus a
  `pg_commit_ts` scan of up to 1M xids (`src/spock_progress_recovery.c`).
- 6.0 apply workers on the upgraded node renegotiate per link: 5 with 6.0
  peers, 4 with 5.x peers. Its walsenders do the same for incoming
  subscribers. Subscription resume positions are the replication origins,
  which the upgrade does not touch.
- Window: between postmaster start and the manager's `ALTER EXTENSION`, the
  6.0 library runs against the 5.x catalog. Apply workers are started by the
  same manager after `spock_manage_extension` returns (manager loop order),
  so local apply should not run in that window; walsenders and SQL calls
  from peers (zodan, sync workers) can.

## Failure scenarios worth testing

1. Kill the node during the manager's `ALTER EXTENSION UPDATE`: the catalog
   change rolls back, slots changed by `slot_enable_failover()` stay changed
   (harmless, idempotent). Next start must retry and finish.
2. Upgraded node's first apply after the swap: progress hash empty, reconcile
   path runs; any duplicate or skipped transaction on the first reconnect
   shows in the ledger. On a 5.x subscriber of the upgraded node, the
   walsender is now 6.0 talking v4.
3. Writes on the old-version nodes during the downtime and catch-up: the
   upgraded node must catch up from the 5.x walsenders through v4 framing.
4. A peer runs add_node or a table resync against the node inside the
   "6.0 binary, 5.x catalog" window (see `mixed-version-add-node-loses-nothing`).

## Invariant

- `Always` (workload, at quiesce after the upgrade step): ledger exactly-once
  on every node, as in the single-version mesh.
- `Sometimes(extversion = '6.0.0' on the upgraded node within N seconds of its restart)`
  is the liveness side; and an `Always` at quiesce that every node's
  `extversion` equals its library `spock.spock_version()`.
- `Always`: no subscription is disabled and `spock.exception_log` gets no rows
  caused by the upgrade alone (no conflicts in the upgrade phase).

## Antithesis angle

The swap itself is a scripted restart; Antithesis adds kills during the
`ALTER EXTENSION`, partitions during catch-up, and pauses of old-version
providers, all of which interact with the empty progress hash and the v4
framing.

## Fault requirements

Node termination (including during the manager's ALTER), partitions,
pauses. Needs a node-level switch (e.g. a flag file read by the entrypoint)
to choose which install tree starts.

## Is it worth it?

Medium. The upgrade path is documented and claimed zero-downtime, and
`014_rolling_upgrade` is commented out of the schedule
(`tests/tap/schedule:38`), so it has little regression coverage. But it is a
one-time transition per cluster, mostly deterministic, and shares nearly all
of its risk with the mixed mesh and with crash restarts that the single-version
run already covers (empty `resource.dat` looks like a crash restart). If only
one mixed-version configuration is built, prefer add_node
(`mixed-version-add-node-loses-nothing`) and run the swap as a setup step of
that configuration.

## Related, out of the planned scope

`slot_enable_failover()` skips active slots during the upgrade. On PG17/18
with a physical standby, such a slot then stays `failover = false` and is not
synced; after a promotion that subscriber cannot resume. Needs a standby
topology; noted, not a property here.

## Resolved questions (see Investigation Log)

- `ALTER EXTENSION UPDATE` under load: it can wait without limit. The manager
  holds `ShareUpdateExclusiveLock` on `pg_extension` and the script needs
  `AccessExclusiveLock` on `spock.progress` (DROP TABLE) and
  `spock.lag_tracker` (DROP VIEW), and row locks for `UPDATE
  spock.resolutions`; the manager sets no `lock_timeout`. Any open
  transaction that has read `spock.progress` on that node (a peer's 6.0 sync
  worker taking the pre-6.0 path, zodan Phase 3 polling, monitoring) holds it
  up. The manager starts apply workers only after this returns
  (`src/spock_manager.c:211-226`), so the effect is a delay in the upgraded
  node's apply start, not loss. The liveness `Sometimes(extversion = 6.0.0
  within N s)` must pick N with this in mind, or the workload must avoid long
  readers of `spock.progress` during the swap.
- Swap without a PG rebuild: on PG15-17, yes (the code patches are the same on
  both branches; v5_STABLE's extra 090 is a test-only Makefile change). On
  PG18, a PG built for 5.0.11 already carries patch 035 (5.0.11's `spock.so`
  will not load without it, see `mixed-version-mesh-applies-exactly-once`);
  035 only exports `check_simple_rowfilter_expr`, which HEAD also defines in
  `src/compat/18/spock_compat.c` with the same signature, so 6.0 should run
  on that PG unchanged. Not verified by building. So the swap is a Spock-only
  binary change if PG18 is built with v5_STABLE's patch set.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW2, implementability CW6); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v2/mixed-version · Faults: node kill during upgrade, partition

- "No `exception_log` rows in the upgrade phase" means none outside the expected-exception registry.

## Open questions

- Is the "6.0 binary, 5.x catalog" window meant to serve walsenders and peer
  SQL, or should the walsender / sync paths refuse until the catalog is
  updated? `(needs human input)`

### Investigation Log

#### Is the "6.0 binary, 5.x catalog" window supposed to serve walsenders and peer SQL?

- Examined: `spock_manage_extension` `src/spock.c:560-612`; manager start-up
  order `src/spock_manager.c:190-240`; output-plugin startup checks
  `src/spock_output_plugin.c:463-480`; `sql/spock--5.0.11--6.0.0.sql` (no
  `ALTER TABLE`/`ADD COLUMN`/`RENAME` on any catalog table; it drops and
  recreates `spock.progress`, `lag_tracker`, rewrites
  `resolutions.conflict_type`, adds new objects);
  `docs/upgrading_spock.md`.
- Found: no gate anywhere. Apply workers on the upgraded node do not run in
  the window (the manager runs the update first). The walsender works: the
  tables it reads have the same layout in both catalogs, and a version
  difference with the subscriber is only LOGged. Peer SQL also works, and a
  6.0 sync worker reading this node takes the pre-6.0 progress path against a
  table the 6.0 binary no longer writes (the risk recorded in
  `mixed-version-add-node-loses-nothing`).
- Not found: any doc statement on the window.
- Conclusion: `(needs human input)`: whether the window is a supported state
  is a design decision.

#### Can `ALTER EXTENSION UPDATE` be held up by peers' locks under load?

- Examined: `spock_manage_extension` (`table_open(ExtensionRelationId,
  ShareUpdateExclusiveLock)`, `ExecAlterExtensionStmt`); lock-taking statements
  in `sql/spock--5.0.11--6.0.0.sql` (lines 26-27 DROP VIEW/TABLE, 178 UPDATE
  resolutions, 348 `slot_enable_failover()`); grep for `lock_timeout` /
  `statement_timeout` in `src/spock.c` and `src/spock_manager.c` (none);
  readers of `spock.progress` in `src/spock_sync.c:489-505, 597, 797`.
- Found: as summarised above; waits are unbounded and only delay apply start.
- Conclusion: resolved. Affects only the liveness check's time bound.

#### Is a 5.0.x -> 6.0 swap without a PostgreSQL rebuild supported?

- Examined: `patches/<15..18>/` on both branches; 035 and 090 contents;
  `git grep check_simple_rowfilter_expr` on v5.0.11 and HEAD;
  `src/compat/18/spock_compat.c:134-141`, `spock_compat.h:130`; PG
  `dfmgr.c:239` (`RTLD_NOW`).
- Found: as summarised above.
- Not found: a build of HEAD against a 035-patched PG18 (no builds run).
- Conclusion: resolved by reading; the harness should build PG18 once with
  v5_STABLE's patches and use it for both Spock versions.
