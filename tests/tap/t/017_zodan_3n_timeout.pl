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
# 1. Creates a 3-node cluster (n1, n2 active; n3 dropped and re-added)
# 2. Drops n3 from cluster and installs zodan on it
# 3. Renames spock.sync_event() on node 1 to simulate it being missing
# 4. Attempts add_node from n3 to join the cluster
# 5. Verifies the call fails quickly with an error (not timeout)

create_cluster(3, 'Create 3-node Spock test cluster');

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
psql_or_bail(3, "SELECT spock.node_drop('n3')");
psql_or_bail(3, "CREATE EXTENSION dblink");
psql_or_bail(3, "\\i ../../samples/Z0DAN/zodan.sql");
psql_or_bail(3, "\\i ../../samples/Z0DAN/zodremove.sql");

# Rename sync_event function on node 1 to simulate it being missing
print STDERR "Rename spock.sync_event() on N1 to simulate missing function\n";
psql_or_bail(1, "ALTER FUNCTION spock.sync_event() RENAME TO sync_event_renamed");

# Attempt add_node - this should fail quickly with an error, not timeout
print STDERR "Attempt add_node from N2 to N1 (should fail quickly with error)\n";
my $start_time = time();

# scalar_query uses backticks which don't throw exceptions - check $? for exit code
my $result = scalar_query(2, qq{
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        new_node_name := 'n2',
        new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
        verb := false
    )});
my $exit_code = $? >> 8;

my $elapsed_time = time() - $start_time;
print STDERR "add_node call completed in $elapsed_time seconds (exit code: $exit_code)\n";

# The call should fail quickly (well under 1200 seconds which is default timeout)
# We expect it to fail within a few seconds since it should error immediately
ok($elapsed_time < 600, "add_node failed quickly (${elapsed_time}s < 600s), not waiting for timeout");
ok($exit_code != 0, "add_node failed as expected when sync_event is missing (exit code: $exit_code)");

# Restore sync_event function on N1 for cleanup
print STDERR "Restore spock.sync_event() on N1\n";
psql_or_bail(1, "ALTER FUNCTION spock.sync_event_renamed() RENAME TO sync_event");

# Clean leftovers in the Spock cluster caused by unsuccessful addition
scalar_query(2, qq{
	CALL spock.remove_node(
		target_node_name := 'n2',
		target_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
		verbose_mode := true)
});

print STDERR "Check: an error during pg_replication_slot_advance should stop node addition\n";

psql_or_bail(2, "ALTER FUNCTION pg_replication_slot_advance RENAME TO pg_replication_slot_advance_renamed");
$start_time = time();

# Should be OK, because of 2-n configuration, no advance needed
psql_or_bail(2, qq{
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        new_node_name := 'n2',
        new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
        verb := false
    )});

# Should fail quickly
$result = scalar_query(3, qq{
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        new_node_name := 'n3',
        new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
        verb := false
    )});
$exit_code = $? >> 8;

$elapsed_time = time() - $start_time;
print STDERR "add_node call completed in $elapsed_time seconds (exit code: $exit_code)\n";

ok($elapsed_time < 600, "add_node on n3 failed quickly");
ok($exit_code != 0, "add_node failed as expected when pg_replication_slot_advance is missing (exit code: $exit_code)");

psql_or_bail(2, "ALTER FUNCTION pg_replication_slot_advance_renamed RENAME TO pg_replication_slot_advance");

# Clean leftovers of node-3 in the Spock cluster caused by unsuccessful addition
scalar_query(3, qq{
	CALL spock.remove_node(
		target_node_name := 'n3',
		target_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
		verbose_mode := true)
});

print STDERR "Check: quick fail if something happens during subscription creation on source node\n";

psql_or_bail(1, "ALTER FUNCTION spock.sub_create RENAME TO sub_create_renamed");
$start_time = time();

$result = scalar_query(3, qq{
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        new_node_name := 'n3',
        new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
        verb := false
    )});
$exit_code = $? >> 8;

$elapsed_time = time() - $start_time;
print STDERR "add_node call completed in $elapsed_time seconds (exit code: $exit_code)\n";

ok($elapsed_time < 600, "add_node on n3 failed quickly");
ok($exit_code != 0, "add_node failed as expected when sub_create is missing (exit code: $exit_code)");

psql_or_bail(1, "ALTER FUNCTION spock.sub_create_renamed RENAME TO sub_create");

# Clean leftovers of node-3 in the Spock cluster caused by unsuccessful addition
scalar_query(2, qq{
	CALL spock.remove_node(
		target_node_name := 'n2',
		target_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
		verbose_mode := true)
});
scalar_query(3, qq{
	CALL spock.remove_node(
		target_node_name := 'n3',
		target_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
		verbose_mode := true)
});

print STDERR "Final check: node-3 adds to the cluster successfully\n";

psql_or_bail(2, qq{
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        new_node_name := 'n2',
        new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
        verb := false
    )});
psql_or_bail(3, qq{
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        new_node_name := 'n3',
        new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
        verb := false
    )});

# Verify cluster has 3 nodes on each node
for my $node (1, 2, 3) {
    my $node_count = scalar_query($node, "SELECT count(*) FROM spock.node");
    ok($node_count == 3, "Node $node sees 3 nodes in cluster (got $node_count)");
}

# Verify each node has 2 non-disabled subscriptions
for my $node (1, 2, 3) {
    my $sub_count = scalar_query($node,
        "SELECT count(*) FROM spock.subscription WHERE sub_enabled = true");
    ok($sub_count == 2, "Node $node has 2 enabled subscriptions (got $sub_count)");
}

# Cleanup will be handled by SpockTest.pm END block
destroy_cluster('Destroy test cluster');
done_testing();
