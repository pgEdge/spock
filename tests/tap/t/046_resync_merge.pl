use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster get_test_config scalar_query psql_or_bail);

# =============================================================================
# Test: 046_resync_merge.pl - spock.sub_resync_table(..., merge := true)
# =============================================================================
# A resync with merge copies the origin's rows into a staging table and merges
# them with ON CONFLICT DO NOTHING, so rows the subscriber already holds are
# kept and only the missing rows are added.  This is the repair path for a
# table whose plain COPY would abort on a duplicate key.
#
# Checks:
# 1. merge together with truncate is rejected.
# 2. merge on a table with no unique index is rejected.
# 3. merge on a table whose only unique index is partial is rejected.
# 4. merge adds the missing rows, keeps a locally changed row unchanged, and
#    leaves the table replicating afterwards.
# 5. merge into an empty table takes the lock-and-copy path, not staging.
# 6. merge copies identity and generated columns correctly.

create_cluster(2, 'Create 2-node cluster for resync merge test');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $node_datadirs = $config->{node_datadirs};
my $pg_bin = $config->{pg_bin};
my $dbname = $config->{db_name};

my $sub_name = 'sub_n2_n1';

# SpockTest sets log_directory to its log_dir, which PostgreSQL resolves
# against the data directory when it is relative.
my $log_dir = $config->{log_dir};
my $n2_logfile = ($log_dir =~ m{^/})
    ? "$log_dir/00$node_ports->[1].log"
    : "$node_datadirs->[1]/$log_dir/00$node_ports->[1].log";

# Read the subscriber's log from $offset, so a check sees only new lines.
sub log_since {
    my ($offset) = @_;
    open my $fh, '<', $n2_logfile or die "Cannot open $n2_logfile: $!";
    seek $fh, $offset, 0;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content // '';
}

sub psql_capture {
    my ($node_num, $sql) = @_;
    my $port = $node_ports->[$node_num - 1];
    return `$pg_bin/psql -X -p $port -d $dbname -t -c "$sql" 2>&1`;
}

# Poll a scalar query until it reads $want, and return the last value seen.
sub wait_for_query {
    my ($node_num, $sql, $want, $timeout) = @_;
    $timeout //= 60;
    my $got = '';
    for (1 .. $timeout) {
        $got = scalar_query($node_num, $sql);
        return $got if defined $got && $got eq $want;
        sleep(1);
    }
    return $got;
}

# Poll until $relname exists on the node, so DDL replication is not timed.
sub wait_for_table {
    my ($node_num, $relname) = @_;
    return wait_for_query($node_num,
        "SELECT count(*) FROM pg_tables WHERE tablename = '$relname'",
        '1', 60);
}

# Poll a table's row in spock.local_sync_status until it reads $expected.
sub wait_for_table_sync_status {
    my ($node_num, $relname, $expected, $timeout) = @_;
    return wait_for_query($node_num,
        "SELECT sync_status FROM spock.local_sync_status " .
        "WHERE sync_relname = '$relname'",
        $expected, $timeout // 60);
}

psql_or_bail(1,
    "CREATE TABLE test_merge (
        id INTEGER PRIMARY KEY,
        name TEXT,
        value INTEGER
    )"
);
psql_or_bail(1, "CREATE TABLE test_nokey (id INTEGER, value INTEGER)");
psql_or_bail(1, "CREATE TABLE test_partial (id INTEGER, value INTEGER)");
psql_or_bail(1, "CREATE UNIQUE INDEX test_partial_id_key ON test_partial (id) WHERE value > 0");
psql_or_bail(1, "CREATE TABLE test_empty (id INTEGER PRIMARY KEY, value INTEGER)");
psql_or_bail(1,
    "CREATE TABLE test_ident (
        id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        value INTEGER,
        doubled INTEGER GENERATED ALWAYS AS (value * 2) STORED
    )"
);

is(wait_for_table(2, 'test_merge'), '1', 'test_merge replicated to the subscriber');
is(wait_for_table(2, 'test_nokey'), '1', 'test_nokey replicated to the subscriber');
is(wait_for_table(2, 'test_partial'), '1', 'test_partial replicated to the subscriber');
is(wait_for_table(2, 'test_empty'), '1', 'test_empty replicated to the subscriber');
is(wait_for_table(2, 'test_ident'), '1', 'test_ident replicated to the subscriber');

# The checks below rest on the subscriber having the same definitions, which
# arrive by DDL replication.  Confirm them, so a rejection or a merge cannot
# pass for the wrong reason.
is(scalar_query(2,
    "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid " .
    "WHERE c.relname = 'test_partial' AND i.indisunique AND i.indpred IS NOT NULL"),
   '1', 'Subscriber test_partial has a partial unique index');
is(scalar_query(2,
    "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid " .
    "WHERE c.relname = 'test_partial' AND i.indisunique AND i.indpred IS NULL"),
   '0', 'Subscriber test_partial has no other unique index');
is(scalar_query(2,
    "SELECT count(*) FROM pg_attribute WHERE attrelid = 'test_ident'::regclass " .
    "AND attidentity = 'a'"),
   '1', 'Subscriber test_ident has a GENERATED ALWAYS AS IDENTITY column');
is(scalar_query(2,
    "SELECT count(*) FROM pg_attribute WHERE attrelid = 'test_ident'::regclass " .
    "AND attgenerated <> ''"),
   '1', 'Subscriber test_ident has a generated column');

psql_or_bail(1, "INSERT INTO test_merge VALUES (1, 'one', 100), (2, 'two', 200), (3, 'three', 300)");

is(wait_for_query(2, "SELECT COUNT(*) FROM test_merge", '3'), '3',
   'Subscriber has the 3 replicated rows');

# Two rows exist only on the origin.
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_merge VALUES (4, 'four', 400), (5, 'five', 500); COMMIT;");

# One row differs on the subscriber; the merge must leave it alone.
psql_or_bail(2, "BEGIN; SELECT spock.repair_mode(true); UPDATE test_merge SET value = 999 WHERE id = 2; COMMIT;");

is(scalar_query(1, "SELECT COUNT(*) FROM test_merge"), '5', 'Origin has 5 rows');
is(scalar_query(2, "SELECT COUNT(*) FROM test_merge"), '3', 'Subscriber still has 3 rows');

# -----------------------------------------------------------------------------
# 1. merge and truncate together make no sense.
# -----------------------------------------------------------------------------
my $out = psql_capture(2,
    "SELECT spock.sub_resync_table('$sub_name', 'public.test_merge', truncate := true, merge := true)");
like($out, qr/cannot merge.*truncat/i, 'merge together with truncate is rejected');
is(scalar_query(2, "SELECT COUNT(*) FROM test_merge"), '3',
   'Rejected call did not truncate the table');

# -----------------------------------------------------------------------------
# 2. merge needs a unique index to detect the rows already present.
# -----------------------------------------------------------------------------
$out = psql_capture(2,
    "SELECT spock.sub_resync_table('$sub_name', 'public.test_nokey', truncate := false, merge := true)");
like($out, qr/unique|primary key/i, 'merge on a table without a unique index is rejected');

# -----------------------------------------------------------------------------
# 3. A partial unique index leaves rows outside its predicate unconstrained.
# -----------------------------------------------------------------------------
$out = psql_capture(2,
    "SELECT spock.sub_resync_table('$sub_name', 'public.test_partial', truncate := false, merge := true)");
like($out, qr/unique|primary key/i, 'merge on a table with only a partial unique index is rejected');

# -----------------------------------------------------------------------------
# 4. merge adds the missing rows and keeps the existing ones.
# -----------------------------------------------------------------------------
my $log_pos = -s $n2_logfile;
$out = psql_capture(2,
    "SELECT spock.sub_resync_table('$sub_name', 'public.test_merge', truncate := false, merge := true)");
like($out, qr/^\s*t\s*$/m, 'merge resync request accepted');

is(wait_for_table_sync_status(2, 'test_merge', 'r'), 'r',
   'table sync reached the replicating state');

# 5 rows on the provider, 3 of them already here.
like(log_since($log_pos),
     qr/finished synchronization of data for table public\.test_merge, added 2 of 5 copied row\(s\)/,
     'Populated target was staged and merged, and both counts were reported');

is(scalar_query(2, "SELECT COUNT(*) FROM test_merge"), '5',
   'Subscriber has 5 rows after the merge');
is(scalar_query(2, "SELECT value FROM test_merge WHERE id = 2"), '999',
   'Locally changed row was kept, not overwritten');
is(scalar_query(2, "SELECT string_agg(id::text, ',' ORDER BY id) FROM test_merge WHERE id IN (4, 5)"), '4,5',
   'The two missing rows were added');

# The table must still replicate after the merge.
psql_or_bail(1, "INSERT INTO test_merge VALUES (6, 'six', 600)");
is(wait_for_query(2, "SELECT COUNT(*) FROM test_merge", '6'), '6',
   'Table keeps replicating after the merge');

# -----------------------------------------------------------------------------
# 5. merge into a table that is empty on the subscriber.  This is the path
#    that locks the table and copies straight into it instead of staging.
# -----------------------------------------------------------------------------
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_empty VALUES (1, 10), (2, 20); COMMIT;");
is(scalar_query(2, "SELECT COUNT(*) FROM test_empty"), '0',
   'Subscriber copy of test_empty is empty');

$log_pos = -s $n2_logfile;
$out = psql_capture(2,
    "SELECT spock.sub_resync_table('$sub_name', 'public.test_empty', truncate := false, merge := true)");
like($out, qr/^\s*t\s*$/m, 'merge resync of an empty table accepted');

is(wait_for_table_sync_status(2, 'test_empty', 'r'), 'r',
   'empty-table merge reached the replicating state');

# No row counts in the message means the copy went straight into the table,
# so the lock was taken and held rather than the staging path being used.
my $empty_log = log_since($log_pos);
like($empty_log,
     qr/finished synchronization of data for table public\.test_empty\s*$/m,
     'Empty target was locked and copied into directly, not staged');
unlike($empty_log, qr/could not lock public\.test_empty/,
       'The table lock was acquired rather than timing out');
is(scalar_query(2, "SELECT string_agg(id::text, ',' ORDER BY id) FROM test_empty"), '1,2',
   'Both rows copied into the empty table');

psql_or_bail(1, "INSERT INTO test_empty VALUES (3, 30)");
is(wait_for_query(2, "SELECT COUNT(*) FROM test_empty", '3'), '3',
   'test_empty keeps replicating after the merge');

# -----------------------------------------------------------------------------
# 6. Identity and generated columns.  The merge inserts the origin's identity
#    values, which needs OVERRIDING SYSTEM VALUE, and lets the target compute
#    the generated column.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO test_ident (value) VALUES (5)");
is(wait_for_query(2, "SELECT COUNT(*) FROM test_ident", '1'), '1',
   'First test_ident row replicated');

psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); INSERT INTO test_ident (value) VALUES (6), (7); COMMIT;");
is(scalar_query(1, "SELECT COUNT(*) FROM test_ident"), '3', 'Origin has 3 test_ident rows');
is(scalar_query(2, "SELECT COUNT(*) FROM test_ident"), '1', 'Subscriber has 1 test_ident row');

$log_pos = -s $n2_logfile;
$out = psql_capture(2,
    "SELECT spock.sub_resync_table('$sub_name', 'public.test_ident', truncate := false, merge := true)");
like($out, qr/^\s*t\s*$/m, 'merge resync of the identity table accepted');

is(wait_for_table_sync_status(2, 'test_ident', 'r'), 'r',
   'identity-table merge reached the replicating state');

like(log_since($log_pos),
     qr/finished synchronization of data for table public\.test_ident, added 2 of 3 copied row\(s\)/,
     'Identity table was staged and merged');
is(scalar_query(2, "SELECT string_agg(id::text, ',' ORDER BY id) FROM test_ident"), '1,2,3',
   'Origin identity values were preserved by the merge');
is(scalar_query(2, "SELECT string_agg(doubled::text, ',' ORDER BY id) FROM test_ident"), '10,12,14',
   'Generated column was recomputed on the subscriber');

destroy_cluster('Destroy 2-node resync merge test cluster');
done_testing();
