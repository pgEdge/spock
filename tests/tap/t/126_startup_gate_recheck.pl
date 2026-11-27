use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail
    poll_query_until
);

# The startup gate opens when every subscription has caught up.  One that
# caught up early must still be caught up when the last one gets there: if
# its apply worker has lost the provider in between, the gate has to wait
# for it again and not open on what the worker found before.

create_cluster(3, 'Create 3-node startup gate test cluster');
cross_wire(3, ['n1', 'n2', 'n3'], 'Cross-wire n1, n2 and n3');

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};
my $dir1   = $config->{node_datadirs}->[0];
my $dir2   = $config->{node_datadirs}->[1];
my $dir3   = $config->{node_datadirs}->[2];

my $gate = "SELECT gate_state || ':' || coalesce(gate_reason, '') " .
           "FROM spock.startup_status LIMIT 1";

sub drain_state {
    my ($provider) = @_;
    return "SELECT replace(drain_state, ' ', '') FROM spock.startup_status " .
           "WHERE provider_node = '$provider'";
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
ok(poll_query_until(3,
        "SELECT count(*) FROM pg_class WHERE relname = 'gate_t'", '1'),
    'table reached n3');

# n1 comes back while n3 is down: n2 is caught up with, n3 is not.
open(my $conf, '>>', "$dir1/postgresql.conf") or die "cannot open conf: $!";
print $conf "spock.max_lag_for_availability_on_startup = '2s'\n";
print $conf "spock.startup_drain_timeout = 0\n";
close($conf);
stop_node($dir1);
stop_node($dir3);
start_node($dir1);

ok(poll_query_until(1, drain_state('n2'), 'caughtup', 120),
    'subscription to n2 has caught up');
is(scalar_query(1, $gate), 'draining:', 'gate waits for n3');

# Now n2 goes away too.  Its subscription is no longer caught up.
stop_node($dir2);
ok(poll_query_until(1, "SELECT count(*) FROM spock.startup_status " .
        "WHERE provider_node = 'n2' AND drain_state <> 'caught up'", '1', 60),
    'subscription to n2 is behind again once its provider is gone');

# n3 comes back and is caught up with.  The gate must stay closed.
start_node($dir3);
ok(poll_query_until(1, drain_state('n3'), 'caughtup', 120),
    'subscription to n3 has caught up');
is(scalar_query(1, $gate), 'draining:', 'gate still waits for n2');

start_node($dir2);
ok(poll_query_until(1, $gate, 'open:drained', 120),
    'gate opens once both have caught up');

destroy_cluster('Destroy startup gate test cluster');
done_testing();
