#!/usr/bin/perl
# =============================================================================
# Test: 056_bidir_join_concurrent_load.pl - spock_create_subscriber
#                                            --bidirectional under simultaneous
#                                            write load on the SOURCE and a
#                                            non-source PEER at once
# =============================================================================
# Design doc (spock_bidirectional_final.md) section 16 lists, as a required
# positive-path scenario: "Concurrent writes on source AND a non-source peer
# throughout catchup; assert row-level convergence on all nodes (no missing
# rows, no duplicates)." Two existing tests each cover half of this:
# 049_bidir_join_under_load.pl loads only the source (n1); 051_bidir_join_
# multipeer_lag.pl loads only a peer (n3, in a 3-node mesh). Neither loads
# both at once, which is what the design scenario actually calls for -- a
# bug specific to two independent write streams converging through the
# forwarding path simultaneously (e.g. an interleaving that the barrier or
# forwarded-origin resolution handles correctly when only one side is active)
# would not be caught by either.
#
# This test keeps the topology as simple as the scenario allows: a 2-node
# pre-existing mesh (n1, n2), joining n3 via n1 as the source -- n1 is "the
# source", n2 is "a non-source peer", matching the design wording exactly
# with no extra nodes needed. Uses the same dependency-free write-load
# mechanism as 051 (a PROCEDURE issuing its own COMMITs per batch, driven by
# a backgrounded psql -c "CALL ...", throttled with pg_sleep) rather than
# 049's pgedge-loadgen dependency -- keeping this test self-contained and
# suitable for the per-push schedule, not gated behind external tooling.
#
# Each writer inserts into disjoint id ranges (n1: 1..999999, n2: 50000000+)
# so a real bug that produced a genuine duplicate row (not just a benign
# conflict-resolution replay) is distinguishable from two writers legitimately
# both succeeding: convergence is checked via an EXACT row-count match (not
# ">="), a COUNT(DISTINCT id) = COUNT(*) uniqueness check, and a full content
# hash, on every node, against both writers' rows at once.
# =============================================================================

use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);
use POSIX qw(:sys_wait_h);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 command_ok get_test_config scalar_query
                 wait_for_pg_ready wait_for_sub_status);

# =============================================================================
# Locate spock_create_subscriber binary
# =============================================================================
my $SCS_BIN;
for my $dir (split(':', $ENV{PATH} // '')) {
    my $c = "$dir/spock_create_subscriber";
    if (-x $c) { $SCS_BIN = $c; last; }
}
unless (defined $SCS_BIN) {
    my $bt = '../../utils/spock_create_subscriber/spock_create_subscriber';
    $SCS_BIN = $bt if -x $bt;
}
BAIL_OUT("spock_create_subscriber binary not found; run 'make install' first")
    unless defined $SCS_BIN;
pass("spock_create_subscriber binary found");

# =============================================================================
# SETUP: 2-node cluster, cross-wired bidirectionally (n1 <-> n2)
# =============================================================================
create_cluster(2, 'Create 2-node cluster');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $dbname      = $config->{db_name};
my $host        = $config->{host};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};
my $log_dir     = $config->{log_dir};

my $n1_dsn = "host=$host port=$node_ports->[0] dbname=$dbname"
           . " user=$db_user password=$db_password";

cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 <-> n2');

sub psql_capture {
    my (@args) = @_;
    open(my $fh, '-|', "$pg_bin/psql", @args) or die "cannot run psql: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    $out //= '';
    $out =~ s/^\s+|\s+$//g;
    return $out;
}

sub spawn_background {
    my ($logfile, @cmd) = @_;
    my $pid = fork();
    die "fork() failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(my $fh, '>>', $logfile) or die "Cannot open $logfile: $!";
        open(STDOUT, '>&', $fh) or die $!;
        open(STDERR, '>&', $fh) or die $!;
        close($fh);
        exec(@cmd) or exit(127);
    }
    return $pid;
}

sub wait_for_pid {
    my ($pid, $timeout) = @_;
    for (1 .. $timeout) {
        my $r = waitpid($pid, WNOHANG);
        return ($? >> 8) if $r == $pid;
        sleep(1);
    }
    return undef;
}

sub wait_for_zero_lag {
    my ($node_num, $timeout) = @_;
    for (1 .. $timeout) {
        my $lag = scalar_query($node_num,
            "SELECT COUNT(*) FROM pg_replication_slots" .
            " WHERE slot_type = 'logical' AND plugin = 'spock_output'" .
            " AND (confirmed_flush_lsn IS NULL OR confirmed_flush_lsn < pg_current_wal_lsn())");
        return 1 if defined $lag && $lag eq '0';
        sleep(1);
    }
    return 0;
}

sub wait_for_table_drain {
    my ($node_a, $node_b, $table, $timeout) = @_;
    $timeout //= 180;
    my $count_a = scalar_query($node_a, "SELECT COUNT(*) FROM $table");
    for (1 .. $timeout) {
        my $count_b = scalar_query($node_b, "SELECT COUNT(*) FROM $table");
        return 1 if defined $count_b && $count_b eq $count_a;
        sleep(1);
    }
    return 0;
}

# =============================================================================
# SETUP: a table + PROCEDURE replicated across n1/n2 via DDL replication,
# used by both concurrent writers below. Disjoint id ranges per writer (a
# large offset for n2) rather than a shared sequence -- two independent
# writers sharing one sequence would themselves need to replicate sequence
# state through the very path being tested, entangling the setup with the
# thing under test.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE concurrent_load_tbl (id bigint PRIMARY KEY, val text, src text)";
pass('concurrent_load_tbl created on n1');

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', q{
    CREATE PROCEDURE concurrent_load(id_base bigint, n_batches int,
                                      batch_rows int, node_label text)
    LANGUAGE plpgsql AS $$
    DECLARE i int;
    BEGIN
        FOR i IN 1..n_batches LOOP
            INSERT INTO concurrent_load_tbl (id, val, src)
                SELECT id_base + (i - 1) * batch_rows + g, 'x' || g, node_label
                FROM generate_series(1, batch_rows) g;
            COMMIT;
            -- Throttled for the same reason as 051_bidir_join_multipeer_
            -- lag.pl's writer: both n1 and n2 apply each other's rows via
            -- their pre-existing cross-wired subscription, so an unthrottled
            -- writer on either side inflates both nodes' outbound WAL, not
            -- just its own.
            PERFORM pg_sleep(0.02);
        END LOOP;
    END $$;
};
pass('concurrent_load procedure created on n1');

my $table_on_n2 = '0';
for (1 .. 30) {
    $table_on_n2 = scalar_query(2,
        "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'concurrent_load_tbl'");
    last if $table_on_n2 eq '1';
    sleep(1);
}
is($table_on_n2, '1', 'concurrent_load_tbl replicated to n2');

my $proc_on_n2 = '0';
for (1 .. 30) {
    $proc_on_n2 = scalar_query(2,
        "SELECT COUNT(*) FROM pg_proc WHERE proname = 'concurrent_load'");
    last if $proc_on_n2 eq '1';
    sleep(1);
}
is($proc_on_n2, '1', 'concurrent_load procedure replicated to n2');

ok(wait_for_zero_lag(1, 60), 'replication drained before starting the join')
    or BAIL_OUT('n1 outbound replication never drained after setup; cannot proceed');

# =============================================================================
# TEST: join n3 via n1 while BOTH n1 (the source) and n2 (a non-source peer)
# are under concurrent, independent write load throughout catchup and the
# coverage barrier.
# =============================================================================
my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_concurrent';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";

remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_pending) if -f $n3_pending;

sub wait_for_slot_created {
    my ($timeout) = @_;
    for (1 .. $timeout) {
        return 1 if -f $n3_pending || -f $n3_manifest;
        sleep(1);
    }
    return 0;
}

my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.concurrent';
open my $conf_fh, '>', $n3_conf or die "Cannot write $n3_conf: $!";
print $conf_fh "shared_buffers=1GB\n";
print $conf_fh "shared_preload_libraries='spock'\n";
print $conf_fh "wal_level=logical\n";
print $conf_fh "spock.enable_ddl_replication=on\n";
print $conf_fh "spock.include_ddl_repset=on\n";
print $conf_fh "spock.allow_ddl_from_functions=on\n";
print $conf_fh "spock.exception_behaviour=sub_disable\n";
print $conf_fh "spock.conflict_resolution=last_update_wins\n";
print $conf_fh "track_commit_timestamp=on\n";
print $conf_fh "spock.exception_replay_queue_size='1MB'\n";
print $conf_fh "spock.enable_spill=on\n";
print $conf_fh "port=$n3_port\n";
print $conf_fh "listen_addresses='*'\n";
print $conf_fh "logging_collector=on\n";
print $conf_fh "log_directory='$log_dir'\n";
print $conf_fh "log_filename='00${n3_port}.log'\n";
close $conf_fh;

my $scs_log = "$log_dir/scs_concurrent.log";
unlink($scs_log) if -f $scs_log;

my $scs_pid = spawn_background($scs_log,
    $SCS_BIN,
    '--bidirectional',
    '--pgdata',           $n3_datadir,
    '--subscriber-name',  'n3',
    '--provider-dsn',     $n1_dsn,
    '--subscriber-dsn',   $n3_dsn,
    '--postgresql-conf',  $n3_conf,
    '--stall-timeout',    '120',
    '--max-wait',         '600',
);

ok(wait_for_slot_created(30),
   'source slot created (safe to start both writers)')
    or BAIL_OUT('spock_create_subscriber never created the source slot; see ' . $scs_log);

# Two independent writers, started together: one against the source (n1),
# one against a non-source peer (n2), both left running through catchup and
# the coverage barrier.
my $n1_writer_pid = spawn_background("$log_dir/concurrent_load_n1.log",
    "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname,
    '-c', "CALL concurrent_load(1, 400, 50, 'n1')");
my $n2_writer_pid = spawn_background("$log_dir/concurrent_load_n2.log",
    "$pg_bin/psql", '-X', '-p', $node_ports->[1], '-d', $dbname,
    '-c', "CALL concurrent_load(50000000, 400, 50, 'n2')");
pass('concurrent writers started on n1 (source) and n2 (peer)');

my $scs_rc = wait_for_pid($scs_pid, 780);
unless (defined $scs_rc) {
    diag("spock_create_subscriber did not exit within 780s; killing it");
    kill('TERM', $scs_pid);
    waitpid($scs_pid, 0);
    $scs_rc = -1;
}
is($scs_rc, 0,
   '--bidirectional exits 0 with concurrent source+peer write load throughout')
    or diag("see $scs_log");

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running');
ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 30),
   'catchup subscription sub_n3_n1 is replicating on n3');
ok(wait_for_sub_status(3, 'sub_n3_n2', 'replicating', 30),
   'direct peer subscription sub_n3_n2 is replicating on n3');
ok(wait_for_sub_status(2, 'sub_n2_n3', 'replicating', 30),
   'reverse subscription sub_n2_n3 is replicating on n2');
ok(wait_for_sub_status(1, 'sub_n1_n3', 'replicating', 30),
   'reverse subscription sub_n1_n3 is replicating on n1');

my $readonly = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
    '-c', "SHOW spock.readonly");
is($readonly, 'off', 'spock.readonly is lifted on n3');

# =============================================================================
# Let both writers finish naturally (each does a fixed, bounded number of
# batches), then let replication fully drain everywhere before comparing.
# =============================================================================
sub stop_writer {
    my ($pid, $timeout) = @_;
    return unless defined $pid;
    my $rc = wait_for_pid($pid, $timeout);
    unless (defined $rc) {
        diag("writer pid $pid did not finish within ${timeout}s; killing it");
        kill('TERM', $pid);
        waitpid($pid, 0);
    }
}
stop_writer($n1_writer_pid, 120);
stop_writer($n2_writer_pid, 120);
pass('both writers finished');

diag('concurrent_load_tbl did not fully drain to n3 within 180s')
    unless wait_for_table_drain(1, 3, 'concurrent_load_tbl');
diag('concurrent_load_tbl did not fully drain to n2 within 180s')
    unless wait_for_table_drain(1, 2, 'concurrent_load_tbl');

# =============================================================================
# THE assertions: every node must agree exactly -- no missing rows (either
# writer's), no duplicates -- on the combined output of both simultaneous
# writers.
# =============================================================================
my $expected_total = 400 * 50 * 2;    # n_batches * batch_rows, both writers
my $hash_query = "SELECT md5(COALESCE(string_agg(x::text, ',' ORDER BY id), '')) " .
    "FROM concurrent_load_tbl x";

for my $pair ([1, 'n1'], [2, 'n2'], [3, 'n3']) {
    my ($node_num, $label) = @$pair;
    my $count = scalar_query($node_num, "SELECT COUNT(*) FROM concurrent_load_tbl");
    is($count, $expected_total,
       "$label has exactly the expected row count from both writers (no missing rows)");
    my $distinct_count = scalar_query($node_num,
        "SELECT COUNT(DISTINCT id) FROM concurrent_load_tbl");
    is($distinct_count, $expected_total,
       "$label has no duplicate ids (COUNT(DISTINCT id) matches COUNT(*))");
}

my $hash_n1 = scalar_query(1, $hash_query);
my $hash_n2 = scalar_query(2, $hash_query);
my $hash_n3 = scalar_query(3, $hash_query);
is($hash_n2, $hash_n1, 'content hash matches between n1 and n2');
is($hash_n3, $hash_n1, 'content hash matches between n1 (source) and n3 (joined)');
is($hash_n3, $hash_n2, 'content hash matches between n2 (peer) and n3 (joined)');

my $src_n1_on_n3 = scalar_query(3,
    "SELECT COUNT(*) FROM concurrent_load_tbl WHERE src = 'n1'");
is($src_n1_on_n3, 400 * 50, "n3 has all of the source's (n1) rows");
my $src_n2_on_n3 = scalar_query(3,
    "SELECT COUNT(*) FROM concurrent_load_tbl WHERE src = 'n2'");
is($src_n2_on_n3, 400 * 50, "n3 has all of the peer's (n2) rows");

# =============================================================================
# Fresh bidirectional dataflow, proving the mesh is genuinely live after
# both simultaneous write streams and the join itself have settled.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c',
    "INSERT INTO concurrent_load_tbl (id, val, src) " .
    "VALUES (999999999, 'post_join', 'n3')";
my $marker_on_n1 = '0';
for (1 .. 30) {
    $marker_on_n1 = scalar_query(1,
        "SELECT COUNT(*) FROM concurrent_load_tbl WHERE val = 'post_join'");
    last if $marker_on_n1 eq '1';
    sleep(1);
}
is($marker_on_n1, '1', 'fresh write on n3 reaches n1 after the join');

command_ok(
    [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir ],
    '--cleanup --force exits 0'
);
ok(!-d $n3_datadir, 'n3 data directory removed after cleanup');

# =============================================================================
# CLEANUP
# =============================================================================
unlink($n3_conf) if -f $n3_conf;
destroy_cluster('Destroy 2-node cluster');

done_testing();
