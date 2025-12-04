use strict;
use warnings;
use Test::More tests => 15;
use IPC::Run;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail get_test_config cross_wire psql_or_bail scalar_query);

create_cluster(3, 'Create initial 2-node Spock test cluster');

my ($handle ,$ret1, $ret2, $ret3);
my $ITERATIONS = 10000;

# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

cross_wire(2, ['n1', 'n2'], 'Cross-wire nodes N1 and N2');

print STDERR "Install the helper functions and do other preparatory stuff\n";
psql_or_bail(3, "\\i '../../samples/Z0DAN/zodan.sql'");
psql_or_bail(3, "CREATE EXTENSION dblink");
psql_or_bail(3, "SELECT spock.node_drop('n3')");

print STDERR "Creata objects, necessary for the test\n";
psql_or_bail(1, "CREATE TABLE t1 (x bigint PRIMARY KEY, y integer)");
# We need a massive table to widen the COPY window and let a concurrent apply
# worker to do some stuff
psql_or_bail(1, "INSERT INTO t1 (x,y) (SELECT -gs,0 FROM generate_series(1, 1000000) AS gs)");
psql_or_bail(1, "INSERT INTO t1 (x,y) VALUES (0,0)");
psql_or_bail(1, "VACUUM FULL");
psql_or_bail(1, q(
CREATE PROCEDURE identity_col_update(relname text, cycles integer, delta integer)
AS $$
DECLARE
	i integer := 0;
BEGIN
  WHILE i < cycles LOOP
    EXECUTE format('UPDATE %I SET x = x + %L, y = y + %L
	WHERE x >= 0;', relname, delta, delta);
	COMMIT;
	i := i + 1;
    -- raise NOTICE 'iteration % from %', i, cycles;
  END LOOP;
  raise NOTICE 'FINISH: iteration % from %', i, cycles;
END;
$$ LANGUAGE plpgsql;
));

# Be sure that global changes doesn't impact the test
psql_or_bail(1, "ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard'");
psql_or_bail(1, "SELECT pg_reload_conf()");
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard'");
psql_or_bail(2, "SELECT pg_reload_conf()");
psql_or_bail(3, "ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard'");
psql_or_bail(3, "SELECT pg_reload_conf()");

print STDERR "Wait until N1 -> N2 replication ends (transfer initial objects and data)\n";
$ret1 = scalar_query(1, "SELECT spock.sync_event()");
psql_or_bail(2, qq(CALL spock.wait_for_sync_event(true, 'n1', '$ret1'::pg_lsn, 600)));

# ##############################################################################
#
# First stage:
#
# The 'transdiscard' option allows to pass hot node addition process and keep
# data consistent.
#
# ##############################################################################

print STDERR "Launch test load on N2 in a separate process\n";
$handle = IPC::Run::start(
    [ "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname,
	'-c', "CALL identity_col_update('t1', $ITERATIONS, 1)"]);
$handle->pump();

print STDERR "Add N3 into loaded configuration of N1 and N2 ...";
psql_or_bail(3,
	"CALL spock.add_node(
		src_node_name := 'n1',
		src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user',
		new_node_name := 'n3',
		new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user',
		verb := true);");

$handle->finish;
is($handle->full_result(0), 0, "test load run successfull");

$ret1 = scalar_query(1, "SELECT spock.sync_event()");
$ret2 = scalar_query(2, "SELECT spock.sync_event()");
print STDERR "Wait until N1 -> N3 sync ends\n";
psql_or_bail(3, qq(CALL spock.wait_for_sync_event(true, 'n1', '$ret1'::pg_lsn, 600)));
print STDERR "Wait until N2 -> N3 sync ends\n";
psql_or_bail(3, qq(CALL spock.wait_for_sync_event(true, 'n2', '$ret2'::pg_lsn, 600)));
print STDERR "Wait until N2 -> N1 sync ends\n";
psql_or_bail(1, qq(CALL spock.wait_for_sync_event(true, 'n2', '$ret2'::pg_lsn, 600)));

print STDERR "Check the data consistency.\n";
$ret1 = scalar_query(1, "SELECT x,y FROM t1 WHERE x >= 0");
$ret2 = scalar_query(2, "SELECT x,y FROM t1 WHERE x >= 0");
$ret3 = scalar_query(3, "SELECT x,y FROM t1 WHERE x >= 0");
print STDERR "DEBUGGING. Results: $ret1 | $ret2 | $ret3\n";

ok($ret1 eq $ret2, "Equality of the data on N1 and N2 is confirmed");
ok($ret1 eq $ret3, "Equality of the data on N1 and N3 is confirmed");

# ##############################################################################
#
# Second stage:
#
# The 'transdiscard' option doesn't allow to detect a divergency moment that
# moves data on N1 and N2 into different states that probably will quickly
# get worse.
#
# ##############################################################################

psql_or_bail(1, "UPDATE t1 SET x = 1000000, y = 1000001 WHERE x >= 0");

my ($handle1, $handle2);

print STDERR "Launch test load on N1 and N2 in separate processes\n";
$handle1 = IPC::Run::start(
    [ "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname,
	'-c', "CALL identity_col_update('t1', 10000, +1)"]);
$handle2 = IPC::Run::start(
    [ "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname,
	'-c', "CALL identity_col_update('t1', 10000, -1)"]);

$handle1->finish;
is($handle1->full_result(0), 0, "test load run on N1 successfull");
$handle2->finish;
is($handle2->full_result(0), 0, "test load run on N2 successfull");

print STDERR "Check the data consistency.\n";
$ret1 = scalar_query(1, "SELECT x,y FROM t1 WHERE x >= 0");
$ret2 = scalar_query(2, "SELECT x,y FROM t1 WHERE x >= 0");
print STDERR "DEBUGGING. Results: $ret1 | $ret2\n";

ok($ret1 eq $ret2, "Equality of the data on N1 and N2 is confirmed");

# Cleanup will be handled by SpockTest.pm END block
# No need for done_testing() when using a test plan
