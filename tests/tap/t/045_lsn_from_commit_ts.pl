#!/usr/bin/perl
#
# =============================================================================
# Test: 045_lsn_from_commit_ts.pl - spock.get_lsn_from_commit_ts() on idle node
# =============================================================================
# The scan behind spock.get_lsn_from_commit_ts() reads WAL
# through the waiting page_read callback, which never reports end of WAL - it
# sleeps until somebody appends more.  Without a bound of its own the scan
# therefore hangs on a node where nothing is happening, and the Control Plane
# add-node workflow stalls behind it.
#
# A single node with no subscriptions is used deliberately: no apply workers,
# so once the setup settles nobody writes WAL and the pathological case is
# reproduced exactly.  A regression makes these calls hang until
# statement_timeout fires rather than fail outright, so every call is bounded
# server-side by $SERVER_TIMEOUT and then checked two ways here: it must have
# succeeded (a cancelled statement leaves an error behind) and it must have
# taken less than $SLOW_THRESHOLD.  Note the threshold has to sit well below
# the server timeout - above it, a regressed run cancelled at $SERVER_TIMEOUT
# would still count as fast enough and the check would pass on broken code.
#
# Also checks that a commit made before the requested timestamp is found and
# reported at or past its own LSN, and that an unanswerable question - one
# about a time before the slot existed - comes back as the slot's restart_lsn.
# =============================================================================

use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time);
use lib '.';
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail scalar_query);

my $SERVER_TIMEOUT = 30;	# statement_timeout for each call
my $SLOW_THRESHOLD = 5;		# a call slower than this is treated as hung

# Single node, no subscriptions - nothing to generate WAL in the background.
create_cluster(1, 'Create 1-node cluster for commit timestamp scan');

# Any logical slot will do: the scan reads raw WAL and never decodes it.  Use
# test_decoding rather than spock_output - it is in the default
# output_plugin_libraries, so the slot can be created on servers carrying the
# security fix that restricts that list.
psql_or_bail(1, "SELECT pg_create_logical_replication_slot('cts_probe', 'test_decoding')");

# One local commit for the scan to find.  It has to write WAL of its own: a
# transaction that merely takes an xid does not flush its commit record on the
# way out, and the scan stops at the flush position.  The message prefix is not
# spock's, so nothing decodes it.
my $probe_lsn = scalar_query(1, "SELECT pg_logical_emit_message(true, 'cts_test', 'probe')");
like($probe_lsn, qr{^[0-9A-Fa-f]+/[0-9A-Fa-f]+$}, "probe commit written at $probe_lsn");

# scalar_query() strips whitespace, so ask for the ISO 8601 'T' form of the
# timestamp - what comes back has to remain a valid timestamptz literal.  Spell
# the format out rather than relying on now()::text, whose layout follows
# DateStyle.  The separator is concatenated instead of quoted inside the
# to_char pattern, because that needs double quotes and the query travels
# through a double-quoted shell argument.  now() is stable within the
# statement, so both halves see the same instant.
my $after_commit = scalar_query(1,
	"SELECT to_char(now(), 'YYYY-MM-DD') || 'T' || to_char(now(), 'HH24:MI:SS.USOF')");
like($after_commit, qr{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}},
	'captured a commit timestamp to search for');

# Let the node fall silent.  From here on nothing appends WAL, so a scan
# without a bound of its own has nothing to wake it up.
sleep(5);

# Run a query with a server-side timeout and measure how long it took.  The
# timeout goes through PGOPTIONS rather than a SET statement so that psql does
# not print the extra command tag into the result we are about to parse.
# scalar_query() drops stderr, so a failing statement is indistinguishable
# from one returning the empty string.  Run psql directly instead, with stderr
# folded in and a server-side timeout so a regressed build cannot wedge the
# suite: without the timeout the scan waits for WAL this idle node will never
# write, and prove() waits with it.
my $config = get_test_config();
my $psql = "$config->{pg_bin}/psql";
my $port = $config->{node_ports}[0];
my $dbname = $config->{db_name};

sub query_output
{
	my ($sql) = @_;
	local $ENV{PGOPTIONS} = "-c statement_timeout=${SERVER_TIMEOUT}s";
	my $out = `$psql -X -p $port -d $dbname -t -c "$sql" 2>&1`;
	chomp($out);
	$out =~ s/^\s+|\s+$//g;
	return $out;
}

# Run a query that is expected to succeed, and fail the test if it either
# errored out or took long enough to look like the hang this file guards
# against.  Checking both matters: a hung call is cancelled by
# statement_timeout, which turns into an error rather than a slow success.
sub timed_query
{
	my ($sql, $what) = @_;
	my $started = time();
	my $result = query_output($sql);
	my $elapsed = time() - $started;

	unlike($result, qr/^ERROR:|^psql:/, "$what completed without error");
	cmp_ok($elapsed, '<', $SLOW_THRESHOLD,
		sprintf('%s returned in %.1fs (slow threshold %ds)',
			$what, $elapsed, $SLOW_THRESHOLD));

	return $result;
}

# The commit made above is not newer than $after_commit, so it is found.  This
# is the call that used to hang: it reaches the end of WAL and, before the fix,
# waited there for WAL that this idle node was never going to produce.  The
# answer is the end of the commit record, so it is at or past the message LSN.
my $found = timed_query(
	"SELECT coalesce((spock.get_lsn_from_commit_ts('cts_probe', '$after_commit') >= '$probe_lsn'::pg_lsn)::text, 'NULL')",
	'scan for a recent commit');
is($found, 'true', 'recent commit resolved to an LSN at or past the probe');

# Nothing was committed before the year 2000, and the scan cannot look behind
# the slot's restart_lsn anyway, so the question is unanswerable.  The answer
# is then restart_lsn itself, which a caller cannot tell from a real match -
# long-standing behaviour of this branch, asserted here so that a change to it
# is a deliberate one.
my $restart_lsn = scalar_query(1,
	"SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = 'cts_probe'");
like($restart_lsn, qr{^[0-9A-Fa-f]+/[0-9A-Fa-f]+$}, "probe slot sits at $restart_lsn");

my $unknown = timed_query(
	"SELECT coalesce((spock.get_lsn_from_commit_ts('cts_probe', '2000-01-01T00:00:00+00') = '$restart_lsn'::pg_lsn)::text, 'NULL')",
	'scan for an ancient commit');
is($unknown, 'true', 'unanswerable question falls back to the slot restart_lsn');

# The function is STRICT, so a NULL argument short-circuits to NULL.
my $null_arg = scalar_query(1,
	"SELECT coalesce(spock.get_lsn_from_commit_ts('cts_probe', NULL)::text, 'NULL')");
is($null_arg, 'NULL', 'NULL commit timestamp yields NULL');

# A physical slot has no database and must be refused, not scanned.
psql_or_bail(1, "SELECT pg_create_physical_replication_slot('cts_phys', true)");
my $phys_err = query_output("SELECT spock.get_lsn_from_commit_ts('cts_phys', now())");
like($phys_err, qr/not a logical replication slot/, 'physical slot is rejected');
psql_or_bail(1, "SELECT pg_drop_replication_slot('cts_phys')");

psql_or_bail(1, "SELECT pg_drop_replication_slot('cts_probe')");

destroy_cluster('Destroy the cluster');

done_testing();
