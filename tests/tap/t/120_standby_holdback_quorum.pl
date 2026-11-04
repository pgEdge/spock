#!/usr/bin/perl
# The walsender hold-back on spock.pg_standby_slot_names with "any N of
# them" in spock.standby_slots_min_confirmed, on every PostgreSQL version:
# with two physical standbys of the provider and one of them down, the
# default waits for it, and min_confirmed = 1 keeps replicating.
#
# Copyright (c) 2022-2026, pgEdge, Inc.

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster get_test_config
                 system_or_bail psql_or_bail scalar_query poll_query_until
                 log_offset wait_for_log);

create_cluster(2, 'Create 2-node cluster');
cross_wire(2, ['n1', 'n2'], 'Bidirectional mesh between n1 and n2');

my $config       = get_test_config();
my $pg_bin       = $config->{pg_bin};
my $host         = $config->{host};
my $dbname       = $config->{db_name};
my $db_user      = $config->{db_user};
my $primary_port = $config->{node_ports}[0];

ok(poll_query_until(2,
       "SELECT status = 'replicating' FROM spock.sub_show_status() " .
       "WHERE subscription_name = 'sub_n2_n1'", 't', 90),
   'n2 replicates from n1');

psql_or_bail(1, "CREATE TABLE holdback_test (id int PRIMARY KEY)");
ok(poll_query_until(2, "SELECT count(*) = 1 FROM pg_tables WHERE tablename = 'holdback_test'",
                    't', 60),
   'holdback_test reached n2');

# =============================================================================
# Two physical standbys of n1, each through its own slot
# =============================================================================
my @standby;
for my $i (1, 2) {
    my $slot    = "sb$i";
    my $port    = $primary_port + 20 + $i;
    my $datadir = "/tmp/tmp_spock_holdback_sb$i";
    my $logdir  = "$datadir/pg_log";

    psql_or_bail(1, "SELECT pg_create_physical_replication_slot('$slot')");
    system("$pg_bin/pg_ctl stop -D $datadir -m immediate >/dev/null 2>&1");
    system("rm -rf $datadir 2>/dev/null");
    system_or_bail("$pg_bin/pg_basebackup", '-D', $datadir,
                   '-h', $host, '-p', $primary_port, '-U', $db_user,
                   '-X', 'stream', '-R', '-c', 'fast');
    system_or_bail('mkdir', '-p', $logdir);
    open(my $conf, '>>', "$datadir/postgresql.conf")
        or die "cannot open $datadir/postgresql.conf: $!";
    print $conf "\n# ---- standby overrides ----\n";
    print $conf "port = $port\n";
    print $conf "hot_standby = on\n";
    print $conf "primary_slot_name = '$slot'\n";
    print $conf "log_directory = '$logdir'\n";
    print $conf "log_filename = 'standby.log'\n";
    close($conf);
    open(my $aconf, '>>', "$datadir/postgresql.auto.conf")
        or die "cannot open $datadir/postgresql.auto.conf: $!";
    print $aconf "primary_conninfo = 'host=$host port=$primary_port user=$db_user'\n";
    close($aconf);
    system_or_bail("$pg_bin/pg_ctl", 'start', '-D', $datadir,
                   '-l', "$datadir/startup.log", '-w');
    push @standby, { slot => $slot, datadir => $datadir };
}

ok(poll_query_until(1, "SELECT count(*) = 2 FROM pg_replication_slots " .
                       "WHERE slot_name IN ('sb1', 'sb2') AND active", 't', 60),
   'both standbys stream from n1');

my $next = 1;
sub insert_row {
    my $id = $next++;
    psql_or_bail(1, "INSERT INTO holdback_test VALUES ($id)");
    return $id;
}
sub arrived {
    my ($id, $timeout) = @_;
    return poll_query_until(2, "SELECT count(*) = 1 FROM holdback_test WHERE id = $id",
                            't', $timeout);
}

# =============================================================================
# Hold-back on, both standbys up: replication goes on
# =============================================================================
psql_or_bail(1, "ALTER SYSTEM SET spock.pg_standby_slot_names = 'sb1,sb2'");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(arrived(insert_row(), 60), 'a row replicates with both standbys confirming');

# =============================================================================
# One standby down: the default waits for it
# =============================================================================
system_or_bail("$pg_bin/pg_ctl", 'stop', '-D', $standby[1]{datadir}, '-m', 'fast');
ok(poll_query_until(1, "SELECT NOT active FROM pg_replication_slots WHERE slot_name = 'sb2'",
                    't', 30),
   'sb2 is down');
my $held = insert_row();
ok(!arrived($held, 15), 'with all standbys required, the row is held back while sb2 is down');

# =============================================================================
# Any one of them is enough
# =============================================================================
psql_or_bail(1, "ALTER SYSTEM SET spock.standby_slots_min_confirmed = 1");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(arrived($held, 90), 'with one standby required, the held row goes through');
ok(arrived(insert_row(), 60), 'and replication keeps going while sb2 is down');

# =============================================================================
# The standby comes back and all are required again
# =============================================================================
system_or_bail("$pg_bin/pg_ctl", 'start', '-D', $standby[1]{datadir},
               '-l', "$standby[1]{datadir}/startup.log", '-w');
psql_or_bail(1, "ALTER SYSTEM RESET spock.standby_slots_min_confirmed");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(arrived(insert_row(), 90), 'a row replicates once sb2 has caught up');

# =============================================================================
# A named slot that does not exist is reported in a warning
# =============================================================================
# Take the provider log offset before the reload, so a warning from an
# earlier run in the reused log file cannot satisfy the check.
my $log_off = log_offset(1);
psql_or_bail(1, "ALTER SYSTEM SET spock.pg_standby_slot_names = 'sb1,sb2,no_such_slot'");
psql_or_bail(1, "ALTER SYSTEM SET spock.standby_slots_min_confirmed = 2");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(arrived(insert_row(), 90), 'two of three named slots confirm, the third missing');
ok(wait_for_log(1,
        qr/replication slot "no_such_slot" named in spock\.pg_standby_slot_names does not exist/,
        $log_off, 30),
   'the missing slot is named in a warning');

# =============================================================================
# Cleanup
# =============================================================================
for my $sb (@standby) {
    system("$pg_bin/pg_ctl stop -D $sb->{datadir} -m immediate >/dev/null 2>&1");
    system("rm -rf $sb->{datadir} 2>/dev/null");
}
destroy_cluster('Destroy test cluster');
done_testing();
