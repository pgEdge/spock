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
#   - unpatched: spock still starts, reports 0, and warns that it is running
#                without the core patches
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
    like($log, qr/spock is running without the Spock core patches/,
         'startup log warns that spock runs without the core patches');
}

# The publisher refuses a subscriber whose core-patch state differs from its
# own.  Fake subscribers by passing startup options to spock_output through
# the SQL decoding interface: one that states the opposite state, and one
# that sends spock_version_num without core_patches, like a subscriber that
# predates the key (and so was patched).
my $cfg = get_test_config();
my $port = $cfg->{node_ports}->[0];
my $db = $cfg->{db_name};
my $pg_bin = $cfg->{pg_bin};
scalar_query(1, "SELECT pg_create_logical_replication_slot('core_patch_check', 'spock_output')");

sub peek_with
{
    my ($extra) = @_;
    my $q = "SELECT count(*) FROM pg_logical_slot_peek_changes('core_patch_check', " .
            "NULL, NULL, 'min_proto_version', '4', 'max_proto_version', '5', " .
            "'startup_params_format', '1', 'proto_format', 'json', " .
            "'spock.replication_set_names', 'default'$extra)";
    my $out = `"$pg_bin/psql" -X -p $port -d $db -c "$q" 2>&1`;
    return ($? == 0, $out);
}

my $own = $patched ? 'true' : 'false';
my $other = $patched ? 'false' : 'true';
my $refusal = qr/cannot replicate between servers with and without the Spock core patches/;

my ($ok, $out) = peek_with(", 'core_patches', '$own'");
ok($ok, "publisher accepts a subscriber with the same core-patch state") or diag($out);

($ok, $out) = peek_with(", 'core_patches', '$other'");
ok(!$ok, 'publisher refuses a subscriber with a different core-patch state');
like($out, $refusal, 'refusal names the core-patch mismatch');

($ok, $out) = peek_with(", 'spock_version_num', '50012'");
if ($patched)
{
    ok($ok, 'patched publisher accepts a subscriber that predates the key') or diag($out);
}
else
{
    ok(!$ok, 'unpatched publisher refuses a subscriber that predates the key');
    like($out, $refusal, 'refusal names the core-patch mismatch');
}

($ok, $out) = peek_with('');
ok($ok, 'publisher does not check a client that is not a spock subscriber') or diag($out);

scalar_query(1, "SELECT pg_drop_replication_slot('core_patch_check')");

destroy_cluster();

done_testing();
