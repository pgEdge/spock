#!/usr/bin/perl
# =============================================================================
# Test: 071_bidir_join_under_load.pl - spock_create_subscriber --bidirectional
#                                       under sustained OLTP write load
# =============================================================================
# 070_bidir_plumbing.pl proves the --bidirectional pipeline (physical backup,
# catalog strip, catchup, coverage barrier, cutover, reverse subscriptions)
# is correct against a quiescent source. It does not prove the pipeline
# survives a source that is actively, continuously being written to for the
# whole multi-minute duration of the join -- which is the realistic
# production scenario this utility exists for.
#
# This test drives a TPC-C-like OLTP workload against n1 (via the
# pgedge-loadgen tool, https://github.com/pgEdge/pgedge-loadgen -- see
# PGEDGE_LOADGEN_BIN below) throughout a --bidirectional join, at a
# configurable intensity (SPOCK_BIDIR_LOAD_LEVEL=light|medium|heavy), and
# verifies: the join completes and reports success; n3's final data matches
# both n1's and n2's exactly -- row count AND full content hash, every
# wholesale table, not just one -- once replication drains; fresh
# bidirectional writes still flow correctly afterward; and --cleanup
# --force correctly recovers an orphaned join attempt while the source
# remains under load. Along the way it exercises --stall-timeout,
# --max-wait, --extra-basebackup-args (both a valid and a deliberately
# broken value), and a deliberately injected catchup-subscription
# apply_delay -- coverage 070 only ever exercises against a quiescent
# cluster, if at all.
#
# check_preconditions() (spock_create_subscriber.c) requires the source's
# outbound replication to have zero lag at the instant it runs, so the load
# generator cannot simply run continuously across the whole test: it is
# stopped and drained before each --bidirectional invocation, then resumed
# the moment that invocation's pending-cleanup sidecar file appears on disk
# (written immediately after the source slot is created, i.e. immediately
# after check_preconditions() has already passed) -- so the actual
# multi-minute body of the join (basebackup transfer, catchup replay,
# coverage barrier, cutover) runs with the source under active write load,
# exactly as intended.
#
# NOT added to tests/tap/schedule or schedule-nightly (see the commented-out
# entry there): this is meant to be run individually for now
# (PROVE_TESTS=t/071_bidir_join_under_load.pl make check_prove) and promoted
# to a nightly/weekly CI schedule later, once its real-world runtime at
# medium/heavy load is characterized.
#
# Requires the pgedge-loadgen binary. Resolved via, in order: the
# PGEDGE_LOADGEN_BIN environment variable; ../../../pgedge-loadgen/bin/
# pgedge-loadgen (a sibling checkout of https://github.com/pgEdge/
# pgedge-loadgen next to this spock checkout); PATH. skip_all (not fail) if
# none is found, matching ensure_lolor()'s precedent for an optional
# external dependency (SpockTest.pm) -- the test count is therefore not
# known up front (see 032_lolor_largeobject_repset.pl for the same
# plan-skip_all-then-done_testing() shape), and is settled by
# done_testing() at the end instead of a fixed Test::More tests => N plan.
#
# Flow: seed n1 with the wholesale schema+data, then run three scenarios,
# each under active pgedge-loadgen write load against n1 throughout the
# multi-minute body of the join:
#   1. a full --bidirectional join with --stall-timeout/--max-wait/
#      --extra-basebackup-args set, verified by exit code, subscription
#      status, an exact row-count+content-hash match between n1/n3 and
#      n1/n2 once replication drains, and a fresh two-way write proof --
#      then --cleanup --force torn down.
#   2. a join that fails part-way (broken --extra-basebackup-args, same
#      trick as 070_bidir_plumbing.pl) orphaning a source slot, recovered via
#      --cleanup --force while n1 is still under load.
#   3. a full join like (1), but with a deliberate apply_delay injected
#      onto the catchup subscription partway through, proving the coverage
#      barrier's stall-timeout logic tolerates steady, bounded replication
#      lag rather than mistaking it for a stall.
# =============================================================================

use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);
use POSIX qw(:sys_wait_h);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 command_ok system_maybe get_test_config scalar_query
                 psql_or_bail wait_for_pg_ready wait_for_sub_status
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

# =============================================================================
# Locate pgedge-loadgen binary; skip_all (not fail) if unavailable
# =============================================================================
my $LOADGEN_BIN = $ENV{PGEDGE_LOADGEN_BIN};
$LOADGEN_BIN = undef if defined $LOADGEN_BIN && !-x $LOADGEN_BIN;
unless (defined $LOADGEN_BIN) {
    my $sibling = '../../../pgedge-loadgen/bin/pgedge-loadgen';
    $LOADGEN_BIN = $sibling if -x $sibling;
}
unless (defined $LOADGEN_BIN) {
    for my $dir (split(':', $ENV{PATH} // '')) {
        my $c = "$dir/pgedge-loadgen";
        if (-x $c) { $LOADGEN_BIN = $c; last; }
    }
}
unless (defined $LOADGEN_BIN) {
    plan skip_all => 'pgedge-loadgen not found (set PGEDGE_LOADGEN_BIN, ' .
        'or check out https://github.com/pgEdge/pgedge-loadgen next to ' .
        'this spock checkout and run "make build" there)';
}

pass("spock_create_subscriber binary found");

# =============================================================================
# Load level: light (default), medium, or heavy -- controls the number of
# concurrent pgedge-loadgen connections hammering n1 during each join.
# =============================================================================
my %LOAD_CONNECTIONS = (light => 2, medium => 10, heavy => 25);
my $load_level = lc($ENV{SPOCK_BIDIR_LOAD_LEVEL} // 'light');
BAIL_OUT("SPOCK_BIDIR_LOAD_LEVEL must be light, medium, or heavy (got '$load_level')")
    unless exists $LOAD_CONNECTIONS{$load_level};
my $load_connections = $LOAD_CONNECTIONS{$load_level};
diag("load level: $load_level ($load_connections connections)");

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
my $n3_provider_uri =
    "postgres://$db_user:$db_password\@$host:$node_ports->[0]/$dbname?sslmode=disable";

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

# =============================================================================
# Fork cmd into the background, redirecting its output to $logfile. Returns
# the child PID immediately without waiting for it to finish.
# =============================================================================
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

# Block (with a bound) until $pid exits; returns its exit code, or undef if
# it did not exit within $timeout seconds.
sub wait_for_pid {
    my ($pid, $timeout) = @_;
    for (1 .. $timeout) {
        my $r = waitpid($pid, WNOHANG);
        return ($? >> 8) if $r == $pid;
        sleep(1);
    }
    return undef;
}

# Send SIGTERM and wait (with a bound) for a clean exit -- pgedge-loadgen's
# run command drains in-flight queries and closes connections on SIGTERM,
# then exits 0 (confirmed empirically: no forced-kill path needed here).
sub stop_loadgen {
    my ($pid) = @_;
    return unless defined $pid;
    kill('TERM', $pid);
    my $rc = wait_for_pid($pid, 30);
    unless (defined $rc) {
        diag("loadgen pid $pid did not exit after SIGTERM+30s; sending KILL");
        kill('KILL', $pid);
        waitpid($pid, 0);
    }
}

# The pending-cleanup sidecar is deliberately ephemeral: it exists only
# between source-slot creation and the real manifest being written (which
# immediately unlinks it, superseded) -- run_basebackup_and_write_manifest()
# always writes the real manifest before removing the sidecar, so there is
# no gap where neither exists. On fast local disks that whole window can
# be well under a second (a small basebackup finishing before the next
# 1-second poll even runs), so polling for the sidecar alone can miss it
# entirely on a successful join even though the slot really was created;
# checking for either file closes that race. (A failed backup, e.g.
# scenario 2 below, never reaches the manifest write, so the sidecar
# alone stays present there for as long as it takes for this to notice.)
sub wait_for_slot_created {
    my ($pending_path, $manifest_path, $timeout) = @_;
    for (1 .. $timeout) {
        return 1 if -f $pending_path || -f $manifest_path;
        sleep(1);
    }
    return 0;
}

# check_preconditions()'s own zero-lag requirement, polled from here so we
# never launch --bidirectional while it would be doomed to fail on it.
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

# The wholesale (TPC-C-like) schema's 9 tables and their primary-key
# columns, used both to pick a drain signal and to build an ORDER BY for
# the content-hash check below (string_agg's row order is otherwise
# undefined, which would make two nodes with identical data hash
# differently).
my @wholesale_tables = qw(warehouse district customer history item stock
                           orders new_orders order_line);
my %TABLE_PK = (
    warehouse  => 'w_id',
    district   => 'd_w_id, d_id',
    customer   => 'c_w_id, c_d_id, c_id',
    history    => 'h_id',
    item       => 'i_id',
    stock      => 's_w_id, s_i_id',
    orders     => 'o_w_id, o_d_id, o_id',
    new_orders => 'no_w_id, no_d_id, no_o_id',
    order_line => 'ol_w_id, ol_d_id, ol_o_id, ol_number',
);

# Poll $table's row count on $node_b until it matches $node_a's (bounded);
# used to let replication drain before a data comparison, since while a
# load generator is active a node's row counts are a moving target.
sub wait_for_table_drain {
    my ($node_a, $node_b, $table, $timeout) = @_;
    $timeout //= 120;
    my $count_a = scalar_query($node_a, "SELECT COUNT(*) FROM $table");
    for (1 .. $timeout) {
        my $count_b = scalar_query($node_b, "SELECT COUNT(*) FROM $table");
        return 1 if defined $count_b && $count_b eq $count_a;
        sleep(1);
    }
    return 0;
}

# Compare every wholesale table between two nodes: row count, and a full
# content hash (md5 of every row's text representation, concatenated in
# primary-key order) -- two assertions per table. Row count alone would
# miss a bug that swapped or corrupted row content without changing the
# row total; hashing every table (not just one) closes that gap.
sub verify_data_consistency {
    my ($node_a, $label_a, $node_b, $label_b) = @_;
    for my $t (@wholesale_tables) {
        my $count_a = scalar_query($node_a, "SELECT COUNT(*) FROM $t");
        my $count_b = scalar_query($node_b, "SELECT COUNT(*) FROM $t");
        is($count_b, $count_a, "row count matches between $label_a and $label_b: $t");

        my $pk = $TABLE_PK{$t};
        my $hash_query = "SELECT md5(COALESCE(string_agg(x::text, ',' " .
            "ORDER BY $pk), '')) FROM $t x";
        my $hash_a = scalar_query($node_a, $hash_query);
        my $hash_b = scalar_query($node_b, $hash_query);
        is($hash_b, $hash_a,
           "content hash matches between $label_a and $label_b: $t");
    }
}

# =============================================================================
# SETUP: seed n1 with the wholesale (TPC-C-like) schema+data via
# pgedge-loadgen -- 9 tables, every one with an explicit primary key (so
# every table gets a usable REPLICA IDENTITY), ~600k rows, ~120MB. The
# --size floor for this app does not shrink below that regardless of the
# value passed, so a fixed small value is used for every load level; only
# the concurrency of the later `run` phase varies by level.
# =============================================================================
my $loadgen_log = "$log_dir/pgedge_loadgen.log";
unlink($loadgen_log) if -f $loadgen_log;

command_ok(
    [ $LOADGEN_BIN, 'init', '--app', 'wholesale', '--size', '20MB',
      '--drop-existing', '--connection', $n3_provider_uri,
      '--log-level', 'warn' ],
    'loadgen schema+data initialized on n1'
);

# Marker table for the final bidirectional-dataflow proof below, kept
# separate from the loadgen tables so that check does not depend on any of
# pgedge-loadgen's own FK/PK shapes.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE load_test_marker (id serial primary key, val text)";
pass('marker table created on n1');

# Wait for the full initial bulk load (schema DDL + ~600k rows) to drain to
# n2 before touching anything else -- item is untouched by the `run`
# workload later, so its count is a clean, stable proxy for "the bulk load
# has fully replicated".
my $item_count_n1 = scalar_query(1, "SELECT COUNT(*) FROM item");
my $item_on_n2 = '-1';
for (1 .. 180) {
    $item_on_n2 = scalar_query(2, "SELECT COUNT(*) FROM item");
    last if $item_on_n2 eq $item_count_n1;
    sleep(1);
}
is($item_on_n2, $item_count_n1, 'loadgen tables replicated to n2');

my $marker_on_n2 = '-1';
for (1 .. 30) {
    $marker_on_n2 = scalar_query(2,
        "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'load_test_marker'");
    last if $marker_on_n2 eq '1';
    sleep(1);
}
is($marker_on_n2, '1', 'marker table replicated to n2');

ok(wait_for_zero_lag(1, 60), 'replication drained before starting scenario 1')
    or BAIL_OUT('n1->n2 replication never drained after the initial bulk load; ' .
                'cannot proceed to --bidirectional under load');

# =============================================================================
# SCENARIO 1: join under load, with a handful of non-default options
# (--stall-timeout, --max-wait, and a valid --extra-basebackup-args) that
# 070_bidir_plumbing.pl only ever exercises against a quiescent cluster.
# =============================================================================
my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_load_s1';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";

remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_pending) if -f $n3_pending;

# n3's postgresql.conf is copied verbatim from n1 by the basebackup, port and
# all; override it with n3's own port, same as 070_bidir_plumbing.pl.
my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.load';
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

my $scs_log_1 = "$log_dir/scs_scenario1.log";
unlink($scs_log_1) if -f $scs_log_1;

my $scs_pid = spawn_background($scs_log_1,
    $SCS_BIN,
    '--bidirectional',
    '--pgdata',                 $n3_datadir,
    '--subscriber-name',        'n3',
    '--provider-dsn',           $n1_dsn,
    '--subscriber-dsn',         $n3_dsn,
    '--postgresql-conf',        $n3_conf,
    '--stall-timeout',          '120',
    '--max-wait',               '600',
    '--extra-basebackup-args',  '--label=spock_bidir_load_test',
    '-v',
);

ok(wait_for_slot_created($n3_pending, $n3_manifest, 30),
   'source slot created (safe to resume load)')
    or BAIL_OUT('spock_create_subscriber never created the source slot; see ' . $scs_log_1);

my $loadgen_run_log_1 = "$log_dir/pgedge_loadgen_run_s1.log";
unlink($loadgen_run_log_1) if -f $loadgen_run_log_1;
my $loadgen_pid = spawn_background($loadgen_run_log_1,
    $LOADGEN_BIN, 'run', '--app', 'wholesale',
    '--connections', $load_connections,
    '--profile', 'global',
    '--report-interval', '30',
    '--connection', $n3_provider_uri,
    '--log-level', 'info',
);

my $scs_rc_1 = wait_for_pid($scs_pid, 780);
unless (defined $scs_rc_1) {
    diag("spock_create_subscriber (scenario 1) did not exit within 780s; killing it");
    kill('TERM', $scs_pid);
    waitpid($scs_pid, 0);
    $scs_rc_1 = -1;
}
is($scs_rc_1, 0, "--bidirectional (under $load_level load) exits 0")
    or diag("see $scs_log_1 and $loadgen_run_log_1");

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

# Stop the load generator and let replication fully drain -- to both n3
# (the node that just joined) and n2 (the pre-existing peer, which has
# been receiving the same load-driven writes the whole time) -- before
# comparing data; while `run` is active, row counts are a moving target.
# order_line sees the heaviest per-transaction churn (new_order inserts
# several rows per order), so it is used as the drain signal for the
# whole batch on each node.
stop_loadgen($loadgen_pid);

diag('replication did not fully drain to n3 within 120s after stopping the load generator')
    unless wait_for_table_drain(1, 3, 'order_line');
diag('replication did not fully drain to n2 within 120s after stopping the load generator')
    unless wait_for_table_drain(1, 2, 'order_line');

verify_data_consistency(1, 'n1', 3, 'n3');
verify_data_consistency(1, 'n1', 2, 'n2');

# Fresh bidirectional dataflow, now that the join is fully settled and load
# has stopped -- proves the mesh is genuinely live, not just "exited 0".
# Explicit, non-colliding ids: load_test_marker's serial sequence is local
# to each node (its value isn't part of what a join round-trips), so an
# id-less insert on n3 and then on n1 would both independently produce
# id=1 and collide once the n3-side row replicates back -- the same pitfall
# 070_bidir_plumbing.pl documents and works around for pr4_peer_tbl.
system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c',
    "INSERT INTO load_test_marker (id, val) VALUES (2000, 'from_n3_after_load_join')";
my $marker_on_n1 = '0';
for (1 .. 30) {
    $marker_on_n1 = scalar_query(1,
        "SELECT COUNT(*) FROM load_test_marker WHERE val = 'from_n3_after_load_join'");
    last if $marker_on_n1 eq '1';
    sleep(1);
}
is($marker_on_n1, '1', 'fresh write on n3 reaches n1 (marker table)');

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "INSERT INTO load_test_marker (id, val) VALUES (3000, 'from_n1_after_load_join')";
my $marker_on_n3 = '0';
for (1 .. 30) {
    $marker_on_n3 = scalar_query(3,
        "SELECT COUNT(*) FROM load_test_marker WHERE val = 'from_n1_after_load_join'");
    last if $marker_on_n3 eq '1';
    sleep(1);
}
is($marker_on_n3, '1', 'fresh write on n1 reaches n3 (marker table)');

command_ok(
    [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir ],
    '--cleanup --force (scenario 1 teardown) exits 0'
);
ok(!-d $n3_datadir, 'n3 data directory removed after scenario 1 cleanup');

# =============================================================================
# SCENARIO 2: a join that fails part-way (deliberately broken
# --extra-basebackup-args, same trick as 070_bidir_plumbing.pl) while n1 is
# under load, orphaning a source slot -- then --cleanup --force must
# recover it while that load is still running, not just once it has
# stopped.
# =============================================================================
ok(wait_for_zero_lag(1, 60), 'replication drained before starting scenario 2')
    or BAIL_OUT('n1->n2 replication never drained after scenario 1; ' .
                'cannot proceed to scenario 2');

my $n3_datadir_2 = '/tmp/tmp_spock_node_2_datadir_bidir_load_s2';
my $n3_pending_2 = "${n3_datadir_2}.spock_bidir_pending.json";
# The broken --extra-basebackup-args below means the backup never succeeds
# and the real manifest is never written, so this path never comes into
# existence for this scenario -- present here only for symmetry with
# wait_for_slot_created()'s signature.
my $n3_manifest_2 = "$n3_datadir_2/spock_bidirectional_manifest.json";
remove_tree($n3_datadir_2) if -d $n3_datadir_2;
unlink($n3_pending_2) if -f $n3_pending_2;

my $scs_log_2 = "$log_dir/scs_scenario2.log";
unlink($scs_log_2) if -f $scs_log_2;

my $scs_pid_2 = spawn_background($scs_log_2,
    $SCS_BIN,
    '--bidirectional',
    '--pgdata',                 $n3_datadir_2,
    '--subscriber-name',        'n3',
    '--provider-dsn',           $n1_dsn,
    '--subscriber-dsn',         $n3_dsn,
    '--postgresql-conf',        $n3_conf,
    '--extra-basebackup-args',  '--waldir=/nonexistent_pr3_load_test_waldir',
);

ok(wait_for_slot_created($n3_pending_2, $n3_manifest_2, 30),
   'source slot created for scenario 2 (safe to resume load)')
    or BAIL_OUT('spock_create_subscriber never created the source slot for ' .
                "scenario 2; see $scs_log_2");

my $loadgen_run_log_2 = "$log_dir/pgedge_loadgen_run_s2.log";
unlink($loadgen_run_log_2) if -f $loadgen_run_log_2;
my $loadgen_pid_2 = spawn_background($loadgen_run_log_2,
    $LOADGEN_BIN, 'run', '--app', 'wholesale',
    '--connections', $load_connections,
    '--profile', 'global',
    '--report-interval', '30',
    '--connection', $n3_provider_uri,
    '--log-level', 'info',
);

my $scs_rc_2 = wait_for_pid($scs_pid_2, 120);
unless (defined $scs_rc_2) {
    diag("spock_create_subscriber (scenario 2) did not exit within 120s; killing it");
    kill('TERM', $scs_pid_2);
    waitpid($scs_pid_2, 0);
    $scs_rc_2 = -1;
}
isnt($scs_rc_2, 0,
     'a broken --extra-basebackup-args makes the base backup fail (under load)');

my $slot_after_failed_backup = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
ok($slot_after_failed_backup >= 1,
   'source slot orphaned on n1 after the failed backup (under load)');

# The whole point of this scenario: --cleanup --force must work while n1 is
# still under active write load, not just once it has quiesced.
command_ok(
    [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir_2 ],
    '--cleanup --force recovers the orphaned slot while n1 is under load'
);

stop_loadgen($loadgen_pid_2);

my $slot_after_cleanup = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
is($slot_after_cleanup, '0', 'source slot removed from n1 after cleanup');

remove_tree($n3_datadir_2) if -d $n3_datadir_2;
unlink($n3_pending_2) if -f $n3_pending_2;

# =============================================================================
# SCENARIO 3: join with deliberately injected replication lag on the
# catchup subscription (sub_n3_n1), on top of the same write load as
# scenario 1 -- proving wait_for_catchup()/the coverage barrier's
# stall-timeout logic correctly tolerates a steady, bounded lag (a
# continuous trickle of small LSN advances) rather than mistaking it for a
# stall, and that --max-wait is honored as an upper bound rather than
# fired early.
#
# apply_delay (spock_apply.c) holds each transaction back until
# apply_delay has elapsed past its own origin commit timestamp; the value
# is read from the subscription row only when the apply worker (re)starts
# (spock_apply.c ApplyWorkerMain), so it has no effect until then.
# spock.sub_alter_options(..., '{"apply_delay": "..."}'::jsonb)
# (spock_functions.c) updates the row and forces exactly that reconnect,
# so the delay takes effect from the point of the ALTER forward -- there
# is no CLI flag for this in --bidirectional (--apply-delay only wires
# into the plain, non-bidirectional path), so it is injected here
# directly against n3's catalog once the row exists, polling rather than
# guessing the timing since the row exists (disabled, then enabled) partway
# through the join and there is no external signal for exactly when.
# =============================================================================
ok(wait_for_zero_lag(1, 60), 'replication drained before starting scenario 3')
    or BAIL_OUT('n1->n2 replication never drained after scenario 2; ' .
                'cannot proceed to scenario 3');

my $n3_datadir_3  = '/tmp/tmp_spock_node_2_datadir_bidir_load_s3';
my $n3_pending_3  = "${n3_datadir_3}.spock_bidir_pending.json";
my $n3_manifest_3 = "$n3_datadir_3/spock_bidirectional_manifest.json";
remove_tree($n3_datadir_3) if -d $n3_datadir_3;
unlink($n3_pending_3) if -f $n3_pending_3;

my $scs_log_3 = "$log_dir/scs_scenario3.log";
unlink($scs_log_3) if -f $scs_log_3;

my $apply_delay_seconds = 5;
my $scenario3_start = time();

my $scs_pid_3 = spawn_background($scs_log_3,
    $SCS_BIN,
    '--bidirectional',
    '--pgdata',                 $n3_datadir_3,
    '--subscriber-name',        'n3',
    '--provider-dsn',           $n1_dsn,
    '--subscriber-dsn',         $n3_dsn,
    '--postgresql-conf',        $n3_conf,
    '--stall-timeout',          '120',
    '--max-wait',               '600',
);

ok(wait_for_slot_created($n3_pending_3, $n3_manifest_3, 30),
   'source slot created for scenario 3 (safe to resume load)')
    or BAIL_OUT('spock_create_subscriber never created the source slot for ' .
                "scenario 3; see $scs_log_3");

my $loadgen_run_log_3 = "$log_dir/pgedge_loadgen_run_s3.log";
unlink($loadgen_run_log_3) if -f $loadgen_run_log_3;
my $loadgen_pid_3 = spawn_background($loadgen_run_log_3,
    $LOADGEN_BIN, 'run', '--app', 'wholesale',
    '--connections', $load_connections,
    '--profile', 'global',
    '--report-interval', '30',
    '--connection', $n3_provider_uri,
    '--log-level', 'info',
);

# n3's postgres comes up partway through the join (after the basebackup,
# system-identifier reset, and restart); sub_n3_n1's catalog row exists
# from create_catchup_subscription()'s first (disabled) sub_create call
# onward, well before catchup actually begins, so polling for it and
# firing the ALTER as soon as it appears lands the delay before or very
# early into the catchup wait either way.
ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 120),
   'n3 postgres is running (scenario 3)');

sub set_sub_n3_n1_apply_delay {
    my ($interval_text) = @_;
    my $alter_sql = "SELECT spock.sub_alter_options('sub_n3_n1', " .
        "'{\"apply_delay\": \"${interval_text}\"}'::jsonb)";
    system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c', $alter_sql;
}

my $apply_delay_injected = 0;
for (1 .. 60) {
    my $sub_exists = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
        '-c', "SELECT COUNT(*) FROM spock.subscription WHERE sub_name = 'sub_n3_n1'");
    if (defined $sub_exists && $sub_exists eq '1') {
        set_sub_n3_n1_apply_delay("${apply_delay_seconds} seconds");
        $apply_delay_injected = 1;
        last;
    }
    sleep(1);
}
ok($apply_delay_injected,
   "injected a ${apply_delay_seconds}s apply_delay onto the catchup subscription")
    or BAIL_OUT('sub_n3_n1 never appeared in spock.subscription; see ' . $scs_log_3);

# Hold the delay for a bounded window -- long enough to prove catchup makes
# steady, delayed-but-not-stalled progress under it -- then clear it before
# clear_forwarding() does its own independent sub_alter_options()-triggered
# reconnect on this same subscription. Both apply_delay and the delay's
# 5-second-per-transaction hold-back persist across a reconnect (it is
# read from the subscription row at apply-worker startup, not reset by
# it), so leaving it set would still be in effect when that second,
# independent reconnect happens; clearing it first keeps this scenario a
# clean test of steady-lag tolerance rather than of two independent,
# uncoordinated reconnect triggers landing on the same subscription close
# together, which is a real but different (and separately worth testing)
# scenario.
my $apply_delay_hold_seconds = 15;
diag("holding the ${apply_delay_seconds}s apply_delay for " .
     "${apply_delay_hold_seconds}s before clearing it");
sleep($apply_delay_hold_seconds);
set_sub_n3_n1_apply_delay('0');

# Poll (rather than a single blocking wait_for_pid()) so spock.exception_log
# can be sampled every second while n3 is still reachable -- if the join
# fails, spock_create_subscriber's own die() path may or may not manage to
# stop postgres afterward before this script regains control, so querying
# only after the wait is an unreliable way to see error_message; sampling
# throughout the wait is not.
my $scs_rc_3;
my $last_exception = '';
for (1 .. 780) {
    my $r = waitpid($scs_pid_3, WNOHANG);
    if ($r == $scs_pid_3) {
        $scs_rc_3 = ($? >> 8);
        last;
    }
    # A failing transaction can touch several rows/tables; only one of the
    # resulting exception_log entries carries the real error, the rest are
    # "discarded due to exception" collateral pointing at it via
    # command_counter -- fetch every entry for the latest failing
    # transaction (not just the single most recent row) so the real one is
    # actually visible here rather than possibly being one of the
    # collateral entries.
    my $exc = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A', '-F', ' | ',
        '-c', "SELECT table_name, operation, command_counter, error_message " .
              "FROM spock.exception_log WHERE remote_commit_ts = " .
              "(SELECT max(remote_commit_ts) FROM spock.exception_log) " .
              "ORDER BY command_counter");
    $last_exception = $exc if $exc ne '';
    sleep(1);
}
unless (defined $scs_rc_3) {
    diag("spock_create_subscriber (scenario 3) did not exit within 780s; killing it");
    kill('TERM', $scs_pid_3);
    waitpid($scs_pid_3, 0);
    $scs_rc_3 = -1;
}
is($scs_rc_3, 0,
   "--bidirectional (under $load_level load, with a ${apply_delay_seconds}s catchup apply_delay) exits 0")
    or diag("see $scs_log_3 and $loadgen_run_log_3 -- most recent n3 " .
            "spock.exception_log entry seen during the wait: " .
            ($last_exception ne '' ? $last_exception : '(none captured)'));

# Sanity check that the delay actually had an effect rather than being
# silently ignored (e.g. a typo'd JSON key that sub_alter_options rejected
# without this script noticing) -- the join must have taken at least
# apply_delay_seconds, since the last transaction it needed to catch up to
# is held back by that much from its own commit time.
my $scenario3_elapsed = time() - $scenario3_start;
ok($scenario3_elapsed >= $apply_delay_seconds,
   "scenario 3 took at least ${apply_delay_seconds}s (${scenario3_elapsed}s elapsed), " .
   "confirming the injected apply_delay actually took effect");

stop_loadgen($loadgen_pid_3);

diag('replication did not fully drain to n3 within 120s after stopping the load generator')
    unless wait_for_table_drain(1, 3, 'order_line');
verify_data_consistency(1, 'n1', 3, 'n3');

command_ok(
    [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir_3 ],
    '--cleanup --force (scenario 3 teardown) exits 0'
);
ok(!-d $n3_datadir_3, 'n3 data directory removed after scenario 3 cleanup');

# =============================================================================
# Final sanity: n1 <-> n2 (the pre-existing bidirectional pair) must still be
# healthy after everything above -- proves the load + three join/cleanup
# cycles did not leave the original mesh in a bad state.
# =============================================================================
my $n1n2_ok = wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30)
           && wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 30);
ok($n1n2_ok, 'n1 <-> n2 subscriptions are still replicating after the load run');

# =============================================================================
# CLEANUP
# =============================================================================
unlink($n3_conf) if -f $n3_conf;
destroy_cluster('Cleanup');

done_testing();
