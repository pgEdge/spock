use strict;
use warnings;
use Test::More tests => 20;
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
# - pg_restored rows predate the subscription
# - Origin-change conflicts are suppressed for pre-subscription data
# - Data replicates correctly without conflicts
# - Subsequent updates also work without conflicts
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

# ---- log helpers -------------------------------------------------------------

sub get_log_size {
    my ($logfile) = @_;
    return -s $logfile || 0;
}

sub get_log_content_since {
    my ($logfile, $offset) = @_;
    open my $fh, '<', $logfile or die "Cannot open $logfile: $!";
    seek $fh, $offset, 0;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content // '';
}

sub wait_for_value {
    my ($node, $query, $expected, $timeout) = @_;
    $timeout //= 30;
    for my $i (1..($timeout * 10)) {
        my $result = scalar_query($node, $query);
        return $result if $result eq $expected;
        system_or_bail 'sleep', '0.1' if $i < $timeout * 10;
    }
    return scalar_query($node, $query);
}

# Compute path to node 2's PostgreSQL log (logging_collector writes to <datadir>/logs/)
my $n2_logfile = "$node_datadirs->[1]/logs/00$node_ports->[1].log";

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

# Configure conflict logging and origin-change detection
psql_or_bail(2, "ALTER SYSTEM SET spock.conflict_log_level = 'LOG'");
psql_or_bail(2, "ALTER SYSTEM SET spock.conflict_resolution = 'last_update_wins'");
psql_or_bail(2, "ALTER SYSTEM SET spock.log_origin_change = 'since_sub_creation'");
psql_or_bail(2, "SELECT pg_reload_conf()");

# Need to restart apply worker for GUC changes to take effect
psql_or_bail(2, "SELECT spock.sub_disable('pgdump_test_sub')");
system_or_bail 'sleep', '2';
psql_or_bail(2, "SELECT spock.sub_enable('pgdump_test_sub', true)");
system_or_bail 'sleep', '3';

# Record log position before updates
my $log_pos = get_log_size($n2_logfile);

# Make updates on node1 (publisher)
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 100 WHERE id = 1");
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 200 WHERE id = 2");
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 50 WHERE id = 3");
pass('Updates executed on node1');

# Wait for replication by polling for data
my $alice_balance_n1 = scalar_query(1, "SELECT balance FROM customer_data WHERE id = 1");
my $alice_balance_n2 = wait_for_value(2,
    "SELECT balance FROM customer_data WHERE id = 1",
    $alice_balance_n1);
is($alice_balance_n1, $alice_balance_n2, 'Balance replicated correctly (data matches)');

# =============================================================================
# PART 6: Verify conflicts occurred with local_origin = NULL
# =============================================================================

diag("=== Part 6: Verify NO conflicts for pg_restored (pre-subscription) data ===");

# Allow time for log flushing
system_or_bail 'sleep', '2';
my $log_content = get_log_content_since($n2_logfile, $log_pos);

# pg_restored rows predate the subscription, so origin-change conflicts should
# be suppressed (skip pre-subscription origin-change conflicts)
unlike($log_content, qr/CONFLICT:.*update_origin_differs on relation public\.customer_data/,
    'No origin-change conflicts logged for pg_restored (pre-subscription) data');

# Verify data was applied without conflict (rows updated correctly)
my $bob_balance_n1 = scalar_query(1, "SELECT balance FROM customer_data WHERE id = 2");
my $bob_balance_n2 = wait_for_value(2,
    "SELECT balance FROM customer_data WHERE id = 2",
    $bob_balance_n1);
is($bob_balance_n1, $bob_balance_n2, 'Bob balance replicated correctly');

my $charlie_balance_n1 = scalar_query(1, "SELECT balance FROM customer_data WHERE id = 3");
my $charlie_balance_n2 = wait_for_value(2,
    "SELECT balance FROM customer_data WHERE id = 3",
    $charlie_balance_n1);
is($charlie_balance_n1, $charlie_balance_n2, 'Charlie balance replicated correctly');

pass('Pre-subscription data updates applied without conflicts');


# =============================================================================
# PART 7: Verify post-subscription origin change IS logged
# =============================================================================

diag("=== Part 7: Verify post-subscription origin change IS logged ===");

# Update locally on node 2 to change the origin (becomes locally-written,
# with a commit timestamp after subscription creation)
psql_or_bail(2, "UPDATE customer_data SET balance = balance + 1 WHERE id = 4");

my $log_pos_part7 = get_log_size($n2_logfile);

# Now update the same row from node 1 — this should trigger an origin-change conflict
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 500 WHERE id = 4");
my $diana_balance_n1 = scalar_query(1, "SELECT balance FROM customer_data WHERE id = 4");
my $diana_balance_n2 = wait_for_value(2,
    "SELECT balance FROM customer_data WHERE id = 4",
    $diana_balance_n1);
is($diana_balance_n1, $diana_balance_n2, 'Post-subscription update replicated correctly');

system_or_bail 'sleep', '2';
my $log_part7 = get_log_content_since($n2_logfile, $log_pos_part7);
like($log_part7, qr/CONFLICT:.*update_origin_differs on relation public\.customer_data/,
    'Origin-change conflict IS logged for post-subscription local update');

# =============================================================================
# PART 8: Verify data is identical despite conflicts
# =============================================================================

diag("=== Part 8: Verify data is identical after all updates ===");

# Final data verification
my $final_checksum_n1 = scalar_query(1,
    "SELECT md5(string_agg(id::text || name || email || balance::text, ',' ORDER BY id)) FROM customer_data"
);
my $final_checksum_n2 = scalar_query(2,
    "SELECT md5(string_agg(id::text || name || email || balance::text, ',' ORDER BY id)) FROM customer_data"
);
is($final_checksum_n1, $final_checksum_n2, 'Final data checksum matches - replication worked correctly');

# =============================================================================
# PART 9: Verify subsequent updates don't cause conflicts
# =============================================================================

diag("=== Part 9: Verify subsequent replicated updates don't cause new conflicts ===");

# Record log position before the subsequent update
my $log_pos_part9 = get_log_size($n2_logfile);

# Make another update on node1
psql_or_bail(1, "UPDATE customer_data SET balance = balance + 10 WHERE id = 1");

# Wait for replication
my $expected_bal = scalar_query(1, "SELECT balance FROM customer_data WHERE id = 1");
wait_for_value(2, "SELECT balance FROM customer_data WHERE id = 1", $expected_bal);

# Check if new conflict occurred in the log
# After the first update, the row should have proper origin, so no conflict
system_or_bail 'sleep', '2';
my $log_part9 = get_log_content_since($n2_logfile, $log_pos_part9);
unlike($log_part9, qr/CONFLICT:.*update_origin_differs on relation public\.customer_data/,
    'No new conflicts after row was updated via replication (origin now tracked)');

# =============================================================================
# CLEANUP
# =============================================================================

# Drop the subscription we created (destroy_cluster expects standard naming)
psql_or_bail(2, "SELECT spock.sub_drop('pgdump_test_sub')");

# Clean up dump file
unlink $dump_file if -e $dump_file;

destroy_cluster('Cleanup pg_dump/restore conflict test cluster');
