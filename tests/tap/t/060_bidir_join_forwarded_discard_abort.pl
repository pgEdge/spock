#!/usr/bin/perl
# =============================================================================
# Test: 060_bidir_join_forwarded_discard_abort.pl - an error-class exception
#                                                    on a forwarded txn
#                                                    during catchup must
#                                                    abort the join, not
#                                                    silently drop the row
# =============================================================================
# SPOC-607 hardening review flagged this as a design-doc scenario (§16,
# "Abort-on-discard") with zero coverage, needing new injection-point
# infrastructure -- there was no way to force an apply failure specifically
# on a *forwarded*-origin change (as opposed to any ordinary apply error).
#
# New infra added alongside this test: SPOCK_FORWARDED_APPLY_ERROR(), a
# named injection point (include/spock_injection.h, same three-way
# SPOCK_RANDOM_DELAYS / USE_INJECTION_POINTS / no-op pattern already used by
# SPOCK_WORKER_DELAY()/SPOCK_OUTPUT_TXN_STALL()) fired from
# spock_apply_heap_insert/update/delete() right before the heap write, but
# only when the row being applied belongs to a forwarded-origin transaction
# (src/spock_apply_heap.c: is_forwarded_origin_apply(), mirroring the same
# replorigin_session_origin vs. MySubscription->origin->id test
# handle_origin() itself uses).
#
# n3 uses spock.exception_behaviour=sub_disable (the same setting every
# other bidir-join test in this family uses; 'error' is not a real value --
# the only ones the GUC accepts are discard/transdiscard/sub_disable). A
# first-attempt apply failure is not yet retried with a subtransaction
# wrapper (MyApplyWorker->use_try_block is false until a worker restart has
# already seen this same commit LSN fail once), so it propagates straight
# out of apply_work()'s outer PG_TRY: no partial commit, and
# maybe_advance_forwarded_origin() never runs for this transaction. The
# manager restarts the apply worker, which retries the same transaction --
# this time with use_try_block=true, so the poisoned action is logged and
# skipped rather than applied, but per spock_apply.c's own SUB_DISABLE
# handling the origin LSN is deliberately NOT advanced even though the
# retry "succeeded", and the worker throws once more to disable sub_n3_n1
# outright. Either way, progress on sub_n3_n1 freezes permanently at the
# poisoned LSN and the subscription ends up disabled -- exactly the signal
# the existing catchup stall watchdog (057_bidir_join_stall_abort.pl) and
# --max-wait ceiling are built to catch, and a world away from "the row
# quietly vanished but the join reported success". This test proves that
# combination actually aborts the *join*: the poisoned row's transaction is
# written on n2 (the peer, not the provider) so it only ever reaches n3 by
# being *forwarded* through n1 -- an ordinary own-origin write from n1 would
# not exercise the forwarded-apply guard at all.
#
# Requires a server built with --enable-injection-points; skips cleanly
# (like 046_apply_worker_exception_misclassification.pl) when that support
# is not present.
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
# Locate spock_create_subscriber binary and check for injection_points
# support before doing any cluster setup.
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

# =============================================================================
# Check for injection_points support; skip_all (not fail) if unavailable.
# Must run before any test assertion (plan skip_all requires it).
# =============================================================================
my $config_probe = get_test_config();
my $pg_bin_probe = $config_probe->{pg_bin};
my $pkglibdir = `"$pg_bin_probe/pg_config" --pkglibdir`;
chomp $pkglibdir;
my $has_injection_points = (-e "$pkglibdir/injection_points.so")
    || (-e "$pkglibdir/injection_points.dylib");

unless ($has_injection_points) {
    plan skip_all =>
        "server not built with --enable-injection-points; " .
        "cannot force a forwarded-apply error deterministically";
}

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
# SETUP: a small continuous writer on n1, purely to keep the catchup wait
# genuinely open (rather than resolving instantly against an idle source,
# per 050/057's own finding) long enough to attach the injection point and
# land the poisoned peer write while forward_origins is still active.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE discard_test_tbl (id bigint PRIMARY KEY, val text)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE SEQUENCE discard_test_id_seq";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', q{
    CREATE PROCEDURE discard_test_load(n_batches int, batch_rows int)
    LANGUAGE plpgsql AS $$
    DECLARE i int;
    BEGIN
        FOR i IN 1..n_batches LOOP
            INSERT INTO discard_test_tbl
                SELECT nextval('discard_test_id_seq'), 'x' || g
                FROM generate_series(1, batch_rows) g;
            COMMIT;
            PERFORM pg_sleep(0.05);
        END LOOP;
    END $$;
};

# The peer's own table -- the row that will be forwarded through n1 to n3
# and trip the injection point. Created directly on n2 (not replicated from
# n1) so it is unambiguously n2-origin.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "CREATE TABLE discard_peer_tbl (id serial PRIMARY KEY, val text)";
pass('writer procedure and peer test table created');

ok(wait_for_zero_lag(1, 60), 'replication drained before starting the join')
    or BAIL_OUT('n1->n2 replication never drained after setup; cannot proceed');

my $writer_pid;

sub start_writer {
    $writer_pid = spawn_background("$log_dir/discard_test_writer.log",
        "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname,
        '-c', "CALL discard_test_load(100000, 200)");
}

sub stop_writer {
    system_or_bail "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname, '-c',
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " .
        "WHERE query LIKE 'CALL discard_test_load%' AND pid <> pg_backend_pid()";
    for (1 .. 30) {
        my $still_running = scalar_query(1,
            "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'CALL discard_test_load%'");
        last if defined $still_running && $still_running eq '0';
        sleep(1);
    }
    kill('TERM', $writer_pid);
    waitpid($writer_pid, 0);
}

# =============================================================================
# TEST: start --bidirectional, arm the forwarded-apply injection point on
# n3, write a row on the peer (n2) so it is forwarded through n1 while
# forward_origins is still active, and confirm the join aborts rather than
# completing with that row silently missing.
# =============================================================================
my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_discard';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";

remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_pending) if -f $n3_pending;

my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.discard';
open my $conf_fh, '>', $n3_conf or die "Cannot write $n3_conf: $!";
print $conf_fh "shared_buffers=1GB\n";
print $conf_fh "shared_preload_libraries='spock,injection_points'\n";
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

my $scs_log = "$log_dir/scs_discard_abort.log";
unlink($scs_log) if -f $scs_log;

my $scs_pid = spawn_background($scs_log,
    $SCS_BIN,
    '--bidirectional',
    '--pgdata',           $n3_datadir,
    '--subscriber-name',  'n3',
    '--provider-dsn',     $n1_dsn,
    '--subscriber-dsn',   $n3_dsn,
    '--postgresql-conf',  $n3_conf,
    '--stall-timeout',    '20',
    '--max-wait',         '90',
);

ok(wait_for_slot_created($n3_pending, $n3_manifest, 30),
   'source slot created (safe to start the writer)')
    or BAIL_OUT('spock_create_subscriber never created the source slot; see ' . $scs_log);
start_writer();

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 60),
   'n3 postgres is running')
    or BAIL_OUT('n3 postgres never came up; see ' . $scs_log);

ok(wait_for_log_pattern($scs_log, qr/Waiting for catchup to the source/, 120),
   'spock_create_subscriber reached the catchup wait phase')
    or BAIL_OUT('never reached the catchup wait phase; see ' . $scs_log);

system_or_bail "$pg_bin/psql", '-X', '-p', $n3_port, '-d', $dbname, '-c',
    "CREATE EXTENSION IF NOT EXISTS injection_points";
ok(system_maybe("$pg_bin/psql", '-X', '-p', $n3_port, '-d', $dbname, '-c',
       "SELECT injection_points_attach('spock-forwarded-apply-error', 'error')"),
   'armed the forwarded-apply-error injection point on n3');

system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "INSERT INTO discard_peer_tbl (val) VALUES ('poison')";
pass('wrote the poisoned row on the peer (n2), to be forwarded through n1');

my $scs_rc = wait_for_pid($scs_pid, 150);

stop_writer();
system_maybe("$pg_bin/psql", '-X', '-p', $n3_port, '-d', $dbname, '-c',
    "SELECT injection_points_detach('spock-forwarded-apply-error')");

ok(defined $scs_rc, 'spock_create_subscriber exited on its own (join aborted)')
    or diag("spock_create_subscriber did not exit within 150s; see $scs_log");
if (!defined $scs_rc) {
    kill('TERM', $scs_pid);
    waitpid($scs_pid, 0);
    $scs_rc = -1;
}
isnt($scs_rc, 0,
     'spock_create_subscriber exits non-zero: the forwarded-txn error aborts the join');

# =============================================================================
# TEST: n3 never reached cutover -- read-only was never lifted, sub_n3_n1
# ended up disabled rather than silently completing, and the poisoned row
# was never durably visible. die()'s own handler already stopped n3's
# postgres as part of aborting, so it must be restarted (independently of
# spock_create_subscriber's own machinery) to inspect it, then stopped
# again before --cleanup runs.
# =============================================================================
system_or_bail "$pg_bin/pg_ctl", 'start', '-D', $n3_datadir,
    '-l', "$log_dir/n3_discard_inspect.log";
ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30),
   'n3 postgres restarted for post-abort inspection');

my $readonly_after_abort = scalar_query(3, "SHOW spock.readonly");
isnt($readonly_after_abort, 'off',
     'n3 never lifted read-only (join did not reach cutover)');

my $sub_n3_n1_enabled = scalar_query(3,
    "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n3_n1'");
is($sub_n3_n1_enabled, 'f',
   'sub_n3_n1 ended up disabled by the forwarded-apply error, not silently caught up');

my $poison_on_n3 = scalar_query(3,
    "SELECT COUNT(*) FROM discard_peer_tbl WHERE val = 'poison'");
is($poison_on_n3, '0',
   'the poisoned row is not durably present on n3 after the abort');

system_or_bail "$pg_bin/pg_ctl", 'stop', '-D', $n3_datadir, '-m', 'fast';

# =============================================================================
# TEST: --cleanup --force recovers cleanly after the aborted join, and the
# pre-existing n1<->n2 mesh is unaffected. die() already stopped n3's
# postgres once (and this test stopped it again above after inspecting it),
# so -- exactly as in 058_bidir_join_failure_matrix.pl and
# 057_bidir_join_stall_abort.pl -- the first --cleanup attempt may
# legitimately report "Cleanup incomplete ... keeping the manifest/sidecar
# record so --cleanup can be retried" because it cannot reach n3 to confirm
# no local subscription was left behind there, even though --force has
# already removed n3's entire data directory. This accepts either outcome
# and verifies the retry succeeds, rather than assuming the first call must
# return 0.
# =============================================================================
my $cleanup_log1 = "$log_dir/scs_discard_cleanup1.log";
unlink($cleanup_log1) if -f $cleanup_log1;
my $cleanup_pid1 = spawn_background($cleanup_log1,
    $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir);
my $cleanup_rc1  = wait_for_pid($cleanup_pid1, 60);
unless (defined $cleanup_rc1) {
    kill('TERM', $cleanup_pid1);
    waitpid($cleanup_pid1, 0);
    $cleanup_rc1 = -1;
}

if ($cleanup_rc1 == 0) {
    pass('--cleanup --force exits 0 after the forwarded-apply-error abort (first attempt)');
} else {
    my $cleanup_out1 = '';
    if (open(my $fh, '<', $cleanup_log1)) {
        local $/;
        $cleanup_out1 = <$fh> // '';
        close($fh);
    }
    like($cleanup_out1,
         qr/Cleanup incomplete.*keeping the manifest.*retried/is,
         'cleanup after the abort reports the documented "retry" outcome, ' .
         'not an unrelated failure')
        or diag("see $cleanup_log1");

    command_ok(
        [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir ],
        '--cleanup --force succeeds on retry after the forwarded-apply-error abort'
    );
}

my $source_slot_after_cleanup = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
is($source_slot_after_cleanup, '0', 'source slot removed from n1 after cleanup');

ok(!-d $n3_datadir, 'n3 data directory removed after cleanup --force');

ok((wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30)
    && wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 30)),
   'pre-existing n1 <-> n2 mesh is unaffected by the abort + cleanup cycle');

system_maybe "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS discard_test_tbl";
system_maybe "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS discard_peer_tbl";

# =============================================================================
# CLEANUP
# =============================================================================
unlink($n3_conf) if -f $n3_conf;
destroy_cluster('Destroy 2-node cluster');

done_testing();
