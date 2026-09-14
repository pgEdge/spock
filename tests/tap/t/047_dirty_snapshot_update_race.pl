use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status system_maybe
);

# SPOC-673: see 046_dirty_snapshot_delete_race.pl for the full mechanism.
#
# UPDATE apply path: an update of a=1 replicates from n1 to n2 while a local
# session on n2 concurrently updates a *different* column of the very same
# row.  Buggy behaviour: FindReplTupleInLocalRel() reports "not found" (the
# dirty-snapshot index scan skipped the row), so spock_apply_heap_update()
# raises "logical replication did not find row to be updated" and the
# publisher's update of "data" is lost -- confirmed empirically to NOT
# disable the subscription (the apply worker logs the exception and keeps
# going), so this test does not assert on subscription status for the bug
# itself, only that it keeps replicating either way.  Fixed behaviour: the
# row is found, the two independent column updates both land.

if (($ENV{SPOCK_ENABLE_INJECTION_POINTS} // '') ne 'yes')
{
    plan skip_all => 'SPOCK_ENABLE_INJECTION_POINTS=yes not set; this build/run does not carry the SPOC-673 repro injection point';
}

create_cluster(2, 'Create 2-node dirty-snapshot update-race cluster');

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

# See 046_dirty_snapshot_delete_race.pl for why this must be 1, not the
# default (5) or 0: with the default, a second, fresh (unpaused) attempt
# started right after our local UPDATE commits just finds the row normally
# and masks the race; with 0 the retry loop's body never runs at all.
psql_or_bail(2, "ALTER SYSTEM SET spock.read_retry_count = 1");
psql_or_bail(2, "SELECT pg_reload_conf()");

psql_or_bail(1, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text)");
# "i" is subscriber-only, updated only locally; "data_index" is what forces
# the local UPDATE below to be non-HOT (see 046 for why that matters).
psql_or_bail(2, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text, i int DEFAULT 0);
                 CREATE INDEX i_index ON conf_tab(i)");

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

# Update the row on the publisher; it replicates to n2 and the apply worker
# pauses inside index_getnext_slot() right after positioning on a=1's
# (still current) PK index entry.
psql_or_bail(1, "UPDATE conf_tab SET data = 'frompubnew' WHERE a = 1");

ok(wait_for_apply_in_injection_point($point, 60),
    'apply worker is paused fetching the heap tuple for a=1');

# While paused, update a *different* column locally: "i" is itself indexed
# (i_index), so this is a non-HOT update -- it sets xmax on the old tuple
# and inserts a fresh PK index entry that the paused scan's already-cached
# leaf page cannot see.
#
# The injection point fires for *any* non-catalog index_getnext_slot() call,
# including the index scan this UPDATE would otherwise use to find a=1 --
# disable index scans for this one statement so it does its own lookup by
# sequential scan and does not pause on the same point itself.
psql_or_bail(2, "SET enable_indexscan = off; SET enable_bitmapscan = off; " .
                "UPDATE conf_tab SET i = 1 WHERE a = 1");

psql_or_bail(2, "SELECT injection_points_detach('$point');
                 SELECT injection_points_wakeup('$point')");

my $missing_row_error = wait_for_log($log_offset,
    qr/logical replication did not find row to be updated/, 20);

if ($missing_row_error) {
    diag('SPOC-673 reproduced: the dirty-snapshot scan missed the row -- ' .
         'the apply worker raised "did not find row to be updated" and the ' .
         'subscription is expected to have been disabled.');
}

# These are the assertions a fix must satisfy; they are expected to FAIL
# against unpatched Spock, which is exactly how this test demonstrates the
# bug for SPOC-673's acceptance criterion.
ok(!$missing_row_error,
    'no "did not find row to be updated" error (dirty-snapshot scan must not skip the row)');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating (not disabled by a spurious error)');

# NOT asserted here: that "data" ends up 'frompubnew'.  Once the row is
# found (bug fixed), apply still runs it through normal origin-based
# conflict resolution -- and since our own local write just gave the row a
# fresh local origin, that resolution can legitimately choose keep_local and
# never apply the publisher's value.  That is a policy decision, not the
# SPOC-673 defect, and asserting a specific winner here would make this
# test fail against a real fix for the wrong reason (confirmed empirically:
# a found=true run, reached here by letting Spock's default retry count
# mask the race, produced exactly "CONFLICT: remote update_origin_differs
# ... Resolution: keep_local" and left data='frompub').  The single
# fix-relevant signal for the UPDATE path is the assertion above: the row
# must be found without needing the error/retry path at all.

destroy_cluster('Destroy dirty-snapshot update-race cluster');
done_testing();
