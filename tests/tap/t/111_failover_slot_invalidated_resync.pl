use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster get_test_config
    system_or_bail psql_or_bail scalar_query
);
use Time::HiRes qw(time);

# =============================================================================
# Test: 111_failover_slot_invalidated_resync.pl
#
# The spock_failover_slots worker must not keep a synced slot that was
# invalidated on the standby.  It used to acquire such a slot and advance
# its LSN and catalog_xmin each cycle, so the slot looked current but could
# not be used after promotion.  Now the worker drops it and creates it again
# from the primary.
#
# Flow:
#   1. n2 subscribes to n1, so n1 has a logical slot.
#   2. Build a physical standby of n1; the worker syncs the slot to it.
#   3. Pause sync (hot_standby_feedback off), set max_slot_wal_keep_size,
#      and generate WAL so a restartpoint invalidates the standby copy.
#   4. Re-enable sync and check the slot is valid again on the standby.
#
# The worker does not exist on PG18+ (native slotsync only).
# =============================================================================

my $pg_bin = get_test_config()->{pg_bin};
my ($pg_major) = `$pg_bin/pg_config --version` =~ /\b(\d+)/;
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

# ---------- logical slot on n1 ----------

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

psql_or_bail(1, "CREATE TABLE inval_test (id serial primary key, pad text)");

# Move the slot past a segment boundary so the worker's catchup wait on the
# standby finishes quickly (see 018_failover_slots.pl).
psql_or_bail(1, "SELECT pg_switch_wal()");
psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
sleep(5);

psql_or_bail(1, "SELECT pg_create_physical_replication_slot('standby_slot')");

# ---------- physical standby ----------

my $standby_port    = $primary_port + 12;
my $standby_datadir = '/tmp/tmp_spock_inval_standby';
my $standby_logdir  = "$standby_datadir/pg_log";
my $standby_logpath = "$standby_logdir/standby.log";

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

is(qport($standby_port, "SELECT pg_is_in_recovery()"), 't',
    'standby is in recovery');

ok(wait_until(120, 3, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name = '$slot_name' AND wal_status <> 'lost'
           AND confirmed_flush_lsn IS NOT NULL") eq '1';
}), "slot '$slot_name' synced to standby");

# ---------- invalidate the standby copy ----------

# hot_standby_feedback off makes the worker skip sync, so the copy keeps
# its old restart_lsn while n1's slot moves ahead.
qport($standby_port, "ALTER SYSTEM SET hot_standby_feedback = off");
qport($standby_port, "ALTER SYSTEM SET max_slot_wal_keep_size = '1MB'");
qport($standby_port, "SELECT pg_reload_conf()");
sleep(3);

for my $i (1 .. 5)
{
    psql_or_bail(1,
        "INSERT INTO inval_test (pad) SELECT repeat('x', 100) FROM generate_series(1, 1000)");
    psql_or_bail(1, "SELECT pg_switch_wal()");
}
psql_or_bail(1, "CHECKPOINT");

my $primary_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
$primary_lsn =~ s/\s+//g;
ok(wait_until(60, 2, sub {
    return qport($standby_port,
        "SELECT pg_last_wal_replay_lsn() >= '$primary_lsn'::pg_lsn") eq 't';
}), 'standby replayed the generated WAL');

# Restartpoint on the standby removes the old WAL and invalidates the copy.
my $lost = wait_until(30, 2, sub {
    qport($standby_port, "CHECKPOINT");
    return qport($standby_port,
        "SELECT wal_status FROM pg_replication_slots
         WHERE slot_name = '$slot_name'") eq 'lost';
});
ok($lost, "standby copy of '$slot_name' is invalidated");
unless ($lost)
{
    diag(qport($standby_port,
        "SELECT slot_name || ' ' || coalesce(wal_status, '') || ' ' || coalesce(restart_lsn::text, '')
                || ' hsf=' || current_setting('hot_standby_feedback')
                || ' keep=' || current_setting('max_slot_wal_keep_size')
                || ' redo=' || (SELECT redo_lsn::text FROM pg_control_checkpoint())
         FROM pg_replication_slots"));
}

# ---------- resume sync ----------

qport($standby_port, "ALTER SYSTEM RESET max_slot_wal_keep_size");
qport($standby_port, "ALTER SYSTEM SET hot_standby_feedback = on");
qport($standby_port, "SELECT pg_reload_conf()");

my $valid = wait_until(120, 3, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name = '$slot_name'
           AND wal_status <> 'lost' AND restart_lsn IS NOT NULL") eq '1';
});
ok($valid, "worker recreated '$slot_name' on the standby after invalidation");

my $warned = 0;
if (open(my $fh, '<', $standby_logpath))
{
    while (<$fh>)
    {
        $warned++ if /replication slot "\Q$slot_name\E" is invalidated on the standby, recreating it/;
    }
    close($fh);
}
ok($warned > 0, 'worker logged a WARNING about the invalidated slot');

unless ($valid)
{
    diag(qport($standby_port,
        "SELECT slot_name || ' ' || coalesce(wal_status, '') || ' ' || coalesce(restart_lsn::text, '')
         FROM pg_replication_slots"));
}

# ---------- cleanup ----------

system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >/dev/null 2>&1");
system("rm -rf $standby_datadir 2>/dev/null");

destroy_cluster('Destroy test cluster');
done_testing();
