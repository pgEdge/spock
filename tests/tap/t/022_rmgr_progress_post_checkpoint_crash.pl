#!/usr/bin/perl
# =============================================================================
# Test: 022_rmgr_progress_post_checkpoint_crash.pl
#       Verify spock.progress recovers correctly after a crash when
#       resource.dat on disk is stale relative to the replication origin.
# =============================================================================
#
# WHY THIS TEST EXISTS
# --------------------
# Under the post-WAL-RMGR design, resource.dat is written only at clean
# shutdown (and after add_node / table sync).  Between a clean shutdown and
# the next crash, the apply worker may advance the replication origin and
# shmem via applied commits, while resource.dat stays at the shutdown-time
# snapshot.  On crash-restart:
#
#   - shmem_startup loads the stale file.
#   - WAL recovery advances pg_replication_origin to its durable post-commit
#     value (via xact_redo_commit → replorigin_advance_by_xlog).
#   - The apply worker's reconcile_progress_with_origin() at startup
#     detects file_lsn < origin_lsn, overwrites remote_commit_lsn with
#     origin_lsn, and clears the (now-stale) timestamp fields to NULL.
#
# This test reproduces that exact scenario and asserts:
#   - remote_commit_lsn matches pre-crash value (recovered via origin).
#   - remote_commit_ts is NULL post-crash (reconcile cleared the stale ts).
#
# Provider is kept UP throughout so the apply worker can actually restart
# and run reconcile after the subscriber crash. (If the provider were down
# during the crash + restart sequence, Spock's SUB_DISABLE behaviour would
# prevent the apply worker from restarting, and reconcile would never run.)
#
# Topology:  n1 (provider) -> n2 (subscriber)
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

ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'subscription is replicating');

# =============================================================================
# 2. Apply DML, then clean restart.  resource.dat is written with the
#    current shmem values; on restart, reconcile finds file_lsn == origin_lsn
#    (MATCH branch, keeps timestamps).
# =============================================================================

psql_or_bail(1, "INSERT INTO public.rmgr_ckpt SELECT g, 'round1_' || g FROM generate_series(1,50) g");

ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.rmgr_ckpt") eq '50' }),
   'round-1 50 rows replicated to subscriber');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
ok(-f "$sub_dir/spock/resource.dat", 'resource.dat written on clean stop');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber back up after clean restart');
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30),
   'subscription replicating again after clean restart');

# =============================================================================
# 3. Apply more DML.  shmem and origin advance, but resource.dat stays at
#    the post-round-1 snapshot.  This creates the "file stale vs origin"
#    precondition that reconcile is designed for.
# =============================================================================

psql_or_bail(1, "INSERT INTO public.rmgr_ckpt SELECT g, 'round2_' || g FROM generate_series(51,100) g");

ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.rmgr_ckpt") eq '100' }),
   'round-2 50 rows replicated to subscriber');

ok(wait_until(30, sub {
    my $c = scalar_query(2, "SELECT count(*) FROM spock.progress");
    defined $c && $c >= 1
}), 'spock.progress has at least one entry');

my $pre_snap = scalar_query(2, q{
    SELECT remote_commit_lsn::text FROM spock.progress LIMIT 1
});
ok($pre_snap =~ m{^[0-9A-F]+/[0-9A-F]+$}, "pre-crash remote_commit_lsn: $pre_snap");

my $pre_origin = scalar_query(2, q{
    SELECT remote_lsn::text FROM pg_replication_origin_status
    WHERE external_id = 'spk_regression_n1_test_sub'
});
is($pre_origin, $pre_snap, "pre-crash: shmem and pg_replication_origin agree");

# =============================================================================
# 4. CHECKPOINT on the subscriber.
#
# Under the OLD (checkpoint-hook) design this rewrote resource.dat with
# current shmem values.  Under the NEW design it must NOT update
# resource.dat — we verify that resource.dat's mtime is unchanged below.
# =============================================================================

my $rdat_path = "$sub_dir/spock/resource.dat";
my $mtime_before_ckpt = (stat($rdat_path))[9];

psql_or_bail(2, 'CHECKPOINT');
# Give any lingering file-system work a moment to settle.
select(undef, undef, undef, 0.5);

my $mtime_after_ckpt = (stat($rdat_path))[9];
is($mtime_after_ckpt, $mtime_before_ckpt,
   "CHECKPOINT does NOT update resource.dat (regression guard against re-introducing checkpoint hook)");

# =============================================================================
# 5. SIGKILL subscriber — no shmem_exit, resource.dat untouched since step 2.
# =============================================================================

my $pid_file = "$sub_dir/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $sub_pid = <$fh>;
chomp($sub_pid);
close($fh);
kill 'KILL', $sub_pid;
pass('subscriber SIGKILLed');

select(undef, undef, undef, 2.0);

# =============================================================================
# 6. Restart subscriber (provider still UP so apply worker can run reconcile
#    and reconnect).  Don't wait for new data — the test asserts the shmem
#    state created by reconcile, before any further commits arrive.
# =============================================================================

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30),
   'subscriber accepting connections after crash recovery');

# Wait for the apply worker to start and run reconcile (which populates the
# shmem entry from origin).
ok(wait_until(30, sub {
    my $lsn = scalar_query(2, q{
        SELECT remote_commit_lsn::text FROM spock.progress LIMIT 1
    });
    defined $lsn && $lsn ne '' && $lsn ne '0/0'
}), 'reconcile populated spock.progress after crash-restart');

# =============================================================================
# 7. Assertions
# =============================================================================

my $post_commit_lsn = scalar_query(2, q{
    SELECT remote_commit_lsn::text FROM spock.progress LIMIT 1
});
is($post_commit_lsn, $pre_snap,
   "remote_commit_lsn matches pre-crash (recovered via replication origin)");

my $post_commit_ts = scalar_query(2, q{
    SELECT remote_commit_ts::text FROM spock.progress LIMIT 1
});
is($post_commit_ts, '',
   "remote_commit_ts is NULL post-crash (reconcile cleared stale ts)");

diag("post-crash: remote_commit_lsn=$post_commit_lsn remote_commit_ts='$post_commit_ts' (expected NULL)");

# =============================================================================
# Cleanup
# =============================================================================

psql_or_bail(2, "SELECT spock.sub_drop('test_sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
