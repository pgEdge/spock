\echo Use "CREATE EXTENSION spock" to load this file. \quit

CREATE TABLE spock.node (
    node_id oid NOT NULL PRIMARY KEY,
    node_name name NOT NULL UNIQUE,
    location text,
    country text,
    info jsonb
) WITH (user_catalog_table=true);

CREATE TABLE spock.node_interface (
    if_id oid NOT NULL PRIMARY KEY,
    if_name name NOT NULL, -- default same as node name
    if_nodeid oid REFERENCES node(node_id),
    if_dsn text NOT NULL,
    UNIQUE (if_nodeid, if_name)
);

CREATE TABLE spock.local_node (
    node_id oid PRIMARY KEY REFERENCES node(node_id),
    node_local_interface oid NOT NULL REFERENCES node_interface(if_id)
);

CREATE TABLE spock.subscription (
    sub_id oid NOT NULL PRIMARY KEY,
    sub_name name NOT NULL UNIQUE,
    sub_origin oid NOT NULL REFERENCES node(node_id),
    sub_target oid NOT NULL REFERENCES node(node_id),
    sub_origin_if oid NOT NULL REFERENCES node_interface(if_id),
    sub_target_if oid NOT NULL REFERENCES node_interface(if_id),
    sub_enabled boolean NOT NULL DEFAULT true,
    sub_slot_name name NOT NULL,
    sub_replication_sets text[],
    sub_forward_origins text[],
    sub_apply_delay interval NOT NULL DEFAULT '0',
    sub_force_text_transfer boolean NOT NULL DEFAULT 'f'
);

CREATE TABLE spock.local_sync_status (
    sync_kind "char" NOT NULL CHECK (sync_kind IN ('i', 's', 'd', 'f')),
    sync_subid oid NOT NULL REFERENCES spock.subscription(sub_id),
    sync_nspname name,
    sync_relname name,
    sync_status "char" NOT NULL,
	sync_statuslsn pg_lsn NOT NULL,
    UNIQUE (sync_subid, sync_nspname, sync_relname)
);


CREATE FUNCTION spock.node_create(node_name name, dsn text,
    location text DEFAULT NULL, country text DEFAULT NULL,
    info jsonb DEFAULT NULL)
RETURNS oid CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_node';
CREATE FUNCTION spock.node_drop(node_name name, ifexists boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_node';

CREATE FUNCTION spock.node_add_interface(node_name name, interface_name name, dsn text)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_node_add_interface';
CREATE FUNCTION spock.node_drop_interface(node_name name, interface_name name)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_node_drop_interface';

CREATE FUNCTION spock.sub_create(subscription_name name, provider_dsn text,
    replication_sets text[] = '{default,default_insert_only,ddl_sql}', synchronize_structure boolean = false,
    synchronize_data boolean = false, forward_origins text[] = '{}', apply_delay interval DEFAULT '0',
    force_text_transfer boolean = false)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_subscription';
CREATE FUNCTION spock.sub_drop(subscription_name name, ifexists boolean DEFAULT false)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_subscription';

CREATE FUNCTION spock.sub_alter_interface(subscription_name name, interface_name name)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_interface';

CREATE FUNCTION spock.sub_disable(subscription_name name, immediate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_disable';
CREATE FUNCTION spock.sub_enable(subscription_name name, immediate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_enable';

CREATE FUNCTION spock.sub_add_repset(subscription_name name, replication_set name)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_add_replication_set';
CREATE FUNCTION spock.sub_remove_repset(subscription_name name, replication_set name)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_remove_replication_set';

CREATE FUNCTION spock.sub_show_status(subscription_name name DEFAULT NULL,
    OUT subscription_name text, OUT status text, OUT provider_node text,
    OUT provider_dsn text, OUT slot_name text, OUT replication_sets text[],
    OUT forward_origins text[])
RETURNS SETOF record STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_subscription_status';

CREATE TABLE spock.replication_set (
    set_id oid NOT NULL PRIMARY KEY,
    set_nodeid oid NOT NULL,
    set_name name NOT NULL,
    replicate_insert boolean NOT NULL DEFAULT true,
    replicate_update boolean NOT NULL DEFAULT true,
    replicate_delete boolean NOT NULL DEFAULT true,
    replicate_truncate boolean NOT NULL DEFAULT true,
    UNIQUE (set_nodeid, set_name)
) WITH (user_catalog_table=true);

CREATE TABLE spock.replication_set_table (
    set_id oid NOT NULL,
    set_reloid regclass NOT NULL,
    set_att_list text[],
    set_row_filter pg_node_tree,
    PRIMARY KEY(set_id, set_reloid)
) WITH (user_catalog_table=true);

CREATE TABLE spock.replication_set_seq (
    set_id oid NOT NULL,
    set_seqoid regclass NOT NULL,
    PRIMARY KEY(set_id, set_seqoid)
) WITH (user_catalog_table=true);

CREATE TABLE spock.sequence_state (
	seqoid oid NOT NULL PRIMARY KEY,
	cache_size integer NOT NULL,
	last_value bigint NOT NULL
) WITH (user_catalog_table=true);

CREATE TABLE spock.depend (
    classid oid NOT NULL,
    objid oid NOT NULL,
    objsubid integer NOT NULL,

    refclassid oid NOT NULL,
    refobjid oid NOT NULL,
    refobjsubid integer NOT NULL,

	deptype "char" NOT NULL
) WITH (user_catalog_table=true);

CREATE TABLE spock.pii (
    id int generated always as identity,
    pii_schema text NOT NULL,
    pii_table text NOT NULL,
    pii_column text NOT NULL,
    PRIMARY KEY(id)
) WITH (user_catalog_table=true);

CREATE TABLE spock.resolutions (
    id int generated always as identity,
    node_name name NOT NULL,
    log_time timestamptz NOT NULL,
    relname text,
    idxname text,
    conflict_type text,
    conflict_resolution text,

    -- columns for local changes
    local_origin int,
    local_tuple text,
    local_xid xid,
    local_timestamp timestamptz,

    -- columns for remote changes
    remote_origin int,
    remote_tuple text,
    remote_xid xid,
    remote_timestamp timestamptz,
    remote_lsn pg_lsn,

    PRIMARY KEY(id, node_name)
) WITH (user_catalog_table=true);

CREATE VIEW spock.TABLES AS
    WITH set_relations AS (
        SELECT s.set_name, r.set_reloid
          FROM spock.replication_set_table r,
               spock.replication_set s,
               spock.local_node n
         WHERE s.set_nodeid = n.node_id
           AND s.set_id = r.set_id
    ),
    user_tables AS (
        SELECT r.oid, n.nspname, r.relname, r.relreplident
          FROM pg_catalog.pg_class r,
               pg_catalog.pg_namespace n
         WHERE r.relkind IN ('r', 'p')
           AND r.relpersistence = 'p'
           AND n.oid = r.relnamespace
           AND n.nspname !~ '^pg_'
           AND n.nspname != 'information_schema'
           AND n.nspname != 'spock'
    )
    SELECT r.oid AS relid, n.nspname, r.relname, s.set_name
      FROM pg_catalog.pg_namespace n,
           pg_catalog.pg_class r,
           set_relations s
     WHERE r.relkind IN ('r', 'p')
       AND n.oid = r.relnamespace
       AND r.oid = s.set_reloid
     UNION
    SELECT t.oid AS relid, t.nspname, t.relname, NULL
      FROM user_tables t
     WHERE t.oid NOT IN (SELECT set_reloid FROM set_relations);

CREATE FUNCTION spock.repset_create(set_name name,
    replicate_insert boolean = true, replicate_update boolean = true,
    replicate_delete boolean = true, replicate_truncate boolean = true)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_replication_set';
CREATE FUNCTION spock.repset_alter(set_name name,
    replicate_insert boolean DEFAULT NULL, replicate_update boolean DEFAULT NULL,
    replicate_delete boolean DEFAULT NULL, replicate_truncate boolean DEFAULT NULL)
RETURNS oid CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_replication_set';
CREATE FUNCTION spock.repset_drop(set_name name, ifexists boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_replication_set';

CREATE FUNCTION spock.repset_add_table(set_name name, relation regclass, synchronize_data boolean DEFAULT false,
	columns text[] DEFAULT NULL, row_filter text DEFAULT NULL, include_partitions boolean default true)
RETURNS boolean CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_table';
CREATE FUNCTION spock.repset_add_all_tables(set_name name, schema_names text[], synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_all_tables';
CREATE FUNCTION spock.repset_remove_table(set_name name, relation regclass, include_partitions boolean default true)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_table';

CREATE FUNCTION spock.repset_add_seq(set_name name, relation regclass, synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_sequence';
CREATE FUNCTION spock.repset_add_all_seqs(set_name name, schema_names text[], synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_all_sequences';
CREATE FUNCTION spock.repset_remove_seq(set_name name, relation regclass)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_sequence';

CREATE FUNCTION spock.repset_add_partition(parent regclass, partition regclass default NULL,
    row_filter text default NULL)
RETURNS int CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_partition';

CREATE FUNCTION spock.repset_remove_partition(parent regclass, partition regclass default NULL)
RETURNS int CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_partition';

CREATE FUNCTION spock.sub_alter_sync(subscription_name name, truncate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_synchronize';

CREATE FUNCTION spock.sub_resync_table(subscription_name name, relation regclass,
	truncate boolean DEFAULT true)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_resynchronize_table';

CREATE FUNCTION spock.sync_seq(relation regclass)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_synchronize_sequence';

CREATE FUNCTION spock.table_data_filtered(reltyp anyelement, relation regclass, repsets text[])
RETURNS SETOF anyelement CALLED ON NULL INPUT STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_table_data_filtered';

CREATE FUNCTION spock.repset_show_table(relation regclass, repsets text[], OUT relid oid, OUT nspname text,
	OUT relname text, OUT att_list text[], OUT has_row_filter boolean, OUT relkind "char", OUT relispartition boolean)
RETURNS record STRICT STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_repset_table_info';

CREATE FUNCTION spock.sub_show_table(subscription_name name, relation regclass, OUT nspname text, OUT relname text, OUT status text)
RETURNS record STRICT STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_subscription_table';

CREATE TABLE spock.queue (
    queued_at timestamp with time zone NOT NULL,
    role name NOT NULL,
    replication_sets text[],
    message_type "char" NOT NULL,
    message json NOT NULL
);

CREATE FUNCTION spock.replicate_ddl(command text,
									replication_sets text[] DEFAULT '{ddl_sql}',
									search_path text DEFAULT '',
									role text DEFAULT CURRENT_USER)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replicate_ddl_command';

CREATE FUNCTION spock.replicate_ddl(command text[], replication_sets text[] DEFAULT '{ddl_sql}')
RETURNS SETOF boolean STRICT VOLATILE LANGUAGE sql AS
    'SELECT spock.replicate_ddl(cmd, $2) FROM (SELECT unnest(command) cmd)';

CREATE OR REPLACE FUNCTION spock.queue_truncate()
RETURNS trigger LANGUAGE c AS 'MODULE_PATHNAME', 'spock_queue_truncate';

CREATE FUNCTION spock.node_info(OUT node_id oid, OUT node_name text,
    OUT sysid text, OUT dbname text, OUT replication_sets text,
    OUT location text, OUT country text, OUT info jsonb)
RETURNS record
STABLE STRICT LANGUAGE c AS 'MODULE_PATHNAME', 'spock_node_info';

CREATE FUNCTION spock.spock_gen_slot_name(name, name, name)
RETURNS name
IMMUTABLE STRICT LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock_version() RETURNS text
LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock_version_num() RETURNS integer
LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock_max_proto_version() RETURNS integer
LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock_min_proto_version() RETURNS integer
LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock.get_country() RETURNS text
LANGUAGE sql AS
$$ SELECT current_setting('spock.country') $$;

CREATE FUNCTION
spock.wait_slot_confirm_lsn(slotname name, target pg_lsn)
RETURNS void LANGUAGE c AS 'spock','spock_wait_slot_confirm_lsn';
CREATE FUNCTION spock.sub_wait_for_sync(subscription_name name)
RETURNS void RETURNS NULL ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_wait_for_subscription_sync_complete';

CREATE FUNCTION spock.table_wait_for_sync(subscription_name name, relation regclass)
RETURNS void RETURNS NULL ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_wait_for_table_sync_complete';

CREATE FUNCTION spock.xact_commit_timestamp_origin("xid" xid, OUT "timestamp" timestamptz, OUT "roident" oid)
RETURNS record RETURNS NULL ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_xact_commit_timestamp_origin';

CREATE FUNCTION spock.get_channel_stats(
    OUT subid oid,
	OUT relid oid,
    OUT n_tup_ins bigint,
    OUT n_tup_upd bigint,
    OUT n_tup_del bigint,
	OUT n_conflict bigint,
	OUT n_dca bigint)
RETURNS SETOF record
LANGUAGE c AS 'MODULE_PATHNAME', 'get_channel_stats';

CREATE FUNCTION spock.reset_channel_stats() RETURNS void
LANGUAGE c AS 'MODULE_PATHNAME', 'reset_channel_stats';

CREATE VIEW spock.channel_table_stats AS
  SELECT H.subid, H.relid,
	 CASE H.subid
	 	WHEN 0 THEN '<output>'
		ELSE S.sub_name
	 END AS sub_name,
	 pg_catalog.quote_ident(N.nspname) || '.' || pg_catalog.quote_ident(C.relname) AS table_name,
	 H.n_tup_ins, H.n_tup_upd, H.n_tup_del,
	 H.n_conflict, H.n_dca
  FROM spock.get_channel_stats() AS H
  LEFT JOIN spock.subscription AS S ON S.sub_id = H.subid
  LEFT JOIN pg_catalog.pg_class AS C ON C.oid = H.relid
  LEFT JOIN pg_catalog.pg_namespace AS N ON N.oid = C.relnamespace;

CREATE VIEW spock.channel_summary_stats AS
  SELECT subid, sub_name,
     sum(n_tup_ins) AS n_tup_ins,
     sum(n_tup_upd) AS n_tup_upd,
     sum(n_tup_del) AS n_tup_del,
     sum(n_conflict) AS n_conflict,
     sum(n_dca) AS n_dca
  FROM spock.channel_table_stats
  GROUP BY subid, sub_name;

CREATE FUNCTION spock.prune_conflict_tracking()
RETURNS int4
AS 'MODULE_PATHNAME', 'prune_conflict_tracking'
LANGUAGE C;

CREATE TABLE spock.conflict_tracker (
    relid oid,
    tid tid,

    last_origin int,
    last_xmin xid,
    last_ts timestamptz,

    PRIMARY KEY(relid, tid)
);

CREATE FUNCTION spock.lag_tracker(
    OUT slot_name text,
    OUT commit_lsn pg_lsn,
    OUT commit_timestamp timestamptz
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'lag_tracker_info'
STRICT LANGUAGE C;


CREATE VIEW spock.lag_tracker AS
    SELECT L.slot_name, L.commit_lsn, L.commit_timestamp,
		CASE WHEN pg_wal_lsn_diff(pg_catalog.pg_current_wal_insert_lsn(), S.write_lsn) <= 0 
		THEN '0'::interval
		ELSE pg_catalog.timeofday()::timestamptz - L.commit_timestamp
		END AS replication_lag,
		pg_wal_lsn_diff(pg_catalog.pg_current_wal_insert_lsn(), S.write_lsn) AS replication_lag_bytes
    FROM spock.lag_tracker() L
	LEFT JOIN pg_catalog.pg_stat_replication S ON S.application_name = L.slot_name;


CREATE FUNCTION spock.md5_agg_sfunc(text, anyelement) 
	RETURNS text
	LANGUAGE sql
AS
$$
	SELECT md5($1 || $2::text)
$$;
CREATE  AGGREGATE spock.md5_agg (ORDER BY anyelement)
(
	STYPE = text,
	SFUNC = spock.md5_agg_sfunc,
	INITCOND = ''
);

-- ----------------------------------------------------------------------
-- Spock Read Only
-- ----------------------------------------------------------------------
CREATE FUNCTION spock.set_cluster_readonly() RETURNS bool
 AS 'MODULE_PATHNAME', 'spockro_set_readonly'
 LANGUAGE C STRICT;

CREATE FUNCTION spock.unset_cluster_readonly() RETURNS bool
 AS 'MODULE_PATHNAME', 'spockro_unset_readonly'
 LANGUAGE C STRICT;

CREATE FUNCTION spock.get_cluster_readonly() RETURNS bool
 AS 'MODULE_PATHNAME', 'spockro_get_readonly'
 LANGUAGE C STRICT;

CREATE FUNCTION spock.terminate_active_transactions() RETURNS bool
 AS 'MODULE_PATHNAME', 'spockro_terminate_active_transactions'
 LANGUAGE C STRICT;

-- ----------------------------------------------------------------------
-- We check the PostgreSQL major version number in case a future
-- catalog change forces us to provide different functions for
-- different versions.
-- ----------------------------------------------------------------------
DO $version_dependent$
DECLARE
	pgmajor	integer;
BEGIN
	pgmajor = regexp_replace(regexp_replace(version(), '^PostgreSQL ', ''), '[^0-9].*', '')::integer;

	CASE
		WHEN pgmajor IN (14, 15, 16, 17) THEN

-- ----------------------------------------------------------------------
-- convert_column_to_int8()
--
--	Change the data type of a column to int8 and recursively alter
--	all columns that reference this one through foreign key constraints.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION spock.convert_column_to_int8(p_rel regclass, p_attnum smallint)
RETURNS integer
SET search_path = pg_catalog
AS $$
DECLARE
	v_attr			record;
	v_fk			record;
	v_attidx		integer;
	v_cmd			text;
	v_num_altered	integer := 0;
BEGIN
	-- ----
	-- Get the attribute definition
	-- ----
	SELECT * INTO v_attr
	FROM pg_namespace N
	JOIN pg_class C
		ON N.oid = C.relnamespace
	JOIN pg_attribute A
		ON C.oid = A.attrelid
	WHERE A.attrelid = p_rel
		AND A.attnum = p_attnum;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Attribute % of reation % not found', p_attnum, p_rel;
	END IF;

	-- ----
	-- If the attribute type is not bigint, we change it
	-- ----
	IF v_attr.atttypid <> 'int8'::regtype THEN
		v_cmd = 'ALTER TABLE ' ||
			quote_ident(v_attr.nspname) || '.' ||
			quote_ident(v_attr.relname) ||
			' ALTER COLUMN ' ||
			quote_ident(v_attr.attname) ||
			' SET DATA TYPE int8';
		RAISE NOTICE 'EXECUTE %', v_cmd;
		EXECUTE v_cmd;

		v_num_altered = v_num_altered + 1;
	END IF;

	-- ----
	-- Convert foreign keys referencing this column as well
	-- ----
	FOR v_fk IN
		SELECT * FROM pg_constraint F
			JOIN pg_class C
				ON C.oid = F.conrelid
			JOIN pg_namespace N
				ON N.oid = C.relnamespace
			WHERE F.contype = 'f'
			AND F.confrelid = v_attr.attrelid
	LOOP
		-- ----
		-- Lookup the attribute index in the possibly compount FK
		-- ----
		v_attidx = array_position(v_fk.confkey, v_attr.attnum);
		IF v_attidx IS NULL THEN
			CONTINUE;
		END IF;

		-- ----
		-- Recurse for the referencing column
		-- ----
		v_num_altered = v_num_altered +
			spock.convert_column_to_int8(v_fk.conrelid,
										 v_fk.conkey[v_attidx]);
	END LOOP;
	RETURN v_num_altered;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------
-- convert_sequence_to_snowflake()
--
--	Convert the DEFAULT expression for a sequence to snowflake's nextval()
--	function. Eventually change the data type of columns using it
--	to bigint.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION spock.convert_sequence_to_snowflake(p_seqid regclass)
RETURNS integer
SET search_path = pg_catalog
AS $$
DECLARE
	v_attrdef		record;
	v_attr			record;
	v_seq			record;
	v_cmd			text;
	v_num_altered	integer := 0;
BEGIN
	-- ----
	-- We are looking for column defaults that use the requested
	-- sequence and the function nextval().
	-- ----
	FOR v_attrdef IN
		SELECT AD.*,
			pg_get_expr(AD.adbin, AD.adrelid, true) adstr
		FROM pg_depend D
		JOIN pg_attrdef AD
			ON D.refclassid = 'pg_class'::regclass
			AND AD.adrelid = D.refobjid
			AND AD.adnum = D.refobjsubid
		WHERE D.classid = 'pg_class'::regclass
			AND D.objid = p_seqid
	LOOP
		IF v_attrdef.adstr NOT LIKE 'nextval(%' THEN
			CONTINUE;
		END IF;

		-- ----
		-- Get the attribute definition
		-- ----
		SELECT * INTO v_attr
		FROM pg_namespace N
		JOIN pg_class C
			ON N.oid = C.relnamespace
		JOIN pg_attribute A
			ON C.oid = A.attrelid
		WHERE A.attrelid = v_attrdef.adrelid
			AND A.attnum = v_attrdef.adnum;

		IF NOT FOUND THEN
			RAISE EXCEPTION 'Attribute for % not found', v_attrdef.adstr;
		END IF;

		-- ----
		-- Get the sequence definition
		-- ----
		SELECT * INTO v_seq
		FROM pg_namespace N
		JOIN pg_class C
			ON N.oid = C.relnamespace
		WHERE C.oid = p_seqid;

		IF NOT FOUND THEN
			RAISE EXCEPTION 'Sequence with Oid % not found', p_seqid;
		END IF;

		-- ----
		-- If the attribute type is not bigint, we change it
		-- ----
		v_num_altered = v_num_altered +
			spock.convert_column_to_int8(v_attr.attrelid, v_attr.attnum);

		-- ----
		-- Now we can change the default to snowflake.nextval()
		-- ----
		v_cmd = 'ALTER TABLE ' ||
			quote_ident(v_attr.nspname) || '.' ||
			quote_ident(v_attr.relname) ||
			' ALTER COLUMN ' ||
			quote_ident(v_attr.attname) ||
			' SET DEFAULT snowflake.nextval(''' ||
			quote_ident(v_seq.nspname) || '.' ||
			quote_ident(v_seq.relname) ||
			'''::regclass)';
		RAISE NOTICE 'EXECUTE %', v_cmd;
		EXECUTE v_cmd;

		v_num_altered = v_num_altered + 1;
	END LOOP;
	RETURN v_num_altered;
END;
$$ LANGUAGE plpgsql;

	-- END pgmajor in (15, 16, 17)
	ELSE
		RAISE EXCEPTION 'Unsupported PostgreSQL major version %', pgmajor;
	END CASE;
-- End of PG major version dependent PL/pgSQL definitions
END;
$version_dependent$ LANGUAGE plpgsql;
