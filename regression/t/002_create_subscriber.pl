use strict;
use warnings;
use Test::More tests => 20;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail system_maybe command_ok get_test_config);

# =============================================================================
# Test: 002_create_subscriber.t - Spock Subscription Creation
# =============================================================================
# This test verifies subscription creation using direct psql commands
# and Spock SQL functions instead of the spock_create_subscriber utility.
#
# Test Coverage:
# - Direct subscription creation using psql and Spock SQL functions
# - Node creation and management
# - Replication set setup
# - Subscription creation and management
# - Data replication verification
# - Node connectivity and accessibility checks
# - Spock extension installation verification
# - Basic subscription functionality validation
# - Cluster setup and teardown
#
# Expected Results:
# - All 14 tests should pass
# - Subscription should be created successfully using psql commands
# - Test data should be created and replicated
# - Both nodes should be running and accessible
# - Spock extension should be installed on both nodes

# Create a 2-node cluster using SpockTest framework
create_cluster(2, 'Create 2-node subscription test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

# Test 1: Verify both nodes are running and accessible
my $node1_running = `$pg_bin/pg_isready -h $host -p $node_ports->[0] -U $db_user`;
is($node1_running =~ /accepting connections/, 1, 'Provider node is running');

my $node2_running = `$pg_bin/pg_isready -h $host -p $node_ports->[1] -U $db_user`;
is($node2_running =~ /accepting connections/, 1, 'Subscriber node is running');

# Test 2: Verify Spock extension is installed on both nodes
my $spock_provider = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT 1 FROM pg_extension WHERE extname = 'spock'"`;
chomp($spock_provider);
$spock_provider =~ s/\s+//g;
is($spock_provider, '1', 'Spock extension installed on provider');

my $spock_subscriber = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT 1 FROM pg_extension WHERE extname = 'spock'"`;
chomp($spock_subscriber);
$spock_subscriber =~ s/\s+//g;
is($spock_subscriber, '1', 'Spock extension installed on subscriber');

# Test 3: Nodes already created by create_cluster() (n1, n2)
# Verify nodes exist
my $n1_exists = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT 1 FROM spock.node WHERE node_name = 'n1'"`;
chomp($n1_exists);
$n1_exists =~ s/\s+//g;
is($n1_exists, '1', 'Node n1 exists');

my $n2_exists = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT 1 FROM spock.node WHERE node_name = 'n2'"`;
chomp($n2_exists);
$n2_exists =~ s/\s+//g;
is($n2_exists, '1', 'Node n2 exists');

# Test 4: Create replication set on provider
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c', "SELECT spock.repset_create('test_repset')";
pass('Replication set created on provider');

# Test 5: Create test table and add to replication set
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "CREATE TABLE test_subscription_data (id serial primary key, name text, value integer)";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[0], '-d', $dbname, '-c', "SELECT spock.repset_add_table('test_repset', 'test_subscription_data')";
pass('Table added to replication set');

# Test 6: Insert test data on provider
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "INSERT INTO test_subscription_data (name, value) VALUES ('test1', 100)";
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "INSERT INTO test_subscription_data (name, value) VALUES ('test2', 200)";

# Test 7: Verify data exists on provider
my $count_provider = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT COUNT(*) FROM test_subscription_data"`;
chomp($count_provider);
$count_provider =~ s/\s+//g;
is($count_provider, '2', 'Provider has test data');

# Test 8: Create subscription using psql command (copy schema and data)
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT spock.sub_create('test_subscription', 'host=$host port=$node_ports->[0] dbname=$dbname user=$db_user password=$db_password', ARRAY['test_repset'], true, true)";

# Test 9: Enable subscription
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT spock.sub_enable('test_subscription')";

# Test 10: Wait for subscription to sync
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT spock.sub_wait_for_sync('test_subscription')";

# Test 11: Verify data replicated to subscriber
my $count_subscriber = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT COUNT(*) FROM test_subscription_data"`;
chomp($count_subscriber);
$count_subscriber =~ s/\s+//g;
is($count_subscriber, '2', 'Subscriber has replicated data');

# Test 12: Verify subscription status (enabled)
my $sub_status = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'test_subscription'"`;
chomp($sub_status);
$sub_status =~ s/\s+//g;
is($sub_status, 't', 'Subscription is enabled');

# Test 13: Insert more data and verify replication
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "INSERT INTO test_subscription_data (name, value) VALUES ('test3', 300)";
system_or_bail "$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT spock.sub_wait_for_sync('test_subscription')";

my $count_subscriber_updated = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT COUNT(*) FROM test_subscription_data"`;
chomp($count_subscriber_updated);
$count_subscriber_updated =~ s/\s+//g;
is($count_subscriber_updated, '3', 'Subscriber has updated replicated data');

# Test 14: Verify nodes still present (n1, n2)
my $provider_node = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT node_name FROM spock.node WHERE node_name = 'n1'"`;
chomp($provider_node);
$provider_node =~ s/\s+//g;
is($provider_node, 'n1', 'Provider node n1 exists');

my $subscriber_node = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT node_name FROM spock.node WHERE node_name = 'n2'"`;
chomp($subscriber_node);
$subscriber_node =~ s/\s+//g;
is($subscriber_node, 'n2', 'Subscriber node n2 exists');

# Clean up (drop our test subscription if present), then destroy cluster
system_maybe("$pg_bin/psql", '-q', '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT spock.sub_drop('test_subscription')");
destroy_cluster('Destroy 2-node subscription test cluster');

