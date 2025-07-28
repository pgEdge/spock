/* spock--5.0.0--5.0.1.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.1'" to load this file. \quit


CREATE OR REPLACE FUNCTION spock.replicate_ddl(command text,
                                    replication_sets text[] DEFAULT '{ddl_sql}',
                                    search_path text DEFAULT current_setting('search_path'),
                                    role text DEFAULT CURRENT_USER)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replicate_ddl_command';
