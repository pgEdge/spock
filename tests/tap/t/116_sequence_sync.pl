use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config scalar_query psql_or_bail poll_query_until
);

# =============================================================================
# Test: 116_sequence_sync.pl
#
# Periodic sequence synchronization.
#
# The manager worker pushes the state of every sequence in a replication set
# to subscribers every spock.sequence_sync_interval seconds, one cache ahead
# of the provider's position, so a subscriber's copy stays ahead of what the
# provider has handed out.
#
# Positive: a consumed sequence reaches the subscriber without anyone calling
# spock.sync_seq(); a sequence consumed faster than its cache is pushed again
# within a second; the interval is reloadable.
#
# Negative: with the interval at 0 nothing is pushed; and in a bidirectional
# setup a received value is not pushed straight back, so two nodes do not
# drive the sequence upward between them.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for sequence sync tests');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $cfg = get_test_config();

sub set_interval {
    my ($seconds) = @_;
    for my $n (1, 2) {
        psql_or_bail($n, "ALTER SYSTEM SET spock.sequence_sync_interval = '${seconds}s'");
        psql_or_bail($n, "SELECT pg_reload_conf()");
    }
    sleep(1);
}

sub last_value {
    my ($n, $seq) = @_;
    return scalar_query($n, "SELECT last_value FROM $seq");
}

sub state_of {
    my ($n, $seq) = @_;
    return scalar_query($n,
        "SELECT cache_size || ':' || last_value FROM spock.sequence_state " .
        " WHERE seqoid = '$seq'::regclass");
}

# Wait until the subscriber's copy is at or beyond $want.
sub wait_at_least {
    my ($n, $seq, $want, $secs, $label) = @_;
    my $got = '';
    for (1 .. $secs * 2) {
        $got = last_value($n, $seq);
        return pass($label) if $got >= $want;
        select(undef, undef, undef, 0.5);
    }
    return fail("$label (wanted >= $want, last saw $got)");
}

# --------------------------------------------------------------------------
# A sequence replicated one way: n1 publishes, n2 receives
#
# The sequence is created on n1 and reaches n2 through DDL replication; only
# n1 adds it to a replication set, so only n1 publishes its state.
# --------------------------------------------------------------------------
is(scalar_query(1, "SELECT setting FROM pg_settings WHERE name = 'spock.sequence_sync_interval'"),
   '60', 'the default interval is 60 seconds');

psql_or_bail(1, "CREATE SEQUENCE public.seq_oneway");
ok(poll_query_until(2, "SELECT count(*) FROM pg_class WHERE relname = 'seq_oneway'", '1', 30),
   'the sequence reached n2');
psql_or_bail(1, "SELECT spock.repset_add_seq('default', 'public.seq_oneway')");
like(state_of(1, 'public.seq_oneway'), qr/^1000:/, 'n1 tracks the sequence with the minimum cache');

set_interval(2);

# The first push puts the subscriber one cache ahead before the sequence has
# been used at all, so a value handed out on n1 can never collide with one
# n2 would hand out from the replicated state.
wait_at_least(2, 'public.seq_oneway', 1001, 10, 'the first push puts n2 a cache ahead');

# Consume it.  The subscriber must end up ahead of the provider.
psql_or_bail(1, "SELECT count(nextval('public.seq_oneway')) FROM generate_series(1, 600)");
my $n1_value = last_value(1, 'public.seq_oneway');
is($n1_value, '600', 'n1 handed out 600 values');
wait_at_least(2, 'public.seq_oneway', 600 + 1000, 15,
              'n2 receives a value one cache ahead of n1, without sync_seq()');
ok(last_value(2, 'public.seq_oneway') > $n1_value, 'the subscriber is ahead of the provider');

# A sequence consumed faster than its cache is pushed again within about a
# second, and the cache grows so the next push covers more.
psql_or_bail(1, "SELECT count(nextval('public.seq_oneway')) FROM generate_series(1, 3000)");
wait_at_least(2, 'public.seq_oneway', 3600, 10, 'a burst is followed up quickly');
like(state_of(1, 'public.seq_oneway'), qr/^2000:/, 'the cache doubled after the burst');

# --------------------------------------------------------------------------
# Disabled: nothing is pushed
# --------------------------------------------------------------------------
set_interval(0);
my $before = last_value(2, 'public.seq_oneway');
psql_or_bail(1, "SELECT count(nextval('public.seq_oneway')) FROM generate_series(1, 5000)");
sleep(5);
is(last_value(2, 'public.seq_oneway'), $before, 'with the interval at 0 nothing is pushed');

# spock.sync_seq() still works by hand.
psql_or_bail(1, "SELECT spock.sync_seq('public.seq_oneway')");
wait_at_least(2, 'public.seq_oneway', 8600, 15, 'sync_seq() still pushes by hand');

# --------------------------------------------------------------------------
# Bidirectional: both nodes publish the same sequence
#
# n2 receives n1's push and, since it publishes the sequence too, would see
# the jump as local consumption and push it straight back, each round adding
# a cache and doubling the cache.  A received value is instead counted as
# already published, so the sequence settles.
# --------------------------------------------------------------------------
psql_or_bail(1, "CREATE SEQUENCE public.seq_both");
ok(poll_query_until(2, "SELECT count(*) FROM pg_class WHERE relname = 'seq_both'", '1', 30),
   'the second sequence reached n2');
psql_or_bail($_, "SELECT spock.repset_add_seq('default', 'public.seq_both')") for (1, 2);

set_interval(2);
psql_or_bail(1, "SELECT count(nextval('public.seq_both')) FROM generate_series(1, 600)");
wait_at_least(2, 'public.seq_both', 1600, 15, 'n2 receives n1\'s push');

# Let several intervals pass.  Nothing should move any more.
sleep(3);
my $n1_settled = last_value(1, 'public.seq_both');
my $n2_settled = last_value(2, 'public.seq_both');
sleep(7);
is(last_value(1, 'public.seq_both'), $n1_settled, 'n1\'s sequence stopped moving');
is(last_value(2, 'public.seq_both'), $n2_settled, 'n2\'s sequence stopped moving');
like(state_of(1, 'public.seq_both'), qr/^1000:/, 'n1\'s cache did not balloon');
like(state_of(2, 'public.seq_both'), qr/^1000:/, 'n2\'s cache did not balloon');

# Consumption on n2 now propagates to n1 the same way.
psql_or_bail(2, "SELECT count(nextval('public.seq_both')) FROM generate_series(1, 600)");
my $n2_value = last_value(2, 'public.seq_both');
wait_at_least(1, 'public.seq_both', $n2_value + 1000, 15, 'n1 receives n2\'s push');

for my $n (1, 2) {
    psql_or_bail($n, "ALTER SYSTEM RESET spock.sequence_sync_interval");
    psql_or_bail($n, "SELECT pg_reload_conf()");
}

destroy_cluster('Destroy sequence sync test cluster');
done_testing();
