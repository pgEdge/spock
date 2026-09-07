#!/usr/bin/perl
# =============================================================================
# Test: 057_bidir_join_stall_abort.pl - the catchup stall watchdog must
#                                        actually fire, cleanly, when
#                                        progress genuinely stops
# =============================================================================
# Design doc (spock_bidirectional_final.md) section 16, progress-watchdog
# scenarios: "Stall a wait (freeze *all* progress signals) past
# --stall-timeout -> clean abort with an attributed bottleneck message;
# state preserved; --cleanup recovers; retry resumes." 051_bidir_join_
# multipeer_lag.pl and 052_bidir_join_big_txn_liveness.pl already prove the
# two "must NOT abort" halves of the same watchdog (slow-but-progressing,
# and a healthy worker busy on one large transaction) -- but nothing
# exercised the abort path itself actually firing. Confirmed by reading
# wait_for_origin_progress() in spock_create_subscriber.c: a stall is only
# declared when BOTH origin LSN progress is frozen AND (for a caller with a
# watch_sub_name) apply_worker_is_busy() reports the apply worker is not
# active -- so to hit this deterministically, both signals need to freeze
# at once, not just one.
#
# This freezes both signals the same way a real network partition or dead
# link would: rather than manufacturing a scenario through extra load or
# timing, it SIGSTOPs the actual walsender backend on n1 serving n3's
# catchup subscription. Found precisely, not "most recently connected" (to
# avoid any ambiguity with the pre-existing n1<->n2 mesh's own apply
# connections): spock_connect_replica() (spock.c) passes the subscription's
# own slot_name as the outbound connection's application_name, so on n1
# that walsender's pg_stat_replication.application_name is exactly
# sub_n3_n1's sub_slot_name. (This is a different application_name than
# the "spock apply <dboid>:<subid>" convention apply_worker_is_busy() uses
# -- that one is set locally on n3's own backend via SetConfigOption() in
# spock_worker.c, for n3's own pg_stat_activity; it is never sent to n1.)
# A stopped walsender sends nothing further, so n3's origin LSN stops
# advancing, and once the apply worker finishes whatever was already in
# flight it goes idle -- both conditions the watchdog requires,
# deterministically and without touching any implementation code.
#
# After the abort: SIGCONT is required before --cleanup, since DROP
# ... REPLICATION SLOT waits for its walsender to detach, which a stopped
# backend never does. --cleanup --force must then recover cleanly, the
# pre-existing n1<->n2 mesh must be unaffected, and a fresh retry (against
# the now-unstalled source) must succeed end-to-end -- the same "genuinely
# rejoinable, not just cleaned up" bar 050_bidir_join_crash_midcatchup.pl
# sets for its own crash scenario.
#
# Unix-only (SIGSTOP/SIGCONT process control), consistent with the rest of
# this test family's existing fork()/exec()/kill() use for spawning and
# killing spock_create_subscriber itself.
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
            return 1 if defined $content && $content =~ $pattern;
        }
        sleep(1);
    }
    return 0;
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

# =============================================================================
# SETUP: a continuous writer on n1, so catchup always has a real, moving
# backlog right up until the freeze -- same rationale as
# 050_bidir_join_crash_midcatchup.pl: a one-time seed already present in
# the physical backup leaves nothing for the logical catchup subscription
# to replay, so only rows written *during* the join are real catchup work.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE stall_test_tbl (id bigint PRIMARY KEY, val text)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE SEQUENCE stall_test_id_seq";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', q{
    CREATE PROCEDURE stall_test_load(n_batches int, batch_rows int)
    LANGUAGE plpgsql AS $$
    DECLARE i int;
    BEGIN
        FOR i IN 1..n_batches LOOP
            INSERT INTO stall_test_tbl
                SELECT nextval('stall_test_id_seq'), 'x' || g
                FROM generate_series(1, batch_rows) g;
            COMMIT;
            PERFORM pg_sleep(0.02);
        END LOOP;
    END $$;
};
pass('stall_test_tbl and writer procedure created on n1');

ok(wait_for_zero_lag(1, 60), 'replication drained before starting the join')
    or BAIL_OUT('n1->n2 replication never drained after setup; cannot proceed');

my $writer_pid;

sub start_writer {
    $writer_pid = spawn_background("$log_dir/stall_test_writer.log",
        "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname,
        '-c', "CALL stall_test_load(100000, 500)");
}

sub stop_writer {
    system_or_bail "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname, '-c',
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " .
        "WHERE query LIKE 'CALL stall_test_load%' AND pid <> pg_backend_pid()";
    for (1 .. 30) {
        my $still_running = scalar_query(1,
            "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'CALL stall_test_load%'");
        last if defined $still_running && $still_running eq '0';
        sleep(1);
    }
    kill('TERM', $writer_pid);
    waitpid($writer_pid, 0);
}

# =============================================================================
# TEST: start --bidirectional, freeze the source walsender partway through
# the join (both LSN progress and apply-worker liveness at once -- this
# lands during catchup or, if catchup finishes first against this test's
# small backlog, the immediately-following coverage barrier's Hop 2, since
# both poll the same sub_n3_n1 connection), and confirm the watchdog
# aborts cleanly with an attributed message.
# =============================================================================
my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_stall';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";
my $stall_timeout = 5;

remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_pending) if -f $n3_pending;

my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.stall';
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

my $scs_log = "$log_dir/scs_stall_abort.log";
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
   'source slot created (safe to start the writer)')
    or BAIL_OUT('spock_create_subscriber never created the source slot; see ' . $scs_log);
start_writer();

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 60),
   'n3 postgres is running (pre-freeze)')
    or BAIL_OUT('n3 postgres never came up; see ' . $scs_log);

ok(wait_for_log_pattern($scs_log, qr/Waiting for catchup to the source/, 120),
   'spock_create_subscriber reached the catchup wait phase')
    or BAIL_OUT('never reached the catchup wait phase; see ' . $scs_log);

stop_writer();

# Precisely identify n3's own catchup-subscription apply connection on n1
# -- not "most recently connected" -- via the slot name spock_connect_
# replica() uses as that connection's application_name, so there is no
# ambiguity with the pre-existing n1<->n2 mesh's own apply connections.
my $n3_slot_name = scalar_query(3,
    "SELECT sub_slot_name FROM spock.subscription WHERE sub_name = 'sub_n3_n1'");
ok(defined $n3_slot_name && length($n3_slot_name), 'read sub_n3_n1 slot name')
    or BAIL_OUT('could not read sub_n3_n1 slot name; see ' . $scs_log);

my $walsender_pid = scalar_query(1,
    "SELECT pid FROM pg_stat_replication WHERE application_name = '$n3_slot_name'");
ok(defined $walsender_pid && $walsender_pid =~ /^\d+$/,
   "found n1's walsender backend for sub_n3_n1 (pid $walsender_pid)")
    or BAIL_OUT("could not find walsender for application_name '$n3_slot_name'");

ok(kill('STOP', $walsender_pid), "SIGSTOPped n1's walsender for sub_n3_n1")
    or BAIL_OUT("could not SIGSTOP walsender pid $walsender_pid: $!");

my $scs_rc = wait_for_pid($scs_pid, 30);

# Always resume the frozen backend before doing anything else, regardless
# of how the assertions below turn out -- a stopped walsender left behind
# would otherwise wedge every later step in this test (including
# --cleanup's own slot drop, and Test::More's own teardown).
ok(kill('CONT', $walsender_pid), "SIGCONTed n1's walsender for sub_n3_n1");

ok(defined $scs_rc, 'spock_create_subscriber exited on its own (watchdog fired)')
    or diag("spock_create_subscriber did not exit within 30s after the freeze; see $scs_log");
if (!defined $scs_rc) {
    kill('TERM', $scs_pid);
    waitpid($scs_pid, 0);
    $scs_rc = -1;
}
isnt($scs_rc, 0,
     'spock_create_subscriber exits non-zero once the stall watchdog fires');

my $scs_output = slurp_log($scs_log);
like($scs_output,
     qr/\S[^\n]*? appears stalled: no origin progress for \d+ second\(s\) and the apply worker is not active \(--stall-timeout\)/,
     'abort message attributes the stall to a specific phase, not a generic wait');

# =============================================================================
# TEST: --cleanup --force recovers cleanly after the aborted join
# =============================================================================
# die()'s own handler (spock_create_subscriber.c) already tries "pg_ctl
# stop -s" on n3 before exiting. Depending on exactly how far that
# shutdown has progressed by the time --cleanup runs moments later,
# cleanup_partial_state() may or may not still be able to reach n3 for a
# fully "confirmed" cleanup -- if not, it deliberately returns non-zero
# and prints "Cleanup incomplete ... keeping the manifest/sidecar record
# so --cleanup can be retried", an explicit invitation to run it again,
# not a failure to route around. Both outcomes are legitimate depending
# on timing, so this exercises the documented retry contract rather than
# assuming either one.
sub run_scs_capture {
    my ($logfile, @args) = @_;
    unlink($logfile) if -f $logfile;
    my $pid = spawn_background($logfile, $SCS_BIN, @args);
    my $rc = wait_for_pid($pid, 60);
    unless (defined $rc) {
        kill('TERM', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    return $rc;
}

my $cleanup_log1 = "$log_dir/scs_stall_abort_cleanup1.log";
my $cleanup_rc1  = run_scs_capture($cleanup_log1,
    '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir);

if ($cleanup_rc1 == 0) {
    pass('--cleanup --force exits 0 after the stall abort (first attempt)');
} else {
    like(slurp_log($cleanup_log1),
         qr/Cleanup incomplete.*keeping the manifest.*retried/is,
         'first cleanup attempt reports the documented "retry" outcome, ' .
         'not an unrelated failure')
        or diag("see $cleanup_log1");

    my $cleanup_log2 = "$log_dir/scs_stall_abort_cleanup2.log";
    my $cleanup_rc2  = run_scs_capture($cleanup_log2,
        '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir);
    is($cleanup_rc2, 0,
       '--cleanup --force succeeds on retry, per its own documented contract')
        or diag("see $cleanup_log2");
}

my $source_slot_after_cleanup = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
is($source_slot_after_cleanup, '0', 'source slot removed from n1 after cleanup');

ok(!-d $n3_datadir, 'n3 data directory removed after cleanup --force');

my $n1n2_ok_after_stall = wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30)
                       && wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 30);
ok($n1n2_ok_after_stall,
   'pre-existing n1 <-> n2 mesh is unaffected by the stall + abort + cleanup cycle');

# =============================================================================
# TEST: a fresh --bidirectional retry against the now-unstalled source
# succeeds end-to-end -- the cluster is genuinely rejoinable, not just
# "cleaned up".
# =============================================================================
my $final_count = scalar_query(1, "SELECT COUNT(*) FROM stall_test_tbl");
ok(defined $final_count && $final_count > 0,
   "writer produced $final_count rows on n1 before it was stopped");

ok(wait_for_zero_lag(1, 60), 'replication drained before the retry')
    or BAIL_OUT('n1->n2 replication never drained after cleanup; cannot retry');

my $scs_log_retry = "$log_dir/scs_stall_abort_retry.log";
unlink($scs_log_retry) if -f $scs_log_retry;

my $scs_pid_retry = spawn_background($scs_log_retry,
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

my $scs_rc_retry = wait_for_pid($scs_pid_retry, 300);
unless (defined $scs_rc_retry) {
    diag("spock_create_subscriber (retry) did not exit within 300s; killing it");
    kill('TERM', $scs_pid_retry);
    waitpid($scs_pid_retry, 0);
    $scs_rc_retry = -1;
}
is($scs_rc_retry, 0, 'fresh --bidirectional retry after the stall abort exits 0')
    or diag("see $scs_log_retry");

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running (retry)');
ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 30),
   'catchup subscription sub_n3_n1 is replicating on n3 (retry)');

my $n3_count_retry = '-1';
for (1 .. 60) {
    $n3_count_retry = scalar_query(3, "SELECT COUNT(*) FROM stall_test_tbl");
    last if $n3_count_retry eq $final_count;
    sleep(1);
}
is($n3_count_retry, $final_count, 'all rows present on n3 after the retry');

my $hash_n1 = scalar_query(1,
    "SELECT md5(COALESCE(string_agg(x::text, ',' ORDER BY id), '')) FROM stall_test_tbl x");
my $hash_n3 = scalar_query(3,
    "SELECT md5(COALESCE(string_agg(x::text, ',' ORDER BY id), '')) FROM stall_test_tbl x");
is($hash_n3, $hash_n1, 'content hash matches between n1 and n3 after the retry');

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
