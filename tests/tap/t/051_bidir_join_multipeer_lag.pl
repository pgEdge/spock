#!/usr/bin/perl
# =============================================================================
# Test: 051_bidir_join_multipeer_lag.pl - spock_create_subscriber
#                                          --bidirectional's coverage barrier
#                                          genuinely waits for EVERY existing
#                                          peer, not just the fastest one
# =============================================================================
# establish_peer_coverage_barrier() (spock_create_subscriber.c) has two
# steps: Hop 1, per peer P, waits for a sync_event emitted on P to land on
# the source (n1); Hop 2, once, fires only after every peer's Hop 1 has
# landed, and cuts the new node over to direct replication. Both
# 048_bidir_join.pl and 049_bidir_join_under_load.pl only ever join a new
# node into a 2-node mesh (n1 + one peer, n2) -- with exactly one peer, the
# "wait for EVERY peer" condition in Hop 2 is vacuously true on every run. A
# bug that fired Hop 2 as soon as *any* single peer's Hop 1 landed, instead
# of *all* of them, would not be caught by either test.
#
# This test builds a genuine 3-node pre-existing mesh (n1, n2, n3, fully
# cross-wired) and keeps n3 under sustained write load throughout the join
# of a 4th node (n4, via n1 as source) -- so n1's replay of n3's changes is
# backlogged right at the moment the coverage barrier runs, while n2 (idle)
# clears its Hop 1 almost immediately. If Hop 2 fired as soon as n2's Hop 1
# landed, n4 would be cut over to direct replication from n1/n2/n3 before
# n3's backlog had fully passed through n1's forwarding path -- a real,
# permanent gap: n4 would end up missing some of n3's rows relative to n3
# itself, even though n4 matches n1 and n2 exactly. Comparing n4 to n3
# specifically (not just to n1/n2, which 048/049 already do) is therefore
# the correctness assertion that actually exercises this: it fails if the
# barrier raced ahead, and passes only if it genuinely waited for n3.
# =============================================================================

use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);
use POSIX qw(:sys_wait_h);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 command_ok system_maybe get_test_config scalar_query
                 psql_or_bail wait_for_pg_ready wait_for_sub_status);

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
# SETUP: 3-node cluster, fully cross-wired (n1 <-> n2 <-> n3 <-> n1)
# =============================================================================
create_cluster(3, 'Create 3-node cluster');

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

cross_wire(3, ['n1', 'n2', 'n3'], 'Cross-wire n1 <-> n2 <-> n3');

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

# Poll a log file's content for a pattern (rather than a fixed offset read)
# since the file may not exist yet when polling starts.
sub wait_for_log_pattern {
    my ($logfile, $pattern, $timeout) = @_;
    for (1 .. $timeout) {
        if (-f $logfile) {
            open(my $fh, '<', $logfile) or die "Cannot open $logfile: $!";
            local $/;
            my $content = <$fh>;
            close($fh);
            return time() if defined $content && $content =~ $pattern;
        }
        sleep(1);
    }
    return undef;
}

# =============================================================================
# SETUP: a table replicated across the existing 3-node mesh via DDL
# replication, to be under sustained write load on n3 throughout n4's join.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE lag_peer_tbl (id bigint PRIMARY KEY, val text)";
pass('lag_peer_tbl created on n1');

for my $peer_node (2, 3) {
    my $on_peer = '0';
    for (1 .. 30) {
        $on_peer = scalar_query($peer_node,
            "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'lag_peer_tbl'");
        last if $on_peer eq '1';
        sleep(1);
    }
    is($on_peer, '1', "lag_peer_tbl replicated to n$peer_node");
}

system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c',
    "CREATE SEQUENCE lag_peer_id_seq";

# A PROCEDURE (not a DO block) can issue its own internal COMMITs, so a
# single long-lived connection on n3 produces a continuous stream of
# separately committed transactions for as long as this test needs a
# backlog to exist -- same technique as 046_apply_worker_exception_
# misclassification.pl's mid-transaction-restart repro.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', q{
    CREATE PROCEDURE lag_peer_load(n_batches int, batch_rows int)
    LANGUAGE plpgsql AS $$
    DECLARE i int;
    BEGIN
        FOR i IN 1..n_batches LOOP
            INSERT INTO lag_peer_tbl
                SELECT nextval('lag_peer_id_seq'), 'x' || g
                FROM generate_series(1, batch_rows) g;
            COMMIT;
            -- Throttled deliberately: n3 is in a full mesh, so n2 also
            -- applies every one of these rows via its own subscription,
            -- inflating n2's own WAL and hence n1's (idle-peer) lag to
            -- n2 as a side effect. An unthrottled writer here overwhelms
            -- the whole cluster, not just n3 (confirmed empirically: without
            -- this sleep, the pre-flight lag gate below tripped on n2, not
            -- the intended target n3).
            PERFORM pg_sleep(0.02);
        END LOOP;
    END $$;
};

ok(wait_for_zero_lag(1, 60), 'replication drained before starting the join')
    or BAIL_OUT('n1 outbound replication never drained after setup; cannot proceed');

# Started only after --bidirectional's own check_preconditions() has
# already passed (see wait_for_slot_created() below) -- it hard-rejects up
# front if the *source* (n1) has any unreplicated changes pending to an
# existing peer. This writer targets n3, not n1, so it may not actually
# trip that specific check, but 050_bidir_join_crash_midcatchup.pl hit
# exactly this failure mode empirically for a same-node case, and starting
# late here costs nothing (n1's replication is already drained above) --
# not worth relitigating precisely which lag check_preconditions() looks
# at. Kept running through the rest of the join; stopped server-side
# afterward (pg_terminate_backend), same as 050 and 046 -- killing the
# client process alone does not reliably stop a backend mid-CALL.
my $writer_pid;

sub start_writer {
    $writer_pid = spawn_background("$log_dir/lag_peer_writer.log",
        "$pg_bin/psql", '-X', '-p', $node_ports->[2], '-d', $dbname,
        '-c', "CALL lag_peer_load(100000, 500)");
}

# =============================================================================
# TEST: join n4 via n1 while n3 is lagging behind on its own writes
# =============================================================================
my $n4_port     = $node_ports->[2] + 1;
my $n4_datadir  = '/tmp/tmp_spock_node_3_datadir_bidir_multipeer';
my $n4_pending  = "${n4_datadir}.spock_bidir_pending.json";
my $n4_manifest = "$n4_datadir/spock_bidirectional_manifest.json";
my $n4_dsn      = "host=$host port=$n4_port dbname=$dbname"
                . " user=$db_user password=$db_password";

remove_tree($n4_datadir) if -d $n4_datadir;
unlink($n4_pending) if -f $n4_pending;

sub wait_for_slot_created {
    my ($timeout) = @_;
    for (1 .. $timeout) {
        return 1 if -f $n4_pending || -f $n4_manifest;
        sleep(1);
    }
    return 0;
}

my $n4_conf = '/tmp/tmp_spock_node_3_postgresql.conf.override.multipeer';
open my $conf_fh, '>', $n4_conf or die "Cannot write $n4_conf: $!";
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
print $conf_fh "port=$n4_port\n";
print $conf_fh "listen_addresses='*'\n";
print $conf_fh "logging_collector=on\n";
print $conf_fh "log_directory='$log_dir'\n";
print $conf_fh "log_filename='00${n4_port}.log'\n";
close $conf_fh;

my $scs_log = "$log_dir/scs_multipeer.log";
unlink($scs_log) if -f $scs_log;

my $scs_pid = spawn_background($scs_log,
    $SCS_BIN,
    '--bidirectional',
    '--pgdata',           $n4_datadir,
    '--subscriber-name',  'n4',
    '--provider-dsn',     $n1_dsn,
    '--subscriber-dsn',   $n4_dsn,
    '--postgresql-conf',  $n4_conf,
    '--stall-timeout',    '120',
    '--max-wait',         '600',
);

ok(wait_for_slot_created(30), 'source slot created (safe to start the n3 writer)')
    or BAIL_OUT('spock_create_subscriber never created the source slot; see ' . $scs_log);
start_writer();

my $barrier_start = wait_for_log_pattern($scs_log,
    qr/Establishing peer coverage barrier/, 60);
ok(defined $barrier_start, 'coverage barrier phase started')
    or diag("see $scs_log");

my $scs_rc = wait_for_pid($scs_pid, 780);
unless (defined $scs_rc) {
    diag("spock_create_subscriber (multipeer) did not exit within 780s; killing it");
    kill('TERM', $scs_pid);
    waitpid($scs_pid, 0);
    $scs_rc = -1;
}
is($scs_rc, 0, '--bidirectional (3-peer mesh, one peer lagging) exits 0')
    or diag("see $scs_log and $log_dir/lag_peer_writer.log");

# Sanity check on test validity, not correctness: if this comes back near 0,
# the load was not actually creating backlog at the moment the barrier ran,
# and the test below would not be exercising the "wait for a lagging peer"
# path at all. Loose threshold (this is a coarse, 1s-polling-resolution
# measurement, not a precise timing assertion) -- the real correctness
# proof is the n3-vs-n4 data comparison further down, which fails
# regardless of how long the barrier actually took if it raced ahead.
my $barrier_end = wait_for_log_pattern($scs_log,
    qr/Clearing forwarding on the catchup subscription/, 5);
if (defined $barrier_start && defined $barrier_end) {
    my $barrier_seconds = $barrier_end - $barrier_start;
    diag("coverage barrier phase took approximately ${barrier_seconds}s");
    ok($barrier_seconds >= 2,
        "coverage barrier took a non-trivial amount of time (${barrier_seconds}s), " .
        "consistent with genuinely waiting on n3's backlog");
} else {
    fail('could not measure coverage barrier duration from ' . $scs_log);
}

ok(wait_for_pg_ready($host, $n4_port, $pg_bin, 30), 'n4 postgres is running');
ok(wait_for_sub_status(4, 'sub_n4_n1', 'replicating', 30),
   'catchup subscription sub_n4_n1 is replicating on n4');
ok(wait_for_sub_status(4, 'sub_n4_n2', 'replicating', 30),
   'direct peer subscription sub_n4_n2 is replicating on n4');
ok(wait_for_sub_status(4, 'sub_n4_n3', 'replicating', 30),
   'direct peer subscription sub_n4_n3 is replicating on n4');
ok(wait_for_sub_status(3, 'sub_n3_n4', 'replicating', 30),
   'reverse subscription sub_n3_n4 is replicating on n3');

# =============================================================================
# Stop the writer (server-side) and let everything drain before comparing.
# =============================================================================
system_or_bail "$pg_bin/psql", '-X', '-p', $node_ports->[2], '-d', $dbname, '-c',
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " .
    "WHERE query LIKE 'CALL lag_peer_load%' AND pid <> pg_backend_pid()";
for (1 .. 30) {
    my $still_running = scalar_query(3,
        "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'CALL lag_peer_load%'");
    last if defined $still_running && $still_running eq '0';
    sleep(1);
}
kill('TERM', $writer_pid);
waitpid($writer_pid, 0);
pass('n3 writer stopped');

diag('lag_peer_tbl did not fully drain to n1 within 180s')
    unless wait_for_table_drain(3, 1, 'lag_peer_tbl');
diag('lag_peer_tbl did not fully drain to n4 within 180s')
    unless wait_for_table_drain(3, 4, 'lag_peer_tbl');
diag('lag_peer_tbl did not fully drain to n2 within 180s')
    unless wait_for_table_drain(3, 2, 'lag_peer_tbl');

# =============================================================================
# THE assertion: n4 must match n3 exactly, not just n1/n2 -- this is the
# pair that only fails if the coverage barrier raced ahead of n3's backlog.
# =============================================================================
my $hash_query = "SELECT md5(COALESCE(string_agg(x::text, ',' ORDER BY id), '')) " .
    "FROM lag_peer_tbl x";
my $count_n3 = scalar_query(3, "SELECT COUNT(*) FROM lag_peer_tbl");
my $count_n4 = scalar_query(4, "SELECT COUNT(*) FROM lag_peer_tbl");
is($count_n4, $count_n3, 'row count matches between n3 (lagging peer) and n4');
my $hash_n3 = scalar_query(3, $hash_query);
my $hash_n4 = scalar_query(4, $hash_query);
is($hash_n4, $hash_n3, 'content hash matches between n3 (lagging peer) and n4');

my $count_n1 = scalar_query(1, "SELECT COUNT(*) FROM lag_peer_tbl");
is($count_n4, $count_n1, 'row count matches between n1 and n4');
my $hash_n1 = scalar_query(1, $hash_query);
is($hash_n4, $hash_n1, 'content hash matches between n1 and n4');

my $count_n2 = scalar_query(2, "SELECT COUNT(*) FROM lag_peer_tbl");
is($count_n4, $count_n2, 'row count matches between n2 and n4');
my $hash_n2 = scalar_query(2, $hash_query);
is($hash_n4, $hash_n2, 'content hash matches between n2 and n4');

# =============================================================================
# Prove the n3 <-> n4 pair is a genuinely live DIRECT subscription, not just
# correct inherited catchup data -- a fresh two-way write test.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $n4_port, '-d', $dbname, '-c',
    "INSERT INTO lag_peer_tbl (id, val) VALUES (900000001, 'from_n4_direct')";
my $on_n3_direct = '0';
for (1 .. 30) {
    $on_n3_direct = scalar_query(3,
        "SELECT COUNT(*) FROM lag_peer_tbl WHERE val = 'from_n4_direct'");
    last if $on_n3_direct eq '1';
    sleep(1);
}
is($on_n3_direct, '1', 'fresh write on n4 reaches n3 via the direct subscription');

system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c',
    "INSERT INTO lag_peer_tbl (id, val) VALUES (900000002, 'from_n3_direct')";
my $on_n4_direct = '0';
for (1 .. 30) {
    $on_n4_direct = scalar_query(4,
        "SELECT COUNT(*) FROM lag_peer_tbl WHERE val = 'from_n3_direct'");
    last if $on_n4_direct eq '1';
    sleep(1);
}
is($on_n4_direct, '1', 'fresh write on n3 reaches n4 via the direct subscription');

command_ok(
    [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n4_datadir ],
    '--cleanup --force exits 0'
);
ok(!-d $n4_datadir, 'n4 data directory removed after cleanup');

# =============================================================================
# CLEANUP
# =============================================================================
unlink($n4_conf) if -f $n4_conf;
destroy_cluster('Destroy 3-node cluster');

done_testing();
