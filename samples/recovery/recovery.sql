-- ============================================================================
-- Spock Recovery Procedures
--
-- Orchestrates catastrophic node failure recovery by cloning a recovery slot
-- on a healthy peer, creating a temporary rescue subscription on the lagging
-- node, and resuming normal replication after catch-up completes.
--
-- Requirements:
--   * Spock 6.0.0-devel or newer with rescue catalog columns
--   * dblink extension on the coordinator database
--
-- Usage:
--
-- Step 1: Run recovery (clones slot and creates rescue subscription)
--   CALL spock.recover_run(
--       failed_node_name := 'n1',
--       source_node_name := 'n2',
--       source_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
--       target_node_name := 'n3',
--       target_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>',
--       stop_lsn         := NULL,  -- Optional: specific LSN to stop at
--       skip_lsn         := NULL,  -- Optional: LSN to skip to
--       stop_timestamp   := NULL,  -- Optional: timestamp to stop at
--       verb             := true,
--       cloned_slot_name => slot_name  -- OUT: cloned slot name for cleanup
--   );
--
-- Step 2: Monitor rescue subscription until cleanup_pending flag is set
--   SELECT sub_name, sub_rescue_cleanup_pending
--     FROM spock.subscription
--    WHERE sub_rescue_temporary;
--
-- Step 3: Finalize recovery (resume subscriptions and drop cloned slot)
--   CALL spock.recover_finalize(
--       target_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>',
--       target_node_name := 'n3',
--       failed_node_name := 'n1',
--       source_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
--       cloned_slot_name := slot_name,  -- From Step 1
--       verb             := true
--   );
--
-- Alternative: Full automated recovery with LSN sync checks
--   Performs precheck with INFO messages, checks lag_tracker and subscription LSNs,
--   skips recovery if all LSNs are synced, otherwise proceeds with full recovery
--   (waits for cleanup, then finalizes).
--   CALL spock.recovery(
--       failed_node_name := 'n1',
--       source_node_name := 'n2',
--       source_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
--       target_node_name := 'n3',
--       target_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>',
--       stop_lsn         := NULL,
--       skip_lsn         := NULL,
--       stop_timestamp   := NULL,
--       verb             := true
--   );
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_precheck
-- Validates connectivity, Spock versions, recovery slot availability, and
-- absence of existing rescue subscriptions.
-- NOTE: This procedure is READ-ONLY - it does NOT create, modify, or delete
-- anything. It only performs SELECT queries for validation.
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
    target_rescue_cleanup_pending integer;
    target_rescue_failed integer;
    target_origin_subs integer;
    source_lag_lsn pg_lsn;
    target_lag_lsn pg_lsn;
    tmp RECORD;
BEGIN
    verb := COALESCE(verb, false);
    recovery_needed := true;

    -- READ-ONLY VALIDATION: This procedure does not create, modify, or delete anything
    RAISE INFO '[CHECK] - : Starting precheck validation (read-only checks only)...';

    IF source_node_name = target_node_name THEN
        RAISE EXCEPTION 'source_node_name (%) and target_node_name (%) must differ',
            source_node_name, target_node_name;
    END IF;
    IF target_node_name = failed_node_name THEN
        RAISE EXCEPTION 'target_node_name (%) cannot equal failed_node_name (%)',
            target_node_name, failed_node_name;
    END IF;
    RAISE INFO '[CHECK] - : Node name validation passed';

    BEGIN
        SELECT version INTO tmp FROM dblink(source_dsn, 'SELECT version()') AS t(version text);
        RAISE INFO '[CHECK] - : Source connection successful: %', source_dsn;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Unable to connect to source DSN %: %', source_dsn, SQLERRM;
    END;

    BEGIN
        SELECT version INTO tmp FROM dblink(target_dsn, 'SELECT version()') AS t(version text);
        RAISE INFO '[CHECK] - : Target connection successful: %', target_dsn;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Unable to connect to target DSN %: %', target_dsn, SQLERRM;
    END;

    SELECT extversion
      INTO source_version
      FROM dblink(
               source_dsn,
               'SELECT extversion FROM pg_extension WHERE extname = ''spock'''
           ) AS t(extversion text);
    IF source_version IS NULL THEN
        RAISE EXCEPTION 'Spock extension not installed on source node %', source_node_name;
    END IF;
    RAISE INFO '[CHECK] - : Source Spock version: %', source_version;

    SELECT extversion
      INTO target_version
      FROM dblink(
               target_dsn,
               'SELECT extversion FROM pg_extension WHERE extname = ''spock'''
           ) AS t(extversion text);
    IF target_version IS NULL THEN
        RAISE EXCEPTION 'Spock extension not installed on target node %', target_node_name;
    END IF;
    RAISE INFO '[CHECK] - : Target Spock version: %', target_version;

    IF regexp_replace(source_version, '-devel$', '') <>
       regexp_replace(target_version, '-devel$', '') THEN
        RAISE EXCEPTION 'Spock version mismatch between source (%) and target (%)',
            source_version, target_version;
    END IF;
    RAISE INFO '[CHECK] - : Spock version compatibility verified';

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
    RAISE INFO '[CHECK] - : Source node name verified: %', source_local_node;

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
    RAISE INFO '[CHECK] - : Target node name verified: %', target_local_node;

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
    RAISE INFO '[CHECK] - : Source recovery slot found: % active slot(s)', source_slot_count;

    -- Check for existing rescue subscriptions and their status
    SELECT cnt, cleanup_pending_cnt, failed_cnt
      INTO target_rescue_subs, target_rescue_cleanup_pending, target_rescue_failed
      FROM dblink(
               target_dsn,
               $_sql$SELECT 
                        count(*) as cnt,
                        count(*) FILTER (WHERE sub_rescue_cleanup_pending) as cleanup_pending_cnt,
                        count(*) FILTER (WHERE sub_rescue_failed) as failed_cnt
                   FROM spock.subscription 
                  WHERE sub_rescue_temporary$_sql$
           ) AS t(cnt int, cleanup_pending_cnt int, failed_cnt int);
    
    IF target_rescue_subs > 0 THEN
        -- Check if rescue subscription is waiting for cleanup
        IF target_rescue_cleanup_pending > 0 THEN
            RAISE INFO '[CHECK] - : Target node % has % rescue subscription(s) waiting for cleanup',
                target_node_name, target_rescue_subs;
            RAISE INFO '[CHECK] - : Run spock.recover_finalize() to complete the previous recovery first';
            recovery_needed := false;
            RETURN;
        ELSIF target_rescue_failed > 0 THEN
            RAISE WARNING '[CHECK] - : Target node % has % failed rescue subscription(s)',
                target_node_name, target_rescue_subs;
            RAISE EXCEPTION 'Target node % has failed rescue subscription(s); clean them up manually first',
                target_node_name;
        ELSE
            RAISE INFO '[CHECK] - : Target node % has % active rescue subscription(s)',
                target_node_name, target_rescue_subs;
            RAISE EXCEPTION 'Target node % already has % active temporary rescue subscription(s); wait for completion or clean them first',
                target_node_name, target_rescue_subs;
        END IF;
    END IF;
    RAISE INFO '[CHECK] - : Target has no existing rescue subscriptions';

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
        RAISE INFO '[CHECK] - : Target node % has no subscriptions sourced from %; rescue not required.',
            target_node_name, failed_node_name;
        RETURN;
    END IF;
    RAISE INFO '[CHECK] - : Target has % subscription(s) sourced from %', target_origin_subs, failed_node_name;

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
    RAISE INFO '[CHECK] - : Failed node % present in target metadata', failed_node_name;

    RAISE INFO '[CHECK] - : All precheck validations passed';

    -- Print lag_tracker LSNs from failed node to source and target
    BEGIN
        SELECT commit_lsn INTO source_lag_lsn
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L$_sql$,
                       failed_node_name,
                       source_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
        IF source_lag_lsn IS NOT NULL THEN
            RAISE INFO '[CHECK] - : Source lag_tracker LSN (n1->n2): %', source_lag_lsn;
        ELSE
            RAISE INFO '[CHECK] - : Source lag_tracker LSN (n1->n2): NULL';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE INFO '[CHECK] - : Could not get source lag_tracker LSN: %', SQLERRM;
    END;

    BEGIN
        SELECT commit_lsn INTO target_lag_lsn
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L$_sql$,
                       failed_node_name,
                       target_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
        IF target_lag_lsn IS NOT NULL THEN
            RAISE INFO '[CHECK] - : Target lag_tracker LSN (n1->n3): %', target_lag_lsn;
        ELSE
            RAISE INFO '[CHECK] - : Target lag_tracker LSN (n1->n3): NULL';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE INFO '[CHECK] - : Could not get target lag_tracker LSN: %', SQLERRM;
    END;

    -- Check lag_tracker LSN comparison
    IF source_lag_lsn IS NOT NULL AND target_lag_lsn IS NOT NULL THEN
        IF source_lag_lsn = target_lag_lsn THEN
            recovery_needed := false;
            RAISE INFO '[CHECK] - : LSN on source node [%] and target node [%] are same, no need of recovery.', 
                source_node_name, target_node_name;
            RETURN;
        ELSIF source_lag_lsn > target_lag_lsn THEN
            -- Source is ahead of target - target needs recovery
            RAISE INFO '[CHECK] - : Source lag_tracker LSN (%) > Target lag_tracker LSN (%) - recovery required', 
                source_lag_lsn, target_lag_lsn;
            -- Continue with recovery
        ELSIF target_lag_lsn > source_lag_lsn THEN
            -- Target is ahead of source - wrong direction, need to run on source
            RAISE WARNING '[CHECK] - : Target lag_tracker LSN (%) > Source lag_tracker LSN (%)', 
                target_lag_lsn, source_lag_lsn;
            RAISE WARNING '[CHECK] - : Target is ahead of source. Run recovery script on source node with proper parameters and exit.';
            recovery_needed := false;
            RETURN;
        END IF;
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_phase_clone
-- Clones the recovery slot on the source node, suspends peer subscriptions
-- on the target node, and creates a temporary rescue subscription.
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
        RAISE INFO '[RECOVERY] - : Cloning recovery slot on % (%)',
            source_node_name, source_dsn;
    END IF;

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

    -- Verify cloned slot actually exists
    IF cloned_slot_name IS NULL OR cloned_slot_name = '' THEN
        RAISE EXCEPTION 'Cloned slot name is NULL or empty from %', source_node_name;
    END IF;

    -- Verify cloned slot exists (may need a small delay for commit)
    FOR attempt IN 1..5 LOOP
        PERFORM 1
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT 1
                          FROM pg_replication_slots
                         WHERE slot_name = %L$_sql$,
                       cloned_slot_name
                   )
               ) AS t(exists int);
        EXIT WHEN FOUND;
        PERFORM pg_sleep(0.1);
    END LOOP;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cloned slot % not found on source node % after creation',
            cloned_slot_name, source_node_name;
    END IF;

    IF verb THEN
        RAISE INFO '[RECOVERY] - : Cloned slot % (restart LSN %)', cloned_slot_name, restart_lsn;
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
        -- Use lag_tracker which includes both regular and rescue subscriptions
        SELECT commit_lsn
          INTO effective_stop
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L
                               ORDER BY commit_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name,
                       source_node_name
                   )
               ) AS t(commit_lsn pg_lsn);

    END IF;

    IF effective_skip IS NULL THEN
        -- Use lag_tracker which includes both regular and rescue subscriptions
        SELECT commit_lsn
          INTO effective_skip
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L
                               ORDER BY commit_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name,
                       target_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
    END IF;

    IF effective_skip IS NULL THEN
        effective_skip := restart_lsn;
    END IF;

    IF effective_stop IS NULL THEN
        -- Use lag_tracker which includes both regular and rescue subscriptions
        -- This is more accurate and consistent than querying pg_replication_origin_status directly
        SELECT commit_lsn
          INTO effective_stop
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L
                               ORDER BY commit_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name,
                       source_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
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
        RAISE INFO '[RECOVERY] - : Using skip LSN %, stop LSN %',
            effective_skip, effective_stop;
        IF stop_timestamp IS NOT NULL THEN
            RAISE INFO '[RECOVERY] - : Stop timestamp requested: %', stop_timestamp;
        END IF;
    END IF;

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
        RAISE INFO '[RECOVERY] - % : Suspended peer subscriptions (status=%)',
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

    -- Create rescue subscription
    BEGIN
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
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Failed to create rescue subscription on %: %',
                target_node_name, SQLERRM;
    END;

    IF sub_id IS NULL OR sub_id = 0 THEN
        RAISE EXCEPTION 'Failed to create rescue subscription on %, cloned slot %: function returned NULL or invalid OID',
            target_node_name, cloned_slot_name;
    END IF;

    -- Verify subscription was actually created
    PERFORM 1
      FROM dblink(
               target_dsn,
               format(
                   $_sql$SELECT 1
                      FROM spock.subscription
                     WHERE sub_id = %L
                       AND sub_rescue_temporary$_sql$,
                   sub_id
               )
           ) AS t(exists int);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rescue subscription with id % was not found after creation on %',
            sub_id, target_node_name;
    END IF;

    -- Verify cloned slot exists on source (may need a small delay for visibility via dblink)
    FOR attempt IN 1..5 LOOP
        PERFORM 1
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT 1
                          FROM pg_replication_slots
                         WHERE slot_name = %L$_sql$,
                       cloned_slot_name
                   )
               ) AS t(exists int);
        EXIT WHEN FOUND;
        PERFORM pg_sleep(0.1);
    END LOOP;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cloned slot % not found on source node %',
            cloned_slot_name, source_node_name;
    END IF;

    RAISE INFO '[RECOVERY] - % : Rescue subscription created, slot %, subscription id %',
        target_node_name, cloned_slot_name, sub_id;
    RAISE INFO '[RECOVERY] - % : Monitor the apply worker until the temporary subscription is removed', target_node_name;
    RAISE INFO '[RECOVERY] - % : Remember to record the cloned slot name "%"', target_node_name, cloned_slot_name;
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_run
-- Orchestrates precheck, clone, wait for completion, cleanup, and verification.
-- Automatically removes rescue subscription and cloned slot when recovery completes.
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
    verb boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    required boolean;
    cloned_slot_name text;
    pending_cleanup integer;
    n2_lsn pg_lsn;
    n3_lsn pg_lsn;
    lag_rec RECORD;
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
        RAISE INFO '[RECOVERY] - : Orchestration complete. Cloned slot: %', cloned_slot_name;
        RAISE INFO '[RECOVERY] - : Waiting for rescue subscription to complete...';
    END IF;

    -- Verify subscription exists before waiting
    BEGIN
        PERFORM 1
          FROM dblink(
                   target_dsn,
                   'SELECT 1 FROM spock.subscription WHERE sub_rescue_temporary LIMIT 1'
               ) AS t(exists int);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Rescue subscription not found on % after creation. Recovery failed.',
                target_node_name;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Could not verify rescue subscription on %: %',
                target_node_name, SQLERRM;
    END;

    -- Wait for rescue subscription to signal cleanup
    pending_cleanup := 0;
    FOR attempt IN 1..300 LOOP
        BEGIN
            SELECT cnt
              INTO pending_cleanup
              FROM dblink(
                       target_dsn,
                       'SELECT count(*) FROM spock.subscription WHERE sub_rescue_cleanup_pending'
                   ) AS t(cnt int);
        EXCEPTION
            WHEN OTHERS THEN
                -- Check if it's a connection error
                IF SQLERRM LIKE '%could not establish connection%' OR
                   SQLERRM LIKE '%connection%' OR
                   SQLERRM LIKE '%server closed%' THEN
                    RAISE WARNING '[RESCUE] Cannot connect to target node %: %. Target node may be down. Recovery cannot proceed.',
                        target_node_name, SQLERRM;
                    -- Exit after a few failed attempts to avoid infinite loop
                    IF attempt >= 5 THEN
                        RAISE EXCEPTION 'Target node % is not accessible after % attempts. Recovery cannot proceed.',
                            target_node_name, attempt;
                    END IF;
                ELSE
                    RAISE WARNING '[RESCUE] Error checking cleanup status: %', SQLERRM;
                END IF;
                pending_cleanup := 0;
        END;

        EXIT WHEN pending_cleanup > 0;
        
        -- Check if subscription still exists
        BEGIN
            PERFORM 1
              FROM dblink(
                       target_dsn,
                       'SELECT 1 FROM spock.subscription WHERE sub_rescue_temporary LIMIT 1'
                   ) AS t(exists int);
            IF NOT FOUND THEN
                RAISE WARNING '[RESCUE] Rescue subscription disappeared during wait. Recovery may have completed or failed.';
                EXIT;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                -- If connection fails, check if we should exit
                IF SQLERRM LIKE '%could not establish connection%' OR
                   SQLERRM LIKE '%connection%' OR
                   SQLERRM LIKE '%server closed%' THEN
                    IF attempt >= 5 THEN
                        RAISE EXCEPTION 'Target node % is not accessible. Recovery cannot proceed.',
                            target_node_name;
                    END IF;
                END IF;
                -- Continue waiting for other errors
                NULL;
        END;
        
        PERFORM pg_sleep(1);
    END LOOP;

    IF pending_cleanup = 0 THEN
        -- Check if subscription still exists
        BEGIN
            PERFORM 1
              FROM dblink(
                       target_dsn,
                       'SELECT 1 FROM spock.subscription WHERE sub_rescue_temporary LIMIT 1'
                   ) AS t(exists int);
            IF FOUND THEN
                RAISE WARNING '[RESCUE] Rescue subscription still applying on %. '
                'Recovery may not be complete. Check subscription status manually.',
                    target_node_name;
            ELSE
                RAISE INFO '[RESCUE] Rescue subscription no longer exists. Recovery may have completed.';
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING '[RESCUE] Could not verify subscription status: %', SQLERRM;
        END;
        RETURN;
    END IF;

    IF verb THEN
        RAISE INFO '[RECOVERY] - : Cleanup flag detected; proceeding with finalization...';
    END IF;

    -- Finalize: cleanup rescue subscription and cloned slot
    CALL spock.recover_finalize(
        target_dsn       => target_dsn,
        target_node_name => target_node_name,
        failed_node_name => failed_node_name,
        source_dsn       => source_dsn,
        cloned_slot_name => cloned_slot_name,
        verb             => verb
    );

    -- Print LSN verification from lag_tracker
    RAISE NOTICE '';
    RAISE NOTICE '=== Recovery Complete - LSN Verification ===';
    
    FOR lag_rec IN
        SELECT 
            receiver_name,
            commit_lsn,
            replication_lag_bytes,
            replication_lag
        FROM dblink(
                 target_dsn,
                 format(
                     $_sql$SELECT 
                         receiver_name,
                         commit_lsn,
                         replication_lag_bytes,
                         replication_lag
                     FROM spock.lag_tracker
                     WHERE origin_name = %L
                       AND receiver_name IN (%L, %L)
                     ORDER BY receiver_name$_sql$,
                     failed_node_name,
                     target_node_name,
                     source_node_name
                 )
             ) AS t(
                 receiver_name text,
                 commit_lsn pg_lsn,
                 replication_lag_bytes bigint,
                 replication_lag interval
             )
    LOOP
        RAISE NOTICE '  %: commit_lsn=%, lag_bytes=%, lag_time=%',
            lag_rec.receiver_name,
            lag_rec.commit_lsn,
            COALESCE(lag_rec.replication_lag_bytes::text, 'NULL'),
            COALESCE(lag_rec.replication_lag::text, 'NULL');
    END LOOP;

    -- Verify sync
    BEGIN
        SELECT commit_lsn INTO n2_lsn
        FROM dblink(
                 target_dsn,
                 format(
                     $_sql$SELECT commit_lsn
                      FROM spock.lag_tracker
                     WHERE origin_name = %L AND receiver_name = %L$_sql$,
                     failed_node_name,
                     target_node_name
                 )
             ) AS t(commit_lsn pg_lsn);
        
        SELECT commit_lsn INTO n3_lsn
        FROM dblink(
                 source_dsn,
                 format(
                     $_sql$SELECT commit_lsn
                      FROM spock.lag_tracker
                     WHERE origin_name = %L AND receiver_name = %L$_sql$,
                     failed_node_name,
                     source_node_name
                 )
             ) AS t(commit_lsn pg_lsn);
        
        IF n2_lsn IS NULL OR n3_lsn IS NULL THEN
            RAISE WARNING 'One or both LSNs are NULL: n2_lsn=%, n3_lsn=%', n2_lsn, n3_lsn;
        ELSIF n2_lsn = n3_lsn THEN
            RAISE NOTICE '✓ SYNCED: % and % have the same LSN from %: %',
                target_node_name, source_node_name, failed_node_name, n2_lsn;
        ELSIF n2_lsn > n3_lsn THEN
            RAISE WARNING '% is ahead: %_lsn=%, %_lsn=%, lag=% bytes',
                target_node_name, target_node_name, n2_lsn, source_node_name, n3_lsn,
                pg_wal_lsn_diff(n2_lsn, n3_lsn);
        ELSE
            RAISE WARNING '% is ahead: %_lsn=%, %_lsn=%, lag=% bytes',
                source_node_name, source_node_name, n3_lsn, target_node_name, n2_lsn,
                pg_wal_lsn_diff(n3_lsn, n2_lsn);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'Could not verify LSN sync: %', SQLERRM;
    END;
    
    RAISE NOTICE '==========================================';
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_failed_node
-- Backward-compatible wrapper for spock.recover_run.
-- ----------------------------------------------------------------------------
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
        verb             => verb
    );

    RAISE INFO '[RECOVERY] - : Legacy wrapper: recovery procedure completed';
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_finalize
-- Resumes peer subscriptions on the rescued node and drops the cloned slot.
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
    enabled_count integer;
BEGIN
    -- Resume rescue-suspended subscriptions
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
        RAISE INFO '[RECOVERY] - % : Resumed peer subscriptions (status=%)',
            target_node_name, exec_status;
    END IF;

    -- Also enable regular subscriptions from failed node that were disabled
    SELECT enabled_count
      INTO enabled_count
      FROM dblink(
               target_dsn,
               format(
                   $_sql$SELECT count(*) as enabled_count
                      FROM spock.subscription s
                      JOIN spock.node o ON o.node_id = s.sub_origin
                      JOIN spock.node t ON t.node_id = s.sub_target
                     WHERE o.node_name = %L
                       AND t.node_name = %L
                       AND NOT s.sub_rescue_temporary
                       AND NOT s.sub_enabled$_sql$,
                   failed_node_name,
                   target_node_name
               )
           ) AS t(enabled_count integer);

    IF enabled_count > 0 THEN
        PERFORM dblink_exec(
            target_dsn,
            format(
                $_sql$UPDATE spock.subscription s
                          SET sub_enabled = true
                        FROM spock.node o, spock.node t
                       WHERE o.node_id = s.sub_origin
                         AND t.node_id = s.sub_target
                         AND o.node_name = %L
                         AND t.node_name = %L
                         AND NOT s.sub_rescue_temporary
                         AND NOT s.sub_enabled$_sql$,
                failed_node_name,
                target_node_name
            )
        );
        IF verb THEN
            RAISE INFO '[RECOVERY] - % : Enabled % regular subscription(s) from % to %',
                target_node_name, enabled_count, failed_node_name, target_node_name;
        END IF;
    END IF;

    -- Drop rescue subscriptions that are marked for cleanup
    -- (Manager process also does this, but we do it explicitly for immediate cleanup)
    BEGIN
        PERFORM dblink_exec(
            target_dsn,
            format(
                $_sql$SELECT spock.sub_drop(s.sub_name, true)
                       FROM spock.subscription s
                       WHERE s.sub_rescue_temporary
                         AND s.sub_rescue_cleanup_pending$_sql$
            )
        );
        IF verb THEN
            RAISE INFO '[RECOVERY] - % : Dropped rescue subscription(s) marked for cleanup', target_node_name;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF verb THEN
                RAISE WARNING '[RECOVERY] - % : Could not drop rescue subscription(s): %', target_node_name, SQLERRM;
                RAISE INFO '[RECOVERY] - % : Manager process will clean up rescue subscriptions automatically', target_node_name;
            END IF;
    END;

    IF cloned_slot_name IS NOT NULL AND cloned_slot_name <> '' THEN
        exec_status := dblink_exec(
            source_dsn,
            format(
                $_sql$DO $_drop$BEGIN PERFORM pg_drop_replication_slot(%L); END$_drop$;$_sql$,
                cloned_slot_name
            )
        );
        IF verb THEN
            RAISE INFO '[RECOVERY] - : Dropped cloned slot % on source (status=%)',
                cloned_slot_name, exec_status;
        END IF;
    ELSE
        IF verb THEN
            RAISE INFO '[RECOVERY] - : No cloned slot supplied, skipping drop';
        END IF;
    END IF;

    RAISE NOTICE 'Recovery finalized for %. Resume normal replication monitoring.', failed_node_name;
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: spock.recover_status
-- Inspects rescue-related catalog state after recovery.
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
        RAISE INFO '[RECOVERY] - % : Subscription rescue state', target_node_name;
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
        RAISE INFO '[RECOVERY] - % : Recovery slot state', target_node_name;
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

-- ----------------------------------------------------------------------------
-- Procedure: spock.recovery
-- Full automated recovery: runs precheck with INFO messages, checks LSN sync,
-- and proceeds with recovery if target is behind source.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spock.recovery(
    text, text, text, text, text, pg_lsn, pg_lsn, timestamptz, boolean
);
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
    required boolean;
    source_lag_lsn pg_lsn;
    target_lag_lsn pg_lsn;
    source_sub_lsn pg_lsn;
    target_sub_lsn pg_lsn;
    source_slot_lsn pg_lsn;
    target_slot_lsn pg_lsn;
    n2_lsn pg_lsn;
    n3_lsn pg_lsn;
    lag_rec RECORD;
    sub_rec RECORD;
    slot_rec RECORD;
BEGIN
    verb := COALESCE(verb, false);

    -- Run precheck with INFO messages - will raise exception on any failure
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
        RAISE INFO '[CHECK] - % : No recovery needed: target has no subscriptions from failed node', target_node_name;
        RETURN;
    END IF;

    -- Check lag_tracker LSNs first
    RAISE INFO '[CHECK] - % : Checking lag_tracker LSNs from failed node to source and target...', source_node_name;
    
    BEGIN
        SELECT commit_lsn INTO source_lag_lsn
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L$_sql$,
                       failed_node_name,
                       source_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            source_lag_lsn := NULL;
            RAISE INFO '[CHECK] - % : Could not get source lag_tracker LSN: %', source_node_name, SQLERRM;
    END;

    BEGIN
        SELECT commit_lsn INTO target_lag_lsn
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L$_sql$,
                       failed_node_name,
                       target_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            target_lag_lsn := NULL;
            RAISE INFO '[CHECK] - % : Could not get target lag_tracker LSN: %', target_node_name, SQLERRM;
    END;

    -- Check subscription LSNs from failed node to source and target
    RAISE INFO '[CHECK] - % : Checking subscription LSNs from failed node to source and target...', source_node_name;
    
    BEGIN
        -- Use lag_tracker which includes both regular and rescue subscriptions
        SELECT commit_lsn INTO source_sub_lsn
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L
                               ORDER BY commit_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name,
                       source_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            source_sub_lsn := NULL;
            RAISE INFO '[CHECK] - % : Could not get source subscription LSN: %', source_node_name, SQLERRM;
    END;

    BEGIN
        -- Use lag_tracker which includes both regular and rescue subscriptions
        SELECT commit_lsn INTO target_sub_lsn
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L
                               ORDER BY commit_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name,
                       target_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            target_sub_lsn := NULL;
            RAISE INFO '[CHECK] - % : Could not get target subscription LSN: %', target_node_name, SQLERRM;
    END;

    -- Check slot LSNs from failed node to source and target
    RAISE INFO '[CHECK] - % : Checking slot LSNs from failed node to source and target...', source_node_name;
    
    BEGIN
        SELECT rs.confirmed_flush_lsn INTO source_slot_lsn
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT rs.confirmed_flush_lsn
                                FROM pg_catalog.pg_replication_slots rs
                                JOIN spock.subscription s ON rs.slot_name = spock.spock_gen_slot_name(
                                        current_database()::name,
                                        o.node_name::name,
                                        s.sub_name)::text
                                JOIN spock.node o ON o.node_id = s.sub_origin
                               WHERE o.node_name = %L
                               ORDER BY rs.confirmed_flush_lsn DESC NULLS LAST
                               LIMIT 1$_sql$,
                       failed_node_name
                   )
               ) AS t(confirmed_flush_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            source_slot_lsn := NULL;
            RAISE INFO '[CHECK] - % : Could not get source slot LSN: %', source_node_name, SQLERRM;
    END;

    BEGIN
        SELECT rs.confirmed_flush_lsn INTO target_slot_lsn
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT rs.confirmed_flush_lsn
                                FROM pg_catalog.pg_replication_slots rs
                                JOIN spock.subscription s ON rs.slot_name = spock.spock_gen_slot_name(
                                        current_database()::name,
                                        o.node_name::name,
                                        s.sub_name)::text
                                JOIN spock.node o ON o.node_id = s.sub_origin
                               WHERE o.node_name = %L
                               ORDER BY rs.confirmed_flush_lsn DESC NULLS LAST
                               LIMIT 1$_sql$,
                       failed_node_name
                   )
               ) AS t(confirmed_flush_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            target_slot_lsn := NULL;
            RAISE INFO '[CHECK] - % : Could not get target slot LSN: %', target_node_name, SQLERRM;
    END;

    -- Print all LSNs
    RAISE INFO '[CHECK] - % : LSN Summary:', source_node_name;
    RAISE INFO '[CHECK] - % :   lag_tracker:   source (%->%) = %, target (%->%) = %', 
        source_node_name, failed_node_name, source_node_name, COALESCE(source_lag_lsn::text, 'NULL'),
        failed_node_name, target_node_name, COALESCE(target_lag_lsn::text, 'NULL');
    RAISE INFO '[CHECK] - % :   subscription:   source (%->%) = %, target (%->%) = %', 
        source_node_name, failed_node_name, source_node_name, COALESCE(source_sub_lsn::text, 'NULL'),
        failed_node_name, target_node_name, COALESCE(target_sub_lsn::text, 'NULL');
    RAISE INFO '[CHECK] - % :   slot:           source (%->%) = %, target (%->%) = %', 
        source_node_name, failed_node_name, source_node_name, COALESCE(source_slot_lsn::text, 'NULL'),
        failed_node_name, target_node_name, COALESCE(target_slot_lsn::text, 'NULL');

    -- Check if all LSNs are synced - if so, recovery not required, quit
    IF (source_lag_lsn IS NOT NULL AND target_lag_lsn IS NOT NULL AND source_lag_lsn = target_lag_lsn)
       AND (source_sub_lsn IS NOT NULL AND target_sub_lsn IS NOT NULL AND source_sub_lsn = target_sub_lsn)
       AND (source_slot_lsn IS NOT NULL AND target_slot_lsn IS NOT NULL AND source_slot_lsn = target_slot_lsn) THEN
        RAISE INFO '[CHECK] - % : All LSNs are synced - recovery not required', source_node_name;
        RETURN;
    END IF;

    -- If we get here, recovery is needed
    RAISE INFO '[CHECK] - % : LSNs are not synced - recovery required', source_node_name;

    -- Proceed with recovery
    CALL spock.recover_run(
        failed_node_name => failed_node_name,
        source_node_name => source_node_name,
        source_dsn       => source_dsn,
        target_node_name => target_node_name,
        target_dsn       => target_dsn,
        stop_lsn         => stop_lsn,
        skip_lsn         => skip_lsn,
        stop_timestamp   => stop_timestamp,
        verb             => verb
    );

    -- Get cloned slot name from source node for finalization
    SELECT slot_name INTO cloned_slot_name
      FROM dblink(
               source_dsn,
               $_sql$SELECT slot_name
                        FROM pg_replication_slots
                       WHERE slot_name LIKE 'spock_rescue_clone_%'
                         AND active = true
                       ORDER BY slot_name DESC
                       LIMIT 1$_sql$
           ) AS t(slot_name text);

    IF cloned_slot_name IS NULL THEN
        RAISE INFO '[CHECK] - % : Recovery skipped: no rescue required.', target_node_name;
        RETURN;
    END IF;

    pending_cleanup := 0;
    IF verb THEN
        RAISE INFO '[RECOVERY] - % : Waiting for temporary rescue subscription to signal cleanup...',
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
        RAISE INFO '[RECOVERY] - % : Rescue subscription still applying. Re-run spock.recovery once cleanup has been signalled',
            target_node_name;
        RETURN;
    END IF;

    IF verb THEN
        RAISE INFO '[RECOVERY] - % : Cleanup flag detected; proceeding with finalization', target_node_name;
    END IF;

    CALL spock.recover_finalize(
        target_dsn       => target_dsn,
        target_node_name => target_node_name,
        failed_node_name => failed_node_name,
        source_dsn       => source_dsn,
        cloned_slot_name => cloned_slot_name,
        verb             => verb
    );

    -- Print LSN verification from lag_tracker
    RAISE NOTICE '';
    RAISE NOTICE '=== Recovery Complete - LSN Verification ===';
    
    FOR lag_rec IN
        SELECT 
            receiver_name,
            commit_lsn,
            replication_lag_bytes,
            replication_lag
        FROM dblink(
                 target_dsn,
                 format(
                     $_sql$SELECT 
                         receiver_name,
                         commit_lsn,
                         replication_lag_bytes,
                         replication_lag
                     FROM spock.lag_tracker
                     WHERE origin_name = %L
                       AND receiver_name IN (%L, %L)
                     ORDER BY receiver_name$_sql$,
                     failed_node_name,
                     target_node_name,
                     source_node_name
                 )
             ) AS t(
                 receiver_name text,
                 commit_lsn pg_lsn,
                 replication_lag_bytes bigint,
                 replication_lag interval
             )
    LOOP
        RAISE NOTICE '  %: commit_lsn=%, lag_bytes=%, lag_time=%',
            lag_rec.receiver_name,
            lag_rec.commit_lsn,
            COALESCE(lag_rec.replication_lag_bytes::text, 'NULL'),
            COALESCE(lag_rec.replication_lag::text, 'NULL');
    END LOOP;

    -- Verify sync
    BEGIN
        SELECT commit_lsn INTO n2_lsn
        FROM dblink(
                 target_dsn,
                 format(
                     $_sql$SELECT commit_lsn
                      FROM spock.lag_tracker
                     WHERE origin_name = %L AND receiver_name = %L$_sql$,
                     failed_node_name,
                     target_node_name
                 )
             ) AS t(commit_lsn pg_lsn);
        
        SELECT commit_lsn INTO n3_lsn
        FROM dblink(
                 source_dsn,
                 format(
                     $_sql$SELECT commit_lsn
                      FROM spock.lag_tracker
                     WHERE origin_name = %L AND receiver_name = %L$_sql$,
                     failed_node_name,
                     source_node_name
                 )
             ) AS t(commit_lsn pg_lsn);
        
        IF n2_lsn IS NULL OR n3_lsn IS NULL THEN
            RAISE WARNING 'One or both LSNs are NULL: n2_lsn=%, n3_lsn=%', n2_lsn, n3_lsn;
        ELSIF n2_lsn = n3_lsn THEN
            RAISE NOTICE '✓ SYNCED: % and % have the same LSN from %: %',
                target_node_name, source_node_name, failed_node_name, n2_lsn;
        ELSIF n2_lsn > n3_lsn THEN
            RAISE WARNING '% is ahead: %_lsn=%, %_lsn=%, lag=% bytes',
                target_node_name, target_node_name, n2_lsn, source_node_name, n3_lsn,
                pg_wal_lsn_diff(n2_lsn, n3_lsn);
        ELSE
            RAISE WARNING '% is ahead: %_lsn=%, %_lsn=%, lag=% bytes',
                source_node_name, source_node_name, n3_lsn, target_node_name, n2_lsn,
                pg_wal_lsn_diff(n3_lsn, n2_lsn);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'Could not verify LSN sync: %', SQLERRM;
    END;
    
    RAISE NOTICE '==========================================';
END;
$$;
