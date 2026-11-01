use strict;
use warnings;
use Test::More;
use Time::HiRes qw(usleep time);
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail
    wait_for_pg_ready log_offset log_since
);

# =============================================================================
# Test: 119_exception_slot_exhausted.pl
# =============================================================================
# An apply worker that finds the exception log full must fail on its own and
# leave SpockCtx->lock free for everybody else.
#
# The exception log in shared memory has max_worker_processes entries for the
# whole instance, one per subscription name, and an entry is not given back
# when its subscription is dropped.  Once every entry is taken, the first
# BEGIN of a subscription with a new name raises "unable to find an empty
# exception log slot".  That error used to be raised with SpockCtx->lock held
# and outside any transaction, so nothing released the lock and every Spock
# process of the instance blocked on it until the server was restarted.  The
# worker now releases the lock first, and the error is class 53, so the
# worker exits and is restarted after spock.restart_delay_default.
#
# The log is filled by subscriptions with new names, created and dropped one
# after the other, each applying one transaction.
# =============================================================================

create_cluster(2, 'Create 2-node exception-slot-exhausted cluster');

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $datadir2 = $config->{node_datadirs}->[1];
my $log_file = $config->{log_file};
my $conn = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# The log has one entry per background worker slot.  Keep it small, so that
# few subscriptions fill it.
my $entries = 8;

open(my $conf, '>>', "$datadir2/postgresql.conf")
    or die "Cannot open $datadir2/postgresql.conf: $!";
print $conf "max_worker_processes = $entries\n";
close($conf);

system_or_bail("$pg_bin/pg_ctl", '-D', $datadir2, '-w', '-m', 'fast', 'stop');
system("$pg_bin/postgres -D $datadir2 >> '$log_file' 2>&1 &");
ok(wait_for_pg_ready($host, $p2, $pg_bin, 30),
    "n2 restarted with max_worker_processes = $entries");

psql_or_bail(1, "CREATE TABLE slot_tab(a int PRIMARY KEY)");
psql_or_bail(2, "CREATE TABLE slot_tab(a int PRIMARY KEY)");

sub wait_for_row {
    my ($key, $timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        return 1 if scalar_query(2, "SELECT count(*) FROM slot_tab WHERE a = $key") eq '1';
        sleep(1);
    }
    return 0;
}

# A worker creates its slot on n1 as it starts, and a row inserted before
# that is never sent.  Wait on n1 for the slot to stream: on n2,
# sub_show_status() would need SpockCtx->lock.
sub create_sub {
    my ($name) = @_;
    psql_or_bail(2,
        "SELECT spock.sub_create('$name', '$conn', " .
        "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
    for (1 .. 60) {
        return 1 if scalar_query(1,
            "SELECT count(*) FROM pg_replication_slots " .
            "WHERE slot_name = 'spk_${dbname}_n1_$name' AND active") eq '1';
        sleep(1);
    }
    return 0;
}

# Each subscription takes an entry for its name with the first transaction it
# applies, and keeps it after it is dropped.
my $filled = 0;
for my $k (1 .. $entries) {
    last unless create_sub("sub_fill_$k");
    psql_or_bail(1, "INSERT INTO slot_tab VALUES ($k)");
    last unless wait_for_row($k);
    psql_or_bail(2, "SELECT spock.sub_drop('sub_fill_$k')");
    $filled++;
}
is($filled, $entries, "$entries subscriptions with new names applied a transaction each");

my $log_start = log_offset(2);

# One name more than there are entries.
ok(create_sub('sub_full'), 'the subscription with one name too many streams');
psql_or_bail(1, "INSERT INTO slot_tab VALUES (100)");

my $found = 0;
for (1 .. 60) {
    if (log_since(2, $log_start) =~ /unable to find an empty exception log slot/) {
        $found = 1;
        last;
    }
    sleep(1);
}
ok($found, 'the next new name finds the exception log full');

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

# ok() rather than like(): a failure would print the whole log.
ok(log_since(2, $log_start) =~
        /SPOCK sub_full: transient resource error, will restart and retry/,
    'the worker exits to be restarted');

SKIP:
{
    # sub_drop() takes SpockCtx->lock itself, and so does the teardown.  Stop
    # n2 without waiting for its processes.
    if ($stuck ne '')
    {
        system("$pg_bin/pg_ctl stop -D $datadir2 -m immediate >> '$log_file' 2>&1");
        skip 'SpockCtx->lock is held for good', 1;
    }

    psql_or_bail(2, "SELECT spock.sub_drop('sub_full')");
    pass('the subscription that found the log full can be dropped');
}

destroy_cluster('Destroy 2-node exception-slot-exhausted cluster');
done_testing();
