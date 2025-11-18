use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail system_or_bail scalar_query);

my ($result);

create_cluster(3, 'Create basic Spock test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

psql_or_bail(2, "SELECT spock.node_drop('n2')");
psql_or_bail(3, "SELECT spock.node_drop('n3')");
psql_or_bail(1, "CREATE EXTENSION snowflake");
psql_or_bail(1, "CREATE EXTENSION lolor");
psql_or_bail(1, "CREATE EXTENSION amcheck");
psql_or_bail(2, "CREATE EXTENSION dblink");
psql_or_bail(3, "CREATE EXTENSION dblink");
psql_or_bail(2, "\\i ../../samples/Z0DAN/zodan.sql");
psql_or_bail(3, "\\i ../../samples/Z0DAN/zodan.sql");
psql_or_bail(1, "CREATE TABLE test(x serial PRIMARY KEY)");
psql_or_bail(1, "INSERT INTO test DEFAULT VALUES");

print STDERR "All supporting stuff has been installed successfully\n";

# ##############################################################################
#
# Basic check that Z0DAN correctly add node to the single-node cluster
#
# ##############################################################################

print STDERR "Call Z0DAN: n2 => n1\n";
psql_or_bail(2, "
    CALL spock.add_node(
        src_node_name := 'n1',
        src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
        new_node_name := 'n2',
        new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
        verb := false
    )");
print STDERR "Z0DAN (n2 => n1) has finished the attach process\n";
$result = scalar_query(2, "SELECT x FROM test");
print STDERR "Check result: $result\n";
ok($result eq '1', "Check state of the test table after the attachment");

psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2')");

# ##############################################################################
#
# Z0DAN reject node addition if some subscriptions are disabled
#
# ##############################################################################

print STDERR "Call Z0DAN: n3 => n2\n";
scalar_query(3, "
	CALL spock.add_node(
		src_node_name := 'n2',
		src_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
		new_node_name := 'n3', new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
		verb := false)");

$result = scalar_query(3, "SELECT count(*) FROM spock.local_node");
ok($result eq '0', "N3 is not in the cluster yet");
print STDERR "Z0DAN should fail because of a disabled subscription\n";

psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2')");
psql_or_bail(3, "
	CALL spock.add_node(
		src_node_name := 'n2',
		src_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
		new_node_name := 'n3', new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
		verb := true)");

$result = scalar_query(3, "SELECT count(*) FROM spock.local_node");
ok($result eq '1', "N3 is in the cluster");
$result = scalar_query(3, "SELECT x FROM test");
print STDERR "Check result: $result\n";
ok($result eq '1', "Check state of the test table on N3 after the attachment");
print STDERR "Z0DAN should add N3 to the cluster\n";

# ##############################################################################
#
# Test that Z0DAN correctly doesn't add node to the cluster if something happens
# during the SYNC process.
#
# ##############################################################################

# Remove node from the cluster and data leftovers.
psql_or_bail(3, "\\i ../../samples/Z0DAN/zodremove.sql");
psql_or_bail(3, "CALL spock.remove_node(target_node_name := 'n3',
	target_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
	verbose_mode := true)");
psql_or_bail(3, "DROP TABLE test");
psql_or_bail(3, "DROP EXTENSION lolor");
psql_or_bail(3, "DROP EXTENSION amcheck");

psql_or_bail(1, "CREATE FUNCTION fake_fn() RETURNS integer LANGUAGE sql AS \$\$ SELECT 1\$\$");
psql_or_bail(3, "CREATE FUNCTION fake_fn() RETURNS integer LANGUAGE sql AS \$\$ SELECT 1\$\$");
print STDERR "### Test: a conflicting object may break add_node ###\n";
scalar_query(3, "
	CALL spock.add_node(
		src_node_name := 'n2',
		src_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
		new_node_name := 'n3', new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
		verb := true)");

$result = scalar_query(3, "SELECT oid FROM pg_class WHERE relname = 'test'");
ok($result eq '', "Check that test table isn't replicated"); # It is not OK, but for the demo

# TODO:
# It seems that add_node keeps remnants after unsuccessful execution. It is
# happened because we have commited some intermediate results before.
# It would be better to keep remote transaction opened until the end of the
# operation or just remove these remnants at the end pretending to be a
# distributed transaction.
#
# $result = scalar_query(3, "SELECT count(*) FROM spock.local_node");
# ok($result eq '0', "N3 is not in the cluster");

# Remove all remnants left after the unsuccessful add_node.
# First, we need to drop the Spock extension: it removes relevant subscriptions
# that is requirement for a drop database command.
scalar_query(3, "\\i ../../samples/Z0DAN/zodremove.sql");

psql_or_bail(3, "CALL spock.remove_node(target_node_name := 'n3',
	target_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
	verbose_mode := true)");
psql_or_bail(3, "DROP FUNCTION fake_fn");

# ##############################################################################
#
# Check how Z0DAN works in presence of different extensions.
#
# ##############################################################################

# Install an arbitrary extension in the origin and target databases and try to
# add node by the Z0DAN protocol.
#psql_or_bail(3, "CREATE EXTENSION amcheck");

# Should fail at the moment because pg_restore fails and causes the sync worker
# to stop.
print STDERR "### Test: a conflicting extension may break add_node ###\n";
scalar_query(3, "
	CALL spock.add_node(
		src_node_name := 'n2',
		src_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
		new_node_name := 'n3', new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
		verb := true)");

$result = scalar_query(3, "SELECT oid FROM pg_class WHERE relname = 'test'");
ok($result eq '', "Check that test table isn't replicated"); # It is not OK, but for the demo

print STDERR "### Test: add_node works on an empty database ###\n";

scalar_query(3, "\\i ../../samples/Z0DAN/zodremove.sql");
psql_or_bail(3, "CALL spock.remove_node(target_node_name := 'n3',
	target_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
	verbose_mode := true)");
psql_or_bail(3, "DROP EXTENSION amcheck");

psql_or_bail(3, "
	CALL spock.add_node(
		src_node_name := 'n2',
		src_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
		new_node_name := 'n3', new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user password=$db_password',
		verb := true)");

$result = scalar_query(3, "SELECT x FROM test");
ok($result eq '1', "Check that test table is replicated");

# Clean up
destroy_cluster('Destroy test cluster');
done_testing();
