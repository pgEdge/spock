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
#   4. Re-enable sync with spock.failover_slots_recreate_invalidated off:
#      the copy stays invalidated and the worker says so once.
#   5. Stop the subscriber and turn the setting back on: the copy is
#      recreated as a temporary slot that waits for n1's slot, and a
#      second slot keeps being synchronized meanwhile.
#      Turning sync off drops the pending copy; turning it on again
#      creates a new one.
#   6. Start the subscriber again and check the copy is made persistent.
#   7. Create a slot on n1 that never moves, so its copy stays pending, then
#      promote the standby and check the copy is dropped, not persisted.
#
# The worker does not exist on PG18+ (native slotsync only).
# =============================================================================

my $pg_bin = get_test_config()->{pg_bin};
my ($pg_major) = `$pg_bin/pg_config --version` =~ /\b(\d+)/;
plan skip_all =>
    "spock_failover_slots worker is disabled on PG18+ (native sync_replication_slots)"
    if defined $pg_major && $pg_major >= 18;

# The second slot uses test_decoding.
my $pkglibdir = `$pg_bin/pg_config --pkglibdir`;
chomp $pkglibdir;
plan skip_all => "test_decoding is not installed in $pkglibdir"
    unless -e "$pkglibdir/test_decoding.so";

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

# A second slot that the test moves by hand, to show the worker keeps
# synchronizing it while it recreates the first one.
my $canary = 'inval_canary';
psql_or_bail(1,
    "SELECT pg_create_logical_replication_slot('$canary', 'test_decoding')");

# Advance the canary to the current WAL position and return its new
# confirmed_flush_lsn on n1.  The checkpoint logs a running-xacts record so
# restart_lsn can move as well.
sub advance_canary {
    psql_or_bail(1, "CHECKPOINT");
    psql_or_bail(1,
        "SELECT pg_replication_slot_advance('$canary', pg_current_wal_lsn())");
    my $lsn = scalar_query(1,
        "SELECT confirmed_flush_lsn FROM pg_replication_slots
         WHERE slot_name = '$canary'");
    $lsn =~ s/\s+//g;
    return $lsn;
}

# Move the slot past a segment boundary so the standby's copy does not stay
# pending long waiting for n1's slot to pass it (see 018_failover_slots.pl).
psql_or_bail(1, "SELECT pg_switch_wal()");
psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
my $insert_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
$insert_lsn =~ s/\s+//g;
ok(wait_until(60, 1, sub {
    return scalar_query(1,
        "SELECT confirmed_flush_lsn >= '$insert_lsn'::pg_lsn
         FROM pg_replication_slots WHERE slot_name = '$slot_name'") =~ /t/;
}), "slot '$slot_name' confirmed past the segment switch");

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
    print $conf "sync_replication_slots = off\n" if ($pg_major // 0) >= 17;
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
    advance_canary();
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name IN ('$slot_name', '$canary') AND NOT temporary
           AND wal_status <> 'lost' AND confirmed_flush_lsn IS NOT NULL") eq '2';
}), "slots '$slot_name' and '$canary' synced to standby");

# ---------- invalidate the standby copy ----------

# hot_standby_feedback off makes the worker skip sync, so the copy keeps
# its old restart_lsn while n1's slot moves ahead.
qport($standby_port, "ALTER SYSTEM SET hot_standby_feedback = off");
qport($standby_port, "ALTER SYSTEM SET max_slot_wal_keep_size = '1MB'");
qport($standby_port, "SELECT pg_reload_conf()");
ok(wait_until(30, 1, sub {
    return qport($standby_port,
        "SELECT current_setting('hot_standby_feedback') = 'off'
            AND current_setting('max_slot_wal_keep_size') = '1MB'") eq 't';
}), 'standby picked up the invalidation settings');

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

# Restartpoint on the standby removes the old WAL and invalidates both
# copies: sync was paused for the canary as well.
my $lost = wait_until(30, 2, sub {
    qport($standby_port, "CHECKPOINT");
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name IN ('$slot_name', '$canary')
           AND wal_status = 'lost'") eq '2';
});
ok($lost, "standby copies of '$slot_name' and '$canary' are invalidated");
unless ($lost)
{
    diag(qport($standby_port,
        "SELECT slot_name || ' ' || coalesce(wal_status, '') || ' ' || coalesce(restart_lsn::text, '')
                || ' hsf=' || current_setting('hot_standby_feedback')
                || ' keep=' || current_setting('max_slot_wal_keep_size')
                || ' redo=' || (SELECT redo_lsn::text FROM pg_control_checkpoint())
         FROM pg_replication_slots"));
}

# ---------- resume sync with recreation turned off ----------

# With spock.failover_slots_recreate_invalidated off the worker must leave
# the invalidated copy alone and say so once.
qport($standby_port, "ALTER SYSTEM RESET max_slot_wal_keep_size");
qport($standby_port, "ALTER SYSTEM SET spock.failover_slots_recreate_invalidated = off");
qport($standby_port, "ALTER SYSTEM SET hot_standby_feedback = on");
qport($standby_port, "SELECT pg_reload_conf()");

my $left_alone_logged = wait_until(60, 2, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    my $n = 0;
    if (open(my $fh, '<', $standby_logpath))
    {
        while (<$fh>)
        {
            $n++ if /replication slot "\Q$slot_name\E" is invalidated on the standby, not recreating it/;
        }
        close($fh);
    }
    return $n > 0;
});
ok($left_alone_logged, 'worker logged that it leaves the invalidated slot alone');

# A few more passes: still invalidated, and the warning was not repeated.
for my $i (1 .. 5)
{
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    sleep(2);
}
is(qport($standby_port,
    "SELECT wal_status FROM pg_replication_slots WHERE slot_name = '$slot_name'"),
    'lost', "standby copy of '$slot_name' is left invalidated while recreation is off");

my $left_alone_warnings = 0;
if (open(my $fh, '<', $standby_logpath))
{
    while (<$fh>)
    {
        $left_alone_warnings++ if /replication slot "\Q$slot_name\E" is invalidated on the standby, not recreating it/;
    }
    close($fh);
}
is($left_alone_warnings, 1, 'the warning about the slot left alone was logged once');

# ---------- turn recreation back on, subscriber stopped ----------

# With the subscriber stopped n1's slot does not move, so it stays behind
# the position the recreated copy reserves on the standby.  The worker must
# keep the copy pending and go on synchronizing the canary.
psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1')");
ok(wait_until(60, 1, sub {
    return scalar_query(1,
        "SELECT active FROM pg_replication_slots
         WHERE slot_name = '$slot_name'") =~ /f/;
}), "slot '$slot_name' is inactive on n1 with the subscription disabled");

qport($standby_port, "ALTER SYSTEM RESET spock.failover_slots_recreate_invalidated");
qport($standby_port, "SELECT pg_reload_conf()");

my $pending = wait_until(60, 2, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    return qport($standby_port,
        "SELECT temporary FROM pg_replication_slots
         WHERE slot_name = '$slot_name'") eq 't';
});
ok($pending, "recreated copy of '$slot_name' waits as a temporary slot");

# The canary's copy is recreated too.  Its own slot on n1 moves, so it must
# become persistent and keep following even though '$slot_name' is stalled
# below it.  Two separate advances, each followed on the standby, show sync
# keeps running across passes while the copy above is pending.
for my $round (1 .. 2)
{
    my $target = advance_canary();
    my $followed = wait_until(90, 2, sub {
        return qport($standby_port,
            "SELECT NOT temporary AND wal_status <> 'lost'
                    AND confirmed_flush_lsn >= '$target'::pg_lsn
             FROM pg_replication_slots WHERE slot_name = '$canary'") eq 't';
    });
    ok($followed, "canary slot is synchronized while '$slot_name' is pending (round $round)");
    diag(qport($standby_port,
        "SELECT string_agg(slot_name || ' tmp=' || temporary || ' ' || coalesce(wal_status, '')
                           || ' ' || coalesce(confirmed_flush_lsn::text, ''), '; ')
         FROM pg_replication_slots")) unless $followed;
}

is(qport($standby_port,
    "SELECT temporary FROM pg_replication_slots WHERE slot_name = '$slot_name'"),
    't', "copy of '$slot_name' is still pending while the subscriber is stopped");

# When sync stops the worker must drop the pending copy, since it is not
# caught up and could not serve a subscriber after a promotion.  The
# persistent canary must stay.
qport($standby_port, "ALTER SYSTEM SET hot_standby_feedback = off");
qport($standby_port, "SELECT pg_reload_conf()");
ok(wait_until(60, 2, sub {
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name = '$slot_name'") eq '0';
}), "pending copy of '$slot_name' is dropped while sync is off");
is(qport($standby_port,
    "SELECT count(*) FROM pg_replication_slots
     WHERE slot_name = '$canary' AND NOT temporary"),
    '1', 'the persistent canary slot is kept while sync is off');

qport($standby_port, "ALTER SYSTEM SET hot_standby_feedback = on");
qport($standby_port, "SELECT pg_reload_conf()");
ok(wait_until(60, 2, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    return qport($standby_port,
        "SELECT temporary FROM pg_replication_slots
         WHERE slot_name = '$slot_name'") eq 't';
}), "copy of '$slot_name' is pending again once sync resumes");

# ---------- start the subscriber again ----------

psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");

my $valid = wait_until(180, 3, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    psql_or_bail(1, "CHECKPOINT");
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name = '$slot_name' AND NOT temporary
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

my $recreated = 0;
if (open(my $fh, '<', $standby_logpath))
{
    while (<$fh>)
    {
        $recreated++ if /created replication slot "\Q$slot_name\E" on the standby/;
    }
    close($fh);
}
# Once for the first copy, once for the recreated one.
is($recreated, 2, 'worker logged that the copy was made persistent');

unless ($valid)
{
    diag(qport($standby_port,
        "SELECT slot_name || ' ' || coalesce(wal_status, '') || ' ' || coalesce(restart_lsn::text, '')
         FROM pg_replication_slots"));
}

# ---------- promotion with a copy still pending ----------

# A new slot on n1 that never moves stays behind the standby's reservation,
# so its copy stays pending.  Promotion must drop it, not persist a copy
# whose restart_lsn is past what the primary's slot still needed.
my $stalled = 'inval_stalled';
psql_or_bail(1,
    "SELECT pg_create_logical_replication_slot('$stalled', 'test_decoding')");
my $stalled_pending = wait_until(90, 2, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    psql_or_bail(1, "CHECKPOINT");
    return qport($standby_port,
        "SELECT temporary FROM pg_replication_slots
         WHERE slot_name = '$stalled'") eq 't';
});
ok($stalled_pending, "copy of '$stalled' is pending on the standby");

# With spock.drop_extra_slots off a persistent copy of a slot the primary no
# longer has is kept, but a pending copy is not a usable slot and goes
# either way.
qport($standby_port, "ALTER SYSTEM SET spock.drop_extra_slots = off");
qport($standby_port, "SELECT pg_reload_conf()");
psql_or_bail(1, "SELECT pg_drop_replication_slot('$stalled')");
ok(wait_until(60, 2, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name = '$stalled'") eq '0';
}), "pending copy of '$stalled' is dropped once n1 drops the slot, with spock.drop_extra_slots off");
is(qport($standby_port,
    "SELECT count(*) FROM pg_replication_slots
     WHERE slot_name = '$canary' AND NOT temporary"),
    '1', 'the persistent canary copy is kept');
qport($standby_port, "ALTER SYSTEM RESET spock.drop_extra_slots");
qport($standby_port, "SELECT pg_reload_conf()");

# Create it again for the promotion below.
psql_or_bail(1,
    "SELECT pg_create_logical_replication_slot('$stalled', 'test_decoding')");
ok(wait_until(90, 2, sub {
    psql_or_bail(1, "INSERT INTO inval_test (pad) VALUES ('x')");
    psql_or_bail(1, "CHECKPOINT");
    return qport($standby_port,
        "SELECT temporary FROM pg_replication_slots
         WHERE slot_name = '$stalled'") eq 't';
}), "copy of '$stalled' is pending on the standby again");

system_or_bail("$pg_bin/pg_ctl", 'promote', '-D', $standby_datadir, '-w');
ok(wait_until(30, 1, sub {
    return qport($standby_port, "SELECT pg_is_in_recovery()") eq 'f';
}), 'standby promoted');

ok(wait_until(60, 2, sub {
    return qport($standby_port,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name = '$stalled'") eq '0';
}), "pending copy of '$stalled' is dropped after promotion");

my $stalled_created = 0;
if (open(my $fh, '<', $standby_logpath))
{
    while (<$fh>)
    {
        $stalled_created++ if /created replication slot "\Q$stalled\E" on the standby/;
    }
    close($fh);
}
is($stalled_created, 0, "copy of '$stalled' was never made persistent");

# ---------- cleanup ----------

system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >/dev/null 2>&1");
system("rm -rf $standby_datadir 2>/dev/null");
psql_or_bail(1, "SELECT pg_drop_replication_slot('$canary')");
psql_or_bail(1, "SELECT pg_drop_replication_slot('$stalled')");

destroy_cluster('Destroy test cluster');
done_testing();
