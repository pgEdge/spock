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
#   b   the race records stamp_mismatch with the winner's stamp, and repairs
#   c   equal bytes written separately: stamp_mismatch, cleared by verify
#   d   stamps off on the sender: plain 'u', every entry no_stamp
#   e   local value inline, remote out of line: stamp_mismatch
#   f   local chunks frozen keep their stamp: nothing recorded
#   g   the sender cannot lock its TOAST table: no_stamp, decoding not held
#   h0  a value written under the initial sync's stamp: no_local_stamp
#   h   a repair writes the value's own stamp, and the row the winner's
#   o   decoding a change made before VACUUM FULL or TRUNCATE sends 'u'
#   x   a row last written by the sender is recorded when the sender's
#       value names another node and differs here
#   y   ... but not on no_local_stamp alone
#   z   after VACUUM FULL on the sender its later updates are not recorded
#   z2  a write of the sender's thrown away here that changed the size is
#       recorded on the sender's next update
#   p   hashes do not depend on lc_monetary
#   s   a failed repair keeps the entry's state and logs no key
#   u   a repair gives up on a locked row and retries it later
#   t   a jsonb primary key is repaired
#   v   an entry whose row is gone here is deleted without asking the winner
#   w   a key that fails the batched local read fails only its own entry
#   k   two TOAST columns, in a different order on each node: each recorded
#       and repaired on its own, and a column written here after the
#       compare stops the repair
#   m   NULL values: a local NULL is recorded and repaired, and a winner's
#       NULL is written

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

sub set_repair {
    my ($node, $on, $retry) = @_;
    $retry //= 1;
    psql_or_bail($node, "ALTER SYSTEM SET spock.toast_divergence_repair = $on");
    psql_or_bail($node, "ALTER SYSTEM RESET spock.toast_divergence_interval");
    psql_or_bail($node, "ALTER SYSTEM SET spock.toast_divergence_retry_interval = $retry");
    psql_or_bail($node, "SELECT pg_reload_conf()");
    my $want = $on eq 'on' ? '1' : '0';
    ok(poll_query_until($node,
           "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'spock toast repair%'",
           $want, 30),
       "repair worker " . ($on eq 'on' ? 'running' : 'gone') . " on n$node");
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

sub verify_counts {
    my ($node) = @_;
    return scalar_query($node, "SELECT (r).cleared || '/' || (r).confirmed || '/' || (r).failed "
                             . "FROM spock.toast_divergence_verify() r");
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
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '21')",
                    '0', 30), '(b) repaired');
is(scalar_query(1, "SELECT md5(big) FROM public.td WHERE id = 21"),
   scalar_query(2, "SELECT md5(big) FROM public.td WHERE id = 21"), '(b) n1 holds n2\'s big');
set_repair(1, 'off');

# ---------------------------------------------------------------------------
# (c) Equal bytes written separately: n1 writes the value n2 already has.
#     The versions differ, so it is recorded; verification clears it without
#     writing anything.
# ---------------------------------------------------------------------------
insert_rows('(c)', 22, 22);
race('(c)',
     "UPDATE public.td SET big = $BIG_Z WHERE id = 22",
     "UPDATE public.td SET small = 'c' WHERE id = 22");
is(reason_of(1, 22), 'stamp_mismatch', '(c) recorded as stamp_mismatch');
my $xmin_c = scalar_query(1, "SELECT xmin FROM public.td WHERE id = 22");
is(verify_counts(1), '1/0/0', '(c) verify clears it');
is(scalar_query(1, "SELECT xmin FROM public.td WHERE id = 22"), $xmin_c, '(c) the row was not rewritten');

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

sub value_stamp {
    my ($node, $id) = @_;
    return scalar_query($node, "SELECT spock.toast_stamp(big) FROM public.td WHERE id = $id");
}

# Row stamp as origin@timestamp, with origin 0 shown as the node's own id so
# the two nodes can be compared.
sub row_stamp {
    my ($node, $id) = @_;
    return scalar_query($node,
        "SELECT format('%s\@%s', CASE WHEN o.roident = 0 THEN (SELECT node_id FROM spock.node_info()) "
      . "ELSE o.roident END, extract(epoch FROM o.timestamp)) "
      . "FROM public.td t, LATERAL spock.xact_commit_timestamp_origin(t.xmin) o WHERE t.id = $id");
}

# ---------------------------------------------------------------------------
# (h) A repair writes the winner's value with the value's own stamp, and the
#     row with the winner row's stamp.  Afterwards a local update on n1 and
#     a later update from n2 record nothing: n1 holds the same version.
# ---------------------------------------------------------------------------
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
insert_rows('(h)', 71, 71);
race('(h)',
     "UPDATE public.td SET big = repeat('h', 200000) WHERE id = 71",
     "UPDATE public.td SET small = 'h' WHERE id = 71");
is(reason_of(1, 71), 'stamp_mismatch', '(h) suspect on n1');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '71')",
                    '0', 30), '(h) repaired');
set_repair(1, 'off');
is(value_stamp(1, 71), value_stamp(2, 71), '(h) n1\'s value carries the value\'s own stamp');
is(row_stamp(1, 71), row_stamp(2, 71), '(h) n1\'s row carries the winner row\'s stamp');
psql_or_bail(1, "UPDATE public.td SET small = 'h1' WHERE id = 71");
drain('(h)');
psql_or_bail(2, "UPDATE public.td SET small = 'h2' WHERE id = 71");
drain('(h)');
is(suspects(1, "pkey = jsonb_build_object('id', '71')"), '0', '(h) the next cross-node update records nothing');

sub suspect_gone {
    my ($id) = @_;
    return poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect "
                             . "WHERE pkey = jsonb_build_object('id', '$id')", '0', 30);
}

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

# ---------------------------------------------------------------------------
# (p) Hashes do not depend on lc_monetary, which changes how money prints:
#     equal money[] values written separately, compared while n1 uses
#     another lc_monetary and n2 the default, are found equal.
# ---------------------------------------------------------------------------
my $MONEY = "array_fill(1234.5::numeric::money, ARRAY[40000])";
psql_or_bail(1, "CREATE TABLE public.tm (id int PRIMARY KEY, small text, m money[]); "
              . "ALTER TABLE public.tm ALTER COLUMN m SET STORAGE EXTERNAL");
ok(poll_query_until(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.tm')", '1', 30),
   '(p) table replicated to n2');
psql_or_bail(1, "INSERT INTO public.tm VALUES (1, 's', $MONEY)");
drain('(p)');
stop_apply(1, 'sub_n1_n2', '(p)');
stop_apply(2, 'sub_n2_n1', '(p)');
psql_or_bail(1, "UPDATE public.tm SET m = $MONEY WHERE id = 1");
psql_or_bail(2, "UPDATE public.tm SET small = 'p' WHERE id = 1");
start_apply(1, 'sub_n1_n2', '(p)');
start_apply(2, 'sub_n2_n1', '(p)');
drain('(p)');
psql_or_bail(1, "DELETE FROM spock.toast_suspect WHERE relid <> 'public.tm'::regclass");
is(scalar_query(1, "SELECT reason FROM spock.toast_suspect WHERE relid = 'public.tm'::regclass"),
   'stamp_mismatch', '(p) recorded as stamp_mismatch');
# Any installed locale that prints money differently from C will do; the
# check skips only on a machine with none.  scalar_query() returns psql's
# "SET" tag in front of the value.
sub money_under {
    my ($l) = @_;
    my $m = scalar_query(1, "SET lc_monetary = '$l'; SELECT 1234.5::money::text");
    $m =~ s/^SET//;
    return $m;
}
my $c_money = money_under('C');
my $p_locale = '';
for my $l (sort { ($b =~ /^de_DE/ ? 1 : 0) <=> ($a =~ /^de_DE/ ? 1 : 0) || $a cmp $b }
           split /,/, scalar_query(1,
               "SELECT string_agg(collcollate, ',') FROM pg_collation "
             . "WHERE collprovider = 'c' AND collcollate ~ '^[a-z]{2}_[A-Z]{2}\\.utf-?8\$'")) {
    my $m = money_under($l);
    if ($m ne '' && $m ne $c_money) {
        $p_locale = $l;
        last;
    }
}
SKIP: {
    diag('(p) SKIPPED: no installed locale prints money differently from C')
        if $p_locale eq '';
    skip 'no installed locale prints money differently from C', 2 if $p_locale eq '';
    psql_or_bail(1, "ALTER DATABASE $cfg->{db_name} SET lc_monetary = '$p_locale'");
    isnt(scalar_query(1, "SELECT (m)[1]::text FROM public.tm"), $c_money,
         "(p) n1 prints money under $p_locale, not as C does");
    is(verify_counts(1), '1/0/0', '(p) verify finds the values equal');
    psql_or_bail(1, "ALTER DATABASE $cfg->{db_name} RESET lc_monetary");
}

# ---------------------------------------------------------------------------
# (s) A repair that fails keeps the entry's state, and the warning leaves the
#     row's key out of the log.  A trigger on n1 only, enabled ALWAYS so it
#     fires for the worker, makes the repair fail.
# ---------------------------------------------------------------------------
insert_rows('(s)', 112, 112);
race('(s)',
     "UPDATE public.td SET big = repeat('t', 200000) WHERE id = 112",
     "UPDATE public.td SET small = 't' WHERE id = 112");
is(scalar_query(1, "SELECT state FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '112')"),
   'suspect', '(s) recorded as suspect');
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "CREATE FUNCTION public.td_block() RETURNS trigger LANGUAGE plpgsql "
              . "AS \$\$BEGIN RAISE EXCEPTION 'td_block'; END\$\$; "
              . "CREATE TRIGGER td_block BEFORE UPDATE ON public.td FOR EACH ROW "
              . "WHEN (NEW.id = 112) EXECUTE FUNCTION public.td_block(); "
              . "ALTER TABLE public.td ENABLE ALWAYS TRIGGER td_block");
my $s_off = log_offset(1);
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '112') "
                     . "AND last_error LIKE '%td_block%'", '1', 30),
   '(s) the repair fails');
set_repair(1, 'off');
is(scalar_query(1, "SELECT state FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '112')"),
   'suspect', '(s) a failed repair keeps the entry suspect');
my $s_log = log_since(1, $s_off);
like($s_log, qr/could not repair a row of relation \d+: td_block/, '(s) the failure is logged');
unlike($s_log, qr/"id": "112"/, '(s) the log does not carry the row\'s key');
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "DROP TRIGGER td_block ON public.td; DROP FUNCTION public.td_block()");
set_repair(1, 'on');
ok(suspect_gone(112), '(s) repaired once the trigger is gone');
set_repair(1, 'off');

# ---------------------------------------------------------------------------
# (u) A repair waits for a row lock only spock.toast_divergence_lock_timeout:
#     a session holding the row makes that entry fail with a lock timeout,
#     and it is repaired once the lock is gone.
# ---------------------------------------------------------------------------
insert_rows('(u)', 113, 113);
race('(u)',
     "UPDATE public.td SET big = repeat('u', 200000) WHERE id = 113",
     "UPDATE public.td SET small = 'u' WHERE id = 113");
is(reason_of(1, 113), 'stamp_mismatch', '(u) suspect on n1');
$locker_node = 1;
$locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[0], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; SELECT 1 FROM public.td WHERE id = 113 FOR UPDATE; "
    . "SELECT pg_sleep(120);" ],
    '>', \my $u_out, '2>', \my $u_err);
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(u) row 113 locked on n1') or diag("locking session: $u_err");
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_lock_timeout = '1s'");
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '113') "
                     . "AND last_error LIKE '%lock timeout%' AND state = 'suspect'", '1', 30),
   '(u) the repair gives up on the locked row');
end_locker();
$locker_node = 2;
ok(suspect_gone(113), '(u) repaired once the lock is gone');
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_lock_timeout");
set_repair(1, 'off');

# ---------------------------------------------------------------------------
# (t) A jsonb primary key.  Key values are kept as JSON strings, so the
#     batched queries must cast them back to jsonb to find the row.
# ---------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE public.tj (k jsonb PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.tj ALTER COLUMN big SET STORAGE EXTERNAL");
ok(poll_query_until(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.tj')", '1', 30),
   '(t) table replicated to n2');
psql_or_bail(1, "INSERT INTO public.tj VALUES ('{\"a\": 1}', 's', $BIG_Z)");
drain('(t)');
race('(t)',
     "UPDATE public.tj SET big = repeat('j', 200000) WHERE k = '{\"a\": 1}'",
     "UPDATE public.tj SET small = 'j' WHERE k = '{\"a\": 1}'");
is(suspects(1, "relid = 'public.tj'::regclass"), '1', '(t) suspect on n1');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.tj'::regclass",
                    '0', 30), '(t) repaired')
    or diag(scalar_query(1, "SELECT state || ' ' || coalesce(last_error, '') FROM spock.toast_suspect "
                          . "WHERE relid = 'public.tj'::regclass"));
set_repair(1, 'off');
is(scalar_query(1, "SELECT md5(big) FROM public.tj"), scalar_query(2, "SELECT md5(big) FROM public.tj"),
   '(t) n1 holds n2\'s big');

# Hand-made suspect entries on n1 naming sub_n1_n2 as the winner.
sub add_entries {
    my (@keys) = @_;
    my $values = join(', ', map { "('public.td'::regclass, '{\"id\": \"$_\"}'::jsonb, '{3}'::int2[], s.sub_id, "
                                . "s.sub_origin, now())" } @keys);
    psql_or_bail(1, "INSERT INTO spock.toast_suspect "
                  . "(relid, pkey, attnums, winner_subid, winner_origin, winner_ts) "
                  . "SELECT v.* FROM spock.subscription s, LATERAL (VALUES $values) "
                  . "v(relid, pkey, attnums, winner_subid, winner_origin, winner_ts) "
                  . "WHERE s.sub_name = 'sub_n1_n2'");
}

# ---------------------------------------------------------------------------
# (v) An entry whose row is gone here is deleted without asking the winner.
#     n2's table is locked, so a fetch from n2 would wait for as long as the
#     lock is held.
# ---------------------------------------------------------------------------
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
add_entries(9130);
$locker_node = 2;
$locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[1], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; LOCK TABLE public.td IN ACCESS EXCLUSIVE MODE; "
    . "SELECT pg_sleep(120);" ],
    '>', \my $v_out, '2>', \my $v_err);
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(v) public.td locked on n2') or diag("locking session: $v_err");
set_repair(1, 'on');
ok(suspect_gone(9130), '(v) the entry is deleted while n2 is locked');
is(scalar_query(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                 . "AND state = 'active'"), '1', '(v) n2 stayed locked throughout');
end_locker();
set_repair(1, 'off');

# ---------------------------------------------------------------------------
# (w) A key that fails the batched local read (not an integer) fails only
#     its own entry: the rest of its group is read row by row and checked.
# ---------------------------------------------------------------------------
insert_rows('(w)', 131, 132);
add_entries(131, 132, 'x');
is(scalar_query(1, "SELECT (r).cleared || '/' || (r).confirmed || '/' || (r).remote_missing || '/' || (r).failed "
                 . "FROM spock.toast_divergence_verify() r"),
   '2/0/0/1', '(w) verify clears the good keys and fails the bad one');
is(scalar_query(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', 'x') "
                 . "AND state = 'suspect' AND last_error LIKE '%invalid input syntax for type integer%'"),
   '1', '(w) the bad key keeps its state and records the error');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# ---------------------------------------------------------------------------
# (k) Two TOAST columns, in a different column order on each node.  Only the
#     column that differs is recorded, under its attnum here; a repair
#     writes each column under that value's own stamp, though the winner's
#     two values carry different ones.  And a column the fetch found equal,
#     written here before the worker locks the row, stops the repair: the
#     row would take the winner's stamp over a value the winner never had.
# ---------------------------------------------------------------------------
for my $n (1, 2) {
    my $cols = $n == 1 ? 'id int PRIMARY KEY, small text, b1 text, b2 text'
                       : 'b2 text, id int PRIMARY KEY, b1 text, small text';
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "CREATE TABLE public.td2 ($cols); "
                   . "ALTER TABLE public.td2 ALTER COLUMN b1 SET STORAGE EXTERNAL, "
                   . "ALTER COLUMN b2 SET STORAGE EXTERNAL; "
                   . "SELECT spock.repset_add_table('default', 'public.td2')");
}
sub td2 {
    my ($node, $expr, $id) = @_;
    return scalar_query($node, "SELECT $expr FROM public.td2 WHERE id = $id");
}
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "INSERT INTO public.td2 (id, small, b1, b2) "
              . "SELECT g, 's', repeat('1', 200000), repeat('2', 200000) FROM generate_series(1, 3) g");
drain('(k)');
is(scalar_query(2, "SELECT count(*) FROM public.td2"), '3', '(k) rows on n2');

# Row 1: n1 writes b1 only.
race('(k)',
     "UPDATE public.td2 SET b1 = repeat('a', 200000) WHERE id = 1",
     "UPDATE public.td2 SET small = 'k' WHERE id = 1");
is(scalar_query(1, "SELECT attnums::text FROM spock.toast_suspect "
                 . "WHERE relid = 'public.td2'::regclass AND pkey = jsonb_build_object('id', '1')"),
   '{' . scalar_query(1, "SELECT attnum FROM pg_attribute "
                       . "WHERE attrelid = 'public.td2'::regclass AND attname = 'b1'") . '}',
   '(k) row 1: only b1 recorded, under its attnum on n1');

# Row 2: n2 wrote b1 earlier, so its b1 and b2 carry different stamps; n1
# then writes both.
psql_or_bail(2, "UPDATE public.td2 SET b1 = repeat('c', 200000) WHERE id = 2");
drain('(k)');
race('(k)',
     "UPDATE public.td2 SET b1 = repeat('d', 200000), b2 = repeat('e', 200000) WHERE id = 2",
     "UPDATE public.td2 SET small = 'k' WHERE id = 2");
is(scalar_query(1, "SELECT cardinality(attnums) FROM spock.toast_suspect "
                 . "WHERE relid = 'public.td2'::regclass AND pkey = jsonb_build_object('id', '2')"),
   '2', '(k) row 2: both columns recorded');
isnt(td2(2, 'spock.toast_stamp(b1)', 2), td2(2, 'spock.toast_stamp(b2)', 2),
     '(k) row 2: n2\'s two values carry different stamps');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td2'::regclass",
                    '0', 30), '(k) both rows repaired');
set_repair(1, 'off');
for my $id (1, 2) {
    for my $c ('b1', 'b2') {
        is(td2(1, "md5($c)", $id), td2(2, "md5($c)", $id), "(k) row $id: n1 holds n2's $c");
        is(td2(1, "spock.toast_stamp($c)", $id), td2(2, "spock.toast_stamp($c)", $id),
           "(k) row $id: n1's $c carries n2's stamp for that value");
    }
}

# Row 3: CLUSTER on n1 gives both its values new stamps, so n1's write of b1
# records b1 (different) and b2 (equal, under another stamp).  A session
# holds the row; once the worker waits for it, the session writes b2.
psql_or_bail(1, "SET spock.enable_ddl_replication = off; CLUSTER public.td2 USING td2_pkey");
race('(k)',
     "UPDATE public.td2 SET b1 = repeat('f', 200000) WHERE id = 3",
     "UPDATE public.td2 SET small = 'k' WHERE id = 3");
is(scalar_query(1, "SELECT cardinality(attnums) FROM spock.toast_suspect "
                 . "WHERE relid = 'public.td2'::regclass AND pkey = jsonb_build_object('id', '3')"),
   '2', '(k) row 3: both columns recorded');
my $k_b2_winner = td2(2, 'spock.toast_stamp(b2)', 3);
my ($k_in, $k_out, $k_err) = ('', '', '');
my $k_timer = IPC::Run::timer(30);
my $k_sess = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-q', '-p', $cfg->{node_ports}->[0], '-d', $cfg->{db_name} ],
    '<', \$k_in, '>', \$k_out, '2>', \$k_err, $k_timer);
$k_in .= "BEGIN; SELECT 1 FROM public.td2 WHERE id = 3 FOR UPDATE;\n";
$k_timer->start;
$k_sess->pump while $k_out !~ /1/ && $k_sess->pumpable && !$k_timer->is_expired;
like($k_out, qr/1/, '(k) row 3 is locked') or diag("locking session: $k_err");
# A long retry interval keeps the worker from comparing again right away.
set_repair(1, 'on', 60);
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity "
                     . "WHERE application_name LIKE 'spock toast repair%' AND wait_event_type = 'Lock'",
                    '1', 30),
   '(k) the worker compared row 3 and waits to settle it');
$k_in .= "UPDATE public.td2 SET b2 = repeat('g', 200000) WHERE id = 3; COMMIT;\n\\q\n";
$k_sess->finish;
ok(poll_query_until(1, "SELECT last_error LIKE '%changed here after it was compared%' "
                     . "FROM spock.toast_suspect WHERE relid = 'public.td2'::regclass "
                     . "AND pkey = jsonb_build_object('id', '3')", 't', 30),
   '(k) row 3: the worker noticed b2 changed and wrote nothing');
set_repair(1, 'off');
is(td2(1, 'md5(b1) = md5(repeat(\'f\', 200000))', 3), 't', '(k) row 3: b1 not written');
isnt(td2(1, 'spock.toast_stamp(b2)', 3), $k_b2_winner, '(k) row 3: b2 did not get the winner\'s stamp');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
drain('(k)');
psql_or_bail(2, "DELETE FROM spock.toast_suspect");

# ---------------------------------------------------------------------------
# (m) NULL values.  Row 121: n1 sets big to NULL while n2's update leaves it
#     alone.  A NULL has no stamp, so n1 records stamp_mismatch, and the
#     repair gives n1 n2's value.  Row 122: after the race n2 sets big to
#     NULL in repair mode, so the change never reaches n1, and n1's repair
#     writes the winner's NULL.
# ---------------------------------------------------------------------------
insert_rows('(m)', 121, 122);
race('(m)',
     "UPDATE public.td SET big = NULL WHERE id = 121; "
   . "UPDATE public.td SET big = repeat('m', 200000) WHERE id = 122",
     "UPDATE public.td SET small = 'm' WHERE id IN (121, 122)");
is(reason_of(1, 121), 'stamp_mismatch', '(m) row 121: a local NULL is recorded as stamp_mismatch');
is(reason_of(1, 122), 'stamp_mismatch', '(m) row 122 recorded');
psql_or_bail(2, "BEGIN; SELECT spock.repair_mode(true); "
              . "UPDATE public.td SET big = NULL WHERE id = 122; COMMIT");
drain('(m)');
is(scalar_query(1, "SELECT big IS NULL FROM public.td WHERE id = 122"), 'f',
   '(m) row 122: n2\'s NULL did not reach n1');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey->>'id' IN ('121', '122')",
                    '0', 30), '(m) both repaired');
set_repair(1, 'off');
is(scalar_query(1, "SELECT md5(big) FROM public.td WHERE id = 121"),
   scalar_query(2, "SELECT md5(big) FROM public.td WHERE id = 121"), '(m) row 121: n1 holds n2\'s big');
is(scalar_query(1, "SELECT big IS NULL FROM public.td WHERE id = 122"), 't',
   '(m) row 122: the repair wrote the winner\'s NULL');
drain('(m)');
is(suspects(1, "pkey->>'id' IN ('121', '122')"), '0', '(m) nothing recorded again');
is(suspects(2, "pkey->>'id' IN ('121', '122')"), '0', '(m) nor on n2');

destroy_cluster('Destroy cluster');
done_testing();
