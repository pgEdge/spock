#!/usr/bin/perl
# =============================================================================
# Test: 047_bidir_plumbing.pl — spock_create_subscriber --bidirectional (PR2)
# =============================================================================
# Validates the PR2 plumbing phase of the SPOC-601 bidirectional node-join
# procedure.  The test does NOT start a third PostgreSQL instance; it only
# exercises the utility's plumbing phase against an existing 2-node cluster:
#
#   --bidirectional   discover peers, check preconditions, write manifest
#   --cleanup         idempotently remove partial state / manifest
#
# Topology:
#   n1 <-> n2   (full bidirectional Spock subscriptions, track_commit_timestamp=on)
#
# The utility is run with --pgdata pointing at a plain temp directory (no PG
# cluster) that exists solely to hold the manifest file.
#
# Test count breakdown:
#   1  binary found
#   1  temp pgdata created
#   5  create_cluster(2)  [2 pg_isready + 2 spock checks + 1 pass]
#   1  cross_wire n1<->n2
#   1  --bidirectional exits 0
#   1  manifest file written
#   1  manifest: version 1
#   1  manifest: subscriber_name n3
#   1  manifest: dbname regression
#   1  manifest: source_dsn present
#   1  manifest: peer n2 listed
#   1  manifest: peer_slot_name present
#   1  --cleanup exits 0
#   1  manifest removed
#   1  --cleanup with no manifest exits 0 (idempotent)
#   1  destroy_cluster
#  ---
#  20  total
# =============================================================================

use strict;
use warnings;
use Test::More tests => 20;
use File::Path qw(remove_tree make_path);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 command_ok system_maybe get_test_config scalar_query psql_or_bail);

# =============================================================================
# Locate spock_create_subscriber binary
# =============================================================================
my $SCS_BIN;
for my $dir (split(':', $ENV{PATH} // '')) {
    my $c = "$dir/spock_create_subscriber";
    if (-x $c) { $SCS_BIN = $c; last; }
}
unless (defined $SCS_BIN) {
    # Fall back to the build tree (CWD is tests/tap/ during make check_prove)
    my $bt = '../../utils/spock_create_subscriber/spock_create_subscriber';
    $SCS_BIN = $bt if -x $bt;
}
BAIL_OUT("spock_create_subscriber binary not found; run 'make install' first")
    unless defined $SCS_BIN;
pass("spock_create_subscriber binary found");

# =============================================================================
# Scratch directory that stands in for n3's future PGDATA.
# It just needs to exist so the manifest can be written there.
# =============================================================================
my $N3_PGDATA = '/tmp/spock_bidir_test_n3_pgdata';
my $MANIFEST  = "$N3_PGDATA/spock_bidirectional_manifest.json";

remove_tree($N3_PGDATA) if -d $N3_PGDATA;
make_path($N3_PGDATA)
    or BAIL_OUT("could not create temp pgdata dir: $N3_PGDATA");
pass("temp pgdata dir for n3 created");

# =============================================================================
# SETUP: 2-node cluster, cross-wired bidirectionally
# create_cluster counts as 5 tests (pg_isready + spock check per node + pass)
# =============================================================================
create_cluster(2, 'Create bidirectional 2-node cluster');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $dbname      = $config->{db_name};
my $host        = $config->{host};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};

my $n1_dsn = "host=$host port=$node_ports->[0] dbname=$dbname"
           . " user=$db_user password=$db_password";

# Create bidirectional subscriptions n1->n2 and n2->n1 (1 test)
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 <-> n2 bidirectionally');

# =============================================================================
# TEST: --bidirectional mode
# Discovers peer n2 from n1, checks preconditions, writes manifest.
# =============================================================================

command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--pgdata',          $N3_PGDATA,
      '--subscriber-name', 'n3',
      '--provider-dsn',    $n1_dsn,
    ],
    '--bidirectional plumbing exits 0'
);

ok(-f $MANIFEST,
    'manifest written to <pgdata>/spock_bidirectional_manifest.json');

# Read and inspect manifest content
my $manifest_content = '';
if (-f $MANIFEST) {
    open my $fh, '<', $MANIFEST or die "Cannot read manifest: $!";
    local $/;
    $manifest_content = <$fh>;
    close $fh;
}

like($manifest_content, qr/"version":\s*1/,
     'manifest: version is 1');
like($manifest_content, qr/"subscriber_name":\s*"n3"/,
     'manifest: subscriber_name is n3');
like($manifest_content, qr/"dbname":\s*"$dbname"/,
     'manifest: dbname matches provider dbname');
ok(index($manifest_content, '"source_dsn":') >= 0,
     'manifest: source_dsn field present');
like($manifest_content, qr/"node_name":\s*"n2"/,
     'manifest: peer n2 is listed in peers array');
ok(index($manifest_content, '"peer_slot_name":') >= 0,
     'manifest: peer_slot_name field present');

# =============================================================================
# TEST: --cleanup mode — removes manifest, exits 0
# =============================================================================

command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--cleanup',
      '--pgdata', $N3_PGDATA,
    ],
    '--cleanup with manifest exits 0'
);

ok(!-f $MANIFEST,
    'manifest file removed by --cleanup');

# Second cleanup with no manifest must also exit 0 (idempotent)
command_ok(
    [ $SCS_BIN,
      '--bidirectional',
      '--cleanup',
      '--pgdata', $N3_PGDATA,
    ],
    '--cleanup with no manifest exits 0 (idempotent)'
);

# =============================================================================
# CLEANUP
# =============================================================================
remove_tree($N3_PGDATA);
destroy_cluster('Cleanup');
