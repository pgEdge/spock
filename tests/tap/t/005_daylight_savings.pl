use strict;
use warnings;
use Cwd;
use Config;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config);

# This is a special test, that tries to modify system time 
# Not required to run in usual suite tests
TODO: {
    todo_skip 'Whole test need rewriting using the new framework, with no sudo etc', 1;

    # Create a 2-node cluster
    create_cluster(2, 'Create 2-node daylight savings test cluster');

    # Get cluster configuration
    my $config = get_test_config();
    my $node_count = $config->{node_count};
    my $node_ports = $config->{node_ports};
    my $host = $config->{host};
    my $dbname = $config->{db_name};
    my $db_user = $config->{db_user};
    my $db_password = $config->{db_password};
    my $pg_bin = $config->{pg_bin};

    my $PROVIDER_PORT = $node_ports->[0];
    my $PGPORT = $node_ports->[1];
    my $PROVIDER_DSN = "postgresql://$db_user\@$host:$PROVIDER_PORT/$dbname";
    my $SUBSCRIBER_DSN = "postgresql://$db_user\@$host:$PGPORT/$dbname";

    #This test requires user to be a part of sudo group
    #for time and timezone changes
    #It is interactive now as it needs password to do sudo
    system_or_bail 'sudo', 'sntp', '-s', '24.56.178.140';
    my $timezone = `timedatectl |grep \'Timezone\'|cut -d ':' -f 2|cut -d ' ' -f 2|sed 's/ //g'`;

    #change timezone to before daylight savings border.
    command_ok([ 'timedatectl', 'set-timezone', 'America/Los_Angeles' ], 'pre-daylight savings time-zone check ');
    command_ok([ 'timedatectl', 'set-time', "2016-11-05 06:40:00" ], 'pre-daylight savings time check');

    #sleep for a short while after this date change
    system_or_bail 'sleep', '10';

    # Create nodes
    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT spock.node_create('test_provider', '$PROVIDER_DSN')";
    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT spock.node_create('test_subscriber', '$SUBSCRIBER_DSN')";

    # Create replication set
    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT spock.repset_create('delay')";

    # Create helper function
    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "CREATE or REPLACE function int2interval (x integer) returns interval as
\$\$ select \$1*'1 sec'::interval \$\$
language sql";

    # create default subscription
    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT spock.sub_create(
        'test_subscription',
        '$PROVIDER_DSN',
        ARRAY['default'],
        true,
        true
    )";

    # create delayed subscription too.
    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT spock.sub_create(
        'test_subscription_delay',
        '$PROVIDER_DSN',
        ARRAY['delay'],
        true,
        true,
        '1 second'::interval
    )";

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "DO \$\$
    BEGIN
            FOR i IN 1..100 LOOP
                    IF EXISTS (SELECT 1 FROM spock.sub_show_status() WHERE status = 'replicating' AND subscription_name = 'test_subscription_delay') THEN
                            RETURN;
                    END IF;
                    PERFORM pg_sleep(0.1);
            END LOOP;
    END;
    \$\$";

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT subscription_name, status, provider_node, replication_sets, forward_origins FROM spock.sub_show_status()";

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "DO \$\$
    BEGIN
        FOR i IN 1..300 LOOP
            IF EXISTS (SELECT 1 FROM spock.local_sync_status WHERE sync_status != 'r') THEN
                PERFORM pg_sleep(0.1);
            ELSE
                EXIT;
            END IF;
        END LOOP;
    END;\$\$";

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status FROM spock.local_sync_status ORDER BY 2,3,4";

    #change timezone to after daylight savings border.
    command_ok([ 'timedatectl', 'set-time', "2016-11-06 06:40:00" ], 'switching daylight savings time check');

    # sleep for ~5 mins to allow both servers to recover
    system_or_bail 'sleep', '300';
    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "DO \$\$
    BEGIN
            FOR i IN 1..100 LOOP
                    IF EXISTS (SELECT 1 FROM spock.sub_show_status() WHERE status = 'replicating' AND subscription_name = 'test_subscription_delay') THEN
                            RETURN;
                    END IF;
                    PERFORM pg_sleep(0.1);
            END LOOP;
    END;
    \$\$";

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT subscription_name, status, provider_node, replication_sets, forward_origins FROM spock.sub_show_status()";

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "DO \$\$
    BEGIN
        FOR i IN 1..300 LOOP
            IF EXISTS (SELECT 1 FROM spock.local_sync_status WHERE sync_status != 'r') THEN
                PERFORM pg_sleep(0.1);
            ELSE
                EXIT;
            END IF;
        END LOOP;
    END;\$\$";

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status FROM spock.local_sync_status ORDER BY 2,3,4";

    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "CREATE OR REPLACE FUNCTION public.pg_xlog_wait_remote_apply(i_pos pg_lsn, i_pid integer) RETURNS VOID
    AS \$FUNC\$
    BEGIN
        WHILE EXISTS(SELECT true FROM pg_stat_get_wal_senders() s WHERE s.replay_location < i_pos AND (i_pid = 0 OR s.pid = i_pid)) LOOP
                    PERFORM pg_sleep(0.01);
            END LOOP;
    END;\$FUNC\$ LANGUAGE plpgsql";

    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "CREATE TABLE public.timestamps (
            id text primary key,
            ts timestamptz
    )";

    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT spock.replicate_ddl(\$\$
        CREATE TABLE public.basic_dml1 (
            id serial primary key,
            other integer,
            data text,
            something interval
        );
    \$\$)";

    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0)";
    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "INSERT INTO timestamps VALUES ('ts1', CURRENT_TIMESTAMP)";
    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT spock.repset_add_table('delay', 'basic_dml1', true) ";

    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0)";
    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "INSERT INTO timestamps VALUES ('ts2', CURRENT_TIMESTAMP)";

    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "INSERT INTO basic_dml1(other, data, something)
    VALUES (5, 'foo', '1 minute'::interval),
           (4, 'bar', '12 weeks'::interval),
           (3, 'baz', '2 years 1 hour'::interval),
           (2, 'qux', '8 months 2 days'::interval),
           (1, NULL, NULL)";
    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), 0)";

    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "INSERT INTO timestamps VALUES ('ts3', CURRENT_TIMESTAMP)";

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "select * from spock.sub_show_status('test_subscription_delay');";
    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT round (EXTRACT(EPOCH FROM (SELECT ts from timestamps where id = 'ts2')) - EXTRACT(EPOCH FROM (SELECT ts from timestamps where id = 'ts1'))) :: integer as ddl_replicate_time";
    system_or_bail "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT round (EXTRACT(EPOCH FROM (SELECT ts from timestamps where id = 'ts3')) - EXTRACT(EPOCH FROM (SELECT ts from timestamps where id = 'ts2'))) :: integer as inserts_replicate_time";
    command_ok([ "$pg_bin/psql", '-p', "$PROVIDER_PORT", '-d', $dbname, '-c', "SELECT * FROM basic_dml1" ], 'provider data check');

    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "select * from spock.sub_show_status('test_subscription_delay');";
    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT * FROM spock.sub_show_table('test_subscription_delay', 'basic_dml1')";
    #check the data of table at subscriber
    command_ok([ "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT * FROM basic_dml1" ], 'replication check');

    # Clean up test-specific subscriptions
    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT spock.sub_drop('test_subscription_delay')";
    system_or_bail "$pg_bin/psql", '-p', "$PGPORT", '-d', $dbname, '-c', "SELECT spock.sub_drop('test_subscription')";

    # change time and timezone back to normal:
    command_ok([ 'sudo', 'sntp', '-s', '24.56.178.140' ], 'sync time with ntp server check');
    system("timedatectl set-timezone $timezone");

    # Clean up cluster
    destroy_cluster('Destroy 2-node daylight savings test cluster');
}

done_testing();
