use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail get_test_config scalar_query psql_or_bail);

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
# 3. merge adds the missing rows, keeps a locally changed row unchanged, and
#    leaves the table replicating afterwards.

create_cluster(2, 'Create 2-node cluster for resync merge test');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $pg_bin = $config->{pg_bin};
my $dbname = $config->{db_name};

my $sub_name = 'sub_n2_n1';

sub psql_capture {
    my ($node_num, $sql) = @_;
    my $port = $node_ports->[$node_num - 1];
    return `$pg_bin/psql -X -p $port -d $dbname -t -c "$sql" 2>&1`;
}

# Poll a table's row in spock.local_sync_status until it reads $expected.
sub wait_for_table_sync_status {
    my ($node_num, $relname, $expected, $timeout) = @_;
    $timeout //= 60;
    my $st = '';
    for (1 .. $timeout) {
        $st = scalar_query($node_num,
            "SELECT sync_status FROM spock.local_sync_status " .
            "WHERE sync_relname = '$relname'");
        return $st if defined $st && $st eq $expected;
        sleep(1);
    }
    return $st;
}

psql_or_bail(1,
    "CREATE TABLE test_merge (
        id INTEGER PRIMARY KEY,
        name TEXT,
        value INTEGER
    )"
);
psql_or_bail(1, "CREATE TABLE test_nokey (id INTEGER, value INTEGER)");

# Wait for DDL replication.
system_or_bail 'sleep', '5';

psql_or_bail(1, "INSERT INTO test_merge VALUES (1, 'one', 100), (2, 'two', 200), (3, 'three', 300)");
system_or_bail 'sleep', '3';

is(scalar_query(2, "SELECT COUNT(*) FROM test_merge"), '3',
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
# 3. merge adds the missing rows and keeps the existing ones.
# -----------------------------------------------------------------------------
$out = psql_capture(2,
    "SELECT spock.sub_resync_table('$sub_name', 'public.test_merge', truncate := false, merge := true)");
like($out, qr/^\s*t\s*$/m, 'merge resync request accepted');

my $status = wait_for_table_sync_status(2, 'test_merge', 'r', 60);
is($status, 'r', 'table sync reached the replicating state');

is(scalar_query(2, "SELECT COUNT(*) FROM test_merge"), '5',
   'Subscriber has 5 rows after the merge');
is(scalar_query(2, "SELECT value FROM test_merge WHERE id = 2"), '999',
   'Locally changed row was kept, not overwritten');
is(scalar_query(2, "SELECT string_agg(id::text, ',' ORDER BY id) FROM test_merge WHERE id IN (4, 5)"), '4,5',
   'The two missing rows were added');

# The table must still replicate after the merge.
psql_or_bail(1, "INSERT INTO test_merge VALUES (6, 'six', 600)");
system_or_bail 'sleep', '3';
is(scalar_query(2, "SELECT COUNT(*) FROM test_merge"), '6',
   'Table keeps replicating after the merge');

destroy_cluster('Destroy 2-node resync merge test cluster');
done_testing();
