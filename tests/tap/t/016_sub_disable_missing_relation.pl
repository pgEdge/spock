use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    system_or_bail system_maybe command_ok
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status wait_for_exception_log wait_for_pg_ready
);

# =============================================================================
# Test 016: SUB_DISABLE on missing relation + skip_lsn recovery
#           + regression: dangling local_tuple after conflict
# =============================================================================
#
# Phase 1: Table dropped on n2 → INSERT on n1 → "Spock can't find relation"
#          → SUB_DISABLE → skip_lsn recovery.
#
# Phase 2: INSERT conflict sets exception_log->local_tuple in MessageContext.
#          After commit MessageContext is reset (local_tuple dangling).
#          Table then dropped on n2. Next INSERT triggers missing-relation
#          exception; without the fix handle_insert() would dereference the
#          dangling pointer → SIGSEGV. Verifies graceful handling.

# ---------------------------------------------------------------------------
# Cluster setup
# ---------------------------------------------------------------------------

create_cluster(2, 'Create 2-node cluster for sub_disable missing relation test');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};

my $p1 = $node_ports->[0];   # n1 — provider
my $p2 = $node_ports->[1];   # n2 — subscriber

my $conn_n1 = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# PG log file for n2 (set by SpockTest create_postgresql_conf).
my $pg_log_n2 = "../logs/00${p2}.log";

# ===========================================================================
# Phase 1: Basic SUB_DISABLE + skip_lsn recovery
# ===========================================================================

# Create the test table on both nodes before subscribing (no DDL replication).
psql_or_bail(1, "CREATE TABLE test_missing_rel (id SERIAL PRIMARY KEY, val TEXT)");
psql_or_bail(2, "CREATE TABLE test_missing_rel (id SERIAL PRIMARY KEY, val TEXT)");

# Create one-way subscription n1 → n2.
# synchronize_structure/data both false — table already exists on both sides.
psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'P1: sub_n1_n2 reaches replicating state');

# Baseline: verify replication is working before we break it.
psql_or_bail(1, "INSERT INTO test_missing_rel (val) VALUES ('baseline_row')");
sleep(3);

my $n2_baseline = scalar_query(2, "SELECT count(*) FROM test_missing_rel");
is($n2_baseline, '1', 'P1: baseline row replicates from n1 to n2');

# Drop the table on n2 only — simulates the missing-relation scenario.
psql_or_bail(2, "DROP TABLE test_missing_rel");

# Trigger the exception: insert on n1 into the table that n2 no longer has.
psql_or_bail(1, "INSERT INTO test_missing_rel (val) VALUES ('trigger_exception_1')");
psql_or_bail(1, "INSERT INTO test_missing_rel (val) VALUES ('trigger_exception_2')");

# Wait for the subscription to auto-disable.
ok(wait_for_sub_status(2, 'sub_n1_n2', 'disabled', 30),
    'P1: sub_n1_n2 becomes disabled after "Spock can\'t find relation" exception');

ok(wait_for_exception_log(2, "error_message LIKE '%can''t find relation%'", 10),
    'P1: exception_log has "Spock can\'t find relation" entry');

my $disable_cnt = scalar_query(2,
    "SELECT count(*) FROM spock.exception_log WHERE operation = 'SUB_DISABLE'");
cmp_ok($disable_cnt, '>=', '1', 'P1: exception_log has SUB_DISABLE entry');

my $skip_lsn = scalar_query(2,
    "SELECT regexp_replace(error_message, " .
    "'.* skip_lsn = ([0-9A-Fa-f/]+).*', '\\1') " .
    "FROM spock.exception_log " .
    "WHERE operation = 'SUB_DISABLE' " .
    "ORDER BY retry_errored_at DESC LIMIT 1");
isnt($skip_lsn, '', 'P1: skip_lsn extracted from SUB_DISABLE exception_log entry');
diag("Phase 1 skip_lsn = $skip_lsn");

# Recovery: recreate the table on n2, set skip_lsn, re-enable.
psql_or_bail(2, "CREATE TABLE test_missing_rel (id SERIAL PRIMARY KEY, val TEXT)");
psql_or_bail(2, "SELECT spock.sub_alter_skiplsn('sub_n1_n2', '$skip_lsn')");
psql_or_bail(2, "SELECT spock.sub_enable('sub_n1_n2')");
pass('P1: skip_lsn set and subscription re-enabled');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'P1: sub_n1_n2 returns to replicating state after recovery');

psql_or_bail(1, "INSERT INTO test_missing_rel (val) VALUES ('post_recovery_row')");
sleep(5);
my $post_count = scalar_query(2, "SELECT count(*) FROM test_missing_rel");
cmp_ok($post_count, '>=', '1', 'P1: post-recovery INSERT replicates to n2');

sleep(3);
my $worker_alive = scalar_query(2,
    "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'spock apply%'");
cmp_ok($worker_alive, '>=', '1', 'P1: apply worker still running after re-enable');

my $still_enabled = scalar_query(2,
    "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'");
is($still_enabled, 't', 'P1: subscription remains enabled (basic survival check)');

# ===========================================================================
# Phase 2: Regression — dangling local_tuple after conflict + missing relation
# ===========================================================================

diag("Phase 2: regression test for dangling local_tuple after conflict");

# Record log byte offset so we search only new entries from this point on.
my $log_offset_p2 = -s $pg_log_n2 // 0;

# Create crash-test table on BOTH nodes — N2 gets a conflict row first so
# the first replication cycle triggers conflict detection (setting local_tuple).
psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE test_crash_target (id INT PRIMARY KEY, val TEXT); " .
    "SELECT spock.repset_add_table('default', 'test_crash_target')");

psql_or_bail(2, "CREATE TABLE test_crash_target (id INT PRIMARY KEY, val TEXT)");

# Plant a conflicting row on N2.
psql_or_bail(2, "INSERT INTO test_crash_target VALUES (1, 'n2_conflict_row')");

# Insert the SAME primary key on N1 — triggers conflict resolution on N2,
# setting exception_log->local_tuple in MessageContext.
psql_or_bail(1, "INSERT INTO test_crash_target VALUES (1, 'n1_row')");

# Wait for T1 (conflict transaction) to be applied.
# After commit, MemoryContextReset(MessageContext) frees local_tuple;
# the pointer in shared memory is now dangling.
my $t1_applied = 0;
for (1..30) {
    sleep(1);
    my $v = scalar_query(2, "SELECT val FROM test_crash_target WHERE id = 1");
    if (defined $v && $v ne '') {
        $t1_applied = 1;
        diag("P2: T1 conflict applied; exception_log->local_tuple is now dangling");
        last;
    }
}
ok($t1_applied, 'P2: conflict transaction T1 applied (local_tuple set then freed)');

# Drop the table on N2 only — missing-relation trigger for T2.
psql_or_bail(2, "DROP TABLE test_crash_target");
sleep(1);

# Insert T2 on N1: without the fix, "can't find relation" on N2 second pass
# would dereference the dangling local_tuple → SIGSEGV.
psql_or_bail(1, "INSERT INTO test_crash_target VALUES (2, 'crash_trigger_row')");
pass('P2: T2 insert sent (missing-relation trigger)');

# Wait for graceful exception handling (SUB_DISABLE).
# A SIGSEGV would kill the postmaster; clean handling just disables the sub.
my $graceful = 0;
for (1..20) {
    sleep(1);
    my $st = scalar_query(2,
        "SELECT status FROM spock.sub_show_status() " .
        "WHERE subscription_name = 'sub_n1_n2'");
    if (defined $st && ($st eq 'disabled' || $st eq 'replicating')) {
        $graceful = 1;
        diag("P2: exception handled gracefully — subscription status: $st");
        last;
    }
}

# Search only new log entries (since Phase 2 started) for signal 11.
my $new_log = '';
if (open(my $lf, '<', $pg_log_n2)) {
    seek($lf, $log_offset_p2, 0);
    local $/;
    $new_log = <$lf> // '';
    close($lf);
}
my $sigsegv_in_p2 = ($new_log =~ /terminated by signal 11/) ? 1 : 0;
my $crash_recovery_in_p2 =
    ($new_log =~ /all server processes terminated.*reinitializing/s ||
     $new_log =~ /terminating any other active server processes/) ? 1 : 0;

ok($graceful && !$sigsegv_in_p2,
    'P2: dangling local_tuple handled gracefully — no SIGSEGV');

if ($sigsegv_in_p2) {
    diag("REGRESSION: signal 11 detected in Phase 2 — fix in handle_insert() may be missing");
} elsif ($graceful) {
    diag("Fix confirmed: apply worker handled missing-relation without crashing");
} else {
    diag("WARNING: subscription did not reach expected state within timeout");
}

# ---------------------------------------------------------------------------
# Cleanup after Phase 2
# ---------------------------------------------------------------------------

# If crash recovery fired (regression), wait for pg to come back.
if ($crash_recovery_in_p2) {
    diag("Crash recovery detected — waiting for n2 to recover");
    ok(wait_for_pg_ready($host, $p2, $pg_bin, 30),
        'n2 postmaster accepts connections after crash recovery');
}

# Disable and drop the subscription to clean up.
system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_disable('sub_n1_n2')");
sleep(3);

system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_drop('sub_n1_n2')");

destroy_cluster('Destroy cluster after sub_disable crash reproduction test');

done_testing();
