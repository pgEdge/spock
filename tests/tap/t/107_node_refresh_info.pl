#!/usr/bin/perl
# Test single-node and bulk node_refresh_info(), including interface fallback
# and partial failure. Direct peers may already be current via propagation.

use strict;
use warnings;
use Test::More;
use Cwd qw(getcwd);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster scalar_query
                 get_test_config psql_or_bail wait_for_sub_status);

# Fresh-install and upgrade scripts must expose matching signatures.
{
    # check_prove runs from tests/tap rather than the repository root.
    my $cwd = getcwd();
    my $spock_repo = ($cwd =~ m{^(/.+)/tests/tap(?:/t)?$}) ? $1 : $cwd;

    my $fresh_sql = do {
        local $/;
        open(my $fh, '<', "$spock_repo/sql/spock--6.0.0.sql")
            or die "cannot open $spock_repo/sql/spock--6.0.0.sql: $!";
        <$fh>;
    };
    my $upgrade_sql = do {
        local $/;
        open(my $fh, '<', "$spock_repo/sql/spock--5.0.12--6.0.0.sql")
            or die "cannot open $spock_repo/sql/spock--5.0.12--6.0.0.sql: $!";
        <$fh>;
    };

    for my $sig (
        'CREATE FUNCTION spock\.node_refresh_info_one\(node_id oid, node_name name, dsn text,\s*'
            . 'OUT location text, OUT country text, OUT info jsonb\)',
        'CREATE FUNCTION spock\.node_refresh_info\(p_node_name name DEFAULT NULL\)',
    ) {
        my ($fresh_matches) = ($fresh_sql =~ /($sig)/s);
        my ($upgrade_matches) = ($upgrade_sql =~ /($sig)/s);
        ok(defined $fresh_matches, "fresh-install script declares: $sig");
        ok(defined $upgrade_matches, "upgrade script declares: $sig");
        is($upgrade_matches, $fresh_matches,
           "fresh-install and upgrade scripts agree on signature: $sig");
    }
}

# Build a full mesh with discovered node and interface rows.
create_cluster(3, 'Create 3-node cluster');
cross_wire(3, ['n1', 'n2', 'n3'], 'Full mesh among n1, n2, and n3');

my $config     = get_test_config();
my $node_ports = $config->{node_ports};
my $dbname     = $config->{db_name};
my $pg_bin     = $config->{pg_bin};
my $host       = $config->{host};
my $db_user    = $config->{db_user};
my $db_password = $config->{db_password};

sub dsn_for {
    my ($node_num) = @_;
    return "host=$host dbname=$dbname port=$node_ports->[$node_num - 1] " .
           "user=$db_user password=$db_password";
}

# Run SQL and capture expected failures without discarding stderr.
sub psql_capture_err {
    my ($node_num, $sql) = @_;
    my $port = $node_ports->[$node_num - 1];
    my $out = `"$pg_bin/psql" -X -p $port -d $dbname -t -c "$sql" 2>&1`;
    my $rc = $? >> 8;
    return ($rc, $out);
}

# Suppress warnings when only the query result is under test.
sub psql_capture_quiet {
    my ($node_num, $sql) = @_;
    my $port = $node_ports->[$node_num - 1];
    my $out = `PGOPTIONS='-c client_min_messages=error' "$pg_bin/psql" -X -p $port -d $dbname -t -c "$sql" 2>&1`;
    my $rc = $? >> 8;
    return ($rc, $out);
}

# Normalize psql's padded scalar output.
sub trimmed {
    my ($s) = @_;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}


# Update a node's own spock.node row without broadcasting it. Direct
# subscribers would otherwise refresh their cached copy on their own, and the
# refresh assertions below could not tell whether node_refresh_info() did it.
sub update_own_node_quiet {
    my ($node_num, $set_clause) = @_;

    # session_replication_role = replica keeps the broadcast trigger from
    # firing without DDL against the spock schema.
    psql_or_bail($node_num,
        "BEGIN; SET LOCAL session_replication_role = replica; " .
        "UPDATE spock.node SET $set_clause " .
        "WHERE node_id = (SELECT node_id FROM spock.node_info()); COMMIT");
}

# Cached column of a peer's row on a given node.
sub cached {
    my ($node_num, $peer, $col) = @_;
    return scalar_query($node_num,
        "SELECT $col FROM spock.node WHERE node_name = '$peer'");
}

# =============================================================================
# TEST 1: single-peer refresh picks up a changed value
# =============================================================================
update_own_node_quiet(2,
    "location = 'loc-n2-v1', country = 'AA', " .
    "info = '{\"tiebreaker\": 101}'::jsonb");

isnt(cached(1, 'n2', 'location'), 'loc-n2-v1',
     "n1's cached location for n2 is stale before the single-peer refresh");

my $refreshed = scalar_query(1, "SELECT spock.node_refresh_info('n2')");
is($refreshed, 't', "single-peer refresh of n2 returns true");

is(scalar_query(1, "SELECT location FROM spock.node WHERE node_name = 'n2'"),
   'loc-n2-v1', "n1's cached location for n2 was updated by single-peer refresh");
is(scalar_query(1, "SELECT country FROM spock.node WHERE node_name = 'n2'"),
   'AA', "n1's cached country for n2 was updated by single-peer refresh");
is(scalar_query(1, "SELECT info->>'tiebreaker' FROM spock.node WHERE node_name = 'n2'"),
   '101', "n1's cached tiebreaker for n2 was updated by single-peer refresh");

# =============================================================================
# TEST 2: bulk (no-argument) refresh updates every peer in one call
# =============================================================================
update_own_node_quiet(3,
    "location = 'loc-n3-v1', country = 'BB', " .
    "info = '{\"tiebreaker\": 202}'::jsonb");
update_own_node_quiet(2, "location = 'loc-n2-v2'");

isnt(cached(1, 'n3', 'location'), 'loc-n3-v1',
     "n1's cached location for n3 is stale before the bulk refresh");
isnt(cached(1, 'n2', 'location'), 'loc-n2-v2',
     "n1's cached location for n2 is stale before the bulk refresh");

my $bulk_ok = scalar_query(1, "SELECT spock.node_refresh_info()");
is($bulk_ok, 't', "bulk refresh (no argument) returns true when every peer is reachable");

is(scalar_query(1, "SELECT location FROM spock.node WHERE node_name = 'n3'"),
   'loc-n3-v1', "bulk refresh updated n1's cached location for n3");
is(scalar_query(1, "SELECT location FROM spock.node WHERE node_name = 'n2'"),
   'loc-n2-v2', "bulk refresh also updated n1's cached location for n2 in the same call");

# =============================================================================
# TEST 3: alternate-interface fallback -- once the default-named interface
# for a peer is dropped (legally, after its subscription switched away from
# it), refresh still finds the peer via whatever interface remains.
# =============================================================================
psql_or_bail(1, "SELECT spock.node_add_interface('n2', 'n2_alt', '" . dsn_for(2) . "')");
psql_or_bail(1, "SELECT spock.sub_alter_interface('sub_n1_n2', 'n2_alt')");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating', 30),
   "sub_n1_n2 returns to replicating after switching to the alternate interface");
psql_or_bail(1, "SELECT spock.node_drop_interface('n2', 'n2')");

update_own_node_quiet(2, "location = 'loc-n2-v3'");

isnt(cached(1, 'n2', 'location'), 'loc-n2-v3',
     "n1's cached location for n2 is stale before the fallback-interface refresh");

my $fallback_ok = scalar_query(1, "SELECT spock.node_refresh_info('n2')");
is($fallback_ok, 't',
   "single-peer refresh of n2 still succeeds with only the alternate interface left");
is(scalar_query(1, "SELECT location FROM spock.node WHERE node_name = 'n2'"),
   'loc-n2-v3',
   "refresh via the fallback interface picked up n2's latest value");

# =============================================================================
# TEST 4: partial bulk failure -- one peer unreachable, the others still
# succeed, and the overall call returns false.
#
# Repoint n3's interface at an address nothing is listening on, so the
# failure is a plain connection failure.
# =============================================================================
psql_or_bail(1,
    "SELECT spock.node_add_interface('n3', 'n3_unreachable', " .
    "'host=127.0.0.1 port=1 dbname=nope')");
psql_or_bail(1, "SELECT spock.sub_alter_interface('sub_n1_n3', 'n3_unreachable')");
psql_or_bail(1, "SELECT spock.node_drop_interface('n3', 'n3')");

update_own_node_quiet(2, "location = 'loc-n2-v4'");

isnt(cached(1, 'n2', 'location'), 'loc-n2-v4',
     "n1's cached location for n2 is stale before the partial bulk refresh");

# psql_capture_quiet() keeps the RAISE WARNING out of this call's captured
# output, so the value check below sees only the boolean result; the
# separate plain call after it is what the warning-text check inspects.
my ($bulk_rc, $bulk_value) = psql_capture_quiet(1, "SELECT spock.node_refresh_info()");
is($bulk_rc, 0, "bulk refresh with one unreachable peer still exits successfully");
is(trimmed($bulk_value), 'f',
   "bulk refresh returns false overall when one peer (n3) cannot be reached");
like(scalar_query(1, "SELECT location FROM spock.node WHERE node_name = 'n2'"),
     qr/^loc-n2-v4$/,
     "the reachable peer (n2) is still updated despite n3's failure in the same bulk call");

my (undef, $warn_out) = psql_capture_err(1, "SELECT spock.node_refresh_info()");
like($warn_out, qr/could not refresh info for node "n3"/,
     "the bulk call warns about the specific peer that failed");

# =============================================================================
# TEST 5: a peer with no usable interface at all is reported, not silently
# skipped -- raises for the single-node call, warns (and still returns
# false) for the bulk call.
#
# Reaching this state for a real peer through the exposed SQL functions
# alone is not possible: node_interface.if_id is referenced by a plain
# foreign key from subscription.sub_origin_if with no cascade, so it can't
# be deleted out from under a live subscription; node_drop_interface()
# enforces the same thing at the API level; and dropping that subscription
# instead cascades to remove the peer's node row (and its interfaces)
# entirely once no other subscription references it
# (spock_drop_subscription(), spock_functions.c). A node row surviving
# with zero interfaces can therefore only happen from something that
# bypasses the API entirely -- a manual catalog repair, or corruption --
# which is exactly what the plpgsql function's explicit NULL-interface
# check defends against. Model that directly with a bare row insert
# instead of disturbing the real (still in use) n2/n3 catalog entries.
# =============================================================================
psql_or_bail(1, "INSERT INTO spock.node (node_id, node_name) VALUES (999999, 'n_no_iface')");

my ($no_if_rc, $no_if_out) = psql_capture_err(1, "SELECT spock.node_refresh_info('n_no_iface')");
isnt($no_if_rc, 0, "single-peer refresh of a node with no interface fails");
like($no_if_out, qr/has no usable interface/,
     "the failure names the missing-interface condition");

my ($bulk_no_if_rc, $bulk_no_if_value) = psql_capture_quiet(1, "SELECT spock.node_refresh_info()");
is($bulk_no_if_rc, 0, "bulk refresh with a no-interface peer still exits successfully");
is(trimmed($bulk_no_if_value), 'f',
   "bulk refresh returns false overall when one peer has no usable interface");

my (undef, $bulk_no_if_warn) = psql_capture_err(1, "SELECT spock.node_refresh_info()");
like($bulk_no_if_warn, qr/could not refresh info for node "n_no_iface"/,
     "the bulk call warns about the specific peer with no usable interface");

# =============================================================================
# CLEANUP
# =============================================================================
destroy_cluster('Destroy 3-node cluster');

done_testing();
