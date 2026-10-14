#!/usr/bin/perl
# Test that spock.sub_resync_table() warns when the cached spock.node row of
# the subscription's provider differs from the provider's own row.

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster scalar_query
                 get_test_config psql_or_bail wait_for_sub_status);

create_cluster(2, 'Create 2-node cluster');
cross_wire(2, ['n1', 'n2'], 'Bidirectional mesh between n1 and n2');

my $config     = get_test_config();
my $node_ports = $config->{node_ports};
my $dbname     = $config->{db_name};
my $pg_bin     = $config->{pg_bin};

# Run SQL and return its exit status and combined output, warnings included.
sub psql_capture_err {
    my ($node_num, $sql) = @_;
    my $port = $node_ports->[$node_num - 1];
    my $out = `"$pg_bin/psql" -X -p $port -d $dbname -t -c "$sql" 2>&1`;
    return ($? >> 8, $out);
}

# Update a node's own row without broadcasting it, so that its subscribers'
# cached copies stay stale.
sub update_own_node_quiet {
    my ($node_num, $set_clause) = @_;

    psql_or_bail($node_num,
        "BEGIN; SET LOCAL session_replication_role = replica; " .
        "UPDATE spock.node SET $set_clause " .
        "WHERE node_id = (SELECT node_id FROM spock.node_info()); COMMIT");
}

# Resync can only start once the previous synchronization of the table has
# finished.
sub resync_when_ready {
    my ($sql) = @_;
    my ($rc, $out);

    for (1 .. 30) {
        ($rc, $out) = psql_capture_err(1, $sql);
        last if $rc == 0;
        sleep(1);
    }
    return ($rc, $out);
}

psql_or_bail(1, "CREATE TABLE resync_tbl (id int PRIMARY KEY, val text)");
for (1 .. 30) {
    last if scalar_query(2, "SELECT count(*) FROM pg_tables " .
                            "WHERE tablename = 'resync_tbl'") eq '1';
    sleep(1);
}
is(scalar_query(2, "SELECT count(*) FROM pg_tables " .
                   "WHERE tablename = 'resync_tbl'"),
   '1', "resync_tbl DDL-replicated to n2");

# =============================================================================
# TEST 1: no warning while the cached row matches the provider's
# =============================================================================
my ($rc, $out) = resync_when_ready(
    "SELECT spock.sub_resync_table('sub_n1_n2', 'resync_tbl', false)");
is($rc, 0, "resync with an up-to-date cached provider row succeeds");
unlike($out, qr/differs from the provider/,
       "no warning when the cached provider row is current");

# =============================================================================
# TEST 2: warning when the provider's row changed and n1 missed the update
# =============================================================================
update_own_node_quiet(2, "location = 'loc-n2-resync'");
isnt(scalar_query(1, "SELECT location FROM spock.node WHERE node_name = 'n2'"),
     'loc-n2-resync', "n1's cached location for n2 is stale");

($rc, $out) = resync_when_ready(
    "SELECT spock.sub_resync_table('sub_n1_n2', 'resync_tbl', false)");
is($rc, 0, "resync still succeeds when the cached provider row is stale");
like($out, qr/cached metadata of node "n2" differs from the provider's/,
     "resync warns about the stale cached provider row");
like($out, qr/spock\.node_refresh_info\('n2'\)/,
     "the warning points to node_refresh_info()");

# =============================================================================
# TEST 3: no warning once the cached row has been refreshed
# =============================================================================
is(scalar_query(1, "SELECT spock.node_refresh_info('n2')"), 't',
   "node_refresh_info('n2') succeeds");

($rc, $out) = resync_when_ready(
    "SELECT spock.sub_resync_table('sub_n1_n2', 'resync_tbl', false)");
is($rc, 0, "resync after refresh succeeds");
unlike($out, qr/differs from the provider/,
       "no warning after the cached provider row was refreshed");

destroy_cluster('Destroy 2-node cluster');

done_testing();
