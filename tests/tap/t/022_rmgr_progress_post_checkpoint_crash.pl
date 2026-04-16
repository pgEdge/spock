#!/usr/bin/perl
# =============================================================================
# Test: 022_rmgr_progress_post_checkpoint_crash.pl
#       Verify spock.progress survives crash when a regular checkpoint has
#       advanced checkPointRedo past the last SPOCK_RMGR_APPLY_PROGRESS
#       WAL records.
# =============================================================================
#
# WHY THIS TEST EXISTS
# --------------------
# In a long-running cluster, regular checkpoints (every checkpoint_timeout,
# default 5 min) continuously advance checkPointRedo. If apply workers have
# been idle (provider unreachable) for longer than checkpoint_timeout, the
# last progress WAL records end up BEFORE checkPointRedo and are not in the
# WAL replay window after a crash. Recovery falls back to the stale
# resource.dat values from the last clean shutdown.
#
# This test reproduces that scenario explicitly by:
#   1. Replicating data and capturing the progress snapshot
#   2. Stopping the provider (apply workers go idle)
#   3. Forcing a CHECKPOINT on the subscriber — advances checkPointRedo past
#      the last SPOCK_RMGR_APPLY_PROGRESS records
#   4. SIGKILL the subscriber (true crash, no resource.dat update)
#   5. Restarting the subscriber (provider still down)
#   6. Asserting progress matches the pre-crash snapshot
#
# Topology:  n1 (provider) -> n2 (subscriber)
# =============================================================================

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail system_maybe
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

# =============================================================================
# 1. Setup
# =============================================================================

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
my $prov_dir  = $datadirs->[0];
my $sub_dir   = $datadirs->[1];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

psql_or_bail(1, "CREATE TABLE public.rmgr_ckpt (id int primary key, val text)");
psql_or_bail(2, "CREATE TABLE public.rmgr_ckpt (id int primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('test_sub', '$prov_dsn', ARRAY['default'], false, false)");

ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30),
    'subscription is replicating');

# Clean stop n2 now — before any DML — so resource.dat is written with an
# empty progress baseline (no rows replicated yet, so no progress entries).
# After restart the DML below produces SPOCK_RMGR_APPLY_PROGRESS WAL records,
# but resource.dat still holds the empty snapshot.  The CHECKPOINT in step 4
# must update resource.dat (fix present) or leave it stale (bug present).
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
ok((-f "$sub_dir/spock/resource.dat"), 'resource.dat written with empty progress baseline');
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30),
    'n2 restarted — resource.dat holds empty baseline, provider still up');

psql_or_bail(1, "INSERT INTO public.rmgr_ckpt SELECT g, 'row_' || g FROM generate_series(1,100) g");

ok(wait_until(30, sub {
    scalar_query(2, "SELECT count(*) FROM public.rmgr_ckpt") eq '100'
}), 'subscriber has 100 rows');

# =============================================================================
# 2. Capture spock.progress snapshot
# =============================================================================

ok(wait_until(30, sub {
    my $c = scalar_query(2, "SELECT count(*) FROM spock.progress");
    defined $c && $c >= 1
}), 'spock.progress has at least one entry');

my $snap = scalar_query(2, q{
    SELECT remote_commit_ts || '|' || remote_commit_lsn || '|' || remote_insert_lsn
    FROM spock.progress
    ORDER BY remote_commit_ts DESC
    LIMIT 1
});
ok($snap =~ /\S+\|\S+\|\S+/, "captured progress snapshot: $snap");

my ($pre_ts, $pre_commit_lsn, $pre_insert_lsn) = split(/\|/, $snap, 3);
my $pre_count = scalar_query(2, "SELECT count(*) FROM spock.progress");

diag("Pre-crash progress: $snap");
diag("Progress WAL records are now at some LSN 'A'");

# =============================================================================
# 3. Stop provider — apply workers on subscriber go idle (no more DML)
# =============================================================================

system_or_bail "$pg_bin/pg_ctl", '-D', $prov_dir, '-m', 'fast', 'stop';
pass('provider (n1) stopped — apply workers on n2 now idle');

# Give apply worker a moment to notice the provider is gone
select(undef, undef, undef, 1.0);

# =============================================================================
# 4. Force a CHECKPOINT on the subscriber
#
# This advances checkPointRedo to a point AFTER the last
# SPOCK_RMGR_APPLY_PROGRESS WAL records written in step 2. After the
# checkpoint, those records are no longer in the WAL replay window.
#
# This simulates what happens naturally in a long-running cluster where
# checkpoint_timeout (default 5 min) runs periodically while apply workers
# are idle (provider unreachable).
# =============================================================================

psql_or_bail(2, 'CHECKPOINT');
pass('CHECKPOINT forced on subscriber — checkPointRedo now past progress WAL records');

diag("checkPointRedo has now advanced past the SPOCK_RMGR_APPLY_PROGRESS records");
diag("After crash+recovery, WAL replay will NOT see those records");
diag("If bug is present: recovery falls back to stale resource.dat");

# =============================================================================
# 5. SIGKILL subscriber (true crash — no shmem_exit, no resource.dat update)
# =============================================================================

my $pid_file = "$sub_dir/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $sub_pid = <$fh>;
chomp($sub_pid);
close($fh);

diag("SIGKILLing n2 postmaster (PID $sub_pid)");
kill 'KILL', $sub_pid;
pass('subscriber (n2) SIGKILLed — resource.dat NOT updated');

# Let OS reap the process before pg_ctl start
select(undef, undef, undef, 2.0);

# =============================================================================
# 6. Restart subscriber (provider still down — only WAL replay can populate
#    spock.progress, but the relevant records are before checkPointRedo)
# =============================================================================

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';

ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30),
    'subscriber (n2) is accepting connections after crash recovery');

# =============================================================================
# 7. Assert: progress must match pre-crash snapshot
# =============================================================================

my $post_count = scalar_query(2, "SELECT count(*) FROM spock.progress");
is($post_count, $pre_count,
    "spock.progress row count matches after crash ($pre_count rows)");

my $post_snap = scalar_query(2, q{
    SELECT remote_commit_ts || '|' || remote_commit_lsn || '|' || remote_insert_lsn
    FROM spock.progress
    ORDER BY remote_commit_ts DESC
    LIMIT 1
});
ok($post_snap =~ /\S+\|\S+\|\S+/, "progress readable after crash recovery: $post_snap");

diag("Pre-crash:  $snap");
diag("Post-crash: $post_snap");

my ($post_ts, $post_commit_lsn, $post_insert_lsn) = split(/\|/, $post_snap, 3);

is($post_ts, $pre_ts,
    "remote_commit_ts matches pre-crash value after crash recovery");
is($post_commit_lsn, $pre_commit_lsn,
    "remote_commit_lsn matches pre-crash value after crash recovery");
is($post_insert_lsn, $pre_insert_lsn,
    "remote_insert_lsn matches pre-crash value after crash recovery");

# =============================================================================
# Cleanup
# =============================================================================

system_or_bail "$pg_bin/pg_ctl", '-D', $prov_dir, '-o', "-p $prov_port", '-w', 'start';
ok(wait_for_pg_ready($host, $prov_port, $pg_bin, 30), 'provider (n1) restarted');

psql_or_bail(2, "SELECT spock.sub_drop('test_sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
