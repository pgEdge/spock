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
# Test: 020_sync_standby_feedback_lsn.pl
#
# Regression test for "spock_apply: do not send local LSN as publisher
# feedback on sync-standby".
#
# Topology:
#   n1 (publisher)         ---logical---> n2 (subscriber)
#                                          ^
#                                          |  physical streaming
#                                          |  synchronous_standby_names
#                                       n2_standby
#
# Bug:
#   When the subscriber had a synchronous physical standby attached, the
#   apply worker queued the subscriber's local XactLastCommitEnd as the
#   "remote" position in the feedback message and later sent it to the
#   publisher as the slot's confirmed flush position.  The two LSNs are
#   from different WAL streams, so the publisher wrote a meaningless value
#   into the slot's confirmed_flush_lsn -- typically far ahead of the
#   publisher's own pg_current_wal_lsn.
#
# Assertion (symptom-level, sufficient to catch regression):
#   Publisher's pg_replication_slots.confirmed_flush_lsn must never exceed
#   the publisher's pg_current_wal_lsn while replication is healthy.
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
# 1. Create 2-node Spock cluster
# ==========================================================================
create_cluster(2, 'Create 2-node Spock cluster');

my $config         = get_test_config();
my $host           = $config->{host};
my $dbname         = $config->{db_name};
my $db_user        = $config->{db_user};
my $db_password    = $config->{db_password};
my $pg_bin         = $config->{pg_bin};
my $node_ports     = $config->{node_ports};
my $node_dirs      = $config->{node_datadirs};
my $publisher_port = $node_ports->[0];     # n1
my $subscriber_port = $node_ports->[1];    # n2
my $subscriber_dir = $node_dirs->[1];

# ==========================================================================
# 2. Create subscription n2 -> n1
# ==========================================================================
psql_or_bail(2, "SELECT spock.sub_create(
    'sub_n2_n1',
    'host=$host dbname=$dbname port=$publisher_port user=$db_user password=$db_password',
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
# 3. Create a physical replication slot on n2 for the sync standby
# ==========================================================================
psql_or_bail(2,
    "SELECT pg_create_physical_replication_slot('n2_sync_slot')");
pass('Physical replication slot created on n2 for sync standby');

# ==========================================================================
# 4. Build a physical standby of n2 via pg_basebackup
# ==========================================================================
my $standby_port    = $subscriber_port + 20;
my $standby_datadir = '/tmp/tmp_spock_sync_standby';
my $standby_logdir  = "$standby_datadir/pg_log";

system("rm -rf $standby_datadir 2>/dev/null");
system_or_bail("$pg_bin/pg_basebackup",
    '-D', $standby_datadir,
    '-h', $host, '-p', $subscriber_port, '-U', $db_user,
    '-X', 'stream', '-R');
pass('Physical standby of n2 created via pg_basebackup');

# ==========================================================================
# 5. Configure standby
# ==========================================================================
system_or_bail('mkdir', '-p', $standby_logdir);
{
    open(my $conf, '>>', "$standby_datadir/postgresql.conf")
        or die "Cannot open standby postgresql.conf: $!";
    print $conf "\n# ---- sync standby overrides ----\n";
    print $conf "port                 = $standby_port\n";
    print $conf "hot_standby          = on\n";
    print $conf "hot_standby_feedback = on\n";
    print $conf "primary_slot_name    = 'n2_sync_slot'\n";
    print $conf "log_directory        = '$standby_logdir'\n";
    print $conf "log_filename         = 'standby.log'\n";
    close($conf);
}

system_or_bail("$pg_bin/pg_ctl", 'start',
    '-D', $standby_datadir, '-l', "$standby_datadir/startup.log", '-w');
command_ok(["$pg_bin/pg_isready", '-h', $host, '-p', $standby_port],
    'Sync standby is accepting connections');

my $in_recovery = qport($pg_bin, $host, $standby_port,
    $dbname, $db_user, "SELECT pg_is_in_recovery()");
is($in_recovery, 't', 'Sync standby is in recovery (streaming from n2)');

# ==========================================================================
# 6. Configure n2 with synchronous_standby_names pointing at the standby
# ==========================================================================
# Wait for the standby walreceiver to register so synchronous_standby_names
# actually has someone to wait on (otherwise commits block forever).
my $standby_registered = wait_until(30, 2, sub {
    my $c = scalar_query(2,
        "SELECT count(*) FROM pg_stat_replication WHERE application_name = 'walreceiver'");
    $c =~ s/\s+//g;
    return $c > 0;
});
ok($standby_registered, 'n2_standby walreceiver is registered on n2');

psql_or_bail(2, "ALTER SYSTEM SET synchronous_standby_names = 'walreceiver'");
# synchronous_commit = 'on' is the default and already means "wait for the
# named standbys to flush"; we only need to set it explicitly if the cluster
# config has overridden it.
psql_or_bail(2, "ALTER SYSTEM SET synchronous_commit = 'on'");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(2);

my $ssn = scalar_query(2, "SHOW synchronous_standby_names");
$ssn =~ s/\s+//g;
is($ssn, 'walreceiver',
    'n2 synchronous_standby_names = walreceiver');

# ==========================================================================
# 7. Generate traffic from n1 and let it flow through n2 (with sync wait)
# ==========================================================================
psql_or_bail(1,
    "CREATE TABLE IF NOT EXISTS feedback_test (id int PRIMARY KEY, v text)");
sleep(3);

# Insert a batch of rows on the publisher; each commit on n2 will block
# until the sync standby has flushed, exercising the feedback queue.
for my $i (1 .. 20) {
    psql_or_bail(1, "INSERT INTO feedback_test VALUES ($i, 'row_$i')");
}

# Wait until the last row is visible on n2
my $applied = wait_until(60, 2, sub {
    my $v = scalar_query(2, "SELECT v FROM feedback_test WHERE id = 20");
    $v =~ s/\s+//g;
    return $v eq 'row_20';
});
ok($applied, 'All 20 rows replicated n1 -> n2');

# ==========================================================================
# 8. Force the apply worker to send a feedback message so the publisher's
#    confirmed_flush_lsn is up-to-date with whatever the subscriber is
#    reporting (good or bad).  A keepalive cycle is enough; sleeping
#    longer than the default wal_receiver_status_interval covers it.
# ==========================================================================
sleep(12);

# ==========================================================================
# 9. ASSERTION: publisher's slot confirmed_flush_lsn must not exceed
#    publisher's current_wal_lsn.  Before the fix the subscriber sent its
#    local commit LSN, which lives in a different WAL stream and was
#    typically far ahead of n1's own WAL position.
# ==========================================================================
my $cmp = scalar_query(1, "
    SELECT
        s.slot_name,
        pg_wal_lsn_diff(pg_current_wal_lsn(), s.confirmed_flush_lsn) AS slack_bytes,
        (s.confirmed_flush_lsn <= pg_current_wal_lsn()) AS ok
    FROM pg_replication_slots s
    WHERE s.slot_type = 'logical'
      AND s.slot_name LIKE 'spk_${dbname}_n1_%'
");
diag("  publisher slot vs current_wal_lsn: $cmp");

my $slot_ok = scalar_query(1, "
    SELECT bool_and(s.confirmed_flush_lsn <= pg_current_wal_lsn())
    FROM pg_replication_slots s
    WHERE s.slot_type = 'logical'
      AND s.slot_name LIKE 'spk_${dbname}_n1_%'
");
$slot_ok =~ s/\s+//g;
is($slot_ok, 't',
    "publisher's confirmed_flush_lsn <= pg_current_wal_lsn (sync-standby feedback "
  . "uses REMOTE LSN, not local)");

# Additional sanity: confirmed_flush_lsn must be > 0 (we did apply work)
my $cf_nonzero = scalar_query(1, "
    SELECT bool_and(s.confirmed_flush_lsn > '0/0'::pg_lsn)
    FROM pg_replication_slots s
    WHERE s.slot_type = 'logical'
      AND s.slot_name LIKE 'spk_${dbname}_n1_%'
");
$cf_nonzero =~ s/\s+//g;
is($cf_nonzero, 't',
    "publisher's confirmed_flush_lsn advanced past 0/0 (feedback is flowing)");

# ==========================================================================
# 10. Failover scenario the original bug surfaced through: stop the
#     subscriber, promote its sync standby, and verify no writes from the
#     publisher are missing.  Before the fix the publisher's slot was
#     poisoned with a subscriber-local LSN, so after promotion the new
#     primary would resume from a wrong position and silently drop the
#     window of recent commits.
# ==========================================================================
psql_or_bail(1, "INSERT INTO feedback_test SELECT g, 'pre_failover_'||g "
              . "FROM generate_series(21, 40) g");

my $pre_failover_applied = wait_until(60, 2, sub {
    my $v = scalar_query(2, "SELECT v FROM feedback_test WHERE id = 40");
    $v =~ s/\s+//g;
    return $v eq 'pre_failover_40';
});
ok($pre_failover_applied, 'pre-failover batch (ids 21..40) replicated to n2');

my $expected_count = scalar_query(1,
    "SELECT count(*) FROM feedback_test");
$expected_count =~ s/\s+//g;

# Wait briefly for n2_standby to flush the latest commits (synchronous
# replication makes this almost immediate, but a small grace handles the
# walreceiver round-trip).
sleep(2);

# Stop the subscriber (n2).  Use fast shutdown so the apply worker exits
# cleanly before the standby is promoted.
diag("Stopping n2 (subscriber) to simulate failover...");
system("$pg_bin/pg_ctl stop -D $node_dirs->[1] -m fast >> /dev/null 2>&1");
sleep(3);

diag("Promoting n2_standby...");
system("$pg_bin/pg_ctl promote -D $standby_datadir >> /dev/null 2>&1");

my $promoted = wait_until(30, 2, sub {
    my $r = qport($pg_bin, $host, $standby_port,
                  $dbname, $db_user, "SELECT pg_is_in_recovery()");
    $r =~ s/\s+//g;
    return $r eq 'f';
});
ok($promoted, 'n2_standby promoted to primary (no longer in recovery)');

# The decisive check: every row the publisher committed before the failover
# must be present on the promoted standby.  With the bug, the publisher's
# slot.confirmed_flush_lsn pointed at a subscriber-local LSN; after
# promotion the new primary would resume from there and miss recent
# commits.  With the fix, confirmed_flush_lsn tracks the publisher's WAL,
# so every committed row is durable on the standby before failover.
my $standby_count = qport($pg_bin, $host, $standby_port,
                          $dbname, $db_user,
                          "SELECT count(*) FROM feedback_test");
$standby_count =~ s/\s+//g;
is($standby_count, $expected_count,
    "promoted standby has all $expected_count publisher rows "
  . "(no writes lost across failover)");

# Spot-check the boundary rows so a wrong count is not masked by an off-by-one
my $boundary_ok = qport($pg_bin, $host, $standby_port,
                        $dbname, $db_user,
                        "SELECT bool_and(v IS NOT NULL) FROM feedback_test "
                      . "WHERE id IN (1, 20, 21, 40)");
$boundary_ok =~ s/\s+//g;
is($boundary_ok, 't',
    'promoted standby has the first, last, and failover-boundary rows');

# Stop the promoted standby so destroy_cluster can run; n2 is already down.
system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >> /dev/null 2>&1");

# Restart n2 so destroy_cluster can connect cleanly (matches 018's pattern).
system("$pg_bin/postgres -D $node_dirs->[1] >> /dev/null 2>&1 &");
sleep(10);

# ==========================================================================
# Cleanup
# ==========================================================================

# Undo synchronous_standby_names on n2 so destroy_cluster can stop n2 cleanly
# even if we kill the standby first.
system_maybe("$pg_bin/psql", '-h', $host, '-p', $subscriber_port,
    '-d', $dbname, '-U', $db_user,
    '-c', "ALTER SYSTEM RESET synchronous_standby_names");
system_maybe("$pg_bin/psql", '-h', $host, '-p', $subscriber_port,
    '-d', $dbname, '-U', $db_user,
    '-c', "ALTER SYSTEM RESET synchronous_commit");
system_maybe("$pg_bin/psql", '-h', $host, '-p', $subscriber_port,
    '-d', $dbname, '-U', $db_user,
    '-c', "SELECT pg_reload_conf()");

system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >> /dev/null 2>&1");
system("rm -rf $standby_datadir 2>/dev/null");

destroy_cluster('Destroy test cluster');
done_testing();
