use strict;
use warnings;
use Test::More;
use IPC::Run;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail
    wait_for_sub_status wait_for_pg_ready
);

# =============================================================================
# Test: 048_insert_conflict_race.pl
# =============================================================================
# An applied INSERT must resolve against a conflicting local row even when
# that row appears after the apply worker has already looked for it and
# found nothing.
#
# The lookup cannot settle the question on its own.  It runs a scan that a
# concurrent local writer can race, and it necessarily runs before the tuple
# is stored, so a row committed in between is missed either way.  The apply
# path therefore stores the tuple speculatively and lets the unique index
# arbitrate: the index sees the key under a page lock and reports a duplicate
# instead of raising one, so the lookup on the next pass finds that row and
# hands it to conflict resolution.
#
# First the conflicting row is already committed when the index reports it.
# Then the competitor is still in progress at that moment, on a unique index
# the lookup does not search.  The index reports it without waiting, so the
# apply worker must wait for that transaction itself before it tries again;
# otherwise it would spend its remaining passes at once against a holder that
# has not decided yet.  Both endings are covered: the holder aborts and the
# applied row takes the key, or it commits and, with
# spock.check_all_uc_indexes on, the next lookup finds its row.
#
# The race is produced deterministically here rather than by timing: the
# worker is held at 'spock-insert-conflict-stall', which sits exactly in the
# window between the lookup and the store, and the conflicting row is
# committed locally while it waits.  Before the speculative insertion this
# ended in "duplicate key value violates unique constraint" and whatever
# spock.exception_behaviour then decided.
#
# Needs PostgreSQL's core injection_points module, which exists only when the
# server was configured with --enable-injection-points; the test skips
# otherwise.  No patched core is required.
# =============================================================================

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};

my $pkglibdir = `"$pg_bin/pg_config" --pkglibdir`;
chomp $pkglibdir;

unless ((-e "$pkglibdir/injection_points.so")
        || (-e "$pkglibdir/injection_points.dylib"))
{
    plan skip_all =>
        "server not built with --enable-injection-points " .
        "(no injection_points test module in $pkglibdir)";
}

create_cluster(2, 'Create 2-node insert-conflict-race cluster');

$config = get_test_config();
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $datadir2 = $config->{node_datadirs}->[1];
my $log_file = $config->{log_file};
my $subscriber_log = "$config->{log_dir}/00${p2}.log";
my $conn = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# The injection point fires in the subscriber's apply worker, so it is n2
# that needs the module preloaded.  That is a postmaster-start GUC, so set
# it and restart the node before any subscription exists.
open(my $conf, '>>', "$datadir2/postgresql.conf")
    or die "Cannot open $datadir2/postgresql.conf: $!";
print $conf "shared_preload_libraries='spock,injection_points'\n";
close($conf);

system_or_bail("$pg_bin/pg_ctl", '-D', $datadir2, '-w', '-m', 'fast', 'stop');
system("$pg_bin/postgres -D $datadir2 >> '$log_file' 2>&1 &");
ok(wait_for_pg_ready($host, $p2, $pg_bin, 30), 'n2 restarted with injection_points preloaded');

psql_or_bail(2, "CREATE EXTENSION injection_points");

psql_or_bail(1, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text)");
psql_or_bail(2, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text)");

# A second unique index, outside the replica identity.  With
# spock.check_all_uc_indexes off (the default) the lookup never searches it,
# but it is an arbiter all the same.
psql_or_bail(1, "CREATE TABLE uc_tab(a int PRIMARY KEY, b int UNIQUE, data text)");
psql_or_bail(2, "CREATE TABLE uc_tab(a int PRIMARY KEY, b int UNIQUE, data text)");

# From PG18 a unique constraint WITHOUT OVERLAPS is a GiST index that is a
# unique index and an exclusion constraint at once, so it arbitrates too, and
# waiting for its holder must not take it for a btree.
my $temporal = scalar_query(2,
    "SELECT current_setting('server_version_num')::int >= 180000 " .
    "AND EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'btree_gist')");
$temporal = ($temporal eq 't');
if ($temporal) {
    for my $n (1, 2) {
        psql_or_bail($n, "CREATE EXTENSION btree_gist");
        psql_or_bail($n,
            "CREATE TABLE tp_tab(a int PRIMARY KEY, id int, valid_at int4range, " .
            "data text, UNIQUE (id, valid_at WITHOUT OVERLAPS))");
    }
}

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

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

# The injection point reports a wait event named after itself, so the worker
# sitting in it is visible in pg_stat_activity.
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

my $point = 'spock-insert-conflict-stall';

psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");

my $log_offset = -s $subscriber_log // 0;

# Insert on the publisher.  It replicates, the apply worker looks for a
# conflicting local row, finds none -- there is none yet -- and stops in the
# window between that answer and storing the tuple.
psql_or_bail(1, "INSERT INTO conf_tab(a, data) VALUES (1, 'frompub')");

ok(wait_for_apply_in_injection_point($point, 60),
    'apply worker is held between the conflict lookup and the insert');

# Now make the lookup's answer stale: commit the conflicting row locally.
psql_or_bail(2, "INSERT INTO conf_tab(a, data) VALUES (1, 'fromsub')");

psql_or_bail(2, "SELECT injection_points_detach('$point')");
psql_or_bail(2, "SELECT injection_points_wakeup('$point')");

# The index reports the duplicate, the next pass finds the row, and the
# insert is resolved as a conflict.
ok(wait_for_log($log_offset, qr/CONFLICT: remote insert_exists/, 60),
    'the insert is reported as an insert_exists conflict');

my $dup_key_error =
    read_log_from($log_offset) =~ /duplicate key value violates unique constraint/;
ok(!$dup_key_error,
    'no duplicate key violation (the index conflict is resolved, not raised)');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating');

# Which row wins is conflict resolution's decision, not this test's business;
# what matters is that exactly one survives and the key is intact.
my $count = scalar_query(2, "SELECT count(*) FROM conf_tab WHERE a = 1");
is($count, '1', 'exactly one row for a=1 survives');

# Replication is still working end to end after the resolved conflict.
psql_or_bail(1, "INSERT INTO conf_tab(a, data) VALUES (2, 'after')");
my $followed = '';
for (1 .. 60) {
    $followed = scalar_query(2, "SELECT count(*) FROM conf_tab WHERE a = 2");
    last if $followed eq '1';
    sleep(1);
}
is($followed, '1', 'a later insert still replicates');

# Now the competitor is still in progress when the index reports it.  A local
# transaction takes a key on b and stays open.  The applied row has a
# different primary key, so the lookup on the primary key never meets the
# holder's tuple.  Only the arbiter on b sees it, and it reports the key
# without waiting.
#
# After losing the race the worker must wait for the holder before its next
# pass.  The point stays armed across the wakeup to tell the two apart: a
# worker that waits blocks on the holder's transaction lock; one that does not
# goes straight round the loop and parks at the point again.

# A local session that holds its transaction open between statements.
sub start_holder {
    my %h = (in => '', out => '');
    $h{run} = IPC::Run::start(
        [ "$pg_bin/psql", '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
          '-p', $p2, '-d', $dbname ],
        '<', \$h{in}, '>', \$h{out}, '2>&1',
        IPC::Run::timeout(180));
    return \%h;
}

sub holder_run {
    my ($h, $sql, $marker) = @_;
    $h->{in} .= "$sql\nSELECT '$marker';\n";
    $h->{run}->pump until $h->{out} =~ /\Q$marker\E/;
}

sub holder_finish {
    my ($h, $sql) = @_;
    holder_run($h, $sql, 'holder-done');
    $h->{in} .= "\\q\n";
    $h->{run}->finish;
}

sub apply_workers_waiting_on {
    my ($cond) = @_;
    return scalar_query(2,
        "SELECT count(*) FROM pg_stat_activity " .
        "WHERE application_name LIKE 'spock apply %' AND $cond");
}

sub wait_for_apply_on_xact_lock {
    my ($timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        my $n = apply_workers_waiting_on(
            "wait_event_type = 'Lock' AND wait_event = 'transactionid'");
        return 1 if defined $n && $n >= 1;
        sleep(1);
    }
    return 0;
}

# Disarm the point.  Detaching does not release a worker already parked in
# it, so wake that one too: should the worker fail to wait for the holder, it
# is parked there again, and leaving it so would turn the failure into a hang.
sub release_point {
    psql_or_bail(2, "SELECT injection_points_detach('$point')");
    if (apply_workers_waiting_on("wait_event = '$point'") ne '0') {
        psql_or_bail(2, "SELECT injection_points_wakeup('$point')");
    }
}

sub wait_for_value {
    my ($sql, $expected, $timeout) = @_;
    $timeout //= 60;
    my $got = '';
    for (1 .. $timeout) {
        $got = scalar_query(2, $sql);
        last if $got eq $expected;
        sleep(1);
    }
    return $got;
}

# Run one holder scenario: the remote row $remote meets a local holder that
# inserted $local, which is still in progress when the index reports it, and
# the holder then ends with $finish.  $label names the case in test output.
sub race_with_holder {
    my ($table, $remote, $local, $label, $finish) = @_;

    psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");

    psql_or_bail(1, "INSERT INTO $table VALUES $remote");
    ok(wait_for_apply_in_injection_point($point, 60),
        "($label) apply worker is held before storing the row");

    my $holder = start_holder();
    holder_run($holder, "BEGIN; INSERT INTO $table VALUES $local;",
        'holder-has-key');

    # Let the worker go on, but leave the point armed.
    psql_or_bail(2, "SELECT injection_points_wakeup('$point')");

    ok(wait_for_apply_on_xact_lock(60),
        "($label) after losing the race the worker waits for the holder");
    is(apply_workers_waiting_on("wait_event = '$point'"), '0',
        "($label) the worker did not go round the loop without waiting");

    # The next pass must not stop at the point.
    release_point();

    holder_finish($holder, "$finish;");
}

# Holder aborts.  spock.check_all_uc_indexes is off, so the next pass looks on
# the primary key only, finds nothing, and the key is free for the store.
$log_offset = -s $subscriber_log // 0;

race_with_holder('uc_tab', "(1, 7, 'frompub')", "(100, 7, 'fromsub')",
    'holder aborts', 'ROLLBACK');

is(wait_for_value("SELECT data FROM uc_tab WHERE b = 7", 'frompub'),
    'frompub', 'once the holder aborts, the applied row takes the key');
ok(read_log_from($log_offset) !~ /duplicate key value violates unique constraint/,
    'no duplicate key violation while waiting for a holder that aborts');
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating after the holder aborts');

# Holder commits.  With spock.check_all_uc_indexes on, the next pass searches
# b too and finds the holder's row, so the insert is resolved as a conflict.
# It is a SIGHUP setting: reload, then push a row through to be sure the
# worker has been round its loop since.
psql_or_bail(2, "ALTER SYSTEM SET spock.check_all_uc_indexes = on");
psql_or_bail(2, "SELECT pg_reload_conf()");
psql_or_bail(1, "INSERT INTO conf_tab(a, data) VALUES (4, 'reloaded')");
is(wait_for_value("SELECT count(*) FROM conf_tab WHERE a = 4", '1'), '1',
    'the worker is past the reload');

$log_offset = -s $subscriber_log // 0;

race_with_holder('uc_tab', "(2, 8, 'frompub')", "(200, 8, 'fromsub')",
    'holder commits', 'COMMIT');

ok(wait_for_log($log_offset, qr/CONFLICT: remote insert_exists/, 60),
    'a holder that commits is found and resolved as insert_exists');
ok(read_log_from($log_offset) !~ /duplicate key value violates unique constraint/,
    'no duplicate key violation while waiting for a holder that commits');
is(scalar_query(2, "SELECT count(*) FROM uc_tab WHERE b = 8"), '1',
    'exactly one row for b = 8 survives');
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating after the holder commits');

psql_or_bail(2, "ALTER SYSTEM RESET spock.check_all_uc_indexes");
psql_or_bail(2, "SELECT pg_reload_conf()");

# The holder takes an overlapping period on a temporal unique constraint and
# aborts.  The worker must wait for it and then store its row.
SKIP: {
    skip 'needs PG18 or later and btree_gist', 6 unless $temporal;

    $log_offset = -s $subscriber_log // 0;

    race_with_holder('tp_tab', "(1, 5, '[1,10)', 'frompub')",
        "(100, 5, '[5,15)', 'fromsub')", 'temporal holder aborts', 'ROLLBACK');

    is(wait_for_value("SELECT data FROM tp_tab WHERE id = 5", 'frompub'),
        'frompub', 'once the temporal holder aborts, the applied row takes the period');
    ok(read_log_from($log_offset) !~
        /TRAP:|terminated by signal|conflicting key value violates exclusion constraint/,
        'no crash and no exclusion violation while waiting for the temporal holder');
    ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
        'subscription is still replicating after the temporal holder aborts');
}

# spock.non_conflicting_inserts is the operator asserting that the race above
# cannot happen on their cluster.  The apply worker then takes neither the
# lookup nor the speculative store, so it never reaches the stall point: an
# insert replicates straight through while that point is armed and waiting.
open($conf, '>>', "$datadir2/postgresql.conf")
    or die "Cannot open $datadir2/postgresql.conf: $!";
print $conf "spock.non_conflicting_inserts = on\n";
close($conf);

system_or_bail("$pg_bin/pg_ctl", '-D', $datadir2, '-w', '-m', 'fast', 'stop');
system("$pg_bin/postgres -D $datadir2 >> '$log_file' 2>&1 &");
ok(wait_for_pg_ready($host, $p2, $pg_bin, 30),
    'n2 restarted with spock.non_conflicting_inserts on');
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is replicating again after the restart');

# The restart cleared the injection point along with the module's shared
# state, so arm it again.
psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");

psql_or_bail(1, "INSERT INTO conf_tab(a, data) VALUES (3, 'direct')");

my $direct = '';
for (1 .. 60) {
    $direct = scalar_query(2, "SELECT count(*) FROM conf_tab WHERE a = 3");
    last if $direct eq '1';
    sleep(1);
}
is($direct, '1', 'the insert replicates without taking the speculative path');

my $stalled = scalar_query(2,
    "SELECT count(*) FROM pg_stat_activity " .
    "WHERE application_name LIKE 'spock apply %' AND wait_event = '$point'");
is($stalled, '0', 'the apply worker never reached the stall point');

psql_or_bail(2, "SELECT injection_points_detach('$point')");

destroy_cluster('Destroy insert-conflict-race cluster');
done_testing();
