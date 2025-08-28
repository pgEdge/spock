--Tuple Origin
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
ALTER SYSTEM SET spock.save_resolutions = on;
SELECT pg_reload_conf();

SELECT spock.replicate_ddl($$
    CREATE TABLE public.users (id int PRIMARY KEY, mgr_id int);
$$);
SELECT * FROM spock.repset_add_table('default', 'users');

BEGIN;
INSERT INTO USERS SELECT 1, 5;
UPDATE USERS SET id = id + 1 WHERE mgr_id < 10; 
UPDATE USERS SET id = id + 1 WHERE mgr_id < 10;
END;

\c :subscriber_dsn
SELECT * FROM users ORDER BY id;

-- Expect 2 rows in spock.resolutions
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


-- cleanup
\c :provider_dsn
SELECT spock.replicate_ddl($$
    DROP TABLE public.users CASCADE;
$$);
ALTER SYSTEM SET spock.save_resolutions = off;
SELECT pg_reload_conf();
