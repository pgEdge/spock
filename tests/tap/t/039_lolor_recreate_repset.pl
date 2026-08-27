use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_maybe get_test_config
                 cross_wire scalar_query ensure_lolor);

# DROP EXTENSION lolor cascade-drops the lolor tables' replication set
# membership along with the tables themselves. A CREATE EXTENSION afterwards
# brings the tables back, and AutoDDL has to put them back in the default set on
# every node -- nothing else would, since lolor is kept out of the structure
# dump. Otherwise large objects created from then on go unreplicated with no
# error anywhere.

my $cfg  = get_test_config();
my $PG   = $cfg->{pg_bin};
my $DB   = $cfg->{db_name};

plan skip_all => "lolor extension unavailable (clone/build failed)"
    unless ensure_lolor();

# psql helper: 1-based node index, returns true on success (output to log).
sub psql_ok {
    my ($node, $sql) = @_;
    my $port = $cfg->{node_ports}[$node - 1];
    return system_maybe("$PG/psql", '-X', '-p', $port, '-d', $DB,
                        '-v', 'ON_ERROR_STOP=1', '-c', $sql);
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

sub wait_for_lo {
    my ($node, $hex) = @_;
    return wait_for_scalar($node,
        "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = '$hex'",
        '1', 30);
}

sub repset_of {
    my ($node, $tbl) = @_;
    return scalar_query($node, "SELECT set_name FROM spock.tables " .
                               "WHERE nspname = 'lolor' AND relname = '$tbl'");
}

create_cluster(3, 'Create 3 instances for lolor re-create test');
cross_wire(3, ['n1', 'n2', 'n3'], 'Cross-wire n1, n2 and n3');

# --- First install: CREATE EXTENSION routes the tables on every node ---------

ok(psql_ok(1, "CREATE EXTENSION lolor"), 'lolor installed on n1');
for my $node (2, 3) {
    ok(wait_for_scalar($node, "SELECT count(*) FROM pg_extension WHERE extname = 'lolor'", '1'),
       "lolor arrived on n$node via DDL replication");
}
for my $node (1, 2, 3) {
    for my $tbl ('pg_largeobject', 'pg_largeobject_metadata') {
        ok(wait_for_scalar($node,
            "SELECT set_name FROM spock.tables WHERE nspname = 'lolor' AND relname = '$tbl'",
            'default'),
           "lolor.$tbl routed into the default set on n$node");
    }
}

ok(psql_ok(1, "SET lolor.node=1; SELECT lo_from_bytea(0, '\\xdeadbeefcafe')"),
   'large object created on n1');
ok(wait_for_lo(2, 'deadbeefcafe'), 'large object replicated to n2');
ok(wait_for_lo(3, 'deadbeefcafe'), 'large object replicated to n3');

# --- DROP: the extension and the membership both go on every node -----------
#
# lolor's event trigger migrates the objects into pg_catalog as each node
# applies the drop, so the data is moved, not lost.

ok(psql_ok(1, "SET spock.allow_ddl_from_functions = on; DROP EXTENSION lolor"),
   'lolor dropped on n1');
for my $node (1, 2, 3) {
    ok(wait_for_scalar($node, "SELECT count(*) FROM pg_extension WHERE extname = 'lolor'", '0'),
       "lolor is gone on n$node");
    ok(wait_for_scalar($node, "SELECT count(*) FROM pg_catalog.pg_largeobject_metadata", '1'),
       "n$node migrated its large object into pg_catalog");
    is(scalar_query($node, "SELECT count(*) FROM spock.replication_set_table rst " .
                           "JOIN pg_class c ON c.oid = rst.set_reloid " .
                           "JOIN pg_namespace n ON n.oid = c.relnamespace " .
                           "WHERE n.nspname = 'lolor'"),
       '0', "membership cascade-dropped with the tables on n$node");
}

# --- Re-create: membership has to come back, or new objects go nowhere -------

ok(psql_ok(1, "CREATE EXTENSION lolor"), 'lolor re-created on n1');
for my $node (2, 3) {
    ok(wait_for_scalar($node, "SELECT count(*) FROM pg_extension WHERE extname = 'lolor'", '1'),
       "re-created lolor arrived on n$node");
}
for my $node (1, 2, 3) {
    for my $tbl ('pg_largeobject', 'pg_largeobject_metadata') {
        ok(wait_for_scalar($node,
            "SELECT set_name FROM spock.tables WHERE nspname = 'lolor' AND relname = '$tbl'",
            'default'),
           "lolor.$tbl back in the default set on n$node after re-create");
    }
}

ok(psql_ok(1, "SET lolor.node=1; SELECT lo_from_bytea(0, '\\xfeedface')"),
   'large object created on n1 after the re-create');
ok(wait_for_lo(2, 'feedface'), 'large object after re-create replicated to n2');
ok(wait_for_lo(3, 'feedface'), 'large object after re-create replicated to n3');

# The objects left behind in pg_catalog by the drop do not get in the way of a
# second round trip either.
ok(psql_ok(3, "SET lolor.node=3; SELECT lo_from_bytea(0, '\\xc0ffee')"),
   'large object created on n3');
ok(wait_for_lo(1, 'c0ffee'), 'large object from n3 replicated to n1');
ok(wait_for_lo(2, 'c0ffee'), 'large object from n3 replicated to n2');

# --- A custom placement must survive the routing ----------------------------

ok(psql_ok(1, "SELECT spock.repset_create('lolor_custom')"), 'custom repset created on n1');
ok(psql_ok(1, "SELECT spock.repset_remove_table('default', 'lolor.pg_largeobject')"),
   'lolor.pg_largeobject taken out of the default set on n1');
ok(psql_ok(1, "SELECT spock.repset_add_table('lolor_custom', 'lolor.pg_largeobject')"),
   'lolor.pg_largeobject placed in the custom set on n1');
ok(psql_ok(1, "ALTER EXTENSION lolor UPDATE"), 'ALTER EXTENSION lolor UPDATE on n1');
is(repset_of(1, 'pg_largeobject'), 'lolor_custom',
   'custom placement survived ALTER EXTENSION');

destroy_cluster('Destroy lolor re-create test cluster');

done_testing();
