use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster get_test_config
                 scalar_query psql_or_bail);

# =============================================================================
# Test: 033_skip_schemas.pl - built-in never-replicate schemas
# =============================================================================
# A node never replicates its built-in skip schemas (pgedge_ace).  This is
# the ACE scenario: a tool using plain Postgres DDL must be able to create
# and use node-local tables without those statements failing and without
# anything leaking to peer nodes.  Exercised here:
#   1. With AutoDDL on (this harness enables it), CREATE TABLE in pgedge_ace
#      succeeds and is not auto-added to any replication set.
#   2. repset_add_table refuses a pgedge_ace table.
#   3. Structure sync excludes pgedge_ace.
#   4. DDL against pgedge_ace does not replicate to a live subscriber (and
#      does not disable the subscription by failing to apply there).
# An ordinary public table must keep replicating throughout.

create_cluster(2, 'Create 2-node skip-schemas test cluster');

my $config    = get_test_config();
my $ports     = $config->{node_ports};
my $host      = $config->{host};
my $dbname    = $config->{db_name};
my $db_user   = $config->{db_user};
my $db_pass   = $config->{db_password};
my $pg_bin    = $config->{pg_bin};

my $provider = $ports->[0];

# Poll a scalar query on a node until it equals $want or we time out.
sub wait_for {
    my ($node, $sql, $want) = @_;
    for (1 .. 100) {
        return 1 if scalar_query($node, $sql) eq $want;
        select(undef, undef, undef, 0.1);
    }
    return 0;
}

# --- 1. AutoDDL tolerates pgedge_ace (pre-subscription part). ----------------
# The harness runs with spock.enable_ddl_replication=on and
# spock.include_ddl_repset=on, so plain DDL below goes through AutoDDL.
psql_or_bail(1, "CREATE SCHEMA pgedge_ace");
psql_or_bail(1, "CREATE TABLE pgedge_ace.ace_state (id int primary key, v text)");
psql_or_bail(1, "INSERT INTO pgedge_ace.ace_state VALUES (1, 'node-local')");
is(scalar_query(1, "SELECT count(*) FROM spock.tables WHERE nspname = 'pgedge_ace' AND set_name IS NOT NULL"),
   '0', 'AutoDDL did not add a pgedge_ace table to any repset');

# --- 2. repset_add_table refuses a pgedge_ace table. -------------------------
my $rc = system("$pg_bin/psql", '-q', '-v', 'ON_ERROR_STOP=1', '-p', $provider, '-d', $dbname, '-c',
    "SELECT spock.repset_add_table('default', 'pgedge_ace.ace_state')");
isnt($rc, 0, 'repset_add_table refuses a pgedge_ace table');

# An ordinary table that must replicate throughout.
psql_or_bail(1, "CREATE TABLE public.normal_tbl (id int primary key, v text)");
psql_or_bail(1, "SELECT spock.repset_create('test_repset')");
psql_or_bail(1, "SELECT spock.repset_add_table('test_repset', 'public.normal_tbl')");

# Subscribe with structure + data sync, including the DDL repsets so AutoDDL
# leakage would be visible on the subscriber.
psql_or_bail(2, "SELECT spock.sub_create('sub1', 'host=$host port=$provider dbname=$dbname user=$db_user password=$db_pass', ARRAY['test_repset','default','default_insert_only','ddl_sql'], true, true)");
psql_or_bail(2, "SELECT spock.sub_enable('sub1', true)");
psql_or_bail(2, "SELECT spock.sub_wait_for_sync('sub1')");

# --- 3. Structure sync skipped pgedge_ace. -----------------------------------
is(scalar_query(2, "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'pgedge_ace'"),
   '0', 'structure sync skipped pgedge_ace on the subscriber');
is(scalar_query(2, "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'normal_tbl'"),
   '1', 'ordinary table still synced by structure sync');

# --- 4. AutoDDL in pgedge_ace does not replicate (live subscription). --------
psql_or_bail(1, "CREATE TABLE pgedge_ace.local_t (id int primary key)");
is(scalar_query(1, "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'pgedge_ace' AND c.relname = 'local_t'"),
   '1', 'CREATE TABLE in pgedge_ace succeeds with AutoDDL on');

# Other relation kinds in pgedge_ace must also succeed locally and stay
# local: matview/view/sequence creation and ALTER INDEX (classified via the
# same code paths).
psql_or_bail(1, "CREATE MATERIALIZED VIEW pgedge_ace.mv AS SELECT 1 AS x");
psql_or_bail(1, "CREATE VIEW pgedge_ace.v AS SELECT 1 AS x");
psql_or_bail(1, "CREATE SEQUENCE pgedge_ace.seq");
psql_or_bail(1, "CREATE INDEX ace_state_v_idx ON pgedge_ace.ace_state (v)");
psql_or_bail(1, "ALTER INDEX pgedge_ace.ace_state_v_idx SET (fillfactor = 90)");

# Regression guard: an unqualified ALTER INDEX on an ordinary index must not
# trip the classifier (it resolves the name by opening the relation, which
# must tolerate non-table relkinds).
psql_or_bail(1, "CREATE INDEX normal_tbl_v_idx ON public.normal_tbl (v)");
psql_or_bail(1, "ALTER INDEX normal_tbl_v_idx SET (fillfactor = 90)");

# Fence: once a replicated row arrives, any DDL queued before it would have
# been applied (and would have failed on the subscriber, which lacks the
# schema, disabling the subscription).
psql_or_bail(1, "INSERT INTO public.normal_tbl VALUES (1, 'fence1')");
ok(wait_for(2, "SELECT count(*) FROM public.normal_tbl WHERE id = 1", '1'),
   'ordinary table replicates alongside pgedge_ace activity');
is(scalar_query(2, "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'pgedge_ace'"),
   '0', 'DDL against pgedge_ace did not replicate');

destroy_cluster();
done_testing();
