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
#   u  the repair worker drains past one batch without sleeping, and
#      entries that can only wait do not block it
#   v  the repair worker keeps its connection to the winner between passes
#   m  a newer local update that left big alone still ends on the race
#      winner's big; the other node waits for it (also p, both at once)
#   w  the same after VACUUM FULL in between
#   x  a newer local update that wrote big ends on that value
#   y  known limit: an inline losing value ends on the losing value
#   ab like m, but the winner updates the row again first: n1 detects the
#      row a second time, and n2 must still wait
#   ac a repair runs the table's triggers as the table owner
#   ao the repair worker's reads run the column type's cast as the table
#      owner, here and on the winner
#   as the repair worker keeps repairing while spock.readonly = local
#   ap the repair worker writes nothing while spock.readonly = all
#   ad without spock.toast_suspect (a failed extension update) the apply
#      worker records nothing and warns once
#   ae a key of a type the winner's search_path does not reach is checked
#   bc functions and operators another role planted in public are not
#      called by verify() or the repair worker
#   af verify() and the repair worker stop while the winner does not answer
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
#   ax a stop request during a repair pass does not wait out the
#      worker's sleep
#   z  entries naming a dropped winner subscription are removed
#   aa a row last written before the subscription existed (initial sync)
#      is not recorded
#   at a row whose commit timestamp can no longer be read is not recorded
#   au a winner row with no readable commit timestamp

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

# This test covers the queue, verify() and the repair worker, and several
# cases need entries for rows that did not diverge (sequential updates from
# two nodes).  With version stamps those are no longer recorded, so stamps
# are off here and every entry is a no_stamp one; 056 covers stamps.
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
# Phase 2: the repair worker.
# ---------------------------------------------------------------------------

sub repair_workers {
    my ($node) = @_;
    return scalar_query($node,
        "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'spock toast repair%'");
}

# Turn the worker on or off on one node and wait for the manager to act.
sub set_repair {
    my ($node, $on) = @_;
    psql_or_bail($node, "ALTER SYSTEM SET spock.toast_divergence_repair = $on");
    psql_or_bail($node, "ALTER SYSTEM RESET spock.toast_divergence_interval");
    psql_or_bail($node, "ALTER SYSTEM SET spock.toast_divergence_retry_interval = 1");
    psql_or_bail($node, "SELECT pg_reload_conf()");
    my $want = $on eq 'on' ? '1' : '0';
    ok(poll_query_until($node,
           "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'spock toast repair%'",
           $want, 30),
       "repair worker " . ($on eq 'on' ? 'running' : 'gone') . " on n$node");
}

# (j) The worker starts and stops with the GUC and acts on suspects on its
#     own, with no manual verify().  Row 3 is diverged with no entry (case
#     (e) ran with detection off).  Race it again so n1 records a suspect.
#
#     The worker verifies and repairs in one fused pass, so there is no
#     separate verify step and no intermediate 'confirmed' state to catch.
#     sub_n1_n2 is disabled while the worker runs here, so it classifies the
#     suspect as waiting and holds it: that both shows the worker acted on
#     the row without a manual verify() and leaves row 3 diverged for (k) to
#     repair.
is(repair_workers(1), '0', '(j) no repair worker while the GUC is off');
race('(j)',
     "UPDATE public.td SET big = repeat('j', 200000) WHERE id = 3",
     "UPDATE public.td SET small = 'j' WHERE id = 3");
is(suspects(1, "pkey = jsonb_build_object('id', '3')"), '1', '(j) suspect recorded for row 3');
psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2', true)");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'disabled'), '(j) n1 apply from n2 stopped');
my $off_j = log_offset(1);
set_repair(1, 'on');
# The fused pass acts on the row without a manual verify().  The winner
# subscription is disabled, so it holds the suspect (waiting) instead of
# repairing it, which keeps row 3 diverged for (k).
ok(wait_for_log(1, qr/SPOCK toast repair: .*processed [1-9]/, $off_j, 60),
   '(j) worker logged the fused pass');
is(scalar_query(1, "SELECT worker_status FROM spock.get_worker_status() "
              . "WHERE worker_type = 'toast repair'"),
   'running', '(j) worker status shows it running');
ok(poll_query_until(1,
       "SELECT state FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '3')",
       'suspect', 30),
   '(j) worker held the suspect while the winner subscription is disabled');
set_repair(1, 'off');
is(repair_workers(1), '0', '(j) worker gone after the GUC is turned off');
psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2', true)");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating'), '(j) n1 apply from n2 resumed');

sub big_md5 {
    my ($node, $id) = @_;
    return scalar_query($node, "SELECT md5(big) FROM public.td WHERE id = $id");
}
sub row_stamp {
    my ($node, $id) = @_;
    return scalar_query($node,
        "SELECT format('%s@%s', (spock.xact_commit_timestamp_origin(xmin)).roident, "
      . "(spock.xact_commit_timestamp_origin(xmin)).timestamp) FROM public.td WHERE id = $id");
}

# Origin id under which rows applied from n2 are stamped on n1.  Spock stamps
# an applied commit with the spock node id of the node the change came from --
# that is what the ORIGIN message carries and what the apply worker puts in
# replorigin_session_origin -- not with the roident of the subscription's own
# replication origin.
my $n2_origin_on_n1 = scalar_query(1,
    "SELECT node_id FROM spock.node WHERE node_name = 'n2'");
like($n2_origin_on_n1, qr/^\d+$/, 'found the origin id of sub_n1_n2 on n1');

# ---------------------------------------------------------------------------
# (k) Repair converges.  Row 3 is still a pending suspect from (j): n1 holds 'j'*200000,
#     n2 holds 'z'*200000 and won.  Start the worker; the entry must go, n1
#     must hold n2's value, and the repaired row must carry n2's origin and
#     n2's commit timestamp for that row.
# ---------------------------------------------------------------------------
# n1's row 3 already carries n2's origin and the winning UPDATE's commit
# timestamp: the apply worker stamped it that way.  Only the content of big
# is wrong, and the repair writes the same stamp back.
is((split /@/, row_stamp(1, 3))[0], $n2_origin_on_n1,
   '(k) the diverged row already carries the winner\'s origin');
my $n2_xmin_before = scalar_query(2, "SELECT xmin FROM public.td WHERE id = 3");
my $n2_resolutions_before = scalar_query(2, "SELECT count(*) FROM spock.resolutions");
my $off_k = log_offset(1);
set_repair(1, 'on');
ok(poll_query_until(1,
       "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '3')",
       '0', 30),
   '(k) entry for row 3 gone after repair');
is(big_md5(1, 3), big_md5(2, 3), '(k) both nodes hold the same big value');
is(big_md5(1, 3), scalar_query(2, "SELECT md5(repeat('z', 200000))"), '(k) and it is the winner\'s');
my ($origin, $ts) = split /@/, row_stamp(1, 3);
is($origin, $n2_origin_on_n1, '(k) repaired row carries the winner\'s origin');
my (undef, $ts_n2) = split /@/, row_stamp(2, 3);
is($ts, $ts_n2, '(k) repaired row carries the winner\'s commit timestamp');
ok(wait_for_log(1, qr/SPOCK toast repair: .*repaired [1-9]/, $off_k, 60), '(k) worker logged the repair');

# ---------------------------------------------------------------------------
# (l) The repair did not replicate: n2's row was not rewritten and n2 saw
#     no conflict.
# ---------------------------------------------------------------------------
drain('(l)');
is(scalar_query(2, "SELECT xmin FROM public.td WHERE id = 3"), $n2_xmin_before,
   '(l) winner\'s row untouched');
is(scalar_query(2, "SELECT count(*) FROM spock.resolutions"), $n2_resolutions_before,
   '(l) no new resolutions on the winner');
is(suspects(2), '0', '(l) no suspect on the winner');

# ---------------------------------------------------------------------------
# (m) The diverged node updates the row again, leaving big alone, before its
#     worker repairs it.  Its row is now the newer one, but big still holds
#     the value that lost the race, and that update reaches n2 with big
#     unchanged.  The cluster must still end on the race winner's big:
#       - n2 records its own suspect naming n1, but must not copy n1's big
#         while n1 has an older pending entry for the row: it waits;
#       - n1 repairs just big toward n2, keeping the rest of its newer row
#         and the row's own commit timestamp and origin;
#       - n2's entry then clears on equal hashes.
# ---------------------------------------------------------------------------
set_repair(1, 'off');
my $z_md5 = scalar_query(1, "SELECT md5(repeat('z', 200000))");
race('(m)',
     "UPDATE public.td SET big = repeat('m', 200000) WHERE id = 3",
     "UPDATE public.td SET small = 'm' WHERE id = 3");
is(suspects(1, "pkey = jsonb_build_object('id', '3')"), '1', '(m) suspect on n1');
is(scalar_query(1, "SELECT (r).confirmed FROM spock.toast_divergence_verify() r"), '1',
   '(m) confirmed by a manual verify');
is(scalar_query(1, "SELECT toast_ptrs[1] = spock.toast_pointer(big) "
              . "FROM spock.toast_suspect s JOIN public.td t ON t.id = 3 "
              . "WHERE s.pkey = jsonb_build_object('id', '3')"),
   't', '(m) the entry recorded the pointer of the value n1 kept');
# n1 now updates the row again: n1 is newer.  n2 applies it with big
# unchanged, keeps its own big, and records its own suspect.
psql_or_bail(1, "UPDATE public.td SET small = 'm2' WHERE id = 3");
is(wait_for_value(2, "SELECT small FROM public.td WHERE id = 3", 'm2'), 'm2', '(m) n1\'s update reached n2');
is(suspects(2, "pkey = jsonb_build_object('id', '3')"), '1', '(m) n2 recorded its own suspect');
my $m_stamp = row_stamp(1, 3);

# n2's worker alone: it must wait on n1's older entry, not copy n1's big.
my $off_m2 = log_offset(2);
set_repair(2, 'on');
ok(poll_query_until(2,
       "SELECT last_error LIKE 'waiting for node n1 to repair its older entry for this row (state confirmed, detected %' FROM spock.toast_suspect "
     . "WHERE pkey = jsonb_build_object('id', '3')", 't', 30),
   '(m) n2 waits while n1 has an older pending entry');
ok(wait_for_log(2, qr/SPOCK toast repair: .*waiting [1-9]/, $off_m2, 60), '(m) n2 logged the wait');
is(big_md5(2, 3), $z_md5, '(m) n2 did not copy n1\'s losing big');
my $m_n2_xmin = scalar_query(2, "SELECT xmin FROM public.td WHERE id = 3");
my $m_n2_res = scalar_query(2, "SELECT count(*) FROM spock.resolutions");

my $off_m = log_offset(1);
set_repair(1, 'on');
ok(poll_query_until(1,
       "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '3')",
       '0', 30),
   '(m) n1 settled its entry');
ok(wait_for_log(1, qr/SPOCK toast repair: .*repaired [1-9]/, $off_m, 60), '(m) n1 logged the repair');
is(big_md5(1, 3), $z_md5, '(m) n1 took the race winner\'s big');
is(scalar_query(1, "SELECT small FROM public.td WHERE id = 3"), 'm2', '(m) n1 kept its newer small');
is(row_stamp(1, 3), $m_stamp, '(m) n1\'s row kept its own commit timestamp and origin');
ok(poll_query_until(2,
       "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '3')",
       '0', 30),
   '(m) n2 settled its entry');
is(big_md5(2, 3), $z_md5, '(m) n2 still holds the race winner\'s big');
drain('(m)');
is(scalar_query(2, "SELECT xmin FROM public.td WHERE id = 3"), $m_n2_xmin,
   '(m) n1\'s repair did not replicate: n2\'s row untouched');
is(scalar_query(2, "SELECT count(*) FROM spock.resolutions"), $m_n2_res,
   '(m) and n2 saw no conflict');
set_repair(2, 'off');

# ---------------------------------------------------------------------------
# (n) Winner's row changed again before repair: converge on the newer value.
# ---------------------------------------------------------------------------
set_repair(1, 'off');
race('(n)',
     "UPDATE public.td SET big = repeat('n', 200000) WHERE id = 4",
     "UPDATE public.td SET small = 'n' WHERE id = 4");
is(scalar_query(1, "SELECT (r).confirmed FROM spock.toast_divergence_verify() r"), '1',
   '(n) confirmed by a manual verify');
psql_or_bail(2, "UPDATE public.td SET big = repeat('v', 200000) WHERE id = 4");
is(wait_for_value(1, "SELECT md5(big) FROM public.td WHERE id = 4",
                  scalar_query(1, "SELECT md5(repeat('v', 200000))")),
   scalar_query(1, "SELECT md5(repeat('v', 200000))"), '(n) winner\'s new value streamed to n1');
set_repair(1, 'on');
ok(poll_query_until(1,
       "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '4')",
       '0', 30),
   '(n) entry gone');
is(big_md5(1, 4), big_md5(2, 4), '(n) converged on the newer value');

# ---------------------------------------------------------------------------
# (o) Winner subscription disabled: the entry waits, then repairs after
#     re-enable.
# ---------------------------------------------------------------------------
set_repair(1, 'off');
race('(o)',
     "UPDATE public.td SET big = repeat('o', 200000) WHERE id = 4",
     "UPDATE public.td SET small = 'o' WHERE id = 4");
is(scalar_query(1, "SELECT (r).confirmed FROM spock.toast_divergence_verify() r"), '1',
   '(o) confirmed by a manual verify');
psql_or_bail(1, "SELECT spock.sub_disable('sub_n1_n2', true)");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'disabled'), '(o) sub_n1_n2 disabled');
my $off_o = log_offset(1);
set_repair(1, 'on');
ok(wait_for_log(1, qr/SPOCK toast repair: .*waiting [1-9]/, $off_o, 60), '(o) worker reported the entry waiting');
is(scalar_query(1, "SELECT state FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '4')"),
   'confirmed', '(o) entry still confirmed while the subscription is disabled');
psql_or_bail(1, "SELECT spock.sub_enable('sub_n1_n2', true)");
ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating'), '(o) sub_n1_n2 re-enabled');
ok(poll_query_until(1,
       "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '4')",
       '0', 30),
   '(o) entry repaired after re-enable');
is(big_md5(1, 4), big_md5(2, 4), '(o) converged');
set_repair(1, 'off');

# ---------------------------------------------------------------------------
# (p) Bidirectional same-row convergence.  Both nodes hold a confirmed
#     suspect for the same row (case (m)'s shape: n2 won the race so n1
#     diverged, then a newer small-only write on n1 made n2 diverge too), and
#     both repair workers run at once.  n1's newer write left big alone, so
#     they must converge on the race winner's big (n2's), not on the value
#     n1 carried forward -- and without hitting the node-against-itself
#     tiebreaker, whose "equal tiebreaker value" warning would mean the two
#     nodes swapped values instead of converging.  Repeated so the
#     interleaving where each worker reads the other's row first is hit.
#
#     Why it converges: n1's entry comes from the race (older winning write),
#     n2's from n1's later write.  n2's worker sees n1's older pending entry
#     on the winner and waits.  n1's worker finds big's pointer unchanged
#     since detection, so it writes n2's big and keeps its newer row's stamp.
#     n2's entry then clears on equal hashes.  Neither reaches the
#     tiebreaker, and neither waits on the other: n1 ignores n2's newer
#     entry.
# ---------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.td VALUES (5, 's', repeat('q', 200000))");
is(wait_for_value(2, "SELECT count(*) FROM public.td WHERE id = 5", '1'), '1',
   '(p) row 5 replicated to n2');

my $q_big = scalar_query(1, "SELECT md5(repeat('q', 200000))");

sub p_cycle {
    my ($label) = @_;

    # Clean slate: workers off, row 5 back to a common baseline, no suspects.
    set_repair(1, 'off');
    set_repair(2, 'off');
    psql_or_bail(1, "UPDATE public.td SET small = 's', big = repeat('q', 200000) WHERE id = 5");
    is(wait_for_value(2, "SELECT md5(big) FROM public.td WHERE id = 5",
                      scalar_query(1, "SELECT md5(repeat('q', 200000))")),
       scalar_query(1, "SELECT md5(repeat('q', 200000))"), "$label baseline on n2");
    drain($label);
    psql_or_bail(1, "DELETE FROM spock.toast_suspect");
    psql_or_bail(2, "DELETE FROM spock.toast_suspect");

    # n2 wins the race; n1 keeps its own big and records a suspect naming n2.
    race($label,
         "UPDATE public.td SET big = repeat('p', 200000) WHERE id = 5",
         "UPDATE public.td SET small = 'p' WHERE id = 5");

    # A newer small-only write on n1: n2 applies it, keeps its big, records
    # its own suspect naming n1.  n1 is now the newer writer of this row.
    psql_or_bail(1, "UPDATE public.td SET small = 'p2' WHERE id = 5");
    is(wait_for_value(2, "SELECT small FROM public.td WHERE id = 5", 'p2'), 'p2',
       "$label n1's newer write reached n2");

    # Confirm both suspects before enabling repair.
    is(scalar_query(1, "SELECT (r).confirmed FROM spock.toast_divergence_verify() r"), '1',
       "$label n1's suspect confirmed");
    is(scalar_query(2, "SELECT (r).confirmed FROM spock.toast_divergence_verify() r"), '1',
       "$label n2's suspect confirmed");
    is(suspects(1, "pkey = jsonb_build_object('id', '5') AND state = 'confirmed'"), '1',
       "$label confirmed suspect on n1");
    is(suspects(2, "pkey = jsonb_build_object('id', '5') AND state = 'confirmed'"), '1',
       "$label confirmed suspect on n2");

    # Both workers on at once, no ordering between them.
    my $o1 = log_offset(1);
    my $o2 = log_offset(2);
    set_repair(1, 'on');
    set_repair(2, 'on');

    ok(poll_query_until(1,
           "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '5')",
           '0', 30),
       "$label n1 settled its entry");
    ok(poll_query_until(2,
           "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '5')",
           '0', 30),
       "$label n2 settled its entry");

    is(wait_for_value(1, "SELECT md5(big) FROM public.td WHERE id = 5", $q_big), $q_big,
       "$label n1 converged on the race winner's big");
    is(big_md5(1, 5), big_md5(2, 5), "$label both nodes hold the same big value");
    is(scalar_query(1, "SELECT small FROM public.td WHERE id = 5"), 'p2',
       "$label n1 kept its newer small");
    unlike(log_since(1, $o1), qr/equal tiebreaker value/,
           "$label no node-against-itself tiebreaker on n1");
    unlike(log_since(2, $o2), qr/equal tiebreaker value/,
           "$label no node-against-itself tiebreaker on n2");
}

p_cycle("(p) cycle 1:");
p_cycle("(p) cycle 2:");
p_cycle("(p) cycle 3:");
set_repair(1, 'off');
set_repair(2, 'off');

# ---------------------------------------------------------------------------
# (q) Hot row.  A single row that keeps re-diverging must collapse onto one
#     queue entry (dedup by (relation, key)), not pile up, and the worker
#     must converge it once the churn stops -- and survive the churn.  With
#     repair off, race the same row several times so n1 re-detects it each
#     time; then turn repair on with the churn stopped and let it settle.
# ---------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.td VALUES (6, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT count(*) FROM public.td WHERE id = 6", '1'), '1',
   '(q) row 6 replicated to n2');
set_repair(1, 'off'); # detection stays on; no repair during churn

for my $i (1 .. 4)
{
    # n1 changes big but loses; n2 wins with a small-only change, so n1
    # keeps its own big and re-detects row 6 as diverged each pass.
    race("(q iter $i)",
         "UPDATE public.td SET big = repeat('$i', 200000) WHERE id = 6",
         "UPDATE public.td SET small = 'h$i' WHERE id = 6");
}

# Dedup: one entry for the row no matter how many times it re-diverged, and
# detect_count reflects the repeated detection collapsing onto that entry.
is(suspects(1, "pkey = jsonb_build_object('id', '6')"), '1',
   '(q) one entry despite repeated divergence');
cmp_ok(scalar_query(1, "SELECT detect_count FROM spock.toast_suspect "
                     . "WHERE pkey = jsonb_build_object('id', '6')"),
       '>=', 2, '(q) detect_count climbed onto the single entry');

# Churn stopped: the worker converges the hot row and clears the entry.
set_repair(1, 'on');
ok(poll_query_until(1,
      "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '6')",
      '0', 60),
   '(q) entry cleared after the churn stopped');
is(big_md5(1, 6), big_md5(2, 6), '(q) hot row converged on both nodes');
is(repair_workers(1), '1', '(q) repair worker survived the churn');
set_repair(1, 'off');

# ---------------------------------------------------------------------------
# (r) The hash guard clears an already-converged suspect with no value repair.
#     Manufacture a suspect (race, n2 wins), then bring both sides' big into
#     agreement by an ordinary n2->n1 update that carries the value in full.
#     The stale suspect entry stays (a same-origin update records nothing new),
#     but the two nodes now hold the same big.  The fused pass hashes the local
#     row against the winner, finds them equal, and drops the entry without
#     fetching or writing a value: cleared >= 1, repaired 0 for that pass.
# ---------------------------------------------------------------------------
# Start from an empty queue so the pass count reflects just this one entry.
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "INSERT INTO public.td VALUES (7, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT count(*) FROM public.td WHERE id = 7", '1'), '1',
   '(r) row 7 replicated to n2');
# n2 wins; n1 keeps its own big and records a suspect naming n2.
race('(r)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 7",
     "UPDATE public.td SET small = 'r' WHERE id = 7");
is(suspects(1, "pkey = jsonb_build_object('id', '7')"), '1', '(r) suspect recorded for row 7');
# An ordinary update from n2 carries big in full; n1 applies it (same origin,
# no conflict) and both sides now hold the same big.  The stale suspect stays.
psql_or_bail(2, "UPDATE public.td SET big = repeat('r', 200000) WHERE id = 7");
is(wait_for_value(1, "SELECT md5(big) FROM public.td WHERE id = 7",
                  scalar_query(1, "SELECT md5(repeat('r', 200000))")),
   scalar_query(1, "SELECT md5(repeat('r', 200000))"),
   '(r) n2 carried big to n1: both sides converged');
is(suspects(1, "pkey = jsonb_build_object('id', '7')"), '1',
   '(r) stale suspect still present after the same-origin update');
is(big_md5(1, 7), big_md5(2, 7), '(r) both nodes hold the same big before repair');
# Enable repair: the hash guard clears the converged entry without a repair.
my $off_r = log_offset(1);
set_repair(1, 'on');
ok(poll_query_until(1,
       "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '7')",
       '0', 30),
   '(r) entry for row 7 gone after repair');
is(big_md5(1, 7), big_md5(2, 7), '(r) still converged after the pass');
ok(wait_for_log(1, qr/SPOCK toast repair: processed \d+ \| repaired 0, cleared [1-9]/, $off_r, 60),
   '(r) the pass logged cleared >= 1 with repaired 0 (guard, no value repair)');
set_repair(1, 'off');

# ---------------------------------------------------------------------------
# (s) A genuine divergence still repairs under fusion.  Same (k) shape: n2
#     wins the race so n1 keeps its own big and truly differs from the winner.
#     The fused pass fetches the winner and rewrites the row: repaired >= 1.
# ---------------------------------------------------------------------------
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "INSERT INTO public.td VALUES (8, 's', $BIG_Z)");
is(wait_for_value(2, "SELECT count(*) FROM public.td WHERE id = 8", '1'), '1',
   '(s) row 8 replicated to n2');
race('(s)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 8",
     "UPDATE public.td SET small = 's' WHERE id = 8");
is(suspects(1, "pkey = jsonb_build_object('id', '8')"), '1', '(s) suspect recorded for row 8');
isnt(big_md5(1, 8), big_md5(2, 8), '(s) the two nodes really differ before repair');
my $off_s = log_offset(1);
set_repair(1, 'on');
ok(poll_query_until(1,
       "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '8')",
       '0', 30),
   '(s) entry for row 8 gone after repair');
is(big_md5(1, 8), big_md5(2, 8), '(s) both nodes hold the same big');
is(big_md5(1, 8), scalar_query(2, "SELECT md5(repeat('z', 200000))"), '(s) and it is the winner\'s');
ok(wait_for_log(1, qr/SPOCK toast repair: .*repaired [1-9]/, $off_s, 60),
   '(s) the pass logged a value repair (repaired >= 1)');
set_repair(1, 'off');

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

# ---------------------------------------------------------------------------
# (u) The worker drains a queue larger than one batch without sleeping
#     between passes, and entries it can only leave waiting do not block the
#     rest.  Batch 5, interval one hour: 20 clean suspects must all clear
#     within seconds, past 6 older entries with no winner subscription (the
#     shape a forwarded change leaves), which must stay.
# ---------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO spock.toast_suspect "
              . "(relid, pkey, attnums, winner_subid, winner_origin, winner_ts, detected_at) "
              . "SELECT 'public.td'::regclass, jsonb_build_object('id', (100 + g)::text), '{3}', "
              . "0, 0, now(), now() - interval '1 hour' FROM generate_series(1, 6) g");
psql_or_bail(1, "INSERT INTO public.td SELECT g, 's', $BIG_Z FROM generate_series(201, 220) g");
ok(sync_nodes(1, 2), '(u) rows 201..220 on n2');
# n1 wrote these rows, so n2's small-only update is recorded on n1; the
# values agree, so each entry just clears.
psql_or_bail(2, "UPDATE public.td SET small = 'u' WHERE id BETWEEN 201 AND 220");
ok(sync_nodes(2, 1), '(u) n2 updates applied on n1');
is(suspects(1, "winner_subid <> 0"), '20', '(u) 20 clean suspects recorded');
is(suspects(1, "winner_subid = 0"), '6', '(u) 6 waiting entries ahead of them');

psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_batch = 5");
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_interval = '1h'");
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_repair = on");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE winner_subid <> 0", '0', 30),
   '(u) all 20 cleared in back-to-back passes');
is(suspects(1, "winner_subid = 0"), '6', '(u) the waiting entries are left alone');
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_batch");
set_repair(1, 'off');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# ---------------------------------------------------------------------------
# (v) The worker keeps its connection to the winner between passes, and
#     closes it every pass with spock.toast_divergence_conn_lifetime = 0 and
#     when it stops.  Each round records one clean suspect for a new row and
#     waits for the pass that clears it to finish (its log line comes after
#     the pass has returned or closed its connections).
# ---------------------------------------------------------------------------
my $WORKER_CONN = "SELECT string_agg(pid::text, ',') FROM pg_stat_activity "
                . "WHERE application_name LIKE '%toastdiv%'";
my $v_id = 300;
sub v_round {
    my ($label) = @_;
    $v_id++;
    psql_or_bail(1, "INSERT INTO public.td VALUES ($v_id, 's', $BIG_Z)");
    ok(sync_nodes(1, 2), "$label: row $v_id on n2");
    my $off = log_offset(1);
    psql_or_bail(2, "UPDATE public.td SET small = 'v' WHERE id = $v_id");
    ok(sync_nodes(2, 1), "$label: update applied on n1");
    ok(wait_for_log(1, qr/SPOCK toast repair: processed 1 .*cleared 1/, $off, 30),
       "$label: the pass cleared the entry");
}

set_repair(1, 'on');
v_round('(v) first');
my $v_pid = scalar_query(2, $WORKER_CONN);
like($v_pid, qr/^\d+$/, '(v) one worker connection open on n2 after the pass');
v_round('(v) second');
is(scalar_query(2, $WORKER_CONN), $v_pid, '(v) the next pass reused it');

psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_conn_lifetime = 0");
psql_or_bail(1, "SELECT pg_reload_conf()");
v_round('(v) lifetime 0');
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '%toastdiv%'",
                    '0', 30),
   '(v) with conn_lifetime 0 the connection is closed after the pass');
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_conn_lifetime");
psql_or_bail(1, "SELECT pg_reload_conf()");
v_round('(v) reopened');
like(scalar_query(2, $WORKER_CONN), qr/^\d+$/, '(v) a connection is kept again');
# A winner backend that dies leaves a dead handle in the cache: the next
# pass finds it broken before using it (conn_cache_prune()), drops it and
# connects again.
my $v_old = scalar_query(2, $WORKER_CONN);
psql_or_bail(2, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
              . "WHERE application_name LIKE '%toastdiv%'");
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '%toastdiv%'",
                    '0', 30),
   '(v) the winner backend is gone');
v_round('(v) after the winner backend died');
my $v_new = scalar_query(2, $WORKER_CONN);
like($v_new, qr/^\d+$/, '(v) a connection is open again');
isnt($v_new, $v_old, '(v) and it is a new one');
set_repair(1, 'off');
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '%toastdiv%'",
                    '0', 30),
   '(v) the connection closes when the worker stops');

# ---------------------------------------------------------------------------
# Cases (w) to (y) start like (m): n2 wins a race on a new row, so n1 keeps
# its own big, and then n1 updates the row again before any repair.  Workers
# are off until the row is set up.
# ---------------------------------------------------------------------------
sub lost_update_setup {
    my ($label, $id, $n1_big, $n1_later) = @_;
    set_repair(1, 'off');
    set_repair(2, 'off');
    psql_or_bail(1, "INSERT INTO public.td VALUES ($id, 's', $BIG_Z)");
    ok(sync_nodes(1, 2), "$label: row $id on n2");
    race($label,
         "UPDATE public.td SET big = $n1_big WHERE id = $id",
         "UPDATE public.td SET small = 'r' WHERE id = $id");
    is(suspects(1, "pkey = jsonb_build_object('id', '$id')"), '1', "$label: suspect on n1");
    psql_or_bail(1, "UPDATE public.td SET $n1_later WHERE id = $id");
    drain($label);
}

sub settled_on_both {
    my ($label, $id) = @_;
    for my $n (1, 2) {
        ok(poll_query_until($n,
               "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '$id')",
               '0', 30),
           "$label: n$n settled its entry");
    }
}

# (w) VACUUM FULL on n1 between detection and repair keeps big's pointer, so
#     n1 still knows big was not written since and takes the winner's.
lost_update_setup('(w)', 401, "repeat('w', 200000)", "small = 'w2'");
psql_or_bail(1, "VACUUM FULL public.td");
is(scalar_query(1, "SELECT toast_ptrs[1] = spock.toast_pointer(big) "
              . "FROM spock.toast_suspect s JOIN public.td t ON t.id = 401 "
              . "WHERE s.pkey = jsonb_build_object('id', '401')"),
   't', '(w) the pointer survived VACUUM FULL');
set_repair(1, 'on');
set_repair(2, 'on');
settled_on_both('(w)', 401);
is(big_md5(1, 401), $z_md5, '(w) n1 took the race winner\'s big');
is(big_md5(2, 401), $z_md5, '(w) n2 kept it');

# (x) n1's later update writes big itself.  That value is the newest, so n1
#     drops its entry and both nodes end on it.  The update carried big in
#     full, so n2 has nothing to suspect.
lost_update_setup('(x)', 402, "repeat('x', 200000)",
                  "small = 'x2', big = repeat('k', 200000)");
my $k_md5 = scalar_query(1, "SELECT md5(repeat('k', 200000))");
my $off_x = log_offset(1);
set_repair(1, 'on');
set_repair(2, 'on');
settled_on_both('(x)', 402);
ok(wait_for_log(1, qr/SPOCK toast repair: .*cleared [1-9]/, $off_x, 60),
   '(x) n1 dropped its entry');
is(big_md5(1, 402), $k_md5, '(x) n1 kept the big it wrote later');
is(big_md5(2, 402), $k_md5, '(x) n2 holds it too');

# (y) Known limit: the value n1 kept is small enough to be stored inline, so
#     it has no TOAST pointer to compare.  n1's later update then carries it
#     in full, n2 takes it with nothing to flag, and n1 drops its entry.  The
#     nodes agree, on n1's value rather than the race winner's.
lost_update_setup('(y)', 403, "'short'", "small = 'y2'");
is(scalar_query(1, "SELECT toast_ptrs[1] IS NULL FROM spock.toast_suspect "
              . "WHERE pkey = jsonb_build_object('id', '403')"),
   't', '(y) no pointer recorded for an inline value');
set_repair(1, 'on');
set_repair(2, 'on');
settled_on_both('(y)', 403);
is(scalar_query(1, "SELECT big FROM public.td WHERE id = 403"), 'short', '(y) n1 holds its own value');
is(scalar_query(2, "SELECT big FROM public.td WHERE id = 403"), 'short', '(y) n2 took it');
set_repair(1, 'off');
set_repair(2, 'off');

# (ab) As in (m), then n2 updates small again, leaving big alone.  n1
#      detects the row a second time and its entry's winner_ts moves to that
#      newer update.  n2's wait compares the oldest winner timestamp of n1's
#      entry, so n2 still waits instead of copying n1's losing big.
lost_update_setup('(ab)', 404, "repeat('b', 200000)", "small = 'ab2'");
is(suspects(2, "pkey = jsonb_build_object('id', '404')"), '1', '(ab) n2 recorded its own suspect');
psql_or_bail(2, "UPDATE public.td SET small = 'ab3' WHERE id = 404");
drain('(ab)');
is(scalar_query(1, "SELECT detect_count || '/' || (first_winner_ts < winner_ts) FROM spock.toast_suspect "
              . "WHERE pkey = jsonb_build_object('id', '404')"),
   '2/true', '(ab) n1 detected the row again and kept its first winner timestamp');
set_repair(2, 'on');
ok(poll_query_until(2,
       "SELECT last_error LIKE 'waiting for node n1 to repair its older entry for this row%' "
     . "FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '404')", 't', 30),
   '(ab) n2 still waits for n1');
is(big_md5(2, 404), $z_md5, '(ab) n2 did not copy n1\'s losing big');
set_repair(1, 'on');
settled_on_both('(ab)', 404);
is(big_md5(1, 404), $z_md5, '(ab) n1 took the race winner\'s big');
is(big_md5(2, 404), $z_md5, '(ab) n2 kept it');
set_repair(1, 'off');
set_repair(2, 'off');

# (ac) The repair write runs as the table owner, as the apply worker does,
#      so code it runs cannot act as the superuser the worker connects as.
#      td_own belongs to a plain role and has an ALWAYS trigger that fails
#      any write in replica mode made by another user.
psql_or_bail(1, "CREATE TABLE public.td_own (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td_own ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_own')", '1'),
   '1', '(ac) td_own replicated to n2');
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "CREATE ROLE td_owner; "
                   . "ALTER TABLE public.td_own OWNER TO td_owner; "
                   . "CREATE FUNCTION public.td_owner_only() RETURNS trigger LANGUAGE plpgsql AS "
                   . "\$f\$BEGIN IF current_setting('session_replication_role') = 'replica' "
                   . "AND current_user <> 'td_owner' THEN "
                   . "RAISE EXCEPTION 'td_own written as %', current_user; END IF; "
                   . "RETURN NEW; END\$f\$; "
                   . "CREATE TRIGGER td_own_who BEFORE UPDATE ON public.td_own "
                   . "FOR EACH ROW EXECUTE FUNCTION public.td_owner_only(); "
                   . "ALTER TABLE public.td_own ENABLE ALWAYS TRIGGER td_own_who");
}
psql_or_bail(1, "INSERT INTO public.td_own VALUES (1, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(ac) row on n2');
race('(ac)',
     "UPDATE public.td_own SET big = $BIG_X WHERE id = 1",
     "UPDATE public.td_own SET small = 'ac' WHERE id = 1");
is(suspects(1, "relid = 'public.td_own'::regclass"), '1', '(ac) suspect on n1');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_own'::regclass",
                    '0', 30), '(ac) repaired')
    or diag('(ac) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                 . "WHERE relid = 'public.td_own'::regclass"));
is(scalar_query(1, "SELECT md5(big) FROM public.td_own WHERE id = 1"),
   scalar_query(2, "SELECT md5(big) FROM public.td_own WHERE id = 1"), '(ac) n1 holds the winner\'s big');
set_repair(1, 'off');

# (ao) The repair worker's reads run as the table owner too, here and on
#      the winner: they cast the suspect columns to text, and a type's owner
#      can define that cast.  big is of a composite type with a cast to text
#      that fails when the repair worker, or its connection to the winner,
#      calls it as anyone but td_owner.  A role outside td_owner's cannot
#      use spock.toast_read_as_owner() to read the table as td_owner.
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "CREATE TYPE public.td_box AS (v text); "
                   . "CREATE FUNCTION public.td_box_text(public.td_box) RETURNS text LANGUAGE plpgsql AS "
                   . "\$f\$BEGIN IF (current_setting('application_name') LIKE 'spock toast repair%' "
                   . "OR current_setting('application_name') LIKE '%toastdiv') "
                   . "AND current_user <> 'td_owner' THEN "
                   . "RAISE EXCEPTION 'td_box cast run as %', current_user; END IF; "
                   . "RETURN textin(record_out(\$1)); END\$f\$; "
                   . "CREATE CAST (public.td_box AS text) WITH FUNCTION public.td_box_text(public.td_box); "
                   . "ALTER TYPE public.td_box OWNER TO td_owner; "
                   . "ALTER FUNCTION public.td_box_text(public.td_box) OWNER TO td_owner");
}
psql_or_bail(1, "CREATE TABLE public.td_boxed (id int PRIMARY KEY, small text, big public.td_box); "
              . "ALTER TABLE public.td_boxed ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_boxed')", '1'),
   '1', '(ao) td_boxed replicated to n2');
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "ALTER TABLE public.td_boxed OWNER TO td_owner");
}
psql_or_bail(1, "INSERT INTO public.td_boxed VALUES (1, 's', ROW($BIG_Z))");
ok(sync_nodes(1, 2), '(ao) row on n2');
race('(ao)',
     "UPDATE public.td_boxed SET big = ROW($BIG_X) WHERE id = 1",
     "UPDATE public.td_boxed SET small = 'ao' WHERE id = 1");
is(suspects(1, "relid = 'public.td_boxed'::regclass"), '1', '(ao) suspect on n1');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_boxed'::regclass",
                    '0', 30), '(ao) repaired')
    or diag('(ao) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                 . "WHERE relid = 'public.td_boxed'::regclass"));
is(scalar_query(1, "SELECT md5((big).v) FROM public.td_boxed WHERE id = 1"),
   scalar_query(2, "SELECT md5((big).v) FROM public.td_boxed WHERE id = 1"), '(ao) n1 holds the winner\'s big');
set_repair(1, 'off');
psql_or_bail(2, "SET spock.enable_ddl_replication = off; "
              . "CREATE ROLE td_nobody; GRANT USAGE ON SCHEMA spock TO td_nobody; "
              . "GRANT EXECUTE ON FUNCTION spock.toast_read_as_owner(regclass, text, jsonb, integer) TO td_nobody");
my $cfg_ao = get_test_config();
my $ao_res = `$cfg_ao->{pg_bin}/psql -X -p $cfg_ao->{node_ports}->[1] -d $cfg_ao->{db_name} -c "SET ROLE td_nobody; SELECT * FROM spock.toast_read_as_owner('public.td_boxed', 'SELECT 1', '{}', 0) AS q(x integer)" 2>&1`;
like($ao_res, qr/permission denied to read table "td_boxed" as its owner/,
     '(ao) a role outside the owner\'s cannot read as the owner');

# (ap) With spock.readonly = all the repair worker writes nothing, as the
#      apply workers apply nothing; the entry is repaired once the mode ends.
psql_or_bail(1, "INSERT INTO public.td VALUES (950, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(ap) row 950 on n2');
race('(ap)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 950",
     "UPDATE public.td SET small = 'ap' WHERE id = 950");
is(suspects(1, "pkey = jsonb_build_object('id', '950')"), '1', '(ap) suspect on n1');
psql_or_bail(1, "ALTER SYSTEM SET spock.readonly = 'all'");
psql_or_bail(1, "SELECT pg_reload_conf()");
my $off_ap = log_offset(1);
set_repair(1, 'on');
ok(wait_for_log(1, qr/repairs paused/, $off_ap), '(ap) the repair worker paused');
is(suspects(1, "pkey = jsonb_build_object('id', '950')"), '1', '(ap) entry kept while read-only');
isnt(big_md5(1, 950), big_md5(2, 950), '(ap) row not repaired while read-only');
psql_or_bail(1, "ALTER SYSTEM RESET spock.readonly");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '950')",
                    '0', 30), '(ap) repaired after the mode ended');
is(big_md5(1, 950), big_md5(2, 950), '(ap) n1 holds the winner\'s big');
set_repair(1, 'off');
ok(wait_for_sub_status(1, 'sub_n1_n2', 'replicating'), '(ap) n1 apply running again');

# (as) With spock.readonly = local the repair worker still repairs, as the
#      apply workers still apply.  Its reads and writes run as the table
#      owner, a plain role the read-only check would otherwise stop.
psql_or_bail(1, "INSERT INTO public.td_own VALUES (2, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(as) row on n2');
race('(as)',
     "UPDATE public.td_own SET big = $BIG_X WHERE id = 2",
     "UPDATE public.td_own SET small = 'as' WHERE id = 2");
is(suspects(1, "relid = 'public.td_own'::regclass"), '1', '(as) suspect on n1');
psql_or_bail(1, "ALTER SYSTEM SET spock.readonly = 'local'");
psql_or_bail(1, "SELECT pg_reload_conf()");
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_own'::regclass",
                    '0', 30), '(as) repaired while read-only for local sessions')
    or diag('(as) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                 . "WHERE relid = 'public.td_own'::regclass"));
is(scalar_query(1, "SELECT md5(big) FROM public.td_own WHERE id = 2"),
   scalar_query(2, "SELECT md5(big) FROM public.td_own WHERE id = 2"), '(as) n1 holds the winner\'s big');
set_repair(1, 'off');
psql_or_bail(1, "ALTER SYSTEM RESET spock.readonly");
psql_or_bail(1, "SELECT pg_reload_conf()");

# (aa) A row last written before the subscription existed is not recorded.
#      Stamp n1's copy of a row the way the initial table sync does (a
#      replication origin session with an epoch commit timestamp), and do
#      not replicate it.  n2's later update with big unchanged is then not
#      recorded on n1.  A row written after the subscription still is.
set_repair(1, 'off');
set_repair(2, 'off');
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
#      verify() and the repair worker pin search_path, here and on the
#      winner, and must not.
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
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_vc'::regclass",
                    '0', 30), '(bc) the repair worker repaired it without calling them')
    or diag('(bc) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                 . "WHERE relid = 'public.td_vc'::regclass"));
is(scalar_query(1, "SELECT md5(big) FROM public.td_vc WHERE id::text = 'a'"),
   scalar_query(2, "SELECT md5(big) FROM public.td_vc WHERE id::text = 'a'"),
   '(bc) n1 holds the winner\'s big');
set_repair(1, 'off');
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
#      verify() and the repair worker cast the key to citext first and must not call it.
my $has_citext = scalar_query(1, "SELECT count(*) FROM pg_available_extensions WHERE name = 'citext'");
SKIP: {
    skip '(be) citext is not installed', 16 unless $has_citext eq '1';
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
    set_repair(1, 'on');
    ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_dom'::regclass",
                        '0', 30), '(be) the repair worker repaired it without calling it')
        or diag('(be) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                     . "WHERE relid = 'public.td_dom'::regclass"));
    is(scalar_query(1, "SELECT md5(big) FROM public.td_dom WHERE id::text = 'a'"),
       scalar_query(2, "SELECT md5(big) FROM public.td_dom WHERE id::text = 'a'"),
       '(be) n1 holds the winner\'s big');
    set_repair(1, 'off');
    for my $n (1, 2) {
        psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                       . "DROP TABLE public.td_dom CASCADE; DROP OPERATOR public.= (public.td_dk, public.td_dk); "
                       . "DROP FUNCTION public.td_dk_eq(public.td_dk, public.td_dk); "
                       . "DROP DOMAIN public.td_dk; DROP EXTENSION citext; "
                       . "REVOKE CREATE ON SCHEMA public FROM td_planter; DROP ROLE td_planter");
    }
    psql_or_bail(1, "DELETE FROM spock.toast_suspect");
}

# (bf) td_su is owned by the superuser the repair worker runs as, and an
#      ALWAYS trigger on it sets search_path for the session, as a plain SET
#      in user code does.  The worker's own search_path must outlast the
#      repair write that fires it: the next repair, of another row, must not
#      call the convert_to td_planter created in public.
psql_or_bail(1, "CREATE TABLE public.td_su (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td_su ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_su')", '1'),
   '1', '(bf) td_su replicated to n2');
psql_or_bail(1, "INSERT INTO public.td_su VALUES (1, 's', $BIG_Z), (2, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(bf) rows on n2');
race('(bf) row 1',
     "UPDATE public.td_su SET big = $BIG_X WHERE id = 1",
     "UPDATE public.td_su SET small = 'bf' WHERE id = 1");
is(suspects(1, "relid = 'public.td_su'::regclass"), '1', '(bf) row 1 suspect on n1');
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "CREATE FUNCTION public.td_su_trg() RETURNS trigger LANGUAGE plpgsql AS "
              . "\$f\$BEGIN RAISE LOG 'td_su_trg fired in %', current_setting('application_name'); "
              . "PERFORM set_config('search_path', 'public', false); RETURN NEW; END\$f\$; "
              . "CREATE TRIGGER td_su_trg BEFORE UPDATE ON public.td_su "
              . "FOR EACH ROW EXECUTE FUNCTION public.td_su_trg(); "
              . "ALTER TABLE public.td_su ENABLE ALWAYS TRIGGER td_su_trg; "
              . "CREATE ROLE td_planter; GRANT CREATE ON SCHEMA public TO td_planter; "
              . "SET ROLE td_planter; "
              . "CREATE FUNCTION public.convert_to(text, text) RETURNS bytea LANGUAGE plpgsql AS "
              . "\$f\$BEGIN RAISE EXCEPTION 'planted convert_to called by %', current_user; END\$f\$");
my $off_bf = log_offset(1);
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_su'::regclass",
                    '0', 30), '(bf) row 1 repaired')
    or diag('(bf) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                 . "WHERE relid = 'public.td_su'::regclass"));
ok(wait_for_log(1, qr/td_su_trg fired in spock toast repair/, $off_bf),
   '(bf) the repair of row 1 fired the trigger');
race('(bf) row 2',
     "UPDATE public.td_su SET big = $BIG_X WHERE id = 2",
     "UPDATE public.td_su SET small = 'bf' WHERE id = 2");
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_su'::regclass",
                    '0', 30), '(bf) row 2 repaired without calling the planted convert_to')
    or diag('(bf) last_error: ' . scalar_query(1, "SELECT last_error FROM spock.toast_suspect "
                                                 . "WHERE relid = 'public.td_su'::regclass"));
is(scalar_query(1, "SELECT md5(big) FROM public.td_su WHERE id = 2"),
   scalar_query(2, "SELECT md5(big) FROM public.td_su WHERE id = 2"),
   '(bf) n1 holds the winner\'s big for row 2');
set_repair(1, 'off');
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; DROP TABLE public.td_su CASCADE");
}
psql_or_bail(1, "SET spock.enable_ddl_replication = off; "
              . "DROP FUNCTION public.td_su_trg(), public.convert_to(text, text); "
              . "REVOKE CREATE ON SCHEMA public FROM td_planter; DROP ROLE td_planter");
# The apply worker fired the trigger too.
restart_apply('(bf)');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (bg) The same on the winner, where the read runs in
#      spock.toast_read_as_owner() as the superuser owner, over a connection
#      kept for later fetches.  td_wo's key is a domain whose CHECK runs in
#      that read and sets a setting for the session, as a plain SET in user
#      code does.  With one row fetched per wave, a later fetch must not see
#      what an earlier one set.
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; "
                   . "CREATE FUNCTION public.td_wchk(text) RETURNS boolean LANGUAGE plpgsql AS \$f\$ "
                   . "DECLARE v text := coalesce(current_setting('td.leak', true), ''); "
                   . "st text := statement_timestamp()::text; "
                   . "BEGIN IF current_setting('application_name') LIKE '%toastdiv%' THEN "
                   . "IF v <> '' AND v <> st THEN RAISE LOG 'td_wchk saw the setting of statement %', v; END IF; "
                   . "RAISE LOG 'td_wchk ran in statement %', st; "
                   . "PERFORM set_config('td.leak', st, false); "
                   . "END IF; RETURN true; END\$f\$; "
                   . "CREATE DOMAIN public.td_wk AS text CHECK (public.td_wchk(VALUE))");
}
psql_or_bail(1, "CREATE TABLE public.td_wo (id public.td_wk PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td_wo ALTER COLUMN big SET STORAGE EXTERNAL");
is(wait_for_value(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td_wo')", '1'),
   '1', '(bg) td_wo replicated to n2');
psql_or_bail(1, "INSERT INTO public.td_wo VALUES ('a', 's', $BIG_Z), ('b', 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(bg) rows on n2');
race('(bg)',
     "UPDATE public.td_wo SET big = $BIG_X",
     "UPDATE public.td_wo SET small = 'bg'");
is(suspects(1, "relid = 'public.td_wo'::regclass"), '2', '(bg) two suspects on n1');
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_fetch_bytes = '64kB'");
my $off_bg = log_offset(2);
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_wo'::regclass",
                    '0', 30), '(bg) both rows repaired')
    or diag('(bg) last_error: ' . scalar_query(1, "SELECT string_agg(last_error, '; ') FROM spock.toast_suspect "
                                                 . "WHERE relid = 'public.td_wo'::regclass"));
set_repair(1, 'off');
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_fetch_bytes");
psql_or_bail(1, "SELECT pg_reload_conf()");
my $log_bg = log_since(2, $off_bg);
my %stmts_bg = map { $_ => 1 } ($log_bg =~ /td_wchk ran in statement ([^\n]+)/g);
ok(scalar(keys %stmts_bg) >= 2, '(bg) the check ran in ' . scalar(keys %stmts_bg) . ' fetches on n2');
unlike($log_bg, qr/td_wchk saw the setting of statement/,
       '(bg) no fetch saw a setting an earlier fetch made');
for my $n (1, 2) {
    psql_or_bail($n, "SET spock.enable_ddl_replication = off; DROP TABLE public.td_wo CASCADE; "
                   . "DROP DOMAIN public.td_wk; DROP FUNCTION public.td_wchk(text)");
}
psql_or_bail(1, "DELETE FROM spock.toast_suspect");

# (af) The winner's table is locked, so the query on it does not return.
#      verify() still stops on its statement_timeout, and the repair worker
#      still exits when it is turned off, without waiting for the lock.
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
set_repair(1, 'on');
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '%toastdiv%' "
                     . "AND wait_event_type = 'Lock'", '1', 30),
   '(af) the repair worker\'s query waits on the lock on n2');
set_repair(1, 'off');
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
set_repair(1, 'off');
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

# (au) The winner no longer keeps its row's commit timestamp, so the
#      conflict rule cannot compare the rows.  Row 1 was last written here
#      by the winner, so the winner's row is at least as new and is
#      repaired.  Row 2 was written here since, so which row is newer is not
#      known: the row stays, and big, which it kept from detection, takes the
#      winner's value.  Freezing every database on n2 moves its horizon past
#      both rows.
set_repair(1, 'off');
td_like('(au)', 'public.td_au', 'id int', 1, 2);
for my $k (1, 2) {
    race("(au) row $k",
         "UPDATE public.td_au SET big = $BIG_X WHERE id = $k",
         "UPDATE public.td_au SET small = 'au' WHERE id = $k");
}
is(suspects(1, "relid = 'public.td_au'::regclass"), '2', '(au) both rows recorded on n1');
psql_or_bail(1, "UPDATE public.td_au SET small = 'au2' WHERE id = 2");
ok(sync_nodes(1, 2), '(au) n1 -> n2 drained');
my $cfg_au = get_test_config();
psql_or_bail(2, "ALTER DATABASE template0 ALLOW_CONNECTIONS true");
my $au_gone = 0;
for (1 .. 30) {
    for my $db ('template0', 'template1', 'postgres', $cfg_au->{db_name}) {
        system("$cfg_au->{pg_bin}/psql", '-X', '-q', '-p', $cfg_au->{node_ports}->[1], '-d', $db,
               '-c', 'VACUUM (FREEZE)');
    }
    if (scalar_query(2, "SELECT bool_and(pg_xact_commit_timestamp(xmin) IS NULL) FROM public.td_au") eq 't') {
        $au_gone = 1;
        last;
    }
    sleep(1);
}
psql_or_bail(2, "ALTER DATABASE template0 ALLOW_CONNECTIONS false");
ok($au_gone, '(au) n2 no longer has either row\'s commit timestamp');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE relid = 'public.td_au'::regclass",
                    '0', 30), '(au) both entries settled')
    or diag('(au) entries: ' . scalar_query(1, "SELECT string_agg(pkey::text || ' ' || coalesce(last_error, ''), '; ') "
                                              . "FROM spock.toast_suspect WHERE relid = 'public.td_au'::regclass"));
is(scalar_query(1, "SELECT md5(big) FROM public.td_au WHERE id = 1"),
   scalar_query(2, "SELECT md5(big) FROM public.td_au WHERE id = 1"), '(au) row 1 repaired');
is(scalar_query(1, "SELECT md5(big) FROM public.td_au WHERE id = 2"),
   scalar_query(2, "SELECT md5(big) FROM public.td_au WHERE id = 2"), '(au) row 2 kept big repaired');
is(scalar_query(1, "SELECT small FROM public.td_au WHERE id = 2"), 'au2', '(au) row 2 keeps its own small');
set_repair(1, 'off');

# (ax) A stop request that arrives during a pass ends the worker without
#      waiting out its sleep.  The worker waits on a row another session
#      holds locked, with both sleeps an hour long, and is sent one SIGTERM
#      while it waits; the lock wait resets the latch the signal set.  The
#      lock wait lasts 10 s, and the worker must exit once it times out.
#      Turning repair off would not show this: the manager signals a
#      running worker again on each of its own passes.
set_repair(1, 'off');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "INSERT INTO public.td VALUES (611, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(ax) row 611 on n2');
race('(ax)',
     "UPDATE public.td SET big = repeat('e', 200000) WHERE id = 611",
     "UPDATE public.td SET small = 'e' WHERE id = 611");
is(suspects(1, "pkey = jsonb_build_object('id', '611')"), '1', '(ax) suspect recorded');
my $ax_locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[0], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; SELECT 1 FROM public.td WHERE id = 611 FOR UPDATE; "
    . "SELECT pg_sleep(120);" ],
    '>', \my $ax_out, '2>', \my $ax_err);
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(ax) row 611 locked on n1') or diag("locking session: $ax_err");
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_interval = '1h'");
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_retry_interval = 3600");
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_lock_timeout = 10000");
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_repair = on");
psql_or_bail(1, "SELECT pg_reload_conf()");
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'spock toast repair%' "
                     . "AND wait_event_type = 'Lock'", '1', 30),
   '(ax) the worker waits on the locked row');
my $ax_pid = scalar_query(1, "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'spock toast repair%'");
psql_or_bail(1, "SELECT pg_terminate_backend($ax_pid)");
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity WHERE pid = $ax_pid", '0', 60),
   '(ax) the worker exited after its lock wait, not after its sleep');
psql_or_bail(1, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'td_locker'");
$ax_locker->finish;
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_lock_timeout");
set_repair(1, 'off');

# ---------------------------------------------------------------------------
# (az) A lock held on the winner's table longer than
#      spock.toast_divergence_lock_timeout fails the entry with the lock
#      timeout, keeping its state, and the entry is repaired once the lock
#      goes.
# ---------------------------------------------------------------------------
set_repair(1, 'off');
set_repair(2, 'off');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "INSERT INTO public.td VALUES (641, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(az) row 641 on n2');
race('(az)',
     "UPDATE public.td SET big = $BIG_X WHERE id = 641",
     "UPDATE public.td SET small = 'az' WHERE id = 641");
is(suspects(1, "pkey = jsonb_build_object('id', '641')"), '1', '(az) suspect on n1');
my $az_state = scalar_query(1, "SELECT state FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '641')");
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_lock_timeout = '1s'");
my $az_locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[1], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker_az'; BEGIN; LOCK TABLE public.td IN ACCESS EXCLUSIVE MODE; "
    . "SELECT pg_sleep(120);" ],
    '>', \my $az_out, '2>', \my $az_err);
ok(poll_query_until(2, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker_az' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(az) public.td locked on n2') or diag("locking session: $az_err");
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT last_error LIKE '%lock timeout%' AND state = '$az_state' "
                     . "FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '641')", 't', 30),
   '(az) the entry failed on the winner\'s lock timeout and kept its state');
psql_or_bail(2, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'td_locker_az'");
$az_locker->finish;
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '641')",
                    '0', 30),
   '(az) repaired once the lock is gone');
set_repair(1, 'off');
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_lock_timeout");
psql_or_bail(1, "SELECT pg_reload_conf()");

# ---------------------------------------------------------------------------
# (ba) Rows that do not fit spock.toast_divergence_fetch_bytes are fetched
#      in several waves, and one pass still settles them all.
# ---------------------------------------------------------------------------
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "INSERT INTO public.td SELECT g, 's', $BIG_Z FROM generate_series(631, 635) g");
ok(sync_nodes(1, 2), '(ba) rows 631 to 635 on n2');
race('(ba)',
     "UPDATE public.td SET big = $BIG_X WHERE id BETWEEN 631 AND 635",
     "UPDATE public.td SET small = 'ba' WHERE id BETWEEN 631 AND 635");
is(suspects(1), '5', '(ba) five suspects on n1');
psql_or_bail(1, "ALTER SYSTEM SET spock.toast_divergence_fetch_bytes = '64kB'");
my $off_ba = log_offset(1);
set_repair(1, 'on');
ok(wait_for_log(1, qr/SPOCK toast repair: processed 5 \| repaired 5,/, $off_ba, 60),
   '(ba) one pass repaired all five, one 200 kB row per wave');
set_repair(1, 'off');
is(scalar_query(1, "SELECT count(*) FROM public.td WHERE id BETWEEN 631 AND 635 "
                 . "AND md5(big) = md5($BIG_Z)"), '5', '(ba) n1 holds n2\'s big in all five');
psql_or_bail(1, "ALTER SYSTEM RESET spock.toast_divergence_fetch_bytes");
psql_or_bail(1, "SELECT pg_reload_conf()");

# ---------------------------------------------------------------------------
# (bb) A repair worker that is killed is started again while the setting is
#      on, and a worker that stops drops its private origin.
# ---------------------------------------------------------------------------
my $REPAIR_PID = "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'spock toast repair%'";
set_repair(1, 'on');
my $bb_pid = scalar_query(1, $REPAIR_PID);
like($bb_pid, qr/^\d+$/, '(bb) one repair worker');
psql_or_bail(1, "SELECT pg_terminate_backend($bb_pid)");
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity "
                     . "WHERE application_name LIKE 'spock toast repair%' AND pid <> $bb_pid", '1', 60),
   '(bb) a new worker started after the old one was killed');
set_repair(1, 'off');
ok(poll_query_until(1, "SELECT count(*) FROM pg_replication_origin WHERE roname LIKE 'spock_toast_repair_%'",
                    '0', 30),
   '(bb) the stopped worker dropped its private origin');

# ---------------------------------------------------------------------------
# (ay) The winner deleted the row, in repair mode so the delete does not
#      reach n1.  The worker marks the entry remote_missing and leaves
#      the entry and n1's row alone.
# ---------------------------------------------------------------------------
set_repair(1, 'off');
set_repair(2, 'off');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(2, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "INSERT INTO public.td VALUES (621, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(ay) row 621 on n2');
race('(ay)',
     "UPDATE public.td SET big = repeat('e', 200000) WHERE id = 621",
     "UPDATE public.td SET small = 'e' WHERE id = 621");
is(suspects(1, "pkey = jsonb_build_object('id', '621')"), '1', '(ay) suspect on n1');
psql_or_bail(2, "BEGIN; SELECT spock.repair_mode(true); "
              . "DELETE FROM public.td WHERE id = 621; COMMIT");
drain('(ay)');
is(scalar_query(1, "SELECT count(*) FROM public.td WHERE id = 621"), '1',
   '(ay) the delete did not reach n1');
my $off_ay = log_offset(1);
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT state FROM spock.toast_suspect "
                     . "WHERE pkey = jsonb_build_object('id', '621')", 'remote_missing', 30),
   '(ay) the worker marked the entry remote_missing');
ok(wait_for_log(1, qr/SPOCK toast repair: .*remote missing 1/, $off_ay, 30), '(ay) and counted it');
set_repair(1, 'off');
is(scalar_query(1, "SELECT md5(big) = md5(repeat('e', 200000)) FROM public.td WHERE id = 621"), 't',
   '(ay) n1\'s row was left as it was');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "BEGIN; SELECT spock.repair_mode(true); "
              . "DELETE FROM public.td WHERE id = 621; COMMIT");

# (z) The winner subscription is dropped, as when its node leaves the
#     cluster.  Entries naming it are deleted with a warning instead of
#     waiting forever; an entry that never had a winner subscription (the
#     shape a forwarded change leaves) is kept.  Runs last: it drops n1's
#     subscription to n2.
set_repair(1, 'off');
set_repair(2, 'off');
psql_or_bail(1, "DELETE FROM spock.toast_suspect");
psql_or_bail(1, "INSERT INTO public.td VALUES (601, 's', $BIG_Z)");
ok(sync_nodes(1, 2), '(z) row 601 on n2');
race('(z)',
     "UPDATE public.td SET big = repeat('d', 200000) WHERE id = 601",
     "UPDATE public.td SET small = 'd' WHERE id = 601");
is(suspects(1, "pkey = jsonb_build_object('id', '601') AND winner_subid <> 0"), '1',
   '(z) suspect on n1 naming sub_n1_n2');
psql_or_bail(1, "INSERT INTO spock.toast_suspect "
              . "(relid, pkey, attnums, winner_subid, winner_origin, winner_ts) "
              . "VALUES ('public.td'::regclass, '{\"id\": \"602\"}', '{3}', 0, 0, now())");
psql_or_bail(1, "SELECT spock.sub_drop('sub_n1_n2')");
is(scalar_query(1, "SELECT count(*) FROM spock.subscription WHERE sub_name = 'sub_n1_n2'"), '0',
   '(z) sub_n1_n2 dropped');
my $off_z = log_offset(1);
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE winner_subid <> 0", '0', 30),
   '(z) the entry naming the dropped subscription is gone');
ok(wait_for_log(1, qr/removed 1 TOAST suspect entries whose winner subscription no longer exists/,
                $off_z, 30),
   '(z) the worker warned about it');
ok(wait_for_log(1, qr/SPOCK toast repair: .*orphaned 1/, $off_z, 30), '(z) and counted it');
is(suspects(1, "winner_subid = 0"), '1', '(z) the entry with no winner subscription is kept');
set_repair(1, 'off');

destroy_cluster('Destroy cluster');
done_testing();
