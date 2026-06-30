#!/usr/bin/perl
# =============================================================================
# Test: 029_remote_commit_ts_recovery_clean_shutdown.pl
#       Verify that on a CLEAN restart (resource.dat in sync with origin),
#       the recovery scan is SKIPPED and the loaded remote_commit_ts is
#       preserved. Confirmed via the apply-worker INFO log line
#       "ts recovery: file in sync with origin, skipping scan".
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

sub log_grep_count {
    my ($logdir, $pattern) = @_;
    return 0 unless -d $logdir;
    opendir(my $dh, $logdir) or return 0;
    my @logs = grep { /\.log$/ } readdir($dh);
    closedir($dh);
    my $count = 0;
    for my $name (@logs) {
        my $path = "$logdir/$name";
        open(my $fh, '<', $path) or next;
        while (my $line = <$fh>) {
            $count++ if $line =~ /$pattern/;
        }
        close($fh);
    }
    return $count;
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
# The logging collector writes server logs into the harness log directory
# (TESTLOGDIR) as 00<port>.log, not into the data directory.  Grep there for
# the apply worker's "ts recovery" lines.
my $logdir    = $conf->{log_dir};

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

psql_or_bail(1, "CREATE TABLE public.ts_clean (id int primary key, val text)");
psql_or_bail(2, "CREATE TABLE public.ts_clean (id int primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('test_sub', '$prov_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'subscription is replicating');

psql_or_bail(1, "INSERT INTO public.ts_clean SELECT g, 'r_' || g FROM generate_series(1,50) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM public.ts_clean") eq '50' }),
   '50 rows replicated');

# Capture pre-shutdown ts.
my $pre_ts = scalar_query(2, "SELECT remote_commit_ts::text FROM spock.progress LIMIT 1");
ok($pre_ts ne '', "pre-shutdown remote_commit_ts: $pre_ts");

# Establish baseline counts BEFORE the restart we're testing.
my $skip_before = log_grep_count($logdir, qr/ts recovery: file in sync with origin, skipping scan/);
my $run_before  = log_grep_count($logdir, qr/ts recovery: scanned \d+ xids, found \d+ commits/);

# CLEAN shutdown + restart. resource.dat should match origin LSN.
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
ok(-f "$sub_dir/spock/resource.dat", 'resource.dat written on clean stop');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber back up');
ok(wait_for_sub_status(2, 'test_sub', 'replicating', 30), 'replicating after clean restart');

# Wait for the new "skipping scan" log line (one per apply-worker restart).
ok(wait_until(15, sub {
    log_grep_count($logdir, qr/ts recovery: file in sync with origin, skipping scan/) > $skip_before
}), 'apply worker logged "file in sync, skipping scan" on clean restart');

# The run path must NOT have fired for this restart.
my $run_after = log_grep_count($logdir, qr/ts recovery: scanned \d+ xids, found \d+ commits/);
is($run_after, $run_before,
   'recovery scan did NOT run on clean restart (no "scanned ... xids, found ... commits" line)');

# remote_commit_ts should still match pre-shutdown.
my $post_ts = scalar_query(2, "SELECT remote_commit_ts::text FROM spock.progress LIMIT 1");
is($post_ts, $pre_ts, "remote_commit_ts preserved across clean restart");

psql_or_bail(2, "SELECT spock.sub_drop('test_sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
