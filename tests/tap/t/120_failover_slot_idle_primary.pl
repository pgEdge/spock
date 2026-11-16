use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config system_or_bail
    psql_or_bail scalar_query
    log_offset log_since
);
use Time::HiRes qw(time);

# =============================================================================
# Test: 120_failover_slot_idle_primary.pl
#
# A new failover slot copy on a standby is a temporary slot until it can serve
# the primary's slot, and is dropped if the standby is promoted first.  A copy
# that starts ahead of the primary's slot has to wait for that slot to pass
# it, and the slot moves only to a running-xacts record, which an idle
# primary does not write.  Up to 5.0.14 every new copy started at the
# standby's own position, so on an idle primary it stayed temporary, and an
# unplanned failover left the new primary without the slot.
#
# The worker now starts the copy at the primary slot's restart_lsn when the
# standby still keeps that WAL, so the copy need not wait for the primary.
#
# Topology:
#   n1 (provider/primary)  ──logical──>  n2 (subscriber)
#   n1                     ──physical──> standby (stream replica of n1)
#
# No transaction runs on n1 after the standby starts.  In both scenarios the
# copy becomes persistent anyway, survives an unplanned failover, and n2
# replicates from the promoted standby.
#
# Scenario "idle":
#   n2 stays connected throughout.
#
# Scenario "lagging":
#   n2 is disconnected while the standby is built, so the primary's slot is
#   older than the standby's redo pointer and the copy has to start ahead of
#   it.  The copy is temporary until n2 reconnects and confirms, with still
#   no transaction on n1.
# =============================================================================

my $PERSIST_SECS = 60;

sub qport {
    my ($pg_bin, $host, $port, $dbname, $user, $sql) = @_;
    my $out = `PGCONNECT_TIMEOUT=10 $pg_bin/psql -X -h $host -p $port -d $dbname -U $user -t -c "$sql" 2>/dev/null`;
    $out //= '';
    $out =~ s/^\s+|\s+$//g;
    return $out;
}

sub wait_until {
    my ($timeout, $poll, $cond) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 if $cond->();
        sleep($poll);
    }
    return 0;
}

# The standby's log is the only place the worker says why a copy is pending.
sub save_standby_log {
    my ($datadir, $log_dir, $tag) = @_;
    foreach my $src ("$datadir/startup.log", glob("$datadir/pg_log/*")) {
        next unless -f $src;
        (my $base = $src) =~ s{.*/}{};
        system('cp', $src, "$log_dir/120_failover_slot_idle_primary_${tag}_$base");
    }
}

sub run_scenario {
    my ($mode) = @_;
    diag("=== 120 scenario: $mode ===");

    create_cluster(2, "[$mode] Create 2-node Spock cluster");

    my $config       = get_test_config();
    my $host         = $config->{host};
    my $dbname       = $config->{db_name};
    my $db_user      = $config->{db_user};
    my $db_password  = $config->{db_password};
    my $pg_bin       = $config->{pg_bin};
    my $primary_port = $config->{node_ports}->[0];
    my $primary_dir  = $config->{node_datadirs}->[0];

    my $standby_port    = $primary_port + 10;
    my $standby_datadir = '/tmp/tmp_spock_idle_primary_standby';
    my $standby_logdir  = "$standby_datadir/pg_log";

    my $sb = sub { qport($pg_bin, $host, $standby_port, $dbname, $db_user, $_[0]) };

    # ----------------------------------------------------------------------
    # n2 subscribes to n1; one replicated table with one row.
    # ----------------------------------------------------------------------
    psql_or_bail(1, "CREATE TABLE idle_test (id int PRIMARY KEY, val text)");
    psql_or_bail(2, "SELECT spock.sub_create(
        'sub_n2_n1',
        'host=$host dbname=$dbname port=$primary_port user=$db_user password=$db_password',
        ARRAY['default','default_insert_only','ddl_sql'],
        true, true
    )");

    my $slot_name = '';
    ok(wait_until(60, 1, sub {
            $slot_name = scalar_query(1,
                "SELECT slot_name FROM pg_replication_slots
                 WHERE slot_type = 'logical' AND active LIMIT 1");
            return length($slot_name) > 0;
        }),
        "[$mode] logical slot '$slot_name' is active on n1");

    psql_or_bail(1, "INSERT INTO idle_test VALUES (1, 'before_standby')");
    ok(wait_until(60, 1, sub {
            scalar_query(2, "SELECT count(*) FROM idle_test WHERE id = 1") eq '1';
        }),
        "[$mode] n2 replicates from n1 before the standby exists");

    # ----------------------------------------------------------------------
    # Physical standby of n1, with the worker passing every second.
    # ----------------------------------------------------------------------
    # In the "lagging" scenario n2 is away while the standby is built, so the
    # primary's slot stays behind the backup's checkpoint, which is where the
    # standby's redo pointer starts.  The copy then cannot start at the
    # primary slot's position and has to wait for it.
    if ($mode eq 'lagging')
    {
        psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1')");
        ok(wait_until(30, 1, sub {
                scalar_query(1, "SELECT active FROM pg_replication_slots
                                 WHERE slot_name = '$slot_name'") eq 'f';
            }),
            "[$mode] n2 disconnected from n1");
    }

    psql_or_bail(1,
        "SELECT pg_create_physical_replication_slot('standby_physical_slot')");

    system("rm -rf $standby_datadir 2>/dev/null");
    system_or_bail("$pg_bin/pg_basebackup",
        '-D', $standby_datadir,
        '-h', $host, '-p', $primary_port, '-U', $db_user,
        '-X', 'stream', '-R', '-c', 'fast');
    system_or_bail('mkdir', '-p', $standby_logdir);
    {
        open(my $conf, '>>', "$standby_datadir/postgresql.conf")
            or die "Cannot open standby postgresql.conf: $!";
        print $conf "\n# ---- standby overrides ----\n";
        print $conf "port                     = $standby_port\n";
        print $conf "hot_standby              = on\n";
        print $conf "hot_standby_feedback     = on\n";
        print $conf "primary_slot_name        = 'standby_physical_slot'\n";
        print $conf "log_directory            = '$standby_logdir'\n";
        print $conf "log_filename             = 'standby.log'\n";
        print $conf "spock.failover_slots_naptime = 1000\n";
        print $conf "spock.failover_slots_feedback_naptime = 1000\n";
        print $conf "log_min_messages         = debug1\n";
        close($conf);

        open(my $aconf, '>>', "$standby_datadir/postgresql.auto.conf")
            or die "Cannot open standby postgresql.auto.conf: $!";
        print $aconf "primary_conninfo = 'host=$host port=$primary_port "
                   . "user=$db_user dbname=$dbname'\n";
        close($aconf);
    }
    system_or_bail("$pg_bin/pg_ctl", 'start',
        '-D', $standby_datadir, '-l', "$standby_datadir/startup.log", '-w');

    ok(wait_until(30, 1, sub {
            scalar_query(1, "SELECT count(*) FROM pg_stat_replication
                             WHERE application_name = 'walreceiver'
                               AND state = 'streaming'") eq '1';
        }),
        "[$mode] standby is streaming from n1");

    # ----------------------------------------------------------------------
    # Leave the primary alone.  The worker creates the copy on its first
    # passes and has to make it persistent without help from a transaction.
    # ----------------------------------------------------------------------
    ok(wait_until(30, 1, sub {
            $sb->("SELECT count(*) FROM pg_replication_slots
                   WHERE slot_name = '$slot_name'") eq '1';
        }),
        "[$mode] worker created a copy of '$slot_name' on the standby");

    if ($mode eq 'lagging')
    {
        is($sb->("SELECT temporary FROM pg_replication_slots
                  WHERE slot_name = '$slot_name'"), 't',
            "[$mode] copy is temporary while the primary's slot is behind it");
        psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");
    }

    my $t0 = time();
    my $persisted = wait_until($PERSIST_SECS, 1, sub {
        $sb->("SELECT temporary FROM pg_replication_slots
               WHERE slot_name = '$slot_name'") eq 'f';
    });
    ok($persisted,
        "[$mode] copy became persistent with no transaction on the primary");
    diag(sprintf("copy persisted after %.0fs", time() - $t0)) if $persisted;

    diag(`grep -h 'reserved WAL at\\|waiting for remote slot' $standby_logdir/standby.log | head -3`);

    save_standby_log($standby_datadir, $config->{log_dir}, "${mode}_before_promote");

    # ----------------------------------------------------------------------
    # Unplanned failover: n1 goes away, the standby is promoted, n2 is
    # pointed at it.
    # ----------------------------------------------------------------------
    system("$pg_bin/pg_ctl stop -D $primary_dir -m immediate >> /dev/null 2>&1");
    system("$pg_bin/pg_ctl promote -D $standby_datadir >> /dev/null 2>&1");
    ok(wait_until(30, 1, sub { $sb->("SELECT pg_is_in_recovery()") eq 'f' }),
        "[$mode] standby promoted");

    # Give the worker a moment to notice the promotion and drop a pending copy.
    sleep(5);
    my $slot_after = $sb->("SELECT count(*) FROM pg_replication_slots
                            WHERE slot_name = '$slot_name'");

    my $n2_log_from = log_offset(2);
    psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1')");
    sleep(3);
    psql_or_bail(2,
        "SELECT spock.node_add_interface(
            'n1', 'n1_promoted',
            'host=$host dbname=$dbname port=$standby_port user=$db_user password=$db_password'
        )");
    psql_or_bail(2,
        "SELECT spock.sub_alter_interface('sub_n2_n1', 'n1_promoted')");
    psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");

    $sb->("INSERT INTO idle_test VALUES (3, 'after_failover')");

    is($slot_after, '1',
        "[$mode] promoted node kept the '$slot_name' slot");
    ok(wait_until(60, 1, sub {
            scalar_query(2, "SELECT count(*) FROM idle_test WHERE id = 3") eq '1';
        }),
        "[$mode] n2 receives the row written after failover");
    is(scalar_query(2, "SELECT count(*) FROM idle_test"),
        '2',
        "[$mode] n2 has every row written on n1 and on the promoted standby");
    unlike(log_since(2, $n2_log_from),
        qr/replication slot "\Q$slot_name\E" does not exist/,
        "[$mode] n2's apply worker never found the slot missing");

    # ----------------------------------------------------------------------
    # Cleanup
    # ----------------------------------------------------------------------
    system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >> /dev/null 2>&1");
    save_standby_log($standby_datadir, $config->{log_dir}, $mode);
    system("rm -rf $standby_datadir 2>/dev/null");

    # destroy_cluster needs n1 up again.
    system_or_bail("$pg_bin/pg_ctl", 'start',
        '-D', $primary_dir, '-l', "$primary_dir/restart.log", '-w');
    destroy_cluster("[$mode] Destroy test cluster");
}

run_scenario('idle');
run_scenario('lagging');

done_testing();
