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

# scalar_query() collapses all whitespace (SpockTest.pm), which would run the
# queued statements together into one unreadable blob -- exactly when a diag
# is needed. Read the queue with the text intact instead.
sub queued_ddl {
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>&', \*STDOUT) or die "cannot dup STDERR: $!";
        exec("$cfg->{pg_bin}/psql", '-X', '-p', $ports->[0], '-d', $db, '-At',
             '-c', "SELECT message #>> '{}' FROM spock.queue ORDER BY queued_at");
        exit 127;
    }
    my $out = do { local $/; <$fh> } // '';
    close($fh);
    return $out;
}

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
# Step 2b: an OPERATOR-added reserved schema (not a built-in). Reserve it on
# both nodes -- node-local config, applied per node -- so its table never
# joins a repset on the provider (block_in_repset) and the structure dump
# excludes it (exclude_from_dump). It must therefore be absent on the
# subscriber after the structure sync below.
# --------------------------------------------------------------------------
psql_or_bail(1, "SELECT spock.reserved_object_add('op_local', 'schema')");
psql_or_bail(2, "SELECT spock.reserved_object_add('op_local', 'schema')");
psql_or_bail(1, "CREATE SCHEMA op_local");
psql_or_bail(1, "CREATE TABLE op_local.t (id int primary key, v text)");

is(scalar_query(1,
    "SELECT count(*) FROM spock.tables WHERE nspname = 'op_local' AND set_name IS NOT NULL"),
   '0', 'operator-reserved op_local.t was not auto-added to any replication set');

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

is(scalar_query(2, "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'op_local')"),
   'f', 'operator-reserved op_local schema is ABSENT on the subscriber (exclude_from_dump)');

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

# --------------------------------------------------------------------------
# Step 5: DDL that an extension's own cleanup path runs must stay node-local.
#
# An extension may register a ddl_command_start event trigger and run DDL of
# its own through SPI while it is being dropped -- lolor does exactly that,
# renaming the native large object functions back into place. That DDL is an
# implementation detail of the drop: a subscriber runs its own copy when it
# applies the replicated DROP EXTENSION, so shipping it as well would execute
# the cleanup twice there.
#
# Core exposes creating_extension so AutoDDL can recognise the CREATE side,
# but has no counterpart for DROP, so spock_ProcessUtility() tracks that half
# itself and autoddl_can_proceed() skips anything nested inside.
#
# hstore stands in for any extension with a cleanup path, and the event
# trigger for the cleanup itself, so this needs no lolor and runs everywhere.
# spock.allow_ddl_from_functions is enabled deliberately: with it off, DDL
# arriving from a function is never a replication candidate and the guard
# would never be reached.
#
# The assertions are deliberately provider-side. This subscription requests
# only 'default', while AutoDDL queues to 'default_insert_only', so no DDL
# reaches n2 here at all -- checking n2 would prove nothing. What must not
# happen is the statement being queued in the first place, and that is what
# spock.queue shows. The end-to-end consequence on a subscriber is covered by
# 033_zodan_lolor_add_node.
# --------------------------------------------------------------------------

# The queued DDL message is a bare JSON string ("SET search_path ...; <stmt>"),
# not an object, so #>> '{}' is how the statement text comes back out.
my $queued = "message #>> '{}'";

# hstore is contrib and may not be installed. Guard the whole step rather
# than letting psql_or_bail die part way through: that would skip
# destroy_cluster, and the nodes share fixed ports and datadirs with every
# other test, so a leaked postmaster takes the rest of the run down with it
# (see the comment in destroy_cluster, SpockTest.pm).
my $have_hstore = scalar_query(1,
    "SELECT count(*) FROM pg_available_extensions WHERE name = 'hstore'");

SKIP: {
    skip 'hstore not available (contrib not installed)', 4
        unless defined $have_hstore && $have_hstore eq '1';

    psql_or_bail(1, "CREATE EXTENSION hstore");

    # IF NOT EXISTS so the trigger stays harmless if it ever fires twice: it
    # runs on ddl_command_start, so an error here takes the DROP with it.
    psql_or_bail(1, <<'SQL');
CREATE FUNCTION public.drop_ext_cleanup() RETURNS event_trigger AS $fn$
BEGIN
    EXECUTE 'CREATE TABLE IF NOT EXISTS public.cleanup_marker (id int primary key)';
END
$fn$ LANGUAGE plpgsql
SQL
    psql_or_bail(1,
        "CREATE EVENT TRIGGER drop_ext_cleanup ON ddl_command_start " .
        "WHEN TAG IN ('DROP EXTENSION') " .
        "EXECUTE FUNCTION public.drop_ext_cleanup()");

    # Count what the drop adds to the queue rather than pattern-matching for
    # the cleanup statement: the event trigger function's own source
    # necessarily contains the text of the statement it runs, so any substring
    # match would hit the CREATE FUNCTION entry and prove nothing.
    my $queue_before = scalar_query(1, "SELECT count(*) FROM spock.queue");

    psql_or_bail(1, "SET spock.allow_ddl_from_functions = on; DROP EXTENSION hstore");

    # The cleanup ran locally...
    is(scalar_query(1,
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables " .
        "WHERE table_schema = 'public' AND table_name = 'cleanup_marker')"),
       't', "the event trigger's DDL executed locally during the drop");

    # ...and the drop queued exactly one statement, so the cleanup was not
    # shipped.
    is(scalar_query(1, "SELECT count(*) FROM spock.queue") - $queue_before, 1,
       'the drop queued exactly one statement')
        or diag("queued DDL was:\n" . queued_ddl());

    # A statement that is not replicated must not be tracked in a repset
    # either: add_ddl_to_repset() only runs when the DDL was actually queued.
    is(scalar_query(1,
        "SELECT count(*) FROM spock.tables " .
        "WHERE relname = 'cleanup_marker' AND set_name IS NOT NULL"),
       '0', 'the node-local table was not added to a replication set');

    # The DROP EXTENSION itself must still replicate, or subscribers keep an
    # extension the provider has removed.
    is(scalar_query(1,
        "SELECT count(*) FROM spock.queue WHERE $queued ILIKE '%DROP EXTENSION%hstore%'"),
       '1', 'and that one statement was the DROP EXTENSION itself');

    # Leave no armed trigger behind: a later DROP EXTENSION in this file would
    # otherwise fire it again.
    psql_or_bail(1, "DROP EVENT TRIGGER drop_ext_cleanup");
}

destroy_cluster('Destroy 2-node reserved-object DDL test cluster');

done_testing();
