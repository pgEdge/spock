#!/usr/bin/perl
# =============================================================================
# Test: 048_bidir_join.pl - spock_create_subscriber --bidirectional
# =============================================================================
# Validates the bidirectional node-join procedure end to end: physical
# backup, recovery to a restore point, catalog strip (capture + origin drop
# + guarded DROP EXTENSION), replication-set/table/sequence restore, and
# catchup (disabled-first subscription to the source, disabled placeholder
# subscriptions to every peer, and a wait for n3 to reach a target LSN
# captured on the source) -- stopping short of enabling any direct peer
# subscription (a later step).
#
# Topology:
#   n1 <-> n2   (full bidirectional Spock subscriptions, existing 2-node
#                cluster from create_cluster/cross_wire)
#   n3          a real third PostgreSQL instance built via
#               `spock_create_subscriber --bidirectional`, physically backed
#               up from n1.
#
# Test count breakdown:
#   1  binary found
#   5  create_cluster(2)
#   1  cross_wire n1<->n2
#   1  custom replication set created on n1
#   1  table with row_filter added to custom set on n1
#   1  table with explicit column list added to custom set on n1
#   1  sequence added to custom set on n1
#   1  sequence advanced past its initial value on n1 (setval fidelity check)
#   1  partitioned table (parent + 2 children) added to custom set on n1
#   1  sequence with apostrophe in name added to custom set on n1
#   1  peer-forwarding test table created on n1
#   1  peer-forwarding test table replicated to n2
#   1  --bidirectional exits 0
#   1  n3 postgres is running
#   1  spock extension installed cleanly on n3 (exactly one row)
#   1  n3 has exactly the catchup and peer origins, none leftover from the basebackup
#   1  n3 was given its own system identifier (pg_resetwal), distinct from n1
#   1  spock.readonly is lifted on n3 once the join is fully verified
#   1  custom replication set restored on n3 with correct flags
#   1  table membership restored with correct row_filter
#   1  table membership restored with correct explicit column list
#   1  sequence value restored exactly (last_value)
#   1  sequence is_called restored exactly
#   1  sequence pr3_test_seq is a member of pr3_test_repset on n3
#   1  partitioned table parent + 2 children all present in repset on n3
#   1  apostrophe-named sequence value restored on n3
#   1  apostrophe-named sequence is_called restored on n3
#   1  apostrophe-named sequence is a member of pr3_test_repset on n3
#   1  manifest: source_slot_name populated
#   1  manifest: source_restore_lsn populated
#   1  manifest: node_dsn populated
#   1  source slot exists on n1
#   1  catchup subscription sub_n3_n1 is replicating on n3
#   1  forwarding cleared on sub_n3_n1 after cutover
#   1  direct peer subscription sub_n3_n2 is replicating on n3 after cutover
#   1  peer slot created on n2 during the coverage barrier
#   1  n2's post-cutover write reached n3 via the direct sub_n3_n2 path
#   1  n3's origin for peer n2 advanced via the direct subscription
#   1  reverse subscription sub_n2_n3 is replicating on n2
#   1  reverse subscription sub_n1_n3 is replicating on n1
#   1  n3's post-join write reached the source via sub_n1_n3
#   1  n3's post-join write reached the peer via sub_n2_n3
#   1  --cleanup --force exits 0
#   1  source slot removed from n1 after cleanup
#   1  n3 data directory removed after cleanup --force
#   1  manifest removed after cleanup
#   1  --bidirectional rejects a multi-database request
#   1  --bidirectional aborts when another database on the source has spock configured
#   1  --bidirectional rejects a broken full-mesh topology (disabled subscription)
#   1  --bidirectional rejects mismatched replication-set flags between source and peer
#   1  a broken --extra-basebackup-args makes the base backup fail
#   1  pending-cleanup sidecar written before the failed backup
#   1  pending-cleanup sidecar is mode 0600
#   1  source slot still exists on n1 after the failed backup (orphaned)
#   1  --cleanup --force recovers via the pending sidecar
#   1  source slot removed from n1 via sidecar-based cleanup
#   1  pending-cleanup sidecar removed after cleanup
#   1  a broken backup orphans a slot for the retry-cleanup test
#   1  pending sidecar written for the retry-cleanup test
#   1  --cleanup exits non-zero when the source is unreachable
#   1  pending sidecar retained after an incomplete cleanup
#   1  n1 postgres is running again
#   1  --cleanup --force succeeds once the source is reachable again
#   1  pending sidecar removed once cleanup actually completed
#   1  destroy_cluster
#  ---
#  69  total
# =============================================================================

use strict;
use warnings;
use Test::More tests => 69;
use File::Path qw(remove_tree);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 command_ok system_maybe get_test_config scalar_query
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

my $n1_dsn = "host=$host port=$node_ports->[0] dbname=$dbname"
           . " user=$db_user password=$db_password";

my $n1_sysid = scalar_query(1, "SELECT system_identifier FROM pg_control_system()");

cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 <-> n2 bidirectionally');

# =============================================================================
# Seed n1 with a custom replication set, a table with a row_filter, and a
# sequence, to exercise the catalog capture/restore with non-default state
# rather than just the three built-in sets.
# =============================================================================
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "SELECT spock.repset_create('pr3_test_repset', true, true, true, false)";
pass('custom replication set created on n1');

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE pr3_test_tbl (id serial primary key, region text, value integer)";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "SELECT spock.repset_add_table(set_name := 'pr3_test_repset', " .
    "relation := 'pr3_test_tbl', synchronize_data := false, " .
    "row_filter := 'region = ''east''')";
pass('table with row_filter added to custom set on n1');

# Table with an explicit, non-default column list, to exercise the
# columns := <text[]> restore path (captured/restored as a bare array-
# literal string relying on implicit text[] coercion) -- previously
# untested, so a round-trip regression here could pass silently.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE pr3_test_cols (id serial primary key, region text, " .
    "value integer, secret text)";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "SELECT spock.repset_add_table(set_name := 'pr3_test_repset', " .
    "relation := 'pr3_test_cols', synchronize_data := false, " .
    "columns := ARRAY['id', 'region', 'value'])";
pass('table with explicit column list added to custom set on n1');

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE SEQUENCE pr3_test_seq";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "SELECT spock.repset_add_seq('pr3_test_repset', 'pr3_test_seq')";
pass('sequence added to custom set on n1');

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "SELECT setval('pr3_test_seq', 42, true)";
my $seq_before = scalar_query(1, "SELECT last_value FROM pr3_test_seq");
is($seq_before, '42', 'sequence advanced past its initial value on n1');

# Partitioned table: parent + 2 children get separate captured membership
# rows (that's how include_partitions => true populated them here); restore
# must not try to re-add children a second time via the parent's own
# include_partitions => true call.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE pr3_test_part (id int, region text, PRIMARY KEY (id, region)) PARTITION BY LIST (region)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE pr3_test_part_east PARTITION OF pr3_test_part FOR VALUES IN ('east')";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE pr3_test_part_west PARTITION OF pr3_test_part FOR VALUES IN ('west')";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "SELECT spock.repset_add_table(set_name := 'pr3_test_repset', " .
    "relation := 'pr3_test_part', synchronize_data := false, " .
    "include_partitions := true)";
pass('partitioned table (parent + 2 children) added to custom set on n1');

# Sequence with an apostrophe in its name, to exercise setval() quoting.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    q(CREATE SEQUENCE "weird's_seq");
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    q(SELECT spock.repset_add_seq('pr3_test_repset', '"weird''s_seq"'));
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    q(SELECT setval('"weird''s_seq"', 7, true));
pass('sequence with apostrophe in name added to custom set on n1');

# Table used later to verify n3's origin for peer n2 advances via forwarding.
# Created on n1 only and left to arrive on n2 via DDL replication (creating
# it directly on both sides races the already-established cross-wire DDL
# replay); spock.include_ddl_repset=on adds it to 'default' on each node
# once it lands there.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE pr4_peer_tbl (id serial primary key, val text)";
pass('peer-forwarding test table created on n1');

my $tbl_on_n2 = '0';
for (1 .. 15) {
    $tbl_on_n2 = scalar_query(2,
        "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'pr4_peer_tbl'");
    last if $tbl_on_n2 eq '1';
    sleep(1);
}
is($tbl_on_n2, '1', 'peer-forwarding test table replicated to n2');

# check_preconditions() requires all of n1's outbound replication to have
# caught up (no unreplicated DDL/data still in flight to n2); wait for the
# setup above to drain.
for (1 .. 15) {
    my $lag = scalar_query(1,
        "SELECT COUNT(*) FROM pg_replication_slots" .
        " WHERE slot_type = 'logical' AND plugin = 'spock_output'" .
        " AND (confirmed_flush_lsn IS NULL OR confirmed_flush_lsn < pg_current_wal_lsn())");
    last if defined $lag && $lag eq '0';
    sleep(1);
}

# =============================================================================
# TEST: --bidirectional continues through physical backup / catalog strip /
# repset restore, stopping before the catchup subscription.
# =============================================================================
my $n3_port   = $node_ports->[1] + 1;
my $n3_datadir = '/tmp/tmp_spock_node_2_datadir_bidir_pr3';
my $manifest  = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn    = "host=$host port=$n3_port dbname=$dbname"
              . " user=$db_user password=$db_password";

remove_tree($n3_datadir) if -d $n3_datadir;

# n3's postgresql.conf is copied verbatim from n1 by the basebackup, port and
# all -- since all nodes run on the same host in this test, n3 must be given
# an override with its own port (a real cross-host join wouldn't need this).
my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override';
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
print $conf_fh "log_directory='" . $config->{log_dir} . "'\n";
print $conf_fh "log_filename='00${n3_port}.log'\n";
close $conf_fh;

command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--pgdata',            $n3_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3_dsn,
      '--postgresql-conf',   $n3_conf,
    ],
    '--bidirectional exits 0'
);

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running');

my $ext_count = `$pg_bin/psql -p $n3_port -d $dbname -t -c "SELECT COUNT(*) FROM pg_extension WHERE extname = 'spock'"`;
$ext_count =~ s/\s+//g;
is($ext_count, '1', 'spock extension installed cleanly on n3 (exactly one row)');

# By this point the catchup subscription and the one disabled peer
# subscription (n2) have each created their own origin -- exactly 2, not
# more. Anything beyond that would mean an origin survived from the
# basebackup instead of being dropped by the catalog strip.
my $origin_count = `$pg_bin/psql -p $n3_port -d $dbname -t -c "SELECT COUNT(*) FROM pg_replication_origin"`;
$origin_count =~ s/\s+//g;
is($origin_count, '2',
   'n3 has exactly the catchup and peer origins, none leftover from the basebackup');

my $n3_sysid = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT system_identifier FROM pg_control_system()"`;
$n3_sysid =~ s/\s+//g;
isnt($n3_sysid, $n1_sysid,
     'n3 was given its own system identifier (pg_resetwal), distinct from n1');

my $readonly = `$pg_bin/psql -p $n3_port -d $dbname -t -c "SHOW spock.readonly"`;
$readonly =~ s/\s+//g;
is($readonly, 'off',
   "spock.readonly is lifted on n3 once the join is fully verified");

my $repset_flags = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT replicate_insert, replicate_update, replicate_delete, replicate_truncate FROM spock.replication_set WHERE set_name = 'pr3_test_repset'"`;
$repset_flags =~ s/\s+//g;
is($repset_flags, 't|t|t|f', 'custom replication set restored on n3 with correct flags');

my $row_filter = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT pg_get_expr(rts.set_row_filter, rts.set_reloid) FROM spock.replication_set_table rts JOIN spock.replication_set rs ON rts.set_id = rs.set_id WHERE rs.set_name = 'pr3_test_repset'"`;
$row_filter =~ s/^\s+|\s+$//g;
like($row_filter, qr/region\s*=\s*'east'/, 'table membership restored with correct row_filter');

my $columns = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT rts.set_att_list FROM spock.replication_set_table rts JOIN spock.replication_set rs ON rts.set_id = rs.set_id WHERE rs.set_name = 'pr3_test_repset' AND rts.set_reloid::regclass::text = 'pr3_test_cols'"`;
$columns =~ s/^\s+|\s+$//g;
is($columns, '{id,region,value}',
   'table membership restored with correct explicit column list');

my $seq_last_value = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT last_value FROM pr3_test_seq"`;
$seq_last_value =~ s/\s+//g;
is($seq_last_value, '42', 'sequence value restored exactly (last_value)');

my $seq_is_called = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT is_called FROM pr3_test_seq"`;
$seq_is_called =~ s/\s+//g;
is($seq_is_called, 't', 'sequence is_called restored exactly');

# pr3_test_seq must be an actual member of pr3_test_repset on n3, not just
# have its value restored (a regression here is the sequence-membership bug:
# setval() alone leaves the sequence unpublished).
my $seq_member = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT COUNT(*) FROM spock.replication_set_seq rss JOIN spock.replication_set rs ON rss.set_id = rs.set_id WHERE rs.set_name = 'pr3_test_repset' AND rss.set_seqoid::regclass::text = 'pr3_test_seq'"`;
$seq_member =~ s/\s+//g;
is($seq_member, '1', 'sequence pr3_test_seq is a member of pr3_test_repset on n3');

# Partitioned table: parent + 2 children must all be present as distinct
# memberships (a regression here is include_partitions => true re-adding
# already-captured children and violating the (set_id, set_reloid) PK,
# which would have aborted the join above rather than just miscounting).
my $part_member_count = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT COUNT(*) FROM spock.replication_set_table rts JOIN spock.replication_set rs ON rts.set_id = rs.set_id WHERE rs.set_name = 'pr3_test_repset' AND rts.set_reloid::regclass::text LIKE 'pr3_test_part%'"`;
$part_member_count =~ s/\s+//g;
is($part_member_count, '3', 'partitioned table parent + 2 children all present in repset on n3');

# Sequence with an apostrophe in its name: value/is_called restored and
# membership present, without a SQL syntax error breaking the whole run.
sub psql_capture {
    my (@args) = @_;
    open(my $fh, '-|', "$pg_bin/psql", @args) or die "cannot run psql: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    $out =~ s/^\s+|\s+$//g if defined $out;
    return $out;
}

my $weird_seq_value = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
    '-c', 'SELECT last_value FROM "weird\'s_seq"');
is($weird_seq_value, '7', "apostrophe-named sequence value restored on n3");

my $weird_seq_called = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
    '-c', 'SELECT is_called FROM "weird\'s_seq"');
is($weird_seq_called, 't', "apostrophe-named sequence is_called restored on n3");

my $weird_seq_member = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
    '-c', "SELECT COUNT(*) FROM spock.replication_set_seq rss JOIN spock.replication_set rs ON rss.set_id = rs.set_id WHERE rs.set_name = 'pr3_test_repset' AND rss.set_seqoid::regclass::text = '\"weird''s_seq\"'");
is($weird_seq_member, '1', "apostrophe-named sequence is a member of pr3_test_repset on n3");

# =============================================================================
# Manifest content checks
# =============================================================================
my $manifest_content = '';
if (-f $manifest) {
    open my $fh, '<', $manifest or die "Cannot read manifest: $!";
    local $/;
    $manifest_content = <$fh>;
    close $fh;
}

ok($manifest_content =~ /"source_slot_name":\s*"[^"]+"/,
   'manifest: source_slot_name populated');
ok($manifest_content =~ /"source_restore_lsn":\s*"[0-9A-Fa-f]+\/[0-9A-Fa-f]+"/,
   'manifest: source_restore_lsn populated');
ok($manifest_content =~ /"node_dsn":\s*"[^"]+"/,
   'manifest: node_dsn populated');

my $source_slot_exists = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
ok($source_slot_exists >= 1, 'source slot exists on n1');

# =============================================================================
# TEST: catchup subscription and, after cutover, the direct peer
# subscription are both replicating; a post-cutover write on n2 reaches n3
# via the direct path, advancing n3's origin for n2.
# =============================================================================
my $sub_status = '';
for (1 .. 30) {
    $sub_status = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
        '-c', "SELECT status FROM spock.sub_show_status('sub_n3_n1')");
    last if $sub_status eq 'replicating';
    sleep(1);
}
is($sub_status, 'replicating', 'catchup subscription sub_n3_n1 is replicating on n3');

is(psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
    '-c', "SELECT forward_origins FROM spock.sub_show_status('sub_n3_n1')"),
    '', "forwarding cleared on sub_n3_n1 after cutover");

my $peer_sub_status = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
    '-c', "SELECT status FROM spock.sub_show_status('sub_n3_n2')");
is($peer_sub_status, 'replicating',
   'direct peer subscription sub_n3_n2 is replicating on n3 after cutover');

# Origin name matches what create_disabled_peer_subscriptions() computed for
# sub_n3_n2 (spock_gen_slot_name(dbname, 'n2', 'sub_n3_n2')) -- the same
# value is also the slot name create_peer_slot() created on n2 during the
# coverage barrier.
my $n2_origin_name = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
    '-c', "SELECT spock.spock_gen_slot_name('$dbname', 'n2', 'sub_n3_n2')");

is(psql_capture('-p', $node_ports->[1], '-d', $dbname, '-t', '-A',
    '-c', "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '$n2_origin_name'"),
    '1', 'peer slot created on n2 during the coverage barrier');

my $n2_origin_query =
    "SELECT COALESCE(s.remote_lsn::text, '0/0') FROM pg_replication_origin o " .
    "LEFT JOIN pg_replication_origin_status s ON o.roident = s.local_id " .
    "WHERE o.roname = '$n2_origin_name'";

# Write on n2 after cutover; forwarding is off and the direct sub_n3_n2 is
# enabled, so this reaches n3 directly from n2, not via n1.
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "INSERT INTO pr4_peer_tbl (val) VALUES ('from_n2_post_join')";

my $row_on_n3 = '0';
for (1 .. 30) {
    $row_on_n3 = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
        '-c', "SELECT COUNT(*) FROM pr4_peer_tbl WHERE val = 'from_n2_post_join'");
    last if $row_on_n3 eq '1';
    sleep(1);
}
is($row_on_n3, '1', "n2's post-cutover write reached n3 via the direct sub_n3_n2 path");

my $n2_origin_lsn = psql_capture('-p', $n3_port, '-d', $dbname, '-t', '-A',
    '-c', $n2_origin_query);
isnt($n2_origin_lsn, '0/0', "n3's origin for peer n2 advanced via the direct subscription");

# =============================================================================
# TEST: reverse subscriptions are replicating, and a write on n3 reaches
# both the source and the peer through them -- an external proof,
# independent of the utility's own internal verify_bidirectional_dataflow()
# check.
# =============================================================================
is(psql_capture('-p', $node_ports->[1], '-d', $dbname, '-t', '-A',
    '-c', "SELECT status FROM spock.sub_show_status('sub_n2_n3')"),
    'replicating', 'reverse subscription sub_n2_n3 is replicating on n2');

is(psql_capture('-p', $node_ports->[0], '-d', $dbname, '-t', '-A',
    '-c', "SELECT status FROM spock.sub_show_status('sub_n1_n3')"),
    'replicating', 'reverse subscription sub_n1_n3 is replicating on n1');

# Explicit id: pr4_peer_tbl's serial sequence isn't part of the custom
# repset that gets its value round-tripped onto n3 (only pr3_test_seq and
# the apostrophe-named sequence are), so n3's own local copy of the
# sequence is still at its basebackup-time value and would collide with
# the id the n2-post-join row already claimed via replication.
system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c',
    "INSERT INTO pr4_peer_tbl (id, val) VALUES (1000, 'from_n3_post_join')";

my $row_on_n1 = '0';
for (1 .. 30) {
    $row_on_n1 = scalar_query(1,
        "SELECT COUNT(*) FROM pr4_peer_tbl WHERE val = 'from_n3_post_join'");
    last if $row_on_n1 eq '1';
    sleep(1);
}
is($row_on_n1, '1', "n3's post-join write reached the source via sub_n1_n3");

my $row_on_n2_from_n3 = '0';
for (1 .. 30) {
    $row_on_n2_from_n3 = scalar_query(2,
        "SELECT COUNT(*) FROM pr4_peer_tbl WHERE val = 'from_n3_post_join'");
    last if $row_on_n2_from_n3 eq '1';
    sleep(1);
}
is($row_on_n2_from_n3, '1', "n3's post-join write reached the peer via sub_n2_n3");

# =============================================================================
# TEST: --cleanup --force removes source slot, data directory, and manifest
# =============================================================================
command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--cleanup',
      '--force',
      '--pgdata', $n3_datadir,
    ],
    '--cleanup --force exits 0'
);

my $source_slot_after = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
is($source_slot_after, '0', 'source slot removed from n1 after cleanup');

ok(!-d $n3_datadir, 'n3 data directory removed after cleanup --force');
ok(!-f $manifest, 'manifest removed after cleanup');

# =============================================================================
# TEST: --bidirectional hard-rejects a multi-database request outright,
# rather than silently joining only the first-named database -- all join
# state is per-database.
# =============================================================================
my $multidb_datadir = '/tmp/tmp_spock_node_2_datadir_bidir_pr3_multidb';
remove_tree($multidb_datadir) if -d $multidb_datadir;
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $multidb_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3_dsn,
      '--databases',         "$dbname,postgres"),
   '--bidirectional rejects a multi-database request');
remove_tree($multidb_datadir) if -d $multidb_datadir;

# =============================================================================
# TEST: --bidirectional aborts if the source instance has spock configured
# on another database too, even though that database was never named via
# --databases (check_single_spock_database() must fail closed).
# =============================================================================
system_or_bail "$pg_bin/createdb", '-p', $node_ports->[0], 'pr3_other_db';
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', 'pr3_other_db', '-c',
    "CREATE EXTENSION spock";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', 'pr3_other_db', '-c',
    "SELECT spock.node_create('pr3_other_node', 'dbname=pr3_other_db')";

my $otherdb_datadir = '/tmp/tmp_spock_node_2_datadir_bidir_pr3_otherdb';
remove_tree($otherdb_datadir) if -d $otherdb_datadir;
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $otherdb_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3_dsn),
   '--bidirectional aborts when another database on the source has spock configured');
remove_tree($otherdb_datadir) if -d $otherdb_datadir;

system_maybe "$pg_bin/psql", '-p', $node_ports->[0], '-d', 'pr3_other_db', '-c',
    "SELECT spock.node_drop('pr3_other_node')";
system_maybe "$pg_bin/dropdb", '-p', $node_ports->[0], 'pr3_other_db';

# =============================================================================
# TEST: --bidirectional rejects a broken full-mesh topology -- a disabled
# subscription is not a valid mesh edge, even though it still exists. A
# plain subscription COUNT would not catch this.
# =============================================================================
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SELECT spock.sub_disable('sub_n2_n1', true)";
for (1 .. 15) {
    my $enabled = scalar_query(2,
        "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n2_n1'");
    last if defined $enabled && $enabled eq 'f';
    sleep(1);
}

my $mesh_datadir = '/tmp/tmp_spock_node_2_datadir_bidir_pr3_mesh';
remove_tree($mesh_datadir) if -d $mesh_datadir;
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $mesh_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3_dsn),
   '--bidirectional rejects a broken full-mesh topology (disabled subscription)');
remove_tree($mesh_datadir) if -d $mesh_datadir;

system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SELECT spock.sub_enable('sub_n2_n1', true)";
for (1 .. 15) {
    my $enabled = scalar_query(2,
        "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n2_n1'");
    last if defined $enabled && $enabled eq 't';
    sleep(1);
}

# =============================================================================
# TEST: --bidirectional rejects mismatched replication-set definitions for a
# selected (subscription-referenced) set between source and peer -- a
# repset the forwarding path and a future direct-peer path disagree on can
# permanently drop changes on cutover. DDL replication is disabled for the
# ALTER itself so the mismatch is real and local to n2.
# =============================================================================
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; " .
    "SELECT spock.repset_alter('default', replicate_truncate := false)";

my $repset_mismatch_datadir = '/tmp/tmp_spock_node_2_datadir_bidir_pr3_repset_mismatch';
remove_tree($repset_mismatch_datadir) if -d $repset_mismatch_datadir;
ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $repset_mismatch_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3_dsn),
   '--bidirectional rejects mismatched replication-set flags between source and peer');
remove_tree($repset_mismatch_datadir) if -d $repset_mismatch_datadir;

system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "SET spock.enable_ddl_replication = off; " .
    "SELECT spock.repset_alter('default', replicate_truncate := true)";

# =============================================================================
# TEST: a failed base backup leaves the source slot recoverable via
# --cleanup, even though the real manifest was never written -- a
# pending-cleanup sidecar is persisted right after source slot creation,
# before the backup even starts, since data_dir must stay empty until
# pg_basebackup runs.
# =============================================================================
my $failed_datadir = '/tmp/tmp_spock_node_2_datadir_bidir_pr3_failed';
my $pending_sidecar = "${failed_datadir}.spock_bidir_pending.json";
remove_tree($failed_datadir) if -d $failed_datadir;
unlink($pending_sidecar) if -f $pending_sidecar;

ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $failed_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3_dsn,
      '--extra-basebackup-args', '--waldir=/nonexistent_pr3_test_waldir_xyz'),
   'a broken --extra-basebackup-args makes the base backup fail');

ok(-f $pending_sidecar, 'pending-cleanup sidecar written before the failed backup');

my $sidecar_mode = (stat($pending_sidecar))[2] & 07777;
is(sprintf('%04o', $sidecar_mode), '0600',
   'pending-cleanup sidecar is mode 0600 (may carry a DSN password)');

my $slot_after_failed_backup = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
ok($slot_after_failed_backup >= 1,
   'source slot still exists on n1 after the failed backup (orphaned)');

command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--cleanup',
      '--force',
      '--pgdata', $failed_datadir,
    ],
    '--cleanup --force recovers via the pending sidecar (no real manifest exists)'
);

my $slot_after_sidecar_cleanup = scalar_query(1,
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
is($slot_after_sidecar_cleanup, '0',
   'source slot removed from n1 via sidecar-based cleanup');

ok(!-f $pending_sidecar, 'pending-cleanup sidecar removed after cleanup');
remove_tree($failed_datadir) if -d $failed_datadir;

# =============================================================================
# TEST: an incomplete cleanup (source unreachable) exits non-zero and keeps
# the pending sidecar so it can be retried, instead of unconditionally
# deleting the only retry record.
# =============================================================================
my $retry_datadir = '/tmp/tmp_spock_node_2_datadir_bidir_pr3_retry';
my $retry_sidecar = "${retry_datadir}.spock_bidir_pending.json";
remove_tree($retry_datadir) if -d $retry_datadir;
unlink($retry_sidecar) if -f $retry_sidecar;

ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--pgdata',            $retry_datadir,
      '--subscriber-name',   'n3',
      '--provider-dsn',      $n1_dsn,
      '--subscriber-dsn',    $n3_dsn,
      '--extra-basebackup-args', '--waldir=/nonexistent_pr3_test_waldir_retry'),
   'a broken backup orphans a slot for the retry-cleanup test');
ok(-f $retry_sidecar, 'pending sidecar written for the retry-cleanup test');

my $n1_datadir = $config->{node_datadirs}->[0];
system_or_bail "$pg_bin/pg_ctl", 'stop', '-D', $n1_datadir, '-m', 'fast';

ok(!system_maybe($SCS_BIN,
      '--bidirectional',
      '--cleanup',
      '--force',
      '--pgdata', $retry_datadir),
   '--cleanup exits non-zero when the source is unreachable');
ok(-f $retry_sidecar,
   'pending sidecar retained after an incomplete cleanup (retryable)');

system_or_bail "$pg_bin/pg_ctl", 'start', '-D', $n1_datadir,
    '-l', "$config->{log_dir}/n1_retry_restart.log";
ok(wait_for_pg_ready($host, $node_ports->[0], $pg_bin, 30),
   'n1 postgres is running again');

command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--cleanup',
      '--force',
      '--pgdata', $retry_datadir,
    ],
    '--cleanup --force succeeds once the source is reachable again'
);
ok(!-f $retry_sidecar,
   'pending sidecar removed once cleanup actually completed');
remove_tree($retry_datadir) if -d $retry_datadir;

# =============================================================================
# CLEANUP
# =============================================================================
system_maybe "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS pr3_test_tbl";
system_maybe "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS pr3_test_part";
system_maybe "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS pr3_test_cols";
system_maybe "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "DROP SEQUENCE IF EXISTS pr3_test_seq";
system_maybe "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    q(DROP SEQUENCE IF EXISTS "weird's_seq");
system_maybe "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "SELECT spock.repset_drop('pr3_test_repset')";
unlink($n3_conf) if -f $n3_conf;
destroy_cluster('Cleanup');
