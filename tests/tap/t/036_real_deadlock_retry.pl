use strict;
use warnings;
use Test::More;
use POSIX ();
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status
);

# 035_deadlock_retry.pl injects the transient SQLSTATEs directly.  This test
# provokes a real PostgreSQL-detected deadlock between the apply worker and a
# local user transaction on the subscriber, and asserts the worker retries the
# transaction instead of disabling the subscription.
#
# Making the apply worker (not the local session) the victim takes care:
# PostgreSQL cancels whichever backend runs the deadlock check and finds a
# cycle, and a waiter runs that check once, deadlock_timeout after it starts
# waiting.  So the worker must be the LAST of the two to enter its lock wait:
#
#   1. the replicated transaction updates id=2 first, so apply takes row 2
#   2. an AFTER UPDATE replica trigger on row 2 holds the apply worker there
#      (row 2 already locked) for a fixed window
#   3. inside that window the local session takes row 1 and then blocks on
#      row 2 -- no cycle exists yet, so its deadlock check finds nothing
#   4. the trigger returns and the apply worker asks for row 1, completing the
#      cycle as the later waiter; its check fires and elects it the victim

create_cluster(2, 'Create 2-node real deadlock retry cluster');

my $config = get_test_config();
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $pg_bin = $config->{pg_bin};
my $conn = "host=$config->{host} dbname=$config->{db_name} port=$p1 " .
           "user=$config->{db_user} password=$config->{db_password}";
my $subscriber_log = "$config->{log_dir}/00${p2}.log";

# sub_disable is the mode where mishandling a deadlock is most destructive:
# unfixed, the transient error stops replication altogether.
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = sub_disable");
psql_or_bail(2, "ALTER SYSTEM SET deadlock_timeout = '1s'");
psql_or_bail(2, "SELECT pg_reload_conf()");

psql_or_bail(1, "CREATE TABLE dl_real (id int PRIMARY KEY, v int)");
psql_or_bail(2, "CREATE TABLE dl_real (id int PRIMARY KEY, v int)");

# AFTER (not BEFORE) so the apply worker already holds row 2's lock while it
# sleeps.  Replica-only so the local session's own updates never fire it.
psql_or_bail(2, q{
    CREATE FUNCTION dl_real_hold() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
        PERFORM pg_sleep(10);
        RETURN NULL;
    END $$;
    CREATE TRIGGER dl_real_hold_trg AFTER UPDATE ON dl_real
        FOR EACH ROW WHEN (NEW.id = 2) EXECUTE FUNCTION dl_real_hold();
    ALTER TABLE dl_real ENABLE REPLICA TRIGGER dl_real_hold_trg;
});

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

psql_or_bail(1, "INSERT INTO dl_real VALUES (1, 1), (2, 2)");
my $seeded = 0;
for (1 .. 60) {
    $seeded = scalar_query(2, "SELECT count(*) FROM dl_real");
    last if defined $seeded && $seeded eq '2';
    sleep(1);
}
is($seeded, '2', 'seed rows replicate to the subscriber');

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
    $timeout //= 90;
    for (1 .. $timeout) {
        return 1 if read_log_from($offset) =~ $pattern;
        sleep(1);
    }
    return 0;
}

# Block until the apply worker is inside dl_real_hold(): spock sets
# application_name to the bgworker name, and pg_sleep() reports wait_event
# 'PgSleep'.  The trigger is AFTER UPDATE, so a sleeping worker already holds
# row 2 -- the precondition for the cycle below.
sub wait_for_apply_in_hold_trigger {
    my ($timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        my $n = scalar_query(2,
            "SELECT count(*) FROM pg_stat_activity " .
            "WHERE application_name LIKE 'spock apply %' " .
            "AND wait_event = 'PgSleep'");
        return 1 if defined $n && $n >= 1;
        sleep(1);
    }
    return 0;
}

my $log_offset = -s $subscriber_log // 0;

# Row 2 is updated first so that apply holds it while the trigger sleeps.
psql_or_bail(1, q{
    BEGIN;
    UPDATE dl_real SET v = 200 WHERE id = 2;
    UPDATE dl_real SET v = 100 WHERE id = 1;
    COMMIT;
});

# A fixed delay would race: if apply had not yet taken row 2, the local
# transaction below would take and release it unopposed and no cycle would form.
ok(wait_for_apply_in_hold_trigger(60),
    'apply worker is inside the hold trigger, holding row 2');

# The contending local transaction: takes row 1, then blocks on row 2.  It
# unblocks the moment the apply worker is aborted, then rolls back, which is
# what lets the retry finally succeed.
my $local_sql = 'BEGIN; ' .
                'UPDATE dl_real SET v = -1 WHERE id = 1; ' .
                'UPDATE dl_real SET v = -2 WHERE id = 2; ' .
                'ROLLBACK;';
my $local_pid = fork();
die 'fork() failed' unless defined $local_pid;
if ($local_pid == 0) {
    # Never exit() from this child.  It is a fork of a Test::More process, so
    # it carries the parent's Test::Builder state and SpockTest's END handler:
    # a normal exit would finalise the TAP plan a second time into the parent's
    # output stream, and run destroy_cluster() -- stopping both postmasters and
    # removing both datadirs -- while the parent is still running.
    # POSIX::_exit() skips END blocks.  Same reasoning as in
    # 103_manager_worker_dboid_race.pl.
    open(STDOUT, '>>', $config->{log_file}) or POSIX::_exit(127);
    open(STDERR, '>>', $config->{log_file}) or POSIX::_exit(127);
    exec("$pg_bin/psql", '-X', '-p', $p2, '-d', $config->{db_name},
         '-c', $local_sql);
    POSIX::_exit(127);
}

ok(wait_for_log($log_offset, qr/deadlock detected/, 90),
    'PostgreSQL detects a deadlock on the subscriber');

# This message is only reachable when the apply worker itself was the victim,
# so it also rules out the local session having been chosen instead.
ok(wait_for_log($log_offset,
        qr/transient error \(deadlock\/lock timeout\), will restart and retry.*40P01/,
        30),
    'apply worker is the deadlock victim and classifies it as transient');

waitpid($local_pid, 0);

is(scalar_query(2,
       "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'"),
   't', 'subscription is not disabled by the deadlock');
is(scalar_query(2,
       "SELECT count(*) FROM spock.exception_log WHERE table_name = 'dl_real'"),
   '0', 'deadlocked transaction is not logged to exception_log');

# The local transaction rolled back, so the retry has a clear field: both
# updates from the replicated transaction must land.
my $applied = '';
for (1 .. 120) {
    $applied = scalar_query(2,
        "SELECT string_agg(v::text, ',' ORDER BY id) FROM dl_real");
    last if $applied eq '100,200';
    sleep(1);
}
is($applied, '100,200', 'deadlocked transaction applies in full on retry');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 60),
    'subscription returns to replicating state');

unlike(read_log_from($log_offset),
       qr/Transaction failed, subscription will be disabled/,
       'deadlock does not enter the SUB_DISABLE exception path');

destroy_cluster('Destroy real deadlock retry cluster');
done_testing();
