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
  skip_schema := '{spock_regress}'
);

SELECT spock_regress.wait_for_sub('sub_387', 'disabled');
SELECT * FROM spock.sub_show_status(subscription_name := 'sub_387');
SELECT 1 FROM spock.sub_drop('sub_387');

\c :provider_dsn
CREATE SCHEMA schema_one;
CREATE SCHEMA schema_two;
CREATE TABLE schema_one.test_405_1 (x integer PRIMARY KEY);
CREATE TABLE schema_two.test_405_2 (x integer PRIMARY KEY);

SELECT 1 FROM spock.repset_create('repset_405');
SELECT 1 FROM spock.repset_add_table('repset_405', 'schema_one.test_405_1');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn

SELECT 1 FROM spock.sub_create(
  subscription_name := 'sub_405',
  provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=super'	,
  replication_sets := '{repset_405}',
  synchronize_structure := true,
  synchronize_data := false,
  skip_schema := '{spock_regress, public, schema_two}'
);

SELECT spock_regress.wait_for_sub('sub_405', 'replicating');
SELECT * FROM spock.sub_show_status(subscription_name := 'sub_405');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\dn
\dt schema_one.*
\dt schema_two.*

SELECT 1 FROM spock.sub_drop('sub_405');

\c :provider_dsn
SELECT spock.repset_drop('repset_387');
SELECT spock.repset_drop('repset_405');
DROP TABLE test_387;
DROP SCHEMA schema_one,schema_two CASCADE;
