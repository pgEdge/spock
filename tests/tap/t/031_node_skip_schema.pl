use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail get_test_config scalar_query);

# =============================================================================
# Test: 031_node_skip_schema.pl - node-level skip-schema exclusion
# =============================================================================
# Exercises the "skip_schema" list stored in the local node's info jsonb:
#   1. Structure sync excludes a skipped schema (a plain, populated schema that
#      pg_dump would otherwise copy).
#   2. repset_add_table refuses a table in a skipped schema.
#   3. The walsender filter drops changes for a schema that was skipped *after*
#      its table was already a replication-set member.
# An ordinary public table must keep replicating throughout.
#
# A plain schema (not an extension) is used on purpose.  Excluding an extension
# that lives in a skipped schema - pg_dump still emits "CREATE EXTENSION ...
# WITH SCHEMA <skipped>" - is a known unhandled corner case; see the XXX in
# dump_structure().

create_cluster(2, 'Create 2-node skip-schema test cluster');

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

# Provider (n1): a populated schema to be skipped (structure-sync case); an
# ordinary table; and later_tbl in its own schema, added to the repset now so
# it replicates before its schema is skipped.
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "CREATE SCHEMA skip_ns; CREATE TABLE skip_ns.bookkeeping (id int primary key, v text); INSERT INTO skip_ns.bookkeeping VALUES (1, 'node-local')";
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "CREATE TABLE public.normal_tbl (id int primary key, v text)";
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "CREATE SCHEMA later_ns; CREATE TABLE later_ns.later_tbl (id int primary key)";
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "SELECT spock.repset_create('test_repset')";
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "SELECT spock.repset_add_table('test_repset', 'public.normal_tbl')";
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "SELECT spock.repset_add_table('test_repset', 'later_ns.later_tbl')";

# Subscriber (n2): register skip_ns as never-replicated.
system_or_bail "$pg_bin/psql", '-q', '-p', $ports->[1], '-d', $dbname, '-c',
    "UPDATE spock.node SET info = jsonb_set(coalesce(info, '{}'::jsonb), '{skip_schema}', '[\"skip_ns\"]'::jsonb, true) WHERE node_id = (SELECT node_id FROM spock.local_node)";

# Subscribe with structure + data sync.
system_or_bail "$pg_bin/psql", '-q', '-p', $ports->[1], '-d', $dbname, '-c',
    "SELECT spock.sub_create('sub1', 'host=$host port=$provider dbname=$dbname user=$db_user password=$db_pass', ARRAY['test_repset'], true, true)";
system_or_bail "$pg_bin/psql", '-q', '-p', $ports->[1], '-d', $dbname, '-c',
    "SELECT spock.sub_enable('sub1')";
system_or_bail "$pg_bin/psql", '-q', '-p', $ports->[1], '-d', $dbname, '-c',
    "SELECT spock.sub_wait_for_sync('sub1')";

# --- 1. Structure sync skipped the registered schema. ------------------------
is(scalar_query(2, "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'skip_ns'"),
   '0', 'structure sync skipped the registered schema on the subscriber');
is(scalar_query(2, "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'normal_tbl'"),
   '1', 'ordinary table still synced by structure sync');

# --- 2. repset_add_table refuses a table in a skipped schema. ----------------
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "CREATE TABLE skip_ns.local_t (id int primary key)";
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "UPDATE spock.node SET info = jsonb_set(coalesce(info, '{}'::jsonb), '{skip_schema}', '[\"skip_ns\"]'::jsonb, true) WHERE node_id = (SELECT node_id FROM spock.local_node)";
my $rc = system("$pg_bin/psql", '-q', '-v', 'ON_ERROR_STOP=1', '-p', $provider, '-d', $dbname, '-c',
    "SELECT spock.repset_add_table('test_repset', 'skip_ns.local_t')");
isnt($rc, 0, 'repset_add_table refuses a table in a skipped schema');

# --- 3. Walsender filter drops a schema skipped after it was replicating. ----
# Baseline: later_tbl replicates while later_ns is not skipped.
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "INSERT INTO later_ns.later_tbl VALUES (1)";
ok(wait_for(2, "SELECT count(*) FROM later_ns.later_tbl", '1'),
   'table replicates before its schema is skipped');

# Now skip later_ns on the provider; the node-row change refreshes the
# walsender's cache in-stream.
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "UPDATE spock.node SET info = jsonb_set(coalesce(info, '{}'::jsonb), '{skip_schema}', '[\"skip_ns\",\"later_ns\"]'::jsonb, true) WHERE node_id = (SELECT node_id FROM spock.local_node)";

# A change to the now-skipped table plus a fence row in an ordinary table.
system_or_bail "$pg_bin/psql", '-q', '-p', $provider, '-d', $dbname, '-c',
    "INSERT INTO later_ns.later_tbl VALUES (2); INSERT INTO public.normal_tbl VALUES (99, 'fence')";

# Once the fence row arrives, the skipped table's second row must be absent.
ok(wait_for(2, "SELECT count(*) FROM public.normal_tbl WHERE id = 99", '1'),
   'fence row on the ordinary table replicated');
is(scalar_query(2, "SELECT count(*) FROM later_ns.later_tbl"), '1',
   'change to a schema skipped after replication started was filtered');

destroy_cluster();
done_testing();
