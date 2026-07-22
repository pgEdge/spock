/* spock--6.0.0--6.0.1.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.0.1'" to load this file. \quit

-- ===========================================================================
-- Group replication slots (BDR/PGD-style)
--
-- One internally managed, inactive logical replication slot per Spock
-- database/group tracks the oldest safe WAL position for the whole group.
-- All safety decisions are recorded durably in the catalog tables below so
-- that they survive restarts without relying on shared memory.
--
-- OPERATIONAL RULE: group slots are managed by Spock. They must NEVER be
-- dropped manually with pg_drop_replication_slot(); doing so can cause loss
-- of WAL still required by other group members. Use spock.repair_group_slot()
-- for recovery.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Durable metadata
-- ---------------------------------------------------------------------------

-- One row per local node/group: the authoritative state of the group slot.
CREATE TABLE spock.group_slot_state (
    node_id                oid  NOT NULL PRIMARY KEY,
    dboid                  oid  NOT NULL,
    slot_name              name NOT NULL,
    membership_generation  bigint      NOT NULL DEFAULT 1,
    node_state             text        NOT NULL DEFAULT 'active',
    safe_lsn               pg_lsn      NOT NULL DEFAULT '0/0',
    freeze_lsn             pg_lsn      NOT NULL DEFAULT '0/0',
    last_advanced_lsn      pg_lsn      NOT NULL DEFAULT '0/0',
    updated_at             timestamptz NOT NULL DEFAULT now(),
    blocked_reason         text,
    repair_required        boolean     NOT NULL DEFAULT false,
    manual_override        boolean     NOT NULL DEFAULT false,
    CHECK (node_state IN ('active','joining','parting','unknown'))
) WITH (user_catalog_table=true);

-- Membership generations: who is a member of the group at each generation,
-- and in what lifecycle state.
CREATE TABLE spock.group_slot_membership (
    membership_generation  bigint      NOT NULL,
    member_node_id         oid         NOT NULL,
    member_node_name       name,
    state                  text        NOT NULL DEFAULT 'active',
    required               boolean     NOT NULL DEFAULT true,
    effective_lsn          pg_lsn      NOT NULL DEFAULT '0/0',
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (membership_generation, member_node_id),
    CHECK (state IN ('active','joining','parting','removed','unknown'))
) WITH (user_catalog_table=true);

-- Per-member replay progress gathered on each maintenance tick.
CREATE TABLE spock.group_slot_member_progress (
    membership_generation  bigint      NOT NULL,
    remote_node_id         oid         NOT NULL,
    sub_id                 oid,
    node_state             text,
    required               boolean     NOT NULL DEFAULT true,
    flush_lsn              pg_lsn,
    replay_lsn             pg_lsn,
    confirmed_lsn          pg_lsn,
    updated_at             timestamptz,
    reason                 text,
    PRIMARY KEY (membership_generation, remote_node_id)
) WITH (user_catalog_table=true);

-- ---------------------------------------------------------------------------
-- Deterministic naming (C)
-- ---------------------------------------------------------------------------
CREATE FUNCTION spock.local_group_slot_name()
RETURNS name
AS 'MODULE_PATHNAME', 'spock_local_group_slot_name_sql'
LANGUAGE C STABLE;

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Oldest WAL still required by any downstream (group-safe horizon), computed
-- as the minimum confirmed_flush_lsn across all per-subscription provider
-- slots on this node.  Excludes the group slot itself.  Returns NULL when
-- there are no downstream provider slots.
CREATE FUNCTION spock.group_slot_min_downstream_lsn()
RETURNS pg_lsn
LANGUAGE sql STABLE AS $$
    SELECT min(confirmed_flush_lsn)
      FROM pg_replication_slots
     WHERE database = current_database()
       AND plugin IN ('spock_output', 'spock')
       AND slot_type = 'logical'
       AND slot_name LIKE 'spk\_%'
       AND slot_name <> COALESCE(spock.local_group_slot_name(), '');
$$;

-- Progress staleness threshold as an interval.  Read via current_setting so
-- it always reflects the live GUC; parsed as an interval because a GUC with
-- unit seconds is displayed with a unit suffix (e.g. '1min').
CREATE FUNCTION spock.group_slot_staleness()
RETURNS interval
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
             current_setting('spock.group_slots_progress_staleness_timeout', true),
             '60s')::interval;
$$;

-- Ensure the physical (inactive) group slot exists.  MUST be called before
-- this transaction performs any write, because a logical replication slot
-- cannot be created in a transaction that has already written.
-- Returns true when a group slot name is defined for this node.
CREATE FUNCTION spock.group_slot_ensure()
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_slot   name;
    v_exists boolean;
BEGIN
    v_slot := spock.local_group_slot_name();
    IF v_slot IS NULL THEN
        RETURN false;
    END IF;

    SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = v_slot)
      INTO v_exists;

    IF NOT v_exists THEN
        PERFORM pg_create_logical_replication_slot(v_slot, 'spock_output');
    END IF;

    RETURN true;
END;
$$;

-- Refresh membership rows and per-member progress for the current generation.
-- Preserves any lifecycle state (joining/parting/unknown/removed) set by the
-- add/remove workflows; only newly-discovered members default to 'active'.
CREATE FUNCTION spock.group_slot_refresh_members(p_gen bigint, p_stale interval)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_local oid;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RETURN;
    END IF;

    -- Ensure a membership row exists for every other known cluster node,
    -- preserving any lifecycle state already recorded for existing members.
    INSERT INTO spock.group_slot_membership
            (membership_generation, member_node_id, member_node_name, state, required)
    SELECT p_gen, n.node_id, n.node_name, 'active', true
      FROM spock.node n
     WHERE n.node_id <> v_local
       AND NOT EXISTS (SELECT 1 FROM spock.group_slot_membership m
                        WHERE m.membership_generation = p_gen
                          AND m.member_node_id = n.node_id);

    UPDATE spock.group_slot_membership m
       SET member_node_name = n.node_name,
           updated_at = now()
      FROM spock.node n
     WHERE m.membership_generation = p_gen
       AND m.member_node_id = n.node_id
       AND m.member_node_name IS DISTINCT FROM n.node_name;

    -- Recompute per-member progress from scratch each tick.  The freshness
    -- source of truth is spock.progress.last_updated_ts.
    DELETE FROM spock.group_slot_member_progress WHERE membership_generation = p_gen;

    -- Refresh per-member progress from apply-group progress (inbound replay).
    INSERT INTO spock.group_slot_member_progress
            (membership_generation, remote_node_id, sub_id, node_state,
             required, flush_lsn, replay_lsn, confirmed_lsn, updated_at, reason)
    SELECT p_gen,
           m.member_node_id,
           (SELECT s.sub_id FROM spock.subscription s
             WHERE s.sub_origin = m.member_node_id
               AND s.sub_target = v_local
             LIMIT 1),
           m.state,
           m.required,
           p.received_lsn,
           p.remote_commit_lsn,
           cf.confirmed_flush_lsn,
           p.last_updated_ts,
           CASE
               WHEN p.last_updated_ts IS NULL THEN 'no_progress'
               WHEN now() - p.last_updated_ts > p_stale THEN 'stale'
               ELSE NULL
           END
      FROM spock.group_slot_membership m
      LEFT JOIN spock.progress p
             ON p.remote_node_id = m.member_node_id
            AND p.node_id = v_local
      LEFT JOIN LATERAL (
               SELECT min(confirmed_flush_lsn) AS confirmed_flush_lsn
                 FROM pg_replication_slots
                WHERE database = current_database()
                  AND slot_type = 'logical'
           ) cf ON true
     WHERE m.membership_generation = p_gen;
END;
$$;

-- Evaluate the current safety state.  Returns the blocked reason (NULL when
-- advancement is permitted) and the computed group-safe LSN.
CREATE FUNCTION spock.group_slot_evaluate(
    p_gen   bigint,
    p_mode  text,
    p_stale interval,
    OUT reason   text,
    OUT safe_lsn pg_lsn
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_local      oid;
    v_node_state text;
    v_freeze     pg_lsn;
    v_min        pg_lsn;
BEGIN
    reason := NULL;

    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RETURN;
    END IF;

    SELECT node_state, freeze_lsn
      INTO v_node_state, v_freeze
      FROM spock.group_slot_state
     WHERE node_id = v_local;

    IF NOT FOUND THEN
        reason := 'missing_slot_state';
        RETURN;
    END IF;

    -- Compute the group-safe horizon (min confirmed downstream).  When there
    -- is nothing downstream, the current WAL insert position is safe.
    v_min := spock.group_slot_min_downstream_lsn();
    IF v_min IS NULL THEN
        v_min := pg_current_wal_lsn();
    END IF;

    -- During a part, never advance past the frozen part boundary.
    IF v_freeze <> '0/0'::pg_lsn AND v_freeze < v_min THEN
        v_min := v_freeze;
    END IF;
    safe_lsn := v_min;

    -- Hard blockers, in priority order.
    IF v_node_state = 'unknown'
       OR EXISTS (SELECT 1 FROM spock.group_slot_membership
                   WHERE membership_generation = p_gen AND state = 'unknown') THEN
        reason := 'unknown_node_state';
        RETURN;
    END IF;

    IF v_node_state = 'joining'
       OR EXISTS (SELECT 1 FROM spock.group_slot_membership
                   WHERE membership_generation = p_gen AND state = 'joining') THEN
        reason := 'join_in_progress';
        RETURN;
    END IF;

    IF v_node_state = 'parting'
       OR EXISTS (SELECT 1 FROM spock.group_slot_membership
                   WHERE membership_generation = p_gen AND state = 'parting') THEN
        reason := 'part_in_progress';
        RETURN;
    END IF;

    -- Any required, non-removed membership row belonging to a different
    -- generation indicates the cluster has not converged on one generation.
    IF EXISTS (SELECT 1 FROM spock.group_slot_membership
                WHERE required
                  AND state <> 'removed'
                  AND membership_generation <> p_gen) THEN
        reason := 'membership_generation_mismatch';
        RETURN;
    END IF;

    -- Stale progress for any required, active member.
    IF EXISTS (
        SELECT 1
          FROM spock.group_slot_membership m
          LEFT JOIN spock.group_slot_member_progress pr
                 ON pr.membership_generation = m.membership_generation
                AND pr.remote_node_id = m.member_node_id
         WHERE m.membership_generation = p_gen
           AND m.required
           AND m.state = 'active'
           AND (pr.updated_at IS NULL
                OR now() - pr.updated_at > p_stale)
    ) THEN
        reason := 'stale_progress';
        RETURN;
    END IF;

    -- Advisory-only mode: keep metadata fresh but never advance.
    IF p_mode = 'off' THEN
        reason := 'safety_mode_off';
        RETURN;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Background-worker tick (invoked by the C group-slot worker)
-- ---------------------------------------------------------------------------
CREATE FUNCTION spock.group_slot_worker_tick()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_local   oid;
    v_slot    name;
    v_gen     bigint;
    v_mode    text;
    v_stale   interval;
    v_reason  text;
    v_safe    pg_lsn;
    v_present boolean;
    v_cur     pg_lsn;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RETURN;
    END IF;

    v_slot  := spock.local_group_slot_name();
    v_mode  := COALESCE(current_setting('spock.group_slots_safety_mode', true), 'strict');
    v_stale := spock.group_slot_staleness();

    -- Create the physical slot BEFORE any write in this transaction.
    PERFORM spock.group_slot_ensure();

    -- Seed/refresh metadata (safe to write now that the slot exists).
    UPDATE spock.group_slot_state SET slot_name = v_slot WHERE node_id = v_local;
    IF NOT FOUND THEN
        INSERT INTO spock.group_slot_state (node_id, dboid, slot_name)
        VALUES (v_local,
                (SELECT oid FROM pg_database WHERE datname = current_database()),
                v_slot);
    END IF;

    SELECT membership_generation INTO v_gen
      FROM spock.group_slot_state WHERE node_id = v_local;

    PERFORM spock.group_slot_refresh_members(v_gen, v_stale);

    SELECT reason, safe_lsn INTO v_reason, v_safe
      FROM spock.group_slot_evaluate(v_gen, v_mode, v_stale);

    v_present := EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = v_slot);
    IF NOT v_present THEN
        UPDATE spock.group_slot_state
           SET blocked_reason = 'missing_slot_state',
               repair_required = true,
               safe_lsn = COALESCE(v_safe, safe_lsn),
               updated_at = now()
         WHERE node_id = v_local;
        RETURN;
    END IF;

    IF v_reason IS NULL THEN
        IF v_safe IS NOT NULL THEN
            SELECT restart_lsn INTO v_cur
              FROM pg_replication_slots WHERE slot_name = v_slot;

            IF v_cur IS NULL OR v_safe > v_cur THEN
                PERFORM pg_replication_slot_advance(v_slot, v_safe);
                UPDATE spock.group_slot_state
                   SET last_advanced_lsn = v_safe
                 WHERE node_id = v_local;
            END IF;
        END IF;

        UPDATE spock.group_slot_state
           SET blocked_reason = NULL,
               repair_required = false,
               safe_lsn = v_safe,
               updated_at = now()
         WHERE node_id = v_local;
    ELSE
        UPDATE spock.group_slot_state
           SET blocked_reason = v_reason,
               safe_lsn = COALESCE(v_safe, safe_lsn),
               repair_required = (v_reason = 'missing_slot_state'),
               updated_at = now()
         WHERE node_id = v_local;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Inspection
-- ---------------------------------------------------------------------------
CREATE FUNCTION spock.group_slot_status(
    OUT slot_name             name,
    OUT membership_generation bigint,
    OUT node_state            text,
    OUT safe_lsn              pg_lsn,
    OUT freeze_lsn            pg_lsn,
    OUT last_advanced_lsn     pg_lsn,
    OUT blocked_reason        text,
    OUT repair_required       boolean,
    OUT slot_present          boolean,
    OUT restart_lsn           pg_lsn,
    OUT confirmed_flush_lsn   pg_lsn,
    OUT updated_at            timestamptz,
    OUT required_members      int,
    OUT stale_members         int
)
RETURNS SETOF record
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_local oid;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT g.slot_name,
           g.membership_generation,
           g.node_state,
           g.safe_lsn,
           g.freeze_lsn,
           g.last_advanced_lsn,
           g.blocked_reason,
           g.repair_required,
           (rs.slot_name IS NOT NULL) AS slot_present,
           rs.restart_lsn,
           rs.confirmed_flush_lsn,
           g.updated_at,
           (SELECT count(*)::int FROM spock.group_slot_membership m
             WHERE m.membership_generation = g.membership_generation
               AND m.required AND m.state <> 'removed'),
           (SELECT count(*)::int
              FROM spock.group_slot_membership m
              LEFT JOIN spock.group_slot_member_progress pr
                     ON pr.membership_generation = m.membership_generation
                    AND pr.remote_node_id = m.member_node_id
             WHERE m.membership_generation = g.membership_generation
               AND m.required AND m.state = 'active'
               AND (pr.updated_at IS NULL
                    OR now() - pr.updated_at > spock.group_slot_staleness()))
      FROM spock.group_slot_state g
      LEFT JOIN pg_replication_slots rs ON rs.slot_name = g.slot_name
     WHERE g.node_id = v_local;
END;
$$;

-- ---------------------------------------------------------------------------
-- Controlled manual advancement
-- ---------------------------------------------------------------------------
CREATE FUNCTION spock.advance_group_slot(
    target_lsn pg_lsn DEFAULT NULL,
    force      boolean DEFAULT false
)
RETURNS pg_lsn
LANGUAGE plpgsql AS $$
DECLARE
    v_local  oid;
    v_slot   name;
    v_gen    bigint;
    v_mode   text;
    v_stale  interval;
    v_reason text;
    v_safe   pg_lsn;
    v_target pg_lsn;
    v_cur    pg_lsn;
    v_hard   boolean;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RAISE EXCEPTION 'current database is not configured as a spock node';
    END IF;

    v_slot  := spock.local_group_slot_name();
    v_mode  := COALESCE(current_setting('spock.group_slots_safety_mode', true), 'strict');
    v_stale := spock.group_slot_staleness();

    PERFORM spock.group_slot_ensure();

    SELECT membership_generation INTO v_gen
      FROM spock.group_slot_state WHERE node_id = v_local;
    IF v_gen IS NULL THEN
        RAISE EXCEPTION 'group slot metadata missing; run spock.repair_group_slot()';
    END IF;

    PERFORM spock.group_slot_refresh_members(v_gen, v_stale);

    SELECT reason, safe_lsn INTO v_reason, v_safe
      FROM spock.group_slot_evaluate(v_gen, v_mode, v_stale);

    -- Hard blockers can never be bypassed, even with force.
    v_hard := v_reason IN ('unknown_node_state', 'join_in_progress',
                           'part_in_progress', 'membership_generation_mismatch',
                           'missing_slot_state');

    IF v_reason IS NOT NULL THEN
        IF v_hard THEN
            RAISE EXCEPTION 'group slot advancement blocked: %', v_reason;
        ELSIF NOT (force AND v_mode <> 'strict') THEN
            -- Soft blockers (stale_progress, safety_mode_off) require an
            -- explicit force AND a non-strict safety mode.
            RAISE EXCEPTION 'group slot advancement blocked: % (use force with a non-strict safety mode to override)', v_reason;
        ELSE
            RAISE WARNING 'group slot advancement forced past soft blocker: %', v_reason;
        END IF;
    END IF;

    v_target := COALESCE(target_lsn, v_safe);

    -- Conflict horizon protection: never advance past the group-safe LSN
    -- unless force is used with a non-strict safety mode.
    IF v_safe IS NOT NULL AND v_target > v_safe THEN
        IF force AND v_mode <> 'strict' THEN
            RAISE WARNING 'group slot advanced past group-safe horizon (% > %) by explicit override',
                v_target, v_safe;
        ELSE
            RAISE EXCEPTION 'requested LSN % is past the group-safe horizon %', v_target, v_safe;
        END IF;
    END IF;

    SELECT restart_lsn INTO v_cur FROM pg_replication_slots WHERE slot_name = v_slot;
    IF v_cur IS NULL OR v_target > v_cur THEN
        PERFORM pg_replication_slot_advance(v_slot, v_target);
    END IF;

    UPDATE spock.group_slot_state
       SET last_advanced_lsn = v_target,
           safe_lsn = COALESCE(v_safe, safe_lsn),
           blocked_reason = CASE WHEN v_reason IS NULL THEN NULL ELSE blocked_reason END,
           manual_override = force,
           updated_at = now()
     WHERE node_id = v_local;

    RETURN v_target;
END;
$$;

-- ---------------------------------------------------------------------------
-- Safe repair
-- ---------------------------------------------------------------------------
CREATE FUNCTION spock.repair_group_slot(mode text DEFAULT 'recreate')
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_local   oid;
    v_slot    name;
    v_present boolean;
    v_safety  text;
    v_safe    pg_lsn;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RAISE EXCEPTION 'current database is not configured as a spock node';
    END IF;

    v_slot   := spock.local_group_slot_name();
    v_safety := COALESCE(current_setting('spock.group_slots_safety_mode', true), 'strict');
    v_present := EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = v_slot);

    IF mode NOT IN ('relink', 'recreate') THEN
        RAISE EXCEPTION 'unknown repair mode %; use ''relink'' or ''recreate''', mode;
    END IF;

    -- Recreating a missing slot must happen BEFORE any write in this
    -- transaction, because a logical replication slot cannot be created in a
    -- transaction that has already performed writes.  Recreation starts
    -- protection at the current WAL position and therefore DROPS protection
    -- for older WAL, so it requires an explicit non-strict safety mode.
    IF mode = 'recreate' AND NOT v_present THEN
        IF v_safety = 'strict' THEN
            RAISE EXCEPTION 'refusing to recreate a missing group slot in strict safety mode'
                USING ERRCODE = 'object_not_in_prerequisite_state',
                      HINT = 'Set spock.group_slots_safety_mode = repair to allow recreation (older WAL protection will be lost).';
        END IF;

        RAISE WARNING 'recreating missing group slot %; WAL older than the current position is no longer protected', v_slot;
        PERFORM pg_create_logical_replication_slot(v_slot, 'spock_output');
        v_present := true;
        SELECT restart_lsn INTO v_safe FROM pg_replication_slots WHERE slot_name = v_slot;
    END IF;

    -- Now it is safe to write: relink metadata to the deterministic name.
    UPDATE spock.group_slot_state
       SET slot_name = v_slot,
           repair_required = (NOT v_present),
           blocked_reason = CASE WHEN v_present THEN NULL ELSE 'missing_slot_state' END,
           safe_lsn = CASE WHEN v_safe IS NOT NULL THEN v_safe ELSE safe_lsn END,
           updated_at = now()
     WHERE node_id = v_local;
    IF NOT FOUND THEN
        INSERT INTO spock.group_slot_state (node_id, dboid, slot_name, repair_required, safe_lsn)
        VALUES (v_local,
                (SELECT oid FROM pg_database WHERE datname = current_database()),
                v_slot,
                (NOT v_present),
                COALESCE(v_safe, '0/0'::pg_lsn));
    END IF;

    IF mode = 'recreate' THEN
        IF v_safe IS NOT NULL THEN
            RETURN 'recreated';
        ELSE
            RETURN 'already_present';
        END IF;
    ELSIF v_present THEN
        RETURN 'relinked';
    ELSE
        RETURN 'missing_slot';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Add/remove (ZODAN) integration helpers
-- ---------------------------------------------------------------------------

-- The group-safe base point a joining node can rely on, or NULL when the
-- group slot is currently blocked (caller should fall back to temp slots).
CREATE FUNCTION spock.group_slot_safe_horizon()
RETURNS pg_lsn
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_local  oid;
    v_safe   pg_lsn;
    v_reason text;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RETURN NULL;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM spock.group_slot_state WHERE node_id = v_local) THEN
        RETURN NULL;
    END IF;

    SELECT reason, safe_lsn INTO v_reason, v_safe
      FROM spock.group_slot_evaluate(
             (SELECT membership_generation FROM spock.group_slot_state WHERE node_id = v_local),
             COALESCE(current_setting('spock.group_slots_safety_mode', true), 'strict'),
             spock.group_slot_staleness());

    IF v_reason IS NOT NULL THEN
        RETURN NULL;
    END IF;
    RETURN v_safe;
END;
$$;

-- Begin a join: advance to the next generation, mark the joining node, and
-- block advancement until every remaining node agrees on the new generation.
CREATE FUNCTION spock.group_slot_begin_join(joining_node_name name)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_local   oid;
    v_join    oid;
    v_gen     bigint;
    v_newgen  bigint;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RAISE EXCEPTION 'current database is not configured as a spock node';
    END IF;

    SELECT node_id INTO v_join FROM spock.node WHERE node_name = joining_node_name;

    SELECT membership_generation INTO v_gen
      FROM spock.group_slot_state WHERE node_id = v_local;
    IF v_gen IS NULL THEN
        PERFORM spock.group_slot_worker_tick();
        SELECT membership_generation INTO v_gen
          FROM spock.group_slot_state WHERE node_id = v_local;
    END IF;

    v_newgen := v_gen + 1;

    -- Start the new generation clean, then carry existing active members
    -- forward and record the joining node.
    DELETE FROM spock.group_slot_membership WHERE membership_generation = v_newgen;

    INSERT INTO spock.group_slot_membership
            (membership_generation, member_node_id, member_node_name, state, required)
    SELECT v_newgen, member_node_id, member_node_name, state, required
      FROM spock.group_slot_membership
     WHERE membership_generation = v_gen
       AND state <> 'removed'
       AND (v_join IS NULL OR member_node_id <> v_join);

    IF v_join IS NOT NULL THEN
        INSERT INTO spock.group_slot_membership
                (membership_generation, member_node_id, member_node_name, state, required)
        VALUES (v_newgen, v_join, joining_node_name, 'joining', true);
    END IF;

    -- Retire the previous generation's rows so only one generation is current.
    DELETE FROM spock.group_slot_membership WHERE membership_generation = v_gen;

    UPDATE spock.group_slot_state
       SET membership_generation = v_newgen,
           node_state = 'joining',
           blocked_reason = 'join_in_progress',
           updated_at = now()
     WHERE node_id = v_local;

    RETURN v_newgen;
END;
$$;

-- Complete a join: promote the joining node to active and resume advancement.
CREATE FUNCTION spock.group_slot_complete_join(joining_node_name name)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_local oid;
    v_gen   bigint;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RETURN;
    END IF;

    SELECT membership_generation INTO v_gen
      FROM spock.group_slot_state WHERE node_id = v_local;

    UPDATE spock.group_slot_membership
       SET state = 'active', updated_at = now()
     WHERE membership_generation = v_gen
       AND member_node_name = joining_node_name;

    UPDATE spock.group_slot_state
       SET node_state = 'active',
           blocked_reason = NULL,
           updated_at = now()
     WHERE node_id = v_local;
END;
$$;

-- Begin a part: freeze the group slot at the current safe boundary and block
-- advancement until the remaining nodes agree on the new generation.
CREATE FUNCTION spock.group_slot_begin_part(parting_node_name name)
RETURNS pg_lsn
LANGUAGE plpgsql AS $$
DECLARE
    v_local  oid;
    v_part   oid;
    v_gen    bigint;
    v_safe   pg_lsn;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RAISE EXCEPTION 'current database is not configured as a spock node';
    END IF;

    SELECT node_id INTO v_part FROM spock.node WHERE node_name = parting_node_name;

    SELECT membership_generation, safe_lsn INTO v_gen, v_safe
      FROM spock.group_slot_state WHERE node_id = v_local;
    IF v_gen IS NULL THEN
        RAISE EXCEPTION 'group slot metadata missing; run spock.repair_group_slot()';
    END IF;

    IF v_part IS NOT NULL THEN
        UPDATE spock.group_slot_membership
           SET state = 'parting', updated_at = now()
         WHERE membership_generation = v_gen AND member_node_id = v_part;
    END IF;

    UPDATE spock.group_slot_state
       SET node_state = 'parting',
           freeze_lsn = CASE WHEN safe_lsn = '0/0'::pg_lsn THEN freeze_lsn ELSE safe_lsn END,
           blocked_reason = 'part_in_progress',
           updated_at = now()
     WHERE node_id = v_local;

    RETURN v_safe;
END;
$$;

-- Complete a part: advance to the next generation with the removed node no
-- longer required, clear the freeze boundary, and resume advancement.
CREATE FUNCTION spock.group_slot_complete_part(parting_node_name name)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_local  oid;
    v_part   oid;
    v_gen    bigint;
    v_newgen bigint;
BEGIN
    SELECT node_id INTO v_local FROM spock.local_node;
    IF v_local IS NULL THEN
        RAISE EXCEPTION 'current database is not configured as a spock node';
    END IF;

    SELECT node_id INTO v_part FROM spock.node WHERE node_name = parting_node_name;

    SELECT membership_generation INTO v_gen
      FROM spock.group_slot_state WHERE node_id = v_local;
    v_newgen := v_gen + 1;

    -- Carry remaining members forward; the parting node is dropped from the
    -- required set (it is simply not carried into the new generation).
    DELETE FROM spock.group_slot_membership WHERE membership_generation = v_newgen;

    INSERT INTO spock.group_slot_membership
            (membership_generation, member_node_id, member_node_name, state, required)
    SELECT v_newgen, member_node_id, member_node_name, 'active', true
      FROM spock.group_slot_membership
     WHERE membership_generation = v_gen
       AND (v_part IS NULL OR member_node_id <> v_part)
       AND state <> 'removed';

    DELETE FROM spock.group_slot_membership WHERE membership_generation = v_gen;

    UPDATE spock.group_slot_state
       SET membership_generation = v_newgen,
           node_state = 'active',
           freeze_lsn = '0/0'::pg_lsn,
           blocked_reason = NULL,
           updated_at = now()
     WHERE node_id = v_local;

    RETURN v_newgen;
END;
$$;

-- Privileged maintenance functions.
REVOKE ALL ON FUNCTION spock.advance_group_slot(pg_lsn, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.repair_group_slot(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.group_slot_worker_tick() FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.group_slot_ensure() FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.group_slot_begin_join(name) FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.group_slot_complete_join(name) FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.group_slot_begin_part(name) FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.group_slot_complete_part(name) FROM PUBLIC;
