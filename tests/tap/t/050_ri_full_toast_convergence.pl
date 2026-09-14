use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    psql_or_bail scalar_query
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
#   m  a FULL table that loses its PRIMARY KEY leaves 'default'
#   n  a PRIMARY KEY table with identity NOTHING is not evicted from
#      every replication set

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

sub toast_oid {
    my ($node, $rel) = @_;
    return scalar_query($node,
        "SELECT reltoastrelid FROM pg_class WHERE oid = '$rel'::regclass");
}

# One counter out of pg_stat_all_tables, 0 before the first stats flush.
sub tup_stat {
    my ($node, $col, $relid) = @_;
    return scalar_query($node,
        "SELECT coalesce((SELECT $col FROM pg_stat_all_tables "
      . "WHERE relid = $relid), 0)");
}

# A backend flushes its pending statistics at most once a second, so a
# counter read right after the statement that moved it can still be stale.
# Wait until it has passed $floor and return the value it settled on.
sub wait_tup_stat {
    my ($node, $col, $relid, $floor) = @_;
    ok(poll_query_until($node,
        "SELECT coalesce((SELECT $col FROM pg_stat_all_tables "
      . "WHERE relid = $relid), 0) > $floor", 't'),
       "$col for relation $relid on n$node passed $floor");
    return tup_stat($node, $col, $relid);
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
my $conv_toast1 = toast_oid(1, 'public.rif_conv');
my $conv_toast2 = toast_oid(2, 'public.rif_conv');

my $t1_ins0 = tup_stat(1, 'n_tup_ins', $conv_toast1);
psql_or_bail(1, "INSERT INTO public.rif_conv VALUES (1, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT length(big) FROM public.rif_conv WHERE id = 1", '200000'),
   '200000', '(b) toasted row replicated to n2');

# One 200 kB value is this many TOAST chunks; used below as the unit.
my $t1_ins1 = wait_tup_stat(1, 'n_tup_ins', $conv_toast1, $t1_ins0);
my $one_value = $t1_ins1 - $t1_ins0;
cmp_ok($one_value, '>', 1, '(b) one big value takes more than one TOAST chunk');

my $c1_upd0 = tup_stat(1, 'n_tup_upd', "'public.rif_conv'::regclass");

race('(b)',
     "UPDATE public.rif_conv SET big = $BIG_X WHERE id = 1",
     "UPDATE public.rif_conv SET small = 'b' WHERE id = 1");

is(row_sig(1, 'public.rif_conv', 1), "b/$z_md5",
   '(b) n1 took n2 whole row, big recovered from the old tuple');
is(row_sig(2, 'public.rif_conv', 1), "b/$z_md5",
   '(b) n2 kept its own row');
is(row_sig(1, 'public.rif_conv', 1), row_sig(2, 'public.rif_conv', 1),
   '(b) identity FULL: nodes converge');

# n1 wrote its own big locally and then had to replace it with the value
# recovered from n2's old row, because the two differ: two whole values
# through TOAST.  This is the contrast to the in-sync case below.
wait_tup_stat(1, 'n_tup_upd', "'public.rif_conv'::regclass", $c1_upd0 + 1);
my $t1_ins2 = tup_stat(1, 'n_tup_ins', $conv_toast1);
cmp_ok($t1_ins2 - $t1_ins1, '>=', 2 * $one_value,
   '(b) n1 rewrote the TOAST value because the recovered bytes differed');

# The nodes are in sync now.  An UPDATE of the small column carries big as
# 'u'; the apply side recovers it from the old row and finds it identical to
# what it already holds, so heap_update() must not re-toast it.
my $t2_ins0 = tup_stat(2, 'n_tup_ins', $conv_toast2);
my $c2_upd0 = tup_stat(2, 'n_tup_upd', "'public.rif_conv'::regclass");
psql_or_bail(1, "UPDATE public.rif_conv SET small = 'x' WHERE id = 1");
is(wait_for_value(2, "SELECT small FROM public.rif_conv WHERE id = 1", 'x'),
   'x', '(b) in-sync UPDATE of the small column applied on n2');
# n_tup_upd moving proves the apply worker flushed this transaction's stats.
wait_tup_stat(2, 'n_tup_upd', "'public.rif_conv'::regclass", $c2_upd0);
is(tup_stat(2, 'n_tup_ins', $conv_toast2), $t2_ins0,
   '(b) in-sync UPDATE wrote no new TOAST chunks on n2');
is(scalar_query(2, "SELECT md5(big) FROM public.rif_conv WHERE id = 1"), $z_md5,
   '(b) big is still intact on n2');

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

# ---------------------------------------------------------------------------
# (j) spock.table_replica_identity_full().  Local to the node: n2 is not
#     touched, which is why relreplident is checked on n1 only.
# ---------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE public.rif_fn (id int PRIMARY KEY, small text)");
psql_or_bail(1, "CREATE TABLE public.rif_fn_nopk (id int, small text)");
psql_or_bail(1, "CREATE TABLE public.rif_fn_part (id int, small text, PRIMARY KEY (id)) PARTITION BY RANGE (id); "
              . "CREATE TABLE public.rif_fn_p0 PARTITION OF public.rif_fn_part FOR VALUES FROM (0) TO (10); "
              . "CREATE TABLE public.rif_fn_p1 PARTITION OF public.rif_fn_part FOR VALUES FROM (10) TO (20)");

is(relreplident(1, 'public.rif_fn'), 'd', '(j) rif_fn starts at DEFAULT');
is(scalar_query(1, "SELECT spock.table_replica_identity_full('public.rif_fn')"), 't',
   '(j) first call changes the identity');
is(relreplident(1, 'public.rif_fn'), 'f', '(j) rif_fn is FULL');
is(scalar_query(1, "SELECT spock.table_replica_identity_full('public.rif_fn')"), 'f',
   '(j) second call has nothing to do');

is(scalar_query(1, "SELECT spock.table_replica_identity_full('public.rif_fn_nopk')"), '',
   '(j) no PK: refused');
is(relreplident(1, 'public.rif_fn_nopk'), 'd', '(j) refused table left at DEFAULT');

is(scalar_query(1, "SELECT spock.table_replica_identity_full('public.rif_fn_part')"), 't',
   '(j) partitioned table: leaves changed');
is(relreplident(1, 'public.rif_fn_p0'), 'f', '(j) partition p0 is FULL');
is(relreplident(1, 'public.rif_fn_p1'), 'f', '(j) partition p1 is FULL');
is(relreplident(1, 'public.rif_fn_part'), 'd', '(j) parent left at DEFAULT');

is(scalar_query(1, "SELECT spock.table_replica_identity_full('public.rif_fn_part', false)"), '',
   '(j) parent alone with include_partitions = false: refused');

is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE relname = 'rif_fn'", '1'),
   '1', '(j) rif_fn exists on n2');
is(relreplident(2, 'public.rif_fn'), 'd', '(j) function did not propagate: n2 still DEFAULT');

# ---------------------------------------------------------------------------
# (k) spock.repset_replica_identity_full().  One set per call, by name.
# ---------------------------------------------------------------------------
psql_or_bail(1, "SELECT spock.repset_create('rif_set')");
psql_or_bail(1, "SELECT spock.repset_create('rif_ins', replicate_update := false, replicate_delete := false)");
psql_or_bail(1, "SET spock.include_ddl_repset = off; "
              . "CREATE TABLE public.rif_k1 (id int PRIMARY KEY, small text); "
              . "CREATE TABLE public.rif_k2 (id int PRIMARY KEY, small text); "
              . "CREATE TABLE public.rif_k3 (id int PRIMARY KEY, small text); "
              . "CREATE TABLE public.rif_k4 (id int PRIMARY KEY, small text); "
              . "ALTER TABLE public.rif_k4 REPLICA IDENTITY FULL");
for my $t (qw(rif_k1 rif_k2 rif_k3 rif_k4)) {
    is(scalar_query(1, "SELECT spock.repset_add_table('rif_set', 'public.$t')"), 't',
       "(k) $t added to rif_set");
}
# With include_ddl_repset off the membership is not re-evaluated, so a
# table without a PK ends up in an UPDATE/DELETE set: the warning path.
psql_or_bail(1, "SET spock.include_ddl_repset = off; "
              . "ALTER TABLE public.rif_k3 DROP CONSTRAINT rif_k3_pkey");
is(members_of(1, 'rif_set', 'public.rif_k3'), '1', '(k) rif_k3 still in rif_set without a PK');

is(scalar_query(1, "SELECT spock.repset_replica_identity_full('rif_set')"), '2',
   '(k) two tables switched: k1 and k2; k3 skipped, k4 already FULL');
is(relreplident(1, 'public.rif_k1'), 'f', '(k) rif_k1 is FULL');
is(relreplident(1, 'public.rif_k2'), 'f', '(k) rif_k2 is FULL');
is(relreplident(1, 'public.rif_k3'), 'd', '(k) rif_k3 left at DEFAULT');
is(relreplident(1, 'public.rif_k4'), 'f', '(k) rif_k4 still FULL');
is(scalar_query(1, "SELECT spock.repset_replica_identity_full('rif_set')"), '0',
   '(k) second call has nothing to do');

is(scalar_query(1, "SELECT spock.repset_replica_identity_full('rif_ins')"), '',
   '(k) insert-only set: refused');
is(scalar_query(1, "SELECT spock.repset_replica_identity_full('rif_nosuch')"), '',
   '(k) unknown set: refused');

# No "all sets" form: NULL is STRICT-returned and a DEFAULT PK table in
# 'default' stays DEFAULT.
psql_or_bail(1, "CREATE TABLE public.rif_k_default (id int PRIMARY KEY, small text)");
is(members_of(1, 'default', 'public.rif_k_default'), '1', '(k) rif_k_default auto-added to default');
is(scalar_query(1, "SELECT spock.repset_replica_identity_full(NULL) IS NULL"), 't',
   '(k) NULL argument returns NULL');
is(relreplident(1, 'public.rif_k_default'), 'd', '(k) NULL argument changed nothing');

# ---------------------------------------------------------------------------
# (m) A FULL table that loses its PRIMARY KEY must leave 'default'.  Bare
#     REPLICA IDENTITY FULL is not an identity Spock can replicate
#     UPDATE/DELETE with: the subscriber needs the PRIMARY KEY to find the
#     row.  Auto-DDL is on here, so the DROP CONSTRAINT is classified and
#     the table is re-routed.
# ---------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE public.rif_drop (id int PRIMARY KEY, small text)");
psql_or_bail(1, "ALTER TABLE public.rif_drop REPLICA IDENTITY FULL");
is(members_of(1, 'default', 'public.rif_drop'), '1',
   '(m) FULL + PK table sits in default');
psql_or_bail(1, "ALTER TABLE public.rif_drop DROP CONSTRAINT rif_drop_pkey");
is(members_of(1, 'default', 'public.rif_drop'), '0',
   '(m) dropping the PRIMARY KEY takes it out of default');
is(members_of(1, 'default_insert_only', 'public.rif_drop'), '1',
   '(m) and puts it in default_insert_only');

# ---------------------------------------------------------------------------
# (n) A PRIMARY KEY table with REPLICA IDENTITY NOTHING must not end up in
#     no replication set at all.  Routing and the gate below it have to
#     agree on what counts as an identity.
# ---------------------------------------------------------------------------
# NOTHING leaves the PRIMARY KEY in place but logs no key, so the table can
# no longer replicate UPDATE or DELETE: the classification reads the
# effective identity, not the key, and re-routes it.
psql_or_bail(1, "CREATE TABLE public.rif_nothing (id int PRIMARY KEY, small text)");
is(members_of(1, 'default', 'public.rif_nothing'), '1',
   '(n) PK table auto-added to default');
psql_or_bail(1, "ALTER TABLE public.rif_nothing REPLICA IDENTITY NOTHING");
is(members_of(1, 'default', 'public.rif_nothing'), '0',
   '(n) REPLICA IDENTITY NOTHING takes it out of default');
is(members_of(1, 'default_insert_only', 'public.rif_nothing'), '1',
   '(n) and puts it in default_insert_only');

# A table that does reach the routing decision with a PRIMARY KEY and no
# usable identity: created without a key, set to NOTHING, then given a
# PRIMARY KEY.  Routing used to send it to 'default' on the strength of the
# key alone, evict it from every set on the way, and then have the gate
# refuse it, leaving it in nothing.
psql_or_bail(1, "CREATE TABLE public.rif_nothing2 (id int, small text)");
is(members_of(1, 'default_insert_only', 'public.rif_nothing2'), '1',
   '(n) keyless table auto-added to default_insert_only');
psql_or_bail(1, "ALTER TABLE public.rif_nothing2 REPLICA IDENTITY NOTHING");
psql_or_bail(1, "ALTER TABLE public.rif_nothing2 ADD PRIMARY KEY (id)");
is(members_of(1, 'default', 'public.rif_nothing2'), '0',
   '(n) NOTHING keeps it out of default even once it has a PRIMARY KEY');
is(members_of(1, 'default_insert_only', 'public.rif_nothing2'), '1',
   '(n) and it is still in default_insert_only');

# ---------------------------------------------------------------------------
# GUC spock.auto_replica_identity_full.  Turned on on both nodes.  The
# apply workers are restarted so the one that executes replicated DDL runs
# with the new value; a fresh psql session picks it up on its own.
# ---------------------------------------------------------------------------
for my $n (1, 2) {
    psql_or_bail($n, "ALTER SYSTEM SET spock.auto_replica_identity_full = on");
    psql_or_bail($n, "SELECT pg_reload_conf()");
    is(wait_for_value($n, "SHOW spock.auto_replica_identity_full", 'on'), 'on',
       "GUC on for new sessions on n$n");
}
psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2', true)");
psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1', true)");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'disabled'), 'GUC: n1 apply stopped');
ok(wait_for_sub_status(2, 'sub_n2_n1', 'disabled'), 'GUC: n2 apply stopped');
psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2', true)");
psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1', true)");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating'), 'GUC: n1 apply restarted');
ok(wait_for_sub_status(2, 'sub_n2_n1', 'replicating'), 'GUC: n2 apply restarted');

# (f) repset_add_table on each node switches the table on that node.
psql_or_bail(1, "SET spock.include_ddl_repset = off; "
              . "CREATE TABLE public.rif_g_add (id int PRIMARY KEY, small text)");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE relname = 'rif_g_add'", '1'),
   '1', '(f) rif_g_add exists on n2');
is(relreplident(1, 'public.rif_g_add'), 'd', '(f) starts at DEFAULT on n1');
is(scalar_query(1, "SELECT spock.repset_add_table('default', 'public.rif_g_add')"), 't',
   '(f) added on n1');
is(relreplident(1, 'public.rif_g_add'), 'f', '(f) n1: FULL after repset_add_table');
# n2 auto-added it at CREATE (its include_ddl_repset is on), so it is FULL
# there through the auto-DDL path; that is case (g)'s mechanism.
is(wait_for_value(2, "SELECT relreplident FROM pg_class WHERE oid = 'public.rif_g_add'::regclass", 'f'),
   'f', '(f) n2: FULL through auto-add of the replicated CREATE');

# (g) auto-DDL: CREATE TABLE with include_ddl_repset on switches the table
#     on the creating node and on the node applying the DDL.
psql_or_bail(1, "CREATE TABLE public.rif_g_auto (id int PRIMARY KEY, small text)");
is(members_of(1, 'default', 'public.rif_g_auto'), '1', '(g) n1: auto-added to default');
is(relreplident(1, 'public.rif_g_auto'), 'f', '(g) n1: FULL without an explicit ALTER');
is(wait_for_value(2, "SELECT relreplident FROM pg_class WHERE oid = 'public.rif_g_auto'::regclass", 'f'),
   'f', '(g) n2: FULL after applying the replicated CREATE');
is(members_of(2, 'default', 'public.rif_g_auto'), '1', '(g) n2: auto-added to default');

# (h) Deliberate identities are left alone.
psql_or_bail(1, "SET spock.include_ddl_repset = off; "
              . "CREATE TABLE public.rif_g_idx (id int PRIMARY KEY, alt int NOT NULL); "
              . "CREATE UNIQUE INDEX rif_g_idx_alt ON public.rif_g_idx (alt); "
              . "ALTER TABLE public.rif_g_idx REPLICA IDENTITY USING INDEX rif_g_idx_alt");
is(scalar_query(1, "SELECT spock.repset_add_table('default', 'public.rif_g_idx')"), 't',
   '(h) USING INDEX table added');
is(relreplident(1, 'public.rif_g_idx'), 'i', '(h) USING INDEX left alone');
psql_or_bail(1, "SET spock.include_ddl_repset = off; "
              . "CREATE TABLE public.rif_g_nopk (id int, small text)");
is(scalar_query(1, "SELECT spock.repset_add_table('default_insert_only', 'public.rif_g_nopk')"), 't',
   '(h) no-PK table added to the insert-only set');
is(relreplident(1, 'public.rif_g_nopk'), 'd', '(h) insert-only set: identity untouched');

# (i) Partitions: every leaf switched, parent untouched.
psql_or_bail(1, "SET spock.include_ddl_repset = off; "
              . "CREATE TABLE public.rif_g_part (id int, small text, PRIMARY KEY (id)) PARTITION BY RANGE (id); "
              . "CREATE TABLE public.rif_g_p0 PARTITION OF public.rif_g_part FOR VALUES FROM (0) TO (10); "
              . "CREATE TABLE public.rif_g_p1 PARTITION OF public.rif_g_part FOR VALUES FROM (10) TO (20)");
is(scalar_query(1, "SELECT spock.repset_add_table('default', 'public.rif_g_part')"), 't',
   '(i) partitioned table added with its partitions');
is(relreplident(1, 'public.rif_g_p0'), 'f', '(i) p0 is FULL');
is(relreplident(1, 'public.rif_g_p1'), 'f', '(i) p1 is FULL');
is(relreplident(1, 'public.rif_g_part'), 'd', '(i) parent left at DEFAULT');

# A FULL table produced by the GUC replicates like any other.
psql_or_bail(1, "INSERT INTO public.rif_g_auto VALUES (1, 's')");
is(wait_for_value(2, "SELECT small FROM public.rif_g_auto WHERE id = 1", 's'),
   's', '(g) rows replicate on the GUC-switched table');
psql_or_bail(1, "UPDATE public.rif_g_auto SET small = 't' WHERE id = 1");
is(wait_for_value(2, "SELECT small FROM public.rif_g_auto WHERE id = 1", 't'),
   't', '(g) UPDATE replicates on the GUC-switched table');

# Put the GUC back so nothing after this block runs with it on.
for my $n (1, 2) {
    psql_or_bail($n, "ALTER SYSTEM RESET spock.auto_replica_identity_full");
    psql_or_bail($n, "SELECT pg_reload_conf()");
    is(wait_for_value($n, "SHOW spock.auto_replica_identity_full", 'off'), 'off',
       "GUC back off for new sessions on n$n");
}

destroy_cluster('Destroy cluster');
done_testing();
