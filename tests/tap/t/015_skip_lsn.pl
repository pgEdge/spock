use strict;
use warnings;
use Test::More tests => 17;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail command_ok get_test_config scalar_query psql_or_bail);

# =============================================================================
# Test: 013_skip_lsn.pl - Skip LSN Functionality in SUB_DISABLE Mode
# =============================================================================
# This test verifies that the skip_lsn mechanism works correctly when a
# subscription is disabled due to exceptions. It ensures that after setting
# skip_lsn and re-enabling the subscription, the worker successfully skips
# the problematic transaction and continues replicating, rather than getting
# disabled again.
#
# Test Scenario:
# 1. Set up bidirectional replication between n1 and n2
# 2. Create a divergence using repair_mode (delete a row on n2)
# 3. Update the same row on n1, causing replication failure on n2
# 4. Verify subscription is disabled with exception logged
# 5. Set skip_lsn to the LSN from exception_log
# 6. Re-enable subscription
# 7. Verify subscription stays enabled (transaction is skipped successfully)
# 8. Verify subsequent replication continues to work
#
# This tests the fix for SPOC-363 where skip_lsn would cause the subscription
# to be disabled again instead of successfully skipping the transaction.

# Create a 2-node cluster
create_cluster(2, 'Create 2-node cluster for skip_lsn test');

# Get cluster configuration
my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};

# Set up bidirectional replication
cross_wire(2, ['n1', 'n2'], 'Cross-wire nodes N1 and N2');

# Configure exception_behaviour to SUB_DISABLE on node 2
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'sub_disable'");
psql_or_bail(2, "SELECT pg_reload_conf()");

# Wait for config reload
system_or_bail 'sleep', '2';

# Create test table on node 1
psql_or_bail(1,
    "CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        k BIGINT
    )"
);

# Insert initial data on node 1
psql_or_bail(1, "INSERT INTO users VALUES (1, 100)");
psql_or_bail(1, "INSERT INTO users VALUES (2, 200)");

# Wait for replication
system_or_bail 'sleep', '5';

# Verify initial replication worked
my $count_n2 = scalar_query(2, "SELECT COUNT(*) FROM users WHERE id = 1");
is($count_n2, '1', 'Initial row replicated to n2');

# Create divergence: Delete row on n2 using repair_mode in a single transaction
psql_or_bail(2, "
    BEGIN;
    SELECT spock.repair_mode(true);
    DELETE FROM users WHERE id = 1;
    COMMIT;
");

pass("Created divergence using repair_mode");

# Verify row is deleted on n2 but not n1
$count_n2 = scalar_query(2, "SELECT COUNT(*) FROM users WHERE id = 1");
is($count_n2, '0', 'Row deleted on n2');

my $count_n1 = scalar_query(1, "SELECT COUNT(*) FROM users WHERE id = 1");
is($count_n1, '1', 'Row still exists on n1');

# Update the row on n1 - this will fail on n2
psql_or_bail(1, "UPDATE users SET k = 1000 WHERE id = 1");

# Wait for replication attempt and failure
system_or_bail 'sleep', '5';

# Verify subscription is disabled (sub_n2_n1 is the subscription on n2 from n1)
my $sub_status = scalar_query(2, "SELECT status FROM spock.sub_show_status()");
is($sub_status, 'disabled', 'Subscription disabled after exception');

# Verify exception was logged
my $exception_count = scalar_query(2, "SELECT COUNT(*) FROM spock.exception_log WHERE operation = 'UPDATE' AND table_name = 'users'");
is($exception_count, '1', 'Exception logged for UPDATE operation');

# Get the skip_lsn from exception_log
my $skip_lsn = scalar_query(2,
    "SELECT SUBSTRING(error_message FROM 'skip_lsn = ([0-9A-F]+/[0-9A-F]+)') " .
    "FROM spock.exception_log " .
    "WHERE operation = 'SUB_DISABLE' " .
    "ORDER BY retry_errored_at DESC LIMIT 1"
);

ok($skip_lsn, "Got skip_lsn from exception_log: $skip_lsn");

# Set skip_lsn
psql_or_bail(2, "SELECT spock.sub_alter_skiplsn('sub_n2_n1', '$skip_lsn')");
pass("Set skip_lsn to $skip_lsn");

# Re-enable subscription
psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");

# Wait for worker to process the skip
system_or_bail 'sleep', '5';

# Verify subscription is still enabled (this is the key test!)
$sub_status = scalar_query(2, "SELECT status FROM spock.sub_show_status()");
is($sub_status, 'replicating', 'Subscription stayed enabled after skipping transaction');

# Verify skip_lsn was cleared
my $current_skip_lsn = scalar_query(2, "SELECT sub_skip_lsn FROM spock.subscription WHERE sub_name = 'sub_n2_n1'");
is($current_skip_lsn, '0/0', 'skip_lsn was cleared after successful skip');

# Test that subsequent replication continues to work
# Insert a new row on n1
psql_or_bail(1, "INSERT INTO users VALUES (2, 200)");

# Wait for replication
system_or_bail 'sleep', '3';

# Verify new row replicated successfully
$count_n2 = scalar_query(2, "SELECT COUNT(*) FROM users WHERE id = 2");
is($count_n2, '1', 'Subsequent replication works after skip');

# Verify the value
my $value_n2 = scalar_query(2, "SELECT k FROM users WHERE id = 2");
is($value_n2, '200', 'Correct value replicated');

# Verify subscription is still enabled
$sub_status = scalar_query(2, "SELECT status FROM spock.sub_show_status()");
is($sub_status, 'replicating', 'Subscription still enabled after subsequent replication');

# Cleanup
destroy_cluster();

pass('Test completed successfully');
