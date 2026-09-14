use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status system_maybe
);

# SPOC-673: the apply worker's tuple lookup (FindReplTupleInLocalRel(), which
# for a PK/RI index calls core's RelationFindReplTupleByIndex()) scans with
# SnapshotDirty.  If a concurrent LOCAL transaction on the subscriber does a
# non-HOT update of the same row (forced here by indexing the "data" column,
# so the update moves the tuple and touches every index including the PK),
# the dirty-snapshot index scan can skip the row entirely: the btree scan
# caches a leaf page's contents before the local update inserts its new
# index entry into that page, so the scan's cached view never sees it (see
# nbtree/README and upstream PostgreSQL CF 5151, "DirtySnapshot index scan
# skips concurrently updated tuples").
#
# This test forces the race deterministically with a core injection point
# (added locally to indexam.c's index_getnext_slot(), right before it fetches
# the heap tuple for the TID it just read from the index -- i.e. after the
# scan has already cached the page, but before it notices anything that
# changed on it since).  It is not part of stock PostgreSQL; SPOC-673's
# reproduction requires it, so this test is skipped when unavailable.
#
# DELETE apply path: a delete of a=1 replicates from n1 to n2 while a local
# session on n2 concurrently updates the very same row.  Buggy behaviour:
# FindReplTupleInLocalRel() reports "not found", so spock_apply_heap_delete()
# silently drops the DELETE and logs it as the wrong conflict type
# (delete_missing instead of delete_origin_differs) -- the row never gets
# deleted.  Fixed behaviour: the row is found, correctly reported as
# delete_origin_differs, and actually deleted.

if (($ENV{SPOCK_ENABLE_INJECTION_POINTS} // '') ne 'yes')
{
    plan skip_all => 'SPOCK_ENABLE_INJECTION_POINTS=yes not set; this build/run does not carry the SPOC-673 repro injection point';
}

create_cluster(2, 'Create 2-node dirty-snapshot delete-race cluster');

my $config = get_test_config();
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $pg_bin = $config->{pg_bin};
my $conn = "host=$config->{host} dbname=$config->{db_name} port=$p1 " .
           "user=$config->{db_user} password=$config->{db_password}";
my $subscriber_log = "$config->{log_dir}/00${p2}.log";

unless (system_maybe("$pg_bin/psql", '-X', '-p', $p2, '-d', $config->{db_name},
        '-c', 'CREATE EXTENSION IF NOT EXISTS injection_points'))
{
    destroy_cluster('Destroy cluster (no injection_points extension)');
    plan skip_all => 'injection_points extension not installed on subscriber';
}

# spock_apply_heap_delete() wraps the lookup in its own retry loop (up to
# spock.read_retry_count attempts), which the ticket already flags as
# ineffective in production (wait_for_previous_transaction() returns
# immediately, so the retries run back to back with no real delay) but which
# would still mask a single deterministically-forced race here: with the
# default retry count, a second attempt started microseconds after our local
# UPDATE commits opens a brand new, non-stale scan and simply finds the row.
# Setting it to 1 (the loop runs the lookup exactly once: spock.c defines
# spock_read_retry_count's minimum as 0, and "while (retry < count)" with
# count=0 would skip the lookup entirely) isolates the actual defect under
# test -- the dirty-snapshot index scan itself -- from that separate (and
# separately inadequate) mitigation.
psql_or_bail(2, "ALTER SYSTEM SET spock.read_retry_count = 1");
psql_or_bail(2, "SELECT pg_reload_conf()");

psql_or_bail(1, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text)");
# The extra index on "data" is what forces a non-HOT update below -- without
# it the local UPDATE would leave the PK index entry untouched and the race
# would not be reachable through this path.
psql_or_bail(2, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text);
                 CREATE INDEX data_index ON conf_tab(data)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

psql_or_bail(1, "INSERT INTO conf_tab(a, data) VALUES (1, 'frompub')");
my $seeded = '';
for (1 .. 60) {
    $seeded = scalar_query(2, "SELECT count(*) FROM conf_tab");
    last if $seeded eq '1';
    sleep(1);
}
is($seeded, '1', 'seed row replicates to the subscriber');

sub read_log_from {
    my ($offset) = @_;
    open(my $lf, '<', $subscriber_log) or return '';
    seek($lf, $offset, 0);
    local $/;
    my $data = <$lf> // '';
    close($lf);
    return $data;
}

sub wait_for_log {
    my ($offset, $pattern, $timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        return 1 if read_log_from($offset) =~ $pattern;
        sleep(1);
    }
    return 0;
}

# The injection point reports a wait event named after itself (see core's
# WaitEventInjectionPointNew()); poll pg_stat_activity for the apply worker
# sitting in it, the same way core's own tests do.
sub wait_for_apply_in_injection_point {
    my ($point, $timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        my $n = scalar_query(2,
            "SELECT count(*) FROM pg_stat_activity " .
            "WHERE application_name LIKE 'spock apply %' " .
            "AND wait_event = '$point'");
        return 1 if defined $n && $n >= 1;
        sleep(1);
    }
    return 0;
}

my $point = 'index_getnext_slot_before_fetch_apply_dirty';

psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");

my $log_offset = -s $subscriber_log // 0;

# Delete the row on the publisher; it replicates to n2 and the apply worker
# will pause inside index_getnext_slot() on its very first (and, for this
# row, only) index entry.
psql_or_bail(1, "DELETE FROM conf_tab WHERE a = 1");

ok(wait_for_apply_in_injection_point($point, 60),
    'apply worker is paused fetching the heap tuple for a=1');

# Now, while the apply worker is paused with the OLD leaf page already
# cached, update the row locally.  Because "data" is indexed this is a
# non-HOT update: it sets xmax on the old tuple and inserts a brand new PK
# index entry -- one the paused scan's cached page view cannot see.
#
# The injection point fires for *any* non-catalog index_getnext_slot() call,
# including the index scan this UPDATE would otherwise use to find a=1 --
# disable index scans for this one statement so it does its own lookup by
# sequential scan and does not pause on the same point itself.
psql_or_bail(2, "SET enable_indexscan = off; SET enable_bitmapscan = off; " .
                "UPDATE conf_tab SET data = 'fromsubnew' WHERE a = 1");

psql_or_bail(2, "SELECT injection_points_detach('$point');
                 SELECT injection_points_wakeup('$point')");

ok(wait_for_log($log_offset, qr/CONFLICT: remote delete_/, 60),
    'apply worker reports some delete conflict for a=1');

my $bug_reproduced = read_log_from($log_offset) =~ /CONFLICT: remote delete_missing/;
my $count_after = scalar_query(2, "SELECT count(*) FROM conf_tab WHERE a = 1");

if ($bug_reproduced) {
    diag('SPOC-673 reproduced: the dirty-snapshot scan missed the row -- ' .
         'delete_missing was logged instead of delete_origin_differs, and ' .
         "the row was not deleted (count=$count_after).");
}

# These are the assertions a fix must satisfy; they are expected to FAIL
# against unpatched Spock, which is exactly how this test demonstrates the
# bug for SPOC-673's acceptance criterion.
ok(!$bug_reproduced,
    'no delete_missing is logged (dirty-snapshot scan must not skip the row)');
ok(read_log_from($log_offset) =~ /CONFLICT: remote delete_origin_differs/,
    'delete_origin_differs is logged instead (correct conflict type)');
is($count_after, '0', 'the row is actually deleted on the subscriber');

destroy_cluster('Destroy dirty-snapshot delete-race cluster');
done_testing();
