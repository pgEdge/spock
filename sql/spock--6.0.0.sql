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
    if_nodeid oid REFERENCES node(node_id) ON UPDATE CASCADE,
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
    sub_origin oid NOT NULL REFERENCES node(node_id) ON UPDATE CASCADE,
    sub_target oid NOT NULL REFERENCES node(node_id) ON UPDATE CASCADE,
    sub_origin_if oid NOT NULL REFERENCES node_interface(if_id),
    sub_target_if oid NOT NULL REFERENCES node_interface(if_id),
    sub_enabled boolean NOT NULL DEFAULT true,
    sub_slot_name name NOT NULL,
    sub_replication_sets text[],
    sub_forward_origins text[],
    sub_apply_delay interval NOT NULL DEFAULT '0',
    sub_force_text_transfer boolean NOT NULL DEFAULT 'f',
	sub_skip_lsn pg_lsn NOT NULL DEFAULT '0/0',
	sub_skip_schema text[],
	sub_created_at timestamptz
);
-- Source for sub_id values.
CREATE SEQUENCE spock.sub_id_generator AS integer MINVALUE 1 CYCLE START WITH 1 OWNED BY spock.subscription.sub_id;

CREATE TABLE spock.local_sync_status (
    sync_kind "char" NOT NULL CHECK (sync_kind IN ('i', 's', 'd', 'f')),
    sync_subid oid NOT NULL REFERENCES spock.subscription(sub_id),
    sync_nspname name,
    sync_relname name,
    sync_status "char" NOT NULL,
	sync_statuslsn pg_lsn NOT NULL,
    UNIQUE (sync_subid, sync_nspname, sync_relname)
);

CREATE TABLE spock.exception_log (
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

CREATE TABLE spock.exception_status (
	remote_origin oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	retry_errored_at timestamptz NOT NULL,
	remote_xid bigint NOT NULL,
	status text NOT NULL,
	resolved_at timestamptz,
	resolution_details jsonb,
	PRIMARY KEY(remote_origin, remote_commit_ts, retry_errored_at)
) WITH (user_catalog_table=true);

CREATE TABLE spock.exception_status_detail (
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
		REFERENCES spock.exception_status
) WITH (user_catalog_table=true);

CREATE FUNCTION spock.apply_group_progress (
	OUT dbid              oid,
	OUT node_id           oid,
	OUT remote_node_id    oid,
	OUT remote_commit_ts  timestamptz,
	OUT prev_remote_ts    timestamptz,
	OUT remote_commit_lsn pg_lsn,
	OUT remote_insert_lsn pg_lsn,
	OUT received_lsn      pg_lsn,
	OUT last_updated_ts   timestamptz,
	OUT updated_by_decode bool
) RETURNS SETOF record
LANGUAGE c AS 'MODULE_PATHNAME', 'get_apply_group_progress';

-- Show the Spock apply progress for the current database
-- Columns prev_remote_ts, last_updated_ts, and updated_by_decode is dedicated
-- for internal use only.
CREATE VIEW spock.progress AS
	SELECT * FROM spock.apply_group_progress()
      WHERE dbid = (
        SELECT oid FROM pg_database WHERE datname = current_database()
      );

-- Read peer progress (ros.remote_lsn) for all peer subscriptions.
-- Called while apply workers are paused and the slot's snapshot is imported.
-- Row 0: header (lsn + snapshot placeholder).  Rows 1+: one progress entry per peer.
CREATE FUNCTION spock.read_peer_progress(
    p_slot_name text,
    p_provider_node_id oid,
    p_subscriber_node_id oid
) RETURNS TABLE(
    lsn pg_lsn,
    snapshot text,
    dbid oid,
    node_id oid,
    remote_node_id oid,
    remote_commit_ts timestamptz,
    prev_remote_ts timestamptz,
    remote_commit_lsn pg_lsn,
    remote_insert_lsn pg_lsn,
    received_lsn pg_lsn,
    last_updated_ts timestamptz,
    updated_by_decode boolean
) VOLATILE STRICT LANGUAGE plpgsql AS $$
DECLARE
    v_lsn          pg_lsn;
    v_snap         text;
    rec            record;
    v_n_peers      int := 0;
BEGIN
    /*
     * The slot and snapshot are created by the C caller via the replication
     * protocol.  The slot's snapshot is imported into this transaction.
     * This function just reads peer progress (ros.remote_lsn) while apply
     * workers are paused.
     */

    -- Get the slot's LSN and the imported snapshot for the header row.
    SELECT restart_lsn INTO v_lsn
    FROM pg_replication_slots WHERE slot_name = p_slot_name;
    v_snap := '';  -- snapshot managed by C caller

    RAISE NOTICE 'SPOCK cswp slot=% v_lsn=%', p_slot_name, v_lsn;

    -- Header row: lsn only (snapshot managed by C caller).
    lsn      := v_lsn;
    snapshot := v_snap;
    RETURN NEXT;

    /*
     * Emit one progress row per peer.  With apply workers paused,
     * ros.remote_lsn is exact: it reflects only committed transactions
     * whose effects are visible in the slot snapshot.
     */
    FOR rec IN (
        SELECT p.dbid, p.node_id, p.remote_node_id,
               p.remote_commit_ts, p.prev_remote_ts,
               p.remote_commit_lsn      AS grp_remote_commit_lsn,
               p.remote_insert_lsn,
               p.received_lsn, p.last_updated_ts, p.updated_by_decode,
               ros.remote_lsn           AS ros_remote_lsn,
               sub.sub_slot_name        AS sub_slot_name
        FROM   spock.subscription sub
        JOIN   spock.progress p
               ON  p.remote_node_id = sub.sub_origin
               AND p.node_id        = sub.sub_target
        JOIN   pg_replication_origin o
               ON  o.roname = sub.sub_slot_name
        LEFT JOIN pg_replication_origin_status ros
               ON  ros.local_id = o.roident
        WHERE  sub.sub_target = p_provider_node_id
          AND  sub.sub_origin <> p_subscriber_node_id
    ) LOOP
        v_n_peers := v_n_peers + 1;

        lsn               := v_lsn;
        snapshot          := v_snap;
        dbid              := rec.dbid;
        node_id           := rec.node_id;
        remote_node_id    := rec.remote_node_id;
        remote_commit_ts  := rec.remote_commit_ts;
        prev_remote_ts    := rec.prev_remote_ts;
        remote_commit_lsn := COALESCE(rec.ros_remote_lsn, '0/0'::pg_lsn);
        remote_insert_lsn := rec.remote_insert_lsn;
        received_lsn      := rec.received_lsn;
        last_updated_ts   := rec.last_updated_ts;
        updated_by_decode := rec.updated_by_decode;

        RAISE NOTICE 'SPOCK cswp peer=% resume_lsn=%',
            rec.remote_node_id, remote_commit_lsn;

        RETURN NEXT;
    END LOOP;

    RAISE NOTICE 'SPOCK cswp slot=% done peers=%', p_slot_name, v_n_peers;
END;
$$;

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

CREATE FUNCTION spock.sub_create(
  subscription_name     name,
  provider_dsn          text,
  replication_sets      text[] = '{default,default_insert_only,ddl_sql}',
  synchronize_structure boolean = false,
  synchronize_data      boolean = false,
  forward_origins       text[] = '{}',
  apply_delay           interval DEFAULT '0',
  force_text_transfer   boolean = false,
  enabled               boolean = true,
  skip_schema           text[] = '{}'
)
RETURNS oid
AS 'MODULE_PATHNAME', 'spock_create_subscription'
LANGUAGE C STRICT VOLATILE;

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
CREATE FUNCTION spock.sub_alter_skiplsn(subscription_name name, lsn pg_lsn)
	RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_skip_lsn';

CREATE FUNCTION spock.sub_alter_options(
  subscription_name name,
  options           jsonb
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_alter_subscription_options'
LANGUAGE C STRICT VOLATILE;

-- Turn on the "failover" flag for spock's existing logical replication slots
-- so PostgreSQL 17+ slot synchronization picks them up.  New 6.0.0 slots set
-- the flag at creation time; this helper exists for slots made by older
-- releases and for manual use after pausing replication.
CREATE FUNCTION spock.slot_enable_failover()
RETURNS integer
AS 'MODULE_PATHNAME', 'spock_slot_enable_failover'
LANGUAGE C VOLATILE;
REVOKE ALL ON FUNCTION spock.slot_enable_failover() FROM PUBLIC;

CREATE FUNCTION spock.sub_show_status(
  subscription_name     name DEFAULT NULL,
  OUT subscription_name text,
  OUT status            text,
  OUT provider_node     text,
  OUT provider_dsn      text,
  OUT slot_name         text,
  OUT replication_sets  text[],
  OUT forward_origins   text[]
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'spock_show_subscription_status'
LANGUAGE C STABLE;

CREATE TABLE spock.replication_set (
    set_id oid NOT NULL PRIMARY KEY,
    set_nodeid oid NOT NULL REFERENCES node(node_id) ON UPDATE CASCADE,
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

-- ----------------------------------------------------------------------------
-- Reserved objects: schemas and extensions Spock treats specially.
--
-- Single source of truth (replacing hard-coded lists in the C code) for:
--   * exclude_from_dump - kept out of the structure-sync dump (pg_dump
--     --exclude-schema / --exclude-extension); restoring these on a subscriber
--     that already has them would fail.
--   * block_in_repset   - may not be added to a replication set.
--   * replicate_ddl     - when false, AutoDDL does not ship DDL for this
--                         object (node-local; e.g. pgedge_ace).
--
-- Built-in rows (builtin = true) are seeded by the extension and are protected
-- from removal/modification.  Add your own with spock.reserved_object_add().
-- ----------------------------------------------------------------------------
CREATE TABLE spock.reserved_object (
    name              name    NOT NULL,
    kind              text    NOT NULL CHECK (kind IN ('schema', 'extension')),
    exclude_from_dump boolean NOT NULL DEFAULT true,
    block_in_repset   boolean NOT NULL DEFAULT true,
    -- replicate_ddl applies to schemas only (when false, AutoDDL keeps DDL
    -- targeting the schema node-local).  It is not meaningful for extensions,
    -- so it is required for schemas and must be NULL for extensions.
    replicate_ddl     boolean,
    builtin           boolean NOT NULL DEFAULT false,
    PRIMARY KEY (name, kind),
    CONSTRAINT reserved_object_replicate_ddl_kind
        CHECK ((kind = 'schema') = (replicate_ddl IS NOT NULL))
) WITH (user_catalog_table=true);

-- Preserve operator-added rows across pg_dump/restore; built-ins are re-seeded
-- by this script, so only non-built-in rows are dumped.
SELECT pg_catalog.pg_extension_config_dump('spock.reserved_object', 'WHERE NOT builtin');

-- lolor is excluded from the dump but NOT blocked from replication sets: its
-- tables must replicate so large objects survive a DROP EXTENSION on all nodes.
INSERT INTO spock.reserved_object
    (name, kind, exclude_from_dump, block_in_repset, replicate_ddl, builtin) VALUES
    ('spock',      'schema',    true, true,  true,  true),
    ('spock',      'extension', true, true,  NULL,  true),
    ('snowflake',  'schema',    true, true,  true,  true),
    ('snowflake',  'extension', true, true,  NULL,  true),
    ('lolor',      'schema',    true, false, true,  true),
    ('lolor',      'extension', true, false, NULL,  true),
    ('pgedge_ace', 'schema',    true, true,  false, true);

CREATE FUNCTION spock.reserved_object_guard()
RETURNS trigger AS $$
BEGIN
    IF OLD.builtin THEN
        RAISE EXCEPTION 'cannot % built-in reserved object "%" (%)',
            lower(TG_OP), OLD.name, OLD.kind;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER reserved_object_guard
    BEFORE UPDATE OR DELETE ON spock.reserved_object
    FOR EACH ROW EXECUTE FUNCTION spock.reserved_object_guard();

CREATE FUNCTION spock.reserved_object_add(
    p_name              name,
    p_kind              text,
    p_exclude_from_dump boolean DEFAULT true,
    p_block_in_repset   boolean DEFAULT true,
    p_replicate_ddl     boolean DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    -- replicate_ddl is schema-only.  For a schema, an unset (NULL) argument
    -- defaults to true; for an extension it is always NULL, so the
    -- reserved_object_replicate_ddl_kind CHECK holds without the caller
    -- having to pass NULL explicitly.  (The table is a user_catalog_table,
    -- which forbids INSERT ... ON CONFLICT, so this hand-rolled upsert stands.)
    v_replicate_ddl boolean := CASE WHEN p_kind = 'schema'
                                    THEN COALESCE(p_replicate_ddl, true) END;
BEGIN
    UPDATE spock.reserved_object
       SET exclude_from_dump = p_exclude_from_dump,
           block_in_repset   = p_block_in_repset,
           replicate_ddl     = v_replicate_ddl
     WHERE name = p_name AND kind = p_kind;
    IF NOT FOUND THEN
        BEGIN
            INSERT INTO spock.reserved_object
                (name, kind, exclude_from_dump, block_in_repset, replicate_ddl, builtin)
            VALUES (p_name, p_kind, p_exclude_from_dump, p_block_in_repset, v_replicate_ddl, false);
        EXCEPTION WHEN unique_violation THEN
            UPDATE spock.reserved_object
               SET exclude_from_dump = p_exclude_from_dump,
                   block_in_repset   = p_block_in_repset,
                   replicate_ddl     = v_replicate_ddl
             WHERE name = p_name AND kind = p_kind;
        END;
    END IF;
END;
$$;

CREATE FUNCTION spock.reserved_object_remove(p_name name, p_kind text)
RETURNS void
LANGUAGE sql AS $$
    DELETE FROM spock.reserved_object WHERE name = p_name AND kind = p_kind;
$$;

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
CREATE INDEX ON spock.resolutions (log_time);

CREATE FUNCTION spock.cleanup_resolutions(days integer DEFAULT NULL)
RETURNS bigint VOLATILE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_cleanup_resolutions_sql';
REVOKE ALL ON FUNCTION spock.cleanup_resolutions(integer) FROM PUBLIC;

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

CREATE FUNCTION spock.repset_create(
  set_name           name,
  replicate_insert   boolean = true,
  replicate_update   boolean = true,
  replicate_delete   boolean = true,
  replicate_truncate boolean = true
)
RETURNS oid
AS 'MODULE_PATHNAME', 'spock_create_replication_set'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION spock.repset_alter(set_name name,
    replicate_insert boolean DEFAULT NULL, replicate_update boolean DEFAULT NULL,
    replicate_delete boolean DEFAULT NULL, replicate_truncate boolean DEFAULT NULL)
RETURNS oid CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_replication_set';

CREATE FUNCTION spock.repset_drop(
  set_name name,
  ifexists boolean DEFAULT false
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_drop_replication_set'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION spock.repset_add_table(
  set_name           name,
  relation           regclass,
  synchronize_data   boolean DEFAULT false,
  columns            text[] DEFAULT NULL,
  row_filter         text DEFAULT NULL,
  include_partitions boolean default true
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_replication_set_add_table'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;

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

CREATE FUNCTION spock.sub_resync_table(
	subscription_name name,
	relation          regclass,
	truncate          boolean DEFAULT true
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_alter_subscription_resynchronize_table'
LANGUAGE C STRICT VOLATILE;

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
									search_path text DEFAULT current_setting('search_path'),
									role text DEFAULT CURRENT_USER)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replicate_ddl_command';

CREATE FUNCTION spock.replicate_ddl(command text[],
									replication_sets text[] DEFAULT '{ddl_sql}',
									search_path text DEFAULT current_setting('search_path'),
									role text DEFAULT CURRENT_USER)
RETURNS SETOF boolean STRICT VOLATILE LANGUAGE sql AS
    'SELECT spock.replicate_ddl(cmd, $2, $3, $4) FROM (SELECT unnest(command) cmd)';

CREATE FUNCTION spock.node_info(OUT node_id oid, OUT node_name text,
    OUT sysid text, OUT dbname text, OUT replication_sets text,
    OUT location text, OUT country text, OUT info jsonb)
RETURNS record
STABLE STRICT LANGUAGE c AS 'MODULE_PATHNAME', 'spock_node_info';

CREATE FUNCTION spock.spock_gen_slot_name(
  dbname        name,
  provider_node name,
  subscription  name
) RETURNS name
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

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

CREATE FUNCTION spock.wait_slot_confirm_lsn(slotname name, target pg_lsn)
RETURNS void
AS 'spock','spock_wait_slot_confirm_lsn'
LANGUAGE C;

CREATE FUNCTION spock.sub_wait_for_sync(subscription_name name)
RETURNS void RETURNS NULL ON NULL INPUT
AS 'MODULE_PATHNAME', 'spock_wait_for_subscription_sync_complete'
LANGUAGE C VOLATILE;

CREATE FUNCTION spock.table_wait_for_sync(
	subscription_name name,
	relation          regclass
) RETURNS void RETURNS NULL ON NULL INPUT
AS 'MODULE_PATHNAME', 'spock_wait_for_table_sync_complete'
LANGUAGE C VOLATILE;

CREATE FUNCTION spock.sync_event(transactional boolean DEFAULT false)
RETURNS pg_lsn RETURNS NULL ON NULL INPUT
AS 'MODULE_PATHNAME', 'spock_create_sync_event'
LANGUAGE C VOLATILE;

CREATE FUNCTION spock.pause_apply_workers()
RETURNS void
AS 'MODULE_PATHNAME', 'spock_pause_apply_workers'
LANGUAGE C VOLATILE;

REVOKE ALL ON FUNCTION spock.pause_apply_workers() FROM PUBLIC;

CREATE FUNCTION spock.resume_apply_workers()
RETURNS void
AS 'MODULE_PATHNAME', 'spock_resume_apply_workers'
LANGUAGE C VOLATILE;

REVOKE ALL ON FUNCTION spock.resume_apply_workers() FROM PUBLIC;

CREATE PROCEDURE spock.wait_for_sync_event(
	OUT result          bool,
	origin_id           oid,
	lsn                 pg_lsn,
	timeout             int  DEFAULT 0,
	wait_if_disabled    bool DEFAULT false
) AS $$
DECLARE
	target_id		oid;
	start_time		timestamptz := clock_timestamp();
	progress_lsn	pg_lsn;
	sub_is_enabled	bool;
	sub_slot		name;
BEGIN
	IF origin_id IS NULL THEN
		RAISE EXCEPTION 'Invalid NULL origin_id';
	END IF;
	target_id := node_id FROM spock.node_info();

	-- Upfront existence check is skipped when wait_if_disabled is true because
	-- the subscription may not yet exist (e.g. a newly added node whose
	-- subscriptions are still initializing).  The loop below handles both the
	-- not-found and disabled cases gracefully in that mode.
	IF NOT wait_if_disabled THEN
		SELECT sub_enabled, sub_slot_name INTO sub_is_enabled, sub_slot
			FROM spock.subscription
			WHERE sub_origin = origin_id AND sub_target = target_id;

		IF NOT FOUND THEN
			RAISE EXCEPTION 'No subscription found for replication % => %',
							origin_id, target_id;
		END IF;
	END IF;

	WHILE true LOOP
		-- Re-check subscription state each iteration.  Also re-fetches
		-- sub_slot_name so the loop is self-contained when wait_if_disabled
		-- is true and the pre-loop check was skipped.
		SELECT sub_enabled, sub_slot_name INTO sub_is_enabled, sub_slot
			FROM spock.subscription
			WHERE sub_origin = origin_id AND sub_target = target_id;

		IF NOT FOUND THEN
			IF NOT wait_if_disabled THEN
				RAISE EXCEPTION 'No subscription found for replication % => %',
								origin_id, target_id;
			END IF;
			-- Subscription not yet created; fall through to sleep.
		ELSIF NOT sub_is_enabled THEN
			IF NOT wait_if_disabled THEN
				RAISE EXCEPTION 'Subscription % => % has been disabled',
								origin_id, target_id;
			END IF;
			-- Subscription still initializing; fall through to sleep.
		ELSE
			-- Subscription is enabled; check LSN progress.
			-- Uses PostgreSQL's native origin tracking rather than spock.progress
			SELECT remote_lsn INTO progress_lsn
				FROM pg_replication_origin_status
				WHERE external_id = sub_slot;

			IF progress_lsn IS NOT NULL AND progress_lsn >= lsn THEN
				result = true;
				RETURN;
			END IF;
		END IF;

		IF timeout <> 0 AND
		   EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) >= timeout THEN
			result := false;
			RETURN;
		END IF;

		ROLLBACK;
		PERFORM pg_sleep(0.2);
	END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE PROCEDURE spock.wait_for_sync_event(
	OUT result          bool,
	origin              name,
	lsn                 pg_lsn,
	timeout             int  DEFAULT 0,
	wait_if_disabled    bool DEFAULT false
) AS $$
DECLARE
	origin_id  oid;
BEGIN
	origin_id := node_id FROM spock.node WHERE node_name = origin;
	IF origin_id IS NULL THEN
		RAISE EXCEPTION 'Origin node ''%'' not found', origin;
	END IF;
	CALL spock.wait_for_sync_event(result, origin_id, lsn, timeout, wait_if_disabled);
END;
$$ LANGUAGE plpgsql;

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

CREATE VIEW spock.lag_tracker AS
	SELECT
		origin.node_name AS origin_name,
		n.node_name AS receiver_name,
		MAX(p.remote_commit_ts) AS commit_timestamp,
		MAX(p.remote_commit_lsn) AS commit_lsn,
		MAX(p.remote_insert_lsn) AS remote_insert_lsn,
		MAX(p.received_lsn) AS received_lsn,
		CASE
			WHEN MAX(p.remote_insert_lsn) IS NOT NULL AND MAX(p.remote_commit_lsn) IS NOT NULL
			  THEN MAX(pg_wal_lsn_diff(p.remote_insert_lsn, p.remote_commit_lsn))
			ELSE NULL
		END AS replication_lag_bytes,
		CASE
			WHEN MAX(p.remote_commit_ts) IS NOT NULL AND MAX(p.last_updated_ts) IS NOT NULL
              THEN MAX(p.last_updated_ts - p.remote_commit_ts)
            ELSE NULL
		END AS replication_lag
	FROM spock.progress p
	LEFT JOIN spock.subscription sub ON (p.node_id = sub.sub_target and p.remote_node_id = sub.sub_origin)
	LEFT JOIN spock.node origin ON sub.sub_origin = origin.node_id
	LEFT JOIN spock.node n ON n.node_id = p.node_id
	GROUP BY origin.node_name, n.node_name;

CREATE FUNCTION spock.md5_agg_sfunc(text, anyelement)
	RETURNS text
AS $$ SELECT md5($1 || $2::text) $$
LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE  AGGREGATE spock.md5_agg (ORDER BY anyelement)
(
	STYPE = text,
	SFUNC = spock.md5_agg_sfunc,
	INITCOND = '',
	PARALLEL = SAFE
);

-- ----------------------------------------------------------------------
-- Spock Read Only
-- ----------------------------------------------------------------------
CREATE FUNCTION spock.terminate_active_transactions() RETURNS bool
 AS 'MODULE_PATHNAME', 'spockro_terminate_active_transactions'
 LANGUAGE C STRICT;

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

-- ----
-- Function to determine LSN from commit timestamp
-- ----
-- Returns the end LSN of the last local commit not newer than commit_ts,
-- scanning from the slot's restart_lsn up to the flush position captured at the
-- start of this call; WAL flushed later is not looked at.  Returns NULL when
-- nothing matched, which means "cannot answer" - the scan cannot look behind
-- restart_lsn - rather than "no such commit exists".  A caller that has to
-- have an answer, such as one about to advance a slot, should check for NULL
-- and complain itself.
CREATE FUNCTION spock.get_lsn_from_commit_ts(slot_name name, commit_ts timestamptz)
RETURNS pg_lsn STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_lsn_from_commit_ts';

-- ----
-- Subscription conflict statistics
-- ----
CREATE FUNCTION spock.get_subscription_stats(
	subid                           oid,
	OUT subid                       oid,
	OUT confl_insert_exists         bigint,
	OUT confl_update_origin_differs bigint,
	OUT confl_update_exists         bigint,
	OUT confl_update_missing        bigint,
	OUT confl_delete_origin_differs bigint,
	OUT confl_delete_missing        bigint,
	OUT confl_delete_exists         bigint,
	OUT stats_reset                 timestamptz
)
RETURNS record
AS 'MODULE_PATHNAME', 'spock_get_subscription_stats'
LANGUAGE C STABLE;

CREATE FUNCTION spock.reset_subscription_stats(subid oid DEFAULT NULL)
RETURNS void
AS 'MODULE_PATHNAME', 'spock_reset_subscription_stats'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;

-- ----------------------------------------------------------------------
-- Node monitoring
--
-- The functions read shared memory and return raw rows; the views join
-- them with the catalogs and are the interface meant for operators.
-- ----------------------------------------------------------------------
CREATE FUNCTION spock.get_worker_status(
    OUT worker_slot           integer,
    OUT worker_type           text,
    OUT pid                   integer,
    OUT database_id           oid,
    OUT subscription_id       oid,
    OUT worker_status         text,
    OUT generation            integer,
    OUT terminated_at         timestamptz,
    OUT restart_delay         integer,
    OUT paused                boolean,
    OUT in_exception_handling boolean,
    OUT sync_pending          boolean,
    OUT replay_stop_lsn       pg_lsn,
    OUT remote_wal_insert_lsn pg_lsn,
    OUT sync_schema_name      name,
    OUT sync_table_name       name)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_worker_status';

CREATE FUNCTION spock.get_events(
    OUT event_id        bigint,
    OUT event_time      timestamptz,
    OUT event_type      text,
    OUT severity        text,
    OUT sqlstate        text,
    OUT database_id     oid,
    OUT subscription_id oid,
    OUT pid             integer,
    OUT lsn             pg_lsn,
    OUT detail          text)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_events';

CREATE FUNCTION spock.reset_events() RETURNS void
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_reset_events';

CREATE FUNCTION spock.get_apply_stats(
    OUT database_id                 oid,
    OUT subscription_id             oid,
    OUT worker_starts               bigint,
    OUT worker_failures             bigint,
    OUT provider_connects           bigint,
    OUT provider_disconnects        bigint,
    OUT idle_timeouts               bigint,
    OUT messages_received           bigint,
    OUT bytes_received              bigint,
    OUT xacts_applied               bigint,
    OUT xacts_skipped               bigint,
    OUT xacts_discarded             bigint,
    OUT apply_errors                bigint,
    OUT sync_errors                 bigint,
    OUT deadlocks                   bigint,
    OUT lock_timeouts               bigint,
    OUT constraint_violations       bigint,
    OUT resource_errors             bigint,
    OUT tables_synced               bigint,
    OUT confl_insert_exists         bigint,
    OUT confl_update_origin_differs bigint,
    OUT confl_update_exists         bigint,
    OUT confl_update_missing        bigint,
    OUT confl_delete_origin_differs bigint,
    OUT confl_delete_missing        bigint,
    OUT confl_delete_exists         bigint,
    OUT last_worker_start           timestamptz,
    OUT last_worker_failure         timestamptz,
    OUT last_provider_connect       timestamptz,
    OUT last_provider_disconnect    timestamptz,
    OUT last_message_received       timestamptz,
    OUT last_xact_applied           timestamptz,
    OUT last_apply_error            timestamptz,
    OUT last_sync_error             timestamptz,
    OUT last_table_synced           timestamptz,
    OUT last_error_message          text,
    OUT last_error_lsn              pg_lsn,
    OUT last_error_sqlstate         text,
    OUT last_error_pid              integer,
    OUT stats_reset                 timestamptz)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_apply_stats';

CREATE FUNCTION spock.get_slot_groups(
    OUT slot_group_name name,
    OUT members         integer,
    OUT last_lsn        pg_lsn,
    OUT last_commit_ts  timestamptz)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_slot_groups';

CREATE FUNCTION spock.get_monitor_summary(
    OUT started_at                  timestamptz,
    OUT supervisor_pid              integer,
    OUT worker_slots                integer,
    OUT worker_slots_used           integer,
    OUT apply_paused                boolean,
    OUT events_capacity             integer,
    OUT events_retained             integer,
    OUT events_recorded             bigint,
    OUT subscription_stats_capacity integer,
    OUT subscription_stats_used     integer,
    OUT channel_stats_capacity      integer,
    OUT channel_stats_used          bigint,
    OUT channel_stats_full          boolean)
RETURNS record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_monitor_summary';

CREATE FUNCTION spock.get_system_info(
    OUT hostname              text,
    OUT os_name               text,
    OUT os_release            text,
    OUT os_version            text,
    OUT architecture          text,
    OUT cpu_count             integer,
    OUT memory_bytes          bigint,
    OUT load_average_1min     float8,
    OUT load_average_5min     float8,
    OUT load_average_15min    float8,
    OUT data_directory        text,
    OUT data_disk_total_bytes bigint,
    OUT data_disk_free_bytes  bigint,
    OUT wal_disk_total_bytes  bigint,
    OUT wal_disk_free_bytes   bigint,
    OUT postmaster_pid        integer,
    OUT postmaster_start_time timestamptz,
    OUT postgres_version      text,
    OUT postgres_version_num  integer,
    OUT spock_version         text,
    OUT spock_version_num     integer,
    OUT protocol_version      integer,
    OUT min_protocol_version  integer)
RETURNS record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_system_info';

CREATE FUNCTION spock.get_pending_exceptions(
    OUT subscription_name name,
    OUT commit_lsn        pg_lsn,
    OUT failed_action     integer,
    OUT error_message     text)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_pending_exceptions';

-- Hide the password of a connection string, in keyword and in URI form.
CREATE FUNCTION spock.redact_dsn(dsn text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT pg_catalog.regexp_replace(
               pg_catalog.regexp_replace(dsn,
                   '(password\s*=\s*)(''[^'']*''|\S+)', '\1********', 'gi'),
               '(://[^/@:]+:)[^@]+@', '\1********@', 'g')
$$;

-- The spock parameters and the core parameters replication depends on.
CREATE VIEW spock.settings AS
    SELECT s.name,
           CASE WHEN s.name IN ('spock.primary_dsn',
                                'spock.extra_connection_options')
                THEN spock.redact_dsn(s.setting)
                ELSE s.setting
           END AS setting,
           s.unit,
           s.context,
           s.source,
           s.pending_restart
      FROM pg_catalog.pg_settings AS s
     WHERE s.name LIKE 'spock.%'
        OR s.name IN ('wal_level', 'max_worker_processes',
                      'max_replication_slots', 'max_wal_senders',
                      'max_slot_wal_keep_size', 'track_commit_timestamp',
                      'shared_preload_libraries', 'output_plugin_libraries',
                      'wal_sender_timeout', 'wal_receiver_timeout',
                      'synchronous_commit', 'synchronous_standby_names',
                      'logical_decoding_work_mem', 'hot_standby_feedback',
                      'sync_replication_slots')
     ORDER BY s.name;

-- Health of the host and of the PostgreSQL instance, for the checks that
-- come before any replication question: disk, load, connections, long
-- transactions, wraparound, archiving and WAL volume.
CREATE VIEW spock.system_status AS
    SELECT si.hostname,
           si.os_name,
           si.os_release,
           si.architecture,
           si.cpu_count,
           si.memory_bytes,
           si.load_average_1min,
           si.load_average_5min,
           si.load_average_15min,
           si.data_directory,
           si.data_disk_total_bytes,
           si.data_disk_free_bytes,
           si.wal_disk_total_bytes,
           si.wal_disk_free_bytes,
           (SELECT sum(size) FROM pg_catalog.pg_ls_waldir())::bigint AS wal_size_bytes,
           pg_catalog.pg_database_size(pg_catalog.current_database()) AS database_size_bytes,
           si.postgres_version,
           si.postmaster_pid,
           si.postmaster_start_time,
           pg_catalog.now() - si.postmaster_start_time AS uptime,
           pg_catalog.pg_is_in_recovery() AS in_recovery,
           pg_catalog.current_setting('max_connections')::integer AS max_connections,
           (SELECT count(*) FROM pg_catalog.pg_stat_activity
             WHERE backend_type = 'client backend') AS connections,
           (SELECT count(*) FROM pg_catalog.pg_stat_activity
             WHERE state = 'active' AND backend_type = 'client backend') AS active_connections,
           (SELECT count(*) FROM pg_catalog.pg_stat_activity
             WHERE state LIKE 'idle in transaction%') AS idle_in_transaction,
           (SELECT max(pg_catalog.now() - xact_start) FROM pg_catalog.pg_stat_activity
             WHERE backend_type = 'client backend' AND xact_start IS NOT NULL)
               AS longest_transaction,
           (SELECT max(pg_catalog.now() - state_change) FROM pg_catalog.pg_stat_activity
             WHERE state LIKE 'idle in transaction%') AS longest_idle_in_transaction,
           (SELECT count(*) FROM pg_catalog.pg_stat_activity
             WHERE wait_event_type = 'Lock') AS waiting_on_locks,
           (SELECT count(*) FROM pg_catalog.pg_prepared_xacts) AS prepared_transactions,
           (SELECT count(*) FROM pg_catalog.pg_stat_replication
             WHERE pid NOT IN (SELECT active_pid FROM pg_catalog.pg_replication_slots
                                WHERE active_pid IS NOT NULL AND slot_type = 'logical'))
               AS physical_standbys,
           pg_catalog.age(d.datfrozenxid) AS oldest_xid_age,
           sd.xact_commit,
           sd.xact_rollback,
           sd.deadlocks,
           sd.conflicts AS recovery_conflicts,
           sd.temp_files,
           sd.temp_bytes,
           sd.checksum_failures,
           sd.stats_reset AS database_stats_reset,
           pg_catalog.current_setting('archive_mode') AS archive_mode,
           ar.archived_count,
           ar.last_archived_time,
           ar.failed_count AS archive_failed_count,
           ar.last_failed_time AS last_archive_failure
      FROM spock.get_system_info() AS si
      CROSS JOIN pg_catalog.pg_database AS d
      LEFT JOIN pg_catalog.pg_stat_database AS sd ON sd.datid = d.oid
      CROSS JOIN pg_catalog.pg_stat_archiver AS ar
     WHERE d.datname = pg_catalog.current_database();

-- Every spock process of this database, plus the cluster-wide supervisor.
CREATE VIEW spock.worker_status AS
    SELECT w.worker_slot,
           w.worker_type,
           w.pid,
           w.worker_status,
           w.subscription_id,
           s.sub_name AS subscription_name,
           w.sync_schema_name,
           w.sync_table_name,
           a.backend_start AS started_at,
           a.xact_start,
           a.state AS backend_state,
           a.wait_event_type,
           a.wait_event,
           blk.blocked_by_pids,
           blk.blocking_pid,
           blk.blocking_xact_start,
           blk.blocking_query,
           w.paused,
           w.in_exception_handling,
           w.sync_pending,
           w.replay_stop_lsn,
           w.remote_wal_insert_lsn,
           w.generation,
           w.terminated_at,
           w.restart_delay
      FROM spock.get_worker_status() AS w
      LEFT JOIN spock.subscription AS s ON s.sub_id = w.subscription_id
      LEFT JOIN pg_catalog.pg_stat_activity AS a ON a.pid = w.pid
      LEFT JOIN LATERAL (
               SELECT bp.pids AS blocked_by_pids,
                      b.pid AS blocking_pid,
                      b.xact_start AS blocking_xact_start,
                      b.query AS blocking_query
                 FROM (SELECT pg_catalog.pg_blocking_pids(w.pid) AS pids) AS bp
                 LEFT JOIN pg_catalog.pg_stat_activity AS b ON b.pid = bp.pids[1]
                WHERE pg_catalog.cardinality(bp.pids) > 0) AS blk ON true
     WHERE w.database_id IS NULL
        OR w.database_id = (SELECT d.oid FROM pg_catalog.pg_database AS d
                             WHERE d.datname = pg_catalog.current_database())
     ORDER BY w.worker_slot;

-- Recent events of this database, oldest first.
CREATE VIEW spock.events AS
    SELECT e.event_id,
           e.event_time,
           e.event_type,
           e.severity,
           e.sqlstate,
           e.subscription_id,
           s.sub_name AS subscription_name,
           o.node_name AS provider_node,
           e.pid,
           e.lsn,
           e.detail
      FROM spock.get_events() AS e
      LEFT JOIN spock.subscription AS s ON s.sub_id = e.subscription_id
      LEFT JOIN spock.node AS o ON o.node_id = s.sub_origin
     WHERE e.database_id IS NULL
        OR e.database_id = (SELECT d.oid FROM pg_catalog.pg_database AS d
                             WHERE d.datname = pg_catalog.current_database())
     ORDER BY e.event_id;

-- Activity, tuple and conflict counters of every subscription.
CREATE VIEW spock.subscription_stats AS
    SELECT s.sub_id AS subscription_id,
           s.sub_name AS subscription_name,
           COALESCE(a.worker_starts, 0) AS worker_starts,
           COALESCE(a.worker_failures, 0) AS worker_failures,
           COALESCE(a.provider_connects, 0) AS provider_connects,
           COALESCE(a.provider_disconnects, 0) AS provider_disconnects,
           COALESCE(a.idle_timeouts, 0) AS idle_timeouts,
           COALESCE(a.messages_received, 0) AS messages_received,
           COALESCE(a.bytes_received, 0) AS bytes_received,
           COALESCE(a.xacts_applied, 0) AS xacts_applied,
           COALESCE(a.xacts_skipped, 0) AS xacts_skipped,
           COALESCE(a.xacts_discarded, 0) AS xacts_discarded,
           COALESCE(a.apply_errors, 0) AS apply_errors,
           COALESCE(a.sync_errors, 0) AS sync_errors,
           COALESCE(a.deadlocks, 0) AS deadlocks,
           COALESCE(a.lock_timeouts, 0) AS lock_timeouts,
           COALESCE(a.constraint_violations, 0) AS constraint_violations,
           COALESCE(a.resource_errors, 0) AS resource_errors,
           COALESCE(a.tables_synced, 0) AS tables_synced,
           COALESCE(c.n_tup_ins, 0)::bigint AS n_tup_ins,
           COALESCE(c.n_tup_upd, 0)::bigint AS n_tup_upd,
           COALESCE(c.n_tup_del, 0)::bigint AS n_tup_del,
           COALESCE(c.n_conflict, 0)::bigint AS n_conflict,
           COALESCE(c.n_dca, 0)::bigint AS n_dca,
           a.confl_insert_exists,
           a.confl_update_origin_differs,
           a.confl_update_exists,
           a.confl_update_missing,
           a.confl_delete_origin_differs,
           a.confl_delete_missing,
           a.confl_delete_exists,
           a.last_worker_start,
           a.last_worker_failure,
           a.last_provider_connect,
           a.last_provider_disconnect,
           a.last_message_received,
           a.last_xact_applied,
           a.last_apply_error,
           a.last_sync_error,
           a.last_table_synced,
           a.last_error_message,
           a.last_error_lsn,
           a.last_error_sqlstate,
           a.last_error_pid,
           a.stats_reset
      FROM spock.subscription AS s
      LEFT JOIN spock.get_apply_stats() AS a ON a.subscription_id = s.sub_id
      LEFT JOIN spock.channel_summary_stats AS c ON c.subid = s.sub_id;

-- Synchronization state of subscriptions and of their tables.  A row
-- without a table describes the subscription as a whole.
CREATE VIEW spock.table_sync_status AS
    SELECT s.sub_name AS subscription_name,
           l.sync_nspname AS schema_name,
           l.sync_relname AS table_name,
           CASE l.sync_kind
               WHEN 'i' THEN 'none'
               WHEN 'f' THEN 'full'
               WHEN 's' THEN 'structure'
               WHEN 'd' THEN 'data'
           END AS sync_kind,
           CASE l.sync_status
               WHEN 'i' THEN 'requested'
               WHEN 's' THEN 'copying structure'
               WHEN 'd' THEN 'copying data'
               WHEN 'c' THEN 'copying constraints'
               WHEN 'w' THEN 'waiting for apply'
               WHEN 'p' THEN 'started'
               WHEN 'u' THEN 'catching up'
               WHEN 'y' THEN 'synchronized'
               WHEN 'r' THEN 'ready'
               WHEN 'f' THEN 'failed'
           END AS sync_status,
           l.sync_statuslsn AS status_lsn
      FROM spock.local_sync_status AS l
      JOIN spock.subscription AS s ON s.sub_id = l.sync_subid
     ORDER BY s.sub_name, l.sync_nspname, l.sync_relname;

-- Everything about a subscription on one row: configuration, the worker
-- serving it, replication position and lag, and the most recent error.
CREATE VIEW spock.subscription_status AS
    SELECT s.sub_id AS subscription_id,
           s.sub_name AS subscription_name,
           s.sub_enabled AS enabled,
           CASE
               WHEN w.pid IS NOT NULL THEN
                   CASE
                       WHEN l.sync_status IS NULL THEN 'unknown'
                       WHEN l.sync_status = 'r' THEN 'replicating'
                       ELSE 'initializing'
                   END
               WHEN NOT s.sub_enabled THEN 'disabled'
               ELSE 'down'
           END AS status,
           o.node_name AS provider_node,
           spock.redact_dsn(oi.if_dsn) AS provider_dsn,
           s.sub_slot_name AS slot_name,
           s.sub_replication_sets AS replication_sets,
           s.sub_forward_origins AS forward_origins,
           s.sub_apply_delay AS apply_delay,
           s.sub_skip_lsn AS skip_lsn,
           s.sub_skip_schema AS skip_schema,
           s.sub_force_text_transfer AS force_text_transfer,
           s.sub_created_at AS created_at,
           t.sync_status,
           w.pid AS worker_pid,
           w.worker_status,
           a.backend_start AS worker_started_at,
           w.terminated_at AS worker_terminated_at,
           w.restart_delay AS worker_restart_delay,
           w.paused AS worker_paused,
           w.in_exception_handling,
           blk.blocked_by_pids AS worker_blocked_by_pids,
           blk.blocking_pid AS worker_blocking_pid,
           blk.blocking_query AS worker_blocking_query,
           pe.commit_lsn AS pending_exception_lsn,
           pe.error_message AS pending_exception_error,
           ros.remote_lsn AS origin_lsn,
           p.remote_commit_lsn,
           p.remote_commit_ts,
           p.remote_insert_lsn,
           p.received_lsn,
           pg_catalog.pg_wal_lsn_diff(p.remote_insert_lsn, p.remote_commit_lsn)
               AS replication_lag_bytes,
           p.last_updated_ts - p.remote_commit_ts AS replication_lag,
           st.last_message_received,
           pg_catalog.now() - st.last_message_received AS time_since_last_message,
           st.last_xact_applied,
           st.worker_starts,
           st.worker_failures,
           st.xacts_applied,
           st.apply_errors,
           st.last_apply_error,
           st.last_error_sqlstate,
           st.last_error_pid,
           st.last_error_message
      FROM spock.subscription AS s
      JOIN spock.node AS o ON o.node_id = s.sub_origin
      JOIN spock.node_interface AS oi ON oi.if_id = s.sub_origin_if
      LEFT JOIN spock.local_sync_status AS l
             ON l.sync_subid = s.sub_id
            AND l.sync_nspname IS NULL
            AND l.sync_relname IS NULL
      LEFT JOIN spock.table_sync_status AS t
             ON t.subscription_name = s.sub_name
            AND t.table_name IS NULL
      LEFT JOIN (
               SELECT DISTINCT ON (ws.subscription_id) ws.*
                 FROM spock.get_worker_status() AS ws
                WHERE ws.worker_type = 'apply'
                  AND ws.database_id = (SELECT d.oid FROM pg_catalog.pg_database AS d
                                         WHERE d.datname = pg_catalog.current_database())
                ORDER BY ws.subscription_id, ws.pid IS NULL, ws.worker_slot) AS w
             ON w.subscription_id = s.sub_id
      LEFT JOIN pg_catalog.pg_stat_activity AS a ON a.pid = w.pid
      LEFT JOIN LATERAL (
               SELECT bp.pids AS blocked_by_pids,
                      b.pid AS blocking_pid,
                      b.query AS blocking_query
                 FROM (SELECT pg_catalog.pg_blocking_pids(w.pid) AS pids) AS bp
                 LEFT JOIN pg_catalog.pg_stat_activity AS b ON b.pid = bp.pids[1]
                WHERE pg_catalog.cardinality(bp.pids) > 0) AS blk ON true
      LEFT JOIN spock.progress AS p
             ON p.node_id = s.sub_target
            AND p.remote_node_id = s.sub_origin
      LEFT JOIN pg_catalog.pg_replication_origin_status AS ros
             ON ros.external_id = s.sub_slot_name
      LEFT JOIN spock.get_pending_exceptions() AS pe
             ON pe.subscription_name = s.sub_name
      LEFT JOIN spock.subscription_stats AS st ON st.subscription_id = s.sub_id
     ORDER BY s.sub_name;

-- Every node this node knows about, with the subscription that brings its
-- changes here.  A node with several subscriptions has one row for each.
CREATE VIEW spock.peer_status AS
    SELECT n.node_id,
           n.node_name,
           n.location,
           n.country,
           n.node_id = ln.node_id AS is_local,
           i.dsn,
           ss.subscription_name,
           ss.status AS subscription_status,
           ss.replication_lag,
           ss.replication_lag_bytes,
           ss.last_message_received
      FROM spock.node AS n
      LEFT JOIN spock.local_node AS ln ON true
      LEFT JOIN LATERAL (
               SELECT string_agg(spock.redact_dsn(ni.if_dsn), ', ' ORDER BY ni.if_name)
                 FROM spock.node_interface AS ni
                WHERE ni.if_nodeid = n.node_id) AS i(dsn) ON true
      LEFT JOIN spock.subscription AS s ON s.sub_origin = n.node_id
      LEFT JOIN spock.subscription_status AS ss ON ss.subscription_id = s.sub_id
     ORDER BY n.node_name, ss.subscription_name;

-- The replication sets of the local node with what they carry.
CREATE VIEW spock.replication_set_status AS
    SELECT rs.set_id,
           rs.set_name,
           rs.replicate_insert,
           rs.replicate_update,
           rs.replicate_delete,
           rs.replicate_truncate,
           (SELECT count(*) FROM spock.replication_set_table AS t
             WHERE t.set_id = rs.set_id) AS table_count,
           (SELECT count(*) FROM spock.replication_set_seq AS q
             WHERE q.set_id = rs.set_id) AS sequence_count,
           (SELECT count(*) FROM spock.subscription AS s
             WHERE rs.set_name::text = ANY (s.sub_replication_sets)) AS subscription_count
      FROM spock.replication_set AS rs
      JOIN spock.local_node AS ln ON ln.node_id = rs.set_nodeid
     ORDER BY rs.set_name;

-- The provider side: every spock replication slot of this database with
-- the walsender serving it and the WAL it holds back.
CREATE VIEW spock.slot_status AS
    SELECT rs.slot_name,
           rs.active,
           rs.active_pid,
           sr.application_name AS client_name,
           sr.client_addr,
           sr.backend_start AS connected_at,
           sr.state,
           rs.restart_lsn,
           rs.confirmed_flush_lsn,
           sr.sent_lsn,
           sr.write_lsn,
           sr.flush_lsn,
           sr.replay_lsn,
           pg_catalog.pg_wal_lsn_diff(cur.lsn, rs.restart_lsn) AS retained_wal_bytes,
           pg_catalog.pg_wal_lsn_diff(cur.lsn, rs.confirmed_flush_lsn) AS pending_wal_bytes,
           sr.write_lag,
           sr.flush_lag,
           sr.replay_lag,
           sr.reply_time AS last_reply_time,
           rs.wal_status,
           rs.safe_wal_size,
           rs.catalog_xmin,
           pg_catalog.age(rs.catalog_xmin) AS catalog_xmin_age,
           rs.temporary,
           rs.two_phase,
           srs.total_txns AS decoded_txns,
           srs.total_bytes AS decoded_bytes,
           srs.spill_txns,
           srs.spill_count,
           srs.spill_bytes,
           srs.stream_txns,
           srs.stream_count,
           srs.stream_bytes,
           srs.stats_reset AS decode_stats_reset,
           sg.slot_group_name,
           sg.members AS slot_group_members,
           sg.last_lsn AS slot_group_last_lsn,
           sg.last_commit_ts AS slot_group_last_commit_ts
      FROM pg_catalog.pg_replication_slots AS rs
      CROSS JOIN LATERAL (
               SELECT CASE WHEN pg_catalog.pg_is_in_recovery()
                           THEN pg_catalog.pg_last_wal_replay_lsn()
                           ELSE pg_catalog.pg_current_wal_lsn()
                      END AS lsn) AS cur
      LEFT JOIN pg_catalog.pg_stat_replication AS sr ON sr.pid = rs.active_pid
      LEFT JOIN pg_catalog.pg_stat_replication_slots AS srs
             ON srs.slot_name = rs.slot_name
      LEFT JOIN spock.get_slot_groups() AS sg
             ON rs.slot_name ~ '_[0-9]$'
            AND sg.slot_group_name = pg_catalog.regexp_replace(rs.slot_name, '_[0-9]$', '')
     WHERE rs.plugin = 'spock_output'
       AND rs.database = pg_catalog.current_database()
     ORDER BY rs.slot_name;

-- The whole node on one row.  Every base view is evaluated once.
CREATE VIEW spock.node_status AS
    SELECT n.node_id,
           n.node_name,
           n.location,
           n.country,
           pg_catalog.current_database() AS database_name,
           si.hostname,
           si.os_name || ' ' || si.os_release AS operating_system,
           si.postmaster_pid,
           si.postmaster_start_time,
           spock.spock_version() AS spock_version,
           e.extversion AS extension_version,
           spock.spock_version() <> e.extversion AS extension_update_pending,
           pg_catalog.current_setting('server_version') AS postgres_version,
           m.started_at AS spock_started_at,
           m.supervisor_pid,
           wk.manager_pid,
           pg_catalog.current_setting('spock.readonly') AS readonly_mode,
           m.apply_paused,
           m.worker_slots,
           m.worker_slots_used,
           ss.subscriptions,
           ss.subscriptions_enabled,
           ss.subscriptions_replicating,
           sl.replication_slots,
           sl.replication_slots_active,
           wk.apply_workers,
           wk.sync_workers,
           wk.workers_restart_pending,
           (SELECT count(*) FROM spock.get_pending_exceptions()) AS pending_exceptions,
           tb.replicated_tables,
           tb.unreplicated_tables,
           cur.lsn AS current_wal_lsn,
           (SELECT sum(size) FROM pg_catalog.pg_ls_waldir()) AS wal_size_bytes,
           si.data_disk_free_bytes,
           si.wal_disk_free_bytes,
           sl.max_retained_wal_bytes,
           ss.max_replication_lag_bytes,
           ss.max_replication_lag,
           (SELECT count(*) FROM spock.exception_log) AS exceptions_logged,
           ev.last_event_time,
           ev.last_error_event_time,
           m.events_retained,
           m.events_recorded
      FROM spock.get_monitor_summary() AS m
      CROSS JOIN spock.get_system_info() AS si
      CROSS JOIN LATERAL (
               SELECT CASE WHEN pg_catalog.pg_is_in_recovery()
                           THEN pg_catalog.pg_last_wal_replay_lsn()
                           ELSE pg_catalog.pg_current_wal_lsn()
                      END AS lsn) AS cur
      CROSS JOIN LATERAL (
               SELECT count(*) AS subscriptions,
                      count(*) FILTER (WHERE enabled) AS subscriptions_enabled,
                      count(*) FILTER (WHERE status = 'replicating')
                          AS subscriptions_replicating,
                      max(replication_lag_bytes) AS max_replication_lag_bytes,
                      max(replication_lag) AS max_replication_lag
                 FROM spock.subscription_status) AS ss
      CROSS JOIN LATERAL (
               SELECT count(*) AS replication_slots,
                      count(*) FILTER (WHERE active) AS replication_slots_active,
                      max(retained_wal_bytes) AS max_retained_wal_bytes
                 FROM spock.slot_status) AS sl
      CROSS JOIN LATERAL (
               SELECT max(pid) FILTER (WHERE worker_type = 'manager') AS manager_pid,
                      count(*) FILTER (WHERE worker_type = 'apply' AND pid IS NOT NULL)
                          AS apply_workers,
                      count(*) FILTER (WHERE worker_type = 'sync' AND pid IS NOT NULL)
                          AS sync_workers,
                      count(*) FILTER (WHERE worker_status = 'restart pending')
                          AS workers_restart_pending
                 FROM spock.worker_status) AS wk
      CROSS JOIN LATERAL (
               SELECT max(event_time) AS last_event_time,
                      max(event_time) FILTER (WHERE severity = 'error')
                          AS last_error_event_time
                 FROM spock.events) AS ev
      CROSS JOIN LATERAL (
               SELECT count(DISTINCT relid) FILTER (WHERE set_name IS NOT NULL)
                          AS replicated_tables,
                      count(*) FILTER (WHERE set_name IS NULL) AS unreplicated_tables
                 FROM spock.tables) AS tb
      LEFT JOIN spock.local_node AS ln ON true
      LEFT JOIN spock.node AS n ON n.node_id = ln.node_id
      LEFT JOIN pg_catalog.pg_extension AS e ON e.extname = 'spock';

-- Render the rows of a query as text, one block per row when expanded and
-- an aligned table otherwise.  Values are printed in their PostgreSQL text
-- form.  A failing query becomes one line, so a report is never cut short
-- by a single section.
CREATE FUNCTION spock.report_section(title text, query text,
                                     expanded boolean DEFAULT false)
RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
    first   json;
    keys    text[];
    cols    text;
    rec     record;
    cells   text[] := '{}';
    ncols   integer;
    nrows   integer;
    widths  integer[];
    r       integer;
    k       integer;
    line    text;
BEGIN
    RETURN NEXT '';
    RETURN NEXT '== ' || title || ' ==';

    BEGIN
        EXECUTE format('SELECT row_to_json(q) FROM (%s) AS q LIMIT 1', query)
           INTO first;
        IF first IS NULL THEN
            RETURN NEXT '(no rows)';
            RETURN;
        END IF;

        -- Column names in query order, then every value cast to text.
        keys := ARRAY(SELECT key FROM json_each_text(first));
        SELECT string_agg(format('regexp_replace(%I::text, ''[\n\r]+'', '' '', ''g'')',
                                 key), ', ' ORDER BY ordinality)
          INTO cols
          FROM unnest(keys) WITH ORDINALITY AS u(key, ordinality);

        FOR rec IN EXECUTE format('SELECT ARRAY[%s] AS vals FROM (%s) AS q',
                                  cols, query)
        LOOP
            cells := cells || rec.vals;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        RETURN NEXT format('(error: %s)', SQLERRM);
        RETURN;
    END;

    ncols := cardinality(keys);
    nrows := cardinality(cells) / ncols;

    IF expanded THEN
        widths[1] := (SELECT max(length(key)) FROM unnest(keys) AS key);
        FOR r IN 1 .. nrows LOOP
            IF r > 1 THEN
                RETURN NEXT repeat('-', widths[1] + 3);
            END IF;
            FOR k IN 1 .. ncols LOOP
                RETURN NEXT format('%s | %s', rpad(keys[k], widths[1]),
                                   coalesce(cells[(r - 1) * ncols + k], ''));
            END LOOP;
        END LOOP;
        RETURN;
    END IF;

    FOR k IN 1 .. ncols LOOP
        widths[k] := length(keys[k]);
        FOR r IN 1 .. nrows LOOP
            widths[k] := greatest(widths[k],
                                  length(coalesce(cells[(r - 1) * ncols + k], '')));
        END LOOP;
    END LOOP;

    line := '';
    FOR k IN 1 .. ncols LOOP
        line := line || CASE WHEN k > 1 THEN ' | ' ELSE '' END
                     || rpad(keys[k], widths[k]);
    END LOOP;
    RETURN NEXT line;

    line := '';
    FOR k IN 1 .. ncols LOOP
        line := line || CASE WHEN k > 1 THEN '-+-' ELSE '' END
                     || repeat('-', widths[k]);
    END LOOP;
    RETURN NEXT line;

    FOR r IN 1 .. nrows LOOP
        line := '';
        FOR k IN 1 .. ncols LOOP
            line := line || CASE WHEN k > 1 THEN ' | ' ELSE '' END
                         || rpad(coalesce(cells[(r - 1) * ncols + k], ''), widths[k]);
        END LOOP;
        RETURN NEXT rtrim(line);
    END LOOP;
    RETURN NEXT format('(%s row%s)', nrows, CASE WHEN nrows = 1 THEN '' ELSE 's' END);
END;
$$;

-- The whole node as one text report: host and versions, installed
-- extensions, settings, and every monitoring view one after another.
-- "recent" bounds the events, exceptions and resolutions listed.
CREATE FUNCTION spock.spock_info(recent integer DEFAULT 50)
RETURNS SETOF text
LANGUAGE plpgsql AS $$
BEGIN
    recent := greatest(coalesce(recent, 50), 0);

    RETURN NEXT format('Spock node report: database %s on %s at %s',
                       current_database(),
                       (SELECT hostname FROM spock.get_system_info()),
                       to_char(now(), 'YYYY-MM-DD HH24:MI:SS TZ'));

    RETURN QUERY SELECT spock.report_section('System',
        'SELECT * FROM spock.system_status', true);
    RETURN QUERY SELECT spock.report_section('Installed extensions',
        'SELECT e.extname AS extension, e.extversion AS version,
                n.nspname AS schema, a.default_version AS available_version
           FROM pg_catalog.pg_extension AS e
           JOIN pg_catalog.pg_namespace AS n ON n.oid = e.extnamespace
           LEFT JOIN pg_catalog.pg_available_extensions AS a ON a.name = e.extname
          ORDER BY e.extname');
    RETURN QUERY SELECT spock.report_section('Settings',
        'SELECT name, setting, unit, source, pending_restart FROM spock.settings');
    RETURN QUERY SELECT spock.report_section('Node status',
        'SELECT * FROM spock.node_status', true);
    RETURN QUERY SELECT spock.report_section('Peers',
        'SELECT node_name, is_local, dsn, subscription_name,
                subscription_status, replication_lag, replication_lag_bytes
           FROM spock.peer_status');
    RETURN QUERY SELECT spock.report_section('Subscriptions',
        'SELECT * FROM spock.subscription_status', true);
    RETURN QUERY SELECT spock.report_section('Subscription statistics',
        'SELECT * FROM spock.subscription_stats', true);
    RETURN QUERY SELECT spock.report_section('Workers',
        'SELECT worker_slot, worker_type, pid, worker_status, subscription_name,
                sync_schema_name, sync_table_name, started_at, backend_state,
                wait_event_type, wait_event, blocked_by_pids, blocking_pid,
                in_exception_handling, paused, terminated_at, restart_delay
           FROM spock.worker_status');
    RETURN QUERY SELECT spock.report_section('Pending exceptions',
        'SELECT * FROM spock.get_pending_exceptions()');
    RETURN QUERY SELECT spock.report_section('Replication slots',
        'SELECT * FROM spock.slot_status', true);
    RETURN QUERY SELECT spock.report_section('Replication sets',
        'SELECT * FROM spock.replication_set_status');
    RETURN QUERY SELECT spock.report_section('Tables not in any replication set',
        'SELECT nspname AS schema_name, relname AS table_name
           FROM spock.tables WHERE set_name IS NULL ORDER BY 1, 2');
    RETURN QUERY SELECT spock.report_section('Table synchronization',
        'SELECT * FROM spock.table_sync_status');
    RETURN QUERY SELECT spock.report_section('Lag by node pair',
        'SELECT * FROM spock.lag_tracker');
    RETURN QUERY SELECT spock.report_section('Recent exceptions',
        format('SELECT retry_errored_at, remote_origin, remote_commit_ts,
                       operation, table_schema, table_name, error_message
                  FROM spock.exception_log
                 ORDER BY retry_errored_at DESC LIMIT %s', recent));
    RETURN QUERY SELECT spock.report_section('Recent conflict resolutions',
        format('SELECT log_time, relname, conflict_type, conflict_resolution,
                       local_origin, remote_origin, remote_lsn
                  FROM spock.resolutions
                 ORDER BY log_time DESC LIMIT %s', recent));
    RETURN QUERY SELECT spock.report_section('Recent events',
        format('SELECT event_time, event_type, severity, sqlstate,
                       subscription_name, provider_node, pid, lsn, detail
                  FROM spock.events
                 ORDER BY event_id DESC LIMIT %s', recent));
END;
$$;
