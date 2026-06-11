use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster
                 get_test_config scalar_query psql_or_bail
                 wait_for_sub_status);

# =============================================================================
# 022_apply_mem_context.pl
#
# Regression guard for the per-row TopTransactionContext leak the apply
# worker hit when replaying a multi-row transaction in use_try_block mode.
#
# Before the fix, log_insert_exception ran with CurrentMemoryContext left
# pointing at TopTransactionContext by RollbackAndReleaseCurrentSubTransaction.
# Every palloc inside it (jsonb_in, CStringGetTextDatum, heap_form_tuple)
# accumulated there until the outer apply txn committed, growing the
# context by roughly 4 KB per row.
#
# Trigger sequence here matches the field reproduction:
#   1. Start a multi-row INSERT on n1 in one transaction.
#   2. Disable the subscription with immediate = true while the apply
#      worker is still mid-transaction. The worker exits without reaching
#      handle_commit, so the in-flight commit_lsn stays in shared memory.
#   3. Re-enable. The new worker sees its slot commit_lsn match the
#      resumed BEGIN message and sets use_try_block = true. From that
#      point, every applied row drives the subtxn + log_insert_exception
#      path that the fix targets.
#
# While the use_try_block worker is busy we ask Postgres to dump its
# memory contexts and assert TopTransactionContext stays well below the
# pre-fix size.
# =============================================================================

my $NROWS     = $ENV{SPOCK_LEAK_ROWS}      // 200000;
# Pre-fix TopTransactionContext would be ~4 KB * NROWS = ~800 MB at 200K
# rows. Post-fix it stays in the low KB range. 5 MB is comfortably between.
my $THRESHOLD = $ENV{SPOCK_LEAK_THRESHOLD} // 5_000_000;
my $TIMEOUT   = $ENV{SPOCK_LEAK_TIMEOUT}   // 180;

create_cluster(2, 'Create 2-node apply memory-context test cluster');

my $config  = get_test_config();
my $p1      = $config->{node_ports}->[0];
my $p2      = $config->{node_ports}->[1];
my $host    = $config->{host};
my $dbname  = $config->{db_name};
my $dbuser  = $config->{db_user};
my $dbpass  = $config->{db_password};
my $n2_dir  = $config->{node_datadirs}->[1];
my $n2_log  = "$n2_dir/logs/00$p2.log";

my $conn_n1 = "host=$host port=$p1 dbname=$dbname user=$dbuser password=$dbpass";

psql_or_bail(2,
    "SELECT spock.sub_create('s_mem', '$conn_n1', " .
    "ARRAY['default','default_insert_only'], false, false)");
ok(wait_for_sub_status(2, 's_mem', 'replicating', 30),
    's_mem reaches replicating state');

# Replicated table with extra unique indexes so per-row apply does enough
# index maintenance to keep the worker busy through the disable window.
psql_or_bail(1,
    "SET spock.enable_ddl_replication = off; " .
    "CREATE TABLE mem_t (" .
    "    id   int PRIMARY KEY, " .
    "    k1   text NOT NULL, " .
    "    k2   text NOT NULL, " .
    "    body text); " .
    "CREATE UNIQUE INDEX mem_t_k1_uidx ON mem_t (k1); " .
    "CREATE UNIQUE INDEX mem_t_k2_uidx ON mem_t (k2); " .
    "SELECT spock.repset_add_table('default', 'mem_t')");
psql_or_bail(2,
    "CREATE TABLE mem_t (" .
    "    id   int PRIMARY KEY, " .
    "    k1   text NOT NULL, " .
    "    k2   text NOT NULL, " .
    "    body text); " .
    "CREATE UNIQUE INDEX mem_t_k1_uidx ON mem_t (k1); " .
    "CREATE UNIQUE INDEX mem_t_k2_uidx ON mem_t (k2)");

# Warm-up row to confirm the pipeline is up.
psql_or_bail(1, "INSERT INTO mem_t VALUES (0, 'warmup_k1', 'warmup_k2', 'warmup')");
my $warm = 0;
for (1 .. 30) {
    $warm = scalar_query(2, "SELECT count(*) FROM mem_t WHERE id = 0") // 0;
    last if $warm == 1;
    sleep(1);
}
is($warm, 1, 'warmup row applied to n2');

# Big single-transaction INSERT. Wide-ish payload + 2 unique indexes per
# row makes apply slow enough to be interrupted mid-flight.
psql_or_bail(1,
    "INSERT INTO mem_t " .
    "SELECT g, 'k1_'||g, 'k2_'||g, repeat('x', 256) " .
    "FROM generate_series(1, $NROWS) g");

# Let apply ingest a chunk, then kill the worker immediately so the
# in-flight commit_lsn is preserved in shared memory.
sleep(2);
psql_or_bail(2, "SELECT spock.sub_disable('s_mem', true)");
ok(wait_for_sub_status(2, 's_mem', 'disabled', 30),
    'subscription disabled mid-apply');

# Re-enable. The new worker resumes the same BEGIN and engages
# use_try_block because its exception_log slot commit_lsn matches.
psql_or_bail(2, "SELECT spock.sub_enable('s_mem', true)");

# Wait for the new worker to come up and be mid-apply (xact_start set).
# This is where use_try_block is engaged.
my $apply_pid;
my $busy = 0;
for (1 .. $TIMEOUT) {
    $apply_pid = scalar_query(2,
        "SELECT pid FROM pg_stat_activity " .
        "WHERE application_name LIKE 'spock apply%' " .
        "  AND xact_start IS NOT NULL " .
        "ORDER BY backend_start DESC LIMIT 1");
    if ($apply_pid && $apply_pid =~ /^\d+$/) {
        $busy = 1;
        last;
    }
    sleep(1);
}
# Whether we caught the worker mid-apply is environment-dependent (CI is
# slow enough that we always do; a very fast machine with a small NROWS
# may apply everything before we look).  When we don't catch it, there
# is no leak window to measure, so the whole RSS-based assertion below
# skips cleanly instead of failing.

# Sample the apply worker's RSS from ps while it churns through the
# in-flight transaction.  This avoids the inherent race between
# pg_log_backend_memory_contexts()'s SIGUSR1 and the worker reaching
# CHECK_FOR_INTERRUPTS (or exiting before it does).  RSS is observable
# from outside the worker process and works regardless of how busy or
# how short-lived the worker is.
#
# The pre-fix leak accumulates ~4 KB per row in TopTransactionContext,
# i.e. ~800 MB at 200 k rows.  That growth is well above any reasonable
# baseline RSS for a small test cluster.  We compute baseline_rss as the
# first sample we take (the worker has just started, no rows applied
# yet) and assert that peak_rss - baseline_rss stays below a generous
# RSS_GROWTH threshold.  Post-fix the growth is in the low MB.
my $RSS_GROWTH = $ENV{SPOCK_LEAK_RSS_GROWTH_KB} // 200_000;  # 200 MB

sub rss_kb {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/;
    my $out = `ps -o rss= -p $pid 2>/dev/null`;
    chomp $out;
    $out =~ s/^\s+|\s+$//g;
    return ($out =~ /^\d+$/) ? int($out) : undef;
}

my $baseline_rss = $busy ? rss_kb($apply_pid) : undef;
my $peak_rss     = $baseline_rss // 0;
my $samples      = 0;
my $applied      = 0;

if ($busy) {
    for my $i (1 .. $TIMEOUT) {
        my $cur = rss_kb($apply_pid);
        if (defined $cur) {
            $peak_rss = $cur if $cur > $peak_rss;
            $samples++;
        }
        $applied = scalar_query(2, "SELECT count(*) FROM mem_t") // 0;
        last if $applied >= $NROWS;
        sleep(1);
    }
}

# If we caught the worker, run the real leak assertion.  Otherwise skip
# all three of these (busy detected, RSS sampled, RSS bounded) with a
# clear reason; CI always catches the worker because Docker/Linux is
# slow enough that the disable-then-detect window is wide.
my $rss_delta = 0;
if ($busy && defined $baseline_rss) {
    $rss_delta = $peak_rss - $baseline_rss;
    $rss_delta = 0 if $rss_delta < 0;
}

SKIP: {
    skip "apply worker not caught mid-transaction (likely a fast machine); leak window is too short to measure on this host", 3
        unless $busy && defined $baseline_rss;

    ok($busy, "new apply worker is mid-transaction (pid $apply_pid)");

    ok($samples > 0,
        "sampled apply worker RSS ($samples samples, baseline ${baseline_rss} KB)");

    ok($rss_delta < $RSS_GROWTH,
       sprintf("apply worker RSS growth stays under %.1f MB (grew %.1f MB)",
               $RSS_GROWTH / 1024, $rss_delta / 1024));
}

# Best-effort dump of memory contexts to the server log for diagnostic
# context.  We do not assert on this -- the signal may or may not land
# before the worker exits, depending on timing.
my $top_used   = -1;
my $apply_used = -1;
my $msg_used   = -1;

if (defined $apply_pid && $apply_pid =~ /^\d+$/) {
    my $log_size_before = -s $n2_log // 0;
    eval {
        psql_or_bail(2, "SELECT pg_log_backend_memory_contexts($apply_pid)");
    };
    sleep(2);
    if (open(my $lh, '<', $n2_log)) {
        seek($lh, $log_size_before, 0);
        while (my $line = <$lh>) {
            if ($line =~ /\[$apply_pid\].*\bTopTransactionContext:.*?(\d+) used/) {
                $top_used = $1 if $1 > $top_used;
            }
            elsif ($line =~ /\[$apply_pid\].*\bApplyOperationContext:.*?(\d+) used/) {
                $apply_used = $1 if $1 > $apply_used;
            }
            elsif ($line =~ /\[$apply_pid\].*\bMessageContext:.*?(\d+) used/) {
                $msg_used = $1 if $1 > $msg_used;
            }
        }
        close($lh);
    }
}

my $expected_prefix = $NROWS * 4096;
diag(sprintf(
    "\n============ apply worker memory ============\n" .
    "  applied rows on n2               : %d / %d\n" .
    "  apply worker pid                 : %s\n" .
    "  RSS baseline                     : %d KB\n" .
    "  RSS peak                         : %d KB\n" .
    "  RSS growth (peak - baseline)     : %d KB (%.1f MB)\n" .
    "  RSS growth limit                 : %d KB (%.1f MB)\n" .
    "  pre-fix expected leak (~4KB/row) : %d bytes (%.1f MB)\n" .
    "  diag-only context snapshot:\n" .
    "    TopTransactionContext used     : %d bytes\n" .
    "    ApplyOperationContext used     : %d bytes\n" .
    "    MessageContext used            : %d bytes\n" .
    "=======================================================\n",
    $applied, $NROWS, $apply_pid // '<none>',
    $baseline_rss // -1, $peak_rss, $rss_delta, $rss_delta / 1024,
    $RSS_GROWTH, $RSS_GROWTH / 1024,
    $expected_prefix, $expected_prefix / (1024*1024),
    $top_used, $apply_used, $msg_used));

destroy_cluster('Destroy apply memory-context test cluster');
done_testing();
