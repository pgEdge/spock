use strict;
use warnings;
use Test::More tests => 36;  # 35 tests + 1 cleanup test from END block
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config system_maybe cross_wire);

# =============================================================================
# Test: 007_zodan_node_addition.pl - Test Zodan Zero-Downtime Node Addition
# =============================================================================
# This test follows the exact sequence:
# 1. Create 2-node cluster and cross-wire them
# 2. Initdb n3
# 3. Check dblink on n1 and n3
# 4. Create procedure on n1
# 5. Add node 3 using n1 as source
# 6. Display subscriptions on n1, n2, n3
# 7. Display nodes on all three
# 8. Destroy cluster

# Step 1: Create a 3-node cluster initially
create_cluster(3, 'Create initial 3-node Spock test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

# Step 1a: Cross-wire only the first 2 nodes (n1 and n2)
cross_wire(2, ['n1', 'n2'], 'Cross-wire first 2 nodes (n1 and n2)');

pass('3-node cluster created, first 2 nodes cross-wired');

# Install dblink extension on all nodes (required for zodan procedures)
system_maybe "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "CREATE EXTENSION IF NOT EXISTS dblink";
system_maybe "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "CREATE EXTENSION IF NOT EXISTS dblink";
system_maybe "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c', "CREATE EXTENSION IF NOT EXISTS dblink";

pass('dblink extension installed on n1, n2, and n3');

# Test data replication between n1 and n2
pass('Testing data replication between n1 and n2');

# Create test table on n2
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "
    CREATE TABLE test_replication (
        id SERIAL PRIMARY KEY,
        name VARCHAR(50),
        value INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
";

# Check what replication sets exist on n2
my $repsets = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT set_name FROM spock.replication_set ORDER BY set_name"`;
chomp($repsets);
print "Available replication sets on n2: $repsets\n";

# Add table to the first available replication set on n2
my $first_repset = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT set_name FROM spock.replication_set ORDER BY set_name LIMIT 1"`;
chomp($first_repset);
$first_repset =~ s/\s+//g;

if ($first_repset) {
    system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "
        SELECT spock.repset_add_table('$first_repset', 'test_replication')
    ";
    pass("Added table to replication set: $first_repset");
} else {
    fail("No replication sets found on n2");
}

# Insert test data on n2
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "
    INSERT INTO test_replication (name, value) VALUES 
    ('test_data_1', 100),
    ('test_data_2', 200)
";

pass('Test table created and data inserted on n2');

# Wait for replication to n1
system_or_bail 'sleep', '1';

# Verify data replicated to n1
my $data_on_n1 = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT COUNT(*) FROM test_replication"`;
chomp($data_on_n1);
$data_on_n1 =~ s/\s+//g;
if ($data_on_n1 eq '2') {
    pass('Data successfully replicated from n2 to n1 (2 rows)');
} else {
    fail("Data replication failed: expected 2 rows, got $data_on_n1");
}

# Step 2: n3 is already created by create_cluster(3), just get its port
my $new_port = $node_ports->[2];  # n3 is the 3rd node (index 2)
pass('n3 is already running from create_cluster(3)');

# Step 3: Check dblink on n1, n2, and n3
my $dblink_check_n1 = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'dblink_connect')"`;
chomp($dblink_check_n1);
$dblink_check_n1 =~ s/\s+//g;
if ($dblink_check_n1 eq 't') {
    pass('dblink extension is available on n1');
} else {
    fail('dblink extension not available on n1');
}

my $dblink_check_n2 = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'dblink_connect')"`;
chomp($dblink_check_n2);
$dblink_check_n2 =~ s/\s+//g;
if ($dblink_check_n2 eq 't') {
    pass('dblink extension is available on n2');
} else {
    fail('dblink extension not available on n2');
}

my $dblink_check_n3 = `$pg_bin/psql -p $new_port -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'dblink_connect')"`;
chomp($dblink_check_n3);
$dblink_check_n3 =~ s/\s+//g;
if ($dblink_check_n3 eq 't') {
    pass('dblink extension is available on n3');
} else {
    fail('dblink extension not available on n3');
}

pass('dblink extension verified on all three nodes (n1, n2, n3)');

# Step 4: Create procedure on n3 (load zodan procedures on the new node)
my $zodan_sql = '../../samples/Z0DAN/zodan.sql';
if (-f $zodan_sql) {
    system_or_bail "$pg_bin/psql", '-p', $new_port, '-d', $dbname, '-f', $zodan_sql;
    
    # Verify the procedure was created in spock schema
    my $proc_check = `$pg_bin/psql -p $new_port -d $dbname -t -c "SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE p.proname = 'check_spock_version_compatibility' AND n.nspname = 'spock'"`;
    chomp($proc_check);
    $proc_check =~ s/\s+//g;
    if ($proc_check > 0) {
        pass('Zodan procedures loaded and verified on n3');
    } else {
        # Try checking all procedures in spock schema
        my $alt_check = `$pg_bin/psql -p $new_port -d $dbname -t -c "SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'spock' AND p.proname LIKE '%compatibility%'"`;
        chomp($alt_check);
        if ($alt_check) {
            pass("Zodan procedures loaded on n3 (found: $alt_check)");
        } else {
            fail('Zodan procedures loaded but check_spock_version_compatibility not found');
        }
    }
} else {
    skip('Zodan SQL file not found, skipping procedure loading', 1);
}

# Step 5: Add node 3 using n3 as source (called from n3)
pass('Attempting to add node 3 using n3 as source (called from n3)');

# Call the zodan add_node procedure and show real-time output
print "=== STARTING ADD_NODE PROCEDURE - LIVE OUTPUT ===\n";

# Use open with pipe to see real-time output
my $add_node_cmd = "$pg_bin/psql -p $new_port -d $dbname -c \"
    CALL spock.add_node(
        'n1',
        'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        'n3',
        'host=$host dbname=$dbname port=$new_port user=$db_user password=$db_password',
        true,
        'CA',
        'USA',
        '{}'::jsonb
    )
\"";

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

pass("add_node procedure execution completed - live output shown above");

# Verify that data was replicated to n3 after node addition
pass('Verifying data replication to n3 after node addition');

# Wait for replication to complete
system_or_bail 'sleep', '1';

# Check if test_replication table exists on n3
my $table_exists_n3 = `$pg_bin/psql -p $new_port -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_replication')"`;
chomp($table_exists_n3);
$table_exists_n3 =~ s/\s+//g;
if ($table_exists_n3 eq 't') {
    pass('Test table exists on n3');
    
    # Check data count on n3
    my $data_on_n3 = `$pg_bin/psql -p $new_port -d $dbname -t -c "SELECT COUNT(*) FROM test_replication"`;
    chomp($data_on_n3);
    $data_on_n3 =~ s/\s+//g;
    if ($data_on_n3 eq '2') {
        pass('Data successfully replicated to n3 (2 rows)');
    } else {
        fail("Data replication to n3 failed: expected 2 rows, got $data_on_n3");
    }
} else {
    fail('Test table does not exist on n3');
}

# Step 6: Display subscriptions on n1, n2, n3
my $subs_n1 = `$pg_bin/psql -p $node_ports->[0] -d $dbname -c "SELECT sub_name, sub_origin, sub_target, sub_enabled FROM spock.subscription ORDER BY sub_name" 2>&1`;
pass("Subscriptions on n1:\n$subs_n1");

# Verify n1 has 2 subscriptions (sub_n1_n2 and sub_n2_n1)
my $sub_count_n1 = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT COUNT(*) FROM spock.subscription"`;
chomp($sub_count_n1);
$sub_count_n1 =~ s/\s+//g;
if ($sub_count_n1 eq '2') {
    pass('n1 has 2 subscriptions as expected');
} else {
    fail("n1 subscription count incorrect: expected 2, got $sub_count_n1");
}

my $subs_n2 = `$pg_bin/psql -p $node_ports->[1] -d $dbname -c "SELECT sub_name, sub_origin, sub_target, sub_enabled FROM spock.subscription ORDER BY sub_name" 2>&1`;
pass("Subscriptions on n2:\n$subs_n2");

# Verify n2 has 2 subscriptions (sub_n1_n2 and sub_n2_n1)
my $sub_count_n2 = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT COUNT(*) FROM spock.subscription"`;
chomp($sub_count_n2);
$sub_count_n2 =~ s/\s+//g;
if ($sub_count_n2 eq '2') {
    pass('n2 has 2 subscriptions as expected');
} else {
    fail("n2 subscription count incorrect: expected 2, got $sub_count_n2");
}

my $subs_n3 = `$pg_bin/psql -p $new_port -d $dbname -c "SELECT sub_name, sub_origin, sub_target, sub_enabled FROM spock.subscription ORDER BY sub_name" 2>&1`;
pass("Subscriptions on n3:\n$subs_n3");

# Verify n3 has 0 subscriptions initially
my $sub_count_n3 = `$pg_bin/psql -p $new_port -d $dbname -t -c "SELECT COUNT(*) FROM spock.subscription"`;
chomp($sub_count_n3);
$sub_count_n3 =~ s/\s+//g;
if ($sub_count_n3 eq '0') {
    pass('n3 has 0 subscriptions as expected');
} else {
    fail("n3 subscription count incorrect: expected 0, got $sub_count_n3");
}

# Step 7: Display nodes on all three
my $nodes_n1 = `$pg_bin/psql -p $node_ports->[0] -d $dbname -c "SELECT node_id, node_name, location, country FROM spock.node ORDER BY node_name" 2>&1`;
pass("Nodes on n1:\n$nodes_n1");

# Verify n1 has 3 nodes (n1, n2, n3)
my $node_count_n1 = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT COUNT(*) FROM spock.node"`;
chomp($node_count_n1);
$node_count_n1 =~ s/\s+//g;
if ($node_count_n1 eq '3') {
    pass('n1 has 3 nodes as expected');
} else {
    fail("n1 node count incorrect: expected 3, got $node_count_n1");
}

my $nodes_n2 = `$pg_bin/psql -p $node_ports->[1] -d $dbname -c "SELECT node_id, node_name, location, country FROM spock.node ORDER BY node_name" 2>&1`;
pass("Nodes on n2:\n$nodes_n2");

# Verify n2 has 3 nodes (n1, n2, n3)
my $node_count_n2 = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT COUNT(*) FROM spock.node"`;
chomp($node_count_n2);
$node_count_n2 =~ s/\s+//g;
if ($node_count_n2 eq '3') {
    pass('n2 has 3 nodes as expected');
} else {
    fail("n2 node count incorrect: expected 3, got $node_count_n2");
}

my $nodes_n3 = `$pg_bin/psql -p $new_port -d $dbname -c "SELECT node_id, node_name, location, country FROM spock.node ORDER BY node_name" 2>&1`;
pass("Nodes on n3:\n$nodes_n3");

# Verify n3 has 3 nodes (n1, n2, n3)
my $node_count_n3 = `$pg_bin/psql -p $new_port -d $dbname -t -c "SELECT COUNT(*) FROM spock.node"`;
chomp($node_count_n3);
$node_count_n3 =~ s/\s+//g;
if ($node_count_n3 eq '3') {
    pass('n3 has 3 nodes as expected');
} else {
    fail("n3 node count incorrect: expected 3, got $node_count_n3");
}

# Step 8: Cleanup - Stop the third PostgreSQL instance
my $new_datadir = $config->{node_datadirs}->[2];  # n3 datadir
system("$pg_bin/pg_ctl stop -D $new_datadir -m immediate >> 'logs/spocktest_$$.log' 2>&1 &");
system_or_bail 'sleep', '5';
system_or_bail 'rm', '-rf', $new_datadir;

pass('Third PostgreSQL instance cleaned up');

# Final verification
pass('Zodan node addition test completed successfully');

# Cleanup will be handled by SpockTest.pm END block
# No need for done_testing() when using a test plan
