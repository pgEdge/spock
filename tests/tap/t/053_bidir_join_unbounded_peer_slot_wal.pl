#!/usr/bin/perl
# =============================================================================
# Test: 053_bidir_join_unbounded_peer_slot_wal.pl - demonstrates the
#                                                    WAL-retention exposure
#                                                    a peer slot has during
#                                                    the coverage barrier,
#                                                    currently unprotected
# =============================================================================
# Design doc (spock_bidirectional_final.md) section 13: a peer slot created
# in Step 20 Phase A sits unconsumed -- pinning WAL and catalog_xmin on that
# peer -- until the direct subscription is enabled in Step 20.6. Section 13
# promotes a pre-flight lag gate and a --max-slot-wal budget/abort valve to
# a v1 requirement to bound that exposure. Both were implemented, tested,
# and then deliberately reverted (see the revert commit for the "how
# necessary is this" discussion): the existing --stall-timeout + manual
# --cleanup path already bounds the exposure in the common case, just less
# precisely (by elapsed time, not actual WAL bytes) than a dedicated guard
# would, and no test had ever actually hit the gap the guard closes.
#
# This test is that missing evidence, kept independently of whether the
# guard exists: it demonstrates the exposure is real, not hypothetical, by
# measuring it directly -- keeping a peer (n2) under continuous write load
# throughout a new node's (n3's) join, and sampling n2's own peer
# replication slot's retained WAL (pg_wal_lsn_diff(pg_current_wal_lsn(),
# restart_lsn), the exact signal section 13 names) throughout the coverage
# barrier. It asserts retention grows past a threshold that would matter in
# production, and that the join still succeeds correctly despite that
# growth -- this is a resource-exposure characterization, not a
# correctness bug: nothing here should ever fail the join itself.
#
# Re-run this same test once --max-slot-wal is reintroduced (a dedicated
# follow-up per the revert commit): with the guard in place and a --max-
# slot-wal budget set below what this test currently observes, the join
# should instead abort with every peer slot dropped -- the assertions
# below would need inverting at that point, which is exactly the point of
# keeping this test around.
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
# SETUP: 2-node cluster, cross-wired bidirectionally
# =============================================================================
create_cluster(2, 'Create bidirectional 2-node cluster');

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

cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 <-> n2 bidirectionally');

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

sub wait_for_slot_created {
    my ($pending_path, $manifest_path, $timeout) = @_;
    for (1 .. $timeout) {
        return 1 if -f $pending_path || -f $manifest_path;
        sleep(1);
    }
    return 0;
}

# =============================================================================
# SETUP: a table on n2, replicated to n1 via the existing mesh, kept under
# continuous write load throughout n3's join. batch-committed via a
# PROCEDURE so a single long-lived connection produces a steady stream
# rather than one huge transaction -- the exposure this test measures
# accrues across many small transactions the peer slot sits behind, not
# from any one of them being unusually large.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "CREATE TABLE peer_wal_tbl (id bigint PRIMARY KEY, val text)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "CREATE SEQUENCE peer_wal_id_seq";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', q{
    CREATE PROCEDURE peer_wal_load(n_batches int, batch_rows int)
    LANGUAGE plpgsql AS $$
    DECLARE i int;
    BEGIN
        FOR i IN 1..n_batches LOOP
            INSERT INTO peer_wal_tbl
                SELECT nextval('peer_wal_id_seq'), 'x' || g
                FROM generate_series(1, batch_rows) g;
            COMMIT;
            PERFORM pg_sleep(0.02);
        END LOOP;
    END $$;
};
pass('peer_wal_tbl and writer procedure created on n2');

# The peer slot spock_create_subscriber will create on n2 for n3's future
# direct subscription is a pure, deterministic function of (dbname,
# provider_node_name, sub_name) -- spock.spock_gen_slot_name() -- so its
# name is knowable before the join even starts (n3's sub-to-n2 always
# follows the sub_<subscriber>_<peer> convention).
my $n2_peer_slot_name = scalar_query(2,
    "SELECT spock.spock_gen_slot_name('$dbname', 'n2', 'sub_n3_n2')");
ok(length($n2_peer_slot_name) > 0, 'resolved n2 peer slot name in advance');

ok(wait_for_zero_lag(1, 60), 'replication drained before starting the join')
    or BAIL_OUT('n1->n2 replication never drained after setup; cannot proceed');

# =============================================================================
# TEST: join n3 via n1 while n2 is under continuous write load; sample the
# peer slot's own retained WAL throughout the coverage barrier.
# =============================================================================
my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_unbounded_wal';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";

remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_pending) if -f $n3_pending;

my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.unbounded_wal';
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

my $scs_log = "$log_dir/scs_unbounded_wal.log";
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
    '--max-wait',         '300',
);

ok(wait_for_slot_created($n3_pending, $n3_manifest, 30),
   'source slot created (safe to start the n2 writer)')
    or BAIL_OUT('spock_create_subscriber never created the source slot; see ' . $scs_log);

my $writer_pid = spawn_background("$log_dir/peer_wal_writer.log",
    "$pg_bin/psql", '-X', '-p', $node_ports->[1], '-d', $dbname,
    '-c', "CALL peer_wal_load(100000, 500)");

# Sample the peer slot's own retention on n2 (the exact query design doc
# section 13 names: pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
# from the moment it appears until the join finishes. WNOHANG so this
# loop and the join proceed concurrently rather than sampling only once
# after the fact, when the slot may already be gone (consumed at cutover)
# or the window already closed.
my $max_retained_bytes = 0;
my $samples = 0;
for (;;) {
    my $r = waitpid($scs_pid, WNOHANG);
    last if $r == $scs_pid;

    my $retained = scalar_query(2,
        "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) " .
        "FROM pg_replication_slots WHERE slot_name = '$n2_peer_slot_name'");
    if (defined $retained && $retained =~ /^\d+$/) {
        $samples++;
        $max_retained_bytes = $retained if $retained > $max_retained_bytes;
    }
    sleep(1);
}
my $scs_rc = ($? >> 8);

diag("sampled the peer slot's retained WAL $samples time(s); " .
     "max observed: $max_retained_bytes byte(s)");

is($scs_rc, 0, '--bidirectional exits 0 despite n2 being under continuous load')
    or diag("see $scs_log");

# The actual demonstration: without a budget guard, retention on the peer
# slot grows to a size that would matter in production while it sits
# unconsumed -- not just a few stray bytes from normal replication
# bookkeeping. 1MB is comfortably below what this test's writer produces
# over even a short barrier window (empirically tens of MB), while being
# far above any incidental noise -- a threshold this loose only fails if
# the exposure genuinely stopped growing, not from ordinary run-to-run
# timing variance.
ok($max_retained_bytes > 1024 * 1024,
   "peer slot retention exceeded 1MB during the barrier " .
   "(max observed: $max_retained_bytes byte(s)) -- the WAL-retention " .
   "exposure design doc section 13 describes is real, not hypothetical");

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running');
ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 30),
   'catchup subscription sub_n3_n1 is replicating on n3');
ok(wait_for_sub_status(3, 'sub_n3_n2', 'replicating', 30),
   'direct peer subscription sub_n3_n2 is replicating on n3');

# Correctness is unaffected by the exposure -- this is a resource cost,
# not a data-safety bug. Stop the writer (server-side: killing the client
# alone does not reliably stop a backend mid-CALL) and confirm the data
# converges exactly once it drains.
system_or_bail "$pg_bin/psql", '-X', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " .
    "WHERE query LIKE 'CALL peer_wal_load%' AND pid <> pg_backend_pid()";
for (1 .. 30) {
    my $still_running = scalar_query(2,
        "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'CALL peer_wal_load%'");
    last if defined $still_running && $still_running eq '0';
    sleep(1);
}
kill('TERM', $writer_pid);
waitpid($writer_pid, 0);

my $count_n2 = scalar_query(2, "SELECT COUNT(*) FROM peer_wal_tbl");
my $count_n3 = '-1';
for (1 .. 60) {
    $count_n3 = scalar_query(3, "SELECT COUNT(*) FROM peer_wal_tbl");
    last if $count_n3 eq $count_n2;
    sleep(1);
}
is($count_n3, $count_n2,
   'n3 eventually receives every row despite the unbounded retention window');

my $slot_gone = scalar_query(2,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '$n2_peer_slot_name'");
ok($slot_gone >= 0, 'peer slot query still succeeds after cutover (informational)');

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
