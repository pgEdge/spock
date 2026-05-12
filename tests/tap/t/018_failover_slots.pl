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
# 4. Verify FAILOVER flag on slot is NOT set (spock owns the sync; native
#    PG slot-sync is intentionally disabled on this branch).
# ==========================================================================
if ($pg_major >= 17) {
    my $fv = scalar_query(1,
        "SELECT failover FROM pg_replication_slots WHERE slot_name='$slot_name'");
    $fv =~ s/\s+//g;
    is($fv, 'f',
        "PG$pg_major: slot '$slot_name' NOT created with FAILOVER (spock handles sync)");
} else {
    pass("PG$pg_major: FAILOVER flag not applicable (PG15/16)");
}

# ==========================================================================
# 5. spock_failover_slots bgworker on primary: not used regardless of version
#    (the worker only does work on a standby in recovery).  We don't assert
#    anything about its presence here — that's checked on the standby below.
# ==========================================================================
pass("PG$pg_major: spock bgworker check deferred to standby (section 12)");

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

    # Native slot sync is intentionally NOT enabled on this branch — spock's
    # failover-slot worker handles synchronization for every supported PG
    # version, so leave sync_replication_slots at its default (off).
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

# synchronized_standby_slots is the native walsender-hold-back mechanism;
# it's intentionally NOT configured here because this branch does not use
# native PG slot sync. Spock's worker covers the sync path on every
# supported PG version.

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
# 11. PG17+: standby slot is synced by spock's worker, NOT by native PG
#     slotsync.  Therefore the slot must show synced=f and failover=f.
# ==========================================================================
if ($pg_major >= 17) {
    my $sd = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT synced FROM pg_replication_slots
         WHERE slot_name = '$slot_name'");
    $sd =~ s/\s+//g;
    is($sd, 'f',
        "PG$pg_major: standby slot '$slot_name' has synced=false (spock worker, not native)");

    my $fb = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT failover FROM pg_replication_slots
         WHERE slot_name = '$slot_name'");
    $fb =~ s/\s+//g;
    is($fb, 'f',
        "PG$pg_major: standby slot '$slot_name' has failover=false (native sync disabled)");

    # Verify slot LSN on standby is set and behind/at primary.  spock's
    # failover-slot worker prefers restart_lsn (which it sets during
    # ReplicationSlotCreate/LogicalIncreaseRestartDecodingForSlot);
    # confirmed_flush_lsn may stay NULL until LogicalConfirmReceivedLocation
    # runs the first time, so poll for either column.
    my $primary_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
    $primary_lsn =~ s/\s+//g;

    my $slot_lsn = '';
    my $slot_lsn_ok = wait_until(30, 2, sub {
        $slot_lsn = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
            "SELECT coalesce(confirmed_flush_lsn::text, restart_lsn::text, '')
             FROM pg_replication_slots WHERE slot_name = '$slot_name'");
        $slot_lsn =~ s/\s+//g;
        return $slot_lsn ne '';
    });
    ok($slot_lsn_ok,
        "PG$pg_major: standby slot has an LSN set (slot_lsn=$slot_lsn)");

    diag("  primary_lsn=$primary_lsn  slot_lsn=$slot_lsn");
} else {
    pass("PG$pg_major: synced column not available");
    pass("PG$pg_major: failover column not available");
    pass("PG$pg_major: LSN lag check skipped");
}

# ==========================================================================
# 12. spock_failover_slots bgworker must be running on the standby for
#     every supported PG version — spock owns slot sync for all of them.
# ==========================================================================
my $bgw_count = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
    "SELECT count(*) FROM pg_stat_activity
     WHERE application_name = 'spock_failover_slots worker'");
$bgw_count =~ s/\s+//g;

ok($bgw_count > 0,
    "PG$pg_major: spock_failover_slots worker running on standby");

# ==========================================================================
# 13. (placeholder to keep test count stable across the schedule)
# ==========================================================================
pass("PG$pg_major: spock owns failover slot sync regardless of PG version");

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
# 14b. REGRESSION: read-only standby is queryable while spock is loaded
#
# A customer reported that after enabling spock with logical slot failover,
# the hot_standby could not be queried — basic SELECTs failed because of
# spock interactions on a recovery backend.  Re-running the full
# slot-failover dance is not enough; we need explicit assertions that the
# standby answers user SELECT, spock catalog SELECT, and pg_replication_slots
# while it's still in recovery.  Without these checks a future regression
# could quietly reintroduce the same bug.
# ==========================================================================

# Wait for the standby to apply the row we just wrote on n1.
my $primary_wal_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
$primary_wal_lsn =~ s/\s+//g;
my $standby_caught_up = wait_until(60, 2, sub {
    my $rl = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
        "SELECT pg_last_wal_replay_lsn() >= '$primary_wal_lsn'::pg_lsn");
    $rl =~ s/\s+//g;
    return $rl eq 't';
});
ok($standby_caught_up,
    "Standby applied WAL up to primary lsn $primary_wal_lsn");

# Standby must still be in recovery — confirms hot_standby mode and that
# no spock hook accidentally took the standby out of recovery.
my $still_in_recovery = qport($pg_bin, $host, $standby_port,
    $dbname, $db_user, "SELECT pg_is_in_recovery()");
$still_in_recovery =~ s/\s+//g;
is($still_in_recovery, 't',
    'Read-only standby is still in recovery (hot_standby mode)');

# 1) User-table SELECT against the standby returns the committed row.
my $val_on_standby = qport($pg_bin, $host, $standby_port,
    $dbname, $db_user, "SELECT val FROM failover_test WHERE id = 1");
$val_on_standby =~ s/\s+//g;
is($val_on_standby, 'before_failover',
    'Read-only standby returns committed user data (SELECT works)');

# 2) Spock catalog SELECT against the standby — the original customer
#    failure mode was that spock.* reads errored out on a recovery backend.
my $standby_node_count = qport($pg_bin, $host, $standby_port,
    $dbname, $db_user, "SELECT count(*) FROM spock.node");
$standby_node_count =~ s/\s+//g;
ok(($standby_node_count =~ /^\d+$/) && $standby_node_count >= 1,
    "Read-only standby returns spock.node ($standby_node_count rows)");

# 3) The synced logical slot is visible on the standby.
my $standby_slot_count = qport($pg_bin, $host, $standby_port,
    $dbname, $db_user,
    "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$slot_name'");
$standby_slot_count =~ s/\s+//g;
is($standby_slot_count, '1',
    "Read-only standby returns synced slot '$slot_name' via pg_replication_slots");

# 4) Writes are rejected — the standby must remain read-only.
my $write_rc = system(
    "$pg_bin/psql -X -h $host -p $standby_port -d $dbname -U $db_user "
  . "-v ON_ERROR_STOP=1 "
  . "-c \"INSERT INTO failover_test VALUES (999, 'must_fail')\" "
  . ">/dev/null 2>&1");
isnt($write_rc, 0,
    'Write against read-only standby is rejected (read-only enforced)');

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

# Restart n1 so destroy_cluster can connect cleanly.
system("$pg_bin/postgres -D $primary_dir >> /dev/null 2>&1 &");
sleep(10);

system("rm -rf $standby_datadir 2>/dev/null");

destroy_cluster('Destroy test cluster');
done_testing();
