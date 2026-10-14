use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status
    log_offset log_since wait_for_log
);

# Some apply-worker errors are TRANSIENT: the same transaction succeeds on a
# later attempt.  Contention (40P01, 55P03) clears when the contending local
# transaction goes away, resource exhaustion (class 53) when the shortage
# passes, and a restarting or recovering provider (57P02, 57P03) comes back.
# All must take the abort-and-rethrow path -- the worker exits without
# advancing the replication origin, the manager respawns it, and the provider
# re-streams the transaction -- and must NOT enter the exception-handling path,
# which is for permanent data faults and would disable the subscription
# (sub_disable) or drop the transaction / row (transdiscard / discard).
#
# Each phase gates apply on a control row read by a replica trigger, standing
# in for a contending local transaction: while the gate is closed every apply
# attempt raises the transient SQLSTATE, and opening it is the equivalent of
# the local transaction committing.  That makes "the error clears and the
# transaction must then apply" deterministic, which a real deadlock race is
# not.  The tail of the file covers the inverse: codes that must stay
# permanent.  A real apply-vs-local deadlock is covered by
# 036_real_deadlock_retry.pl.

create_cluster(2, 'Create 2-node transient apply error retry cluster');

my $config = get_test_config();
my $p1 = $config->{node_ports}->[0];
my $conn = "host=$config->{host} dbname=$config->{db_name} port=$p1 " .
           "user=$config->{db_user} password=$config->{db_password}";

# Gate table and replica trigger live on the subscriber only; node 1 has no
# subscription back to node 2, so this DDL is not replicated.
psql_or_bail(2, q{
    CREATE TABLE dl_gate (id int PRIMARY KEY, blocked boolean, errcode text);
    INSERT INTO dl_gate VALUES (1, true, '40P01');
    CREATE FUNCTION dl_gate_check() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
        g record;
    BEGIN
        SELECT blocked, errcode INTO g FROM dl_gate WHERE id = 1;
        IF g.blocked THEN
            RAISE EXCEPTION 'injected transient apply failure'
                USING ERRCODE = g.errcode;
        END IF;
        RETURN NEW;
    END $$;
});

# Each retryable SQLSTATE reaches one of two branches in apply_work()'s
# PG_CATCH, which log differently.
my $CONTENTION_LOG = qr/transient error \(deadlock\/lock timeout\), will restart and retry/;
my $RESOURCE_LOG   = qr/transient resource error, will restart and retry/;
my $CONNECTION_LOG = qr/connection error during apply, exiting via rethrow/;

# All phase tables are created up front so that no DDL is replicated while a
# phase has apply gated.
my @phases = (
    # Contention.  40001 is absent -- see the contention branch in
    # spock_apply.c for why it is no longer classified as retryable.
    { table => 'dl_retry_discard',      mode => 'discard',      errcode => '40P01', logpat => $CONTENTION_LOG },
    { table => 'dl_retry_transdiscard', mode => 'transdiscard', errcode => '40P01', logpat => $CONTENTION_LOG },
    { table => 'dl_retry_sub_disable',  mode => 'sub_disable',  errcode => '40P01', logpat => $CONTENTION_LOG },
    { table => 'dl_retry_lock_timeout', mode => 'sub_disable',  errcode => '55P03', logpat => $CONTENTION_LOG },
    # Class 53, insufficient resources.  All four members are covered because
    # the C code tests the whole category; enumerating them here pins that.
    { table => 'dl_retry_disk_full',    mode => 'transdiscard', errcode => '53100', logpat => $RESOURCE_LOG },
    { table => 'dl_retry_out_of_mem',   mode => 'sub_disable',  errcode => '53200', logpat => $RESOURCE_LOG },
    { table => 'dl_retry_too_many_con', mode => 'discard',      errcode => '53300', logpat => $RESOURCE_LOG },
    { table => 'dl_retry_conf_limit',   mode => 'sub_disable',  errcode => '53400', logpat => $RESOURCE_LOG },
    # Provider going away or not ready yet; these take the connection branch.
    { table => 'dl_retry_crash_shut',   mode => 'sub_disable',  errcode => '57P02', logpat => $CONNECTION_LOG },
    { table => 'dl_retry_cannot_conn',  mode => 'transdiscard', errcode => '57P03', logpat => $CONNECTION_LOG },
);

# Codes that must NOT be classified as retryable.  Each is the specific hazard
# that makes a whole-category test wrong for its class, so these are what catch
# a future ERRCODE_TO_CATEGORY() collapse of the class 08 or class 40 checks.
# Run in discard mode so the subscription survives and the run continues.
my @permanent = (
    { table => 'dl_perm_constraint', errcode => '40002',
      why => 'deferred constraint violation (class 40) stays permanent' },
    { table => 'dl_perm_protocol',   errcode => '08P01',
      why => 'protocol violation (class 08) stays permanent' },
);

for my $phase (@phases, @permanent) {
    my $t = $phase->{table};
    psql_or_bail(1, "CREATE TABLE $t (id int PRIMARY KEY, val text)");
    psql_or_bail(2, "CREATE TABLE $t (id int PRIMARY KEY, val text)");
    psql_or_bail(2, "CREATE TRIGGER ${t}_gate BEFORE INSERT ON $t " .
                    "FOR EACH ROW EXECUTE FUNCTION dl_gate_check()");
    psql_or_bail(2, "ALTER TABLE $t ENABLE REPLICA TRIGGER ${t}_gate");
}

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

sub count_in_log {
    my ($offset, $pattern) = @_;
    my $data = log_since(2, $offset);
    my $n = () = $data =~ /$pattern/g;
    return $n;
}

sub wait_for_row {
    my ($table, $timeout) = @_;
    $timeout //= 90;
    for (1 .. $timeout) {
        my $c = scalar_query(2, "SELECT count(*) FROM $table WHERE id = 1");
        return $c if defined $c && $c eq '1';
        sleep(1);
    }
    return scalar_query(2, "SELECT count(*) FROM $table WHERE id = 1");
}

for my $phase (@phases) {
    my $t    = $phase->{table};
    my $mode = $phase->{mode};
    my $ec   = $phase->{errcode};
    my $tag  = "$ec/$mode";

    psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = $mode");
    psql_or_bail(2, "SELECT pg_reload_conf()");

    # Close the gate: every apply attempt for this table now raises $ec.
    psql_or_bail(2, "UPDATE dl_gate SET blocked = true, errcode = '$ec' WHERE id = 1");

    my $log_offset = log_offset(2);
    psql_or_bail(1, "INSERT INTO $t VALUES (1, 'must survive $tag')");

    ok(wait_for_log(2, qr/injected transient apply failure/, $log_offset, 60),
        "$tag: apply worker hits the transient error");

    # Give the error handler time to run to completion (disable the
    # subscription, or log to exception_log and discard) before asserting it
    # did none of those things.
    sleep(5);

    is(scalar_query(2,
           "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'"),
       't', "$tag: subscription is not disabled");
    is(scalar_query(2,
           "SELECT count(*) FROM spock.exception_log WHERE table_name = '$t'"),
       '0', "$tag: transaction is not logged to exception_log");
    is(scalar_query(2, "SELECT count(*) FROM $t WHERE id = 1"),
       '0', "$tag: row is not applied while the error persists");

    like(log_since(2, $log_offset), $phase->{logpat},
         "$tag: error is classified as retryable");

    # Every retry branch must set restart_delay to restart_delay_default; a
    # branch that leaves the restart_delay_on_exception (default 0) installed
    # by handle_begin() respawns the worker as fast as it can reconnect and
    # re-stream.  Over the grace window above, paced retries are a couple of
    # attempts; an unpaced branch was measured at ~80 per second.
    my $retries = count_in_log($log_offset, $phase->{logpat});
    cmp_ok($retries, '<=', 4,
        "$tag: retries are paced, not spinning ($retries in the grace window)");

    # Open the gate: this is the contending local transaction going away.
    psql_or_bail(2, "UPDATE dl_gate SET blocked = false WHERE id = 1");

    is(wait_for_row($t), '1', "$tag: transaction applies on retry");
    ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 60),
        "$tag: subscription returns to replicating state");
    is(scalar_query(2,
           "SELECT count(*) FROM spock.exception_log WHERE table_name = '$t'"),
       '0', "$tag: retried transaction leaves no exception_log entry");
}

# Negative coverage: these must still reach the exception path.  In discard
# mode that means the operation is logged to spock.exception_log and skipped,
# and none of the retry classifications fire.
for my $phase (@permanent) {
    my $t   = $phase->{table};
    my $ec  = $phase->{errcode};
    my $tag = "$ec/permanent";

    psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = discard");
    psql_or_bail(2, "SELECT pg_reload_conf()");
    psql_or_bail(2, "UPDATE dl_gate SET blocked = true, errcode = '$ec' WHERE id = 1");

    my $log_offset = log_offset(2);
    psql_or_bail(1, "INSERT INTO $t VALUES (1, 'must not be retried')");

    ok(wait_for_log(2, qr/injected transient apply failure/, $log_offset, 60),
        "$tag: apply worker hits the error");

    my $logged = 0;
    for (1 .. 60) {
        $logged = scalar_query(2,
            "SELECT count(*) FROM spock.exception_log WHERE table_name = '$t'");
        last if defined $logged && $logged >= 1;
        sleep(1);
    }
    ok($logged >= 1, "$tag: $phase->{why} - reaches the exception path");

    my $new_log = log_since(2, $log_offset);
    unlike($new_log, $CONTENTION_LOG, "$tag: not classified as contention");
    unlike($new_log, $RESOURCE_LOG,   "$tag: not classified as a resource shortage");
    unlike($new_log, $CONNECTION_LOG, "$tag: not classified as a connection error");

    psql_or_bail(2, "UPDATE dl_gate SET blocked = false WHERE id = 1");
}

destroy_cluster('Destroy transient apply error retry cluster');
done_testing();
