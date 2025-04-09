#!/usr/bin/perl
# filepath: /home/pgedge/spock/spockctrl/t/sub.t

use strict;
use warnings;
use Test::More tests => 6;

# Test variables
my $NODE = "n1";
my $DB = "pgedge";
my $DSN = "host=127.0.0.1 port=5432 user=pgedge password=password1";
my $LOCATION = "location1";
my $COUNTRY = "country1";
my $INFO = "info1";

my $SUB_NAME = "s1";
my $PROVIDER_DSN = "host=127.0.0.1 port=5432 user=pgedge password=password1";
my $IMMEDIATE = "true";

# Function to run a command and check its success
sub run_test {
    my ($description, $command) = @_;
    my $result = system($command);
    ok($result == 0, $description);
}

# Node-related test
run_test("node create", "./spockctrl node create --node_name=$NODE --dsn=\"$DSN\" --location=\"$LOCATION\" --country=\"$COUNTRY\" --info=\"$INFO\"");

# Subscription-related tests
run_test("Creating spock subscription ($SUB_NAME)",
    "./spockctrl sub create --node=$NODE --sub_name=$SUB_NAME --provider_dsn=\"$PROVIDER_DSN\" --db=$DB");

run_test("Enabling spock subscription ($SUB_NAME)",
    "./spockctrl sub enable --node=$NODE --sub_name=$SUB_NAME --db=$DB --immediate=$IMMEDIATE");

run_test("Disabling spock subscription ($SUB_NAME)",
    "./spockctrl sub disable --node=$NODE --sub_name=$SUB_NAME --db=$DB --immediate=$IMMEDIATE");

run_test("Showing status of spock subscription ($SUB_NAME)",
    "./spockctrl sub show-status --node=$NODE --sub_name=$SUB_NAME --db=$DB");

run_test("Dropping spock subscription ($SUB_NAME)",
    "./spockctrl sub drop --node=$NODE --sub_name=$SUB_NAME --db=$DB");

# Node cleanup
run_test("node drop", "./spockctrl node drop --node_name=$NODE");