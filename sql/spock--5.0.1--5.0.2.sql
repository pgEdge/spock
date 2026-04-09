/* spock--5.0.1--5.0.2.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.2'" to load this file. \quit

ALTER TABLE spock.subscription
    ADD sub_skip_schema text;

DROP FUNCTION spock.sub_create;

CREATE FUNCTION spock.sub_create(
  subscription_name     name,
  provider_dsn          text,
  replication_sets      text[]   DEFAULT '{default,default_insert_only,ddl_sql}',
  synchronize_structure boolean  DEFAULT false,
  synchronize_data      boolean  DEFAULT false,
  forward_origins       text[]   DEFAULT '{}',
  apply_delay           interval DEFAULT '0',
  force_text_transfer   boolean  DEFAULT false,
  enabled               boolean  DEFAULT true,
  skip_schema           text[]   DEFAULT '{}'
)
RETURNS oid
AS 'MODULE_PATHNAME', 'spock_create_subscription'
LANGUAGE C STRICT VOLATILE;


