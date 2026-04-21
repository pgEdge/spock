
/* spock--5.0.6--5.0.7.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.7'" to load this file. \quit

CREATE FUNCTION spock.pause_apply_workers()
RETURNS void VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_pause_apply_workers';

CREATE FUNCTION spock.resume_apply_workers()
RETURNS void VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_resume_apply_workers';

REVOKE EXECUTE ON FUNCTION spock.pause_apply_workers() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION spock.resume_apply_workers() FROM PUBLIC;
