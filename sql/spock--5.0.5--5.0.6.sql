/* spock--5.0.5--5.0.6.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.6'" to load this file. \quit

DO $$
BEGIN
    IF spock.spock_version_num() < 50100 THEN
        RAISE EXCEPTION 'This upgrade step requires the spock 5.1 binary. '
            'Please install the spock 5.1 package before running '
            'ALTER EXTENSION spock UPDATE.';
    END IF;
END $$;

ALTER TABLE spock.subscription
    ADD COLUMN sub_created_at timestamptz;
