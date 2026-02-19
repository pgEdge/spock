--Tuple Origin
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
ALTER SYSTEM SET spock.save_resolutions = on;
SELECT pg_reload_conf();

\c :subscriber_dsn
TRUNCATE spock.resolutions;

\c :provider_dsn
SELECT spock.replicate_ddl($$
    CREATE TABLE users (id int PRIMARY KEY, mgr_id int);
$$);
SELECT * FROM spock.repset_add_table('default', 'users');

BEGIN;
INSERT INTO USERS SELECT 1, 5;
UPDATE USERS SET id = id + 1 WHERE mgr_id < 10; 
UPDATE USERS SET id = id + 1 WHERE mgr_id < 10;
END;

\c :subscriber_dsn
SELECT * FROM users ORDER BY id;

-- Expect 0 rows in spock.resolutions since the origin is the same
SELECT COUNT(*) FROM spock.resolutions
    WHERE relname='public.users'
    AND local_timestamp = remote_timestamp;

-- DELETE the row from subscriber first, in order to create a conflict
DELETE FROM users where id = 3;

\c :provider_dsn
-- This will create a conflict on the subscriber
DELETE FROM users where id = 3;

\c :subscriber_dsn
-- Expect 1 row in spock.resolutions with NULL local_timestamp
SELECT COUNT(*) FROM spock.resolutions
    WHERE relname='public.users'
    AND local_timestamp IS NULL;

-- More tests
\c :provider_dsn
SELECT spock.replicate_ddl($$
	CREATE TABLE basic_conflict (
		id int primary key,
		data text);
$$);

SELECT * FROM spock.repset_add_table('default', 'basic_conflict');

INSERT INTO basic_conflict VALUES (1, 'A'), (2, 'B');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

TRUNCATE spock.resolutions;

SELECT * FROM basic_conflict ORDER BY id;

\c :provider_dsn

UPDATE basic_conflict SET data = 'AAA' WHERE id = 1;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM basic_conflict ORDER BY id;

--- should return nothing
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- now update row locally to set up an origin difference
UPDATE basic_conflict SET data = 'sub-A' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn

-- Update on provider again so subscriber will see
-- an origin different from its local one
UPDATE basic_conflict SET data = 'pub-A' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM basic_conflict ORDER BY id;

-- Origin changes are no longer saved to resolutions
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Clean
TRUNCATE spock.resolutions;

\c :provider_dsn
-- Do update in same transaction as INSERT
BEGIN;
INSERT INTO basic_conflict VALUES (3, 'C');
UPDATE basic_conflict SET data = 'pub-C' WHERE id = 3;
COMMIT;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM basic_conflict ORDER BY id;

-- We should not see a conflict
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

\c :provider_dsn

-- cleanup
\c :provider_dsn
SELECT * FROM spock.repset_remove_table('default', 'users');
SELECT * FROM spock.repset_remove_table('default', 'basic_conflict');

SELECT spock.replicate_ddl($$
    DROP TABLE users CASCADE;
$$);
SELECT spock.replicate_ddl($$
	DROP TABLE basic_conflict;
$$);
ALTER SYSTEM SET spock.save_resolutions = off;
SELECT pg_reload_conf();
