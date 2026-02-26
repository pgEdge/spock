use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok
                 get_test_config scalar_query psql_or_bail);
use Cwd;

# =============================================================================
# Test: 013_origin_change_restore.pl - Origin-change logging after pg_restore
# =============================================================================
# Verify that:
#   1. pg_restored data (predating subscription) does NOT produce origin-change
#      conflict log entries when log_origin_change = 'since_sub_creation'
#   2. Post-subscription origin changes ARE logged (since_sub_creation)
#   3. Mode 'none' suppresses all origin-change logging
#   4. Mode 'remote_only_differs' suppresses logging for locally-written tuples
#
# Origin-change conflicts are written to the PostgreSQL log (not spock.resolutions),
# so all assertions check the log file content.

# ---- helpers ----------------------------------------------------------------

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

# ---- cluster setup (5 TAP tests emitted by create_cluster) -----------------
create_cluster(2, 'Create 2-node cluster for origin-change restore test');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};

# Compute path to node 2's PostgreSQL log
my $parent_dir  = Cwd::abs_path(getcwd() . "/..");
my $n2_logfile  = "$parent_dir/logs/00$node_ports->[1].log";

# Verify both nodes are present
my $n1 = scalar_query(1, "SELECT EXISTS (SELECT 1 FROM spock.node WHERE node_name = 'n1')");
is($n1, 't', 'Node n1 exists');

my $n2 = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM spock.node WHERE node_name = 'n2')");
is($n2, 't', 'Node n2 exists');

# ---- Step 1: create table + seed data on node 1 ----------------------------
psql_or_bail(1, "CREATE TABLE test_origin (id INTEGER PRIMARY KEY, data TEXT)");
psql_or_bail(1, "INSERT INTO test_origin VALUES (1, 'row-A'), (2, 'row-B'), (3, 'row-C')");

my $count_n1 = scalar_query(1, "SELECT COUNT(*) FROM test_origin");
is($count_n1, '3', 'Node 1 has 3 rows after INSERT');

# ---- Step 2: pg_dump node 1 ------------------------------------------------
my $dump_file = '/tmp/test_origin_dump_$$.dump';
system_or_bail("$pg_bin/pg_dump", '-p', $node_ports->[0],
               '-d', $dbname, '-t', 'test_origin', '-Fc', '-f', $dump_file);
pass('pg_dump from node 1 succeeded');

# ---- Step 3: pg_restore to node 2 ------------------------------------------
system_or_bail("$pg_bin/pg_restore", '-p', $node_ports->[1],
               '-d', $dbname, $dump_file);
pass('pg_restore to node 2 succeeded');

my $count_n2 = scalar_query(2, "SELECT COUNT(*) FROM test_origin");
is($count_n2, '3', 'Node 2 has 3 rows after pg_restore');

# ---- Step 4: enable GUC on node 2 ------------------------------------------
psql_or_bail(2, "ALTER SYSTEM SET spock.log_origin_change = 'since_sub_creation'");
psql_or_bail(2, "SELECT pg_reload_conf()");
pass('Enabled log_origin_change = since_sub_creation on node 2');

# ---- Step 5: create repset + subscription -----------------------------------
psql_or_bail(1, "SELECT spock.repset_create('origin_test_repset')");
psql_or_bail(1, "SELECT spock.repset_add_table('origin_test_repset', 'test_origin')");
pass('Created repset and added table on node 1');

my $conn_string = "host=$host dbname=$dbname port=$node_ports->[0] "
                . "user=$db_user password=$db_password";
psql_or_bail(2,
    "SELECT spock.sub_create('sub_origin_test', "
    . "'$conn_string', "
    . "ARRAY['origin_test_repset'], false, false)");

my $sub_exists = scalar_query(2,
    "SELECT EXISTS (SELECT 1 FROM spock.subscription "
    . "WHERE sub_name = 'sub_origin_test')");
is($sub_exists, 't', 'Subscription sub_origin_test created');

# Wait for the subscription to become active (poll up to 30s)
psql_or_bail(2, "DO \$\$
BEGIN
    FOR i IN 1..300 LOOP
        IF EXISTS (SELECT 1 FROM spock.sub_show_status()
                   WHERE subscription_name = 'sub_origin_test'
                     AND status = 'replicating') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    RAISE EXCEPTION 'subscription did not reach replicating state';
END;
\$\$");

# =============================================================================
# Test 1: since_sub_creation — pg_restored data should NOT produce log entry
# =============================================================================
my $log_pos = get_log_size($n2_logfile);

psql_or_bail(1, "UPDATE test_origin SET data = 'row-A-updated' WHERE id = 1");

my $val = wait_for_value(2,
    "SELECT data FROM test_origin WHERE id = 1",
    'row-A-updated');
is($val, 'row-A-updated', 'UPDATE replicated to node 2');

# Allow time for any log flushing
system_or_bail 'sleep', '2';
my $log_content = get_log_content_since($n2_logfile, $log_pos);
unlike($log_content, qr/CONFLICT:.*remote UPDATE on relation public\.test_origin/,
    'since_sub_creation: no conflict logged for pg_restored data');

# =============================================================================
# Test 2: since_sub_creation — post-subscription data SHOULD produce log entry
# =============================================================================
# Update locally on node 2 to change origin (becomes locally-written,
# with a commit timestamp after subscription creation)
psql_or_bail(2, "UPDATE test_origin SET data = 'local-1' WHERE id = 1");

$log_pos = get_log_size($n2_logfile);

psql_or_bail(1, "UPDATE test_origin SET data = 'from-n1-v2' WHERE id = 1");
$val = wait_for_value(2,
    "SELECT data FROM test_origin WHERE id = 1",
    'from-n1-v2');
BAIL_OUT("UPDATE did not replicate") unless $val eq 'from-n1-v2';

system_or_bail 'sleep', '2';
$log_content = get_log_content_since($n2_logfile, $log_pos);
like($log_content, qr/CONFLICT:.*remote UPDATE on relation public\.test_origin/,
    'since_sub_creation: conflict logged for post-subscription data');

# =============================================================================
# Test 3: mode 'none' — suppresses all origin-change logging
# =============================================================================
psql_or_bail(2, "ALTER SYSTEM SET spock.log_origin_change = 'none'");
psql_or_bail(2, "SELECT pg_reload_conf()");

# Update locally to change origin
psql_or_bail(2, "UPDATE test_origin SET data = 'local-2' WHERE id = 2");

$log_pos = get_log_size($n2_logfile);

psql_or_bail(1, "UPDATE test_origin SET data = 'from-n1-v2b' WHERE id = 2");
$val = wait_for_value(2,
    "SELECT data FROM test_origin WHERE id = 2",
    'from-n1-v2b');
BAIL_OUT("UPDATE did not replicate") unless $val eq 'from-n1-v2b';

system_or_bail 'sleep', '2';
$log_content = get_log_content_since($n2_logfile, $log_pos);
unlike($log_content, qr/CONFLICT:.*remote UPDATE on relation public\.test_origin/,
    'none: no conflict logged');

# =============================================================================
# Test 4: remote_only_differs — locally-written tuple NOT logged
# =============================================================================
psql_or_bail(2, "ALTER SYSTEM SET spock.log_origin_change = 'remote_only_differs'");
psql_or_bail(2, "SELECT pg_reload_conf()");

# Update locally so local tuple has origin = InvalidRepOriginId
psql_or_bail(2, "UPDATE test_origin SET data = 'local-3' WHERE id = 3");

$log_pos = get_log_size($n2_logfile);

psql_or_bail(1, "UPDATE test_origin SET data = 'from-n1-v3' WHERE id = 3");
$val = wait_for_value(2,
    "SELECT data FROM test_origin WHERE id = 3",
    'from-n1-v3');
BAIL_OUT("UPDATE did not replicate") unless $val eq 'from-n1-v3';

system_or_bail 'sleep', '2';
$log_content = get_log_content_since($n2_logfile, $log_pos);
unlike($log_content, qr/CONFLICT:.*remote UPDATE on relation public\.test_origin/,
    'remote_only_differs: no conflict logged for locally-written tuple');

# ---- teardown ---------------------------------------------------------------
psql_or_bail(2, "SELECT spock.sub_drop('sub_origin_test')");

# Wait for subscription to be fully removed (poll up to 10s)
for my $i (1..100) {
    my $still_exists = scalar_query(2,
        "SELECT EXISTS (SELECT 1 FROM spock.subscription "
        . "WHERE sub_name = 'sub_origin_test')");
    last if $still_exists eq 'f';
    system_or_bail 'sleep', '0.1' if $i < 100;
}

destroy_cluster('Destroy 2-node origin-change restore test cluster');

done_testing();
