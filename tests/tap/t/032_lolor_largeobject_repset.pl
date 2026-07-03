use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_maybe get_test_config
                 scalar_query wait_for_sub_status);

# lolor stores large objects in ordinary tables in the "lolor" schema. Those
# tables must be allowed into a replication set, otherwise a DROP EXTENSION
# migrates the objects only on the node where it ran and the other nodes are
# left with unreachable data. This test verifies that the tables replicate,
# that other protected schemas (spock) stay blocked, and that add-node
# structure sync still works when lolor is present on both ends.

my $LOLOR_URL = 'https://github.com/pgEdge/lolor.git';

my $cfg   = get_test_config();
my $PG    = $cfg->{pg_bin};
my $DB    = $cfg->{db_name};
my $USER  = $cfg->{db_user};
my $HOST  = $cfg->{host};
my $LOGD  = $cfg->{log_dir};

# psql helper: 1-based node index, returns true on success (output goes to log).
sub psql_ok {
    my ($node, $sql) = @_;
    my $port = $cfg->{node_ports}[$node - 1];
    return system_maybe("$PG/psql", '-X', '-p', $port, '-d', $DB,
                        '-v', 'ON_ERROR_STOP=1', '-c', $sql);
}

# Build and install lolor if it is not already present. Skip the whole test
# (rather than fail) when it cannot be fetched or built, e.g. no network.
sub ensure_lolor {
    my $sharedir = `$PG/pg_config --sharedir`;
    chomp $sharedir;
    return 1 if $sharedir && -f "$sharedir/extension/lolor.control";

    my $build = "/tmp/spock_lolor_build";
    my $log   = "$LOGD/032_lolor_build.log";
    system('rm', '-rf', $build);
    my $rc = system("git clone --depth 1 $LOLOR_URL $build >> '$log' 2>&1");
    return 0 if $rc != 0;
    $rc = system("make -C $build USE_PGXS=1 PG_CONFIG='$PG/pg_config' install >> '$log' 2>&1");
    return 0 if $rc != 0;
    return ($sharedir && -f "$sharedir/extension/lolor.control") ? 1 : 0;
}

plan skip_all => "lolor extension unavailable (clone/build failed)"
    unless ensure_lolor();

create_cluster(2, 'Create 2-node cluster for lolor large object test');

# Both nodes get lolor installed (mimics a pre-provisioned pgEdge node).
ok(psql_ok(1, "CREATE EXTENSION lolor"), 'lolor installed on n1');
ok(psql_ok(2, "CREATE EXTENSION lolor"), 'lolor installed on n2');

# Add-node with structure sync while n2 already has the lolor schema: this
# must succeed, i.e. the structure dump still excludes lolor.
ok(
    psql_ok(2,
        "SELECT spock.sub_create('sub_n1_n2', " .
        "'host=$HOST dbname=$DB port=$cfg->{node_ports}[0] user=$USER', " .
        "ARRAY['default'], true, true, '{}'::text[], '0', true)"),
    'sub_create with synchronize_structure succeeds with lolor present');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 60),
   'subscription reached replicating (structure sync excluded lolor)');

# The fix: lolor tables may now be added to a replication set.
ok(psql_ok(1, "SELECT spock.repset_add_table('default', 'lolor.pg_largeobject')"),
   'lolor.pg_largeobject added to replication set');
ok(psql_ok(1, "SELECT spock.repset_add_table('default', 'lolor.pg_largeobject_metadata')"),
   'lolor.pg_largeobject_metadata added to replication set');

# The guard still protects other schemas: spock relations stay excluded.
ok(!psql_ok(1, "SELECT spock.repset_add_table('default', 'spock.node')"),
   'spock-schema relation still blocked from replication sets');

# Create a large object on n1 and confirm it replicates to n2.
ok(psql_ok(1, "SET lolor.node=1; SELECT lo_from_bytea(0, '\\xdeadbeefcafe')"),
   'large object created on n1');

my $replicated = 0;
for (1 .. 30) {
    my $hex = scalar_query(2,
        "SELECT encode(data, 'hex') FROM lolor.pg_largeobject");
    if (defined $hex && $hex eq 'deadbeefcafe') { $replicated = 1; last; }
    sleep(1);
}
ok($replicated, 'large object data replicated to n2');

destroy_cluster('Destroy lolor large object test cluster');

done_testing();
