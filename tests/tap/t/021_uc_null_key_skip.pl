use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster cross_wire
                 scalar_query psql_or_bail);

# =============================================================================
# 021_uc_null_key_skip.pl - check_all_uc_indexes must NOT scan a unique index
# when the incoming row has a NULL in one of that index's key columns.
#
# A NULL key can never conflict in a unique index (NULLs are distinct), yet the
# proactive scan would otherwise emit an IS NULL search that returns every
# NULL-keyed row, only to discard them all -- an O(rows) scan per insert. This
# test proves the probe is skipped, by comparing index-scan stats on a
# NULL-keyed unique index (must stay ~0) vs a non-null unique index (probed
# per insert).
# =============================================================================

my $NROWS   = $ENV{SPOCK_UC_TEST_ROWS}    // 2000;   # applied inserts (1 txn)
my $SEED    = $ENV{SPOCK_UC_SEED_ROWS}    // 5000;   # pre-existing NULL-keyed rows on n2
my $TIMEOUT = $ENV{SPOCK_UC_TEST_TIMEOUT} // 600;

create_cluster(2, 'Create 2-node cluster for NULL-key UC-skip test');
cross_wire(2, ['n1', 'n2']);
psql_or_bail(1, "SELECT spock.sub_drop('sub_n1_n2')");   # one-directional n1 -> n2
sleep(3);

psql_or_bail(2, "ALTER SYSTEM SET spock.check_all_uc_indexes = on");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(2);

# nk = nullable unique key column (always NULL here); nn = non-null unique key.
psql_or_bail(1, "CREATE TABLE nulltest (id bigint PRIMARY KEY, grp int NOT NULL, nn text NOT NULL, nk text)");
psql_or_bail(1, "CREATE UNIQUE INDEX nulltest_nn_uidx ON nulltest (grp, nn)");
psql_or_bail(1, "CREATE UNIQUE INDEX nulltest_nk_uidx ON nulltest (grp, nk)");

my $got = 0;
for (1 .. 60) {
    $got = scalar_query(2, "SELECT count(*) FROM pg_indexes WHERE tablename='nulltest'") // 0;
    last if $got >= 3;   # pk + 2 unique
    sleep(1);
}
is($got, 3, "nulltest + 2 unique indexes replicated to n2");

# Pre-seed n2 (local) with NULL-keyed rows so an IS NULL scan would return many.
psql_or_bail(2, "INSERT INTO nulltest SELECT g, 1, 'seed-'||g, NULL FROM generate_series(1, $SEED) g");
is(scalar_query(2, "SELECT count(*) FROM nulltest"), $SEED, "n2 pre-seeded with $SEED NULL-keyed rows");

sub idx_stat {
    my ($name, $col) = @_;
    return scalar_query(2,
        "SELECT coalesce($col, 0) FROM pg_stat_user_indexes WHERE indexrelname = '$name'") // 0;
}

# Baseline (local seed inserts maintain the index but do not proactively scan).
my $base_nk_scan = idx_stat('nulltest_nk_uidx', 'idx_scan');
my $base_nn_scan = idx_stat('nulltest_nn_uidx', 'idx_scan');
my $base_nk_read = idx_stat('nulltest_nk_uidx', 'idx_tup_read');

# Apply N inserts from n1: new PKs (so PK lookup misses -> proactive UC scan),
# non-null nn, NULL nk.
psql_or_bail(1, "INSERT INTO nulltest SELECT 1000000+g, 1, 'app-'||g, NULL FROM generate_series(1, $NROWS) g");
my $applied = 0;
for (1 .. $TIMEOUT) {
    $applied = scalar_query(2, "SELECT count(*) FROM nulltest WHERE id > 1000000") // 0;
    last if $applied >= $NROWS;
    sleep(1);
}
ok($applied >= $NROWS, "n2 applied $NROWS rows (got $applied) within ${TIMEOUT}s")
    or BAIL_OUT("no catch-up");
sleep(3);   # let the apply worker flush cumulative index stats

my $nk_scan = idx_stat('nulltest_nk_uidx', 'idx_scan')     - $base_nk_scan;
my $nn_scan = idx_stat('nulltest_nn_uidx', 'idx_scan')     - $base_nn_scan;
my $nk_read = idx_stat('nulltest_nk_uidx', 'idx_tup_read') - $base_nk_read;

# The non-null unique index must be probed once per applied insert -- this
# proves the proactive scan actually ran (so a passing NULL assertion is real).
ok($nn_scan >= $NROWS * 0.9,
   "non-null unique index probed per insert (idx_scan +$nn_scan, expected ~$NROWS)");

# The NULL-keyed unique index must NOT be scanned (the fix skips it).
ok($nk_scan <= 5,
   "NULL-key unique index NOT scanned (idx_scan +$nk_scan, expected ~0)");

# And it must not have read any tuples -- without the fix this would be ~N*SEED.
ok($nk_read <= $SEED,
   "no O(rows) IS NULL scan on the NULL-key index (idx_tup_read +$nk_read)");

diag(sprintf(<<'REPORT', $NROWS, $SEED, $nn_scan, $nk_scan, $nk_read, $NROWS * $SEED));

============ NULL-key UC-skip ============
  applied=%d inserts, pre-seeded NULL rows=%d
  non-null index idx_scan delta : %d   (probed -- expected ~applied)
  NULL  index idx_scan delta    : %d   (expected ~0 with fix)
  NULL  index idx_tup_read delta: %d   (expected 0 with fix; ~%d without)
==========================================
REPORT

destroy_cluster('Destroy NULL-key UC-skip test cluster');
done_testing();
