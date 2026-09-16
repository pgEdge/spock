#!/usr/bin/perl
# Test timestamp/LSN divergence on n2 -> n1 -> n3 forwarding.
#
# Hold commit A on n2, commit newer B on n1, then release A. Node n3 receives
# B before forwarded A, while A retains its older origin timestamp. Verify
# that LSN progress follows stream order and prev_remote_ts records A rather
# than the timestamp maximum. Also verify crash recovery does not invent a
# prev_remote_ts value.
#
# This does not exercise slot-group commit-order waiting.

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail psql_or_bail
                 scalar_query wait_for_sub_status get_test_config);

sub poll_slow {
    my ($node_num, $query, $expected, $timeout) = @_;
    $expected //= 'true';
    $timeout  //= 30;
    for (1 .. $timeout) {
        my $got = scalar_query($node_num, $query);
        return 1 if defined $got && $got eq $expected;
        sleep(1);
    }
    return 0;
}

create_cluster(3, 'Create 3-node cluster (n1, n2, n3)');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $pg_bin      = $config->{pg_bin};
my $dbname      = $config->{db_name};
my $host        = $config->{host};

my $conn_n1 = "host=$host port=$node_ports->[0] dbname=$dbname";
my $conn_n2 = "host=$host port=$node_ports->[1] dbname=$dbname";

# Set up the forwarding topology.

for my $n (1, 2, 3) {
    psql_or_bail($n, "SELECT spock.repset_create('skew_set')");
    psql_or_bail($n, "CREATE TABLE skew_test (id integer primary key, val text)");
    psql_or_bail($n, "SELECT spock.repset_add_table('skew_set', 'skew_test')");
}
pass('Created replication sets, test table, and repset membership on all nodes');

# n1 <- n2: ordinary subscription.
psql_or_bail(1,
    "SELECT spock.sub_create('sub_n1_n2', '$conn_n2', ARRAY['skew_set'], false, false)");
pass('Created subscription n1->n2');
ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30),
   'sub_n1_n2 is replicating');

# n3 receives both direct n1 commits and forwarded n2 commits.
psql_or_bail(3,
    "SELECT spock.sub_create('sub_n3_n1', '$conn_n1', ARRAY['skew_set'], false, false, ARRAY['all'])");
pass('Created subscription n3->n1 with forward_origins=all');
ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 30),
   'sub_n3_n1 is replicating');

# Confirm live streaming rather than relying only on subscription status.
psql_or_bail(1, "INSERT INTO skew_test (id, val) VALUES (1, 'settle_check')");
ok(poll_slow(3,
    "SELECT (COUNT(*) = 1)::text FROM skew_test WHERE val = 'settle_check'",
    'true', 30),
   'n3 confirmed streaming live changes from n1 before provoking the divergence');

# Deliver direct B before older forwarded A.

psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2')");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'disabled', 30),
   'sub_n1_n2 disabled -- n2 writes now undelivered');

psql_or_bail(2, "INSERT INTO skew_test (id, val) VALUES (2, 'row_from_n2_old')");
pass("Inserted row A on n2 (timestamp T_A) -- held back on n2's slot");

system_or_bail 'sleep', '2';

psql_or_bail(1, "INSERT INTO skew_test (id, val) VALUES (3, 'row_from_n1_direct')");
pass('Inserted row B directly on n1 (timestamp T_B > T_A)');

ok(poll_slow(3,
    "SELECT (COUNT(*) = 1)::text FROM skew_test WHERE val = 'row_from_n1_direct'",
    'true', 30),
   'Row B (n1 direct) reached n3 before A is ever delivered to n1');

# Capture the bound before releasing A; later WAL may exceed A's commit LSN.
my $lsn_before_release = scalar_query(1, "SELECT pg_current_wal_lsn()");

psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2')");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30),
   'sub_n1_n2 re-enabled -- n1 now applies and forwards row A');

ok(poll_slow(3,
    "SELECT (COUNT(*) = 1)::text FROM skew_test WHERE val = 'row_from_n2_old'",
    'true', 30),
   'Row A (forwarded, older timestamp) converges on n3 despite arriving after B in LSN order');

ok(poll_slow(3,
    "SELECT (COUNT(*) = 3)::text FROM skew_test",
    'true', 30),
   'n3 has all three expected rows after Row A converges');

# Check progress on n3 for the n1 stream.

my $lsn_advanced = poll_slow(3,
    "SELECT (remote_commit_lsn >= '$lsn_before_release'::pg_lsn)::text " .
    "FROM spock.progress p JOIN spock.node n ON n.node_id = p.remote_node_id " .
    "WHERE n.node_name = 'n1'",
    'true', 30);
ok($lsn_advanced,
   "remote_commit_lsn advanced past both commits despite the timestamp inversion");

my ($prev_ts, $commit_ts) = split /\|/, scalar_query(3,
    "SELECT prev_remote_ts || '|' || remote_commit_ts " .
    "FROM spock.progress p JOIN spock.node n ON n.node_id = p.remote_node_id " .
    "WHERE n.node_name = 'n1'");
diag("prev_remote_ts=$prev_ts  remote_commit_ts=$commit_ts");

my $prev_below_max = scalar_query(3,
    "SELECT (prev_remote_ts < remote_commit_ts)::text " .
    "FROM spock.progress p JOIN spock.node n ON n.node_id = p.remote_node_id " .
    "WHERE n.node_name = 'n1'");
is($prev_below_max, 'true',
   "prev_remote_ts (row A's timestamp) sits below remote_commit_ts (row B's, retained as the max) -- " .
   "impossible before this fix, when prev_remote_ts was gated the same way as remote_commit_ts");

# Crash n3 and verify recovery does not guess prev_remote_ts.
# Flush A and its origin progress so replay cannot mask the recovered value.
psql_or_bail(3, "CHECKPOINT");

my $pid_file = "$node_datadirs->[2]/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $n3_pid = <$fh>;
chomp($n3_pid);
close($fh);

diag("SIGKILLing n3 (PID $n3_pid)...");
kill 'KILL', $n3_pid;
system_or_bail 'sleep', '2';

diag("Restarting n3...");
system_or_bail "$pg_bin/pg_ctl", 'start', '-D', $node_datadirs->[2],
    '-l', "$node_datadirs->[2]/logfile", '-w';

ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 60),
   'sub_n3_n1 is replicating again after n3 restart');

my $prev_ts_after_crash = scalar_query(3,
    "SELECT prev_remote_ts " .
    "FROM spock.progress p JOIN spock.node n ON n.node_id = p.remote_node_id " .
    "WHERE n.node_name = 'n1'");
diag("prev_remote_ts after crash+restart: '$prev_ts_after_crash'");
is($prev_ts_after_crash, '',
   "prev_remote_ts reads NULL after crash recovery -- left unset, not reconstructed as a guess");

psql_or_bail(1, "INSERT INTO skew_test (id, val) VALUES (4, 'row_after_crash')");
ok(poll_slow(3,
    "SELECT (COUNT(*) = 1)::text FROM skew_test WHERE val = 'row_after_crash'",
    'true', 30),
   'Replication resumes and converges after the crash');

psql_or_bail(1, "DROP TABLE skew_test");

destroy_cluster('Cleanup');

done_testing();
