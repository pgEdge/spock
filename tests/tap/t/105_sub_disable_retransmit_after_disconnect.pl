use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status
);

# A connection-class error after BEGIN aborts the local transaction and makes
# the provider retransmit it.  The exception marker recorded by handle_begin()
# must not make the replacement worker treat that valid retransmission as
# exception replay under SUB_DISABLE.

create_cluster(2, 'Create 2-node reconnect retransmission test cluster');

my $config = get_test_config();
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $conn = "host=$config->{host} dbname=$config->{db_name} port=$p1 " .
           "user=$config->{db_user} password=$config->{db_password}";
my $subscriber_log = "$config->{log_dir}/00${p2}.log";

psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = sub_disable");
psql_or_bail(2, "SELECT pg_reload_conf()");

psql_or_bail(1, "CREATE TABLE reconnect_retransmit (id int PRIMARY KEY, val text)");
psql_or_bail(2, "CREATE TABLE reconnect_retransmit (id int PRIMARY KEY, val text)");

# Sequence increments are non-transactional, so SQLSTATE 08006 is raised only
# on the first apply attempt.  ENABLE REPLICA restricts the trigger to apply.
psql_or_bail(2, q{
    CREATE SEQUENCE reconnect_fail_once;
    CREATE FUNCTION reconnect_fail_once() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
        IF nextval('reconnect_fail_once') = 1 THEN
            RAISE EXCEPTION 'injected provider connection loss'
                USING ERRCODE = '08006';
        END IF;
        RETURN NEW;
    END $$;
    CREATE TRIGGER reconnect_fail_once_trg
        BEFORE INSERT ON reconnect_retransmit
        FOR EACH ROW EXECUTE FUNCTION reconnect_fail_once();
    ALTER TABLE reconnect_retransmit
        ENABLE REPLICA TRIGGER reconnect_fail_once_trg;
});

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

my $log_offset = -s $subscriber_log // 0;
psql_or_bail(1, "INSERT INTO reconnect_retransmit VALUES (1, 'must survive reconnect')");

my $applied = 0;
for (1 .. 60) {
    $applied = scalar_query(2,
        "SELECT count(*) FROM reconnect_retransmit WHERE id = 1");
    last if defined $applied && $applied eq '1';
    sleep(1);
}
is($applied, '1', 'retransmitted transaction is applied after worker restart');

is(scalar_query(2,
       "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'"),
   't', 'SUB_DISABLE subscription remains enabled');
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription returns to replicating state');
is(scalar_query(2, "SELECT last_value FROM reconnect_fail_once"),
   '2', 'replica trigger proves the transaction was attempted twice');

my $new_log = '';
if (open(my $lf, '<', $subscriber_log)) {
    seek($lf, $log_offset, 0);
    local $/;
    $new_log = <$lf> // '';
    close($lf);
}

like($new_log,
     qr/cleared transient exception state after provider connection loss/,
     'connection-loss path clears transient exception state');
unlike($new_log,
       qr/exception handling had no exception.*replay/,
       'retransmission does not enter empty exception replay');

destroy_cluster('Destroy reconnect retransmission test cluster');
done_testing();
