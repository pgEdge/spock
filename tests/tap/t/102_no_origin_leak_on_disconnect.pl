use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    system_maybe
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status
);

# =============================================================================
# Test 102: apply_delay + walsender SIGKILL — no assertion crash, no row loss
# =============================================================================
#
# Companion to test 101.  Test 101 verifies the discriminator branch in
# apply_work's PG_CATCH was engaged (via the unique "connection error during
# apply, exiting via rethrow" log line) when the worker is idle in
# WaitLatchOrSocket.  Test 102 covers a different shape: the worker is
# inside handle_begin's apply_delay pg_usleep when the upstream connection
# is severed.  This was the path where an earlier version of the fix
# (calling replorigin_session_reset() to detach the session origin slot)
# tripped an "Assert(session_replication_state != NULL)" in
# replorigin_session_advance during spock_apply_main's on-exit
# flush_progress_if_needed(true) commit -- because update_progress_entry
# carries a stale session_origin_lsn into RecordTransactionCommit.
#
# The current fix (in spock_apply.c) clears the session origin variables
# directly without releasing the in-memory slot, mirroring spock's existing
# spock_apply_worker_shmem_exit pattern.  This both blocks the leak via
# RecordTransactionAbort/Commit advance gate AND avoids the dangling slot
# pointer.  This test catches a regression to either issue.
#
# What this test does verify:
#   - SIGKILL of the walsender during the apply worker's pg_usleep does
#     not crash the apply worker with an assertion failure
#   - The "connection error during apply, exiting via rethrow" log line fires
#   - The subscription recovers cleanly back to "replicating"
#   - All rows committed on the publisher (including the ones that were
#     in-flight at SIGKILL time) end up on the subscriber
#
# What this test does NOT verify:
#   - The leak invariant in a true mid-DML scenario.  apply_delay's
#     pg_usleep delays disconnect detection until AFTER handle_commit has
#     completed legitimately, so the apply worker is between transactions
#     when PG_CATCH fires -- there is no in-flight remote transaction
#     whose final_lsn could leak through.  Reproducing the true mid-DML
#     scenario deterministically requires injection points which the
#     v5_STABLE branch does not have.  The leak-prevention invariant is
#     preserved by code analogy with PG core's start_apply PG_CATCH
#     (src/backend/replication/logical/worker.c:4452).
# =============================================================================

create_cluster(2, 'Create 2-node cluster for apply_delay disconnect test');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};
my $log_dir     = $config->{log_dir};

my $p1 = $node_ports->[0];
my $p2 = $node_ports->[1];

my $conn_n1 = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";
my $pg_log_n2 = "$log_dir/00${p2}.log";

psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard'");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(1);

psql_or_bail(1, "CREATE TABLE test_origin_leak (id SERIAL PRIMARY KEY, val TEXT)");
psql_or_bail(2, "CREATE TABLE test_origin_leak (id SERIAL PRIMARY KEY, val TEXT)");

# 15s apply_delay: long enough to reliably catch the worker inside
# handle_begin's pg_usleep when we SIGKILL the walsender.
psql_or_bail(2,
    "SELECT spock.sub_create(" .
    "subscription_name => 'sub_n1_n2', " .
    "provider_dsn => '$conn_n1', " .
    "replication_sets => ARRAY['default', 'default_insert_only', 'ddl_sql'], " .
    "synchronize_structure => false, " .
    "synchronize_data => false, " .
    "apply_delay => '15 seconds'::interval)");

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 reaches replicating state');

# Baseline: 5 rows.  apply_delay=15s so each commit takes 15s+ to land.
my $batch = '';
$batch .= "INSERT INTO test_origin_leak (val) VALUES ('pre_$_');\n" for 1 .. 5;
psql_or_bail(1, $batch);

my $baseline_count = 0;
for (1 .. 40) {
    $baseline_count = scalar_query(2, "SELECT count(*) FROM test_origin_leak");
    last if defined $baseline_count && $baseline_count eq '5';
    sleep(1);
}
is($baseline_count, '5', 'baseline 5 rows replicate n1->n2 (after apply_delay)');

# Insert T_inflight on the publisher.  We will SIGKILL the walsender while
# the apply worker is in pg_usleep waiting on this transaction's
# apply_delay.
psql_or_bail(1, "INSERT INTO test_origin_leak (val) VALUES ('inflight_critical')");

# Wait so n2's apply worker has received T_inflight and entered its
# apply_delay pg_usleep.
sleep(3);

# Snapshot subscriber log offset BEFORE SIGKILL so we can scrape only the
# new lines.
my $log_offset = -s $pg_log_n2 // 0;

my $walsender_pid = scalar_query(1,
    "SELECT pid FROM pg_stat_replication WHERE state = 'streaming' LIMIT 1");
BAIL_OUT("no streaming walsender to SIGKILL — apply worker not yet attached")
    unless defined $walsender_pid && $walsender_pid =~ /^\d+$/;

my $signaled = kill 9, int($walsender_pid);
BAIL_OUT("could not SIGKILL walsender PID $walsender_pid") unless $signaled;
diag("SIGKILL sent to walsender PID $walsender_pid (subscriber is mid-pg_usleep)");

# 18 s: covers worker wake (12s remaining of pg_usleep) + handle_commit
# of the in-flight txn + connection-failure detection + clean exit +
# manager respawn + new worker entering its own apply_delay sleep.
sleep(18);

my $new_log = '';
if (open(my $lf, '<', $pg_log_n2)) {
    seek($lf, $log_offset, 0);
    local $/;
    $new_log = <$lf> // '';
    close($lf);
}

# (1) The discriminator branch fired — this is the unique positive proof.
my $clean_exit =
    ($new_log =~ /connection error during apply, exiting via rethrow/) ? 1 : 0;
ok($clean_exit, 'apply worker logged "connection error during apply, exiting via rethrow"');

# (2) No assertion crash from replorigin_session_advance.  An earlier
# iteration of the fix called replorigin_session_reset() which detached
# the in-memory slot pointer, leaving session_replication_state == NULL
# while replorigin_session_origin and update_progress_entry were still
# carrying the stale state into the on-exit catalog commit -- triggering
# Assert("session_replication_state != NULL").  Catch any regression.
my $assert_failed =
    ($new_log =~ /Assert.*session_replication_state.*!= NULL/) ? 1 : 0;
ok(!$assert_failed,
    'no Assert(session_replication_state != NULL) failure on apply worker exit');

my $aborted_signal_6 =
    ($new_log =~ /spock apply.*was terminated by signal 6: Aborted/) ? 1 : 0;
ok(!$aborted_signal_6,
    'no signal 6 (SIGABRT) termination on apply worker exit');

# (3) Subscription recovers and forward progress resumes.
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 60),
    'sub_n1_n2 returns to replicating state after reconnect');

psql_or_bail(1, "INSERT INTO test_origin_leak (val) VALUES ('post_recovery')");

# (4) All rows match — including T_inflight which was in-flight at the
# moment of SIGKILL.  If progress had been incorrectly advanced past
# T_inflight, the new worker would have skipped it on START_REPLICATION
# and the count would be short by 1.
my $caught_up = 0;
my ($n1_count, $n2_count);
for (1 .. 60) {
    $n1_count = scalar_query(1, "SELECT count(*) FROM test_origin_leak");
    $n2_count = scalar_query(2, "SELECT count(*) FROM test_origin_leak");
    if (defined $n1_count && defined $n2_count && $n1_count eq $n2_count) {
        $caught_up = 1;
        last;
    }
    sleep(1);
}
ok($caught_up,
    "subscriber caught up to publisher (n1=$n1_count, n2=$n2_count)");

is(scalar_query(2,
    "SELECT count(*) FROM test_origin_leak WHERE val = 'inflight_critical'"),
    '1',
    'in-flight transaction is durably present on subscriber after recovery');

system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_drop('sub_n1_n2')");

destroy_cluster('Destroy cluster after apply_delay disconnect test');

done_testing();
