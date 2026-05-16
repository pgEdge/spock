#!/usr/bin/perl
#
# =============================================================================
# Test: 044_apply_change_logging.pl - spock.log_verbosity / apply_change_logging
# =============================================================================
# Verifies the two GUCs added for SPOC-551:
#
#   spock.log_verbosity = normal | verbose
#       When 'verbose', spock's own DEBUG1/DEBUG2 messages are promoted to
#       LOG so they appear in the standard server log without changing
#       log_min_messages globally.
#
#   spock.apply_change_logging = none | key_only | verbose
#       Controls JSON change logging by the apply worker:
#         none      - no extra output (default)
#         key_only  - log {action, schema, table, pk, origin, commit_ts}
#         verbose   - additionally log old/new row data
#       DDL is logged in both 'key_only' and 'verbose' modes.
#
# Test coverage:
#   1. Both GUCs are present and have the expected defaults / accepted values.
#   2. They are PGC_SUSET (settable by superuser via SET, reloaded via SIGHUP).
#   3. apply_change_logging = key_only - an INSERT produces a JSON record on
#      the subscriber's server log with action/schema/table/pk/origin.
#   4. apply_change_logging = verbose - an UPDATE produces a JSON record that
#      also contains the "new" row data.
#   5. apply_change_logging = none - subsequent inserts produce NO JSON log
#      records (verifies the no-op default path).
#   6. DDL via replicate_ddl() is logged with action=DDL in key_only mode.
#

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail
    get_test_config scalar_query psql_or_bail wait_for_sub_status
);

# -------------------------------------------------------------------------
# Cluster setup
# -------------------------------------------------------------------------
create_cluster(2, 'Create 2-node cluster for apply-change-logging test');

my $config   = get_test_config();
my $host     = $config->{host};
my $dbname   = $config->{db_name};
my $user     = $config->{db_user};
my $pw       = $config->{db_password};
my $ports    = $config->{node_ports};
my $datadirs = $config->{node_datadirs};

# postgresql.conf in SpockTest.pm sets log_directory='logs' (relative), so
# the actual server log on the subscriber lives under its data directory.
my $sub_log  = "$datadirs->[1]/logs/00" . $ports->[1] . ".log";

my $conn = "host=$host dbname=$dbname port=$ports->[0] user=$user password=$pw";
psql_or_bail(2,
    "SELECT spock.sub_create('acl_sub', '$conn', "
  . "ARRAY['default','default_insert_only','ddl_sql'], true, true)");
ok(wait_for_sub_status(2, 'acl_sub', 'replicating', 60),
    'subscription replicating');

# -------------------------------------------------------------------------
# 1. GUCs exist with correct default values
# -------------------------------------------------------------------------
is(scalar_query(2, "SHOW spock.log_verbosity"), 'normal',
    'spock.log_verbosity defaults to normal');
is(scalar_query(2, "SHOW spock.apply_change_logging"), 'none',
    'spock.apply_change_logging defaults to none');

# -------------------------------------------------------------------------
# 2. Both GUCs are PGC_SUSET - settable by superuser via SET
# -------------------------------------------------------------------------
psql_or_bail(2, "SET spock.log_verbosity = 'verbose'");
psql_or_bail(2, "SET spock.apply_change_logging = 'key_only'");
psql_or_bail(2, "RESET spock.log_verbosity");
psql_or_bail(2, "RESET spock.apply_change_logging");

# -------------------------------------------------------------------------
# 3. apply_change_logging = key_only: INSERT generates a JSON record
# -------------------------------------------------------------------------
# With spock.enable_ddl_replication+include_ddl_repset on (the SpockTest
# default), CREATE TABLE is auto-added to the 'default' repset and the
# DDL is replicated to n2, so no explicit repset_add_table is needed.
psql_or_bail(1, "CREATE TABLE acl_tbl (id int PRIMARY KEY, name text)");
system_or_bail 'sleep', '4';

# Flip the GUC on the subscriber via ALTER SYSTEM (so the apply worker
# picks it up after pg_reload_conf).  PGC_SUSET also accepts SET, but the
# apply worker is a separate backend - ALTER SYSTEM + reload is the way
# the GUC reaches it.
psql_or_bail(2, "ALTER SYSTEM SET spock.apply_change_logging = 'key_only'");
psql_or_bail(2, "SELECT pg_reload_conf()");
system_or_bail 'sleep', '2';

# Mark the current end of the log so we can scan only what came after.
my $log_size_before_insert = -s $sub_log;
$log_size_before_insert //= 0;

psql_or_bail(1, "INSERT INTO acl_tbl VALUES (42, 'alice')");

# Wait for the row to land on n2 (and for the apply worker to emit the log).
my $cnt;
for (1 .. 30) {
    $cnt = scalar_query(2, "SELECT count(*) FROM acl_tbl WHERE id = 42");
    last if defined $cnt && $cnt eq '1';
    sleep(1);
}
is($cnt, '1', 'INSERT replicated to n2');

# Allow the apply worker's logger a moment to flush.
sleep(2);

# Slurp everything after the marker and look for the JSON record.
my $after_insert = read_tail($sub_log, $log_size_before_insert);
my $key_only_line = find_apply_change_line($after_insert, '"action":"INSERT"');
ok($key_only_line,
    'key_only: server log contains a "spock apply change" INSERT JSON record');

SKIP: {
    skip 'no INSERT JSON line found', 4 unless $key_only_line;
    like($key_only_line, qr/"schema":"public"/,    '... has schema=public');
    like($key_only_line, qr/"table":"acl_tbl"/,    '... has table=acl_tbl');
    like($key_only_line, qr/"pk":\{[^}]*"id":"42"/, '... has pk.id=42');
    # key_only mode must NOT contain "new":{} row data
    unlike($key_only_line, qr/"new":\{/,
        '... key_only mode omits the "new" row payload');
}

# -------------------------------------------------------------------------
# 4. apply_change_logging = verbose: UPDATE produces a record with "new"
# -------------------------------------------------------------------------
psql_or_bail(2, "ALTER SYSTEM SET spock.apply_change_logging = 'verbose'");
psql_or_bail(2, "SELECT pg_reload_conf()");
system_or_bail 'sleep', '2';

my $log_size_before_update = -s $sub_log;

psql_or_bail(1, "UPDATE acl_tbl SET name = 'alice_v2' WHERE id = 42");

# Wait for the new value to land on n2.
my $name;
for (1 .. 30) {
    $name = scalar_query(2,
        "SELECT name FROM acl_tbl WHERE id = 42");
    last if defined $name && $name eq 'alice_v2';
    sleep(1);
}
is($name, 'alice_v2', 'UPDATE replicated to n2');
sleep(2);

my $after_update = read_tail($sub_log, $log_size_before_update);
my $verbose_line = find_apply_change_line($after_update, '"action":"UPDATE"');
ok($verbose_line,
    'verbose: server log contains a "spock apply change" UPDATE JSON record');

SKIP: {
    skip 'no UPDATE JSON line found', 2 unless $verbose_line;
    like($verbose_line, qr/"new":\{[^}]*"name":"alice_v2"/,
        '... verbose mode includes the "new" row payload');
    like($verbose_line, qr/"pk":\{[^}]*"id":"42"/,
        '... verbose mode still includes pk');
}

# -------------------------------------------------------------------------
# 5. DDL is logged in key_only mode (replicated via replicate_ddl path)
# -------------------------------------------------------------------------
psql_or_bail(2, "ALTER SYSTEM SET spock.apply_change_logging = 'key_only'");
psql_or_bail(2, "SELECT pg_reload_conf()");
system_or_bail 'sleep', '2';

my $log_size_before_ddl = -s $sub_log;

# Use spock.replicate_ddl so the DDL flows through the queue / handle_sql path.
psql_or_bail(1,
    "SELECT spock.replicate_ddl("
  . "  \$ddl\$ ALTER TABLE public.acl_tbl ADD COLUMN created_at timestamptz \$ddl\$, "
  . "  ARRAY['ddl_sql'])");

# Wait for the DDL to apply on n2 (column visible).
my $col;
for (1 .. 30) {
    $col = scalar_query(2,
        "SELECT count(*) FROM information_schema.columns "
      . "WHERE table_name='acl_tbl' AND column_name='created_at'");
    last if defined $col && $col eq '1';
    sleep(1);
}
is($col, '1', 'DDL replicated to n2');
sleep(2);

my $after_ddl = read_tail($sub_log, $log_size_before_ddl);
my $ddl_line = find_apply_change_line($after_ddl, '"action":"DDL"');
ok($ddl_line,
    'key_only: server log contains a "spock apply change" DDL JSON record');

SKIP: {
    skip 'no DDL JSON line found', 1 unless $ddl_line;
    # The SQL value is JSON-escaped (search_path setup contains \"$user\"),
    # so allow anything between "sql": and the ALTER TABLE / created_at
    # tokens.
    like($ddl_line, qr/"sql":".*ALTER TABLE.*created_at/,
        '... DDL record contains the ALTER TABLE SQL text');
}

# -------------------------------------------------------------------------
# 6. apply_change_logging = none: no further "spock apply change" lines
# -------------------------------------------------------------------------
psql_or_bail(2, "ALTER SYSTEM SET spock.apply_change_logging = 'none'");
psql_or_bail(2, "SELECT pg_reload_conf()");
system_or_bail 'sleep', '2';

my $log_size_before_none = -s $sub_log;

psql_or_bail(1, "INSERT INTO acl_tbl VALUES (43, 'bob')");
for (1 .. 30) {
    $cnt = scalar_query(2, "SELECT count(*) FROM acl_tbl WHERE id = 43");
    last if defined $cnt && $cnt eq '1';
    sleep(1);
}
is($cnt, '1', 'second INSERT replicated to n2');
sleep(2);

my $after_none = read_tail($sub_log, $log_size_before_none);
unlike($after_none, qr/spock apply change/,
    'none: no JSON change-log records emitted');

# -------------------------------------------------------------------------
# Cleanup
# -------------------------------------------------------------------------
psql_or_bail(2, "ALTER SYSTEM RESET spock.apply_change_logging");
psql_or_bail(2, "ALTER SYSTEM RESET spock.log_verbosity");
psql_or_bail(2, "SELECT pg_reload_conf()");

psql_or_bail(2, "SELECT spock.sub_drop('acl_sub')");
psql_or_bail(1, "DROP TABLE IF EXISTS acl_tbl CASCADE");
destroy_cluster('Destroy apply-change-logging cluster');

done_testing();

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------
sub read_tail {
    my ($path, $offset) = @_;
    return '' unless -f $path;
    open(my $fh, '<', $path) or return '';
    seek($fh, $offset // 0, 0);
    local $/;
    my $data = <$fh>;
    close($fh);
    return defined $data ? $data : '';
}

sub find_apply_change_line {
    my ($haystack, $needle) = @_;
    for my $line (split /\n/, $haystack) {
        next unless $line =~ /spock apply change:/;
        return $line if index($line, $needle) >= 0;
    }
    return undef;
}
