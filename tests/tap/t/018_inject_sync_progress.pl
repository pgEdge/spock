use strict;
use warnings;
use Test::More;
use IPC::Run;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail get_test_config cross_wire psql_or_bail scalar_query);

# =============================================================================
# Test: Verify that progress info is read consistently with the COPY snapshot
# during subscription sync.
#
# Uses injection points to insert a delay between the replication slot
# snapshot creation and the progress read. During that delay, a DML from
# N2 arrives at N1. With the fix (progress read inside the snapshot),
# the progress entries will be consistent despite the delay.
# =============================================================================

my $configure_options = `pg_config --configure`;
if ($configure_options !~ /enable-injection-points/) {
	plan skip_all => 'Injection points not supported by this build';
}

plan tests => 5;

create_cluster(3, 'Create initial 3-node Spock test cluster');

my ($ret1, $ret2, $ret3, $lsn1, $lsn2, $lsn3);

my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

cross_wire(2, ['n1', 'n2'], 'Cross-wire nodes N1 and N2');

print STDERR "Install preparatory stuff and wait until it will be propagated\n";
psql_or_bail(3, "ALTER SYSTEM SET spock.exception_behaviour = 'sub_disable'");
psql_or_bail(3, "SELECT pg_reload_conf()");
psql_or_bail(3, "CREATE EXTENSION injection_points");
psql_or_bail(1, "CREATE TABLE t1 (x bigint PRIMARY KEY)");
psql_or_bail(1, "INSERT INTO t1 (x) VALUES (42)");
$lsn1 = scalar_query(1, "SELECT spock.sync_event()");
psql_or_bail(2, "CALL spock.wait_for_sync_event(true, 'n1', '$lsn1'::pg_lsn, 600)");
print STDERR "---> LSN1: $lsn1\n";

# Create N2 -> N3 disabled subscription and its slot manually.
# Then install an injection point on N3 to delay the N1 -> N3 sync.
psql_or_bail(3, "SELECT spock.sub_create(subscription_name := 'n2_n3',
	provider_dsn := 'host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password',
	enabled := false);");
psql_or_bail(2, "SELECT 1 FROM pg_create_logical_replication_slot(
									'spk_${dbname}_n2_n2_n3', 'spock_output')");
psql_or_bail(3, "SELECT injection_points_attach(
							'spock-before-replication-slot-snapshot', 'wait')");
psql_or_bail(3, "SELECT spock.sub_create(subscription_name := 'n1_n3',
  provider_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password',
  synchronize_structure := true, synchronize_data := true, enabled := true);");

sleep 10;

# While N3 is paused at the injection point (after snapshot, before progress
# read), update data on N2. This will be replicated to N1 and included in the
# COPY snapshot. With the fix, the progress read also uses the same snapshot,
# so the LSN will correctly reflect this transaction.
psql_or_bail(2, "UPDATE t1 SET x = x + 1");

$lsn2 = scalar_query(2, "SELECT spock.sync_event()");
psql_or_bail(1, "CALL spock.wait_for_sync_event(true, 'n2', '$lsn2'::pg_lsn, 600)");
print STDERR "---> LSN2: $lsn2\n";

# Wake up N1 -> N3 subscription and wait until it becomes ready
psql_or_bail(3, "SELECT injection_points_wakeup('spock-before-replication-slot-snapshot');");
psql_or_bail(3, "SELECT injection_points_detach('spock-before-replication-slot-snapshot');");
psql_or_bail(1, "SELECT spock.wait_slot_confirm_lsn(NULL, NULL)");
$lsn1 = scalar_query(1, "SELECT spock.sync_event()");
psql_or_bail(3, "CALL spock.wait_for_sync_event(true, 'n1', '$lsn1'::pg_lsn, 600)");

# Advance the N2->N3 slot using the progress LSN from N3, then enable the sub
$lsn3 = scalar_query(3, "SELECT remote_commit_lsn FROM spock.progress p
							JOIN spock.node n ON (p.remote_node_id = n.node_id)
						 WHERE n.node_name = 'n2';");
psql_or_bail(2, "SELECT pg_replication_slot_advance('spk_${dbname}_n2_n2_n3', '$lsn3'::pg_lsn)");
psql_or_bail(3, "SELECT spock.sub_enable('n2_n3', immediate := false)");

$lsn2 = scalar_query(2, "SELECT spock.sync_event()");
psql_or_bail(3, "CALL spock.wait_for_sync_event(true, 'n2', '$lsn2'::pg_lsn, 600)");

print STDERR "Check aggregates on all of the nodes\n";
$ret1 = scalar_query(1, "SELECT sum(x), count(*) FROM t1");
$ret2 = scalar_query(2, "SELECT sum(x), count(*) FROM t1");
$ret3 = scalar_query(3, "SELECT sum(x), count(*) FROM t1");
print STDERR "Aggregates: N1=$ret1 | N2=$ret2 | N3=$ret3\n";
ok($ret1 eq $ret2, "Equality of the data on N1 and N2 is confirmed");
ok($ret1 eq $ret3, "Equality of the data on N1 and N3 is confirmed");

print STDERR "Check that all existing subscriptions are enabled\n";
$ret1 = scalar_query(1, "SELECT count(*) FROM spock.subscription WHERE sub_enabled = false;");
$ret2 = scalar_query(2, "SELECT count(*) FROM spock.subscription WHERE sub_enabled = false;");
$ret3 = scalar_query(3, "SELECT count(*) FROM spock.subscription WHERE sub_enabled = false;");
ok($ret1 eq '0', "All subscriptions on the node N1 are active");
ok($ret2 eq '0', "All subscriptions on the node N2 are active");
ok($ret3 eq '0', "All subscriptions on the node N3 are active");
