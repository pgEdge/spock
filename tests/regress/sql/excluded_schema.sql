/* First test whether a table's replication set can be properly manipulated */

SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

CREATE TABLE spock.test_387 (x integer PRIMARY KEY);
INSERT INTO spock.test_387 (x) VALUES (1);

SELECT 1 FROM spock.repset_create('repset_387');
SELECT 1 FROM spock.repset_add_table('repset_387', 'spock.test_387');

-- This also states that each test should clean their objects before the end.
SELECT nspname,relname,set_name FROM spock.TABLES
ORDER BY nspname,relname,set_name COLLATE "C";

/*
 * TODO: check, if table in a legal schema, but dependent sequence is not.
 */
ALTER TABLE spock.test_387 SET SCHEMA public;
ALTER TABLE public.test_387 ADD COLUMN y serial;
SELECT 1 FROM spock.repset_add_table('repset_387', 'test_387');

SELECT nspname,relname,set_name FROM spock.TABLES
ORDER BY nspname,relname,set_name COLLATE "C";

\c :subscriber_dsn
SELECT 1 FROM spock.sub_create(
  subscription_name := 'sub_387',
  provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=super'	,
  replication_sets := '{repset_387}',
  synchronize_structure := false,
  synchronize_data := true,
  skip_schema := '{}'
);

SET statement_timeout = '180s'; -- enough to stay away of false positives
DO $$
DECLARE
  cnt integer;
BEGIN
  LOOP
    SELECT count(*) FROM spock.sub_show_status(subscription_name := 'sub_387')
    WHERE status = 'down' INTO cnt;

    EXIT WHEN cnt > 0;
    END LOOP;
END; $$;

SELECT 1 FROM spock.sub_drop('sub_387');

\c :provider_dsn
SELECT spock.repset_drop('repset_387');
DROP TABLE test_387;
