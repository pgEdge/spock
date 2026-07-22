use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok
                 get_test_config scalar_query psql_or_bail);

# =============================================================================
# Test: 105_group_slots.pl - Group replication slots (BDR/PGD-style)
# =============================================================================
# Verifies the group-slot subsystem:
#   - deterministic naming (spock.local_group_slot_name)
#   - automatic creation of the inactive group slot by the background worker
#   - persistence of the group slot across a server restart
#   - blocked-advancement reasons (join_in_progress) and recovery
#   - membership-generation transitions (begin/complete join and part)
#   - controlled manual advancement (spock.advance_group_slot)
#   - safe repair semantics (strict refuses recreate; repair mode allows it)
#   - the group slot is NOT removed by ordinary subscription/slot cleanup
# =============================================================================

my $config     = get_test_config();
my $host       = $config->{host};
my $dbname     = $config->{db_name};
my $db_user    = $config->{db_user};
my $db_pass    = $config->{db_password};
my $pg_bin     = $config->{pg_bin};
my $ports      = $config->{node_ports};
my $datadirs   = $config->{node_datadirs};

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------
sub node_port { return $ports->[$_[0] - 1]; }

# Run a statement, returning ($stdout, $exit_code).
sub psql_capture {
    my ($node_num, $sql) = @_;
    my $port = node_port($node_num);
    my $out = `$pg_bin/psql -X -p $port -d $dbname -t -v ON_ERROR_STOP=1 -c "$sql" 2>&1`;
    my $rc  = ($? >> 8);
    chomp $out;
    return ($out, $rc);
}

# Poll a scalar query until it equals $want (or timeout). Returns last value.
sub poll_scalar {
    my ($node_num, $sql, $want, $timeout) = @_;
    $timeout //= 40;
    my $val = '';
    for (1 .. $timeout) {
        $val = scalar_query($node_num, $sql);
        return $val if defined $val && $val eq $want;
        sleep(1);
    }
    return $val;
}

sub reload {
    my ($node_num) = @_;
    psql_or_bail($node_num, "SELECT pg_reload_conf()");
}

# ---------------------------------------------------------------------------
# Cluster setup
# ---------------------------------------------------------------------------
create_cluster(2, 'Create 2-node cluster for group-slot tests');

# Test 1: deterministic naming with the reserved group-slot prefix.
my $slot_name = scalar_query(1, "SELECT spock.local_group_slot_name()");
like($slot_name, qr/^spkgrp_/, "group slot name uses reserved 'spkgrp_' prefix ($slot_name)");

# Enable the feature on node 1 with a fast worker interval and short staleness.
psql_or_bail(1, "ALTER SYSTEM SET spock.group_slots_enabled = 'on'");
psql_or_bail(1, "ALTER SYSTEM SET spock.group_slots_worker_interval = '1'");
psql_or_bail(1, "ALTER SYSTEM SET spock.group_slots_progress_staleness_timeout = '30'");
reload(1);

# Test 2: the background worker creates the inactive group slot.
my $present = poll_scalar(1,
    "SELECT slot_present FROM spock.group_slot_status()", 't', 40);
is($present, 't', 'group slot is created by the background worker');

# Test 3: exactly one status row for the local group.
my $rows = scalar_query(1, "SELECT count(*) FROM spock.group_slot_status()");
is($rows, '1', 'group_slot_status() returns exactly one row');

# Test 4: the physical slot is a logical, inactive slot.
my $slot_ok = scalar_query(1,
    "SELECT (slot_type = 'logical' AND NOT active) FROM pg_replication_slots WHERE slot_name = '$slot_name'");
is($slot_ok, 't', 'group slot is a logical, inactive replication slot');

# -------------------------------------------------------------------------
# Restart persistence
# -------------------------------------------------------------------------
system_or_bail("$pg_bin/pg_ctl", '-D', $datadirs->[0], '-w', 'restart');
my $port1 = node_port(1);
my $ready = 0;
for (1 .. 30) {
    last if ($ready = (system("$pg_bin/pg_isready -h $host -p $port1 -q 2>/dev/null") == 0));
    sleep(1);
}
is($ready, 1, 'node 1 is back up after restart');

# Test 5: the group slot persists across a restart.
my $still = scalar_query(1,
    "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$slot_name'");
is($still, '1', 'group slot persists across a server restart');

# -------------------------------------------------------------------------
# Blocked advancement: join in progress
# -------------------------------------------------------------------------
# Inject a 'joining' member into the current generation.
psql_or_bail(1,
    "INSERT INTO spock.group_slot_membership " .
    "(membership_generation, member_node_id, member_node_name, state, required) " .
    "SELECT membership_generation, 999999, 'ghost', 'joining', true " .
    "FROM spock.group_slot_state");

# Test 6: advancement is blocked with the expected reason.
my $reason = poll_scalar(1,
    "SELECT blocked_reason FROM spock.group_slot_status()", 'join_in_progress', 20);
is($reason, 'join_in_progress', 'advancement blocked while a member is joining');

# Test 7: manual advance is refused for a hard blocker.
my (undef, $adv_rc) = psql_capture(1, "SELECT spock.advance_group_slot()");
isnt($adv_rc, 0, 'manual advance refused during join_in_progress (hard blocker)');

# Remove the joining member; advancement resumes.
psql_or_bail(1, "DELETE FROM spock.group_slot_membership WHERE member_node_id = 999999");

# Test 8: blocked_reason clears once the join marker is gone.
my $cleared = poll_scalar(1,
    "SELECT COALESCE(blocked_reason,'none') FROM spock.group_slot_status()", 'none', 20);
is($cleared, 'none', 'advancement resumes after the joining member is removed');

# -------------------------------------------------------------------------
# Membership-generation transitions
# -------------------------------------------------------------------------
my $gen0 = scalar_query(1, "SELECT membership_generation FROM spock.group_slot_state");

# Test 9: begin_join bumps the generation and blocks advancement.
my $gen_join = scalar_query(1, "SELECT spock.group_slot_begin_join('n2')");
cmp_ok($gen_join, '>', $gen0, 'begin_join advances the membership generation');
my $join_state = scalar_query(1, "SELECT node_state FROM spock.group_slot_state");
is($join_state, 'joining', 'node_state is joining after begin_join');

# Test 10: complete_join returns to the active state.
psql_or_bail(1, "SELECT spock.group_slot_complete_join('n2')");
my $active_state = poll_scalar(1,
    "SELECT node_state FROM spock.group_slot_state", 'active', 10);
is($active_state, 'active', 'node_state is active after complete_join');

# Test 11: begin_part freezes the boundary and blocks advancement.
psql_or_bail(1, "SELECT spock.group_slot_begin_part('n2')");
my $part_state = scalar_query(1, "SELECT node_state FROM spock.group_slot_state");
is($part_state, 'parting', 'node_state is parting after begin_part');

# Test 12: complete_part advances the generation, clears freeze, resumes.
my $gen_before_complete = scalar_query(1, "SELECT membership_generation FROM spock.group_slot_state");
my $gen_part = scalar_query(1, "SELECT spock.group_slot_complete_part('n2')");
cmp_ok($gen_part, '>', $gen_before_complete, 'complete_part advances the membership generation');
my $freeze = scalar_query(1, "SELECT freeze_lsn FROM spock.group_slot_state");
is($freeze, '0/0', 'freeze boundary cleared after complete_part');

# -------------------------------------------------------------------------
# Controlled manual advancement
# -------------------------------------------------------------------------
# Wait for a clean (unblocked) state first.
poll_scalar(1, "SELECT COALESCE(blocked_reason,'none') FROM spock.group_slot_status()", 'none', 20);
my ($adv_out, $adv_ok_rc) = psql_capture(1, "SELECT spock.advance_group_slot()");
is($adv_ok_rc, 0, 'manual advance succeeds when unblocked');
like($adv_out, qr{[0-9A-F]+/[0-9A-F]+}, 'manual advance returns an LSN');

# -------------------------------------------------------------------------
# Group slot survives ordinary subscription/slot cleanup
# -------------------------------------------------------------------------
# Node 2 subscribes to node 1 (creates a provider slot on node 1), then drops
# it. The group slot on node 1 must remain.
my $conn1 = "host=$host dbname=$dbname port=$port1 user=$db_user password=$db_pass";
psql_or_bail(2, "SELECT spock.sub_create('gs_sub', '$conn1', ARRAY['default'], true, true)");
sleep(5);
psql_or_bail(2, "SELECT spock.sub_drop('gs_sub')");
sleep(3);

# Test 13: the group slot is untouched by subscription teardown.
my $survived = scalar_query(1,
    "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$slot_name'");
is($survived, '1', 'group slot is not removed by ordinary subscription cleanup');

# -------------------------------------------------------------------------
# Safe repair semantics
# -------------------------------------------------------------------------
# Stop the worker so it cannot recreate the slot from under us.
psql_or_bail(1, "ALTER SYSTEM SET spock.group_slots_enabled = 'off'");
reload(1);
my $gone = poll_scalar(1,
    "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'spock group_slot%'",
    '0', 20);
is($gone, '0', 'group slot worker exits when the feature is disabled');

# Drop the slot manually to simulate damage.
psql_or_bail(1, "SELECT pg_drop_replication_slot('$slot_name')");

# Test 14: strict safety mode refuses to recreate a missing slot.
my (undef, $strict_rc) = psql_capture(1, "SELECT spock.repair_group_slot('recreate')");
isnt($strict_rc, 0, 'repair recreate refused in strict safety mode');

# Test 15: repair safety mode allows recreation.
psql_or_bail(1, "ALTER SYSTEM SET spock.group_slots_safety_mode = 'repair'");
reload(1);
my ($rep_out, $rep_rc) = psql_capture(1, "SELECT spock.repair_group_slot('recreate')");
is($rep_rc, 0, 'repair recreate succeeds in repair safety mode');
my $recreated = scalar_query(1,
    "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$slot_name'");
is($recreated, '1', 'group slot exists again after repair');

# Test 16: relink is idempotent and safe.
my ($relink_out, $relink_rc) = psql_capture(1, "SELECT spock.repair_group_slot('relink')");
is($relink_rc, 0, 'repair relink succeeds');
like($relink_out, qr/relinked/, 'repair relink reports relinked');

destroy_cluster('Destroy group-slot test cluster');
done_testing();
