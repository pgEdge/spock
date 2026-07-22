#!/usr/bin/perl
# =============================================================================
# Test: 015_forward_origin_advance.pl - Verify Forward Origin Tracking
# =============================================================================
# This test verifies that when forward_origins='all' is set and a disabled
# subscription is pre-created on the new node to a peer, the apply worker
# on the new node correctly advances that pre-created origin as the peer's
# forwarded transactions arrive during catchup.
#
# Topology:
#   n2 -> n1 -> n3
#         forward_origins='all' only on n3's subscription to n1 -- that is
#         what tells n1 to relay transactions it received from n2, rather
#         than only its own
#
# Roles:
#   n1 = source   — the node n3 actively subscribes to for catchup (enabled,
#                   forward_origins='all'); forwards n2's changes to n3
#   n2 = peer     — existing cluster member whose changes are forwarded
#                   through n1 to n3
#   n3 = new_node — the node being added to the cluster
#
# Expected behavior:
# - Before catchup: n3 pre-creates a disabled subscription to n2 (sub_n3_n2).
#   This creates a named replication origin at LSN 0/0.
# - n2 inserts data; n1 receives it (via sub_n1_n2) and forwards it to n3
#   (via the enabled sub_n3_n1, forward_origins='all')
# - n3 advances the pre-created sub_n3_n2 origin LSN as forwarded n2
#   transactions arrive
# - When sub_enable('sub_n3_n2') fires, the apply worker starts from
#   the correct position — no duplicates, no gaps
# =============================================================================

use strict;
use warnings;
use Test::More tests => 31;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail get_test_config scalar_query psql_or_bail wait_for_sub_status);

# =============================================================================
# SETUP: Create 3-node cluster
# =============================================================================

create_cluster(3, 'Create 3-node cluster');

my $config     = get_test_config();
my $node_ports = $config->{node_ports};
my $dbname     = $config->{db_name};
my $host       = $config->{host};

my $conn_n1 = "host=$host port=$node_ports->[0] dbname=$dbname";
my $conn_n2 = "host=$host port=$node_ports->[1] dbname=$dbname";

# =============================================================================
# TEST: Forward Origin Advance
# =============================================================================

# Create replication sets on all nodes
psql_or_bail(1, "SELECT spock.repset_create('cascade_set')");
psql_or_bail(2, "SELECT spock.repset_create('cascade_set')");
psql_or_bail(3, "SELECT spock.repset_create('cascade_set')");
pass('Created replication sets');

# Create test table on all nodes
psql_or_bail(1, "CREATE TABLE test_origin (id serial primary key, val text)");
psql_or_bail(2, "CREATE TABLE test_origin (id serial primary key, val text)");
psql_or_bail(3, "CREATE TABLE test_origin (id serial primary key, val text)");
pass('Created test table on all nodes');

# Add table to replication sets
psql_or_bail(1, "SELECT spock.repset_add_table('cascade_set', 'test_origin')");
psql_or_bail(2, "SELECT spock.repset_add_table('cascade_set', 'test_origin')");
psql_or_bail(3, "SELECT spock.repset_add_table('cascade_set', 'test_origin')");
pass('Added table to replication sets');

# n1 subscribes to n2, an ordinary subscription. n2's own commits carry no
# origin (InvalidRepOriginId, since n2 has no upstream peer of its own in
# this test) and are never filtered by forward_origins regardless of its
# setting, so this leg does not need it.
psql_or_bail(1, "SELECT spock.sub_create('sub_n1_n2', '$conn_n2', ARRAY['cascade_set'], false, false)");
pass('Created subscription n1->n2');

# n3 subscribes to n1 (the source) for catchup.  forward_origins='all' here
# is what tells n1's output plugin to also include transactions n1 itself
# received from n2 (tagged with n2's origin), rather than only n1's own.
psql_or_bail(3, "SELECT spock.sub_create('sub_n3_n1', '$conn_n1', ARRAY['cascade_set'], false, false, ARRAY['all'])");
pass('Created subscription n3->n1 with forward_origins=all');

# Pre-create a disabled subscription on n3 to peer n2 before catchup begins.
# sub_create(enabled=false) creates a named replication origin on n3 at LSN 0/0
# without starting an apply worker.  track_forward_peer_origin()/
# maybe_advance_forwarded_origin() advance it as forwarded n2 transactions
# arrive, so that sub_enable('sub_n3_n2') starts from the correct LSN.
psql_or_bail(3, "SELECT spock.sub_create(
    subscription_name := 'sub_n3_n2',
    provider_dsn      := '$conn_n2',
    replication_sets  := ARRAY['cascade_set'],
    synchronize_structure := false,
    synchronize_data  := false,
    enabled           := false
)");
pass('Pre-created disabled subscription n3->n2');

# sub_create(enabled=false) creates the catalog entry and replication origin
# but not a slot on the provider.  In the real join flow, spock_create_subscriber
# handles slot creation.  Create it directly here so sub_enable() can start the
# apply worker.
my $sub_n3_n2_slot = scalar_query(3,
    "SELECT spock.spock_gen_slot_name(current_database()::name, 'n2'::name, 'sub_n3_n2'::name)");
psql_or_bail(2, "SELECT pg_create_logical_replication_slot('$sub_n3_n2_slot', 'spock_output')");

ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30),
   'Subscription n1->n2 is replicating');
ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 30),
   'Subscription n3->n1 is replicating');

my $sub_disabled = scalar_query(3, "SELECT 1 FROM spock.sub_show_status() WHERE subscription_name = 'sub_n3_n2' AND status = 'disabled'");
is($sub_disabled, '1', 'Subscription sub_n3_n2 is disabled on n3');

# Insert data on n2 — will be forwarded through n1 to n3
psql_or_bail(2, "INSERT INTO test_origin (val) VALUES ('from_n2')");
system_or_bail 'sleep', '5';

my $count_n3 = scalar_query(3, "SELECT COUNT(*) FROM test_origin WHERE val = 'from_n2'");
is($count_n3, '1', 'Data from n2 reached n3 via n1');

# =============================================================================
# KEY TEST: Check that n3's pre-created origin for n2 has been advanced
# =============================================================================
# sub_create(enabled=false) created the origin at 0/0.
# As forwarded n2 transactions arrive on n3, maybe_advance_forwarded_origin()
# looks up sub_n3_n2 by n2's node OID and advances its named origin.
# When sub_enable('sub_n3_n2') fires, the apply worker reads this origin
# and starts replication from the already-advanced position.

my $expected_origin = scalar_query(3,
    "SELECT spock.spock_gen_slot_name(current_database()::name, 'n2'::name, 'sub_n3_n2'::name)");
diag("Expected forwarded origin name on n3: $expected_origin");

my $origin_exists = scalar_query(3,
    "SELECT COUNT(*) FROM pg_replication_origin WHERE roname = '$expected_origin'");
diag("Origin '$expected_origin' exists on n3: $origin_exists");
is($origin_exists, '1', "n3 has replication origin for forwarded n2 ($expected_origin)");

my $origin_lsn = scalar_query(3,
    "SELECT COALESCE(s.remote_lsn::text, 'NULL')
     FROM pg_replication_origin o
     LEFT JOIN pg_replication_origin_status s ON o.roident = s.local_id
     WHERE o.roname = '$expected_origin'");
diag("Origin '$expected_origin' LSN on n3: $origin_lsn");
ok($origin_lsn ne '0/0' && $origin_lsn ne 'NULL' && $origin_lsn ne '',
    "Origin $expected_origin has been advanced (LSN is valid)");

# =============================================================================
# GAP DETECTION TEST: Demonstrate origin tracking enables gap detection
# =============================================================================

diag("=== GAP DETECTION TEST: Origin tracking enables gap detection ===");

psql_or_bail(2, "INSERT INTO test_origin (val) VALUES ('batch2_row1')");
psql_or_bail(2, "INSERT INTO test_origin (val) VALUES ('batch2_row2')");
system_or_bail 'sleep', '3';

my $count_after_batch2 = scalar_query(3, "SELECT COUNT(*) FROM test_origin");
diag("Row count on n3 after batch 2: $count_after_batch2");
is($count_after_batch2, '3', 'n3 has 3 rows after batch 2');

my $c_origin_lsn = scalar_query(3,
    "SELECT COALESCE(s.remote_lsn::text, 'not_tracked')
     FROM pg_replication_origin o
     LEFT JOIN pg_replication_origin_status s ON o.roident = s.local_id
     WHERE o.roname = '$expected_origin'");
diag("n3's tracked LSN for n2 (origin '$expected_origin'): $c_origin_lsn");

ok($c_origin_lsn ne 'not_tracked' && $c_origin_lsn ne '',
   'n3 can track its position relative to n2 (gap detection enabled)');

# Simulate gap: disable n1->n2, insert on n2, check origin does not advance
diag("Creating gap: disabling n1->n2 subscription...");
psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2')");
system_or_bail 'sleep', '2';

psql_or_bail(2, "INSERT INTO test_origin (val) VALUES ('gap_data')");
system_or_bail 'sleep', '5';

my $c_origin_after_gap = scalar_query(3,
    "SELECT COALESCE(s.remote_lsn::text, 'not_tracked')
     FROM pg_replication_origin o
     LEFT JOIN pg_replication_origin_status s ON o.roident = s.local_id
     WHERE o.roname = '$expected_origin'");
diag("n3's origin LSN (unchanged, gap detected): $c_origin_after_gap");

is($c_origin_after_gap, $c_origin_lsn, 'Gap detected: n3 origin unchanged while n2 advanced');

my $count_with_gap = scalar_query(3, "SELECT COUNT(*) FROM test_origin");
is($count_with_gap, '3', 'n3 still has 3 rows (gap data not received)');

# =============================================================================
# GAP RECOVERY TEST: Re-enable n1->n2 and verify gap data arrives on n3
# =============================================================================

psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2')");
system_or_bail 'sleep', '5';

my $count_after_reenable = scalar_query(3, "SELECT COUNT(*) FROM test_origin");
is($count_after_reenable, '4', 'n3 received gap_data after n1->n2 re-enabled');

my $c_origin_after_reenable = scalar_query(3,
    "SELECT COALESCE(s.remote_lsn::text, 'not_tracked')
     FROM pg_replication_origin o
     LEFT JOIN pg_replication_origin_status s ON o.roident = s.local_id
     WHERE o.roname = '$expected_origin'");
diag("n3's origin LSN after re-enable: $c_origin_after_reenable");
ok($c_origin_after_reenable ne $c_origin_lsn,
   'n3 forwarded origin LSN advanced after gap closed');

# =============================================================================
# SUB_ENABLE TEST: Verify no duplicates when sub_n3_n2 is enabled
# =============================================================================
# The forwarded origin on n3 for n2 has been advanced during cascade catchup.
# When sub_enable('sub_n3_n2') fires, the apply worker calls
# replorigin_session_get_progress() on the pre-created origin and receives
# the forwarded LSN — so it starts replication from that position, skipping
# rows n3 already received via the n1 cascade.  This is the end-to-end proof
# that maybe_advance_forwarded_origin() prevents duplicates.

# Disable the cascade leg so that new rows on n2 can only reach n3 via the
# direct subscription we are about to enable.  Without this, data arriving
# via sub_n3_n1 would mask whether sub_n3_n2 is actually running.
psql_or_bail(3, "SELECT spock.sub_disable('sub_n3_n1')");

psql_or_bail(3, "SELECT spock.sub_enable('sub_n3_n2')");
pass('Enabled direct subscription sub_n3_n2 on n3');

# No-duplicates check: if the apply worker started from 0/0 instead of the
# forwarded LSN, it would re-send all 4 rows already on n3, making the count
# jump to 8.  A stable count of 4 proves the correct start position was used.
system_or_bail 'sleep', '3';
my $count_no_dup = scalar_query(3, "SELECT COUNT(*) FROM test_origin");
is($count_no_dup, '4', 'No duplicates: existing rows not re-sent after sub_enable');

# Insert a new row on n2 and poll for it to arrive on n3.  With sub_n3_n1
# disabled, the only path is sub_n3_n2, so arrival proves that subscription
# is live and replicating.
psql_or_bail(2, "INSERT INTO test_origin (val) VALUES ('via_direct_sub')");
my $direct_arrived = 0;
for my $attempt (1..60) {
    my $cnt = scalar_query(3,
        "SELECT COUNT(*) FROM test_origin WHERE val = 'via_direct_sub'");
    if (defined $cnt && $cnt >= 1) { $direct_arrived = 1; last; }
    sleep 1;
}
ok($direct_arrived, 'sub_n3_n2 is replicating directly from n2 (cascade disabled)');

my $count_after_direct = scalar_query(3, "SELECT COUNT(*) FROM test_origin");
is($count_after_direct, '5', 'n3 has exactly 5 rows via direct sub_n3_n2');

my $direct_row = scalar_query(3,
    "SELECT COUNT(*) FROM test_origin WHERE val = 'via_direct_sub'");
is($direct_row, '1', 'Direct row arrived exactly once on n3');

# =============================================================================
# CLEANUP
# =============================================================================

destroy_cluster('Cleanup');
