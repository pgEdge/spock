#!/usr/bin/perl
# =============================================================================
# Test: 023_forced_keepalive_timing.pl
#       Verify that after apply-worker reconnect, received_lsn in
#       spock.progress is populated quickly (within a couple of seconds)
#       even when wal_sender_timeout is set high enough that the publisher's
#       timer-driven keepalive would not fire.
#
# Proves the forced 'r' status update with replyRequested=true sent
# immediately after spock_start_replication triggers an immediate 'k'
# reply from the publisher. We assert received_lsn (not remote_insert_lsn)
# because 'k' messages only update received_lsn; remote_insert_lsn is
# only advanced by 'w' data messages (see UpdateWorkerStats and the 'k'
# handler in spock_apply.c).
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
        select(undef, undef, undef, 0.05);
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
my $prov_dir  = $datadirs->[0];
my $sub_dir   = $datadirs->[1];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

# Set wal_sender_timeout HIGH on the provider so the timer-driven
# keepalive (fires at wal_sender_timeout/2) would take 5 minutes to
# arrive. Any remote_insert_lsn refresh within seconds must therefore be
# driven by our forced initial status update.
psql_or_bail(1, "ALTER SYSTEM SET wal_sender_timeout = '10min'");
system_or_bail "$pg_bin/pg_ctl", '-D', $prov_dir, 'reload';

psql_or_bail(1, "CREATE TABLE public.keepalive_test (id int primary key)");
psql_or_bail(2, "CREATE TABLE public.keepalive_test (id int primary key)");

psql_or_bail(2, "SELECT spock.sub_create('sub', '$prov_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'sub', 'replicating', 30), 'subscription is replicating');

# Apply one commit so shmem has a real entry.
psql_or_bail(1, "INSERT INTO public.keepalive_test VALUES (1)");
ok(wait_until(10, sub { scalar_query(2, "SELECT count(*) FROM public.keepalive_test") eq '1' }),
   'row replicated');

ok(wait_until(10, sub {
    my $lsn = scalar_query(2, "SELECT received_lsn::text FROM spock.progress LIMIT 1");
    defined $lsn && $lsn ne '' && $lsn ne '0/0'
}), 'received_lsn populated by initial apply');

# Stop subscriber cleanly. The supervisor's before_shmem_exit writes
# resource.dat with the current shmem state -- which would mask a
# broken forced keepalive on the next start (shmem reseeds from the file
# before reconnect, so "non-zero" assertions would pass spuriously).
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';

# Remove resource.dat so shmem starts empty on next boot. After
# reconcile_progress_with_origin runs in the ABSENT branch, the new
# entry has received_lsn = InvalidXLogRecPtr. The only mechanism that
# can populate it within seconds is a 'k' keepalive carrying the
# publisher's sentPtr -- which is exactly what request_initial_status_update
# triggers. Without forced keepalive, the timer-driven 'k' wouldn't fire
# for wal_sender_timeout/2 = 5min, well outside the test's window.
my $resource_dat = "$sub_dir/spock/resource.dat";
unlink $resource_dat or diag "no resource.dat to remove (already absent)";
ok(! -e $resource_dat, 'resource.dat absent before restart');

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber restarted');

# After restart, wait for the subscription to reach 'replicating' again
# (apply worker reconnected and the forced keepalive was sent).
ok(wait_for_sub_status(2, 'sub', 'replicating', 30), 'subscription replicating after restart');

# received_lsn must transition from 0/0 (post-reconcile) to a non-zero
# LSN within 5s. Under the forced-keepalive path this happens in
# milliseconds; without it, in 5 minutes (wal_sender_timeout/2).
my $start = time();
my $got = wait_until(5, sub {
    my $lsn = scalar_query(2, "SELECT received_lsn::text FROM spock.progress LIMIT 1");
    defined $lsn && $lsn ne '' && $lsn ne '0/0'
});
my $elapsed = time() - $start;

ok($got,
   "received_lsn populated within 5s of reconnect despite wal_sender_timeout=10min (elapsed=${elapsed}s)");

# Sanity: confirm wal_sender_timeout is actually high on the provider
# (i.e., the setting took effect). If it didn't, the above test might
# pass for the wrong reason.
my $wst = scalar_query(1, "SHOW wal_sender_timeout");
ok($wst eq '10min' || $wst eq '600000ms',
   "provider wal_sender_timeout is '10min' ($wst)");

psql_or_bail(2, "SELECT spock.sub_drop('sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
