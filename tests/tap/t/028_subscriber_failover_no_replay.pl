use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail
    get_test_config scalar_query psql_or_bail wait_for_sub_status
);

# =============================================================================
# Test 028: a promoted standby of a subscriber must not replay transactions
# =============================================================================
# The apply worker records how far it has applied in the subscription's
# replication origin, but the commit records it writes name the transaction's
# origin node instead, which is what conflict resolution and forwarding need.
# Crash recovery and a physical standby replay only what the WAL says, so the
# subscription's origin was left where the last checkpoint or base backup put
# it.  A standby promoted after a clean switchover then asked the provider to
# resend from there, and the provider resent everything after its slot's
# confirmed position.  Tables with a primary key absorbed that as conflicts;
# tables without one got the rows twice.
#
# n2 subscribes to n1.  A standby of n2 is built and streams until it holds
# everything n2 has.  n2 is then stopped and the standby promoted, as Patroni
# would do it.  The promoted node resumes the subscription, and once it has
# caught up with new traffic on n1 it must hold every row exactly once.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for the subscriber failover test');

my $config  = get_test_config();
my $host    = $config->{host};
my $dbname  = $config->{db_name};
my $db_user = $config->{db_user};
my $pw      = $config->{db_password};
my @ports   = @{$config->{node_ports}};
my $pg_bin  = $config->{pg_bin};
my $log_dir = $config->{log_dir};

my $standby_port = $ports[1] + 20;
my $standby_dir  = '/tmp/tmp_spock_failover_standby';

sub standby_query {
    my ($sql) = @_;
    my $out = `$pg_bin/psql -X -h $host -p $standby_port -d $dbname -U $db_user -Atc "$sql" 2>/dev/null`;
    chomp $out;
    return $out;
}

sub wait_until {
    my ($secs, $check) = @_;
    for (1 .. $secs * 2) {
        return 1 if $check->();
        select(undef, undef, undef, 0.5);
    }
    return 0;
}

sub counts {
    my ($q) = @_;
    return "SELECT count(*) || ' rows, ' || count(*) - count(DISTINCT (id, batch)) || ' duplicates' FROM history";
}

# A table without a primary key, which is what makes a replay visible, and
# one with a primary key, which hides it.
psql_or_bail(1, "CREATE TABLE history (id int, batch int, note text)");
psql_or_bail(1, "CREATE TABLE keyed (id int PRIMARY KEY, batch int)");

my $provider_dsn = "host=$host dbname=$dbname port=$ports[0] user=$db_user password=$pw";
psql_or_bail(2,
    "SELECT spock.sub_create('sub_n2_n1', '$provider_dsn', " .
    "ARRAY['default', 'default_insert_only'], true, true)");
ok(wait_for_sub_status(2, 'sub_n2_n1', 'replicating', 60), 'sub_n2_n1 is replicating');

psql_or_bail(1, "INSERT INTO history SELECT g, 0, 'base' FROM generate_series(1, 100) g");
psql_or_bail(1, "INSERT INTO keyed SELECT g, 0 FROM generate_series(1, 100) g");
ok(wait_until(30, sub { scalar_query(2, "SELECT count(*) FROM history") eq '100' }),
   'the base rows reached n2');

# --------------------------------------------------------------------------
# A physical standby of n2
# --------------------------------------------------------------------------
system("rm -rf $standby_dir");
system_or_bail("$pg_bin/pg_basebackup", '-D', $standby_dir,
               '-h', $host, '-p', $ports[1], '-U', $db_user, '-X', 'stream', '-R');
{
    open(my $conf, '>>', "$standby_dir/postgresql.conf") or die "cannot open standby conf: $!";
    print $conf "port = $standby_port\n";
    print $conf "hot_standby = on\n";
    print $conf "log_directory = '$log_dir'\n";
    print $conf "log_filename = '028_standby.log'\n";
    close($conf);
}
system_or_bail("$pg_bin/pg_ctl", 'start', '-w', '-D', $standby_dir, '-l', "$log_dir/028_standby_ctl.log");
is(standby_query("SELECT pg_is_in_recovery()"), 't', 'the standby is in recovery');

# Traffic in several transactions, so the origin has moved well past the base
# backup by the time the standby is promoted.
for my $batch (1 .. 20) {
    psql_or_bail(1, "INSERT INTO history SELECT g, $batch, 'batch' FROM generate_series(1, 10) g");
    psql_or_bail(1, "INSERT INTO keyed SELECT $batch * 1000 + g, $batch FROM generate_series(1, 10) g");
}
my $n1_rows = scalar_query(1, "SELECT count(*) FROM history");
is($n1_rows, '300', 'n1 holds 300 history rows');
ok(wait_until(60, sub { standby_query("SELECT count(*) FROM history") eq $n1_rows }),
   'the standby holds everything n1 has');
is(scalar_query(2, "SELECT count(*) FROM history"), $n1_rows, 'so does n2');

# The decisive check.  The subscription's origin on n2 says how far it has
# applied; the standby, which holds the same rows, must say the same, or it
# will ask the provider to start from wherever its base backup left off.
# Whether that turns into duplicate rows depends on how far the provider's
# slot had advanced at that moment, which is why the row counts alone are
# not a reliable test.
my $origin_sql =
    "SELECT s.remote_lsn FROM pg_replication_origin_status s " .
    "  JOIN pg_replication_origin o ON o.roident = s.local_id " .
    " WHERE o.roname = (SELECT sub_slot_name FROM spock.subscription WHERE sub_name = 'sub_n2_n1')";
my $n2_origin = scalar_query(2, $origin_sql);
ok($n2_origin =~ m{^[0-9A-F]+/[0-9A-F]+$}, "n2's subscription origin is at $n2_origin");
ok(wait_until(30, sub { standby_query($origin_sql) eq $n2_origin }),
   'the standby\'s subscription origin matches n2\'s')
    or diag("standby origin: " . standby_query($origin_sql));

# --------------------------------------------------------------------------
# Switch over: stop n2, promote the standby
# --------------------------------------------------------------------------
system_or_bail("$pg_bin/pg_ctl", 'stop', '-m', 'fast', '-w', '-D', $config->{node_datadirs}[1]);
system_or_bail("$pg_bin/pg_ctl", 'promote', '-w', '-D', $standby_dir);
ok(wait_until(30, sub { standby_query("SELECT pg_is_in_recovery()") eq 'f' }),
   'the standby was promoted');

# Spock's supervisor only starts the managers once the server is out of
# recovery; a restart makes that deterministic rather than waiting on its
# retry interval.
system_or_bail("$pg_bin/pg_ctl", 'restart', '-w', '-D', $standby_dir, '-l', "$log_dir/028_standby_ctl.log");

ok(wait_until(60, sub {
       standby_query("SELECT status FROM spock.sub_show_status('sub_n2_n1')") eq 'replicating' }),
   'the promoted node resumed the subscription');

# New traffic proves the subscription is live, and gives the apply worker a
# reason to have asked the provider for a start position.
psql_or_bail(1, "INSERT INTO history SELECT g, 99, 'after' FROM generate_series(1, 10) g");
psql_or_bail(1, "INSERT INTO keyed SELECT 99000 + g, 99 FROM generate_series(1, 10) g");
$n1_rows = scalar_query(1, "SELECT count(*) FROM history");
ok(wait_until(60, sub { standby_query("SELECT count(*) FROM history WHERE batch = 99") eq '10' }),
   'the promoted node received the new rows');
sleep(2);

is(standby_query(counts()), "$n1_rows rows, 0 duplicates",
   'the promoted node holds every history row exactly once');
is(standby_query("SELECT count(*) FROM keyed"),
   scalar_query(1, "SELECT count(*) FROM keyed"),
   'the keyed table matches too');
is(standby_query("SELECT count(*) FROM spock.exception_log"), '0',
   'nothing was logged as an exception');

system("$pg_bin/pg_ctl stop -m fast -w -D $standby_dir >/dev/null 2>&1");
system("rm -rf $standby_dir");
system_or_bail("$pg_bin/pg_ctl", 'start', '-w', '-D', $config->{node_datadirs}[1],
               '-l', "$log_dir/028_n2_restart.log");

destroy_cluster('Destroy cluster after the subscriber failover test');
done_testing();
