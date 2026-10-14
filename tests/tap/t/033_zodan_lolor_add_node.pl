use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail system_maybe
                 get_test_config cross_wire scalar_query ensure_lolor);

# Zodan add_node with lolor large objects. The source cluster replicates the
# lolor tables (lolor.pg_largeobject, lolor.pg_largeobject_metadata) in the
# default replication set. Adding a node through zodan's add_node() must:
#   - reject a new node that lacks the lolor extension (data sync would fail),
#   - reject a new node whose lolor tables already contain data,
#   - accept a new node with lolor installed and empty, and copy the large
#     object data from the source during the initial data sync,
#   - stream large objects created after the join,
#   - leave the lolor tables in the new node's own default replication set,
#     so large objects created there replicate back to the existing nodes.
# After that, the cluster drops lolor without shipping its cleanup DDL, then
# recreates it, migrates the native large objects back on every node, and
# replicates a new large object again.

my $cfg   = get_test_config();
my $PG    = $cfg->{pg_bin};
my $DB    = $cfg->{db_name};
my $USER  = $cfg->{db_user};
my $PASS  = $cfg->{db_password};
my $HOST  = $cfg->{host};

plan skip_all => "lolor extension unavailable (clone/build failed)"
    unless ensure_lolor();

# psql helper: 1-based node index, returns true on success (output to log).
sub psql_ok {
    my ($node, $sql) = @_;
    my $port = $cfg->{node_ports}[$node - 1];
    return system_maybe("$PG/psql", '-X', '-p', $port, '-d', $DB,
                        '-v', 'ON_ERROR_STOP=1', '-c', $sql);
}

# Run SQL and capture combined stdout/stderr without going through a shell,
# so quoting inside the SQL is preserved. Returns (exit_code, output).
sub psql_capture {
    my ($node, $sql) = @_;
    my $port = $cfg->{node_ports}[$node - 1];
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>&', \*STDOUT) or die "cannot dup STDERR: $!";
        exec("$PG/psql", '-X', '-p', $port, '-d', $DB,
             '-v', 'ON_ERROR_STOP=1', '-c', $sql);
        exit 127;
    }
    my $out = do { local $/; <$fh> } // '';
    close($fh);
    return ($? >> 8, $out);
}

# Poll a scalar query on a node until it returns $expected.
sub wait_for_scalar {
    my ($node, $sql, $expected, $timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        my $v = scalar_query($node, $sql);
        return 1 if defined $v && $v eq $expected;
        sleep(1);
    }
    return 0;
}

sub dsn {
    my ($node) = @_;
    my $port = $cfg->{node_ports}[$node - 1];
    return "host=$HOST dbname=$DB port=$port user=$USER password=$PASS";
}

# --- Cluster setup: n1/n2 cross-wired, n3 is a blank target for zodan -------

create_cluster(3, 'Create 3 instances for zodan lolor test');
cross_wire(2, ['n1', 'n2'], 'Cross-wire nodes n1 and n2');

# create_cluster registered a spock node on n3; drop it so n3 looks like a
# freshly prepared instance (spock + dblink installed, no node/repsets).
ok(psql_ok(3, "SELECT spock.node_drop('n3')"), 'n3 spock node registration dropped');
ok(psql_ok(3, "CREATE EXTENSION IF NOT EXISTS dblink"), 'dblink installed on n3');

# lolor on the source cluster, its tables in the default replication set.
# n1 and n2 are cross-wired with automatic DDL replication, so CREATE
# EXTENSION on n1 arrives on n2 by itself.
ok(psql_ok(1, "CREATE EXTENSION lolor"), 'lolor installed on n1');
ok(wait_for_scalar(2, "SELECT count(*) FROM pg_extension WHERE extname = 'lolor'", '1'),
   'lolor arrived on n2 via DDL replication');
for my $node (1, 2) {
    ok(psql_ok($node, "SELECT spock.repset_add_table('default', 'lolor.pg_largeobject')"),
       "lolor.pg_largeobject in default repset on n$node");
    ok(psql_ok($node, "SELECT spock.repset_add_table('default', 'lolor.pg_largeobject_metadata')"),
       "lolor.pg_largeobject_metadata in default repset on n$node");
}

# Large object on n1; sanity-check it reaches n2 before involving zodan.
ok(psql_ok(1, "SET lolor.node=1; SELECT lo_from_bytea(0, '\\xdeadbeefcafe')"),
   'large object created on n1');
ok(wait_for_scalar(2, "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = 'deadbeefcafe'", '1'),
   'large object replicated from n1 to n2');

# Load the zodan procedures on the node being added.
system_or_bail("$PG/psql", '-X', '-p', $cfg->{node_ports}[2], '-d', $DB,
               '-v', 'ON_ERROR_STOP=1', '-f', '../../samples/Z0DAN/zodan.sql');
pass('zodan procedures loaded on n3');

my $add_node_sql =
    "CALL spock.add_node('n1', '" . dsn(1) . "', 'n3', '" . dsn(3) . "', " .
    "true, 'CA', 'USA', '{}'::jsonb)";

# --- Negative: source replicates lolor but n3 has no lolor extension --------

my ($rc, $out) = psql_capture(3, $add_node_sql);
ok($rc != 0, 'add_node rejected while n3 lacks the lolor extension');
like($out, qr/does not have the lolor extension installed/,
     'rejection message asks for CREATE EXTENSION lolor');

# --- Negative: n3 has lolor installed but with pre-existing data ------------

ok(psql_ok(3, "CREATE EXTENSION lolor"), 'lolor installed on n3');
ok(psql_ok(3, "SET lolor.node=3; SELECT lo_from_bytea(0, '\\x0bad0bad')"),
   'pre-existing large object created on n3');

($rc, $out) = psql_capture(3, $add_node_sql);
ok($rc != 0, 'add_node rejected while n3 has pre-existing lolor data');
like($out, qr/pre-existing large object data/,
     'rejection message mentions pre-existing large object data');

# health_check 'pre' must report the same problem without raising.
($rc, $out) = psql_capture(3,
    "CALL spock.health_check('n1', '" . dsn(1) . "', 'n3', '" . dsn(3) . "', 'pre', false)");
like($out, qr/FAIL: Destination database has pre-existing large object data/,
     'health_check pre-check flags pre-existing lolor data');

# --- Positive: empty lolor tables, add_node copies the data -----------------

ok(psql_ok(3, "DELETE FROM lolor.pg_largeobject; DELETE FROM lolor.pg_largeobject_metadata"),
   'pre-existing lolor data cleared on n3');

($rc, $out) = psql_capture(3, $add_node_sql);
is($rc, 0, 'add_node succeeded with lolor installed and empty') or diag($out);

ok(wait_for_scalar(3, "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = 'deadbeefcafe'", '1'),
   'existing large object data copied to n3 by initial sync');
ok(wait_for_scalar(3, "SELECT count(*) FROM lolor.pg_largeobject_metadata", '1'),
   'large object metadata copied to n3');

# --- Streaming: a large object created after the join reaches n3 ------------

ok(psql_ok(1, "SET lolor.node=1; SELECT lo_from_bytea(0, '\\xfeedface')"),
   'second large object created on n1 after join');
ok(wait_for_scalar(3, "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = 'feedface'", '1'),
   'post-join large object streamed to n3');

# --- Outbound: a large object created on n3 must reach n1 and n2 ------------
#
# Everything above tests the inbound direction, which rides on n1's
# replication sets. Outbound rides on n3's own sets, and nothing in the
# replication machinery copies set membership to a joining node. What
# populates the sets during a normal join is AutoDDL firing while pg_restore
# replays the structure dump, and that never sees the lolor tables: they are
# left out of the dump (reserved_object.exclude_from_dump), so they arrive via
# CREATE EXTENSION instead, and autoddl_can_proceed() returns false while
# creating_extension is set. So the lolor tables reach n3's default set only
# if add_node mirrors the source node's sets onto the new node.

for my $tbl ('pg_largeobject', 'pg_largeobject_metadata') {
    is(scalar_query(3,
        "SELECT set_name FROM spock.tables " .
        "WHERE nspname = 'lolor' AND relname = '$tbl'"),
       'default',
       "lolor.$tbl is in n3 default replication set after the join");
}

ok(psql_ok(3, "SET lolor.node=3; SELECT lo_from_bytea(0, '\\xc0ffee')"),
   'large object created on n3 after the join');

for my $node (1, 2) {
    ok(wait_for_scalar($node,
        "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = 'c0ffee'", '1'),
       "large object created on n3 replicated to n$node");
    ok(wait_for_scalar($node,
        "SELECT count(*) FROM lolor.pg_largeobject_metadata m " .
        "JOIN lolor.pg_largeobject l ON l.loid = m.oid " .
        "WHERE encode(l.data, 'hex') = 'c0ffee'", '1'),
       "metadata for the n3 large object replicated to n$node");
}

# --- DROP EXTENSION: lolor's cleanup must not replicate ---------------------
#
# lolor's ddl_command_start event trigger calls lolor.disable() through SPI,
# which issues ~40 "ALTER FUNCTION pg_catalog.lo_*(...) RENAME TO ..."
# statements to put the native large object API back. Those belong to the node
# running the drop: every peer runs its own copy when it applies the
# replicated DROP EXTENSION. Shipping them as well lands the renames on the
# peer ahead of the drop, leaving lolor disabled out of band, and the drop
# that follows then fails in migrate_to_native() with "lolor must be enabled
# before migration to native" -- which stalls apply.
#
# Runs after the add_node checks: it removes the extension they depend on.
# The section below puts it back.
#
# spock.allow_ddl_from_functions is enabled deliberately. With it off, DDL
# arriving from a function is never a replication candidate, and this would
# pass without exercising the guard at all.

# The queued DDL message is a bare JSON string ("SET search_path ...; <stmt>"),
# not an object, so #>> '{}' is how the statement text comes back out.
my $queued = "message #>> '{}'";

# Fence table, used below to show the peers are still applying after the drop.
ok(psql_ok(1, "CREATE TABLE public.fence (id int primary key, v text)"),
   'fence table created on n1');
for my $node (2, 3) {
    ok(wait_for_scalar($node,
        "SELECT count(*) FROM information_schema.tables " .
        "WHERE table_schema = 'public' AND table_name = 'fence'", '1'),
       "fence table reached n$node");
}

ok(psql_ok(1, "SET spock.allow_ddl_from_functions = on; DROP EXTENSION lolor"),
   'lolor dropped on n1');

is(scalar_query(1,
    "SELECT count(*) FROM spock.queue WHERE $queued ILIKE '%ALTER FUNCTION%RENAME%'"),
   '0', "lolor.disable()'s ALTER FUNCTION ... RENAME statements were not queued")
    or diag("queued DDL was:\n" . (psql_capture(1,
        "SELECT message #>> '{}' FROM spock.queue ORDER BY queued_at"))[1]);

isnt(scalar_query(1,
    "SELECT count(*) FROM spock.queue WHERE $queued ILIKE '%DROP EXTENSION%lolor%'"),
   '0', 'the DROP EXTENSION itself was queued for replication');

for my $node (2, 3) {
    ok(wait_for_scalar($node,
        "SELECT count(*) FROM pg_extension WHERE extname = 'lolor'", '0'),
       "DROP EXTENSION replicated: lolor is gone on n$node");

    # Each peer must have run its OWN cleanup while applying the drop:
    # disable() renames lo_open_orig back to lo_open, so the _orig name is
    # gone afterwards. This separates "we suppressed the replication" from
    # "we suppressed the cleanup".
    is(scalar_query($node, "SELECT count(*) FROM pg_proc WHERE proname = 'lo_open_orig'"),
       '0', "n$node ran its own lolor cleanup: native lo_open restored");
    is(scalar_query($node, "SELECT count(*) FROM pg_proc WHERE proname = 'lo_open'"),
       '1', "n$node has exactly one lo_open, the native one");
}

# Apply is still healthy on both peers.
ok(psql_ok(1, "INSERT INTO public.fence (id, v) VALUES (1, 'after-drop')"),
   'fence row inserted on n1 after the drop');
for my $node (2, 3) {
    ok(wait_for_scalar($node, "SELECT v FROM public.fence WHERE id = 1", 'after-drop'),
       "fence row reached n$node after the drop, so apply did not stall");
}

# --- Recreate lolor after the drop and replicate large objects again --------
#
# The drop above moved every large object into pg_catalog on every node.
# Create the extension again, pull the native large objects back into lolor
# storage on each node with lolor.migrate_from_native(), add the lolor tables
# back to the default set, and check that a new large object replicates.
#
# repset_add_table must run with synchronize_data => false here. Every node
# already holds the same rows after migrate_from_native(), and the table sync
# that synchronize_data => true triggers on each subscriber is a plain COPY
# into the local table with no truncate. It fails on the primary key, the
# subscription records the table's sync as failed (spock.local_sync_status
# shows 'f'), and the apply worker then skips every later change to that
# table on that subscription, silently. New large objects never arrive.

ok(psql_ok(1, "CREATE EXTENSION lolor"), 'lolor recreated on n1');
for my $node (2, 3) {
    ok(wait_for_scalar($node, "SELECT count(*) FROM pg_extension WHERE extname = 'lolor'", '1'),
       "recreated lolor arrived on n$node via DDL replication");
}

# Three large objects exist (deadbeefcafe, feedface, c0ffee); after the drop
# they live in pg_catalog on every node.
for my $node (1, 2, 3) {
    is(scalar_query($node, "SELECT count(*) FROM pg_catalog.pg_largeobject_metadata"),
       '3', "n$node holds the 3 large objects natively after the drop");
    is(scalar_query($node, "SELECT lolor.migrate_from_native()"),
       '3', "n$node migrated its 3 native large objects back into lolor");
}

# Only after every node has migrated: once a table is back in a set, rows
# written to it replicate, and the migration must stay local to each node.
for my $node (1, 2, 3) {
    for my $tbl ('pg_largeobject', 'pg_largeobject_metadata') {
        ok(psql_ok($node, "SELECT spock.repset_add_table('default', 'lolor.$tbl', false)"),
           "lolor.$tbl re-added to default repset on n$node");
    }
}

ok(psql_ok(1, "SET lolor.node=1; SELECT lo_from_bytea(0, '\\xabad1dea')"),
   'large object created on n1 after lolor was recreated');

sub diag_sync_status {
    my ($node) = @_;
    diag("n$node local_sync_status:\n" . (psql_capture($node,
        "SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status, sync_statuslsn " .
        "FROM spock.local_sync_status ORDER BY 2,3,4"))[1]);
}

for my $node (2, 3) {
    ok(wait_for_scalar($node,
        "SELECT count(*) FROM lolor.pg_largeobject WHERE encode(data, 'hex') = 'abad1dea'", '1'),
       "large object created after lolor recreate replicated to n$node")
        or diag_sync_status($node);
}

# Guards the synchronize_data => false above: a failed table sync is the
# first sign that someone put it back to true. Every node subscribes to the
# others, so every node is checked.
for my $node (1, 2, 3) {
    is(scalar_query($node,
        "SELECT count(*) FROM spock.local_sync_status WHERE sync_status = 'f'"),
       '0', "n$node has no failed table sync")
        or diag_sync_status($node);
}

# The three migrated large objects and the new one live side by side.
for my $node (1, 2, 3) {
    is(scalar_query($node, "SELECT count(*) FROM lolor.pg_largeobject_metadata"),
       '4', "n$node holds the 3 migrated large objects plus the new one");
}

destroy_cluster('Destroy zodan lolor test cluster');

done_testing();
