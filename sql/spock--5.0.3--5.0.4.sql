
/* spock--5.0.3--5.0.4.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.4'" to load this file. \quit

DO $$
BEGIN
    IF spock.spock_version_num() < 50100 THEN
        RAISE EXCEPTION 'This upgrade step requires the spock 5.1 binary. '
            'Please install the spock 5.1 package before running '
            'ALTER EXTENSION spock UPDATE.';
    END IF;
END $$;
