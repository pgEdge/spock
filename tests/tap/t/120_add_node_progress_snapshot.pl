use strict;
use warnings;
use Test::More;
use POSIX ();
use File::Temp ();
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster get_test_config
    psql_or_bail scalar_query wait_for_sub_status
    poll_query_until sync_nodes
);

# =============================================================================
# Test: 120_add_node_progress_snapshot.pl
#
# n1 subscribes to n3, and n3 is written to throughout.  n2 joins by copying
# n1, as add_node does, and then subscribes to n3 from the position n1 had
# applied when the copy snapshot was taken, which the sync seeds into n2's
# spock.progress.  n2's subscription to n3 resumes from that position, so
# every row n3 committed after it must reach n2 through replication, since
# the copy did not contain it.
#
# The seed used to be read from n1's spock.progress table after the whole
# copy.  n1's apply workers are paused for the sync, but the pause expires
# after spock.pause_timeout, so for a copy longer than that n1 was applying
# and flushing progress again by the time of the read, and the table named
# a position well past the snapshot.  n2 then resumed from there and skipped
# every row n1 had applied from n3 since the snapshot but had not copied.
#
# The seed is now read from the origin status right after the slot is
# created, while the workers are still paused, and the workers are resumed
# before the copy, so the seed is the snapshot position whatever the copy
# does afterward.
#
# The test sets spock.pause_timeout to 2s on n1 and holds the sync on n2
# between the slot creation and the copy, by locking pg_replication_origin
# there, until n1 has applied and flushed a clear block of further rows from
# n3.  On the old code the copy then outlasts the pause and the post-copy
# read seeds n2 past the snapshot, losing that block; on the fixed code the
# seed is taken before the hold and no row is lost.
# =============================================================================

create_cluster(3, 'Create 3-node Spock cluster');

my $config      = get_test_config();
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};
my @port        = @{$config->{node_ports}};
my $repsets     = "ARRAY['default', 'default_insert_only', 'ddl_sql']";

sub dsn {
    my ($node) = @_;
    return "host=$host dbname=$dbname port=$port[$node - 1] " .
           "user=$db_user password=$db_password";
}

sub count_load { return scalar_query($_[0], "SELECT count(*) FROM load"); }

# n1's apply worker pauses for at most this long; the sync from n1 to n2 is
# held on n2 for longer below.
psql_or_bail(1, "ALTER SYSTEM SET spock.pause_timeout = 2");
psql_or_bail(1, "SELECT pg_reload_conf()");

# n1 applies from n3.  The table is created on n3 so that n1 gets it through
# DDL replication, as it would in a running cluster.
psql_or_bail(1, "SELECT spock.sub_create('sub_n1_n3', '" . dsn(3) . "', " .
    "$repsets, false, false)");
ok(wait_for_sub_status(1, 'sub_n1_n3', 'replicating', 60),
    'n1 replicates from n3');

psql_or_bail(3, "CREATE TABLE load (id serial PRIMARY KEY, pad text)");
ok(sync_nodes(3, 1), 'n1 has the table from n3');

# n2's subscription to n3 is created disabled, with its slot made on n3 now,
# so that n3 keeps every change from here on for n2.  This is what add_node
# does before it starts the copy.
psql_or_bail(2, "SELECT spock.sub_create('sub_n2_n3', '" . dsn(3) . "', " .
    "$repsets, false, false, '{}', '0', false, false)");
my $slot_n3 = scalar_query(2,
    "SELECT sub_slot_name FROM spock.subscription WHERE sub_name = 'sub_n2_n3'");
ok($slot_n3 ne '', "sub_n2_n3 uses slot $slot_n3 on n3");
psql_or_bail(3,
    "SELECT pg_create_logical_replication_slot('$slot_n3', 'spock_output')");

# ---------- a steady, fast writer on n3 ----------
#
# A persistent psql fed one INSERT per line keeps n3 advancing quickly
# without a new process per row, so n1 applies a clear block of rows during
# the hold below.
#
# The feeder stops on a file rather than a signal: the pipe buffers a few
# thousand statements ahead of psql, and killing the feeder would leave
# psql running them after stop_writer() returned.  Closing the pipe waits
# for psql to finish what it has and exit, so when stop_writer() returns no
# further row can land on n3.

my $stop_dir = File::Temp::tempdir(CLEANUP => 1);
my $stop_file = "$stop_dir/stop";
my $writer = fork();
die "fork failed: $!" unless defined $writer;
if ($writer == 0)
{
    open(my $w, '|-', "$pg_bin/psql", '-X', '-q', '-h', $host, '-p', $port[2],
        '-U', $db_user, '-d', $dbname) or POSIX::_exit(1);
    $w->autoflush(1);
    print $w "INSERT INTO load (pad) VALUES ('x');\n" until -e $stop_file;
    close($w);
    POSIX::_exit(0);
}

sub stop_writer {
    return unless defined $writer;
    open(my $s, '>', $stop_file) or die "cannot create $stop_file: $!";
    close($s);
    waitpid($writer, 0);
    undef $writer;
}

ok(poll_query_until(3, "SELECT count(*) >= 50 FROM load", 't', 60),
    'n3 is being written to');
# Everything n3 committed before its slot for n2 was created is on n1, so
# the copy from n1 contains it.
ok(sync_nodes(3, 1), 'n1 has applied n3 past the slot creation');

my $progress_n3 =
    "SELECT p.remote_lsn FROM spock.progress p " .
    "JOIN spock.node n ON n.node_id = p.remote_node_id " .
    "WHERE n.node_name = 'n3'";

# ---------- the copy outlasts the pause ----------

# Right after the slot is created on n1, the sync creates its replication
# origin on n2, which needs pg_replication_origin.  With that catalog locked
# on n2 the sync waits there, between the slot's snapshot and the copy, for
# as long as the lock is held.  n2 is the subscriber, so the transaction id
# the lock takes holds back no snapshot on n1.
open(my $lock, '|-', "$pg_bin/psql", '-X', '-q', '-h', $host,
    '-p', $port[1], '-U', $db_user, '-d', $dbname)
    or die "cannot start psql on n2: $!";
$lock->autoflush(1);
print $lock "BEGIN;\nLOCK TABLE pg_replication_origin IN ACCESS EXCLUSIVE MODE;\n";
ok(poll_query_until(2,
    "SELECT EXISTS (SELECT 1 FROM pg_locks " .
    "WHERE relation = 'pg_replication_origin'::regclass " .
    "AND mode = 'AccessExclusiveLock' AND granted)", 't', 30),
    'pg_replication_origin is locked on n2');

my $rows_at_snapshot = count_load(1);

psql_or_bail(2, "SELECT spock.sub_create('sub_n2_n1', '" . dsn(1) . "', " .
    "$repsets, true, true)");

ok(poll_query_until(2,
    "SELECT EXISTS (SELECT 1 FROM pg_locks " .
    "WHERE relation = 'pg_replication_origin'::regclass AND NOT granted)",
    't', 60), 'the sync has its snapshot and waits before the copy');

# Hold until n1 has applied and flushed a clear block of further rows from
# n3.  spock.progress is flushed about once a second, so a run of a few
# hundred rows takes several flushes: the table is then well past the
# snapshot, which is what the post-copy read on the old code seeds from.
my $target = $rows_at_snapshot + 300;
ok(poll_query_until(1, "SELECT count(*) >= $target FROM load", 't', 60),
    "n1 applied a block of further rows from n3 (>= $target)")
    or diag("n1.load=" . count_load(1) . " snapshot=$rows_at_snapshot");
isnt(wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 1), 1,
    'the sync is still waiting');

print $lock "COMMIT;\n";
close($lock);

ok(wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 180),
    'n2 replicates from n1');

# ---------- n2 subscribes to n3 from the seeded position ----------

my $resume_lsn = scalar_query(2, $progress_n3);
ok($resume_lsn ne '' && $resume_lsn ne '0/0',
    "n2's seeded position for n3 is $resume_lsn");
psql_or_bail(2,
    "SELECT pg_replication_origin_advance('$slot_n3', '$resume_lsn')");
psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n3')");
ok(wait_for_sub_status(2, 'sub_n2_n3', 'replicating', 60),
    'n2 replicates from n3');

stop_writer();

ok(sync_nodes(3, 1, 'n3', 120), 'n1 has applied everything from n3');
ok(sync_nodes(3, 2, 'n3', 120), 'n2 has applied everything from n3');

# n2 must hold every row n3 ever wrote.  The rows n1 applied from n3 between
# the snapshot and the post-copy progress read are the ones the old code
# left out of both the copy and the resumed stream.
my $summary = "SELECT count(*), coalesce(sum(id), 0), coalesce(max(id), 0) FROM load";
my $on_n3 = scalar_query(3, $summary);
is(scalar_query(1, $summary), $on_n3, 'n1 has every row n3 wrote');
is(scalar_query(2, $summary), $on_n3, 'n2 has every row n3 wrote')
    or diag("n3=$on_n3 n2=" . scalar_query(2, $summary) .
            " seed=$resume_lsn snapshot_rows=$rows_at_snapshot");
is(scalar_query(2, "SELECT count(*) FROM spock.exception_log"), '0',
    'no row from n3 was applied twice on n2');

# ---------- cleanup ----------

psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n3')");
psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1')");
psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n3')");

destroy_cluster('Destroy test cluster');
done_testing();

END {
    stop_writer() if defined $writer;
}
