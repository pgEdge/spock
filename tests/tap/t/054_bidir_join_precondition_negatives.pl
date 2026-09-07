#!/usr/bin/perl
# =============================================================================
# Test: 054_bidir_join_precondition_negatives.pl
#   spock_create_subscriber --bidirectional -- cheap pre-flight rejections
# =============================================================================
# Design doc spock_bidirectional_final.md section 16 "Negative paths" lists a
# set of preconditions --bidirectional must reject before touching a peer's
# replication slot or the source's data directory.  048_bidir_join.pl already
# covers a broken full-mesh topology and one replication-set flag mismatch;
# this file rounds out the rest of that list with scenarios that don't need
# any pause/injection machinery -- each sets up exactly one bad precondition,
# attempts the join, and asserts a clean, specific rejection, then repairs the
# precondition before moving on so later scenarios start from a known-good
# state.  The final scenario is the one exception: it needs one real
# completed join, to test that a second, colliding join attempt fails clean.
#
# Topology: n1 <-> n2, the same cross-wired 2-node cluster 048 uses.
#
# Test count breakdown:
#    1  binary found
#    5  create_cluster(2)
#    1  cross_wire n1<->n2
#   -- Scenario 1: peer unreachable at discovery
#    1  --bidirectional rejects an unreachable peer
#    1  rejection reports the mesh edge to the down peer as unhealthy
#    1  n2 postgres is running again
#   -- Scenario 2: track_commit_timestamp=off on the source (SKIPPED -- see
#      comment at the scenario: no legal spock.conflict_resolution value
#      permits track_commit_timestamp=off in this build, so no live node
#      exists to test this precondition against)
#    2  skip
#   -- Scenario 3: track_commit_timestamp=off on a peer (SKIPPED, same reason)
#    2  skip
#   -- Scenario 4: Spock version too old
#    1  --bidirectional rejects a too-old Spock version on the source
#    1  --bidirectional rejects a too-old Spock version on a peer
#   -- Scenario 5: source has unreplicated changes pending to an existing peer
#    1  --bidirectional rejects source with undrained outbound lag to a peer
#   -- Scenario 6: P0.5 filter-equivalence, remaining sub-cases
#    1  --bidirectional rejects a repset table-membership mismatch
#    1  --bidirectional rejects a repset row_filter mismatch
#    1  --bidirectional rejects a repset sequence-membership mismatch
#   -- Scenario 7: idempotent double-invocation
#    1  first --bidirectional join (minimal, no custom repset seeding) exits 0
#    1  n3a postgres is running
#    1  second --bidirectional join reusing the subscriber name "n3" is rejected
#    1  the first n3's own subscription to the source is still replicating
#    1  no duplicate "n3" node row was left behind on the source
#    1  --cleanup --force removes the first join's state
#    1  destroy_cluster
#  ---
#   27  total
# =============================================================================

use strict;
use warnings;
use Test::More tests => 27;
use File::Path qw(remove_tree);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 command_ok system_maybe get_test_config scalar_query
                 wait_for_sub_status
                 psql_or_bail wait_for_pg_ready);

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
my $log_file    = $config->{log_file};
my $n1_datadir  = $config->{node_datadirs}->[0];
my $n2_datadir  = $config->{node_datadirs}->[1];

my $n1_dsn = "host=$host port=$node_ports->[0] dbname=$dbname"
           . " user=$db_user password=$db_password";
my $n2_dsn = "host=$host port=$node_ports->[1] dbname=$dbname"
           . " user=$db_user password=$db_password";

cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 <-> n2 bidirectionally');

sub psql_capture {
    my (@args) = @_;
    open(my $fh, '-|', "$pg_bin/psql", @args) or die "cannot run psql: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    $out =~ s/^\s+|\s+$//g if defined $out;
    return $out;
}

# The die() message for every rejection below lands in this test's own log
# file (SpockTest.pm redirects every child process's stderr there), not on
# the console -- read it back after each system_maybe() to verify *why* the
# join was rejected, not just that it was.
sub log_tail_has {
    my ($pattern, $since_bytes) = @_;
    open(my $fh, '<', $log_file) or return '';
    seek($fh, $since_bytes, 0);
    local $/;
    my $tail = <$fh> // '';
    close $fh;
    return $tail =~ $pattern;
}
sub log_size {
    return -s $log_file // 0;
}

# Wait for n1's outbound replication to n2 to fully drain (the same
# precondition check() itself performs) before attempting a join, so an
# earlier scenario's DDL/data doesn't leak into a later one's rejection.
sub wait_for_n1_drained {
    for (1 .. 15) {
        my $lag = scalar_query(1,
            "SELECT COUNT(*) FROM pg_replication_slots" .
            " WHERE slot_type = 'logical' AND plugin = 'spock_output'" .
            " AND (confirmed_flush_lsn IS NULL OR confirmed_flush_lsn < pg_current_wal_lsn())");
        return if defined $lag && $lag eq '0';
        sleep(1);
    }
}
wait_for_n1_drained();

my $port_ctr = 0;
sub fresh_datadir {
    $port_ctr++;
    my $dir = "/tmp/tmp_spock_node_2_datadir_bidir_pn_$port_ctr";
    remove_tree($dir) if -d $dir;
    return $dir;
}

# =============================================================================
# Scenario 1: peer unreachable at discovery.  A fully-down peer is caught by
# check_mesh_edges() -- which reads sub_n1_n2's *local* status on n1, not a
# live connection to n2 -- before check_preconditions()'s later per-peer
# connect loop is ever reached, so the actual rejection is the mesh-health
# message, not a distinct "cannot connect" one.  (The narrower race this
# file cannot construct -- n1 still believes sub_n1_n2 is replicating while
# a direct TCP attempt to n2 independently fails -- is what "cannot connect
# to peer" in check_preconditions()/check_replication_set_equivalence()
# actually guards.)
# =============================================================================
note("Scenario 1: peer unreachable at discovery");
system_or_bail "$pg_bin/pg_ctl", 'stop', '-D', $n2_datadir, '-m', 'fast';

my $before = log_size();
my $dir1 = fresh_datadir();
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $dir1,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    "host=$host port=" . ($node_ports->[1] + 100) . " dbname=$dbname"),
   '--bidirectional rejects an unreachable peer');
ok(log_tail_has(qr/no healthy \(status = 'replicating'\) subscription from "n2"/, $before),
   'rejection reports the mesh edge to the down peer as unhealthy');
remove_tree($dir1) if -d $dir1;

system_or_bail "$pg_bin/pg_ctl", 'start', '-D', $n2_datadir,
    '-l', "$config->{log_dir}/n2_scenario1_restart.log";
ok(wait_for_pg_ready($host, $node_ports->[1], $pg_bin, 30), 'n2 postgres is running again')
    or BAIL_OUT('cannot continue without n2 back up');
wait_for_n1_drained();

# =============================================================================
# Scenario 2/3: track_commit_timestamp=off, source then peer.  SKIPPED --
# confirmed genuinely unreachable in this build, not a test-construction
# problem.  spock.conflict_resolution's only enabled enum string is
# "last_update_wins" (SpockConflictResolvers[], spock.c:83-93 -- apply_remote/
# error/keep_local/first_update_wins are all commented out pending upstream
# design work: "Disabled until we can clearly define their desired behavior.
# Jan Wieck 2024-08-12").  spock_conflict_resolver_check_hook()
# (spock_conflict.c:799) rejects last_update_wins whenever
# track_commit_timestamp is off and accepts only apply_remote/error instead
# -- neither of which is a legal GUC value right now.  So no spock-loaded
# postmaster can boot at all with track_commit_timestamp=off in this build
# (confirmed directly: ALTER SYSTEM SET spock.conflict_resolution =
# 'apply_remote' itself fails with "invalid value for parameter
# ... HINT: Available values: last_update_wins.", before the intended
# restart-and-observe-FATAL path is even reached) -- there is no live node
# check_preconditions()'s track_commit_timestamp check can ever be exercised
# against.  Revisit once apply_remote/error are re-enabled.
# =============================================================================
note("Scenario 2: track_commit_timestamp=off on the source");
SKIP: {
    skip 'no legal spock.conflict_resolution value permits track_commit_timestamp'
       . '=off in this build (apply_remote/error are commented out of'
       . ' SpockConflictResolvers[], spock.c:83-93) -- a spock-loaded postmaster'
       . ' cannot boot with it off at all, so this precondition path has no live'
       . ' node to test against', 2;
}

note("Scenario 3: track_commit_timestamp=off on a peer");
SKIP: {
    skip 'same as Scenario 2 -- see comment above', 2;
}

# =============================================================================
# Scenario 4: Spock version too old.  Faked by editing the catalog metadata
# row check_spock_version_at_least_6() reads (pg_extension.extversion) --
# this does not touch the loaded shared library, only the version string the
# precondition check itself trusts, which is exactly the surface being
# tested.  Restored immediately after each attempt.
# =============================================================================
note("Scenario 4: Spock version too old");
my $real_extversion = scalar_query(1, "SELECT extversion FROM pg_extension WHERE extname = 'spock'");

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "UPDATE pg_extension SET extversion = '5.0.11' WHERE extname = 'spock'";
my $dir4a = fresh_datadir();
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $dir4a,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    "host=$host port=" . ($node_ports->[1] + 103) . " dbname=$dbname"),
   '--bidirectional rejects a too-old Spock version on the source');
remove_tree($dir4a) if -d $dir4a;
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "UPDATE pg_extension SET extversion = '$real_extversion' WHERE extname = 'spock'";

system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "UPDATE pg_extension SET extversion = '5.0.11' WHERE extname = 'spock'";
my $dir4b = fresh_datadir();
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $dir4b,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    "host=$host port=" . ($node_ports->[1] + 104) . " dbname=$dbname"),
   '--bidirectional rejects a too-old Spock version on a peer');
remove_tree($dir4b) if -d $dir4b;
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "UPDATE pg_extension SET extversion = '$real_extversion' WHERE extname = 'spock'";

# =============================================================================
# Scenario 5: source has unreplicated changes pending to an existing peer.
# Disabling sub_n2_n1 stops n2 consuming, without needing a full restart;
# a write on n1 then leaves n1's outbound slot to n2 behind.
# =============================================================================
note("Scenario 5: source has undrained outbound lag to an existing peer");
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SELECT spock.sub_disable('sub_n2_n1', true)";
for (1 .. 15) {
    my $enabled = scalar_query(2,
        "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n2_n1'");
    last if defined $enabled && $enabled eq 'f';
    sleep(1);
}
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE pn_lag_probe (id int)";

$before = log_size();
my $dir5 = fresh_datadir();
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $dir5,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    "host=$host port=" . ($node_ports->[1] + 105) . " dbname=$dbname"),
   '--bidirectional rejects source with undrained outbound lag to a peer');
remove_tree($dir5) if -d $dir5;

system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SELECT spock.sub_enable('sub_n2_n1', true)";
for (1 .. 15) {
    my $enabled = scalar_query(2,
        "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n2_n1'");
    last if defined $enabled && $enabled eq 't';
    sleep(1);
}
wait_for_n1_drained();
system_maybe "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS pn_lag_probe";
wait_for_n1_drained();

# =============================================================================
# Scenario 6: P0.5 filter-equivalence, remaining sub-cases.  048_bidir_join.pl
# already proves the flags sub-case (replicate_truncate mismatch on
# 'default'); these three exercise the other independent segments of
# compute_repset_fingerprints()'s per-table string (tbl=...|cols=...|
# filter=...|schema=(...)) and the separate seq=... segment.  Column-list and
# partition-inclusion mismatches are not separately tested here -- they
# differ from the row_filter case only in which substring of the same
# per-table fingerprint changes, not in which code path fires or which die()
# message is reached, so table-membership + row_filter + sequence-membership
# already exercise every independent branch of check_replication_set_
# equivalence() (found on source only, found on peer only, and same-name-
# different-fingerprint).  Only 'default' is checked here because
# build_selected_set_name_filter() restricts comparison to sets an existing
# subscription actually references -- an unreferenced custom set (as seeded
# in 048) is invisible to this check.  DDL replication is turned off for
# each mutating ALTER so the mismatch is real and local to n2, exactly as
# 048's flags test does.
# =============================================================================
note("Scenario 6: repset table-membership mismatch");
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; CREATE TABLE pn_extra_tbl (id int PRIMARY KEY)";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; " .
    "SELECT spock.repset_add_table('default', 'pn_extra_tbl', synchronize_data := false)";

my $dir6a = fresh_datadir();
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $dir6a,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    "host=$host port=" . ($node_ports->[1] + 106) . " dbname=$dbname"),
   '--bidirectional rejects a repset table-membership mismatch');
remove_tree($dir6a) if -d $dir6a;

system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; " .
    "SELECT spock.repset_remove_table('default', 'pn_extra_tbl')";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; DROP TABLE pn_extra_tbl";

note("Scenario 6: repset row_filter mismatch");
# CREATE TABLE runs with DDL replication ON (unlike the table-membership
# case above), specifically so it reaches n2 -- but autoddl capture
# (spock_autoddl.c) auto-adds a newly created table to 'default' on BOTH
# nodes as part of applying that same DDL, with no filter on either side.
# An explicit repset_add_table() on n1 here would just collide with that
# auto-membership (duplicate key on replication_set_table_pkey) -- so skip
# it and let auto-membership do the (filter-less, matching) add on n1;
# the wait loop below confirms n2 got the same auto-add.  The actual
# mismatch is then made by remove+re-add *on n2 only*, DDL replication off.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE pn_filter_tbl (id int PRIMARY KEY, region text)";
for (1 .. 15) {
    my $present = scalar_query(2,
        "SELECT COUNT(*) FROM spock.replication_set_table rts" .
        " JOIN spock.replication_set rs ON rts.set_id = rs.set_id" .
        " WHERE rs.set_name = 'default' AND rts.set_reloid::regclass::text = 'pn_filter_tbl'");
    last if defined $present && $present eq '1';
    sleep(1);
}
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; " .
    "SELECT spock.repset_remove_table('default', 'pn_filter_tbl')";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; " .
    "SELECT spock.repset_add_table('default', 'pn_filter_tbl', synchronize_data := false, " .
    "row_filter := 'id > 0')";

my $dir6b = fresh_datadir();
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $dir6b,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    "host=$host port=" . ($node_ports->[1] + 107) . " dbname=$dbname"),
   '--bidirectional rejects a repset row_filter mismatch');
remove_tree($dir6b) if -d $dir6b;

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "DROP TABLE pn_filter_tbl";
for (1 .. 15) {
    my $gone = scalar_query(2, "SELECT to_regclass('pn_filter_tbl') IS NULL");
    last if defined $gone && $gone eq 't';
    sleep(1);
}

note("Scenario 6: repset sequence-membership mismatch");
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; CREATE SEQUENCE pn_extra_seq";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; " .
    "SELECT spock.repset_add_seq('default', 'pn_extra_seq')";

my $dir6c = fresh_datadir();
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $dir6c,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    "host=$host port=" . ($node_ports->[1] + 108) . " dbname=$dbname"),
   '--bidirectional rejects a repset sequence-membership mismatch');
remove_tree($dir6c) if -d $dir6c;

system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; " .
    "SELECT spock.repset_remove_seq('default', 'pn_extra_seq')";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; DROP SEQUENCE pn_extra_seq";
wait_for_n1_drained();
# wait_for_n1_drained() only confirms LSN lag has drained, not that
# sub_show_status() itself has settled -- the DROP SEQUENCE/repset_remove_seq
# cycle just above can leave a brief window where a worker is still
# restarting from the DDL and check_mesh_edges() sees a transient non-
# 'replicating' status on one side, which would spuriously fail Scenario 7's
# very first join for a reason that has nothing to do with idempotency.
# Confirmed happening in practice once -- wait for both directions to be
# genuinely settled before relying on the mesh being healthy.
wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30)
    or BAIL_OUT('mesh did not restabilize after Scenario 6 cleanup');
wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 30)
    or BAIL_OUT('mesh did not restabilize after Scenario 6 cleanup');

# =============================================================================
# Scenario 7: idempotent double-invocation.  One real join, left live (no
# --cleanup), then a second attempt reusing the same --subscriber-name "n3"
# against a fresh, empty pgdata.  Whichever check trips it, the join must
# fail rather than leave a duplicate "n3" node or disturb the first n3.
# =============================================================================
note("Scenario 7: idempotent double-invocation");
my $n3a_datadir = fresh_datadir();
my $n3a_port    = $node_ports->[1] + 150;
my $n3a_dsn     = "host=$host port=$n3a_port dbname=$dbname"
                . " user=$db_user password=$db_password";
my $n3a_conf    = '/tmp/tmp_spock_node_2_postgresql.conf.override.n3a';
open my $conf_fh_a, '>', $n3a_conf or die "Cannot write $n3a_conf: $!";
print $conf_fh_a "shared_buffers=1GB\n";
print $conf_fh_a "shared_preload_libraries='spock'\n";
print $conf_fh_a "wal_level=logical\n";
print $conf_fh_a "spock.enable_ddl_replication=on\n";
print $conf_fh_a "spock.include_ddl_repset=on\n";
print $conf_fh_a "spock.allow_ddl_from_functions=on\n";
print $conf_fh_a "spock.exception_behaviour=sub_disable\n";
print $conf_fh_a "spock.conflict_resolution=last_update_wins\n";
print $conf_fh_a "track_commit_timestamp=on\n";
print $conf_fh_a "spock.exception_replay_queue_size='1MB'\n";
print $conf_fh_a "spock.enable_spill=on\n";
print $conf_fh_a "port=$n3a_port\n";
print $conf_fh_a "listen_addresses='*'\n";
print $conf_fh_a "logging_collector=on\n";
print $conf_fh_a "log_directory='" . $config->{log_dir} . "'\n";
print $conf_fh_a "log_filename='00${n3a_port}.log'\n";
close $conf_fh_a;

command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--pgdata',            $n3a_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3a_dsn,
      '--postgresql-conf',   $n3a_conf,
    ],
    'first --bidirectional join (minimal, no custom repset seeding) exits 0'
);
ok(wait_for_pg_ready($host, $n3a_port, $pg_bin, 30), 'n3a postgres is running');

my $n3b_datadir = fresh_datadir();
my $n3b_port    = $node_ports->[1] + 151;
my $n3b_dsn     = "host=$host port=$n3b_port dbname=$dbname"
                . " user=$db_user password=$db_password";

# n3a's own postgres is still running on $n3a_port -- reusing $n3a_conf here
# (which hardcodes that port) would make n3b's postgres either fail to bind
# it (n3a already holds it) or, if it somehow started anyway, listen on a
# port --subscriber-dsn never points at, so --bidirectional's own
# wait_postmaster_connection() polls a port nothing answers on forever.
# n3b needs its own override, identical to n3a's but for its own port.
my $n3b_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.n3b';
open my $conf_fh_b, '>', $n3b_conf or die "Cannot write $n3b_conf: $!";
print $conf_fh_b "shared_buffers=1GB\n";
print $conf_fh_b "shared_preload_libraries='spock'\n";
print $conf_fh_b "wal_level=logical\n";
print $conf_fh_b "spock.enable_ddl_replication=on\n";
print $conf_fh_b "spock.include_ddl_repset=on\n";
print $conf_fh_b "spock.allow_ddl_from_functions=on\n";
print $conf_fh_b "spock.exception_behaviour=sub_disable\n";
print $conf_fh_b "spock.conflict_resolution=last_update_wins\n";
print $conf_fh_b "track_commit_timestamp=on\n";
print $conf_fh_b "spock.exception_replay_queue_size='1MB'\n";
print $conf_fh_b "spock.enable_spill=on\n";
print $conf_fh_b "port=$n3b_port\n";
print $conf_fh_b "listen_addresses='*'\n";
print $conf_fh_b "logging_collector=on\n";
print $conf_fh_b "log_directory='" . $config->{log_dir} . "'\n";
print $conf_fh_b "log_filename='00${n3b_port}.log'\n";
close $conf_fh_b;

ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $n3b_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3b_dsn,
      '--postgresql-conf',   $n3b_conf),
   'second --bidirectional join reusing the subscriber name "n3" is rejected');
remove_tree($n3b_datadir) if -d $n3b_datadir;
unlink($n3b_conf) if -f $n3b_conf;

is(psql_capture('-p', $n3a_port, '-d', $dbname, '-t', '-A',
    '-c', "SELECT status FROM spock.sub_show_status('sub_n3_n1')"),
    'replicating', "the first n3's own subscription to the source is still replicating");

my $node_name_count = scalar_query(1,
    "SELECT COUNT(*) FROM spock.node WHERE node_name = 'n3'");
is($node_name_count, '1', 'no duplicate "n3" node row was left behind on the source');

command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--cleanup',
      '--force',
      '--pgdata', $n3a_datadir,
    ],
    q(--cleanup --force removes the first join's state)
);
unlink($n3a_conf) if -f $n3a_conf;
remove_tree($n3a_datadir) if -d $n3a_datadir;

# =============================================================================
# CLEANUP
# =============================================================================
destroy_cluster('Cleanup');
