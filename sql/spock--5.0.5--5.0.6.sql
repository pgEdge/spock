/* spock--5.0.5--5.0.6.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.6'" to load this file. \quit

ALTER TABLE spock.subscription
    ADD COLUMN sub_created_at timestamptz;
