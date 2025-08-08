package SpockTest;

use strict;
use warnings;
use Exporter 'import';
use Test::More;
use TAP::Formatter::Color;
use TAP::Harness;
use File::Path qw(make_path);

our @EXPORT_OK = qw(
    create_cluster
    cross_wire
    destroy_cluster
    system_or_bail
    command_ok
    system_maybe
    get_test_config
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

# Logging
my $LOG_FILE = $ENV{SPOCKTEST_LOG_FILE} // "logs/spocktest_$$.log";
eval { make_path('logs') };

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
    print $conf "shared_preload_libraries='spock'\n";
    print $conf "wal_level=logical\n";
    print $conf "spock.enable_ddl_replication=on\n";
    print $conf "spock.include_ddl_repset=on\n";
    print $conf "spock.allow_ddl_from_functions=on\n";
    print $conf "spock.exception_behaviour=sub_disable\n";
    print $conf "spock.conflict_resolution=last_update_wins\n";
    print $conf "track_commit_timestamp=on\n";
    print $conf "port=$port\n";
    print $conf "listen_addresses='*'\n";
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

# Cross-wire nodes with subscriptions (full mesh)
sub cross_wire {
    my ($test_name) = @_;
    $test_name //= 'Cross-wire nodes with subscriptions';
    
    die "No cluster created. Call create_cluster() first." unless $nodes_created;
    
    # Create subscriptions between all nodes (full mesh)
    for (my $i = 0; $i < $node_count; $i++) {
        for (my $j = 0; $j < $node_count; $j++) {
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
            for (my $j = 0; $j < $node_count; $j++) {
                next if $i == $j; # Skip self-subscription
                
                my $source_node = "n" . ($i + 1);
                my $target_node = "n" . ($j + 1);
                my $sub_name = "sub_${source_node}_${target_node}";
                
                system_maybe "$PG_BIN/psql", '-p', $node_ports[$i], '-d', $DB_NAME, '-c', "SELECT spock.sub_drop('$sub_name')";
            }
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

# Ensure cleanup on module destruction
END {
    destroy_cluster() if $nodes_created;
}

1;
