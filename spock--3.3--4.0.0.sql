/* spock--3.3--4.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '4.0'" to load this file. \quit

-- ----------------------------------------------------------------------
-- In order to update the node_id, which is referenced by many, first
-- adjust the constraints. It is done by dropping the constraints and
-- then adding them back with the ON UPDATE CASCADE option.
-- ----------------------------------------------------------------------

-- DROP/ADD CONSTRAINS with ON UPDATE CASCADE option.
ALTER TABLE spock.node_interface
    DROP CONSTRAINT node_interface_if_nodeid_fkey,
    ADD CONSTRAINT node_interface_if_nodeid_fkey FOREIGN KEY (if_nodeid) REFERENCES node(node_id) ON UPDATE CASCADE;

ALTER TABLE spock.subscription
    DROP CONSTRAINT subscription_sub_origin_fkey,
    ADD CONSTRAINT subscription_sub_origin_fkey FOREIGN KEY (sub_origin) REFERENCES spock.node(node_id) ON UPDATE CASCADE;

ALTER TABLE spock.subscription
    DROP CONSTRAINT subscription_sub_target_fkey,
    ADD CONSTRAINT subscription_sub_target_fkey FOREIGN KEY (sub_target) REFERENCES spock.node(node_id) ON UPDATE CASCADE;

ALTER TABLE spock.local_node
    DROP CONSTRAINT local_node_node_id_fkey,
    ADD CONSTRAINT local_node_node_id_fkey FOREIGN KEY (node_id) REFERENCES spock.node(node_id) ON UPDATE CASCADE;

ALTER TABLE spock.replication_set
    ADD CONSTRAINT replication_set_set_nodeid_fkey FOREIGN KEY (set_nodeid) REFERENCES spock.node(node_id) ON UPDATE CASCADE;

-- Update the node_id in spock.node to the new encoding style
DO $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN SELECT node_id FROM spock.node LOOP
        -- The new node_id is changed to a uint16 so that it can be used
		-- in the commit-timestamp data as RepOriginId. We generate this
		-- by creating a 32-bit CRC and then truncating it to 16 bits.
		-- Because the old node_id was the full 32-bit CRC, the below
		-- generates the exact same IDs as the 4.0 code does now.
        UPDATE spock.node
        SET node_id = (rec.node_id::int8 & 0xffff)
        WHERE node_id = rec.node_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------
-- Add/Drop objects as per spock--4.0
-- ----------------------------------------------------------------------

-- A single transaction could have multiple erroring rows
CREATE TABLE spock.exception_log (
	remote_origin oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	command_counter integer NOT NULL,
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
	retry_errored_at timestamptz NOT NULL,
	PRIMARY KEY(remote_origin, remote_commit_ts, command_counter)
) WITH (user_catalog_table=true);

ALTER TABLE spock.subscription ADD COLUMN sub_skip_lsn pg_lsn NOT NULL DEFAULT '0/0';

CREATE FUNCTION spock.sub_alter_skiplsn(subscription_name name, lsn pg_lsn)
	RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_skip_lsn';

-- ----
-- Generic delta apply functions for all numeric data types
-- ----
CREATE FUNCTION spock.delta_apply(int2, int2, int2)
RETURNS int2 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_int2';
CREATE FUNCTION spock.delta_apply(int4, int4, int4)
RETURNS int4 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_int4';
CREATE FUNCTION spock.delta_apply(int8, int8, int8)
RETURNS int8 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_int8';
CREATE FUNCTION spock.delta_apply(float4, float4, float4)
RETURNS float4 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_float4';
CREATE FUNCTION spock.delta_apply(float8, float8, float8)
RETURNS float8 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_float8';
CREATE FUNCTION spock.delta_apply(numeric, numeric, numeric)
RETURNS numeric LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_numeric';
CREATE FUNCTION spock.delta_apply(money, money, money)
RETURNS money LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_money';

-- ----
-- Function to control REPAIR mode
-- ----
CREATE FUNCTION spock.repair_mode(enabled bool)
RETURNS pg_catalog.pg_lsn LANGUAGE c
AS 'MODULE_PATHNAME', 'spock_repair_mode';

-- drop deprecated functions/tables
DROP FUNCTION spock.set_cluster_readonly();
DROP FUNCTION spock.unset_cluster_readonly();
DROP FUNCTION spock.get_cluster_readonly();
DROP FUNCTION spock.queue_truncate() CASCADE;
DROP FUNCTION spock.prune_conflict_tracking();
DROP TABLE spock.conflict_tracker;
