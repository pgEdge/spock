use strict;
use warnings;
use Test::More;
use IPC::Run;
use lib '.';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster get_test_config
    psql_or_bail scalar_query poll_query_until
    wait_for_sub_status sync_nodes log_offset log_since wait_for_exception_log
);

# TOAST version stamps: exact divergence detection.
#
# The sender sends, with each unchanged out-of-line TOAST column, the stamp
# of the value it holds (node id and commit timestamp of the transaction
# that wrote it, and its raw size).  The receiver records a suspect only
# when its own value's stamp differs, or cannot be told.
#
# Cases (lettered in the order they were written, so the list has gaps):
#   a   sequential cross-node updates record nothing
#   b   the race records stamp_mismatch with the winner's stamp
#   c   equal bytes written separately: stamp_mismatch
#   d   stamps off on the sender: plain 'u', every entry no_stamp
#   e   local value inline, remote out of line: stamp_mismatch
#   f   local chunks frozen keep their stamp: nothing recorded
#   g   the sender cannot lock its TOAST table: no_stamp, decoding not held
#   h0  a value written under the initial sync's stamp: no_local_stamp
#   o   decoding a change made before VACUUM FULL or TRUNCATE sends 'u'
#   x   a row last written by the sender is recorded when the sender's
#       value names another node and differs here
#   y   ... but not on no_local_stamp alone
#   z   after VACUUM FULL on the sender its later updates are not recorded
#   z2  a write of the sender's thrown away here that changed the size is
#       recorded on the sender's next update

create_cluster(2, 'Create 2-node cluster for TOAST version stamps');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');
# Stamps are on by default, so the walsenders send them from the start.

my $cfg = get_test_config();
my $BIG_Z = "repeat('z', 200000)";

# The background session holding a lock in (g); killed at exit as well, so a
# failure cannot leave the lock held.
my $locker;
my $locker_node = 2;
sub end_locker {
    return unless $locker;
    run_on_node_quiet($locker_node, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                                  . "WHERE application_name = 'td_locker'");
    $locker->kill_kill;
    $locker = undef;
}
END { end_locker(); }

sub run_on_node_quiet {
    my ($node, $sql) = @_;
    system("$cfg->{pg_bin}/psql", '-X', '-q', '-p', $cfg->{node_ports}->[$node - 1],
           '-d', $cfg->{db_name}, '-c', $sql);
}

sub suspects {
    my ($node, $where) = @_;
    $where //= 'true';
    return scalar_query($node, "SELECT count(*) FROM spock.toast_suspect WHERE $where");
}

sub drain {
    my ($label) = @_;
    ok(sync_nodes(1, 2), "$label: n1 -> n2 drained");
    ok(sync_nodes(2, 1), "$label: n2 -> n1 drained");
}

sub stop_apply {
    my ($node, $sub, $label) = @_;
    psql_or_bail($node, "SELECT spock.sub_disable('$sub', true)");
    ok(wait_for_sub_status($node, $sub, 'disabled'), "$label: $sub stopped");
}

sub start_apply {
    my ($node, $sub, $label) = @_;
    psql_or_bail($node, "SELECT spock.sub_enable('$sub', true)");
    ok(wait_for_sub_status($node, $sub, 'replicating'), "$label: $sub replicating");
}

# n1 then n2 change the row while neither applies; n2 commits second and
# wins on both nodes, so n1 applies n2's update and may diverge.
sub race {
    my ($label, $n1_sql, $n2_sql) = @_;
    stop_apply(1, 'sub_n1_n2', $label);
    stop_apply(2, 'sub_n2_n1', $label);
    psql_or_bail(1, $n1_sql);
    psql_or_bail(2, $n2_sql);
    start_apply(1, 'sub_n1_n2', $label);
    start_apply(2, 'sub_n2_n1', $label);
    drain($label);
}

sub insert_rows {
    my ($label, $from, $to) = @_;
    psql_or_bail(1, "INSERT INTO public.td SELECT g, 's', $BIG_Z FROM generate_series($from, $to) g");
    drain($label);
}

sub reason_of {
    my ($node, $id) = @_;
    return scalar_query($node,
        "SELECT reason FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '$id')");
}

# --- setup -----------------------------------------------------------------

psql_or_bail(1, "CREATE TABLE public.td (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td ALTER COLUMN big SET STORAGE EXTERNAL");
ok(poll_query_until(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td')", '1', 30),
   'table replicated to n2');
my $toast_n1 = scalar_query(1, "SELECT reltoastrelid::regclass FROM pg_class WHERE oid = 'public.td'::regclass");
my $toast_n2 = scalar_query(2, "SELECT reltoastrelid::regclass FROM pg_class WHERE oid = 'public.td'::regclass");

# ---------------------------------------------------------------------------
# (a) Sequential cross-node updates: n1 wrote the rows, n2 later updates
#     small.  Same value version on both nodes, so nothing is recorded.
# ---------------------------------------------------------------------------
insert_rows('(a)', 1, 20);
psql_or_bail(2, "UPDATE public.td SET small = 'a' WHERE id BETWEEN 1 AND 20");
drain('(a)');
is(scalar_query(1, "SELECT count(*) FROM public.td WHERE small = 'a'"), '20', '(a) updates applied on n1');
is(suspects(1), '0', '(a) no suspects for sequential cross-node updates');

# ---------------------------------------------------------------------------
# (b) The race: n1 writes big, n2 writes small and wins.  n1 keeps its own
#     big, a different version: stamp_mismatch, carrying n2's stamp.
# ---------------------------------------------------------------------------
insert_rows('(b)', 21, 21);
race('(b)',
     "UPDATE public.td SET big = repeat('b', 200000) WHERE id = 21",
     "UPDATE public.td SET small = 'b' WHERE id = 21");
is(suspects(1, "pkey = jsonb_build_object('id', '21')"), '1', '(b) suspect on n1');
is(reason_of(1, 21), 'stamp_mismatch', '(b) reason stamp_mismatch');
is(scalar_query(1, "SELECT winner_stamps[1] FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '21')"),
   scalar_query(2, "SELECT spock.toast_stamp(big) FROM public.td WHERE id = 21"),
   '(b) the entry carries n2\'s stamp for big');

# ---------------------------------------------------------------------------
# (c) Equal bytes written separately: n1 writes the value n2 already has.
#     The versions differ, so it is recorded.
# ---------------------------------------------------------------------------
insert_rows('(c)', 22, 22);
race('(c)',
     "UPDATE public.td SET big = $BIG_Z WHERE id = 22",
     "UPDATE public.td SET small = 'c' WHERE id = 22");
is(reason_of(1, 22), 'stamp_mismatch', '(c) recorded as stamp_mismatch');

# ---------------------------------------------------------------------------
# (d) Stamps off on the sender: plain 'u', today's rule, every entry no_stamp.
# ---------------------------------------------------------------------------
psql_or_bail(2, "ALTER SYSTEM SET spock.toast_divergence_stamps = off");
psql_or_bail(2, "SELECT pg_reload_conf()");
stop_apply(1, 'sub_n1_n2', '(d)');
start_apply(1, 'sub_n1_n2', '(d)');
insert_rows('(d)', 31, 40);
psql_or_bail(2, "UPDATE public.td SET small = 'd' WHERE id BETWEEN 31 AND 40");
drain('(d)');
is(suspects(1, "(pkey->>'id')::int BETWEEN 31 AND 40"), '10', '(d) all ten recorded');
is(suspects(1, "(pkey->>'id')::int BETWEEN 31 AND 40 AND reason = 'no_stamp'"), '10', '(d) all no_stamp');
psql_or_bail(2, "ALTER SYSTEM RESET spock.toast_divergence_stamps");
psql_or_bail(2, "SELECT pg_reload_conf()");
stop_apply(1, 'sub_n1_n2', '(d)');
start_apply(1, 'sub_n1_n2', '(d)');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# ---------------------------------------------------------------------------
# (e) Local value inline, remote out of line, different sizes.
# ---------------------------------------------------------------------------
insert_rows('(e)', 41, 41);
race('(e)',
     "UPDATE public.td SET big = 'short' WHERE id = 41",
     "UPDATE public.td SET small = 'e' WHERE id = 41");
is(reason_of(1, 41), 'stamp_mismatch', '(e) inline local value: stamp_mismatch');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# ---------------------------------------------------------------------------
# (f) Freezing keeps the xid, so frozen chunks keep their stamp: a later
#     sequential update from n2 still finds the same version and records
#     nothing.  The chunks are frozen once the TOAST table's relfrozenxid has
#     passed them; VACUUM freezes only chunks older than every running
#     snapshot, so repeat it until then.
# ---------------------------------------------------------------------------
insert_rows('(f)', 51, 55);
my $frozen_f = 0;
for (1 .. 30) {
    psql_or_bail(1, "VACUUM (FREEZE) $toast_n1");
    if (scalar_query(1, "SELECT bool_and(age(t.xmin) > age(c.relfrozenxid)) "
                      . "FROM $toast_n1 t, pg_class c WHERE c.oid = '$toast_n1'::regclass") eq 't') {
        $frozen_f = 1;
        last;
    }
    sleep(1);
}
ok($frozen_f, '(f) n1\'s TOAST chunks are frozen');
is(scalar_query(1, "SELECT count(*) FROM public.td WHERE id BETWEEN 51 AND 55 "
                 . "AND spock.toast_stamp(big) IS NOT NULL"), '5',
   '(f) frozen chunks keep their stamp');
psql_or_bail(2, "UPDATE public.td SET small = 'f' WHERE id BETWEEN 51 AND 55");
drain('(f)');
is(suspects(1, "(pkey->>'id')::int BETWEEN 51 AND 55"), '0',
   '(f) frozen local chunks: nothing recorded');

# ---------------------------------------------------------------------------
# (g) The sender cannot lock its TOAST table while decoding: it sends plain
#     'u' instead of waiting.  n2's update is made while n1 does not apply,
#     then a session on n2 holds an exclusive lock on the TOAST table's
#     index (an uncommitted REINDEX), then n1 applies.  The lookup takes that
#     lock conditionally, so it must give up instead of holding decoding.
#     Only the TOAST relation is locked: decoding opens the table itself.
# ---------------------------------------------------------------------------
insert_rows('(g)', 61, 61);
stop_apply(1, 'sub_n1_n2', '(g)');
psql_or_bail(2, "UPDATE public.td SET small = 'g' WHERE id = 61");
$locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[1], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; REINDEX TABLE $toast_n2; SELECT pg_sleep(120);" ],
    '>', \my $lock_out, '2>', \my $lock_err);
ok(poll_query_until(2, "SELECT count(*) FROM pg_locks l JOIN pg_index i ON i.indexrelid = l.relation "
                     . "WHERE i.indrelid = '$toast_n2'::regclass "
                     . "AND l.mode = 'AccessExclusiveLock' AND l.granted", '1', 30),
   '(g) the TOAST index on n2 is locked') or diag("locking session: $lock_err");
start_apply(1, 'sub_n1_n2', '(g)');
ok(poll_query_until(1, "SELECT small FROM public.td WHERE id = 61", 'g', 30),
   '(g) n1 received the update while the lock was held');
is(reason_of(1, 61), 'no_stamp', '(g) the sender fell back to plain unchanged');
end_locker();
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# ---------------------------------------------------------------------------
# (h0) A value written under the initial sync's stamp (a replication origin
#      session with an epoch timestamp, which does not replicate) is not a
#      usable stamp.  After a local update the row is newer than the
#      subscription, so only the stamp decides: no_local_stamp, never a match.
# ---------------------------------------------------------------------------
insert_rows('(h0)', 65, 65);
psql_or_bail(1, "SELECT pg_replication_origin_create('td_sync_stamp')");
psql_or_bail(1, "BEGIN; "
              . "SELECT pg_replication_origin_session_setup('td_sync_stamp'); "
              . "SELECT pg_replication_origin_xact_setup('0/0', 'epoch'); "
              . "UPDATE public.td SET big = $BIG_Z WHERE id = 65; "
              . "COMMIT; "
              . "SELECT pg_replication_origin_session_reset()");
is(scalar_query(1, "SELECT spock.toast_stamp(big) IS NULL FROM public.td WHERE id = 65"), 't',
   '(h0) the sync-stamped value has no stamp');
psql_or_bail(1, "UPDATE public.td SET small = 'h1' WHERE id = 65");
drain('(h0)');
psql_or_bail(2, "UPDATE public.td SET small = 'h2' WHERE id = 65");
drain('(h0)');
is(reason_of(1, 65), 'no_local_stamp', '(h0) recorded as no_local_stamp');

# ---------------------------------------------------------------------------
# (x) A row last written by the sender is recorded when the sender's value
#     names another node and differs here: the mesh case, where the sender
#     took the value from a third node.  With two nodes, n1 is that third
#     node: n1's big is replaced here without replicating, so n2 still holds
#     n1's earlier version.  n2's first update is cross-origin; its second
#     finds the row last written by n2.
# ---------------------------------------------------------------------------
insert_rows('(x)', 66, 66);
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); "
              . "UPDATE public.td SET big = repeat('q', 200000) WHERE id = 66; COMMIT");
psql_or_bail(2, "UPDATE public.td SET small = 'x1' WHERE id = 66");
drain('(x)');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "UPDATE public.td SET small = 'x2' WHERE id = 66");
drain('(x)');
is(reason_of(1, 66), 'stamp_mismatch', '(x) same-origin row recorded as stamp_mismatch');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# ---------------------------------------------------------------------------
# (y) A row last written by the sender is recorded only on proof: n1's
#     value is rewritten under an epoch-stamped origin session (as in (h0)),
#     which does not replicate, so n1 cannot read its stamp
#     (no_local_stamp), and that is not enough.  n2's first update finds
#     the row last written by that session; its second finds it n2's.
# ---------------------------------------------------------------------------
insert_rows('(y)', 67, 67);
psql_or_bail(1, "SELECT pg_replication_origin_create('td_epoch_y')");
psql_or_bail(1, "BEGIN; "
              . "SELECT pg_replication_origin_session_setup('td_epoch_y'); "
              . "SELECT pg_replication_origin_xact_setup('0/0', 'epoch'); "
              . "UPDATE public.td SET big = $BIG_Z WHERE id = 67; "
              . "COMMIT; "
              . "SELECT pg_replication_origin_session_reset()");
is(scalar_query(1, "SELECT spock.toast_stamp(big) IS NULL FROM public.td WHERE id = 67"), 't',
   '(y) n1 cannot read the stamp of row 67');
psql_or_bail(2, "UPDATE public.td SET small = 'y1' WHERE id = 67");
drain('(y)');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "UPDATE public.td SET small = 'y2' WHERE id = 67");
drain('(y)');
is(scalar_query(1, "SELECT small FROM public.td WHERE id = 67"), 'y2', '(y) update applied');
is(suspects(1, "pkey = jsonb_build_object('id', '67')"), '0', '(y) same-origin no_local_stamp not recorded');

# ---------------------------------------------------------------------------
# (z) VACUUM FULL on the sender gives every value there a new stamp naming
#     the sender.  Its later updates of rows it last wrote are not recorded.
# ---------------------------------------------------------------------------
insert_rows('(z)', 68, 70);
psql_or_bail(2, "UPDATE public.td SET small = 'z1' WHERE id BETWEEN 68 AND 70");
drain('(z)');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "VACUUM FULL public.td");
psql_or_bail(2, "UPDATE public.td SET small = 'z2' WHERE id BETWEEN 68 AND 70");
drain('(z)');
is(scalar_query(1, "SELECT count(*) FROM public.td WHERE id BETWEEN 68 AND 70 AND small = 'z2'"), '3',
   '(z) updates applied');
is(suspects(1, "(pkey->>'id')::int BETWEEN 68 AND 70"), '0', '(z) nothing recorded after VACUUM FULL on the sender');

# ---------------------------------------------------------------------------
# (z2) n1 throws away n2's write of a larger big after an apply error
#      (transdiscard), so n1's row stays the one n2 wrote before.  n2's next
#      update finds a same-origin row whose stamp names n2; the size differs,
#      so it is recorded.  The constraint is added on n1 only.
# ---------------------------------------------------------------------------
insert_rows('(z2)', 73, 73);
psql_or_bail(2, "UPDATE public.td SET small = 'z2a' WHERE id = 73");
drain('(z2)');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "TRUNCATE spock.exception_log");
psql_or_bail(1, "BEGIN; SET LOCAL spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.td ADD CONSTRAINT td_z2 "
              . "CHECK (id <> 73 OR length(big) <> 300000) NOT VALID; COMMIT");
is(scalar_query(2, "SELECT count(*) FROM pg_constraint WHERE conname = 'td_z2'"), '0',
   '(z2) constraint only on n1');
psql_or_bail(1, "ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard'");
psql_or_bail(1, "SELECT pg_reload_conf()");
stop_apply(1, 'sub_n1_n2', '(z2)');
psql_or_bail(2, "UPDATE public.td SET big = repeat('w', 300000) WHERE id = 73");
start_apply(1, 'sub_n1_n2', '(z2)');
ok(wait_for_exception_log(1, "table_name = 'td'"), '(z2) n2\'s write thrown away on n1');
drain('(z2)');
is(scalar_query(1, "SELECT length(big) FROM public.td WHERE id = 73"), '200000',
   '(z2) n1 kept its older big');
psql_or_bail(1, "BEGIN; SET LOCAL spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.td DROP CONSTRAINT td_z2; COMMIT");
psql_or_bail(1, "ALTER SYSTEM RESET spock.exception_behaviour");
psql_or_bail(1, "SELECT pg_reload_conf()");
stop_apply(1, 'sub_n1_n2', '(z2) reset');
start_apply(1, 'sub_n1_n2', '(z2) reset');
is(suspects(1, "pkey = jsonb_build_object('id', '73')"), '0', '(z2) nothing recorded yet');
psql_or_bail(2, "UPDATE public.td SET small = 'z2b' WHERE id = 73");
drain('(z2)');
is(scalar_query(1, "SELECT small FROM public.td WHERE id = 73"), 'z2b', '(z2) update applied');
is(reason_of(1, 73), 'stamp_mismatch', '(z2) same-origin row with a different size recorded');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# ---------------------------------------------------------------------------
# (o) Decoding a change made before the table was rewritten.  PostgreSQL
#     truncates the old file at commit and unlinks it only at the next
#     checkpoint, so it still exists, empty.  The sender must send plain
#     'u', not fail.  First VACUUM FULL, then TRUNCATE (last: it empties
#     the table).
# ---------------------------------------------------------------------------
for my $op ('VACUUM FULL public.td', 'TRUNCATE public.td') {
    my $id = $op =~ /VACUUM/ ? 88 : 89;
    insert_rows("(o) $op", $id, $id);
    stop_apply(1, 'sub_n1_n2', "(o) $op");
    psql_or_bail(2, "UPDATE public.td SET small = 'o' WHERE id = $id");
    psql_or_bail(2, $op);
    my $off_o = log_offset(2);
    start_apply(1, 'sub_n1_n2', "(o) $op");
    if ($op =~ /VACUUM/) {
        ok(poll_query_until(1, "SELECT small FROM public.td WHERE id = $id", 'o', 30),
           "(o) after $op: the earlier change arrived");
        is(reason_of(1, $id), 'no_stamp', "(o) after $op: sent without a stamp");
    }
    else {
        ok(poll_query_until(1, "SELECT count(*) FROM public.td", '0', 30),
           "(o) after $op: the earlier change and the truncate arrived");
    }
    unlike(log_since(2, $off_o), qr/could not read blocks|could not read block/,
           "(o) after $op: no read error on the sender");
}

destroy_cluster('Destroy cluster');
done_testing();
