use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail system_maybe
    wait_for_sub_status wait_for_pg_ready
);

# =============================================================================
# Test: 046_apply_worker_exception_misclassification.pl
# =============================================================================
# Two related bugs in the apply worker's restart/exit machinery, both found
# by auditing that code after the first was found: a non-error event gets
# misread as evidence of a prior apply failure, entering exception replay
# and, under spock.exception_behaviour = sub_disable, disabling a healthy
# subscription for a transaction that never actually errored.
#
# Scenario 1 -- mid-transaction worker restart:
#   handle_begin() stamps exception_log->commit_lsn on every BEGIN, not just
#   ones that fail. A worker restart (e.g. sub_alter_options() reconnecting
#   to pick up a new setting) can land mid-transaction, and the provider's
#   ordinary retransmission of that same transaction to the replacement
#   worker matches the stale commit_lsn on its first BEGIN.
#
# Scenario 2 -- apply-idle-timeout misclassification:
#   spock.apply_idle_timeout's "no data received... reconnecting" error was
#   a bare elog(ERROR), defaulting to a sqlerrcode the PG_CATCH
#   discriminator in apply_work() doesn't recognize as connection-class, so
#   a merely-slow or stalled provider mid-transaction fell into the same
#   branch as a genuine data conflict.
#
# Both scenarios run against one shared 2-node cluster and subscription.
# Scenario 2 needs PostgreSQL's core injection_points test module, which
# only exists when the server was configured with --enable-injection-points
# -- it is not part of an ordinary `make install`/`ninja install`. Scenario 1
# has no such dependency and always runs; only scenario 2 is skipped when
# the module is unavailable.
# =============================================================================

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};

my $pkglibdir = `"$pg_bin/pg_config" --pkglibdir`;
chomp $pkglibdir;
my $has_injection_points = (-e "$pkglibdir/injection_points.so")
    || (-e "$pkglibdir/injection_points.dylib");
my $skip_reason =
    "server not built with --enable-injection-points " .
    "(no injection_points test module in $pkglibdir)";

create_cluster(2, 'Create 2-node apply-worker exception-misclassification cluster');

$config = get_test_config();
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $datadir1 = $config->{node_datadirs}->[0];
my $log_file = $config->{log_file};
my $conn = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# n1 (the provider) needs injection_points in shared_preload_libraries for
# scenario 2 to attach test injection points -- that's a postmaster-start
# GUC, so add it and restart just this node, before any subscription
# exists. A later duplicate setting in postgresql.conf overrides the
# earlier one, so appending is enough. Skipped entirely when the module
# isn't available; scenario 1 doesn't need it.
SKIP: {
    skip $skip_reason, 1 unless $has_injection_points;

    open(my $conf, '>>', "$datadir1/postgresql.conf")
        or die "Cannot open $datadir1/postgresql.conf: $!";
    print $conf "shared_preload_libraries='spock,injection_points'\n";
    close($conf);

    system_or_bail("$pg_bin/pg_ctl", '-D', $datadir1, '-w', '-m', 'fast', 'stop');
    system("$pg_bin/postgres -D $datadir1 >> '$log_file' 2>&1 &");
    ok(wait_for_pg_ready($host, $p1, $pg_bin, 30), 'n1 restarted with injection_points preloaded');

    psql_or_bail(1, "CREATE EXTENSION injection_points");
}

psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = sub_disable");
psql_or_bail(2, "ALTER SYSTEM SET spock.apply_idle_timeout = 3");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(1);

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], true, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

# =============================================================================
# Scenario 1: mid-transaction worker restart
# =============================================================================

psql_or_bail(1, "CREATE TABLE midtxn_restart (id bigint PRIMARY KEY, val text)");
psql_or_bail(1, "CREATE SEQUENCE midtxn_restart_id_seq");

# A PROCEDURE (not a DO block) can issue its own internal COMMITs, so a
# single long-lived connection produces a continuous stream of separately
# committed, multi-row transactions -- wide enough for a worker restart to
# land mid-transaction -- without the overhead of spawning one psql process
# per transaction.
psql_or_bail(1, q{
    CREATE PROCEDURE midtxn_restart_load(n_batches int, batch_rows int)
    LANGUAGE plpgsql AS $$
    DECLARE i int;
    BEGIN
        FOR i IN 1..n_batches LOOP
            INSERT INTO midtxn_restart
                SELECT nextval('midtxn_restart_id_seq'), 'x' || g
                FROM generate_series(1, batch_rows) g;
            COMMIT;
            -- Bulk INSERT...SELECT is fast enough to produce tens of
            -- millions of rows in the toggle loop's ~12s window, far more
            -- than row-by-row logical apply can drain afterwards. Throttle
            -- so total volume stays boundable while each transaction is
            -- still wide enough for a worker restart to land mid-flight.
            PERFORM pg_sleep(0.02);
        END LOOP;
    END $$;
});

# Background writer, left running for the duration of the restart-toggle
# loop below. Killing the *client* process on its own would not reliably
# stop it -- Postgres does not proactively notice a dropped client
# connection while a backend is busy inside a single long-running CALL
# (no client_connection_check_interval by default) -- so it is stopped
# server-side afterwards via pg_terminate_backend().
my $writer_pid = fork();
die "fork() failed: $!" unless defined $writer_pid;
if ($writer_pid == 0) {
    exec("$pg_bin/psql", '-X', '-p', $p1, '-d', $dbname,
         '-c', "CALL midtxn_restart_load(100000, 500)")
        or exit(127);
}

# Restart the apply worker repeatedly while the writer is running, via
# sub_alter_options() toggling apply_delay -- the same mechanism that
# uncovered this bug in 049_bidir_join_under_load.pl's lag-injection
# scenario.
for my $i (1 .. 40) {
    system_or_bail("$pg_bin/psql", '-X', '-p', $p2, '-d', $dbname, '-c',
        "SELECT spock.sub_alter_options('sub_n1_n2', '{\"apply_delay\": \"1 millisecond\"}'::jsonb)");
    select(undef, undef, undef, 0.15);
    system_or_bail("$pg_bin/psql", '-X', '-p', $p2, '-d', $dbname, '-c',
        "SELECT spock.sub_alter_options('sub_n1_n2', '{\"apply_delay\": \"0\"}'::jsonb)");
    select(undef, undef, undef, 0.15);
}

# Stop the writer at the server: terminate the backend actually running the
# CALL, then confirm it is gone before treating n1's row count as final.
system_or_bail("$pg_bin/psql", '-X', '-p', $p1, '-d', $dbname, '-c',
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " .
    "WHERE query LIKE 'CALL midtxn_restart_load%' AND pid <> pg_backend_pid()");
for (1 .. 30) {
    my $still_running = scalar_query(1,
        "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'CALL midtxn_restart_load%'");
    last if defined $still_running && $still_running eq '0';
    sleep(1);
}
kill('TERM', $writer_pid);
waitpid($writer_pid, 0);

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 60),
    'scenario 1: subscription is still replicating after repeated mid-load worker restarts');

is(scalar_query(2,
       "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'"),
   't', 'scenario 1: SUB_DISABLE subscription remains enabled after repeated restarts');

my $s1_count1 = scalar_query(1, "SELECT count(*) FROM midtxn_restart");

my $s1_count2;
for (1 .. 120) {
    $s1_count2 = scalar_query(2, "SELECT count(*) FROM midtxn_restart");
    last if defined $s1_count2 && $s1_count2 eq $s1_count1;
    sleep(1);
}
is($s1_count2, $s1_count1, 'scenario 1: no rows lost/discarded across the restarts');

is(scalar_query(2, "SELECT count(*) FROM spock.exception_log"),
   '0', 'scenario 1: no exceptions were ever logged');

# =============================================================================
# Scenario 2: apply-idle-timeout misclassification
# =============================================================================

SKIP: {
    skip $skip_reason, 7 unless $has_injection_points;

    psql_or_bail(1, "CREATE TABLE idle_timeout_midtxn (id int PRIMARY KEY, val text)");

    # Apply workers set application_name to "spock apply <dboid>:<subid>"
    # (see BackgroundWorkerInitializeConnection() in spock_worker.c); with
    # one subscription on n2 this identifies it unambiguously. Recorded
    # before the stall so a later PID change proves the idle-timeout error
    # actually fired and drove a real worker restart through the
    # ERRCODE_CONNECTION_FAILURE path -- not just that nothing else broke.
    my $worker_pid_before = scalar_query(2,
        "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'spock apply %'");

    psql_or_bail(1, "SELECT injection_points_attach('spock-output-txn-stall', 'wait')");

    psql_or_bail(1, q{
        BEGIN;
        INSERT INTO idle_timeout_midtxn VALUES (1, 'before');
        INSERT INTO idle_timeout_midtxn VALUES (2, 'stalled-here');
        INSERT INTO idle_timeout_midtxn VALUES (3, 'after');
        COMMIT;
    });

    my $stalled = 0;
    for (1 .. 30) {
        my $n = scalar_query(1,
            "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'walsender' " .
            "AND wait_event = 'spock-output-txn-stall'");
        if (defined $n && $n >= 1) {
            $stalled = 1;
            last;
        }
        sleep(1);
    }
    ok($stalled, 'scenario 2: walsender hit the mid-transaction stall injection point');

    # apply_idle_timeout is 3s, and the worker paces its respawn by
    # spock.restart_delay_default (5s default) after the idle-timeout
    # error, so the new PID isn't expected to appear for up to ~8s. Watch
    # well past that and confirm both that the apply worker actually
    # restarts through the idle-timeout reconnect path (proving the fix's
    # code path executed) and that the subscription is never disabled
    # while doing so.
    my $worker_restarted = 0;
    my $disabled_during_stall = 0;
    for (1 .. 20) {
        my $enabled = scalar_query(2,
            "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'");
        if (defined $enabled && $enabled eq 'f') {
            $disabled_during_stall = 1;
            last;
        }
        my $worker_pid_now = scalar_query(2,
            "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'spock apply %'");

        # A reconnect attempt right after the idle-timeout exit typically
        # fails immediately with "replication slot is active" (the old,
        # still-stalled walsender hasn't released it yet) and the worker
        # dies again in milliseconds -- far faster than this 1s polling
        # interval can catch it alive with a new PID. So treat the PID
        # going empty as proof of restart too, not just a differing
        # non-empty PID: the original PID is guaranteed non-empty (the
        # subscription was already confirmed replicating), so either
        # outcome means the original worker is gone.
        if (defined $worker_pid_now && $worker_pid_now ne $worker_pid_before) {
            $worker_restarted = 1;
        }
        last if $worker_restarted;
        sleep(1);
    }
    ok($worker_restarted,
        'scenario 2: apply worker restarted through the idle-timeout reconnect path');
    ok(!$disabled_during_stall,
        'scenario 2: subscription stays enabled while the provider is stalled past apply_idle_timeout');

    # If scenario 1's bug already disabled the subscription, nothing ever
    # decoded this transaction and the injection point was never reached --
    # waking a point nobody is waiting on is then an error in its own right,
    # not a symptom worth crashing this test over. Best-effort only.
    system_maybe("$pg_bin/psql", '-X', '-p', $p1, '-d', $dbname, '-c',
        "SELECT injection_points_wakeup('spock-output-txn-stall')");
    system_maybe("$pg_bin/psql", '-X', '-p', $p1, '-d', $dbname, '-c',
        "SELECT injection_points_detach('spock-output-txn-stall')");

    my $s2_count1 = scalar_query(1, "SELECT count(*) FROM idle_timeout_midtxn");
    my $s2_count2;
    for (1 .. 60) {
        $s2_count2 = scalar_query(2, "SELECT count(*) FROM idle_timeout_midtxn");
        last if defined $s2_count2 && $s2_count2 eq $s2_count1;
        sleep(1);
    }
    is($s2_count2, $s2_count1,
        'scenario 2: the stalled transaction applies in full once released, no rows lost');

    is(scalar_query(2,
           "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'"),
       't', 'scenario 2: subscription is not disabled by the idle-timeout liveness reconnect');

    ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
        'scenario 2: subscription returns to replicating after the reconnect');

    is(scalar_query(2, "SELECT count(*) FROM spock.exception_log"),
       '0', 'scenario 2: no spurious exception_log entry for the idle-timeout liveness reconnect');
}

destroy_cluster('Destroy apply-worker exception-misclassification cluster');
done_testing();
