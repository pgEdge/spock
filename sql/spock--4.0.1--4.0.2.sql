
/* spock--4.0.1--4.0.2.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '4.0.2'" to load this file. \quit

-- ----
-- Change the layout and primary key of the exception_log* tables
-- ----
CREATE TABLE spock.exception_log_temp (
	remote_origin oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	command_counter integer NOT NULL,
	retry_errored_at timestamptz NOT NULL,
	remote_xid bigint NOT NULL,
	local_origin oid,
	local_commit_ts timestamptz,
	table_schema text,
	table_name text,
	operation text,
	local_tup jsonb,
	remote_old_tup jsonb,
	remote_new_tup jsonb,
	ddl_statement text,
	ddl_user text,
	error_message text NOT NULL,
	PRIMARY KEY(remote_origin, remote_commit_ts,
				command_counter, retry_errored_at)
) WITH (user_catalog_table=true);

INSERT INTO spock.exception_log_temp
	SELECT remote_origin,
		   remote_commit_ts,
		   command_counter,
		   retry_errored_at,
		   remote_xid,
		   local_origin,
		   local_commit_ts,
		   table_schema,
		   table_name,
		   operation,
		   local_tup,
		   remote_old_tup,
		   remote_new_tup,
		   ddl_statement,
		   ddl_user,
		   error_message
	FROM spock.exception_log;

DROP TABLE spock.exception_log;
ALTER TABLE spock.exception_log_temp RENAME TO exception_log;

CREATE TABLE spock.exception_status_temp (
	remote_origin oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	retry_errored_at timestamptz NOT NULL,
	remote_xid bigint NOT NULL,
	status text NOT NULL,
	resolved_at timestamptz,
	resolution_details jsonb,
	PRIMARY KEY(remote_origin, remote_commit_ts, retry_errored_at)
) WITH (user_catalog_table=true);

INSERT INTO spock.exception_status_temp
	SELECT remote_origin,
		   remote_commit_ts,
		   'epoch'::timestamptz,
		   remote_xid,
		   status,
		   resolved_at,
		   resolution_details
	FROM spock.exception_status;

CREATE TABLE spock.exception_status_detail_temp (
	remote_origin oid NOT NULL,
    remote_commit_ts timestamptz NOT NULL,
	command_counter integer NOT NULL,
	retry_errored_at timestamptz NOT NULL,
	remote_xid bigint NOT NULL,
	status text NOT NULL,
	resolved_at timestamptz,
	resolution_details jsonb,
	PRIMARY KEY(remote_origin, remote_commit_ts,
				command_counter, retry_errored_at),
	FOREIGN KEY(remote_origin, remote_commit_ts, retry_errored_at)
		REFERENCES spock.exception_status_temp
) WITH (user_catalog_table=true);

INSERT INTO spock.exception_status_detail_temp
	SELECT remote_origin,
		   remote_commit_ts,
		   command_counter,
		   'epoch'::timestamptz,
		   remote_xid,
		   status,
		   resolved_at,
		   resolution_details
	FROM spock.exception_status_detail;

DROP TABLE spock.exception_status_detail;
ALTER TABLE spock.exception_status_detail_temp
	RENAME TO exception_status_detail;

DROP TABLE spock.exception_status;
ALTER TABLE spock.exception_status_temp
	RENAME TO exception_status;
