/* spock--6.0.0--6.1.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.1.0'" to load this file. \quit

-- ----
-- Quorum layer
--
-- Spock does not implement consensus; spock.quorum_provider selects the
-- external system consulted for quorum decisions.  Both functions consult
-- the provider afresh, so they are VOLATILE: a STABLE declaration would let
-- the planner fold two calls in one statement into a stale answer.
--
-- has_quorum and is_leader are NULL, not false, when no answer could be
-- obtained: "we are not in a quorum" and "we could not ask" call for
-- different responses during an incident.
-- ----
CREATE FUNCTION spock.quorum_status(
    OUT provider       text,
    OUT has_quorum     boolean,
    OUT is_leader      boolean,
    OUT leader         text,
    OUT last_consulted timestamptz,
    OUT last_error     text)
RETURNS record VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_quorum_status_sql';
REVOKE ALL ON FUNCTION spock.quorum_status() FROM PUBLIC;

-- The membership the layer would act on: the provider's view, restricted to
-- nodes present in spock.node.  Empty while this node is not in a quorum.
CREATE FUNCTION spock.quorum_members(
    OUT member_name text,
    OUT live        boolean,
    OUT voting      boolean,
    OUT last_seen   timestamptz)
RETURNS SETOF record VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_quorum_members_sql';
REVOKE ALL ON FUNCTION spock.quorum_members() FROM PUBLIC;
