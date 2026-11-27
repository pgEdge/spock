use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail
    poll_query_until log_offset log_since
);

# A drain round ends when the apply worker has received everything up to
# the provider position taken at its start.  WAL that carries nothing for
# the subscription, such as the writes of another database, moves that
# position without sending a change.  With wal_sender_timeout off the
# provider sends no regular keepalive either, so the round has to be able
# to end without one.

create_cluster(3, 'Create 3-node startup gate test cluster');
cross_wire(3, ['n1', 'n2', 'n3'], 'Cross-wire n1, n2 and n3');

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};
my $port2  = $config->{node_ports}->[1];
my $dir1   = $config->{node_datadirs}->[0];
my $dir2   = $config->{node_datadirs}->[1];
my $dir3   = $config->{node_datadirs}->[2];

my $gate = "SELECT gate_state || ':' || coalesce(gate_reason, '') " .
           "FROM spock.startup_status LIMIT 1";
my $n2_state = "SELECT replace(drain_state, ' ', '') " .
               "FROM spock.startup_status WHERE provider_node = 'n2'";
my $n2_round = "SELECT round FROM spock.startup_status " .
               "WHERE provider_node = 'n2'";

sub stop_node {
    my ($dir) = @_;
    system_or_bail("$pg_bin/pg_ctl", '-D', $dir, '-m', 'fast', '-w', 'stop');
}

sub start_node {
    my ($dir) = @_;
    system_or_bail("$pg_bin/pg_ctl", '-D', $dir, '-w', 'start');
}

# WAL on n2 that the subscription of n1 gets nothing from.
sub other_database_write {
    my ($sql) = @_;
    system_or_bail("$pg_bin/psql", '-X', '-q', '-p', $port2,
                   '-d', 'postgres', '-c', $sql);
}

psql_or_bail(1, "CREATE TABLE gate_t (id int PRIMARY KEY, v text)");
ok(poll_query_until(2,
        "SELECT count(*) FROM pg_class WHERE relname = 'gate_t'", '1'),
    'table reached n2');
ok(poll_query_until(3,
        "SELECT count(*) FROM pg_class WHERE relname = 'gate_t'", '1'),
    'table reached n3');

open(my $conf2, '>>', "$dir2/postgresql.conf") or die "cannot open conf: $!";
print $conf2 "wal_sender_timeout = 0\n";
close($conf2);
stop_node($dir2);
start_node($dir2);
other_database_write("CREATE TABLE other_t (id int, v text)");

# n1 comes back while n3 is down, so the gate stays closed and the
# subscription to n2 keeps running rounds.
open(my $conf1, '>>', "$dir1/postgresql.conf") or die "cannot open conf: $!";
print $conf1 "spock.max_lag_for_availability_on_startup = '2s'\n";
print $conf1 "spock.startup_drain_timeout = 0\n";
close($conf1);
stop_node($dir1);
stop_node($dir3);
other_database_write(
    "INSERT INTO other_t SELECT g, 'down' FROM generate_series(1, 1000) g");
my $offset = log_offset(1);
start_node($dir1);

ok(poll_query_until(1, $n2_state, 'caughtup', 60),
    'subscription to an idle provider has caught up');

# Every later round starts at a position that only the other database
# moved.  Each has to end in time.  The round counter is read after the
# write: the next round then starts past the write, and the one after it
# starts only when that round has ended.
for my $i (1 .. 5)
{
    my $round;

    other_database_write(
        "INSERT INTO other_t SELECT g, 'r$i' FROM generate_series(1, 1000) g");
    $round = scalar_query(1, $n2_round);
    ok(poll_query_until(1,
            "SELECT round >= $round + 2 FROM spock.startup_status " .
            "WHERE provider_node = 'n2'", 't', 30),
        "rounds go on after write $i of the other database");
}

is(scalar_query(1, $n2_state), 'caughtup',
    'subscription to the idle provider is still caught up');
unlike(log_since(1, $offset), qr/behind again/,
    'no round was late');
is(scalar_query(1, $gate), 'draining:', 'gate waits for n3');

start_node($dir3);
ok(poll_query_until(1, $gate, 'open:drained', 120),
    'gate opens once both have caught up');

destroy_cluster('Destroy startup gate test cluster');
done_testing();
