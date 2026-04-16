use strict;
use warnings;
use Test::More tests => 10;

use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster
    destroy_cluster
    scalar_query
    psql_or_bail
    get_test_config
);

# =============================================================================
# Version safety-net tests
#
# Exercises the node_version column in spock.local_node and the
# corresponding check inside get_local_node().
#
# IMPORTANT: Spock's autoddl event trigger calls get_local_node() on
# every DDL statement.  So we must always restore node_version to the
# correct value BEFORE issuing any DDL (ALTER TABLE, DROP COLUMN, etc.).
# Only set it to a wrong value right before the SELECT that tests the
# check.
# =============================================================================

create_cluster(1, 'Version safety-net test cluster');

my $cfg    = get_test_config();
my $PG_BIN = $cfg->{pg_bin};

# -----------------------------------------------------------------
# Scenario 1: fresh install -- node_version matches, operations work.
# -----------------------------------------------------------------
note("Scenario 1: version matches after create_node");

my $ver = scalar_query(1, "SELECT node_version FROM spock.local_node");
isnt($ver, '0', "node_version is non-zero after create_node");
isnt($ver, '', "node_version is not empty");

# spock.node_info() calls get_local_node(false, false) internally.
my $node_name = scalar_query(1,
    "SELECT node_name FROM spock.node_info()");
is($node_name, 'n1', "node_info succeeds with correct version");

# -----------------------------------------------------------------
# Scenario 2: version tampered to 0 -- simulates stale schema.
# -----------------------------------------------------------------
note("Scenario 2: node_version set to 0 (stale schema)");

psql_or_bail(1, "UPDATE spock.local_node SET node_version = 0");

my $output = psql_expect_error(1,
    "SELECT node_name FROM spock.node_info()");
like($output, qr/version mismatch/i,
    "error mentions version mismatch");
like($output, qr/ALTER EXTENSION spock UPDATE/,
    "error hints to run ALTER EXTENSION UPDATE");

# Restore before next scenario (DDL triggers get_local_node via autoddl).
psql_or_bail(1,
    "UPDATE spock.local_node SET node_version = spock.spock_version_num()");

# -----------------------------------------------------------------
# Scenario 3: version from the future -- simulates binary rollback.
# -----------------------------------------------------------------
note("Scenario 3: node_version higher than binary (rollback)");

psql_or_bail(1, "UPDATE spock.local_node SET node_version = 999999");

$output = psql_expect_error(1,
    "SELECT node_name FROM spock.node_info()");
like($output, qr/version mismatch.*999999/,
    "error includes the future version number");

# Restore before DDL.
psql_or_bail(1,
    "UPDATE spock.local_node SET node_version = spock.spock_version_num()");

# -----------------------------------------------------------------
# Scenario 4: column dropped -- simulates pre-6.0 schema.
# DDL must happen while version is correct (autoddl check).
# -----------------------------------------------------------------
note("Scenario 4: node_version column dropped (pre-6.0 schema)");

psql_or_bail(1,
    "ALTER TABLE spock.local_node DROP COLUMN node_version");

$output = psql_expect_error(1,
    "SELECT node_name FROM spock.node_info()");
like($output, qr/schema outdated/i,
    "error mentions outdated schema");
like($output, qr/ALTER EXTENSION spock UPDATE/,
    "error hint present for missing column");

# -----------------------------------------------------------------
# Scenario 5: column restored -- operations resume.
# We must disable the autoddl event trigger to run DDL when the
# schema is in a broken state (column missing).
# -----------------------------------------------------------------
note("Scenario 5: column restored with correct version");

# Disable autoddl trigger so ALTER TABLE can proceed without
# get_local_node() firing.
psql_or_bail(1, q{
    ALTER EVENT TRIGGER spock_autoddl DISABLE;
    ALTER TABLE spock.local_node
        ADD COLUMN node_version int4 NOT NULL DEFAULT 0;
    UPDATE spock.local_node
        SET node_version = spock.spock_version_num();
    ALTER EVENT TRIGGER spock_autoddl ENABLE;
});

$node_name = scalar_query(1,
    "SELECT node_name FROM spock.node_info()");
is($node_name, 'n1',
    "node_info succeeds after version restored");

destroy_cluster('Version safety-net test cleanup');

# =============================================================================
# Run psql expecting a failure; return combined stdout+stderr.
# =============================================================================
sub psql_expect_error {
    my ($node_num, $sql) = @_;
    my $port = $cfg->{node_ports}[$node_num - 1];
    my $result = `$PG_BIN/psql -X -p $port -d regression -t -c "$sql" 2>&1`;
    return $result;
}
