-- ============================================================================
-- Spock Rescue Workflow Helpers
--
-- This script orchestrates catastrophic node failure recovery by cloning a
-- recovery slot on a healthy peer, wiring a temporary rescue subscription on
-- the lagging node, and providing helpers to resume normal replication after
-- the catch-up completes.
-- Execute these procedures from a coordinator/control node (any node with
-- connectivity to both the advanced peer and the lagging node). The helpers
-- invoke dblink to perform recovery-slot cloning on the source node and
-- suspension/rescue-subscription work on the target node.
--
-- Requirements:
--   * Spock 6.0.0-devel (or newer) with the rescue catalog columns and
--     spock.create_rescue_subscription() installed.
--   * dblink extension available on the coordinator database.
--
-- Usage overview:
--   1. CALL spock.recover_run(
--          failed_node_name := 'n1',
--          source_node_name := 'n2',
--          source_dsn       := 'host=127.0.0.1 port=5432 dbname=pgedge user=pgedge',
--          target_node_name := 'n3',
--          target_dsn       := 'host=127.0.0.1 port=5433 dbname=pgedge user=pgedge',
--          stop_lsn         := '0/5000000'::pg_lsn,
--          skip_lsn         := NULL,
--          stop_timestamp   := NULL,
--          verb             := true,
--          cloned_slot_name => slot_name
--      );
--
--      This performs Phase 1 (precheck) and Phase 2 (clone + rescue subscription).
--      The OUT parameter `slot_name` captures the cloned slot for later cleanup.
--
--   2. Monitor the temporary subscription (spock.subscription.rescue_cleanup_pending)
--      and WAL replay. Once the manager worker reports that the rescue
--      subscription was dropped, finish by resuming the suspended peer
--      subscriptions and dropping the cloned recovery slot:
--
--         CALL spock.recover_finalize(
--             target_dsn        := 'host=… n3 …',
--             target_node_name  := 'n3',
--             failed_node_name  := 'n1',
--             source_dsn        := 'host=… n2 …',
--             cloned_slot_name  := slot_name,
--             verb              := true
--         );
--
-- Notes:
--   * These helpers rely on the SPOC-137 rescue lifecycle features: cloning the
--     recovery slot, suspending peer subscriptions, enabling a temporary rescue
--     subscription (rescue_temporary=true), and allowing the manager worker to
--     cleanly drop the rescue subscription once rescue_cleanup_pending is set.
--   * The helper uses dblink_exec with direct DSN strings. Ensure credentials
--     permit connections from the coordinator database.
--   * The cloned slot is not dropped automatically; call recover_finalize after
--     verifying that the rescue subscription completed successfully.
--   * The stop_lsn parameter defaults to the restart_lsn of the cloned slot.
--     Provide a higher stop_lsn or a stop_timestamp if you need to replay past
--     the restart point.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_precheck
-- Validates connectivity, Spock presence, recovery slot availability, and
-- absence of existing rescue subscriptions before running the recovery flow.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spock.recover_precheck(
    text, text, text, text, text, boolean
);
CREATE OR REPLACE PROCEDURE spock.recover_precheck(
    failed_node_name text,
    source_node_name text,
    source_dsn text,
    target_node_name text,
    target_dsn text,
    verb boolean,
    OUT recovery_needed boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    source_version text;
    target_version text;
    source_local_node text;
    target_local_node text;
    source_slot_count integer;
    target_rescue_subs integer;
    target_origin_subs integer;
    tmp RECORD;
BEGIN
    verb := COALESCE(verb, false);
    recovery_needed := true;

    -- [Coordinator] Validate that source and target nodes are reachable,
    -- running matching Spock versions, and that the rescue metadata is sane.
    IF source_node_name = target_node_name THEN
        RAISE EXCEPTION 'source_node_name (%) and target_node_name (%) must differ',
            source_node_name, target_node_name;
    END IF;
    IF target_node_name = failed_node_name THEN
        RAISE EXCEPTION 'target_node_name (%) cannot equal failed_node_name (%)',
            target_node_name, failed_node_name;
    END IF;

    BEGIN
        SELECT version INTO tmp FROM dblink(source_dsn, 'SELECT version()') AS t(version text);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Unable to connect to source DSN %: %', source_dsn, SQLERRM;
    END;

    BEGIN
        SELECT version INTO tmp FROM dblink(target_dsn, 'SELECT version()') AS t(version text);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Unable to connect to target DSN %: %', target_dsn, SQLERRM;
    END;

    -- [Source node] Ensure Spock is installed.
    SELECT extversion
      INTO source_version
      FROM dblink(
               source_dsn,
               'SELECT extversion FROM pg_extension WHERE extname = ''spock'''
           ) AS t(extversion text);
    IF source_version IS NULL THEN
        RAISE EXCEPTION 'Spock extension not installed on source node %', source_node_name;
    END IF;

    -- [Target node] Ensure Spock is installed.
    SELECT extversion
      INTO target_version
      FROM dblink(
               target_dsn,
               'SELECT extversion FROM pg_extension WHERE extname = ''spock'''
           ) AS t(extversion text);
    IF target_version IS NULL THEN
        RAISE EXCEPTION 'Spock extension not installed on target node %', target_node_name;
    END IF;

    IF regexp_replace(source_version, '-devel$', '') <>
       regexp_replace(target_version, '-devel$', '') THEN
        RAISE EXCEPTION 'Spock version mismatch between source (%) and target (%)',
            source_version, target_version;
    END IF;

    SELECT node_name
      INTO source_local_node
      FROM dblink(
               source_dsn,
               'SELECT n.node_name
                  FROM spock.node n
                  JOIN spock.local_node l ON l.node_id = n.node_id'
           ) AS t(node_name text);
    IF source_local_node IS DISTINCT FROM source_node_name THEN
        RAISE EXCEPTION 'Source DSN resolves to node %, expected %',
            source_local_node, source_node_name;
    END IF;

    SELECT node_name
      INTO target_local_node
      FROM dblink(
               target_dsn,
               'SELECT n.node_name
                  FROM spock.node n
                  JOIN spock.local_node l ON l.node_id = n.node_id'
           ) AS t(node_name text);
    IF target_local_node IS DISTINCT FROM target_node_name THEN
        RAISE EXCEPTION 'Target DSN resolves to node %, expected %',
            target_local_node, target_node_name;
    END IF;

    -- [Source node] Confirm a recovery slot is available/active.
    SELECT cnt
      INTO source_slot_count
      FROM dblink(
               source_dsn,
               $_sql$SELECT count(*)
                    FROM pg_replication_slots
                   WHERE slot_name LIKE 'spk_recovery_%'
                     AND active IS TRUE$_sql$
           ) AS t(cnt int);
    IF source_slot_count = 0 THEN
        RAISE EXCEPTION 'No active recovery slot found on source node %', source_node_name;
    END IF;

    -- [Target node] Ensure there is no existing rescue subscription in flight.
    SELECT cnt
      INTO target_rescue_subs
      FROM dblink(
               target_dsn,
               'SELECT count(*) FROM spock.subscription WHERE sub_rescue_temporary'
           ) AS t(cnt int);
    IF target_rescue_subs > 0 THEN
        RAISE EXCEPTION 'Target node % already has % temporary rescue subscription(s); clean them first',
            target_node_name, target_rescue_subs;
    END IF;

    SELECT cnt
      INTO target_origin_subs
      FROM dblink(
               target_dsn,
               format(
                   $_sql$SELECT count(*)
                        FROM spock.subscription s
                        JOIN spock.node o ON o.node_id = s.sub_origin
                       WHERE o.node_name = %L
                         AND NOT s.sub_rescue_temporary$_sql$,
                   failed_node_name
               )
           ) AS t(cnt int);

    IF target_origin_subs = 0 THEN
        recovery_needed := false;
        IF verb THEN
            RAISE NOTICE '[RESCUE] Target node % has no subscriptions sourced from %; rescue not required.',
                target_node_name, failed_node_name;
        END IF;
        RETURN;
    END IF;

    PERFORM 1
      FROM dblink(
               target_dsn,
               format(
                   $_sql$SELECT 1
                      FROM spock.node
                     WHERE node_name = %L$_sql$,
                   failed_node_name
               )
           ) AS t(exists int);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Failed node name % not present in metadata on target node %',
            failed_node_name, target_node_name;
    END IF;

    IF verb THEN
        RAISE NOTICE '[RESCUE] Precheck complete: connectivity, versions, recovery slot, and metadata verified.';
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_phase_clone
-- Clones the recovery slot on the rescue source, suspends peer subscriptions
-- on the lagging node, and creates a temporary rescue subscription using the
-- cloned slot.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spock.recover_phase_clone(
    text, text, text, text, text, pg_lsn, pg_lsn, timestamptz, boolean
);
CREATE OR REPLACE PROCEDURE spock.recover_phase_clone(
    failed_node_name text,
    source_node_name text,
    source_dsn text,
    target_node_name text,
    target_dsn text,
    OUT cloned_slot_name text,
    stop_lsn pg_lsn,
    skip_lsn pg_lsn,
    stop_timestamp timestamptz,
    verb boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    slot_info RECORD;
    restart_lsn pg_lsn;
    exec_status text;
    sub_id oid;
    effective_skip pg_lsn;
    effective_stop pg_lsn;
    slot_restart pg_lsn;
    slot_confirm pg_lsn;
    skip_expr text;
    stop_expr text;
    stop_ts_expr text;
BEGIN
    verb := COALESCE(verb, false);
    IF verb THEN
        RAISE NOTICE '[RESCUE] Cloning recovery slot on % (%).',
            source_node_name, source_dsn;
    END IF;

    -- [Source node] Clone the inactive recovery slot to an active temporary slot.
    SELECT t.cloned_slot_name,
           t.original_slot_name,
           t.restart_lsn,
           t.success,
           t.message
      INTO slot_info
      FROM dblink(
               source_dsn,
               'SELECT cloned_slot_name, original_slot_name, restart_lsn, success, message FROM spock.clone_recovery_slot()'
           )
           AS t(
               cloned_slot_name text,
               original_slot_name text,
               restart_lsn pg_lsn,
               success boolean,
               message text
           );

    IF slot_info IS NULL THEN
        RAISE EXCEPTION 'spock.clone_recovery_slot() returned no data from %', source_node_name;
    END IF;
    IF slot_info.success IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'Failed to clone recovery slot on %: %',
            source_node_name, COALESCE(slot_info.message, 'unknown error');
    END IF;

    cloned_slot_name := slot_info.cloned_slot_name;
    restart_lsn := slot_info.restart_lsn;

    IF verb THEN
        RAISE NOTICE '[RESCUE] Cloned slot % (restart LSN %)', cloned_slot_name, restart_lsn;
    END IF;

    effective_skip := skip_lsn;
    effective_stop := stop_lsn;
    IF effective_stop IS NULL THEN
        SELECT slot_restart, slot_confirm
          INTO slot_restart, slot_confirm
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT restart_lsn, confirmed_flush_lsn
                                FROM pg_catalog.pg_replication_slots
                               WHERE slot_name = %L$_sql$,
                       slot_info.cloned_slot_name
                   )
               ) AS t(restart_lsn pg_lsn, confirmed_flush_lsn pg_lsn);

        effective_stop := COALESCE(slot_confirm, slot_restart, restart_lsn);
    END IF;

    IF effective_stop IS NULL THEN
        SELECT source_remote_lsn
          INTO effective_stop
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT pos.remote_lsn AS source_remote_lsn
                                FROM spock.subscription s
                                JOIN spock.node o ON o.node_id = s.sub_origin
                                JOIN pg_catalog.pg_replication_origin_status pos
                                  ON pos.external_id = spock.spock_gen_slot_name(
                                        current_database()::name,
                                        o.node_name::name,
                                        s.sub_name)::text
                               WHERE o.node_name = %L
                               ORDER BY pos.remote_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name
                   )
               ) AS t(source_remote_lsn pg_lsn);

    END IF;

    IF effective_skip IS NULL THEN
        SELECT target_remote_lsn
          INTO effective_skip
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT pos.remote_lsn AS target_remote_lsn
                                FROM spock.subscription s
                                JOIN spock.node o ON o.node_id = s.sub_origin
                                JOIN pg_catalog.pg_replication_origin_status pos
                                  ON pos.external_id = spock.spock_gen_slot_name(
                                        current_database()::name,
                                        o.node_name::name,
                                        s.sub_name)::text
                               WHERE o.node_name = %L
                               ORDER BY pos.remote_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name
                   )
               ) AS t(target_remote_lsn pg_lsn);
    END IF;

    IF effective_skip IS NULL THEN
        effective_skip := restart_lsn;
    END IF;

    IF effective_stop IS NULL THEN
        SELECT last_lsn
          INTO effective_stop
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT frs.last_lsn
                                FROM spock.find_rescue_source(%L) frs
                                JOIN spock.node src ON src.node_id = frs.source_node_id
                               WHERE src.node_name = %L$_sql$,
                       failed_node_name,
                       source_node_name
                   )
               ) AS t(last_lsn pg_lsn);
    END IF;

    IF effective_stop IS NULL THEN
        RAISE EXCEPTION 'Unable to determine stop LSN automatically; provide stop_lsn or stop_timestamp explicitly';
    END IF;

    IF effective_skip IS NOT NULL
       AND effective_stop IS NOT NULL
       AND effective_skip >= effective_stop THEN
        effective_skip := NULL;
    END IF;

    IF verb THEN
        RAISE NOTICE '[RESCUE] Using skip LSN %, stop LSN %',
            effective_skip, effective_stop;
        IF stop_timestamp IS NOT NULL THEN
            RAISE NOTICE '[RESCUE] Stop timestamp requested: %', stop_timestamp;
        END IF;
    END IF;

    -- [Target node] Suspend peer-to-peer subscriptions that would interfere with rescue.
    SELECT suspend_success::text
      INTO exec_status
      FROM dblink(
               target_dsn,
               format(
                   $_sql$SELECT spock.suspend_all_peer_subs_for_rescue(t.node_id, f.node_id) AS suspend_success
                      FROM spock.node t, spock.node f
                     WHERE t.node_name = %L
                       AND f.node_name = %L$_sql$,
                   target_node_name,
                   failed_node_name
               )
           ) AS t(suspend_success boolean);

    IF verb THEN
        RAISE NOTICE '[RESCUE] Suspended peer subscriptions on % (status=%)',
            target_node_name, exec_status;
    END IF;

    skip_expr := CASE
                    WHEN effective_skip IS NULL
                        THEN 'NULL::pg_lsn'
                    ELSE quote_literal(effective_skip::text) || '::pg_lsn'
                 END;
    stop_expr := CASE
                    WHEN effective_stop IS NULL
                        THEN 'NULL::pg_lsn'
                    ELSE quote_literal(effective_stop::text) || '::pg_lsn'
                 END;
    stop_ts_expr := CASE
                        WHEN stop_timestamp IS NULL
                            THEN 'NULL::timestamptz'
                        ELSE quote_literal(stop_timestamp::text) || '::timestamptz'
                     END;

    -- [Target node] Create a temporary rescue subscription that streams from the cloned slot.
    SELECT created_sub_id
      INTO sub_id
      FROM dblink(
               target_dsn,
               format(
                   $_sql$SELECT spock.create_rescue_subscription(%L, %L, %L, %s, %s, %s)$_sql$,
                   target_node_name,
                   source_node_name,
                   cloned_slot_name,
                   skip_expr,
                   stop_expr,
                   stop_ts_expr
               )
           ) AS t(created_sub_id oid);

    IF sub_id IS NULL THEN
        RAISE EXCEPTION 'Failed to create rescue subscription on %, cloned slot %',
            target_node_name, cloned_slot_name;
    END IF;

    RAISE NOTICE 'Rescue subscription created on %, slot %, subscription id %.',
        target_node_name, cloned_slot_name, sub_id;
    RAISE NOTICE 'Monitor the apply worker on % until the temporary subscription is removed.', target_node_name;
    RAISE NOTICE 'Remember to record the cloned slot name "%".', cloned_slot_name;
END;
$$;

-- Backward-compatible wrapper for older tooling
DROP PROCEDURE IF EXISTS spock.recover_failed_node(
    text, text, text, text, text, pg_lsn, pg_lsn, timestamptz, boolean
);
CREATE OR REPLACE PROCEDURE spock.recover_failed_node(
    failed_node_name text,
    source_node_name text,
    source_dsn text,
    target_node_name text,
    target_dsn text,
    stop_lsn pg_lsn DEFAULT NULL,
    skip_lsn pg_lsn DEFAULT NULL,
    stop_timestamp timestamptz DEFAULT NULL,
    verb boolean DEFAULT false
)
LANGUAGE plpgsql
AS $$
DECLARE
    cloned_slot text;
BEGIN
    CALL spock.recover_run(
        failed_node_name => failed_node_name,
        source_node_name => source_node_name,
        source_dsn       => source_dsn,
        target_node_name => target_node_name,
        target_dsn       => target_dsn,
        stop_lsn         => stop_lsn,
        skip_lsn         => skip_lsn,
        stop_timestamp   => stop_timestamp,
        verb             => verb,
        cloned_slot_name => cloned_slot
    );

    IF cloned_slot IS NULL THEN
        RAISE NOTICE '[RESCUE] Legacy wrapper: recovery not required.';
    ELSE
        RAISE NOTICE '[RESCUE] Legacy wrapper created rescue subscription using cloned slot %', cloned_slot;
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_run
-- Orchestrates Phase 1 (precheck) and Phase 2 (clone & temporary subscription).
-- Returns the cloned slot name for later cleanup.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spock.recover_run(
    text, text, text, text, text, pg_lsn, pg_lsn, timestamptz, boolean
);
CREATE OR REPLACE PROCEDURE spock.recover_run(
    failed_node_name text,
    source_node_name text,
    source_dsn text,
    target_node_name text,
    target_dsn text,
    stop_lsn pg_lsn,
    skip_lsn pg_lsn,
    stop_timestamp timestamptz,
    verb boolean,
    OUT cloned_slot_name text
)
LANGUAGE plpgsql
AS $$
DECLARE
    required boolean;
BEGIN
    verb := COALESCE(verb, false);
    CALL spock.recover_precheck(
        failed_node_name => failed_node_name,
        source_node_name => source_node_name,
        source_dsn       => source_dsn,
        target_node_name => target_node_name,
        target_dsn       => target_dsn,
        verb             => verb,
        recovery_needed  => required
    );

    IF NOT required THEN
        cloned_slot_name := NULL;
        IF verb THEN
            RAISE NOTICE '[RESCUE] Recovery skipped: no subscriptions sourced from % on %.',
                failed_node_name, target_node_name;
        END IF;
        RETURN;
    END IF;
    CALL spock.recover_phase_clone(
        failed_node_name => failed_node_name,
        source_node_name => source_node_name,
        source_dsn       => source_dsn,
        target_node_name => target_node_name,
        target_dsn       => target_dsn,
        stop_lsn         => stop_lsn,
        skip_lsn         => skip_lsn,
        stop_timestamp   => stop_timestamp,
        verb             => verb,
        cloned_slot_name => cloned_slot_name
    );

    IF verb THEN
        RAISE NOTICE '[RESCUE] Orchestration complete. Cloned slot: %', cloned_slot_name;
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recovery
-- Convenience wrapper that runs the full flow (precheck, clone/rescue, finalize).
-- Execute from the coordinator node once you are ready to recover and clean up.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spock.recovery(
    text, text, text, text, text, pg_lsn, pg_lsn, timestamptz, boolean
);

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_finalize
-- Resumes peer subscriptions on the rescued node and drops the cloned slot on
-- the rescue source once catch-up is confirmed.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spock.recover_finalize(
    text, text, text, text, text, boolean
);
CREATE OR REPLACE PROCEDURE spock.recover_finalize(
    target_dsn text,
    target_node_name text,
    failed_node_name text,
    source_dsn text,
    cloned_slot_name text,
    verb boolean DEFAULT false
)
LANGUAGE plpgsql
AS $$
DECLARE
    exec_status text;
BEGIN
    -- [Coordinator] Resume normal replication by clearing rescue suspension flags.
    SELECT resume_success::text
      INTO exec_status
      FROM dblink(
               target_dsn,
               format(
                   $_sql$SELECT spock.resume_all_peer_subs_post_rescue(t.node_id) AS resume_success
                      FROM spock.node t
                     WHERE t.node_name = %L$_sql$,
                   target_node_name
               )
           ) AS t(resume_success boolean);

    IF verb THEN
        RAISE NOTICE '[RESCUE] Resumed peer subscriptions on % (status=%)',
            target_node_name, exec_status;
    END IF;

    IF cloned_slot_name IS NOT NULL AND cloned_slot_name <> '' THEN
        -- [Source node] Drop the temporary cloned slot now that the rescue subscription is gone.
        exec_status := dblink_exec(
            source_dsn,
            format(
                $_sql$DO $_drop$BEGIN PERFORM pg_drop_replication_slot(%L); END$_drop$;$_sql$,
                cloned_slot_name
            )
        );
        IF verb THEN
            RAISE NOTICE '[RESCUE] Dropped cloned slot % on source (status=%)',
                cloned_slot_name, exec_status;
        END IF;
    ELSE
        IF verb THEN
            RAISE NOTICE '[RESCUE] No cloned slot supplied, skipping drop.';
        END IF;
    END IF;

    RAISE NOTICE 'Recovery finalized for %. Resume normal replication monitoring.', failed_node_name;
END;
$$;


-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_status
-- Convenience routine to inspect rescue-related catalog state after recovery.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spock.recover_status(text, text, boolean);
CREATE OR REPLACE PROCEDURE spock.recover_status(
    target_dsn text,
    target_node_name text,
    verb boolean DEFAULT false
)
LANGUAGE plpgsql
AS $$
DECLARE
    sub_rec RECORD;
    slot_rec RECORD;
    subs_found boolean := false;
    slots_found boolean := false;
BEGIN
    IF verb THEN
        RAISE NOTICE '[RESCUE] Subscription rescue state on %:', target_node_name;
    END IF;

    FOR sub_rec IN
        SELECT *
          FROM dblink(
                   target_dsn,
                   format(
           $_sql$SELECT s.sub_name,
                    s.sub_rescue_temporary,
                    s.sub_rescue_cleanup_pending,
                    s.sub_rescue_failed
                           FROM spock.subscription s
                           JOIN spock.node t ON t.node_id = s.sub_target
                          WHERE t.node_name = %L
                            AND s.sub_rescue_temporary
                          ORDER BY s.sub_name$_sql$,
                       target_node_name
                   )
               ) AS t(
                   sub_name text,
                   sub_rescue_temporary boolean,
                   sub_rescue_cleanup_pending boolean,
                   sub_rescue_failed boolean
               )
    LOOP
        subs_found := true;
        IF verb THEN
            RAISE NOTICE '  sub=% temporary=% cleanup_pending=% failed=%',
                sub_rec.sub_name,
                sub_rec.sub_rescue_temporary,
                sub_rec.sub_rescue_cleanup_pending,
                sub_rec.sub_rescue_failed;
        END IF;
    END LOOP;

    IF NOT subs_found AND verb THEN
        RAISE NOTICE '  (no rescue subscriptions found)';
    END IF;

    IF verb THEN
        RAISE NOTICE '[RESCUE] Recovery slot state on %:', target_node_name;
    END IF;

    FOR slot_rec IN
        SELECT *
          FROM dblink(
                   target_dsn,
                   $_sql$SELECT slot_name,
                             restart_lsn::text,
                             confirmed_flush_lsn::text,
                             active,
                             in_recovery
                        FROM spock.get_recovery_slot_status()
                       ORDER BY slot_name$_sql$
               ) AS t(
                   slot_name text,
                   restart_lsn text,
                   confirmed_flush_lsn text,
                   active boolean,
                   in_recovery boolean
               )
    LOOP
        slots_found := true;
        IF verb THEN
            RAISE NOTICE '  slot=% restart=% confirmed=% active=% in_recovery=%',
                slot_rec.slot_name,
                slot_rec.restart_lsn,
                slot_rec.confirmed_flush_lsn,
                slot_rec.active,
                slot_rec.in_recovery;
        END IF;
    END LOOP;

    IF NOT slots_found AND verb THEN
        RAISE NOTICE '  (no recovery slot information returned)';
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE spock.recovery(
    failed_node_name text,
    source_node_name text,
    source_dsn text,
    target_node_name text,
    target_dsn text,
    stop_lsn pg_lsn DEFAULT NULL,
    skip_lsn pg_lsn DEFAULT NULL,
    stop_timestamp timestamptz DEFAULT NULL,
    verb boolean DEFAULT false
)
LANGUAGE plpgsql
AS $$
DECLARE
    cloned_slot_name text;
    pending_cleanup integer;
BEGIN
    CALL spock.recover_run(
        failed_node_name => failed_node_name,
        source_node_name => source_node_name,
        source_dsn       => source_dsn,
        target_node_name => target_node_name,
        target_dsn       => target_dsn,
        stop_lsn         => stop_lsn,
        skip_lsn         => skip_lsn,
        stop_timestamp   => stop_timestamp,
        verb             => verb,
        cloned_slot_name => cloned_slot_name
    );

    IF cloned_slot_name IS NULL THEN
        IF verb THEN
            RAISE NOTICE '[RESCUE] Recovery skipped: no rescue required.';
        END IF;
        RETURN;
    END IF;

    pending_cleanup := 0;
    IF verb THEN
        RAISE NOTICE '[RESCUE] Waiting for temporary rescue subscription on % to signal cleanup...',
            target_node_name;
    END IF;

    FOR attempt IN 1..300 LOOP
        SELECT cnt
          INTO pending_cleanup
          FROM dblink(
                   target_dsn,
                   'SELECT count(*) FROM spock.subscription WHERE sub_rescue_cleanup_pending'
               ) AS t(cnt int);

        EXIT WHEN pending_cleanup > 0;
        PERFORM pg_sleep(1);
    END LOOP;

    IF pending_cleanup = 0 THEN
        RAISE NOTICE '[RESCUE] Rescue subscription still applying on %. '
        'Re-run spock.recovery once cleanup has been signalled.',
            target_node_name;
        RETURN;
    END IF;

    IF verb THEN
        RAISE NOTICE '[RESCUE] Cleanup flag detected; proceeding with finalization on %.', target_node_name;
    END IF;

    CALL spock.recover_finalize(
        target_dsn       => target_dsn,
        target_node_name => target_node_name,
        failed_node_name => failed_node_name,
        source_dsn       => source_dsn,
        cloned_slot_name => cloned_slot_name,
        verb             => verb
    );

    CALL spock.recover_status(
        target_dsn       => target_dsn,
        target_node_name => target_node_name,
        verb             => verb
    );

    IF verb THEN
        RAISE NOTICE '[RESCUE] Recovery completed. Temporary slot % removed.', cloned_slot_name;
    END IF;
END;
$$;
