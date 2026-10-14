/* spock--6.0.0-beta1-to-beta2--6.0.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.0.0'" to load this file. \quit

-- Second half of the beta 1 fix: no changes, only sets the version name back
-- to 6.0.0.  See spock--6.0.0--6.0.0-beta1-to-beta2.sql.  Remove at general
-- availability.
