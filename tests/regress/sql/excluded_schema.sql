/* First test whether a table's replication set can be properly manipulated */

SELECT * FROM spock_regress_variables()
\gset

--
-- Test resynchronization
--

\c :provider_dsn

CREATE TABLE spock.test_387 (x integer PRIMARY KEY);
INSERT INTO spock.test_387 (x) VALUES (1);

SELECT 1 FROM spock.repset_create('repset_387');
SELECT 1 FROM spock.repset_add_table('repset_387', 'spock.test_387');

\c :subscriber_dsn
SELECT 1 FROM spock.sub_create(
  subscription_name := 'sub_387',
  provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=super'	,
  replication_sets := '{repset_387}',
  synchronize_structure := true,
  synchronize_data := true,
  skip_schema := '{}'
);

SET statement_timeout = '20s';
DO $$
DECLARE
  cnt integer;
BEGIN -- error_message
  LOOP
    SELECT count(*) FROM spock.exception_log INTO cnt;

    EXIT WHEN cnt > 0;
    END LOOP;
END; $$;

SELECT status FROM spock.sub_show_status(subscription_name := 'sub_387');
SELECT operation,error_message FROM spock.exception_log;
DELETE FROM spock.exception_log WHERE error_message LIKE '%sub_387%';
--DELETE FROM spock.exception_log WHERE error_message LIKE '%sub_387%';
SELECT 1 FROM spock.sub_drop('sub_387');

\c :provider_dsn
SELECT spock.repset_drop('repset_387');
DROP TABLE spock.test_387;
