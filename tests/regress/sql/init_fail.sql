
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
SET client_min_messages = 'warning';
DROP ROLE IF EXISTS nonreplica;
CREATE USER nonreplica;

CREATE EXTENSION IF NOT EXISTS spock;
GRANT ALL ON SCHEMA spock TO nonreplica;
GRANT ALL ON ALL TABLES IN SCHEMA spock TO nonreplica;

\c :subscriber_dsn
SET client_min_messages = 'warning';
\set VERBOSITY terse

DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS spock VERSION '6.0.0-devel';
END;
$$;
ALTER EXTENSION spock UPDATE;

-- fail (local node not existing)
SELECT 1 FROM spock.sub_create(
    subscription_name := 'test_subscription',
    provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=nonreplica',
	forward_origins := '{}');

-- succeed
SELECT * FROM spock.node_create(node_name := 'test_subscriber', dsn := (SELECT subscriber_dsn FROM spock_regress_variables()) || ' user=nonreplica');

-- fail (can't connect to remote)
DO $$
BEGIN
    SELECT 1 FROM spock.sub_create(
        subscription_name := 'test_subscription',
        provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=nonexisting',
        forward_origins := '{}');
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '%:%', split_part(SQLERRM, ':', 1), (regexp_matches(SQLERRM, '^.*( FATAL:.*role.*)$'))[1];
END;
$$;

-- fail (remote node not existing)
SELECT 1 FROM spock.sub_create(
    subscription_name := 'test_subscription',
    provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=nonreplica',
	forward_origins := '{}');

\c :provider_dsn
-- succeed
SELECT * FROM spock.node_create(node_name := 'test_provider', dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=nonreplica');

\c :subscriber_dsn
\set VERBOSITY terse

-- fail (can't connect with replication connection to remote)
DO $$
BEGIN
    SELECT 1 FROM spock.sub_create(
        subscription_name := 'test_subscription',
        provider_dsn := (SELECT provider_dsn FROM spock_regress_variables()) || ' user=nonreplica',
            forward_origins := '{}');
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '%', split_part(SQLERRM, ':', 1);
END;
$$;
-- cleanup

SELECT * FROM spock.node_drop('test_subscriber');
DROP EXTENSION spock;

\c :provider_dsn
SELECT * FROM spock.node_drop('test_provider');

SET client_min_messages = 'warning';
DROP OWNED BY nonreplica;
DROP ROLE IF EXISTS nonreplica;
DROP EXTENSION spock;
