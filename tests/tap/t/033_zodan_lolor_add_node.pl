use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail system_maybe
                 get_test_config cross_wire scalar_query ensure_lolor);

# Zodan add_node with lolor large objects. The source cluster replicates the
# lolor tables (lolor.pg_largeobject, lolor.pg_largeobject_metadata) in the
# default replication set. Adding a node through zodan's add_node() must:
#   - reject a new node that lacks the lolor extension (data sync would fail),
#   - reject a new node whose lolor tables already contain data,
#   - accept a new node with lolor installed and empty, and copy the large
#     object data from the source during the initial data sync,
#   - stream large objects created after the join.

my $cfg   = get_test_config();
my $PG    = $cfg->{pg_bin};
my $DB    = $cfg->{db_name};
my $USER  = $cfg->{db_user};
my $PASS  = $cfg->{db_password};
my $HOST  = $cfg->{host};

plan skip_all => "lolor extension unavailable (clone/build failed)"
    unless ensure_lolor();

# psql helper: 1-based node index, returns true on success (output to log).
sub psql_ok {
    my ($node, $sql) = @_;
    my $port = $cfg->{node_ports}[$node - 1];
    return system_maybe("$PG/psql", '-X', '-p', $port, '-d', $DB,
                        '-v', 'ON_ERROR_STOP=1', '-c', $sql);
}

# Run SQL and capture combined stdout/stderr without going through a shell,
# so quoting inside the SQL is preserved. Returns (exit_code, output).
sub psql_capture {
    my ($node, $sql) = @_;
    my $port = $cfg->{node_ports}[$node - 1];
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>&', \*STDOUT) or die "cannot dup STDERR: $!";
        exec("$PG/psql", '-X', '-p', $port, '-d', $DB,
             '-v', 'ON_ERROR_STOP=1', '-c', $sql);
        exit 127;
    }
    my $out = do { local $/; <$fh> } // '';
    close($fh);
    return ($? >> 8, $out);
}

# Poll a scalar query on a node until it returns $expected.
sub wait_for_scalar {
    my ($node, $sql, $expected, $timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        my $v = scalar_query($node, $sql);
        return 1 if defined $v && $v eq $expected;
        sleep(1);
    }
    return 0;
}

sub dsn {
    my ($node) = @_;
    my $port = $cfg->{node_ports}[$node - 1];
    return "host=$HOST dbname=$DB port=$port user=$USER password=$PASS";
}

# --- Cluster setup: n1/n2 cross-wired, n3 is a blank target for zodan -------

create_cluster(3, 'Create 3 instances for zodan lolor test');
cross_wire(2, ['n1', 'n2'], 'Cross-wire nodes n1 and n2');

# create_cluster registered a spock node on n3; drop it so n3 looks like a
# freshly prepared instance (spock + dblink installed, no node/repsets).
ok(psql_ok(3, "SELECT spock.node_drop('n3')"), 'n3 spock node registration dropped');
ok(psql_ok(3, "CREATE EXTENSION IF NOT EXISTS dblink"), 'dblink installed on n3');

# lolor on the source cluster, its tables in the default replication set.
# n1 and n2 are cross-wired with automatic DDL replication, so CREATE
# EXTENSION on n1 arrives on n2 by itself.
ok(psql_ok(1, "CREATE EXTENSION lolor"), 'lolor installed on n1');
ok(wait_for_scalar(2, "SELECT count(*) FROM pg_extension WHERE extname = 'lolor'", '1'),
   'lolor arrived on n2 via DDL replication');
for my $node (1, 2) {
    ok(psql_ok($node, "SELECT spock.repset_add_table('default', 'lolor.pg_largeobject')"),
       "lolor.pg_largeobject in default repset on n$node");
    ok(psql_ok($node, "SELECT spock.repset_add_table('default', 'lolor.pg_largeobject_metadata')"),
       "lolor.pg_largeobject_metadata in default repset on n$node");
}

# Large object on n1; sanity-check it reaches n2 before involving zodan.
ok(psql_ok(1, "SET lolor.node=1; SELECT lo_from_bytea(0, '\\xdeadbeefcafe')"),
   'large object created on n1');
ok(wait_for_scalar(2, "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = 'deadbeefcafe'", '1'),
   'large object replicated from n1 to n2');

# Load the zodan procedures on the node being added.
system_or_bail("$PG/psql", '-X', '-p', $cfg->{node_ports}[2], '-d', $DB,
               '-v', 'ON_ERROR_STOP=1', '-f', '../../samples/Z0DAN/zodan.sql');
pass('zodan procedures loaded on n3');

my $add_node_sql =
    "CALL spock.add_node('n1', '" . dsn(1) . "', 'n3', '" . dsn(3) . "', " .
    "true, 'CA', 'USA', '{}'::jsonb)";

# --- Negative: source replicates lolor but n3 has no lolor extension --------

my ($rc, $out) = psql_capture(3, $add_node_sql);
ok($rc != 0, 'add_node rejected while n3 lacks the lolor extension');
like($out, qr/does not have the lolor extension installed/,
     'rejection message asks for CREATE EXTENSION lolor');

# --- Negative: n3 has lolor installed but with pre-existing data ------------

ok(psql_ok(3, "CREATE EXTENSION lolor"), 'lolor installed on n3');
ok(psql_ok(3, "SET lolor.node=3; SELECT lo_from_bytea(0, '\\x0bad0bad')"),
   'pre-existing large object created on n3');

($rc, $out) = psql_capture(3, $add_node_sql);
ok($rc != 0, 'add_node rejected while n3 has pre-existing lolor data');
like($out, qr/pre-existing large object data/,
     'rejection message mentions pre-existing large object data');

# health_check 'pre' must report the same problem without raising.
($rc, $out) = psql_capture(3,
    "CALL spock.health_check('n1', '" . dsn(1) . "', 'n3', '" . dsn(3) . "', 'pre', false)");
like($out, qr/FAIL: Destination database has pre-existing large object data/,
     'health_check pre-check flags pre-existing lolor data');

# --- Positive: empty lolor tables, add_node copies the data -----------------

ok(psql_ok(3, "DELETE FROM lolor.pg_largeobject; DELETE FROM lolor.pg_largeobject_metadata"),
   'pre-existing lolor data cleared on n3');

($rc, $out) = psql_capture(3, $add_node_sql);
is($rc, 0, 'add_node succeeded with lolor installed and empty') or diag($out);

ok(wait_for_scalar(3, "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = 'deadbeefcafe'", '1'),
   'existing large object data copied to n3 by initial sync');
ok(wait_for_scalar(3, "SELECT count(*) FROM lolor.pg_largeobject_metadata", '1'),
   'large object metadata copied to n3');

# --- Streaming: a large object created after the join reaches n3 ------------

ok(psql_ok(1, "SET lolor.node=1; SELECT lo_from_bytea(0, '\\xfeedface')"),
   'second large object created on n1 after join');
ok(wait_for_scalar(3, "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = 'feedface'", '1'),
   'post-join large object streamed to n3');

destroy_cluster('Destroy zodan lolor test cluster');

done_testing();
