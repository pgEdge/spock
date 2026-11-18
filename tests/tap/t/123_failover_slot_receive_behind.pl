use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config system_or_bail
    psql_or_bail scalar_query
);
use Time::HiRes qw(time usleep);

# =============================================================================
# Test: 123_failover_slot_receive_behind.pl
#
# A new failover slot copy starts at the primary slot's restart_lsn.  While
# the standby has not received that WAL yet, the only position it could
# start at instead is the end of the WAL received.  A standby that is
# catching up receives WAL in chunks that end on page boundaries, so that
# position is usually inside a record, and decoding cannot start there: the
# worker ended with "could not find record while advancing replication
# slot" on every pass until the standby caught up, synchronizing nothing
# meanwhile.  Where the standby cannot decode, the copy was made persistent
# at a position no subscriber could start from.
#
# The worker now creates the copy only once the standby has received the
# primary slot's restart_lsn.
#
# A copy that already exists had a related problem where the standby cannot
# decode: its restart_lsn was moved to the oldest restart_lsn of the
# primary's slots even when the standby had not received that WAL, so a
# promotion left the slot pointing at WAL the node never had.  The worker
# now leaves the copy's restart_lsn alone until that WAL is received.
#
# Topology:
#   n1 (provider/primary)  ──logical──>  n2 (subscriber)
#   n1                     ──physical──> standby (stream replica of n1)
#
#   1. The standby's walreceiver is stopped (SIGSTOP), and n1 writes many
#      1 MB records and moves its slot past them.
#   2. The walreceiver is let run just long enough to receive part of those
#      records.
#   3. The worker moves the existing copy, whose restart_lsn must stay
#      within the WAL received.
#   4. The copy is dropped.  The worker must not create a new one while the
#      standby is short of the primary slot's restart_lsn.
#   5. The walreceiver is let go.  The copy appears and becomes persistent,
#      and the worker never fails to read a record.
#
# This runs twice on the same standby: first with positions copied as they
# are (spock.failover_slots_database empty, the default), then, on PG16 and
# later, with the worker decoding the copy's WAL.
# =============================================================================

my $config       = get_test_config();
my $host         = $config->{host};
my $dbname       = $config->{db_name};
my $db_user      = $config->{db_user};
my $db_password  = $config->{db_password};
my $pg_bin       = $config->{pg_bin};

my ($pg_major) = `$pg_bin/pg_config --version` =~ /\b(\d+)/;

my $standby_datadir = '/tmp/tmp_spock_receive_behind_standby';
my $standby_logdir  = "$standby_datadir/pg_log";
my $standby_log     = "$standby_logdir/standby.log";

# 1 MB records, so nearly every page boundary is inside one.  The run has to
# be much longer than what the walreceiver takes in during one burst, which
# is around 5 MB.
my $PAD_RECORDS = 64;

my $walreceiver_pid;

# Never leave a stopped walreceiver or a running standby behind.
END {
    my $status = $?;
    kill('CONT', $walreceiver_pid) if $walreceiver_pid;
    system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >/dev/null 2>&1")
        if defined $pg_bin && -d $standby_datadir;
    $? = $status;
}

sub qport {
    my ($port, $sql) = @_;
    my $out = `PGCONNECT_TIMEOUT=10 $pg_bin/psql -X -h $host -p $port -d $dbname -U $db_user -t -A -c "$sql" 2>/dev/null`;
    $out //= '';
    $out =~ s/^\s+|\s+$//g;
    return $out;
}

sub wait_until {
    my ($timeout, $poll, $cond) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 if $cond->();
        usleep($poll * 1_000_000);
    }
    return 0;
}

sub standby_log_offset { return (-s $standby_log) // 0 }

sub standby_log_since {
    my ($offset) = @_;
    open(my $lf, '<', $standby_log) or die "cannot open $standby_log: $!";
    seek($lf, $offset, 0) or die "cannot seek in $standby_log: $!";
    local $/;
    my $data = <$lf> // '';
    close($lf);
    return $data;
}

create_cluster(2, 'Create 2-node Spock cluster');

$config = get_test_config();
my $primary_port = $config->{node_ports}->[0];
my $standby_port = $primary_port + 18;
my $sb = sub { qport($standby_port, $_[0]) };

# -----------------------------------------------------------------------------
# n2 subscribes to n1; one replicated table.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE behind_test (id serial PRIMARY KEY, val text)");
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
    "logical slot '$slot_name' is active on n1");

psql_or_bail(1, "INSERT INTO behind_test (val) VALUES ('before_standby')");
ok(wait_until(60, 1, sub {
        scalar_query(2, "SELECT count(*) FROM behind_test") eq '1';
    }),
    'n2 replicates from n1');

# The walsender must not give up on the walreceiver while it is stopped.
psql_or_bail(1, "ALTER SYSTEM SET wal_sender_timeout = 0");
psql_or_bail(1, "SELECT pg_reload_conf()");

# -----------------------------------------------------------------------------
# Physical standby of n1, with the worker passing every second.  It copies
# positions as they are until spock.failover_slots_database is set for the
# second round.
# -----------------------------------------------------------------------------
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
    print $conf "wal_sender_timeout       = 60s\n";
    print $conf "spock.failover_slots_naptime = 1000\n";
    print $conf "spock.failover_slots_feedback_naptime = 1000\n";
    print $conf "sync_replication_slots   = off\n" if $pg_major >= 17;
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

ok(wait_until(60, 1, sub {
        $sb->("SELECT temporary FROM pg_replication_slots
               WHERE slot_name = '$slot_name'") eq 'f';
    }),
    "worker made a persistent copy of '$slot_name' on the standby");

# -----------------------------------------------------------------------------
# One round of the steps in the header.
#
# While it is behind, the walreceiver is sent WAL in chunks that end on page
# boundaries, so stopping it in the middle of a long run of 1 MB records
# leaves its flush position on a page boundary inside a record.  How far it
# gets before it is stopped again depends on timing, so that step is
# repeated if it received everything.
# -----------------------------------------------------------------------------

# The worker synchronizes nothing while the primary's oldest slot is past
# the last WAL position the walreceiver has heard of.  n1's slot can move
# once more after the walreceiver was stopped, when n2 confirms the last
# checkpoint.  If it has, let the walreceiver run for another burst so it
# hears of the newer position.
sub hear_primary_slot {
    my $restart = scalar_query(1,
        "SELECT restart_lsn FROM pg_replication_slots
         WHERE slot_name = '$slot_name'");
    return unless $walreceiver_pid && length($restart);
    return unless $sb->("SELECT latest_end_lsn < '$restart'
                         FROM pg_stat_wal_receiver") eq 't';
    kill('CONT', $walreceiver_pid);
    usleep(5_000);
    kill('STOP', $walreceiver_pid);
}

sub run_round {
    my ($mode) = @_;
    diag("=== 123 round: $mode ===");

    my $slot_restart = '';
    my $pad_start = '';
    my $behind = 0;

    ATTEMPT: foreach my $attempt (1 .. 3)
    {
        $walreceiver_pid = $sb->("SELECT pid FROM pg_stat_wal_receiver");
        BAIL_OUT('no walreceiver on the standby')
            unless $walreceiver_pid =~ /^\d+$/;
        kill('STOP', $walreceiver_pid);

        $pad_start = scalar_query(1, "SELECT pg_current_wal_lsn()");
        psql_or_bail(1,
            "SELECT count(*) FROM (
                SELECT pg_logical_emit_message(false, 'pad', repeat('x', 1000000))
                FROM generate_series(1, $PAD_RECORDS)) s");
        my $pad_end = scalar_query(1, "SELECT pg_current_wal_lsn()");

        # n1's slot moves to a running-xacts record once n2 has confirmed it.
        my $moved = wait_until(60, 1, sub {
            psql_or_bail(1, "INSERT INTO behind_test (val) VALUES ('move_slot')");
            psql_or_bail(1, "CHECKPOINT");
            $slot_restart = scalar_query(1,
                "SELECT restart_lsn FROM pg_replication_slots
                 WHERE slot_name = '$slot_name' AND restart_lsn > '$pad_end'");
            return length($slot_restart) > 0;
        });
        BAIL_OUT("n1's slot did not move past the padding") unless $moved;

        # Let the walreceiver run in short bursts until it has flushed part
        # of the padding, so that its flush position is inside a record.  By
        # then it has also heard of WAL past the primary slot's restart_lsn,
        # which is when the worker starts synchronizing again.
        foreach my $burst (1 .. 200)
        {
            kill('CONT', $walreceiver_pid);
            usleep(5_000);
            kill('STOP', $walreceiver_pid);

            my $state = $sb->(
                "SELECT (flushed_lsn < '$slot_restart')::int || ',' ||
                        (latest_end_lsn >= '$slot_restart' AND
                         flushed_lsn > '$pad_start')::int || ',' ||
                        flushed_lsn
                 FROM pg_stat_wal_receiver");
            my ($short, $inside, $flushed) = split /,/, $state;
            next unless defined $inside;
            if (!$short)
            {
                diag("attempt $attempt: the walreceiver received everything, trying again");
                kill('CONT', $walreceiver_pid);
                next ATTEMPT;
            }
            if ($inside)
            {
                diag("standby received up to $flushed, padding starts at $pad_start, "
                   . "primary slot restart_lsn is $slot_restart");
                $behind = 1;
                last ATTEMPT;
            }
        }
        kill('CONT', $walreceiver_pid);
    }
    ok($behind,
        "[$mode] standby has received only part of the WAL up to the primary slot's restart_lsn");

    # -------------------------------------------------------------------------
    # The existing copy.  Its confirmed position moving into the padding
    # shows that the worker has synchronized it in this state.
    # -------------------------------------------------------------------------
    ok(wait_until(30, 0.5, sub {
            hear_primary_slot();
            $sb->("SELECT count(*) FROM pg_replication_slots
                   WHERE slot_name = '$slot_name'
                     AND confirmed_flush_lsn > '$pad_start'") eq '1';
        }),
        "[$mode] worker synchronized the existing copy");
    is($sb->("SELECT s.restart_lsn <= r.flushed_lsn
              FROM pg_replication_slots s, pg_stat_wal_receiver r
              WHERE s.slot_name = '$slot_name'"), 't',
        "[$mode] existing copy's restart_lsn is within the WAL received");

    # -------------------------------------------------------------------------
    # A new copy.  The worker passes every second.  It must wait for the WAL
    # rather than start a copy at the end of what was received.
    # -------------------------------------------------------------------------
    my $log_from = standby_log_offset();

    wait_until(30, 0.2, sub {
        $sb->("SELECT pg_drop_replication_slot('$slot_name')");
        return standby_log_since($log_from) =~
            /not creating replication slot "\Q$slot_name\E" yet/
          || $sb->("SELECT count(*) FROM pg_replication_slots
                    WHERE slot_name = '$slot_name'") eq '0';
    }) or BAIL_OUT('could not drop the copy on the standby');

    ok(wait_until(30, 1, sub {
            hear_primary_slot();
            standby_log_since($log_from) =~
                /not creating replication slot "\Q$slot_name\E" yet/;
        }),
        "[$mode] worker waits for the standby to receive the restart_lsn");
    is($sb->("SELECT count(*) FROM pg_replication_slots
              WHERE slot_name = '$slot_name'"), '0',
        "[$mode] no copy exists while the restart_lsn has not been received");
    my $restart_now = scalar_query(1,
        "SELECT restart_lsn FROM pg_replication_slots
         WHERE slot_name = '$slot_name'");
    is($sb->("SELECT flushed_lsn < '$restart_now' FROM pg_stat_wal_receiver"), 't',
        "[$mode] and the standby is still short of it");

    # -------------------------------------------------------------------------
    # Let the standby catch up.  The copy is created and becomes persistent.
    # -------------------------------------------------------------------------
    kill('CONT', $walreceiver_pid);
    $walreceiver_pid = undef;

    ok(wait_until(60, 1, sub {
            $sb->("SELECT temporary FROM pg_replication_slots
                   WHERE slot_name = '$slot_name'") eq 'f';
        }),
        "[$mode] copy is persistent once the standby has caught up");

    # ok() rather than unlike(): a failed unlike() prints the whole log.
    my $log = standby_log_since($log_from);
    ok($log !~ /could not find record while advancing replication slot/,
        "[$mode] worker never failed to read a record");
    ok($log !~ /TRAP:|was terminated by signal/,
        "[$mode] no process on the standby crashed");
}

run_round('copied');

SKIP: {
    skip 'PG15 cannot decode WAL on a standby', 9 if $pg_major < 16;

    open(my $conf, '>>', "$standby_datadir/postgresql.conf")
        or die "Cannot open standby postgresql.conf: $!";
    print $conf "spock.failover_slots_database = '$dbname'\n";
    close($conf);
    system_or_bail("$pg_bin/pg_ctl", 'restart', '-D', $standby_datadir,
        '-l', "$standby_datadir/startup.log", '-w');
    wait_until(30, 1, sub {
        $sb->("SELECT count(*) FROM pg_stat_wal_receiver
               WHERE status = 'streaming'") eq '1';
    }) or BAIL_OUT('standby did not resume streaming after the restart');

    run_round('decoded');
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >> /dev/null 2>&1");
foreach my $src ("$standby_datadir/startup.log", glob("$standby_logdir/*")) {
    next unless -f $src;
    (my $base = $src) =~ s{.*/}{};
    system('cp', $src, "$config->{log_dir}/123_failover_slot_receive_behind_$base");
}
system("rm -rf $standby_datadir 2>/dev/null");

psql_or_bail(1, "ALTER SYSTEM RESET wal_sender_timeout");
psql_or_bail(1, "SELECT pg_reload_conf()");
destroy_cluster('Destroy test cluster');

done_testing();
