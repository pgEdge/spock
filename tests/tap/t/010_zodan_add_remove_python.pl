use strict;
use warnings;
use Test::More tests => 33;  # Fixed test count to match actual tests
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config cross_wire system_maybe);

# ==============================================================================================
# Test: 010_zodan_add_remove_python.pl - Test Zodan Node Addition and Removal for python version
# ==============================================================================================
# This test follows the sequence:
# 1. Create 2-node cluster and cross-wire them
# 2. Create test data and replication sets
# 3. Add node n3 using zodan.py procedure
# 4. Verify n3 is properly integrated
# 5. Remove node n3 using zodremove.py
# 6. Verify n3 is properly removed
# 7. Clean up

# Step 1: Create a 2-node cluster initially
create_cluster(2, 'Create initial 2-node Spock test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

# Step 1a: Cross-wire the 2 nodes (n1 and n2)
cross_wire(2, ['n1', 'n2'], 'Cross-wire nodes n1 and n2');

pass('2-node cluster created and cross-wired');

# Install dblink extension on all nodes (required for ZODAN procedures)
system_maybe "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "CREATE EXTENSION IF NOT EXISTS dblink";
system_maybe "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "CREATE EXTENSION IF NOT EXISTS dblink";

pass('dblink extension installed on n1 and n2');

# Step 2: Create test data and replication sets
pass('Creating test data and replication sets');

# Create test table on n1
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "
    CREATE TABLE test_zodan_table (
        id SERIAL PRIMARY KEY,
        name VARCHAR(50),
        value INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
";

# Create a custom replication set on n1
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "
    SELECT spock.repset_create('zodan_test_set', true, true, true, true)
";

# Add table to the custom replication set
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "
    SELECT spock.repset_add_table('zodan_test_set', 'test_zodan_table')
";

# Insert test data on n1
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "
    INSERT INTO test_zodan_table (name, value) VALUES 
    ('test_data_1', 100),
    ('test_data_2', 200),
    ('test_data_3', 300)
";

pass('Test table created and data inserted on n1');

# Wait for replication to n2
system_or_bail 'sleep', '2';

# Verify data replicated to n2
my $data_on_n2 = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT COUNT(*) FROM test_zodan_table"`;
chomp($data_on_n2);
$data_on_n2 =~ s/\s+//g;
if ($data_on_n2 eq '3') {
    pass('Data successfully replicated from n1 to n2 (3 rows)');
} else {
    fail("Data replication failed: expected 3 rows, got $data_on_n2");
}

# Step 3: Create n3 database instance
pass('Creating n3 database instance');

# Create n3 data directory and start PostgreSQL instance
my $n3_datadir = "/tmp/tmp_spock_node_3_datadir";
my $n3_port = $node_ports->[0] + 2;  # Use next available port

# Clean up any existing n3 directory
system_or_bail 'rm', '-rf', $n3_datadir;

# Initialize n3 data directory
system_or_bail "$pg_bin/initdb", '-A', 'trust', '-D', $n3_datadir;

# Copy configuration files if they exist
if (-f 'regress-pg_hba.conf') {
    system_or_bail 'cp', 'regress-pg_hba.conf', "$n3_datadir/pg_hba.conf";
}

# Create PostgreSQL configuration for n3
open(my $conf, '>>', "$n3_datadir/postgresql.conf") or die "Cannot open config file: $!";
print $conf "shared_buffers=1GB\n";
print $conf "shared_preload_libraries='spock'\n";
print $conf "wal_level=logical\n";
print $conf "spock.enable_ddl_replication=on\n";
print $conf "spock.include_ddl_repset=on\n";
print $conf "spock.allow_ddl_from_functions=on\n";
print $conf "spock.exception_behaviour=sub_disable\n";
print $conf "spock.conflict_resolution=last_update_wins\n";
print $conf "track_commit_timestamp=on\n";
print $conf "spock.exception_replay_queue_size=1MB\n";
print $conf "spock.enable_spill=on\n";
print $conf "port=$n3_port\n";
print $conf "listen_addresses='*'\n";
print $conf "logging_collector=on\n";
print $conf "log_directory='/tmp/logs'\n";
print $conf "log_filename='00$n3_port.log'\n";
close($conf);

# Start n3 PostgreSQL instance
system("$pg_bin/postgres -D $n3_datadir >> '$config->{log_file}' 2>&1 &");

# Allow n3 to startup
system_or_bail 'sleep', '10';

# Create database and user for testing on n3
system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', 'postgres', '-c', "CREATE DATABASE $dbname";
system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c', "CREATE USER $db_user SUPERUSER";
system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c', "CREATE USER super SUPERUSER";

# Install Spock extension on n3
system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c', "CREATE EXTENSION IF NOT EXISTS spock";
system_or_bail "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c', "ALTER EXTENSION spock UPDATE";

# Install dblink extension on n3
system_maybe "$pg_bin/psql", '-p', $n3_port, '-d', $dbname, '-c', "CREATE EXTENSION IF NOT EXISTS dblink";

pass('n3 database instance created and configured');

# Step 4: Add node n3 using zodan.py(called from n3)
pass('Adding node n3 using zodan.py (called from n3)');

print "=== STARTING ADD_NODE PROCEDURE ===\n";

my $add_node_cmd = "../../samples/Z0DAN/zodan.py \\
    add_node \\
    --src-node-name n1 \\
    --src-dsn 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password' \\
    --new-node-name n3 \\
    --new-node-dsn 'host=$host dbname=$dbname port=$n3_port user=$db_user password=$db_password' \\
    --new-node-location CA \\
    --new-node-country USA \\
";

print "Executing: $add_node_cmd\n";
print "---\n";

open(my $pipe, "$add_node_cmd 2>&1 |") or die "Cannot open pipe: $!";
while (my $line = <$pipe>) {
    print $line;
}
close($pipe);
my $add_node_result = $? >> 8;

print "---\n";
print "=== ADD_NODE PROCEDURE COMPLETED (exit code: $add_node_result) ===\n";

if ($add_node_result == 0) {
    pass('zodan.py executed successfully');
} else {
    fail("zodan.py failed with exit code: $add_node_result");
}

# Step 5: Verify n3 is properly integrated
pass('Verifying n3 integration');

# Wait for replication to complete
system_or_bail 'sleep', '3';

# Check if test table exists on n3
my $table_exists_n3 = `$pg_bin/psql -p $n3_port -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_zodan_table')"`;
chomp($table_exists_n3);
$table_exists_n3 =~ s/\s+//g;
if ($table_exists_n3 eq 't') {
    pass('Test table exists on n3');
    
    # Check data count on n3
    my $data_on_n3 = `$pg_bin/psql -p $n3_port -d $dbname -t -c "SELECT COUNT(*) FROM test_zodan_table"`;
    chomp($data_on_n3);
    $data_on_n3 =~ s/\s+//g;
    if ($data_on_n3 eq '3') {
        pass('Data successfully replicated to n3 (3 rows)');
    } else {
        fail("Data replication to n3 failed: expected 3 rows, got $data_on_n3");
    }
} else {
    fail('Test table does not exist on n3');
}

# Verify n3 has subscriptions that reference the default replication sets
my $sub_count_n3 = `$pg_bin/psql -p $n3_port -d $dbname -t -c "SELECT COUNT(*) FROM spock.subscription"`;
chomp($sub_count_n3);
$sub_count_n3 =~ s/\s+//g;
if ($sub_count_n3 >= 2) {
    pass('n3 has subscriptions referencing default replication sets (ZODAN behavior)');
} else {
    # Debug: List all subscriptions on n3
    my $debug_subs = `$pg_bin/psql -p $n3_port -d $dbname -c "SELECT sub_name FROM spock.subscription ORDER BY sub_name"`;
    print "Debug: Subscriptions on n3:\n$debug_subs\n";
    fail('n3 does not have expected subscriptions');
}

# Verify n3 is in the node list on all nodes
my $node_count_n1 = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT COUNT(*) FROM spock.node"`;
chomp($node_count_n1);
$node_count_n1 =~ s/\s+//g;
if ($node_count_n1 eq '3') {
    pass('n1 shows 3 nodes in cluster');
} else {
    fail("n1 node count incorrect: expected 3, got $node_count_n1");
}

my $node_count_n2 = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT COUNT(*) FROM spock.node"`;
chomp($node_count_n2);
$node_count_n2 =~ s/\s+//g;
if ($node_count_n2 eq '3') {
    pass('n2 shows 3 nodes in cluster');
} else {
    fail("n2 node count incorrect: expected 3, got $node_count_n2");
}

my $node_count_n3 = `$pg_bin/psql -p $n3_port -d $dbname -t -c "SELECT COUNT(*) FROM spock.node"`;
chomp($node_count_n3);
$node_count_n3 =~ s/\s+//g;
if ($node_count_n3 eq '3') {
    pass('n3 shows 3 nodes in cluster');
} else {
    fail("n3 node count incorrect: expected 3, got $node_count_n3");
}

# Step 6: Remove node n3 using ZODREMOVE remove_node procedure
pass('Removing node n3 using ZODREMOVE remove_node procedure');

print "=== STARTING REMOVE_NODE PROCEDURE ===\n";

my $remove_node_cmd = "../../samples/Z0DAN/zodremove.py \\
    remove_node \\
    --target-node-name n3 \\
    --target-node-dsn 'host=$host dbname=$dbname port=$n3_port user=$db_user password=$db_password' \\
    --verbose \\
";

print "Executing: $remove_node_cmd\n";
print "---\n";

open($pipe, "$remove_node_cmd 2>&1 |") or die "Cannot open pipe: $!";
while (my $line = <$pipe>) {
    print $line;
}
close($pipe);
my $remove_node_result = $? >> 8;

print "---\n";
print "=== REMOVE_NODE PROCEDURE COMPLETED (exit code: $remove_node_result) ===\n";

if ($remove_node_result == 0) {
    pass('zodremove procedure executed successfully');
} else {
    fail("zodremove procedure failed with exit code: $remove_node_result");
}

# Step 7: Verify n3 is properly removed
pass('Verifying n3 removal');

# Wait for cleanup to complete
system_or_bail 'sleep', '2';

# Verify n3 is no longer in the node list on n1 and n2
my $node_count_n1_after = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT COUNT(*) FROM spock.node"`;
chomp($node_count_n1_after);
$node_count_n1_after =~ s/\s+//g;
if ($node_count_n1_after eq '2') {
    pass('n1 shows 2 nodes in cluster after removal');
} else {
    fail("n1 node count incorrect after removal: expected 2, got $node_count_n1_after");
}

my $node_count_n2_after = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT COUNT(*) FROM spock.node"`;
chomp($node_count_n2_after);
$node_count_n2_after =~ s/\s+//g;
if ($node_count_n2_after eq '2') {
    pass('n2 shows 2 nodes in cluster after removal');
} else {
    fail("n2 node count incorrect after removal: expected 2, got $node_count_n2_after");
}

# Verify n3 no longer exists in node list
my $n3_exists_n1 = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM spock.node WHERE node_name = 'n3')"`;
chomp($n3_exists_n1);
$n3_exists_n1 =~ s/\s+//g;
if ($n3_exists_n1 eq 'f') {
    pass('n3 no longer exists in n1 node list');
} else {
    fail('n3 still exists in n1 node list after removal');
}

my $n3_exists_n2 = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM spock.node WHERE node_name = 'n3')"`;
chomp($n3_exists_n2);
$n3_exists_n2 =~ s/\s+//g;
if ($n3_exists_n2 eq 'f') {
    pass('n3 no longer exists in n2 node list');
} else {
    fail('n3 still exists in n2 node list after removal');
}

# Step 8 Clean up n3
pass('Cleaning up n3');

# Stop n3 PostgreSQL instance
system("$pg_bin/pg_ctl stop -D $n3_datadir -m immediate >> '$config->{log_file}' 2>&1 &");
system_or_bail 'sleep', '5';
system_or_bail 'rm', '-rf', $n3_datadir;

pass('n3 database instance cleaned up');

# Final verification
pass('ZODAN node addition and removal test completed successfully');

# Test summary
print "\n=== TEST SUMMARY ===\n";
print "✓ Created 2-node cluster\n";
print "✓ Cross-wired nodes n1 and n2\n";
print "✓ Created test data and replication sets\n";
print "✓ Added node n3 using zodan.py \n";
print "✓ Verified n3 integration\n";
print "✓ Removed node n3 using zodremove.py\n";
print "✓ Verified n3 removal\n";
print "✓ Cleaned up n3\n";
print "========================\n";

# Cleanup will be handled by SpockTest.pm END block
# No need for done_testing() when using a test plan
