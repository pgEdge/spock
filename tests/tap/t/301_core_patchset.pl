use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster scalar_query get_test_config);

# =============================================================================
# Test: 301_core_patchset.pl - Core patch-set generation handshake
# =============================================================================
# Verifies that spock reports the core patch-set generation correctly via
# spock.core_patchset(), on both patched and unpatched servers.
#
# What to expect is decided without asking spock: the postgres binary's
# dynamic symbol table either exports SpockCorePatchsetVersion (patched) or
# it does not (unpatched, or a patch set that predates the marker).
#   - patched:   spock reports SPOCK_CORE_PATCHSET_TARGET from include/spock.h
#   - unpatched: spock still loads and reports 0
# =============================================================================

# Read the generation this build targets, so the test follows a bump.
my $header = '../../include/spock.h';
open(my $hf, '<', $header) or BAIL_OUT("cannot open $header: $!");
my ($target) = map { /^#define\s+SPOCK_CORE_PATCHSET_TARGET\s+(\d+)/ ? $1 : () } <$hf>;
close($hf);
BAIL_OUT("SPOCK_CORE_PATCHSET_TARGET not found in $header") unless defined $target;

# Look for the marker symbol in the server binary.
my $postgres = get_test_config()->{pg_bin} . '/postgres';
my $nm_cmd = $^O eq 'darwin' ? "nm -gU '$postgres'" : "nm -D --defined-only '$postgres'";
my $symbols = `$nm_cmd 2>/dev/null`;
BAIL_OUT("'$nm_cmd' failed; cannot tell whether the server is patched") if $? != 0;
my $patched = $symbols =~ /\b_?SpockCorePatchsetVersion\b/;
my $expected = $patched ? $target : 0;

note($patched ? "server exports SpockCorePatchsetVersion; expecting $target"
              : "server does not export SpockCorePatchsetVersion; expecting 0");

# A server without the marker may just have patches older than it, so the
# test alone cannot tell that from the 000 patch having gone missing.  CI jobs
# that build PostgreSQL with this tree's patches set SPOCK_EXPECT_CORE_PATCHSET,
# so a missing patch fails here instead of passing as an older patch set; a
# stale one fails the generation check below.
if ($ENV{SPOCK_EXPECT_CORE_PATCHSET})
{
    ok($patched, 'server exports SpockCorePatchsetVersion, as '
       . 'SPOCK_EXPECT_CORE_PATCHSET requires');
}

# The per-test log is appended to across runs, so only look at what this run
# writes.
my $log_file = get_test_config()->{log_file};
my $log_offset = (-s $log_file) // 0;

create_cluster(1, 'Create 1-node cluster for core patch-set handshake test');

my $patchset = scalar_query(1, "SELECT spock.core_patchset()");
is($patchset, $expected, "spock.core_patchset() reports $expected");

# _PG_init logs which case it took at postmaster start.  That is before the
# logging collector starts, so the line goes to the postmaster's stderr,
# which create_cluster sends to the per-test log, not to the node's log.
open(my $lf, '<', $log_file) or die "cannot open $log_file: $!";
seek($lf, $log_offset, 0) or die "cannot seek to $log_offset in $log_file: $!";
my $log = do { local $/; <$lf> } // '';
close($lf);
if ($patched)
{
    like($log, qr/core patch set generation $target detected/,
         'startup log reports the detected generation');
}
else
{
    like($log, qr/SpockCorePatchsetVersion not found/,
         'startup log reports the baseline (generation 0)');
}

destroy_cluster();

done_testing();
