#!/usr/bin/perl
# =============================================================================
# Test: 106_lww_conflict_full_mesh.pl - a node resolving a conflict between
#                                        two *other* nodes' writes must agree
#                                        with what those two nodes themselves
#                                        resolved to
# =============================================================================
# spock_conflict.c's conflict_resolve_by_timestamp() used the applying
# node's own identity (get_local_node()) as one side of the last-update-wins
# tiebreaker comparison, instead of the local tuple's actual replication
# origin. The applying node is guaranteed to be one of the two conflicting
# writers in a two-node topology. With three or more nodes, it can instead
# resolve a conflict between two *other* nodes' writes: the existing row's
# origin is node A, the incoming change's origin is node B, and it is applying
# as node C. The buggy code
# compared C against B instead of A against B, and could pick the wrong
# writer's value -- disagreeing with what A and B themselves, comparing
# directly, already converged on.
#
# This does not require forwarding or relaying. It reproduces in a plain
# three-node multi-master topology where every node is directly subscribed
# to every other node and forward_origins remains empty. cross_wire() builds
# exactly this full mesh. Topology:
#
#   n1 <-> n2, n1 <-> n3, n2 <-> n3; no forwarding.
#
# A conflicting near-simultaneous UPDATE of the same row, fired from n1 and
# n2, must resolve to the SAME winner on all three nodes. n1 and n2 each
# compare the real pair of contending nodes directly; n3 -- applying a
# conflict between two nodes neither of which is itself -- must agree with
# them, not compare itself against one of them.
#
# Whether two independently-committed transactions on different nodes land
# in the exact same commit-timestamp tick is a scheduler- and clock-
# resolution-dependent race no test should rely on to reach the tiebreaker
# path: a correct build could still fail this test on an unlucky run, and a
# broken build could pass it on a run where every pair happened to be
# strictly timestamp-ordered. Attaching to the 'spock-conflict-force-tie'
# injection point (PostgreSQL core's injection_points test module, requires
# --enable-injection-points) makes every timestamp-based conflict
# resolution take the tiebreaker branch deterministically, regardless of
# the real commit timestamps, so this test never depends on the race. The
# whole test is skipped before PostgreSQL 18 or when the module is
# unavailable, rather than falling back to the racy behavior this exists to
# avoid.
# =============================================================================

use strict;
use warnings;
use Test::More;
use POSIX qw(:sys_wait_h);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 system_maybe scalar_query get_test_config psql_or_bail
                 wait_for_pg_ready
                 log_offset log_since);

my $config    = get_test_config();
my $pg_bin    = $config->{pg_bin};

my $pkglibdir = `"$pg_bin/pg_config" --pkglibdir`;
chomp $pkglibdir;
my $has_injection_points = (-e "$pkglibdir/injection_points.so")
    || (-e "$pkglibdir/injection_points.dylib");

# SPOCK_CONFLICT_TIE_FORCED() is compiled out entirely (always false) below
# PG18 -- IS_INJECTION_POINT_ATTACHED() doesn't exist in core before that --
# so the module being present isn't enough on its own: PG17 (and earlier)
# ships injection_points too, and would otherwise attach the point, run
# every trial, and still never force a tie, failing the tiebreaker-count
# assertion below instead of skipping cleanly.
my $pg_version_output = `"$pg_bin/pg_config" --version`;
my ($pg_major) = $pg_version_output =~ /(\d+)/;

plan skip_all =>
    "server not built with --enable-injection-points " .
    "(no injection_points test module in $pkglibdir) -- required to force " .
    "the deterministic tiebreaker tie this test depends on"
    unless $has_injection_points;

plan skip_all =>
    "SPOCK_CONFLICT_TIE_FORCED() is compiled out before PG18 (found PG$pg_major) " .
    "-- injection_points being installed doesn't help without it, and this " .
    "test's tiebreaker-count assertion would otherwise fail non-deterministically " .
    "instead of skipping cleanly"
    unless defined $pg_major && $pg_major >= 18;

# =============================================================================
# SETUP: 3-node cluster, full mesh (every node directly subscribed to every
# other node, forward_origins left at its default '{}').
# =============================================================================
create_cluster(3, 'Create 3-node cluster');
cross_wire(3, ['n1', 'n2', 'n3'],
           'Full mesh among n1, n2, and n3; no forwarding');

$config         = get_test_config();
my $node_ports  = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $dbname      = $config->{db_name};
my $log_dir     = $config->{log_dir};
my $log_file    = $config->{log_file};
my $host        = $config->{host};

# injection_points needs to be in shared_preload_libraries -- a postmaster-
# start GUC -- on every node, since each is a fully independent postgres
# instance with its own shared memory (no cluster-wide attachment).
for my $node_num (1, 2, 3) {
    my $datadir = $node_datadirs->[$node_num - 1];

    open(my $conf, '>>', "$datadir/postgresql.conf")
        or die "Cannot open $datadir/postgresql.conf: $!";
    print $conf "shared_preload_libraries='spock,injection_points'\n";
    close($conf);

    system_or_bail("$pg_bin/pg_ctl", '-D', $datadir, '-w', '-m', 'fast', 'stop');
    system("$pg_bin/postgres -D $datadir >> '$log_file' 2>&1 &");
    ok(wait_for_pg_ready($host, $node_ports->[$node_num - 1], $pg_bin, 30),
       "n$node_num restarted with injection_points preloaded");

    # spock's DDL replication can auto-propagate CREATE EXTENSION from
    # whichever node ran it first to the others before this loop reaches
    # them, so IF NOT EXISTS is required, not just defensive.
    psql_or_bail($node_num, "CREATE EXTENSION IF NOT EXISTS injection_points");
    psql_or_bail($node_num,
        "SELECT injection_points_attach('spock-conflict-force-tie', 'notice')");
}

sub psql_capture {
    my ($node_num, $sql) = @_;
    return scalar_query($node_num, $sql);
}

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

# =============================================================================
# SETUP: a conflict table, created once on n1. DDL replication propagates the
# CREATE TABLE to n2 and n3 automatically; cross_wire()'s mesh subscriptions
# already include the 'default' set, so no explicit repset_add_table() is
# needed.
# =============================================================================
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "CREATE TABLE lww_mesh_tbl (id int PRIMARY KEY, val text)";
pass('lww_mesh_tbl created on n1');

for my $node_num (2, 3) {
    my $seen = '0';
    for (1 .. 30) {
        $seen = psql_capture(
            $node_num,
            "SELECT COUNT(*) FROM pg_tables " .
            "WHERE tablename = 'lww_mesh_tbl'");
        last if $seen eq '1';
        sleep(1);
    }
    is($seen, '1', "lww_mesh_tbl DDL-replicated to n$node_num");
}

# =============================================================================
# TEST: fire a conflicting UPDATE on n1 and n2 for the same row, then confirm
# all three nodes converge on the same winner. The
# 'spock-conflict-force-tie' injection point attached above makes every pair
# take the tiebreaker path deterministically, so a handful of trials (a fresh
# row each time) is enough without relying on any of them racing to an
# identical timestamp.
# =============================================================================
my $num_trials = 5;
my @mismatches;
my @untiebroken_trials;

for my $id (1 .. $num_trials) {
    my $trial_log_start = log_offset(3);

    system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
        "INSERT INTO lww_mesh_tbl (id, val) VALUES ($id, 'seed')";

    for my $node_num (2, 3) {
        my $seeded = '0';
        for (1 .. 30) {
            $seeded = psql_capture(
                $node_num,
                "SELECT COUNT(*) FROM lww_mesh_tbl WHERE id = $id");
            last if $seeded eq '1';
            sleep(1);
        }
        BAIL_OUT("trial $id: seed row never reached n$node_num")
            unless $seeded eq '1';
    }

    my $pid1 = spawn_background("$log_dir/mesh_n1_update_$id.log",
        "$pg_bin/psql", '-X', '-p', $node_ports->[0], '-d', $dbname,
        '-c', "UPDATE lww_mesh_tbl SET val = 'from_n1' WHERE id = $id");
    my $pid2 = spawn_background("$log_dir/mesh_n2_update_$id.log",
        "$pg_bin/psql", '-X', '-p', $node_ports->[1], '-d', $dbname,
        '-c', "UPDATE lww_mesh_tbl SET val = 'from_n2' WHERE id = $id");
    waitpid($pid1, 0);
    my $status1 = $?;
    waitpid($pid2, 0);
    my $status2 = $?;
    if ($status1 != 0 || $status2 != 0) {
        # Not the bug under test -- an infra hiccup here would otherwise let
        # a trial silently settle at 'seed' on every node and pass an
        # equality-only convergence check with nothing actually exercised.
        BAIL_OUT("trial $id: background UPDATE failed " .
                 "(n1 update exit=$status1, n2 update exit=$status2) -- see " .
                 "$log_dir/mesh_n1_update_$id.log and " .
                 "$log_dir/mesh_n2_update_$id.log");
    }

    my ($v1, $v2) = ('', '');
    for (1 .. 15) {
        $v1 = psql_capture(1, "SELECT val FROM lww_mesh_tbl WHERE id = $id");
        $v2 = psql_capture(2, "SELECT val FROM lww_mesh_tbl WHERE id = $id");
        last if $v1 eq $v2 && ($v1 eq 'from_n1' || $v1 eq 'from_n2');
        sleep(1);
    }
    unless ($v1 eq $v2 && ($v1 eq 'from_n1' || $v1 eq 'from_n2')) {
        BAIL_OUT("trial $id: n1 and n2 never converged on a resolved value " .
                 "(n1=$v1 n2=$v2) -- both background updates exited 0 but " .
                 "neither conflict-resolved value was ever reached");
    }

    my $v3 = '';
    for (1 .. 15) {
        $v3 = psql_capture(3, "SELECT val FROM lww_mesh_tbl WHERE id = $id");
        last if $v3 eq $v1;
        sleep(1);
    }

    push @mismatches, "trial $id: n1=$v1 n2=$v2 n3=$v3"
        if $v2 ne $v1 || $v3 ne $v1;

    # The 'spock-conflict-force-tie' injection point makes every
    # timestamp-based resolution take the tiebreaker path, so n3 must log
    # at least one "by tiebreaker" line for THIS trial specifically. Row
    # convergence above only proves n3's value matches the winner, which a
    # direct, uncontested apply of the winning write can also produce
    # before n3 has even received -- let alone resolved a conflict against
    # -- the losing write. An aggregate count across all trials would not
    # catch that: depending on arrival order, a single trial can log twice
    # (once for each write, if both are seen as conflicting) while another
    # logs zero, and the totals can still add up to $num_trials. Scoping
    # the log window to $trial_log_start -- taken before this trial's
    # writes were fired -- ties the check to this trial alone; a late log
    # line from a still-settling earlier trial only makes this trial's own
    # count higher, never lower, since this trial doesn't start polling
    # until the previous one's own check already passed.
    my $trial_tiebreak_count = 0;
    for (1 .. 15) {
        my $trial_log = log_since(3, $trial_log_start);
        $trial_tiebreak_count = () = $trial_log =~ /by tiebreaker/g;
        last if $trial_tiebreak_count >= 1;
        sleep(1);
    }
    push @untiebroken_trials, $id unless $trial_tiebreak_count >= 1;
}
pass("fired $num_trials sequential conflict trials");

diag("trial $_: no \"by tiebreaker\" log line on n3") for @untiebroken_trials;
is(scalar(@untiebroken_trials), 0,
   "the forced tiebreaker path actually ran on n3 for every trial -- " .
   "without this, convergence alone would not prove the tiebreaker " .
   "itself was ever exercised");

diag($_) for @mismatches;
is(scalar(@mismatches), 0,
   "all $num_trials trials converge identically on n1, n2, and n3 -- " .
   "a mismatch means n3 (resolving a forced-tie conflict between n1 and " .
   "n2, neither of which is itself) diverged from the winner n1 and n2 " .
   "already agreed on");

# =============================================================================
# CLEANUP
# =============================================================================
system_maybe "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS lww_mesh_tbl";
system_maybe "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS lww_mesh_tbl";
system_maybe "$pg_bin/psql", '-p', $node_ports->[2], '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS lww_mesh_tbl";

destroy_cluster('Destroy 3-node cluster');

done_testing();
