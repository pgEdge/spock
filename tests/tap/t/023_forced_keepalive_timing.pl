#!/usr/bin/perl
# =============================================================================
# Test: 023_forced_keepalive_timing.pl
#       Verify that after apply-worker reconnect, remote_insert_lsn in
#       spock.progress is populated quickly (within a couple of seconds)
#       even when wal_sender_timeout is set high enough that the publisher's
#       timer-driven keepalive would not fire.
#
# Proves the forced 'r' status update with replyRequested=true sent
# immediately after spock_start_replication triggers an immediate 'k'
# reply from the publisher.
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
    my $lsn = scalar_query(2, "SELECT remote_insert_lsn::text FROM spock.progress LIMIT 1");
    defined $lsn && $lsn ne '' && $lsn ne '0/0'
}), 'remote_insert_lsn populated by initial apply');

# Restart the subscriber cleanly. With wal_sender_timeout=10min, the
# publisher's timer-driven 'k' message will NOT fire within our test
# window, so any refresh of remote_insert_lsn within seconds after the
# apply worker reconnects must be caused by our forced keepalive.
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'subscriber restarted');

# After restart, wait for the subscription to reach 'replicating' again
# (apply worker reconnected and the forced keepalive was sent).
ok(wait_for_sub_status(2, 'sub', 'replicating', 30), 'subscription replicating after restart');

# Capture the start time and wait for remote_insert_lsn to become non-zero.
# Under the forced-keepalive path, this should happen within 1-2 seconds.
# Without it, it would take wal_sender_timeout/2 = 5 minutes.
my $start = time();
my $got = wait_until(5, sub {
    my $lsn = scalar_query(2, "SELECT remote_insert_lsn::text FROM spock.progress LIMIT 1");
    defined $lsn && $lsn ne '' && $lsn ne '0/0'
});
my $elapsed = time() - $start;

ok($got,
   "remote_insert_lsn populated within 5s of reconnect despite wal_sender_timeout=10min (elapsed=${elapsed}s)");

# Sanity: confirm wal_sender_timeout is actually high on the provider
# (i.e., the setting took effect). If it didn't, the above test might
# pass for the wrong reason.
my $wst = scalar_query(1, "SHOW wal_sender_timeout");
ok($wst eq '10min' || $wst eq '600000ms',
   "provider wal_sender_timeout is '10min' ($wst)");

psql_or_bail(2, "SELECT spock.sub_drop('sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
