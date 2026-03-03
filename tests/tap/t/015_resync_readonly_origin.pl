use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail command_ok get_test_config scalar_query psql_or_bail system_maybe);

# =============================================================================
# Test: 015_resync_readonly_origin.pl - Resync Readonly Check (SPOC-440)
# =============================================================================
# This test verifies that spock.sub_resync_table() with truncate=true checks
# if the SUBSCRIBER is in read-only mode BEFORE truncating, preventing data loss.
#
# Bug scenario (SPOC-440):
# - User calls spock.sub_resync_table('sub', 'schema.table', true)
# - Old behavior: Truncate local table immediately, then sync worker tries COPY
# - If subscriber is in read-only mode, COPY FROM fails (can't insert data)
# - The table was already truncated, causing permanent data loss
# - New behavior: Check spock.readonly on subscriber first; error out before truncating
#
# Note: Origin readonly does NOT block resync because:
# - Origin uses COPY TO (a read operation) which is allowed in readonly mode
# - Only subscriber uses COPY FROM (a write operation) which is blocked
#
# Test approach:
# 1. Set spock.readonly on provider, verify resync SUCCEEDS (COPY TO is allowed)
# 2. Set spock.readonly on subscriber, verify resync FAILS and data preserved
# 3. Set spock.readonly on subscriber with truncate=false, verify resync FAILS
# 4. With subscriber writable, verify resync succeeds

# Create a 2-node cluster and cross-wire
create_cluster(2, 'Create 2-node cluster for resync readonly check test');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

# Get cluster configuration
my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $pg_bin = $config->{pg_bin};
my $dbname = $config->{db_name};

# Subscription name: n2 subscribing to n1
my $sub_name = 'sub_n2_n1';

# Create a test table on n1 (will replicate via DDL to n2)
psql_or_bail(1,
    "CREATE TABLE test_resync (
        id SERIAL PRIMARY KEY,
        name VARCHAR(50),
        value INTEGER
    )"
);

# Wait for DDL replication and table sync
system_or_bail 'sleep', '5';

# Insert data on n1
psql_or_bail(1, "INSERT INTO test_resync (name, value) VALUES ('test1', 100)");
psql_or_bail(1, "INSERT INTO test_resync (name, value) VALUES ('test2', 200)");
psql_or_bail(1, "INSERT INTO test_resync (name, value) VALUES ('test3', 300)");

# Wait for replication
system_or_bail 'sleep', '3';

# Verify data replicated to n2
my $count_subscriber = scalar_query(2, "SELECT COUNT(*) FROM test_resync");
is($count_subscriber, '3', 'Subscriber has 3 rows (replication working)');

# =============================================================================
# Test: Origin readonly does NOT block resync (COPY TO is allowed)
# =============================================================================

# Add a 4th row on provider using repair_mode (won't replicate)
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_resync (name, value) VALUES ('test4', 400); COMMIT;");

# Verify provider has 4 rows, subscriber still has 3
my $provider_count = scalar_query(1, "SELECT COUNT(*) FROM test_resync");
is($provider_count, '4', 'Provider has 4 rows');
my $sub_count = scalar_query(2, "SELECT COUNT(*) FROM test_resync");
is($sub_count, '3', 'Subscriber has 3 rows (4th not replicated due to repair_mode)');

# Set provider (n1) to read-only mode
psql_or_bail(1, "ALTER SYSTEM SET spock.readonly = 'all'");
psql_or_bail(1, "SELECT pg_reload_conf()");
system_or_bail 'sleep', '2';

# Verify provider is in read-only mode
my $readonly_status = scalar_query(1, "SHOW spock.readonly");
is($readonly_status, 'all', 'Provider is in read-only mode (spock.readonly = all)');

# Resync with truncate=true should SUCCEED even with provider readonly
# because COPY TO (reading from origin) is allowed in readonly mode
my $resync_origin_readonly = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT spock.sub_resync_table('$sub_name', 'public.test_resync', true)" 2>&1`;
like($resync_origin_readonly, qr/t/, 'Resync succeeds when origin is read-only (COPY TO allowed)');

# Wait for sync to complete
system_or_bail 'sleep', '10';

# Verify subscriber now has 4 rows after resync
my $count_after_origin_readonly = scalar_query(2, "SELECT COUNT(*) FROM test_resync");
is($count_after_origin_readonly, '4', 'Subscriber has 4 rows after resync with origin readonly');

# Reset provider to writable
psql_or_bail(1, "ALTER SYSTEM RESET spock.readonly");
psql_or_bail(1, "SELECT pg_reload_conf()");
system_or_bail 'sleep', '2';

# Verify provider is writable again
my $readonly_off = scalar_query(1, "SHOW spock.readonly");
is($readonly_off, 'off', 'Provider is writable again (spock.readonly = off)');

# =============================================================================
# Test subscriber readonly case - should FAIL
# =============================================================================
# If spock.readonly is set on the subscriber, the resync would truncate the
# table but then fail when trying to insert the copied data (COPY FROM blocked),
# causing data loss. The fix checks subscriber readonly before truncating.

# Add a 5th row on provider using repair_mode (won't replicate)
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_resync (name, value) VALUES ('test5', 500); COMMIT;");

# Verify provider has 5 rows, subscriber still has 4
$provider_count = scalar_query(1, "SELECT COUNT(*) FROM test_resync");
is($provider_count, '5', 'Provider has 5 rows');
$sub_count = scalar_query(2, "SELECT COUNT(*) FROM test_resync");
is($sub_count, '4', 'Subscriber has 4 rows');

# Set subscriber (n2) to read-only mode
psql_or_bail(2, "ALTER SYSTEM SET spock.readonly = 'all'");
psql_or_bail(2, "SELECT pg_reload_conf()");
system_or_bail 'sleep', '2';

# Verify subscriber is in read-only mode
my $sub_readonly_status = scalar_query(2, "SHOW spock.readonly");
is($sub_readonly_status, 'all', 'Subscriber is in read-only mode (spock.readonly = all)');

# Try to resync with truncate=true while subscriber is read-only
# This should fail immediately with an error about subscriber readonly mode
my $resync_sub_readonly = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT spock.sub_resync_table('$sub_name', 'public.test_resync', true)" 2>&1`;

# Check that the error message mentions subscriber readonly
like($resync_sub_readonly, qr/subscriber is in read-only mode|readonly/i, 'Resync with truncate fails when subscriber is read-only');

# CRITICAL TEST: Data must NOT be truncated when subscriber is read-only
my $count_after_sub_readonly = scalar_query(2, "SELECT COUNT(*) FROM test_resync");
is($count_after_sub_readonly, '4', 'CRITICAL: Data preserved when subscriber is read-only (readonly check prevents truncate)');

# =============================================================================
# Test subscriber readonly + truncate=false (prevents error loop)
# =============================================================================
# Even without truncate, if subscriber readonly is set the sync worker will
# fail repeatedly in an error loop (COPY FROM blocked).

# Try resync with truncate=false while subscriber is read-only
my $resync_sub_no_truncate = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT spock.sub_resync_table('$sub_name', 'public.test_resync', false)" 2>&1`;

# Check that the error message mentions subscriber readonly
like($resync_sub_no_truncate, qr/subscriber is in read-only mode|readonly/i, 'Resync without truncate fails when subscriber is read-only');

# Reset subscriber to writable
psql_or_bail(2, "ALTER SYSTEM RESET spock.readonly");
psql_or_bail(2, "SELECT pg_reload_conf()");
system_or_bail 'sleep', '2';

# Verify subscriber is writable
my $sub_readonly_off = scalar_query(2, "SHOW spock.readonly");
is($sub_readonly_off, 'off', 'Subscriber is writable again (spock.readonly = off)');

# =============================================================================
# Final test: Resync succeeds when subscriber is writable
# =============================================================================

# Now resync with truncate=true should succeed
my $resync_ok = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT spock.sub_resync_table('$sub_name', 'public.test_resync', true)" 2>&1`;
like($resync_ok, qr/t/, 'Resync with truncate succeeds when subscriber is writable');

# Wait for sync to complete
system_or_bail 'sleep', '10';

# Verify subscriber now has 5 rows after resync
my $final_count = scalar_query(2, "SELECT COUNT(*) FROM test_resync");
is($final_count, '5', 'Subscriber has 5 rows after successful resync');

# Destroy cluster
destroy_cluster('Destroy 2-node resync readonly check test cluster');
done_testing();
