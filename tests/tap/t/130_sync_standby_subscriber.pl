#!/usr/bin/perl
# A Spock subscriber named in synchronous_standby_names.
#
# The output plugin waits for the synchronous standbys to confirm a commit
# before it sends the commit to a subscriber, so that a failover to a
# physical standby cannot forget a transaction a Spock node already has.
# When the subscriber is itself the synchronous standby, the commit can only
# be confirmed after it has been sent, and the wait never ended: the session
# that committed waited with the walsender.
#
# The write runs in the background and the test polls for it, so that a
# commit that waits for ever fails a check instead of hanging the test.
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
my $pg_bin     = $config->{pg_bin};

psql_or_bail(2, "SELECT spock.sub_create('sub_n2_n1', "
              . "'host=$host port=$node_ports->[0] dbname=$dbname user=$db_user', "
              . "synchronize_structure := false, synchronize_data := false)");
poll_query_until(2, "SELECT count(*) FROM spock.sub_show_status() "
                  . "WHERE status = 'replicating'", '1', 60)
    or die 'n2 has no replicating subscription';

psql_or_bail(1, "CREATE TABLE sync_t (id int PRIMARY KEY)");
psql_or_bail(1, "INSERT INTO sync_t VALUES (1)");
sync_nodes(1, 2) or die 'sync n1 -> n2 timed out';

# The apply worker connects with its slot name as application_name.
my $slot = scalar_query(2, "SELECT sub_slot_name FROM spock.subscription");
psql_or_bail(1, "ALTER SYSTEM SET synchronous_standby_names = '$slot'");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(poll_query_until(1, "SELECT sync_state FROM pg_stat_replication "
                     . "WHERE application_name = '$slot'", 'sync', 30),
   "n2's apply worker is the synchronous standby of n1");

system("$pg_bin/psql -X -q -p $node_ports->[0] -d $dbname "
     . "-c \"INSERT INTO sync_t VALUES (2)\" >/dev/null 2>&1 &");
ok(poll_query_until(1, "SELECT count(*) FROM sync_t WHERE id = 2", '1', 20),
   'a commit on n1 returns');
ok(poll_query_until(2, "SELECT count(*) FROM sync_t WHERE id = 2", '1', 20),
   'and is on n2');
is(scalar_query(1, "SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'SyncRep'"),
   '0', 'nothing on n1 waits for synchronous replication');

# Back to asynchronous.  In the background too: if the commit above is
# still waiting, so are the walsenders, and a reload is what frees them.
system("$pg_bin/psql -X -q -p $node_ports->[0] -d $dbname "
     . "-c \"ALTER SYSTEM RESET synchronous_standby_names\" >/dev/null 2>&1 &");
poll_query_until(1, "SELECT count(*) FROM pg_file_settings "
                  . "WHERE name = 'synchronous_standby_names'", '0', 20);
system("$pg_bin/psql -X -q -p $node_ports->[0] -d $dbname "
     . "-c \"SELECT pg_reload_conf()\" >/dev/null 2>&1 &");
ok(poll_query_until(1, "SELECT current_setting('synchronous_standby_names')", '', 30),
   'n1 is asynchronous again');
psql_or_bail(1, "INSERT INTO sync_t VALUES (3)");
ok(sync_nodes(1, 2), 'n2 applies what n1 writes');
is(scalar_query(2, "SELECT count(*) FROM sync_t"), '3', 'n2 has every row');

destroy_cluster('Destroy test cluster');
done_testing();
