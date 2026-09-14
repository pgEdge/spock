use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config psql_or_bail scalar_query
    poll_query_until wait_for_sub_status sync_nodes
);

# REPLICA IDENTITY FULL + PRIMARY KEY as the fix for TOAST divergence.
#
# PostgreSQL does not WAL-log a TOAST value an UPDATE left unchanged, so it
# is not in the replicated message ('u' on the wire) and the apply worker
# keeps whatever the local row holds.  When two nodes update the same row
# concurrently, both agree on the winner but end up with different rows.
# With REPLICA IDENTITY FULL the whole old row travels with the UPDATE, and
# the apply side takes the unchanged column from it.
#
# Cases (letters match the design spec, section 8.1):
#   a  identity DEFAULT: the race leaves the nodes divergent (pins the bug)
#   b  identity FULL: the same race converges
#   c  repset admits FULL + PK, refuses FULL without PK
#   d  row-present UPDATE and DELETE on a FULL table land via the PK
#   e  membership in 'default' survives ALTER ... REPLICA IDENTITY FULL
#   l  substitution is inert when the old tuple is key-only
#   j  spock.table_replica_identity_full()            (Task 3)
#   k  spock.repset_replica_identity_full()           (Task 4)
#   f-i spock.auto_replica_identity_full               (Task 5)

create_cluster(2, 'Create 2-node cluster for RI FULL TOAST convergence');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $BIG_Z = "repeat('z', 200000)";
my $BIG_X = "repeat('x', 200000)";

# --- helpers ---------------------------------------------------------------

sub relreplident {
    my ($node, $rel) = @_;
    return scalar_query($node,
        "SELECT relreplident FROM pg_class WHERE oid = '$rel'::regclass");
}

sub members_of {
    my ($node, $set, $rel) = @_;
    return scalar_query($node,
        "SELECT count(*) FROM spock.replication_set_table t "
      . "JOIN spock.replication_set s ON s.set_id = t.set_id "
      . "WHERE s.set_name = '$set' AND t.set_reloid = '$rel'::regclass");
}

sub row_sig {
    my ($node, $rel, $id) = @_;
    return scalar_query($node,
        "SELECT small || '/' || md5(big) FROM $rel WHERE id = $id");
}

# Wait until $query on $node returns $expected, then return the last value.
sub wait_for_value {
    my ($node, $query, $expected, $timeout) = @_;
    poll_query_until($node, $query, $expected, $timeout // 30);
    return scalar_query($node, $query);
}

# Both directions drained: n1 has applied everything n2 sent and vice versa.
sub drain {
    my ($label) = @_;
    ok(sync_nodes(1, 2), "$label: n1 -> n2 drained");
    ok(sync_nodes(2, 1), "$label: n2 -> n1 drained");
}

# Run $n1_sql on n1 and then $n2_sql on n2 while neither node is applying,
# so both changes are local when the other side's arrives.  n2 commits
# second, so last-update-wins picks n2's row on both nodes.  Spock classes
# this as update_origin_differs (a locally written row met a remote UPDATE),
# which is treated as ordinary replication flow and is not written to
# spock.resolutions, so the evidence is the rows themselves.
sub race {
    my ($label, $n1_sql, $n2_sql) = @_;
    psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2', true)");
    psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1', true)");
    ok(wait_for_sub_status(1, 'sub_n1_n2', 'disabled'), "$label: n1 apply stopped");
    ok(wait_for_sub_status(2, 'sub_n2_n1', 'disabled'), "$label: n2 apply stopped");

    psql_or_bail(1, $n1_sql);
    psql_or_bail(2, $n2_sql);

    psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2', true)");
    psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1', true)");
    ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating'), "$label: n1 apply resumed");
    ok(wait_for_sub_status(2, 'sub_n2_n1', 'replicating'), "$label: n2 apply resumed");
    drain($label);
}

# --- table setup -----------------------------------------------------------

# Auto-DDL is on (create_cluster sets spock.enable_ddl_replication and
# spock.include_ddl_repset), so a CREATE TABLE on n1 lands on n2 and joins
# 'default' on both.  Tables that must stay out of 'default' on n1 are
# created with spock.include_ddl_repset off in the same session.
psql_or_bail(1, "CREATE TABLE public.rif_base (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.rif_base ALTER COLUMN big SET STORAGE EXTERNAL");
psql_or_bail(1, "CREATE TABLE public.rif_conv (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.rif_conv ALTER COLUMN big SET STORAGE EXTERNAL; "
              . "ALTER TABLE public.rif_conv REPLICA IDENTITY FULL");
psql_or_bail(1, "CREATE TABLE public.rif_inert (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.rif_inert ALTER COLUMN big SET STORAGE EXTERNAL");
psql_or_bail(1, "SET spock.include_ddl_repset = off; "
              . "CREATE TABLE public.rif_gate (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.rif_gate ALTER COLUMN big SET STORAGE EXTERNAL; "
              . "ALTER TABLE public.rif_gate REPLICA IDENTITY FULL");
psql_or_bail(1, "SET spock.include_ddl_repset = off; "
              . "CREATE TABLE public.rif_gate_nopk (id int, small text); "
              . "ALTER TABLE public.rif_gate_nopk REPLICA IDENTITY FULL");

is(wait_for_value(2,
     "SELECT count(*) FROM pg_class WHERE relkind = 'r' AND relname IN "
   . "('rif_base', 'rif_conv', 'rif_inert', 'rif_gate', 'rif_gate_nopk')", '5'),
   '5', 'all tables replicated to n2');
is(wait_for_value(2, "SELECT relreplident FROM pg_class WHERE oid = 'public.rif_conv'::regclass", 'f'),
   'f', 'rif_conv is REPLICA IDENTITY FULL on n2 too');

# ---------------------------------------------------------------------------
# (a) Identity DEFAULT: the race leaves the nodes divergent.  This pins the
#     bug so that a change which makes DEFAULT tables converge is noticed.
# ---------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.rif_base VALUES (1, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT length(big) FROM public.rif_base WHERE id = 1", '200000'),
   '200000', '(a) toasted row replicated to n2');

race('(a)',
     "UPDATE public.rif_base SET big = $BIG_X WHERE id = 1",
     "UPDATE public.rif_base SET small = 'b' WHERE id = 1");

my $z_md5 = scalar_query(1, "SELECT md5($BIG_Z)");
my $x_md5 = scalar_query(1, "SELECT md5($BIG_X)");
is(row_sig(1, 'public.rif_base', 1), "b/$x_md5",
   '(a) n1 took n2 small but kept its own big');
is(row_sig(2, 'public.rif_base', 1), "b/$z_md5",
   '(a) n2 kept its own row');
isnt(row_sig(1, 'public.rif_base', 1), row_sig(2, 'public.rif_base', 1),
   '(a) identity DEFAULT: nodes diverge on the TOAST column');

# ---------------------------------------------------------------------------
# (b) Identity FULL: the same race converges.  n2 won, so both nodes must
#     hold n2's whole row: small = 'b' and the original big.
# ---------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.rif_conv VALUES (1, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT length(big) FROM public.rif_conv WHERE id = 1", '200000'),
   '200000', '(b) toasted row replicated to n2');

race('(b)',
     "UPDATE public.rif_conv SET big = $BIG_X WHERE id = 1",
     "UPDATE public.rif_conv SET small = 'b' WHERE id = 1");

is(row_sig(1, 'public.rif_conv', 1), "b/$z_md5",
   '(b) n1 took n2 whole row, big recovered from the old tuple');
is(row_sig(2, 'public.rif_conv', 1), "b/$z_md5",
   '(b) n2 kept its own row');
is(row_sig(1, 'public.rif_conv', 1), row_sig(2, 'public.rif_conv', 1),
   '(b) identity FULL: nodes converge');

# ---------------------------------------------------------------------------
# (c) Admission gate: FULL + PK is admitted, FULL without PK is refused.
# ---------------------------------------------------------------------------
is(scalar_query(1, "SELECT spock.repset_add_table('default', 'public.rif_gate')"),
   't', '(c) repset admits FULL table that has a PK');
is(scalar_query(1, "SELECT spock.repset_add_table('default', 'public.rif_gate_nopk')"),
   '', '(c) repset refuses FULL table without a PK');
is(members_of(1, 'default', 'public.rif_gate_nopk'), '0',
   '(c) refused table is not in the set');

# ---------------------------------------------------------------------------
# (d) Row-present UPDATE and DELETE on a FULL table are found via the PK.
# ---------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.rif_gate VALUES (1, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT length(big) FROM public.rif_gate WHERE id = 1", '200000'),
   '200000', '(d) toasted row replicated to n2');
psql_or_bail(1, "UPDATE public.rif_gate SET small = 'present' WHERE id = 1");
is(wait_for_value(2, "SELECT small FROM public.rif_gate WHERE id = 1", 'present'),
   'present', '(d) UPDATE applied via PK lookup');
is(scalar_query(2, "SELECT md5(big) FROM public.rif_gate WHERE id = 1"), $z_md5,
   '(d) unchanged big is intact after the UPDATE');
psql_or_bail(1, "DELETE FROM public.rif_gate WHERE id = 1");
is(wait_for_value(2, "SELECT count(*) FROM public.rif_gate", '0'),
   '0', '(d) DELETE on FULL table applied');

# ---------------------------------------------------------------------------
# (e) A PK table auto-added to 'default' stays there across ALTER ... FULL.
# ---------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE public.rif_stick (id int PRIMARY KEY, small text, big text)");
is(members_of(1, 'default', 'public.rif_stick'), '1',
   '(e) PK table auto-added to default while REPLICA IDENTITY DEFAULT');
psql_or_bail(1, "ALTER TABLE public.rif_stick REPLICA IDENTITY FULL");
is(members_of(1, 'default', 'public.rif_stick'), '1',
   '(e) membership in default survives ALTER REPLICA IDENTITY FULL');
psql_or_bail(1, "INSERT INTO public.rif_stick VALUES (1, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT length(big) FROM public.rif_stick WHERE id = 1", '200000'),
   '200000', '(e) rows still replicate after the ALTER');

# ---------------------------------------------------------------------------
# (l) Substitution is inert on an identity DEFAULT table, both when no old
#     tuple is sent (plain UPDATE of a non-key column) and when a key-only
#     old tuple is sent (UPDATE that changes the PK).  In the second case the
#     old tuple carries big as NULL because it was not logged; the null guard
#     must leave the local value alone rather than copy the sentinel.
# ---------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.rif_inert VALUES (1, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT length(big) FROM public.rif_inert WHERE id = 1", '200000'),
   '200000', '(l) toasted row replicated to n2');
psql_or_bail(1, "UPDATE public.rif_inert SET small = 't' WHERE id = 1");
is(wait_for_value(2, "SELECT small FROM public.rif_inert WHERE id = 1", 't'),
   't', '(l) non-key UPDATE applied');
is(scalar_query(2, "SELECT md5(big) FROM public.rif_inert WHERE id = 1"), $z_md5,
   '(l) no old tuple: big left alone and intact');
psql_or_bail(1, "UPDATE public.rif_inert SET id = 2 WHERE id = 1");
is(wait_for_value(2, "SELECT count(*) FROM public.rif_inert WHERE id = 2", '1'),
   '1', '(l) key-changing UPDATE applied');
is(scalar_query(2, "SELECT small || '/' || md5(big) FROM public.rif_inert WHERE id = 2"), "t/$z_md5",
   '(l) key-only old tuple: big left alone and intact');

# Later tasks append their cases above this line.

destroy_cluster('Destroy cluster');
done_testing();
