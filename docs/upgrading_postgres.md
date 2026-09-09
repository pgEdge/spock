# Upgrading Postgres under Spock

Upgrading Postgres beneath a Spock cluster is two different jobs, and this
page treats them separately:

- A **minor** upgrade (17.9 to 17.11, say) keeps the same catalog version.
  Nothing is dumped or converted; you replace the binaries and restart.
- A **major** upgrade (17 to 19) rewrites the catalog. `pg_upgrade` moves the
  data directory, but it does not move the replication topology: Spock's
  inbound positions have to be recorded before the upgrade and restored after
  it, and each peer's subscription to the upgraded node has to be rebuilt.

Both kinds need attention that a stand-alone Postgres upgrade does not,
because Spock does not run on a stock server. It requires a patched Postgres
source tree -- see the patch sets in
[`patches/`](https://github.com/pgEdge/spock/tree/main/patches), three or four
per major -- and the extension itself is built against one major
(`src/compat/<major>`). So a new Postgres build means a new Spock build to go
with it.

!!! note
    If you run pgEdge-packaged Postgres, the patched build and a matching
    Spock are packaged together and the build steps below are handled for you.
    The replication steps still apply.

Do either upgrade **one node at a time**. The rest of the cluster keeps
serving traffic, and the node being worked on is fenced first so nothing is
lost while it is away.

!!! warning
    Take a backup of the node before you start, for a minor upgrade as well as
    a major one.

## Upgrading the minor Postgres version

A minor release changes no catalog structures, so there is no `pg_upgrade`
step, no dump and restore, and no need to touch subscriptions, slots or
replication origins. The node's data directory is used as-is by the new
binaries, and replication resumes on its own when the node comes back.

What makes it more than a binary swap is the patch set. Spock's patches are
maintained per major, but they apply to core code that a minor release can
move -- an anchor point shifting is enough to make a patch fail, or worse,
apply in the wrong place. **Verify the patches apply cleanly to the new minor
before you schedule the window,** not during it.

### 1. Build the new minor, patched

```bash
git clone --branch REL_17_11 https://github.com/postgres/postgres.git
cd postgres
for p in /path/to/spock/patches/17/*.diff; do
    patch -p1 -N -f < "$p" || echo "FAILED: $p"
done
./configure --prefix=/path/to/pg17.11 <your usual flags>
make && make install
```

Use the same `./configure` flags as the running installation. Then rebuild and
install Spock against the new `pg_config`:

```bash
cd /path/to/spock
make clean
make PG_CONFIG=/path/to/pg17.11/bin/pg_config
make PG_CONFIG=/path/to/pg17.11/bin/pg_config install
```

!!! warning
    `make install` installs **two** shared libraries: `spock.so` and
    `spock_output.so`. The second one is the logical decoding output plugin
    that every walsender loads, so a stale copy of it breaks replication while
    `spock.so` looks perfectly current. Install both, from the same build.

### 2. Check for new parameters that affect replication

A minor release can introduce a setting that stops Spock replicating. The
`output_plugin_libraries` parameter is the current example: it was added by a
2026 security fix (CVE-2026-6471) and back-patched, so it arrives in a *minor*
upgrade. It is an allowlist of libraries that may be named as a logical
decoding output plugin, and its default -- `'pgoutput, test_decoding'` --
does not include `spock_output`. Without `spock_output` in the list, logical
decoding fails with:

```text
ERROR: library "spock_output" may not be used as an output plugin
```

This affects established clusters, not just new ones, because the check runs
every time decoding starts. Add it to `postgresql.conf` on the upgraded node:

```ini
output_plugin_libraries = 'pgoutput, test_decoding, spock_output'
```

Keep the built-in entries alongside `spock_output` unless you intend to
disallow them.

!!! warning
    Set this **only** on a server that has the parameter. On a release
    predating the fix the parameter does not exist, and an unrecognised
    parameter in `postgresql.conf` stops the postmaster from starting. Check
    first:

    ```sql
    SELECT current_setting('output_plugin_libraries', true);
    ```

    A `NULL` result means the parameter is not there and must not be set.

### 3. Take the node out of the write path

Not strictly required -- the node is only down for a restart -- but on a
cluster resolving conflicts with `last_update_wins` it avoids resolving
conflicts you did not need to create. Also confirm the peers will keep the
WAL the node has not consumed yet:

```sql
-- on every other node
ALTER SYSTEM SET max_slot_wal_keep_size = -1;
SELECT pg_reload_conf();
```

### 4. Swap the binaries

```bash
pg_ctl -D /path/to/data stop -m fast
# point PATH, or your service unit, at the new installation
pg_ctl -D /path/to/data -l /path/to/logfile start
```

### 5. Verify before moving on

Check that the library and the catalog agree, and that the node is replicating
again:

```sql
SELECT spock.spock_version();                    -- the loaded library
SELECT extversion FROM pg_extension WHERE extname = 'spock';
SELECT version();                                -- the new minor
SELECT * FROM spock.sub_show_status();
SELECT slot_name, plugin, active FROM pg_replication_slots;
```

Every subscription should read `replicating`, and every slot should be
`active` with `plugin = spock_output`. Then repeat on the next node.

!!! note
    Commit timestamps survive a minor upgrade, so conflict resolution is
    unaffected. This is not true of a major upgrade -- see below.

## Upgrading the major Postgres version

A major upgrade needs the node fenced properly, because `pg_upgrade` takes it
away for minutes rather than seconds, and because the replication plumbing
does not come back on its own. The shape of it is:

> fence the node, record where it had got to, upgrade it, put the positions
> back, have the peers rebuild their subscription from the record, verify, move
> to the next node.

The procedure below is exercised end to end by
[`tests/run-cluster-upgrade.sh`](https://github.com/pgEdge/spock/blob/main/tests/run-cluster-upgrade.sh),
which builds a three-node mesh on the old major, upgrades it a node at a time
and checks that replication survives and the nodes still agree. Run it with
`--stop-after upgrade` to get a cluster paused mid-procedure to inspect.

### Before you start

The new major must be a **patched** build with Spock installed for it, and its
`postgresql.conf` must carry the same Spock-relevant settings as the old one:

```ini
shared_preload_libraries = 'spock'
wal_level = logical
track_commit_timestamp = on
output_plugin_libraries = 'pgoutput, test_decoding, spock_output'  # if the parameter exists
```

`pg_upgrade` refuses to run when the two clusters disagree about any of the
following, so check them while you can still rebuild:

- **data checksums.** Postgres 18's `initdb` enables them by default, so a
  cluster created on 17 or earlier very likely does not have them. Both
  clusters must agree.
- **encoding, locale, and locale provider** -- including the ICU version when
  the provider is ICU.
- **loadable libraries.** `pg_upgrade` walks `pg_proc.probin` in the old
  cluster and requires every library named there to load in the new one. Any
  contrib module or extension in use must be installed for the new major too,
  not just Spock.

Then set the cluster-wide preconditions:

```sql
-- on every node
ALTER SYSTEM SET spock.enable_ddl_replication = off;
ALTER SYSTEM SET max_slot_wal_keep_size = -1;
SELECT pg_reload_conf();
```

And confirm no subscription forwards a third node's changes, which this
procedure does not preserve:

```sql
SELECT sub_name FROM spock.subscription
WHERE coalesce(sub_forward_origins, '{}') <> '{}';
```

That query must return no rows on every node.

### 1. Take the node out of the write path

Stop directing application traffic at the node being upgraded. Nothing should
write to it again until step 9.

### 2. Drain the peers

Emit a sync event on the node, wait for every peer to apply it, then wait for
the node's own slots to confirm past it. This is what makes it safe to rebuild
a slot later at the current position: it proves the peers hold everything the
node produced.

```sql
-- on the node being upgraded (N)
SELECT spock.sync_event();     -- returns LSN0; note it down
```

```sql
-- on each peer, with the LSN0 from above
CALL spock.wait_for_sync_event(NULL, 'n1'::name, '0/1C99C30'::pg_lsn, 300);
```

```sql
-- back on N: every slot must have caught up
SELECT slot_name, active, confirmed_flush_lsn
FROM pg_replication_slots
WHERE confirmed_flush_lsn IS NULL OR confirmed_flush_lsn < '0/1C99C30'::pg_lsn;
```

Poll that last query rather than reading it once -- a peer applying the event
and N's walsender processing that peer's feedback are two different moments.
It must return no rows before you continue.

### 3. Disable the node's subscriptions

```sql
-- on N
SELECT spock.sub_disable(sub_name, false) FROM spock.subscription;
```

Pass `false` for `immediate`: an immediate disable stops the apply worker
mid-stream. Then wait for the workers to actually exit -- `sub_disable()`
returns as soon as the catalog is updated:

```sql
SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'spock apply%';
```

### 4. Record the fence

This is the step that makes the rest recoverable. Record it somewhere outside
the node, because the node is about to be replaced.

The inbound positions -- how far N had applied from each peer:

```sql
-- on N
SELECT s.sub_name, s.sub_slot_name, o.remote_lsn
FROM spock.subscription s
LEFT JOIN pg_replication_origin_status o ON o.external_id = s.sub_slot_name
ORDER BY 1;
```

!!! warning
    A `NULL` `remote_lsn` means a subscription with no replication origin.
    Diagnose that before upgrading; do not proceed with a gap in the record.

And each peer's definition of its subscription to N, which step 8 rebuilds
from:

```sql
-- on each peer, for sub_<N>_<peer>
SELECT sub_replication_sets, sub_forward_origins, sub_apply_delay,
       sub_force_text_transfer, sub_enabled, sub_skip_lsn, sub_skip_schema
FROM spock.subscription WHERE sub_name = 'sub_n1_n2';
```

### 5. Have the peers drop their subscription to N -- while N is still up

```sql
-- on each peer
SELECT spock.sub_drop('sub_n1_n2');
```

This step is easy to leave until after the upgrade, and doing so causes real
trouble. Disabling N's subscriptions in step 3 stops N applying; it does
nothing to stop the peers *pulling from* N. Their apply workers retry N's
address in a loop for the whole upgrade window, so whatever answers at that
address collects them -- including the short-lived server `pg_upgrade` starts
for its own checks, which then fails with
`replication slot "spk_..." is active for PID`.

Dropping now also removes the slot on N properly. `spock.sub_drop()` drops the
slot on the provider only while it can still reach it; run after N is down, it
logs `could not drop slot ... you will probably have to drop it manually` and
carries on. Confirm N has none left:

```sql
-- on N
SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE 'spk\_%';
```

Nothing is lost by dropping this early: step 2 drove the peers' debt on N to
zero, and step 4 recorded what step 8 rebuilds from.

### 6. Run pg_upgrade

```bash
pg_ctl -D /path/to/old/data stop -m fast

/path/to/new/bin/pg_upgrade --check \
    -d /path/to/old/data -D /path/to/new/data \
    -b /path/to/old/bin  -B /path/to/new/bin \
    -U postgres
```

Run `--check` first and read it. It is the only mode that verifies the logical
slots have caught up, which is exactly what step 2 bought you. Then run it for
real by dropping `--check`.

!!! note
    Give `pg_upgrade` scratch ports with `-p` and `-P` rather than the node's
    production port. The servers it starts are short-lived, but while they are
    up they will answer at whatever port they are given -- and if that is the
    production port, a peer can reconnect to one of them.

Start the node on the new major, then put the cluster-wide settings back:

```sql
-- on N, after starting on the new major
ALTER SYSTEM SET spock.enable_ddl_replication = off;
ALTER SYSTEM SET max_slot_wal_keep_size = -1;
SELECT pg_reload_conf();
```

!!! warning
    `ALTER SYSTEM` writes `postgresql.auto.conf`, and `pg_upgrade` does not
    carry that file across. Every setting applied with `ALTER SYSTEM` before
    the upgrade -- including the two preconditions above -- returns to its
    default on the new cluster. Re-apply them before the next node is fenced,
    or that node's precondition checks will read this one and fail.

### 7. Let Spock update its own catalog

Spock's database manager compares `pg_extension.extversion` with the version
of the loaded library at startup and runs `ALTER EXTENSION spock UPDATE`
itself, so no manual step is normally needed:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'spock';
SELECT spock.spock_version();
```

If the two do not agree after a minute or so, do it by hand:

```sql
ALTER EXTENSION spock UPDATE;
```

!!! note
    The automatic update is skipped while the server is in recovery, so a node
    promoted from a standby may need the manual `ALTER EXTENSION`.

### 8. Restore the origins, then rebuild the peers' subscriptions

For each line of the record from step 4, on N:

```sql
SELECT pg_replication_origin_create('spk_mydb_n2_sub_n2_n1');
SELECT pg_replication_origin_advance('spk_mydb_n2_sub_n2_n1', '0/1C99C30'::pg_lsn);
```

Then confirm each one landed:

```sql
SELECT external_id, remote_lsn FROM pg_replication_origin_status ORDER BY 1;
```

!!! warning
    Compare those positions **as `pg_lsn`, not as text**. Postgres 18 changed
    how `pg_lsn` renders -- the low half is zero-padded, so a position recorded
    on 17 as `0/1C99C30` reads back from 19 as `0/01C99C30`. It is the same
    value. Comparing the strings makes every correctly restored origin look
    wrong:

    ```sql
    SELECT remote_lsn = '0/1C99C30'::pg_lsn FROM pg_replication_origin_status
    WHERE external_id = 'spk_mydb_n2_sub_n2_n1';
    ```

!!! note
    From a Postgres 17 or later old cluster, `pg_upgrade` migrates logical
    slots and replication origins may survive too, so `origin_create` can fail
    with "already exists". Check what came through before assuming it is gone:
    `SELECT * FROM pg_replication_origin_status;` and
    `SELECT slot_name, plugin FROM pg_replication_slots;`. Advance whatever
    survived to the recorded position anyway.

Now each peer recreates its subscription to N **from the step-4 record, not
from `sub_create()`'s defaults**:

```sql
-- on each peer
SELECT spock.sub_create(
    subscription_name     := 'sub_n1_n2',
    provider_dsn          := 'host=10.0.0.5 port=5432 dbname=acctg',
    replication_sets      := '{default,default_insert_only,ddl_sql}',  -- as recorded
    forward_origins       := '{}',                                     -- as recorded
    apply_delay           := '00:00:00',                               -- as recorded
    force_text_transfer   := false,                                    -- as recorded
    synchronize_structure := false,
    synchronize_data      := false,
    enabled               := true);
```

!!! warning
    Retyping `replication_sets` from memory instead of from the record is the
    quiet way to lose data here. A subscription created with the default array
    replicates perfectly while silently no longer carrying the sets you had
    added, and nothing reports an error. Read it back and compare against the
    record -- comparing membership, not element order:

    ```sql
    SELECT sub_replication_sets FROM spock.subscription WHERE sub_name = 'sub_n1_n2';
    ```

`synchronize_structure` and `synchronize_data` are `false` because step 2
established that the peers and N already hold the same rows. `sub_skip_lsn`
has no `sub_create()` argument and comes back as `0/0`; if the record shows a
non-zero value, re-apply it with
[`spock.sub_alter_skiplsn()`](spock_functions/functions/spock_sub_alter_skiplsn.md).

### 9. Re-enable, then verify before moving on

```sql
-- on N
SELECT spock.sub_enable(sub_name, true) FROM spock.subscription;
```

Put N back in the write path, then check the whole cluster before fencing the
next node:

```sql
SELECT * FROM spock.sub_show_status();   -- on every node
```

Every subscription on every node should read `replicating`. Then prove data
moves in both directions rather than trusting the status: emit
`spock.sync_event()` on each node and wait for it on the others with
`spock.wait_for_sync_event()`, as in step 2. Comparing row counts across
nodes, or running
[ACE](https://github.com/pgEdge/ace)'s `repset-diff` and `spock-diff`, is
the stronger check where you can afford it.

Repeat from step 1 for the next node. Running with mixed majors between nodes
is expected during the roll; keep the window short.

### After the last node

Restore the settings you changed as preconditions -- including
`spock.enable_ddl_replication` if your cluster uses automatic DDL replication:

```sql
ALTER SYSTEM SET spock.enable_ddl_replication = on;
SELECT pg_reload_conf();
```

!!! warning
    **Commit timestamps do not survive a major upgrade.** `pg_upgrade` does
    not copy `pg_commit_ts`, so transactions committed before the upgrade have
    no commit timestamp on the upgraded node:

    ```sql
    SELECT pg_xact_commit_timestamp('12345'::xid);   -- NULL, or an error
    ```

    Spock's `last_update_wins` conflict resolution is built on that timestamp,
    so a conflict involving a row last written before the upgrade cannot be
    resolved by timestamp. This is inherent to `pg_upgrade` and there is
    nothing to configure; it is a reason to keep writes off a node until its
    upgrade is complete, and to expect it when reading
    `spock.resolutions` afterwards. See
    [Conflict Types and Resolution](conflict_types.md).

## Related

- [Upgrading the Spock Extension](upgrading_spock.md) -- upgrading Spock
  itself, which is a separate operation from either of the above.
- [Installing and Configuring Spock](install_spock.md)
- [Using Advanced Configuration Options](configuring.md)
- [Troubleshooting](troubleshooting.md)
