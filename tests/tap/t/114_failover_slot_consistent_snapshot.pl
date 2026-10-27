use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster get_test_config
    system_or_bail system_maybe psql_or_bail scalar_query
);
use Time::HiRes qw(time);

# =============================================================================
# Test: 114_failover_slot_consistent_snapshot.pl
#
# After a promotion, decoding starts at the copied slot's restart_lsn.  The
# primary saved a snapshot there, but physical replication does not carry
# it, so the new primary had to build one from scratch.  A transaction that
# committed before that snapshot was consistent was never sent: the
# subscriber silently missed the last commits of the old primary.
#
# The spock_failover_slots worker now decodes the copy's WAL on the standby
# (spock.failover_slots_database), so the copy only ever points at a
# position where the standby has saved a snapshot of its own.
#
# Flow:
#   1. n2 subscribes to n1; a physical standby of n1 syncs the slot, first
#      without spock.failover_slots_database, so positions are only copied.
#   2. A transaction T1 stays open on n1, so n1's slot keeps a restart_lsn
#      from before it, and the copy gets that restart_lsn.
#   3. The setting is turned on: decoding from that restart_lsn cannot be
#      consistent while T1 is open, and the worker says so.  T1 ends and
#      the copy becomes consistent.
#   4. A transaction T2 stays open on n1 as in step 2, this time with the
#      copy decoded on the standby.
#   5. The subscription is disabled and rows are committed on n1; they
#      reach the standby but not n2.
#   6. n1 is killed, the standby promoted, and n2 pointed at it.
#   7. Every row committed on n1 must reach n2.
#
# PG15 cannot decode WAL on a standby, and PG18+ uses native slot sync.
# =============================================================================

my $pg_bin = get_test_config()->{pg_bin};
my ($pg_major) = `$pg_bin/pg_config --version` =~ /\b(\d+)/;
plan skip_all =>
    "spock_failover_slots worker cannot decode on a PG15 standby"
    if defined $pg_major && $pg_major < 16;
plan skip_all =>
    "spock_failover_slots worker is disabled on PG18+ (native sync_replication_slots)"
    if defined $pg_major && $pg_major >= 18;

sub qport {
    my ($port, $sql) = @_;
    my $config = get_test_config();
    my $out = `PGCONNECT_TIMEOUT=10 $config->{pg_bin}/psql -X -h $config->{host} -p $port -d $config->{db_name} -U $config->{db_user} -t -A -c "$sql" 2>/dev/null`;
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

create_cluster(2, 'Create 2-node Spock cluster');

my $config       = get_test_config();
my $host         = $config->{host};
my $dbname       = $config->{db_name};
my $db_user      = $config->{db_user};
my $db_password  = $config->{db_password};
my $primary_port = $config->{node_ports}[0];
my $primary_dir  = $config->{node_datadirs}[0];

psql_or_bail(2, "SELECT spock.sub_create(
    'sub_n2_n1',
    'host=$host dbname=$dbname port=$primary_port user=$db_user password=$db_password',
    ARRAY['default','default_insert_only','ddl_sql'],
    true, true
)");

my $slot_name = '';
ok(wait_until(60, 2, sub {
    $slot_name = scalar_query(1,
        "SELECT slot_name FROM pg_replication_slots WHERE slot_type = 'logical' LIMIT 1");
    $slot_name =~ s/\s+//g;
    return length($slot_name) > 0;
}), "logical slot created on n1");

psql_or_bail(1, "CREATE TABLE snap_test (id int primary key, pad text)");
ok(wait_until(60, 2, sub {
    return scalar_query(2,
        "SELECT count(*) FROM pg_tables WHERE tablename = 'snap_test'") =~ /1/;
}), 'table reached n2');

psql_or_bail(1, "SELECT pg_create_physical_replication_slot('standby_slot')");

# ---------- physical standby ----------

my $standby_port    = $primary_port + 14;
my $standby_datadir = '/tmp/tmp_spock_snap_standby';
my $standby_logdir  = "$standby_datadir/pg_log";

system("rm -rf $standby_datadir 2>/dev/null");
system_or_bail("$pg_bin/pg_basebackup",
    '-D', $standby_datadir,
    '-h', $host, '-p', $primary_port, '-U', $db_user,
    '-X', 'stream', '-R');

system_or_bail('mkdir', '-p', $standby_logdir);
{
    open(my $conf, '>>', "$standby_datadir/postgresql.conf")
        or die "Cannot open standby postgresql.conf: $!";
    print $conf "\n# ---- standby overrides ----\n";
    print $conf "port = $standby_port\n";
    print $conf "hot_standby = on\n";
    print $conf "hot_standby_feedback = on\n";
    print $conf "primary_slot_name = 'standby_slot'\n";
    print $conf "log_directory = '$standby_logdir'\n";
    print $conf "log_filename = 'standby.log'\n";
    # PG17: keep native slotsync off so the spock worker does the sync
    print $conf "sync_replication_slots = off\n" if $pg_major >= 17;
    close($conf);
}
{
    open(my $aconf, '>>', "$standby_datadir/postgresql.auto.conf")
        or die "Cannot open standby postgresql.auto.conf: $!";
    print $aconf "primary_conninfo = 'host=$host port=$primary_port "
               . "user=$db_user dbname=$dbname'\n";
    close($aconf);
}

system_or_bail("$pg_bin/pg_ctl", 'start', '-D', $standby_datadir,
    '-l', "$standby_datadir/startup.log", '-w');

my $next_id = 1;
sub insert_rows {
    my ($n) = @_;
    my $first = $next_id;
    my $last  = $next_id + $n - 1;
    psql_or_bail(1,
        "INSERT INTO snap_test SELECT g, 'x' FROM generate_series($first, $last) g");
    $next_id = $last + 1;
}

ok(wait_until(120, 2, sub {
    insert_rows(1);
    psql_or_bail(1, "CHECKPOINT");
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name = '$slot_name' AND NOT temporary
           AND confirmed_flush_lsn IS NOT NULL") eq '1';
}), "slot '$slot_name' synced to the standby");

sub count_log {
    my ($re) = @_;
    my $n = 0;
    if (open(my $fh, '<', "$standby_logdir/standby.log"))
    {
        while (<$fh>) { $n++ if /$re/; }
        close($fh);
    }
    return $n;
}

# Open a transaction on n1 that stays open; the marker tells them apart.
sub open_transaction {
    my ($marker) = @_;
    system("$pg_bin/psql -X -h $host -p $primary_port -d $dbname -U $db_user "
         . "-c \"BEGIN; INSERT INTO snap_test VALUES ($marker, 'open'); "
         . "SELECT pg_sleep(600 + $marker); COMMIT;\" >/dev/null 2>&1 &");
    ok(wait_until(30, 1, sub {
        return scalar_query(1,
            "SELECT count(*) FROM pg_stat_activity
             WHERE backend_xid IS NOT NULL
               AND query LIKE '%pg_sleep(600 + $marker)%'
               AND pid <> pg_backend_pid()") =~ /1/;
    }), "transaction $marker is open on n1");
}

# Commit rows that reach n2, so n1's slot confirms past the open
# transaction's start while its restart_lsn stays before it, and wait for
# the standby's copy to follow.
sub confirm_past_open_transaction {
    my ($label) = @_;
    insert_rows(100);
    my $target = scalar_query(1, "SELECT pg_current_wal_lsn()");
    $target =~ s/\s+//g;
    ok(wait_until(60, 2, sub {
        psql_or_bail(1, "CHECKPOINT");
        return scalar_query(1,
            "SELECT confirmed_flush_lsn >= '$target'::pg_lsn
             FROM pg_replication_slots WHERE slot_name = '$slot_name'") =~ /t/;
    }), "$label: n1's slot confirmed past the open transaction's start");
    ok(wait_until(60, 2, sub {
        return qport($standby_port,
            "SELECT confirmed_flush_lsn >= '$target'::pg_lsn
             FROM pg_replication_slots WHERE slot_name = '$slot_name'") eq 't';
    }), "$label: the standby's copy followed");
}

ok(count_log(qr/replication slot "\Q$slot_name\E" is synchronized without a consistent snapshot/) == 1,
    'without spock.failover_slots_database the worker warns once');

# ---------- a copy made without local decoding ----------

open_transaction(-1);
confirm_past_open_transaction('T1');

qport($standby_port, "ALTER SYSTEM SET spock.failover_slots_database = '$dbname'");
system_or_bail("$pg_bin/pg_ctl", 'restart', '-D', $standby_datadir, '-w',
    '-l', "$standby_datadir/startup.log");

my $inconsistent_re =
    qr/replication slot "\Q$slot_name\E" has no consistent snapshot on the standby/;
ok(wait_until(60, 2, sub {
    insert_rows(1);
    psql_or_bail(1, "CHECKPOINT");
    return count_log($inconsistent_re) > 0;
}), 'the worker reports a copy that cannot be consistent while T1 is open');

my $old_restart = qport($standby_port,
    "SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = '$slot_name'");

# Once T1 ends, decoding on the standby becomes consistent and restart_lsn
# moves to a position where the standby saved a snapshot.
psql_or_bail(1,
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
     WHERE query LIKE '%pg_sleep(600 + -1)%' AND pid <> pg_backend_pid()");
ok(wait_until(90, 2, sub {
    insert_rows(1);
    psql_or_bail(1, "CHECKPOINT");
    return qport($standby_port,
        "SELECT restart_lsn > '$old_restart'::pg_lsn
         FROM pg_replication_slots WHERE slot_name = '$slot_name'") eq 't';
}), 'the copy moves on once T1 has ended');
is(count_log($inconsistent_re), 1, 'the inconsistent copy was reported once');

# ---------- the same with local decoding ----------

open_transaction(-2);
confirm_past_open_transaction('T2');

# ---------- rows n2 does not receive before the failover ----------

psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1')");
ok(wait_until(60, 1, sub {
    return scalar_query(1,
        "SELECT active FROM pg_replication_slots
         WHERE slot_name = '$slot_name'") =~ /f/;
}), 'subscription disabled');

insert_rows(100);
my $expected = scalar_query(1, "SELECT count(*) FROM snap_test");
$expected =~ s/\s+//g;
my $final_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
$final_lsn =~ s/\s+//g;
ok(wait_until(60, 1, sub {
    return qport($standby_port,
        "SELECT pg_last_wal_replay_lsn() >= '$final_lsn'::pg_lsn") eq 't';
}), 'the standby replayed every commit');

# ---------- failover ----------

system("$pg_bin/pg_ctl stop -D $primary_dir -m immediate >/dev/null 2>&1");
system_or_bail("$pg_bin/pg_ctl", 'promote', '-D', $standby_datadir, '-w');
ok(wait_until(30, 1, sub {
    return qport($standby_port, "SELECT pg_is_in_recovery()") eq 'f';
}), 'standby promoted');

is(qport($standby_port, "SELECT count(*) FROM snap_test"), $expected,
    'the promoted standby has every row n1 committed');

psql_or_bail(2,
    "SELECT spock.node_add_interface(
        'n1', 'n1_promoted',
        'host=$host dbname=$dbname port=$standby_port user=$db_user password=$db_password'
    )");
psql_or_bail(2, "SELECT spock.sub_alter_interface('sub_n2_n1', 'n1_promoted')");
psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");

# A row written after the promotion arrives only once decoding is past
# everything before it.
qport($standby_port, "INSERT INTO snap_test VALUES (-100, 'after')");
my $caught_up = wait_until(120, 3, sub {
    return scalar_query(2,
        "SELECT count(*) FROM snap_test WHERE id = -100") =~ /1/;
});
ok($caught_up, 'n2 receives a row written on the promoted standby');

my $n2_count = scalar_query(2, "SELECT count(*) FROM snap_test WHERE id > 0");
$n2_count =~ s/\s+//g;
is($n2_count, $expected, "n2 has all $expected rows committed on n1 before the failover");

# ---------- cleanup ----------

system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >/dev/null 2>&1");
system("rm -rf $standby_datadir 2>/dev/null");
system_maybe("$pg_bin/pg_ctl", 'start', '-D', $primary_dir, '-w',
    '-l', "$primary_dir/restart.log");

destroy_cluster('Destroy test cluster');
done_testing();
