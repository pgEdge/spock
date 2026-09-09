/* spock--6.0.0--6.1.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.1.0'" to load this file. \quit

-- Quorum layer.
--
-- Spock does not implement consensus; spock.quorum_provider selects the
-- external system consulted for quorum decisions.  This view exists because
-- anything able to influence WAL retention has to be inspectable before it is
-- trusted to.  has_quorum and is_leader are NULL, not false, when no answer
-- could be obtained: "we are not in a quorum" and "we could not ask" call for
-- different responses during an incident.
CREATE FUNCTION spock.quorum_status(
    OUT provider       text,
    OUT has_quorum     boolean,
    OUT is_leader      boolean,
    OUT leader         text,
    OUT last_consulted timestamptz,
    OUT last_error     text)
-- VOLATILE, not STABLE: the function deliberately invalidates the cached
-- reading and consults the provider afresh, so two calls in one statement
-- can legitimately differ.  STABLE would let the planner fold them together
-- and report a stale answer.
RETURNS record VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_quorum_status_sql';
REVOKE ALL ON FUNCTION spock.quorum_status() FROM PUBLIC;
