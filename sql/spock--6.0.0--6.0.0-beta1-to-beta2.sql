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
