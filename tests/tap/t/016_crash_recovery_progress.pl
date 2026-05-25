#!/usr/bin/perl
# =============================================================================
# Test: 016_crash_recovery_progress.pl
#       Verify that after a SIGKILL of the subscriber, the apply worker
#       reconnects, the forced keepalive refreshes received_lsn from the
#       publisher's sentPtr, and a subsequent commit drives remote_insert_lsn
#       forward via the next 'w' message -- so spock.progress reflects a
#       value at least as advanced as the pre-crash position.
#
# Topology:  n1 (provider) -> n2 (subscriber)
#
# Background:
#   resource.dat is a shutdown-only snapshot, so after SIGKILL the on-disk
#   file (if any) is stale. reconcile_progress_with_origin clamps
#   remote_insert_lsn / received_lsn up to the durable origin LSN
#   (= end_lsn of last applied commit), which may be below the pre-crash
#   values. The publisher's forced keepalive on reconnect populates
#   received_lsn with the publisher's current sentPtr; remote_insert_lsn
#   only advances when a 'w' data message arrives, so we drive one by
#   inserting after the restart.
#
# Note: pre/post equality is NOT asserted -- pre-crash remote_insert_lsn
# is r->dataStart of the latest received record on the subscriber, while
# post-crash refreshes come from publisher state at different moments.
# The invariant the new design guarantees is monotonic advance (>=).
# =============================================================================

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail
                 get_test_config scalar_query psql_or_bail
                 wait_for_sub_status wait_for_pg_ready);

sub wait_until {
    my ($timeout_s, $probe) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if $probe->();
        select(undef, undef, undef, 0.1);
    }
    return 0;
}

# =============================================================================
# SETUP: 2-node cluster
# =============================================================================

create_cluster(2, 'Create 2-node cluster');

my $config = get_test_config();
my $host          = $config->{host};
my $pg_bin        = $config->{pg_bin};
my $node_ports    = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $dbname        = $config->{db_name};

my $sub_dir  = $node_datadirs->[1];
my $sub_port = $node_ports->[1];

my $conn_n1 = "host=$host port=$node_ports->[0] dbname=$dbname";

psql_or_bail(1, "CREATE TABLE test_progress (id serial primary key, val text)");
psql_or_bail(2, "CREATE TABLE test_progress (id serial primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30), 'subscription is replicating');

# =============================================================================
# Apply rows and capture pre-crash LSNs.
# =============================================================================

psql_or_bail(1, "INSERT INTO test_progress (val) SELECT 'row_' || g FROM generate_series(1, 100) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT COUNT(*) FROM test_progress") eq '100' }),
   '100 rows replicated to n2');

my $remote_node_filter = "remote_node_id = (SELECT node_id FROM spock.node WHERE node_name = 'n1')";

my $insert_lsn_before   = scalar_query(2, "SELECT remote_insert_lsn::text   FROM spock.progress WHERE $remote_node_filter");
my $received_lsn_before = scalar_query(2, "SELECT received_lsn::text        FROM spock.progress WHERE $remote_node_filter");
my $commit_lsn_before   = scalar_query(2, "SELECT remote_commit_lsn::text   FROM spock.progress WHERE $remote_node_filter");

diag("pre-crash: insert=$insert_lsn_before received=$received_lsn_before commit=$commit_lsn_before");
ok($insert_lsn_before   ne '' && $insert_lsn_before   ne '0/0', 'pre-crash remote_insert_lsn populated');
ok($received_lsn_before ne '' && $received_lsn_before ne '0/0', 'pre-crash received_lsn populated');

# =============================================================================
# SIGKILL n2.
# =============================================================================

my $pid_file = "$sub_dir/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $postmaster_pid = <$fh>;
chomp($postmaster_pid);
close($fh);

diag("Killing n2 (PID $postmaster_pid) with SIGKILL");
kill 'KILL', $postmaster_pid;
select(undef, undef, undef, 2.0);

# =============================================================================
# Restart and wait for the apply worker to reconnect.
# =============================================================================

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'n2 accepting connections after crash');
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30), 'subscription replicating after restart');

# =============================================================================
# Verify post-crash recovery.
# =============================================================================
#
# At this point the forced keepalive has been sent and should have refreshed
# received_lsn. To advance remote_insert_lsn past whatever reconcile clamped
# it to, drive a 'w' message by inserting on the publisher.

psql_or_bail(1, "INSERT INTO test_progress (val) VALUES ('after_crash')");
ok(wait_until(30, sub { scalar_query(2, "SELECT COUNT(*) FROM test_progress") eq '101' }),
   'post-crash insert replicated to n2');

# Both LSNs should now be >= their pre-crash values. wait_until is a short
# safety net for shmem propagation; in practice this resolves on the first
# probe once the row above has been applied.
ok(wait_until(5, sub {
    my $ok = scalar_query(2, qq{
        SELECT remote_insert_lsn >= '$insert_lsn_before'::pg_lsn
               AND received_lsn  >= '$received_lsn_before'::pg_lsn
        FROM spock.progress WHERE $remote_node_filter
    });
    defined $ok && $ok eq 't'
}), 'post-crash remote_insert_lsn and received_lsn advanced past pre-crash values');

my $insert_lsn_after   = scalar_query(2, "SELECT remote_insert_lsn::text FROM spock.progress WHERE $remote_node_filter");
my $received_lsn_after = scalar_query(2, "SELECT received_lsn::text      FROM spock.progress WHERE $remote_node_filter");
my $commit_lsn_after   = scalar_query(2, "SELECT remote_commit_lsn::text FROM spock.progress WHERE $remote_node_filter");
diag("post-crash: insert=$insert_lsn_after received=$received_lsn_after commit=$commit_lsn_after");

# Explicit non-zero assertions for clarity in the test report.
ok($insert_lsn_after   ne '' && $insert_lsn_after   ne '0/0', 'remote_insert_lsn non-zero after recovery');
ok($received_lsn_after ne '' && $received_lsn_after ne '0/0', 'received_lsn non-zero after recovery');

# remote_commit_lsn must also have survived (this is what reconcile guarantees
# via the durable replication origin). 027 covers the deeper recovery-scan
# path; the assertion here is just a smoke check.
my $commit_advanced = scalar_query(2, qq{
    SELECT remote_commit_lsn >= '$commit_lsn_before'::pg_lsn
    FROM spock.progress WHERE $remote_node_filter
});
is($commit_advanced, 't', 'remote_commit_lsn >= pre-crash value (reconcile via durable origin)');

destroy_cluster('Cleanup');
done_testing();
