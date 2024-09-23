
/* spock--4.0.4--4.1.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '4.1.0'" to load this file. \quit

CREATE TABLE spock.progress (
	node_id oid NOT NULL,
	remote_node_id oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	PRIMARY KEY(node_id, remote_node_id)
) WITH (user_catalog_table=true, fillfactor=50);
