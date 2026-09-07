#!/usr/bin/perl
# =============================================================================
# Test: 052_bidir_join_big_txn_liveness.pl - the catchup stall watchdog must
#                                             not fire on a healthy, merely
#                                             slow-to-apply transaction
# =============================================================================
# Design doc (spock_bidirectional_final.md) section 11: the Spock output
# plugin registers no streaming (in-progress-transaction) callbacks, so a
# large transaction is decoded and sent, and its origin advanced, only at
# its COMMIT. Every LSN signal wait_for_catchup()/wait_for_origin_progress()
# watches therefore freezes for as long as that one transaction is still
# being applied -- even though the apply worker is healthy and busy, not
# stalled. Before this fix, --stall-timeout was a pure LSN-progress
# watchdog and would die() on exactly this pattern; section 16 calls out a
# "big-transaction liveness" regression test for it explicitly, and it did
# not exist.
#
# This reproduces it directly: a REPLICA-only trigger with pg_sleep() on a
# table, present on n1 before the physical backup (so n3 inherits it too),
# fires only when a row is *applied* via replication -- not when n1's own
# origin transaction inserts it -- so a single, fast-committing transaction
# on n1 takes many seconds to fully apply on n3, freezing n3's catchup
# origin for that whole window. --stall-timeout is set far shorter than
# that window: without the liveness check, catchup dies well before the
# transaction finishes applying; with it, the apply worker's own
# pg_stat_activity state proves it is still busy, and the wait continues
# through to a correct, complete result.
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
# SETUP: a table with a REPLICA-only slow trigger, present on n1 before the
# physical backup so n3 inherits it too. ENABLE REPLICA TRIGGER means it
# fires only on rows applied via replication, not on n1's own origin
# inserts -- so inserting into this table on n1 is fast, but n3 takes a
# long time to apply each row.
# =============================================================================
my $rows = 200;
my $sleep_per_row = 0.15;
my $expected_min_seconds = int($rows * $sleep_per_row * 0.8);   # generous margin

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE slow_apply_tbl (id serial primary key, val text)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', qq{
    CREATE FUNCTION slow_apply_trigger() RETURNS trigger LANGUAGE plpgsql AS \$\$
    BEGIN
        PERFORM pg_sleep($sleep_per_row);
        RETURN NEW;
    END \$\$;
    CREATE TRIGGER slow_apply_trg BEFORE INSERT ON slow_apply_tbl
        FOR EACH ROW EXECUTE FUNCTION slow_apply_trigger();
    ALTER TABLE slow_apply_tbl ENABLE REPLICA TRIGGER slow_apply_trg;
};
pass("slow_apply_tbl with a replica-only ${sleep_per_row}s-per-row trigger created on n1");

ok(wait_for_zero_lag(1, 60), 'replication drained before starting the join')
    or BAIL_OUT('n1->n2 replication never drained after setup; cannot proceed');

# =============================================================================
# TEST: join with a --stall-timeout far shorter than the time this one
# transaction will take to apply on n3
# =============================================================================
my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_liveness';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";
my $stall_timeout = 5;

remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_pending) if -f $n3_pending;

my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.liveness';
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

my $scs_log = "$log_dir/scs_liveness.log";
unlink($scs_log) if -f $scs_log;

my $scs_pid = spawn_background($scs_log,
    $SCS_BIN,
    '--bidirectional',
    '--pgdata',           $n3_datadir,
    '--subscriber-name',  'n3',
    '--provider-dsn',     $n1_dsn,
    '--subscriber-dsn',   $n3_dsn,
    '--postgresql-conf',  $n3_conf,
    '--stall-timeout',    "$stall_timeout",
    '--max-wait',         '300',
);

ok(wait_for_slot_created($n3_pending, $n3_manifest, 30),
   'source slot created (safe to insert the slow transaction)')
    or BAIL_OUT('spock_create_subscriber never created the source slot; see ' . $scs_log);

# Fast on n1 (the replica-only trigger does not fire for n1's own origin
# insert): a single transaction, all $rows rows, so its origin only
# advances on n3 once every row has been applied there.
my $insert_start = time();
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "INSERT INTO slow_apply_tbl (val) SELECT 'row ' || g FROM generate_series(1, $rows) g";
my $insert_elapsed = time() - $insert_start;
ok($insert_elapsed < $expected_min_seconds,
   "the insert on n1 itself was fast (${insert_elapsed}s) -- the replica " .
   "trigger did not fire for n1's own origin transaction");

my $join_start = time();
my $scs_rc = wait_for_pid($scs_pid, 300);
unless (defined $scs_rc) {
    diag("spock_create_subscriber did not exit within 300s; killing it");
    kill('TERM', $scs_pid);
    waitpid($scs_pid, 0);
    $scs_rc = -1;
}
my $join_elapsed = time() - $join_start;
is($scs_rc, 0,
   "--bidirectional exits 0 despite a single transaction frozen on n3 for " .
   "longer than --stall-timeout=${stall_timeout}s")
    or diag("see $scs_log");

ok($join_elapsed >= $expected_min_seconds,
   "the join took at least ${expected_min_seconds}s (${join_elapsed}s elapsed), " .
   "confirming the slow-apply transaction was genuinely still in flight " .
   "when the join reached it, not skipped or already caught up");

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running');
ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 30),
   'catchup subscription sub_n3_n1 is replicating on n3');

my $n1_count = scalar_query(1, "SELECT COUNT(*) FROM slow_apply_tbl");
is($n1_count, "$rows", 'all rows present on n1');
my $n3_count = '-1';
for (1 .. 30) {
    $n3_count = scalar_query(3, "SELECT COUNT(*) FROM slow_apply_tbl");
    last if $n3_count eq $n1_count;
    sleep(1);
}
is($n3_count, $n1_count,
   'every row of the slow transaction was applied on n3, none skipped or discarded');

is(scalar_query(3, "SELECT COUNT(*) FROM spock.exception_log"),
   '0', 'no exceptions were logged (the wait genuinely continued, not replayed/discarded)');

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
