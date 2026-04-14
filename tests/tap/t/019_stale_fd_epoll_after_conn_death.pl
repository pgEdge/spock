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
# Test 019: Stale socket fd causes spurious worker restart after provider death
# =============================================================================
#
# Bug: fd = PQsocket(applyconn) is captured once before stream_replay: and
# never refreshed.  When the provider connection dies, the worker catches the
# first exception, aborts, and jumps back to stream_replay: with use_try_block=
# true.  On re-entry the fd is stale:
#
#   Linux: epoll_ctl(EPOLL_CTL_ADD, closed_fd) -> EBADF/EINVAL
#          => ERROR "epoll_ctl() failed: ..."
#
#   macOS: kevent with nevents=0 silently ignores the bad fd; WaitLatchOrSocket
#          returns WL_SOCKET_READABLE from the buffered EOF; PQconsumeInput
#          detects CONNECTION_BAD and fires a second "connection to other side
#          has died" exception.
#
# Both paths are caught by PG_CATCH with use_try_block=true, producing
# LOG "error during exception handling" + PG_RE_THROW (TRANSDISCARD default).
#
# Fix: at stream_replay:, call PQconsumeInput, refresh fd = PQsocket(applyconn),
# and return cleanly if the connection is dead.
#
# We kill the walsender with SIGKILL (not pg_terminate_backend/SIGTERM) so that
# no CopyDone is sent.  libpq reads a raw EOF, calls pqDropConnection to close
# conn->sock, and the first exception is "connection to other side has died" —
# leaving a closed fd for the stream_replay: re-entry to stumble over.
# SIGKILL triggers crash recovery on n1; the postmaster restarts automatically.
#
# SpockTest.pm defaults to sub_disable; we override to transdiscard on n2 so
# the test observes the production behaviour (worker restart, not sub disable).
# =============================================================================

create_cluster(2, 'Create 2-node cluster for stale-fd regression test');

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

# Override exception_behaviour to transdiscard on n2.  ALTER SYSTEM writes
# postgresql.auto.conf which takes precedence over SpockTest.pm's postgresql.conf.
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard'");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(1);

psql_or_bail(1, "CREATE TABLE test_stale_fd (id SERIAL PRIMARY KEY, val TEXT)");
psql_or_bail(2, "CREATE TABLE test_stale_fd (id SERIAL PRIMARY KEY, val TEXT)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 reaches replicating state');

psql_or_bail(1, "INSERT INTO test_stale_fd (val) VALUES ('before_kill')");
sleep(3);

my $before_count = scalar_query(2, "SELECT count(*) FROM test_stale_fd");
is($before_count, '1', 'baseline row replicates n1->n2');

my $log_offset = -s $pg_log_n2 // 0;

# Kill the walsender with SIGKILL so n1 crashes and restarts automatically.
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

# 10 s covers both the stream_replay: re-entry error and n1 crash recovery.
sleep(10);

my $new_log = '';
if (open(my $lf, '<', $pg_log_n2)) {
    seek($lf, $log_offset, 0);
    local $/;
    $new_log = <$lf> // '';
    close($lf);
}

my $initial_exception =
    ($new_log =~ /data stream ended|connection to other side has died/) ? 1 : 0;
ok($initial_exception, 'n2 log shows connection failure after walsender kill');

# Primary cross-platform check: "error during exception handling" fires on both
# Linux and macOS when stream_replay: re-enters with a dead connection.
my $eeh = ($new_log =~ /error during exception handling/) ? 1 : 0;
ok(!$eeh, 'no "error during exception handling" after connection failure (stale-fd bug)');
if ($eeh) {
    diag("BUG CONFIRMED: stream_replay: re-entered with dead connection");
    diag("  use_try_block=true => 'error during exception handling' => PG_RE_THROW");
}

# Linux-specific: with SIGKILL the fd is closed before stream_replay: is
# entered, so epoll_ctl(closed_fd) returns EBADF/EINVAL without the fix.
my $wait_event_error =
    ($new_log =~ /epoll_ctl\(\) failed|kevent failed: Bad file descriptor/) ? 1 : 0;
SKIP: {
    skip 'epoll_ctl error is Linux-specific', 1 unless $^O eq 'linux';
    ok(!$wait_event_error,
        'Linux: no epoll_ctl error after connection failure (stale-fd fix)');
}

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 returns to replicating state after reconnect');

psql_or_bail(1, "INSERT INTO test_stale_fd (val) VALUES ('after_reconnect')");
sleep(5);

my $after_count = scalar_query(2, "SELECT count(*) FROM test_stale_fd");
cmp_ok($after_count, '>=', '2', 'post-reconnect row replicates n1->n2');

system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_drop('sub_n1_n2')");

destroy_cluster('Destroy cluster after stale-fd regression test');

done_testing();
