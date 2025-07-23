#!/usr/bin/env python3
"""
Adds a new node to a Spock cluster using psql (no dblink).
Each step is logged and all SQL is executed via subprocess.
"""

import subprocess
import json
import time
from typing import List, Dict, Any, Optional
import argparse

def log(msg: str):
    print(f"[LOG] {msg}")

def info(msg: str):
    print(f"[INFO] {msg}")

def run_psql(dsn: str, sql: str, fetch: bool = False) -> Optional[List[Dict[str, Any]]]:
    """
    Runs a SQL command using psql and returns results as list of dicts if fetch=True.
    """
    cmd = [
        "psql",
        dsn,
        "-X",
        "-A",
        "-t",
        "-c",
        sql
    ]
    info(f"Running SQL on DSN: {dsn}\nSQL: {sql}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        log(f"SQL failed: {result.stderr.strip()}")
        return None
    if fetch:
        lines = [line for line in result.stdout.strip().split('\n') if line]
        if not lines:
            return []
        # Assume columns are returned in order, split by '|'
        # You must know the column order for each query
        return [dict(zip(sql.split("SELECT")[1].split("FROM")[0].replace(" ", "").split(","), line.split("|"))) for line in lines]
    return None

def get_spock_nodes(dsn: str) -> List[Dict[str, Any]]:
    sql = """
    SELECT n.node_id, n.node_name, n.location, n.country, n.info, i.if_dsn
    FROM spock.node n
    JOIN spock.node_interface i ON n.node_id = i.if_nodeid;
    """
    info("[STEP] Fetching Spock nodes from remote cluster")
    cmd = [
        "psql",
        dsn,
        "-X",
        "-A",
        "-F", ",",
        "-t",
        "-c",
        sql
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        log("[STEP] Failed to fetch nodes.")
        return []
    lines = [line for line in result.stdout.strip().split('\n') if line]
    columns = ["node_id", "node_name", "location", "country", "info", "dsn"]
    rows = []
    for line in lines:
        values = line.split(",")
        row = dict(zip(columns, values))
        rows.append(row)
    info(f"[STEP] Retrieved {len(rows)} nodes from remote DSN: {dsn}")
    return rows

def node_exists(dsn: str, node_name: str) -> bool:
    sql = f"SELECT count(*) FROM spock.node WHERE node_name = '{node_name}';"
    rows = run_psql(dsn, sql, fetch=True)
    exists = rows and int(list(rows[0].values())[0]) > 0
    info(f"[STEP] Node existence check for '{node_name}': {exists}")
    return exists

def create_node(dsn: str, node_name: str, location: str, country: str, info_json: str):
    if node_exists(dsn, node_name):
        log(f"[STEP] Node '{node_name}' already exists. Skipping creation.")
        return
    sql = f"""
    SELECT spock.node_create(
        node_name := '{node_name}',
        dsn := '{dsn}',
        location := '{location}',
        country := '{country}',
        info := '{info_json}'::jsonb
    );
    """
    info(f"[STEP] Creating node '{node_name}' on DSN: {dsn}")
    run_psql(dsn, sql)

def subscription_exists(dsn: str, sub_name: str) -> bool:
    sql = f"SELECT count(*) FROM spock.subscription WHERE sub_name = '{sub_name}';"
    rows = run_psql(dsn, sql, fetch=True)
    exists = rows and int(list(rows[0].values())[0]) > 0
    info(f"[STEP] Subscription existence check for '{sub_name}': {exists}")
    return exists

def create_sub(
    node_dsn: str,
    subscription_name: str,
    provider_dsn: str,
    replication_sets: str,
    synchronize_structure: bool,
    synchronize_data: bool,
    forward_origins: str,
    apply_delay: str,
    enabled: bool
):
    if subscription_exists(node_dsn, subscription_name):
        log(f"[STEP] Subscription '{subscription_name}' already exists. Skipping creation.")
        return
    sql = f"""
    SELECT spock.sub_create(
        subscription_name := '{subscription_name}',
        provider_dsn := '{provider_dsn}',
        replication_sets := {replication_sets},
        synchronize_structure := {str(synchronize_structure).lower()},
        synchronize_data := {str(synchronize_data).lower()},
        forward_origins := {forward_origins},
        apply_delay := '{apply_delay}',
        enabled := {str(enabled).lower()}
    );
    """
    info(f"[STEP] Creating subscription '{subscription_name}' on DSN: {node_dsn}")
    run_psql(node_dsn, sql)

def slot_exists(dsn: str, slot_name: str) -> bool:
    sql = f"SELECT count(*) FROM pg_replication_slots WHERE slot_name = '{slot_name}';"
    rows = run_psql(dsn, sql, fetch=True)
    exists = rows and int(list(rows[0].values())[0]) > 0
    info(f"[STEP] Replication slot existence check for '{slot_name}': {exists}")
    return exists

def create_replication_slot(dsn: str, slot_name: str, plugin: str = "spock_output"):
    if slot_exists(dsn, slot_name):
        log(f"[STEP] Replication slot '{slot_name}' already exists. Skipping creation.")
        return
    sql = f"SELECT slot_name, lsn FROM pg_create_logical_replication_slot('{slot_name}', '{plugin}');"
    info(f"[STEP] Creating replication slot '{slot_name}' with plugin '{plugin}' on DSN: {dsn}")
    run_psql(dsn, sql)
    
def sync_event(dsn: str) -> Optional[str]:
    """
    Triggers a sync event on the given DSN and returns the resulting LSN.
    Uses run_psql to execute the SQL.
    """
    sql = "SELECT spock.sync_event();"
    info(f"[STEP] Triggering sync event on DSN: {dsn}")
    rows = run_psql(dsn, sql, fetch=True)
    # rows is a list of dicts, but the key may be missing; fallback to first value
    if rows and len(rows[0].values()) > 0:
        lsn = list(rows[0].values())[0]
    else:
        lsn = None
    log(f"[STEP] Sync event triggered on DSN: {dsn} with LSN {lsn}")
    return lsn

def wait_for_sync_event(
    dsn: str,
    wait_for_all: bool,
    provider_node: str,
    sync_lsn: str,
    timeout_ms: int
):
    sql = f"CALL spock.wait_for_sync_event({str(wait_for_all).lower()}, '{provider_node}', '{sync_lsn}', {timeout_ms});"
    info(f"[STEP] Waiting for sync event on DSN: {dsn} for provider '{provider_node}' at LSN {sync_lsn}")
    run_psql(dsn, sql)

def get_commit_timestamp(dsn: str, origin: str, receiver: str) -> Optional[str]:
    sql = f"SELECT commit_timestamp FROM spock.lag_tracker WHERE origin_name = '{origin}' AND receiver_name = '{receiver}';"
    info(f"[STEP] Getting commit timestamp for lag from '{origin}' to '{receiver}' on DSN: {dsn}")
    rows = run_psql(dsn, sql, fetch=True)
    ts = rows[0]['commit_timestamp'] if rows else None
    log(f"[STEP] Commit timestamp for lag: {ts}")
    return ts

def advance_replication_slot(dsn: str, slot_name: str, sync_timestamp: str):
    if not sync_timestamp:
        log(f"[STEP] Commit timestamp is NULL, skipping slot advance for slot '{slot_name}'.")
        return
    sql = f"""
    WITH lsn_cte AS (
        SELECT spock.get_lsn_from_commit_ts('{slot_name}', '{sync_timestamp}') AS lsn
    )
    SELECT pg_replication_slot_advance('{slot_name}', lsn) FROM lsn_cte;
    """
    info(f"[STEP] Advancing replication slot '{slot_name}' to commit timestamp {sync_timestamp} on DSN: {dsn}")
    run_psql(dsn, sql)

def enable_sub(dsn: str, sub_name: str, immediate: bool = True):
    sql = f"SELECT spock.sub_enable(subscription_name := '{sub_name}', immediate := {str(immediate).lower()});"
    info(f"[STEP] Enabling subscription '{sub_name}' on DSN: {dsn}")
    run_psql(dsn, sql)

def monitor_replication_lag(dsn: str):
    sql = """
    DO $$
    DECLARE
        lag_n1_n4 interval;
        lag_n2_n4 interval;
        lag_n3_n4 interval;
    BEGIN
        LOOP
            SELECT now() - commit_timestamp INTO lag_n1_n4
            FROM spock.lag_tracker
            WHERE origin_name = 'n1' AND receiver_name = 'n4';

            SELECT now() - commit_timestamp INTO lag_n2_n4
            FROM spock.lag_tracker
            WHERE origin_name = 'n2' AND receiver_name = 'n4';

            SELECT now() - commit_timestamp INTO lag_n3_n4
            FROM spock.lag_tracker
            WHERE origin_name = 'n3' AND receiver_name = 'n4';

            RAISE NOTICE 'n1 → n4 lag: %, n2 → n4 lag: %, n3 → n4 lag: %',
                         COALESCE(lag_n1_n4::text, 'NULL'),
                         COALESCE(lag_n2_n4::text, 'NULL'),
                         COALESCE(lag_n3_n4::text, 'NULL');

            EXIT WHEN lag_n1_n4 IS NOT NULL AND lag_n2_n4 IS NOT NULL AND lag_n3_n4 IS NOT NULL
                      AND extract(epoch FROM lag_n1_n4) < 59
                      AND extract(epoch FROM lag_n2_n4) < 59
                      AND extract(epoch FROM lag_n3_n4) < 59;

            PERFORM pg_sleep(1);
        END LOOP;
    END
    $$;
    """
    info(f"[STEP] Monitoring replication lag on DSN: {dsn}")
    run_psql(dsn, sql)

def add_node(
    src_node_name: str,
    src_dsn: str,
    new_node_name: str,
    new_node_dsn: str,
    new_node_location: str = "NY",
    new_node_country: str = "USA",
    new_node_info: str = "{}"
):
    """
    Adds a new node to the Spock cluster.
    """
    log(f"[STEP 1] Creating new node '{new_node_name}'")
    create_node(new_node_dsn, new_node_name, new_node_location, new_node_country, new_node_info)

    nodes = get_spock_nodes(src_dsn)
    for rec in nodes:
        if rec['node_name'] == src_node_name:
            continue
        sub_name = f"sub_{rec['node_name']}_{new_node_name}"
        create_sub(
            new_node_dsn,
            sub_name,
            rec['dsn'],
            "ARRAY['default', 'default_insert_only', 'ddl_sql']",
            False,
            False,
            "'{}'",
            "0",
            False
        )

    for rec in nodes:
        if rec['node_name'] == src_node_name:
            continue
        dbname = rec['dsn'].split("dbname=")[1].split()[0] if "dbname=" in rec['dsn'] else "pgedge"
        slot_name = f"spk_{dbname}_{rec['node_name']}_sub_{rec['node_name']}_{new_node_name}"[:64]
        create_replication_slot(rec['dsn'], slot_name)

    for rec in nodes:
        if rec['node_name'] != src_node_name:
            sync_lsn = sync_event(rec['dsn'])
            wait_for_sync_event(src_dsn, True, rec['node_name'], sync_lsn, 10000)

    sub_name = f"sub_{src_node_name}_{new_node_name}"
    create_sub(
        new_node_dsn,
        sub_name,
        src_dsn,
        "ARRAY['default', 'default_insert_only', 'ddl_sql']",
        True,
        True,
        "'{}'",
        "0",
        True
    )
    sync_lsn = sync_event(src_dsn)
    wait_for_sync_event(new_node_dsn, True, src_node_name, sync_lsn, 10000)

    for rec in nodes:
        if rec['node_name'] != src_node_name:
            sync_timestamp = get_commit_timestamp(new_node_dsn, src_node_name, rec['node_name'])
            dbname = rec['dsn'].split("dbname=")[1].split()[0] if "dbname=" in rec['dsn'] else "pgedge"
            slot_name = f"spk_{dbname}_{src_node_name}_sub_{rec['node_name']}_{new_node_name}"
            advance_replication_slot(rec['dsn'], slot_name, sync_timestamp)

    for rec in nodes:
        sub_name = f"sub_{new_node_name}_{rec['node_name']}"
        create_sub(
            rec['dsn'],
            sub_name,
            new_node_dsn,
            "ARRAY['default', 'default_insert_only', 'ddl_sql']",
            False,
            False,
            "'{}'",
            "0",
            True
        )

    for rec in nodes:
        if rec['node_name'] == new_node_name:
            continue
        sub_name = f"sub_{rec['node_name']}_{new_node_name}"
        enable_sub(new_node_dsn, sub_name)

    log("[STEP] Node addition complete.")

    
def main():
    parser = argparse.ArgumentParser(
        description="Add a new node to a Spock cluster using psql."
    )
    parser.add_argument("--src-node-name", required=True, help="Source node name")
    parser.add_argument("--src-dsn", required=True, help="Source node DSN")
    parser.add_argument("--new-node-name", required=True, help="New node name")
    parser.add_argument("--new-node-dsn", required=True, help="New node DSN")
    parser.add_argument("--new-node-location", default="NY", help="New node location")
    parser.add_argument("--new-node-country", default="USA", help="New node country")
    parser.add_argument("--new-node-info", default="{}", help="New node info JSON")

    args = parser.parse_args()

    add_node(
        args.src_node_name,
        args.src_dsn,
        args.new_node_name,
        args.new_node_dsn,
        args.new_node_location,
        args.new_node_country,
        args.new_node_info
    )

if __name__ == "__main__":
        main()