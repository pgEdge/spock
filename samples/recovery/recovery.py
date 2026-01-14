#!/usr/bin/env python3
"""
Spock Recovery System - Python Version
Version: 1.0.0
100% matches recovery.sql functionality but uses direct psql connections instead of dblink.

This script provides all the same procedures and functionality as recovery.sql:
- recover_cluster: Complete recovery with comprehensive and origin-aware modes
- All validation, analysis, and recovery procedures
- Error handling and verbose logging

Usage:
    python recovery.py recover_cluster --source-dsn "host=localhost port=5453 dbname=pgedge user=pgedge" --target-dsn "host=localhost port=5452 dbname=pgedge user=pgedge" --recovery-mode comprehensive --verbose
"""

import subprocess
import json
import time
import sys
import re
from typing import List, Dict, Any, Optional, Tuple
import argparse
from datetime import datetime
import uuid

try:
    import psycopg2
    from psycopg2 import sql
    from psycopg2.extras import RealDictCursor
except ImportError:
    psycopg2 = None
    print("ERROR: psycopg2 is required. Install with: pip install psycopg2-binary")
    sys.exit(1)


class SpockRecoveryManager:
    VERSION = "1.0.0"
    
    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self.source_dsn = None
        self.target_dsn = None
        
    def log(self, msg: str):
        """Log a message with timestamp"""
        print(f"[LOG] {msg}")
        
    def info(self, msg: str):
        """Log an info message"""
        if self.verbose:
            print(f"[INFO] {msg}")
        
    def notice(self, msg: str):
        """Log a notice message (matches PostgreSQL NOTICE)"""
        print(f"NOTICE: {msg}")
        
    def format_notice(self, status: str, message: str, node: str = None):
        """Format notice message like recovery.sql: OK:/ERROR datetime [node] : message"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        if node:
            formatted_msg = f"{status} {timestamp} [{node}] : {message}"
        else:
            formatted_msg = f"{status} {timestamp} : {message}"
        self.notice(formatted_msg)
        
    def parse_dsn(self, dsn: str) -> Dict[str, str]:
        """Parse DSN string into components"""
        result = {}
        # Simple parser for key=value pairs
        for part in dsn.split():
            if '=' in part:
                key, value = part.split('=', 1)
                result[key] = value.strip("'\"")
        return result
        
    def dsn_to_psycopg2(self, dsn: str) -> str:
        """Convert DSN string to psycopg2 connection string"""
        parsed = self.parse_dsn(dsn)
        # psycopg2 uses space-separated key=value format
        return dsn
        
    def execute_sql(self, dsn: str, sql_query: str, fetch: bool = False, fetch_one: bool = False) -> Optional[Any]:
        """
        Execute SQL using psycopg2 connection.
        
        Args:
            dsn: Database connection string
            sql_query: SQL command to execute
            fetch: Whether to return results
            fetch_one: If fetch=True, return single row instead of list
        """
        try:
            conn = psycopg2.connect(self.dsn_to_psycopg2(dsn))
            conn.autocommit = True
            cur = conn.cursor(cursor_factory=RealDictCursor)
            
            if self.verbose:
                self.info(f"Executing SQL on: {dsn}")
                self.info(f"SQL: {sql_query[:200]}...")
            
            cur.execute(sql_query)
            
            if fetch:
                if fetch_one:
                    result = cur.fetchone()
                    cur.close()
                    conn.close()
                    return dict(result) if result else None
                else:
                    results = cur.fetchall()
                    cur.close()
                    conn.close()
                    return [dict(row) for row in results]
            else:
                cur.close()
                conn.close()
                return None
                
        except Exception as e:
            self.log(f"SQL execution failed: {str(e)}")
            if conn:
                conn.close()
            raise
            
    def execute_sql_value(self, dsn: str, sql_query: str) -> Optional[Any]:
        """Execute SQL and return single value"""
        result = self.execute_sql(dsn, sql_query, fetch=True, fetch_one=True)
        if result:
            return list(result.values())[0] if result else None
        return None
        
    def validate_prerequisites(self, source_dsn: str, target_dsn: str):
        """Phase 0: Validate prerequisites and connectivity"""
        self.notice("Phase 0: Validating prerequisites and connectivity")
        self.notice("")
        
        # Check if spock extension is installed on target node
        try:
            result = self.execute_sql_value(
                target_dsn,
                "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'spock')"
            )
            if result:
                self.format_notice("✓", "Checking Spock extension is installed on target node")
            else:
                self.format_notice("✗", "Spock extension is not installed on target node")
                raise Exception("Exiting recover_cluster: Spock extension is required on target node. Please install it first.")
        except Exception as e:
            if "✗" not in str(e):
                self.format_notice("✗", f"Error checking Spock extension on target: {str(e)}")
            raise
            
        # Check if source database is accessible
        try:
            source_db_name = self.parse_dsn(source_dsn).get('dbname', 'unknown')
            result = self.execute_sql_value(source_dsn, "SELECT 1")
            if result:
                self.format_notice("✓", f"Checking source database {source_db_name} is accessible")
            else:
                self.format_notice("✗", f"Source database {source_db_name} is not accessible")
                raise Exception("Exiting recover_cluster: Cannot connect to source database. Please verify DSN and connectivity.")
        except Exception as e:
            if "✗" not in str(e):
                self.format_notice("✗", f"Source database connection failed: {str(e)}")
            raise Exception(f"Exiting recover_cluster: Cannot connect to source database: {str(e)}")
            
        # Check if spock extension is installed on source node
        try:
            result = self.execute_sql_value(
                source_dsn,
                "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'spock')"
            )
            if result:
                self.format_notice("✓", "Checking Spock extension is installed on source node")
            else:
                self.format_notice("✗", "Spock extension is not installed on source node")
                raise Exception("Exiting recover_cluster: Spock extension is required on source node. Please install it first.")
        except Exception as e:
            if "✗" not in str(e):
                self.format_notice("✗", f"Error checking Spock extension on source: {str(e)}")
            raise
            
        # Check if source node has spock.node table (spock is configured)
        try:
            result = self.execute_sql_value(
                source_dsn,
                "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = 'spock' AND table_name = 'node')"
            )
            if result:
                self.format_notice("✓", "Checking Spock is configured on source node")
            else:
                self.format_notice("✗", "Spock is not configured on source node")
                raise Exception("Exiting recover_cluster: Spock is not configured on source node. Please configure Spock first.")
        except Exception as e:
            if "✗" not in str(e):
                self.format_notice("✗", f"Error checking Spock configuration on source: {str(e)}")
            raise
            
        # Check if target node has spock.node table (spock is configured)
        try:
            result = self.execute_sql_value(
                target_dsn,
                "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = 'spock' AND table_name = 'node')"
            )
            if result:
                self.format_notice("✓", "Checking Spock is configured on target node")
            else:
                self.format_notice("✗", "Spock is not configured on target node")
                raise Exception("Exiting recover_cluster: Spock is not configured on target node. Please configure Spock first.")
        except Exception as e:
            if "✗" not in str(e):
                self.format_notice("✗", f"Error checking Spock configuration on target: {str(e)}")
            raise
            
        self.notice("")
        self.notice("Phase 0 Complete: All prerequisites validated")
        self.notice("")
        
    def get_replicated_tables(self, target_dsn: str, include_schemas: List[str] = None, exclude_schemas: List[str] = None) -> List[Dict[str, Any]]:
        """Get all replicated tables from target node"""
        if include_schemas is None:
            include_schemas = ['public']
        if exclude_schemas is None:
            exclude_schemas = ['pg_catalog', 'information_schema', 'spock']
            
        exclude_list = "', '".join(exclude_schemas)
        include_condition = ""
        if include_schemas:
            include_list = "', '".join(include_schemas)
            include_condition = f"AND (n.nspname = ANY(ARRAY['{include_list}']))"
            
        sql = f"""
        SELECT DISTINCT
            n.nspname as schema_name,
            c.relname as table_name,
            c.oid::text as table_oid
        FROM spock.replication_set rs
        JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
        JOIN pg_class c ON c.oid = rst.set_reloid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname <> ALL(ARRAY['{exclude_list}'])
        {include_condition}
        ORDER BY n.nspname, c.relname
        """
        
        return self.execute_sql(target_dsn, sql, fetch=True) or []
        
    def get_primary_key_columns(self, dsn: str, schema_name: str, table_name: str) -> List[str]:
        """Get primary key columns for a table"""
        sql = f"""
        SELECT a.attname
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = '{schema_name}.{table_name}'::regclass
        AND i.indisprimary
        ORDER BY array_position(i.indkey, a.attnum)
        """
        results = self.execute_sql(dsn, sql, fetch=True) or []
        return [r['attname'] for r in results]
        
    def get_all_columns(self, dsn: str, schema_name: str, table_name: str) -> List[Dict[str, str]]:
        """Get all columns with types for a table"""
        sql = f"""
        SELECT 
            a.attname,
            format_type(a.atttypid, a.atttypmod) as atttype
        FROM pg_attribute a
        WHERE a.attrelid = '{schema_name}.{table_name}'::regclass
        AND a.attnum > 0 
        AND NOT a.attisdropped
        ORDER BY a.attnum
        """
        return self.execute_sql(dsn, sql, fetch=True) or []
        
    def get_row_count(self, dsn: str, schema_name: str, table_name: str, origin_node_id: Optional[int] = None) -> int:
        """Get row count from a table, optionally filtered by origin"""
        if origin_node_id:
            sql = f"""
            SELECT COUNT(*) 
            FROM {schema_name}.{table_name}
            WHERE (to_json(spock.xact_commit_timestamp_origin(xmin))->>'roident')::oid = {origin_node_id}
            """
        else:
            sql = f"SELECT COUNT(*) FROM {schema_name}.{table_name}"
            
        result = self.execute_sql_value(dsn, sql)
        return int(result) if result else 0
        
    def get_missing_rows(self, source_dsn: str, target_dsn: str, schema_name: str, table_name: str, 
                        pk_columns: List[str], all_columns: List[Dict[str, str]], 
                        origin_node_id: Optional[int] = None) -> List[Dict[str, Any]]:
        """Get missing rows from source that don't exist in target"""
        # Build column list with types
        col_list = ", ".join([f"{col['attname']} {col['atttype']}" for col in all_columns])
        pk_list = ", ".join(pk_columns)
        
        # Build WHERE clause for origin filter
        origin_filter = ""
        if origin_node_id:
            origin_filter = f"WHERE (to_json(spock.xact_commit_timestamp_origin(xmin))->>'roident')::oid = {origin_node_id}"
        
        # Get all rows from source
        source_sql = f"SELECT * FROM {schema_name}.{table_name} {origin_filter}"
        source_rows = self.execute_sql(source_dsn, source_sql, fetch=True) or []
        
        # Get existing PKs from target
        target_pk_sql = f"SELECT {pk_list} FROM {schema_name}.{table_name}"
        target_pks = self.execute_sql(target_dsn, target_pk_sql, fetch=True) or []
        target_pk_set = set()
        for row in target_pks:
            pk_tuple = tuple(row[col] for col in pk_columns)
            target_pk_set.add(pk_tuple)
        
        # Find missing rows
        missing_rows = []
        for row in source_rows:
            pk_tuple = tuple(row[col] for col in pk_columns)
            if pk_tuple not in target_pk_set:
                missing_rows.append(row)
                
        return missing_rows
        
    def insert_rows(self, target_dsn: str, schema_name: str, table_name: str, rows: List[Dict[str, Any]]) -> int:
        """Insert rows into target table"""
        if not rows:
            return 0
            
        # Get column names from first row
        columns = list(rows[0].keys())
        col_list = ", ".join([f'"{col}"' for col in columns])
        
        # Build INSERT statement
        values_list = []
        for row in rows:
            value_strs = []
            for col in columns:
                val = row[col]
                if val is None:
                    value_strs.append("NULL")
                elif isinstance(val, str):
                    # Escape single quotes
                    escaped = val.replace("'", "''")
                    value_strs.append(f"'{escaped}'")
                elif isinstance(val, (int, float)):
                    value_strs.append(str(val))
                elif isinstance(val, bool):
                    value_strs.append("TRUE" if val else "FALSE")
                else:
                    # For other types, convert to string and quote
                    escaped = str(val).replace("'", "''")
                    value_strs.append(f"'{escaped}'")
            values_list.append(f"({', '.join(value_strs)})")
        
        insert_sql = f"""
        INSERT INTO {schema_name}.{table_name} ({col_list})
        VALUES {', '.join(values_list)}
        """
        
        try:
            conn = psycopg2.connect(self.dsn_to_psycopg2(target_dsn))
            conn.autocommit = True
            cur = conn.cursor()
            cur.execute(insert_sql)
            rowcount = cur.rowcount
            cur.close()
            conn.close()
            return rowcount
        except Exception as e:
            self.log(f"Insert failed: {str(e)}")
            raise
            
    def recover_cluster(self, source_dsn: str, target_dsn: str, recovery_mode: str = 'comprehensive',
                       origin_node_name: Optional[str] = None, dry_run: bool = False, 
                       verbose: bool = True, auto_repair: bool = True,
                       include_schemas: List[str] = None, exclude_schemas: List[str] = None):
        """
        Main recovery procedure - matches recovery.sql exactly
        
        Args:
            source_dsn: DSN to source node (n3)
            target_dsn: DSN to target node (n2)
            recovery_mode: 'comprehensive' or 'origin-aware'
            origin_node_name: Required for origin-aware mode
            dry_run: Preview changes without applying
            verbose: Enable verbose output
            auto_repair: Automatically repair tables
            include_schemas: Schemas to include (None for all)
            exclude_schemas: Schemas to exclude
        """
        self.verbose = verbose
        start_time = time.time()
        
        # Validate recovery mode
        recovery_mode = recovery_mode.lower()
        if recovery_mode not in ('comprehensive', 'origin-aware'):
            raise Exception(f'Invalid recovery mode "{recovery_mode}". Must be "comprehensive" or "origin-aware".')
            
        # For origin-aware mode, require origin node name
        origin_node_id = None
        if recovery_mode == 'origin-aware':
            if not origin_node_name:
                raise Exception('Origin-aware recovery requires origin_node_name parameter.')
            # Get origin node ID from target
            sql = f"SELECT node_id FROM spock.node WHERE node_name = '{origin_node_name}'"
            result = self.execute_sql_value(target_dsn, sql)
            if not result:
                raise Exception(f'Origin node "{origin_node_name}" not found in spock.node table.')
            origin_node_id = int(result)
            
        if verbose:
            self.notice("")
            self.notice("========================================================================")
            self.notice(f"         Spock Recovery System - {recovery_mode.upper()} Mode")
            self.notice("========================================================================")
            self.notice("")
            self.notice("Configuration:")
            self.notice(f"  Recovery Mode: {recovery_mode.upper()}")
            if recovery_mode == 'origin-aware':
                self.notice(f"  Origin Node: {origin_node_name} (OID: {origin_node_id})")
            self.notice(f"  Source DSN: {source_dsn}")
            self.notice(f"  Target DSN: {target_dsn}")
            self.notice(f"  Dry Run: {dry_run}")
            self.notice(f"  Auto Repair: {auto_repair}")
            self.notice("")
            
        # Phase 0: Validate prerequisites
        self.validate_prerequisites(source_dsn, target_dsn)
        
        # Phase 1: Discovery
        if verbose:
            self.notice("========================================================================")
            self.notice("PHASE 1: Discovery - Find All Replicated Tables")
            self.notice("========================================================================")
            self.notice("")
            
        tables = self.get_replicated_tables(target_dsn, include_schemas, exclude_schemas)
        table_count = len(tables)
        
        if verbose:
            self.notice(f"Found {table_count} replicated tables")
            self.notice("")
            
        if table_count == 0:
            self.notice("WARNING: No replicated tables found. Nothing to recover.")
            return
            
        # Phase 2: Analysis
        if verbose:
            self.notice("========================================================================")
            self.notice("PHASE 2: Analysis - Check Each Table for Inconsistencies")
            self.notice("========================================================================")
            self.notice("")
            
        recovery_report = []
        tables_needing_recovery = []
        
        for idx, table in enumerate(tables, 1):
            schema_name = table['schema_name']
            table_name = table['table_name']
            table_full_name = f"{schema_name}.{table_name}"
            
            if verbose:
                self.notice(f"[{idx}/{table_count}] Checking {table_full_name}...")
                
            # Check if table has primary key
            pk_cols = self.get_primary_key_columns(target_dsn, schema_name, table_name)
            if not pk_cols:
                if verbose:
                    self.notice("  [SKIPPED] No primary key")
                recovery_report.append({
                    'schema': schema_name,
                    'table': table_name,
                    'status': 'SKIPPED',
                    'details': 'No primary key',
                    'rows_affected': 0
                })
                continue
                
            # Get row counts
            source_count = self.get_row_count(source_dsn, schema_name, table_name)
            target_count = self.get_row_count(target_dsn, schema_name, table_name)
            
            source_origin_count = None
            if recovery_mode == 'origin-aware':
                source_origin_count = self.get_row_count(source_dsn, schema_name, table_name, origin_node_id)
                missing_rows = max(0, source_origin_count - target_count)
            else:
                missing_rows = source_count - target_count
                
            # Determine status
            if missing_rows > 0:
                status = 'NEEDS_RECOVERY'
                if recovery_mode == 'origin-aware':
                    details = f"{missing_rows} rows from origin {origin_node_name} missing (source: {source_origin_count} origin-rows, target: {target_count} rows)"
                else:
                    details = f"{missing_rows} rows missing (source: {source_count}, target: {target_count})"
                tables_needing_recovery.append({
                    'schema': schema_name,
                    'table': table_name,
                    'missing_rows': missing_rows,
                    'pk_cols': pk_cols
                })
            elif missing_rows < 0:
                status = 'WARNING'
                details = f"Target has {-missing_rows} more rows than source"
            else:
                status = 'OK'
                if recovery_mode == 'origin-aware':
                    details = f"All origin rows present (source: {source_origin_count} origin-rows, target: {target_count} rows)"
                else:
                    details = f"Synchronized (source: {source_count}, target: {target_count})"
                    
            if verbose:
                if status == 'NEEDS_RECOVERY':
                    self.notice(f"  ⚠ {details}")
                elif status == 'OK':
                    self.notice(f"  ✓ {details}")
                else:
                    self.notice(f"  ⚠ {details}")
                    
            recovery_report.append({
                'schema': schema_name,
                'table': table_name,
                'status': status,
                'details': details,
                'rows_affected': missing_rows if missing_rows > 0 else 0,
                'source_count': source_count,
                'target_count': target_count
            })
            
        # Phase 3: Recovery
        if auto_repair and tables_needing_recovery:
            if verbose:
                self.notice("")
                self.notice("========================================================================")
                self.notice("PHASE 3: Recovery - Repair Tables")
                self.notice("========================================================================")
                self.notice("")
                
            total_rows_recovered = 0
            tables_recovered = 0
            
            for idx, table_info in enumerate(tables_needing_recovery, 1):
                schema_name = table_info['schema']
                table_name = table_info['table']
                table_full_name = f"{schema_name}.{table_name}"
                missing_rows = table_info['missing_rows']
                pk_cols = table_info['pk_cols']
                
                if verbose:
                    self.notice(f"[{idx}/{len(tables_needing_recovery)}] Recovering {table_full_name}...")
                    
                try:
                    # Get all columns
                    all_cols = self.get_all_columns(target_dsn, schema_name, table_name)
                    
                    # Get missing rows
                    missing_data = self.get_missing_rows(
                        source_dsn, target_dsn, schema_name, table_name,
                        pk_cols, all_cols, origin_node_id if recovery_mode == 'origin-aware' else None
                    )
                    
                    if dry_run:
                        status = 'DRY_RUN'
                        details = f"DRY RUN: Would insert {len(missing_data)} rows"
                        rows_affected = len(missing_data)
                    else:
                        # Insert missing rows
                        rows_affected = self.insert_rows(target_dsn, schema_name, table_name, missing_data)
                        status = 'RECOVERED'
                        details = f"Successfully inserted {rows_affected} rows"
                        total_rows_recovered += rows_affected
                        tables_recovered += 1
                        
                    # Update report
                    for report in recovery_report:
                        if report['schema'] == schema_name and report['table'] == table_name:
                            report['status'] = status
                            report['details'] = details
                            report['rows_affected'] = rows_affected
                            break
                            
                    if verbose:
                        self.notice(f"  ✓ Recovered {rows_affected} rows")
                        
                except Exception as e:
                    if verbose:
                        self.notice(f"  ✗ RECOVERY_FAILED: {str(e)}")
                    for report in recovery_report:
                        if report['schema'] == schema_name and report['table'] == table_name:
                            report['status'] = 'RECOVERY_FAILED'
                            report['details'] = str(e)
                            break
                            
            # Final Report
            if verbose:
                end_time = time.time()
                time_taken = end_time - start_time
                
                self.notice("")
                self.notice("========================================================================")
                self.notice("                    FINAL RECOVERY REPORT")
                self.notice("========================================================================")
                self.notice("")
                
                # Summary by status
                status_counts = {}
                for report in recovery_report:
                    status = report['status']
                    status_counts[status] = status_counts.get(status, 0) + 1
                    
                self.notice("Summary by Status:")
                for status, count in sorted(status_counts.items()):
                    self.notice(f"  {status}: {count} tables")
                    
                self.notice("")
                self.notice("========================================================================")
                self.notice("Recovery Statistics")
                self.notice("========================================================================")
                self.notice(f"  ✓ Tables Recovered: {tables_recovered}")
                ok_count = sum(1 for r in recovery_report if r['status'] == 'OK')
                self.notice(f"  ✓ Tables Already OK: {ok_count}")
                still_need = sum(1 for r in recovery_report if r['status'] == 'NEEDS_RECOVERY')
                self.notice(f"  ⚠ Tables Still Need Recovery: {still_need}")
                error_count = sum(1 for r in recovery_report if r['status'] in ('ERROR', 'RECOVERY_FAILED'))
                self.notice(f"  ✗ Tables With Errors: {error_count}")
                self.notice(f"  Total Rows Recovered: {total_rows_recovered}")
                self.notice(f"  Total Time: {time_taken:.2f}s")
                self.notice("")
                
                if dry_run:
                    self.notice("========================================================================")
                    self.notice("              DRY RUN COMPLETE - NO CHANGES MADE")
                    self.notice("========================================================================")
                elif still_need == 0 and error_count == 0:
                    self.notice("========================================================================")
                    self.notice("                  RECOVERY COMPLETE - SUCCESS")
                    self.notice("========================================================================")
                else:
                    self.notice("========================================================================")
                    self.notice("              RECOVERY COMPLETED WITH ISSUES")
                    self.notice("========================================================================")
                self.notice("")
                
        return recovery_report


def main():
    parser = argparse.ArgumentParser(
        description='Spock Recovery System - Python Version',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument('command', choices=['recover_cluster'],
                       help='Command to execute')
    parser.add_argument('--source-dsn', required=True,
                       help='DSN to source node (e.g., "host=localhost port=5453 dbname=pgedge user=pgedge")')
    parser.add_argument('--target-dsn', required=True,
                       help='DSN to target node (e.g., "host=localhost port=5452 dbname=pgedge user=pgedge")')
    parser.add_argument('--recovery-mode', default='comprehensive',
                       choices=['comprehensive', 'origin-aware'],
                       help='Recovery mode: comprehensive or origin-aware')
    parser.add_argument('--origin-node-name',
                       help='Origin node name (required for origin-aware mode)')
    parser.add_argument('--dry-run', action='store_true',
                       help='Preview changes without applying')
    parser.add_argument('--verbose', action='store_true', default=True,
                       help='Enable verbose output')
    parser.add_argument('--auto-repair', action='store_true', default=True,
                       help='Automatically repair tables')
    
    args = parser.parse_args()
    
    manager = SpockRecoveryManager(verbose=args.verbose)
    
    try:
        if args.command == 'recover_cluster':
            manager.recover_cluster(
                source_dsn=args.source_dsn,
                target_dsn=args.target_dsn,
                recovery_mode=args.recovery_mode,
                origin_node_name=args.origin_node_name,
                dry_run=args.dry_run,
                verbose=args.verbose,
                auto_repair=args.auto_repair
            )
    except Exception as e:
        print(f"ERROR: {str(e)}")
        sys.exit(1)


if __name__ == '__main__':
    main()

