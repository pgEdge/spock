use strict;
use warnings;
use Test::More;
use lib '.';
use IPC::Run;
use SpockTest qw(
    create_cluster cross_wire destroy_cluster get_test_config
    psql_or_bail scalar_query poll_query_until
    wait_for_sub_status sync_nodes log_offset wait_for_log
);

# Multi-winner fan-out in one repair pass.
#
# The fused repair pass reads a batch of suspects and fetches the winners for
# the rows that need them, one connection per winning subscription.  A batch
# can hold entries whose winner differs, so one pass must fetch from more than
# one winner.  This test builds exactly that: on n1, rows 1-2 diverge with n2
# as the winner and rows 3-4 with n3, so a single pass fetches from both n2 and
# n3 and repairs all four.
#
# The pass logs one line per run -- "SPOCK toast repair: processed N |
# repaired R, cleared C, ..." -- aggregating every winner group in that run.
# With the default batch (100 rows) and fetch budget (32MB) all four rows fit
# in one wave, so a single logged pass shows repaired 4, which can only
# happen if that one pass fetched from both n2 and n3.
#
# Then two mesh cases where the sending node also last wrote the local row,
# which only version stamps can catch:
#   (b) n2 takes big from n3 and updates small; n2's update reaches n1 before
#       n3's change, which then loses on n1.
#   (c) n1's repair copies n2's big while n2 itself lost big to n3 and has
#       not repaired yet; n3's change reaches n1 afterwards.
# And two where the newer local row came from a third node:
#   (d) n1's entry names n2, but n3's newer row, which carries n1's big,
#       arrives first; the repair must not copy n2's losing big.
#   (e) n1's entry outlives an update from a third node.

create_cluster(3, 'Create 3-node cluster for multi-winner TOAST repair');
cross_wire(3, ['n1', 'n2', 'n3'], 'Cross-wire n1, n2, n3');

# --- helpers ---------------------------------------------------------------

sub suspects {
    my ($node, $where) = @_;
    $where //= 'true';
    return scalar_query($node, "SELECT count(*) FROM spock.toast_suspect WHERE $where");
}

sub big_md5 {
    my ($node, $id) = @_;
    return scalar_query($node, "SELECT md5(big) FROM public.td WHERE id = $id");
}

# Turn the repair worker on or off on one node and wait for the manager to act.
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

# Drive a cross-origin divergence on n1 for the given rows, with $winner (node
# number 2 or 3) as the node whose value wins.  Both directions between n1 and
# the winner are stopped so the two local changes are staged before either is
# applied.  n1 changes big (older, loses); the winner changes small (newer,
# wins).  The winner applies n1's older update and keeps its own row; n1 then
# applies the winner's newer update, keeps its own big, and records suspects
# naming the winner.  n1 ends up diverged (big = 'x'), the winner keeps 'z'.
sub diverge_on_n1 {
    my ($winner, @ids) = @_;
    my $wname    = "n$winner";
    my $label    = "winner $wname";
    my $sub_n1_w = "sub_n1_$wname";     # n1's apply from the winner
    my $sub_w_n1 = "sub_${wname}_n1";   # the winner's apply from n1
    my $idlist   = join(',', @ids);

    psql_or_bail(1, "SELECT spock.sub_disable('$sub_n1_w', true)");
    psql_or_bail($winner, "SELECT spock.sub_disable('$sub_w_n1', true)");
    ok(wait_for_sub_status(1, $sub_n1_w, 'disabled'), "$label: n1 apply from $wname stopped");
    ok(wait_for_sub_status($winner, $sub_w_n1, 'disabled'), "$label: $wname apply from n1 stopped");

    psql_or_bail(1, "UPDATE public.td SET big = repeat('x', 200000) WHERE id IN ($idlist)");
    psql_or_bail($winner, "UPDATE public.td SET small = 'w$winner' WHERE id IN ($idlist)");

    psql_or_bail($winner, "SELECT spock.sub_enable('$sub_w_n1', true)");
    ok(wait_for_sub_status($winner, $sub_w_n1, 'replicating'), "$label: $wname apply from n1 resumed");
    psql_or_bail(1, "SELECT spock.sub_enable('$sub_n1_w', true)");
    ok(wait_for_sub_status(1, $sub_n1_w, 'replicating'), "$label: n1 apply from $wname resumed");

    # Drain both directions so the suspects are recorded before we look.
    ok(sync_nodes($winner, 1, $wname), "$label: $wname -> n1 drained");
    ok(sync_nodes(1, $winner, 'n1'), "$label: n1 -> $wname drained");
}

# --- setup -----------------------------------------------------------------

# Confirm the subscription names the divergence recipe relies on.  cross_wire()
# names each subscription sub_<subscriber>_<provider>, so n1 pulls from n2 over
# sub_n1_n2 and from n3 over sub_n1_n3.
my $n1_subs = scalar_query(1, "SELECT string_agg(sub_name, ',' ORDER BY sub_name) FROM spock.subscription");
is($n1_subs, 'sub_n1_n2,sub_n1_n3', 'n1 has the expected subscriptions to n2 and n3');

# Auto-DDL is on: the CREATE replicates and the table joins 'default' on all
# three nodes at REPLICA IDENTITY DEFAULT.
psql_or_bail(1, "CREATE TABLE public.td (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td ALTER COLUMN big SET STORAGE EXTERNAL");
is(poll_query_until(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td')", '1', 60), 1,
   'td replicated to n2');
is(poll_query_until(3, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td')", '1', 60), 1,
   'td replicated to n3');

psql_or_bail(1, "INSERT INTO public.td VALUES "
              . "(1,'s',repeat('z',200000)),(2,'s',repeat('z',200000)),"
              . "(3,'s',repeat('z',200000)),(4,'s',repeat('z',200000))");
is(poll_query_until(2, "SELECT count(*) FROM public.td", '4', 60), 1, 'rows on n2');
is(poll_query_until(3, "SELECT count(*) FROM public.td", '4', 60), 1, 'rows on n3');

is(suspects(1), '0', 'queue starts empty on n1');

# --- drive the divergence --------------------------------------------------

# rows 1,2 diverge with n2 as winner; rows 3,4 with n3 as winner.
diverge_on_n1(2, 1, 2);
diverge_on_n1(3, 3, 4);

# n1 now holds four suspects: two naming n2 and two naming n3.  The winners
# recorded nothing (they kept their own winning rows).
is(suspects(1), '4', 'n1 holds four suspects');
is(scalar_query(1, "SELECT count(*) FROM spock.toast_divergence WHERE winner_node = 'n2'"), '2',
   'two suspects on n1 name n2 as the winner');
is(scalar_query(1, "SELECT count(*) FROM spock.toast_divergence WHERE winner_node = 'n3'"), '2',
   'two suspects on n1 name n3 as the winner');

# n1 really diverged: its big is 'x', each winner still holds 'z'.
my $md5_z = scalar_query(1, "SELECT md5(repeat('z', 200000))");
my $md5_x = scalar_query(1, "SELECT md5(repeat('x', 200000))");
is(big_md5(1, 1), $md5_x, 'n1 row 1 diverged to x');
is(big_md5(1, 3), $md5_x, 'n1 row 3 diverged to x');
is(big_md5(2, 1), $md5_z, 'winner n2 still holds z for row 1');
is(big_md5(3, 3), $md5_z, 'winner n3 still holds z for row 3');

# --- one repair pass fetches from both winners -----------------------------

my $off = log_offset(1);
set_repair(1, 'on');

# All four entries clear.
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect", '0', 60),
   'all four suspects cleared after repair');

# n1's big now matches each row's own winner: rows 1,2 -> n2, rows 3,4 -> n3.
is(big_md5(1, 1), big_md5(2, 1), 'row 1 on n1 matches winner n2');
is(big_md5(1, 2), big_md5(2, 2), 'row 2 on n1 matches winner n2');
is(big_md5(1, 3), big_md5(3, 3), 'row 3 on n1 matches winner n3');
is(big_md5(1, 4), big_md5(3, 4), 'row 4 on n1 matches winner n3');
is(big_md5(1, 1), $md5_z, 'row 1 converged on the winner value');
is(big_md5(1, 4), $md5_z, 'row 4 converged on the winner value');

# The key assertion: a single logged pass repaired all four.  The pass log
# line aggregates every winner group in one run, and rows 1-2 name n2 while
# rows 3-4 name n3, so one run repairing four fetched from both winners.
ok(wait_for_log(1, qr/SPOCK toast repair: processed \d+ \| repaired 4,/, $off, 60),
   'one repair pass repaired all four, fetching from both winners');

set_repair(1, 'off');

# --- mesh cases ----------------------------------------------------------

my $cfg = get_test_config();

sub md5_of {
    my ($c) = @_;
    return scalar_query(1, "SELECT md5(repeat('$c', 200000))");
}
sub hold {
    my ($sub) = @_;
    my ($node) = $sub =~ /^sub_n(\d)_/;
    psql_or_bail($node, "SELECT spock.sub_disable('$sub', true)");
    ok(wait_for_sub_status($node, $sub, 'disabled'), "$sub stopped");
}
sub release {
    my ($sub) = @_;
    my ($node) = $sub =~ /^sub_n(\d)_/;
    psql_or_bail($node, "SELECT spock.sub_enable('$sub', true)");
    ok(wait_for_sub_status($node, $sub, 'replicating'), "$sub resumed");
}
sub sync_all {
    my ($label) = @_;
    for my $a (1 .. 3) {
        for my $b (1 .. 3) {
            next if $a == $b;
            ok(sync_nodes($a, $b, "n$a"), "$label: n$a -> n$b drained");
        }
    }
}
sub converged {
    my ($label, $id, $want) = @_;
    for my $n (1 .. 3) {
        ok(poll_query_until($n, "SELECT md5(big) FROM public.td WHERE id = $id", $want, 30),
           "$label: n$n holds the expected big")
            or diag("$label: n$n holds " . big_md5($n, $id));
    }
}

# (b) n1's copy of row 11 was last written by n2.  n3 changes big; n2
#     applies it and then changes small, leaving big unchanged; n1 receives
#     n2's update first.  The local row's last writer is the sender, but
#     n2's stamp for big is n3's and n1's is not, so n1 records the row.
#     n3's change then loses on n1 to n2's newer row, and the repair copies
#     n3's big from n2.
psql_or_bail(2, "INSERT INTO public.td VALUES (11, 's', repeat('z', 200000))");
sync_all('(b) setup');
hold('sub_n1_n3');
psql_or_bail(3, "UPDATE public.td SET big = repeat('x', 200000) WHERE id = 11");
ok(sync_nodes(3, 2, 'n3'), '(b) n3 -> n2 drained');
psql_or_bail(2, "UPDATE public.td SET small = 'b' WHERE id = 11");
ok(sync_nodes(2, 1, 'n2'), '(b) n2 -> n1 drained');
is(suspects(1, "pkey = jsonb_build_object('id', '11') AND reason = 'stamp_mismatch'"), '1',
   '(b) n1 recorded the same-origin row on the stamp mismatch');
release('sub_n1_n3');
sync_all('(b)');
set_repair($_, 'on') for 1 .. 3;
converged('(b)', 11, md5_of('x'));
set_repair($_, 'off') for 1 .. 3;
psql_or_bail($_, "DELETE FROM spock.toast_suspect") for 1 .. 3;

# (c) n1 diverges on row 12 with n2 as the winner.  Then n2 changes big and
#     loses to a newer n3 update of small, so n2 holds its own losing big and
#     an entry naming n3.  n1's apply from n2 is held on a locked row, so n1
#     has not seen n2's big change when its worker copies n2's big and the
#     row's stamp (n3's).  n3's update then reaches n1 from the row's own
#     origin; the stamps for big differ, so n1 records it, and the cluster
#     ends on n3's big.
psql_or_bail(2, "INSERT INTO public.td VALUES (12, 's', repeat('z', 200000)), (13, 's', 's')");
sync_all('(c) setup');
hold($_) for qw(sub_n1_n2 sub_n2_n1 sub_n3_n1);
psql_or_bail(1, "UPDATE public.td SET big = repeat('b', 200000) WHERE id = 12");
psql_or_bail(2, "UPDATE public.td SET small = 'w1' WHERE id = 12");
release($_) for qw(sub_n1_n2 sub_n2_n1);
ok(sync_nodes(1, 2, 'n1'), '(c) n1 -> n2 drained');
ok(sync_nodes(2, 1, 'n2'), '(c) n2 -> n1 drained');
is(suspects(1, "pkey = jsonb_build_object('id', '12')"), '1', '(c) n1 diverged, naming n2');
release('sub_n3_n1');
sync_all('(c) step 1');

my $locker = IPC::Run::start(
    [ "$cfg->{pg_bin}/psql", '-X', '-p', $cfg->{node_ports}->[0], '-d', $cfg->{db_name}, '-c',
      "SET application_name = 'td_locker'; BEGIN; SELECT 1 FROM public.td WHERE id = 13 FOR UPDATE; "
    . "SELECT pg_sleep(120);" ],
    '>', \my $l_out, '2>', \my $l_err);
ok(poll_query_until(1, "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'td_locker' "
                     . "AND state = 'active' AND query LIKE '%pg_sleep%'", '1', 30),
   '(c) row 13 locked on n1') or diag("locking session: $l_err");
hold($_) for qw(sub_n2_n3 sub_n3_n2 sub_n1_n3);
psql_or_bail(2, "UPDATE public.td SET small = 'lock' WHERE id = 13");
ok(poll_query_until(1, "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype = 'transactionid'",
                    '1', 30), '(c) n1 apply from n2 waits on the lock');
psql_or_bail(2, "UPDATE public.td SET big = repeat('a', 200000) WHERE id = 12");
psql_or_bail(3, "UPDATE public.td SET small = 'c' WHERE id = 12");
release($_) for qw(sub_n2_n3 sub_n3_n2);
ok(sync_nodes(2, 3, 'n2'), '(c) n2 -> n3 drained');
ok(sync_nodes(3, 2, 'n3'), '(c) n3 -> n2 drained');
is(suspects(2, "pkey = jsonb_build_object('id', '12')"), '1', '(c) n2 lost big to n3');

set_repair(1, 'on');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '12')",
                    '0', 30), '(c) n1 settled its entry from n2');
is(big_md5(1, 12), md5_of('a'), "(c) n1 took n2's big, which has not been repaired yet");

psql_or_bail(1, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'td_locker'");
$locker->finish;
release('sub_n1_n3');
set_repair($_, 'on') for 2, 3;
sync_all('(c)');
converged('(c)', 12, md5_of('z'));
set_repair($_, 'off') for 1 .. 3;

# (d) The newer local row was written by a third node.  n1 changes big; n2
#     updates small before n1's change reaches it; n3 updates small after
#     taking n1's big but before n2's update reaches it.  n1 applies n2's
#     update (an entry naming n2), then n3's newer one.  n3's row is the
#     newest, with n1's big, so the cluster must end on n1's big.  n1's
#     worker runs while n2 still holds its old big and has not applied
#     n3's update: the local row is newer and was written by n3, so the
#     entry is pointed at n3 and cleared on equal values, instead of copying
#     n2's losing big.  Had n2 applied n3's update first, both rows would be
#     n3's, and n1 would copy n2's big: a limit the docs list.
psql_or_bail(1, "INSERT INTO public.td VALUES (21, 's', repeat('z', 200000))");
sync_all('(d) setup');
hold($_) for qw(sub_n2_n1 sub_n3_n2 sub_n1_n3 sub_n2_n3);
psql_or_bail(1, "UPDATE public.td SET big = repeat('x', 200000) WHERE id = 21");
ok(sync_nodes(1, 3, 'n1'), '(d) n1 -> n3 drained');
psql_or_bail(2, "UPDATE public.td SET small = 'd1' WHERE id = 21");
ok(sync_nodes(2, 1, 'n2'), '(d) n2 -> n1 drained');
is(suspects(1, "pkey = jsonb_build_object('id', '21')"), '1', '(d) n1 recorded an entry naming n2');
psql_or_bail(3, "UPDATE public.td SET small = 'd2' WHERE id = 21");
release('sub_n1_n3');
ok(sync_nodes(3, 1, 'n3'), '(d) n3 -> n1 drained');
is(scalar_query(1, "SELECT small FROM public.td WHERE id = 21"), 'd2', '(d) n1 holds n3\'s row');
my $d_first = scalar_query(1, "SELECT first_winner_ts FROM spock.toast_suspect "
                             . "WHERE pkey = jsonb_build_object('id', '21')");
hold('sub_n1_n3');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT winner_node FROM spock.toast_divergence "
                     . "WHERE pkey = jsonb_build_object('id', '21')", 'n3', 30),
   '(d) n1\'s entry now names n3');
is(scalar_query(1, "SELECT first_winner_ts FROM spock.toast_suspect "
                 . "WHERE pkey = jsonb_build_object('id', '21')"), $d_first,
   '(d) its first winner timestamp is kept');
is(big_md5(1, 21), md5_of('x'), '(d) n1 did not copy n2\'s big');
release('sub_n1_n3');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '21')",
                    '0', 30), '(d) n1 settled its entry');
is(big_md5(1, 21), md5_of('x'), '(d) n1 kept its big, which n3\'s newest row carries');
set_repair(1, 'off');
release($_) for qw(sub_n2_n1 sub_n3_n2 sub_n2_n3);
set_repair($_, 'on') for 1 .. 3;
sync_all('(d)');
converged('(d)', 21, md5_of('x'));
set_repair($_, 'off') for 1 .. 3;

# (e) An entry outlives a third node's update.  n3 changes big; n1 takes it,
#     n2 does not.  n2 updates small, which wins on n1 and n3: both record an
#     entry naming n2.  n3 updates small again; n1 takes it with equal
#     stamps, so its entry still names n2.  n2 then takes n3's changes: n3's
#     big loses to n2's newer row, and n3's later update leaves an entry on
#     n2 naming n3.  n2's row won and nobody wrote big after it, so every
#     node ends on n2's big.
psql_or_bail(1, "INSERT INTO public.td VALUES (41, 's', repeat('z', 200000))");
sync_all('(e) setup');
hold('sub_n2_n3');
psql_or_bail(3, "UPDATE public.td SET big = repeat('y', 200000) WHERE id = 41");
ok(sync_nodes(3, 1, 'n3'), '(e) n3 -> n1 drained');
psql_or_bail(2, "UPDATE public.td SET small = 'f1' WHERE id = 41");
ok(sync_nodes(2, 1, 'n2'), '(e) n2 -> n1 drained');
ok(sync_nodes(2, 3, 'n2'), '(e) n2 -> n3 drained');
is(suspects(1, "pkey = jsonb_build_object('id', '41')"), '1', '(e) n1 recorded an entry naming n2');
is(suspects(3, "pkey = jsonb_build_object('id', '41')"), '1', '(e) n3 recorded an entry naming n2');
psql_or_bail(3, "UPDATE public.td SET small = 'f2' WHERE id = 41");
ok(sync_nodes(3, 1, 'n3'), '(e) n3 -> n1 drained');
release('sub_n2_n3');
ok(sync_nodes(3, 2, 'n3'), '(e) n3 -> n2 drained');
is(suspects(2, "pkey = jsonb_build_object('id', '41')"), '1', '(e) n2 recorded an entry naming n3');
set_repair($_, 'on') for 1 .. 3;
sync_all('(e)');
converged('(e)', 41, md5_of('z'));
for my $n (1 .. 3) {
    ok(poll_query_until($n, "SELECT count(*) FROM spock.toast_suspect WHERE pkey = jsonb_build_object('id', '41')",
                        '0', 30), "(e) n$n settled its entry");
}
set_repair($_, 'off') for 1 .. 3;

destroy_cluster('Destroy cluster');
done_testing();
