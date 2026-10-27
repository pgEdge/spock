use strict;
use warnings;
use Test::More;
use Time::HiRes qw(usleep time);
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail
    wait_for_sub_status wait_for_pg_ready log_offset log_since
);

# =============================================================================
# Test: 118_exception_slot_same_name.pl
# =============================================================================
# Two apply workers of one instance whose subscriptions have the same name,
# each in its own database, must both start applying, and neither may leave
# SpockCtx->lock held.
#
# The exception log in shared memory has one entry per subscription name for
# the whole instance.  On its first BEGIN, handle_begin() searches it without
# a lock and, when the name is missing, searches again under SpockCtx->lock to
# take a free entry.  When another worker took the name in between, the second
# search stopped at that entry before it had seen a free one, and the worker
# raised "unable to find an empty exception log slot" although nearly every
# entry was free.  The error was raised with SpockCtx->lock held and outside
# any transaction, so nothing released the lock: the managers, sub_create()
# and finally the worker itself blocked on it until the server was restarted.
#
# The window is produced deterministically here rather than by timing: both
# workers are held at 'spock-exception-slot-stall', after the unlocked search
# has missed and before the lock is taken, and are released one after the
# other.  The second one then finds the entry the first one has just taken.
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

create_cluster(2, 'Create 2-node exception-slot cluster');

$config = get_test_config();
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $datadir2 = $config->{node_datadirs}->[1];
my $log_file = $config->{log_file};

# The second database, on both nodes.
my $dbname_b = "${dbname}_b";

# psql_or_bail() and scalar_query() only reach the default database.
sub psql_db_or_bail {
    my ($port, $db, $sql) = @_;
    system_or_bail("$pg_bin/psql", '-X', '-q', '-p', $port, '-d', $db,
                   '-v', 'ON_ERROR_STOP=1', '-c', $sql);
}

sub query_db {
    my ($port, $db, $sql) = @_;
    my $result = `"$pg_bin/psql" -X -A -t -p $port -d $db -c "$sql"`;
    chomp($result);
    return $result;
}

# The injection point fires in the subscriber's apply workers, so it is n2
# that needs the module preloaded.  That is a postmaster-start GUC.  The
# restart also leaves the exception log empty: no worker has taken a name.
open(my $conf, '>>', "$datadir2/postgresql.conf")
    or die "Cannot open $datadir2/postgresql.conf: $!";
print $conf "shared_preload_libraries='spock,injection_points'\n";
close($conf);

system_or_bail("$pg_bin/pg_ctl", '-D', $datadir2, '-w', '-m', 'fast', 'stop');
system("$pg_bin/postgres -D $datadir2 >> '$log_file' 2>&1 &");
ok(wait_for_pg_ready($host, $p2, $pg_bin, 30), 'n2 restarted with injection_points preloaded');

psql_or_bail(2, "CREATE EXTENSION injection_points");

# A second database on both nodes, with Spock nodes of the same names as in
# the first one.
for my $node ([1, $p1, 'n1'], [2, $p2, 'n2']) {
    my ($num, $port, $name) = @$node;
    psql_or_bail($num, "CREATE DATABASE $dbname_b");
    psql_db_or_bail($port, $dbname_b, "CREATE EXTENSION spock");
    psql_db_or_bail($port, $dbname_b,
        "SELECT spock.node_create('$name', 'host=$host dbname=$dbname_b " .
        "port=$port user=$db_user password=$db_password')");
}

for my $port ($p1, $p2) {
    for my $db ($dbname, $dbname_b) {
        psql_db_or_bail($port, $db, "CREATE TABLE slot_tab(a int PRIMARY KEY)");
    }
}

my $point = 'spock-exception-slot-stall';

# The injection point reports a wait event named after itself.
sub held_workers {
    return scalar_query(2,
        "SELECT count(*) FROM pg_stat_activity " .
        "WHERE application_name LIKE 'spock apply %' " .
        "AND wait_event = '$point'");
}

sub wait_for_held_workers {
    my ($expected, $timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout * 10) {
        return 1 if held_workers() eq $expected;
        usleep(100_000);
    }
    return 0;
}

# Hold every apply worker whose subscription name has no entry yet.
psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");

my $log_start = log_offset(2);

# The same subscription name in both databases.
for my $db ($dbname, $dbname_b) {
    psql_db_or_bail($p2, $db,
        "SELECT spock.sub_create('sub_n1_n2', 'host=$host dbname=$db " .
        "port=$p1 user=$db_user password=$db_password', " .
        "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
}

# A worker creates its slot on n1 as it starts, and a row inserted before
# that is never sent.  Insert only once both are replicating.
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    "the subscription in $dbname starts replicating");
my $status_b = '';
for (1 .. 30) {
    $status_b = query_db($p2, $dbname_b,
        "SELECT status FROM spock.sub_show_status() " .
        "WHERE subscription_name = 'sub_n1_n2'");
    last if $status_b eq 'replicating';
    sleep(1);
}
is($status_b, 'replicating', "the subscription in $dbname_b starts replicating");

# Give both workers a transaction to begin.
for my $db ($dbname, $dbname_b) {
    psql_db_or_bail($p1, $db, "INSERT INTO slot_tab VALUES (1)");
}

ok(wait_for_held_workers('2'),
    'both apply workers are held after the unlocked search missed');

# Every held worker waits in a slot of its own, and injection_points_wakeup()
# releases one of them per call.  The first one takes the lock and an entry
# for the name; the second one then searches under the lock and finds it.
psql_or_bail(2, "SELECT injection_points_detach('$point')");
psql_or_bail(2, "SELECT injection_points_wakeup('$point')");
ok(wait_for_held_workers('1'), 'the first worker is released');
psql_or_bail(2, "SELECT injection_points_wakeup('$point')");
ok(wait_for_held_workers('0'), 'the second worker is released');

for my $db ($dbname, $dbname_b) {
    my $count = '';
    for (1 .. 60) {
        $count = query_db($p2, $db, "SELECT count(*) FROM slot_tab");
        last if $count eq '1';
        sleep(1);
    }
    is($count, '1', "the first row reached $db");
}

# ok() rather than unlike(): a failure would print the whole log.
ok(log_since(2, $log_start) !~ /unable to find an empty exception log slot/,
    'no worker found the exception log full');

# A manager takes SpockCtx->lock at least every spock.restart_delay_default
# (5 s by default), so a lock left held soon shows up as processes stuck on
# it.  A wait for a lock that is free is over at once: the same process seen
# waiting seconds apart is stuck.
my %waiting_since;
my $stuck = '';
my $deadline = time() + 12;
while (time() < $deadline && $stuck eq '') {
    my $pids = scalar_query(2,
        "SELECT string_agg(pid::text, ',' ORDER BY pid) FROM pg_stat_activity " .
        "WHERE wait_event_type = 'LWLock' AND wait_event = 'spock context lock'");
    my %now = map { $_ => 1 } grep { $_ ne '' } split(/,/, $pids // '');
    for my $pid (keys %now) {
        $waiting_since{$pid} //= time();
        $stuck = $pid if time() - $waiting_since{$pid} >= 3;
    }
    delete $waiting_since{$_} for grep { !$now{$_} } keys %waiting_since;
    usleep(500_000);
}
is($stuck, '', 'no process is stuck on SpockCtx->lock');

# Replication keeps going in both databases.
for my $db ($dbname, $dbname_b) {
    psql_db_or_bail($p1, $db, "INSERT INTO slot_tab VALUES (2)");
}
for my $db ($dbname, $dbname_b) {
    my $count = '';
    for (1 .. 60) {
        $count = query_db($p2, $db, "SELECT count(*) FROM slot_tab");
        last if $count eq '2';
        sleep(1);
    }
    is($count, '2', "a later row reached $db");
}

SKIP:
{
    # sub_show_status() and sub_drop() take SpockCtx->lock themselves, and
    # so does the teardown.  Stop n2 without waiting for its processes.
    if ($stuck ne '')
    {
        system("$pg_bin/pg_ctl stop -D $datadir2 -m immediate >> '$log_file' 2>&1");
        skip 'SpockCtx->lock is held for good', 2;
    }

    ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
        "the subscription in $dbname is replicating");
    is(query_db($p2, $dbname_b,
            "SELECT status FROM spock.sub_show_status() " .
            "WHERE subscription_name = 'sub_n1_n2'"),
        'replicating', "the subscription in $dbname_b is replicating");

    psql_db_or_bail($p2, $dbname_b, "SELECT spock.sub_drop('sub_n1_n2')");
}

destroy_cluster('Destroy 2-node exception-slot cluster');
done_testing();
