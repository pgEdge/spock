-- Tests for read-only mode (spock.readonly GUC)
-- Verifies three modes (off, local, all), superuser exemption,
-- backward-compatible 'user' alias, and user-imposed transaction_read_only.
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
-- Store superuser name for reconnections after user switching
SELECT current_user AS regress_su
\gset

-- Setup: test table with grants for nonsuper
CREATE TABLE public.ro_test (id int primary key, data text);
GRANT ALL ON public.ro_test TO nonsuper;

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
--- Test: user-imposed transaction_read_only is respected when spock.readonly = off
---
SET spock.readonly = 'off';
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
SELECT pg_sleep(0.5);

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
SELECT pg_sleep(0.5);

-- Non-superuser can write after ALTER SYSTEM RESET
\c regression nonsuper
INSERT INTO ro_test VALUES (6, 'nonsuper after sys reset');
SELECT count(*) FROM ro_test;

---
--- Cleanup
---
\c regression :regress_su
SET spock.readonly = 'off';
DROP TABLE public.ro_test;
