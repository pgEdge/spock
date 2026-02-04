#!/usr/bin/perl
# =============================================================================
# Test: 016_crash_recovery_progress.pl - Verify progress survives crash recovery
# =============================================================================
# This test verifies that spock.progress.remote_insert_lsn is correctly
# persisted to WAL and survives crash recovery.
#
# Topology:
#   n1 (provider) -> n2 (subscriber)
#
# Test scenario:
# 1. Create subscription, insert data, verify remote_insert_lsn > 0
# 2. Crash n2 (immediate stop - no clean shutdown)
# 3. Restart n2 and verify remote_insert_lsn is still > 0
#
# Without the fix, remote_insert_lsn would be 0 after crash recovery.
# =============================================================================

use strict;
use warnings;
use Test::More tests => 13;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail system_maybe
                 command_ok get_test_config scalar_query psql_or_bail);

# =============================================================================
# SETUP: Create 2-node cluster
# =============================================================================

create_cluster(2, 'Create 2-node cluster');

my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $pg_bin = $config->{pg_bin};
my $dbname = $config->{db_name};
my $host = $config->{host};

# Connection string for n1
my $conn_n1 = "host=$host port=$node_ports->[0] dbname=$dbname";

# =============================================================================
# TEST: Setup replication and verify progress
# =============================================================================

# Create test table on both nodes (auto-added to default repset via DDL replication)
psql_or_bail(1, "CREATE TABLE test_progress (id serial primary key, val text)");
psql_or_bail(2, "CREATE TABLE test_progress (id serial primary key, val text)");
pass('Created test table on both nodes');

# Create subscription on n2 to n1
psql_or_bail(2, "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', ARRAY['default'], false, false)");
pass('Created subscription n2->n1');

# Wait for subscription to be ready
system_or_bail 'sleep', '5';

my $sub_status = scalar_query(2, "SELECT 1 FROM spock.sub_show_status() WHERE subscription_name = 'sub_n1_n2' AND status = 'replicating'");
is($sub_status, '1', 'Subscription is replicating');

# Insert data on n1
psql_or_bail(1, "INSERT INTO test_progress (val) SELECT 'row_' || g FROM generate_series(1, 100) g");
system_or_bail 'sleep', '3';

# Verify data reached n2
my $count_n2 = scalar_query(2, "SELECT COUNT(*) FROM test_progress");
is($count_n2, '100', 'Data replicated to n2');

# =============================================================================
# KEY TEST: Verify remote_insert_lsn before crash
# =============================================================================

my $insert_lsn_before = scalar_query(2, "SELECT remote_insert_lsn FROM spock.progress WHERE remote_node_id = (SELECT node_id FROM spock.node WHERE node_name = 'n1')");
diag("remote_insert_lsn before crash: $insert_lsn_before");
ok($insert_lsn_before ne '0/0' && $insert_lsn_before ne '', 'remote_insert_lsn is valid before crash');

# =============================================================================
# CRASH: Kill n2 with SIGKILL (simulates crash - no cleanup, no resource.dat)
# =============================================================================

# Get postmaster PID
my $pid_file = "$node_datadirs->[1]/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $postmaster_pid = <$fh>;
chomp($postmaster_pid);
close($fh);

diag("Killing n2 (PID $postmaster_pid) with SIGKILL...");
kill 'KILL', $postmaster_pid;
system_or_bail 'sleep', '2';

# =============================================================================
# RECOVERY: Restart n2
# =============================================================================

diag("Restarting n2...");
system_or_bail "$pg_bin/pg_ctl", 'start', '-D', $node_datadirs->[1], '-l', "$node_datadirs->[1]/logfile", '-w';
system_or_bail 'sleep', '3';

# =============================================================================
# VERIFY: remote_insert_lsn should survive crash recovery
# =============================================================================

my $insert_lsn_after = scalar_query(2, "SELECT remote_insert_lsn FROM spock.progress WHERE remote_node_id = (SELECT node_id FROM spock.node WHERE node_name = 'n1')");
diag("remote_insert_lsn after recovery: $insert_lsn_after");

# The key assertion: remote_insert_lsn should NOT be 0 after crash recovery
ok($insert_lsn_after ne '0/0' && $insert_lsn_after ne '', 'remote_insert_lsn survives crash recovery');

# Verify it's the same or close to the value before crash
is($insert_lsn_after, $insert_lsn_before, 'remote_insert_lsn matches value before crash');

# =============================================================================
# CLEANUP
# =============================================================================

destroy_cluster('Cleanup');
