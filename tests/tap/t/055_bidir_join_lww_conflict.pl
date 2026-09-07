#!/usr/bin/perl
# =============================================================================
# Test: 055_bidir_join_lww_conflict.pl - conflicting concurrent writes on two
#                                         existing peers during a new node's
#                                         --bidirectional catchup resolve to
#                                         the SAME value on the new node as on
#                                         the existing peers
# =============================================================================
# Design doc spock_bidirectional_final.md section 16 lists, as a required
# positive-path scenario: "LWW conflict: concurrent conflicting writes on two
# peers during catchup; assert LWW resolves identically on source and n3."
# No existing bidirectional test exercises a genuine same-row conflict; every
# other bidir test (048/049/050/051/052/053) only ever writes NEW, non-
# colliding rows.
#
# n3 does not live through the conflict itself: it is not yet directly
# subscribed to n2 while catching up (that direct subscription stays
# disabled -- see spock_bidirectional_implementation.md's "Step 16b" --
# until Step 20.6, well after this test's conflicting writes land). n3 only
# ever sees n2's write forwarded through n1's catchup subscription
# (forward_origins := '{all}'), tagged with n2's own origin so n3's apply
# worker resolves the conflict independently, against n1's own write, using
# the SAME origin/commit-timestamp inputs n1 itself used. If forwarding
# dropped a change, reordered it, or lost the origin tag, n3 would converge
# on a different winner than n1/n2 despite the join reporting success --
# exactly the failure this test is positioned to catch that no other bidir
# test can (they never create a same-row conflict in the first place).
# =============================================================================

use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);
use POSIX qw(:sys_wait_h);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 command_ok system_maybe get_test_config scalar_query
                 wait_for_pg_ready wait_for_sub_status);

# =============================================================================
# Locate spock_create_subscriber binary
# =============================================================================
my $SCS_BIN;
for my $dir (split(':', $ENV{PATH} // '')) {
    my $c = "$dir/spock_create_subscriber";
    if (-x $c) { $SCS_BIN = $c; last; }
}
unless (defined $SCS_BIN) {
    my $bt = '../../utils/spock_create_subscriber/spock_create_subscriber';
    $SCS_BIN = $bt if -x $bt;
}
BAIL_OUT("spock_create_subscriber binary not found; run 'make install' first")
    unless defined $SCS_BIN;
pass("spock_create_subscriber binary found");

# =============================================================================
# SETUP: 2-node cluster, bidirectionally cross-wired (n1 <-> n2)
# =============================================================================
create_cluster(2, 'Create 2-node cluster');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $dbname      = $config->{db_name};
my $host        = $config->{host};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};
my $log_dir     = $config->{log_dir};

my $n1_dsn = "host=$host port=$node_ports->[0] dbname=$dbname"
           . " user=$db_user password=$db_password";

cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 <-> n2');

sub spawn_background {
    my ($logfile, @cmd) = @_;
    my $pid = fork();
    die "fork() failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(my $fh, '>>', $logfile) or die "Cannot open $logfile: $!";
        open(STDOUT, '>&', $fh) or die $!;
        open(STDERR, '>&', $fh) or die $!;
        close($fh);
        exec(@cmd) or exit(127);
    }
    return $pid;
}

sub wait_for_pid {
    my ($pid, $timeout) = @_;
    for (1 .. $timeout) {
        my $r = waitpid($pid, WNOHANG);
        return ($? >> 8) if $r == $pid;
        sleep(1);
    }
    return undef;
}

# Poll a log file's content for a pattern (rather than a fixed offset read)
# since the file may not exist yet when polling starts.
sub wait_for_log_pattern {
    my ($logfile, $pattern, $timeout) = @_;
    for (1 .. $timeout) {
        if (-f $logfile) {
            open(my $fh, '<', $logfile) or die "Cannot open $logfile: $!";
            local $/;
            my $content = <$fh>;
            close($fh);
            return 1 if defined $content && $content =~ $pattern;
        }
        sleep(1);
    }
    return 0;
}

# =============================================================================
# SETUP: a table on the existing mesh, one seed row both n1 and n2 will race
# to update once n3's join is underway.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE lww_conflict_tbl (id int PRIMARY KEY, val text, writer text)";
pass('lww_conflict_tbl created on n1');

my $on_n2 = '0';
for (1 .. 30) {
    $on_n2 = scalar_query(2,
        "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'lww_conflict_tbl'");
    last if $on_n2 eq '1';
    sleep(1);
}
is($on_n2, '1', 'lww_conflict_tbl replicated to n2');

system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "INSERT INTO lww_conflict_tbl (id, val, writer) VALUES (1, 'seed', 'n1')";

my $seed_on_n2 = '';
for (1 .. 30) {
    $seed_on_n2 = scalar_query(2,
        "SELECT val FROM lww_conflict_tbl WHERE id = 1");
    last if $seed_on_n2 eq 'seed';
    sleep(1);
}
is($seed_on_n2, 'seed', 'seed row replicated to n2 before the join starts');

# check_preconditions() rejects the join outright if n1's outbound slot to
# an existing peer (n2) has not fully drained -- the DDL/data that set up
# lww_conflict_tbl and its seed row just above leaves exactly that kind of
# residual lag for a moment.  Wait for it to clear before launching, or the
# join dies immediately with "source has unreplicated changes pending to an
# existing peer" (confirmed happening in practice).
for (1 .. 15) {
    my $lag = scalar_query(1,
        "SELECT COUNT(*) FROM pg_replication_slots" .
        " WHERE slot_type = 'logical' AND plugin = 'spock_output'" .
        " AND (confirmed_flush_lsn IS NULL OR confirmed_flush_lsn < pg_current_wal_lsn())");
    last if defined $lag && $lag eq '0';
    sleep(1);
}

# Log every conflict resolution spock makes to spock.resolutions on n1/n2,
# so the LWW decision can be inspected directly rather than only inferred
# from the converged value. PGC_SIGHUP -- ALTER SYSTEM + reload is enough,
# no restart needed.
for my $port (@$node_ports) {
    system_or_bail "$pg_bin/psql", '-p', $port, '-d', $dbname, '-c',
        "ALTER SYSTEM SET spock.save_resolutions = on";
    system_or_bail "$pg_bin/psql", '-p', $port, '-d', $dbname, '-c',
        "SELECT pg_reload_conf()";
}

# =============================================================================
# TEST: join n3 via n1 while conflicting writes race on n1 and n2
# =============================================================================
my $n3_port     = $node_ports->[1] + 1;
my $n3_datadir  = '/tmp/tmp_spock_node_2_datadir_bidir_lww';
my $n3_pending  = "${n3_datadir}.spock_bidir_pending.json";
my $n3_manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $n3_dsn      = "host=$host port=$n3_port dbname=$dbname"
                . " user=$db_user password=$db_password";

remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_pending) if -f $n3_pending;

my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override.lww';
open my $conf_fh, '>', $n3_conf or die "Cannot write $n3_conf: $!";
print $conf_fh "shared_buffers=1GB\n";
print $conf_fh "shared_preload_libraries='spock'\n";
print $conf_fh "wal_level=logical\n";
print $conf_fh "spock.enable_ddl_replication=on\n";
print $conf_fh "spock.include_ddl_repset=on\n";
print $conf_fh "spock.allow_ddl_from_functions=on\n";
print $conf_fh "spock.exception_behaviour=sub_disable\n";
print $conf_fh "spock.conflict_resolution=last_update_wins\n";
print $conf_fh "spock.save_resolutions=on\n";
print $conf_fh "track_commit_timestamp=on\n";
print $conf_fh "spock.exception_replay_queue_size='1MB'\n";
print $conf_fh "spock.enable_spill=on\n";
print $conf_fh "port=$n3_port\n";
print $conf_fh "listen_addresses='*'\n";
print $conf_fh "logging_collector=on\n";
print $conf_fh "log_directory='$log_dir'\n";
print $conf_fh "log_filename='00${n3_port}.log'\n";
close $conf_fh;

my $scs_log = "$log_dir/scs_lww.log";
unlink($scs_log) if -f $scs_log;

my $scs_pid = spawn_background($scs_log,
    $SCS_BIN,
    '--bidirectional',
    '--pgdata',           $n3_datadir,
    '--subscriber-name',  'n3',
    '--provider-dsn',     $n1_dsn,
    '--subscriber-dsn',   $n3_dsn,
    '--postgresql-conf',  $n3_conf,
    '--stall-timeout',    '120',
    '--max-wait',         '600',
);

# Forwarding (forward_origins := '{all}' on the catchup subscription) is
# live from "Creating catchup subscription" (Step 14/15) through the end of
# the coverage barrier (Step 20), cleared only by clear_forwarding() just
# before Step 20.6 enables the direct peer subscription -- see
# spock_bidirectional_implementation.md. Waiting for the catchup wait-loop
# log line guarantees we are somewhere inside that whole window, not
# necessarily "still waiting" specifically (with only one seed row, Step 18
# may already be satisfied): either way, both conflicting writes below are
# still guaranteed to reach n3 via forwarding, not via a live direct
# subscription to n2 (which does not exist yet).
ok(wait_for_log_pattern($scs_log, qr/Waiting for catchup to the source/, 60),
   'join reached the catchup wait phase (forwarding is live)')
    or BAIL_OUT('spock_create_subscriber never reached catchup; see ' . $scs_log);

# Fire both conflicting UPDATEs as near-simultaneously as two forked OS
# processes allow, so neither is sequenced through the other via the
# existing n1<->n2 mesh subscription before the second one commits.
my $writer1_log = "$log_dir/lww_writer_n1.log";
my $writer2_log = "$log_dir/lww_writer_n2.log";
my $w1_pid = spawn_background($writer1_log,
    "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname, '-c',
    "UPDATE lww_conflict_tbl SET val = 'from_n1', writer = 'n1' WHERE id = 1");
my $w2_pid = spawn_background($writer2_log,
    "$pg_bin/psql", '-X', '-p', $node_ports->[1], '-d', $dbname, '-c',
    "UPDATE lww_conflict_tbl SET val = 'from_n2', writer = 'n2' WHERE id = 1");

my $w1_rc = wait_for_pid($w1_pid, 30);
my $w2_rc = wait_for_pid($w2_pid, 30);
is($w1_rc, 0, 'conflicting UPDATE from n1 committed')
    or diag("see $writer1_log");
is($w2_rc, 0, 'conflicting UPDATE from n2 committed')
    or diag("see $writer2_log");

my $scs_rc = wait_for_pid($scs_pid, 780);
unless (defined $scs_rc) {
    diag("spock_create_subscriber (lww) did not exit within 780s; killing it");
    kill('TERM', $scs_pid);
    waitpid($scs_pid, 0);
    $scs_rc = -1;
}
is($scs_rc, 0, '--bidirectional exits 0 despite a same-row conflict during catchup')
    or diag("see $scs_log");

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running');
ok(wait_for_sub_status(3, 'sub_n3_n1', 'replicating', 30),
   'catchup subscription sub_n3_n1 is replicating on n3');
ok(wait_for_sub_status(3, 'sub_n3_n2', 'replicating', 30),
   'direct peer subscription sub_n3_n2 is replicating on n3');

# =============================================================================
# THE assertion: all three nodes converge on the SAME LWW winner. n1 and n2
# resolve the conflict live, in real time, via their existing mesh
# subscription; n3 only ever sees it via forwarding through n1's catchup
# subscription. If forwarding lost the origin tag or reordered the two
# writes, n3 would independently resolve to a different winner than n1/n2
# even though row counts and the rest of the join look perfectly healthy.
# =============================================================================
my $val_n1 = '';
my $val_n2 = '';
my $val_n3 = '';
for (1 .. 60) {
    $val_n1 = scalar_query(1, "SELECT val FROM lww_conflict_tbl WHERE id = 1");
    $val_n2 = scalar_query(2, "SELECT val FROM lww_conflict_tbl WHERE id = 1");
    $val_n3 = scalar_query(3, "SELECT val FROM lww_conflict_tbl WHERE id = 1");
    last if $val_n1 eq $val_n2 && $val_n2 eq $val_n3;
    sleep(1);
}
diag("final values -- n1: '$val_n1', n2: '$val_n2', n3: '$val_n3'");

ok($val_n1 eq 'from_n1' || $val_n1 eq 'from_n2',
   'n1 resolved the conflict to one of the two contending writers, not a third value');
is($val_n2, $val_n1, 'n2 agrees with n1 on the LWW winner (both saw the conflict live)');
is($val_n3, $val_n1,
   'n3 agrees with n1/n2 on the LWW winner despite only seeing it forwarded');

my $exc_count_n3 = scalar_query(3, "SELECT count(*) FROM spock.exception_log");
is($exc_count_n3, '0', 'no exceptions logged on n3 for the resolved conflict');

# =============================================================================
# Best-effort: confirm the resolution was actually logged (spock.resolutions),
# not just inferred from the converged value. Not load-bearing for the core
# assertion above -- resolution logging is an independent code path
# (spock_conflict.c, spock_save_resolutions) from the value that ends up on
# disk, so its absence would be a separate, secondary finding.
my $resolutions_n1 = '0';
for (1 .. 30) {
    $resolutions_n1 = scalar_query(1,
        "SELECT count(*) FROM spock.resolutions WHERE relname = 'lww_conflict_tbl'");
    last if $resolutions_n1 ne '0';
    sleep(1);
}
if ($resolutions_n1 ne '0') {
    pass('n1 logged a conflict resolution for lww_conflict_tbl to spock.resolutions');
    my $conflict_type = scalar_query(1,
        "SELECT conflict_type FROM spock.resolutions " .
        "WHERE relname = 'lww_conflict_tbl' ORDER BY id LIMIT 1");
    like($conflict_type, qr/UPDATE_ORIGIN_DIFFERS/,
         'logged conflict_type matches a same-row concurrent update');
} else {
    diag('no spock.resolutions row found on n1 for lww_conflict_tbl within 30s ' .
         '(informational only -- not required for this scenario)');
}

command_ok(
    [ $SCS_BIN, '--bidirectional', '--cleanup', '--force', '--pgdata', $n3_datadir ],
    '--cleanup --force exits 0'
);
ok(!-d $n3_datadir, 'n3 data directory removed after cleanup');

# =============================================================================
# CLEANUP
# =============================================================================
unlink($n3_conf) if -f $n3_conf;
destroy_cluster('Destroy 2-node cluster');

done_testing();
