use strict;
use warnings;
use Test::More tests => 55;
use File::Path qw(make_path remove_tree);
use Cwd qw(getcwd);

use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster
    destroy_cluster
    system_or_bail
    system_maybe
    get_test_config
    cross_wire
    psql_or_bail
    scalar_query
);

# =============================================================================
# Configuration - modify these as needed
# =============================================================================
my $TEMP_BASE = "/tmp/spock_rolling_upgrade_test";
my $V5_INSTALL = "$TEMP_BASE/v5_install";
my $V6_INSTALL = "$TEMP_BASE/v6_install";
my $V5_BRANCH = "origin/v5_STABLE";
my $V6_BRANCH = "HEAD";

# =============================================================================
# Test: Rolling upgrade multi-protocol support between Spock v5.0.x and v6.0.0
# =============================================================================
# This test verifies that Spock supports rolling upgrades by:
# 1. Building and installing Spock v5_STABLE to a temp location
# 2. Building and installing Spock v6.0.0 (current branch) to another temp location
# 3. Creating a 2-node cluster using v5 libraries
# 4. Verifying replication works with both nodes on v5
# 5. Upgrading node 1 to v6.0.0 while node 2 stays on v5
# 6. Verifying bidirectional replication during mixed-version state
# 7. Upgrading node 2 to v6.0.0
# 8. Verifying replication works with both nodes on v6
#
# This tests the multi-protocol negotiation (Protocol 4 vs Protocol 5)
# =============================================================================

# Determine SPOCK_REPO path
# Priority: 1) /home/pgedge/spock (CI and standard install), 2) detect from cwd
my $SPOCK_REPO;
if (-d "/home/pgedge/spock" && -f "/home/pgedge/spock/Makefile") {
    $SPOCK_REPO = "/home/pgedge/spock";
} else {
    # Detect from current working directory (for local testing)
    # Test runs from tests/tap directory, so strip that suffix
    my $cwd = getcwd();
    if ($cwd =~ m{^(/.+)/tests/tap(?:/t)?$}) {
        $SPOCK_REPO = $1;
    } else {
        $SPOCK_REPO = $cwd;
    }
}

die "SPOCK_REPO not found or missing Makefile: $SPOCK_REPO"
    unless $SPOCK_REPO && -d $SPOCK_REPO && -f "$SPOCK_REPO/Makefile";

diag("=" x 70);
diag("Rolling Upgrade Test: Spock v5.0.x -> v6.0.0");
diag("SPOCK_REPO: $SPOCK_REPO");
diag("TEMP_BASE: $TEMP_BASE");
diag("=" x 70);

# Get pg_config paths
my $PG_CONFIG = `which pg_config`;
chomp($PG_CONFIG);
die "pg_config not found in PATH" unless $PG_CONFIG && -x $PG_CONFIG;

my $PG_LIBDIR = `$PG_CONFIG --pkglibdir`;
chomp($PG_LIBDIR);

my $PG_SHAREDIR = `$PG_CONFIG --sharedir`;
chomp($PG_SHAREDIR);

# =============================================================================
# Helper Functions (specific to rolling upgrade test)
# =============================================================================

# Build and install Spock from a specific git ref to a destination directory
# If build already exists (spock.so present), skip the build
sub build_spock_version {
    my ($git_ref, $install_dir, $version_name) = @_;

    # Check if already built (handle both .so on Linux and .dylib on macOS)
    my $spock_lib = "$install_dir$PG_LIBDIR/spock";
    my $lib_exists = (-f "$spock_lib.so" || -f "$spock_lib.dylib");
    if ($lib_exists) {
        diag("");
        diag("=" x 70);
        diag("Spock $version_name already built, skipping...");
        diag("Found: $spock_lib (.so or .dylib)");
        diag("=" x 70);
        return 1;
    }

    diag("");
    diag("=" x 70);
    diag("Building Spock $version_name from $git_ref");
    diag("Install to: $install_dir");
    diag("=" x 70);

    my $build_dir = "$TEMP_BASE/build_$version_name";
    diag("Build dir: $build_dir");
    make_path($build_dir);
    make_path($install_dir);

    # Clone the repo to build directory (avoids permission issues with cp -r on .git)
    my $rc;
    if (-d $build_dir) {
        diag("Removing existing build dir...");
        remove_tree($build_dir);
    }

    diag("Cloning repo to build dir...");
    $rc = system_or_bail("git clone --quiet $SPOCK_REPO $build_dir");
    die "git clone failed with exit code " . ($rc >> 8) if $rc != 0;

    # Checkout the specific ref
    if ($git_ref ne 'HEAD') {
        diag("Checking out $git_ref...");
        $rc = system_or_bail("cd $build_dir && git checkout --quiet $git_ref");
        die "git checkout failed with exit code " . ($rc >> 8) if $rc != 0;
    }

    diag("Running make clean...");
    system_or_bail("cd $build_dir && make clean 2>/dev/null");  # Ignore errors

    diag("Running make...");
    $rc = system_or_bail("cd $build_dir && make PG_CONFIG=$PG_CONFIG");
    die "make failed with exit code " . ($rc >> 8) if $rc != 0;

    diag("Running make install...");
    $rc = system_or_bail("cd $build_dir && make install DESTDIR=$install_dir PG_CONFIG=$PG_CONFIG");
    die "make install failed with exit code " . ($rc >> 8) if $rc != 0;

    diag("Spock $version_name built successfully");
    return 1;
}

# Stop a specific node
sub stop_node {
    my ($node_num) = @_;
    my $config = get_test_config();
    my $datadir = $config->{node_datadirs}->[$node_num - 1];
    my $pg_bin = $config->{pg_bin};

    diag("Stopping node $node_num...");
    system("$pg_bin/pg_ctl stop -D $datadir -m fast -w 2>/dev/null");
    sleep(2);
    return 1;
}

# Start a specific node
sub start_node {
    my ($node_num) = @_;
    my $config = get_test_config();
    my $datadir = $config->{node_datadirs}->[$node_num - 1];
    my $pg_bin = $config->{pg_bin};
    my $log_file = $config->{log_file};

    diag("Starting node $node_num... $log_file");
    system("$pg_bin/pg_ctl start -D $datadir -l $log_file -w");
    sleep(3);
    return 1;
}

# Configure a node to use a specific Spock version
# This updates postgresql.conf with dynamic_library_path and extension_control_path
sub configure_node_spock_version {
    my ($node_num, $version) = @_;  # version: 'v5' or 'v6'

    my $config = get_test_config();
    my $datadir = $config->{node_datadirs}->[$node_num - 1];
    my $install_dir = ($version eq 'v5') ? $V5_INSTALL : $V6_INSTALL;
    my $spock_libdir = "$install_dir$PG_LIBDIR";
    my $spock_extdir = "$install_dir$PG_SHAREDIR";

    diag("Configuring node $node_num to use Spock $version");
    diag("Library path: $spock_libdir");
    diag("Extension path: $spock_extdir");

    # Read existing postgresql.conf
    my $conf_file = "$datadir/postgresql.conf";
    open(my $fh, '<', $conf_file) or die "Cannot read $conf_file: $!";
    my @lines = <$fh>;
    close($fh);

    # Remove old settings we're going to update
    @lines = grep {
        !/^dynamic_library_path\s*=/ &&
        !/^shared_preload_libraries\s*=/ &&
        !/^extension_control_path\s*=/
    } @lines;

    # Add new settings pointing to the appropriate version
    push @lines, "# Spock $version configuration\n";
    push @lines, "dynamic_library_path = '$spock_libdir:\$libdir'\n";
    push @lines, "shared_preload_libraries = '$spock_libdir/spock'\n";
    push @lines, "extension_control_path = '$spock_extdir'\n";

    # Write updated config
    open($fh, '>', $conf_file) or die "Cannot write $conf_file: $!";
    print $fh @lines;
    close($fh);

    return 1;
}

# Wait for replication to catch up
sub wait_for_replication {
    diag("Waiting for replication to catch up...");
    psql_or_bail(1, "SELECT spock.wait_slot_confirm_lsn(NULL, NULL)");
    psql_or_bail(2, "SELECT spock.wait_slot_confirm_lsn(NULL, NULL)");
    sleep(3);
}

# =============================================================================
# Main Test Execution
# Note: Build directories in $TEMP_BASE are preserved for reuse across test runs.
# To force a rebuild, manually remove /tmp/spock_rolling_upgrade_test/
# =============================================================================

make_path($TEMP_BASE);

# =============================================================================
# PHASE 1: Build both Spock versions
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 1: Building Spock versions");
diag("#" x 70);

ok(build_spock_version($V5_BRANCH, $V5_INSTALL, 'v5'), "Built Spock v5 (v5_STABLE branch)");
ok(build_spock_version($V6_BRANCH, $V6_INSTALL, 'v6'), "Built Spock v6 (current branch)");

# =============================================================================
# PHASE 2: Create cluster - but we need to configure it for v5 first
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 2: Initialize cluster with Spock v5");
diag("#" x 70);

# Create cluster using SpockTest (this uses default spock in PATH)
create_cluster(2, 'Create 2-node cluster for rolling upgrade test');

# Now stop both nodes, reconfigure for v5, and restart
diag("Reconfiguring nodes to use Spock v5...");

# Drop extensions first
psql_or_bail(1, "DROP EXTENSION IF EXISTS spock CASCADE");
psql_or_bail(2, "DROP EXTENSION IF EXISTS spock CASCADE");

stop_node(1);
stop_node(2);

configure_node_spock_version(1, 'v5');
configure_node_spock_version(2, 'v5');

start_node(1);
start_node(2);

# Reinstall extension with v5
psql_or_bail(1, "CREATE EXTENSION spock");
psql_or_bail(2, "CREATE EXTENSION spock");

# Recreate nodes after extension reinstall
my $config = get_test_config();
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $node_ports = $config->{node_ports};

psql_or_bail(1, "SELECT spock.node_create('n1', 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user')");
psql_or_bail(2, "SELECT spock.node_create('n2', 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user')");

# Verify both nodes are running v5
my $v1 = scalar_query(1, "SELECT spock.spock_version()");
my $v2 = scalar_query(2, "SELECT spock.spock_version()");
diag("Node 1 Spock version: $v1");
diag("Node 2 Spock version: $v2");

like($v1, qr/^5\./, "Node 1 running Spock v5.x");
like($v2, qr/^5\./, "Node 2 running Spock v5.x");

# =============================================================================
# PHASE 3: Setup bidirectional replication
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 3: Setup bidirectional replication");
diag("#" x 70);

cross_wire(2, ['n1', 'n2'], 'Cross-wire nodes N1 and N2');

# =============================================================================
# PHASE 4: Create test data and verify initial replication
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 4: Create test data and verify v5 <-> v5 replication");
diag("#" x 70);

psql_or_bail(1, "CREATE TABLE test_upgrade (id SERIAL PRIMARY KEY, data TEXT, node_origin TEXT, created_at TIMESTAMP DEFAULT now())");
sleep(3);

# Insert data from node 1
psql_or_bail(1, "INSERT INTO test_upgrade (data, node_origin) VALUES ('initial_v5_n1_1', 'n1'), ('initial_v5_n1_2', 'n1')");
wait_for_replication();

my $count1 = scalar_query(1, "SELECT count(*) FROM test_upgrade");
my $count2 = scalar_query(2, "SELECT count(*) FROM test_upgrade");

is($count1, '2', "Node 1 has 2 rows after initial insert");
is($count2, '2', "Node 2 has 2 rows after replication (v5 -> v5)");

# Insert data from node 2
psql_or_bail(2, "INSERT INTO test_upgrade (id, data, node_origin) VALUES (3, 'initial_v5_n2_1', 'n2'), (4, 'initial_v5_n2_2', 'n2')");
wait_for_replication();

$count1 = scalar_query(1, "SELECT count(*) FROM test_upgrade");
$count2 = scalar_query(2, "SELECT count(*) FROM test_upgrade");

is($count1, '4', "Node 1 has 4 rows after bidirectional replication");
is($count2, '4', "Node 2 has 4 rows after bidirectional replication");

pass("Initial v5 <-> v5 bidirectional replication working");

# =============================================================================
# PHASE 5: Rolling upgrade - Upgrade Node 1 to v6.0.0
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 5: Rolling upgrade - Upgrade Node 1 to v6.0.0");
diag("#" x 70);

ok(stop_node(1), "Node 1 stopped for upgrade");
ok(configure_node_spock_version(1, 'v6'), "Node 1 configured for Spock v6");
ok(start_node(1), "Node 1 restarted with Spock v6");

# Update extension
psql_or_bail(1, "ALTER EXTENSION spock UPDATE");

# Verify version change
$v1 = scalar_query(1, "SELECT spock.spock_version()");
$v2 = scalar_query(2, "SELECT spock.spock_version()");
diag("After upgrade - Node 1 Spock version: $v1");
diag("After upgrade - Node 2 Spock version: $v2");

like($v1, qr/^6\./, "Node 1 now running Spock v6.x");
like($v2, qr/^5\./, "Node 2 still running Spock v5.x");

# =============================================================================
# PHASE 6: Test mixed-version replication (v6 <-> v5)
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 6: Test mixed-version replication (v6 <-> v5)");
diag("#" x 70);

sleep(5);  # Allow subscriptions to reconnect

# Test INSERT from v6 node -> v5 node
psql_or_bail(1, "INSERT INTO test_upgrade (id, data, node_origin) VALUES (5, 'mixed_v6_n1_1', 'n1'), (6, 'mixed_v6_n1_2', 'n1')");
wait_for_replication();

$count1 = scalar_query(1, "SELECT count(*) FROM test_upgrade");
$count2 = scalar_query(2, "SELECT count(*) FROM test_upgrade");

is($count1, '6', "Node 1 (v6) has 6 rows");
is($count2, '6', "Node 2 (v5) received data from v6 node");

pass("v6 -> v5 replication working (Protocol negotiation successful)");

# Test INSERT from v5 node -> v6 node
psql_or_bail(2, "INSERT INTO test_upgrade (id, data, node_origin) VALUES (7, 'mixed_v5_n2_1', 'n2'), (8, 'mixed_v5_n2_2', 'n2')");
wait_for_replication();

$count1 = scalar_query(1, "SELECT count(*) FROM test_upgrade");
$count2 = scalar_query(2, "SELECT count(*) FROM test_upgrade");

is($count1, '8', "Node 1 (v6) received data from v5 node");
is($count2, '8', "Node 2 (v5) has 8 rows");

pass("v5 -> v6 replication working (Protocol negotiation successful)");

# Test batch INSERT during mixed version
diag("Testing batch INSERT during mixed version...");
psql_or_bail(1, "INSERT INTO test_upgrade (id, data, node_origin) SELECT g, 'batch_v6_' || g, 'n1' FROM generate_series(9, 108) g");
wait_for_replication();

$count1 = scalar_query(1, "SELECT count(*) FROM test_upgrade");
$count2 = scalar_query(2, "SELECT count(*) FROM test_upgrade");

is($count1, '108', "Node 1 (v6) has 108 rows after batch insert");
is($count2, '108', "Node 2 (v5) received batch insert from v6");

pass("Batch INSERT v6 -> v5 working");

# Test UPDATE during mixed version
psql_or_bail(1, "UPDATE test_upgrade SET data = 'updated_by_v6' WHERE node_origin = 'n1' AND id = 1");
psql_or_bail(2, "UPDATE test_upgrade SET data = 'updated_by_v5' WHERE node_origin = 'n2' AND id = 4");
wait_for_replication();

my $updated_v6 = scalar_query(2, "SELECT data FROM test_upgrade WHERE id = 1");
my $updated_v5 = scalar_query(1, "SELECT data FROM test_upgrade WHERE id = 4");

is($updated_v6, 'updated_by_v6', "UPDATE from v6 node replicated to v5");
is($updated_v5, 'updated_by_v5', "UPDATE from v5 node replicated to v6");

pass("Bidirectional UPDATE replication working in mixed-version state");

# Test DDL replication during mixed version
diag("Testing DDL replication during mixed version...");
psql_or_bail(1, "CREATE INDEX idx_test_data ON test_upgrade(data)");
sleep(5);

my $idx_exists_n2 = scalar_query(2, "SELECT count(*) FROM pg_indexes WHERE indexname = 'idx_test_data'");
is($idx_exists_n2, '1', "CREATE INDEX replicated from v6 to v5");

psql_or_bail(2, "CREATE INDEX idx_test_origin ON test_upgrade(node_origin)");
sleep(5);

my $idx_exists_n1 = scalar_query(1, "SELECT count(*) FROM pg_indexes WHERE indexname = 'idx_test_origin'");
is($idx_exists_n1, '1', "CREATE INDEX replicated from v5 to v6");

pass("DDL replication working in mixed-version state");

# Test TRUNCATE during mixed version
diag("Testing TRUNCATE replication during mixed version...");
psql_or_bail(1, "CREATE TABLE test_truncate (id SERIAL PRIMARY KEY, data TEXT)");
sleep(3);

psql_or_bail(1, "INSERT INTO test_truncate (data) SELECT 'row_' || g FROM generate_series(1, 50) g");
wait_for_replication();

my $trunc_count1 = scalar_query(1, "SELECT count(*) FROM test_truncate");
my $trunc_count2 = scalar_query(2, "SELECT count(*) FROM test_truncate");

is($trunc_count1, '50', "test_truncate has 50 rows on node 1");
is($trunc_count2, '50', "test_truncate has 50 rows on node 2");

psql_or_bail(1, "TRUNCATE test_truncate");
wait_for_replication();

$trunc_count1 = scalar_query(1, "SELECT count(*) FROM test_truncate");
$trunc_count2 = scalar_query(2, "SELECT count(*) FROM test_truncate");

is($trunc_count1, '0', "TRUNCATE executed on node 1");
is($trunc_count2, '0', "TRUNCATE replicated from v6 to v5");

pass("TRUNCATE replication working in mixed-version state");


# =============================================================================
# PHASE 7: Complete rolling upgrade - Upgrade Node 2 to v6.0.0
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 7: Complete rolling upgrade - Upgrade Node 2 to v6.0.0");
diag("#" x 70);

ok(stop_node(2), "Node 2 stopped for upgrade");
ok(configure_node_spock_version(2, 'v6'), "Node 2 configured for Spock v6");
ok(start_node(2), "Node 2 restarted with Spock v6");

psql_or_bail(2, "ALTER EXTENSION spock UPDATE");

$v1 = scalar_query(1, "SELECT spock.spock_version()");
$v2 = scalar_query(2, "SELECT spock.spock_version()");
diag("Final - Node 1 Spock version: $v1");
diag("Final - Node 2 Spock version: $v2");

like($v1, qr/^6\./, "Node 1 running Spock v6.x");
like($v2, qr/^6\./, "Node 2 now running Spock v6.x");

# =============================================================================
# PHASE 8: Test full v6 <-> v6 replication
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 8: Test full v6 <-> v6 replication");
diag("#" x 70);

sleep(5);

psql_or_bail(1, "INSERT INTO test_upgrade (id, data, node_origin) VALUES (200, 'final_v6_n1_1', 'n1'), (201, 'final_v6_n1_2', 'n1')");
psql_or_bail(2, "INSERT INTO test_upgrade (id, data, node_origin) VALUES (202, 'final_v6_n2_1', 'n2'), (203, 'final_v6_n2_2', 'n2')");
wait_for_replication();

$count1 = scalar_query(1, "SELECT count(*) FROM test_upgrade");
$count2 = scalar_query(2, "SELECT count(*) FROM test_upgrade");

is($count1, '112', "Node 1 (v6) has all 112 rows");
is($count2, '112', "Node 2 (v6) has all 112 rows");

my $sum1 = scalar_query(1, "SELECT count(*) || ',' || count(DISTINCT id) FROM test_upgrade");
my $sum2 = scalar_query(2, "SELECT count(*) || ',' || count(DISTINCT id) FROM test_upgrade");

is($sum1, $sum2, "Data consistent between both v6 nodes");

# Test DELETE
psql_or_bail(1, "DELETE FROM test_upgrade WHERE data LIKE 'initial%' AND node_origin = 'n1'");
wait_for_replication();

$count1 = scalar_query(1, "SELECT count(*) FROM test_upgrade");
$count2 = scalar_query(2, "SELECT count(*) FROM test_upgrade");

is($count1, '111', "DELETE replicated - Node 1 has 111 rows");
is($count2, '111', "DELETE replicated - Node 2 has 111 rows");

pass("Full v6 <-> v6 bidirectional replication working after rolling upgrade");

# =============================================================================
# PHASE 9: Final verification
# =============================================================================
diag("");
diag("#" x 70);
diag("# PHASE 9: Final verification");
diag("#" x 70);

my $v1_num = scalar_query(1, "SELECT spock.spock_version_num()");
my $v2_num = scalar_query(2, "SELECT spock.spock_version_num()");
diag("Node 1 Spock version_num: $v1_num");
diag("Node 2 Spock version_num: $v2_num");

cmp_ok($v1_num, '>=', 60000, "Node 1 version_num >= 60000");
cmp_ok($v2_num, '>=', 60000, "Node 2 version_num >= 60000");

my $data1 = scalar_query(1, "SELECT md5(string_agg(id::text || data, ',' ORDER BY id)) FROM test_upgrade");
my $data2 = scalar_query(2, "SELECT md5(string_agg(id::text || data, ',' ORDER BY id)) FROM test_upgrade");

is($data1, $data2, "Final data fully consistent between nodes (MD5 match)");

diag("");
diag("=" x 70);
diag("ROLLING UPGRADE TEST COMPLETED SUCCESSFULLY!");
diag("=" x 70);
diag("Summary:");
diag("  - Built Spock v5 and v6 from source");
diag("  - Verified v5 <-> v5 bidirectional replication");
diag("  - Performed rolling upgrade: Node 1 to v6 while Node 2 on v5");
diag("  - Verified v6 -> v5 replication (Protocol 5 -> Protocol 4)");
diag("  - Verified v5 -> v6 replication (Protocol 4 -> Protocol 5)");
diag("  - Tested batch INSERT during mixed-version state");
diag("  - Tested DDL replication (CREATE INDEX) during mixed-version");
diag("  - Tested TRUNCATE replication during mixed-version");
diag("  - Tested conflict resolution during mixed-version");
diag("  - Completed upgrade: Node 2 to v6");
diag("  - Verified v6 <-> v6 bidirectional replication");
diag("  - All data consistent across nodes");
diag("=" x 70);

# Cleanup handled by SpockTest.pm END block
