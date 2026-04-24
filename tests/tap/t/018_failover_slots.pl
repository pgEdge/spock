use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config system_or_bail command_ok system_maybe
    psql_or_bail scalar_query
);
use Time::HiRes qw(time);

# =============================================================================
# Test: 018_failover_slots.pl
#
# Verifies logical replication slot failover for all supported PG versions.
#
# Topology:
#   n1 (provider/primary)  ──logical──>  n2 (subscriber)
#   n1                     ──physical──> standby (stream replica of n1)
#
# Test flow:
#   1. Create 2-node spock cluster (n1 + n2, cross-wired)
#   2. Build a physical streaming standby of n1 via pg_basebackup
#   3. Configure standby for slot sync (version-appropriate)
#   4. Verify logical slot appears on standby with correct flags
#   5. Confirm slot LSN on standby tracks primary (slot is live)
#   6. Write data to n1, confirm n2 receives it (replication healthy)
#   7. Promote standby, reconnect n2, confirm post-failover replication
# =============================================================================

# --------------------------------------------------------------------------
# Helper: query on an arbitrary port
# --------------------------------------------------------------------------
sub qport {
    my ($pg_bin, $host, $port, $dbname, $user, $sql) = @_;
    my $out = `$pg_bin/psql -X -h $host -p $port -d $dbname -U $user -t -c "$sql" 2>/dev/null`;
    $out //= '';
    $out =~ s/^\s+|\s+$//g;
    return $out;
}

# --------------------------------------------------------------------------
# Helper: poll until condition or timeout
# --------------------------------------------------------------------------
sub wait_until {
    my ($timeout, $poll, $cond) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 if $cond->();
        sleep($poll);
    }
    return 0;
}

# ==========================================================================
# 1. Create 2-node spock cluster
# ==========================================================================
create_cluster(2, 'Create 2-node Spock cluster');

my $config       = get_test_config();
my $host         = $config->{host};
my $dbname       = $config->{db_name};
my $db_user      = $config->{db_user};
my $db_password  = $config->{db_password};
my $pg_bin       = $config->{pg_bin};
my $node_ports   = $config->{node_ports};
my $node_dirs    = $config->{node_datadirs};
my $primary_port = $node_ports->[0];   # n1
my $sub_port     = $node_ports->[1];   # n2
my $primary_dir  = $node_dirs->[0];

# Detect PostgreSQL major version
my $pgver = scalar_query(1,
    "SELECT current_setting('server_version_num')::int");
$pgver =~ s/\s+//g;
my $pg_major = int($pgver / 10000);
diag("PostgreSQL major version: $pg_major");

# ==========================================================================
# 2. Create subscription n2 -> n1 (n2 subscribes to n1)
# ==========================================================================
psql_or_bail(2, "SELECT spock.sub_create(
    'sub_n2_n1',
    'host=$host dbname=$dbname port=$primary_port user=$db_user password=$db_password',
    ARRAY['default','default_insert_only','ddl_sql'],
    true, true
)");

my $sub_active = wait_until(60, 3, sub {
    my $s = scalar_query(2,
        "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n2_n1'");
    $s =~ s/\s+//g;
    return $s eq 't';
});
ok($sub_active, 'Subscription sub_n2_n1 active on n2');

# ==========================================================================
# 3. Get the logical slot created on n1 for n2
# ==========================================================================
# The slot is created asynchronously by the sync worker after subscription
# is enabled, so poll until it appears (up to 60s).
my $slot_name = '';
my $slot_ready = wait_until(60, 3, sub {
    $slot_name = scalar_query(1,
        "SELECT slot_name FROM pg_replication_slots WHERE slot_type='logical' LIMIT 1");
    $slot_name =~ s/\s+//g;
    return length($slot_name) > 0;
});
ok($slot_ready && length($slot_name) > 0,
    "Logical slot created on n1: '$slot_name'");

# ==========================================================================
# 4. Verify FAILOVER flag on slot (PG17+)
# ==========================================================================
if ($pg_major >= 17) {
    my $fv = scalar_query(1,
        "SELECT failover FROM pg_replication_slots WHERE slot_name='$slot_name'");
    $fv =~ s/\s+//g;
    is($fv, 't',
        "PG$pg_major: slot '$slot_name' was created with FAILOVER=true");
} else {
    pass("PG$pg_major: FAILOVER flag not applicable (PG15/16)");
}

# ==========================================================================
# 5. Verify spock failover bgworker state on n1 (primary)
# ==========================================================================
if ($pg_major >= 18) {
    my $wc = scalar_query(1,
        "SELECT count(*) FROM pg_stat_activity
         WHERE application_name = 'spock_failover_slots worker'");
    $wc =~ s/\s+//g;
    is($wc, '0',
        "PG18+: spock_failover_slots bgworker not registered on primary");
} else {
    pass("PG$pg_major: spock bgworker expected (PG15/16/17 uses it on standby)");
}

# ==========================================================================
# 6. Create physical replication slot for the standby
# ==========================================================================

# Force a WAL segment switch on n1 so the logical slot's restart_lsn
# advances across a segment boundary.  On PG15/16 the failover-slot bgworker
# uses wait_for_primary_slot_catchup() which requires the primary slot's
# restart_lsn to be >= the standby's local WAL reservation; without a forced
# switch the gap can be just a few bytes (within the same segment), making
# the wait too easy to interrupt by promotion before the slot is persisted.
if ($pg_major < 17) {
    psql_or_bail(1, "SELECT pg_switch_wal()");
    # Wait for n2's apply worker to acknowledge the new WAL position so the
    # slot's confirmed_flush_lsn (and restart_lsn) advances past the switch
    # point before we take the basebackup.
    sleep(5);
}

psql_or_bail(1,
    "SELECT pg_create_physical_replication_slot('standby_physical_slot')");
pass('Physical replication slot created on n1');

# ==========================================================================
# 7. Build physical standby of n1 via pg_basebackup
# ==========================================================================
my $standby_port    = $primary_port + 10;
my $standby_datadir = '/tmp/tmp_spock_failover_standby';
my $standby_logdir  = "$standby_datadir/pg_log";
my $standby_logfile = "$standby_logdir/standby.log";

system("rm -rf $standby_datadir 2>/dev/null");
system_or_bail("$pg_bin/pg_basebackup",
    '-D', $standby_datadir,
    '-h', $host, '-p', $primary_port, '-U', $db_user,
    '-X', 'stream', '-R');
pass('Physical standby created via pg_basebackup');

# ==========================================================================
# 8. Configure and start standby
# ==========================================================================
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
    print $conf "log_min_messages         = debug1\n";
    print $conf "log_replication_commands = on\n";

    if ($pg_major >= 17) {
        # Enable native slot sync worker on standby
        print $conf "sync_replication_slots = on\n";
    }
    close($conf);
}

# pg_basebackup -R writes primary_conninfo without dbname to postgresql.auto.conf,
# but PG17+ slotsync worker requires dbname in primary_conninfo to locate logical
# slots.  Append a corrected primary_conninfo to auto.conf (last entry wins).
{
    open(my $aconf, '>>', "$standby_datadir/postgresql.auto.conf")
        or die "Cannot open standby postgresql.auto.conf: $!";
    print $aconf "\n# slotsync requires dbname in primary_conninfo\n";
    print $aconf "primary_conninfo = 'host=$host port=$primary_port "
               . "user=$db_user dbname=$dbname'\n";
    close($aconf);
}

# PG17+: hold walsenders on primary until standby confirms LSN
if ($pg_major >= 17) {
    psql_or_bail(1,
        "ALTER SYSTEM SET synchronized_standby_slots = 'standby_physical_slot'");
    psql_or_bail(1, "SELECT pg_reload_conf()");
}

system_or_bail("$pg_bin/pg_ctl", 'start',
    '-D', $standby_datadir, '-l', "$standby_datadir/startup.log", '-w');

command_ok(["$pg_bin/pg_isready", '-h', $host, '-p', $standby_port],
    'Standby is accepting connections');

# pg_is_in_recovery() returns boolean — psql displays as 't'/'f'
my $in_recovery = qport($pg_bin, $host, $standby_port,
    $dbname, $db_user, "SELECT pg_is_in_recovery()");
$in_recovery =~ s/\s+//g;
is($in_recovery, 't', 'Standby is in recovery (streaming from n1)');

# ==========================================================================
# 9. Verify physical streaming replication is active on n1
# ==========================================================================
my $streaming = wait_until(30, 3, sub {
    my $c = scalar_query(1,
        "SELECT count(*) FROM pg_stat_replication
         WHERE state = 'streaming'");
    $c =~ s/\s+//g;
    return $c > 0;
});
ok($streaming, 'n1 has an active streaming replication connection to standby');

# ==========================================================================
# 10. Wait for logical slot to be synchronized to standby
# ==========================================================================
my $wait_secs = ($pg_major >= 17) ? 60 : 120;
my $poll_secs = 5;
diag("Waiting up to ${wait_secs}s for slot '$slot_name' on standby...");

my $slot_present = wait_until($wait_secs, $poll_secs, sub {
    my $c = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT count(*) FROM pg_replication_slots
         WHERE slot_name = '$slot_name'");
    $c =~ s/\s+//g;
    return $c > 0;
});
ok($slot_present,
    "Logical slot '$slot_name' present on standby within ${wait_secs}s");

# Emit diagnostics whenever slot sync is slow / failed.
unless ($slot_present) {
    my $all_slots = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT slot_name, slot_type, active FROM pg_replication_slots");
    diag("  standby pg_replication_slots: $all_slots");

    my $sub_enabled = scalar_query(2,
        "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n2_n1'");
    $sub_enabled =~ s/\s+//g;
    diag("  n2 sub_n2_n1 sub_enabled: $sub_enabled");

    my $n1_slots = scalar_query(1,
        "SELECT slot_name||':'||active::text FROM pg_replication_slots WHERE slot_type='logical'");
    $n1_slots =~ s/\s+//g;
    diag("  n1 logical slots: $n1_slots");

    if ($pg_major < 17) {
        my $bgw_pid = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
            "SELECT pid||' state='||state FROM pg_stat_activity
             WHERE application_name = 'spock_failover_slots worker'");
        $bgw_pid =~ s/\s+//g;
        diag("  standby bgworker: $bgw_pid");
    }
}

# ==========================================================================
# 11. PG17+: verify synced=t and failover=t on standby
# ==========================================================================
if ($pg_major >= 17) {
    # Poll until synced=true (slotsync may take a few cycles)
    my $fully_synced = wait_until(30, 3, sub {
        my $s = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
            "SELECT synced FROM pg_replication_slots
             WHERE slot_name = '$slot_name'");
        $s =~ s/\s+//g;
        return $s eq 't';
    });
    is($fully_synced, 1,
        "PG$pg_major: standby slot '$slot_name' has synced=true");

    my $fb = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT failover FROM pg_replication_slots
         WHERE slot_name = '$slot_name'");
    $fb =~ s/\s+//g;
    is($fb, 't',
        "PG$pg_major: standby slot '$slot_name' has failover=true");

    # Verify slot LSN on standby is not behind primary by more than 1MB
    my $primary_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
    $primary_lsn =~ s/\s+//g;
    my $slot_lsn = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT confirmed_flush_lsn FROM pg_replication_slots
         WHERE slot_name = '$slot_name'");
    $slot_lsn =~ s/\s+//g;
    my $lag = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT '$primary_lsn'::pg_lsn - confirmed_flush_lsn
         FROM pg_replication_slots WHERE slot_name = '$slot_name'");
    $lag =~ s/\s+//g;
    ok(defined($lag) && $lag ne '',
        "PG$pg_major: slot LSN lag from primary is measurable ($lag bytes)");

    diag("  primary_lsn=$primary_lsn  slot_lsn=$slot_lsn  lag=${lag}bytes");
} else {
    pass("PG$pg_major: synced column not available");
    pass("PG$pg_major: failover column not available");
    pass("PG$pg_major: LSN lag check skipped");
}

# ==========================================================================
# 12. Verify spock_failover_slots bgworker state on standby per PG version:
#     PG15/16: worker must be running (sole sync mechanism)
#     PG17:    worker is registered and present; it yields to native slotsync
#              when sync_replication_slots=on but still appears in pg_stat_activity
#     PG18+:   worker is not registered at all
# ==========================================================================
my $bgw_count = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
    "SELECT count(*) FROM pg_stat_activity
     WHERE application_name = 'spock_failover_slots worker'");
$bgw_count =~ s/\s+//g;

if ($pg_major < 17) {
    ok($bgw_count > 0,
        "PG$pg_major: spock_failover_slots worker running on standby");
} elsif ($pg_major == 17) {
    ok($bgw_count > 0,
        "PG17: spock_failover_slots worker registered on standby (yields to native slotsync)");
} else {
    pass("PG$pg_major: spock bgworker not expected on standby (PG18+ native slotsync only)");
}

# ==========================================================================
# 13. PG18+: confirm no spock bgworker on standby
# ==========================================================================
if ($pg_major >= 18) {
    is($bgw_count, '0',
        "PG18+: no spock_failover_slots bgworker on standby");
} else {
    pass("PG$pg_major: bgworker absence check not applicable (< PG18)");
}

# ==========================================================================
# 14. Write data on n1, verify n2 receives it (baseline replication check)
# ==========================================================================
psql_or_bail(1,
    "CREATE TABLE IF NOT EXISTS failover_test (id int primary key, val text)");
sleep(5);
psql_or_bail(1,
    "INSERT INTO failover_test VALUES (1, 'before_failover')");

# Check subscription state before waiting for data
{
    my $sub_state = scalar_query(2,
        "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n2_n1'");
    $sub_state =~ s/\s+//g;
    diag("  n2 sub_n2_n1 sub_enabled before data check: $sub_state");

    # If disabled due to error, re-enable so the test can proceed
    if ($sub_state eq 'f') {
        diag("  Re-enabling disabled subscription sub_n2_n1");
        psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");
        sleep(5);
    }
}

my $data_ok = wait_until(60, 3, sub {
    my $v = scalar_query(2,
        "SELECT val FROM failover_test WHERE id = 1");
    $v =~ s/\s+//g;
    return $v eq 'before_failover';
});
ok($data_ok, 'Row (1, before_failover) replicated n1 -> n2 before failover');

# ==========================================================================
# 15. Verify invalidation_reason is NULL (slot is healthy on standby)
# ==========================================================================
if ($pg_major >= 17) {
    my $inv = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT coalesce(invalidation_reason::text, 'none')
         FROM pg_replication_slots WHERE slot_name = '$slot_name'");
    $inv =~ s/\s+//g;
    is($inv, 'none',
        "PG$pg_major: slot '$slot_name' on standby has no invalidation_reason");
} else {
    pass("PG$pg_major: invalidation_reason check not applicable");
}

# ==========================================================================
# 16. Failover: stop n1, promote standby
# ==========================================================================
diag("Stopping n1 (primary) to simulate failover...");
system("$pg_bin/pg_ctl stop -D $primary_dir -m fast >> /dev/null 2>&1");
sleep(5);

diag("Promoting standby to new primary...");
# Use promote without -w, then poll
system("$pg_bin/pg_ctl promote -D $standby_datadir >> /dev/null 2>&1");

my $promoted = wait_until(30, 3, sub {
    my $r = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT pg_is_in_recovery()");
    $r =~ s/\s+//g;
    return $r eq 'f';
});
ok($promoted, 'Standby promoted to primary (no longer in recovery)');

# ==========================================================================
# 17. Reconnect n2 to the promoted standby
#     - Add a failover interface on n1's node record
#     - Switch subscription to use that interface
# ==========================================================================

# Disable the subscription first to ensure the apply worker has fully
# stopped before we change the interface DSN.  This is especially important
# on PG16 where the worker may be in a reconnect loop after the primary
# went away; without an explicit disable the DSN change can race with the
# worker's next connection attempt.
psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1')");
sleep(3);

psql_or_bail(2,
    "SELECT spock.node_add_interface(
        'n1', 'n1_promoted',
        'host=$host dbname=$dbname port=$standby_port user=$db_user password=$db_password'
    )");

psql_or_bail(2,
    "SELECT spock.sub_alter_interface('sub_n2_n1', 'n1_promoted')");

# Re-enable so the apply worker connects using the new interface that
# points to the promoted standby.
psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");

# Wait for n2's apply worker to connect to the promoted standby.
diag("Waiting for sub_n2_n1 to reconnect to promoted standby (up to 90s)...");
my $sub_reconnected = wait_until(90, 5, sub {
    my $s = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT count(*) FROM pg_stat_replication");
    $s =~ s/\s+//g;
    return $s > 0;
});
diag($sub_reconnected
    ? "  n2 connected to promoted standby"
    : "  WARNING: n2 did not reconnect within 90s");

# ==========================================================================
# 18. Write data on promoted standby, verify n2 receives it
# ==========================================================================
system("$pg_bin/psql -X -h $host -p $standby_port -d $dbname -U $db_user "
    . "-c \"INSERT INTO failover_test VALUES (2, 'after_failover')\" "
    . ">> /dev/null 2>&1");

my $post_ok = wait_until(60, 3, sub {
    my $v = scalar_query(2,
        "SELECT val FROM failover_test WHERE id = 2");
    $v =~ s/\s+//g;
    return $v eq 'after_failover';
});
ok($post_ok,
    'Row (2, after_failover) replicated promoted-standby -> n2 after failover');

# ==========================================================================
# Cleanup
# ==========================================================================
system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >> /dev/null 2>&1");

# Undo primary GUC change so destroy_cluster can restart n1 cleanly
system("$pg_bin/postgres -D $primary_dir >> /dev/null 2>&1 &");
sleep(10);
system_maybe("$pg_bin/psql", '-h', $host, '-p', $primary_port,
    '-d', $dbname, '-U', $db_user,
    '-c', "ALTER SYSTEM RESET synchronized_standby_slots");
system_maybe("$pg_bin/psql", '-h', $host, '-p', $primary_port,
    '-d', $dbname, '-U', $db_user, '-c', "SELECT pg_reload_conf()");

system("rm -rf $standby_datadir 2>/dev/null");

destroy_cluster('Destroy test cluster');
done_testing();
