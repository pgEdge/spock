use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config system_or_bail command_ok system_maybe
    psql_or_bail scalar_query apply_worker_pid
);
use Time::HiRes qw(time);

# =============================================================================
# Test: 124_sync_standby_feedback_hold.pl
#
# Regression test for the apply worker reporting flush/apply feedback beyond
# what its synchronous physical standby has flushed (GitHub issue #636).
#
# Topology: n1 (publisher) --logical--> n2 (subscriber) --physical--> standby
#
# While the standby's walreceiver is frozen (SIGSTOP), a change committed on
# n1 is applied on n2 but cannot be confirmed by the standby.  The publisher's
# slot confirmed_flush_lsn must therefore NOT advance past that change.  Once
# the standby resumes, the slot must catch up.
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
    "SELECT pg_create_physical_replication_slot('n2_hold_slot')");
pass('Physical replication slot created on n2 for sync standby');

# ==========================================================================
# 4. Build a physical standby of n2 via pg_basebackup
# ==========================================================================
my $standby_port    = $subscriber_port + 20;
my $standby_datadir = '/tmp/tmp_spock_sync_hold_standby';
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
    print $conf "primary_slot_name    = 'n2_hold_slot'\n";
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
# 7. Baseline: with a healthy standby the slot advances past a new row
# ==========================================================================
psql_or_bail(1, "CREATE TABLE hold_test (id int PRIMARY KEY, v text)");
sleep(3);
psql_or_bail(1, "INSERT INTO hold_test VALUES (1, 'baseline')");
my $base_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
$base_lsn =~ s/\s+//g;

my $slot_where = "slot_type = 'logical' AND slot_name LIKE 'spk_${dbname}_n1_%'";

my $caught_up = wait_until(60, 1, sub {
    my $r = scalar_query(1,
        "SELECT bool_and(confirmed_flush_lsn >= '$base_lsn'::pg_lsn) "
      . "FROM pg_replication_slots WHERE $slot_where");
    $r =~ s/\s+//g;
    return $r eq 't';
});
ok($caught_up, 'baseline: publisher slot advances while standby is healthy');

# ==========================================================================
# 8. Freeze the standby's walreceiver so it cannot flush anything
# ==========================================================================
our $wr_pid = qport($pg_bin, $host, $standby_port, $dbname, $db_user,
    "SELECT pid FROM pg_stat_wal_receiver");
$wr_pid =~ s/\s+//g;
ok($wr_pid =~ /^\d+$/, "found standby walreceiver pid ($wr_pid)");
# Never leave the walreceiver stopped if the test dies early.
my $wr_stopped = 1;
END { kill('CONT', $wr_pid) if $wr_stopped && defined $wr_pid && $wr_pid =~ /^\d+$/; }
kill('STOP', $wr_pid);

psql_or_bail(1, "INSERT INTO hold_test VALUES (2, 'held')");
my $held_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
$held_lsn =~ s/\s+//g;

# Row is applied locally on n2 (apply worker does not wait on the standby)
my $applied = wait_until(30, 1, sub {
    my $v = scalar_query(2, "SELECT v FROM hold_test WHERE id = 2");
    $v =~ s/\s+//g;
    return $v eq 'held';
});
ok($applied, 'held row applied locally on n2');

# Let several feedback cycles pass
sleep(12);

my $advanced = scalar_query(1,
    "SELECT bool_or(confirmed_flush_lsn >= '$held_lsn'::pg_lsn) "
  . "FROM pg_replication_slots WHERE $slot_where");
$advanced =~ s/\s+//g;
is($advanced, 'f',
    'publisher slot did NOT advance past a change the sync standby has not flushed');

# ==========================================================================
# 8b. Restart the apply worker while the commit is still held.  The
#     replacement resumes from the local origin, which already includes the
#     held commit, but must not report it to the publisher yet.
# ==========================================================================
my $old_apply = apply_worker_pid(2, 'sub_n2_n1', 20);
ok($old_apply, "found apply worker pid ($old_apply)");
psql_or_bail(2, "SELECT pg_terminate_backend($old_apply)");
my $new_apply = wait_until(60, 1, sub {
    my $p = apply_worker_pid(2, 'sub_n2_n1', 1);
    return $p && $p ne $old_apply;
});
ok($new_apply, 'apply worker restarted');

sleep(12);

my $advanced2 = scalar_query(1,
    "SELECT bool_or(confirmed_flush_lsn >= '$held_lsn'::pg_lsn) "
  . "FROM pg_replication_slots WHERE $slot_where");
$advanced2 =~ s/\s+//g;
is($advanced2, 'f',
    'publisher slot did NOT advance past the held change after an apply worker restart');

# ==========================================================================
# 9. Resume the standby: the slot must catch up
# ==========================================================================
kill('CONT', $wr_pid);
$wr_stopped = 0;

# The apply worker retries the release on its 1s wakeup, so the slot must
# catch up promptly and not only on the next publisher keepalive.
my $resumed = wait_until(15, 1, sub {
    my $r = scalar_query(1,
        "SELECT bool_and(confirmed_flush_lsn >= '$held_lsn'::pg_lsn) "
      . "FROM pg_replication_slots WHERE $slot_where");
    $r =~ s/\s+//g;
    return $r eq 't';
});
ok($resumed, 'publisher slot advances after the sync standby resumes');

# ==========================================================================
# Cleanup
# ==========================================================================
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
