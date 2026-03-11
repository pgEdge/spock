use strict;
use warnings;
use Test::More tests => 9;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config psql_or_bail);

# =============================================================================
# Test: 800_standby_hot_standby_feedback.pl
# =============================================================================
# Verifies that the spock_failover_slots worker does NOT flood the log
# with repeated ERROR messages when hot_standby_feedback is off on a
# physical standby, and that after enabling the GUC and reloading the
# worker picks up the change and begins synchronizing slots.
#
# Previously the worker called synchronize_failover_slots() on every
# cycle regardless of hot_standby_feedback, producing:
#
#   ERROR: cannot synchronize replication slot positions because
#          hot_standby_feedback is off
#
# and restarting every 60 seconds.  The fix gates the call on the GUC
# so the worker simply sleeps when it is off.

# ---------- primary setup ----------

create_cluster(1, 'Create primary node');

my $config       = get_test_config();
my $primary_port = $config->{node_ports}[0];
my $host         = $config->{host};
my $dbname       = $config->{db_name};
my $db_user      = $config->{db_user};
my $pg_bin       = $config->{pg_bin};

# Create a physical replication slot for the standby to use.
# The failover_slots worker requires primary_slot_name to be set
# (i.e. WalRcv->slotname must be non-empty) before it will attempt
# slot synchronization.
psql_or_bail(1, "SELECT pg_create_physical_replication_slot('standby_slot')");

# ---------- physical standby via pg_basebackup ----------

my $standby_port    = $primary_port + 8;
my $standby_datadir = '/tmp/tmp_spock_standby_datadir';
my $standby_logdir  = "$standby_datadir/pg_log";
my $standby_logname = 'standby.log';
my $standby_logpath = "$standby_logdir/$standby_logname";

# Clean up any leftovers from a previous run
system("rm -rf $standby_datadir 2>/dev/null");

# -R writes standby.signal and primary_conninfo into postgresql.auto.conf
system_or_bail("$pg_bin/pg_basebackup",
    '-D', $standby_datadir,
    '-h', $host, '-p', $primary_port, '-U', $db_user,
    '-X', 'stream', '-R');
pass('Physical standby created via pg_basebackup');

# Override standby configuration:
#   - Different port
#   - hot_standby_feedback explicitly OFF (the scenario under test)
#   - primary_slot_name so the wal receiver uses our slot
#   - Dedicated log directory so we can inspect it
system_or_bail('mkdir', '-p', $standby_logdir);
{
    open(my $conf, '>>', "$standby_datadir/postgresql.conf")
        or die "Cannot open standby postgresql.conf: $!";
    print $conf "\n# ---- standby overrides for test ----\n";
    print $conf "port = $standby_port\n";
    print $conf "hot_standby = on\n";
    print $conf "hot_standby_feedback = off\n";
    print $conf "primary_slot_name = 'standby_slot'\n";
    print $conf "log_directory = '$standby_logdir'\n";
    print $conf "log_filename = '$standby_logname'\n";
    print $conf "log_min_messages = debug1\n";
    close($conf);
}

# Start the standby (pg_ctl -w waits until server is ready)
system_or_bail("$pg_bin/pg_ctl", 'start', '-D', $standby_datadir,
    '-l', "$standby_datadir/startup.log", '-w');

# ---------- verify the standby is functional ----------

command_ok(["$pg_bin/pg_isready", '-h', $host, '-p', $standby_port],
    'Standby is accepting connections');

my $in_recovery = `$pg_bin/psql -X -h $host -p $standby_port -d $dbname -U $db_user -t -c "SELECT pg_is_in_recovery()"`;
$in_recovery =~ s/\s+//g;
is($in_recovery, 't', 'Standby is in recovery mode');

# ==========================================================================
# Phase 1 — hot_standby_feedback = off: worker must NOT error
# ==========================================================================
# The worker starts immediately and iterates every WORKER_NAP_TIME (60 s).
# With the old bug it would elog(ERROR) on the first cycle as soon as the
# wal receiver connects, then restart after bgw_restart_time (60 s).
# Sleeping 30 s is enough to catch at least the first ERROR.

system_or_bail('sleep', '30');

my $error_count = 0;
if (-f $standby_logpath) {
    open(my $fh, '<', $standby_logpath)
        or die "Cannot read standby log: $!";
    while (<$fh>) {
        $error_count++
            if /cannot synchronize replication slot positions because hot_standby_feedback is off/;
    }
    close($fh);
} else {
    diag("Standby log not found at $standby_logpath - checking startup log");
    my $startup_log = "$standby_datadir/startup.log";
    if (-f $startup_log) {
        open(my $fh, '<', $startup_log)
            or die "Cannot read startup log: $!";
        while (<$fh>) {
            $error_count++
                if /cannot synchronize replication slot positions because hot_standby_feedback is off/;
        }
        close($fh);
    }
}
is($error_count, 0,
    'No "hot_standby_feedback is off" ERROR in standby log');

# ==========================================================================
# Phase 2 — enable hot_standby_feedback and SIGHUP: worker must sync
# ==========================================================================
# After the user sets hot_standby_feedback = on and reloads, the worker
# should wake from its latch wait (SIGHUP sets the latch), pick up the
# new GUC value, and call synchronize_failover_slots() which logs
# "starting replication slot synchronization from primary" at DEBUG1.

system_or_bail("$pg_bin/psql", '-X', '-h', $host, '-p', $standby_port,
    '-d', $dbname, '-U', $db_user, '-c',
    "ALTER SYSTEM SET hot_standby_feedback = on");

system_or_bail("$pg_bin/psql", '-X', '-h', $host, '-p', $standby_port,
    '-d', $dbname, '-U', $db_user, '-c',
    "SELECT pg_reload_conf()");

# SIGHUP wakes the worker immediately; give it a few seconds to connect
# to the primary and run the sync cycle.
system_or_bail('sleep', '15');

my $sync_found = 0;
if (-f $standby_logpath) {
    open(my $fh, '<', $standby_logpath)
        or die "Cannot read standby log: $!";
    while (<$fh>) {
        $sync_found++
            if /starting replication slot synchronization from primary/;
    }
    close($fh);
}
ok($sync_found > 0,
    'Failover slot synchronization ran after enabling hot_standby_feedback');

# ---------- cleanup ----------

system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate 2>/dev/null");
system_or_bail('sleep', '3');
system("rm -rf $standby_datadir");

destroy_cluster('Destroy primary node');

done_testing();
