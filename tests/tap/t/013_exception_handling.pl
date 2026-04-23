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
# Test 017: Exception Handling Modes
# =============================================================================
# Port of main's 013_exception_handling.pl, adapted for v5_STABLE:
#   - GUC changes via postgresql.conf append + reload (no apply-worker race)
#   - Tables created explicitly on both nodes (no DDL-replication dependency)
#   - Fixed sleeps replaced with wait_for_sub_status / wait_for_exception_log
#   - Part 5 added: TRANSDISCARD error_message quality ('unavailable' not
#     'unknown' for bystander rows; failing row gets real constraint message)
#
# Part 1: DISCARD  — per-row skip; passing rows committed, failing row logged
# Part 2: TRANSDISCARD — whole transaction rolled back; all rows logged
# Part 3: SUB_DISABLE — subscription disabled on exception
# Part 4: Deferred constraint trigger abort under DISCARD mode
# Part 5: TRANSDISCARD error_message regression (backport fix verification)
# =============================================================================

create_cluster(2, 'Create 2-node exception handling test cluster');

my $config        = get_test_config();
my $node_ports    = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $host          = $config->{host};
my $dbname        = $config->{db_name};
my $db_user       = $config->{db_user};
my $db_password   = $config->{db_password};
my $pg_bin        = $config->{pg_bin};

my $p1          = $node_ports->[0];   # n1 — provider
my $p2          = $node_ports->[1];   # n2 — subscriber
my $n2_datadir  = $node_datadirs->[1];

my $conn_n1 = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# ---------------------------------------------------------------------------
# Helper: switch n2's exception_behaviour by appending to postgresql.conf.
# Appending is more reliable than ALTER SYSTEM because the last entry wins
# and there is no SIGHUP-propagation race with the apply worker fork.
# ---------------------------------------------------------------------------
sub set_exception_behaviour {
    my ($mode) = @_;
    open(my $fh, '>>', "$n2_datadir/postgresql.conf")
        or die "Cannot append to postgresql.conf: $!";
    print $fh "spock.exception_behaviour=$mode\n";
    close($fh);
    psql_or_bail(2, "SELECT pg_reload_conf()");
    sleep(2);
}

# Create one-way subscription n1 → n2 used for Parts 1–4.
# No synchronize_structure/data — tables are created explicitly.
psql_or_bail(2,
    "SELECT spock.sub_create('exception_test_sub', '$conn_n1', " .
    "ARRAY['default', 'default_insert_only'], false, false)");

ok(wait_for_sub_status(2, 'exception_test_sub', 'replicating', 30),
    'exception_test_sub reaches replicating state');

# ===========================================================================
# Part 1: DISCARD mode
# ===========================================================================
# Failed per-row operations are skipped (subtransaction rolled back).
# The remaining rows in the transaction continue and are committed.
# Exception log entries are written in the parent transaction.
# ===========================================================================

diag("=== Part 1: DISCARD mode ===");

set_exception_behaviour('discard');
psql_or_bail(2, "TRUNCATE spock.exception_log");

psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE test_discard (id INT PRIMARY KEY, name TEXT UNIQUE, value INT); " .
    "SELECT spock.repset_add_table('default', 'test_discard')");
psql_or_bail(2,
    "CREATE TABLE test_discard (id INT PRIMARY KEY, name TEXT UNIQUE, value INT)");

# Plant a conflicting row on n2 — subscriber already has name='conflict_name'.
psql_or_bail(2,
    "BEGIN; SELECT spock.repair_mode(true); " .
    "INSERT INTO test_discard VALUES (100, 'conflict_name', 999); COMMIT");

# Multi-row transaction: row 2 will fail (unique conflict on name), rows 1 and 3 pass.
psql_or_bail(1,
    "BEGIN; " .
    "INSERT INTO test_discard VALUES (1, 'ok_name_1', 100); " .
    "INSERT INTO test_discard VALUES (2, 'conflict_name', 200); " .
    "INSERT INTO test_discard VALUES (3, 'ok_name_3', 300); " .
    "COMMIT");

ok(wait_for_exception_log(2, "table_name = 'test_discard'", 30),
    'DISCARD: exception_log has entry for test_discard');

my $d_row1 = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_discard WHERE id = 1)");
is($d_row1, 't', 'DISCARD: row 1 replicated (non-conflicting)');

my $d_row2 = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_discard WHERE id = 2)");
is($d_row2, 'f', 'DISCARD: row 2 discarded (unique conflict on name)');

my $d_row3 = scalar_query(2, "SELECT EXISTS (SELECT 1 FROM test_discard WHERE id = 3)");
is($d_row3, 't', 'DISCARD: row 3 replicated (non-conflicting)');

my $d_exc_cnt = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log " .
    "WHERE operation = 'INSERT' AND table_name = 'test_discard'");
cmp_ok($d_exc_cnt, '>=', '1', 'DISCARD: exception_log entry exists for discarded INSERT');

my $d_null_cnt = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log WHERE error_message IS NULL");
is($d_null_cnt, '0', 'DISCARD: no NULL error_message entries');

pass('Part 1 (DISCARD) complete');

# ===========================================================================
# Part 2: TRANSDISCARD mode
# ===========================================================================
# Any failure causes the entire transaction to be rolled back on the subscriber.
# All rows (pass and fail) are logged individually in the exception_log.
# ===========================================================================

diag("=== Part 2: TRANSDISCARD mode ===");

set_exception_behaviour('transdiscard');
psql_or_bail(2, "TRUNCATE spock.exception_log");

psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE test_transdiscard " .
    "(id INT PRIMARY KEY, name TEXT UNIQUE, value INT); " .
    "SELECT spock.repset_add_table('default', 'test_transdiscard')");
psql_or_bail(2,
    "CREATE TABLE test_transdiscard " .
    "(id INT PRIMARY KEY, name TEXT UNIQUE, value INT)");

psql_or_bail(2,
    "BEGIN; SELECT spock.repair_mode(true); " .
    "INSERT INTO test_transdiscard VALUES (100, 'td_conflict', 999); COMMIT");

psql_or_bail(1,
    "BEGIN; " .
    "INSERT INTO test_transdiscard VALUES (1, 'td_ok_1', 100); " .
    "INSERT INTO test_transdiscard VALUES (2, 'td_conflict', 200); " .
    "INSERT INTO test_transdiscard VALUES (3, 'td_ok_3', 300); " .
    "COMMIT");

ok(wait_for_exception_log(2, "table_name = 'test_transdiscard'", 30),
    'TRANSDISCARD: exception_log has entries for test_transdiscard');

my $td_row1 = scalar_query(2,
    "SELECT EXISTS (SELECT 1 FROM test_transdiscard WHERE id = 1)");
is($td_row1, 'f', 'TRANSDISCARD: row 1 rolled back (entire transaction discarded)');

my $td_row3 = scalar_query(2,
    "SELECT EXISTS (SELECT 1 FROM test_transdiscard WHERE id = 3)");
is($td_row3, 'f', 'TRANSDISCARD: row 3 rolled back (entire transaction discarded)');

my $td_exc_cnt = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log " .
    "WHERE table_name = 'test_transdiscard'");
cmp_ok($td_exc_cnt, '>=', '1', 'TRANSDISCARD: exception_log entries created');

my $td_null_cnt = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log WHERE error_message IS NULL");
is($td_null_cnt, '0', 'TRANSDISCARD: no NULL error_message entries');

pass('Part 2 (TRANSDISCARD) complete');

# ===========================================================================
# Part 3: SUB_DISABLE mode
# ===========================================================================
# Any exception disables the subscription entirely.
# ===========================================================================

diag("=== Part 3: SUB_DISABLE mode ===");

set_exception_behaviour('sub_disable');
psql_or_bail(2, "TRUNCATE spock.exception_log");

psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE test_subdisable (id INT PRIMARY KEY, name TEXT UNIQUE); " .
    "SELECT spock.repset_add_table('default', 'test_subdisable')");
psql_or_bail(2,
    "CREATE TABLE test_subdisable (id INT PRIMARY KEY, name TEXT UNIQUE)");

psql_or_bail(2,
    "BEGIN; SELECT spock.repair_mode(true); " .
    "INSERT INTO test_subdisable VALUES (100, 'sd_conflict'); COMMIT");

# Single conflicting insert — triggers SUB_DISABLE.
psql_or_bail(1, "INSERT INTO test_subdisable VALUES (1, 'sd_conflict')");

ok(wait_for_sub_status(2, 'exception_test_sub', 'disabled', 30),
    'SUB_DISABLE: subscription disabled after exception');

my $sd_enabled = scalar_query(2,
    "SELECT sub_enabled FROM spock.subscription " .
    "WHERE sub_name = 'exception_test_sub'");
is($sd_enabled, 'f', 'SUB_DISABLE: sub_enabled = false in catalog');

my $sd_exc_cnt = scalar_query(2, "SELECT COUNT(*) FROM spock.exception_log");
cmp_ok($sd_exc_cnt, '>=', '1', 'SUB_DISABLE: exception_log entry created');

my $sd_null_cnt = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log WHERE error_message IS NULL");
is($sd_null_cnt, '0', 'SUB_DISABLE: no NULL error_message entries');

pass('Part 3 (SUB_DISABLE) complete');

# ===========================================================================
# Part 4: Deferred constraint trigger abort under DISCARD mode
# ===========================================================================
# Recovery from Part 3: extract skip_lsn, re-enable the subscription.
# Then verify that a deferred trigger firing at commit time is handled
# gracefully — exception log entries survive and data is eventually applied.
# ===========================================================================

diag("=== Part 4: Deferred constraint trigger under DISCARD ===");

my $skip_lsn = scalar_query(2,
    "SELECT SUBSTRING(error_message FROM 'skip_lsn = ([0-9A-Fa-f/]+)') " .
    "FROM spock.exception_log " .
    "WHERE operation = 'SUB_DISABLE' " .
    "ORDER BY retry_errored_at DESC LIMIT 1");

ok($skip_lsn, "P4: extracted skip_lsn from SUB_DISABLE entry: $skip_lsn");
BAIL_OUT("Cannot proceed without skip_lsn") unless $skip_lsn;

psql_or_bail(2, "SELECT spock.sub_alter_skiplsn('exception_test_sub', '$skip_lsn')");
psql_or_bail(2, "SELECT spock.sub_enable('exception_test_sub', true)");
pass("P4: skip_lsn set and subscription re-enabled");

ok(wait_for_sub_status(2, 'exception_test_sub', 'replicating', 30),
    'P4: exception_test_sub back to replicating after skip_lsn recovery');

set_exception_behaviour('discard');
psql_or_bail(2, "TRUNCATE spock.exception_log");

psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE test_deferred " .
    "(id INT PRIMARY KEY, name TEXT UNIQUE, trigger_abort BOOL DEFAULT false); " .
    "SELECT spock.repset_add_table('default', 'test_deferred')");
psql_or_bail(2,
    "CREATE TABLE test_deferred " .
    "(id INT PRIMARY KEY, name TEXT UNIQUE, trigger_abort BOOL DEFAULT false)");

# Deferred constraint trigger on n2 only: fires at commit when trigger_abort=true.
psql_or_bail(2, "
    CREATE OR REPLACE FUNCTION abort_at_commit_fn() RETURNS trigger AS \$\$
    BEGIN
        IF NEW.trigger_abort = true THEN
            RAISE EXCEPTION 'Deferred trigger forcing abort at commit time';
        END IF;
        RETURN NEW;
    END;
    \$\$ LANGUAGE plpgsql
");
psql_or_bail(2, "
    CREATE CONSTRAINT TRIGGER abort_at_commit_trigger
    AFTER INSERT ON test_deferred
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION abort_at_commit_fn()
");
pass('P4: deferred constraint trigger created on n2');

# Plant a conflict row on n2.
psql_or_bail(2,
    "BEGIN; SELECT spock.repair_mode(true); " .
    "INSERT INTO test_deferred VALUES (100, 'deferred_conflict', false); COMMIT");

# Transaction: row 1 conflicts (exception logged in DISCARD), row 2 queues
# the deferred trigger (fires at commit → aborts that pass, worker retries).
psql_or_bail(1,
    "BEGIN; " .
    "INSERT INTO test_deferred VALUES (1, 'deferred_conflict', false); " .
    "INSERT INTO test_deferred VALUES (2, 'ok_row', true); " .
    "COMMIT");

# Give the worker time to attempt, abort, and retry.
sleep(10);

my $p4_exc_cnt = scalar_query(2, "SELECT COUNT(*) FROM spock.exception_log");
ok($p4_exc_cnt > 0,
    "P4: exception_log has entries after deferred trigger abort (count: $p4_exc_cnt)");

my $p4_row2 = scalar_query(2,
    "SELECT EXISTS (SELECT 1 FROM test_deferred WHERE id = 2)");
ok($p4_row2 eq 't',
    'P4: row 2 eventually applied (apply worker handled deferred trigger gracefully)');

pass('Part 4 (Deferred trigger) complete');

# ===========================================================================
# Part 5: TRANSDISCARD error_message quality  (backport fix regression test)
# ===========================================================================
# Before the fix, TRANSDISCARD logged bystander rows with error_message =
# 'unknown' because the NULL fallback in add_entry_to_exception_log was the
# string "unknown".  After the fix:
#   - The NULL fallback is "unavailable"
#   - The originally-failing row carries the real constraint-violation message
#   - Bystander rows carry "unavailable"
#
# Scenario: three-table transaction where t_ehx_b has NOT NULL on n2 only.
# The INSERT with v=NULL succeeds on n1 but fails on n2, triggering TRANSDISCARD.
# ===========================================================================

diag("=== Part 5: TRANSDISCARD error_message quality (regression guard) ===");

# Fresh subscription for this part to avoid any state from Parts 1–4.
set_exception_behaviour('transdiscard');

psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE t_ehx_a (id INT PRIMARY KEY, v INT); " .
    "CREATE TABLE t_ehx_b (id INT PRIMARY KEY, v INT); " .
    "CREATE TABLE t_ehx_c (id INT PRIMARY KEY, v INT); " .
    "SELECT spock.repset_add_table('default', 't_ehx_a'); " .
    "SELECT spock.repset_add_table('default', 't_ehx_b'); " .
    "SELECT spock.repset_add_table('default', 't_ehx_c')");

# t_ehx_b has NOT NULL on n2 only — INSERT with v=NULL fails on n2, not on n1.
psql_or_bail(2,
    "CREATE TABLE t_ehx_a (id INT PRIMARY KEY, v INT); " .
    "CREATE TABLE t_ehx_b (id INT PRIMARY KEY, v INT NOT NULL); " .
    "CREATE TABLE t_ehx_c (id INT PRIMARY KEY, v INT)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_ehx', '$conn_n1', " .
    "ARRAY['default'], false, false)");

ok(wait_for_sub_status(2, 'sub_ehx', 'replicating', 30),
    'P5: sub_ehx reaches replicating state');

# Multi-row transaction: t_ehx_b row has v=NULL (fails NOT NULL on n2).
# t_ehx_a and t_ehx_c are bystander rows.
psql_or_bail(1,
    "BEGIN; " .
    "INSERT INTO t_ehx_a VALUES (1, 10); " .
    "INSERT INTO t_ehx_b VALUES (1, NULL); " .
    "INSERT INTO t_ehx_c VALUES (1, 30); " .
    "COMMIT");

ok(wait_for_exception_log(2, "table_name = 't_ehx_b'", 30),
    'P5: exception_log has entry for t_ehx_b (the failing row)');

# Regression guard: no bystander row must carry the old 'unknown' fallback.
my $p5_unknown_cnt = scalar_query(2,
    "SELECT COUNT(*) FROM spock.exception_log " .
    "WHERE error_message = 'unknown' " .
    "AND table_name IN ('t_ehx_a', 't_ehx_b', 't_ehx_c')");
is($p5_unknown_cnt, '0',
    "P5: no exception_log entries with error_message = 'unknown' (regression guard)");

# Failing row must carry the real NOT NULL constraint-violation message.
my $p5_b_err = scalar_query(2,
    "SELECT error_message FROM spock.exception_log " .
    "WHERE table_name = 't_ehx_b' " .
    "ORDER BY retry_errored_at DESC LIMIT 1");
like($p5_b_err, qr/null|not.null|violates/i,
    'P5: t_ehx_b exception_log has real constraint-violation message');

# Bystander rows must have 'unavailable', not 'unknown'.
my $p5_a_err = scalar_query(2,
    "SELECT error_message FROM spock.exception_log " .
    "WHERE table_name = 't_ehx_a' " .
    "ORDER BY retry_errored_at DESC LIMIT 1");
is($p5_a_err, 'unavailable',
    "P5: bystander t_ehx_a has error_message = 'unavailable'");

my $p5_c_err = scalar_query(2,
    "SELECT error_message FROM spock.exception_log " .
    "WHERE table_name = 't_ehx_c' " .
    "ORDER BY retry_errored_at DESC LIMIT 1");
is($p5_c_err, 'unavailable',
    "P5: bystander t_ehx_c has error_message = 'unavailable'");

# TRANSDISCARD rolls back the entire transaction — no rows land on n2.
sleep(3);
my $p5_a_cnt = scalar_query(2, "SELECT count(*) FROM t_ehx_a WHERE id = 1");
is($p5_a_cnt, '0', 'P5: t_ehx_a not on n2 (TRANSDISCARD rolls back entire transaction)');

my $p5_b_cnt = scalar_query(2, "SELECT count(*) FROM t_ehx_b WHERE id = 1");
is($p5_b_cnt, '0', 'P5: t_ehx_b not on n2 (TRANSDISCARD dropped failing row)');

my $p5_c_cnt = scalar_query(2, "SELECT count(*) FROM t_ehx_c WHERE id = 1");
is($p5_c_cnt, '0', 'P5: t_ehx_c not on n2 (TRANSDISCARD rolls back entire transaction)');

pass('Part 5 (TRANSDISCARD error_message quality) complete');

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_disable('sub_ehx')");
sleep(2);
system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_drop('sub_ehx')");

destroy_cluster('Destroy exception handling test cluster');

done_testing();
