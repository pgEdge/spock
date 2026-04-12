-- resolutions_retention: test spock.resolutions_retention_days GUC and
-- spock.cleanup_resolutions() SQL function.
SELECT * FROM spock_regress_variables()
\gset

-- Configure GUCs up front on both nodes
\c :provider_dsn
ALTER SYSTEM SET spock.save_resolutions = on;
SELECT pg_reload_conf();

\c :subscriber_dsn
ALTER SYSTEM SET spock.save_resolutions = on;
SELECT pg_reload_conf();
SELECT pg_sleep(1);

TRUNCATE spock.resolutions;

-- Setup: create a table and seed it on both sides to enable conflict generation
\c :provider_dsn
SELECT spock.replicate_ddl($$
    CREATE TABLE retention_test (id int PRIMARY KEY, data text);
$$);
SELECT * FROM spock.repset_add_table('default', 'retention_test');
INSERT INTO retention_test VALUES (1, 'one');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- Generate an insert_exists conflict: insert same PK on subscriber first,
-- then provider insert arrives and conflicts.
\c :subscriber_dsn
INSERT INTO retention_test VALUES (2, 'sub-two');

\c :provider_dsn
INSERT INTO retention_test VALUES (2, 'pub-two');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Expect 1 conflict row (insert_exists)
SELECT conflict_type FROM spock.resolutions WHERE relname = 'public.retention_test';

-- Backdate that row to 60 days ago to simulate aged history
UPDATE spock.resolutions
SET log_time = now() - '60 days'::interval
WHERE relname = 'public.retention_test';

-- Expect 1 row total (the 60-day-old one)
SELECT COUNT(*) AS total FROM spock.resolutions WHERE relname = 'public.retention_test';

-- Set retention to 30 days: the 60-day-old row falls outside the window
-- (60 > 30) so cleanup will delete it.
ALTER SYSTEM SET spock.resolutions_retention_days = 30;
SELECT pg_reload_conf();
SELECT pg_sleep(1);
SELECT spock.cleanup_resolutions() AS rows_deleted;

-- Expect 0 rows remaining
SELECT COUNT(*) AS remaining FROM spock.resolutions WHERE relname = 'public.retention_test';

-- Generate a fresh conflict for subsequent tests
INSERT INTO retention_test VALUES (3, 'sub-three');

\c :provider_dsn
INSERT INTO retention_test VALUES (3, 'pub-three');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Expect 1 recent row
SELECT COUNT(*) AS total FROM spock.resolutions WHERE relname = 'public.retention_test';

-- Test that retention_days = 0 disables cleanup: backdate the row so it
-- would be deleted if cleanup ran, then verify the guard prevents deletion.
UPDATE spock.resolutions
SET log_time = now() - '999 days'::interval
WHERE relname = 'public.retention_test';
ALTER SYSTEM SET spock.resolutions_retention_days = 0;
SELECT pg_reload_conf();
SELECT pg_sleep(1);
SELECT spock.cleanup_resolutions() AS rows_deleted;

-- Row should still be there
SELECT COUNT(*) AS remaining FROM spock.resolutions WHERE relname = 'public.retention_test';

-- Test that cleanup runs even when save_resolutions=off: logging controls new
-- inserts only; cleanup is driven solely by retention_days.
UPDATE spock.resolutions
SET log_time = now() - '999 days'::interval
WHERE relname = 'public.retention_test';

ALTER SYSTEM SET spock.resolutions_retention_days = 30;
SELECT pg_reload_conf();
SELECT pg_sleep(1);
ALTER SYSTEM SET spock.save_resolutions = off;
SELECT pg_reload_conf();
SELECT pg_sleep(1);

SELECT spock.cleanup_resolutions() AS rows_deleted;

-- Row should be deleted (save_resolutions=off does not suppress cleanup)
SELECT COUNT(*) AS remaining FROM spock.resolutions WHERE relname = 'public.retention_test';

-- Cleanup
\c :provider_dsn
SELECT * FROM spock.repset_remove_table('default', 'retention_test');
SELECT spock.replicate_ddl($$
    DROP TABLE retention_test CASCADE;
$$);
ALTER SYSTEM SET spock.save_resolutions = off;
SELECT pg_reload_conf();

\c :subscriber_dsn
ALTER SYSTEM RESET spock.resolutions_retention_days;
SELECT pg_reload_conf();
ALTER SYSTEM SET spock.save_resolutions = off;
SELECT pg_reload_conf();
