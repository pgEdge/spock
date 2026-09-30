use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    system_maybe
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status
    log_offset log_since
);

# =============================================================================
# Test 023: initial sync against an origin that predates
#           spock.pause_apply_workers() / spock.resume_apply_workers()
#           (both first released in 5.0.7) -- the mixed
#           5.0.5/5.0.11-style pairing supported during a rolling upgrade.
# =============================================================================
# Simulate a pre-5.0.7 origin by dropping both functions on the provider.
# The subscriber's sync worker must detect their absence up front, log one
# clear compatibility message without a raw "function does not exist" error,
# and complete the sync -- without ever attempting
# spock.resume_apply_workers() against an origin that cannot serve it either.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for mixed-version pause/resume test');

my $config      = get_test_config();
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $node_ports  = $config->{node_ports};
my $pg_bin      = $config->{pg_bin};

my $conn_n1 = "host=$host dbname=$dbname port=$node_ports->[0] " .
              "user=$db_user password=$db_password";

# Simulate an origin running Spock older than 5.0.7: neither function exists.
# Both are extension member objects, so they must be detached from the
# extension before they can be dropped.
psql_or_bail(1, "ALTER EXTENSION spock DROP FUNCTION spock.pause_apply_workers()");
psql_or_bail(1, "ALTER EXTENSION spock DROP FUNCTION spock.resume_apply_workers()");
psql_or_bail(1, "DROP FUNCTION spock.pause_apply_workers()");
psql_or_bail(1, "DROP FUNCTION spock.resume_apply_workers()");

# A table to actually copy, so the sync worker takes the data-copy path
# (copy_replication_sets_data(), the code path whose resume_apply_workers()
# call used to be unconditional) rather than a structure-only sync. AutoDDL
# adds it to the default replication set automatically.
psql_or_bail(1, "CREATE TABLE t1 (a INT PRIMARY KEY, b TEXT)");
psql_or_bail(1, "INSERT INTO t1 VALUES (1, 'before_subscribe')");

# The sync worker on the subscriber (n2) issues the remote pause/resume SQL
# calls.  Its local compatibility and libpq error messages are logged on n2;
# the functions themselves, when present, execute on the origin (n1).
my $log_off = log_offset(2);

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', " .
    "ARRAY['default'], true, true)");

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 60),
    'sub_n1_n2 reaches replicating state despite the origin lacking '
    . 'pause/resume_apply_workers()');

my $row = scalar_query(2, "SELECT b FROM t1 WHERE a = 1");
is($row, 'before_subscribe',
    'initial data copies fine without the pause/resume protection');

my $log = log_since(2, $log_off);

like($log, qr/SPOCK: origin does not support spock\.pause_apply_workers\(\)/,
    'subscriber logs one clear compatibility message');

unlike($log, qr/function spock\.(pause|resume)_apply_workers\(\) does not exist/,
    'neither function is actually invoked against the pre-5.0.7 origin '
    . '(no raw "does not exist" error from either call)');

# Prove ongoing replication is unaffected too, not just the initial sync.
psql_or_bail(1, "INSERT INTO t1 VALUES (2, 'after_subscribe')");

my $row2_ok = 0;
for (1..30) {
    sleep(1);
    my $v = scalar_query(2, "SELECT b FROM t1 WHERE a = 2");
    if (defined $v && $v eq 'after_subscribe') { $row2_ok = 1; last; }
}
ok($row2_ok, 'ongoing replication continues normally after the mixed-version sync');

system_maybe("$pg_bin/psql", '-h', $host, '-p', $node_ports->[1], '-U', $db_user,
    '-d', $dbname, '-c', "SELECT spock.sub_disable('sub_n1_n2')");
sleep(1);
system_maybe("$pg_bin/psql", '-h', $host, '-p', $node_ports->[1], '-U', $db_user,
    '-d', $dbname, '-c', "SELECT spock.sub_drop('sub_n1_n2')");

destroy_cluster('Destroy cluster after mixed-version pause/resume test');

done_testing();
