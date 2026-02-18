use strict;
use warnings;
use Test::More tests => 27;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config scalar_query psql_or_bail);

# =============================================================================
# Test: 014_pgdump_restore_conflict.pl - pg_dump/restore Conflict Scenario
# =============================================================================
# This test reproduces a common customer setup pattern:
#
# 1. Customer has existing PostgreSQL database
# 2. They want to set up multi-master replication
# 3. They use pg_dump/pg_restore to initialize the subscriber
# 4. They create subscription after restore
# 5. They observe conflicts even though data is identical
#
# Root Cause:
# - Rows loaded via pg_dump have no replication origin tracking (origin = NULL)
# - When updates arrive via replication, spock detects "conflict" because
#   the local row exists but has no origin
# - This causes UPDATE_UPDATE conflicts with identical data
#
# This test verifies:
# - The conflict behavior is reproducible
# - local_origin = NULL for pg_dump loaded rows (SPOC-442)
# - Conflicts occur even with identical data
# - Resolution is apply_remote (correct behavior)
# =============================================================================

# Create 2-node cluster
create_cluster(2, 'Create 2-node cluster for pg_dump/restore test');

my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

# =============================================================================
# PART 1: Setup - Create data on node1 (publisher/writer)
# =============================================================================

diag("=== Part 1: Create initial data on publisher (node1) ===");

# Create test table on node1 only (no DDL replication yet)
psql_or_bail(1, "
    CREATE TABLE customer_data (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        email VARCHAR(100) UNIQUE,
        balance DECIMAL(10,2) DEFAULT 0,
        updated_at TIMESTAMP DEFAULT now()
    )
");
pass('Test table created on node1');

# Insert initial data
psql_or_bail(1, "
    INSERT INTO customer_data (name, email, balance) VALUES
    ('Alice', 'alice\@example.com', 1000.00),
    ('Bob', 'bob\@example.com', 2500.50),
    ('Charlie', 'charlie\@example.com', 750.25),
    ('Diana', 'diana\@example.com', 3200.00),
    ('Eve', 'eve\@example.com', 150.75)
");
pass('Initial data inserted on node1');

my $node1_count = scalar_query(1, "SELECT COUNT(*) FROM customer_data");
is($node1_count, '5', 'Node1 has 5 rows');

# =============================================================================
# PART 2: pg_dump from node1, pg_restore to node2
# =============================================================================

diag("=== Part 2: pg_dump/pg_restore to subscriber (node2) ===");

# pg_dump the table from node1
my $dump_file = "/tmp/customer_data_dump.sql";
system_or_bail("$pg_bin/pg_dump",
    "-h", $host,
    "-p", $node_ports->[0],
    "-U", $db_user,
    "-d", $dbname,
    "-t", "customer_data",
    "--no-owner",
    "--no-acl",
    "-f", $dump_file
);
pass('pg_dump completed from node1');

# pg_restore (actually psql since it's plain SQL) to node2
system_or_bail("$pg_bin/psql",
    "-h", $host,
    "-p", $node_ports->[1],
    "-U", $db_user,
    "-d", $dbname,
    "-f", $dump_file
);
pass('pg_restore completed to node2');

# Verify data exists on node2
my $node2_count = scalar_query(2, "SELECT COUNT(*) FROM customer_data");
is($node2_count, '5', 'Node2 has 5 rows after pg_restore');

# Verify data is identical
my $node1_checksum = scalar_query(1,
    "SELECT md5(string_agg(id::text || name || email || balance::text, ',' ORDER BY id)) FROM customer_data"
);
my $node2_checksum = scalar_query(2,
    "SELECT md5(string_agg(id::text || name || email || balance::text, ',' ORDER BY id)) FROM customer_data"
);
is($node1_checksum, $node2_checksum, 'Data checksum matches between nodes');

# =============================================================================
# PART 3: Verify pg_restore rows have no origin tracking
# =============================================================================

diag("=== Part 3: Verify rows have no origin tracking ===");

# Check commit timestamps exist (track_commit_timestamp should be on)
my $has_commit_ts = scalar_query(2, "SHOW track_commit_timestamp");
is($has_commit_ts, 'on', 'track_commit_timestamp is enabled');

# Get commit timestamps of rows on node2
# Rows from pg_restore will have timestamps clustered around restore time
my $row_timestamps = scalar_query(2, "
    SELECT COUNT(DISTINCT date_trunc('second', pg_xact_commit_timestamp(xmin)))
    FROM customer_data
");
diag("Distinct commit timestamp seconds for pg_restore rows: $row_timestamps");
ok($row_timestamps <= 2, 'pg_restore rows have clustered commit timestamps (same transaction)');

# =============================================================================
# PART 4: Create subscription AFTER pg_restore
# =============================================================================

diag("=== Part 4: Create subscription after pg_restore ===");

# Check if table is already in replication set (DDL replication may have added it)
my $in_repset = scalar_query(1,
    "SELECT EXISTS (SELECT 1 FROM spock.replication_set_table WHERE set_reloid = 'customer_data'::regclass)"
);
if ($in_repset eq 't') {
    pass('Table already in replication set (auto-added by DDL replication)');
} else {
    psql_or_bail(1, "SELECT spock.repset_add_table('default', 'customer_data')");
    pass('Table added to replication set on node1');
}

# Create subscription on node2 -> node1
my $conn_string = "host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password";
psql_or_bail(2, "
    SELECT spock.sub_create(
        'pgdump_test_sub',
        '$conn_string',
        ARRAY['default'],
        synchronize_structure := false,
        synchronize_data := false
    )
");
pass('Subscription created on node2 (no sync - data already exists from pg_restore)');

# Wait for subscription to be ready
system_or_bail 'sleep', '5';

my $sub_status = scalar_query(2, "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'pgdump_test_sub'");
is($sub_status, 't', 'Subscription is enabled');

# =============================================================================
# PART 5: Make updates on node1 and verify conflicts
# =============================================================================

diag("=== Part 5: Make updates on publisher, verify conflicts ===");

# Clear any existing conflicts
psql_or_bail(2, "TRUNCATE spock.resolutions");

# Configure conflict logging - ensure conflicts are logged to table
psql_or_bail(2, "ALTER SYSTEM SET spock.conflict_log_level = 'LOG'");
psql_or_bail(2, "ALTER SYSTEM SET spock.save_resolutions = true");
psql_or_bail(2, "ALTER SYSTEM SET spock.conflict_resolution = 'last_update_wins'");
psql_or_bail(2, "SELECT pg_reload_conf()");

# Need to restart apply worker for GUC changes to take effect
psql_or_bail(2, "SELECT spock.sub_disable('pgdump_test_sub')");
system_or_bail 'sleep', '2';
psql_or_bail(2, "SELECT spock.sub_enable('pgdump_test_sub', true)");
system_or_bail 'sleep', '3';


# Make updates on node1 (publisher)
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 100 WHERE id = 1");
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 200 WHERE id = 2");
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 50 WHERE id = 3");
pass('Updates executed on node1');

# Wait for replication
system_or_bail 'sleep', '5';

# Verify data was replicated correctly
my $alice_balance_n1 = scalar_query(1, "SELECT balance FROM customer_data WHERE id = 1");
my $alice_balance_n2 = scalar_query(2, "SELECT balance FROM customer_data WHERE id = 1");
is($alice_balance_n1, $alice_balance_n2, 'Balance replicated correctly (data matches)');

# =============================================================================
# PART 6: Verify conflicts occurred with local_origin = NULL
# =============================================================================

diag("=== Part 6: Verify conflicts with local_origin = NULL ===");

# Check for conflicts
my $conflict_count = scalar_query(2, "SELECT COUNT(*) FROM spock.resolutions");
ok($conflict_count >= 3, "Conflicts were logged (count: $conflict_count)");

# Verify conflict type is update_origin_differs (v6) or update_update (v5)
# This conflict type indicates the local row has a different/no origin than incoming
my $origin_conflicts = scalar_query(2,
    "SELECT COUNT(*) FROM spock.resolutions WHERE conflict_type IN ('update_origin_differs', 'update_update')"
);
ok($origin_conflicts >= 3, "Origin-related conflicts occurred (count: $origin_conflicts)");

# KEY VERIFICATION: local_origin should be NULL (no replication origin)
# This proves the rows from pg_dump have no origin tracking
# SPOC-442: We now store NULL instead of -1 for unknown origin
my $no_origin_conflicts = scalar_query(2,
    "SELECT COUNT(*) FROM spock.resolutions WHERE local_origin IS NULL"
);
ok($no_origin_conflicts >= 3, "Conflicts have local_origin = NULL (no origin tracking): $no_origin_conflicts");

# Verify resolution is apply_remote (v6)
my $remote_apply_count = scalar_query(2,
    "SELECT COUNT(*) FROM spock.resolutions WHERE conflict_resolution = 'apply_remote'"
);
ok($remote_apply_count >= 3, "Resolution is apply_remote (count: $remote_apply_count)");

# Display conflict details for debugging
my $conflict_details = `$pg_bin/psql -h $host -p $node_ports->[1] -U $db_user -d $dbname -c "
    SELECT conflict_type, conflict_resolution, local_origin, remote_origin
    FROM spock.resolutions
    ORDER BY log_time DESC
    LIMIT 5
" 2>&1`;
diag("Conflict details:\n$conflict_details");


# =============================================================================
# PART 7: Verify data is identical despite conflicts
# =============================================================================

diag("=== Part 7: Verify data is identical despite conflicts ===");

# Final data verification
my $final_checksum_n1 = scalar_query(1,
    "SELECT md5(string_agg(id::text || name || email || balance::text, ',' ORDER BY id)) FROM customer_data"
);
my $final_checksum_n2 = scalar_query(2,
    "SELECT md5(string_agg(id::text || name || email || balance::text, ',' ORDER BY id)) FROM customer_data"
);
is($final_checksum_n1, $final_checksum_n2, 'Final data checksum matches - replication worked correctly');

# =============================================================================
# PART 8: Verify subsequent updates don't cause conflicts
# =============================================================================

diag("=== Part 8: Verify subsequent updates don't cause new conflicts ===");

# Clear conflicts
psql_or_bail(2, "TRUNCATE spock.resolutions");

# Get current conflict count (should be 0)
my $pre_update_conflicts = scalar_query(2, "SELECT COUNT(*) FROM spock.resolutions");
is($pre_update_conflicts, '0', 'Conflict table cleared');

# Make another update on node1
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 10 WHERE id = 1");
system_or_bail 'sleep', '3';

# Check if new conflict occurred
# After the first update, the row should have proper origin, so no conflict
my $post_update_conflicts = scalar_query(2, "SELECT COUNT(*) FROM spock.resolutions");

if ($post_update_conflicts eq '0') {
    pass('No new conflicts after row was updated via replication (origin now tracked)');
} else {
    # This might still conflict if the row wasn't properly updated
    diag("Unexpected conflicts after second update: $post_update_conflicts");
    my $new_conflict_origin = scalar_query(2,
        "SELECT local_origin FROM spock.resolutions ORDER BY conflict_time DESC LIMIT 1"
    );
    diag("New conflict local_origin: $new_conflict_origin");
    fail('Expected no new conflicts after row has proper origin');
}

# =============================================================================
# CLEANUP
# =============================================================================

# Drop the subscription we created (destroy_cluster expects standard naming)
psql_or_bail(2, "SELECT spock.sub_drop('pgdump_test_sub')");

# Clean up dump file
unlink $dump_file if -e $dump_file;

destroy_cluster('Cleanup pg_dump/restore conflict test cluster');
