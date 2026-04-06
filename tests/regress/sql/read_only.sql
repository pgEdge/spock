-- Tests for read-only mode (spock.readonly GUC)
-- Verifies three modes (off, local, all), superuser exemption,
-- backward-compatible 'user' alias, utility commands, SECURITY DEFINER,
-- user-imposed transaction_read_only, and replication behavior.
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
-- Store superuser name for reconnections after user switching
SELECT current_user AS regress_su
\gset

-- Setup: test table owned by nonsuper (allows VACUUM/ANALYZE tests)
CREATE TABLE public.ro_test (id int primary key, data text);
ALTER TABLE public.ro_test OWNER TO nonsuper;

-- Verify default state is 'off'
SHOW spock.readonly;

---
--- Test: non-superuser can write when readonly is off
---
SET ROLE nonsuper;
INSERT INTO ro_test VALUES (1, 'nonsuper writes when off');
RESET ROLE;
SELECT count(*) FROM ro_test;

---
--- Test: set readonly to 'local', superuser can still write
---
SET spock.readonly = 'local';
SHOW spock.readonly;

INSERT INTO ro_test VALUES (2, 'superuser writes in local');
SELECT count(*) FROM ro_test;

---
--- Test: non-superuser blocked from DML and DDL in 'local' mode
---
\set VERBOSITY terse
SET ROLE nonsuper;
-- INSERT blocked
INSERT INTO ro_test VALUES (3, 'should fail');
-- UPDATE blocked
UPDATE ro_test SET data = 'fail' WHERE id = 1;
-- DELETE blocked
DELETE FROM ro_test WHERE id = 1;
-- TRUNCATE blocked
TRUNCATE ro_test;
-- DDL blocked
CREATE TABLE public.ro_fail (id int);

---
--- Test: utility commands allowed in 'local' mode (still as nonsuper)
--- Spock sets XactReadOnly = true and delegates enforcement entirely to
--- Postgres.  These commands are allowed because Postgres does not call
--- PreventCommandIfReadOnly() for maintenance operations.
---
VACUUM ro_test;
ANALYZE ro_test;

-- Non-superuser can still SELECT
SELECT count(*) FROM ro_test;
-- Non-superuser cannot change spock.readonly
SET spock.readonly = 'off';
RESET ROLE;
\set VERBOSITY default

---
--- Test: backward-compatible 'user' alias maps to 'local'
---
SET spock.readonly = 'user';
SHOW spock.readonly;

\set VERBOSITY terse
SET ROLE nonsuper;
INSERT INTO ro_test VALUES (4, 'fail user alias');
RESET ROLE;
\set VERBOSITY default

---
--- Test: reset to 'off', non-superuser can write again
---
SET spock.readonly = 'off';
SHOW spock.readonly;

SET ROLE nonsuper;
INSERT INTO ro_test VALUES (3, 'nonsuper after reset');
RESET ROLE;
SELECT count(*) FROM ro_test;

---
--- Test: 'all' mode - non-superuser blocked, superuser exempt
---
SET spock.readonly = 'all';
SHOW spock.readonly;

-- Superuser can write in 'all' mode
INSERT INTO ro_test VALUES (4, 'superuser in all');

-- Non-superuser blocked
\set VERBOSITY terse
SET ROLE nonsuper;
INSERT INTO ro_test VALUES (5, 'fail all mode');
RESET ROLE;
\set VERBOSITY default

SELECT count(*) FROM ro_test;

---
--- Test: SECURITY DEFINER function does NOT bypass read-only
--- This is native Postgres behavior: XactReadOnly is a transaction-level
--- flag, and SECURITY DEFINER only switches the effective user for
--- permission checks — it does not change the transaction's read-only
--- state.  Both SECURITY DEFINER and SECURITY INVOKER are blocked.
---
SET spock.readonly = 'local';

CREATE OR REPLACE FUNCTION public.ro_secdef_write()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO ro_test VALUES (99, 'security definer write');
END;
$$;
GRANT EXECUTE ON FUNCTION public.ro_secdef_write() TO nonsuper;

-- SECURITY DEFINER: still blocked despite definer being superuser
SET ROLE nonsuper;
\set VERBOSITY terse
SELECT public.ro_secdef_write();
\set VERBOSITY default
RESET ROLE;
SELECT count(*) FROM ro_test WHERE id = 99;

-- SECURITY INVOKER: also blocked (caller is non-superuser)
CREATE OR REPLACE FUNCTION public.ro_secinv_write()
RETURNS void LANGUAGE plpgsql SECURITY INVOKER AS $$
BEGIN
    INSERT INTO ro_test VALUES (98, 'security invoker write');
END;
$$;
GRANT EXECUTE ON FUNCTION public.ro_secinv_write() TO nonsuper;

SET ROLE nonsuper;
\set VERBOSITY terse
SELECT public.ro_secinv_write();
\set VERBOSITY default
RESET ROLE;
SELECT count(*) FROM ro_test WHERE id = 98;

-- Cleanup
DROP FUNCTION public.ro_secdef_write();
DROP FUNCTION public.ro_secinv_write();
SET spock.readonly = 'off';

---
--- Test: user-imposed transaction_read_only is respected when spock.readonly = off
---
\set VERBOSITY terse
BEGIN;
SET LOCAL transaction_read_only = on;
INSERT INTO ro_test VALUES (5, 'fail user readonly');
ROLLBACK;
\set VERBOSITY default

---
--- Test: ALTER SYSTEM with separate non-superuser connection
---
ALTER SYSTEM SET spock.readonly = 'local';
SELECT pg_reload_conf();

-- New connection as nonsuper inherits system-level setting
\c regression nonsuper
SHOW spock.readonly;

\set VERBOSITY terse
INSERT INTO ro_test VALUES (5, 'fail new conn');
\set VERBOSITY default
SELECT count(*) FROM ro_test;

-- Superuser not blocked
\c regression :regress_su
INSERT INTO ro_test VALUES (5, 'superuser alter system');
SELECT count(*) FROM ro_test;

-- Reset system setting
ALTER SYSTEM RESET spock.readonly;
SELECT pg_reload_conf();

-- Non-superuser can write after ALTER SYSTEM RESET
\c regression nonsuper
INSERT INTO ro_test VALUES (6, 'nonsuper after sys reset');
SELECT count(*) FROM ro_test;

---
--- Test: replication still works when subscriber is in 'local' mode
---

-- Create a replicated table for testing
\c regression :regress_su
SELECT spock.replicate_ddl($$
    CREATE TABLE public.ro_repl_test (id int primary key, data text);
$$);
SELECT * FROM spock.repset_add_table('default', 'ro_repl_test');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- Set subscriber to 'local' readonly
\c :subscriber_dsn
ALTER SYSTEM SET spock.readonly = 'local';
SELECT pg_reload_conf();

-- Insert on provider and wait for replication
\c :provider_dsn
INSERT INTO ro_repl_test VALUES (1, 'local mode repl');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- Data should arrive: 'local' mode does not block apply workers
\c :subscriber_dsn
SELECT * FROM ro_repl_test ORDER BY id;

---
--- Test: auto DDL blocked in read-only mode, nothing replicated
---
\c :provider_dsn
SET spock.enable_ddl_replication = on;
SET spock.readonly = 'local';

-- Non-superuser tries DDL with auto DDL enabled: blocked by read-only
\set VERBOSITY terse
SET ROLE nonsuper;
CREATE TABLE public.ro_autoddl_test (id int);
RESET ROLE;
\set VERBOSITY default

-- Table was never created on provider
SELECT count(*) FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'ro_autoddl_test';

-- Nothing replicated to subscriber
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT count(*) FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'ro_autoddl_test';

---
--- Test: repair_mode() allows local-only writes in read-only mode
---
\c :provider_dsn
-- Provider still in readonly = 'local' from above
-- Superuser uses repair_mode for a local-only fix that won't replicate
BEGIN;
SELECT spock.repair_mode(true) \gset
INSERT INTO ro_repl_test VALUES (99, 'repair data');
SELECT spock.repair_mode(false) \gset
COMMIT;

-- Data exists on provider
SELECT count(*) FROM ro_repl_test WHERE id = 99;

-- But NOT replicated to subscriber
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT count(*) FROM ro_repl_test WHERE id = 99;

-- Reset provider state
\c :provider_dsn
SET spock.readonly = 'off';
SET spock.enable_ddl_replication = off;

---
--- Test: replication paused when subscriber is in 'all' mode
---
ALTER SYSTEM SET spock.readonly = 'all';
SELECT pg_reload_conf();
-- Give apply worker time to detect config change and enter readonly mode
SELECT pg_sleep(2);

\c :provider_dsn
INSERT INTO ro_repl_test VALUES (2, 'all mode repl');

-- Slot should not advance: wait with short timeout
\set VERBOSITY terse
BEGIN;
SET LOCAL statement_timeout = '5s';
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
ROLLBACK;
\set VERBOSITY default

-- Data should NOT have arrived on subscriber
\c :subscriber_dsn
SELECT * FROM ro_repl_test ORDER BY id;

---
--- Test: replication resumes after resetting readonly
---
ALTER SYSTEM RESET spock.readonly;
SELECT pg_reload_conf();

\c :provider_dsn
BEGIN;
SET LOCAL statement_timeout = '30s';
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
COMMIT;

\c :subscriber_dsn
SELECT * FROM ro_repl_test ORDER BY id;

-- Cleanup replicated table and subscriber readonly state
ALTER SYSTEM RESET spock.readonly;
SELECT pg_reload_conf();

\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl($$
    DROP TABLE public.ro_repl_test CASCADE;
$$);
\set VERBOSITY default

---
--- Cleanup
---
\c regression :regress_su
SET spock.readonly = 'off';
DROP TABLE public.ro_test;
