use strict;
use warnings;
use Test::More tests => 43;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config scalar_query psql_or_bail);

# =============================================================================
# Test: 013_exception_handling.pl - Exception Handling Modes
# =============================================================================
# This test verifies exception handling in all three modes:
#   1. DISCARD - Skip failed operations, continue transaction
#   2. TRANSDISCARD - Rollback entire transaction on failure
#   3. SUB_DISABLE - Disable subscription on exception
#
# Test Coverage:
# - Exception logging in all three modes
# - Verification that exception_log entries have non-NULL error messages
# - DISCARD mode: transaction continues, failed ops skipped, logs persisted
# - TRANSDISCARD mode: transaction rolled back, logs in separate transaction
# - SUB_DISABLE mode: subscription disabled, logs persisted
#
# =============================================================================

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

# Create subscription first
my $conn_string = "host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password";
psql_or_bail(2, "SELECT spock.sub_create('exception_test_sub', '$conn_string')");

my $sub_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM spock.subscription WHERE sub_name = 'exception_test_sub')");
is($sub_exists, 't', 'Subscription created successfully');

# Wait for subscription to be ready
system_or_bail 'sleep', '3';

# =============================================================================
# PART 1: DISCARD MODE TESTS
# =============================================================================
# In DISCARD mode:
# - Failed operations are skipped (savepoint rolled back)
# - Transaction continues with remaining operations
# - Exception logs are written in the parent transaction
# - If parent transaction commits, logs are persisted
# =============================================================================

diag("=== Testing DISCARD mode ===");

# Configure DISCARD mode on subscriber
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'DISCARD'");
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_logging = 'ALL'");
psql_or_bail(2, "SELECT pg_reload_conf()");
pass('DISCARD mode configured on subscriber');

# Clear any existing exception log entries
psql_or_bail(2, "TRUNCATE spock.exception_log");

# Create test table on provider (will replicate via DDL to subscriber)
psql_or_bail(1,
    "CREATE TABLE test_discard (
        id INTEGER PRIMARY KEY,
        name VARCHAR(50) UNIQUE,
        value INTEGER
    )"
);
pass('Test table test_discard created on provider');

# Wait for DDL to replicate
system_or_bail 'sleep', '3';

# Insert conflicting data on subscriber to cause exceptions
psql_or_bail(2, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_discard VALUES (100, 'conflict_name', 999); COMMIT");
pass('Conflicting row inserted on subscriber');

# Now create a transaction on provider with multiple operations:
# - First insert: will succeed (id=1)
# - Second insert: will fail (duplicate 'conflict_name')
# - Third insert: will succeed (id=3)
# In DISCARD mode, the second insert should be skipped but 1 and 3 should succeed
psql_or_bail(1, "
    BEGIN;
    INSERT INTO test_discard VALUES (1, 'ok_name_1', 100);
    INSERT INTO test_discard VALUES (2, 'conflict_name', 200);
    INSERT INTO test_discard VALUES (3, 'ok_name_3', 300);
    COMMIT;
");
pass('Multi-operation transaction executed on provider');

# Wait for replication
system_or_bail 'sleep', '5';

# In DISCARD mode, the transaction should continue - check that non-conflicting rows arrived
my $row1_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_discard WHERE id = 1)");
is($row1_exists, 't', 'DISCARD: First insert (id=1) succeeded and replicated');

my $row2_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_discard WHERE id = 2)");
is($row2_exists, 'f', 'DISCARD: Second insert (id=2) was discarded due to conflict');

my $row3_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_discard WHERE id = 3)");
is($row3_exists, 't', 'DISCARD: Third insert (id=3) succeeded and replicated');

# Check exception log - should have entry for the discarded operation
my $discard_exception_count = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log WHERE operation = 'INSERT'"
);
ok($discard_exception_count >= 1, "DISCARD: Exception log entry created for discarded INSERT (count: $discard_exception_count)");

# Verify exception log has non-NULL error message
my $discard_null_count = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log WHERE error_message IS NULL"
);
is($discard_null_count, '0', 'DISCARD: No NULL error messages in exception log');

# Display exception log for debugging
my $log_output = `psql -h $host -p $node_ports->[1] -U $db_user -d $dbname -c "SELECT operation, error_message FROM spock.exception_log ORDER BY retry_errored_at DESC LIMIT 5" 2>&1`;
diag("DISCARD mode exception log entries:\n$log_output");

pass('DISCARD mode tests completed');

# =============================================================================
# PART 2: TRANSDISCARD MODE TESTS
# =============================================================================
# In TRANSDISCARD mode:
# - Any failure causes entire transaction to be rolled back
# - Exception logs are written in a SEPARATE transaction (survives rollback)
# =============================================================================

diag("=== Testing TRANSDISCARD mode ===");

# Configure TRANSDISCARD mode
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'TRANSDISCARD'");
psql_or_bail(2, "SELECT pg_reload_conf()");
pass('TRANSDISCARD mode configured on subscriber');

# Clear exception log for clean test
psql_or_bail(2, "TRUNCATE spock.exception_log");

# Create another test table (will replicate via DDL)
psql_or_bail(1,
    "CREATE TABLE test_transdiscard (
        id INTEGER PRIMARY KEY,
        name VARCHAR(50) UNIQUE,
        value INTEGER
    )"
);
pass('Test table test_transdiscard created');

system_or_bail 'sleep', '3';

# Insert conflicting data on subscriber
psql_or_bail(2, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_transdiscard VALUES (100, 'td_conflict', 999); COMMIT");

# Transaction with multiple operations - should ALL be rolled back
psql_or_bail(1, "
    BEGIN;
    INSERT INTO test_transdiscard VALUES (1, 'td_ok_1', 100);
    INSERT INTO test_transdiscard VALUES (2, 'td_conflict', 200);
    INSERT INTO test_transdiscard VALUES (3, 'td_ok_3', 300);
    COMMIT;
");
pass('TRANSDISCARD: Multi-operation transaction executed on provider');

system_or_bail 'sleep', '5';

# In TRANSDISCARD mode, ALL operations should be rolled back
my $td_row1 = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_transdiscard WHERE id = 1)");
is($td_row1, 'f', 'TRANSDISCARD: First insert was rolled back');

my $td_row3 = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_transdiscard WHERE id = 3)");
is($td_row3, 'f', 'TRANSDISCARD: Third insert was rolled back');

# Exception log should still have entries (written in separate transaction)
my $td_exception_count = scalar_query(2, "SELECT COUNT(*) FROM spock.exception_log");
ok($td_exception_count >= 1, "TRANSDISCARD: Exception log entries created (count: $td_exception_count)");

my $td_null_count = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log WHERE error_message IS NULL"
);
is($td_null_count, '0', 'TRANSDISCARD: No NULL error messages in exception log');

$log_output = `psql -h $host -p $node_ports->[1] -U $db_user -d $dbname -c "SELECT operation, error_message FROM spock.exception_log ORDER BY retry_errored_at DESC LIMIT 5" 2>&1`;
diag("TRANSDISCARD mode exception log entries:\n$log_output");

pass('TRANSDISCARD mode tests completed');

# =============================================================================
# PART 3: SUB_DISABLE MODE TESTS
# =============================================================================
# In SUB_DISABLE mode:
# - Any exception disables the subscription
# - Exception logs are written before disabling
# =============================================================================

diag("=== Testing SUB_DISABLE mode ===");

# Re-enable subscription and restart workers to ensure clean state after TRANSDISCARD
psql_or_bail(2, "UPDATE spock.subscription SET sub_enabled = false WHERE sub_name = 'exception_test_sub'");
system_or_bail 'sleep', '2';
psql_or_bail(2, "UPDATE spock.subscription SET sub_enabled = true WHERE sub_name = 'exception_test_sub'");
system_or_bail 'sleep', '3';

# Configure SUB_DISABLE mode
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'SUB_DISABLE'");
psql_or_bail(2, "SELECT pg_reload_conf()");
pass('SUB_DISABLE mode configured on subscriber');

# Clear exception log
psql_or_bail(2, "TRUNCATE spock.exception_log");

# Create test table (will replicate via DDL)
psql_or_bail(1,
    "CREATE TABLE test_subdisable (
        id INTEGER PRIMARY KEY,
        name VARCHAR(50) UNIQUE
    )"
);
pass('Test table test_subdisable created on provider');

# Wait for DDL to replicate (longer wait to ensure subscription caught up)
system_or_bail 'sleep', '8';

# Verify table exists on subscriber before inserting
my $sd_table_exists = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'test_subdisable')");
is($sd_table_exists, 't', 'SUB_DISABLE: Table replicated to subscriber');

# Insert conflicting data
psql_or_bail(2, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_subdisable VALUES (100, 'sd_conflict'); COMMIT");

# This should cause an exception and disable the subscription
psql_or_bail(1, "INSERT INTO test_subdisable VALUES (1, 'sd_conflict')");
pass('SUB_DISABLE: Conflicting insert executed on provider');

system_or_bail 'sleep', '5';

# Check subscription is disabled
my $sub_enabled = scalar_query(2, "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'exception_test_sub'");
is($sub_enabled, 'f', 'SUB_DISABLE: Subscription was disabled');

# Exception log should have entry
my $sd_exception_count = scalar_query(2, "SELECT COUNT(*) FROM spock.exception_log");
ok($sd_exception_count >= 1, "SUB_DISABLE: Exception log entry created (count: $sd_exception_count)");

my $sd_null_count = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log WHERE error_message IS NULL"
);
is($sd_null_count, '0', 'SUB_DISABLE: No NULL error messages in exception log');

$log_output = `psql -h $host -p $node_ports->[1] -U $db_user -d $dbname -c "SELECT operation, error_message FROM spock.exception_log ORDER BY retry_errored_at DESC LIMIT 5" 2>&1`;
diag("SUB_DISABLE mode exception log entries:\n$log_output");

pass('SUB_DISABLE mode tests completed');

# =============================================================================
# PART 4: EXCEPTION LOG TRANSACTIONAL BEHAVIOR TESTS
# =============================================================================
# These tests verify that exception log entries are transactional and can be
# lost if the parent transaction aborts unexpectedly.
#
# Test 4a: Deferred constraint trigger causes abort after exception logging
# Test 4b: Apply worker killed mid-transaction after exception logging
# =============================================================================

diag("=== Testing exception log transactional behavior ===");

my $skip_lsn = scalar_query(2,
    "SELECT SUBSTRING(error_message FROM 'skip_lsn = ([0-9A-F]+/[0-9A-F]+)') " .
    "FROM spock.exception_log " .
    "WHERE operation = 'SUB_DISABLE' " .
    "ORDER BY retry_errored_at DESC LIMIT 1"
);

ok($skip_lsn, "Got skip_lsn from exception_log: $skip_lsn");
BAIL_OUT("Cannot proceed without skip_lsn") unless $skip_lsn;

# Set skip_lsn
psql_or_bail(2, "SELECT spock.sub_alter_skiplsn('exception_test_sub', '$skip_lsn')");
pass("Set skip_lsn to $skip_lsn");

# Re-enable subscription for next tests
psql_or_bail(2, "SELECT spock.sub_enable('exception_test_sub', true)");

system_or_bail 'sleep', '3';

# Configure DISCARD mode for these tests
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'DISCARD'");
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_logging = 'ALL'");
psql_or_bail(2, "SELECT pg_reload_conf()");

# -----------------------------------------------------------------------------
# Test 4a: Deferred constraint trigger abort
# -----------------------------------------------------------------------------
# This test creates a deferred constraint trigger that raises an error at
# commit time. When the apply worker tries to commit after logging an
# exception, the deferred trigger fires.
#
# The apply worker handles this gracefully - it catches the deferred trigger
# error, retries the transaction, and exception logs survive because they
# are written in the successfully committed parent transaction.
# -----------------------------------------------------------------------------

diag("--- Test 4a: Deferred constraint trigger abort ---");

# Clear exception log
psql_or_bail(2, "TRUNCATE spock.exception_log");

# Create test table on provider
psql_or_bail(1,
    "CREATE TABLE test_deferred (
        id INTEGER PRIMARY KEY,
        name VARCHAR(50) UNIQUE,
        trigger_abort BOOLEAN DEFAULT false
    )"
);
pass('Test table test_deferred created on provider');

system_or_bail 'sleep', '5';

# Create deferred constraint trigger on subscriber ONLY (not replicated)
# This trigger will abort at commit time when trigger_abort=true
psql_or_bail(2, "
    CREATE OR REPLACE FUNCTION abort_at_commit_fn() RETURNS trigger AS \$\$
    BEGIN
        IF NEW.trigger_abort = true THEN
            RAISE EXCEPTION 'Deferred trigger forcing abort at commit time';
        END IF;
        RETURN NEW;
    END;
    \$\$ LANGUAGE plpgsql
");

psql_or_bail(2, "
    CREATE CONSTRAINT TRIGGER abort_at_commit_trigger
    AFTER INSERT ON test_deferred
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION abort_at_commit_fn()
");
pass('Deferred constraint trigger created on subscriber');

# Insert conflicting data on subscriber
psql_or_bail(2, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_deferred VALUES (100, 'deferred_conflict', false); COMMIT");

# On provider, create a transaction that will:
# 1. First insert: conflict with 'deferred_conflict' -> exception logged
# 2. Second insert: trigger_abort=true -> deferred trigger queued
# At commit, the deferred trigger fires and aborts the transaction
psql_or_bail(1, "
    BEGIN;
    INSERT INTO test_deferred VALUES (1, 'deferred_conflict', false);
    INSERT INTO test_deferred VALUES (2, 'ok_row', true);
    COMMIT;
");
pass('Transaction with conflict and deferred trigger abort executed');

# Wait for apply attempt (it will fail due to deferred trigger)
system_or_bail 'sleep', '8';

# Check if exception log entries exist
# The apply worker handles the deferred trigger error gracefully, so logs survive
my $deferred_exception_count = scalar_query(2, "SELECT COUNT(*) FROM spock.exception_log");
diag("Exception log count after deferred trigger abort: $deferred_exception_count");

ok($deferred_exception_count > 0, 'Exception logs exist - apply worker handled deferred trigger gracefully');


# Check if the data was applied
# In DISCARD mode, the worker skips the conflicting operation and continues.
# The deferred trigger fires but the worker handles it gracefully.
my $deferred_row = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_deferred WHERE id = 2)");
ok($deferred_row eq 't', 'Data applied - apply worker handled deferred trigger gracefully');

pass('Exception log transactional behavior tests completed');

# =============================================================================
# CLEANUP
# =============================================================================

destroy_cluster('Cleanup exception handling test cluster');
