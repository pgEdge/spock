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
# Test 101: Apply worker exits cleanly on connection loss (no replorigin leak)
# =============================================================================
#
# Verifies the connection-error short-circuit added at the top of apply_work's
# PG_CATCH (src/spock_apply.c).  When the upstream connection dies the worker
# must:
#
#   1. classify the error via sqlerrcode (ERRCODE_CONNECTION_FAILURE) or
#      PQstatus(applyconn) == CONNECTION_BAD as a fallback,
#   2. clear replorigin_session_origin / _lsn / _timestamp directly (without
#      calling replorigin_session_reset(), which would release the in-memory
#      slot and leave session_replication_state == NULL, tripping an Assert in
#      replorigin_session_advance on any subsequent commit path) so that
#      spock_apply_main's on-exit flush_progress_if_needed(true) commit does
#      not advance the replication origin to the stale in-flight end_lsn,
#   3. return cleanly from apply_work rather than goto'ing stream_replay with
#      stale libpq state,
#   4. emit a single LOG line "connection error during apply, exiting via rethrow".
#
# Test 019 already proves the stale-fd / epoll_ctl absence; this test
# additionally asserts the new clean-exit log signature is present, which is
# the only positive proof that the new discriminator was engaged.  Apply-side
# errors (constraint violations etc.) intentionally do not take this branch
# and continue to use the spock.exception_log replay path.
#
# Without the fix:
#   - the LOG line "connection error during apply, exiting via rethrow" is absent
#   - "error during exception handling" appears (replay path tries to
#     re-enter stream_replay with stale libpq state)
#
# As in test 019 we SIGKILL the walsender so libpq sees a hard EOF without a
# CopyDone.  SIGKILL also crashes the provider postmaster which restarts
# automatically; that gives us a realistic firewall-style disconnect.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for clean-exit regression test');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};
my $log_dir     = $config->{log_dir};

my $p1 = $node_ports->[0];   # n1 — provider
my $p2 = $node_ports->[1];   # n2 — subscriber

my $conn_n1 = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";
my $pg_log_n2 = "$log_dir/00${p2}.log";

# Match the customer's environment (TRANSDISCARD).  ALTER SYSTEM writes
# postgresql.auto.conf which takes precedence over SpockTest.pm defaults.
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard'");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(1);

psql_or_bail(1, "CREATE TABLE test_clean_exit (id SERIAL PRIMARY KEY, val TEXT)");
psql_or_bail(2, "CREATE TABLE test_clean_exit (id SERIAL PRIMARY KEY, val TEXT)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 reaches replicating state');

# Drive a series of small commits so the apply worker has plenty of in-flight
# state when we kill the walsender.  Each statement in psql is its own
# implicit transaction, which is what we want here.
my $batch = '';
for my $i (1 .. 100) {
    $batch .= "INSERT INTO test_clean_exit (val) VALUES ('pre_$i');\n";
}
psql_or_bail(1, $batch);
sleep(2);

my $pre_count = scalar_query(2, "SELECT count(*) FROM test_clean_exit");
is($pre_count, '100', 'baseline 100 rows replicate n1->n2');

my $log_offset = -s $pg_log_n2 // 0;

my $walsender_pid = scalar_query(1,
    "SELECT pid FROM pg_stat_replication WHERE state = 'streaming' LIMIT 1");

my $signaled = 0;
if (defined $walsender_pid && $walsender_pid =~ /^\d+$/) {
    $signaled = kill 9, int($walsender_pid);
}
BAIL_OUT("could not SIGKILL walsender PID " . ($walsender_pid // 'undef') .
         " — apply worker may not have been streaming yet")
    unless $signaled;
diag("SIGKILL sent to walsender PID $walsender_pid");

# 12 s covers the n2 PG_CATCH discriminator path + n1 crash recovery + n2
# manager respawn.  We do NOT want to wait until replication catches up here
# — we want to scrape the log for the proof-of-engagement LOG line first.
sleep(12);

my $new_log = '';
if (open(my $lf, '<', $pg_log_n2)) {
    seek($lf, $log_offset, 0);
    local $/;
    $new_log = <$lf> // '';
    close($lf);
}

# Primary assertion: the discriminator was engaged.  This message is emitted
# by the new connection-error branch in PG_CATCH and exists only with the
# fix in place.  Without the fix, the worker exits via the existing
# goto-stream_replay path and never logs this string.
my $clean_exit =
    ($new_log =~ /connection error during apply, exiting via rethrow/) ? 1 : 0;
ok($clean_exit,
    'n2 log shows "connection error during apply, exiting via rethrow" (fix engaged)');
if (!$clean_exit) {
    my @recent = grep { /SPOCK|connection|epoll|exception/ }
                 split /\n/, $new_log;
    diag("FAIL: clean-exit log line missing — discriminator did not fire");
    diag("Recent SPOCK/connection log lines on n2:");
    diag("  $_") for @recent;
}

# Secondary cross-platform assertion: the second-exception cascade ("error
# during exception handling") must not appear, because the discriminator
# prevents re-entry into stream_replay with stale libpq state.  This
# overlaps with test 019 but is included so this test is self-contained.
my $eeh = ($new_log =~ /error during exception handling/) ? 1 : 0;
ok(!$eeh, 'no "error during exception handling" after connection loss');

# Linux-specific: the stale-fd path produces epoll_ctl(EINVAL).  Absent with
# the fix.
SKIP: {
    skip 'epoll_ctl error is Linux-specific', 1 unless $^O eq 'linux';
    my $epoll_err = ($new_log =~ /epoll_ctl\(\) failed/) ? 1 : 0;
    ok(!$epoll_err, 'Linux: no epoll_ctl() error after connection loss');
}

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 returns to replicating state after reconnect');

# Drive more rows and confirm row counts match — sanity check that no
# transaction was silently skipped on either side of the disconnect.
my $batch2 = '';
for my $i (101 .. 150) {
    $batch2 .= "INSERT INTO test_clean_exit (val) VALUES ('post_$i');\n";
}
psql_or_bail(1, $batch2);

# Poll for catch-up rather than fixed sleep.
my $caught_up = 0;
my $n1_count;
my $n2_count;
for my $attempt (1 .. 30) {
    $n1_count = scalar_query(1, "SELECT count(*) FROM test_clean_exit");
    $n2_count = scalar_query(2, "SELECT count(*) FROM test_clean_exit");
    if (defined $n1_count && defined $n2_count && $n1_count eq $n2_count) {
        $caught_up = 1;
        last;
    }
    sleep(1);
}

ok($caught_up,
    "subscriber caught up to publisher row count (n1=$n1_count, n2=$n2_count)");

my $n1_max = scalar_query(1, "SELECT coalesce(max(id), 0) FROM test_clean_exit");
my $n2_max = scalar_query(2, "SELECT coalesce(max(id), 0) FROM test_clean_exit");
is($n2_max, $n1_max,
    "subscriber max(id) matches publisher (n1=$n1_max, n2=$n2_max)");

system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_drop('sub_n1_n2')");

destroy_cluster('Destroy cluster after clean-exit regression test');

done_testing();
