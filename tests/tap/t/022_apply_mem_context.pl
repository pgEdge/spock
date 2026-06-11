use strict;
use warnings;
use Test::More;
use lib '.';
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

# Wait for the new worker to come up and become busy (xact_start set
# means it is mid-apply, which is when the bug would manifest).
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
ok($busy, "new apply worker is mid-transaction (pid " . ($apply_pid // 'none') . ")");

# Take several memory-context snapshots while apply is still running and
# keep the worst (largest TopTransactionContext we see). The bug only
# manifests during the live transaction, so a single snapshot may miss it
# if the worker has already committed.
my $top_used   = -1;
my $apply_used = -1;
my $msg_used   = -1;

for my $i (1 .. 6) {
    # Confirm the worker is still mid-transaction before each dump.
    my $still_busy = scalar_query(2,
        "SELECT count(*) FROM pg_stat_activity " .
        "WHERE pid = $apply_pid AND xact_start IS NOT NULL") // 0;
    last unless $still_busy > 0;

    my $log_size_before = -s $n2_log;
    $log_size_before //= 0;
    psql_or_bail(2, "SELECT pg_log_backend_memory_contexts($apply_pid)");
    sleep(1);

    open(my $lh, '<', $n2_log) or die "open $n2_log: $!";
    seek($lh, $log_size_before, 0);
    while (my $line = <$lh>) {
        if ($line =~ /\[$apply_pid\].*level: 2; TopTransactionContext:.*?(\d+) used/) {
            $top_used = $1 if $1 > $top_used;
        }
        elsif ($line =~ /\[$apply_pid\].*level: 2; ApplyOperationContext:.*?(\d+) used/) {
            $apply_used = $1 if $1 > $apply_used;
        }
        elsif ($line =~ /\[$apply_pid\].*level: 2; MessageContext:.*?(\d+) used/) {
            $msg_used = $1 if $1 > $msg_used;
        }
    }
    close($lh);
}

# When the apply worker is between transactions, TopTransactionContext is
# not even allocated and the regex misses (top_used stays -1). Skip the
# strict assertion in that case but still report it.
SKIP: {
    skip "apply worker was idle at dump time (no TopTransactionContext)", 1
        if $top_used < 0;

    ok($top_used < $THRESHOLD,
       sprintf("TopTransactionContext stays under %.1f MB (got %.1f KB)",
               $THRESHOLD / (1024*1024), $top_used / 1024));
}

ok($apply_used >= 0,
    "captured ApplyOperationContext used = $apply_used");

my $expected_prefix = $NROWS * 4096;
diag(sprintf(
    "\n============ apply worker memory contexts ============\n" .
    "  applied rows on n1               : %d\n" .
    "  apply worker pid                 : %s\n" .
    "  TopTransactionContext used       : %d bytes\n" .
    "  ApplyOperationContext used       : %d bytes\n" .
    "  MessageContext used              : %d bytes\n" .
    "  pre-fix expected (~4 KB per row) : %d bytes (%.1f MB)\n" .
    "=======================================================\n",
    $NROWS, $apply_pid, $top_used, $apply_used, $msg_used,
    $expected_prefix, $expected_prefix / (1024*1024)));

destroy_cluster('Destroy apply memory-context test cluster');
done_testing();
