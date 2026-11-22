use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster get_test_config
    psql_or_bail scalar_query poll_query_until
    wait_for_sub_status sync_nodes
);

# TOAST divergence when the winning change was forwarded.
#
# Topology, a chain with forwarding on n1's subscription:
#
#   n3 <-> n2 <-> n1        n1 subscribes to n2 with forward_origins {all}
#
# n3's UPDATEs reach n1 through n2.  n2 applied the same unchanged TOAST
# column, so its own value proves nothing, and Spock does not allow n1 a
# direct subscription to n3 while sub_n1_n2 forwards.  So the entry must be
# recorded with no winner subscription and a last_error saying why.
#
# Every n1 write in this test loses its conflict on n2, so n2 never applies
# one and nothing loops back to n1 through the {all} subscription.

create_cluster(3, 'Create 3-node cluster for forwarded TOAST divergence');

my $cfg = get_test_config();
my @port = @{ $cfg->{node_ports} };

sub dsn {
    my ($n) = @_;
    return "host=$cfg->{host} dbname=$cfg->{db_name} port=$port[$n - 1] "
         . "user=$cfg->{db_user} password=$cfg->{db_password}";
}

sub subscribe {
    my ($node, $provider, $forward) = @_;
    my $name = "sub_n${node}_n${provider}";
    psql_or_bail($node, "SELECT spock.sub_create('$name', '" . dsn($provider) . "', "
                      . "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false, "
                      . "'$forward')");
    ok(wait_for_sub_status($node, $name, 'replicating'), "$name replicating");
}

sub suspects {
    my ($node, $where) = @_;
    $where //= 'true';
    return scalar_query($node, "SELECT count(*) FROM spock.toast_suspect WHERE $where");
}

sub big_md5 {
    my ($node, $id) = @_;
    return scalar_query($node, "SELECT md5(big) FROM public.td WHERE id = $id");
}

# Stage a forwarded divergence on n1 for row $id.  n1 changes big while
# neither n1 nor n2 applies from the other; n3 then changes small, which is
# newer.  n2 applies n3's change, then discards n1's older one.  n1 receives
# n3's change through n2, keeps its own big, and records a suspect.
sub diverge_forwarded {
    my ($label, $id) = @_;

    psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2', true)");
    psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1', true)");
    ok(wait_for_sub_status(1, 'sub_n1_n2', 'disabled'), "$label: n1 apply from n2 stopped");
    ok(wait_for_sub_status(2, 'sub_n2_n1', 'disabled'), "$label: n2 apply from n1 stopped");

    psql_or_bail(1, "UPDATE public.td SET big = repeat('x', 200000) WHERE id = $id");
    psql_or_bail(3, "UPDATE public.td SET small = 'w3' WHERE id = $id");
    ok(sync_nodes(3, 2), "$label: n3 -> n2 drained");
    is(scalar_query(2, "SELECT small FROM public.td WHERE id = $id"), 'w3',
       "$label: n2 applied n3's change");

    psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1', true)");
    ok(wait_for_sub_status(2, 'sub_n2_n1', 'replicating'), "$label: n2 apply from n1 resumed");
    ok(sync_nodes(1, 2), "$label: n1 -> n2 drained");

    psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2', true)");
    ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating'), "$label: n1 apply from n2 resumed");
    ok(poll_query_until(1, "SELECT small FROM public.td WHERE id = $id", 'w3', 30),
       "$label: n1 applied n3's change forwarded by n2");
}

# --- setup -----------------------------------------------------------------

subscribe(1, 2, '{all}');
subscribe(2, 1, '{}');
subscribe(2, 3, '{}');
subscribe(3, 2, '{}');

# Auto-DDL is on: created on n2, the table reaches n1 and n3 directly.
psql_or_bail(2, "CREATE TABLE public.td (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td ALTER COLUMN big SET STORAGE EXTERNAL");
for my $n (1, 3) {
    ok(poll_query_until($n, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td')", '1', 60),
       "td replicated to n$n");
}
psql_or_bail(2, "INSERT INTO public.td VALUES (1, 's', repeat('z', 200000)), (2, 's', repeat('z', 200000))");
for my $n (1, 3) {
    ok(poll_query_until($n, "SELECT count(*) FROM public.td", '2', 60), "rows on n$n");
}
is(suspects(1), '0', 'queue starts empty on n1');

my $md5_x = scalar_query(1, "SELECT md5(repeat('x', 200000))");
my $md5_z = scalar_query(1, "SELECT md5(repeat('z', 200000))");

# ---------------------------------------------------------------------------
# A forwarded winning change.
# ---------------------------------------------------------------------------
diverge_forwarded('fwd', 1);

is(suspects(1, "pkey = jsonb_build_object('id', '1')"), '1', 'suspect recorded on n1');
is(scalar_query(1, "SELECT winner_subid FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '1')"),
   '0', 'no winner subscription recorded');
# n1 has no spock.node row for n3, so take n3's id from n3 itself.
my $n3_id = scalar_query(3, "SELECT node_id FROM spock.local_node");
is(scalar_query(1, "SELECT winner_origin FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '1')"),
   $n3_id, 'the winning origin is n3');
is(scalar_query(1, "SELECT last_error LIKE '%was forwarded by subscription sub_n1_n2%' "
                 . "FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '1')"),
   't', 'last_error names the forwarding subscription');
is(big_md5(1, 1), $md5_x, 'n1 diverged to x');
is(big_md5(3, 1), $md5_z, 'n3 still holds z');

# ---------------------------------------------------------------------------
# Stamps across the chain.  n3 writes row 3's big; n2 then updates small, so
# every node's row was last written by a node other than the next sender.
# n3 then updates small: n2 applies it directly and n1 through n2's
# forwarding.  Each node holds the same version of big (written by n3), so
# with stamps no node records anything.
# ---------------------------------------------------------------------------
psql_or_bail(3, "INSERT INTO public.td VALUES (3, 's', repeat('z', 200000))");
ok(poll_query_until(1, "SELECT count(*) FROM public.td WHERE id = 3", '1', 60), 'row 3 forwarded to n1');
psql_or_bail(2, "UPDATE public.td SET small = 'st2' WHERE id = 3");
for my $n (1, 3) {
    ok(poll_query_until($n, "SELECT small FROM public.td WHERE id = 3", 'st2', 60), "n2's update on n$n");
}
psql_or_bail(3, "UPDATE public.td SET small = 'st3' WHERE id = 3");
for my $n (1, 2) {
    ok(poll_query_until($n, "SELECT small FROM public.td WHERE id = 3", 'st3', 60), "n3's update on n$n");
}
for my $n (1, 2, 3) {
    is(suspects($n, "pkey = jsonb_build_object('id', '3')"), '0',
       "stamps: nothing recorded on n$n for the same version across two hops");
}

destroy_cluster('Destroy cluster');
done_testing();
