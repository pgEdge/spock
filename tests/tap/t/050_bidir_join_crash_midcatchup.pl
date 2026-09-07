#!/usr/bin/perl
# =============================================================================
# Test: 050_bidir_join_crash_midcatchup.pl - spock_create_subscriber
#                                             --bidirectional survives the
#                                             utility process itself being
#                                             killed mid-catchup
# =============================================================================
# 048_bidir_join.pl and 049_bidir_join_under_load.pl both prove --cleanup
# --force recovers a join that failed during the *base backup* phase (a
# deliberately broken --extra-basebackup-args). Neither kills the utility
# process itself once it is past that point and into the catchup replay --
# the phase this session's investigation (spurious SUB_DISABLE / apply-idle-
# timeout misclassification, PR 607) was all about. The design doc's own
# resumability contract for a mid-catchup crash is "not a resumable journal":
# the practical recovery is --cleanup --force + a fresh basebackup, same as
# for a backup failure -- but that path was never actually exercised for a
# crash landing *after* the source slot exists and the catchup subscription
# is already replicating, only for one landing *before* the backup completes.
#
# This test seeds n1 with enough rows that the catchup replay is guaranteed
# to still be in progress a few seconds in, starts --bidirectional in the
# background, waits until n3's catchup subscription (sub_n3_n1) is
# genuinely mid-replay (present, replicating, and only partially caught up),
# then SIGKILLs the utility process outright -- no SIGTERM, no chance for
# graceful shutdown -- and verifies: --cleanup --force still recovers
# cleanly (source slot removed, data directory removed); the pre-existing
# n1<->n2 mesh is unaffected; and a fresh --bidirectional retry against the
# same source afterward succeeds end-to-end with correct data, proving the
# cluster is genuinely left in a rejoinable state, not just "cleaned up".
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

# =============================================================================
# SETUP: a continuous writer on n1, so catchup always has a growing WAL
# delta to replay. --bidirectional does a *physical* basebackup first --
# a one-time seed inserted before the join is already present in that
# backup, leaving nothing for the logical catchup subscription to actually
# replay (confirmed empirically: a 400k-row one-time seed made catchup
# resolve instantly, giving no window to interrupt at all). Only rows
# written *during* the join, after the backup's start LSN, are real
# catchup work.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE crash_test_tbl (id bigint PRIMARY KEY, val text)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE SEQUENCE crash_test_id_seq";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', q{
    CREATE PROCEDURE crash_test_load(n_batches int, batch_rows int)
    LANGUAGE plpgsql AS $$
    DECLARE i int;
    BEGIN
        FOR i IN 1..n_batches LOOP
            INSERT INTO crash_test_tbl
                SELECT nextval('crash_test_id_seq'), 'x' || g
                FROM generate_series(1, batch_rows) g;
            COMMIT;
            PERFORM pg_sleep(0.02);
        END LOOP;
    END $$;
};
pass('crash_test_tbl and writer procedure created on n1');

ok(wait_for_zero_lag(1, 60), 'replication drained before starting the join')
    or BAIL_OUT('n1->n2 replication never drained after setup; cannot proceed');

# The writer is started only after --bidirectional's own
# check_preconditions() has already passed (see wait_for_slot_created()
# below) -- it hard-rejects up front if the source has *any* unreplicated
# changes pending to an existing peer, so starting it any earlier makes
# every run fail before n3's postgres even comes up (confirmed
# empirically). Kept running through the rest of the physical backup and
# into catchup, then stopped (server-side) once the kill has landed. Same
# technique as 046_apply_worker_exception_misclassification.pl and
# 051_bidir_join_multipeer_lag.pl: killing the client process alone does
# not reliably stop a backend mid-CALL.
my $writer_pid;

sub start_writer {
    $writer_pid = spawn_background("$log_dir/crash_test_writer.log",
        "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname,
        '-c', "CALL crash_test_load(100000, 3000)");
}

sub stop_writer {
    system_or_bail "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname, '-c',
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " .
        "WHERE query LIKE 'CALL crash_test_load%' AND pid <> pg_backend_pid()";
    for (1 .. 30) {
        my $still_running = scalar_query(1,
            "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'CALL crash_test_load%'");
        last if defined $still_running && $still_running eq '0';
        sleep(1);
    }
    kill('TERM', $writer_pid);
    waitpid($writer_pid, 0);
}

# =============================================================================
# TEST: start --bidirectional, kill it mid-catchup, confirm --cleanup
# --force recovers cleanly
# =============================================================================
my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_crash';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";

remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_pending) if -f $n3_pending;

# The pending-cleanup sidecar is written immediately after the source slot
# is created, i.e. immediately after check_preconditions() has already
# passed -- polling for it (or the real manifest, in case it lands between
# polls) is the same technique 049_bidir_join_under_load.pl uses to know
# it is now safe to resume write load against the source.
sub wait_for_slot_created {
    my ($timeout) = @_;
    for (1 .. $timeout) {
        return 1 if -f $n3_pending || -f $n3_manifest;
        sleep(1);
    }
    return 0;
}

my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.crash';
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

my $scs_log = "$log_dir/scs_crash_midcatchup.log";
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

ok(wait_for_slot_created(30), 'source slot created (safe to start the writer)')
    or BAIL_OUT('spock_create_subscriber never created the source slot; see ' . $scs_log);
start_writer();

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 60),
   'n3 postgres is running (pre-kill)')
    or BAIL_OUT('n3 postgres never came up; see ' . $scs_log);

# Wait until spock_create_subscriber's own log shows it has entered the
# catchup wait -- sub_n3_n1 exists, is enabled, and wait_for_catchup() is
# now polling its progress against a fixed target LSN captured moments
# earlier. The writer has been running since the source slot was created
# (well before this point: the physical backup transfer, restore-point
# dance, and n3 postgres restart all happen in between), so the target
# captured is already a large, real backlog -- no margin sleep here on
# purpose: with an idle peer (n2) the coverage barrier and clear_forwarding
# phases that follow catchup are fast, so killing as early as possible
# (the instant this line appears) rather than after any extra delay is
# what keeps this test inside the catchup wait specifically, rather than
# racing into later phases.
ok(wait_for_log_pattern($scs_log, qr/Waiting for catchup to the source/, 120),
   'spock_create_subscriber reached the catchup wait phase')
    or BAIL_OUT('never reached the catchup wait phase; see ' . $scs_log);

# The harshest interruption: no SIGTERM, no chance to run any cleanup path
# at all -- a genuine crash, not a graceful stop.
kill('KILL', $scs_pid);
waitpid($scs_pid, 0);
pass('spock_create_subscriber process killed (SIGKILL) mid-catchup');

stop_writer();

my $final_count = scalar_query(1, "SELECT COUNT(*) FROM crash_test_tbl");
ok(defined $final_count && $final_count > 0,
   "writer produced $final_count rows on n1 before being stopped");

my $source_slot_after_kill = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
ok($source_slot_after_kill >= 1,
   'source slot on n1 survives the kill (orphaned, as expected)');

command_ok(
    [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir ],
    '--cleanup --force exits 0 after a mid-catchup kill'
);

my $source_slot_after_cleanup = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
is($source_slot_after_cleanup, '0', 'source slot removed from n1 after cleanup');

ok(!-d $n3_datadir, 'n3 data directory removed after cleanup --force');

ok(!wait_for_pg_ready($host, $n3_port, $pg_bin, 5),
   'n3 postgres is no longer reachable after cleanup');

my $n1n2_ok_after_kill = wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30)
                      && wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 30);
ok($n1n2_ok_after_kill,
   'pre-existing n1 <-> n2 mesh is unaffected by the crash + cleanup cycle');

# =============================================================================
# TEST: a fresh --bidirectional retry against the same source succeeds --
# the cluster is genuinely rejoinable, not just "cleaned up".
# =============================================================================
ok(wait_for_zero_lag(1, 60), 'replication drained before the retry')
    or BAIL_OUT('n1->n2 replication never drained after cleanup; cannot retry');

my $scs_log_retry = "$log_dir/scs_crash_midcatchup_retry.log";
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
    '--max-wait',         '600',
);

my $scs_rc_retry = wait_for_pid($scs_pid_retry, 300);
unless (defined $scs_rc_retry) {
    diag("spock_create_subscriber (retry) did not exit within 300s; killing it");
    kill('TERM', $scs_pid_retry);
    waitpid($scs_pid_retry, 0);
    $scs_rc_retry = -1;
}
is($scs_rc_retry, 0, 'fresh --bidirectional retry after the crash exits 0')
    or diag("see $scs_log_retry");

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running (retry)');
ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 30),
   'catchup subscription sub_n3_n1 is replicating on n3 (retry)');

my $n3_count_retry = '-1';
for (1 .. 60) {
    $n3_count_retry = scalar_query(3, "SELECT COUNT(*) FROM crash_test_tbl");
    last if $n3_count_retry eq $final_count;
    sleep(1);
}
is($n3_count_retry, $final_count, 'all rows present on n3 after the retry');

my $hash_n1 = scalar_query(1,
    "SELECT md5(COALESCE(string_agg(x::text, ',' ORDER BY id), '')) FROM crash_test_tbl x");
my $hash_n3 = scalar_query(3,
    "SELECT md5(COALESCE(string_agg(x::text, ',' ORDER BY id), '')) FROM crash_test_tbl x");
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
