use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail
    poll_query_until log_offset wait_for_log
);

# With spock.max_lag_for_availability_on_startup set, a restarted node
# rejects statements of ordinary sessions until its subscriptions have
# caught up, the drain times out, the gate is opened by hand, or the
# setting is switched off.

create_cluster(2, 'Create 2-node startup gate test cluster');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};
my $db     = $config->{db_name};
my $p1     = $config->{node_ports}->[0];
my $dir1   = $config->{node_datadirs}->[0];
my $dir2   = $config->{node_datadirs}->[1];

my $gate   = "SELECT gate_state || ':' || coalesce(gate_reason, '') " .
             "FROM spock.startup_status";

# Run a statement on n1 as the ordinary role.  Returns exit code and output.
sub app_query {
    my ($sql) = @_;
    my $out = `$pg_bin/psql -X -U gate_app -p $p1 -d $db -At -c "$sql" 2>&1`;
    return ($? >> 8, $out);
}

sub set_conf {
    my ($line) = @_;
    open(my $conf, '>>', "$dir1/postgresql.conf") or die "cannot open conf: $!";
    print $conf "$line\n";
    close($conf);
}

sub stop_node {
    my ($dir) = @_;
    system_or_bail("$pg_bin/pg_ctl", '-D', $dir, '-m', 'fast', '-w', 'stop');
}

sub start_node {
    my ($dir) = @_;
    system_or_bail("$pg_bin/pg_ctl", '-D', $dir, '-w', 'start');
}

psql_or_bail(1, "CREATE TABLE gate_t (id int PRIMARY KEY, v text)");
ok(poll_query_until(2,
        "SELECT count(*) FROM pg_class WHERE relname = 'gate_t'", '1'),
    'table reached n2');

# The role stays local to n1.
psql_or_bail(1, "SET spock.enable_ddl_replication = off; " .
                "CREATE ROLE gate_app LOGIN; " .
                "GRANT SELECT, INSERT ON gate_t TO gate_app");

# Off by default: a restarted node serves at once and reports no gate.
stop_node($dir1);
start_node($dir1);
my ($rc, $out) = app_query("SELECT count(*) FROM gate_t");
is($rc, 0, 'no gate by default');
is(scalar_query(1, "SELECT count(*) FROM spock.startup_status"), '0',
    'startup_status is empty by default');

# Gate on.  With the provider down the node cannot catch up, so the gate
# stays closed for as long as we like.
set_conf("spock.max_lag_for_availability_on_startup = '10s'");
set_conf("spock.startup_drain_timeout = '300s'");
stop_node($dir1);
psql_or_bail(2, "INSERT INTO gate_t SELECT g, 'x' FROM generate_series(1, 100) g");
stop_node($dir2);
my $offset = log_offset(1);
start_node($dir1);

ok(poll_query_until(1, $gate, 'draining:'), 'gate is closed after restart');

($rc, $out) = app_query("SELECT count(*) FROM gate_t");
isnt($rc, 0, 'read is rejected');
like($out, qr/catching up with its peers/, 'read reports the gate');
($rc, $out) = app_query("INSERT INTO gate_t VALUES (1000, 'y')");
isnt($rc, 0, 'write is rejected');
($rc, $out) = app_query("SET application_name = 'gate_test'");
is($rc, 0, 'SET passes the closed gate');
is(scalar_query(1, "SELECT count(*) FROM gate_t"), '0',
    'superuser is served and sees the old data');
cmp_ok(scalar_query(1, "SELECT max(rejected_statements) FROM spock.startup_status"),
    '>=', 2, 'rejected statements are counted');

# Bring the provider back: the node drains and opens.
start_node($dir2);
ok(poll_query_until(1, $gate, 'open:drained', 120), 'gate opens after the drain');
($rc, $out) = app_query("SELECT count(*) FROM gate_t");
is($rc, 0, 'read is served after the drain');
chomp($out);
is($out, '100', 'changes made during the outage are there');
is(scalar_query(1, "SELECT drain_state FROM spock.startup_status"), 'caughtup',
    'subscription is reported as caught up');
ok(wait_for_log(1, qr/startup drain round \d+ reached/, $offset),
    'round is logged');
cmp_ok(scalar_query(1, "SELECT count(*) FROM spock.events " .
                       "WHERE event_type LIKE 'startup_drain%'"),
    '>=', 2, 'drain events are recorded');

# A provider that keeps writing while the backlog is applied forces a
# second round.  The writer goes on until the test tells it to stop, so it
# cannot run out before the second round is there.
stop_node($dir1);
psql_or_bail(2, "INSERT INTO gate_t SELECT g, 'backlog' " .
                "FROM generate_series(10000, 209999) g");
my $p2 = $config->{node_ports}->[1];
system("$pg_bin/psql -X -p $p2 -d $db -qc \"DO \\\$\\\$ BEGIN " .
       "FOR i IN 200..2999 LOOP " .
       "EXIT WHEN EXISTS (SELECT 1 FROM gate_t WHERE id = -1); " .
       "INSERT INTO gate_t VALUES (i, 'busy'); " .
       "COMMIT; PERFORM pg_sleep(0.1); END LOOP; END \\\$\\\$\" " .
       ">/dev/null 2>&1 &");
$offset = log_offset(1);
start_node($dir1);
ok(wait_for_log(1, qr/startup drain round [2-9]\d* reached/, $offset, 120),
    'a busy provider needs more than one round');
psql_or_bail(2, "INSERT INTO gate_t VALUES (-1, 'stop')");
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity " .
        "WHERE query LIKE 'DO %busy%' AND pid <> pg_backend_pid()", '0', 60),
    'the writer has stopped');
ok(poll_query_until(1, $gate, 'open:drained', 120), 'busy drain opens the gate');
my $busy = scalar_query(2, "SELECT count(*) FROM gate_t WHERE v = 'busy'");
cmp_ok($busy, '>', 0, 'the writer wrote during the drain');
ok(poll_query_until(1, "SELECT count(*) FROM gate_t WHERE v = 'busy'",
        $busy, 120), 'writes made during the drain arrive');

# A database that gets Spock after the start has nothing to drain.
psql_or_bail(1, "CREATE DATABASE gate_late");
system_or_bail("$pg_bin/psql", '-X', '-p', $p1, '-d', 'gate_late', '-qc',
    'CREATE EXTENSION spock');
my $late = `$pg_bin/psql -X -U gate_app -p $p1 -d gate_late -At -c "SELECT 1" 2>&1`;
chomp($late);
is($late, '1', 'database that got Spock after the start is not gated');

# Timeout: the provider stays down and the gate opens anyway.
set_conf("spock.startup_drain_timeout = '5s'");
stop_node($dir1);
stop_node($dir2);
$offset = log_offset(1);
start_node($dir1);
ok(poll_query_until(1, $gate, 'open:timeout', 60), 'gate opens on timeout');
ok(wait_for_log(1, qr/startup gate opened on timeout/, $offset),
    'timeout is logged');
($rc, $out) = app_query("SELECT count(*) FROM gate_t");
is($rc, 0, 'read is served after the timeout');

# -1: an unreachable provider is set aside after three failed connects,
# and the gate opens without it.
set_conf("spock.startup_drain_timeout = -1");
stop_node($dir1);
$offset = log_offset(1);
start_node($dir1);
ok(poll_query_until(1, $gate, 'open:drained', 120),
    'gate opens without the unreachable provider');
is(scalar_query(1, "SELECT drain_state FROM spock.startup_status"), 'setaside',
    'unreachable subscription is set aside');
ok(wait_for_log(1, qr/opened without waiting for unreachable providers/, $offset),
    'set aside subscriptions are logged');

# No timeout: the gate waits until it is opened by hand.
set_conf("spock.startup_drain_timeout = 0");
stop_node($dir1);
start_node($dir1);
ok(poll_query_until(1, $gate, 'draining:'), 'gate is closed without a timeout');
sleep(3);
is(scalar_query(1, $gate), 'draining:', 'gate stays closed');
is(scalar_query(1, "SELECT spock.startup_gate_open()"), 't',
    'startup_gate_open() opens the gate');
is(scalar_query(1, $gate), 'open:manual', 'gate was opened by hand');
($rc, $out) = app_query("SELECT count(*) FROM gate_t");
is($rc, 0, 'read is served after the manual open');

# Switching the setting off on a reload opens the gate.
stop_node($dir1);
start_node($dir1);
ok(poll_query_until(1, $gate, 'draining:'), 'gate is closed again');
set_conf("spock.max_lag_for_availability_on_startup = 0");
system_or_bail("$pg_bin/pg_ctl", '-D', $dir1, 'reload');
ok(poll_query_until(1, $gate, 'open:disabled', 60), 'reload to 0 opens the gate');

start_node($dir2);
destroy_cluster('Destroy startup gate test cluster');
done_testing();
