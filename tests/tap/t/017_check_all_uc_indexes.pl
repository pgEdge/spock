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
# cost on a wide table with a realistic index mix: a few multi-column UNIQUE
# constraints that share a leading column, plus many ordinary non-unique indexes (all of
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

# Index layout: a few multi-column UNIQUE constraints that all
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
if (defined $ENV{SPOCK_UC_REPLAY_QSIZE}) {    # raw bytes; large value makes the
    # exception replay queue buffer the whole txn in ApplyReplayContext (memory test)
    psql_or_bail(2, "ALTER SYSTEM SET spock.exception_replay_queue_size = $ENV{SPOCK_UC_REPLAY_QSIZE}");
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

# Publisher-side (n1) logical-slot snapshot. While the
# apply worker is mid-transaction the subscriber shows 0 newly-applied rows and
# the publisher's restart_lsn stays FROZEN, so the WAL it pins cannot be released
# (retainedWAL keeps growing if the publisher keeps writing).
# NB: scalar_query() strips all whitespace from the result, so fields are
# delimited with '|' (and slots separated by '||') to stay readable, and PIDs
# are joined with ':' rather than spaces.
sub slot_snapshot {
    my $q = "SELECT coalesce(string_agg("
          . "slot_name || '|restart=' || coalesce(restart_lsn::text,'-')"
          . " || '|confirmed=' || coalesce(confirmed_flush_lsn::text,'-')"
          . " || '|retainedWAL=' || pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))"
          . " || '|active=' || active::text, ' || '), 'no logical slots')"
          . " FROM pg_replication_slots WHERE slot_type = 'logical'";
    return scalar_query(1, $q);
}

# Name of the active logical slot on n1 currently pinning the most WAL (the one
# feeding the n2 apply during the conflict load).
sub pinned_slot {
    return scalar_query(1,
        "SELECT slot_name FROM pg_replication_slots "
      . "WHERE slot_type = 'logical' AND active AND restart_lsn IS NOT NULL "
      . "ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC LIMIT 1");
}

# (restart_lsn bytes-from-0, retained WAL bytes) for a named slot on n1.
sub slot_lsns {
    my ($name) = @_;
    my $r = scalar_query(1,
        "SELECT coalesce(pg_wal_lsn_diff(restart_lsn, '0/0')::bigint, 0) || ':' "
      . "|| coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint, 0) "
      . "FROM pg_replication_slots WHERE slot_name = '$name'");
    my ($restart, $retained) = split /:/, ($r // '0:0');
    return ($restart || 0, $retained || 0);
}

# n2 apply-worker resident memory (RSS, MB); tracks the peak across the run.
# A long single-transaction apply accumulates per-row allocations until COMMIT,
# so RSS climbs the whole time the worker is mid-transaction.
my $peak_rss_mb = 0;
our $LAST_APPLY_PID = '';
sub apply_rss {
    my $pidstr = scalar_query(2,
        "SELECT coalesce(string_agg(pid::text, ':'), '') FROM pg_stat_activity "
      . "WHERE backend_type ILIKE '%apply%'");
    my $total_kb = 0;
    for my $pid (split /:/, $pidstr) {
        next unless $pid =~ /^\d+$/;
        $LAST_APPLY_PID = $pid;
        my $kb = `ps -o rss= -p $pid 2>/dev/null`;
        $kb =~ s/\D//g;
        $total_kb += $kb if $kb ne '';
    }
    my $mb = $total_kb / 1024;
    $peak_rss_mb = $mb if $mb > $peak_rss_mb;
    return sprintf('%.0fMB peak=%.0fMB pid=%s', $mb, $peak_rss_mb, $pidstr || '-');
}

# SPOCK_UC_DEEP=1: apply-worker activity (state/wait/xact age), plus a one-shot
# memory-context dump (to n2's server log) and stack sample during the conflict
# phase -- to attribute the RSS growth and the slowness.
my %deep_done;
sub deep_probe {
    my ($pid, $label, $elapsed) = @_;
    return '' unless $pid =~ /^\d+$/;
    my $act = scalar_query(2,
        "SELECT coalesce(state,'-') || '|' || coalesce(wait_event_type,'-') || '.'"
      . " || coalesce(wait_event,'-') || '|xact='"
      . " || coalesce((extract(epoch from now() - xact_start))::int::text,'-') || 's'"
      . " FROM pg_stat_activity WHERE pid = $pid");
    # Once per phase (after it's been running a bit): dump the apply worker's top
    # memory contexts (which context holds the GB?) and grab a stack sample.
    if (!$deep_done{$label} && $elapsed >= 18) {
        $deep_done{$label} = 1;
        my $mem = scalar_query(2,
            "SELECT coalesce(string_agg(name || '=' || pg_size_pretty(total_bytes), ',' "
          . "ORDER BY total_bytes DESC), '?') FROM (SELECT name, sum(total_bytes) total_bytes "
          . "FROM pg_get_process_memory_contexts($pid, true, 10) GROUP BY name "
          . "ORDER BY 2 DESC LIMIT 6) t");
        (my $tag = $label) =~ s/[^a-z]//g;
        system("sample $pid 3 -file /tmp/apply_sample_$tag.txt >/dev/null 2>&1");
        diag("[deep $label] top-mem-contexts: $mem  (stack -> /tmp/apply_sample_$tag.txt)");
    }
    return "  worker: $act";
}

sub wait_count {    # poll n2 until $expect rows match $where; elapsed secs or -1
    my ($where, $expect, $t0, $label) = @_;
    $label //= $where;
    for my $i (1 .. $TIMEOUT) {
        my $n = scalar_query(2, "SELECT count(*) FROM uctest WHERE $where");
        if ($ENV{SPOCK_UC_MONITOR} && ($i == 1 || $i % 15 == 0)) {
            my $rss  = apply_rss();
            my $deep = $ENV{SPOCK_UC_DEEP}
                     ? deep_probe($LAST_APPLY_PID, $label, int(time() - $t0)) : '';
            diag(sprintf("[%s +%4ds] n2-applied=%s  apply-rss=%s%s  n1-slot: %s",
                         $label, int(time() - $t0), (defined $n ? $n : '?'),
                         $rss, $deep, slot_snapshot()));
        }
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

# Baseline the publisher slot while the apply is in flight: restart_lsn is frozen
# and WAL is pinned for the whole single-transaction apply.
my $pin_slot = pinned_slot();
my ($restart_frozen, $retained_peak) = slot_lsns($pin_slot);
diag(sprintf("during apply: slot=%s restart_lsn pinned, retainedWAL=%.2f GB",
             $pin_slot, $retained_peak / 1073741824)) if $ENV{SPOCK_UC_MONITOR};

my $t_conf = wait_count("payload='conf'", $NROWS, $t0, 'conf');
ok($t_conf >= 0, "GUC-ON+CONFLICT: $NROWS rows resolved (GUC on) within ${TIMEOUT}s")
    or diag("no catch-up on conflict load within ${TIMEOUT}s");

# After the transaction commits the pin must release: restart_lsn advances past
# the big transaction and the retained WAL drops.  Nudge the publisher with
# pg_log_standby_snapshot() so logical decoding establishes a new restart point.
my ($restart_after, $retained_after) = ($restart_frozen, $retained_peak);
for (1 .. 120) {
    psql_or_bail(1, "SELECT pg_log_standby_snapshot()") if $_ % 5 == 1;
    ($restart_after, $retained_after) = slot_lsns($pin_slot);
    last if $restart_after > $restart_frozen && $retained_after < $retained_peak;
    sleep(1);
}
ok($restart_after > $restart_frozen,
   sprintf("slot %s restart_lsn advanced after commit (+%.1f MB)",
           $pin_slot, ($restart_after - $restart_frozen) / 1048576));
ok($retained_after < $retained_peak,
   sprintf("retained WAL released after commit: %.2f GB -> %.2f GB",
           $retained_peak / 1073741824, $retained_after / 1073741824));

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
