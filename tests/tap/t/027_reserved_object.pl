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
   '6', 'six built-in reserved objects are seeded');
is(scalar_query(1, "SELECT block_in_repset FROM spock.reserved_object WHERE name='spock' AND kind='schema'"),
   't', 'spock schema is blocked from replication sets');
is(scalar_query(1, "SELECT block_in_repset FROM spock.reserved_object WHERE name='lolor' AND kind='schema'"),
   'f', 'lolor schema is NOT blocked from replication sets (its tables must replicate)');
is(scalar_query(1, "SELECT exclude_from_dump FROM spock.reserved_object WHERE name='lolor' AND kind='schema'"),
   't', 'lolor schema is excluded from the structure dump');

# --------------------------------------------------------------------------
# Built-in rows are protected
# --------------------------------------------------------------------------
my ($rc, $out) = psql_try("DELETE FROM spock.reserved_object WHERE name='spock' AND kind='schema'");
isnt($rc, 0, 'deleting a built-in reserved object is rejected');
like($out, qr/cannot delete built-in reserved object/, 'guard message shown on delete');

($rc, $out) = psql_try("UPDATE spock.reserved_object SET builtin=false WHERE name='spock' AND kind='schema'");
isnt($rc, 0, 'modifying a built-in reserved object is rejected');

# --------------------------------------------------------------------------
# Add helper + the C repset path reading the table live
# --------------------------------------------------------------------------
($rc, $out) = psql_try("SELECT spock.reserved_object_add('ace','schema')");
is($rc, 0, "reserved_object_add('ace','schema') succeeds") or diag($out);
is(scalar_query(1, "SELECT builtin FROM spock.reserved_object WHERE name='ace' AND kind='schema'"),
   'f', "user-added 'ace' is not a built-in");

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

destroy_cluster();
done_testing();
