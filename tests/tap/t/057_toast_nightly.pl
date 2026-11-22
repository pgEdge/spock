use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster get_test_config
    psql_or_bail scalar_query poll_query_until
    wait_for_sub_status sync_nodes system_or_bail wait_for_pg_ready
);

# TOAST divergence cases too slow or too disruptive for every push (run from
# schedule-nightly):
#   a   the winner node is down: the entry keeps its state with the error,
#       and is repaired once the node is back
#   b   a subscriber that negotiates protocol 5 gets plain 'u' for an
#       unchanged TOAST column, never the version stamp it cannot read

create_cluster(2, 'Create 2-node cluster for TOAST nightly cases');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $cfg = get_test_config();
my $BIG_Z = "repeat('z', 200000)";

sub drain {
    my ($label) = @_;
    ok(sync_nodes(1, 2), "$label: n1 -> n2 drained");
    ok(sync_nodes(2, 1), "$label: n2 -> n1 drained");
}

# n1 then n2 change the row while neither applies; n2 commits second and
# wins on both nodes, so n1 applies n2's update and diverges.
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

sub set_repair {
    my ($node, $on) = @_;
    psql_or_bail($node, "ALTER SYSTEM SET spock.toast_divergence_repair = $on");
    psql_or_bail($node, "ALTER SYSTEM SET spock.toast_divergence_retry_interval = 1");
    psql_or_bail($node, "SELECT pg_reload_conf()");
    my $want = $on eq 'on' ? '1' : '0';
    ok(poll_query_until($node,
           "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'spock toast repair%'",
           $want, 30),
       "repair worker " . ($on eq 'on' ? 'running' : 'gone') . " on n$node");
}

psql_or_bail(1, "CREATE TABLE public.td (id int PRIMARY KEY, small text, big text); "
              . "ALTER TABLE public.td ALTER COLUMN big SET STORAGE EXTERNAL");
ok(poll_query_until(2, "SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.td')", '1', 30),
   'table replicated to n2');
psql_or_bail(1, "INSERT INTO public.td VALUES (1, 's', $BIG_Z), (2, 's', $BIG_Z)");
drain('setup');

# ---------------------------------------------------------------------------
# (a) The winner node is down.  The worker cannot reach it: the entry keeps
#     its state and records the connection error.  Once the node is back,
#     the entry is repaired.
# ---------------------------------------------------------------------------
race('(a)',
     "UPDATE public.td SET big = repeat('a', 200000) WHERE id = 1",
     "UPDATE public.td SET small = 'a' WHERE id = 1");
my $KEY1 = "pkey = jsonb_build_object('id', '1')";
is(scalar_query(1, "SELECT count(*) FROM spock.toast_suspect WHERE $KEY1"), '1', '(a) suspect on n1');
my $a_state = scalar_query(1, "SELECT state FROM spock.toast_suspect WHERE $KEY1");
system_or_bail("$cfg->{pg_bin}/pg_ctl", '-D', $cfg->{node_datadirs}->[1], '-m', 'fast', '-w', 'stop');
set_repair(1, 'on');
ok(poll_query_until(1, "SELECT last_error IS NOT NULL AND state = '$a_state' "
                     . "FROM spock.toast_suspect WHERE $KEY1", 't', 60),
   '(a) with n2 down the entry keeps its state and records the error');
system_or_bail("$cfg->{pg_bin}/pg_ctl", '-D', $cfg->{node_datadirs}->[1],
               '-o', "-p $cfg->{node_ports}->[1]", '-l', $cfg->{log_file}, '-w', 'start');
ok(wait_for_pg_ready($cfg->{host}, $cfg->{node_ports}->[1]), '(a) n2 is back');
ok(poll_query_until(1, "SELECT count(*) FROM spock.toast_suspect WHERE $KEY1", '0', 90),
   '(a) repaired once n2 is back');
set_repair(1, 'off');
is(scalar_query(1, "SELECT md5(big) FROM public.td WHERE id = 1"),
   scalar_query(2, "SELECT md5(big) FROM public.td WHERE id = 1"), '(a) n1 holds n2\'s big');

# ---------------------------------------------------------------------------
# (b) Protocol 5 knows only 'u' for an unchanged TOAST column.  Decode one
#     update that leaves big alone at protocol 5 and at 6: the update
#     message is the same but for the 16-byte stamp after 'U' (node id,
#     timestamp, raw size).  A 6.0 subscriber during a rolling upgrade
#     negotiates 5, so this is what it receives.  Each message the SQL
#     interface returns starts with its 8-byte LSN, then the message type.
# ---------------------------------------------------------------------------
psql_or_bail(1, "SELECT pg_create_logical_replication_slot('td_proto', 'spock_output')");
psql_or_bail(1, "UPDATE public.td SET small = 'b' WHERE id = 2");
sub update_bytes {
    my ($proto) = @_;
    return scalar_query(1,
        "SELECT sum(length(data)) FROM pg_logical_slot_peek_binary_changes('td_proto', NULL, NULL, "
      . "'expected_encoding', getdatabaseencoding(), 'min_proto_version', '4', "
      . "'max_proto_version', '$proto', 'startup_params_format', '1', "
      . "'hooks.setup_function', 'spock.spock_hooks_setup', "
      . "'spock.replication_set_names', 'default') "
      . "WHERE get_byte(data, 8) = ascii('U')");
}
my $b5 = update_bytes(5);
my $b6 = update_bytes(6);
like($b5, qr/^\d+$/, '(b) the update decodes at protocol 5');
is($b6 - $b5, 16, '(b) only protocol 6 adds the stamp');
psql_or_bail(1, "SELECT pg_drop_replication_slot('td_proto')");

destroy_cluster('Destroy cluster');
done_testing();
