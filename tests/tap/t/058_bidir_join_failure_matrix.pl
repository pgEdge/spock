#!/usr/bin/perl
# =============================================================================
# Test: 058_bidir_join_failure_matrix.pl - spock_create_subscriber
#                                           --bidirectional: --cleanup
#                                           recovers from a failure at each
#                                           Phase 3 cutover step
# =============================================================================
# SPOC-607 hardening review flagged a gap: 048_bidir_join.pl and
# 050_bidir_join_crash_midcatchup.pl both prove --cleanup --force recovers a
# join that failed during the *base backup* phase or mid-*catchup*, but
# nothing exercises a failure landing after catchup completes -- inside the
# Phase 3 cutover sequence itself (coverage barrier, forwarding teardown,
# peer subscription enable, reverse subscription creation, the post-reverse
# readiness wait, and the final dataflow verification). The design doc's own
# testing-strategy section calls this out explicitly ("kill n3 between Step
# 20 and Step 21").
#
# There is no reliable external timing signal for these steps -- unlike
# catchup, which can run arbitrarily long under write load, each of these
# steps normally completes in well under a second against an idle peer, so a
# SIGKILL race from the test side would be too flaky to trust. Instead this
# test uses a small test-only hook in spock_create_subscriber itself:
# SPOCK_CREATE_SUBSCRIBER_TEST_FAIL_AFTER=<step> makes the utility die()
# immediately after that named step completes, going through the exact same
# failure path (process exits non-zero, whatever manifest state was
# persisted up to that point stays on disk) a genuine crash there would.
#
# For each of the 6 named steps: run the join to a deliberate death at that
# step, confirm --cleanup --force fully recovers (source slot, peer slot,
# data directory, manifest/sidecar, and any reverse subscriptions already
# created are all gone; the pre-existing n1<->n2 mesh is untouched), then
# move on to the next step. After the last (latest-possible) step, prove a
# fresh retry succeeds end-to-end -- the cluster is genuinely rejoinable,
# not just "cleaned up".
#
# die()'s own handler already tries "pg_ctl stop" on n3 before exiting, so
# by the time --cleanup runs moments later n3's postgres is typically
# already down -- cleanup_verified_subscriber_node() then cannot connect to
# confirm no subscription was left behind there, and cleanup_partial_state()
# deliberately reports "Cleanup incomplete ... keeping the manifest/sidecar
# record so --cleanup can be retried" rather than claiming a success it
# cannot verify, even though --force has already removed n3's entire data
# directory (which is what actually makes the retry trivially succeed: with
# the manifest gone as a side effect of that removal, and no sidecar either
# this late in the join, the next --cleanup finds nothing left to do). This
# is the same documented, timing-dependent contract
# 057_bidir_join_stall_abort.pl already exercises for its own die()-via-
# stall-timeout abort -- this test follows the identical accept-either-
# outcome-then-verify-physical-state pattern rather than assuming the first
# --cleanup call must return 0.
# =============================================================================

use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);
use POSIX qw(:sys_wait_h);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 command_ok system_maybe get_test_config scalar_query
                 wait_for_pg_ready wait_for_sub_status
                 output_plugin_libraries_conf);

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

my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_failmatrix';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";

my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.failmatrix';
open my $conf_fh, '>', $n3_conf or die "Cannot write $n3_conf: $!";
print $conf_fh "shared_buffers=1GB\n";
print $conf_fh "shared_preload_libraries='spock'\n";
print $conf_fh output_plugin_libraries_conf($pg_bin);
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

sub slurp_log {
    my ($logfile) = @_;
    return '' unless -f $logfile;
    open(my $fh, '<', $logfile) or die "Cannot open $logfile: $!";
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content // '';
}

# Runs one --cleanup --force attempt with its own log file, returning its
# exit code (0 = success).
sub run_cleanup_once {
    my ($logfile) = @_;
    unlink($logfile) if -f $logfile;
    my $pid = spawn_background($logfile,
        $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir);
    my $rc = wait_for_pid($pid, 60);
    unless (defined $rc) {
        kill('TERM', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    return $rc;
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

# Runs the join to completion (or to its test-injected death). $fail_after
# undef means a real, unhindered join. Returns true (like system_maybe) iff
# the process exited 0.
sub run_join {
    my ($fail_after) = @_;
    local $ENV{SPOCK_CREATE_SUBSCRIBER_TEST_FAIL_AFTER} = $fail_after
        if defined $fail_after;
    return system_maybe($SCS_BIN,
        '--bidirectional',
        '--pgdata',           $n3_datadir,
        '--subscriber-name',  'n3',
        '--provider-dsn',     $n1_dsn,
        '--subscriber-dsn',   $n3_dsn,
        '--postgresql-conf',  $n3_conf,
        '--stall-timeout',    '60',
        '--max-wait',         '300',
    );
}

# The peer slot name is a pure hash of (dbname, peer_node_name,
# subscription_name) -- deterministic and computable without n3 being up,
# from either half of the pre-existing n1<->n2 mesh.
my $n2_peer_slot_name = scalar_query(1,
    "SELECT spock.spock_gen_slot_name('$dbname', 'n2', 'sub_n3_n2')");

my @steps = qw(coverage_barrier clear_forwarding enable_peer_subs
               reverse_subs reverse_subs_ready verify);

for my $step (@steps) {
    ok(wait_for_zero_lag(1, 60), "replication drained before the '$step' attempt")
        or BAIL_OUT("n1->n2 replication never drained; cannot proceed");

    remove_tree($n3_datadir) if -d $n3_datadir;
    unlink($n3_pending) if -f $n3_pending;

    ok(!run_join($step), "join fails after step '$step' (test-injected)");

    my $cleanup_log1 = "$log_dir/scs_failmatrix_cleanup_${step}_1.log";
    my $cleanup_rc1  = run_cleanup_once($cleanup_log1);

    if ($cleanup_rc1 == 0) {
        pass("--cleanup --force exits 0 after failing at '$step' (first attempt)");
    } else {
        like(slurp_log($cleanup_log1),
             qr/Cleanup incomplete.*keeping the manifest.*retried/is,
             "cleanup after '$step' reports the documented \"retry\" outcome, " .
             "not an unrelated failure")
            or diag("see $cleanup_log1");

        my $cleanup_log2 = "$log_dir/scs_failmatrix_cleanup_${step}_2.log";
        my $cleanup_rc2  = run_cleanup_once($cleanup_log2);
        is($cleanup_rc2, 0,
           "--cleanup --force succeeds on retry after failing at '$step'")
            or diag("see $cleanup_log2");
    }

    is(scalar_query(1,
           "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'"),
       '0', "source slot removed from n1 after '$step' cleanup");

    is(scalar_query(2,
           "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '$n2_peer_slot_name'"),
       '0', "peer slot removed from n2 after '$step' cleanup");

    ok(!-d $n3_datadir, "n3 data directory removed after '$step' cleanup");
    ok(!-f $n3_manifest, "manifest removed after '$step' cleanup");
    ok(!-f $n3_pending, "pending sidecar removed after '$step' cleanup");

    is(scalar_query(1,
           "SELECT COUNT(*) FROM spock.subscription WHERE sub_name LIKE '%n3%'"),
       '0', "no orphaned n3-related subscription remains on n1 after '$step'");

    is(scalar_query(2,
           "SELECT COUNT(*) FROM spock.subscription WHERE sub_name LIKE '%n3%'"),
       '0', "no orphaned n3-related subscription remains on n2 after '$step'");

    ok((wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30)
        && wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 30)),
       "pre-existing n1 <-> n2 mesh unaffected after '$step' cleanup");
}

# =============================================================================
# TEST: after the last (latest-possible) failure point, a fresh retry
# succeeds end-to-end -- the cluster is genuinely rejoinable, not just
# "cleaned up".
# =============================================================================
ok(wait_for_zero_lag(1, 60), 'replication drained before the retry')
    or BAIL_OUT('n1->n2 replication never drained; cannot retry');

ok(run_join(undef), 'fresh --bidirectional retry after the failure matrix exits 0');

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running (retry)');
ok(wait_for_sub_status(3, 'sub_n3_n2', 'replicating', 30),
   'direct peer subscription sub_n3_n2 is replicating on n3 (retry)');

is(scalar_query(3, "SHOW spock.readonly"), 'off',
   'spock.readonly is lifted on n3 once the retried join is fully verified');

command_ok(
    [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir ],
    '--cleanup --force (final teardown) exits 0'
);
ok(!-d $n3_datadir, 'n3 data directory removed after final cleanup');

# =============================================================================
# CLEANUP
# =============================================================================
unlink($n3_conf) if -f $n3_conf;
destroy_cluster('Destroy 2-node cluster');

done_testing();
