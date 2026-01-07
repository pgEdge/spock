package SpockTest;

use strict;
use warnings;
use Exporter 'import';
use Test::More;
use TAP::Formatter::Color;
use TAP::Harness;
use File::Path qw(make_path);
use File::Basename;
use Cwd;

our @EXPORT_OK = qw(
    create_cluster
    cross_wire
    destroy_cluster
    system_or_bail
    command_ok
    system_maybe
    get_test_config
    scalar_query
    psql_or_bail
);

# Test configuration
my $BASE_PORT = '5441';
my $HOST = '127.0.0.1';
my $DB_NAME = 'regression';
my $DB_USER = 'regression';
my $DB_PASSWORD = 'regression';

# PostgreSQL binary paths - get from PATH
my $PG_BIN = '';
sub {
    # Try to find PostgreSQL binaries in PATH
    for my $path (split(':', $ENV{PATH})) {
        if (-x "$path/psql" && -x "$path/initdb" && -x "$path/postgres") {
            $PG_BIN = $path;
            last;
        }
    }
    die "PostgreSQL binaries not found in PATH. Please ensure psql, initdb, and postgres are available." unless $PG_BIN;
}->();

# Logging - derive test name from script filename
my $test_name = basename($0, '.pl');  # e.g., "001_basic" from "t/001_basic.pl"
# Use TESTLOGDIR from environment (set by Makefile) or fall back to relative logs/
my $LOG_DIR = $ENV{TESTLOGDIR} // "logs";
eval { make_path($LOG_DIR) };
my $LOG_FILE = $ENV{SPOCKTEST_LOG_FILE} // "${LOG_DIR}/${test_name}.log";

# Redirect all STDERR (from Perl and child processes like backticks) to the per-test log
{
    open my $stderr_log, '>>', $LOG_FILE or die "Cannot open log $LOG_FILE: $!";
    select((select($stderr_log), $| = 1)[0]);
    open STDERR, '>>&', $stderr_log or die "Cannot dup STDERR: $!";
}

sub _run_cmd_logged_wait {
    my (@cmd) = @_;
    my $pid = fork();
    if (!defined $pid) {
        die "fork() failed";
    }
    if ($pid == 0) {
        open my $logfh, '>>', $LOG_FILE or die "Cannot open log $LOG_FILE: $!";
        open STDOUT, '>&', $logfh or die $!;
        open STDERR, '>&', $logfh or die $!;
        exec @cmd;
        exit 127;
    }
    waitpid($pid, 0);
    return ($? >> 8);
}

# Data directory base
my $DATADIR_BASE = '/tmp/tmp_spock_node';

# Global state
my $nodes_created = 0;
my $node_count = 0;
my @node_ports = ();
my @node_datadirs = ();

# Add PostgreSQL bin to PATH
$ENV{PATH} = "$PG_BIN:$ENV{PATH}";

# Disable user's psqlrc to prevent interference with test output
# (e.g., "\pset pager" produces "Pager usage is off." which breaks tests)
$ENV{PSQLRC} = '/dev/null';
$ENV{PSQL_HISTORY} = '/dev/null';

sub get_test_config {
    return {
        node_count => $node_count,
        node_ports => \@node_ports,
        host => $HOST,
        db_name => $DB_NAME,
        db_user => $DB_USER,
        db_password => $DB_PASSWORD,
        pg_bin => $PG_BIN,
        node_datadirs => \@node_datadirs,
        log_dir => $LOG_DIR,
        log_file => $LOG_FILE
    };
}

# Helper function to run system commands and bail on failure
sub system_or_bail {
    my @cmd = @_;
    my $rc = _run_cmd_logged_wait(@cmd);
    if ($rc != 0) {
        die "Command failed with exit code $rc: @cmd";
    }
}

# Helper function to run system commands and bail on failure
sub psql_or_bail {
    my ($node_num, $cmd) = @_;
    my $node_port = ($BASE_PORT + $node_num - 1);
    my @psql_cmd = ("$PG_BIN/psql", '-X', '-p', $node_port, '-d', $DB_NAME, '-t', '-c', $cmd);

    my $rc = _run_cmd_logged_wait(@psql_cmd);
    if ($rc != 0) {
        die "Command failed with exit code $rc: @psql_cmd";
    }
}

# Helper function to run commands and test results
sub command_ok {
    my ($cmd, $test_name) = @_;
    my $rc = _run_cmd_logged_wait(@$cmd);
    if ($rc == 0) {
        pass($test_name);
        return 1;
    } else {
        fail("$test_name: Command failed with exit code $rc");
        return 0;
    }
}

# Helper function to run commands that might fail (like creating existing users)
sub system_maybe {
    my @cmd = @_;
    my $rc = _run_cmd_logged_wait(@cmd);
    return $rc == 0;
}

# Create PostgreSQL configuration file
sub create_postgresql_conf {
    my ($datadir, $port) = @_;

    open(my $conf, '>>', "$datadir/postgresql.conf") or die "Cannot open config file: $!";
    print $conf "shared_buffers=1GB\n";
    print $conf "shared_preload_libraries='spock'\n";
    print $conf "wal_level=logical\n";
    print $conf "spock.enable_ddl_replication=on\n";
    print $conf "spock.include_ddl_repset=on\n";
    print $conf "spock.allow_ddl_from_functions=on\n";
    print $conf "spock.exception_behaviour=sub_disable\n";
    print $conf "spock.conflict_resolution=last_update_wins\n";
    print $conf "track_commit_timestamp=on\n";
    print $conf "spock.exception_replay_queue_size='1MB'\n";
    print $conf "spock.enable_spill=on\n";
    print $conf "port=$port\n";
    print $conf "listen_addresses='*'\n";

    # Enable logging
    print $conf "logging_collector=on\n";
    print $conf "log_directory='$LOG_DIR'\n";
    print $conf "log_filename='00$port.log'\n";
    print $conf "log_rotation_age=1d\n";
    print $conf "log_rotation_size=10MB\n";
    print $conf "log_min_messages=debug1\n";
    print $conf "log_statement=all\n";
    print $conf "log_line_prefix='%m [%p] %q%u@%d '\n";
    print $conf "log_checkpoints=on\n";
    print $conf "log_connections=on\n";
    print $conf "log_disconnections=on\n";
    print $conf "log_lock_waits=on\n";
    print $conf "log_temp_files=0\n";
    print $conf "log_autovacuum_min_duration=0\n";
    print $conf "log_replication_commands=on\n";
    print $conf "log_min_duration_statement=0\n";
    print $conf "log_statement_stats=on\n";

    close($conf);
}

# Create multi-node Spock cluster
sub create_cluster {
    my ($num_nodes, $test_name) = @_;
    $num_nodes //= 2;
    $test_name //= "Create $num_nodes-node Spock cluster";

    # Initialize arrays
    @node_ports = ();
    @node_datadirs = ();
    $node_count = $num_nodes;

    # Generate ports and datadirs for all nodes
    for (my $i = 0; $i < $num_nodes; $i++) {
        my $port = $BASE_PORT + $i;
        my $datadir = "${DATADIR_BASE}_${i}_datadir";
        push @node_ports, $port;
        push @node_datadirs, $datadir;
    }

    # Clean up any existing test directories
    for my $datadir (@node_datadirs) {
        system_or_bail 'rm', '-rf', $datadir;
    }

    # Initialize PostgreSQL data directories for all nodes
    for (my $i = 0; $i < $num_nodes; $i++) {
        system_or_bail "$PG_BIN/initdb", '-A', 'trust', '-D', $node_datadirs[$i];
    }

    # Ensure logs directory exists (uses TESTLOGDIR from env or relative logs/)
    system_or_bail 'mkdir', '-p', $LOG_DIR;
    system_or_bail 'chmod', '755', $LOG_DIR;

    # Copy configuration files if they exist
    if (-f 'regress-pg_hba.conf') {
        for my $datadir (@node_datadirs) {
            system_or_bail 'cp', 'regress-pg_hba.conf', "$datadir/pg_hba.conf";
        }
    }

    # Create PostgreSQL configuration for all nodes
    for (my $i = 0; $i < $num_nodes; $i++) {
        create_postgresql_conf($node_datadirs[$i], $node_ports[$i]);
    }

    # Start PostgreSQL instances for all nodes
    for (my $i = 0; $i < $num_nodes; $i++) {
        system("$PG_BIN/postgres -D $node_datadirs[$i] >> '$LOG_FILE' 2>&1 &");
    }

    # Allow PostgreSQL servers to startup
    system_or_bail 'sleep', '17';

    # Create superuser on all nodes (ignore if already exists)
    for (my $i = 0; $i < $num_nodes; $i++) {
        system_maybe "$PG_BIN/psql", '-p', $node_ports[$i], '-d', 'postgres', '-c', "CREATE USER super SUPERUSER";
    }

    # Create database and user for testing on all nodes (ignore if already exists)
    for (my $i = 0; $i < $num_nodes; $i++) {
        system_maybe "$PG_BIN/psql", '-p', $node_ports[$i], '-d', 'postgres', '-c', "CREATE DATABASE $DB_NAME";
        system_maybe "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c', "CREATE USER $DB_USER SUPERUSER";
    }

    # Install Spock extension on all nodes
    for (my $i = 0; $i < $num_nodes; $i++) {
        system_or_bail "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c', "CREATE EXTENSION IF NOT EXISTS spock";
        system_or_bail "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c', "ALTER EXTENSION spock UPDATE";
    }

    # Test if PostgreSQL instances are running
    for (my $i = 0; $i < $num_nodes; $i++) {
        my $node_name = "n" . ($i + 1);
        command_ok([ "$PG_BIN/pg_isready", '-h', $HOST, '-p', $node_ports[$i], '-U', $DB_USER ], "$node_name is running");
    }

    # Test Spock extension on all nodes
    for (my $i = 0; $i < $num_nodes; $i++) {
        my $node_name = "n" . ($i + 1);
        command_ok([ "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c', "SELECT 1 FROM pg_extension WHERE extname = 'spock'" ], "Check Spock extension on $node_name");
    }

    # Create nodes
    for (my $i = 0; $i < $num_nodes; $i++) {
        my $node_name = "n" . ($i + 1);
        system_or_bail "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c', "SELECT spock.node_create('$node_name', 'host=$HOST dbname=$DB_NAME port=$node_ports[$i] user=$DB_USER password=$DB_PASSWORD')";
    }

    $nodes_created = 1;

    pass($test_name);
    return 1;
}

# Cross-wire nodes with subscriptions following the cross-wire.json workflow
# Takes number of nodes and node names as parameters for flexibility
sub cross_wire {
    my ($num_nodes, $node_names, $test_name) = @_;
    $test_name //= 'Cross-wire nodes with subscriptions';

    die "No cluster created. Call create_cluster() first." unless $nodes_created;
    die "Number of nodes cannot exceed cluster size" unless $num_nodes <= $node_count;
    die "Node names array must match number of nodes" unless @$node_names == $num_nodes;

    # Step 1: Create subscriptions between all nodes (full mesh, skip self)
    for (my $i = 0; $i < $num_nodes; $i++) {
        for (my $j = 0; $j < $num_nodes; $j++) {
            next if $i == $j; # Skip self-subscription

            my $source_node = $node_names->[$i];
            my $target_node = $node_names->[$j];
            my $sub_name = "sub_${source_node}_${target_node}";

            # Create subscription from source_node to target_node
            system_or_bail(
                "$PG_BIN/psql",
                '-p', $node_ports[$i],
                '-d', $DB_NAME,
                '-c', "SELECT spock.sub_create('$sub_name', 'host=$HOST dbname=$DB_NAME port=$node_ports[$j] user=$DB_USER password=$DB_PASSWORD', ARRAY['default', 'default_insert_only', 'ddl_sql'], true, true)"
            );
        }
    }

    # Step 2: Create replication sets for each node
    for (my $i = 0; $i < $num_nodes; $i++) {
        my $node_name = $node_names->[$i];
        my $repset_name = "${node_name}r" . ($i + 1);

        system_or_bail(
            "$PG_BIN/psql",
            '-p', $node_ports[$i],
            '-d', $DB_NAME,
            '-c', "SELECT spock.repset_create('$repset_name', true, true, true, true)"
        );
    }

    # Step 3: Wait for cross-wiring to complete
    system_or_bail 'sleep', '10';

    pass($test_name);
    return 1;
}

# Cross-wire only the first 2 nodes (n1 and n2)
sub cross_wire_first_two {
    my ($test_name) = @_;
    $test_name //= 'Cross-wire first 2 nodes (n1 and n2)';

    die "No cluster created. Call create_cluster() first." unless $nodes_created;
    die "Need at least 2 nodes to cross-wire first two" unless $node_count >= 2;

    # Create subscriptions only between the first 2 nodes (n1 and n2)
    for (my $i = 0; $i < 2; $i++) {
        for (my $j = 0; $j < 2; $j++) {
            next if $i == $j; # Skip self-subscription

            my $source_node = "n" . ($i + 1);
            my $target_node = "n" . ($j + 1);
            my $sub_name = "sub_${source_node}_${target_node}";

            system_or_bail "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c', "SELECT spock.sub_create('$sub_name', 'host=$HOST dbname=$DB_NAME port=$node_ports[$j] user=$DB_USER password=$DB_PASSWORD', ARRAY['default', 'default_insert_only', 'ddl_sql'], true, true)";
        }
    }

    # Wait for cross-wiring to complete
    system_or_bail 'sleep', '10';

    pass($test_name);
    return 1;
}

# Destroy multi-node Spock cluster
sub destroy_cluster {
    my ($test_name) = @_;
    $test_name //= 'Destroy multi-node Spock cluster';

    if ($nodes_created) {
        # Cleanup subscriptions and nodes (ignore errors for subscriptions that don't exist)
        for (my $i = 0; $i < $node_count; $i++) {
			# Remove each subscription, created on the node
            system_maybe "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c',
			  "SELECT sub_name AS deleted_subscriptions,sub_origin,sub_target
			  FROM spock.subscription s, LATERAL spock.sub_drop(s.sub_name)";
        }

        for (my $i = 0; $i < $node_count; $i++) {
            my $node_name = "n" . ($i + 1);
            system_or_bail "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c', "SELECT spock.node_drop('$node_name')";
        }

        # Stop PostgreSQL instances
        for (my $i = 0; $i < $node_count; $i++) {
            system("$PG_BIN/pg_ctl stop -D $node_datadirs[$i] -m immediate >> '$LOG_FILE' 2>&1 &");
        }

        # Wait for processes to stop
        system_or_bail 'sleep', '5';

        # Clean up test directories
        for my $datadir (@node_datadirs) {
            system_or_bail 'rm', '-rf', $datadir;
        }

        $nodes_created = 0;
        $node_count = 0;
        @node_ports = ();
        @node_datadirs = ();
    }

    pass($test_name);
    return 1;
}

sub run_on_node {
    my ($node_num, $cmd) = @_;
    my $node_port = ($BASE_PORT + $node_num - 1);
    my $result = `$PG_BIN/psql -X -p $node_port -d $DB_NAME -t -c "$cmd"`;
    chomp($result);
    return $result;
}

sub scalar_query {
    my ($node_num, $cmd) = @_;
    my $result = run_on_node($node_num, $cmd);
    $result =~ s/\s+//g;
    return $result;
}

# Ensure cleanup on module destruction
END {
    destroy_cluster() if $nodes_created;
}

1;
