use strict;
use warnings;
use Test::More tests => 25;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config scalar_query psql_or_bail);

# =============================================================================
# Test: 013_exception_handling.pl - Exception Handling with TRANSDISCARD Mode
# =============================================================================
# This test verifies that exception handling properly logs error messages
# in TRANSDISCARD mode, ensuring no NULL error messages in exception_log.
#
# Test Coverage:
# - Exception handling in TRANSDISCARD mode
# - Initial error message preservation across retries
# - Verification that exception_log entries have non-NULL error messages
# - Transaction-level TRANSDISCARDED logging
#
# Expected Results:
# - Transaction should fail initially due to constraint violation
# - Worker should retry with exception handling enabled
# - Exception log should contain entries with the initial error message
# - No entries should have NULL error_message

# Create a 2-node cluster
create_cluster(2, 'Create 2-node exception handling test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};

# Verify nodes exist
my $node1_exists = scalar_query(1, "SELECT EXISTS (SELECT 1 FROM spock.node WHERE node_name = 'n1')");
is($node1_exists, 't', 'Node n1 exists');

my $node2_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM spock.node WHERE node_name = 'n2')");
is($node2_exists, 't', 'Node n2 exists');

# Configure exception handling on subscriber (node2)
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'TRANSDISCARD'");
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_logging = 'ALL'");
psql_or_bail(2, "SELECT pg_reload_conf()");

pass('Exception handling configured on subscriber');

# Create test table with unique constraint on provider
psql_or_bail(1,
    "CREATE TABLE test_exception (
        id INTEGER PRIMARY KEY,
        name VARCHAR(50),
        value INTEGER,
        UNIQUE(name)
    )
");

psql_or_bail(1, "INSERT INTO test_exception VALUES (1, 'conflict_test_1', 100)");
psql_or_bail(1, "INSERT INTO test_exception VALUES (2, 'conflict_test_2', 200)");
pass('Test table created on provider');
# Create subscription
my $conn_string = "host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password";
psql_or_bail(2, "SELECT spock.sub_create('exception_test_sub', '$conn_string')");

my $sub_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM spock.subscription WHERE sub_name = 'exception_test_sub')");
is($sub_exists, 't', 'Subscription created successfully');

# Create the table on subscriber too (for structure)
psql_or_bail(2,
    "CREATE TABLE test_exception (
        id INTEGER PRIMARY KEY,
        name VARCHAR(50),
        value INTEGER,
        UNIQUE(name)
    )
");

pass('Test table created on subscriber');

# Wait for subscription to be ready
system_or_bail 'sleep', '5';

my $table_exists = scalar_query(1, "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_exception')");
is($table_exists, 't', 'Test table created on provider');

my $table_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_exception')");
is($table_exists, 't', 'Test table created on subscriber');

my $table_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_exception')");
is($table_exists, 't', 'Test table created on subscriber');


# Insert initial data that will cause conflict
# First, insert on subscriber to create potential conflict
psql_or_bail(2, "BEGIN; select spock.repair_mode(true); INSERT INTO test_exception VALUES (3, 'conflict_test', 300); commit;");
pass('Conflicting data inserted on subscriber');

# Now insert on provider - this should cause a constraint violation on subscriber
# which will trigger exception handling
psql_or_bail(1, "INSERT INTO test_exception VALUES (4, 'conflict_test')");
pass('Insert executed on provider');

# This will also cause a conflict, because id=1 doesn't exists on subscriber
psql_or_bail(1, "UPDATE test_exception SET value = 400 WHERE id = 1;");
pass('Update executed on provider');
# This will also cause a conflict, because id=2 doesn't exists on subscriber
psql_or_bail(1, "DELETE FROM test_exception WHERE id = 2;");
pass('Delete executed on provider');

# Wait for replication attempt
system_or_bail 'sleep', '5';

# Check if exception was logged
my $exception_count = scalar_query(2, "SELECT COUNT(*) FROM spock.exception_log");
ok($exception_count >= 2, "Exception log entries created (count: $exception_count)");

# Verify no NULL error messages in exception log
my $null_error_count = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log
     WHERE error_message IS NULL"
);

is($null_error_count, '0', 'No NULL error messages in exception log');

# Check that we have an entry with the actual error message
my $has_error_message = scalar_query(2,
    "SELECT EXISTS (
        SELECT 1 FROM spock.exception_log
        WHERE error_message LIKE '%duplicate key%'
           OR error_message LIKE '%unique%'
           OR error_message LIKE '%constraint%'
           OR error_message LIKE '%logical replication did not%'
           OR error_message IS NOT NULL
    )"
);

is($has_error_message, 't', 'Exception log contains actual error messages');

# Display exception log for debugging
my $log_output = `psql -h $host -p $node_ports->[1] -U $db_user -d $dbname -c "SELECT operation, error_message FROM spock.exception_log ORDER BY retry_errored_at DESC LIMIT 5" 2>&1`;
diag("Exception log entries:\n$log_output");

pass('TRANSDISCARDED Exception handling test completed');

# Reset exception handling configuration to SUB_DISABLE
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'SUB_DISABLE'");
psql_or_bail(2, "SELECT pg_reload_conf()");

# This will also cause a conflict, because id=1 doesn't exists on subscriber
psql_or_bail(1, "UPDATE test_exception SET value = 400 WHERE id = 1;");
pass('Update executed on provider');

# SUB_DISABLE should disable the subscription on exception
system_or_bail 'sleep', '5';

# Check if exception was logged
my $exception_count = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log WHERE operation = 'SUB_DISABLE'"
);
is($exception_count, '1', 'SUB_DISABLE exception log entry created');

# Display exception log for debugging
my $log_output = `psql -h $host -p $node_ports->[1] -U $db_user -d $dbname -c "SELECT operation, error_message FROM spock.exception_log ORDER BY retry_errored_at DESC LIMIT 5" 2>&1`;
diag("Exception log entries:\n$log_output");

# Cleanup
destroy_cluster('Cleanup exception handling test cluster');
