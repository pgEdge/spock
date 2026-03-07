/* spock--5.0.1--5.0.2.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.2'" to load this file. \quit

DO $$
BEGIN
    IF spock.spock_version_num() < 50100 THEN
        RAISE EXCEPTION 'This upgrade step requires the spock 5.1 binary. '
            'Please install the spock 5.1 package before running '
            'ALTER EXTENSION spock UPDATE.';
    END IF;
END $$;

ALTER TABLE spock.subscription
    ADD sub_skip_schema text;

DROP FUNCTION spock.sub_create;

CREATE FUNCTION spock.sub_create(subscription_name name, provider_dsn text,
    replication_sets text[] = '{default,default_insert_only,ddl_sql}', synchronize_structure boolean = false,
    synchronize_data boolean = false, forward_origins text[] = '{}', apply_delay interval DEFAULT '0',
    force_text_transfer boolean = false,
    enabled boolean = true, skip_schema text[] = '{}')
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_subscription';


