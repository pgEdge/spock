#
# Test for RT#60889, trying to reproduce an issue where sync fails during
# catchup with a walsender timeout for as-yet-unknown reasons.
#
use strict;
use warnings;
use Data::Dumper;
use Test::More tests => 10;
use Time::HiRes;
use Carp;
use IPC::Run;
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail command_ok get_test_config);

my $PGBENCH_SCALE = $ENV{PGBENCH_SCALE} // 1;
my $PGBENCH_CLIENTS = $ENV{PGBENCH_CLIENTS} // 5;
my $PGBENCH_JOBS = $ENV{PGBENCH_JOBS} // 1;
my $PGBENCH_TIME = $ENV{PGBENCH_TIME} // 30;
my $WALSENDER_TIMEOUT = $ENV{PGBENCH_TIMEOUT} // '5s';

$SIG{__DIE__} = sub { Carp::confess @_ };
$SIG{INT}  = sub { die("interupted by SIGINT"); };

# Create a 2-node cluster
create_cluster(2, 'Create 2-node sync during write test cluster');

# Get cluster configuration
my $config = get_test_config();
my $node_count = $config->{node_count};
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};

my $provider_port = $node_ports->[0];
my $subscriber_port = $node_ports->[1];
my $provider_connstr = "host=$host dbname=$dbname port=$provider_port user=$db_user password=$db_password";
my $subscriber_connstr = "host=$host dbname=$dbname port=$subscriber_port user=$db_user password=$db_password";

print "provider - connstr : $provider_connstr\n";
print "subscriber - connstr : $subscriber_connstr\n";

# Use existing nodes created by create_cluster
# Nodes are already created as 'n1' and 'n2' by create_cluster
my $provider_node = 'n1';
my $subscriber_node = 'n2';

# Initialise pgbench on provider and print initial data count in tables
system_or_bail "$pg_bin/pgbench", '-i', '-s', $PGBENCH_SCALE, '-h', $host, '-p', $provider_port, '-U', $db_user, $dbname;

my @pgbench_tables = ('pgbench_accounts', 'pgbench_tellers', 'pgbench_history');

# Tables are already added to replication sets automatically by pgbench
# No need to add them manually

# Create subscription
system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c',
    "SELECT spock.sub_create(
        'test_subscription',
        '$provider_connstr',
        ARRAY['default', 'default_insert_only'],
        true,
        true
    )";

# Wait for subscription to be replicating
my $max_attempts = 100;
my $attempt = 0;
my $replicating = 0;
while ($attempt < $max_attempts) {
    my $status = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT status FROM spock.sub_show_status() WHERE subscription_name = 'test_subscription'"`;
    chomp($status);
    $status =~ s/\s+//g;
    if ($status eq 'replicating') {
        $replicating = 1;
        last;
    }
    sleep(1);
    $attempt++;
}

BAIL_OUT('subscription failed to reach "replicating" state') unless $replicating;

# Make write-load active on the tables pgbench_history
# with this TPC-B-ish run. Run it in the background.
diag "provider port is $provider_port";
my $max_connections = `$pg_bin/psql -p $provider_port -d $dbname -t -c 'SHOW max_connections;'`;
chomp($max_connections);
$max_connections =~ s/\s+//g;
diag "max_connections is $max_connections";

my $pgbench_stdout='';
my $pgbench_stderr='';
my $pgbench_handle = IPC::Run::start(
    [ "$pg_bin/pgbench", '-T', $PGBENCH_TIME, '-j', $PGBENCH_JOBS, '-s', $PGBENCH_SCALE, '-c', $PGBENCH_CLIENTS, '-h', $host, '-p', $provider_port, '-U', $db_user, $dbname],
    '>', \$pgbench_stdout, '2>', \$pgbench_stderr);
$pgbench_handle->pump();

# Wait for pgbench to connect
$max_attempts = 100;
$attempt = 0;
my $pgbench_running = 0;
while ($attempt < $max_attempts) {
    my $running = `$pg_bin/psql -p $provider_port -d $dbname -t -c "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE query like 'UPDATE pgbench%')"`;
    chomp($running);
    $running =~ s/\s+//g;
    if ($running eq 't') {
        $pgbench_running = 1;
        last;
    }
    sleep(1);
    $attempt++;
}

BAIL_OUT('pgbench process is not running currently') unless $pgbench_running;

system_or_bail "$pg_bin/psql", '-p', $provider_port, '-d', $dbname, '-c', "ALTER SYSTEM SET log_statement = 'ddl'";
system_or_bail "$pg_bin/psql", '-p', $provider_port, '-d', $dbname, '-c', "SELECT pg_reload_conf()";

# Let it warm up for a while
note "warming up pgbench for " . ($PGBENCH_TIME/10) . "s";
sleep($PGBENCH_TIME/10);
note "done warmup";

# Get PIDs for monitoring
my $walsender_pid = `$pg_bin/psql -p $provider_port -d $dbname -t -c "SELECT pid FROM pg_stat_activity WHERE application_name = 'test_subscription'"`;
chomp($walsender_pid);
$walsender_pid =~ s/\s+//g;
$walsender_pid = int($walsender_pid);

my $apply_pid = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT pid FROM pg_stat_activity WHERE application_name LIKE '%apply%'"`;
chomp($apply_pid);
$apply_pid =~ s/\s+//g;
$apply_pid = int($apply_pid);

note "wal sender pid is $walsender_pid; apply worker pid is $apply_pid";

my $i = 1;
my $pgbench_active;
do {
    # Resync all the tables in turn
    EACH_TABLE: for my $tbl (@pgbench_tables)
    {
        my $resync_start = [Time::HiRes::gettimeofday()];

        eval {
            system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c',
                "SELECT spock.sub_resync_table('test_subscription', '$tbl')";
        };
        if ($@)
        {
            my $sync_status = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT sync_status FROM spock.local_sync_status WHERE sync_relname = '$tbl'"`;
            chomp($sync_status);
            $sync_status =~ s/\s+//g;
            diag "attempt to resync $tbl failed with $@; sync_status is currently $sync_status";
            fail("$tbl didn't sync: resync request failed");
            next EACH_TABLE;
        }

        while (1)
        {
            Time::HiRes::usleep(100);

            my $running = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT pid FROM pg_stat_activity WHERE application_name LIKE '%sync%'"`;
            chomp($running);
            $running =~ s/\s+//g;

            my $status = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT sync_status FROM spock.local_sync_status WHERE sync_relname = '$tbl'"`;
            chomp($status);
            $status =~ s/\s+//g;

            if ($status eq 'r')
            {
                pass("$tbl synced on iteration $i (elapsed " . Time::HiRes::tv_interval($resync_start) . ")" );
                last;
            }
            elsif ($status eq 'i')
            {
                # worker still starting
            }
            elsif ($status eq 'y')
            {
                # worker done but master hasn't noticed yet
                # keep looping until master notices and switches to 'r'
            }
            elsif (!$running)
            {
                fail("$tbl didn't sync on iteration $i, sync worker exited (running=$running) while sync state was '$status' (elapsed " . Time::HiRes::tv_interval($resync_start) . ")" );
            }
        }
    }

    $i++;

    # and repeat until pgbench exits
    my $pgbench_active = `$pg_bin/psql -p $provider_port -d $dbname -t -c "SELECT 1 FROM pg_stat_activity WHERE application_name = 'pgbench'"`;
    chomp($pgbench_active);
    $pgbench_active =~ s/\s+//g;
} while ($pgbench_active);

$pgbench_handle->finish;
note "##### output of pgbench #####";
note $pgbench_stdout;
note "##### end of output #####";

is($pgbench_handle->full_result(0), 0, "pgbench run successful");

note "waiting for catchup";

# Wait for catchup
system_or_bail "$pg_bin/psql", '-p', $provider_port, '-d', $dbname, '-c', 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)';

note "comparing tables";

# Compare final table entries on provider and subscriber.
for my $tbl (@pgbench_tables)
{
    my $rowcount_provider = `$pg_bin/psql -p $provider_port -d $dbname -t -c "SELECT count(*) FROM $tbl"`;
    chomp($rowcount_provider);
    $rowcount_provider =~ s/\s+//g;

    my $rowcount_subscriber = `$pg_bin/psql -p $subscriber_port -d $dbname -t -c "SELECT count(*) FROM $tbl"`;
    chomp($rowcount_subscriber);
    $rowcount_subscriber =~ s/\s+//g;

    my $matched = is($rowcount_subscriber, $rowcount_provider,
        "final $tbl row counts match after sync");
    if (!$matched)
    {
        diag "final provider rowcount for $tbl is $rowcount_provider, but subscriber has $rowcount_subscriber";

        my $sortkey;
        if ($tbl eq "pgbench_history") {
            $sortkey = "1, 2, 3, 4";
        } elsif ($tbl eq "pgbench_tellers" || $tbl eq "pgbench_accounts") {
            $sortkey = "1, 2";
        } elsif ($tbl eq "pgbench_branches") {
            $sortkey = "1";
        }

        # Compare the tables
        system_or_bail "$pg_bin/psql", '-p', $provider_port, '-d', $dbname, '-c', "\\copy (SELECT * FROM $tbl ORDER BY $sortkey) to tmp_check/$tbl-provider";
        system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c', "\\copy (SELECT * FROM $tbl ORDER BY $sortkey) to tmp_check/$tbl-subscriber";
        system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c', "\\copy (SELECT * FROM $tbl, spock.xact_commit_timestamp_origin($tbl.xmin) ORDER BY $sortkey) to tmp_check/$tbl-subscriber-detail";
        system_or_bail 'diff', '-u', "tmp_check/$tbl-provider", "tmp_check/$tbl-subscriber", '>', "tmp_check/$tbl-diff";
        diag "differences between $tbl on provider and subscriber recorded in tmp_check/";
    }
}

# Clean up test-specific subscription
system_or_bail "$pg_bin/psql", '-p', $subscriber_port, '-d', $dbname, '-c', "SELECT spock.sub_drop('test_subscription')";

# Clean up cluster
destroy_cluster('Destroy 2-node sync during write test cluster');

done_testing();
