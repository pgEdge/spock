use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster cross_wire
                 scalar_query psql_or_bail);
use Time::HiRes qw(time);

# =============================================================================
# 017_check_all_uc_indexes.pl - cost of spock.check_all_uc_indexes on the apply
# =============================================================================
# spock.check_all_uc_indexes ON makes the INSERT apply path scan the table's
# unique indexes (to find/resolve a conflicting row). This test isolates that
# cost on a customer-shaped wide table: a few multi-column UNIQUE constraints
# that share a leading column, plus many ordinary non-unique indexes (all of
# which are still maintained on every insert). It runs three scenarios:
#
#   * GUC-OFF          : non-colliding inserts, GUC off -> no scan (baseline).
#   * GUC-ON           : non-colliding inserts, GUC on  -> full not-found scan
#                        of every unique index per insert. GUC-ON/GUC-OFF is
#                        the scan cost.
#   * GUC-ON+CONFLICT  : inserts colliding with seeded rows on the LAST unique
#                        compound index, GUC on -> scan + INSERT->UPDATE resolve.
#
# Runs one-directional (n1 -> n2): n2 is seeded with rows n1 lacks so the
# conflict inserts succeed on n1 but conflict on apply.
#
# Key type matters: bigint probes are cheap; uuid/text keys probe far costlier.
# Choose via SPOCK_UC_KEYTYPE = bigint | uuid | text (default bigint).
#
# Tunables: SPOCK_UC_TEST_ROWS (200000), SPOCK_UC_TEST_TIMEOUT (900),
#   SPOCK_UC_KEYTYPE, SPOCK_UC_SAVE_RESOLUTIONS, SPOCK_UC_PROD_LOGS,
#   SPOCK_UC_CONFLICT_LOG_LEVEL.
# =============================================================================

my $NROWS   = $ENV{SPOCK_UC_TEST_ROWS}    // 200_000;
my $NCOL    = 20;                                      # 20 data columns c00..c19
my $TIMEOUT = $ENV{SPOCK_UC_TEST_TIMEOUT} // 900;
my $KEYTYPE = $ENV{SPOCK_UC_KEYTYPE}      // 'bigint';

# Index layout (customer-shaped): a few multi-column UNIQUE constraints that all
# share a leading column, plus many ordinary non-unique indexes.  Only the
# unique ones drive spock.check_all_uc_indexes; all are maintained on insert.
my $LEAD      = 0;                   # shared leading column of the unique compound indexes
my @UQ_SECOND = (1, 2, 3, 4);        # second columns -> 4 unique indexes (c00,c01)..(c00,c04)
my @NONUNIQUE = (0, 5 .. $NCOL - 1); # 16 non-unique single-column indexes
my $NUNIQUE   = scalar @UQ_SECOND;   # 4
my $NIDX      = $NUNIQUE + scalar @NONUNIQUE;   # 20 secondary indexes (+ PK)

my %CT = (bigint => 'bigint', uuid => 'uuid', text => 'text');
my $CTYPE = $CT{$KEYTYPE} or die "SPOCK_UC_KEYTYPE must be bigint|uuid|text\n";

# Map a numeric SQL expression (in terms of g) to the chosen key type, keeping it
# deterministic so collisions can be engineered: equal numeric => equal key.
sub kv {
    my ($n) = @_;
    return "($n)"                                 if $KEYTYPE eq 'bigint';
    return "md5(($n)::text)::uuid"                if $KEYTYPE eq 'uuid';
    return "(md5(($n)::text) || md5(($n)::text))" if $KEYTYPE eq 'text';  # ~64-char token
}

create_cluster(2, 'Create 2-node cluster for check_all_uc_indexes test');
cross_wire(2, ['n1', 'n2']);

# One-directional n1 -> n2: drop n1's subscription so n2 seed rows stay divergent.
psql_or_bail(1, "SELECT spock.sub_drop('sub_n1_n2')");
sleep(3);

# Logging / resolution knobs (applied on the subscriber, n2).
if (defined $ENV{SPOCK_UC_SAVE_RESOLUTIONS}) {
    psql_or_bail(2, "ALTER SYSTEM SET spock.save_resolutions = $ENV{SPOCK_UC_SAVE_RESOLUTIONS}");
}
if ($ENV{SPOCK_UC_PROD_LOGS}) {
    for my $g ('log_min_messages = warning', 'log_statement = none',
               'log_min_duration_statement = -1', 'log_statement_stats = off') {
        psql_or_bail(2, "ALTER SYSTEM SET $g");
    }
}
if (defined $ENV{SPOCK_UC_CONFLICT_LOG_LEVEL}) {
    psql_or_bail(2, "ALTER SYSTEM SET spock.conflict_log_level = $ENV{SPOCK_UC_CONFLICT_LOG_LEVEL}");
}
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(1);

sub set_uc {    # toggle spock.check_all_uc_indexes on n2 and let the apply worker reload
    my ($v) = @_;
    psql_or_bail(2, "ALTER SYSTEM SET spock.check_all_uc_indexes = $v");
    psql_or_bail(2, "SELECT pg_reload_conf()");
    sleep(2);
}

# --- Wide table + $NIDX indexes ($NUNIQUE unique compound + non-unique) on n1 ---
my $coldefs = join(', ', map { sprintf('c%02d %s', $_, $CTYPE) } 0 .. $NCOL - 1);
psql_or_bail(1, "CREATE TABLE uctest (id bigint PRIMARY KEY, $coldefs, payload text)");
# Index collation. Default to "C" (byte comparison -- avoids per-compare strcoll
# on text keys); set SPOCK_UC_INDEX_COLLATE='' for the database default collation,
# or to any collation name to override.
my $ICOLL_NAME = $ENV{SPOCK_UC_INDEX_COLLATE} // 'C';
my $ICOLL = $ICOLL_NAME ? qq{ COLLATE "$ICOLL_NAME"} : '';
# UNIQUE compound indexes, all sharing leading column c%02d (a few multi-column
# unique constraints on text columns -- the shape we care about).
for my $j (@UQ_SECOND) {
    psql_or_bail(1, sprintf('CREATE UNIQUE INDEX uctest_uq_c%02d_c%02d ON uctest (c%02d%s, c%02d%s)',
                  $LEAD, $j, $LEAD, $ICOLL, $j, $ICOLL));
}
# Non-unique single-column indexes: maintained on every insert, but not
# scanned by check_all_uc_indexes for conflicts.
for my $j (@NONUNIQUE) {
    psql_or_bail(1, sprintf('CREATE INDEX uctest_ix_c%02d ON uctest (c%02d%s)', $j, $j, $ICOLL));
}

my $want_idx = $NIDX + 1;
my $got_idx  = 0;
for (1 .. 60) {
    $got_idx = scalar_query(2, "SELECT count(*) FROM pg_indexes WHERE tablename = 'uctest'");
    last if $got_idx && $got_idx >= $want_idx;
    sleep(1);
}
is($got_idx, $want_idx,
   "uctest + $NIDX indexes ($NUNIQUE unique compound, $KEYTYPE keys) replicated to n2");

sub wait_count {    # poll n2 until $expect rows match $where; elapsed secs or -1
    my ($where, $expect, $t0) = @_;
    for (1 .. $TIMEOUT) {
        my $n = scalar_query(2, "SELECT count(*) FROM uctest WHERE $where");
        return time() - $t0 if defined $n && $n >= $expect;
        sleep(1);
    }
    return -1;
}
sub vals { my ($fn) = @_; return join(', ', map { kv($fn->($_)) } 0 .. $NCOL - 1); }

# Seed n2 (conflict targets): every column = g.
psql_or_bail(2, "INSERT INTO uctest SELECT g, " . vals(sub { 'g' })
              . ", 'base' FROM generate_series(1, $NROWS) g");
is(scalar_query(2, "SELECT count(*) FROM uctest WHERE payload='base'"), $NROWS,
   "n2 seeded with $NROWS rows");

my ($t0, $t_off, $t_on) = (0, 0, 0);
if ($ENV{SPOCK_UC_ONLY_CONFLICT}) {
    set_uc('on');    # conflict scenario needs the GUC on
}
else {
# Scenario 1 - GUC-OFF: GUC off, non-colliding inserts (no scan, baseline).
set_uc('off');
$t0 = time();
psql_or_bail(1, "INSERT INTO uctest SELECT 5000000+g, " . vals(sub { '(2000000 + g)' })
              . ", 'gucoff' FROM generate_series(1, $NROWS) g");
$t_off = wait_count("payload='gucoff'", $NROWS, $t0);
ok($t_off >= 0, "GUC-OFF: $NROWS rows applied (GUC off) within ${TIMEOUT}s")
    or BAIL_OUT("no catch-up on GUC-OFF load");

# Scenario 2 - GUC-ON: GUC on, non-colliding inserts (full not-found scan per insert).
set_uc('on');
$t0 = time();
psql_or_bail(1, "INSERT INTO uctest SELECT 7000000+g, " . vals(sub { '(3000000 + g)' })
              . ", 'gucon' FROM generate_series(1, $NROWS) g");
$t_on = wait_count("payload='gucon'", $NROWS, $t0);
ok($t_on >= 0, "GUC-ON: $NROWS rows applied (GUC on) within ${TIMEOUT}s")
    or diag("no catch-up on GUC-ON load within ${TIMEOUT}s");
}

# Scenario 3 - GUC-ON+CONFLICT: GUC on, collide with seed row g on the LAST
# unique compound index only -- (c00, c04).  Match the shared lead column and
# that index's second column to seed g; keep the other unique second columns
# distinct so exactly one unique index conflicts (single resolvable target).
my $last_uq = $UQ_SECOND[-1];
my $conf_vals = vals(sub {
    my $c = shift;
    return 'g'             if $c == $LEAD || $c == $last_uq;   # -> conflict on (c00,c04)
    return '(7000000 + g)' if grep { $_ == $c } @UQ_SECOND;    # other unique second cols: no collision
    return sprintf('(%d + g)', (10 + $c) * 10_000_000);        # non-unique columns: distinct
});
$t0 = time();
psql_or_bail(1, "INSERT INTO uctest SELECT 6000000+g, $conf_vals, 'conf' FROM generate_series(1, $NROWS) g");
my $t_conf = wait_count("payload='conf'", $NROWS, $t0);
ok($t_conf >= 0, "GUC-ON+CONFLICT: $NROWS rows resolved (GUC on) within ${TIMEOUT}s")
    or diag("no catch-up on conflict load within ${TIMEOUT}s");

# Integrity: n2 = seed + gucoff + gucon (+ conflict resolves into seed) = 3*NROWS.
unless ($ENV{SPOCK_UC_ONLY_CONFLICT}) {
is(scalar_query(2, "SELECT count(*) FROM uctest"), 3 * $NROWS,
   "n2 row count = 3*$NROWS after seed + GUC-OFF + GUC-ON (+ resolved conflict)");
}

# --- Summary report: per-scenario apply time, then the cost each step adds ---
my $scan_x  = ($t_off > 0 && $t_on   >= 0) ? sprintf('%.2fx', $t_on   / $t_off) : 'n/a';
my $conf_x  = ($t_off > 0 && $t_conf >= 0) ? sprintf('%.2fx', $t_conf / $t_off) : 'n/a';
my $conf_xo = ($t_on  > 0 && $t_conf >= 0) ? sprintf('%.2fx', $t_conf / $t_on)  : 'n/a';
diag(sprintf(<<'REPORT', $KEYTYPE, $NROWS, $NIDX, $NUNIQUE, $t_off, $t_on, $t_conf, $scan_x, $conf_xo, $conf_x));

============== spock.check_all_uc_indexes apply cost ==============
  keys=%s  rows=%d  indexes=%d (%d unique compound)

  apply time per scenario:
    GUC-OFF          : %6.1fs   (baseline -- no index scan)
    GUC-ON           : %6.1fs   (baseline + per-insert unique-index scan)
    GUC-ON+CONFLICT  : %6.1fs   (scan + INSERT->UPDATE resolution)

  cost added by each step (slowdown factor):
    scan overhead    GUC-ON          / GUC-OFF : %s
    resolve overhead GUC-ON+CONFLICT / GUC-ON  : %s
    total overhead   GUC-ON+CONFLICT / GUC-OFF : %s
==================================================================
REPORT

destroy_cluster('Destroy check_all_uc_indexes test cluster');
done_testing();
