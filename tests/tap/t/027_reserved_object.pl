use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query
);

# =============================================================================
# Test: 027_reserved_object.pl
#
# Verifies the spock.reserved_object catalog: the single source of truth for
# schemas/extensions that are excluded from the structure-sync dump
# (exclude_from_dump) and blocked from replication sets (block_in_repset),
# replacing the old hard-coded C arrays.
#
# Checks the seeded built-ins, the built-in guard, the add helper, and that
# the C repset-validation path reads the table live (adding/removing a
# reserved schema changes whether its tables can join a replication set).
# =============================================================================

create_cluster(1);

my $cfg  = get_test_config();
my $bin  = $cfg->{pg_bin};
my $host = $cfg->{host};
my $port = $cfg->{node_ports}[0];
my $db   = $cfg->{db_name};
my $user = $cfg->{db_user};

# Run SQL, return (exit_code, combined_output).  ON_ERROR_STOP => non-zero on
# server error, so we can assert both success and failure.
sub psql_try {
    my ($sql) = @_;
    my $out = `$bin/psql -X -h $host -p $port -d $db -U $user -v ON_ERROR_STOP=1 -c "$sql" 2>&1`;
    return ($? >> 8, $out);
}

# --------------------------------------------------------------------------
# Seeded built-ins
# --------------------------------------------------------------------------
is(scalar_query(1, "SELECT count(*) FROM spock.reserved_object WHERE builtin"),
   '7', 'seven built-in reserved objects are seeded');
is(scalar_query(1, "SELECT block_in_repset FROM spock.reserved_object WHERE name='spock' AND kind='schema'"),
   't', 'spock schema is blocked from replication sets');
is(scalar_query(1, "SELECT block_in_repset FROM spock.reserved_object WHERE name='lolor' AND kind='schema'"),
   'f', 'lolor schema is NOT blocked from replication sets (its tables must replicate)');
is(scalar_query(1, "SELECT exclude_from_dump FROM spock.reserved_object WHERE name='lolor' AND kind='schema'"),
   't', 'lolor schema is excluded from the structure dump');

# --------------------------------------------------------------------------
# pgedge_ace: node-local schema (replicate_ddl=false), seeded as builtin
# --------------------------------------------------------------------------
is(scalar_query(1, "SELECT replicate_ddl FROM spock.reserved_object WHERE name='pgedge_ace' AND kind='schema'"),
   'f', 'pgedge_ace schema has replicate_ddl=false (AutoDDL keeps it node-local)');
is(scalar_query(1, "SELECT block_in_repset FROM spock.reserved_object WHERE name='pgedge_ace' AND kind='schema'"),
   't', 'pgedge_ace schema is blocked from replication sets');
is(scalar_query(1, "SELECT exclude_from_dump FROM spock.reserved_object WHERE name='pgedge_ace' AND kind='schema'"),
   't', 'pgedge_ace schema is excluded from the structure dump');

# --------------------------------------------------------------------------
# Built-in rows are protected
# --------------------------------------------------------------------------
my ($rc, $out) = psql_try("DELETE FROM spock.reserved_object WHERE name='spock' AND kind='schema'");
isnt($rc, 0, 'deleting a built-in reserved object is rejected');
like($out, qr/cannot delete built-in reserved object/, 'guard message shown on delete');

($rc, $out) = psql_try("UPDATE spock.reserved_object SET builtin=false WHERE name='spock' AND kind='schema'");
isnt($rc, 0, 'modifying a built-in reserved object is rejected');

($rc, $out) = psql_try("DELETE FROM spock.reserved_object WHERE name='pgedge_ace' AND kind='schema'");
isnt($rc, 0, 'deleting the built-in pgedge_ace reserved object is rejected');
like($out, qr/cannot delete built-in reserved object/, 'guard message shown on pgedge_ace delete');

# --------------------------------------------------------------------------
# Add helper + the C repset path reading the table live
# --------------------------------------------------------------------------
($rc, $out) = psql_try("SELECT spock.reserved_object_add('ace','schema')");
is($rc, 0, "reserved_object_add('ace','schema') succeeds") or diag($out);
is(scalar_query(1, "SELECT builtin FROM spock.reserved_object WHERE name='ace' AND kind='schema'"),
   'f', "user-added 'ace' is not a built-in");

# p_replicate_ddl round-trips through reserved_object_add.
($rc, $out) = psql_try("SELECT spock.reserved_object_add('foo','schema', p_replicate_ddl := false)");
is($rc, 0, "reserved_object_add('foo','schema', p_replicate_ddl := false) succeeds") or diag($out);
is(scalar_query(1, "SELECT replicate_ddl FROM spock.reserved_object WHERE name='foo' AND kind='schema'"),
   'f', "'foo' round-trips replicate_ddl=false");
is(scalar_query(1, "SELECT builtin FROM spock.reserved_object WHERE name='foo' AND kind='schema'"),
   'f', "user-added 'foo' is not a built-in");

# --------------------------------------------------------------------------
# replicate_ddl is schema-only: NULL for extensions, enforced by a CHECK.
# --------------------------------------------------------------------------
is(scalar_query(1, "SELECT replicate_ddl IS NULL FROM spock.reserved_object WHERE name='spock' AND kind='extension'"),
   't', 'built-in extension row has replicate_ddl NULL (not applicable)');

# reserved_object_add coerces replicate_ddl to NULL for an extension, even
# when a value is passed for it.
($rc, $out) = psql_try("SELECT spock.reserved_object_add('myext','extension', p_replicate_ddl := false)");
is($rc, 0, 'reserved_object_add for an extension succeeds') or diag($out);
is(scalar_query(1, "SELECT replicate_ddl IS NULL FROM spock.reserved_object WHERE name='myext' AND kind='extension'"),
   't', "extension row's replicate_ddl is coerced to NULL");

# The CHECK rejects a non-NULL replicate_ddl on an extension row...
($rc, $out) = psql_try("INSERT INTO spock.reserved_object (name, kind, replicate_ddl) VALUES ('badext', 'extension', true)");
isnt($rc, 0, 'CHECK rejects a non-NULL replicate_ddl on an extension row');

# ...and rejects a NULL replicate_ddl on a schema row.
($rc, $out) = psql_try("INSERT INTO spock.reserved_object (name, kind, replicate_ddl) VALUES ('badschema', 'schema', NULL)");
isnt($rc, 0, 'CHECK rejects a NULL replicate_ddl on a schema row');

# Create the schemas/tables with DDL replication off, so nothing is
# auto-added to a replication set (this cluster runs with include_ddl_repset
# on).  That keeps the explicit repset_add_table calls below deterministic.
psql_try("SET spock.enable_ddl_replication=off; CREATE SCHEMA ace; CREATE TABLE ace.t (id int primary key); CREATE TABLE public.ok (id int primary key)");

# public table: allowed
($rc, $out) = psql_try("SELECT spock.repset_add_table('default','public.ok')");
is($rc, 0, 'a public table can be added to a replication set') or diag($out);

# ace table: blocked, because ace is a reserved (block_in_repset) schema
($rc, $out) = psql_try("SELECT spock.repset_add_table('default','ace.t')");
isnt($rc, 0, 'a table in a reserved schema is blocked from the replication set');
like($out, qr/ignored schema ace/, 'block message names the reserved schema');

# unblock ace at runtime -> the C path picks it up immediately
($rc, $out) = psql_try("SELECT spock.reserved_object_add('ace','schema', p_block_in_repset := false)");
is($rc, 0, 'ace can be unblocked via the helper');
($rc, $out) = psql_try("SELECT spock.repset_add_table('default','ace.t')");
is($rc, 0, 'after unblocking, the ace table can join the replication set') or diag($out);

# --------------------------------------------------------------------------
# Reserving a schema block_in_repset evicts an already-member table the next
# time AutoDDL re-evaluates it (apply_repset_policy_for_reloid).
# --------------------------------------------------------------------------
psql_try("SET spock.enable_ddl_replication=off; CREATE SCHEMA evict_ns; CREATE TABLE evict_ns.t (id int primary key)");
($rc, $out) = psql_try("SELECT spock.repset_add_table('default','evict_ns.t')");
is($rc, 0, 'evict_ns.t joins a repset while its schema is unreserved') or diag($out);
is(scalar_query(1, "SELECT count(*) FROM spock.tables WHERE nspname='evict_ns' AND set_name IS NOT NULL"),
   '1', 'evict_ns.t is a repset member before its schema is reserved');

psql_try("SELECT spock.reserved_object_add('evict_ns','schema')");
($rc, $out) = psql_try("SET spock.enable_ddl_replication=on; ALTER TABLE evict_ns.t ADD COLUMN v text");
is($rc, 0, 'ALTER on a table in a now-reserved schema succeeds locally') or diag($out);
is(scalar_query(1, "SELECT count(*) FROM spock.tables WHERE nspname='evict_ns' AND set_name IS NOT NULL"),
   '0', 'reserving block_in_repset then AutoDDL evicts the table from all repsets');

# --------------------------------------------------------------------------
# pg_dump/pg_restore round-trip: pg_extension_config_dump(..., 'WHERE NOT
# builtin') dumps only operator-added rows; CREATE EXTENSION re-seeds the
# built-ins on restore, so they are preserved and never duplicated.
# --------------------------------------------------------------------------
is(scalar_query(1, "SELECT count(*) FROM spock.reserved_object WHERE NOT builtin"),
   '4', 'four operator-added rows present before the dump (ace, foo, myext, evict_ns)');

my $dumpfile = "/tmp/spock_reserved_$$.dump";
my $rtdb     = "reserved_roundtrip";
system("$bin/pg_dump -Fc -h $host -p $port -U $user -d $db -f $dumpfile") == 0
    or diag("pg_dump failed");
system("$bin/dropdb --if-exists -h $host -p $port -U $user $rtdb 2>/dev/null");
system("$bin/createdb -h $host -p $port -U $user $rtdb") == 0
    or diag("createdb failed");
# Default (no --exit-on-error): unrelated restore noise never fails the run;
# the reserved_object COPY still lands.
system("$bin/pg_restore -h $host -p $port -U $user -d $rtdb $dumpfile 2>/dev/null");

my $rt = sub {
    my ($sql) = @_;
    my $r = `$bin/psql -X -h $host -p $port -d $rtdb -U $user -tAc "$sql" 2>/dev/null`;
    $r =~ s/\s+//g;
    return $r;
};
is($rt->("SELECT count(*) FROM spock.reserved_object WHERE builtin"), '7',
   'restore re-seeded exactly 7 built-in rows (no duplicates)');
is($rt->("SELECT count(*) FROM spock.reserved_object WHERE NOT builtin"), '4',
   'restore preserved all 4 operator-added rows');
is($rt->("SELECT replicate_ddl FROM spock.reserved_object WHERE name='foo' AND kind='schema'"),
   'f', "operator-added 'foo' kept replicate_ddl=false across the round-trip");

system("$bin/dropdb --if-exists -h $host -p $port -U $user $rtdb 2>/dev/null");
unlink $dumpfile;

destroy_cluster();
done_testing();
