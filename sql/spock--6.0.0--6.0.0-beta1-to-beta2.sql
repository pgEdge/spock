/* spock--6.0.0--6.0.0-beta1-to-beta2.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.0.0-beta1-to-beta2'" to load this file. \quit

-- One-time catalog fix for nodes installed with 6.0.0-beta.1.
--
-- Beta 1 and beta 2 both call themselves 6.0.0, so a plain ALTER EXTENSION
-- UPDATE has nothing to do on a beta 1 node.  Run instead:
--
--   ALTER EXTENSION spock UPDATE TO '6.0.0-beta1-to-beta2';
--   ALTER EXTENSION spock UPDATE TO '6.0.0';
--
-- This script brings the beta 1 catalog to the beta 2 one; the second step
-- (an empty script) sets the version name back to 6.0.0.  Every statement is
-- written to be a no-op on a catalog that already has the beta 2 objects, so
-- running this on a beta 2 node changes nothing.  The definitions are the
-- same as in spock--6.0.0.sql and spock--5.0.12--6.0.0.sql.
--
-- Remove both files at general availability.

DROP FUNCTION IF EXISTS spock.wait_for_apply_worker(bigint, int);

CREATE OR REPLACE FUNCTION spock.slot_enable_failover()
RETURNS integer
AS 'MODULE_PATHNAME', 'spock_slot_enable_failover'
LANGUAGE C VOLATILE;
REVOKE ALL ON FUNCTION spock.slot_enable_failover() FROM PUBLIC;

-- Beta 1's upgrade from 5.x did not set the failover flag on existing slots.
SELECT spock.slot_enable_failover();

CREATE TABLE IF NOT EXISTS spock.reserved_object (
    name              name    NOT NULL,
    kind              text    NOT NULL CHECK (kind IN ('schema', 'extension')),
    exclude_from_dump boolean NOT NULL DEFAULT true,
    block_in_repset   boolean NOT NULL DEFAULT true,
    replicate_ddl     boolean,
    builtin           boolean NOT NULL DEFAULT false,
    PRIMARY KEY (name, kind),
    CONSTRAINT reserved_object_replicate_ddl_kind
        CHECK ((kind = 'schema') = (replicate_ddl IS NOT NULL))
) WITH (user_catalog_table=true);

SELECT pg_catalog.pg_extension_config_dump('spock.reserved_object', 'WHERE NOT builtin');

-- A user_catalog_table does not allow INSERT ... ON CONFLICT, so skip rows
-- that are already there instead.
INSERT INTO spock.reserved_object
    (name, kind, exclude_from_dump, block_in_repset, replicate_ddl, builtin)
SELECT v.* FROM (VALUES
    ('spock'::name,      'schema',    true, true,  true,  true),
    ('spock',            'extension', true, true,  NULL,  true),
    ('snowflake',        'schema',    true, true,  true,  true),
    ('snowflake',        'extension', true, true,  NULL,  true),
    ('lolor',            'schema',    true, false, true,  true),
    ('lolor',            'extension', true, false, NULL,  true),
    ('coldfront',        'schema',    true, false, true,  true),
    ('coldfront',        'extension', true, false, NULL,  true),
    ('pgedge_ace',       'schema',    true, true,  false, true)
) AS v(name, kind, exclude_from_dump, block_in_repset, replicate_ddl, builtin)
WHERE NOT EXISTS (SELECT 1 FROM spock.reserved_object r
                  WHERE r.name = v.name AND r.kind = v.kind);

CREATE OR REPLACE FUNCTION spock.reserved_object_guard()
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

CREATE OR REPLACE TRIGGER reserved_object_guard
    BEFORE UPDATE OR DELETE ON spock.reserved_object
    FOR EACH ROW EXECUTE FUNCTION spock.reserved_object_guard();

CREATE OR REPLACE FUNCTION spock.reserved_object_add(
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

CREATE OR REPLACE FUNCTION spock.reserved_object_remove(p_name name, p_kind text)
RETURNS void
LANGUAGE sql AS $$
    DELETE FROM spock.reserved_object WHERE name = p_name AND kind = p_kind;
$$;

-- Node metadata refresh and propagation.  Without node_info_apply() an apply
-- worker that receives a peer's metadata change fails, and without the
-- trigger this node's own changes are not sent.

-- Emit a full node-metadata snapshot to direct subscribers only.
CREATE OR REPLACE FUNCTION spock.node_info_emit(
    node_name  name,
    location   text,
    country    text,
    info       jsonb
) RETURNS pg_lsn
AS 'MODULE_PATHNAME', 'spock_node_info_emit'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;
REVOKE ALL ON FUNCTION spock.node_info_emit(name, text, text, jsonb) FROM PUBLIC;

-- Internal metadata update for a cached peer row. The C caller verifies
-- that node_name belongs to the node that originated the transaction.
-- Returns false when no row has that name. A missing row is not created.
CREATE OR REPLACE FUNCTION spock.node_info_apply(
    p_node_name name,
    p_location  text,
    p_country   text,
    p_info      jsonb
) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE spock.node
       SET location = p_location,
           country  = p_country,
           info     = p_info
     WHERE node_name = p_node_name;

    RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION spock.node_info_apply(name, text, text, jsonb) FROM PUBLIC;

-- Broadcast changes to this node's own row. Updates to cached peer rows return
-- without emitting, preventing recursion on receivers.
CREATE OR REPLACE FUNCTION spock.node_info_broadcast() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.node_id IS DISTINCT FROM (SELECT node_id FROM spock.local_node) THEN
        RETURN NULL;
    END IF;

    PERFORM spock.node_info_emit(NEW.node_name, NEW.location,
                                 NEW.country, NEW.info);

    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER node_info_broadcast_trigger
    AFTER UPDATE ON spock.node
    FOR EACH ROW
    EXECUTE FUNCTION spock.node_info_broadcast();

-- Internal: fetch one already-known node's current info via the given
-- dsn. Not meant to be called directly; see spock.node_refresh_info(),
-- which is the one that writes the result into spock.node.
CREATE OR REPLACE FUNCTION spock.node_refresh_info_one(node_id oid, node_name name, dsn text,
    OUT location text, OUT country text, OUT info jsonb)
RETURNS record STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_node_refresh_info_one';
REVOKE ALL ON FUNCTION spock.node_refresh_info_one(oid, name, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION spock.node_refresh_info(p_node_name name DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_local_id oid;
    v_rec      record;
    v_fresh    record;
    v_ok       boolean := true;
BEGIN
    SELECT ni.node_id INTO v_local_id FROM spock.node_info() ni;

    IF p_node_name IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM spock.node n WHERE n.node_name = p_node_name) THEN
            RAISE EXCEPTION 'node "%" not found', p_node_name;
        END IF;
        IF EXISTS (SELECT 1 FROM spock.node n
                   WHERE n.node_name = p_node_name AND n.node_id = v_local_id) THEN
            RAISE EXCEPTION 'cannot refresh info for the local node "%" from itself', p_node_name;
        END IF;
    END IF;

    FOR v_rec IN
        /*
         * Prefer the interface named the same as the node (the default one
         * node_create()/sub_create() set up), but fall back to any other
         * interface the node has rather than silently skipping it -- the
         * default one may have been legally dropped after a subscription
         * was switched to use an alternate interface. Ordering guarantees
         * exactly one row per node (never zero, when at least one interface
         * exists), so a node is never dropped out of this loop -- and thus
         * out of the existence/error checks below -- just because its
         * default-named interface is gone.
         */
        SELECT n.node_id, n.node_name,
               (SELECT ni.if_dsn
                  FROM spock.node_interface ni
                 WHERE ni.if_nodeid = n.node_id
                 ORDER BY (ni.if_name = n.node_name) DESC, ni.if_id
                 LIMIT 1) AS dsn
        FROM spock.node n
        WHERE n.node_id != v_local_id
          AND (p_node_name IS NULL OR n.node_name = p_node_name)
    LOOP
        BEGIN
            IF v_rec.dsn IS NULL THEN
                RAISE EXCEPTION 'node "%" has no usable interface', v_rec.node_name;
            END IF;

            SELECT * INTO v_fresh
              FROM spock.node_refresh_info_one(v_rec.node_id, v_rec.node_name, v_rec.dsn);

            UPDATE spock.node
               SET location = v_fresh.location,
                   country  = v_fresh.country,
                   info     = v_fresh.info
             WHERE node_id = v_rec.node_id;
        EXCEPTION WHEN OTHERS THEN
            IF p_node_name IS NOT NULL THEN
                RAISE;   -- explicit single-node call: bubble the real error up
            END IF;
            RAISE WARNING 'could not refresh info for node "%": %', v_rec.node_name, SQLERRM;
            v_ok := false;
        END;
    END LOOP;

    RETURN v_ok;
END;
$$;

-- Update this node's metadata, merging info and validating tiebreaker.
-- The shared UPDATE trigger handles propagation.
CREATE OR REPLACE FUNCTION spock.node_alter(
    p_location   text  DEFAULT NULL,
    p_country    text  DEFAULT NULL,
    p_info_patch jsonb DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_local_id   oid;
    v_tiebreaker numeric;
    v_rows       int;
BEGIN
    SELECT ni.node_id INTO v_local_id FROM spock.node_info() ni;

    IF p_info_patch IS NOT NULL THEN
        IF jsonb_typeof(p_info_patch) != 'object' THEN
            RAISE EXCEPTION 'info patch must be a JSON object';
        END IF;

        -- Other info keys remain open-ended and unvalidated.
        IF p_info_patch ? 'tiebreaker' THEN
            IF jsonb_typeof(p_info_patch->'tiebreaker') != 'number' THEN
                RAISE EXCEPTION 'invalid "tiebreaker" value %: must be a JSON number, not a string or null',
                    p_info_patch->'tiebreaker';
            END IF;

            v_tiebreaker := (p_info_patch->>'tiebreaker')::numeric;
            IF v_tiebreaker != trunc(v_tiebreaker)
               OR v_tiebreaker NOT BETWEEN -2147483648 AND 2147483647 THEN
                RAISE EXCEPTION 'invalid "tiebreaker" value %: must fit a 32-bit integer',
                    p_info_patch->'tiebreaker';
            END IF;

            -- Store a canonical integer: node_fromtuple() parses the text
            -- form with pg_strtoint32(), which rejects "5.0" or "1e2".
            p_info_patch := jsonb_set(p_info_patch, '{tiebreaker}',
                                      to_jsonb(v_tiebreaker::int));
        END IF;
    END IF;

    UPDATE spock.node
       SET location = COALESCE(p_location, location),
           country  = COALESCE(p_country, country),
           info     = CASE WHEN p_info_patch IS NOT NULL
                            THEN COALESCE(info, '{}'::jsonb) || p_info_patch
                            ELSE info END
     WHERE node_id = v_local_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows != 1 THEN
        RAISE EXCEPTION 'local node (id=%) not found in spock.node', v_local_id;
    END IF;

    RETURN true;
END;
$$;
