#!/usr/bin/perl
# =============================================================================
# Test: 015_forward_origin_advance.pl - Verify Forward Origin Tracking
# =============================================================================
# This test verifies that when forward_origins='all' is set, the subscriber
# creates and advances a replication origin for the original source node.
#
# Topology:
#   A (n1) -> B (n2) -> C (n3)
#            forward_origins='all' on both subscriptions
#
# Expected behavior:
# - A inserts data
# - B receives from A and forwards to C
# - C should create a replication origin using slot name format:
#   spk_<db>_<source>_<subscriber> (e.g., "spk_regression_n1_n3")
# - C should advance that origin's LSN as it receives forwarded transactions
#
# This test FAILS on 'main' branch (origin not created)
# This test PASSES on 'task/SPOC-228/physical-to-logical-replica' branch
# =============================================================================

use strict;
use warnings;
use Test::More tests => 22;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail system_maybe command_ok get_test_config scalar_query psql_or_bail);

# =============================================================================
# SETUP: Create 3-node cluster
# =============================================================================

create_cluster(3, 'Create 3-node cluster');

my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $pg_bin = $config->{pg_bin};
my $dbname = $config->{db_name};
my $host = $config->{host};

# Connection strings
my $conn_a = "host=$host port=$node_ports->[0] dbname=$dbname";
my $conn_b = "host=$host port=$node_ports->[1] dbname=$dbname";

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

# Create cascade: A -> B -> C
# B subscribes to A with forward_origins='all'
psql_or_bail(2, "SELECT spock.sub_create('sub_a_to_b', '$conn_a', ARRAY['cascade_set'], false, false, ARRAY['all'])");
pass('Created subscription B->A with forward_origins=all');

# C subscribes to B with forward_origins='all'
psql_or_bail(3, "SELECT spock.sub_create('sub_b_to_c', '$conn_b', ARRAY['cascade_set'], false, false, ARRAY['all'])");
pass('Created subscription C->B with forward_origins=all');

# Wait for subscriptions to be ready
system_or_bail 'sleep', '5';

# Verify subscriptions are replicating
my $sub_b = scalar_query(2, "SELECT 1 FROM spock.sub_show_status() WHERE subscription_name = 'sub_a_to_b' AND status = 'replicating'");
is($sub_b, '1', 'Subscription A->B is replicating');

my $sub_c = scalar_query(3, "SELECT 1 FROM spock.sub_show_status() WHERE subscription_name = 'sub_b_to_c' AND status = 'replicating'");
is($sub_c, '1', 'Subscription B->C is replicating');

# Insert data on A - this will be forwarded through B to C
psql_or_bail(1, "INSERT INTO test_origin (val) VALUES ('from_node_a')");
system_or_bail 'sleep', '5';

# Verify data reached C
my $count_c = scalar_query(3, "SELECT COUNT(*) FROM test_origin WHERE val = 'from_node_a'");
is($count_c, '1', 'Data from A reached C via B');

# =============================================================================
# KEY TEST: Check if C has created a replication origin for node A
# =============================================================================
# On main branch: This origin will NOT exist (test fails)
# On fix branch: This origin WILL exist (test passes)
#
# The origin uses slot name format: spk_<db>_<provider>_<subscription>
# e.g., "spk_regression_n1_sub_b_to_c" for forwarded transactions from n1 via sub_b_to_c

my $expected_origin = scalar_query(3, "SELECT spock.spock_gen_slot_name(current_database()::name, 'n1'::name, 'sub_b_to_c'::name)");
diag("Expected forwarded origin name on C: $expected_origin");

my $origin_exists = scalar_query(3, "SELECT COUNT(*) FROM pg_replication_origin WHERE roname = '$expected_origin'");
diag("Origin '$expected_origin' exists on C: $origin_exists");
is($origin_exists, '1', "C has replication origin for forwarded source ($expected_origin)");

# Also verify the origin has a valid LSN (not 0/0)
my $origin_lsn = scalar_query(3, "SELECT COALESCE(s.remote_lsn::text, 'NULL') FROM pg_replication_origin o LEFT JOIN pg_replication_origin_status s ON o.roident = s.local_id WHERE o.roname = '$expected_origin'");
diag("Origin '$expected_origin' LSN on C: $origin_lsn");
ok($origin_lsn ne '0/0' && $origin_lsn ne 'NULL' && $origin_lsn ne '', "Origin $expected_origin has been advanced (LSN is valid)");

# =============================================================================
# GAP DETECTION TEST: Demonstrate origin tracking enables gap detection
# =============================================================================
# This test demonstrates that forwarded origin tracking enables detection of
# unreplicated data during cascade switchover scenarios.
#
# With the fix (forwarded origin tracking):
#   - We can query C's position relative to A via the forwarded origin LSN
#   - We can query A's current position: pg_current_wal_lsn()
#   - If A's LSN > C's tracked LSN, there's unreplicated data (a "gap")
#   - This enables tooling to make informed switchover decisions
#
# Without the fix (main branch):
#   - C has no forwarded origin, so we cannot detect gaps
#   - Switchover is "blind" - we don't know what C has received from A

diag("=== GAP DETECTION TEST: Origin tracking enables gap detection ===");

# Insert more data and let it propagate
psql_or_bail(1, "INSERT INTO test_origin (val) VALUES ('batch2_row1')");
psql_or_bail(1, "INSERT INTO test_origin (val) VALUES ('batch2_row2')");
system_or_bail 'sleep', '3';

# Verify data reached C
my $count_after_batch2 = scalar_query(3, "SELECT COUNT(*) FROM test_origin");
diag("Row count on C after batch 2: $count_after_batch2");
is($count_after_batch2, '3', 'C has 3 rows after batch 2');

# KEY TEST: Query C's tracked position for forwarded origin (only works with fix)
my $c_origin_lsn = scalar_query(3, "SELECT COALESCE(s.remote_lsn::text, 'not_tracked') FROM pg_replication_origin o LEFT JOIN pg_replication_origin_status s ON o.roident = s.local_id WHERE o.roname = '$expected_origin'");
diag("C's tracked LSN for A (origin '$expected_origin'): $c_origin_lsn");

# Query A's current WAL position
my $a_wal_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()::text");
diag("A's current WAL LSN: $a_wal_lsn");

# On fix branch: c_origin_lsn should be a valid LSN (not 'not_tracked')
# On main branch: c_origin_lsn would be 'not_tracked' (query returns nothing)
ok($c_origin_lsn ne 'not_tracked' && $c_origin_lsn ne '',
   'C can track its position relative to A (gap detection enabled)');

# Simulate gap: disable B->A, insert on A, check that we can detect the gap
diag("Creating gap: disabling B->A subscription...");
psql_or_bail(2, "SELECT spock.sub_disable('sub_a_to_b')");
system_or_bail 'sleep', '2';

# Insert data on A that creates a gap (can't reach C)
psql_or_bail(1, "INSERT INTO test_origin (val) VALUES ('gap_data')");
my $a_wal_after_gap = scalar_query(1, "SELECT pg_current_wal_lsn()::text");
diag("A's WAL LSN after gap data: $a_wal_after_gap");

# C's origin LSN should still be at the old position (gap exists)
my $c_origin_after_gap = scalar_query(3, "SELECT COALESCE(s.remote_lsn::text, 'not_tracked') FROM pg_replication_origin o LEFT JOIN pg_replication_origin_status s ON o.roident = s.local_id WHERE o.roname = '$expected_origin'");
diag("C's origin LSN (unchanged, gap detected): $c_origin_after_gap");

# Verify the LSNs show a gap (A advanced, C's tracking hasn't)
# This is the key insight: with origin tracking, we KNOW there's unreplicated data
is($c_origin_after_gap, $c_origin_lsn, 'Gap detected: C origin unchanged while A advanced');

# Clean test: verify C still has 3 rows (gap data didn't arrive)
my $count_with_gap = scalar_query(3, "SELECT COUNT(*) FROM test_origin");
is($count_with_gap, '3', 'C still has 3 rows (gap data not received)');

# =============================================================================
# CLEANUP
# =============================================================================

destroy_cluster('Cleanup');
