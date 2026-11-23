#!/usr/bin/perl
# A table is resynchronized, and the provider writes to it once the copy is
# done.
#
# When the copy is done the sync worker waits for the apply worker.  The
# apply worker answers as it commits the next transaction from the
# provider, telling the sync worker to catch up to the end of that
# transaction, and the sync worker is then sent it too.  It used to share
# the apply worker's entry in the exception log, found the transaction's
# commit LSN there, and took the transaction for one that had failed
# before: its changes to the table were discarded, or the subscription was
# disabled, as spock.exception_behaviour says.
#
# Copyright (c) 2022-2026, pgEdge, Inc.

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster scalar_query psql_or_bail
                 get_test_config poll_query_until sync_nodes);

create_cluster(2, 'Create 2-node cluster');

my $config     = get_test_config();
my $host       = $config->{host};
my $node_ports = $config->{node_ports};
my $dbname     = $config->{db_name};
my $db_user    = $config->{db_user};

psql_or_bail(2, "SELECT spock.sub_create('sub_n2_n1', "
              . "'host=$host port=$node_ports->[0] dbname=$dbname user=$db_user', "
              . "synchronize_structure := false, synchronize_data := false)");
poll_query_until(2, "SELECT count(*) FROM spock.sub_show_status() "
                  . "WHERE status = 'replicating'", '1', 60)
    or die 'n2 has no replicating subscription';

psql_or_bail(1, "CREATE TABLE resync_t (id int PRIMARY KEY, v int)");
psql_or_bail(1, "INSERT INTO resync_t SELECT g, 0 FROM generate_series(1, 100) g");
sync_nodes(1, 2) or die 'sync n1 -> n2 timed out';
is(scalar_query(2, "SELECT count(*) FROM resync_t"), '100',
   'the table replicates to n2');

my $status = "SELECT sync_status FROM spock.local_sync_status "
           . "WHERE sync_relname = 'resync_t'";

for my $round (1 .. 3)
{
    # The provider is quiet, so the copy ends with the sync worker waiting
    # for the apply worker: 'w'.
    psql_or_bail(2, "SELECT spock.sub_resync_table('sub_n2_n1', 'resync_t')");
    ok(poll_query_until(2, $status, 'w', 60),
       "round $round: the copy is done and waits for the apply worker");

    # This is the transaction the apply worker answers on, and the one the
    # sync worker is sent.
    psql_or_bail(1, "INSERT INTO resync_t VALUES (1000 + $round, $round)");
    ok(poll_query_until(2, $status, 'r', 60),
       "round $round: the table is synchronized again");
    ok(sync_nodes(1, 2), "round $round: n2 has applied what n1 wrote");

    is(scalar_query(2, "SELECT sub_enabled FROM spock.subscription"), 't',
       "round $round: the subscription is still enabled");
    is(scalar_query(2, "SELECT count(*) FROM spock.exception_log"), '0',
       "round $round: the transaction was not taken for one that had failed");
    is(scalar_query(2, "SELECT count(*) FROM resync_t"), 100 + $round,
       "round $round: n2 has the row written after the copy");
}

destroy_cluster('Destroy test cluster');
done_testing();
