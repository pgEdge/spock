--
-- Version guard: verify that spock.local_node.node_version protects
-- against binary/schema mismatches.
--
SELECT * FROM spock_regress_variables()
\gset
\c :provider_dsn

-- The node was created by the regression setup.  Verify the
-- node_version column exists and carries the current binary version.
SELECT node_version = spock.spock_version_num() AS version_matches
  FROM spock.local_node;

-- Verify the column has a NOT NULL constraint.
SELECT attnotnull FROM pg_attribute
 WHERE attrelid = 'spock.local_node'::regclass AND attname = 'node_version';

-- ---------------------------------------------------------------
-- Scenario: version tampered to 0 (simulates stale schema after
-- binary upgrade without ALTER EXTENSION UPDATE).
-- ---------------------------------------------------------------
UPDATE spock.local_node SET node_version = 0;

-- Any operation that calls get_local_node() should fail.
\set VERBOSITY terse
SELECT * FROM spock.node_info();
\set VERBOSITY default

-- Restore before next DDL (autoddl event trigger calls get_local_node).
UPDATE spock.local_node SET node_version = spock.spock_version_num();

-- ---------------------------------------------------------------
-- Scenario: version set to a future value (simulates binary
-- rollback after schema was already upgraded).
-- ---------------------------------------------------------------
UPDATE spock.local_node SET node_version = 999999;

\set VERBOSITY terse
SELECT * FROM spock.node_info();
\set VERBOSITY default

-- Restore before DDL.
UPDATE spock.local_node SET node_version = spock.spock_version_num();
