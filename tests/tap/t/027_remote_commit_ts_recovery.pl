#!/usr/bin/perl
# =============================================================================
# Test: 027_remote_commit_ts_recovery.pl
#       Verify that after a crash, remote_commit_ts is recovered from the
#       subscriber's pg_commit_ts SLRU rather than left NULL, so the
#       spock.progress view shows an accurate timestamp post-crash. The
#       recovered prev_remote_ts is also intended to be useful for the
#       planned parallel-apply rework.
#
# Topology:  n1 (provider) -> n2 (subscriber)
#
# Sequence:
#   1. Apply commits, clean restart (writes resource.dat).
#   2. Apply more commits (origin advances; resource.dat stale).
#   3. SIGKILL subscriber.
#   4. Restart. Apply worker reconcile detects stale, calls the new
#      recover_progress_timestamps_from_commit_ts which scans pg_commit_ts
#      backward and populates remote_commit_ts.
#   5. Assert remote_commit_ts is NOT NULL.
# =============================================================================

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail
    command_ok get_test_config scalar_query psql_or_bail
    wait_for_sub_status wait_for_pg_ready
);

sub wait_until {
    my ($timeout_s, $probe) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if $probe->();
        select(undef, undef, undef, 0.25);
    }
    return 0;
}

create_cluster(2, 'Create 2-node cluster');

my $conf      = get_test_config();
my $host      = $conf->{host};
my $pg_bin    = $conf->{pg_bin};
my $ports     = $conf->{node_ports};
my $datadirs  = $conf->{node_datadirs};
my $dbname    = $conf->{db_name};
my $user      = $conf->{db_user};

my $prov_port = $ports->[0];
my $sub_port  = $ports->[1];
my $sub_dir   = $datadirs->[1];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

psql_or_bail(1, "CREATE TABLE public.ts_recovery (id int primary key, val text)");
psql_or_bail(2, "CREATE TABLE public.ts_recovery (id int primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('test_sub', '$prov_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'subscription is replicating');

# --- Round 1: apply, clean restart so resource.dat is written. ---
psql_or_bail(1, "INSERT INTO public.ts_recovery SELECT g, 'r1_' || g FROM generate_series(1,50) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.ts_recovery") eq '50' }),
   'round-1 50 rows replicated');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
ok(-f "$sub_dir/spock/resource.dat", 'resource.dat written on clean stop');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber back up');
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'replicating after clean restart');

# --- Round 2: apply more so origin advances past resource.dat's snapshot. ---
psql_or_bail(1, "INSERT INTO public.ts_recovery SELECT g, 'r2_' || g FROM generate_series(51,100) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.ts_recovery") eq '100' }),
   'round-2 50 rows replicated');

# Confirm remote_commit_ts is non-NULL pre-crash (sanity).
my $pre_ts = scalar_query(2, "SELECT remote_commit_ts::text FROM spock.progress LIMIT 1");
ok($pre_ts ne '', "pre-crash remote_commit_ts populated: $pre_ts");

# Capture pre-crash remote_commit_lsn. After restart, the post-reconcile
# remote_commit_lsn must reach AT LEAST this value -- resource.dat alone
# holds the round-1 snapshot, whose commit_lsn is strictly less. Observing
# commit_lsn >= $pre_lsn therefore proves reconcile actually ran.
my $pre_lsn = scalar_query(2, "SELECT remote_commit_lsn::text FROM spock.progress LIMIT 1");
diag("pre-crash remote_commit_lsn=$pre_lsn");

# CHECKPOINT to advance pg_replication_origin durably past resource.dat's
# round-1 snapshot. Without this, after SIGKILL the origin may roll back to
# round-1 and reconcile takes the IN_SYNC branch -- not what we want to test.
psql_or_bail(2, 'CHECKPOINT');
select(undef, undef, undef, 0.5);

# --- SIGKILL subscriber. ---
my $pid_file = "$sub_dir/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $sub_pid = <$fh>;
chomp($sub_pid);
close($fh);
kill 'KILL', $sub_pid;
pass('subscriber SIGKILLed');

select(undef, undef, undef, 2.0);

# --- Restart. Reconcile detects stale; recovery scan populates remote_commit_ts. ---
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber accepting connections after crash');

# Wait for the apply worker to start, run reconcile, run recovery scan.
# Gate on BOTH:
#   1. remote_commit_lsn >= pre-crash value (proves reconcile ran;
#      resource.dat reseed alone gives round-1 commit_lsn, strictly less).
#   2. remote_commit_ts IS NOT NULL (proves recovery scan ran; reconcile
#      clears ts to 0/NULL when stale, so non-NULL after reconcile means
#      the scan repopulated it).
# Both updates are atomic under apply_group_master_lock, so SQL reads
# see one consistent (commit_lsn, ts) pair per query.
ok(wait_until(30, sub {
    my $row = scalar_query(2, qq{
        SELECT remote_commit_lsn >= '$pre_lsn'::pg_lsn
               AND remote_commit_ts IS NOT NULL
        FROM spock.progress LIMIT 1
    });
    defined $row && $row eq 't'
}), 'reconcile advanced commit_lsn AND recovery scan repopulated remote_commit_ts');

# --- Assertions ---
my $post_not_null = scalar_query(2,
    "SELECT remote_commit_ts IS NOT NULL FROM spock.progress LIMIT 1");
is($post_not_null, 't',
   "post-crash remote_commit_ts is NOT NULL (recovered via pg_commit_ts scan)");

my $post_lsn = scalar_query(2,
    "SELECT remote_commit_lsn::text FROM spock.progress LIMIT 1");
diag("post-crash remote_commit_lsn=$post_lsn (pre-crash was $pre_lsn)");

my $post_lsn_advanced = scalar_query(2, qq{
    SELECT remote_commit_lsn >= '$pre_lsn'::pg_lsn
    FROM spock.progress LIMIT 1
});
is($post_lsn_advanced, 't',
   "post-crash remote_commit_lsn >= pre-crash $pre_lsn (reconcile ran)");

my $post_ts = scalar_query(2, "SELECT remote_commit_ts::text FROM spock.progress LIMIT 1");
diag("post-crash remote_commit_ts: '$post_ts'");

psql_or_bail(2, "SELECT spock.sub_drop('test_sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
