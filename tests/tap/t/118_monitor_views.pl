#!/usr/bin/perl
# The monitoring views across things the regression suite cannot do: a
# provider going down and coming back, a node restarted with a small event
# ring, and a role that is not a superuser.
#
# Copyright (c) 2022-2026, pgEdge, Inc.

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster scalar_query
                 get_test_config psql_or_bail system_or_bail poll_query_until
                 wait_for_pg_ready);

create_cluster(2, 'Create 2-node cluster');
cross_wire(2, ['n1', 'n2'], 'Bidirectional mesh between n1 and n2');

my $config      = get_test_config();
my $host        = $config->{host};
my $node_ports  = $config->{node_ports};
my $node_dirs   = $config->{node_datadirs};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};

# cross_wire() names a subscription after the node it lives on, then its
# provider: sub_n2_n1 is n2's subscription to n1.
my $stats  = "spock.subscription_stats WHERE subscription_name = 'sub_n2_n1'";
my $status = "spock.subscription_status WHERE subscription_name = 'sub_n2_n1'";

sub is_true {
    my ($node, $query, $name) = @_;
    is(scalar_query($node, $query), 't', $name);
}

sub replicating {
    my ($node, $sub) = @_;
    return poll_query_until($node,
        "SELECT status = 'replicating' FROM spock.subscription_status " .
        "WHERE subscription_name = '$sub'", 't', 90);
}

sub reset_monitor {
    my ($node) = @_;
    psql_or_bail($node, "SELECT spock.reset_subscription_stats()");
    psql_or_bail($node, "SELECT spock.reset_events()");
}

# A resync can only start once the previous one has finished.
sub resync_when_ready {
    my ($node, $table) = @_;
    my $port = $node_ports->[$node - 1];
    my $rc;

    for (1 .. 30) {
        `"$pg_bin/psql" -X -p $port -d $dbname -c "SELECT spock.sub_resync_table('sub_n2_n1', '$table', true)" 2>&1`;
        $rc = $? >> 8;
        last if $rc == 0;
        sleep(1);
    }
    return $rc;
}

ok(replicating(2, 'sub_n2_n1'), 'n2 replicates from n1');
ok(replicating(1, 'sub_n1_n2'), 'n1 replicates from n2');

# =============================================================================
# The DSN carries a password; the views never show it
# =============================================================================
is_true(2, "SELECT provider_dsn LIKE '%password=********%' " .
           "AND provider_dsn NOT LIKE '%password=$db_password%' FROM $status",
        'subscription_status masks the provider password');
is_true(2, "SELECT dsn LIKE '%password=********%' " .
           "AND dsn NOT LIKE '%password=$db_password%' " .
           "FROM spock.peer_status WHERE node_name = 'n1'",
        'peer_status masks the password too');

# =============================================================================
# The provider goes down and comes back
# =============================================================================
reset_monitor(2);
system_or_bail("$pg_bin/pg_ctl", '-D', $node_dirs->[0], '-m', 'fast', 'stop');

ok(poll_query_until(2,
       "SELECT provider_disconnects >= 1 AND worker_failures >= 1 FROM $stats",
       't', 60),
   'the disconnect and the failed reconnect are counted');
is_true(2, "SELECT count(*) >= 1 FROM spock.events " .
           "WHERE event_type = 'provider_disconnected'",
        'provider_disconnected is recorded');
# The first failure is the lost stream, whose message has no DSN.  The
# password can only leak from the reconnect attempt, so wait for that one.
ok(poll_query_until(2,
       "SELECT last_error_message LIKE 'could not connect to the postgresql server%' " .
       "FROM $stats", 't', 60),
   'the failed reconnect is the last error');
is_true(2, "SELECT last_error_message LIKE '%password=X%' " .
           "AND last_error_message NOT LIKE '%password=$db_password%' FROM $stats",
        'the connection error shows the password masked');
is_true(2, "SELECT status <> 'replicating' FROM $status",
        'the subscription no longer reads as replicating');
is(scalar_query(2, "SELECT subscriptions_replicating FROM spock.node_status"),
   '0', 'node_status counts no replicating subscription');
is(scalar_query(2, "SELECT sync_worker_starts FROM $stats"),
   '0', 'no sync worker was involved');

system_or_bail("$pg_bin/pg_ctl", '-D', $node_dirs->[0], '-w', 'start');
ok(wait_for_pg_ready($host, $node_ports->[0]), 'n1 accepts connections again');
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates again once n1 is back');
is_true(2, "SELECT provider_connects >= 1 AND worker_starts >= 1 FROM $stats",
        'the reconnect and the worker restart are counted');
is_true(2, "SELECT count(*) >= 1 FROM spock.events " .
           "WHERE event_type = 'provider_connected'",
        'provider_connected is recorded');

# =============================================================================
# A resync is a sync worker, not an apply worker restart
# =============================================================================
psql_or_bail(1, "CREATE TABLE mon_tbl (id int PRIMARY KEY, val text)");
ok(poll_query_until(2, "SELECT count(*) = 1 FROM pg_tables WHERE tablename = 'mon_tbl'",
                    't', 60),
   'mon_tbl arrived on n2');
psql_or_bail(1, "INSERT INTO mon_tbl SELECT i, 'row ' || i FROM generate_series(1, 20) i");
ok(poll_query_until(2, "SELECT count(*) = 20 FROM mon_tbl", 't', 60),
   'its rows arrived on n2');

reset_monitor(2);
is(resync_when_ready(2, 'mon_tbl'), 0, 'resync of mon_tbl started');
psql_or_bail(2, "SELECT spock.table_wait_for_sync('sub_n2_n1', 'mon_tbl')");
ok(poll_query_until(2, "SELECT count(*) >= 1 FROM spock.events " .
                       "WHERE event_type = 'sync_finished'", 't', 60),
   'sync_finished is recorded');
is(scalar_query(2, "SELECT sync_worker_starts >= 1 FROM $stats"),
   't', 'the sync worker start is counted');
is(scalar_query(2, "SELECT worker_starts FROM $stats"),
   '0', 'the apply worker did not restart');
is(scalar_query(2, "SELECT tables_synced FROM $stats"), '1', 'one table synced');

# =============================================================================
# A copy that fails is recorded for the table, with the reason
# =============================================================================
reset_monitor(2);
psql_or_bail(2, "SET spock.enable_ddl_replication = off; " .
                "ALTER TABLE mon_tbl ADD CONSTRAINT mon_tbl_no_copy CHECK (id < 0) NOT VALID");
is(resync_when_ready(2, 'mon_tbl'), 0, 'resync against the constraint started');
ok(poll_query_until(2, "SELECT count(*) >= 1 FROM spock.events " .
                       "WHERE event_type = 'sync_failed' " .
                       "AND detail LIKE 'table public.mon_tbl: %violates check constraint%'",
                    't', 60),
   'sync_failed names the table and the constraint');
is_true(2, "SELECT sync_worker_failures >= 1 AND sync_errors >= 1 FROM $stats",
        'the failure is counted against the sync worker');
is(scalar_query(2, "SELECT worker_failures FROM $stats"),
   '0', 'and not against the apply worker');
# The event comes from the sync worker that died; the next one marks the
# table failed.
ok(poll_query_until(2, "SELECT sync_status = 'failed' FROM spock.table_sync_status " .
                       "WHERE table_name = 'mon_tbl'", 't', 60),
   'the table is marked failed');

psql_or_bail(2, "SET spock.enable_ddl_replication = off; " .
                "ALTER TABLE mon_tbl DROP CONSTRAINT mon_tbl_no_copy");
is(resync_when_ready(2, 'mon_tbl'), 0, 'resync without the constraint started');
psql_or_bail(2, "SELECT spock.table_wait_for_sync('sub_n2_n1', 'mon_tbl')");
is(scalar_query(2, "SELECT count(*) FROM mon_tbl"), '20', 'the rows are back');

# =============================================================================
# The event ring keeps the newest events once it is full
# =============================================================================
psql_or_bail(2, "ALTER SYSTEM SET spock.event_history_size = 32");
system_or_bail("$pg_bin/pg_ctl", '-D', $node_dirs->[1], '-m', 'fast', '-w', 'restart');
ok(wait_for_pg_ready($host, $node_ports->[1]), 'n2 accepts connections after its restart');
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates after its restart');
is(scalar_query(2, "SELECT events_capacity FROM spock.get_monitor_summary()"),
   '32', 'the ring holds 32 events');

for (1 .. 25) {
    psql_or_bail(2, "SELECT spock.pause_apply_workers()");
    psql_or_bail(2, "SELECT spock.resume_apply_workers()");
}
is(scalar_query(2, "SELECT events_retained FROM spock.get_monitor_summary()"),
   '32', 'the ring is full');
is_true(2, "SELECT events_recorded >= 50 FROM spock.get_monitor_summary()",
        'everything recorded is still counted');
is_true(2, "SELECT min(event_id) > 1 AND max(event_id) - min(event_id) + 1 = 32 " .
           "FROM spock.events",
        'the oldest events were dropped and the rest are contiguous');
is_true(2, "SELECT count(*) > 0 FROM spock.spock_info(5) AS line WHERE line LIKE '== % =='",
        'spock_info() still produces its sections');

# =============================================================================
# A role without pg_monitor reads the WAL size
# =============================================================================
psql_or_bail(2, "CREATE ROLE mon_plain LOGIN");
psql_or_bail(2, "GRANT USAGE ON SCHEMA spock TO mon_plain");
my $port2 = $node_ports->[1];
my $wal = `"$pg_bin/psql" -X -p $port2 -d $dbname -U mon_plain -At -c "SELECT spock.wal_size_bytes() > 0" 2>&1`;
chomp $wal;
is($wal, 't', 'wal_size_bytes() works without pg_monitor');

# =============================================================================
# A role whose only grant is pg_monitor reads the views
# =============================================================================
psql_or_bail(2, "CREATE ROLE mon_role LOGIN");
psql_or_bail(2, "GRANT pg_monitor TO mon_role");
sub as_monitor {
    my ($query) = @_;
    my $out = `"$pg_bin/psql" -X -p $port2 -d $dbname -U mon_role -At -c "$query" 2>&1`;
    chomp $out;
    return $out;
}
is(as_monitor("SELECT subscriptions FROM spock.node_status"), '1',
   'pg_monitor reads node_status');
# pg_monitor includes pg_read_all_settings, so the data directory is shown.
is(as_monitor("SELECT hostname IS NOT NULL AND data_directory IS NOT NULL FROM spock.system_status"), 't',
   'pg_monitor reads system_status, with the data directory');
is(as_monitor("SELECT status FROM spock.subscription_status WHERE subscription_name = 'sub_n2_n1'"),
   'replicating', 'pg_monitor reads subscription_status');
# The sections on spock.tables, lag_tracker, exception_log and resolutions
# are not part of the grant and show as one error line each; every function
# the report calls is.
is(as_monitor("SELECT count(*) FILTER (WHERE line LIKE '== % ==') > 10 " .
              "AND count(*) FILTER (WHERE line LIKE '(error: permission denied for function%') = 0 " .
              "FROM spock.spock_info(5) AS line"), 't',
   'spock_info() runs every function it calls for pg_monitor');
like(as_monitor("SELECT spock.reset_events()"), qr/permission denied/,
     'pg_monitor cannot reset the events');

destroy_cluster('Destroy test cluster');
done_testing();
