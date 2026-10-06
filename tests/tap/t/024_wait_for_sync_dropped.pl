use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status log_offset log_since
);

# =============================================================================
# Test 024: spock.sub_wait_for_sync() while the subscription is dropped
# =============================================================================
# A backend waiting in spock.sub_wait_for_sync() re-reads the subscription's
# sync status every 200 ms.  Dropping the subscription from another session
# removes that row, and the waiter used to pass the resulting NULL to pfree()
# and die with SIGSEGV, taking the whole server through crash recovery.  It
# must instead report that the subscription no longer exists.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for the wait-for-sync drop test');

my $config  = get_test_config();
my $host    = $config->{host};
my $dbname  = $config->{db_name};
my $db_user = $config->{db_user};
my $pw      = $config->{db_password};
my @ports   = @{$config->{node_ports}};
my $pg_bin  = $config->{pg_bin};
my $log_dir = $config->{log_dir};

my $provider_dsn = "host=$host dbname=$dbname port=$ports[0] user=$db_user password=$pw";

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n2_n1', '$provider_dsn', ARRAY['default'], true, true)");
ok(wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 60),
   'sub_n2_n1 reaches replicating state');

# A synced subscription makes the wait return at once; that is the baseline.
my ($rc) = psql_or_bail(2, "SELECT spock.sub_wait_for_sync('sub_n2_n1')");
pass('sub_wait_for_sync() returns at once for a synced subscription');

# Put the subscription back into "initializing" so the next wait blocks, the
# way it would for a subscription whose initial sync is stuck.
psql_or_bail(2,
    "UPDATE spock.local_sync_status SET sync_status = 'i' " .
    " WHERE sync_relname IS NULL " .
    "   AND sync_subid = (SELECT sub_id FROM spock.subscription WHERE sub_name = 'sub_n2_n1')");
is(scalar_query(2,
    "SELECT sync_status FROM spock.local_sync_status " .
    " WHERE sync_relname IS NULL " .
    "   AND sync_subid = (SELECT sub_id FROM spock.subscription WHERE sub_name = 'sub_n2_n1')"),
   'i', 'the subscription reads as not yet synced');

my $log_off = log_offset(2);

# Session A: wait.  Its output goes to a file, so the drop below can be run
# while it is still blocked.
my $out_file = "$log_dir/024_waiter.out";
my $waiter = fork();
die "fork failed" unless defined $waiter;
if ($waiter == 0) {
    open(STDOUT, '>', $out_file) or exit(1);
    open(STDERR, '>&', \*STDOUT);
    exec("$pg_bin/psql", '-X', '-h', $host, '-p', $ports[1], '-d', $dbname, '-U', $db_user,
         '-At', '-c', "SELECT spock.sub_wait_for_sync('sub_n2_n1')") or exit(1);
}
sleep(3);
is(scalar_query(2,
    "SELECT count(*) FROM pg_stat_activity " .
    " WHERE query LIKE '%sub_wait_for_sync%' AND pid <> pg_backend_pid()"),
   '1', 'session A is blocked in sub_wait_for_sync()');

# Session B: drop the subscription underneath it.
psql_or_bail(2, "SELECT spock.sub_drop('sub_n2_n1')");

waitpid($waiter, 0);
my $exit = $? >> 8;
open(my $fh, '<', $out_file) or die "cannot read $out_file: $!";
my $output = do { local $/; <$fh> };
close($fh);

isnt($exit, 0, 'the waiter ends with an error, not a result');
like($output, qr/subscription "sub_n2_n1" does not exist/,
     'the waiter is told the subscription no longer exists');
unlike($output, qr/server closed the connection unexpectedly/,
       'the waiter\'s connection was not lost');

my $log = log_since(2, $log_off);
unlike($log, qr/signal 11|Segmentation fault|terminating any other active server processes/,
       'no backend crashed and no crash recovery ran');

is(scalar_query(2, "SELECT 1"), '1', 'n2 is still serving');
is(scalar_query(2, "SELECT count(*) FROM spock.subscription WHERE sub_name = 'sub_n2_n1'"),
   '0', 'the subscription is gone');

destroy_cluster('Destroy cluster after the wait-for-sync drop test');
done_testing();
