use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status wait_for_exception_log
);

# =============================================================================
# Test 031: DISCARD mode skips only an un-appliable TRUNCATE
# =============================================================================
#
# A single replicated transaction mixes INSERT/UPDATE/DELETE on one table with
# a TRUNCATE of another table that has been dropped on the subscriber (modelling
# a missing relation by removing it manually).  In 'discard' mode:
#
#   - only the TRUNCATE must be discarded (and logged), and
#   - the INSERT/UPDATE/DELETE in the same transaction must still apply, and
#   - the apply worker must keep running -- the un-appliable TRUNCATE must not
#     escape and send the worker into a crash/restart loop.
#
# Before the fix, the replayed TRUNCATE raised "Spock can't find relation",
# which escaped handle_truncate() and was re-thrown by the apply worker on every
# retry: the whole transaction (row changes included) never applied and the
# stream wedged.

create_cluster(2, 'Create 2-node cluster for DISCARD truncate test');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};

my $p1 = $node_ports->[0];   # n1 -- provider
my $p2 = $node_ports->[1];   # n2 -- subscriber

my $conn_n1 = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# ---------------------------------------------------------------------------
# Setup: two tables on both nodes, then a one-way subscription n1 -> n2.
# t_data carries the row changes; t_trunc is the TRUNCATE target.  Both go into
# the 'default' repset on the provider, which replicates TRUNCATE (unlike
# 'default_insert_only').  DDL replication is turned off for the creation so the
# subscriber copy can be created explicitly and dropped later.
# ---------------------------------------------------------------------------
psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE t_data (id int PRIMARY KEY, val text); " .
    "CREATE TABLE t_trunc (id int PRIMARY KEY, val text); " .
    "SELECT spock.repset_add_table('default', 't_data'); " .
    "SELECT spock.repset_add_table('default', 't_trunc')");

psql_or_bail(2,
    "CREATE TABLE t_data (id int PRIMARY KEY, val text); " .
    "CREATE TABLE t_trunc (id int PRIMARY KEY, val text)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 reaches replicating state');

# Discard failed actions individually rather than disabling the subscription.
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'DISCARD'");
psql_or_bail(2, "ALTER SYSTEM SET spock.enable_ddl_replication = off");
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_logging = 'ALL'");
psql_or_bail(2, "SELECT pg_reload_conf()");

# Seed rows the UPDATE/DELETE will target, plus a row in the TRUNCATE target.
psql_or_bail(1, "INSERT INTO t_data VALUES (10, 'to_update'), (20, 'to_delete')");
psql_or_bail(1, "INSERT INTO t_trunc VALUES (1, 'survivor')");

# Both tables and their seed rows should reach the subscriber.
my $seeded = 0;
for (1 .. 30)
{
    my $a = scalar_query(2, "SELECT count(*) FROM t_data");
    my $b = scalar_query(2, "SELECT count(*) FROM t_trunc");
    if ($a eq '2' && $b eq '1') { $seeded = 1; last; }
    sleep(1);
}
ok($seeded, 'schema and seed rows replicated to subscriber');

psql_or_bail(2, "TRUNCATE spock.exception_log");

# Drop the TRUNCATE target on the subscriber only -- a replicated TRUNCATE of
# t_trunc can now no longer be applied ("Spock can't find relation").
psql_or_bail(2, "DROP TABLE t_trunc CASCADE");

# ---------------------------------------------------------------------------
# One transaction mixing row changes with the un-appliable TRUNCATE.
# ---------------------------------------------------------------------------
psql_or_bail(1, "
    BEGIN;
    INSERT INTO t_data VALUES (1, 'inserted');
    UPDATE t_data SET val = 'updated' WHERE id = 10;
    DELETE FROM t_data WHERE id = 20;
    TRUNCATE t_trunc;
    COMMIT;
");

# The TRUNCATE must be discarded and recorded in the exception log.
ok(wait_for_exception_log(2, "operation = 'TRUNCATE'", 30),
    'discarded TRUNCATE is recorded in spock.exception_log');

# The row changes in the SAME transaction must still apply.
my $applied = 0;
for (1 .. 30)
{
    my $ins = scalar_query(2, "SELECT val FROM t_data WHERE id = 1");
    my $upd = scalar_query(2, "SELECT val FROM t_data WHERE id = 10");
    my $del = scalar_query(2, "SELECT count(*) FROM t_data WHERE id = 20");
    if ($ins eq 'inserted' && $upd eq 'updated' && $del eq '0')
    {
        $applied = 1;
        last;
    }
    sleep(1);
}
ok($applied, 'INSERT/UPDATE/DELETE applied while only the TRUNCATE was skipped');

# Per-statement checks, for a clear message if the combined check above fails.
is(scalar_query(2, "SELECT val FROM t_data WHERE id = 1"), 'inserted',
    'INSERT from the mixed transaction applied on subscriber');
is(scalar_query(2, "SELECT val FROM t_data WHERE id = 10"), 'updated',
    'UPDATE from the mixed transaction applied on subscriber');
is(scalar_query(2, "SELECT count(*) FROM t_data WHERE id = 20"), '0',
    'DELETE from the mixed transaction applied on subscriber');

# The apply worker must survive: the subscription stays replicating (not
# disabled, not stuck) -- i.e. no crash/restart loop on the missing relation.
is(scalar_query(2,
    "SELECT status FROM spock.sub_show_status() WHERE subscription_name = 'sub_n1_n2'"),
    'replicating', 'subscription still replicating after the discarded TRUNCATE');

# And a later change still flows end-to-end, proving the stream did not wedge.
psql_or_bail(1, "INSERT INTO t_data VALUES (2, 'after')");
my $flows = 0;
for (1 .. 30)
{
    if (scalar_query(2, "SELECT val FROM t_data WHERE id = 2") eq 'after')
    {
        $flows = 1;
        last;
    }
    sleep(1);
}
ok($flows, 'replication keeps flowing after the discarded TRUNCATE');

destroy_cluster('Destroy cluster after DISCARD truncate test');

done_testing();
