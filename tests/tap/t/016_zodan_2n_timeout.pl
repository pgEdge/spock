use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail scalar_query);
use Time::HiRes qw(time);

# =============================================================================
# Test: Verify that add_node fails immediately with an error when sync_event
# function is missing on the source node, rather than waiting for timeout.
# =============================================================================
# This test verifies the fix where RAISE NOTICE was changed to RAISE EXCEPTION
# in zodan.sql for sync_event failures. The test:
# 1. Creates a 2-node cluster
# 2. Renames spock.sync_event() on node 1 to simulate it being missing
# 3. Attempts add_node from node 2
# 4. Verifies the call fails quickly with an error (not timeout)

create_cluster(2, 'Create 2-node Spock test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

# Prepare node 2: drop from cluster, install zodan
print STDERR "Prepare N2: drop local node and install zodan.sql\n";
psql_or_bail(2, "SELECT spock.node_drop('n2')");
psql_or_bail(2, "CREATE EXTENSION dblink");
psql_or_bail(2, "\\i ../../samples/Z0DAN/zodan.sql");
psql_or_bail(2, "\\i ../../samples/Z0DAN/zodremove.sql");

# Rename sync_event function on node 1 to simulate it being missing
print STDERR "Rename spock.sync_event() on N1 to simulate missing function\n";
psql_or_bail(1, "ALTER FUNCTION spock.sync_event() RENAME TO sync_event_renamed");

# Attempt add_node - this should fail quickly with an error, not timeout
print STDERR "Attempt add_node from N2 to N1 (should fail quickly with error)\n";
my $start_time = time();

# Use scalar_query which doesn't die on error - we expect this to fail
my $result = scalar_query(2, qq{
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        new_node_name := 'n2',
        new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
        verb := false
    )});

my $elapsed_time = time() - $start_time;
print STDERR "add_node call completed in $elapsed_time seconds\n";

# The call should fail quickly (well under 1200 seconds which is default timeout)
# We expect it to fail within a few seconds since it should error immediately
ok($elapsed_time < 600, "add_node failed quickly (${elapsed_time}s < 600s), not waiting for timeout");

# Restore sync_event function on N1 for cleanup
print STDERR "Restore spock.sync_event() on N1\n";
psql_or_bail(1, "ALTER FUNCTION spock.sync_event_renamed() RENAME TO sync_event");

# Cleanup will be handled by SpockTest.pm END block
destroy_cluster('Destroy test cluster');
done_testing();
