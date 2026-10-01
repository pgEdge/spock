#!/usr/bin/perl
#
# =============================================================================
# Test: 048_change_log_attmap.pl - SPOC-704
# =============================================================================
# spock.apply_change_logging builds its JSON from SpockTupleData.  That array
# is indexed by LOCAL attribute position - spock_read_tuple() writes every
# value at rel->attmap[i], and converts it to the LOCAL column type.  But
# append_row_json() (src/spock_change_log.c) reads it at the REMOTE index i,
# and takes the column name and the type from the remote side as well.
#
# The two indexes agree only when provider and subscriber have identical
# physical layouts: same column order, no dropped columns on either side.
# That is exactly the shape of the table in 044_apply_change_logging.pl, so
# that test cannot see this.  Here the layouts differ, and each case pins
# down one consequence:
#
#   Case 1 (cl_reorder)  Same types, different column order.  Every value is
#                        taken from the wrong column - including "pk", so
#                        key_only mode is affected too, and a DELETE logs
#                        pk.id as null, leaving nothing to identify the row.
#
#   Case 2 (cl_dropped)  A dropped column on the subscriber.  The dropped
#                        slot is always NULL, so one column logs as null and
#                        every later column is shifted by one position.  Here
#                        a text pointer lands under int4out() and the low 32
#                        bits of an address are logged as a number.
#
#   Case 3 (cl_crash)    A local int4 sitting in the slot of a remote text.
#                        textout() dereferences the integer as a pointer and
#                        the apply worker takes SIGSEGV.  The postmaster
#                        restarts the instance, the worker replays the same
#                        transaction, and it crashes again - a crash loop
#                        that lasts until someone turns the GUC off.  This
#                        test turns it off itself, then proves the node is
#                        healthy again.
#
# Every assertion states what the log SHOULD say.  The data applied to the
# tables is correct in all three cases and the test checks that too, so a
# failure here is unambiguously a change-log bug and not a replication one.
#
# Expected on unfixed code: the value assertions fail, and case 3 fails with
# a dead apply worker.  Expected after the fix: all green.
# =============================================================================

use strict;
use warnings;
use Test::More;
use Time::HiRes qw(usleep);
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail wait_for_sub_status
    log_offset log_since poll_query_until
);

# -------------------------------------------------------------------------
# Cluster setup
# -------------------------------------------------------------------------
create_cluster(2, 'Create 2-node cluster for change-log attmap test');

my $config = get_test_config();
my $host   = $config->{host};
my $dbname = $config->{db_name};
my $user   = $config->{db_user};
my $pw     = $config->{db_password};
my $ports  = $config->{node_ports};
my $pg_bin = $config->{pg_bin};

my $conn_n1 = "host=$host dbname=$dbname port=$ports->[0] "
            . "user=$user password=$pw";

# -------------------------------------------------------------------------
# Schema: deliberately divergent physical layouts
# -------------------------------------------------------------------------
# DDL replication is off for these CREATEs so the two nodes can disagree
# about column order, which is the whole point.  Spock maps columns by name,
# so replication itself is expected to work throughout - cl_control, with an
# identical layout on both nodes, is the control that proves it.
# -------------------------------------------------------------------------
psql_or_bail(1,
    'SET spock.enable_ddl_replication = off; '
  . 'CREATE TABLE cl_reorder (id int PRIMARY KEY, a int, b int); '
  . 'CREATE TABLE cl_dropped (id int PRIMARY KEY, a text, b int); '
  . 'CREATE TABLE cl_crash   (id int PRIMARY KEY, a text, b int); '
  . 'CREATE TABLE cl_control (id int PRIMARY KEY, v text)');

psql_or_bail(2,
    'SET spock.enable_ddl_replication = off; '
    # same types, reversed order
  . 'CREATE TABLE cl_reorder (b int, a int, id int PRIMARY KEY); '
    # same order, but with a hole punched in the middle
  . 'CREATE TABLE cl_dropped (id int PRIMARY KEY, x int, a text, b int); '
  . 'ALTER TABLE cl_dropped DROP COLUMN x; '
    # int4 where the remote has text, and text where the remote has int4
  . 'CREATE TABLE cl_crash   (id int PRIMARY KEY, b int, a text); '
  . 'CREATE TABLE cl_control (id int PRIMARY KEY, v text)');

psql_or_bail(1,
    "SELECT spock.repset_add_table('default', 'cl_reorder'); "
  . "SELECT spock.repset_add_table('default', 'cl_dropped'); "
  . "SELECT spock.repset_add_table('default', 'cl_crash'); "
  . "SELECT spock.repset_add_table('default', 'cl_control')");

# No structure or data sync: the subscriber's tables are what this test just
# built, and a sync would replace them with the provider's layout.
psql_or_bail(2,
    "SELECT spock.sub_create('cl_sub', '$conn_n1', "
  . "ARRAY['default','default_insert_only'], false, false)");

ok(wait_for_sub_status(2, 'cl_sub', 'replicating', 60),
    'subscription cl_sub reaches replicating state');

# Baseline: a table with matching layouts replicates before we touch anything.
psql_or_bail(1, "INSERT INTO cl_control VALUES (1, 'baseline')");
ok(poll_query_until(2, 'SELECT count(*) = 1 FROM cl_control WHERE id = 1'),
    'baseline row replicates on the control table');

# -------------------------------------------------------------------------
# Case 1: same types, different column order
# -------------------------------------------------------------------------
# attmap maps remote (id,a,b) to local (2,1,0), so SpockTupleData holds
# b's value at slot 0 and id's at slot 2.  Reading slot i for remote column
# i therefore reports id as 100, a as 10 and b as 1.
# -------------------------------------------------------------------------
set_change_logging('verbose');

my $off = log_offset(2);
psql_or_bail(1, 'INSERT INTO cl_reorder VALUES (1, 10, 100)');
ok(poll_query_until(2, 'SELECT count(*) = 1 FROM cl_reorder WHERE id = 1'),
    'case 1: INSERT replicated');
is(scalar_query(2, "SELECT id || '/' || a || '/' || b FROM cl_reorder"),
    '1/10/100', 'case 1: the row itself is applied correctly');

my $line = wait_for_change_line(2, $off, qr/"action":"INSERT".*"table":"cl_reorder"/);
ok($line, 'case 1: INSERT change-log record emitted');

SKIP: {
    skip 'no cl_reorder INSERT record', 3 unless $line;
    like($line, qr/"pk":\{"id":"1"\}/,
        'case 1 INSERT: pk.id is 1, not the value of a different column');
    like($line, qr/"new":\{[^}]*"a":"10"/, 'case 1 INSERT: new.a is 10');
    like($line, qr/"new":\{[^}]*"b":"100"/, 'case 1 INSERT: new.b is 100');
}

$off = log_offset(2);
psql_or_bail(1, 'UPDATE cl_reorder SET a = 11 WHERE id = 1');
ok(poll_query_until(2, 'SELECT a = 11 FROM cl_reorder WHERE id = 1'),
    'case 1: UPDATE replicated');

$line = wait_for_change_line(2, $off, qr/"action":"UPDATE".*"table":"cl_reorder"/);
ok($line, 'case 1: UPDATE change-log record emitted');

SKIP: {
    skip 'no cl_reorder UPDATE record', 3 unless $line;
    like($line, qr/"pk":\{"id":"1"\}/,     'case 1 UPDATE: pk.id is 1');
    like($line, qr/"new":\{[^}]*"a":"11"/, 'case 1 UPDATE: new.a is 11');
    like($line, qr/"new":\{[^}]*"b":"100"/, 'case 1 UPDATE: new.b is 100');
}

# A DELETE carries only the replica-identity columns, so every slot except
# id's is NULL.  Read at the remote index, that prints pk.id as null - a
# change-log record that cannot say which row was deleted.
$off = log_offset(2);
psql_or_bail(1, 'DELETE FROM cl_reorder WHERE id = 1');
ok(poll_query_until(2, 'SELECT count(*) = 0 FROM cl_reorder WHERE id = 1'),
    'case 1: DELETE replicated');

$line = wait_for_change_line(2, $off, qr/"action":"DELETE".*"table":"cl_reorder"/);
ok($line, 'case 1: DELETE change-log record emitted');

SKIP: {
    skip 'no cl_reorder DELETE record', 2 unless $line;
    like($line, qr/"pk":\{"id":"1"\}/,
        'case 1 DELETE: pk.id identifies the deleted row');
    like($line, qr/"old":\{"id":"1"/, 'case 1 DELETE: old.id is 1');
}

# key_only builds "pk" through the same wrong index, so it is affected even
# though it never prints the row payload.
set_change_logging('key_only');

$off = log_offset(2);
psql_or_bail(1, 'INSERT INTO cl_reorder VALUES (2, 20, 200)');
ok(poll_query_until(2, 'SELECT count(*) = 1 FROM cl_reorder WHERE id = 2'),
    'case 1: key_only INSERT replicated');

$line = wait_for_change_line(2, $off, qr/"action":"INSERT".*"table":"cl_reorder"/);
ok($line, 'case 1: key_only INSERT change-log record emitted');

SKIP: {
    skip 'no key_only cl_reorder INSERT record', 2 unless $line;
    like($line, qr/"pk":\{"id":"2"\}/, 'case 1 key_only: pk.id is 2');
    unlike($line, qr/"new":\{/, 'case 1 key_only: no row payload');
}

# -------------------------------------------------------------------------
# Case 2: same column order, dropped column on the subscriber
# -------------------------------------------------------------------------
# Local layout is (id, dropped, a, b), so attmap is (0,2,3).  Slot 1 belongs
# to the dropped column and is never filled, so reading slot i for remote
# column i gives a=null and prints the text pointer from slot 2 through
# int4out() - the low 32 bits of an address, logged as a number.
# -------------------------------------------------------------------------
set_change_logging('verbose');

$off = log_offset(2);
psql_or_bail(1, "INSERT INTO cl_dropped VALUES (1, 'hello', 42)");
ok(poll_query_until(2, 'SELECT count(*) = 1 FROM cl_dropped WHERE id = 1'),
    'case 2: INSERT replicated');
is(scalar_query(2, "SELECT id || '/' || a || '/' || b FROM cl_dropped"),
    '1/hello/42', 'case 2: the row itself is applied correctly');

$line = wait_for_change_line(2, $off, qr/"action":"INSERT".*"table":"cl_dropped"/);
ok($line, 'case 2: INSERT change-log record emitted');

SKIP: {
    skip 'no cl_dropped INSERT record', 3 unless $line;
    like($line, qr/"new":\{"id":"1","a":"hello","b":"42"\}/,
        'case 2 INSERT: every column logged at its own value');
    unlike($line, qr/"a":null/,
        'case 2 INSERT: no column reads the dropped slot and logs null');
    unlike($line, qr/"b":"-?\d{6,}"/,
        'case 2 INSERT: b is not a pointer printed as an integer');
}

$off = log_offset(2);
psql_or_bail(1, 'UPDATE cl_dropped SET b = 43 WHERE id = 1');
ok(poll_query_until(2, 'SELECT b = 43 FROM cl_dropped WHERE id = 1'),
    'case 2: UPDATE replicated');

$line = wait_for_change_line(2, $off, qr/"action":"UPDATE".*"table":"cl_dropped"/);
ok($line, 'case 2: UPDATE change-log record emitted');

SKIP: {
    skip 'no cl_dropped UPDATE record', 1 unless $line;
    like($line, qr/"new":\{"id":"1","a":"hello","b":"43"\}/,
        'case 2 UPDATE: every column logged at its own value');
}

# -------------------------------------------------------------------------
# Case 3: a local int4 in the slot of a remote text - SIGSEGV
# -------------------------------------------------------------------------
# Local layout is (id, b, a), so attmap is (0,2,1) and slot 1 holds b's
# int4 42.  Remote column 1 is a text, so the datum 42 is handed to
# textout(), which dereferences address 42 and dies.  The postmaster
# restarts every backend, the apply worker replays the same transaction,
# and it dies again: the subscriber instance is in a crash loop until the
# GUC goes off.  This is the last case in the file for that reason.
# -------------------------------------------------------------------------
my $crash_off = log_offset(2);
psql_or_bail(1, "INSERT INTO cl_crash VALUES (1, 'hello', 42)");

# Race the two possible outcomes: on fixed code the record appears, on
# unfixed code the worker dies first.  Whichever happens, stop waiting.
my $crashed    = 0;
my $crash_line = undef;
for (1 .. 600) {
    if (log_since(2, $crash_off) =~ /was terminated by signal \d+/) {
        $crashed = 1;
        last;
    }
    $crash_line =
        change_line(2, $crash_off, qr/"action":"INSERT".*"table":"cl_crash"/);
    last if $crash_line;
    usleep(100_000);
}

ok(!$crashed,
    'case 3: apply worker survives a text column read from an int4 slot');

SKIP: {
    skip 'apply worker crashed, no JSON record to inspect', 2 if $crashed;
    ok($crash_line, 'case 3: INSERT change-log record emitted');
    like($crash_line // '', qr/"new":\{"id":"1","a":"hello","b":"42"\}/,
        'case 3 INSERT: every column logged at its own value');
}

# -------------------------------------------------------------------------
# Break the crash loop, then prove the node came back
# -------------------------------------------------------------------------
# With the GUC off the apply worker stops building the JSON, so the
# transaction finally commits and the replay stops repeating.  The instance
# is restarting underneath us, which takes out any connection we happen to
# hold, so retry until one attempt lands rather than bailing on the first
# failure.
my $quiesced = 0;
for (1 .. 120) {
    if (psql_try(2, "ALTER SYSTEM SET spock.apply_change_logging = 'none'")
        && psql_try(2, 'SELECT pg_reload_conf()'))
    {
        $quiesced = 1;
        last;
    }
    sleep(1);
}
ok($quiesced, 'change logging could be turned off on the subscriber');

# The crash happens before the transaction commits, so until now cl_crash
# has been empty on n2.  Once the log is out of the way the same change
# applies cleanly, which is the point: the data path was never wrong.
ok(poll_query_until(2, 'SELECT count(*) = 1 FROM cl_crash WHERE id = 1',
                    't', 120),
    'case 3: the change applies once change logging is out of the way');
is(scalar_query(2, "SELECT id || '/' || a || '/' || b FROM cl_crash"),
    '1/hello/42', 'case 3: the row itself is applied correctly');

psql_or_bail(1, "INSERT INTO cl_control VALUES (2, 'after')");
ok(poll_query_until(2, 'SELECT count(*) = 1 FROM cl_control WHERE id = 2',
                    't', 120),
    'subscriber is replicating again after case 3');

# -------------------------------------------------------------------------
# Cleanup
# -------------------------------------------------------------------------
psql_try(2, 'ALTER SYSTEM RESET spock.apply_change_logging');
psql_try(2, 'SELECT pg_reload_conf()');
psql_try(2, "SELECT spock.sub_drop('cl_sub')");
psql_try(1, 'SET spock.enable_ddl_replication = off; '
          . 'DROP TABLE IF EXISTS cl_reorder, cl_dropped, cl_crash, '
          . 'cl_control CASCADE');
destroy_cluster('Destroy change-log attmap cluster');

done_testing();

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

# ALTER SYSTEM + reload, the way the GUC reaches the apply worker: it is a
# separate backend, so a SET in a psql session never gets there.  The short
# sleep lets the worker act on the SIGHUP before the next change arrives.
sub set_change_logging {
    my ($mode) = @_;
    psql_or_bail(2, "ALTER SYSTEM SET spock.apply_change_logging = '$mode'");
    psql_or_bail(2, 'SELECT pg_reload_conf()');
    sleep(2);
}

# The last "spock apply change" line since $offset that matches $re, or
# undef.  The last rather than the first: after a crash the apply worker
# replays from its origin LSN and can re-emit earlier records, and the
# freshest line is the one that reflects the current code path.
sub change_line {
    my ($node_num, $offset, $re) = @_;
    my $found;

    for my $l (split /\n/, log_since($node_num, $offset)) {
        next unless index($l, 'spock apply change:') >= 0;
        $found = $l if $l =~ $re;
    }
    return $found;
}

# Poll change_line() until it matches or $timeout seconds pass.
sub wait_for_change_line {
    my ($node_num, $offset, $re, $timeout) = @_;
    $timeout //= 30;

    for (1 .. $timeout * 10) {
        my $l = change_line($node_num, $offset, $re);
        return $l if $l;
        usleep(100_000);
    }
    return undef;
}

# psql that reports failure instead of dying, for statements aimed at a node
# that may be restarting under us.  Output goes nowhere: it would otherwise
# land on stdout and corrupt the TAP stream.
sub psql_try {
    my ($node_num, $sql) = @_;
    my $port = $ports->[$node_num - 1];
    my $pid  = fork();

    die 'fork() failed' unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', '/dev/null') or exit 127;
        open(STDERR, '>&', \*STDOUT)   or exit 127;
        exec("$pg_bin/psql", '-X', '-q', '-p', $port, '-d', $dbname,
             '-t', '-A', '-c', $sql);
        exit 127;
    }
    waitpid($pid, 0);
    return (($? >> 8) == 0);
}
