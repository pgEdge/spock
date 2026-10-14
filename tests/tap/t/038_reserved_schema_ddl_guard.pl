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
# Test: 037_reserved_schema_ddl_guard.pl
#
# Verifies the AutoDDL guard rail for built-in extension-owned schemas: the
# reserved_object rows with builtin AND block_in_repset AND replicate_ddl,
# which today are exactly spock and snowflake.
#
# Nothing legitimate issues runtime DDL in those schemas -- their objects come
# from extension scripts, where AutoDDL is suppressed via creating_extension --
# so a direct statement against them is almost certainly a user mistake. It
# must fail loudly rather than half-apply, which is what happened before: the
# command text replicated to peers while the relation was quietly kept out of
# every replication set.
#
# Three things this must NOT break:
#   - the never-replicate class (pgedge_ace: replicate_ddl=false), whose DDL
#     stays silently node-local and must not raise this error;
#   - operator-added reserved schemas, where creating objects is legitimate;
#   - the escape hatch, spock.enable_ddl_replication = off in-session, which
#     leaves deliberate node-local surgery possible.
#
# A single node is enough: the guard fires in the utility hook on the node
# where the statement is issued. create_cluster() sets
# spock.enable_ddl_replication=on, which is what makes the check live.
# =============================================================================

create_cluster(1, 'Create 1-node cluster for the reserved-schema DDL guard');

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

# Assert $sql is refused by the guard, naming $nsp in the message.
sub refused {
    my ($sql, $nsp, $label) = @_;
    my ($rc, $out) = psql_try($sql);
    isnt($rc, 0, "$label: refused");
    like($out,
         qr/cannot run DDL against schema \Q$nsp\E while DDL replication is enabled/,
         "$label: purposeful error message");
    like($out, qr/enable_ddl_replication = off/,
         "$label: hint points at the escape hatch");
}

# The snowflake schema belongs to a separate extension that is not installed
# here, and reserved_object guards it by name whether or not it exists.  Plant
# the schema and a scratch table with the guard off, so the statements below
# have something to aim at and fail on the guard rather than on a missing
# schema.  Creating it this way is itself a first exercise of the escape hatch.
my ($rc_seed, $out_seed) = psql_try(
    'SET spock.enable_ddl_replication = off; ' .
    'CREATE SCHEMA snowflake; ' .
    'CREATE TABLE snowflake.guard_seed (id int primary key, v text)');
is($rc_seed, 0, "snowflake schema and seed table created with DDL replication off: $out_seed");

# --------------------------------------------------------------------------
# The refusals. One per statement class named in the acceptance criteria.
# --------------------------------------------------------------------------
refused('CREATE TABLE snowflake.t (id int primary key)',
        'snowflake', 'CREATE TABLE');
refused('CREATE TABLE spock.t (id int primary key)',
        'spock', 'CREATE TABLE in the spock schema');
refused('ALTER TABLE snowflake.guard_seed ADD COLUMN extra int',
        'snowflake', 'ALTER TABLE');
refused('CREATE INDEX guard_seed_v_idx ON snowflake.guard_seed (v)',
        'snowflake', 'CREATE INDEX');
refused('DROP TABLE snowflake.guard_seed',
        'snowflake', 'DROP TABLE');
refused('CREATE TABLE snowflake.ctas AS SELECT 1 AS x',
        'snowflake', 'CREATE TABLE AS');
refused('CREATE SEQUENCE snowflake.s',
        'snowflake', 'CREATE SEQUENCE');
refused('CREATE VIEW snowflake.v AS SELECT 1 AS x',
        'snowflake', 'CREATE VIEW');
refused('DROP SCHEMA snowflake CASCADE',
        'snowflake', 'DROP SCHEMA');

# A DROP mixing a guarded object with an ordinary one trips on the guarded
# one: the guard quantifier is ANY, because a false negative would let the
# mistake through.
my ($rc_mixed, $out_mixed) = psql_try(
    'CREATE TABLE public.mixed_ok (id int primary key)');
is($rc_mixed, 0, "control table for the mixed DROP created: $out_mixed");
refused('DROP TABLE public.mixed_ok, snowflake.guard_seed',
        'snowflake', 'DROP mixing a guarded and an ordinary table');

# --------------------------------------------------------------------------
# The statement was rolled back. This is a post-execution hook, so the ERROR
# aborts the transaction and undoes the DDL rather than leaving it applied
# locally and merely unreplicated.
# --------------------------------------------------------------------------
is(scalar_query(1,
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " .
    "WHERE n.nspname = 'snowflake' AND c.relname IN ('t', 'ctas', 's', 'v')"),
   '0', 'no refused object was left behind on the node');
is(scalar_query(1,
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " .
    "WHERE n.nspname = 'snowflake' AND c.relname = 'guard_seed_v_idx'"),
   '0', 'the refused CREATE INDEX left no index behind');
is(scalar_query(1,
    "SELECT count(*) FROM information_schema.columns " .
    "WHERE table_schema = 'snowflake' AND table_name = 'guard_seed' AND column_name = 'extra'"),
   '0', 'the refused ALTER TABLE left no column behind');
is(scalar_query(1,
    "SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " .
    "WHERE n.nspname = 'snowflake' AND c.relname = 'guard_seed')"),
   't', 'the refused DROP TABLE left the table in place');
is(scalar_query(1, "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'snowflake')"),
   't', 'the refused DROP SCHEMA left the schema in place');

# --------------------------------------------------------------------------
# The escape hatch: the same statements succeed with DDL replication off in
# the session.
# --------------------------------------------------------------------------
my ($rc_off, $out_off) = psql_try(
    'SET spock.enable_ddl_replication = off; ' .
    'CREATE TABLE snowflake.t (id int primary key)');
is($rc_off, 0, "CREATE TABLE snowflake.t succeeds with DDL replication off: $out_off");
is(scalar_query(1,
    "SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " .
    "WHERE n.nspname = 'snowflake' AND c.relname = 't')"),
   't', 'snowflake.t exists after the node-local create');

my ($rc_off2, $out_off2) = psql_try(
    'SET spock.enable_ddl_replication = off; DROP TABLE snowflake.t');
is($rc_off2, 0, "DROP TABLE snowflake.t succeeds with DDL replication off: $out_off2");

# The guard is still live afterwards -- the GUC was per-session, not global.
refused('CREATE TABLE snowflake.t (id int primary key)',
        'snowflake', 'guard still live in a fresh session');

# --------------------------------------------------------------------------
# The never-replicate class must NOT be caught. pgedge_ace carries
# block_in_repset=true as well, so a guard keyed on that flag alone would
# wrongly reject it; replicate_ddl=false is what keeps the classes apart.
# --------------------------------------------------------------------------
my ($rc_ace, $out_ace) = psql_try('CREATE SCHEMA pgedge_ace');
is($rc_ace, 0, "CREATE SCHEMA pgedge_ace is not caught by the guard: $out_ace");
my ($rc_ace2, $out_ace2) = psql_try(
    'CREATE TABLE pgedge_ace.node_local (id int primary key)');
is($rc_ace2, 0, "CREATE TABLE pgedge_ace.node_local is not caught by the guard: $out_ace2");
is(scalar_query(1,
    "SELECT count(*) FROM spock.tables WHERE nspname = 'pgedge_ace' AND set_name IS NOT NULL"),
   '0', 'pgedge_ace.node_local still kept out of every replication set');

# lolor is reserved but neither blocked from repsets nor node-local, so its
# DDL is ordinary and must pass through untouched.
my ($rc_lolor, $out_lolor) = psql_try('CREATE SCHEMA lolor');
is($rc_lolor, 0, "CREATE SCHEMA lolor is not caught by the guard: $out_lolor");

# --------------------------------------------------------------------------
# Ordinary DDL is unaffected.
# --------------------------------------------------------------------------
my ($rc_pub, $out_pub) = psql_try(
    'CREATE TABLE public.guard_control (id int primary key, v text)');
is($rc_pub, 0, "ordinary CREATE TABLE still succeeds: $out_pub");
is(scalar_query(1,
    "SELECT set_name FROM spock.tables WHERE nspname = 'public' AND relname = 'guard_control'"),
   'default', 'ordinary table still auto-added to the default replication set');

# --------------------------------------------------------------------------
# CREATE/ALTER EXTENSION for a guarded schema is unaffected: AutoDDL is
# suppressed inside extension scripts, so the guard never sees those
# subcommands. spock itself is already installed, so re-running its own
# ALTER EXTENSION ... UPDATE is the available no-op form.
# --------------------------------------------------------------------------
my ($rc_ext, $out_ext) = psql_try("ALTER EXTENSION spock UPDATE");
is($rc_ext, 0, "ALTER EXTENSION spock UPDATE is unaffected by the guard: $out_ext");

# --------------------------------------------------------------------------
# An OPERATOR-added reserved schema is NOT guarded, even with exactly the flag
# combination the built-ins carry. The guard requires builtin=true.
#
# This is the boundary of the feature. Reserving a schema is how an operator
# keeps it out of the structure dump and out of every replication set, and
# creating objects in such a schema is a legitimate thing to do -- unlike in
# spock or snowflake, whose objects only ever come from extension scripts. If
# the guard keyed on the flags alone it would take that away, and it would
# also make the repset-eviction net in apply_repset_policy_for_reloid
# unreachable, since AutoDDL would error before ever re-evaluating membership.
# --------------------------------------------------------------------------
my ($rc_add, $out_add) = psql_try(
    "SELECT spock.reserved_object_add('op_reserved', 'schema')");
is($rc_add, 0, "operator reserved op_reserved: $out_add");
is(scalar_query(1,
    "SELECT block_in_repset || '/' || replicate_ddl || '/' || builtin " .
    "FROM spock.reserved_object WHERE name = 'op_reserved' AND kind = 'schema'"),
   'true/true/false',
   'op_reserved carries the guarded flag pair but is not builtin');

my ($rc_op, $out_op) = psql_try(
    'CREATE SCHEMA op_reserved; CREATE TABLE op_reserved.t (id int primary key)');
is($rc_op, 0, "DDL against an operator-reserved schema is allowed: $out_op");
is(scalar_query(1,
    "SELECT count(*) FROM spock.tables WHERE nspname = 'op_reserved' AND set_name IS NOT NULL"),
   '0', 'op_reserved.t still kept out of every replication set');

destroy_cluster('Destroy the reserved-schema DDL guard cluster');

done_testing();
