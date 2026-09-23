#!/usr/bin/perl
# =============================================================================
# Test: 107_node_refresh_info.pl - coverage for spock.node_refresh_info() and
#                                   its internal helper spock.node_refresh_info_one()
# =============================================================================
# spock.node is a local catalog: each node populates its row for a peer once,
# from whatever the peer reported at sub_create() time, and never refreshes
# it afterward. If a peer's location/country/info (including a "tiebreaker"
# key inside info) changes later, every other node keeps using its stale
# cached copy until spock.node_refresh_info() is called explicitly. This
# test exercises that function end to end:
#
#   - single-peer refresh actually picks up a changed value
#   - bulk (no-argument) refresh updates every peer in one call
#   - a peer with an alternate (non-default-named) interface is still found,
#     via the fallback lookup, once its default-named interface is dropped
#   - a bulk refresh with one peer failing still updates the others and
#     returns false overall, without leaking that peer's failure into the
#     others' results
#   - a peer with no usable interface at all is reported, not silently
#     skipped, in both the single-node (raises) and bulk (warns) forms
#
# Fresh-install and upgrade-script availability: create_cluster() already
# exercises the fresh-install path (sql/spock--6.0.0.sql) for every node in
# this test. The full old-version-build-and-upgrade path is covered
# separately and much more expensively by 018_upgrade_schema_match.pl
# (excluded from the default schedule). What this test adds cheaply instead
# is a static check, below, that spock--6.0.0.sql and
# spock--5.0.11--6.0.0.sql declare the exact same signatures for both
# functions -- the two scripts drifting out of sync is a real mistake this
# feature's review already caught once.
# =============================================================================

use strict;
use warnings;
use Test::More;
use Cwd qw(getcwd);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster scalar_query
                 get_test_config psql_or_bail wait_for_sub_status);

# =============================================================================
# STATIC CHECK: fresh-install and upgrade scripts declare matching signatures
# for both functions. Does not need a running cluster.
# =============================================================================
{
    # Same repo-root detection as 018_upgrade_schema_match.pl: check_prove
    # runs this file from tests/tap, not the repo root.
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
        open(my $fh, '<', "$spock_repo/sql/spock--5.0.11--6.0.0.sql")
            or die "cannot open $spock_repo/sql/spock--5.0.11--6.0.0.sql: $!";
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

# =============================================================================
# SETUP: 3-node cluster, full mesh (cross_wire's default), so n1's catalog
# holds real, working node/interface rows for n2 and n3 obtained the normal
# way (via sub_create()'s discovery), not fabricated.
# =============================================================================
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

# Runs $sql on node $node_num and returns (exit_code, combined stdout+stderr)
# -- unlike SpockTest's scalar_query()/psql_or_bail(), this does not die on
# failure and does not discard stderr, since several scenarios below expect
# an ERROR and need to inspect its text.
sub psql_capture_err {
    my ($node_num, $sql) = @_;
    my $port = $node_ports->[$node_num - 1];
    my $out = `"$pg_bin/psql" -X -p $port -d $dbname -t -c "$sql" 2>&1`;
    my $rc = $? >> 8;
    return ($rc, $out);
}

# Same as psql_capture_err(), but with the connection's client_min_messages
# raised to error via PGOPTIONS, so a RAISE WARNING from within the called
# function is not sent to the client at all. Used where a test only wants
# the query result itself, not the warning text (checked separately, via
# plain psql_capture_err(), by another call).  A "SET client_min_messages
# ...; SELECT ..." string in one -c would still print the SET command's own
# completion tag ahead of the value, so this uses a startup option instead.
sub psql_capture_quiet {
    my ($node_num, $sql) = @_;
    my $port = $node_ports->[$node_num - 1];
    my $out = `PGOPTIONS='-c client_min_messages=error' "$pg_bin/psql" -X -p $port -d $dbname -t -c "$sql" 2>&1`;
    my $rc = $? >> 8;
    return ($rc, $out);
}

# All leading/trailing whitespace stripped, for comparing a single-value
# result exactly (psql -t pads/newlines the raw text captured above).
sub trimmed {
    my ($s) = @_;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# =============================================================================
# TEST 1: single-peer refresh picks up a changed value
# =============================================================================
psql_or_bail(2,
    "UPDATE spock.node SET location = 'loc-n2-v1', country = 'AA', " .
    "info = '{\"tiebreaker\": 101}'::jsonb " .
    "WHERE node_id = (SELECT node_id FROM spock.node_info())");

my $before = scalar_query(1, "SELECT location FROM spock.node WHERE node_name = 'n2'");
isnt($before, 'loc-n2-v1',
     "n1's cached location for n2 is still stale before any refresh");

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
psql_or_bail(3,
    "UPDATE spock.node SET location = 'loc-n3-v1', country = 'BB', " .
    "info = '{\"tiebreaker\": 202}'::jsonb " .
    "WHERE node_id = (SELECT node_id FROM spock.node_info())");
psql_or_bail(2,
    "UPDATE spock.node SET location = 'loc-n2-v2' " .
    "WHERE node_id = (SELECT node_id FROM spock.node_info())");

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

psql_or_bail(2,
    "UPDATE spock.node SET location = 'loc-n2-v3' " .
    "WHERE node_id = (SELECT node_id FROM spock.node_info())");

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

psql_or_bail(2,
    "UPDATE spock.node SET location = 'loc-n2-v4' " .
    "WHERE node_id = (SELECT node_id FROM spock.node_info())");

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
