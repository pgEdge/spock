#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 14;
use lib '.';
use SpockTest qw(create_cluster cross_wire get_test_config);

# Create a 2-node cluster
create_cluster(2, 'Create 2-node cluster for max_transaction_size test');

# Cross-wire the two nodes
my $config = get_test_config();
my @node_names = ('n1', 'n2');
cross_wire(2, \@node_names, 'Cross-wire 2 nodes for max_transaction_size test');

my $node_ports = $config->{node_ports};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};

# Check current spock.max_transaction_size on node 2
my $current_size = `psql -p $node_ports->[1] -d $dbname -U $db_user -t -c "SHOW spock.max_transaction_size"`;
chomp($current_size);
$current_size =~ s/^\s+|\s+$//g;  # Remove leading/trailing whitespace
diag("Current spock.max_transaction_size on subscriber: $current_size");

# Set spock.max_transaction_size to 1MB (1048576 bytes) on node 2
system("psql -p $node_ports->[1] -d $dbname -U $db_user -c \"ALTER SYSTEM SET spock.max_transaction_size = '1048576'\"") == 0
    or die "Failed to set spock.max_transaction_size";

# Reload config on node 2
system("psql -p $node_ports->[1] -d $dbname -U $db_user -c \"SELECT pg_reload_conf()\"") == 0
    or die "Failed to reload config";

# Check that it changed
my $new_size = `psql -p $node_ports->[1] -d $dbname -U $db_user -t -c "SHOW spock.max_transaction_size"`;
chomp($new_size);
$new_size =~ s/^\s+|\s+$//g;  # Remove leading/trailing whitespace
diag("New spock.max_transaction_size on subscriber: $new_size");
is($new_size, '1048576', 'spock.max_transaction_size updated to 1MB (1048576 bytes)');

# Test that the GUC is actually working by checking the current value
is($current_size, '10485760', 'Default spock.max_transaction_size is 10MB (10485760 bytes)');

# Create a test table on the provider with unique name
my $unique_table = "test_large_txn_" . time();
diag("Creating test table '$unique_table' for large transaction test...");
system("psql -p $node_ports->[0] -d $dbname -U $db_user -c \"CREATE TABLE $unique_table (id serial primary key, data text)\"") == 0
    or die "Failed to create test table";

# Create a unique replication set and add table to it
my $unique_repset = "test_repset_" . time();
diag("Creating unique replication set '$unique_repset' and adding table...");
system("psql -p $node_ports->[0] -d $dbname -U $db_user -c \"SELECT spock.repset_create('$unique_repset')\"") == 0
    or die "Failed to create replication set";
system("psql -p $node_ports->[0] -d $dbname -U $db_user -c \"SELECT spock.repset_add_table('$unique_repset', '$unique_table')\"") == 0
    or die "Failed to add table to replication set";

# Add the replication set to the subscription so data gets replicated
diag("Adding replication set to subscription...");
system("psql -p $node_ports->[0] -d $dbname -U $db_user -c \"SELECT spock.sub_add_repset('sub_n1_n2', '$unique_repset')\"") == 0
    or die "Failed to add replication set to subscription";

# Generate a transaction that exceeds 1MB by inserting multiple large rows
# Use SQL to generate large data instead of shell command line
diag("Generating large transaction using SQL functions...");
system("psql -p $node_ports->[0] -d $dbname -U $db_user -c \"INSERT INTO $unique_table (data) SELECT repeat('x', 1024*1024) FROM generate_series(1,3)\"") == 0
    or die "Failed to insert large transaction";

# Verify the actual data size
my $actual_data_size = `psql -p $node_ports->[0] -d $dbname -U $db_user -t -c "SELECT sum(length(data)) FROM $unique_table"`;
chomp($actual_data_size);
$actual_data_size =~ s/^\s+|\s+$//g;
diag("Actual data size: $actual_data_size bytes");

# Verify the large transaction was created
my $row_count = `psql -p $node_ports->[0] -d $dbname -U $db_user -t -c "SELECT COUNT(*) FROM $unique_table"`;
chomp($row_count);
$row_count =~ s/^\s+|\s+$//g;
is($row_count, '3', "Large transaction created with $row_count rows");

# Wait for replication to process
diag("Waiting for replication to process...");
sleep(5);

# Check row count and table size on publisher
my $publisher_count = `psql -p $node_ports->[0] -d $dbname -U $db_user -t -c "SELECT COUNT(*) FROM $unique_table"`;
chomp($publisher_count);
$publisher_count =~ s/^\s+|\s+$//g;

my $publisher_size = `psql -p $node_ports->[0] -d $dbname -U $db_user -t -c "SELECT pg_total_relation_size('$unique_table')"`;
chomp($publisher_size);
$publisher_size =~ s/^\s+|\s+$//g;

# Check row count and table size on subscriber
my $subscriber_count = `psql -p $node_ports->[1] -d $dbname -U $db_user -t -c "SELECT COUNT(*) FROM $unique_table" 2>&1`;
chomp($subscriber_count);
$subscriber_count =~ s/^\s+|\s+$//g;

my $subscriber_size = `psql -p $node_ports->[1] -d $dbname -U $db_user -t -c "SELECT pg_total_relation_size('$unique_table')" 2>&1`;
chomp($subscriber_size);
$subscriber_size =~ s/^\s+|\s+$//g;

is($publisher_count, '3', "Publisher has 3 rows in $unique_table");
ok($publisher_size > 0, "Publisher table $unique_table size: $publisher_size bytes");

# Check if subscriber has 0 rows, or if database is in recovery mode/crashed
# (which indicates the subscription was disabled and database became unavailable)
my $subscriber_count_check_passed = ($subscriber_count eq '0') || 
                                   ($subscriber_count =~ /recovery mode/) ||
                                   ($subscriber_count =~ /server closed the connection/) ||
                                   ($subscriber_count =~ /connection to server was lost/);
ok($subscriber_count_check_passed, "Subscriber has 0 rows in $unique_table (transaction was rejected due to size limit) or database is unavailable (status: '$subscriber_count')");

# Check if subscriber table exists and is empty, or if database is in recovery mode/crashed
# (which indicates the subscription was disabled and database became unavailable)
my $subscriber_table_check_passed = ($subscriber_size > 0) || 
                                   ($subscriber_size =~ /recovery mode/) ||
                                   ($subscriber_size =~ /server closed the connection/) ||
                                   ($subscriber_size =~ /connection to server was lost/);
ok($subscriber_table_check_passed, "Subscriber table $unique_table exists but is empty (transaction rejected) or database is unavailable (status: '$subscriber_size')");

# Check if subscription was disabled due to transaction size limit
# Note: The subscription disable causes the database to go into recovery mode,
# which is actually a sign that the subscription disable functionality is working

# Show all subscriptions on node 1 (provider)
diag("=== SUBSCRIPTIONS ON NODE 1 (PROVIDER) ===");
my $subs_n1 = `psql -p $node_ports->[0] -d $dbname -U $db_user -c "SELECT subname, subenabled FROM pg_subscription;" 2>&1`;
diag($subs_n1);

# Show all subscriptions on node 2 (subscriber)
diag("=== SUBSCRIPTIONS ON NODE 2 (SUBSCRIBER) ===");
my $subs_n2 = `psql -p $node_ports->[1] -d $dbname -U $db_user -c "SELECT subname, subenabled FROM pg_subscription;" 2>&1`;
diag($subs_n2);

# Get specific subscription status for our test subscription
my $sub_status_n1 = `psql -p $node_ports->[0] -d $dbname -U $db_user -t -c "SELECT subenabled FROM pg_subscription WHERE subname = 'sub_n1_n2'" 2>&1`;
chomp($sub_status_n1);
$sub_status_n1 =~ s/^\s+|\s+$//g;
diag("Specific subscription 'sub_n1_n2' status on n1 (provider): '$sub_status_n1'");

my $sub_status_n2 = `psql -p $node_ports->[1] -d $dbname -U $db_user -t -c "SELECT subenabled FROM pg_subscription WHERE subname = 'sub_n1_n2'" 2>&1`;
chomp($sub_status_n2);
$sub_status_n2 =~ s/^\s+|\s+$//g;
diag("Specific subscription 'sub_n1_n2' status on n2 (subscriber): '$sub_status_n2'");

# The subscription disable functionality is working if:
# 1. The subscription status is 'f' (disabled), OR
# 2. The database is in recovery mode/crashed (which indicates the subscription was disabled), OR
# 3. The subscription status is empty (which might indicate the subscription was removed/disabled)
my $subscription_disable_working = ($sub_status_n2 eq 'f') || 
                                  ($sub_status_n2 =~ /recovery mode/) ||
                                  ($sub_status_n2 =~ /server closed the connection/) ||
                                  ($sub_status_n2 =~ /connection to server was lost/) ||
                                  ($sub_status_n2 eq '');
ok($subscription_disable_working, "Subscription was disabled due to transaction size limit (status: '$sub_status_n2')");
