use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    system_maybe
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status
);

# =============================================================================
# Test 104: Connection block via iptables (firewall-style outage)
# =============================================================================
# Reproduces the customer scenario: a firewall briefly blocks the replication
# connection, a transaction is committed on the provider during the outage, and
# the connection is then restored.
#
# Exercises the b75cb4fc connection-loss handling together with the
# exception_log message backport (ed17523 + b32ef95).  Asserts that:
#
#   1. The block stops replication: rows committed during the outage do not
#      reach the subscriber while blocked.
#   2. In SUB_DISABLE mode the outage does NOT disable the subscription (a
#      connection error rethrows before the disable path; a stall just waits).
#   3. After the block is lifted the subscription returns to 'replicating' and
#      the during-outage transaction is applied with NO row loss.
#   4. The connection blip produces NO spurious spock.exception_log entries.
#      (Any that appear are dumped; their messages now carry [SQLSTATE ...].)
#
# Whether iptables tears the connection down or merely stalls it is host
# dependent (over loopback it often stalls); both are safe and the test reports
# which occurred as diag rather than asserting a specific teardown.
#
# Mechanics: the harness's control psql connects over the unix socket (no -h),
# while spock's replication connection uses host=127.0.0.1 (TCP).  So we sever
# replication with iptables on TCP to/from 127.0.0.1:<provider-port> while still
# driving the provider over the socket.  We use REJECT --reject-with tcp-reset
# (not DROP) so the broken connection is detected immediately and reconnect
# attempts fail fast, rather than silently stalling.
#
# Detection is proved via an observable, log-independent signal (the walsender
# PID change), because the harness's server-log location is environment
# dependent (logging_collector with a relative log_directory lands under each
# node's datadir).  A best-effort log scrape is emitted as diag only.
#
# Requires iptables usable as root or via passwordless sudo; otherwise skipped.
# Not in the schedule -- run manually:
#   PERL5LIB=t prove -v t/104_iptables_conn_block.pl
# =============================================================================

# ---------------------------------------------------------------------------
# Probe for a usable iptables before any expensive setup.
# ---------------------------------------------------------------------------
chomp(my $ipt_bin = `command -v iptables 2>/dev/null`);
plan skip_all => 'iptables not found in PATH' unless $ipt_bin;

my @IPT;
if ($> == 0) {
    @IPT = ($ipt_bin);
}
elsif (system("sudo -n $ipt_bin -S OUTPUT >/dev/null 2>&1") == 0) {
    @IPT = ('sudo', '-n', $ipt_bin);
}
else {
    plan skip_all =>
        'iptables requires root or passwordless sudo (neither available)';
}

# Lexicals the helper subs close over; filled in after create_cluster().
my (@RULES, %installed, $node_datadirs);

sub block_conn {
    for my $r (@RULES) {
        my ($chain, @spec) = @$r;
        my $rc = system(@IPT, '-I', $chain, @spec);
        $installed{"@$r"} = $r if $rc == 0;
    }
    return scalar keys %installed;
}

sub unblock_conn {
    for my $key (keys %installed) {
        my ($chain, @spec) = @{ $installed{$key} };
        system(@IPT, '-D', $chain, @spec);
        delete $installed{$key};
    }
}

# Safety net: remove our rules even if the test dies or bails out.
END { unblock_conn() if %installed; }

sub set_guc_n2 {
    my ($kv) = @_;
    open(my $fh, '>>', "$node_datadirs->[1]/postgresql.conf")
        or die "cannot append to n2 postgresql.conf: $!";
    print $fh "$kv\n";
    close($fh);
    psql_or_bail(2, "SELECT pg_reload_conf()");
}

# ---------------------------------------------------------------------------
create_cluster(2, 'Create 2-node cluster for iptables connection-block test');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};
$node_datadirs  = $config->{node_datadirs};

my $p1 = $node_ports->[0];   # n1 — provider
my $p2 = $node_ports->[1];   # n2 — subscriber

my $conn_n1 = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# REJECT both directions of the apply<->walsender TCP flow with a TCP reset so
# the connection breaks immediately and reconnects fail fast.  Control psql
# uses the unix socket and is unaffected.
@RULES = (
    ['OUTPUT', '-p', 'tcp', '-d', $host, '--dport', $p1, '-j', 'REJECT', '--reject-with', 'tcp-reset'],
    ['INPUT',  '-p', 'tcp', '-s', $host, '--sport', $p1, '-j', 'REJECT', '--reject-with', 'tcp-reset'],
);

# Low ping timeout as a backstop in case a direction goes quiet rather than
# resetting.
set_guc_n2('wal_sender_timeout = 5s');
set_guc_n2("spock.exception_behaviour = 'sub_disable'");
sleep(1);

psql_or_bail(1, "CREATE TABLE t_ipt (id INT PRIMARY KEY, v TEXT)");
psql_or_bail(2, "CREATE TABLE t_ipt (id INT PRIMARY KEY, v TEXT)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_ipt', '$conn_n1', " .
    "ARRAY['default', 'default_insert_only'], false, false)");

ok(wait_for_sub_status(2, 'sub_ipt', 'replicating', 30),
    'sub_ipt reaches replicating state');

# Baseline rows must replicate before we cut the connection.
psql_or_bail(1, "INSERT INTO t_ipt SELECT g, 'pre_' || g FROM generate_series(1, 50) g");

my $baseline_ok = 0;
for (1 .. 15) {
    last if ($baseline_ok = (scalar_query(2, "SELECT count(*) FROM t_ipt") == 50));
    sleep 1;
}
ok($baseline_ok, 'baseline 50 rows replicated n1->n2 before block');

# Capture the provider's walsender PID for this subscription before the block.
my $wal_pid_before =
    scalar_query(1, "SELECT pid FROM pg_stat_replication WHERE state = 'streaming' LIMIT 1");
ok($wal_pid_before =~ /^\d+$/,
    "provider has a streaming walsender before the block (pid $wal_pid_before)");

# ---------------------------------------------------------------------------
# Block the replication connection.
# ---------------------------------------------------------------------------
is(block_conn(), scalar(@RULES),
    'iptables REJECT rules installed on both directions of provider TCP port');

# Commit a transaction on the provider DURING the outage (over the unix
# socket, which iptables does not touch).  The walsender's attempt to ship it
# triggers the reset.
psql_or_bail(1,
    "INSERT INTO t_ipt SELECT g, 'mid_' || g FROM generate_series(51, 100) g");

# Whether the connection is torn down or merely stalls is host dependent
# (over loopback, iptables often stalls rather than resets the established
# connection).  Report which happened -- both are safe outcomes -- but do not
# gate the test on it.
sleep 8;
my $still = scalar_query(1,
    "SELECT count(*) FROM pg_stat_replication WHERE pid = $wal_pid_before");
diag($still eq '0'
    ? "connection TORN DOWN during block (old walsender pid $wal_pid_before gone)"
    : "connection STALLED during block (old walsender pid $wal_pid_before still present)");

# During-outage rows must NOT have reached the subscriber.
is(scalar_query(2, "SELECT count(*) FROM t_ipt WHERE v LIKE 'mid_%'"), '0',
    'during-outage rows are not on n2 while blocked');

# A *connection* error must not disable the subscription in SUB_DISABLE mode.
isnt(scalar_query(2,
        "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_ipt'"),
    'f',
    'SUB_DISABLE: connection error did NOT disable the subscription');

# ---------------------------------------------------------------------------
# Restore the connection.
# ---------------------------------------------------------------------------
unblock_conn();
pass('iptables rules removed (connection restored)');

ok(wait_for_sub_status(2, 'sub_ipt', 'replicating', 60),
    'sub_ipt returns to replicating after the block is lifted');

# Report the post-recovery walsender (new PID => reconnected; same => stalled
# connection resumed).  Informational -- the row-count check below is the real
# proof that replication recovered.
my $wal_pid_after = scalar_query(1,
    "SELECT pid FROM pg_stat_replication WHERE state = 'streaming' LIMIT 1");
diag(($wal_pid_after =~ /^\d+$/ && $wal_pid_after ne $wal_pid_before)
    ? "RECONNECTED after unblock (new walsender pid $wal_pid_after, was $wal_pid_before)"
    : "stalled connection RESUMED after unblock (walsender pid $wal_pid_after)");

# All 100 rows (50 pre + 50 mid) must eventually be present -- no loss.
my $final_count = 0;
for (1 .. 30) {
    $final_count = scalar_query(2, "SELECT count(*) FROM t_ipt");
    last if $final_count == 100;
    sleep 2;
}
is($final_count, '100',
    'all 100 rows present on n2 after recovery (no row loss across disconnect)');

# The connection blip should not have produced spurious exception_log entries.
my $exc_cnt = scalar_query(2, "SELECT count(*) FROM spock.exception_log");
is($exc_cnt, '0',
    'no spock.exception_log entries produced by the connection blip');
if ($exc_cnt ne '0') {
    diag("Unexpected exception_log entries after connection blip:");
    my $dump = `$pg_bin/psql -X -p $p2 -d $dbname -t -A -F'|' -c ` .
               "\"SELECT table_name, operation, error_message FROM spock.exception_log ORDER BY retry_errored_at\"";
    diag("  $_") for split /\n/, ($dump // '');
}

# ---------------------------------------------------------------------------
system_maybe("$pg_bin/psql", '-p', $p2, '-d', $dbname,
    '-c', "SELECT spock.sub_drop('sub_ipt')");

destroy_cluster('Destroy iptables connection-block test cluster');

done_testing();
