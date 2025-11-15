use strict;
use warnings;
use Test::More tests => 34;
use IPC::Run;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail get_test_config cross_wire psql_or_bail scalar_query);

# =============================================================================
# Test: Add third node (N3) to the configuration of highly loaded (N1 and N2)
# by non-intersecting DMLs.
# =============================================================================
# This test follows the sequence:
# 1. Create nodes N1 and N2
# 2. Init pgbench database
# 3. CHECK: database replicated and we see a 'zero' lag
# 4. Load N1 and N2 with a custom non-intersecting UPDATE load
# 5. Call add_node() on N3
# 6. Check that pgbench load still exists after the end of the Z0DAN protocol
# 7. Wait for the end of the test and final data sync.
# 8. Check consistency of the data on each node.
# 9. Clean up

create_cluster(3, 'Create initial 2-node Spock test cluster');


my ($ret1, $ret2, $ret3);

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
my $helper_sql = '../../samples/Z0DAN/wait_subscription.sql';
my $zodan_sql = '../../samples/Z0DAN/zodan.sql';
psql_or_bail(1, "\\i $helper_sql");
psql_or_bail(2, "\\i $helper_sql");
psql_or_bail(3, "\\i $zodan_sql");
psql_or_bail(3, "CREATE EXTENSION dblink");
psql_or_bail(3, "SELECT spock.node_drop('n3')");

# Reduce the logfile size
psql_or_bail(1, "ALTER SYSTEM SET log_min_messages TO LOG");
psql_or_bail(1, "ALTER SYSTEM SET log_statement TO none");
psql_or_bail(1, "ALTER SYSTEM SET log_checkpoints TO off");
psql_or_bail(1, "ALTER SYSTEM SET log_connections TO off");
psql_or_bail(1, "ALTER SYSTEM SET log_disconnections TO off");
psql_or_bail(1, "ALTER SYSTEM SET log_lock_waits TO off");
psql_or_bail(1, "ALTER SYSTEM SET log_statement_stats TO off");
psql_or_bail(1, "SELECT pg_reload_conf()");

psql_or_bail(2, "ALTER SYSTEM SET log_min_messages TO LOG");
psql_or_bail(2, "ALTER SYSTEM SET log_statement TO none");
psql_or_bail(2, "ALTER SYSTEM SET log_checkpoints TO off");
psql_or_bail(2, "ALTER SYSTEM SET log_connections TO off");
psql_or_bail(2, "ALTER SYSTEM SET log_disconnections TO off");
psql_or_bail(2, "ALTER SYSTEM SET log_lock_waits TO off");
psql_or_bail(2, "ALTER SYSTEM SET log_statement_stats TO off");
psql_or_bail(2, "SELECT pg_reload_conf()");

psql_or_bail(3, "ALTER SYSTEM SET log_min_messages TO LOG");
psql_or_bail(3, "ALTER SYSTEM SET log_statement TO none");
psql_or_bail(3, "ALTER SYSTEM SET log_checkpoints TO off");
psql_or_bail(3, "ALTER SYSTEM SET log_connections TO off");
psql_or_bail(3, "ALTER SYSTEM SET log_disconnections TO off");
psql_or_bail(3, "ALTER SYSTEM SET log_lock_waits TO off");
psql_or_bail(3, "ALTER SYSTEM SET log_statement_stats TO off");
psql_or_bail(3, "SELECT pg_reload_conf()");

print STDERR "Initialize pgbench database and wait for initial sync on N1 and N2 ...\n";
system_or_bail "$pg_bin/pgbench", '-i', '-s', 1, '-h', $host,
							'-p', $node_ports->[0], '-U', $db_user, $dbname;
# Wait until tables and data will be sent to N2
psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
# Test 1: after the end of replication process we should be able to see a 'zero'
# lag between the nodes.
my $lag = scalar_query(2, "SELECT * FROM wait_subscription(remote_node_name := 'n1',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");

ok($lag  <= 0, "Initial replication has been successful");

# Create non-intersecting load for nodes N1 and N2.
# Test duration should be enough to cover all the Z0DAN stages. We will kill
# pgbench immediately after the N3 is attached.
my $load1 = '../../samples/Z0DAN/n1.pgb';
my $load2 = '../../samples/Z0DAN/n2.pgb';
my $pgbench_stdout1='';
my $pgbench_stderr1='';
my $pgbench_stdout2='';
my $pgbench_stderr2='';
my $pgbench_handle1 = IPC::Run::start(
    [ "$pg_bin/pgbench", '-n', '-f', $load1, '-T', 80, '-j', 3, '-c', 3,
	'-h', $host, '-p', $node_ports->[0], '-U', $db_user, $dbname],
	'>', \$pgbench_stdout1, '2>', \$pgbench_stderr1);
my $pgbench_handle2 = IPC::Run::start(
    [ "$pg_bin/pgbench", '-n', '-f', $load2, '-T', 80, '-j', 3, '-c', 3,
	'-h', $host, '-p', $node_ports->[1], '-U', $db_user, $dbname],
	'>', \$pgbench_stdout2, '2>', \$pgbench_stderr2);
$pgbench_handle1->pump();
$pgbench_handle2->pump();

# Warming up ...
print STDERR "warming up pgbench for 5s\n";
sleep(5);
print STDERR "done warmup\n";

print STDERR "Add N3 into highly loaded configuration of N1 and N2 ...\n";
psql_or_bail(3,
	"CALL spock.add_node(src_node_name := 'n1',
						 src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user',
						 new_node_name := 'n3',
						 new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user',
						 verb := false);");

# Ensure that pgbench load lasts longer than the Z0DAN protocol.
my $pid = $pgbench_handle1->{KIDS}[0]{PID};
my $alive = kill 0, $pid;
ok($alive eq 1, "pgbench load to N1 still exists");
$pid = $pgbench_handle2->{KIDS}[0]{PID};
$alive = kill 0, $pid;
ok($alive eq 1, "pgbench load to N2 still exists");

print STDERR "Kill pgbench process to reduce test time\n";
$pgbench_handle1->pump();
$pgbench_handle2->pump();
$pgbench_handle1->kill_kill;
$pgbench_handle2->kill_kill;

print STDERR "Check if pgbench finalised correctly\n";
$pgbench_handle1->finish;
$pgbench_handle2->finish;
print STDERR "##### output of pgbench #####\n";
print STDERR $pgbench_stdout1;
print STDERR $pgbench_stdout2;
print STDERR "##### end of output #####\n";

psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(2, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');

print STDERR "Wait until the end of replication ..\n";
$lag = scalar_query(1, "SELECT * FROM wait_subscription(remote_node_name := 'n2',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N2 => N1 has been finished successfully");
$lag = scalar_query(2, "SELECT * FROM wait_subscription(remote_node_name := 'n1',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N1 => N2 has been finished successfully");
$lag = scalar_query(3, "SELECT * FROM wait_subscription(remote_node_name := 'n1',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N1 => N3 has been finished successfully");
$lag = scalar_query(3, "SELECT * FROM wait_subscription(remote_node_name := 'n2',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N2 => N3 has been finished successfully");

print STDERR "Check the data consistency.\n";
$ret1 = scalar_query(1, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts");
print STDERR "The N1's pgbench_accounts aggregates: $ret1\n";
$ret2 = scalar_query(2, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts");
print STDERR "The N2's pgbench_accounts aggregates: $ret2\n";
$ret3 = scalar_query(3, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts");

print STDERR "The N3's pgbench_accounts aggregates: $ret3\n";
ok($ret1 eq $ret3, "Equality of the data on N1 and N3 is confirmed");
ok($ret2 eq $ret3, "Equality of the data on N2 and N3 is confirmed");

# Before we finish this test and destroy the cluster, we need to ensure that
# the nodes are not stuck in some work. N1 and N2 have done their job and are
# ready to switch off. However, after receiving a large amount of WAL during
# catch-up, N3 may be decoding WAL to determine a proper LSN for N3->N1 and
# N3->N2 replication.
# Being in this process, the walsender doesn't send anything valuable except
# a 'keepalive' message. Hence, we can't clearly detect the end of the process.
# So, nudge it, employing the sync_event machinery.
psql_or_bail(3, "SELECT spock.sync_event()");
print STDERR "Wait for the end of N3->N1, N3->N2 decoding process that means the actual start of LR\n";
psql_or_bail(3, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');

# Nothing sensitive should be awaited here, just to be sure.
$lag = scalar_query(1, "SELECT * FROM wait_subscription(remote_node_name := 'n3',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N2 => N1 has been finished successfully");
$lag = scalar_query(2, "SELECT * FROM wait_subscription(remote_node_name := 'n3',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N1 => N2 has been finished successfully");

# ##############################################################################
#
# Try to update an IDENTITY column (pgbench_accounts.aid). This is the case of
# 2n congiguration. With non-intersecting load we don't anticipate any issues
# with this test. It is written to prepare infrastructure and for demonstration
# purposes.
#
# ##############################################################################

$zodan_sql = '../../samples/Z0DAN/zodremove.sql';
psql_or_bail(3, "\\i $zodan_sql");
psql_or_bail(3, "CALL spock.remove_node(
	target_node_name := 'n3',
	target_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user',
	verbose_mode := true)");
system_or_bail "$pg_bin/pgbench", '-i', '-I', 'd', '-h', $host, '-p', $node_ports->[2], '-U', $db_user, $dbname;
psql_or_bail(3, 'DROP FUNCTION wait_subscription');
psql_or_bail(3, 'VACUUM FULL');

# To improve TPS
psql_or_bail(1, "CREATE UNIQUE INDEX ON pgbench_accounts(abs(aid))");
$lag = scalar_query(2, "SELECT * FROM wait_subscription(remote_node_name := 'n1',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Wait replication of the CREATE INDEX");

# Create non-intersecting load for nodes N1 and N2.
# Test duration should be enough to cover all the Z0DAN stages. We will kill
# pgbench immediately after the N3 is attached.
$load1 = '../../samples/Z0DAN/n1_1.pgb';
$load2 = '../../samples/Z0DAN/n2_1.pgb';
$pgbench_stdout1='';
$pgbench_stderr1='';
$pgbench_stdout2='';
$pgbench_stderr2='';
$pgbench_handle1 = IPC::Run::start(
    [ "$pg_bin/pgbench", '-n', '-f', $load1, '-T', 80, '-j', 3, '-c', 3,
	'-h', $host, '-p', $node_ports->[0], '-U', $db_user, $dbname],
	'>', \$pgbench_stdout1, '2>', \$pgbench_stderr1);
$pgbench_handle2 = IPC::Run::start(
    [ "$pg_bin/pgbench", '-n', '-f', $load2, '-T', 80, '-j', 3, '-c', 3,
	'-h', $host, '-p', $node_ports->[1], '-U', $db_user, $dbname],
	'>', \$pgbench_stdout2, '2>', \$pgbench_stderr2);
$pgbench_handle1->pump();
$pgbench_handle2->pump();

# Warming up ...
print STDERR "warming up pgbench for 20s\n";
sleep(20);
print STDERR "done warmup\n";

# Ensure that pgbench load lasts longer than the Z0DAN protocol.
$pid = $pgbench_handle1->{KIDS}[0]{PID};
$alive = kill 0, $pid;
ok($alive eq 1, "pgbench load to N1 still exists");
$pid = $pgbench_handle2->{KIDS}[0]{PID};
$alive = kill 0, $pid;
ok($alive eq 1, "pgbench load to N2 still exists");

print STDERR "Kill pgbench process to reduce test time";
$pgbench_handle1->pump();
$pgbench_handle2->pump();
$pgbench_handle1->kill_kill;
$pgbench_handle2->kill_kill;

print STDERR "Check if pgbench finalised correctly\n";
$pgbench_handle1->finish;
$pgbench_handle2->finish;
print STDERR "##### output of pgbench #####\n";
print STDERR "$pgbench_stdout1";
print STDERR "$pgbench_stdout2";
print STDERR "##### end of output #####\n";

psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(2, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');

print STDERR "Wait until the end of replication ..\n";
$lag = scalar_query(1, "SELECT * FROM wait_subscription(remote_node_name := 'n2',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N2 => N1 has been finished successfully");
$lag = scalar_query(2, "SELECT * FROM wait_subscription(remote_node_name := 'n1',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N1 => N2 has been finished successfully");

print STDERR "Check the data consistency.\n";
$ret1 = scalar_query(1, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts");
print STDERR "The N1's pgbench_accounts aggregates: $ret1\n";
$ret2 = scalar_query(2, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts");
print STDERR "The N2's pgbench_accounts aggregates: $ret2\n";

ok($ret1 eq $ret2, "Equality of the data on N1 and N2 is confirmed");

# ##############################################################################
#
# Try to update an IDENTITY column in case of 3n configuration.
# It works precisely like the previous one, but node 3 should sync its state
# with loaded nodes in real time under the pgbench load.
# Here, we also inderectly test how the Z0DAN add/remove protocol works in case
# of multiple adding cycles.
#
# ##############################################################################

$pgbench_stdout1='';
$pgbench_stderr1='';
$pgbench_stdout2='';
$pgbench_stderr2='';
$pgbench_handle1 = IPC::Run::start(
    [ "$pg_bin/pgbench", '-n', '-f', $load1, '-T', 80, '-j', 3, '-c', 3,
	'-h', $host, '-p', $node_ports->[0], '-U', $db_user, $dbname],
	'>', \$pgbench_stdout1, '2>', \$pgbench_stderr1);
$pgbench_handle2 = IPC::Run::start(
    [ "$pg_bin/pgbench", '-n', '-f', $load2, '-T', 80, '-j', 3, '-c', 3,
	'-h', $host, '-p', $node_ports->[1], '-U', $db_user, $dbname],
	'>', \$pgbench_stdout2, '2>', \$pgbench_stderr2);
$pgbench_handle1->pump();
$pgbench_handle2->pump();

# Warming up ...
print STDERR "warming up pgbench for 5s\n";
sleep(5);
print STDERR "done warmup\n";

print STDERR "Add N3 into highly loaded configuration of N1 and N2 ...";
psql_or_bail(3,
	"CALL spock.add_node(src_node_name := 'n1',
						 src_dsn := 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user',
						 new_node_name := 'n3',
						 new_node_dsn := 'host=$host dbname=$dbname port=$node_ports->[2] user=$db_user',
						 verb := false);");

# ...

# Ensure that pgbench load lasts longer than the Z0DAN protocol.
$pid = $pgbench_handle1->{KIDS}[0]{PID};
$alive = kill 0, $pid;
ok($alive eq 1, "pgbench load to N1 still exists");
$pid = $pgbench_handle2->{KIDS}[0]{PID};
$alive = kill 0, $pid;
ok($alive eq 1, "pgbench load to N2 still exists");

print STDERR "Kill pgbench process to reduce test time\n";
$pgbench_handle1->pump();
$pgbench_handle2->pump();
$pgbench_handle1->kill_kill;
$pgbench_handle2->kill_kill;

print STDERR "Check if pgbench finalised correctly\n";
$pgbench_handle1->finish;
$pgbench_handle2->finish;
print STDERR "##### output of pgbench #####\n";
print STDERR $pgbench_stdout1;
print STDERR $pgbench_stdout2;
print STDERR "##### end of output #####\n";

# We need such a trick: the wait_slot_confirm_lsn routine gets Last Committed
# LSN position and waits for the confirmations on the remote side. But if there
# a conflict has happened, feedback will not be sent and we will wait forever.
psql_or_bail(1, "SELECT spock.sync_event()");
psql_or_bail(2, "SELECT spock.sync_event()");
psql_or_bail(3, "SELECT spock.sync_event()");

psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(2, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');

print STDERR "Wait for the end of N3->N1, N3->N2 decoding process that means the actual start of LR\n";
psql_or_bail(3, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');

print STDERR "Wait until the end of replication ..\n";
$lag = scalar_query(1, "SELECT * FROM wait_subscription(remote_node_name := 'n2',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N2 => N1 has been finished successfully");
$lag = scalar_query(2, "SELECT * FROM wait_subscription(remote_node_name := 'n1',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N1 => N2 has been finished successfully");
$lag = scalar_query(3, "SELECT * FROM wait_subscription(remote_node_name := 'n1',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N1 => N3 has been finished successfully");
$lag = scalar_query(3, "SELECT * FROM wait_subscription(remote_node_name := 'n2',
														   report_it := true,
														   timeout := '10 minutes',
														   delay := 1.)");
ok($lag  <= 0, "Replication N2 => N3 has been finished successfully");

print STDERR "Check the data consistency.\n";
$ret1 = scalar_query(1, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts");
print STDERR "The N1's pgbench_accounts aggregates: $ret1\n";
$ret2 = scalar_query(2, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts");
print STDERR "The N2's pgbench_accounts aggregates: $ret2\n";
$ret3 = scalar_query(3, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts");
print STDERR "The N3's pgbench_accounts aggregates: $ret3\n";

ok($ret1 eq $ret2, "Equality of the data on N1 and N2 is confirmed");
ok($ret1 eq $ret3, "Equality of the data on N1 and N3 is confirmed");

# Cleanup will be handled by SpockTest.pm END block
# No need for done_testing() when using a test plan
