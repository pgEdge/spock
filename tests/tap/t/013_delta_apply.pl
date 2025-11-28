use strict;
use warnings;
use Test::More tests => 9;
use IPC::Run;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster system_or_bail get_test_config cross_wire psql_or_bail scalar_query);

create_cluster(3, 'Create initial 2-node Spock test cluster');
cross_wire(2, ['n1', 'n2', 'n3'], 'Cross-wire nodes');

psql_or_bail(3, qq(
	CREATE TABLE t1 (id serial, x integer);
	INSERT INTO t1 (x) VALUES (42);
));

psql_or_bail(3, qq(
CREATE PROCEDURE counter_change(relname text, value integer, cycles integer)
AS \$\$
DECLARE
	i integer := 0;
BEGIN
  WHILE i < cycles LOOP
    EXECUTE format('UPDATE %I SET x = x + %L;', relname, value);
	COMMIT;
	i := i + 1;

  END LOOP;
  raise NOTICE '[%] FINISH: iteration % from %', value, i, cycles;
END;
\$\$ LANGUAGE plpgsql;));

# Cleanup will be handled by SpockTest.pm END block
# No need for done_testing() when using a test plan
