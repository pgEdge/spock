#!/usr/bin/perl
# The event history and the counters survive a crash and a clean restart
# through the on-disk copy written by the supervisor, and are gone when the
# copy is turned off.
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

my $config     = get_test_config();
my $host       = $config->{host};
my $node_ports = $config->{node_ports};
my $node_dirs  = $config->{node_datadirs};
my $pg_bin     = $config->{pg_bin};

my $stats = "spock.subscription_stats WHERE subscription_name = 'sub_n2_n1'";
my $sub_rows = "spock.channel_table_stats WHERE table_name = 'public.persist_dml' AND subid <> 0";

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

sub crash_and_start {
    my ($node) = @_;
    system_or_bail("$pg_bin/pg_ctl", '-D', $node_dirs->[$node - 1], '-m', 'immediate', 'stop');
    system_or_bail("$pg_bin/pg_ctl", '-D', $node_dirs->[$node - 1], '-w', 'start');
    ok(wait_for_pg_ready($host, $node_ports->[$node - 1]), "n$node accepts connections again");
}

sub clean_restart {
    my ($node) = @_;
    system_or_bail("$pg_bin/pg_ctl", '-D', $node_dirs->[$node - 1], '-m', 'fast', '-w', 'restart');
    ok(wait_for_pg_ready($host, $node_ports->[$node - 1]), "n$node accepts connections after its restart");
}

# The newest node_started event of this run.  scalar_query() strips the
# blanks, so the patterns below have none.
sub start_detail {
    my ($node) = @_;
    return scalar_query($node,
        "SELECT detail FROM spock.events WHERE event_type = 'node_started' " .
        "ORDER BY event_id DESC LIMIT 1");
}

ok(replicating(2, 'sub_n2_n1'), 'n2 replicates from n1');
ok(replicating(1, 'sub_n1_n2'), 'n1 replicates from n2');

# =============================================================================
# Something to remember: events and counters, written to disk
# =============================================================================
is_true(2, "SELECT spock.monitor_flush()", 'monitor_flush() writes the files');
like(start_detail(2), qr/noeventhistoryorcountersondisk/,
     'the first start found nothing on disk');

psql_or_bail(2, "SELECT spock.reset_events()");
# DDL replication is on in this cluster, so the table joins the default
# replication set by itself.
psql_or_bail(1, "CREATE TABLE public.persist_dml (id integer PRIMARY KEY, data text)");
ok(poll_query_until(2, "SELECT count(*) = 1 FROM pg_class WHERE relname = 'persist_dml'", 't', 60),
   'the table reached n2');
psql_or_bail(1, "INSERT INTO public.persist_dml SELECT g, 'row ' || g FROM generate_series(1, 20) AS g");
ok(poll_query_until(2, "SELECT count(*) = 20 FROM public.persist_dml", 't', 60),
   'the rows reached n2');

# Replicating a table records nothing; a subscription bounce records the
# disable, the enable, the worker stop and start and the reconnect.
psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1')");
psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates again after the bounce');
ok(poll_query_until(2, "SELECT count(*) >= 5 FROM spock.events", 't', 30),
   'the bounce was recorded');

my $events_before = scalar_query(2, "SELECT count(*) FROM spock.events");
my $min_id_before = scalar_query(2, "SELECT min(event_id) FROM spock.events");
my $max_id_before = scalar_query(2, "SELECT max(event_id) FROM spock.events");
my $starts_before = scalar_query(2, "SELECT worker_starts FROM $stats");
my $xacts_before  = scalar_query(2, "SELECT xacts_applied FROM $stats");
my $ins_before    = scalar_query(2, "SELECT n_tup_ins FROM $sub_rows");
ok($events_before > 0, "n2 has $events_before events to keep");
ok($ins_before >= 20, "n2 counted $ins_before inserted rows");

is_true(2, "SELECT spock.monitor_flush()", 'the files are written before the crash');
is_true(2, "SELECT last_flush_time IS NOT NULL FROM spock.node_status",
        'node_status shows the time of the write');

# =============================================================================
# A crash keeps the history and the counters
# =============================================================================
crash_and_start(2);
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates again after its crash');

like(start_detail(2), qr/didnotshutdowncleanly/,
     'node_started says the previous run crashed');
is(scalar_query(2, "SELECT count(*) FROM spock.events WHERE event_id <= $max_id_before"),
   $events_before, 'every event before the crash is back');
is(scalar_query(2, "SELECT min(event_id) FROM spock.events"), $min_id_before,
   'the oldest event is still the oldest');
is_true(2, "SELECT count(*) > 0 FROM spock.events WHERE event_id > $max_id_before " .
           "AND event_type = 'worker_started'",
        'events after the crash continue the id sequence');
is_true(2, "SELECT worker_starts > $starts_before FROM $stats",
        'worker_starts continues from its value before the crash');
is_true(2, "SELECT xacts_applied >= $xacts_before FROM $stats",
        'xacts_applied was kept');
is_true(2, "SELECT n_tup_ins >= $ins_before FROM $sub_rows",
        'the channel counters were kept');
is_true(2, "SELECT NOT prior_shutdown_clean AND events_restored >= $events_before " .
           "FROM spock.node_status",
        'node_status reports the crash and the restored events');

# =============================================================================
# A clean restart says so, and the log reaches further back than the ring
# =============================================================================
psql_or_bail(2, "ALTER SYSTEM SET spock.event_history_size = 16");
clean_restart(2);
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates again after its restart');

like(start_detail(2), qr/shutdowncleanlyat/,
     'node_started says the previous run shut down cleanly');
is_true(2, "SELECT prior_shutdown_clean FROM spock.node_status",
        'node_status reports the clean shutdown');
is_true(2, "SELECT count(*) <= 16 FROM spock.events", 'the ring holds 16 events');
is_true(2, "SELECT count(*) >= $events_before FROM spock.event_log(0, 100000) " .
           "WHERE event_id <= $max_id_before",
        'event_log() still has every event from before the crash');
is(scalar_query(2, "SELECT min(event_id) FROM spock.event_log(0, 100000)"), $min_id_before,
   'event_log() starts at the oldest event');
is_true(2, "SELECT count(*) = 3 FROM spock.event_log($max_id_before, 3)",
        'event_log() honours since_id and max_rows');
is_true(2, "SELECT worker_starts > $starts_before FROM $stats",
        'the counters survived the clean restart too');

# =============================================================================
# A reset holds across a crash
# =============================================================================
my $max_id_reset = scalar_query(2, "SELECT max(event_id) FROM spock.events");
psql_or_bail(2, "SELECT spock.reset_events()");
is_true(2, "SELECT spock.monitor_flush()", 'the reset is written');
crash_and_start(2);
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates again after its second crash');
is(scalar_query(2, "SELECT count(*) FROM spock.events WHERE event_id <= $max_id_reset"),
   '0', 'the events reset before the crash did not come back');
is(scalar_query(2, "SELECT count(*) FROM spock.event_log(0, 100000) WHERE event_id <= $max_id_reset"),
   '0', 'event_log() leaves out the events before the reset');

# =============================================================================
# With the copy turned off nothing is written or read back
# =============================================================================
psql_or_bail(2, "ALTER SYSTEM SET spock.monitor_flush_interval = 0");
clean_restart(2);
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates with the copy turned off');
is(scalar_query(2, "SELECT spock.monitor_flush()"), 'f',
   'monitor_flush() reports the copy is off');
is_true(2, "SELECT events_restored IS NULL AND prior_shutdown_clean IS NULL " .
           "AND last_flush_time IS NULL FROM spock.node_status",
        'nothing was restored');
is(scalar_query(2, "SELECT count(*) FROM spock.events WHERE event_type = 'node_started'"),
   '0', 'no node_started event without the copy');
psql_or_bail(2, "ALTER SYSTEM RESET spock.monitor_flush_interval");
psql_or_bail(2, "ALTER SYSTEM RESET spock.event_history_size");

# =============================================================================
# The log rotates at spock.event_log_max_size and keeps the rotated half
# =============================================================================
clean_restart(2);    # the resets above take effect: the copy is on again
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates with the copy back on');
psql_or_bail(2, "ALTER SYSTEM SET spock.event_log_max_size = '1MB'");
psql_or_bail(2, "SELECT pg_reload_conf()");

my $log_min = scalar_query(2, "SELECT min(event_id) FROM spock.event_log(0, 100000)");
# A record is a little under 600 bytes: 3000 events pass 1MB once and stay
# under 2MB, so events.log is renamed to events.log.old exactly once.  Each
# round fits the ring and is written out before the next.
for my $round (1 .. 5)
{
    psql_or_bail(2, "DO \$\$ BEGIN FOR i IN 1..300 LOOP " .
                    "PERFORM spock.repair_mode(true); " .
                    "PERFORM spock.repair_mode(false); " .
                    "END LOOP; END \$\$");
    is_true(2, "SELECT spock.monitor_flush()", "round $round of events is written");
}
ok(-f "$node_dirs->[1]/spock/events.log.old", 'events.log was rotated');
is_true(2, "SELECT count(*) >= 3000 FROM spock.event_log(0, 100000)",
        'event_log() reads the rotated log and the current one');
is(scalar_query(2, "SELECT min(event_id) FROM spock.event_log(0, 100000)"), $log_min,
   'the oldest event survived the rotation');

# Both halves are read back after a crash
crash_and_start(2);
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates after the crash with a rotated log');
is_true(2, "SELECT count(*) >= 3000 FROM spock.event_log(0, 100000)",
        'both halves of the log are back');
is(scalar_query(2, "SELECT min(event_id) FROM spock.event_log(0, 100000)"), $log_min,
   'the oldest event is still the oldest after the crash');
psql_or_bail(2, "ALTER SYSTEM RESET spock.event_log_max_size");
psql_or_bail(2, "SELECT pg_reload_conf()");

# =============================================================================
# A tail torn by a crash is cut off; what follows it is written readably
# =============================================================================
my $events_whole = scalar_query(2, "SELECT count(*) FROM spock.event_log(0, 100000)");
my $max_whole    = scalar_query(2, "SELECT max(event_id) FROM spock.event_log(0, 100000)");
system_or_bail("$pg_bin/pg_ctl", '-D', $node_dirs->[1], '-m', 'fast', '-w', 'stop');
open(my $log, '>>', "$node_dirs->[1]/spock/events.log")
    or BAIL_OUT("cannot open events.log: $!");
binmode($log);
print $log 'torn' x 300;    # two garbage records and a partial one
close($log);
system_or_bail("$pg_bin/pg_ctl", '-D', $node_dirs->[1], '-w', 'start');
ok(wait_for_pg_ready($host, $node_ports->[1]), 'n2 starts with a torn event log');
ok(replicating(2, 'sub_n2_n1'), 'n2 replicates with a torn event log');
is_true(2, "SELECT count(*) >= $events_whole FROM spock.event_log(0, 100000) " .
           "WHERE event_id <= $max_whole",
        'the records before the tear were read');
is_true(2, "SELECT spock.monitor_flush()", 'the log is written to again');
is_true(2, "SELECT max(event_id) > $max_whole FROM spock.event_log(0, 100000)",
        'events recorded after the tear are readable');

destroy_cluster('Destroy test cluster');
done_testing();
