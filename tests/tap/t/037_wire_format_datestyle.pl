#!/usr/bin/perl
# =============================================================================
# Test: 037_wire_format_datestyle.pl - Peer sessions must use a canonical
#                                      value representation on the wire
# =============================================================================
# Spock moves values between nodes as TEXT in two places:
#
#   1. The native protocol falls back to text transfer whenever the binary
#      representation is unavailable -- when the two nodes disagree on major
#      version, or when the subscription sets force_text_transfer.  User column
#      values are then rendered by the walsender with OidOutputFunctionCall()
#      and parsed by the apply worker with OidInputFunctionCall().
#   2. spock.progress.remote_commit_ts is read from a peer over libpq during
#      subscription sync (adjust_progress_info(),
#      spock_create_slot_and_read_progress()) and parsed with
#      str_to_timestamptz().
#
# Nothing in either protocol negotiates the text format, so it follows whatever
# DateStyle / TimeZone each end happens to run with.  Under DateStyle 'SQL' or
# 'German' the date component is ordered by the sender's MDY/DMY setting and the
# zone appears as an abbreviation rather than a numeric offset.  A receiver with
# the opposite setting reads a DIFFERENT DAY, and raises nothing: 05/06/2025
# rendered MDY and read DMY is a silent 30-day error.
#
# spock_connect_base() therefore passes
#   -c datestyle=ISO -c intervalstyle=postgres -c extra_float_digits=3
# in the startup packet of every peer connection, mirroring what
# libpqrcv_connect() does for core logical replication. ISO is the only style
# that always emits an unambiguous date and an explicit numeric UTC offset. This
# test asserts that the pinning actually holds.
#
# Note TimeZone is deliberately NOT forced, and this test covers that decision:
# the nodes are left in different zones on purpose. Under ISO a timestamptz
# always carries its offset, so the receiver reconstructs the same instant
# whatever zone either end runs in.
#
# Setup: the two nodes are configured to disagree as sharply as possible.
#   n1 = provider   DateStyle 'SQL, MDY',  TimeZone 'Asia/Tokyo'
#   n2 = subscriber DateStyle 'SQL, DMY',  TimeZone 'UTC'
# The subscription uses force_text_transfer := true so the text path is taken
# deterministically, without needing two PostgreSQL major versions.
#
# The test data deliberately uses day-of-month <= 12 so that BOTH the MDY and
# the DMY reading are valid calendar dates.  That is what makes the failure
# silent rather than an error, and it is the case a test must cover: an
# out-of-range day would merely raise, which is easy to notice.
#
# Without the fix the replicated timestamps land on the wrong day. With it they
# match the source exactly.
# =============================================================================

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail
                 get_test_config scalar_query psql_or_bail
                 wait_for_sub_status wait_for_pg_ready);

# PGTZ/PGDATESTYLE in the environment would override the server settings for
# our own psql sessions and mask what we are trying to measure.
delete $ENV{PGTZ};
delete $ENV{PGDATESTYLE};

my $DS_PROVIDER = 'SQL, MDY';
my $TZ_PROVIDER = 'Asia/Tokyo';
my $DS_SUBSCRIBER = 'SQL, DMY';
my $TZ_SUBSCRIBER = 'UTC';

create_cluster(2, 'Create 2-node cluster');

my $config     = get_test_config();
my $node_ports = $config->{node_ports};
my $dbname     = $config->{db_name};
my $host       = $config->{host};
my $pg_bin     = $config->{pg_bin};

my $conn_n1 = "host=$host port=$node_ports->[0] dbname=$dbname";

# =============================================================================
# SETUP: make the two nodes disagree about DateStyle and TimeZone
# =============================================================================
# These must be server settings, not per-session ones: the sessions that do the
# rendering are the walsender on n1 and the apply worker on n2, neither of which
# we can reach with a SET.

psql_or_bail(1, "ALTER SYSTEM SET DateStyle = '$DS_PROVIDER'");
psql_or_bail(1, "ALTER SYSTEM SET TimeZone = '$TZ_PROVIDER'");
psql_or_bail(2, "ALTER SYSTEM SET DateStyle = '$DS_SUBSCRIBER'");
psql_or_bail(2, "ALTER SYSTEM SET TimeZone = '$TZ_SUBSCRIBER'");

for my $i (0, 1) {
    system_or_bail "$pg_bin/psql", '-X', '-p', $node_ports->[$i], '-d', $dbname,
        '-c', 'SELECT pg_reload_conf()';
}

ok(wait_for_pg_ready($host, $node_ports->[0], $pg_bin, 30), 'n1 ready after reload');
ok(wait_for_pg_ready($host, $node_ports->[1], $pg_bin, 30), 'n2 ready after reload');

# scalar_query strips whitespace, so compare against the squeezed spelling.
(my $ds_provider_squeezed   = $DS_PROVIDER)   =~ s/\s+//g;
(my $ds_subscriber_squeezed = $DS_SUBSCRIBER) =~ s/\s+//g;

is(scalar_query(1, 'SHOW DateStyle'), $ds_provider_squeezed,
   "n1 DateStyle is $DS_PROVIDER");
is(scalar_query(2, 'SHOW DateStyle'), $ds_subscriber_squeezed,
   "n2 DateStyle is $DS_SUBSCRIBER");
is(scalar_query(1, 'SHOW TimeZone'), $TZ_PROVIDER, "n1 TimeZone is $TZ_PROVIDER");
is(scalar_query(2, 'SHOW TimeZone'), $TZ_SUBSCRIBER, "n2 TimeZone is $TZ_SUBSCRIBER");

# =============================================================================
# NEGATIVE CONTROL: prove the hazard is live in this configuration
# =============================================================================
# Without this, a green run proves nothing: if the assertions further down passed
# because the two nodes happened to agree, or because the values never went
# through text at all, the test would be reporting success for the wrong reason.
#
# So first demonstrate that a date rendered on n1 and read back on n2 really does
# change meaning.  Only the date component is used, deliberately: it isolates
# DateStyle and needs no zone abbreviation to be resolvable on either node.

my $render_n1 = scalar_query(1, "SELECT '2025-05-06 10:30:45+00'::timestamptz::text");
my $render_n2 = scalar_query(2, "SELECT '2025-05-06 10:30:45+00'::timestamptz::text");
isnt($render_n1, $render_n2,
     "The nodes render the same instant differently (n1: $render_n1, n2: $render_n2)");

# n1 renders 6 May 2025 in its own DateStyle; 'SQL, MDY' gives "05/06/2025".
my $date_on_wire = scalar_query(1, "SELECT '2025-05-06'::date::text");
is($date_on_wire, '05/06/2025',
   "n1 renders 2025-05-06 as $date_on_wire");

# n2 reads that same text under 'SQL, DMY' and lands on 5 June: 30 days out, with
# no error, because both readings are real dates.
my $drift = scalar_query(2,
    "SELECT '$date_on_wire'::date - '2025-05-06'::date");
is($drift, '30',
   "n2 reads $date_on_wire as a date 30 days away -- the misinterpretation this "
   . "test exists to catch is reachable here");

# =============================================================================
# SETUP: a table covering every datetime type that goes through the text path
# =============================================================================

my $ddl = 'CREATE TABLE wire_fmt ('
        . 'id int primary key, '
        . 'ts timestamptz, '     # instant; the zone must survive
        . 'tsn timestamp, '      # wall clock; the date order must survive
        . 'd date, '             # date order only
        . 'iv interval, '        # IntervalStyle
        . 'f float8)';           # extra_float_digits

psql_or_bail(1, "SELECT spock.repset_create('wireset')");
psql_or_bail(2, "SELECT spock.repset_create('wireset')");
psql_or_bail(1, $ddl);
psql_or_bail(2, $ddl);
psql_or_bail(1, "SELECT spock.repset_add_table('wireset', 'wire_fmt')");
psql_or_bail(2, "SELECT spock.repset_add_table('wireset', 'wire_fmt')");
pass('Created replication set and test table on both nodes');

# force_text_transfer := true takes the text path deterministically, so the test
# does not need two PostgreSQL major versions to reach it.
psql_or_bail(2, "SELECT spock.sub_create(
    subscription_name     := 'sub_n2_n1',
    provider_dsn          := '$conn_n1',
    replication_sets      := ARRAY['wireset'],
    synchronize_structure := false,
    synchronize_data      := false,
    force_text_transfer   := true
)");
ok(wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 60),
   'Subscription n2->n1 is replicating with force_text_transfer');

# Confirm the flag was actually recorded, not silently dropped by sub_create().
# That matters more than it looks: the flag is what makes the text path certain.
# spock_start_replication() sends binary.want_internal_basetypes and
# binary.want_binary_basetypes as '0' when it is set, so the publisher leaves
# allow_internal_basetypes and allow_binary_basetypes at false, and
# decide_datum_transfer() has no branch left but 't'.  There is no negotiation
# that could quietly restore binary transfer behind our back, so if the flag is
# set, every value below travelled as text.
is(scalar_query(2,
       "SELECT sub_force_text_transfer FROM spock.subscription
        WHERE sub_name = 'sub_n2_n1'"),
   't',
   'force_text_transfer is recorded on the subscription, so transfer is text');

# =============================================================================
# Replicate values whose MDY and DMY readings are both valid dates
# =============================================================================
# Day <= 12 in every row, so a swapped date order produces another real date
# instead of an error.
#
# Mind the provider's zone when editing these.  A timestamptz is rendered in the
# provider's TimeZone, so the day-of-month that goes on the wire is the one in
# Asia/Tokyo, not in UTC.  An earlier revision used 2025-01-12 23:59:59+00 here,
# which is 2025-01-13 in Tokyo: the swapped reading became month 13, apply raised
# "date/time field value out of range", and the subscription disabled itself.  The
# test still failed without the fix, but for the wrong reason -- it stopped
# demonstrating the quiet misreading it is supposed to be about.  Every instant
# below is chosen so that its Tokyo date also has a day of month not above 12.

psql_or_bail(1, "INSERT INTO wire_fmt VALUES
    (1, '2025-05-06 10:30:45.123456+00', '2025-05-06 10:30:45.123456',
     '2025-05-06', '1 day 02:03:04', 1.2345678901234567),
    (2, '2025-01-11 23:59:59.999999+00', '2025-01-11 23:59:59.999999',
     '2025-01-11', '-3 days', 0.1),
    (3, '2025-11-02 01:30:00+00',        '2025-11-02 01:30:00',
     '2025-11-02', '00:00:01', -9.87654321e10)");

my $applied = 0;
for my $attempt (1 .. 60) {
    $applied = scalar_query(2, 'SELECT count(*) FROM wire_fmt');
    last if defined $applied && $applied eq '3';
    sleep 1;
}
is($applied, '3', 'All three rows reached n2 over the text path');

# =============================================================================
# ASSERTIONS: compare instants, not rendered strings
# =============================================================================
# Both sides are asked for epoch seconds, which carry no zone and no date order,
# so the comparison is immune to the very settings under test. Any surviving
# difference is a real difference in the stored value.

for my $id (1 .. 3) {
    my $src = scalar_query(1,
        "SELECT extract(epoch FROM ts)::numeric::text FROM wire_fmt WHERE id = $id");
    my $dst = scalar_query(2,
        "SELECT extract(epoch FROM ts)::numeric::text FROM wire_fmt WHERE id = $id");
    is($dst, $src, "row $id: timestamptz replicated as the same instant ($src)");

    my $src_n = scalar_query(1,
        "SELECT extract(epoch FROM tsn)::numeric::text FROM wire_fmt WHERE id = $id");
    my $dst_n = scalar_query(2,
        "SELECT extract(epoch FROM tsn)::numeric::text FROM wire_fmt WHERE id = $id");
    is($dst_n, $src_n, "row $id: timestamp replicated with the same date");

    my $src_d = scalar_query(1,
        "SELECT to_char(d, 'YYYY-MM-DD') FROM wire_fmt WHERE id = $id");
    my $dst_d = scalar_query(2,
        "SELECT to_char(d, 'YYYY-MM-DD') FROM wire_fmt WHERE id = $id");
    is($dst_d, $src_d, "row $id: date replicated unswapped ($src_d)");

    my $src_i = scalar_query(1,
        "SELECT extract(epoch FROM iv)::numeric::text FROM wire_fmt WHERE id = $id");
    my $dst_i = scalar_query(2,
        "SELECT extract(epoch FROM iv)::numeric::text FROM wire_fmt WHERE id = $id");
    is($dst_i, $src_i, "row $id: interval replicated intact");

    my $src_f = scalar_query(1, "SELECT f::text FROM wire_fmt WHERE id = $id");
    my $dst_f = scalar_query(2, "SELECT f::text FROM wire_fmt WHERE id = $id");
    is($dst_f, $src_f, "row $id: float8 replicated without losing digits");
}

# A whole-table checksum over canonically formatted values: catches anything the
# per-column assertions above might have missed.
my $sum_sql =
    "SELECT md5(string_agg(
         id || '|' || extract(epoch FROM ts) || '|' ||
         extract(epoch FROM tsn) || '|' || to_char(d, 'YYYY-MM-DD') || '|' ||
         extract(epoch FROM iv) || '|' || f, ',' ORDER BY id))
     FROM wire_fmt";
is(scalar_query(2, $sum_sql), scalar_query(1, $sum_sql),
   'Whole table matches between provider and subscriber');

destroy_cluster('Destroy cluster');

done_testing();
