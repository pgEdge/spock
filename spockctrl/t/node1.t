#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 15;
use IPC::Run qw(run);

# Test variables
my $NODE = "n2";
my $DB = "pgedge";
my $NODE_NAME = "n2";
my $DSN = "host=127.0.0.1 port=5433 user=pgedge password=pgedge";
my $INTERFACE_NAME = "interface1";
my $LOCATION = "New York";
my $COUNTRY = "USA";
my $INFO = "{\\\"key\\\": \\\"value\\\"}";
my $SUB_NAME = "sub2";
my $PROVIDER_DSN = "host=127.0.0.1 port=5433 user=pgedge password=pgedge";
my $IMMEDIATE = "true";

# Function to run a command and check its success
sub run_test {
    my ($description, $command) = @_;
    my $result = system($command);
    ok($result == 0, $description);
}

# Node-related tests
run_test("node spock-version", "./spockctrl node spock-version --node=$NODE --db=$DB");
run_test("node pg-version", "./spockctrl node pg-version --node=$NODE --db=$DB");
run_test("node create", "./spockctrl node create --node=$NODE --db=$DB --node_name=$NODE_NAME --dsn=\"$DSN\" --location=\"$LOCATION\" --country=\"$COUNTRY\" --info=\"$INFO\"");
run_test("node status", "./spockctrl node status --node=$NODE --db=$DB");
run_test("node gucs", "./spockctrl node gucs --node=$NODE --db=$DB");
run_test("node add-interface", "./spockctrl node add-interface --node=$NODE --db=$DB --node_name=$NODE_NAME --interface_name=$INTERFACE_NAME --dsn=\"$DSN\"");
run_test("sub create", "./spockctrl sub create --node=$NODE --db=$DB --sub_name=$SUB_NAME --provider_dsn=\"$PROVIDER_DSN\"");
run_test("sub enable", "./spockctrl sub enable --node=$NODE --db=$DB --sub_name=$SUB_NAME --immediate=$IMMEDIATE");
run_test("sub disable", "./spockctrl sub disable --node=$NODE --db=$DB --sub_name=$SUB_NAME --immediate=$IMMEDIATE");
run_test("sub show-status", "./spockctrl sub show-status --node=$NODE --db=$DB --sub_name=$SUB_NAME");
run_test("sub drop", "./spockctrl sub drop --node=$NODE --db=$DB --sub_name=$SUB_NAME");
run_test("node drop-interface", "./spockctrl node drop-interface --node=$NODE --db=$DB --node_name=$NODE_NAME --interface_name=$INTERFACE_NAME");

run_test("repset create", "./spockctrl repset create --node=$NODE --db=$DB --set_name=test_set --replicate_insert=true --replicate_update=true --replicate_delete=true --replicate_truncate=true");
run_test("repset drop", "./spockctrl repset drop --node=$NODE --db=$DB --set_name=test_set");
run_test("node drop", "./spockctrl node drop --node=$NODE --db=$DB --node_name=$NODE_NAME");
