use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status wait_for_exception_log
);

# =============================================================================
# Test 020: discarded entries log the captured root cause
# =============================================================================
# In TRANSDISCARD/SUB_DISABLE replay, only the record whose command_counter
# matches failed_action used to get the real error; every other discarded
# record logged a synthetic "... discarded ... at command_counter N" with no
# root cause (and command_counter 0 when the failure was not attributable to a
# row).
#
# Scenario A (row-attributable): a two-row transaction fails on its second row
# (an ALWAYS BEFORE INSERT trigger on the subscriber RAISEs for that row). On
# replay the first row is a non-failing discard -- exactly the errmsg==NULL
# path. Its exception_log entry must contain the real RAISE text.
#
# Scenario B (commit-time / not row-attributable): a DEFERRABLE INITIALLY
# DEFERRED constraint trigger (ENABLE ALWAYS, so it fires under replica role)
# that exists only on the subscriber and RAISEs at COMMIT. The row applies fine;
# the failure surfaces during CommitTransactionCommand, where handle_commit has
# already bumped the action counter and no per-row counter matches -- i.e. the
# failed_action-not-attributable path this PR fixes. Verifies the captured root
# cause is surfaced, the transaction is discarded, and apply does not wedge.
#
# (A deferred UNIQUE/FK constraint can't be used here: session_replication_role
# = replica suppresses index and RI constraint checks during apply, so only an
# ENABLE ALWAYS trigger reliably fires.)
#
# Uses TRANSDISCARD so failed transactions are discarded and apply continues,
# leaving the per-entry exception_log rows committed and observable. The code
# path (log_insert_exception) is identical under SUB_DISABLE.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for exception root-cause test');

my $config = get_test_config();
my $p1   = $config->{node_ports}->[0];
my $conn = "host=$config->{host} dbname=$config->{db_name} port=$p1 " .
           "user=$config->{db_user} password=$config->{db_password}";

# Poll until the apply-side config actually reflects the new setting, rather
# than relying on a fixed sleep (which is flaky under load).
sub wait_for_guc {
    my ($node, $guc, $want, $timeout) = @_;
    $timeout //= 30;
    for (1 .. $timeout) {
        my $v = scalar_query($node, "SHOW $guc");
        return 1 if defined $v && $v eq $want;
        sleep(1);
    }
    return 0;
}

psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = transdiscard");
psql_or_bail(2, "SELECT pg_reload_conf()");
ok(wait_for_guc(2, 'spock.exception_behaviour', 'transdiscard', 30),
    'subscriber picked up exception_behaviour = transdiscard');

# --- Scenario A table: row-attributable failure via subscriber trigger -------
psql_or_bail(1, "CREATE TABLE excroot (id int PRIMARY KEY, val text)");
psql_or_bail(2, "CREATE TABLE excroot (id int PRIMARY KEY, val text)");

# Subscriber-side guard: an ALWAYS BEFORE INSERT trigger that fails the 'bad'
# row during apply. ENABLE ALWAYS so it fires under session_replication_role.
psql_or_bail(2, q{
    CREATE FUNCTION excroot_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
        IF NEW.val = 'bad' THEN
            RAISE EXCEPTION 'boom on row %', NEW.id;
        END IF;
        RETURN NEW;
    END $$;
    CREATE TRIGGER excroot_guard_trg BEFORE INSERT ON excroot
        FOR EACH ROW EXECUTE FUNCTION excroot_guard();
    ALTER TABLE excroot ENABLE ALWAYS TRIGGER excroot_guard_trg;
});

# --- Scenario B table: deferred constraint trigger only on the subscriber ----
# The trigger fires at COMMIT (DEFERRABLE INITIALLY DEFERRED) and under replica
# role (ENABLE ALWAYS), and RAISEs only for the 'bad' key so a later good row
# can prove recovery.
psql_or_bail(1, "CREATE TABLE defcon (id int PRIMARY KEY, k int)");
psql_or_bail(2, "CREATE TABLE defcon (id int PRIMARY KEY, k int)");
psql_or_bail(2, q{
    CREATE FUNCTION defcon_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
        IF NEW.k = 5 THEN
            RAISE EXCEPTION 'deferred boom at commit for k=%', NEW.k;
        END IF;
        RETURN NULL;
    END $$;
    CREATE CONSTRAINT TRIGGER defcon_guard_trg AFTER INSERT ON defcon
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION defcon_guard();
    ALTER TABLE defcon ENABLE ALWAYS TRIGGER defcon_guard_trg;
});

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 reaches replicating state');

# =============================================================================
# Scenario A: row-attributable failure
# =============================================================================
# One transaction, two rows: row 1 ('good') applies, row 2 ('bad') fails on the
# subscriber. With TRANSDISCARD the whole transaction is discarded and both rows
# are logged to exception_log; apply then continues.
psql_or_bail(1, "INSERT INTO excroot VALUES (1, 'good'), (2, 'bad')");

ok(wait_for_exception_log(2, "operation = 'INSERT' AND remote_new_tup::text LIKE '%good%'", 30),
    'exception_log has an INSERT entry for the non-failing (good) row');

diag("=== exception_log dump (scenario A) ===");
diag(scalar_query(2,
    "SELECT coalesce(string_agg(format('[op=%s msg=%s]', operation, error_message), E' | '), '(empty)') " .
    "FROM spock.exception_log WHERE operation = 'INSERT'"));

# The failing 'bad' row (matched by command_counter) carries the real error;
# the non-failing 'good' row points at it via command_counter (cheap, no
# per-row duplication).
my $bad_msg = scalar_query(2,
    "SELECT error_message FROM spock.exception_log " .
    "WHERE operation = 'INSERT' AND remote_new_tup::text LIKE '%bad%' " .
    "ORDER BY retry_errored_at DESC LIMIT 1");
my $good_msg = scalar_query(2,
    "SELECT error_message FROM spock.exception_log " .
    "WHERE operation = 'INSERT' AND remote_new_tup::text LIKE '%good%' " .
    "ORDER BY retry_errored_at DESC LIMIT 1");

diag("bad-row  msg: $bad_msg");
diag("good-row msg: $good_msg");
like($bad_msg, qr/boom/, "failing row carries the real error message");
like($good_msg, qr/command_counter/, "non-failing row points at the failing row's command_counter");

# =============================================================================
# Scenario B: commit-time failure (deferred unique), not attributable to a row
# =============================================================================
# A single row with the 'bad' key applies fine, then the deferred trigger RAISEs
# during COMMIT -- the failure is attributable to no counted row.
psql_or_bail(1, "INSERT INTO defcon VALUES (1, 5)");

ok(wait_for_exception_log(2, "table_name = 'defcon'", 60),
    'exception_log records the deferred-constraint (commit-time) failure');

diag("=== exception_log dump (scenario B) ===");
diag(scalar_query(2,
    "SELECT coalesce(string_agg(format('[op=%s cc=%s msg=%s]', operation, command_counter, error_message), E' | '), '(empty)') " .
    "FROM spock.exception_log WHERE table_name = 'defcon'"));

# Before the fix this entry would dangle ("command_counter 0"); now the captured
# root cause must be surfaced.
my $defcon_msg = scalar_query(2,
    "SELECT error_message FROM spock.exception_log " .
    "WHERE table_name = 'defcon' ORDER BY retry_errored_at DESC LIMIT 1");
diag("defcon commit-time msg: $defcon_msg");
# scalar_query strips whitespace, so match the spaceless form of the RAISE text.
like($defcon_msg, qr/deferredboom/,
    'commit-time failure surfaces the captured root cause (not a dangling command_counter)');

# The transaction must be discarded, NOT applied: no defcon rows on n2.
is(scalar_query(2, "SELECT count(*) FROM defcon"), 0,
   "commit-time-failed transaction was discarded (no rows applied)");

# Apply must not wedge: a subsequent non-conflicting transaction still arrives.
psql_or_bail(1, "INSERT INTO defcon VALUES (10, 100)");
my $recovered = 0;
for (1 .. 60) {
    $recovered = scalar_query(2, "SELECT count(*) FROM defcon WHERE id = 10");
    last if $recovered;
    sleep(1);
}
ok($recovered, 'apply recovers after the commit-time discard (later txn replicates)');
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'sub_n1_n2 still replicating after commit-time discard');

destroy_cluster('Destroy cluster after exception root-cause test');
done_testing();
