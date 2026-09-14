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
# INSERT apply path: a=1 already exists locally on n2 (inserted directly,
# not via replication) when a *replicated* INSERT of a=1 arrives from n1 --
# a normal insert_exists conflict, which spock_apply_heap_insert() resolves
# by calling FindReplTupleInLocalRel() first, the same as the UPDATE/DELETE
# paths, and unlike them with NO retry loop at all (see the TODO at
# spock_apply_heap.c:872 quoted in SPOC-673).  A local session on n2
# concurrently updates that existing row while the apply worker's lookup is
# paused.  Buggy behaviour: the dirty-snapshot scan reports "not found" even
# though the row plainly exists, so apply falls through to a raw
# ExecSimpleRelationInsert() and gets a duplicate-key violation -- the worst
# symptom in the ticket, because it breaks conflict resolution outright
# instead of just mishandling it.  Fixed behaviour: the row is found and the
# insert resolves as an insert_exists conflict, no duplicate-key error.

if (($ENV{SPOCK_ENABLE_INJECTION_POINTS} // '') ne 'yes')
{
    plan skip_all => 'SPOCK_ENABLE_INJECTION_POINTS=yes not set; this build/run does not carry the SPOC-673 repro injection point';
}

create_cluster(2, 'Create 2-node dirty-snapshot insert-race cluster');

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

psql_or_bail(1, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text)");
psql_or_bail(2, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text);
                 CREATE INDEX data_index ON conf_tab(data)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

# The row that will conflict: inserted directly on the subscriber, never
# replicated from the publisher, so n1 does not have it yet.
psql_or_bail(2, "INSERT INTO conf_tab(a, data) VALUES (1, 'fromsub')");

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

# Insert the conflicting row on the publisher; it replicates to n2 as an
# INSERT of a=1, and the apply worker pauses inside index_getnext_slot()
# right after positioning on n2's existing (locally-inserted) a=1 entry.
psql_or_bail(1, "INSERT INTO conf_tab(a, data) VALUES (1, 'frompub')");

ok(wait_for_apply_in_injection_point($point, 60),
    'apply worker is paused fetching the heap tuple for a=1');

# While paused, update the existing local row.  Non-HOT (because "data" is
# indexed), so the PK index gains a fresh entry the paused scan's
# already-cached leaf page cannot see.
#
# The injection point fires for *any* non-catalog index_getnext_slot() call,
# including the index scan this UPDATE would otherwise use to find a=1 --
# disable index scans for this one statement so it does its own lookup by
# sequential scan and does not pause on the same point itself.
psql_or_bail(2, "SET enable_indexscan = off; SET enable_bitmapscan = off; " .
                "UPDATE conf_tab SET data = 'fromsubnew' WHERE a = 1");

psql_or_bail(2, "SELECT injection_points_detach('$point');
                 SELECT injection_points_wakeup('$point')");

my $dup_key_error = wait_for_log($log_offset,
    qr/duplicate key value violates unique constraint/, 20);

if ($dup_key_error) {
    diag('SPOC-673 reproduced: the dirty-snapshot scan missed the ' .
         'existing row -- apply fell through to a raw insert and hit a ' .
         'duplicate-key violation instead of resolving an insert_exists ' .
         'conflict.');
}

# These are the assertions a fix must satisfy; they are expected to FAIL
# against unpatched Spock, which is exactly how this test demonstrates the
# bug for SPOC-673's acceptance criterion.
ok(!$dup_key_error,
    'no duplicate-key violation (dirty-snapshot scan must not skip the row)');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating (not disabled by a spurious error)');

my $count_after = scalar_query(2, "SELECT count(*) FROM conf_tab WHERE a = 1");
is($count_after, '1', 'exactly one row for a=1 survives (conflict resolved, not duplicated)');

destroy_cluster('Destroy dirty-snapshot insert-race cluster');
done_testing();
