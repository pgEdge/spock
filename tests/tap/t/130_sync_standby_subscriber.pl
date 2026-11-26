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
# The subscriber must not be sent the commit early either.  With
# 'FIRST 1 (physical, subscriber)' the physical standby is the one that has to
# confirm, and the subscriber takes over only when that standby is gone.
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
                 system_or_bail get_test_config poll_query_until sync_nodes);

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

# A subscriber that reconnects is behind, and its walsender is not counted
# as a synchronous standby until it has caught up.  It must still be sent
# what it missed.
psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1')");
poll_query_until(1, "SELECT count(*) FROM pg_stat_replication "
                  . "WHERE application_name = '$slot'", '0', 30)
    or die "n2's walsender did not exit";
system_or_bail("$pg_bin/psql", '-X', '-q', '-p', $node_ports->[0], '-d', $dbname,
    '-c', 'SET synchronous_commit = local',
    '-c', 'INSERT INTO sync_t VALUES (6)');
psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1')");
ok(poll_query_until(2, "SELECT count(*) FROM sync_t WHERE id = 6", '1', 30),
   'n2 is sent a commit it missed while it was away');
ok(poll_query_until(1, "SELECT sync_state FROM pg_stat_replication "
                     . "WHERE application_name = '$slot'", 'sync', 30),
   'n2 is the synchronous standby again');

# A physical standby ahead of the subscriber in synchronous_standby_names.
my $standby_port = $node_ports->[0] + 10;
my $standby_dir  = $config->{node_datadirs}->[0] . '_standby';
my $walrcv_pid;
my $standby_running = 0;

# Do not leave the standby behind when the test dies.
END
{
    local $?;
    kill 'CONT', $walrcv_pid if $walrcv_pid;
    if ($standby_running)
    {
        system("$pg_bin/pg_ctl stop -D $standby_dir -m immediate >/dev/null 2>&1");
        system("rm -rf $standby_dir 2>/dev/null");
    }
}

system("rm -rf $standby_dir 2>/dev/null");
system_or_bail("$pg_bin/pg_basebackup", '-D', $standby_dir, '-h', $host,
    '-p', $node_ports->[0], '-U', $db_user, '-X', 'stream', '-c', 'fast');
{
    open(my $conf, '>>', "$standby_dir/postgresql.conf")
        or die "Cannot open standby postgresql.conf: $!";
    print $conf "port = $standby_port\n";
    print $conf "hot_standby = on\n";
    print $conf "primary_conninfo = 'host=$host port=$node_ports->[0] "
              . "user=$db_user application_name=physical'\n";
    close($conf);
    open(my $signal, '>', "$standby_dir/standby.signal")
        or die "Cannot create standby.signal: $!";
    close($signal);
}
$standby_running = 1;
system_or_bail("$pg_bin/pg_ctl", 'start', '-D', $standby_dir,
    '-l', "$standby_dir/startup.log", '-w');

psql_or_bail(1, "ALTER SYSTEM SET synchronous_standby_names = "
              . "'FIRST 1 (physical, \"$slot\")'");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(poll_query_until(1, "SELECT string_agg(sync_state, ',' ORDER BY application_name) "
                     . "FROM pg_stat_replication "
                     . "WHERE application_name IN ('physical', '$slot')",
                    $slot lt 'physical' ? 'potential,sync' : 'sync,potential', 30),
   'the physical standby is synchronous and n2 is a potential one');

# Stop the standby from confirming, and commit without waiting for it.  The
# walsender of n2 has its own synchronous_commit and must wait.
$walrcv_pid = `$pg_bin/psql -X -At -h $host -p $standby_port -d $dbname -U $db_user -c "SELECT pid FROM pg_stat_wal_receiver"`;
chomp($walrcv_pid);
$walrcv_pid =~ /^\d+$/ or die 'the standby has no WAL receiver';
kill 'STOP', $walrcv_pid;

system_or_bail("$pg_bin/psql", '-X', '-q', '-p', $node_ports->[0], '-d', $dbname,
    '-c', 'SET synchronous_commit = local',
    '-c', 'INSERT INTO sync_t VALUES (4)');
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity "
                     . "WHERE application_name = '$slot' "
                     . "AND wait_event = 'Extension'", '1', 30),
   "n2's walsender waits for the physical standby");
is(scalar_query(2, "SELECT count(*) FROM sync_t WHERE id = 4"), '0',
   'n2 does not have a commit the physical standby has not confirmed');

kill 'CONT', $walrcv_pid;
$walrcv_pid = undef;
ok(poll_query_until(2, "SELECT count(*) FROM sync_t WHERE id = 4", '1', 30),
   'n2 has it once the physical standby confirms');

# Without the physical standby n2 is the synchronous standby again.
system_or_bail("$pg_bin/pg_ctl", 'stop', '-D', $standby_dir, '-m', 'fast', '-w');
$standby_running = 0;
ok(poll_query_until(1, "SELECT sync_state FROM pg_stat_replication "
                     . "WHERE application_name = '$slot'", 'sync', 30),
   'n2 is the synchronous standby when the physical one is gone');
system("$pg_bin/psql -X -q -p $node_ports->[0] -d $dbname "
     . "-c \"INSERT INTO sync_t VALUES (5)\" >/dev/null 2>&1 &");
ok(poll_query_until(1, "SELECT count(*) FROM sync_t WHERE id = 5", '1', 20),
   'a commit on n1 returns then');
ok(poll_query_until(2, "SELECT count(*) FROM sync_t WHERE id = 5", '1', 20),
   'and is on n2');
system("rm -rf $standby_dir 2>/dev/null");

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
is(scalar_query(2, "SELECT count(*) FROM sync_t"), '6', 'n2 has every row');

destroy_cluster('Destroy test cluster');
done_testing();
