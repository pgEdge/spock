use strict;
use warnings;
use Test::More tests => 13;
use IPC::Run;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail get_test_config cross_wire psql_or_bail scalar_query);

my ($result1, $result2, $result3, $lsn1, $lsn2);

create_cluster(3, 'Create initial 3-node Spock test cluster');
cross_wire(3, ['n1', 'n2', 'n3'], 'Cross-wire nodes');
# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

psql_or_bail(1, qq(
	CREATE TABLE t1 (id integer PRIMARY KEY, x integer NOT NULL, y integer);
	INSERT INTO t1 (id, x) VALUES (1,42);
));

psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(2, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(3, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');

psql_or_bail(1, "SELECT spock.delta_apply('t1', 'x');");
psql_or_bail(2, "SELECT spock.delta_apply('t1', 'x');");
psql_or_bail(3, "SELECT spock.delta_apply('t1', 'x');");

psql_or_bail(3, q(
CREATE PROCEDURE counter_change(relname name, attname name,
								value integer, cycles integer)
AS $$
DECLARE
	i integer := 0;
BEGIN
  WHILE i < cycles LOOP
    EXECUTE format('UPDATE %I SET %s = %s + %L;', relname, attname, attname, value);
	-- raise WARNING '[%] iteration % from %', value, i, cycles;
	COMMIT;
	i := i + 1;

  END LOOP;
  raise NOTICE '[%] FINISH: iteration % from %', value, i, cycles;
END;
$$ LANGUAGE plpgsql;));

psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(2, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(3, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');

$result1 = scalar_query(1,"SELECT * FROM pg_catalog.pg_seclabels");
$result2 = scalar_query(2,"SELECT * FROM pg_catalog.pg_seclabels");
$result3 = scalar_query(3,"SELECT * FROM pg_catalog.pg_seclabels");
print STDERR "DEBUGGING. Spock nodes IDs: \n$result1 $result2 $result3\n";

my ($pgbench_stdout1, $pgbench_stderr1) = ('', '');
my $phandle1 = IPC::Run::start(
	[
		'psql',
		'-c', "CALL counter_change('t1', 'x', -1, 10000)",
		'-h', $host, '-p', $node_ports->[1], '-U', $db_user, $dbname
	],
	'>' => \$pgbench_stdout1,
	'2>' => \$pgbench_stderr1);
#$phandle1->pump();

psql_or_bail(1, "CALL counter_change('t1', 'x', +1, 10001)");

$phandle1->finish;
is($phandle1->full_result(0), 0, "alternative run successfull");

print STDERR "##### output of psql #####\n";
print STDERR "$pgbench_stdout1";
print STDERR "$pgbench_stderr1";
print STDERR "##### end of output #####\n";

# Wait for sync ...
$lsn1 = scalar_query(1, "SELECT spock.sync_event()");
$lsn2 = scalar_query(2, "SELECT spock.sync_event()");
psql_or_bail(1, "CALL spock.wait_for_sync_event(true, 'n2', '$lsn2'::pg_lsn, 600)");
psql_or_bail(2, "CALL spock.wait_for_sync_event(true, 'n1', '$lsn1'::pg_lsn, 600)");
psql_or_bail(3, "CALL spock.wait_for_sync_event(true, 'n1', '$lsn1'::pg_lsn, 600)");
psql_or_bail(3, "CALL spock.wait_for_sync_event(true, 'n2', '$lsn2'::pg_lsn, 600)");

$result1 = scalar_query(1, "SELECT x FROM t1");
$result2 = scalar_query(2, "SELECT x FROM t1");
$result3 = scalar_query(3, "SELECT x FROM t1");

ok($result1 eq '43', "Data on the node N1 has correct value");
ok($result1 eq $result3, "Equality of the data on N1 and N3 is confirmed");
ok($result2 eq $result3, "Equality of the data on N2 and N3 is confirmed");
print STDERR "DEBUGGING. Results: $result1 | $result2 | $result3\n";

# Cleanup will be handled by SpockTest.pm END block
# No need for done_testing() when using a test plan
