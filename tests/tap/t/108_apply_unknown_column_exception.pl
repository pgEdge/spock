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
# Test 108: apply-time schema mismatch ("unknown column name") does not
#           crash-loop the apply worker
# =============================================================================
# Reproduce a provider-only column with DDL replication disabled.  The
# mismatch is detected before row-level exception handling begins.  Under
# transdiscard, each bad transaction must be logged and discarded while the
# apply worker remains healthy and unrelated tables continue to replicate.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for unknown-column exception test');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};

my $p1         = $node_ports->[0];   # n1 - provider
my $p2         = $node_ports->[1];   # n2 - subscriber
my $n2_datadir = $node_datadirs->[1];

my $conn_n1 = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# PG log file for n2, to look for the crash-loop log lines directly.
my $pg_log_n2 = "$config->{log_dir}/00${p2}.log";

# Force spock.exception_behaviour = transdiscard on n2 explicitly (it is the
# default, but pin it so the test does not depend on that default).
open(my $fh, '>>', "$n2_datadir/postgresql.conf")
    or die "Cannot append to postgresql.conf: $!";
print $fh "spock.exception_behaviour=transdiscard\n";
close($fh);
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(2);

# ---------------------------------------------------------------------------
# Create the schema mismatch directly: n1 has an extra column n2 lacks.
# DDL replication is off so the CREATE TABLE itself never has to replicate --
# this isolates the DML-apply bug from anything DDL-replication related.
#
# Once t1 diverges like this, its logical row images always carry all 3
# columns (Postgres decodes the whole stored row, not just the columns an
# INSERT statement happened to name), so every future change to t1 is
# expected to keep failing -- t1_control, with identical schema on both
# nodes, is the control used to prove general replication health.
# ---------------------------------------------------------------------------

psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE t1 (a INT PRIMARY KEY, b TEXT, c TEXT); " .
    "SELECT spock.repset_add_table('default', 't1')");

psql_or_bail(2, "CREATE TABLE t1 (a INT PRIMARY KEY, b TEXT)");

# A control table with identical schema on both nodes, used to prove the
# apply worker is alive and replicating both before and after the bad
# transaction.
psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE t1_control (a INT PRIMARY KEY, b TEXT); " .
    "SELECT spock.repset_add_table('default', 't1_control')");
psql_or_bail(2, "CREATE TABLE t1_control (a INT PRIMARY KEY, b TEXT)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', " .
    "ARRAY['default', 'default_insert_only'], false, false)");

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 reaches replicating state');

# Baseline: a schema-consistent table replicates fine before we do anything
# to t1.
psql_or_bail(1, "INSERT INTO t1_control (a, b) VALUES (1, 'baseline')");

my $baseline_ok = 0;
for (1..30) {
    sleep(1);
    my $v = scalar_query(2, "SELECT count(*) FROM t1_control WHERE a = 1");
    if (defined $v && $v eq '1') { $baseline_ok = 1; last; }
}
ok($baseline_ok, 'baseline row on the control table replicates from n1 to n2');

psql_or_bail(2, "TRUNCATE spock.exception_log");
my $exc_before = scalar_query(2, "SELECT count(*) FROM spock.exception_log");

# Record the n2 log offset so later checks only look at what this test adds.
my $log_offset = -s $pg_log_n2 // 0;

# Trigger the bug: insert into the table n2 has a stale/narrower schema for.
psql_or_bail(1, "INSERT INTO t1 VALUES (4, 'data4', 'data4')");

# ---------------------------------------------------------------------------
# Core regression checks
# ---------------------------------------------------------------------------

# Without the fix this never happens -- the "unknown column name" error
# bypasses exception_behaviour/exception_log entirely and the apply worker
# crash-loops instead, so this count never grows.
my $got_exception_row = 0;
for (1..30) {
    sleep(1);
    my $cnt = scalar_query(2, "SELECT count(*) FROM spock.exception_log");
    if (defined $cnt && $cnt > $exc_before) { $got_exception_row = 1; last; }
}
ok($got_exception_row,
    'exception_log gains an entry for the unknown-column transaction '
    . '(without the fix, this never happens and the worker crash-loops)');

my $err_msg = scalar_query(2,
    "SELECT error_message FROM spock.exception_log " .
    "ORDER BY retry_errored_at DESC LIMIT 1");
isnt($err_msg, '', 'exception_log entry has a non-empty error_message');

# The exception_log row itself uses the same generic "discarded" wording as
# the pre-existing missing-relation case (log_insert_exception's literal is
# not specific to this failure); the real, specific cause is what actually
# matters for diagnosis and is what an operator would grep for, so check it
# in the server log instead.
my $log_at_error = '';
if (open(my $lf, '<', $pg_log_n2)) {
    seek($lf, $log_offset, 0);
    local $/;
    $log_at_error = <$lf> // '';
    close($lf);
}
like($log_at_error, qr/unknown column name "c" in relation "public"\."t1"/,
    'n2 server log names the real cause: unknown column "c" on relation t1');

# TRANSDISCARD: the whole offending transaction is rolled back, not applied.
my $row4 = scalar_query(2, "SELECT count(*) FROM t1 WHERE a = 4");
is($row4, '0', 'row referencing the missing column is not applied on n2 (TRANSDISCARD)');

# The subscription must still be up -- not disabled, not stuck restarting.
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 stays in replicating state (no crash loop, no SUB_DISABLE)');

# Replication of other transactions must continue.  Insert into the control
# table after the bad transaction and confirm it still replicates.
psql_or_bail(1, "INSERT INTO t1_control (a, b) VALUES (100, 'after_bad_txn')");

my $post_replicated = 0;
for (1..30) {
    sleep(1);
    my $v = scalar_query(2, "SELECT count(*) FROM t1_control WHERE a = 100");
    if (defined $v && $v eq '1') { $post_replicated = 1; last; }
}
ok($post_replicated,
    'a later, unrelated transaction still replicates after the unknown-column '
    . 'transaction (replication did not stop)');

# A second, independent row on the still-mismatched t1 must also be handled
# gracefully -- proving this is not a one-shot fluke and there is no
# creeping crash-loop building up under repeated failures.
my $exc_before_2 = scalar_query(2, "SELECT count(*) FROM spock.exception_log");
psql_or_bail(1, "INSERT INTO t1 VALUES (5, 'data5', 'data5')");

my $got_second_exception_row = 0;
for (1..30) {
    sleep(1);
    my $cnt = scalar_query(2, "SELECT count(*) FROM spock.exception_log");
    if (defined $cnt && $cnt > $exc_before_2) { $got_second_exception_row = 1; last; }
}
ok($got_second_exception_row,
    'a second, independent unknown-column transaction is also discarded and logged '
    . '(no degradation after the first occurrence)');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 still replicating after a second unknown-column transaction');

# And the control table must still be unaffected.
psql_or_bail(1, "INSERT INTO t1_control (a, b) VALUES (101, 'after_second_bad_txn')");

my $post_replicated_2 = 0;
for (1..30) {
    sleep(1);
    my $v = scalar_query(2, "SELECT count(*) FROM t1_control WHERE a = 101");
    if (defined $v && $v eq '1') { $post_replicated_2 = 1; last; }
}
ok($post_replicated_2,
    'the control table keeps replicating after two unknown-column transactions');

# Confirm there is no infinite-restart signature in the n2 log for this
# window (repeated "error during exception handling" is the crash-loop's
# fingerprint -- distinct from "caught initial exception", which
# legitimately fires once per new transaction against the still-mismatched
# table).
my $new_log = '';
if (open(my $lf, '<', $pg_log_n2)) {
    seek($lf, $log_offset, 0);
    local $/;
    $new_log = <$lf> // '';
    close($lf);
}
my $retry_storm = () = ($new_log =~ /error during exception handling/g);
is($retry_storm, 0,
    "no crash-loop signature in n2 log for the unknown-column transactions "
    . "(found $retry_storm occurrences)");

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_disable('sub_n1_n2')");
sleep(2);
system_maybe("$pg_bin/psql", '-h', $host, '-p', $p2, '-U', $db_user, '-d', $dbname,
    '-c', "SELECT spock.sub_drop('sub_n1_n2')");

destroy_cluster('Destroy cluster after unknown-column exception test');

done_testing();
