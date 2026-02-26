#!/usr/bin/env perl
#
# 100_progress_period.pl - Measure replication catch-up time and progress
# table update frequency under pgbench load.
#
# This test builds up a WAL backlog by disabling the subscription during
# a pgbench run, then re-enables it and measures pure catch-up time.
# With deferred spock.progress writes, catch-up should be faster because
# the apply worker spends less time on catalog I/O.
#
# Run manually:
#   cd tests/tap/t && prove -v 100_progress_period.pl
#
# Tunable via environment variables:
#   PGBENCH_SCALE     - pgbench scale factor (default: 10)
#   PGBENCH_CLIENTS   - number of pgbench clients (default: 32)
#   PGBENCH_JOBS      - number of pgbench threads (default: 32)
#   PGBENCH_TIME      - pgbench duration in seconds (default: 30)
#
use strict;
use warnings;
use Test::More tests => 14;
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail
                 command_ok get_test_config scalar_query psql_or_bail);

$SIG{__DIE__} = sub { Carp::confess @_ };
$SIG{INT}     = sub { die("interrupted by SIGINT") };

my $PGBENCH_SCALE   = $ENV{PGBENCH_SCALE}   // 10;
my $PGBENCH_CLIENTS = $ENV{PGBENCH_CLIENTS} // 32;
my $PGBENCH_JOBS    = $ENV{PGBENCH_JOBS}    // 32;
my $PGBENCH_TIME    = $ENV{PGBENCH_TIME}    // 30;

# ── 1. Create a 2-node cluster ──────────────────────────────────────────

create_cluster(2, 'Create 2-node progress-period test cluster');

my $config    = get_test_config();
my $ports     = $config->{node_ports};
my $host      = $config->{host};
my $dbname    = $config->{db_name};
my $db_user   = $config->{db_user};
my $db_pass   = $config->{db_password};
my $pg_bin    = $config->{pg_bin};

my $provider_port   = $ports->[0];
my $subscriber_port = $ports->[1];
my $provider_connstr =
    "host=$host dbname=$dbname port=$provider_port user=$db_user password=$db_pass";

# Reduce log noise — this is a performance test, not a debugging test
for my $port ($provider_port, $subscriber_port) {
    system_or_bail "$pg_bin/psql", '-p', $port, '-d', $dbname, '-c',
        "ALTER SYSTEM SET log_min_messages TO warning";
    system_or_bail "$pg_bin/psql", '-p', $port, '-d', $dbname, '-c',
        "SELECT pg_reload_conf()";
}

# ── 2. Initialise pgbench on provider only ──────────────────────────────

note "initializing pgbench with scale=$PGBENCH_SCALE ...";
system_or_bail "$pg_bin/pgbench", '-i', '-s', $PGBENCH_SCALE,
    '-h', $host, '-p', $provider_port, '-U', $db_user, $dbname;
pass('pgbench initialized on provider');

# ── 3. Create subscription and wait for initial sync ────────────────────

system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c',
    "SELECT spock.sub_create(
        'test_sub',
        '$provider_connstr',
        ARRAY['default', 'default_insert_only'],
        true,
        true
    )";

my $max_wait = 120;
my $replicating = 0;
for (1 .. $max_wait) {
    my $status = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT status FROM spock.sub_show_status() WHERE subscription_name = 'test_sub'"`;
    chomp $status;
    $status =~ s/\s+//g;
    if ($status eq 'replicating') {
        $replicating = 1;
        last;
    }
    sleep 1;
}
BAIL_OUT('subscription never reached replicating state') unless $replicating;
pass('subscription is replicating');

# Let initial sync settle and confirm data matches before we start
system_or_bail "$pg_bin/psql", '-p', $provider_port, '-d', $dbname,
    '-c', "SET statement_timeout = '60s'; SELECT spock.wait_slot_confirm_lsn(NULL, NULL)";

# ── 4. Disable subscription to build up a backlog ───────────────────────

system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c',
    "SELECT spock.sub_disable('test_sub')";

# Wait for subscription to go down
for (1 .. 30) {
    my $status = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT status FROM spock.sub_show_status() WHERE subscription_name = 'test_sub'"`;
    chomp $status;
    $status =~ s/\s+//g;
    last if $status eq 'down';
    sleep 1;
}
note "subscription disabled, building WAL backlog ...";

# ── 5. Run pgbench while subscription is disabled ───────────────────────

note "running pgbench: scale=$PGBENCH_SCALE clients=$PGBENCH_CLIENTS "
   . "jobs=$PGBENCH_JOBS time=${PGBENCH_TIME}s";

system_or_bail "$pg_bin/pgbench",
    '-T', $PGBENCH_TIME,
    '-c', $PGBENCH_CLIENTS,
    '-j', $PGBENCH_JOBS,
    '-s', $PGBENCH_SCALE,
    '-h', $host, '-p', $provider_port, '-U', $db_user, $dbname;
pass('pgbench completed (backlog built)');

# Snapshot provider row counts now (pgbench is done, no more changes)
my %provider_counts;
for my $tbl (qw(pgbench_accounts pgbench_tellers pgbench_history)) {
    $provider_counts{$tbl} = scalar_query(1, "SELECT count(*) FROM $tbl");
}
note "provider pgbench_history rows: $provider_counts{pgbench_history}";

# ── 6. Reset stats, re-enable subscription, and time the catch-up ───────

system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c',
    "SELECT pg_stat_reset()";
sleep 2;

my $upd_before = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT COALESCE(n_tup_upd, 0) FROM pg_stat_user_tables WHERE schemaname = 'spock' AND relname = 'progress'"`;
chomp $upd_before;
$upd_before =~ s/\s+//g;
$upd_before = int($upd_before || 0);

# Re-enable subscription -- this is where catch-up begins
my $t_catchup = [gettimeofday()];

system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c',
    "SELECT spock.sub_enable('test_sub')";

# Wait for it to come back up
for (1 .. 60) {
    my $status = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT status FROM spock.sub_show_status() WHERE subscription_name = 'test_sub'"`;
    chomp $status;
    $status =~ s/\s+//g;
    last if $status eq 'replicating';
    sleep 1;
}

# Now wait for the slot to confirm it has caught up to the provider's
# current WAL position
system_or_bail "$pg_bin/psql", '-p', $provider_port, '-d', $dbname,
    '-c', "SET statement_timeout = '300s'; SELECT spock.wait_slot_confirm_lsn(NULL, NULL)";

my $catchup_secs = tv_interval($t_catchup);
note sprintf("catch-up time: %.2f seconds", $catchup_secs);
pass('subscriber caught up');

# ── 7. Verify row counts match ──────────────────────────────────────────

for my $tbl (qw(pgbench_accounts pgbench_tellers pgbench_history)) {
    my $cnt_sub = scalar_query(2, "SELECT count(*) FROM $tbl");
    is($cnt_sub, $provider_counts{$tbl},
       "$tbl row counts match ($provider_counts{$tbl} rows)");
}

# ── 8. Check progress table update frequency ────────────────────────────

sleep 2;

my $upd_after = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT COALESCE(n_tup_upd, 0) FROM pg_stat_user_tables WHERE schemaname = 'spock' AND relname = 'progress'"`;
chomp $upd_after;
$upd_after =~ s/\s+//g;
$upd_after = int($upd_after || 0);

my $progress_updates = $upd_after - $upd_before;

note "============================================================";
note sprintf("  catch-up time:           %.2f s", $catchup_secs);
note sprintf("  spock.progress updates:  %d", $progress_updates);
if ($catchup_secs > 0) {
    note sprintf("  updates per second:      %.1f", $progress_updates / $catchup_secs);
}
note sprintf("  transactions replayed:   %s", $provider_counts{pgbench_history});
note "============================================================";

# With deferred writes we expect roughly 1 update/sec, not 1 per xact.
my $max_expected = $catchup_secs * 3 + 10;
ok($progress_updates <= $max_expected,
    "progress table updates ($progress_updates) within expected range (<= $max_expected)");

# ── 9. Cleanup ──────────────────────────────────────────────────────────

system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c',
    "SELECT spock.sub_drop('test_sub')";

destroy_cluster('Destroy 2-node progress-period test cluster');
done_testing();
