use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail wait_for_sub_status
);

# =============================================================================
# Test: 034_reserved_object_ddl.pl
#
# Verifies that Spock's AutoDDL machinery treats the built-in pgedge_ace
# schema as node-local: DDL that targets only pgedge_ace (replicate_ddl=false
# in spock.reserved_object) must run locally on the node where it is issued,
# but must NOT be shipped to subscribers, and pgedge_ace tables must never be
# auto-added to a replication set (block_in_repset=true for that schema).
#
# This is Spock-only: it does not invoke the real pgEdge ACE utility. Plain
# CREATE SCHEMA/CREATE TABLE DDL against the reserved "pgedge_ace" name is
# enough to exercise the classifier. The 2-node cluster from create_cluster()
# runs with spock.enable_ddl_replication=on and spock.include_ddl_repset=on,
# which is exactly the AutoDDL configuration this test needs to be
# meaningful: without it, DDL would never be a candidate for replication in
# the first place.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for reserved-object DDL test');

my $cfg   = get_test_config();
my $host  = $cfg->{host};
my $db    = $cfg->{db_name};
my $user  = $cfg->{db_user};
my $pass  = $cfg->{db_password};
my $ports = $cfg->{node_ports};

my $prov_dsn = "host=$host dbname=$db port=$ports->[0] user=$user password=$pass";
my $sub_name = 'sub_n1_n2';

# --------------------------------------------------------------------------
# Step 1: on the provider (n1), create the reserved pgedge_ace schema and a
# table in it. This must succeed locally...
# --------------------------------------------------------------------------
psql_or_bail(1, "CREATE SCHEMA pgedge_ace");
psql_or_bail(1, "CREATE TABLE pgedge_ace.ace_state (id int primary key, v text)");

is(scalar_query(1, "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgedge_ace')"),
   't', 'pgedge_ace schema created locally on the provider');

# ...but must never be auto-added to a replication set: pgedge_ace is
# block_in_repset=true in spock.reserved_object.
is(scalar_query(1,
    "SELECT count(*) FROM spock.tables WHERE nspname = 'pgedge_ace' AND set_name IS NOT NULL"),
   '0', 'pgedge_ace.ace_state was not auto-added to any replication set');

# --------------------------------------------------------------------------
# Step 2: an ordinary public table is our control -- it DOES get picked up
# by AutoDDL and DOES replicate.
# --------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE public.ace_ctrl (id int primary key, v text)");

is(scalar_query(1,
    "SELECT set_name FROM spock.tables WHERE nspname = 'public' AND relname = 'ace_ctrl'"),
   'default', 'control table public.ace_ctrl was auto-added to the default replication set');

# --------------------------------------------------------------------------
# Step 3: subscribe n2 to n1 with structure AND data sync.  If pgedge_ace's
# DDL had been captured for replication, or if the structure dump had not
# excluded pgedge_ace (exclude_from_dump=true), this sync would try to
# recreate it -- and either fail (schema already handled specially) or leak
# it onto the subscriber. Neither should happen.
# --------------------------------------------------------------------------
psql_or_bail(2,
    "SELECT spock.sub_create('$sub_name', '$prov_dsn', ARRAY['default'], true, true)");

ok(wait_for_sub_status(2, $sub_name, 'replicating', 60),
   'subscription reached replicating (structure+data sync completed)');

is(scalar_query(2, "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgedge_ace')"),
   'f', 'pgedge_ace schema is ABSENT on the subscriber after structure sync');

is(scalar_query(2,
    "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'ace_ctrl')"),
   't', 'control table public.ace_ctrl IS present on the subscriber');

# --------------------------------------------------------------------------
# Step 4: post-subscription DDL. Create another pgedge_ace table (schema-
# qualified, so the classifier can identify it) and confirm normal DDL/DML
# keeps flowing for the replicating repset while the pgedge_ace DDL stays
# node-local.
# --------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE pgedge_ace.local_t (id int primary key)");

is(scalar_query(1, "SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'pgedge_ace' AND c.relname = 'local_t')"),
   't', 'pgedge_ace.local_t created locally on the provider after subscribe');

# Fence row through the still-replicating control table.
psql_or_bail(1, "INSERT INTO public.ace_ctrl (id, v) VALUES (1, 'fence')");

my $fenced = 0;
for (1 .. 30) {
    my $v = scalar_query(2, "SELECT v FROM public.ace_ctrl WHERE id = 1");
    if (defined $v && $v eq 'fence') { $fenced = 1; last; }
    sleep(1);
}
ok($fenced, 'fence row replicated after node-local pgedge_ace DDL was skipped');

# The pgedge_ace DDL issued after subscribe must still not have been shipped.
is(scalar_query(2, "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgedge_ace')"),
   'f', 'pgedge_ace schema is still ABSENT on the subscriber after post-subscription DDL');

# The subscription itself must be healthy -- the pgedge_ace DDL must not have
# broken or disabled replication.
ok(wait_for_sub_status(2, $sub_name, 'replicating', 30),
   'subscription is still enabled/replicating after the fence row');

destroy_cluster('Destroy 2-node reserved-object DDL test cluster');

done_testing();
