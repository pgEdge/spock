#!/usr/bin/perl
# filepath: /home/pgedge/spock/spockctrl/t/node.t

use strict;
use warnings;
use Test::More tests => 7;

# Test variables
my $NODE = "n1";
my $DB = "pgedge";
my $DSN = "host=127.0.0.1 port=5433 user=pgedge password=password1";
my $INTERFACE_NAME = "interface1";
my $LOCATION = "location1";
my $COUNTRY = "country1";
my $INFO = "info1";

# Function to run a command and check its success
sub run_test {
    my ($description, $command) = @_;
    my $result = system($command);
    ok($result == 0, $description);
}

# Node-related tests
run_test("node spock-version", "./spockctrl node spock-version --node=$NODE --db=$DB");
run_test("node pg-version", "./spockctrl node pg-version --node=$NODE --db=$DB");
run_test("node create", "./spockctrl node create --node_name=$NODE --dsn=\"$DSN\" --location=\"$LOCATION\" --country=\"$COUNTRY\" --info=\"$INFO\"");
run_test("node status", "./spockctrl node status --node=$NODE --db=$DB");
run_test("node gucs", "./spockctrl node gucs --node=$NODE --db=$DB");
run_test("node add-interface", "./spockctrl node add-interface --node_name=$NODE --interface_name=$INTERFACE_NAME --dsn=\"$DSN\"");
run_test("node drop-interface", "./spockctrl node drop-interface --node_name=$NODE --interface_name=$INTERFACE_NAME");
run_test("node drop", "./spockctrl node drop --node_name=$NODE");