use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster scalar_query);

# =============================================================================
# Test: 106_core_patchset.pl - Core patch-set generation handshake
# =============================================================================
# Verifies that a patched PostgreSQL server exposes a patch-set generation and
# that spock detects and reports it via spock.core_patchset(). This is the
# positive path: a correctly patched build starts and reports a non-zero
# generation matching what this spock build requires.
# =============================================================================

create_cluster(1, 'Create 1-node cluster for core patch-set handshake test');

# The recorded generation must be non-zero (server is patched and spock
# detected the symbol). Update the expected value when the generation bumps.
my $patchset = scalar_query(1, "SELECT spock.core_patchset()");
ok($patchset > 0, "core patch set generation is detected (non-zero), got $patchset");
is($patchset, 1, "core patch set generation matches SPOCK_CORE_PATCHSET_TARGET (1)");

destroy_cluster();

done_testing();
