#!/usr/bin/env python3
"""
ZODAN - Spock Cluster Management Tool (Python Version)
Version: 1.0.0
100% matches zodan.sql functionality but uses direct psql connections instead of dblink.

This script provides all the same procedures and functionality as zodan.sql:
- add_node: Complete node addition with all 11 phases
- Schema detection and skipping functionality
- All validation, creation, and monitoring procedures
- Error handling and verbose logging

Usage:
    python zodan.py add_node --src-node-name n1 --src-dsn "host=localhost dbname=pgedge port=5431 user=pgedge password=pgedge" --new-node-name n3 --new-node-dsn "host=localhost dbname=pgedge port=5433 user=pgedge password=pgedge" --verbose
"""

import subprocess
import json
import time
import sys
from typing import List, Dict, Any, Optional, Tuple
import argparse
import re

class SpockClusterManager:
    VERSION = "1.0.0"
    REQUIRED_SPOCK_VERSION = "5.0.4"
    
    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self.src_dsn = None
        self.new_node_dsn = None
        
    def log(self, msg: str):
        """Log a message with timestamp"""
        print(f"[LOG] {msg}")
        
    def info(self, msg: str):
        """Log an info message"""
        print(f"[INFO] {msg}")
        
    def notice(self, msg: str):
        """Log a notice message (matches PostgreSQL NOTICE)"""
        print(f"NOTICE: {msg}")
        
    def format_notice(self, status: str, message: str, node: str = None):
        """Format notice message like zodan.sql: OK:/ERROR datetime [node] : message"""
        from datetime import datetime
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        if node:
            formatted_msg = f"{status} {timestamp} [{node}] : {message}"
        else:
            formatted_msg = f"{status} {timestamp} : {message}"
        self.notice(formatted_msg)
        
    def run_psql(self, dsn: str, sql: str, fetch: bool = False, return_single: bool = False) -> Optional[Any]:
        """
        Runs a SQL command using psql and returns results.
        
        Args:
            dsn: Database connection string
            sql: SQL command to execute
            fetch: Whether to return results as list of dicts
            return_single: If fetch=True, return single value instead of list
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
        
        if self.verbose:
            self.info(f"Running SQL on DSN: {dsn}")
            self.info(f"SQL: {sql}")
            
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode != 0:
            self.log(f"SQL failed: {result.stderr.strip()}")
            return None
        
        if fetch:
            lines = [line.strip() for line in result.stdout.strip().split('\n') if line.strip()]
            if not lines:
                return [] if not return_single else None
                
            if return_single:
                return lines[0] if lines else None
                
            # Parse results as list of dicts
            # This is a simplified parser - in practice you'd need to know column names
            return lines
            
        return None

    def get_spock_nodes(self, dsn: str) -> List[Dict[str, Any]]:
        """Retrieve all Spock nodes and their DSNs from a remote cluster"""
        sql = """
        SELECT n.node_id, n.node_name, n.location, n.country, n.info, i.if_dsn
        FROM spock.node n
        JOIN spock.node_interface i ON n.node_id = i.if_nodeid
        ORDER BY n.node_id;
        """
        
        if self.verbose:
            self.info("[STEP] get_spock_nodes: Retrieved nodes from remote DSN: " + dsn)
            self.info("[QUERY] SELECT n.node_id, n.node_name, n.location, n.country, n.info, i.if_dsn FROM spock.node n JOIN spock.node_interface i ON n.node_id = i.if_nodeid")
        
        cmd = [
            "psql",
            dsn,
            "-X",
            "-A",
            "-F", "|",
            "-t",
            "-c",
            sql
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode != 0:
            self.log("[STEP] Failed to fetch nodes.")
            return []
            
        lines = [line.strip() for line in result.stdout.strip().split('\n') if line.strip()]
        columns = ["node_id", "node_name", "location", "country", "info", "dsn"]
        rows = []
        
        for line in lines:
            values = line.split("|")
            if len(values) == len(columns):
                row = dict(zip(columns, values))
                rows.append(row)
                
        if self.verbose:
            self.info(f"Retrieved {len(rows)} nodes from remote cluster")
            
        return rows

    def verify_node_prerequisites(self, src_node_name: str, src_dsn: str, new_node_name: str, new_node_dsn: str):
        """Phase 1: Verify prerequisites (source and new node validation)"""
        self.notice("Phase 1: Validating source and new node prerequisites")
        
        # Check if database specified in new_node_dsn exists on new node
        import re
        db_match = re.search(r'dbname=([^\s]+)', new_node_dsn)
        if db_match:
            new_db_name = db_match.group(1).strip("'\"")
        else:
            new_db_name = 'pgedge'
        
        try:
            self.run_psql(new_node_dsn, "SELECT 1;", fetch=True, return_single=True)
            self.format_notice("OK:", f"Checking database {new_db_name} exists on new node")
        except Exception as e:
            self.format_notice("✗", f"Database {new_db_name} does not exist on new node")
            raise Exception(f"Exiting add_node: Database {new_db_name} does not exist on new node. Please create it first.")
        
        # Check if database has user-created tables
        sql = """
        SELECT count(*) FROM pg_tables 
        WHERE schemaname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'spock') 
        AND schemaname NOT LIKE 'pg_temp_%' 
        AND schemaname NOT LIKE 'pg_toast_temp_%';
        """
        user_table_count = self.run_psql(new_node_dsn, sql, fetch=True, return_single=True)
        
        if user_table_count and int(user_table_count.strip()) > 0:
            self.format_notice("✗", f"Database {new_db_name} has {user_table_count.strip()} user-created tables")
            raise Exception(f"Exiting add_node: Database {new_db_name} on new node has user-created tables. It must be a freshly created database with no user tables (only system and extension tables allowed).")
        else:
            self.format_notice("OK:", f"Checking database {new_db_name} has no user-created tables")
        
        # Check that new node has all users that source node has
        src_users_sql = """
        SELECT rolname FROM pg_roles 
        WHERE rolcanlogin = true 
        AND rolname NOT IN ('postgres', 'rdsadmin', 'rdsrepladmin', 'rds_superuser') 
        ORDER BY rolname;
        """
        
        try:
            src_users_result = self.run_psql(src_dsn, src_users_sql, fetch=True)
            if src_users_result:
                src_users = [line.strip() for line in src_users_result.strip().split('\n') if line.strip()]
                missing_users = []
                
                for user in src_users:
                    # Use proper SQL escaping by replacing single quotes with two single quotes
                    escaped_user = user.replace("'", "''")
                    check_user_sql = f"SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = '{escaped_user}' AND rolcanlogin = true);"
                    user_exists = self.run_psql(new_node_dsn, check_user_sql, fetch=True, return_single=True)
                    
                    if not user_exists or user_exists.strip() != 't':
                        missing_users.append(user)
                
                if missing_users:
                    missing_users_str = ', '.join(missing_users)
                    self.format_notice("✗", f"New node missing users: {missing_users_str}")
                    raise Exception(f"Exiting add_node: New node is missing the following users that exist on source node: {missing_users_str}. Please create these users on the new node before adding it to the cluster.")
                else:
                    self.format_notice("OK:", "Checking new node has all source node users")
        except Exception as e:
            if "missing users" in str(e):
                raise
            else:
                self.format_notice("✗", f"Failed to check user compatibility: {str(e)}")
                raise Exception(f"Exiting add_node: Failed to verify user compatibility between source and new node: {str(e)}")
        
        # Check if new node already exists
        sql = f"SELECT count(*) FROM spock.node WHERE node_name = '{new_node_name}';"
        count = self.run_psql(new_node_dsn, sql, fetch=True, return_single=True)
        
        if count and int(count.strip()) > 0:
            self.format_notice("✗", f"Checking new node \"{new_node_name}\" already exists")
            raise Exception(f"Exiting add_node: New node {new_node_name} already exists")
        else:
            self.format_notice("OK:", f"Checking new node {new_node_name} does not exist")
            
        # Check if new node has subscriptions
        sql = f"""
        SELECT count(*) FROM spock.subscription s 
        JOIN spock.node n ON s.sub_origin = n.node_id 
        WHERE n.node_name = '{new_node_name}';
        """
        count = self.run_psql(new_node_dsn, sql, fetch=True, return_single=True)
        
        if count and int(count.strip()) > 0:
            self.format_notice("✗", f"Checking new node \"{new_node_name}\" has subscriptions")
            raise Exception(f"Exiting add_node: New node {new_node_name} has subscriptions")
        else:
            self.format_notice("OK:", f"Checking new node {new_node_name} has no subscriptions")
            
        # Check if new node has replication sets
        sql = f"""
        SELECT count(*) FROM spock.replication_set rs 
        JOIN spock.node n ON rs.set_nodeid = n.node_id 
        WHERE n.node_name = '{new_node_name}';
        """
        count = self.run_psql(new_node_dsn, sql, fetch=True, return_single=True)
        
        if count and int(count.strip()) > 0:
            self.format_notice("✗", f"Checking new node \"{new_node_name}\" has replication sets")
            raise Exception(f"Exiting add_node: New node {new_node_name} has replication sets")
        else:
            self.format_notice("OK:", f"Checking new node {new_node_name} has no replication sets")

    def create_node(self, node_name: str, dsn: str, location: str = "NY", country: str = "USA", info: str = "{}"):
        """Create a Spock node on a remote cluster"""
        # Check if node already exists
        sql = f"SELECT count(*) FROM spock.node WHERE node_name = '{node_name}';"
        count = self.run_psql(dsn, sql, fetch=True, return_single=True)
        
        if count and int(count.strip()) > 0:
            if self.verbose:
                self.info(f"Node '{node_name}' already exists. Skipping creation.")
            return
            
        sql = f"""
        SELECT spock.node_create(
            node_name := '{node_name}',
            dsn := '{dsn}',
            location := '{location}',
            country := '{country}',
            info := '{info}'::jsonb
        );
        """
        
        if self.verbose:
            self.info(f"[QUERY] SELECT spock.node_create(...)")
            
        # Use run_psql with fetch=True to get the actual result
        result = self.run_psql(dsn, sql, fetch=True, return_single=True)
        if result is None:
            raise Exception(f"Failed to create node '{node_name}' - connection failed")
            
        if self.verbose:
            self.info(f"Node {node_name} created remotely with DSN: {dsn}")

    def create_nodes_only(self, src_node_name: str, src_dsn: str, new_node_name: str, new_node_dsn: str, 
                         new_node_location: str, new_node_country: str, new_node_info: str) -> int:
        """Phase 2: Create nodes only"""
        self.notice("Phase 2: Creating nodes")
        
        # Check if source node exists on remote cluster
        sql = f"SELECT count(*) FROM spock.node WHERE node_name = '{src_node_name}';"
        count = self.run_psql(src_dsn, sql, fetch=True, return_single=True)
        
        if count and int(count.strip()) > 0:
            self.notice("    OK: Creating source node " + src_node_name + "...")
        else:
            # Create source node
            self.create_node(src_node_name, src_dsn)
            self.notice("    OK: Creating source node " + src_node_name + "...")
            
        # Create new node
        self.create_node(new_node_name, new_node_dsn, new_node_location, new_node_country, new_node_info)
        self.notice("    OK: Creating new node " + new_node_name + "...")
        
        return 2  # Return initial node count

    def detect_existing_schemas(self, node_dsn: str) -> str:
        """Detect existing schemas on a node (excluding system schemas)"""
        sql = """
        SELECT string_agg(schema_name, ',') as schemas
        FROM information_schema.schemata
        WHERE schema_name NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'spock', 'public')
        AND schema_name NOT LIKE 'pg_temp_%'
        AND schema_name NOT LIKE 'pg_toast_temp_%';
        """
        
        if self.verbose:
            self.info("[QUERY] Detecting existing schemas on new node: " + sql)
            
        result = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        
        if result and result.strip():
            if self.verbose:
                self.info(f"[INFO] Found existing schemas to skip: {result}")
            # Convert comma-separated list to PostgreSQL array format
            schemas = result.split(',')
            array_str = "ARRAY['" + "','".join(schemas) + "']::text[]"
            return array_str
        else:
            if self.verbose:
                self.info("[INFO] No existing user schemas found on new node")
            return "ARRAY[]::text[]"

    def create_sub(self, node_dsn: str, subscription_name: str, provider_dsn: str, 
                   replication_sets: str, synchronize_structure: bool, synchronize_data: bool,
                   forward_origins: str, apply_delay: str, enabled: bool, 
                   force_text_transfer: bool = False, skip_schema: str = None):
        """Create a Spock subscription on a remote node"""
        
        # Check if subscription already exists
        sql = f"SELECT count(*) FROM spock.subscription WHERE sub_name = '{subscription_name}';"
        count = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        
        if count and int(count.strip()) > 0:
            if self.verbose:
                self.info(f"Subscription '{subscription_name}' already exists. Skipping creation.")
            return
        
        # Auto-detect existing schemas when synchronize_structure is true
        skip_schema_list = "ARRAY[]::text[]"
        
        if synchronize_structure and skip_schema is None:
            try:
                skip_schema_list = self.detect_existing_schemas(node_dsn)
            except Exception as e:
                if self.verbose:
                    self.info(f"[WARNING] Failed to detect existing schemas: {e}")
                skip_schema_list = "ARRAY[]::text[]"
        elif skip_schema:
            skip_schema_list = skip_schema
            
        sql = f"""
        SELECT spock.sub_create(
            subscription_name := '{subscription_name}',
            provider_dsn := '{provider_dsn}',
            replication_sets := {replication_sets},
            synchronize_structure := {str(synchronize_structure).lower()},
            synchronize_data := {str(synchronize_data).lower()},
            forward_origins := {forward_origins},
            apply_delay := '{apply_delay}',
            enabled := {str(enabled).lower()},
            force_text_transfer := {str(force_text_transfer).lower()},
            skip_schema := {skip_schema_list}
        );
        """
        
        if self.verbose:
            self.info(f"[QUERY] SQL: {sql}")
            
        # Use run_psql with fetch=True to get the actual result
        result = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        if result is None:
            raise Exception(f"Subscription '{subscription_name}' creation failed on remote node!")
            
        if self.verbose:
            self.info(f"Subscription {subscription_name} created remotely")

    def create_replication_slot(self, node_dsn: str, slot_name: str, plugin: str = "spock_output"):
        """Create a logical replication slot on a remote node"""
        # Check if slot already exists
        sql = f"SELECT count(*) FROM pg_replication_slots WHERE slot_name = '{slot_name}';"
        count = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        
        if count and int(count.strip()) > 0:
            if self.verbose:
                self.info(f"Replication slot '{slot_name}' already exists. Skipping creation.")
            return
            
        sql = f"SELECT slot_name, lsn FROM pg_create_logical_replication_slot('{slot_name}', '{plugin}');"
        
        if self.verbose:
            self.info(f"[QUERY] {sql}")
            
        result = self.run_psql(node_dsn, sql)
        if result is None:
            if self.verbose:
                self.info(f"Replication slot '{slot_name}' may already exist or creation failed.")
        else:
            if self.verbose:
                self.info(f"Created replication slot '{slot_name}' with plugin '{plugin}' on remote node.")

    def create_disable_subscriptions_and_slots(self, src_node_name: str, src_dsn: str,
                                             new_node_name: str, new_node_dsn: str):
        """Phase 3: Create disabled subscriptions and slots with sync events"""
        self.notice("Phase 3: Creating disabled subscriptions and slots")

        # Get all nodes from source cluster
        nodes = self.get_spock_nodes(src_dsn)

        # Store sync LSNs for later use when enabling subscriptions
        self.sync_lsns = {}

        for rec in nodes:
            if rec['node_name'] == src_node_name:
                continue

            # Create replication slot
            dbname = "pgedge"  # Default database name
            if "dbname=" in rec['dsn']:
                dbname = rec['dsn'].split("dbname=")[1].split()[0]

            slot_name = f"spk_{dbname}_{rec['node_name']}_sub_{rec['node_name']}_{new_node_name}"
            if len(slot_name) > 64:
                slot_name = slot_name[:64]

            self.create_replication_slot(rec['dsn'], slot_name)
            self.notice(f"    OK: Creating replication slot {slot_name} on node {rec['node_name']}")

            # Trigger sync event on origin node and store LSN for later use
            sync_lsn = self.sync_event(rec['dsn'])
            self.sync_lsns[rec['node_name']] = sync_lsn
            self.notice(f"    OK: Triggering sync event on node {rec['node_name']} (LSN: {sync_lsn})")

            # Create disabled subscription
            sub_name = f"sub_{rec['node_name']}_{new_node_name}"
            self.create_sub(
                new_node_dsn, sub_name, rec['dsn'],
                "ARRAY['default', 'default_insert_only', 'ddl_sql']",
                False, False, "ARRAY[]::text[]", "00:00:00", False
            )
            self.notice(f"    OK: Creating initial subscription {sub_name} on node {rec['node_name']}")

    def create_source_to_new_subscription(self, src_node_name: str, src_dsn: str, 
                                        new_node_name: str, new_node_dsn: str):
        """Phase 4: Create source to new node subscription"""
        self.notice("Phase 4: Creating source to new node subscription")
        
        sub_name = f"sub_{src_node_name}_{new_node_name}"
        self.create_sub(
            new_node_dsn, sub_name, src_dsn,
            "ARRAY['default', 'default_insert_only', 'ddl_sql']",
            True, True, "ARRAY[]::text[]", "00:00:00", True
        )
        self.notice(f"    OK: Creating subscription {sub_name} on node {new_node_name}...")

    def sync_event(self, node_dsn: str) -> str:
        """Trigger a sync event on a remote node and return the LSN"""
        sql = "SELECT spock.sync_event();"
        
        if self.verbose:
            self.info(f"[QUERY] {sql}")
            
        result = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        
        if self.verbose:
            self.info(f"[STEP] Sync event triggered on remote node: {node_dsn} with LSN {result}")
            
        return result

    def wait_for_sync_event(self, node_dsn: str, wait_for_all: bool, provider_node: str, 
                           sync_lsn: str, timeout_ms: int):
        """Wait for a sync event from a provider node"""
        sql = f"CALL spock.wait_for_sync_event({str(wait_for_all).lower()}, '{provider_node}', '{sync_lsn}', {timeout_ms});"
        
        if self.verbose:
            self.info(f"[QUERY] {sql}")
            
        # Use run_psql with fetch=True to get the actual result
        result = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        if result is None:
            raise Exception(f"Failed to wait for sync event from {provider_node}")
            
        if self.verbose:
            self.info(f"Sync event completed successfully: {result}")

    def trigger_sync_on_other_nodes_and_wait_on_source(self, src_node_name: str, src_dsn: str, 
                                                      new_node_name: str, new_node_dsn: str):
        """Phase 5: Trigger sync events on other nodes and wait on source"""
        self.notice("Phase 5: Triggering sync events on other nodes and waiting on source")
        
        # Get all nodes from source cluster
        nodes = self.get_spock_nodes(src_dsn)
        
        for rec in nodes:
            if rec['node_name'] == src_node_name:
                continue
                
            # Trigger sync event on other node
            sync_lsn = self.sync_event(rec['dsn'])
            self.notice(f"    OK: Triggering sync event on node {rec['node_name']} (LSN: {sync_lsn})...")
            
            # Wait for sync event on source
            self.wait_for_sync_event(src_dsn, True, rec['node_name'], sync_lsn, 1200)
            self.notice(f"    OK: Waiting for sync event from {rec['node_name']} on source node {src_node_name}...")

    def wait_for_source_node_sync(self, src_node_name: str, src_dsn: str,
                                 new_node_name: str, new_node_dsn: str, wait_for_all: bool):
        """Phase 6: Wait for sync on source and new node using sync_event and wait_for_sync_event"""
        self.notice("Phase 6: Waiting for sync on source and new node")

        # Trigger sync event on new node and wait for it on source node
        sync_lsn = None
        timeout_ms = 1200  # 20 minutes timeout

        try:
            # Trigger sync event on new node
            sql = "SELECT spock.sync_event();"
            if self.verbose:
                self.info(f"    Remote SQL for sync_event on new node {new_node_name}: {sql}")

            sync_lsn = self.run_psql(new_node_dsn, sql, fetch=True, return_single=True)
            if sync_lsn:
                self.format_notice("✓", f"Triggered sync_event on new node {new_node_name} (LSN: {sync_lsn})")
            else:
                raise Exception("Failed to get sync LSN from new node")

        except Exception as e:
            self.format_notice("✗", f"Triggering sync_event on new node {new_node_name} (error: {str(e)})")
            raise

        try:
            # Wait for sync event on source node
            sql = f"CALL spock.wait_for_sync_event(true, '{new_node_name}', '{sync_lsn}'::pg_lsn, {timeout_ms});"
            if self.verbose:
                self.info(f"    Remote SQL for wait_for_sync_event on source node {src_node_name}: {sql}")

            self.run_psql(src_dsn, sql)
            self.format_notice("✓", f"Waiting for sync event from {new_node_name} on source node {src_node_name}")

        except Exception as e:
            self.format_notice("✗", f"Unable to wait for sync event from {new_node_name} on source node {src_node_name} (error: {str(e)})")
            raise

    def get_commit_timestamp(self, node_dsn: str, origin: str, receiver: str) -> str:
        """Get commit timestamp for lag tracking"""
        sql = f"SELECT commit_timestamp FROM spock.lag_tracker WHERE origin_name = '{origin}' AND receiver_name = '{receiver}';"
        
        if self.verbose:
            self.info(f"[QUERY] {sql}")
            
        result = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        return result

    def advance_replication_slot(self, node_dsn: str, slot_name: str, sync_timestamp: str):
        """Advance a replication slot to a specific timestamp"""
        if not sync_timestamp:
            if self.verbose:
                self.info(f"Commit timestamp is NULL, skipping slot advance for slot '{slot_name}'.")
            return
            
        sql = f"""
        WITH lsn_cte AS (
            SELECT spock.get_lsn_from_commit_ts('{slot_name}', '{sync_timestamp}') AS lsn
        )
        SELECT pg_replication_slot_advance('{slot_name}', lsn) FROM lsn_cte;
        """
        
        if self.verbose:
            self.info(f"[QUERY] {sql}")
            
        self.run_psql(node_dsn, sql)

    def check_commit_timestamp_and_advance_slot(self, src_node_name: str, src_dsn: str, 
                                               new_node_name: str, new_node_dsn: str):
        """Phase 7: Check commit timestamp and advance replication slot"""
        self.notice("Phase 7: Checking commit timestamp and advancing replication slot")
        
        # Get all nodes from source cluster
        nodes = self.get_spock_nodes(src_dsn)
        
        for rec in nodes:
            if rec['node_name'] == src_node_name:
                continue
                
            # Get commit timestamp
            sync_timestamp = self.get_commit_timestamp(new_node_dsn, src_node_name, rec['node_name'])
            if sync_timestamp:
                self.notice(f"    OK: Found commit timestamp for {src_node_name}->{rec['node_name']}: {sync_timestamp}")
                
                # Advance replication slot
                dbname = "pgedge"
                if "dbname=" in rec['dsn']:
                    dbname = rec['dsn'].split("dbname=")[1].split()[0]
                    
                slot_name = f"spk_{dbname}_{src_node_name}_sub_{rec['node_name']}_{new_node_name}"
                
                # Check current slot position
                sql = f"SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = '{slot_name}'"
                if self.verbose:
                    self.info(f"[QUERY] {sql}")
                    
                current_lsn = self.run_psql(rec['dsn'], sql, fetch=True, return_single=True)
                
                # Get target LSN
                sql = f"SELECT spock.get_lsn_from_commit_ts('{slot_name}', '{sync_timestamp}')"
                if self.verbose:
                    self.info(f"[QUERY] {sql}")
                    
                target_lsn = self.run_psql(rec['dsn'], sql, fetch=True, return_single=True)
                
                if current_lsn and target_lsn and current_lsn >= target_lsn:
                    self.notice(f"    - Slot {slot_name} already at or beyond target LSN (current: {current_lsn}, target: {target_lsn})")
                else:
                    self.advance_replication_slot(rec['dsn'], slot_name, sync_timestamp)

    def enable_sub(self, node_dsn: str, sub_name: str, immediate: bool = True):
        """Enable a subscription on a remote node"""
        # Check if subscription is already enabled
        sql = f"SELECT sub_enabled FROM spock.subscription WHERE sub_name = '{sub_name}';"
        
        if self.verbose:
            self.info(f"[QUERY] Checking subscription status: {sql}")
            
        is_enabled = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        
        if is_enabled and is_enabled.lower() == 't':
            if self.verbose:
                self.info(f"Subscription '{sub_name}' is already enabled. Skipping.")
            return
            
        # Enable subscription
        sql = f"SELECT spock.sub_enable(subscription_name := '{sub_name}', immediate := {str(immediate).lower()});"
        
        if self.verbose:
            self.info(f"[QUERY] {sql}")
            
        # Use run_psql with fetch=True to get the actual result
        result = self.run_psql(node_dsn, sql, fetch=True, return_single=True)
        if result is None:
            if self.verbose:
                self.info(f"[ERROR] Failed to enable subscription '{sub_name}'")
            raise Exception(f"Failed to enable subscription '{sub_name}'")
            
        if self.verbose:
            self.info(f"Subscription {sub_name} enabled successfully")

    def enable_disabled_subscriptions(self, src_node_name: str, src_dsn: str,
                                    new_node_name: str, new_node_dsn: str):
        """Phase 8: Enable disabled subscriptions and wait for stored sync events"""
        self.notice("Phase 8: Enabling disabled subscriptions")

        # Get all nodes from source cluster
        nodes = self.get_spock_nodes(src_dsn)

        for rec in nodes:
            if rec['node_name'] == src_node_name:
                continue

            sub_name = f"sub_{rec['node_name']}_{new_node_name}"
            try:
                self.enable_sub(new_node_dsn, sub_name, True)
                self.notice(f"    OK: Enabling subscription {sub_name}...")

                # Wait for the sync event that was captured when subscription was created
                # This ensures the subscription starts replicating from the correct sync point
                timeout_ms = 1200  # 20 minutes
                sync_lsn = self.sync_lsns.get(rec['node_name'])  # Use stored sync LSN from Phase 3
                if sync_lsn:
                    self.notice(f"    OK: Using stored sync event from origin node {rec['node_name']} (LSN: {sync_lsn})...")

                    # Wait for this sync event on the new node where the subscription exists
                    sql = f"CALL spock.wait_for_sync_event(true, '{rec['node_name']}', '{sync_lsn}'::pg_lsn, {timeout_ms});"
                    if self.verbose:
                        self.info(f"    Remote SQL for wait_for_sync_event on new node {new_node_name}: {sql}")

                    self.run_psql(new_node_dsn, sql)
                    self.notice(f"    OK: Waiting for sync event from {rec['node_name']} on new node {new_node_name}...")
                else:
                    self.notice(f"    ⚠ No stored sync LSN found for {rec['node_name']}, skipping sync wait")

            except Exception as e:
                self.notice(f"    ✗ Enabling subscription {sub_name}... (error: {e})")
                raise

    def create_sub_on_new_node_to_src_node(self, src_node_name: str, src_dsn: str, 
                                          new_node_name: str, new_node_dsn: str):
        """Phase 9: Create subscription from new node to source node"""
        self.notice("Phase 9: Creating subscriptions from all other nodes to new node")
        
        # Get all nodes from source cluster
        nodes = self.get_spock_nodes(src_dsn)
        
        for rec in nodes:
            sub_name = f"sub_{new_node_name}_{rec['node_name']}"
            self.create_sub(
                rec['dsn'], sub_name, new_node_dsn,
                "ARRAY['default', 'default_insert_only', 'ddl_sql']",
                False, False, "ARRAY[]::text[]", "00:00:00", True
            )
            self.notice(f"    OK: Creating subscription {sub_name} on node {rec['node_name']}...")
            
        self.notice(f"    OK: Created {len(nodes)} subscriptions from other nodes to new node")

    def present_final_cluster_state(self, initial_node_count: int):
        """Phase 10: Present final cluster state"""
        self.notice("Phase 10: Presenting final cluster state")
        self.notice("    Waiting for replication to be active...")
        
        # Check replication status
        sql = "SELECT status FROM spock.sub_show_status() LIMIT 1"
        status = self.run_psql(self.src_dsn, sql, fetch=True, return_single=True)
        
        if status and "replicating" in status.lower():
            self.notice("    OK: Replication is active (status: replicating)")
        else:
            self.notice("    ⚠ Replication status: " + (status or "unknown"))
            
        # Show current nodes
        self.notice("")
        self.notice("Current Spock Nodes:")
        self.notice(" node_id | node_name | location | country | info")
        self.notice("---------+-----------+----------+---------+------")
        
        sql = "SELECT node_id, node_name, location, country, info FROM spock.node ORDER BY node_id"
        nodes = self.run_psql(self.src_dsn, sql, fetch=True)
        
        for node in nodes:
            parts = node.split("|")
            if len(parts) >= 5:
                self.notice(f" {parts[0]:<7} | {parts[1]:<9} | {parts[2]:<8} | {parts[3]:<7} | {parts[4]}")
                
        # Show subscription status
        self.notice("")
        self.notice("Subscription Status:")
        sql = "SELECT * FROM spock.sub_show_status()"
        subs = self.run_psql(self.src_dsn, sql, fetch=True)
        
        for sub in subs:
            self.notice(f" {sub}")

    def monitor_replication_lag(self, src_node_name: str, new_node_name: str, new_node_dsn: str):
        """Phase 11: Monitor replication lag"""
        self.notice("Phase 11: Monitoring replication lag")
        
        # Simple lag monitoring - check lag from source to new node
        sql = f"""
        SELECT 
            now() - commit_timestamp as lag_interval
        FROM spock.lag_tracker 
        WHERE origin_name = '{src_node_name}' AND receiver_name = '{new_node_name}'
        LIMIT 1;
        """
        
        result = self.run_psql(new_node_dsn, sql, fetch=True, return_single=True)
        
        if result:
            self.notice(f"    {src_node_name} → {new_node_name} lag: {result}")
        else:
            self.notice(f"    {src_node_name} → {new_node_name} lag: No data available")
            
        self.notice("    OK: Replication lag monitoring completed")

    def show_all_subscription_status(self, cluster_dsn: str):
        """Phase 12: Show comprehensive subscription status across all nodes in the cluster"""
        self.notice("")
        self.notice("COMPREHENSIVE SUBSCRIPTION STATUS REPORT")
        self.notice("=========================================")

        # Get all nodes from the cluster
        nodes = self.get_spock_nodes(cluster_dsn)

        total_subscriptions = 0
        replicating_count = 0
        error_count = 0

        for node in nodes:
            self.notice("")
            self.notice(f"Node: {node['node_name']} (DSN: {node['dsn']})")
            self.notice("Subscriptions:")

            # Get all subscriptions from this node
            sql = "SELECT * FROM spock.sub_show_status() ORDER BY subscription_name"
            result = self.run_psql(node['dsn'], sql, fetch=True)

            if result:
                for sub in result:
                    # Parse the result (assuming it's a string that needs parsing)
                    # This is a simplified version - you might need to adjust based on actual output format
                    total_subscriptions += 1

                    # Extract status from the result (this will depend on the actual format)
                    # For now, we'll use a placeholder approach
                    if 'replicating' in str(sub).lower():
                        replicating_count += 1
                        self.notice(f"  [OK] Subscription is replicating")
                    elif 'disabled' in str(sub).lower():
                        self.notice(f"  [DISABLED] Subscription is disabled")
                    elif 'down' in str(sub).lower():
                        error_count += 1
                        self.notice(f"  [ERROR] Subscription is down")
                    else:
                        self.notice(f"  [UNKNOWN] Subscription status: {sub}")
            else:
                self.notice("  (no subscriptions found)")

        # Summary
        self.notice("")
        self.notice("SUBSCRIPTION STATUS SUMMARY")
        self.notice("=========================================")
        self.notice(f"Total subscriptions: {total_subscriptions}")
        self.notice(f"Replicating: {replicating_count}")
        self.notice(f"With errors/issues: {error_count}")

        if total_subscriptions > 0:
            success_rate = (replicating_count / total_subscriptions) * 100
            self.notice(f"Success rate: {success_rate:.1f}%")

        if replicating_count == total_subscriptions and total_subscriptions > 0:
            self.notice("All subscriptions are replicating successfully!")
        elif error_count > 0:
            self.notice("Some subscriptions have issues - check details above")
        else:
            self.notice("Subscriptions are in various states - check details above")

        self.notice("=========================================")

    def check_spock_version_compatibility(self, src_dsn: str, new_node_dsn: str):
        """Check that all nodes have the required Spock version"""
        self.info("Checking Spock version compatibility across all nodes")
        required_version = self.REQUIRED_SPOCK_VERSION
        
        # Get source node version
        src_version = self.run_psql(src_dsn, 
            "SELECT extversion FROM pg_extension WHERE extname = 'spock';",
            fetch=True, return_single=True)
        if not src_version:
            raise Exception("Spock extension not found on source node")
        src_version = src_version.strip()
        
        # Check source node has required version
        if src_version != required_version:
            raise Exception(f"Spock version mismatch: source node has version {src_version}, "
                          f"but required version is {required_version}. Please upgrade all nodes to {required_version}.")
        
        # Get new node version
        new_version = self.run_psql(new_node_dsn,
            "SELECT extversion FROM pg_extension WHERE extname = 'spock';",
            fetch=True, return_single=True)
        if not new_version:
            raise Exception("Spock extension not found on new node")
        new_version = new_version.strip()
        
        # Check new node has required version
        if new_version != required_version:
            raise Exception(f"Spock version mismatch: new node has version {new_version}, "
                          f"but required version is {required_version}. Please upgrade all nodes to {required_version}.")
        
        # Check all existing nodes in cluster
        nodes = self.get_spock_nodes(src_dsn)
        
        for node in nodes:
            node_version = self.run_psql(node['dsn'],
                "SELECT extversion FROM pg_extension WHERE extname = 'spock';",
                fetch=True, return_single=True)
            if not node_version:
                raise Exception(f"Spock extension not found on node {node['node_name']}")
            node_version = node_version.strip()
            
            if node_version != required_version:
                raise Exception(f"Spock version mismatch: node {node['node_name']} has version {node_version}, "
                              f"but required version is {required_version}. "
                              f"All nodes must have version {required_version}.")
        
        self.notice(f"Version check passed: All nodes running Spock version {required_version}")

    def add_node(self, src_node_name: str, src_dsn: str, new_node_name: str, new_node_dsn: str,
                 new_node_location: str = "NY", new_node_country: str = "USA",
                 new_node_info: str = "{}"):
        """Main add_node procedure - matches zodan.sql exactly"""

        # Store DSN values as instance attributes to avoid hard-coding
        self.src_dsn = src_dsn
        self.new_node_dsn = new_node_dsn

        # Phase 0: Check Spock version compatibility across all nodes
        # Example: Ensure all nodes are running the same Spock version before proceeding
        self.check_spock_version_compatibility(src_dsn, new_node_dsn)

        # Phase 1: Verify prerequisites for source and new node.
        # Example: Ensure n1 (source) and n4 (new) are ready before adding n4 to cluster n1,n2,n3.
        self.verify_node_prerequisites(src_node_name, src_dsn, new_node_name, new_node_dsn)

        # Phase 2: Create node objects in the cluster.
        # Example: Register n4 as a new node alongside n1, n2, n3.
        initial_node_count = self.create_nodes_only(src_node_name, src_dsn, new_node_name, new_node_dsn,
                                                   new_node_location, new_node_country, new_node_info)

        # Phase 3: Create disabled subscriptions and replication slots.
        # Example: Prepare n4 for replication but keep subscriptions disabled initially.
        self.create_disable_subscriptions_and_slots(src_node_name, src_dsn, new_node_name, new_node_dsn)

        # Phase 4: Trigger sync events on other nodes and wait on source.
        # Example: Sync n2 and n3, then wait for n1 to acknowledge before proceeding with n4.
        self.trigger_sync_on_other_nodes_and_wait_on_source(src_node_name, src_dsn, new_node_name, new_node_dsn)

        # Phase 5: Create subscription from source to new node.
        # Example: Set up n1 to replicate to n4.
        self.create_source_to_new_subscription(src_node_name, src_dsn, new_node_name, new_node_dsn)

        # Phase 6: Wait for sync on source and new node.
        # Example: Ensure n1 and n4 are fully synchronized before continuing.
        self.wait_for_source_node_sync(src_node_name, src_dsn, new_node_name, new_node_dsn, True)

        # Phase 7: Check commit timestamp and advance replication slot.
        # Example: Confirm n4 is caught up to n1's latest changes.
        self.check_commit_timestamp_and_advance_slot(src_node_name, src_dsn, new_node_name, new_node_dsn)

        # Phase 8: Enable previously disabled subscriptions.
        # Example: Activate replication paths for n4.
        self.enable_disabled_subscriptions(src_node_name, src_dsn, new_node_name, new_node_dsn)

        # Phase 9: Create subscription from new node to source node.
        # Example: Set up n4 to replicate back to n1 for bidirectional sync.
        self.create_sub_on_new_node_to_src_node(src_node_name, src_dsn, new_node_name, new_node_dsn)

        # Phase 10: Present final cluster state.
        # Example: Show n1, n2, n3, n4 as fully connected and synchronized.
        self.present_final_cluster_state(initial_node_count)

        # Phase 11: Monitor replication lag.
        # Example: Check that n4 is keeping up with n1, n2, n3 after joining.
        self.monitor_replication_lag(src_node_name, new_node_name, new_node_dsn)

        # Phase 12: Show comprehensive node status across all nodes.
        # Example: Display all nodes in n1, n2, n3, n4, n5 cluster.
        self.show_all_nodes(src_dsn)

        # Phase 13: Show comprehensive subscription status across all nodes.
        # Example: Display status of all subscriptions in n1, n2, n3, n4, n5 cluster.
        self.show_all_subscription_status(src_dsn)

        self.notice("")
        self.notice("Node addition completed successfully!")

    def health_check(self, src_node_name: str, src_dsn: str, new_node_name: str = None, new_node_dsn: str = None, check_type: str = "pre"):
        """
        Validate cluster health before or after Z0DAN node addition
        Similar to pg_upgrade -c (check) option
        
        check_type: 'pre' (before add_node) or 'post' (after add_node)
        """
        self.notice("")
        self.notice("=" * 80)
        self.notice(f"ZODAN CLUSTER HEALTH CHECK ({check_type.upper()}-CHECK)")
        self.notice("=" * 80)
        
        checks_passed = 0
        checks_failed = 0
        
        # Check 1: Spock version compatibility
        if new_node_dsn:
            try:
                self.check_spock_version_compatibility(src_dsn, new_node_dsn)
                self.format_notice("PASS:", "Spock version compatibility check")
                checks_passed += 1
            except Exception as e:
                self.format_notice("FAIL:", f"Spock version compatibility - {str(e)}")
                checks_failed += 1
        
        # Check 2: Node connectivity
        try:
            self.run_psql(src_dsn, "SELECT 1;", fetch=True, return_single=True)
            self.format_notice("PASS:", f"Source node {src_node_name} connectivity")
            checks_passed += 1
        except Exception as e:
            self.format_notice("FAIL:", f"Source node {src_node_name} connectivity - {str(e)}")
            checks_failed += 1
        
        if new_node_dsn:
            try:
                self.run_psql(new_node_dsn, "SELECT 1;", fetch=True, return_single=True)
                self.format_notice("PASS:", f"New node {new_node_name} connectivity")
                checks_passed += 1
            except Exception as e:
                self.format_notice("FAIL:", f"New node {new_node_name} connectivity - {str(e)}")
                checks_failed += 1
        
        # Check 3: Spock extension installation
        try:
            result = self.run_psql(src_dsn, "SELECT extversion FROM pg_extension WHERE extname = 'spock';", fetch=True, return_single=True)
            if result:
                self.format_notice("PASS:", f"Spock extension on source node (version {result.strip()})")
                checks_passed += 1
            else:
                self.format_notice("FAIL:", "Spock extension not installed on source node")
                checks_failed += 1
        except Exception as e:
            self.format_notice("FAIL:", f"Spock extension check on source - {str(e)}")
            checks_failed += 1
        
        if new_node_dsn:
            try:
                result = self.run_psql(new_node_dsn, "SELECT extversion FROM pg_extension WHERE extname = 'spock';", fetch=True, return_single=True)
                if result:
                    self.format_notice("PASS:", f"Spock extension on new node (version {result.strip()})")
                    checks_passed += 1
                else:
                    self.format_notice("FAIL:", "Spock extension not installed on new node")
                    checks_failed += 1
            except Exception as e:
                self.format_notice("FAIL:", f"Spock extension check on new node - {str(e)}")
                checks_failed += 1
        
        # Check 4: Replication status (for existing cluster nodes)
        try:
            nodes = self.get_spock_nodes(src_dsn)
            self.format_notice("PASS:", f"Cluster has {len(nodes)} nodes")
            checks_passed += 1
            
            # Check subscriptions are healthy
            for node in nodes:
                try:
                    sub_count = self.run_psql(node['dsn'], 
                        "SELECT count(*) FROM spock.subscription WHERE sub_enabled = true;", 
                        fetch=True, return_single=True)
                    self.format_notice("PASS:", f"Node {node['node_name']} has {sub_count.strip() if sub_count else '0'} active subscriptions")
                    checks_passed += 1
                except Exception as e:
                    self.format_notice("FAIL:", f"Node {node['node_name']} subscription check - {str(e)}")
                    checks_failed += 1
        except Exception as e:
            self.format_notice("FAIL:", f"Cluster node enumeration - {str(e)}")
            checks_failed += 1
        
        # Check 5: Database prerequisites (for pre-check only)
        if check_type == "pre" and new_node_dsn:
            # Check database is empty
            try:
                sql = """
                SELECT count(*) FROM pg_tables 
                WHERE schemaname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'spock') 
                AND schemaname NOT LIKE 'pg_temp_%' 
                AND schemaname NOT LIKE 'pg_toast_temp_%';
                """
                user_table_count = self.run_psql(new_node_dsn, sql, fetch=True, return_single=True)
                
                if user_table_count and int(user_table_count.strip()) == 0:
                    self.format_notice("PASS:", f"New node database is empty (fresh database)")
                    checks_passed += 1
                else:
                    self.format_notice("FAIL:", f"New node database has {user_table_count.strip()} user-created tables")
                    checks_failed += 1
            except Exception as e:
                self.format_notice("FAIL:", f"Database emptiness check - {str(e)}")
                checks_failed += 1
        
        # Check 6: Replication lag (for post-check only)
        if check_type == "post" and new_node_name:
            try:
                # Check if new node is replicating
                sql = f"SELECT count(*) FROM spock.subscription WHERE sub_enabled = true;"
                sub_count = self.run_psql(new_node_dsn, sql, fetch=True, return_single=True)
                
                if sub_count and int(sub_count.strip()) > 0:
                    self.format_notice("PASS:", f"New node {new_node_name} has active subscriptions")
                    checks_passed += 1
                else:
                    self.format_notice("FAIL:", f"New node {new_node_name} has no active subscriptions")
                    checks_failed += 1
            except Exception as e:
                self.format_notice("FAIL:", f"Post-addition replication check - {str(e)}")
                checks_failed += 1
        
        # Summary
        self.notice("")
        self.notice("=" * 80)
        self.notice(f"HEALTH CHECK SUMMARY")
        self.notice("=" * 80)
        self.notice(f"Checks Passed: {checks_passed}")
        self.notice(f"Checks Failed: {checks_failed}")
        self.notice(f"Total Checks:  {checks_passed + checks_failed}")
        self.notice("")
        
        if checks_failed > 0:
            self.notice("RESULT: FAILED - Please resolve issues before proceeding")
            return False
        else:
            self.notice("RESULT: PASSED - Cluster is ready for Z0DAN node addition")
            return True

    def show_all_nodes(self, cluster_dsn: str):
        """Phase 12: Show comprehensive node status across all nodes in the cluster"""
        self.notice("")
        self.notice("COMPREHENSIVE NODE STATUS REPORT")
        self.notice("====================================")

        # Get all nodes from the cluster
        nodes = self.get_spock_nodes(cluster_dsn)
        total_nodes = len(nodes)

        for node in nodes:
            # Mask password in DSN for security
            dsn_masked = node['dsn'].replace(' password=pgedge', ' password=***')
            self.notice(f"    [NODE] {node['node_name']}: {node['node_id']} ({node['location']}, {node['country']}) - {dsn_masked}")

        self.notice("")
        self.notice("NODE STATUS SUMMARY")
        self.notice("===================")
        self.notice(f"Total nodes: {total_nodes}")

    def show_all_subscription_status(self, cluster_dsn: str):
        """Phase 13: Show comprehensive subscription status across all nodes in the cluster"""
        self.notice("")
        self.notice("COMPREHENSIVE SUBSCRIPTION STATUS REPORT")
        self.notice("==========================================")

        # Get all nodes from the cluster
        nodes = self.get_spock_nodes(cluster_dsn)
        total_subscriptions = 0
        replicating_count = 0
        error_count = 0

        for node in nodes:
            self.notice("")
            self.notice(f"Node: {node['node_name']} (DSN: {node['dsn']})")
            self.notice("Subscriptions:")

            # Get subscriptions for this node
            sql = "SELECT * FROM spock.sub_show_status() ORDER BY subscription_name"
            subscriptions = self.run_psql(node['dsn'], sql, fetch=True)

            if subscriptions:
                for sub in subscriptions:
                    total_subscriptions += 1
                    status = sub.split('|')[1].strip() if len(sub.split('|')) > 1 else 'unknown'

                    if status == 'replicating':
                        replicating_count += 1
                        self.notice(f"  [OK] {sub}")
                    elif status in ['disabled', 'initializing', 'syncing']:
                        if status == 'disabled':
                            self.notice(f"  [DISABLED] {sub}")
                        elif status in ['initializing', 'syncing']:
                            self.notice(f"  [INITIALIZING] {sub}")
                        else:
                            self.notice(f"  [UNKNOWN] {sub}")
                    elif status == 'down':
                        error_count += 1
                        self.notice(f"  [ERROR] {sub}")
                    else:
                        self.notice(f"  [UNKNOWN] {sub}")
            else:
                self.notice("  (no subscriptions found)")

        # Summary
        self.notice("")
        self.notice("SUBSCRIPTION STATUS SUMMARY")
        self.notice("===========================")
        self.notice(f"Total subscriptions: {total_subscriptions}")
        self.notice(f"Replicating: {replicating_count}")
        self.notice(f"With errors/issues: {error_count}")

        if total_subscriptions > 0:
            success_rate = round((replicating_count / total_subscriptions) * 100, 1)
            self.notice(f"Success rate: {success_rate}%")

        if replicating_count == total_subscriptions and total_subscriptions > 0:
            self.notice("SUCCESS: All subscriptions are replicating successfully!")
        elif error_count > 0:
            self.notice("WARNING: Some subscriptions have issues - check details above")
        else:
            self.notice("INFO: Subscriptions are in various states - check details above")


def main():
    parser = argparse.ArgumentParser(
        description="ZODAN - Spock Cluster Management Tool (Python Version)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Pre-check cluster health before adding a node
  python zodan.py health-check --src-node-name n1 --src-dsn "host=localhost dbname=pgedge port=5431 user=pgedge password=pgedge" --new-node-name n3 --new-node-dsn "host=localhost dbname=pgedge port=5433 user=pgedge password=pgedge" --check-type pre --verbose

  # Add a new node to the cluster
  python zodan.py add_node --src-node-name n1 --src-dsn "host=localhost dbname=pgedge port=5431 user=pgedge password=pgedge" --new-node-name n3 --new-node-dsn "host=localhost dbname=pgedge port=5433 user=pgedge password=pgedge" --verbose

  # Post-check cluster health after adding a node
  python zodan.py health-check --src-node-name n1 --src-dsn "host=localhost dbname=pgedge port=5431 user=pgedge password=pgedge" --new-node-name n3 --new-node-dsn "host=localhost dbname=pgedge port=5433 user=pgedge password=pgedge" --check-type post --verbose
        """
    )
    
    subparsers = parser.add_subparsers(dest='command', help='Available commands')
    
    # Health check command
    health_check_parser = subparsers.add_parser('health-check', help='Validate cluster health before or after Z0DAN node addition')
    health_check_parser.add_argument('--src-node-name', required=True, help='Source node name')
    health_check_parser.add_argument('--src-dsn', required=True, help='Source node DSN')
    health_check_parser.add_argument('--new-node-name', help='New node name (optional for cluster-wide check)')
    health_check_parser.add_argument('--new-node-dsn', help='New node DSN (optional for cluster-wide check)')
    health_check_parser.add_argument('--check-type', choices=['pre', 'post'], default='pre', help='Check type: pre (before add_node) or post (after add_node)')
    health_check_parser.add_argument('--verbose', action='store_true', help='Enable verbose output')
    
    # Add node command
    add_node_parser = subparsers.add_parser('add_node', help='Add a new node to the Spock cluster')
    add_node_parser.add_argument('--src-node-name', required=True, help='Source node name')
    add_node_parser.add_argument('--src-dsn', required=True, help='Source node DSN')
    add_node_parser.add_argument('--new-node-name', required=True, help='New node name')
    add_node_parser.add_argument('--new-node-dsn', required=True, help='New node DSN')
    add_node_parser.add_argument('--new-node-location', default='NY', help='New node location (default: NY)')
    add_node_parser.add_argument('--new-node-country', default='USA', help='New node country (default: USA)')
    add_node_parser.add_argument('--new-node-info', default='{}', help='New node info JSON (default: {})')
    add_node_parser.add_argument('--verbose', action='store_true', help='Enable verbose output')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return
    
    if args.command == 'health-check':
        manager = SpockClusterManager(verbose=args.verbose)
        try:
            result = manager.health_check(
                args.src_node_name,
                args.src_dsn,
                args.new_node_name,
                args.new_node_dsn,
                args.check_type
            )
            sys.exit(0 if result else 1)
        except Exception as e:
            print(f"ERROR: {e}")
            sys.exit(1)
        
    elif args.command == 'add_node':
        manager = SpockClusterManager(verbose=args.verbose)
        try:
            manager.add_node(
                args.src_node_name,
                args.src_dsn,
                args.new_node_name,
                args.new_node_dsn,
                args.new_node_location,
                args.new_node_country,
                args.new_node_info
            )
        except Exception as e:
            print(f"ERROR: {e}")
            sys.exit(1)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
