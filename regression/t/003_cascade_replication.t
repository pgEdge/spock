# =============================================================================
# Test: 003_cascade_replication.pl - Cascade Replication Configuration
# =============================================================================
# This test verifies cascade replication functionality where data flows
# through multiple nodes in a chain configuration (A -> B -> C).
# This is useful for scenarios where you need to replicate data across
# multiple geographic locations or through intermediate nodes.
#
# Test Coverage:
# - 3-node cluster creation and management (n1, n2, n3)
# - Cascade replication setup (A -> B -> C)
# - Data insertion and replication through the chain
# - Selective replication set management
# - Data verification at each node in the chain
# - Truncate operation and selective replication
# - Subscription management across multiple nodes
# - Cross-node data consistency verification
#
# Expected Results:
# - All 17 tests should pass
# - 3-node cascade cluster should be created successfully
# - Data should replicate correctly through the chain A -> B -> C
# - Selective replication sets should work properly
# - Data should be consistent across all nodes
#
# Bug Reference: RT87453 - test truncate on cascade nodes with different replication sets

use strict;
use warnings;
use Test::More tests => 17;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail command_ok get_test_config);

# Create a 3-node cluster
create_cluster(3, 'Create 3-node cascade test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

# Create different replication sets on nodes
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "SELECT * FROM spock.repset_create('set_a')";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT * FROM spock.repset_create('set_b')";

# Create cascade subscriptions (A -> B -> C)
# Node B subscribes to Node A's set_a
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', 
    "SELECT spock.sub_create('sub_a_b', 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password', ARRAY['set_a'], true, true)";

# Node C subscribes to Node B's set_b
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', 
    "SELECT spock.sub_create('sub_b_c', 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password', ARRAY['set_b'], true, true)";

# Wait for subscriptions to be replicating
system_or_bail 'sleep', '10';

# Create the tables and add them to the correct repset
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "CREATE TABLE a2b(x int primary key)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "SELECT * FROM spock.repset_add_table('set_a', 'a2b', false)";

system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "CREATE TABLE a2b(x int primary key)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "CREATE TABLE b2c(x int primary key)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT * FROM spock.repset_add_table('set_b', 'b2c', false)";

system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "CREATE TABLE a2b(x int primary key)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "CREATE TABLE b2c(x int)";

# Add an INVALID index, then add the real PRIMARY KEY on node C
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "INSERT INTO b2c VALUES (1),(2)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "CREATE UNIQUE INDEX CONCURRENTLY ON b2c(x)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "DELETE FROM b2c";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "ALTER TABLE b2c ADD PRIMARY KEY (x)";

# Insert some rows to check that replication actually worked
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "INSERT INTO a2b VALUES (1)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "INSERT INTO b2c VALUES (1)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "INSERT INTO a2b VALUES (1)";

sleep(2);

# Check that rows are present on all nodes
my $result_a = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT x FROM a2b ORDER BY x"`;
my $result_b = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT x FROM a2b ORDER BY x"`;
my $result_c = `$pg_bin/psql -p $node_ports->[2] -d $dbname -t -c "SELECT x FROM a2b ORDER BY x"`;

chomp($result_a, $result_b, $result_c);
$result_a =~ s/\s+//g;
$result_b =~ s/\s+//g;
$result_c =~ s/\s+//g;
is($result_a, "1", 'row present on node_a');
is($result_b, "1", 'row present on node_b');
is($result_c, "1", 'row present on node_c');

# Test TRUNCATE cascade
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "TRUNCATE TABLE a2b";
sleep(2);

# Check that TRUNCATE cascaded properly
$result_a = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT x FROM a2b ORDER BY x"`;
$result_b = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT x FROM a2b ORDER BY x"`;
$result_c = `$pg_bin/psql -p $node_ports->[2] -d $dbname -t -c "SELECT x FROM a2b ORDER BY x"`;
my $result_c_b2c = `$pg_bin/psql -p $node_ports->[2] -d $dbname -t -c "SELECT x FROM b2c ORDER BY x"`;

chomp($result_a, $result_b, $result_c, $result_c_b2c);
$result_a =~ s/\s+//g;
$result_b =~ s/\s+//g;
$result_c =~ s/\s+//g;
$result_c_b2c =~ s/\s+//g;
is($result_a, "", 'no row present on node_a after truncate');
is($result_b, "", 'no row present on node_b after truncate');
is($result_c, "1", 'row still present on node_c (not in set_b)');
is($result_c_b2c, "1", 'row present on node_c in b2c table');

# Verify subscriptions are still replicating
my $sub_status_a_b = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT status FROM spock.sub_show_status() WHERE subscription_name = 'sub_a_b'"`;
my $sub_status_b_c = `$pg_bin/psql -p $node_ports->[2] -d $dbname -t -c "SELECT status FROM spock.sub_show_status() WHERE subscription_name = 'sub_b_c'"`;

chomp($sub_status_a_b, $sub_status_b_c);
$sub_status_a_b =~ s/\s+//g;
$sub_status_b_c =~ s/\s+//g;
is($sub_status_a_b, "replicating", 'subscription a_b still replicating');
is($sub_status_b_c, "replicating", 'subscription b_c still replicating');

# Clean up specific subscriptions first
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT spock.sub_drop('sub_a_b')";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "SELECT spock.sub_drop('sub_b_c')";

# Clean up
destroy_cluster('Destroy 3-node cascade test cluster');

done_testing();
