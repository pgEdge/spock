# 07 — Existing Test Strategy

SUT: spock @ 69d9228f (main). Focus: what the existing tests exercise, how they
build/run, how they check convergence, and what they leave untested, so that the
Antithesis work adds coverage instead of repeating it.

## Summary

| Layer | Where | Topology | Runs on | Concurrency / faults |
|---|---|---|---|---|
| pg_regress SQL | `tests/regress/sql/*.sql`, `Makefile:63-81` (`make regresscheck`) | ONE postgres instance, "nodes" are separate databases (`regression`, `postgres`, `regression1`, `sourcedb`) on loopback | every PR (inside `spockbench.yml`, `random-delays-regress.yml`); `pg-stable-test.yml` | none; serial, deterministic output diffs. Random 1–100 ms sleeps in one variant |
| Perl TAP | `tests/tap/t/*.pl`, harness `t/SpockTest.pm`, `schedule` / `schedule-nightly` | 1–3 real postmasters on 127.0.0.1, ports 5441+ in one container/host | per PR (`schedule`, in `spockbench.yml`), nightly (`schedule-nightly`), weekly (011) | targeted, single-shot faults: SIGKILL of walsender/subscriber, `pg_ctl -m immediate`, sub_disable/enable mid-txn, pg_cancel_backend, one injection-point stall, iptables (not scheduled) |
| Docker 3-node cluster | `tests/docker/*` | 3 containers n1/n2/n3 on a compose network | per PR (`spockbench.yml`, `installcheck.yml`) | spockbench concurrent writes on all 3 nodes for 120 s; NO fault injection |
| Shell mesh rigs (no Docker) | `tests/run-single-pg18-installcheck.sh`, `tests/run-cluster-upgrade.sh` | 3 single-node clusters, full mesh | every push (single-pg18), nightly (upgrade) | core PG regression suite as DDL/DML load; rolling pg_upgrade one node at a time |

Main takeaway: **no existing test combines (a) conflicting writes on the same
rows from several nodes, (b) faults (partition / kill / pause) at random times,
and (c) a full cross-node data comparison afterwards.** Every fault test is a
2-node (rarely 3-node) script with one fault at a hand-picked moment, and the
one multi-writer load (spockbench in Docker) runs with no faults and checks
results inside spockbench, which lives outside this repo.

---

## Findings

### 1. pg_regress suite (`tests/regress`)

* Driven by `make regresscheck` (`Makefile:137-145`): `pg_regress --temp-instance`
  with `tests/regress/regress-postgresql.conf` (+ `regress-output-plugin.conf`
  when the server knows the `output_plugin_libraries` GUC, `Makefile:124-133`).
* **Single instance.** The "provider" and "subscriber" are databases in the same
  postmaster: `spock.provider_dsn='dbname=regression'`,
  `spock.subscriber_dsn='dbname=postgres'`, `spock.provider1_dsn='dbname=regression1'`,
  `spock.orig_provider_dsn='dbname=sourcedb'` (regress-postgresql.conf), read back
  through `spock_regress_variables()` (e.g. `init.sql:3`). Databases created in
  `preseed.sql:59-60`. So there is no network, one clock, one WAL stream
  host, and every "node" crashes together.
* Config: `fsync=off`, `autovacuum=off`, `spock.synchronous_commit=true`,
  `spock.check_all_uc_indexes=true`, `DateStyle='ISO, DMY'`. Conflict resolution
  left at default.
* Schedule (`Makefile:63-68`): preseed infofuncs init_fail init preseed_check basic
  conflict_secondary_unique excluded_schema conflict_stat(PG18+ only, `:80-82`)
  toasted replication_set exception_row_capture matview bidirectional primary_key
  interfaces foreign_key copy sequence triggers parallel functions row_filter
  row_filter_sampling att_list column_filter apply_delay alter_options extended
  node_origin_cascade multiple_upstreams tuple_origin autoddl sync_event
  sync_table generated_columns spill_transaction read_only resolutions_retention drop.
  `add_table` is filtered out (`:77`). `huge_tx*.sql` exist but are not in REGRESS.
  `parallel.sql` has its sub_create commented out with a FIXME.
* What it covers: SQL API surface (node/sub/repset functions), row/column
  filters, DDL replication (autoddl, replicate_ddl), TOAST, sequences, triggers,
  generated columns, read-only GUC modes, sync_event / wait_for_sync_event,
  exception_behaviour modes (`exception_row_capture.sql`, `spill_transaction.sql`
  with spill-to-disk of replay queue), conflict logging into
  `spock.resolutions` / `spock.exception_log` (`tuple_origin.sql`,
  `conflict_secondary_unique.sql`, `conflict_stat.sql`).
* How conflicts are produced: **by hand-made divergence**, e.g. insert/delete a
  row on the subscriber, then change it on the provider, then wait with
  `spock.wait_slot_confirm_lsn(NULL,NULL)` and inspect the tables. Never two
  concurrent writers.
* Checking: exact text diff against `tests/regress/expected/*.out`.

### 2. Random-delay build (`spock_injection`)

* `include/spock_injection.h` defines two hook macros:
  * `SPOCK_WORKER_DELAY()` — `src/spock_worker.c:350`, `:423` (worker start /
    finish) and `src/spock_apply.c:668` (apply-side, in the BEGIN path).
  * `SPOCK_OUTPUT_TXN_STALL()` — `src/spock_output_plugin.c:662`, right after a
    transaction's BEGIN is sent by the walsender.
* Three build modes:
  * `SPOCK_RANDOM_DELAYS` (Makefile:26-30, `make SPOCK_RANDOM_DELAYS=1`) →
    `spock_random_delay()` (`src/spock_injection.c`), sleeps 1–100 ms using
    `pg_global_prng_state`, logs `"Spock random delay: sleeping %ld ms"`.
  * `USE_INJECTION_POINTS` (PG built with `--enable-injection-points`) → named
    points `spock-worker-delay`, `spock-output-txn-stall`.
  * neither → no-ops.
* Used by: `.github/workflows/random-delays-regress.yml` (per PR, PG15–19:
  builds the Docker image with `--build-arg SPOCK_RANDOM_DELAYS=1`, runs
  `run-spock-regress.sh` = the pg_regress suite). Only the single-instance
  regress suite runs under random delays; TAP and the Docker cluster do not.
* Injection points are attached in exactly one test:
  `tests/tap/t/046_apply_worker_exception_misclassification.pl` scenario 2
  (`injection_points_attach('spock-output-txn-stall','wait')` at :209, wakeup
  :276) to stall the walsender mid-transaction and trigger
  `spock.apply_idle_timeout`. Skipped when the `injection_points` module is
  missing (:47-51). It runs in CI because `spockbench.yml:53-58` builds the
  image with `ENABLE_INJECTION_POINTS=1` and runs the TAP schedule in that
  image. `spock-worker-delay` is never attached by any test.
* Relevance: these two hook sites are natural spots for Antithesis SDK
  assertions / reachability markers, and the random-delay mode shows the
  developers already suspect timing bugs around worker start/stop and
  mid-transaction stalls.

### 3. TAP suite (`tests/tap`)

**Harness — `tests/tap/t/SpockTest.pm` (679 lines)**

* `create_cluster(N)` (:272): `initdb -A trust` per node, ports `5441+i` on
  127.0.0.1, all in the same machine/container, `CREATE EXTENSION spock`,
  `spock.node_create('nI', ...)`. Does NOT create subscriptions.
* `create_postgresql_conf` (:230) sets on every node:
  `spock.enable_ddl_replication=on`, `spock.include_ddl_repset=on`,
  `spock.allow_ddl_from_functions=on`, **`spock.exception_behaviour=sub_disable`**,
  `spock.conflict_resolution=last_update_wins`, `track_commit_timestamp=on`,
  `spock.exception_replay_queue_size='1MB'`, `spock.enable_spill=on`,
  `log_min_messages=debug1`, `log_statement=all`.
* `cross_wire(N, names)` (:373): full mesh `spock.sub_create(... ARRAY['default',
  'default_insert_only','ddl_sql'], true, true)` then `sleep 10` (no readiness
  wait). `cross_wire_first_two` likewise.
* Wait/convergence helpers: `sync_nodes(from,to)` (:622) =
  `spock.sync_event()` on source then `CALL spock.wait_for_sync_event(NULL,
  'nX', lsn, timeout)` on target — this is the suite's standard "replication
  caught up" barrier; `poll_query_until` (:602), `wait_for_sub_status`,
  `wait_for_exception_log`, `wait_for_log`/`log_since` (grep server log),
  `apply_worker_pid` (:647, finds `spock apply <dboid>:<subid>` in
  pg_stat_activity, used to target kills).
* Nothing is mocked: real postmasters, real walsenders, real libpq. Faults are
  done with OS signals, `pg_ctl`, `pg_terminate_backend`/`pg_cancel_backend`,
  sub_disable/sub_enable, or replica-role triggers that raise errors.

**Schedules**

* `tests/tap/schedule` (per PR, via `make check_prove` / `run_tests.sh`):
  001, 002, 003, 004, 008, 009, 013_origin_change_restore,
  014_pgdump_restore_conflict, 013_exception_handling, 015_skip_lsn,
  015_forward_origin_advance, 016_sub_disable_missing_relation, 031, 018_forward_origins,
  018_failover_slots, 019, 021, 022_rmgr_progress_post_checkpoint_crash,
  022_apply_mem_context, 024, 025, 027_reserved_object, 028, 030_autoddl, 032,
  033, 034, 037, 038, 039, 044, 045, 046, 103, 105.
  Commented out: 005_daylight_savings, 006_sync_during_write, 011 (moved to weekly
  workflow), 014_rolling_upgrade, 018_upgrade_schema_match.
* `tests/tap/schedule-nightly` (`make check_prove_nightly`, `nightly_tap.yml`
  02:00 UTC for every PR updated in the last 25 h plus main, PG15–19):
  012_zodan_basics, 017_zodan_3n_timeout, 035_deadlock_retry,
  036_real_deadlock_retry, 099_zodan_mixed_version. 016_crash_recovery_progress
  commented out (and itself `plan skip_all`).
* In the tree but in **no schedule**: 015_resync_readonly_origin,
  016_crash_recovery_progress (skip_all), 020_exception_root_cause,
  020_sync_standby_feedback_lsn, 023_forced_keepalive_timing,
  026_no_double_wal_flush, 027_remote_commit_ts_recovery,
  029_remote_commit_ts_recovery_clean_shutdown, 030_read_retry_count_guc,
  100_progress_period (manual benchmark), 101_clean_exit_on_conn_loss,
  102_no_origin_leak_on_disconnect, 104_iptables_conn_block (needs root/sudo
  iptables), 800_standby_hot_standby_feedback (skip_all on PG18+).
  Note several crash/disconnect tests (027, 101, 102, 104) are not run in CI.
* `zodan_sync.yml`: weekly (Sat 22:00 UTC) runs `011_zodan_sync_third.pl` 10
  times in a row per PG version via `run-spock-tap.sh "t/011..." 10` — the
  only repeat-to-find-flakes loop in CI.

**Scenario map (what is actually exercised)**

* Basic replication/topology: 001, 002 (2-node), 003 cascade A→B→C,
  004 non-default repset, 018_forward_origins (n1→n2→n3, `forward_origins`
  switched via `sub_alter_options`), 015_forward_origin_advance (pre-created
  disabled sub's origin advanced from forwarded txns, "no duplicates, no gaps").
* Node add/remove (Z0DAN, `samples/Z0DAN/zodan.sql`): 009 (add n3 then
  zodremove), 012, 017 (fail fast when `sync_event` missing on source), 033
  (with lolor), 099 (mixed v5/v6 versions), 011 (add n3 while n1 and n2 run
  pgbench). In 011 the pgbench loads are **non-intersecting** by design
  (`samples/Z0DAN/n1.pgb` aid 1–50000, `n2.pgb` aid 50001–100000), and each
  script's updates net to zero.
* Exception handling / apply error paths: 013_exception_handling (discard,
  transdiscard, sub_disable), 015_skip_lsn, 016_sub_disable_missing_relation,
  020_exception_root_cause, 031, 039 (replay-mode leak after cancel between
  txns), 046 (mid-txn worker restart; apply_idle_timeout misclassification),
  105 (retransmit after disconnect under sub_disable), 035/036 (transient
  SQLSTATEs 40P01/55P03/53xxx/57P0x must retry, not disable).
* Crash / restart / progress tracking: 008_rmgr (clean restart, crash restart,
  stale resource.dat), 022_rmgr_progress_post_checkpoint_crash, 027 / 029
  (`remote_commit_ts` recovery from pg_commit_ts), 016 (skip_all — see below),
  023 (forced keepalive after reconnect), 026 (one fsync per applied commit).
* Connection loss: 019 (SIGKILL walsender → stale fd), 101 (clean exit, no
  replorigin advance to in-flight end_lsn), 102 (SIGKILL walsender during
  apply_delay sleep, assert no row loss), 104 (iptables REJECT on loopback,
  assert no row loss and no spurious exception_log rows), 105.
* Failover slots / standbys: 018_failover_slots (pg_basebackup standby, promote,
  reconnect n2), 020_sync_standby_feedback_lsn (confirmed_flush_lsn must not
  exceed publisher's current LSN), 028, 800.
* Conflict-resolution specifics: 014_pgdump_restore_conflict and
  013_origin_change_restore (origin-change logging for pre-subscription rows,
  `log_origin_change` modes), 021 (NULL key skip in `check_all_uc_indexes`),
  025 (no "tiebreaker values are equal" WARNING when a row is updated twice in
  one txn), 024 (node_id collision from `hash_any(name) & 0xffff`).
* DDL/catalog: 027_reserved_object, 030_autoddl_repset_stickiness, 034, 038,
  032/033 lolor, 037 (datestyle on wire), 045 (`get_lsn_from_commit_ts` bound).
* Supervisor race: 103 (CREATE/DROP DATABASE churn from 6 children + fast
  restart → manager-worker dboid race).

**Known-weak or disabled spots worth noting**

* `016_crash_recovery_progress.pl:19-40` is `plan skip_all`: after commit
  2f9a686c (PR #450, "Reduce work for spock.progress and remove checkpoint hook")
  `resource.dat` is written only at clean shutdown, so after SIGKILL
  `remote_insert_lsn` is only restored later by the publisher's forced
  keepalive; the strict equality "matches value before crash" races. This is a
  documented gap in crash-consistency of `spock.progress`.
* `005_daylight_savings.pl` is wrapped in `todo_skip` ("needs rewriting ... no
  sudo"): it set the system clock with `timedatectl`. **There is no working
  clock-change / clock-skew test.**
* `011_zodan_sync_third.pl:191-198` checks convergence with
  `SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts` compared
  across nodes. Because every pgbench script in `samples/Z0DAN/*.pgb` adds and
  subtracts the same amount, a whole lost or doubled transaction leaves
  `sum(abalance)` unchanged; this check only catches partial transactions or
  missing/extra rows.
* 046's header references `049_bidir_join_under_load.pl`, which is not in this
  tree (other branch); bidirectional join under load is therefore not covered here.
* `cross_wire` uses a fixed `sleep 10` rather than waiting for `replicating`.

### 4. Docker cluster (`tests/docker`) — detailed build, since Antithesis will reuse it

**Images**

1. `Dockerfile-base.el9` → `ghcr.io/pgedge/base-test-image:latest` (built and
   pushed by `.github/workflows/cache-base-image.yml`, multi-arch). Rocky Linux 9,
   "Development Tools", PG build deps (bison, flex, clang/llvm, icu, lz4, zstd,
   openssl, krb5, ldap, pam, libxml2/xslt, uuid, systemd-devel, python3-devel,
   perl-IPC-Run, perl-Test-Simple), openssh, user `pgedge` with passwordless
   sudo and an ed25519 key. dnf retries 5×.
2. `Dockerfile-step-1.el9` (`FROM ${BASE_IMAGE}`), build args `PGVER` (default
   17), `DBUSER=admin`, `DBPASSWD=testpass`, `DBNAME=demo`, `DBPORT=5432`,
   `MAKE_JOBS=4`, `PG_REF` (override), `SPOCK_RANDOM_DELAYS`,
   `ENABLE_INJECTION_POINTS`. Steps:
   * writes PG env (PGUSER/PGPASSWORD/PGDATABASE/PGPORT/PATH/PGDATA) into
     `/home/pgedge/.bashrc`; `PGDATA=/home/pgedge/pgedge/data/pg${PGVER}`,
     install prefix `/home/pgedge/pgedge/pg${PGVER}`.
   * `COPY . /home/pgedge/spock` (build context is repo root, `context: ../..`)
     and `COPY tests/docker/*.sh /home/pgedge/`.
   * clones **spockbench from GitHub master, unpinned** (`git clone --depth 1
     https://github.com/pgEdge/spockbench.git`, TODO says pin it) and
     `python3 setup.py install`. → Network access needed at build time; output
     not reproducible.
   * PG source: `tests/resolve-pg-ref.sh $PGVER` reads
     `tests/postgres-build.conf` (all majors currently `tag` → newest
     `REL_<major>_*` tag via `git ls-remote`; `branch` → `REL_<major>_STABLE`;
     or an explicit ref) then `git fetch --depth 1` from github.com/postgres/postgres.
     Also network-dependent; `PG_REF` build-arg pins it.
   * applies every file in `patches/${PGVER}/` in lexical order with
     `patch -p1` (PG18: `pg18-015-attoptions.diff` — per-column reloption
     `log_old_value` for delta apply; `pg18-025-logical_commit_clock.diff` —
     `remoteTransactionStopTimestamp`, a monotonic logical commit clock that the
     apply worker bumps forward when a remote commit appears to be in the
     future; `pg18-030-per-subtrans-commit-ts.diff` — `COMMIT_TS_SUBTRANS_TS`
     WAL record with per-subxact commit ts + nodeid). PG15 additionally has
     `pg15-010-allow_logical_decoding_on_standbys.diff`.
   * `./configure --enable-debug --enable-dtrace --enable-cassert
     --enable-tap-tests [--enable-injection-points] --with-llvm --with-python
     ... CFLAGS="-g -O0"`, `make`, `make -C contrib`, install.
   * spock: `make clean; make [SPOCK_RANDOM_DELAYS=1]; make install`.
   * `CMD /home/pgedge/entrypoint.sh && exec postgres -D $PGDATA -k /tmp` —
     postgres is PID 1 after init, so a postgres crash ends the container
     (no restart policy in compose).
   * Build takes a full PG compile per image; all three services build the
     same `image: spock` tag.

**`docker-compose.yml`**: services `pgedge-n1/n2/n3`, container/hostname
n1/n2/n3, env `HOSTNAME`, `PEER_NAMES` (other two), `TZ=America/Toronto`,
`env_file: pgedge.env`, host ports 15432–15434, `cap_add SYS_PTRACE SYS_ADMIN`,
unlimited core ulimit, volumes `./cores/nX:/cores` and `.:/home/pgedge/tests`
(the test scripts are bind-mounted, the **data directory is not a volume** — it
lives in the container layer). `depends_on` chains n2 on n1 healthy and n3 on
n2 healthy. Healthcheck: `pg_isready` AND `/tmp/spock_init_complete`.

**`entrypoint.sh`** (first start only, when `$PGDATA` is absent):
`initdb --locale=C`, appends `wal_level=logical`, `track_commit_timestamp=on`,
`max_worker_processes/replication_slots/wal_senders=32`,
`shared_preload_libraries='spock'`, `spock.conflict_resolution='last_update_wins'`,
`spock.save_resolutions='on'`, `listen_addresses='*'`, and
`output_plugin_libraries='pgoutput, test_decoding, spock_output'` if the GUC
exists (probe with `postgres --describe-config`). pg_hba `host all all
0.0.0.0/0 trust`. Starts PG, `createdb`, `CREATE EXTENSION spock`. n1:
`spock.node_create('n1', dsn, info := '{"tiebreaker":"1"}')`. n2/n3:
`CREATE EXTENSION dblink`, load `samples/Z0DAN/zodan.sql`, `CALL
spock.add_node(src_node_name:='n1', ..., new_node_name:=$HOSTNAME, ...)`. So
the mesh is built by Z0DAN add_node, sequentially (n2 then n3), not by
`sub_create` cross-wiring. Then `pg_ctl -m smart -t 60 stop`, touch marker,
`exec postgres`. On container restart PGDATA exists → init skipped.
Implication for Antithesis: cluster formation is done inside container
startup and depends on ordering; a fault during startup could leave a node
half-joined with the container still "healthy" only if add_node finished.
Antithesis setup will likely want init moved to a separate setup step and
`depends_on` replaced by a readiness wait.

**What runs on it**

* `spockbench.yml` (per PR, PG15–19, image with `ENABLE_INJECTION_POINTS=1`):
  `docker compose up --wait`, then `run-tests.sh` concurrently on n1, n2, n3:
  * n1 only: exception-log check — table `t4` created with different data on n1
    and n2, then n1 does insert-dup / update-missing / delete-missing; waits
    with `sync_event`/`wait_for_sync_event`; asserts one UPDATE row in
    `spock.exception_log` on n2 and `insert_exists` + `delete_missing` in
    `spock.resolutions`.
  * every node: `spockbench -i -s 10 --spock-node=N` (same schema created
    independently on each node, autoDDL off), `repset_add_all_tables('default',
    '{public}')`, then `spockbench --spock-num-nodes=3 -s 10 -T 120 -R 3000 -j 16
    -c 50 --spock-tx-mix=550,225,225` on all three nodes at once. Header comment:
    spockbench turns on delta apply for the `balance` columns. **This is the
    only test anywhere with concurrent writes to overlapping rows on 3 nodes.**
  * `sleep 5` ("There are still races possible"), then for each peer
    `sync_event()` on peer + `wait_for_sync_event` locally, then
    `spockbench-check $PGDATABASE > spockbench-$HOST.out`; fail on any "ERROR"
    line. spockbench-check is external (not in this tree), so what it compares
    (per-node invariants vs cross-node equality) cannot be confirmed here.
  * Same job then runs `run-spock-regress.sh` and the TAP `schedule` in a
    single `docker run` of the same image (not the compose cluster).
* `installcheck.yml` (per PR, PG15–19): 3-node compose cluster with
  `DBUSER=regression DBNAME=regression`; runs the **core PostgreSQL**
  `parallel_schedule` against n1 (`run-installcheck.sh`, skipping
  `security_label` and PG19 `create_property_graph`). Checks only that core
  regress output matches on n1 and containers exit 0 (`check-outputs.sh`);
  n2/n3 logs are kept but "can't pass these tests without errors". Acts as a
  DDL/DML fuzz of autoDDL; no convergence check.
* `random-delays-regress.yml`, `nightly_tap.yml`, `zodan_sync.yml`,
  `pgindent.yml` use the step-1 image via plain `docker run`, not compose.
* Helper scripts `build`, `up`, `down` (`down -v`), `exec` call `docker-compose`.

### 5. Non-Docker mesh rigs

* `tests/run-single-pg18-installcheck.sh` (`installcheck-single-pg18.yml`,
  every push): builds PG REL_18_STABLE + patches (`git apply`, :382-397) +
  spock, 3 clusters in a full mesh (6 subs, `exception_behaviour='discard'`,
  autoDDL on), runs core `make installcheck` on n1, then asserts every
  subscription `sub_enabled` and `sync_event` round-trips on all 6 directed
  edges (:811-959). Liveness only; no row comparison.
* `tests/run-cluster-upgrade.sh` (6930 lines, `nightly_cluster_upgrade.yml`
  04:00 UTC): 3 nodes on PG17 (v5_STABLE spock), loaded with the core regress DB,
  rolling `pg_upgrade` to PG19 with HEAD spock per a written procedure, a
  "witness table" written on peers while a node is fenced (keyed so loss =
  missing key, duplicate = PK conflict), and **ACE `repset-diff`** for
  cross-node comparison (header :18-25, :152). States its own gaps (:140-156):
  no per-table checksum because pg_lsn text rendering changed in PG18, rollback
  path not exercised.

### 6. Convergence-checking tooling available

* `spock.sync_event()` + `CALL spock.wait_for_sync_event(wait_if_disabled,
  origin_name, lsn, timeout)` — per-edge "caught up to this LSN" barrier; used
  by `SpockTest::sync_nodes`, run-tests.sh, single-pg18 rig, regress
  `sync_event.sql`. Proves delivery of a marker, not data equality.
* `spock.wait_slot_confirm_lsn(NULL, NULL)` — provider-side wait for all slots.
* `wait_subscription()` from `samples/Z0DAN/wait_subscription.sql` (lag ≤ 0).
* Aggregate equality (`sum/count`) in 011 — weak, see above.
* ACE repset-diff / table-diff (external Go tool, only in cluster-upgrade rig).
* spockbench-check (external Python, only in Docker run).
* `spock.exception_log`, `spock.resolutions` (`spock.save_resolutions=on`),
  PG18 conflict stats (`spock.reset_subscription_stats`) — used as oracles for
  "no spurious exception" (104) and "expected conflict type logged".
* No in-tree generic "dump every replicated table on every node and compare"
  helper exists. Antithesis will need its own (e.g. ordered md5 of
  `SELECT * ... ORDER BY pk` per table after a quiesce + sync_event barrier).

### 7. What is NOT tested (where Antithesis adds value)

1. **Conflicting concurrent writes on 3+ nodes with faults.** Only spockbench
   (no faults) writes overlapping rows; all TAP conflicts are staged by hand
   (divergent row on subscriber, then one remote change). Insert/insert races on
   the same PK, update/delete races, update/update on the same row from three
   nodes, and secondary-unique-key races under partition are untested.
2. **Network partitions.** Only 104 (loopback iptables REJECT, 2 nodes, not
   scheduled; over loopback it often stalls instead of resetting). No
   asymmetric partition, no partition between subsets of a 3-node mesh, no
   latency/packet-delay, no partition during add_node / sync / COPY.
3. **Clock skew / clock jumps.** 005 is disabled; regress runs in one instance
   (one clock); TAP nodes share a host clock; Docker containers share the host
   kernel clock. `last_update_wins` ordering, the logical commit clock patch
   (`remoteTransactionStopTimestamp`), equal-timestamp tiebreaker
   (`info '{"tiebreaker":...}'`, 025 only checks a WARNING) and
   `get_lsn_from_commit_ts`/`remote_commit_ts` recovery under skew are never
   exercised with nodes that disagree on time.
4. **Random crash timing.** Crash tests kill at one chosen point (idle worker,
   during apply_delay sleep, after a checkpoint). No kill/pause at random
   points in commit → origin advance → progress flush, during spill-to-disk,
   during table sync/COPY, during Z0DAN add_node phases, or of the provider
   mid-decode. `spock.progress` crash consistency is admitted as not
   guaranteed (016 skip_all).
5. **Process pause (SIGSTOP) / slow nodes.** Only one injection-point stall
   (046 scenario 2). Long walsender/apply pauses vs `wal_sender_timeout`,
   `spock.apply_idle_timeout`, keepalive logic are lightly covered.
6. **Node add/remove under faults.** 011 adds a node under non-conflicting load
   with no faults; 017 covers one missing-function failure. No crash or
   partition mid-add_node / remove_node, no concurrent add of two nodes.
7. **Repeated runs / long runs.** Only 011 is looped (10×, weekly). Flaky
   timing bugs surface mainly by chance in CI.
8. **Exception-behaviour modes under load.** `sub_disable` is the TAP default;
   `discard`/`transdiscard` are checked on small scripted transactions, not
   with faults causing retransmission while conflicts are being logged (the
   retransmission-misread class of bugs fixed in 046/105/039 suggests this area
   still has bugs).
9. **Data equality after the fact.** Most tests check a few specific rows or
   counts. No test checks full cross-node equality of all replicated tables
   after a fault scenario (the upgrade rig with ACE is the exception, and it
   has no faults besides planned fencing).

---

## Areas examined

* `tests/regress/{sql,expected,*.conf}`, `Makefile:26-30, 55-176`
* `tests/tap/{schedule,schedule-nightly,run_tests.sh,README.md}`, every
  `tests/tap/t/*.pl` header, `tests/tap/t/SpockTest.pm` in full
  (create/cross_wire/conf/wait helpers); bodies of 005, 011, 046, 104 in part
* `tests/docker/*` (Dockerfile-base.el9, Dockerfile-step-1.el9,
  docker-compose.yml, entrypoint.sh, pgedge.env, run-*.sh, check-outputs.sh)
* `tests/postgres-build.conf`, `tests/resolve-pg-ref.sh`,
  headers of `tests/run-cluster-upgrade.sh`, `tests/run-single-pg18-installcheck.sh`
* `.github/workflows/*.yml` (all 11; release.yml only skimmed — packaging only)
* `include/spock_injection.h`, `src/spock_injection.c`, call sites in
  `spock_worker.c`, `spock_apply.c`, `spock_output_plugin.c`
* `patches/18/*` headers; `samples/Z0DAN/*.pgb`
* `git log -- tests/` (last 25 commits)

## Assumptions

* spockbench `--spock-tx-mix=550,225,225` produces overlapping-row conflicts
  across the three nodes and spockbench-check validates balance invariants;
  inferred from run-tests.sh comments, not verified (external repo).
* `tests/docker/spock.patches/` is an (empty or unused) directory — `cat` failed
  on it and nothing references it.
* CI uses GitHub-hosted ubuntu runners for all Docker work (no self-hosted
  multi-host setup), so no test ever runs nodes on separate kernels/clocks.

## Open Questions

* What exactly does spockbench-check verify — per-node invariants (e.g. sum of
  balances) or cross-node equality? Is spockbench pinnable to a commit for a
  reproducible Antithesis image?
* Is there a reason 101/102/027/104 are not in the PR schedule (flaky? slow?
  need root)? If flaky, those are strong leads for Antithesis.
* Should the Antithesis image reuse `Dockerfile-step-1.el9` directly (needs
  network at build for PG source + spockbench) or vendor/pin `PG_REF` and
  spockbench? Antithesis builds generally want hermetic images.
* Does `049_bidir_join_under_load.pl` (referenced by 046) exist on another
  branch, and what did it find?
* Is the 016 `spock.progress` crash gap considered a correctness issue (could
  it cause wrong restart LSN / duplicate apply) or only a monitoring
  inaccuracy? Other discovery agents covering progress/origin should confirm.
