use strict;
use warnings;
use Test::More tests => 10;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config);

# Create a 2-node cluster
create_cluster(2, 'Create 2-node non-default replication set test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

# Create custom replication set on provider (node 0)
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "SELECT * FROM spock.repset_create('delay')";

# Create subscription on subscriber (node 1) to provider's 'delay' replication set
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', 
    "SELECT * FROM spock.sub_create('test_subscription_delay', 'host=$host dbname=$dbname port=$node_ports->[0] user=$db_user password=$db_password', ARRAY['delay'], false, false)";

# Wait for subscription to be replicating
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "DO \$\$
BEGIN
    FOR i IN 1..100 LOOP
        IF EXISTS (SELECT 1 FROM spock.sub_show_status() WHERE status = 'replicating') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
\$\$";

# Check subscription status
my $sub_status = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT subscription_name, status, provider_node, replication_sets, forward_origins FROM spock.sub_show_status()"`;
chomp($sub_status);
$sub_status =~ s/\s+/ /g;
like($sub_status, qr/test_subscription_delay.*replicating/, 'subscription is replicating');

# Wait for sync to complete
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "DO \$\$
BEGIN
    FOR i IN 1..300 LOOP
        IF EXISTS (SELECT 1 FROM spock.local_sync_status WHERE sync_status = 'r') THEN
            EXIT;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;\$\$";

# Check sync status
my $sync_status = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status FROM spock.local_sync_status ORDER BY 2,3,4"`;
chomp($sync_status);
ok(length($sync_status) > 0, 'sync status available');

# Create a function to wait for WAL replication
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "CREATE OR REPLACE FUNCTION public.pg_xlog_wait_remote_apply(i_pos pg_lsn, i_pid integer) RETURNS VOID
AS \$FUNC\$
BEGIN
    WHILE EXISTS(SELECT true FROM pg_stat_get_wal_senders() s WHERE s.replay_location < i_pos AND (i_pid = 0 OR s.pid = i_pid)) LOOP
        PERFORM pg_sleep(0.01);
    END LOOP;
END;\$FUNC\$ LANGUAGE plpgsql";

# Create table directly on provider (without automatic replication set assignment)
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "
    CREATE TABLE public.basic_dml1 (
        id serial primary key,
        other integer,
        data text,
        something interval
    );
";

# Remove from default replication set if it was automatically added
system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "SELECT spock.repset_remove_table('default', 'basic_dml1')";

# Check if table is already in delay replication set, if not add it
my $table_in_delay = `$pg_bin/psql -p $node_ports->[0] -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM spock.tables WHERE set_name = 'delay' AND relname = 'basic_dml1')"`;
chomp($table_in_delay);
$table_in_delay =~ s/\s+//g;

if ($table_in_delay eq 'f') {
    system_or_bail "$pg_bin/psql", '-p', $node_ports->[0], '-d', $dbname, '-c', "SELECT spock.repset_add_table('delay', 'basic_dml1', true)";
}

# Check subscription status after DDL
my $sub_status_after_ddl = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT status FROM spock.sub_show_status('test_subscription_delay')"`;
chomp($sub_status_after_ddl);
$sub_status_after_ddl =~ s/\s+//g;
is($sub_status_after_ddl, "replicating", 'subscription still replicating after DDL');

# Wait for sync to complete
system_or_bail 'sleep', '10';

# Test that table doesn't exist on subscriber (as expected for non-default replication set)
my $table_check = `$pg_bin/psql -p $node_ports->[1] -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'basic_dml1')"`;
chomp($table_check);
$table_check =~ s/\s+//g;
is($table_check, "f", 'table does not exist on subscriber (non-default replication set)');

# Clean up test-specific subscription first
system_or_bail "$pg_bin/psql", '-p', $node_ports->[1], '-d', $dbname, '-c', "SELECT spock.sub_drop('test_subscription_delay')";

# Clean up
destroy_cluster('Destroy 2-node non-default replication set test cluster');

done_testing();

