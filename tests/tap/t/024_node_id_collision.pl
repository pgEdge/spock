use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok
                 get_test_config scalar_query psql_or_bail);

# =============================================================================
# Test: 024_node_id_collision.pl - What happens when two nodes share a node_id
# =============================================================================
# Spock derives node_id as hash_any(name) & 0xffff at node_create time and
# uses that value verbatim as the on-the-wire RepOriginId. Because the value
# is local-only (no cluster-wide coordination), two independently created
# nodes can end up with the same id. This test engineers the collision
# deliberately, before either node has joined a cluster, then demonstrates
# what the operator sees when they try to cross-wire.
#
# Tampering strategy
#   create_cluster() runs spock.node_create on each node but does *not* run
#   sub_create — so at this point each node's spock catalog contains only
#   its own row, its own interface, its own repsets, and its own
#   local_node entry. There are no remote-representation rows yet, so no
#   cascading FK problem to navigate.
#
#   We override n2's local node_id to match n1's id. The only FK that needs
#   manual handling is local_node.node_id (it has no ON UPDATE CASCADE);
#   we bypass that with SET session_replication_role = replica, which
#   skips FK trigger firing. node_interface.if_nodeid and
#   replication_set.set_nodeid both have ON UPDATE CASCADE so they follow
#   the spock.node UPDATE automatically.
#
# Expected current behaviour
#   Once n2 is tampered to share n1's id, attempting cross-wire from either
#   side fails: spock.sub_create on the joining side calls
#   spock_remote_node_info(), gets the remote's (id, name), and tries to
#   INSERT a row into the local spock.node table representing the remote
#   peer. That INSERT collides with the existing local row at the same id
#   and trips the PRIMARY KEY constraint. The operator sees a generic
#   "duplicate key" error rather than a clear "node_id collision" diagnostic.
#
#   The existing PK saves us from data-path corruption in this simple case,
#   but only because both colliding ids happen to be in the same future
#   spock.node table. Cluster-merge scenarios where the collision is with a
#   third-party node (one that's a peer of the provider but not the local
#   node) produce silent misattribution — that case is out of scope for
#   this test and will be covered by the negotiation-protocol work.
# =============================================================================

create_cluster(2, 'Create 2-node cluster (node_create only, no cross-wire)');

my $config        = get_test_config();
my $node_ports    = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $host          = $config->{host};
my $dbname        = $config->{db_name};
my $db_user       = $config->{db_user};
my $db_password   = $config->{db_password};
my $pg_bin        = $config->{pg_bin};

my $conn_n1 = "host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password";
my $conn_n2 = "host=$host dbname=$dbname port=$node_ports->[1] user=$db_user password=$db_password";

# ---- Step 1: read original ids ---------------------------------------------
# create_cluster ran node_create on both nodes but no subscriptions exist,
# so each catalog has exactly one node row.
my $id_n1 = scalar_query(1, "SELECT node_id FROM spock.node WHERE node_name = 'n1'");
my $id_n2 = scalar_query(2, "SELECT node_id FROM spock.node WHERE node_name = 'n2'");

isnt($id_n1, $id_n2, 'baseline: n1 and n2 have distinct ids');
diag("baseline ids: n1=$id_n1, n2=$id_n2");

# Confirm pre-attach state: only one node row on each side.
is(scalar_query(1, "SELECT count(*) FROM spock.node"),
   '1', 'n1 catalog has exactly one node row pre-attach');
is(scalar_query(2, "SELECT count(*) FROM spock.node"),
   '1', 'n2 catalog has exactly one node row pre-attach');

scalar_query(1, "
  CREATE TABLE test (id serial PRIMARY KEY, x integer);
  INSERT INTO test (x) (VALUES (42));
");

# ---- Step 2: force n2's local node_id to collide with n1's -----------------
# Pre-attach there are no remote-representation rows in n2's catalog, so the
# UPDATE only has to navigate local_node (which has no ON UPDATE CASCADE).
# session_replication_role = replica skips FK triggers so the manual
# local_node update lands.
psql_or_bail(2, "
    BEGIN;
    SET LOCAL session_replication_role = replica;
    UPDATE spock.node       SET node_id = $id_n1 WHERE node_id = $id_n2;
    UPDATE spock.local_node SET node_id = $id_n1 WHERE node_id = $id_n2;
    COMMIT;
");

is(scalar_query(2, "SELECT node_id FROM spock.local_node"), $id_n1,
   'tamper succeeded: n2.local_node now carries n1 id');
is(scalar_query(2, "SELECT node_id FROM spock.node WHERE node_name = 'n2'"),
   $id_n1,
   'tamper succeeded: n2.spock.node row now carries n1 id');

# ---- Step 3: try to cross-wire and observe failure -------------------------
# n2 calls spock.sub_create against n1. spock_remote_node_info returns
# (id=$id_n1, name='n1'). create_node(origin) at src/spock_functions.c:503
# tries INSERT INTO spock.node (node_id, node_name) VALUES ($id_n1, 'n1').
# n2's catalog already holds a row at $id_n1 for name='n2', so the INSERT
# trips the PRIMARY KEY.
my $sub_cmd = "$pg_bin/psql -X -p $node_ports->[1] -d $dbname -t -c " .
    "\"SELECT spock.sub_create('sub_n2_from_n1', '$conn_n1', " .
    "ARRAY['default','default_insert_only','ddl_sql'], true, true)\" 2>&1";
my $sub_output = `$sub_cmd`;
my $sub_rc     = $?;

isnt($sub_rc, 0, 'sub_create from tampered n2 to n1 fails as expected');
like($sub_output,
     qr/duplicate key|unique constraint|already exists|node.*exists|collides with existing node/i,
     "failure mode is a collision diagnostic " .
     "(sees: " . substr($sub_output, 0, 120) . "...)");

# ---- Step 4: same in the reverse direction ---------------------------------
# n1 calling sub_create against n2 also fails: n1's catalog at $id_n1
# already holds the row for name='n1', and create_node(origin) tries to
# INSERT a row at $id_n1 for name='n2'. Same PK trip.
my $sub_cmd2 = "$pg_bin/psql -X -p $node_ports->[0] -d $dbname -t -c " .
    "\"SELECT spock.sub_create('sub_n1_from_n2', '$conn_n2', " .
    "ARRAY['default','default_insert_only','ddl_sql'], true, true)\" 2>&1";
my $sub_output2 = `$sub_cmd2`;
my $sub_rc2     = $?;

isnt($sub_rc2, 0, 'sub_create from n1 to tampered n2 fails as expected');
like($sub_output2,
     qr/duplicate key|unique constraint|already exists|node.*exists|collides with existing node/i,
     "reverse failure mode is also a collision diagnostic " .
     "(sees: " . substr($sub_output2, 0, 120) . "...)");

# ---- Step 5: verify catalog state was not corrupted by the failed attempts -
# The failed sub_create transactions should have rolled back cleanly. Each
# catalog should still have exactly one node row.
is(scalar_query(1, "SELECT count(*) FROM spock.node"),
   '1', 'n1 catalog unchanged after failed sub_create');
is(scalar_query(2, "SELECT count(*) FROM spock.node"),
   '1', 'n2 catalog unchanged after failed sub_create');

# ---- Step 6: no subscription rows survived the failed attempts -------------
# Both sub_create calls aborted, so neither side should hold a subscription
# row. If a row leaked through, the next apply-worker spawn would trip on a
# half-initialised subscription with FKs pointing at the colliding id.
is(scalar_query(1, "SELECT count(*) FROM spock.subscription"),
   '0', 'n1 has no subscription rows after failed sub_create');
is(scalar_query(2, "SELECT count(*) FROM spock.subscription"),
   '0', 'n2 has no subscription rows after failed sub_create');

# ---- Step 7: structure/data sync did not run on n2 -------------------------
# The sub_create from n2 was called with sync_structure=true,sync_data=true.
# If the PK collision had been detected *after* the schema/data copy phase,
# n2 would be left with an orphaned 'test' table populated with n1's data.
# create_node(origin) at src/spock_functions.c:503 runs before any copy, so
# n2 should have neither the table nor its row. Sanity-check that n1's
# original row is still present so we know the test setup itself worked.
is(scalar_query(1, "SELECT count(*) FROM test"),
   '1', "n1's original test row is still present (sanity)");
is(scalar_query(2,
       "SELECT count(*) FROM information_schema.tables " .
       "WHERE table_schema = 'public' AND table_name = 'test'"),
   '0', 'n2 has no public.test table — schema sync did not run');

# ---- cleanup ---------------------------------------------------------------
# Revert the tamper so destroy_cluster's node_drop path works.
psql_or_bail(2, "
    BEGIN;
    SET LOCAL session_replication_role = replica;
    UPDATE spock.node       SET node_id = $id_n2 WHERE node_id = $id_n1;
    UPDATE spock.local_node SET node_id = $id_n2 WHERE node_id = $id_n1;
    COMMIT;
");

destroy_cluster('Destroy cluster after collision test');
done_testing();
