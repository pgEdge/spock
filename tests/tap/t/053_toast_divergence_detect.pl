use strict;
use warnings;
use Test::More;
use lib '.';
use IPC::Run;
use Time::HiRes qw(time);
use SpockTest qw(
    create_cluster cross_wire destroy_cluster get_test_config
    psql_or_bail scalar_query poll_query_until
    wait_for_sub_status sync_nodes log_offset wait_for_log log_since
);

# TOAST divergence detection on REPLICA IDENTITY DEFAULT tables.
#
# When an UPDATE from another node wins a conflict and carries a TOAST column
# it did not change ('u' on the wire), this node keeps its own value for that
# column.  If this node had changed that column itself, the two nodes now
# disagree and nothing else records it.  The apply worker writes such rows to
# spock.toast_suspect; spock.toast_divergence_verify() checks them against the
# winner.
#
# Cases:
#   a  the race leaves a suspect on the node that applied the win, none on
#      the winner
#   b  an in-sync UPDATE from the same origin adds nothing (condition 5)
#   c  a second race on the same row updates the entry in place
#   d  the cap stops recording and warns once, but an existing entry is
#      still refreshed
#   e  detection off records nothing
#   f  verify() confirms a real divergence
#   g  verify() clears a suspect whose values agree
#   h  verify() marks a row deleted on the winner
#   i  verify() keeps and reports an entry it cannot check
#   t  a date key under a non-ISO DateStyle is confirmed, not cleared
#   ad without spock.toast_suspect (a failed extension update) the apply
#      worker records nothing and warns once
#   ae a key of a type the winner's search_path does not reach is checked
#   bc functions and operators another role planted in public are not
#      called
#   af verify() stops while the winner does not answer
#   bd a row is recorded although replicated DDL left the apply worker a
#      search_path that reaches a planted now()
#   ag a row a remote transaction updates twice, retried in discard mode,
#      is not recorded
#   ah a REPLICA IDENTITY FULL table is not looked at
#   al a table with no replica identity key here is not recorded, and its
#      update applies
#   ai a failure to record a row is a warning; the change still applies
#   aj a key the winner cannot read fails only its own entry
#   ak key columns named like the query's own fields, and a key of a domain
#      over jsonb, are verified
#   am verify() leaves an entry another session holds locked
#   an a local lock timeout fails a group's entries after one wait
#   ar verify() leaves an entry recorded again while it compared the row
#   aw a key matching more than one row on the winner fails its entry
#   aa a row last written before the subscription existed (initial sync)
#      is not recorded
#   at a row whose commit timestamp can no longer be read is not recorded

create_cluster(2, 'Create 2-node cluster for TOAST divergence detection');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $BIG_Z = "repeat('z', 200000)";
my $BIG_X = "repeat('x', 200000)";

# --- helpers ---------------------------------------------------------------

sub suspects {
    my ($node, $where) = @_;
    $where //= 'true';
    return scalar_query($node, "SELECT count(*) FROM spock.toast_suspect WHERE $where");
}

sub wait_for_value {
    my ($node, $query, $expected, $timeout) = @_;
    poll_query_until($node, $query, $expected, $timeout // 30);
    return scalar_query($node, $query);
}

sub drain {
    my ($label) = @_;
    ok(sync_nodes(1, 2), "$label: n1 -> n2 drained");
    ok(sync_nodes(2, 1), "$label: n2 -> n1 drained");
}

# Run $n1_sql on n1 and then $n2_sql on n2 while neither node is applying,
# so both changes are local when the other side's arrives.  n2 commits
# second, so last-update-wins picks n2's row on both nodes: n1 applies n2's
# update and is the node that may diverge.
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

# Restart both apply workers so a reloaded SIGHUP GUC is in effect there.
sub restart_apply {
    my ($label) = @_;
    for my $n (1, 2) {
        psql_or_bail($n, "SELECT pg_reload_conf()");
    }
    psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2', true)");
    psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1', true)");
    ok(wait_for_sub_status(1, 'sub_n1_n2', 'disabled'), "$label: n1 apply stopped");
    ok(wait_for_sub_status(2, 'sub_n2_n1', 'disabled'), "$label: n2 apply stopped");
    psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2', true)");
    psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1', true)");
    ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating'), "$label: n1 apply restarted");
    ok(wait_for_sub_status(2, 'sub_n2_n1', 'replicating'), "$label: n2 apply restarted");
}

# --- setup -----------------------------------------------------------------

# This test covers the queue and verify(), and several cases need entries
# for rows that did not diverge (sequential updates from two nodes).  With
# version stamps those are no longer recorded, so stamps are off here and every entry is a no_stamp one; 056 covers stamps.
for my $n (1, 2) {
    psql_or_bail($n, "ALTER SYSTEM SET spock.toast_divergence_stamps = off");
    psql_or_bail($n, "SELECT pg_reload_conf()");
}

# Auto-DDL is on in this cluster: the CREATE replicates and the table joins
# 'default' on both nodes at REPLICA IDENTITY DEFAULT.
psql_or_bail(1, "CREATE TABLE public.td (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td')", '1'),
   '1', 'table replicated to n2');
psql_or_bail(1, "INSERT INTO public.td VALUES (1, 's', $BIG_Z), (2, 's', $BIG_Z), (3, 's', $BIG_Z), (4, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT count(*) FROM public.td", '4'), '4', 'rows replicated to n2');

is(suspects(1), '0', 'queue starts empty on n1');
is(suspects(2), '0', 'queue starts empty on n2');

# ---------------------------------------------------------------------------
# (a) The race.  n1 changes big, n2 changes small later.  n2 wins; n1 applies
#     n2's UPDATE, which carries big unchanged, and keeps its own big.  n1 is
#     the node that may have diverged and must record the row.  n2 discarded
#     n1's UPDATE and holds the winning row; it records nothing.
# ---------------------------------------------------------------------------
race('(a)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 1",
     "UPDATE public.td SET small = 'b' WHERE id = 1");

is(suspects(1), '1', '(a) one suspect on the node that applied the win');
is(suspects(2), '0', '(a) none on the winner');
is(scalar_query(1, "SELECT state || '/' || attnums::text || '/' || detect_count FROM spock.toast_suspect"),
   'suspect/{3}/1', '(a) state suspect, column big (attnum 3), seen once');
is(scalar_query(1, "SELECT pkey::text FROM spock.toast_suspect"), '{"id":"1"}',
   '(a) keyed by the primary key');
is(scalar_query(1, "SELECT winner_subscription || '/' || winner_node FROM spock.toast_divergence"),
   'sub_n1_n2/n2', '(a) the view names the winning subscription and node');
is(scalar_query(1, "SELECT columns::text FROM spock.toast_divergence"), '{big}',
   '(a) the view resolves the column name');

# ---------------------------------------------------------------------------
# (b) Ordinary replication from the same origin is not a suspect.  After (a)
#     the row on n1 was last written by n2; another n2 UPDATE of a small
#     column arrives with big unchanged, and both sides already agree on big.
# ---------------------------------------------------------------------------
psql_or_bail(2, "UPDATE public.td SET small = 'b2' WHERE id = 1");
is(wait_for_value(1, "SELECT small FROM public.td WHERE id = 1", 'b2'), 'b2', '(b) update applied on n1');
is(suspects(1), '1', '(b) same-origin update recorded nothing new');
is(scalar_query(1, "SELECT detect_count FROM spock.toast_suspect"), '1', '(b) detect_count unchanged');

# ---------------------------------------------------------------------------
# (c) A second race on the same row replaces the entry rather than adding one.
# ---------------------------------------------------------------------------
race('(c)',
     "UPDATE public.td SET big = repeat('y', 200000) WHERE id = 1",
     "UPDATE public.td SET small = 'c' WHERE id = 1");
is(suspects(1), '1', '(c) still one entry');
is(scalar_query(1, "SELECT detect_count FROM spock.toast_suspect"), '2', '(c) detect_count is 2');

# ---------------------------------------------------------------------------
# (d) The cap.  With one entry present and the cap at 1, the next race records
#     nothing and the apply worker warns once.
# ---------------------------------------------------------------------------
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_max_suspects = 1");
restart_apply('(d)');
my $off_d = log_offset(1);
race('(d)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 2",
     "UPDATE public.td SET small = 'd' WHERE id = 2");
is(suspects(1), '1', '(d) cap held: no second entry');
ok(wait_for_log(1, qr/spock\.toast_suspect has reached the cap of 1 rows/, $off_d),
   '(d) apply worker warned about the cap');
# At the cap an entry the row already has is still refreshed, so it names
# the newest winner.  Row 1's entry from (a) and (c) is detected again.
my $d_ts = scalar_query(1, "SELECT extract(epoch FROM winner_ts) FROM spock.toast_suspect "
                         . "WHERE pkey = jsonb_build_object('id', '1')");
race('(d) refresh',
     "UPDATE public.td SET big = repeat('y', 200000) WHERE id = 1",
     "UPDATE public.td SET small = 'd' WHERE id = 1");
is(scalar_query(1, "SELECT detect_count || '/' || (extract(epoch FROM winner_ts) > $d_ts) "
                 . "FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '1')"),
   '3/true', '(d) at the cap: the existing entry is counted again and names the newer winner');
is(suspects(1), '1', '(d) at the cap: still one entry');
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_max_suspects");
restart_apply('(d) reset');

# ---------------------------------------------------------------------------
# (e) Detection off records nothing.
# ---------------------------------------------------------------------------
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_detection = off");
restart_apply('(e)');
race('(e)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 3",
     "UPDATE public.td SET small = 'e' WHERE id = 3");
is(suspects(1), '1', '(e) detection off: nothing recorded');
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_detection");
restart_apply('(e) reset');

# ---------------------------------------------------------------------------
# (f) verify() confirms the real divergence from (a)/(c): n1 holds 'y'*200000
#     in big, n2 holds 'z'*200000.
# ---------------------------------------------------------------------------
is(scalar_query(1, "SELECT (r).cleared || '/' || (r).confirmed || '/' || (r).remote_missing || '/' || (r).failed "
                 . "FROM spock.toast_divergence_verify() r"),
   '0/1/0/0', '(f) verify confirms one entry');
is(scalar_query(1, "SELECT state || '/' || differing::text FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '1')"),
   'confirmed/{3}', '(f) state confirmed, big differs');
is(scalar_query(1, "SELECT differing_columns::text FROM spock.toast_divergence WHERE pkey = jsonb_build_object('id', '1')"),
   '{big}', '(f) the view names the differing column');
ok(scalar_query(1, "SELECT verified_at IS NOT NULL FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '1')") eq 't',
   '(f) verified_at set');

# ---------------------------------------------------------------------------
# (g) A suspect whose values agree is cleared.  Both nodes update small on
#     row 4; neither touches big, so n1 records a suspect (different origin,
#     big unchanged) that verification finds equal.
# ---------------------------------------------------------------------------
race('(g)',
     "UPDATE public.td SET small = 'g1' WHERE id = 4",
     "UPDATE public.td SET small = 'g2' WHERE id = 4");
is(suspects(1, "pkey = jsonb_build_object('id', '4')"), '1', '(g) suspect recorded for row 4');
is(scalar_query(1, "SELECT (r).cleared || '/' || (r).confirmed FROM spock.toast_divergence_verify() r"),
   '1/0', '(g) verify clears it');
is(suspects(1, "pkey = jsonb_build_object('id', '4')"), '0', '(g) entry gone');

# ---------------------------------------------------------------------------
# (h) The winner deleted the row.  Stop n1's apply from n2 first so the
#     DELETE does not reach n1 before verification looks.
# ---------------------------------------------------------------------------
race('(h)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 2",
     "UPDATE public.td SET small = 'h' WHERE id = 2");
is(suspects(1, "pkey = jsonb_build_object('id', '2') AND state = 'suspect'"), '1', '(h) suspect recorded for row 2');
psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2', true)");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'disabled'), '(h) n1 apply from n2 stopped');
psql_or_bail(2, "DELETE FROM public.td WHERE id = 2");
is(scalar_query(1, "SELECT (r).remote_missing FROM spock.toast_divergence_verify() r"),
   '1', '(h) verify reports the row missing on the winner');
is(scalar_query(1, "SELECT state FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '2')"),
   'remote_missing', '(h) entry kept as remote_missing');
psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2', true)");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating'), '(h) n1 apply resumed');
is(wait_for_value(1, "SELECT count(*) FROM public.td WHERE id = 2", '0'), '0', '(h) the DELETE has now arrived');
is(scalar_query(1, "SELECT (r).cleared || '/' || (r).confirmed || '/' || (r).remote_missing || '/' || (r).failed "
                 . "FROM spock.toast_divergence_verify() r"),
   '0/0/0/0', '(h) remote_missing entries are not re-verified');
is(scalar_query(1, "SELECT spock.toast_divergence_clear('public.td', jsonb_build_object('id', '2'))"), 't',
   '(h) operator clears it by hand');

# ---------------------------------------------------------------------------
# (i) An entry the verifier cannot check is kept and reported: a winner
#     subscription that does not exist.
# ---------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO spock.toast_suspect (relid, pkey, attnums, winner_subid, winner_origin, winner_ts) "
              . "VALUES ('public.td'::regclass, '{\"id\": \"3\"}', '{3}', 4242, 0, now())");
is(scalar_query(1, "SELECT (r).failed FROM spock.toast_divergence_verify() r"), '1',
   '(i) verify reports one failure');
is(scalar_query(1, "SELECT state || '/' || (last_error IS NOT NULL) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '3')"),
   'suspect/true', '(i) entry kept as suspect with last_error set');
# scalar_query() squeezes out whitespace, which would hide the space this
# regex needs; run_on_node() (not exported, called by its full name) keeps
# it since this query has no embedded double quotes to trip its shell quoting.
like(SpockTest::run_on_node(1, "SELECT last_error FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '3')"),
     qr/subscription 4242/, '(i) last_error names the subscription');
psql_or_bail(1, "DELETE FROM spock.toast_suspect WHERE pkey = '{\"id\": \"3\"}'");

# ---------------------------------------------------------------------------
# (t) A date key under a non-ISO DateStyle.  n1's apply worker runs with
#     DateStyle 'SQL, DMY', so the key would render as '11/03/2026' and be
#     read back by verify() under 'ISO, MDY' as 3 November: no such row, and
#     the real divergence would be cleared.  The key must be stored in ISO
#     form and the divergence confirmed.
# ---------------------------------------------------------------------------
psql_or_bail(1, "ALTER SYSTEM SET datestyle = 'SQL, DMY'");
restart_apply('(t)');
psql_or_bail(1, "CREATE TABLE public.tdd (d date PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.tdd ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.tdd')", '1'),
   '1', '(t) table replicated to n2');
psql_or_bail(1, "INSERT INTO public.tdd VALUES ('2026-03-11', 's', $BIG_Z)");
is(wait_for_value(2, "SELECT count(*) FROM public.tdd", '1'), '1', '(t) row replicated to n2');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
race('(t)',
     "UPDATE public.tdd SET big = $BIG_X WHERE d = '2026-03-11'",
     "UPDATE public.tdd SET small = 't' WHERE d = '2026-03-11'");
is(suspects(1, "relid = 'public.tdd'::regclass AND pkey = jsonb_build_object('d', '2026-03-11')"),
   '1', '(t) key stored in ISO form despite the DMY DateStyle');
is(scalar_query(1, "SELECT (r).cleared || '/' || (r).confirmed FROM spock.toast_divergence_verify() r"),
   '0/1', '(t) verify confirms the divergence rather than clearing it');
psql_or_bail(1, "ALTER SYSTEM RESET datestyle");
restart_apply('(t) reset');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (aa) A row last written before the subscription existed is not recorded.
#      Stamp n1's copy of a row the way the initial table sync does (a
#      replication origin session with an epoch commit timestamp), and do
#      not replicate it.  n2's later update with big unchanged is then not
#      recorded on n1.  A row written after the subscription still is.
psql_or_bail(1, "INSERT INTO public.td VALUES (701, 's', $BIG_Z), (702, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(aa) rows 701 and 702 on n2');
psql_or_bail(1, "SELECT pg_replication_origin_create('td_sync_stamp')");
psql_or_bail(1, "BEGIN; "
              . "SELECT pg_replication_origin_session_setup('td_sync_stamp'); "
              . "SELECT pg_replication_origin_xact_setup('0/0', 'epoch'); "
              . "UPDATE public.td SET big = big WHERE id = 701; "
              . "COMMIT; "
              . "SELECT pg_replication_origin_session_reset()");
is(scalar_query(1, "SELECT extract(epoch FROM (spock.xact_commit_timestamp_origin(xmin)).timestamp) = 0 "
              . "FROM public.td WHERE id = 701"),
   't', '(aa) row 701 on n1 carries the sync stamp');
psql_or_bail(2, "UPDATE public.td SET small = 'aa' WHERE id IN (701, 702)");
ok(sync_nodes(2, 1), '(aa) n2\'s updates applied on n1');
is(scalar_query(1, "SELECT small FROM public.td WHERE id = 701"), 'aa', '(aa) the update reached row 701');
is(suspects(1, "pkey = jsonb_build_object('id', '701')"), '0',
   '(aa) no suspect for the row older than the subscription');
is(suspects(1, "pkey = jsonb_build_object('id', '702')"), '1',
   '(aa) a suspect for the row written after it');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (ad) Without spock.toast_suspect, as after a failed extension update;
#      renaming it on n1 stands in for that.  n2's
#      updates still apply, nothing is recorded, and the apply worker warns
#      once rather than once per row.
psql_or_bail(1, "INSERT INTO public.td VALUES (801, 's', $BIG_Z), (802, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(ad) rows 801 and 802 on n2');
psql_or_bail(1, "ALTER TABLE spock.toast_suspect RENAME TO toast_suspect_away");
my $off_ad = log_offset(1);
race('(ad)',
     "UPDATE public.td SET big = $BIG_X WHERE id IN (801, 802)",
     "UPDATE public.td SET small = 'ad' WHERE id IN (801, 802)");
is(scalar_query(1, "SELECT string_agg(small, ',' ORDER BY id) FROM public.td WHERE id IN (801, 802)"),
   'ad,ad', '(ad) n2\'s updates applied on n1');
my $log_ad = log_since(1, $off_ad);
my @warn_ad = $log_ad =~ /spock\.toast_suspect does not exist/g;
is(scalar(@warn_ad), 1, '(ad) the apply worker warned once');
unlike($log_ad, qr/could not record TOAST suspect/, '(ad) no failure per row');
psql_or_bail(1, "ALTER TABLE spock.toast_suspect_away RENAME TO toast_suspect");

# (ae) The key column's type, an enum in schema tds, is on the caller's
#      search_path but not on the winner session's.  verify() must name it
#      with its schema in the query it sends to the winner.
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "CREATE SCHEMA tds; CREATE TYPE tds.k AS ENUM ('a', 'b')");
}
psql_or_bail(1, "CREATE TABLE public.td_enum (id tds.k PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td_enum ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_enum')", '1'),
   '1', '(ae) td_enum replicated to n2');
psql_or_bail(1, "INSERT INTO public.td_enum VALUES ('a', 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(ae) row on n2');
race('(ae)',
     "UPDATE public.td_enum SET big = $BIG_X WHERE id = 'a'",
     "UPDATE public.td_enum SET small = 'ae' WHERE id = 'a'");
is(suspects(1, "relid = 'public.td_enum'::regclass"), '1', '(ae) suspect on n1');
my $ae_res = scalar_query(1, "SET search_path = tds, public; "
                         . "SELECT (r).confirmed || '/' || (r).failed FROM spock.toast_divergence_verify() r");
$ae_res =~ s/^SET//;
is($ae_res, '1/0', '(ae) verify() confirmed it instead of failing on the type name');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (bc) public is made writable, as on a cluster upgraded from PostgreSQL 14
#      or older, and td_planter creates there a convert_to(text, text) and
#      an = on varchar, both of which fail when called.  Plain SQL under the
#      default search_path calls them in place of the built-in ones;
#      verify() pins search_path, here and on the winner, and must not.
psql_or_bail(1, "CREATE TABLE public.td_vc (id varchar(10) PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td_vc ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_vc')", '1'),
   '1', '(bc) td_vc replicated to n2');
psql_or_bail(1, "INSERT INTO public.td_vc VALUES ('a', 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(bc) row on n2');
race('(bc)',
     "UPDATE public.td_vc SET big = $BIG_X WHERE id = 'a'",
     "UPDATE public.td_vc SET small = 'bc' WHERE id = 'a'");
is(suspects(1, "relid = 'public.td_vc'::regclass"), '1', '(bc) suspect on n1');
my $cfg_bc = get_test_config();
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "CREATE ROLE td_planter; GRANT CREATE ON SCHEMA public TO td_planter; "
                   . "SET ROLE td_planter; "
                   . "CREATE FUNCTION public.convert_to(text, text) RETURNS bytea LANGUAGE plpgsql AS "
                   . "\$f\$BEGIN RAISE EXCEPTION 'planted convert_to called by %', current_user; END\$f\$; "
                   . "CREATE FUNCTION public.td_vc_eq(varchar, varchar) RETURNS boolean LANGUAGE plpgsql AS "
                   . "\$f\$BEGIN RAISE EXCEPTION 'planted = called by %', current_user; END\$f\$; "
                   . "CREATE OPERATOR public.= (LEFTARG = varchar, RIGHTARG = varchar, "
                   . "FUNCTION = public.td_vc_eq)");
    my $psql = "$cfg_bc->{pg_bin}/psql -X -p $cfg_bc->{node_ports}->[$n - 1] -d $cfg_bc->{db_name}";
    like(`$psql -c "SELECT convert_to('a', 'UTF8')" 2>&1`, qr/planted convert_to called/,
         "(bc) n$n: plain SQL calls the planted convert_to");
    like(`$psql -c "SELECT 'a'::varchar = 'a'::varchar" 2>&1`, qr/planted = called/,
         "(bc) n$n: plain SQL calls the planted =");
}
is(scalar_query(1, "SELECT (r).confirmed || '/' || (r).failed FROM spock.toast_divergence_verify() r"),
   '1/0', '(bc) verify() confirmed it without calling them')
    or diag('(bc) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                 . "WHERE relid = 'public.td_vc'::regclass"));
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "DROP OPERATOR public.= (varchar, varchar); "
                   . "DROP FUNCTION public.td_vc_eq(varchar, varchar), public.convert_to(text, text); "
                   . "REVOKE CREATE ON SCHEMA public FROM td_planter; DROP ROLE td_planter");
}
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (be) The key is a domain over citext, so its equality operator is
#      citext's, outside pg_catalog.  td_planter creates an = on the domain
#      itself in public, which an exact match on the domain type would pick
#      over citext's even when the operator is named OPERATOR(public.=).
#      verify() cast the key to citext first and must not call it.
my $has_citext = scalar_query(1, "SELECT count(*) FROM pg_available_extensions WHERE name = 'citext'");
SKIP: {
    skip '(be) citext is not installed', 12 unless $has_citext eq '1';
    for my $n (1, 2) {
        psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                       . "CREATE EXTENSION citext SCHEMA public; "
                       . "CREATE DOMAIN public.td_dk AS public.citext");
    }
    psql_or_bail(1, "CREATE TABLE public.td_dom (id public.td_dk PRIMARY KEY, small text, big text); "
                  . "ALTER TABLE public.td_dom ALTER COLUMN big SET STORAGE EXTERNAL");
    is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_dom')", '1'),
       '1', '(be) td_dom replicated to n2');
    psql_or_bail(1, "INSERT INTO public.td_dom VALUES ('a', 's', $BIG_Z)");
    ok(sync_nodes(1, 2), '(be) row on n2');
    race('(be)',
         "UPDATE public.td_dom SET big = $BIG_X WHERE id = 'a'",
         "UPDATE public.td_dom SET small = 'be' WHERE id = 'a'");
    is(suspects(1, "relid = 'public.td_dom'::regclass"), '1', '(be) suspect on n1');
    my $cfg_be = get_test_config();
    for my $n (1, 2) {
        psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                       . "CREATE ROLE td_planter; GRANT CREATE ON SCHEMA public TO td_planter; "
                       . "SET ROLE td_planter; "
                       . "CREATE FUNCTION public.td_dk_eq(public.td_dk, public.td_dk) RETURNS boolean "
                       . "LANGUAGE plpgsql AS "
                       . "\$f\$BEGIN RAISE EXCEPTION 'planted domain = called by %', current_user; END\$f\$; "
                       . "CREATE OPERATOR public.= (LEFTARG = public.td_dk, RIGHTARG = public.td_dk, "
                       . "FUNCTION = public.td_dk_eq)");
        my $psql = "$cfg_be->{pg_bin}/psql -X -p $cfg_be->{node_ports}->[$n - 1] -d $cfg_be->{db_name}";
        like(`$psql -c "SET search_path = pg_catalog, pg_temp; SELECT 'a'::public.td_dk OPERATOR(public.=) 'a'::public.td_dk" 2>&1`,
             qr/planted domain = called/,
             "(be) n$n: the domain operands alone call the planted =");
    }
    is(scalar_query(1, "SELECT (r).confirmed || '/' || (r).failed FROM spock.toast_divergence_verify() r"),
       '1/0', '(be) verify() confirmed it without calling it')
        or diag('(be) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                     . "WHERE relid = 'public.td_dom'::regclass"));
    for my $n (1, 2) {
        psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                       . "DROP TABLE public.td_dom CASCADE; DROP OPERATOR public.= (public.td_dk, public.td_dk); "
                       . "DROP FUNCTION public.td_dk_eq(public.td_dk, public.td_dk); "
                       . "DROP DOMAIN public.td_dk; DROP EXTENSION citext; "
                       . "REVOKE CREATE ON SCHEMA public FROM td_planter; DROP ROLE td_planter");
    }
    psql_or_bail(1, "DELETE FROM spock.toast_suspect");
}

# (af) The winner's table is locked, so the query on it does not return.
#      verify() still stops on its statement_timeout, without waiting for
#      the lock.
my $cfg = get_test_config();
psql_or_bail(1, "INSERT INTO public.td VALUES (901, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(af) row 901 on n2');
race('(af)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 901",
     "UPDATE public.td SET small = 'af' WHERE id = 901");
is(suspects(1, "pkey = jsonb_build_object('id', '901')"), '1', '(af) suspect on n1');
my $af_locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[1], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; LOCK TABLE public.td IN ACCESS EXCLUSIVE MODE; "
    . "SELECT pg_sleep(120);" ],
    '>', \my $af_out, '2>', \my $af_err);
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(af) public.td locked on n2') or diag("locking session: $af_err");
my $af_t0 = time();
my $af_res = `$cfg->{pg_bin}/psql -X -p $cfg->{node_ports}->[0] -d $cfg->{db_name} -c "SET statement_timeout = '2s'; SELECT spock.toast_divergence_verify()" 2>&1`;
cmp_ok(time() - $af_t0, '<', 30, '(af) verify() returned while the winner was blocked');
like($af_res, qr/statement timeout/, '(af) on its statement_timeout');
psql_or_bail(2, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'td_locker'");
$af_locker->finish;
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# verify()'s counts as cleared/confirmed/remote_missing/failed.
sub vcounts {
    my ($node) = @_;
    return scalar_query($node, "SELECT format('%s/%s/%s/%s', (r).cleared, (r).confirmed, "
                             . "(r).remote_missing, (r).failed) FROM spock.toast_divergence_verify() r");
}

# A table shaped like public.td, created on n1 and replicated, with rows.
sub td_like {
    my ($label, $table, $keydef, @keys) = @_;
    psql_or_bail(1, "CREATE TABLE $table ($keydef PRIMARY KEY, small text, big text); "
                  . "ALTER TABLE $table ALTER COLUMN big SET STORAGE EXTERNAL");
    is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('$table')", '1'),
       '1', "$label: $table replicated to n2");
    for my $k (@keys) {
        psql_or_bail(1, "INSERT INTO $table VALUES ($k, 's', $BIG_Z)");
    }
    ok(sync_nodes(1, 2), "$label: rows on n2");
}

# (bd) The apply worker keeps the search_path of the last replicated DDL
#      it ran.  n2's winning transaction creates a table with tdp first on
#      its path, so n1 applies the update under that path, and n1 holds a
#      tdp.now() that fails when called, as a role with CREATE on a schema
#      could.  The hook pins search_path, so n1 still records the row.
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; CREATE SCHEMA tdp");
}
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "CREATE FUNCTION tdp.now() RETURNS timestamptz LANGUAGE plpgsql AS "
              . "\$f\$BEGIN RAISE EXCEPTION 'planted now() called by %', current_user; END\$f\$");
my $cfg_bd = get_test_config();
like(`$cfg_bd->{pg_bin}/psql -X -p $cfg_bd->{node_ports}->[0] -d $cfg_bd->{db_name} -c "SET search_path = tdp, pg_catalog; SELECT now()" 2>&1`,
     qr/planted now\(\) called/, '(bd) under that path plain SQL calls the planted now()');
td_like('(bd)', 'tdp.td_sp', 'id int', 1);
my $off_bd = log_offset(1);
race('(bd)',
     "UPDATE tdp.td_sp SET big = $BIG_X WHERE id = 1",
     "SET search_path = tdp, pg_catalog; CREATE TABLE tdp.td_sp_ddl (id int PRIMARY KEY); "
   . "UPDATE tdp.td_sp SET small = 'bd' WHERE id = 1");
is(scalar_query(1, "SELECT small FROM tdp.td_sp WHERE id = 1"), 'bd', '(bd) n2\'s update applied on n1');
is(suspects(1, "relid = 'tdp.td_sp'::regclass"), '1', '(bd) n1 recorded the row');
unlike(log_since(1, $off_bd), qr/planted now\(\) called/, '(bd) the planted now() was not called');
restart_apply('(bd)');
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; DROP SCHEMA tdp CASCADE");
}
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (ag) A remote transaction updates the same row twice, leaving big alone,
#      and fails later on n1, so n1 retries it in discard mode, each change
#      in its own subtransaction.  The row was last written by n2, so the
#      first update is not recorded (condition 5), and the second must not
#      be either: it finds the row written by this transaction.
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
td_like('(ag)', 'public.td_ag', 'id int', 1);
psql_or_bail(1, "CREATE TABLE public.td_agc (id int PRIMARY KEY, v int)");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_agc')", '1'),
   '1', '(ag) td_agc replicated to n2');
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.td_agc ADD CONSTRAINT td_agc_v CHECK (v > 0)");
psql_or_bail(2, "UPDATE public.td_ag SET small = 'ag0' WHERE id = 1");
ok(sync_nodes(2, 1), '(ag) n1 holds n2\'s row');
# That update was itself a cross-origin one, recorded with stamps off.
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "ALTER SYSTEM SET spock.exception_behaviour = 'discard'");
restart_apply('(ag)');
psql_or_bail(2, "BEGIN; "
              . "UPDATE public.td_ag SET small = 'ag1' WHERE id = 1; "
              . "UPDATE public.td_ag SET small = 'ag2' WHERE id = 1; "
              . "INSERT INTO public.td_agc VALUES (1, -1); "
              . "COMMIT");
is(wait_for_value(1, "SELECT small FROM public.td_ag WHERE id = 1", 'ag2'), 'ag2',
   '(ag) both updates applied on n1 in the retry');
is(scalar_query(1, "SELECT count(*) FROM public.td_agc"), '0', '(ag) the failing insert was discarded');
is(suspects(1, "relid = 'public.td_ag'::regclass"), '0', '(ag) nothing recorded');
psql_or_bail(1, "ALTER SYSTEM RESET spock.exception_behaviour");
restart_apply('(ag) reset');

# (ah) A REPLICA IDENTITY FULL table is not looked at: the whole old row
#      travels, so a row the update finds already holds the sender's values.
#      The table is FULL on both nodes, set without DDL replication so it
#      stays in the replication set.  n1 rewrites big with its own value
#      without replicating it, so the full old row n2 sends still matches,
#      and the row's last writer here is n1, which would otherwise be
#      recorded.
td_like('(ah)', 'public.td_full', 'id int', 1);
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "ALTER TABLE public.td_full REPLICA IDENTITY FULL");
}
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); "
              . "UPDATE public.td_full SET big = big || '' WHERE id = 1; COMMIT");
psql_or_bail(2, "UPDATE public.td_full SET small = 'ah' WHERE id = 1");
is(wait_for_value(1, "SELECT small FROM public.td_full WHERE id = 1", 'ah'), 'ah',
   '(ah) n2\'s update applied on n1');
is(suspects(1, "relid = 'public.td_full'::regclass"), '0', '(ah) nothing recorded');
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "ALTER TABLE public.td_full REPLICA IDENTITY DEFAULT");
}

# (al) The table is REPLICA IDENTITY FULL on the sender and has no replica
#      identity key here (NOTHING), so n1 finds the row by a full scan and
#      has no key to name it by.  Nothing is recorded, and the update
#      applies.  n1 rewrites big
#      with its own value without replicating it, so the full old row n2
#      sends still matches, the row's last writer here is n1, and big's
#      stamp differs from n2's.
td_like('(al)', 'public.td_al', 'id int', 1);
psql_or_bail(2, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.td_al REPLICA IDENTITY FULL");
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.td_al REPLICA IDENTITY NOTHING");
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); "
              . "UPDATE public.td_al SET big = big || '' WHERE id = 1; COMMIT");
psql_or_bail(2, "UPDATE public.td_al SET small = 'al' WHERE id = 1");
is(wait_for_value(1, "SELECT small FROM public.td_al WHERE id = 1", 'al'), 'al',
   '(al) n2\'s update applied on n1');
is(suspects(1, "relid = 'public.td_al'::regclass"), '0', '(al) nothing recorded');
psql_or_bail(2, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.td_al REPLICA IDENTITY DEFAULT");
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.td_al REPLICA IDENTITY DEFAULT");

# (ai) Recording one row fails (a constraint added to the queue table for
#      the test).  The change still applies, the failure is a warning, and
#      the other row of the same transaction is recorded.
td_like('(ai)', 'public.td_ai', 'id int', 1, 2);
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE spock.toast_suspect ADD CONSTRAINT td_ai_block "
              . "CHECK (relid <> 'public.td_ai'::regclass OR pkey <> '{\"id\": \"1\"}') NOT VALID");
my $off_ai = log_offset(1);
race('(ai)',
     "UPDATE public.td_ai SET big = $BIG_X WHERE id IN (1, 2)",
     "UPDATE public.td_ai SET small = 'ai' WHERE id IN (1, 2)");
is(scalar_query(1, "SELECT string_agg(small, ',' ORDER BY id) FROM public.td_ai"), 'ai,ai',
   '(ai) both updates applied on n1');
is(scalar_query(1, "SELECT string_agg(pkey->>'id', ',') FROM spock.toast_suspect "
                 . "WHERE relid = 'public.td_ai'::regclass"), '2', '(ai) only row 2 recorded');
like(log_since(1, $off_ai), qr/could not record TOAST suspect/, '(ai) the failure was a warning');
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE spock.toast_suspect DROP CONSTRAINT td_ai_block");
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (aj) One key the winner cannot read (an enum label added on n1 only)
#      fails only its own entry: the group's query is retried an entry at a
#      time, and the other entry of the same table is settled.
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; CREATE TYPE public.tdk AS ENUM ('a', 'b')");
}
td_like('(aj)', 'public.td_aj', 'id public.tdk', "'a'");
psql_or_bail(1, "SET spock.enable_ddl_replication = off; ALTER TYPE public.tdk ADD VALUE 'x'");
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); "
              . "INSERT INTO public.td_aj VALUES ('x', 's', $BIG_Z); COMMIT");
my $aj_sub = scalar_query(1, "SELECT sub_id FROM spock.subscription WHERE sub_name = 'sub_n1_n2'");
my $aj_n2 = scalar_query(1, "SELECT node_id FROM spock.node WHERE node_name = 'n2'");
for my $k ('a', 'x') {
    psql_or_bail(1, "INSERT INTO spock.toast_suspect "
                  . "(relid, pkey, attnums, winner_subid, winner_origin, winner_ts) "
                  . "VALUES ('public.td_aj'::regclass, '{\"id\": \"$k\"}', '{3}', $aj_sub, $aj_n2, now())");
}
is(vcounts(1), '1/0/0/1', '(aj) row a cleared, row x failed');
like(scalar_query(1, "SELECT last_error FROM spock.toast_suspect WHERE relid = 'public.td_aj'::regclass"),
     qr/invalidinputvalueforenum/, '(aj) row x failed on its key');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (ak) Key columns named like the fields the batched queries add (h0, the
#      first column's hash) and a key of a domain over jsonb, which
#      jsonb_to_record() would read as a JSON string.  verify() confirms
#      both real divergences.
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; CREATE DOMAIN public.tdj AS jsonb");
}
td_like('(ak)', 'public.td_h0', 'h0 int', 1);
td_like('(ak)', 'public.td_dj', 'k public.tdj', q{'{"a": 1}'});
race('(ak)',
     "UPDATE public.td_h0 SET big = $BIG_X; UPDATE public.td_dj SET big = $BIG_X",
     "UPDATE public.td_h0 SET small = 'ak'; UPDATE public.td_dj SET small = 'ak'");
is(suspects(1), '2', '(ak) both recorded');
is(vcounts(1), '0/2/0/0', '(ak) verify() confirms both');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

$cfg = get_test_config();

# (am) verify() does not wait for an entry another session has locked, as
#      an apply worker detecting the row again would: it settles the rest
#      and leaves that one for the next run.
td_like('(am)', 'public.td_am', 'id int', 1, 2);
race('(am)',
     "UPDATE public.td_am SET big = $BIG_X",
     "UPDATE public.td_am SET small = 'am'");
is(suspects(1, "relid = 'public.td_am'::regclass"), '2', '(am) both recorded');
my $am_locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[0], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; "
    . "SELECT 1 FROM spock.toast_suspect WHERE relid = 'public.td_am'::regclass "
    . "AND pkey = jsonb_build_object('id', '1') FOR UPDATE; SELECT pg_sleep(120);" ],
    '>', \my $am_out, '2>', \my $am_err);
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(am) entry for row 1 locked on n1') or diag("locking session: $am_err");
is(vcounts(1), '0/1/0/0', '(am) verify() confirmed row 2 only');
is(scalar_query(1, "SELECT state FROM spock.toast_suspect WHERE relid = 'public.td_am'::regclass "
                 . "AND pkey = jsonb_build_object('id', '1')"), 'suspect', '(am) row 1 left as it was');
psql_or_bail(1, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'td_locker'");
$am_locker->finish;
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (an) A local lock timeout is about the table, so the rows of a group are
#      not read again one at a time, each waiting it out: three entries fail
#      after one wait.
td_like('(an)', 'public.td_an', 'id int', 1, 2, 3);
race('(an)',
     "UPDATE public.td_an SET big = $BIG_X",
     "UPDATE public.td_an SET small = 'an'");
is(suspects(1, "relid = 'public.td_an'::regclass"), '3', '(an) three recorded');
my $an_locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[0], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; LOCK TABLE public.td_an IN ACCESS EXCLUSIVE MODE; "
    . "SELECT pg_sleep(120);" ],
    '>', \my $an_out, '2>', \my $an_err);
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(an) public.td_an locked on n1') or diag("locking session: $an_err");
my $an_t0 = time();
my $an_res = `$cfg->{pg_bin}/psql -X -A -t -p $cfg->{node_ports}->[0] -d $cfg->{db_name} -c "SET lock_timeout = '3s'; SELECT format('%s/%s/%s/%s', (r).cleared, (r).confirmed, (r).remote_missing, (r).failed) FROM spock.toast_divergence_verify() r" 2>&1`;
my $an_secs = time() - $an_t0;
$an_res =~ s/^SET\s*//;
chomp $an_res;
is($an_res, '0/0/0/3', '(an) all three failed');
cmp_ok($an_secs, '<', 9, '(an) after one lock wait, not one per row');
psql_or_bail(1, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'td_locker'");
$an_locker->finish;
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (ar) An entry cleared and recorded again while verify() was comparing is
#      a new detection, although it starts again at detect_count 1: the
#      older comparison leaves it alone.  verify() is held on a lock on n2's
#      table while the entry is replaced.
td_like('(ar)', 'public.td_ar', 'id int', 1);
race('(ar)',
     "UPDATE public.td_ar SET big = $BIG_X",
     "UPDATE public.td_ar SET small = 'ar'");
is(suspects(1, "relid = 'public.td_ar'::regclass"), '1', '(ar) recorded');
my $ar_locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[1], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; LOCK TABLE public.td_ar IN ACCESS EXCLUSIVE MODE; "
    . "SELECT pg_sleep(120);" ],
    '>', \my $ar_lout, '2>', \my $ar_lerr);
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(ar) public.td_ar locked on n2') or diag("locking session: $ar_lerr");
my $ar_verify = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-A', '-t', '-p', $cfg->{node_ports}->[0], '-d', $cfg->{db_name}, '-c',
      "SELECT format('%s/%s/%s/%s', (r).cleared, (r).confirmed, (r).remote_missing, (r).failed) "
    . "FROM spock.toast_divergence_verify() r" ],
    '>', \my $ar_vout, '2>', \my $ar_verr);
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '%toastdiv%' "
                     . "AND wait_event_type = 'Lock'", '1', 30),
   '(ar) verify()\'s query waits on the lock on n2');
psql_or_bail(1, "BEGIN; "
              . "CREATE TEMP TABLE ar_copy ON COMMIT DROP AS "
              . "SELECT * FROM spock.toast_suspect WHERE relid = 'public.td_ar'::regclass; "
              . "DELETE FROM spock.toast_suspect WHERE relid = 'public.td_ar'::regclass; "
              . "UPDATE ar_copy SET detected_at = clock_timestamp(), detect_count = 1; "
              . "INSERT INTO spock.toast_suspect SELECT * FROM ar_copy; COMMIT");
psql_or_bail(2, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'td_locker'");
$ar_locker->finish;
$ar_verify->finish;
chomp $ar_vout;
is($ar_vout, '0/0/0/0', '(ar) verify() settled nothing') or diag("verify: $ar_verr");
is(scalar_query(1, "SELECT state FROM spock.toast_suspect WHERE relid = 'public.td_ar'::regclass"),
   'suspect', '(ar) the new entry was left alone');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (aw) A key that matches more than one row on the winner fails its entry,
#      as it does on the local side.  n2's key is widened after the entry
#      was recorded, and n2 then holds a second row with the same id.
psql_or_bail(1, "CREATE TABLE public.td_aw (id int PRIMARY KEY, region int DEFAULT 0, "
              . "small text, big text); "
              . "ALTER TABLE public.td_aw ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_aw')", '1'),
   '1', '(aw) td_aw replicated to n2');
psql_or_bail(1, "INSERT INTO public.td_aw VALUES (1, 0, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(aw) row on n2');
race('(aw)',
     "UPDATE public.td_aw SET big = $BIG_X WHERE id = 1",
     "UPDATE public.td_aw SET small = 'aw' WHERE id = 1");
is(suspects(1, "relid = 'public.td_aw'::regclass"), '1', '(aw) recorded');
psql_or_bail(2, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.td_aw DROP CONSTRAINT td_aw_pkey, ADD PRIMARY KEY (id, region)");
psql_or_bail(2, "BEGIN; SELECT spock.repair_mode(true); "
              . "INSERT INTO public.td_aw VALUES (1, 1, 's', $BIG_Z); COMMIT");
is(vcounts(1), '0/0/0/1', '(aw) verify() failed the entry');
is(scalar_query(1, "SELECT last_error LIKE '%more than one row on the winning node%' "
                 . "FROM spock.toast_suspect WHERE relid = 'public.td_aw'::regclass"),
   't', '(aw) last_error says why');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (at) A local row whose commit timestamp can no longer be read is not
#      recorded: its last write is older than pg_commit_ts keeps, as for
#      every row after a pg_upgrade, so it is not a recent local write.
#      Freezing every database on n1 moves that horizon past the row.
td_like('(at)', 'public.td_at', 'id int', 1);
my $cfg_at = get_test_config();
psql_or_bail(1, "ALTER DATABASE template0 ALLOW_CONNECTIONS true");
my $at_gone = 0;
for (1 .. 30) {
    for my $db ('template0', 'template1', 'postgres', $cfg_at->{db_name}) {
        system("$cfg_at->{pg_bin}/psql", '-X', '-q', '-p', $cfg_at->{node_ports}->[0], '-d', $db,
               '-c', 'VACUUM (FREEZE)');
    }
    if (scalar_query(1, "SELECT pg_xact_commit_timestamp(xmin) IS NULL FROM public.td_at WHERE id = 1") eq 't') {
        $at_gone = 1;
        last;
    }
    sleep(1);
}
psql_or_bail(1, "ALTER DATABASE template0 ALLOW_CONNECTIONS false");
ok($at_gone, '(at) n1 no longer has the row\'s commit timestamp');
psql_or_bail(2, "UPDATE public.td_at SET small = 'at' WHERE id = 1");
ok(sync_nodes(2, 1), '(at) n2 -> n1 drained');
is(scalar_query(1, "SELECT small FROM public.td_at WHERE id = 1"), 'at', '(at) n2\'s update applied on n1');
is(suspects(1, "relid = 'public.td_at'::regclass"), '0', '(at) nothing recorded');

destroy_cluster('Destroy cluster');
done_testing();
