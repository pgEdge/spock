#!/usr/bin/env python3
"""
Spock Three-Node Cluster Setup and Verification Script

Creates a three-node PostgreSQL cluster with Spock replication:
- n1, n2, n3 nodes
- Cross-wired replication
- Verification from all nodes
- Colored output with timestamps and elapsed time
- Automatic cleanup on errors
"""

import argparse
import os
import sys
import time
import subprocess
import shutil
import platform
import getpass
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime

try:
    import psycopg2
    from psycopg2 import OperationalError, Error as Psycopg2Error
except ImportError:
    psycopg2 = None
    OperationalError = None
    Psycopg2Error = None


# ============================================================================
# ANSI Color Codes
# ============================================================================

class Colors:
    """ANSI color codes for terminal output."""
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    @staticmethod
    def disable():
        """Disable colors."""
        Colors.GREEN = ''
        Colors.RED = ''
        Colors.YELLOW = ''
        Colors.BLUE = ''
        Colors.RESET = ''
        Colors.BOLD = ''


# ============================================================================
# Configuration
# ============================================================================

@dataclass
class ClusterConfig:
    """Cluster configuration."""
    DB_USER: str = getpass.getuser()  # Use system user
    DB_PASSWORD: str = "1safepassword"
    DB_NAME: str = "pgedge"  # Default database name
    DEFAULT_PORT_START: int = 5451
    MAX_RETRIES: int = 60  # Increased for slower systems
    RETRY_DELAY_SEC: int = 1  # Reduced delay but more retries
    CONNECT_TIMEOUT: int = 5
    NUM_NODES: int = 3


# ============================================================================
# Output Formatter
# ============================================================================

class OutputFormatter:
    """Formats output with colors, timestamps, and alignment."""
    
    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self.start_time = time.time()
        self.column_widths = {
            'status': 1,
            'timestamp': 19,
            'statement': 50,
            'elapsed': 10
        }
    
    def print_banner(self, os_info: str, pg_version: str, pg_bin: str, spock_version: str):
        """Print initial banner with system information."""
        print(f"\n{Colors.BOLD}{'-'*72}{Colors.RESET}")
        print(f"{Colors.BOLD}OS:{Colors.RESET}")
        print(f"         Version: {os_info}")
        print(f"{Colors.BOLD}PostgreSQL:{Colors.RESET}")
        print(f"                 Version: {pg_version}")
        print(f"                 Bin:     {pg_bin}")
        print(f"{Colors.BOLD}Spock:{Colors.RESET}")
        print(f"                 Version: {spock_version}")
        print(f"{Colors.BOLD}{'-'*72}{Colors.RESET}\n")
    
    def _get_elapsed(self) -> str:
        """Get elapsed time since start."""
        elapsed = time.time() - self.start_time
        return f"{elapsed:.2f}s"
    
    def _get_timestamp(self) -> str:
        """Get current timestamp."""
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    def _format_line(self, status: str, statement: str, elapsed: Optional[str] = None, 
                     port: Optional[int] = None, indent: int = 0) -> str:
        """Format a single line with perfect column alignment."""
        if elapsed is None:
            elapsed = self._get_elapsed()
        
        timestamp = self._get_timestamp()
        
        # Choose color based on status
        if status == '✓':
            color = Colors.GREEN
        elif status == '✗':
            color = Colors.RED
        elif status == '⚠':
            color = Colors.YELLOW
        else:
            color = Colors.RESET
        
        # Format columns with fixed widths for perfect alignment
        indent_str = "  " * indent  # Use spaces instead of tabs for consistent alignment
        
        # Status: 1 char (colored)
        status_col = f"{color}{status}{Colors.RESET}"
        
        # Timestamp: 19 chars (YYYY-MM-DD HH:MM:SS)
        timestamp_col = timestamp
        
        # Port: 8 chars ( [XXXX] format, padded)
        if port is not None:
            port_col = f" [{port}]"
        else:
            port_col = "        "  # 8 spaces
        
        # Statement: truncate if too long (but preserve full message for errors)
        # For errors, show full message on separate lines to maintain elapsed time alignment
        statement_col = statement
        
        # Fixed width for statement area: 60 chars (20% more than 50, truncate if longer for alignment)
        # But for errors and info messages with LSNs/slots, we want to show the full message
        STATEMENT_WIDTH = 60
        if len(statement_col) > STATEMENT_WIDTH and status != '✗' and 'Slot' not in statement_col and 'LSN' not in statement_col:
            statement_col = statement_col[:57] + "..."
        
        # Build the line with fixed column positions
        # Status (1) + space (1) = 2
        # Timestamp (19) = 21
        # Port (8) = 29
        # ": " (2) = 31
        # Statement (60) = 91
        # Space (1) = 92
        # Elapsed (10, right-aligned) = 102
        
        # For errors, show full message but keep it clean and readable
        if status == '✗':
            # Truncate very long messages but show key info
            if len(statement) > 120:
                # Show first part and last part
                first_part = statement[:60]
                last_part = statement[-50:]
                statement_col = f"{first_part}...{last_part}"
            elif len(statement) > STATEMENT_WIDTH:
                statement_col = statement
            else:
                statement_col = statement
            
            # For long error messages, print on multiple lines
            if len(statement_col) > STATEMENT_WIDTH:
                lines = []
                # First line with truncated message and elapsed time (aligned)
                first_line = f"{indent_str}{status_col} {timestamp_col}{port_col}: {statement_col[:57]:<57}... {elapsed:>10}"
                lines.append(first_line)
                # Additional lines with continuation
                cont_indent = len(indent_str) + 31
                remaining = statement_col[57:]
                while remaining:
                    chunk = remaining[:90] if len(remaining) > 90 else remaining
                    remaining = remaining[90:] if len(remaining) > 90 else ""
                    lines.append(f"{' ' * cont_indent}{chunk}")
                return "\n".join(lines)
            else:
                line = f"{indent_str}{status_col} {timestamp_col}{port_col}: {statement_col:<{STATEMENT_WIDTH}} {elapsed:>10}"
                return line
        else:
            # For non-errors, truncate if too long
            if len(statement_col) > STATEMENT_WIDTH:
                statement_col = statement_col[:57] + "..."
            line = f"{indent_str}{status_col} {timestamp_col}{port_col}: {statement_col:<{STATEMENT_WIDTH}} {elapsed:>10}"
            return line
    
    def success(self, statement: str, elapsed: Optional[str] = None, port: Optional[int] = None, indent: int = 0):
        """Print success message."""
        print(self._format_line('✓', statement, elapsed, port, indent))
    
    def error(self, statement: str, elapsed: Optional[str] = None, port: Optional[int] = None, indent: int = 0):
        """Print error message."""
        print(self._format_line('✗', statement, elapsed, port, indent))
    
    def warning(self, statement: str, elapsed: Optional[str] = None, port: Optional[int] = None, indent: int = 0):
        """Print warning message."""
        print(self._format_line('⚠', statement, elapsed, port, indent))
    
    def info(self, statement: str, elapsed: Optional[str] = None, port: Optional[int] = None, indent: int = 0):
        """Print info message with optional indentation."""
        print(self._format_line(' ', statement, elapsed, port, indent))
    
    def substep(self, statement: str, indent: int = 1):
        """Print a sub-step with indentation."""
        indent_str = "  " * indent
        if self.verbose:
            timestamp = self._get_timestamp()
            elapsed = self._get_elapsed()
            print(f"{indent_str}→ {statement} {elapsed.rjust(10)}")
        else:
            print(f"{indent_str}→ {statement}")
    
    def header(self, title: str):
        """Print section header."""
        print(f"\n{Colors.BOLD}{'='*70}{Colors.RESET}")
        print(f"{Colors.BOLD}{title.center(70)}{Colors.RESET}")
        print(f"{Colors.BOLD}{'='*70}{Colors.RESET}\n")


# ============================================================================
# PostgreSQL Manager
# ============================================================================

class PostgresManager:
    """Manages PostgreSQL instances."""
    
    def __init__(self, config: ClusterConfig, formatter: OutputFormatter, 
                 pgdata_path: str, postgres_path: Optional[str] = None):
        self.config = config
        self.formatter = formatter
        self.pgdata_path = Path(pgdata_path)
        self.postgres_path = Path(postgres_path) if postgres_path else None
        self.postgres_bin = None
        self.nodes: Dict[str, Dict] = {}
        
        if psycopg2 is None:
            raise RuntimeError("psycopg2 is required. Install with: pip install psycopg2-binary")
    
    def _run_command(self, cmd: List[str], check: bool = True, 
                     capture_output: bool = False) -> subprocess.CompletedProcess:
        """Run a command and return result."""
        try:
            # If capture_output is True, suppress output; otherwise show it
            if capture_output:
                stdout = subprocess.DEVNULL
                stderr = subprocess.DEVNULL
            else:
                stdout = None
                stderr = None
            result = subprocess.run(
                cmd,
                check=check,
                stdout=stdout,
                stderr=stderr,
                text=True
            )
            return result
        except subprocess.CalledProcessError as e:
            if check:
                raise RuntimeError(f"Command failed: {' '.join(cmd)}: {e}")
            return e
    
    def _find_postgres_binary(self) -> Path:
        """Find PostgreSQL binary path from PATH or specified location."""
        if self.postgres_bin:
            return self.postgres_bin
        
        # First, try to find from PATH
        which_result = shutil.which("postgres")
        if which_result:
            postgres_bin = Path(which_result).parent
            if (postgres_bin / "initdb").exists():
                self.postgres_bin = postgres_bin
                return postgres_bin
        
        # If postgres_path was provided, use it
        if self.postgres_path:
            self.postgres_bin = self.postgres_path / "bin"
            if self.postgres_bin.exists():
                return self.postgres_bin
        
        # Try common locations (prioritize pgsql.spock.18)
        for path in [Path("/usr/local/pgsql.spock.18/bin"),
                    Path("/usr/local/pgsql.18-pge/bin"), 
                    Path("/usr/local/pgsql/bin"),
                    Path("/usr/pgsql-18/bin"),
                    Path("/usr/pgsql-17/bin"),
                    Path("/usr/pgsql-16/bin")]:
            if path.exists() and (path / "initdb").exists():
                self.postgres_bin = path
                return path
        
        raise RuntimeError("PostgreSQL binaries not found. Please ensure PostgreSQL is in PATH or use --postgres option.")
    
    def initdb(self, node_name: str, port: int) -> Path:
        """Initialize PostgreSQL data directory and create pgedge database."""
        datadir = self.pgdata_path / node_name
        
        # Remove existing datadir if it exists
        if datadir.exists():
            shutil.rmtree(datadir)
        
        datadir.mkdir(parents=True, exist_ok=True)
        
        pg_bin = self._find_postgres_binary()
        initdb_cmd = [
            str(pg_bin / "initdb"),
            "-A", "trust",
            "-D", str(datadir),
            "-U", self.config.DB_USER
        ]
        
        # Suppress initdb output - we show formatted status instead
        self._run_command(initdb_cmd, capture_output=True)
        
        # Create pgedge database as default after initdb
        # We'll do this after starting PostgreSQL, but note it here
        return datadir
    
    def optimize_postgresql_conf(self, datadir: Path, port: int):
        """Optimize PostgreSQL configuration for Spock replication."""
        conf_file = datadir / "postgresql.conf"
        
        # Read existing config
        config_lines = []
        if conf_file.exists():
            with open(conf_file, 'r') as f:
                config_lines = f.readlines()
        
        # Check if Spock library exists
        pg_bin = self._find_postgres_binary()
        pg_lib = pg_bin.parent / "lib"
        spock_lib = pg_lib / "spock.so"
        has_spock = spock_lib.exists()
        # Now that we've fixed the compilation issue, we can use shared_preload_libraries
        use_shared_preload = True
        
        # Essential Spock configuration settings
        spock_settings = {
            # Core PostgreSQL settings for logical replication
            'wal_level': 'logical',
            'max_worker_processes': '10',
            'max_replication_slots': '10',
            'max_wal_senders': '10',
            # Note: shared_preload_libraries will be set only if Spock is available
            # We'll check and set this conditionally
            'track_commit_timestamp': 'on',
            
            # Spock-specific settings
            'spock.enable_ddl_replication': 'on',
            'spock.include_ddl_repset': 'on',
            'spock.allow_ddl_from_functions': 'on',
            'spock.exception_behaviour': 'sub_disable',
            'spock.conflict_resolution': 'last_update_wins',
            
            # Network and connection settings
            'port': str(port),
            'listen_addresses': "'*'",
            
            # Performance tuning for Spock
            'shared_buffers': '128MB',
            'effective_cache_size': '256MB',
            'maintenance_work_mem': '64MB',
            'checkpoint_completion_target': '0.9',
            'wal_buffers': '16MB',
            'default_statistics_target': '100',
            'random_page_cost': '1.1',
            'effective_io_concurrency': '200',
            'work_mem': '4MB',
            'min_wal_size': '1GB',
            'max_wal_size': '4GB',
            
            # Additional settings for large operations
            'max_locks_per_transaction': '1000',
            
            # Logging (useful for debugging replication issues)
            'log_connections': 'on',
            'log_disconnections': 'on',
            'log_replication_commands': 'on',
            'log_min_messages': 'debug1',
            'log_statement': 'all',
            'log_min_duration_statement': '0',
            'log_line_prefix': "'%m [%p] %q%u@%d '",
            'log_checkpoints': 'on',
            'log_lock_waits': 'on',
        }
        
        # Track which settings we've processed (to avoid duplicates)
        processed_keys = set()
        updated_lines = []
        
        # Process existing lines - update or skip duplicates
        for line in config_lines:
            stripped = line.strip()
            line_updated = False
            
            for key, value in spock_settings.items():
                # Check if this line is a commented or uncommented version of our setting
                if key in processed_keys:
                    # Skip if we've already processed this setting
                    if stripped.startswith(f"#{key}") or (stripped.startswith(f"{key}") and not stripped.startswith('##')):
                        line_updated = True  # Mark to skip this duplicate
                        break
                    continue
                
                # Check if this line matches our setting (commented or not)
                if stripped.startswith(f"#{key}") or (stripped.startswith(f"{key}") and not stripped.startswith('##')):
                    updated_lines.append(f"{key} = {value}\n")
                    processed_keys.add(key)
                    line_updated = True
                    break
            
            # Keep the line if it wasn't a setting we're managing
            if not line_updated:
                updated_lines.append(line)
        
        # Add any missing settings
        for key, value in spock_settings.items():
            if key not in processed_keys:
                updated_lines.append(f"{key} = {value}\n")
        
        # Skip shared_preload_libraries to avoid startup failures
        # The Spock extension can still be created after server start
        # Note: Some Spock features require preloading, but basic replication should work
        if use_shared_preload and has_spock and 'shared_preload_libraries' not in processed_keys:
            updated_lines.append("shared_preload_libraries = 'spock'\n")
            processed_keys.add('shared_preload_libraries')
        
        # Write config
        with open(conf_file, 'w') as f:
            f.writelines(updated_lines)
        
        # Configure pg_hba.conf for Spock replication
        hba_file = datadir / "pg_hba.conf"
        hba_lines = [
            "# TYPE  DATABASE        USER            ADDRESS                 METHOD\n",
            "\n",
            "# Local connections\n",
            "local   all             all                                     trust\n",
            "\n",
            "# IPv4 local connections\n",
            "host    all             all             127.0.0.1/32            trust\n",
            "host    all             all             ::1/128                 trust\n",
            "\n",
            "# Replication connections (required for Spock)\n",
            "local   replication     all                                     trust\n",
            "host    replication     all             127.0.0.1/32            trust\n",
            "host    replication     all             ::1/128                 trust\n",
            "\n",
            "# Allow connections from local network (adjust as needed)\n",
            "host    all             all             0.0.0.0/0                trust\n",
            "host    replication     all             0.0.0.0/0                trust\n"
        ]
        with open(hba_file, 'w') as f:
            f.writelines(hba_lines)
    
    def start_postgres(self, datadir: Path, port: int) -> subprocess.Popen:
        """Start PostgreSQL instance."""
        pg_bin = self._find_postgres_binary()
        log_file = datadir / "postgresql.log"
        
        # Ensure log file exists and is writable
        log_file.parent.mkdir(parents=True, exist_ok=True)
        
        with open(log_file, 'a') as log:
            process = subprocess.Popen(
                [str(pg_bin / "postgres"), "-D", str(datadir), "-p", str(port)],
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True  # Start in new session to avoid signal issues
            )
        
        # Give it a moment to start
        time.sleep(0.5)
        
        return process
    
    def wait_for_postgres(self, port: int, max_retries: int = None, process: subprocess.Popen = None) -> bool:
        """Wait for PostgreSQL to be ready."""
        max_retries = max_retries or self.config.MAX_RETRIES
        for i in range(max_retries):
            # Check if process is still running (only check after a few attempts to give it time to start)
            if process is not None and i > 3:
                poll_result = process.poll()
                if poll_result is not None:
                    # Process has exited, check return code
                    if poll_result != 0:
                        return False
            
            try:
                conn = psycopg2.connect(
                    host="localhost",
                    port=port,
                    user=self.config.DB_USER,
                    password=self.config.DB_PASSWORD,
                    database="postgres",
                    connect_timeout=2
                )
                conn.close()
                return True
            except Exception:
                if i < max_retries - 1:
                    time.sleep(self.config.RETRY_DELAY_SEC)
        return False
    
    def connect(self, port: int):
        """Create a PostgreSQL connection."""
        return psycopg2.connect(
            host="localhost",
            port=port,
            user=self.config.DB_USER,
            password=self.config.DB_PASSWORD,
            database=self.config.DB_NAME,
            connect_timeout=self.config.CONNECT_TIMEOUT
        )
    
    def execute_sql(self, conn, sql: str, params: Tuple = None):
        """Execute SQL statement."""
        try:
            with conn.cursor() as cur:
                if params:
                    cur.execute(sql, params)
                else:
                    cur.execute(sql)
            conn.commit()
        except Psycopg2Error as e:
            conn.rollback()
            # Format SQL command for display (single line, clean)
            sql_clean = ' '.join(sql.strip().split())
            # Create a clean error message
            error_msg = f"{sql_clean} | ERROR: {e}"
            raise RuntimeError(error_msg) from e
    
    def fetch_sql(self, conn, sql: str, params: Tuple = None):
        """Execute SQL and fetch results."""
        try:
            with conn.cursor() as cur:
                if params:
                    cur.execute(sql, params)
                else:
                    cur.execute(sql)
                return cur.fetchall()
        except Psycopg2Error as e:
            raise RuntimeError(f"SQL execution failed: {e}") from e


# ============================================================================
# Spock Setup
# ============================================================================

class SpockSetup:
    """Sets up Spock replication."""
    
    def __init__(self, config: ClusterConfig, pg_manager: PostgresManager, 
                 formatter: OutputFormatter):
        self.config = config
        self.pg_manager = pg_manager
        self.formatter = formatter
    
    def setup_cluster(self, port_start: int):
        """Set up Spock cluster with cross-wired nodes."""
        self.formatter.success("Cross-wiring nodes", port=None, indent=0)
        node_dsns = {}
        for i in range(self.config.NUM_NODES):
            port = port_start + i
            node_name = f"n{i+1}"
            dsn = (f"host=localhost port={port} dbname={self.config.DB_NAME} "
                   f"user={self.config.DB_USER} password={self.config.DB_PASSWORD}")
            node_dsns[node_name] = dsn
            
            try:
                conn = self.pg_manager.connect(port)
                
                # Create extension
                try:
                    self.pg_manager.execute_sql(conn, "CREATE EXTENSION IF NOT EXISTS spock;")
                except Exception as e:
                    # If extension creation fails, provide helpful error message
                    error_msg = str(e)
                    if "could not load library" in error_msg.lower():
                        raise RuntimeError(f"Spock library cannot be loaded. This usually means: 1) Spock needs to be in shared_preload_libraries (but this causes startup failure due to compilation issue), or 2) The Spock library needs to be recompiled. Error: {error_msg[:100]}")
                    elif "extension" in error_msg.lower() and "does not exist" in error_msg.lower():
                        raise RuntimeError(f"Spock extension not found. The Spock library may not be installed or needs to be recompiled. Error: {error_msg[:100]}")
                    else:
                        raise RuntimeError(f"Failed to create Spock extension: {error_msg[:100]}")
                
                # Cleanup existing subscriptions and nodes
                cleanup_sql = f"""
                DO $$
                DECLARE sub RECORD;
                BEGIN
                    FOR sub IN
                        SELECT s.sub_name
                          FROM spock.subscription s
                          JOIN spock.node n ON n.node_id = s.sub_target
                         WHERE n.node_name = '{node_name}'
                    LOOP
                        PERFORM spock.sub_drop(sub.sub_name, true);
                    END LOOP;
                    
                    FOR sub IN
                        SELECT s.sub_name
                          FROM spock.subscription s
                          JOIN spock.node n ON n.node_id = s.sub_origin
                         WHERE n.node_name = '{node_name}'
                    LOOP
                        PERFORM spock.sub_drop(sub.sub_name, true);
                    END LOOP;
                END;
                $$;
                """
                self.pg_manager.execute_sql(conn, cleanup_sql)
                
                # Create node
                self.pg_manager.execute_sql(conn, f"SELECT spock.node_drop('{node_name}', true);")
                self.pg_manager.execute_sql(conn, f"SELECT spock.node_create('{node_name}', '{dsn}');")
                
                # Set Spock auto DDL settings using ALTER SYSTEM and reload
                try:
                    # Use ALTER SYSTEM to set the configuration parameters
                    self.pg_manager.execute_sql(conn, "ALTER SYSTEM SET spock.enable_ddl_replication = on;")
                    self.pg_manager.execute_sql(conn, "ALTER SYSTEM SET spock.include_ddl_repset = on;")
                    # Reload configuration to apply changes
                    self.pg_manager.execute_sql(conn, "SELECT pg_reload_conf();")
                except Exception as e:
                    # If ALTER SYSTEM fails, try SET as fallback
                    try:
                        self.pg_manager.execute_sql(conn, "SET spock.enable_ddl_replication = on;")
                        self.pg_manager.execute_sql(conn, "SET spock.include_ddl_repset = on;")
                    except Exception:
                        pass  # Settings may already be configured
                
                # Ensure ddl_sql replication set exists on this node
                try:
                    result = self.pg_manager.fetch_sql(conn, """
                        SELECT EXISTS (
                            SELECT 1 FROM spock.replication_set 
                            WHERE set_name = 'ddl_sql'
                        );
                    """)
                    if not (result and result[0][0]):
                        # Create ddl_sql replication set if it doesn't exist
                        self.pg_manager.execute_sql(conn, "SELECT spock.repset_create('ddl_sql', true, true, true, true);")
                except Exception:
                    pass  # Replication set might already exist or creation failed
                
                # Ensure default replication set exists and add all existing tables to it
                try:
                    # Add all tables in public schema to default replication set
                    self.pg_manager.execute_sql(conn, "SELECT spock.repset_add_all_tables('default', ARRAY['public'], false);")
                except Exception as e:
                    # If it fails, the replication set might not exist or tables might already be added
                    # Try to create default replication set if it doesn't exist
                    try:
                        self.pg_manager.execute_sql(conn, "SELECT spock.repset_create('default', true, true, true, true);")
                        # Try again to add all tables
                        try:
                            self.pg_manager.execute_sql(conn, "SELECT spock.repset_add_all_tables('default', ARRAY['public'], false);")
                        except Exception:
                            pass  # Tables might already be added or no tables exist yet
                    except Exception:
                        pass  # Replication set might already exist
                
                conn.close()
                self.formatter.success(f"Creating node {node_name}", port=port, indent=1)
            except Exception as e:
                error_msg = str(e)
                self.formatter.error(f"Creating node {node_name}: {error_msg}", port=port, indent=1)
                raise
        
        for i in range(self.config.NUM_NODES):
            local_port = port_start + i
            local_node_name = f"n{i+1}"
            
            try:
                conn = self.pg_manager.connect(local_port)
                
                for j in range(self.config.NUM_NODES):
                    if i == j:
                        continue
                    
                    remote_node_name = f"n{j+1}"
                    remote_dsn = node_dsns[remote_node_name]
                    sub_name = f"sub_{remote_node_name}_{local_node_name}"
                    
                    try:
                        # Drop subscription if exists
                        self.pg_manager.execute_sql(conn, f"SELECT spock.sub_drop('{sub_name}', true);")
                        
                        # Create subscription
                        # Note: sub_create will connect to the provider, so we need to ensure
                        # the provider is ready and accessible
                        sql = (f"SELECT spock.sub_create("
                               f"subscription_name := '{sub_name}', "
                               f"provider_dsn := '{remote_dsn}', "
                               f"replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'], "
                               f"synchronize_structure := false, "
                               f"synchronize_data := false, "
                               f"enabled := true"
                               f");")
                        self.pg_manager.execute_sql(conn, sql)
                        
                        # Ensure all replication sets are added to the subscription
                        try:
                            # Add default replication set if not already added
                            self.pg_manager.execute_sql(conn, f"SELECT spock.sub_add_repset('{sub_name}', 'default');")
                        except Exception:
                            pass  # Replication set might already be added
                        try:
                            # Add ddl_sql replication set if not already added
                            self.pg_manager.execute_sql(conn, f"SELECT spock.sub_add_repset('{sub_name}', 'ddl_sql');")
                        except Exception:
                            pass  # Replication set might already be added
                        
                        # Verify subscription is enabled and has ddl_sql replication set
                        try:
                            result = self.pg_manager.fetch_sql(conn, f"""
                                SELECT sub_enabled, sub_replication_sets 
                                FROM spock.subscription 
                                WHERE sub_name = '{sub_name}';
                            """)
                            if result:
                                enabled = result[0][0]
                                repsets = result[0][1] if result[0][1] else []
                                if not enabled:
                                    # Enable subscription if disabled
                                    self.pg_manager.execute_sql(conn, f"SELECT spock.sub_enable('{sub_name}');")
                                if 'ddl_sql' not in repsets:
                                    # Ensure ddl_sql is in replication sets
                                    self.pg_manager.execute_sql(conn, f"SELECT spock.sub_add_repset('{sub_name}', 'ddl_sql');")
                        except Exception:
                            pass  # Verification failed, but subscription was created
                        
                        self.formatter.success(f"Creating subscription {sub_name}", port=local_port, indent=1)
                        
                        # Wait a bit for subscription to start and check if it gets disabled
                        time.sleep(2)
                        try:
                            status_result = self.pg_manager.fetch_sql(conn, f"""
                                SELECT status FROM spock.sub_show_status('{sub_name}');
                            """)
                            if status_result and status_result[0][0] == 'disabled':
                                # Subscription got disabled immediately, likely due to old WAL data
                                # Get current LSN from provider and skip to it
                                provider_port = port_start + j
                                try:
                                    provider_conn = self.pg_manager.connect(provider_port)
                                    lsn_result = self.pg_manager.fetch_sql(provider_conn, "SELECT pg_current_wal_lsn();")
                                    provider_conn.close()
                                    
                                    if lsn_result and lsn_result[0][0]:
                                        current_lsn = lsn_result[0][0]
                                        self.pg_manager.execute_sql(conn, f"SELECT spock.sub_alter_skiplsn('{sub_name}', '{current_lsn}');")
                                        self.pg_manager.execute_sql(conn, f"SELECT spock.sub_enable('{sub_name}');")
                                        self.formatter.warning(f"Fixed disabled subscription {sub_name} by skipping problematic LSN", port=local_port, indent=2)
                                except Exception:
                                    pass  # Could not fix, will be caught later
                        except Exception:
                            pass  # Status check failed, continue
                    except Exception as e:
                        error_msg = str(e)
                        # Provide more context for connection errors
                        if "connection" in error_msg.lower() or "could not connect" in error_msg.lower():
                            # Extract the remote port from the DSN
                            remote_port = port_start + j
                            raise RuntimeError(f"Failed to connect to provider node {remote_node_name} (port {remote_port}) for subscription {sub_name}: {error_msg}")
                        self.formatter.error(f"Creating subscription {sub_name}: {error_msg}", port=local_port, indent=1)
                        raise
                
                conn.close()
            except Exception as e:
                self.formatter.error(f"Connecting to {local_node_name}: {e}", port=local_port, indent=1)
                raise
        
        # Diagnostic: Check subscription status and replication sets for n1 subscriptions
        # (Diagnostic checks run silently, not displayed in output)
        for i in range(self.config.NUM_NODES):
            local_port = port_start + i
            local_node_name = f"n{i+1}"
            
            try:
                conn = self.pg_manager.connect(local_port)
                
                # Check subscriptions from this node
                result = self.pg_manager.fetch_sql(conn, """
                    SELECT sub_name, sub_enabled, sub_replication_sets, 
                           (SELECT node_name FROM spock.node WHERE node_id = sub_origin) as provider_node
                    FROM spock.subscription
                    WHERE sub_name LIKE 'sub_n1_%';
                """)
                
                # Diagnostic checks (not displayed in output)
                if result:
                    for row in result:
                        sub_name, enabled, repsets, provider = row
                        repsets_str = ', '.join(repsets) if repsets else 'none'
                        status = "enabled" if enabled else "disabled"
                        # Diagnostic info - not displayed
                        # self.formatter.info(f"  {sub_name}: {status}, provider: {provider}, repsets: [{repsets_str}]", indent=1)
                
                # Check if ddl_sql replication set exists on this node
                result = self.pg_manager.fetch_sql(conn, """
                    SELECT set_name FROM spock.replication_set WHERE set_name = 'ddl_sql';
                """)
                ddl_sql_exists = result and len(result) > 0
                # Diagnostic info - not displayed
                # self.formatter.info(f"  ddl_sql replication set exists on {local_node_name}: {ddl_sql_exists}", indent=1)
                
                # Check DDL replication settings
                result = self.pg_manager.fetch_sql(conn, """
                    SELECT name, setting FROM pg_settings 
                    WHERE name IN ('spock.enable_ddl_replication', 'spock.include_ddl_repset');
                """)
                if result:
                    for row in result:
                        setting_name, setting_value = row
                        # Diagnostic info - not displayed
                        # self.formatter.info(f"  {setting_name} = {setting_value}", indent=1)
                
                conn.close()
            except Exception as e:
                self.formatter.warning(f"Diagnostic check failed for {local_node_name}: {e}", port=local_port, indent=1)
    
    def verify_replication(self, port_start: int) -> bool:
        """Verify replication is working from all nodes."""
        self.formatter.success("Verifying Cross-wiring nodes", port=None, indent=0)
        
        # First, verify subscriptions from n1 are active before creating table
        for i in range(1, self.config.NUM_NODES):  # Check n2 and n3
            port = port_start + i
            node_name = f"n{i+1}"
            sub_name = f"sub_n1_{node_name}"
            
            try:
                conn = self.pg_manager.connect(port)
                result = self.pg_manager.fetch_sql(conn, f"""
                    SELECT status FROM spock.sub_show_status('{sub_name}');
                """)
                conn.close()
                
                if result:
                    status = result[0][0]
                    if status != 'replicating':
                        self.formatter.error(f"Subscription {sub_name} is {status}, not replicating - cannot proceed", port=port, indent=1)
                        return False
            except Exception as e:
                self.formatter.error(f"Could not check subscription {sub_name} status: {e}", port=port, indent=1)
                return False
        
        # Step 1: Create test table on n1 and verify it exists on n2 and n3
        test_table = "cluster_test"
        
        try:
            # Create table on n1 (port_start)
            conn = self.pg_manager.connect(port_start)
            # Drop table if exists (CASCADE to handle dependencies)
            try:
                self.pg_manager.execute_sql(conn, f"DROP TABLE IF EXISTS {test_table} CASCADE;")
            except Exception:
                pass  # Ignore errors when dropping
            
            # Remove from replication set if it exists
            try:
                self.pg_manager.execute_sql(conn, f"SELECT spock.repset_remove_table('default', '{test_table}');")
            except Exception:
                pass  # Ignore if not in replication set
            
            # Create table on n1
            self.pg_manager.execute_sql(conn, f"""
                CREATE TABLE {test_table} (
                    id SERIAL PRIMARY KEY,
                    node_name TEXT,
                    test_data TEXT,
                    created_at TIMESTAMPTZ DEFAULT now()
                );
            """)
            conn.close()
            self.formatter.success(f"Creating test table on n1", port=port_start, indent=1)
        except Exception as e:
            error_msg = str(e)
            self.formatter.error(f"Creating test table on n1: {error_msg}", port=port_start, indent=1)
            return False
        
        # Check if subscriptions got disabled after table creation
        for i in range(1, self.config.NUM_NODES):
            port = port_start + i
            node_name = f"n{i+1}"
            sub_name = f"sub_n1_{node_name}"
            
            try:
                conn = self.pg_manager.connect(port)
                result = self.pg_manager.fetch_sql(conn, f"""
                    SELECT status FROM spock.sub_show_status('{sub_name}');
                """)
                conn.close()
                
                if result:
                    status = result[0][0]
                    if status == 'disabled':
                        # Check logs for why it got disabled
                        self.formatter.error(f"Subscription {sub_name} got disabled after table creation - DDL replication failed", port=port, indent=1)
                        # Try to get more info from subscription
                        try:
                            conn = self.pg_manager.connect(port)
                            slot_result = self.pg_manager.fetch_sql(conn, f"""
                                SELECT slot_name, active, restart_lsn, confirmed_flush_lsn 
                                FROM pg_replication_slots 
                                WHERE slot_name = (SELECT slot_name FROM spock.subscription WHERE sub_name = '{sub_name}');
                            """)
                            conn.close()
                            if slot_result:
                                slot_name, active, restart_lsn, confirmed_lsn = slot_result[0]
                                self.formatter.info(f"  Slot {slot_name}: active={active}, restart_lsn={restart_lsn}, confirmed_lsn={confirmed_lsn}", indent=2)
                        except Exception:
                            pass
                        return False
            except Exception:
                pass
        
        # Wait for DDL replication and verify table exists on n2 and n3
        time.sleep(5)  # Initial wait for DDL replication
        
        # Verify table exists on n2 and n3 (not n1, we just created it there)
        for i in range(1, self.config.NUM_NODES):  # Start from n2 (index 1)
            port = port_start + i
            node_name = f"n{i+1}"
            max_retries = 30
            table_exists = False
            
            for retry in range(max_retries):
                try:
                    conn = self.pg_manager.connect(port)
                    result = self.pg_manager.fetch_sql(conn, f"""
                        SELECT EXISTS (
                            SELECT 1 FROM information_schema.tables 
                            WHERE table_schema = 'public' 
                            AND table_name = '{test_table}'
                        );
                    """)
                    conn.close()
                    if result and result[0][0]:
                        table_exists = True
                        break
                except Exception:
                    pass
                
                if retry < max_retries - 1:
                    wait_time = 1 if retry < 10 else 2
                    time.sleep(wait_time)
            
            if not table_exists:
                self.formatter.error(f"Table {test_table} not found on {node_name} after DDL replication - DDL replication failed", port=port, indent=1)
                return False
            else:
                self.formatter.success(f"Table {test_table} found on {node_name}", port=port, indent=1)
        
        # Step 2: Insert test data on each node
        # Use explicit IDs to avoid sequence conflicts when data replicates
        for i in range(self.config.NUM_NODES):
            port = port_start + i
            node_name = f"n{i+1}"
            # Use node number as base ID to avoid conflicts
            explicit_id = i + 1
            
            try:
                conn = self.pg_manager.connect(port)
                sql = f"INSERT INTO {test_table}(id, node_name, test_data) VALUES ({explicit_id}, '{node_name}', 'test-data-from-{node_name}');"
                self.pg_manager.execute_sql(conn, sql)
                conn.close()
                self.formatter.success(f"Inserting test data", port=port, indent=1)
                # Small delay between inserts to allow replication to process
                if i < self.config.NUM_NODES - 1:
                    time.sleep(2)
            except Exception as e:
                error_msg = str(e)
                # If it's a duplicate key error, the data might have already replicated
                if "duplicate key" in error_msg.lower() or "already exists" in error_msg.lower():
                    self.formatter.warning(f"Insert failed (duplicate key) - data may have already replicated: {error_msg[:60]}", port=port, indent=1)
                    # Continue - this is actually a good sign that replication is working
                else:
                    # Error message from execute_sql already includes SQL command and error
                    self.formatter.error(f"Inserting test data: {error_msg}", port=port, indent=1)
                return False
        
        # Wait for replication
        time.sleep(10)
        
        # Sub-step 3: Verify data on all nodes
        all_ok = True
        for i in range(self.config.NUM_NODES):
            port = port_start + i
            node_name = f"n{i+1}"
            
            try:
                conn = self.pg_manager.connect(port)
                result = self.pg_manager.fetch_sql(conn, f"SELECT COUNT(*) FROM {test_table};")
                count = result[0][0] if result else 0
                conn.close()
                
                expected_count = self.config.NUM_NODES
                if count == expected_count:
                    self.formatter.success(f"Verifying data: {count} rows", port=port, indent=1)
                else:
                    self.formatter.warning(f"Verifying data: {count} rows (expected {expected_count})", port=port, indent=1)
                    all_ok = False
            except Exception as e:
                self.formatter.error(f"Verifying data: {e}", port=port, indent=1)
                all_ok = False
        
        # Sub-step 4: Check subscription status
        for i in range(self.config.NUM_NODES):
            port = port_start + i
            node_name = f"n{i+1}"
            
            try:
                conn = self.pg_manager.connect(port)
                result = self.pg_manager.fetch_sql(conn, """
                    SELECT subscription_name, status, provider_node
                    FROM spock.sub_show_status()
                    ORDER BY subscription_name;
                """)
                conn.close()
                
                if result:
                    for row in result:
                        sub_name, status, provider = row
                        if status == 'replicating':
                            self.formatter.success(f"Subscription {sub_name} -> {provider} ({status})", port=port, indent=1)
                        else:
                            self.formatter.warning(f"Subscription {sub_name} -> {provider} ({status})", port=port, indent=1)
                            all_ok = False
            except Exception as e:
                self.formatter.error(f"Checking subscription status: {e}", port=port, indent=1)
                all_ok = False
        
        return all_ok
    
    def show_logs(self, port_start: int, num_lines: int = 50):
        """Show recent log entries from all nodes for debugging replication issues."""
        print(f"\n{'='*80}")
        print(f"PostgreSQL Log Files (last {num_lines} lines per node):")
        print(f"{'='*80}\n")
        
        for i in range(self.config.NUM_NODES):
            port = port_start + i
            node_name = f"n{i+1}"
            # Find datadir - it should be in pgdata_path
            datadir = self.pg_manager.pgdata_path / node_name
            log_file = datadir / "postgresql.log"
            
            print(f"\n--- Node {node_name} (Port {port}) ---")
            print(f"Log file: {log_file}")
            
            if log_file.exists():
                try:
                    with open(log_file, 'r') as f:
                        lines = f.readlines()
                        # Show last num_lines
                        recent_lines = lines[-num_lines:] if len(lines) > num_lines else lines
                        # Filter for replication-related or error messages
                        relevant_lines = [l for l in recent_lines if any(
                            keyword in l.lower() for keyword in [
                                'replication', 'spock', 'subscription', 'error', 'fatal', 
                                'warning', 'repset', 'apply', 'worker'
                            ]
                        )]
                        if relevant_lines:
                            print("Relevant log entries:")
                            for line in relevant_lines[-20:]:  # Show last 20 relevant lines
                                print(f"  {line.rstrip()}")
                        else:
                            print("No replication-related entries in recent logs.")
                            print("Last 10 lines:")
                            for line in recent_lines[-10:]:
                                print(f"  {line.rstrip()}")
                except Exception as e:
                    print(f"Error reading log file: {e}")
            else:
                print("Log file not found.")
        
        print(f"\n{'='*80}\n")


# ============================================================================
# Cleanup Manager
# ============================================================================

class CleanupManager:
    """Manages cleanup of cluster resources."""
    
    def __init__(self, config: ClusterConfig, pg_manager: PostgresManager,
                 formatter: OutputFormatter):
        self.config = config
        self.pg_manager = pg_manager
        self.formatter = formatter
        self.processes: List[Tuple[subprocess.Popen, Optional[int]]] = []  # (process, port)
        self.datadirs: List[Tuple[Path, Optional[int]]] = []  # (datadir, port)
    
    def register_process(self, process: subprocess.Popen, port: Optional[int] = None):
        """Register a process for cleanup."""
        self.processes.append((process, port))
    
    def register_datadir(self, datadir: Path, port: Optional[int] = None):
        """Register a datadir for cleanup."""
        self.datadirs.append((datadir, port))
    
    def cleanup(self):
        """Clean up all resources."""
        self.formatter.success("Cleaning Up", port=None, indent=0)
        
        # Stop PostgreSQL processes
        for process, port in self.processes:
            try:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                    self.formatter.success(f"Stopped PostgreSQL process (PID: {process.pid})", port=port, indent=1)
            except Exception as e:
                self.formatter.warning(f"Failed to stop process: {e}", port=port, indent=1)
                try:
                    process.kill()
                except:
                    pass
        
        # Remove datadirs
        for datadir, port in self.datadirs:
            try:
                if datadir.exists():
                    shutil.rmtree(datadir)
                    self.formatter.success(f"Removed datadir: {datadir.name}", port=port, indent=1)
            except Exception as e:
                self.formatter.warning(f"Failed to remove {datadir.name}: {e}", port=port, indent=1)
        
        self.formatter.success("Cleanup completed", port=None, indent=0)


# ============================================================================
# Crash Scenario
# ============================================================================

def _run_crash_scenario(pg_manager, spock_setup, config, formatter, port_start, processes, verbose):
    """Generate data on n1, monitor lag_tracker, and crash n1 when n2 LSN > n3 LSN."""
    formatter.success("Running crash scenario", port=None, indent=0)
    
    port_n1 = port_start
    port_n2 = port_start + 1
    port_n3 = port_start + 2
    
    try:
        # Create test table on n1 if it doesn't exist
        conn_n1 = pg_manager.connect(port_n1)
        pg_manager.execute_sql(conn_n1, """
            CREATE TABLE IF NOT EXISTS crash_test (
                id SERIAL PRIMARY KEY,
                data TEXT,
                created_at TIMESTAMP DEFAULT NOW()
            );
        """)
        try:
            pg_manager.execute_sql(conn_n1, """
                SELECT spock.repset_add_table('default', 'crash_test');
            """)
        except Exception:
            pass  # Table may already be in replication set
        conn_n1.close()
        formatter.success("Created test table on n1", port=port_n1, indent=1)
        
        # Step 1: Insert some initial data
        formatter.success("Inserting initial data on n1", port=port_n1, indent=1)
        conn_n1 = pg_manager.connect(port_n1)
        for i in range(20):
            pg_manager.execute_sql(conn_n1, 
                f"INSERT INTO crash_test (data) VALUES ('initial_data_{i}');")
        conn_n1.close()
        time.sleep(3)  # Wait for replication
        
        # Check initial LSNs to see which node is ahead
        conn_n2 = pg_manager.connect(port_n2)
        lag_n2_init = pg_manager.fetch_sql(conn_n2, """
            SELECT commit_lsn FROM spock.lag_tracker
            WHERE origin_name = 'n1' AND receiver_name = 'n2';
        """)
        conn_n2.close()
        
        conn_n3 = pg_manager.connect(port_n3)
        lag_n3_init = pg_manager.fetch_sql(conn_n3, """
            SELECT commit_lsn FROM spock.lag_tracker
            WHERE origin_name = 'n1' AND receiver_name = 'n3';
        """)
        conn_n3.close()
        
        n2_lsn_init = lag_n2_init[0][0] if lag_n2_init and lag_n2_init[0] and lag_n2_init[0][0] else None
        n3_lsn_init = lag_n3_init[0][0] if lag_n3_init and lag_n3_init[0] and lag_n3_init[0][0] else None
        
        if verbose:
            formatter.info(f"Initial LSNs: n2={n2_lsn_init}, n3={n3_lsn_init}", port=None, indent=1)
        
        # If n3 is ahead, we need to wait for n2 to catch up or generate more data
        if n2_lsn_init and n3_lsn_init:
            try:
                conn_n2 = pg_manager.connect(port_n2)
                n3_ahead = pg_manager.fetch_sql(conn_n2, 
                    f"SELECT '{n3_lsn_init}'::pg_lsn > '{n2_lsn_init}'::pg_lsn;")
                conn_n2.close()
                
                if n3_ahead and n3_ahead[0] and n3_ahead[0][0]:
                    formatter.success("n3 is ahead of n2, generating more data to let n2 catch up", port=None, indent=1)
                    # Generate more data until n2 catches up
                    catchup_batch_size = 10
                    for catchup_iter in range(100):
                        conn_n1 = pg_manager.connect(port_n1)
                        for i in range(catchup_batch_size):
                            pg_manager.execute_sql(conn_n1, 
                                f"INSERT INTO crash_test (data) VALUES ('catchup_data_{catchup_iter}_row_{i}');")
                        conn_n1.close()
                        time.sleep(0.5)
                        
                        # Check if n2 caught up
                        conn_n2 = pg_manager.connect(port_n2)
                        lag_n2_check = pg_manager.fetch_sql(conn_n2, """
                            SELECT commit_lsn FROM spock.lag_tracker
                            WHERE origin_name = 'n1' AND receiver_name = 'n2';
                        """)
                        conn_n2.close()
                        n2_lsn_check = lag_n2_check[0][0] if lag_n2_check and lag_n2_check[0] and lag_n2_check[0][0] else None
                        
                        if n2_lsn_check:
                            conn_n2 = pg_manager.connect(port_n2)
                            n2_ahead_now = pg_manager.fetch_sql(conn_n2, 
                                f"SELECT '{n2_lsn_check}'::pg_lsn > '{n3_lsn_init}'::pg_lsn;")
                            conn_n2.close()
                            
                            if n2_ahead_now and n2_ahead_now[0] and n2_ahead_now[0][0]:
                                if verbose:
                                    formatter.info(f"n2 caught up: n2 LSN={n2_lsn_check} > n3 LSN={n3_lsn_init}", port=None, indent=2)
                                break
            except Exception as e:
                if verbose:
                    formatter.warning(f"Error checking initial LSNs: {e}", port=None, indent=1)
        
        # Step 2: Disable n3's subscription from n1 to create lag
        formatter.success("Disabling n3 subscription from n1 to create lag", port=port_n3, indent=1)
        conn_n3 = pg_manager.connect(port_n3)
        sub_n3_name = None
        try:
            # Find subscription name from n1 to n3
            sub_result = pg_manager.fetch_sql(conn_n3, """
                SELECT s.sub_name
                FROM spock.subscription s
                JOIN spock.node o ON o.node_id = s.sub_origin
                JOIN spock.node t ON t.node_id = s.sub_target
                WHERE o.node_name = 'n1' AND t.node_name = 'n3';
            """)
            if sub_result and sub_result[0]:
                sub_n3_name = sub_result[0][0]
                pg_manager.execute_sql(conn_n3, f"SELECT spock.sub_disable('{sub_n3_name}');")
                formatter.success(f"Disabled subscription {sub_n3_name} on n3", port=port_n3, indent=2)
            else:
                formatter.warning("Could not find subscription from n1 to n3", port=port_n3, indent=2)
        except Exception as e:
            formatter.warning(f"Could not disable n3 subscription: {e}", port=port_n3, indent=2)
        conn_n3.close()
        
        # Wait a moment for the disable to take effect
        time.sleep(2)
        
        # Step 3: Generate data (n2 receives it, n3 doesn't)
        formatter.success("Generating data on n1 (n2 receives, n3 doesn't)", port=None, indent=1)
        
        batch_size = 10
        max_iterations = 500
        n1_process = processes[0] if processes and len(processes) > 0 else None
        n2_lsn_saved = None
        n3_lsn_saved = None
        
        # First monitoring phase: until n2 LSN > n3 LSN
        for iteration in range(max_iterations):
            # Insert data on n1
            conn_n1 = pg_manager.connect(port_n1)
            for i in range(batch_size):
                pg_manager.execute_sql(conn_n1, 
                    f"INSERT INTO crash_test (data) VALUES ('batch_{iteration}_row_{i}');")
            conn_n1.close()
            
            # Check lag_tracker on n2 and n3
            conn_n2 = pg_manager.connect(port_n2)
            lag_n2 = pg_manager.fetch_sql(conn_n2, """
                SELECT commit_lsn FROM spock.lag_tracker
                WHERE origin_name = 'n1' AND receiver_name = 'n2';
            """)
            conn_n2.close()
            
            conn_n3 = pg_manager.connect(port_n3)
            lag_n3 = pg_manager.fetch_sql(conn_n3, """
                SELECT commit_lsn FROM spock.lag_tracker
                WHERE origin_name = 'n1' AND receiver_name = 'n3';
            """)
            conn_n3.close()
            
            n2_lsn = lag_n2[0][0] if lag_n2 and lag_n2[0] and lag_n2[0][0] else None
            n3_lsn = lag_n3[0][0] if lag_n3 and lag_n3[0] and lag_n3[0][0] else None
            
            if verbose and iteration % 10 == 0:
                formatter.info(f"Iteration {iteration}: n2 LSN={n2_lsn}, n3 LSN={n3_lsn}", 
                             port=None, indent=2)
            
            # Check if n2 LSN > n3 LSN (both must be valid)
            if n2_lsn and n3_lsn:
                # Compare LSNs - use PostgreSQL's LSN comparison
                try:
                    conn_n2 = pg_manager.connect(port_n2)
                    comparison = pg_manager.fetch_sql(conn_n2, 
                        f"SELECT '{n2_lsn}'::pg_lsn > '{n3_lsn}'::pg_lsn;")
                    conn_n2.close()
                    
                    if comparison and comparison[0] and comparison[0][0]:
                        formatter.success(
                            f"n2 LSN ({n2_lsn}) > n3 LSN ({n3_lsn}) - first lag achieved",
                            port=None, indent=1
                        )
                        # Save the LSN values for later comparison
                        n2_lsn_saved = n2_lsn
                        n3_lsn_saved = n3_lsn
                        break
                except Exception as e:
                    if verbose:
                        formatter.warning(f"Error comparing LSNs: {e}", port=None, indent=2)
            
            time.sleep(0.1)  # Small delay between batches
        
        # Step 4: Enable/disable subscriptions to create more lag
        formatter.success("Enabling n3, then disabling n2 to create more lag", port=None, indent=1)
        
        # Enable n3 subscription
        if sub_n3_name:
            conn_n3 = pg_manager.connect(port_n3)
            try:
                pg_manager.execute_sql(conn_n3, f"SELECT spock.sub_enable('{sub_n3_name}');")
                formatter.success(f"Enabled subscription {sub_n3_name} on n3", port=port_n3, indent=2)
            except Exception as e:
                formatter.warning(f"Could not enable n3 subscription: {e}", port=port_n3, indent=2)
            conn_n3.close()
            time.sleep(2)
        
        # Disable n2 subscription
        conn_n2 = pg_manager.connect(port_n2)
        sub_n2_name = None
        try:
            sub_result = pg_manager.fetch_sql(conn_n2, """
                SELECT s.sub_name
                FROM spock.subscription s
                JOIN spock.node o ON o.node_id = s.sub_origin
                JOIN spock.node t ON t.node_id = s.sub_target
                WHERE o.node_name = 'n1' AND t.node_name = 'n2';
            """)
            if sub_result and sub_result[0]:
                sub_n2_name = sub_result[0][0]
                pg_manager.execute_sql(conn_n2, f"SELECT spock.sub_disable('{sub_n2_name}');")
                formatter.success(f"Disabled subscription {sub_n2_name} on n2", port=port_n2, indent=2)
            else:
                formatter.warning("Could not find subscription from n1 to n2", port=port_n2, indent=2)
        except Exception as e:
            formatter.warning(f"Could not disable n2 subscription: {e}", port=port_n2, indent=2)
        conn_n2.close()
        time.sleep(2)
        
        # Step 5: Generate more data and monitor - check current LSNs
        # Note: n2 is disabled so its LSN won't advance, n3 is enabled so it will catch up
        # We want to crash when n2 was ahead (saved LSN) or immediately when we detect n2 > n3
        formatter.success("Generating more data and monitoring - n2 was ahead, will crash when confirmed", port=None, indent=1)
        
        # Use saved n2 LSN from phase 1 (when n2 was ahead)
        if not n2_lsn_saved:
            formatter.warning("n2_lsn_saved not set, using current n2 LSN", port=None, indent=1)
            conn_n2 = pg_manager.connect(port_n2)
            lag_n2 = pg_manager.fetch_sql(conn_n2, """
                SELECT commit_lsn FROM spock.lag_tracker
                WHERE origin_name = 'n1' AND receiver_name = 'n2';
            """)
            conn_n2.close()
            n2_lsn_saved = lag_n2[0][0] if lag_n2 and lag_n2[0] and lag_n2[0][0] else None
        
        # Generate a few batches and check - crash immediately since n2 was ahead
        for iteration in range(20):
            # Insert data on n1
            conn_n1 = pg_manager.connect(port_n1)
            for i in range(batch_size):
                pg_manager.execute_sql(conn_n1, 
                    f"INSERT INTO crash_test (data) VALUES ('phase2_batch_{iteration}_row_{i}');")
            conn_n1.close()
            time.sleep(0.2)
            
            # Check current n3 LSN
            conn_n3 = pg_manager.connect(port_n3)
            lag_n3 = pg_manager.fetch_sql(conn_n3, """
                SELECT commit_lsn FROM spock.lag_tracker
                WHERE origin_name = 'n1' AND receiver_name = 'n3';
            """)
            conn_n3.close()
            
            n3_lsn = lag_n3[0][0] if lag_n3 and lag_n3[0] and lag_n3[0][0] else None
            
            if verbose and iteration % 5 == 0:
                formatter.info(f"Phase 2 Iteration {iteration}: n2 LSN (saved)={n2_lsn_saved}, n3 LSN={n3_lsn}", 
                             port=None, indent=2)
            
            # Check if saved n2 LSN > current n3 LSN (n2 was ahead)
            if n2_lsn_saved and n3_lsn:
                # Compare LSNs - use PostgreSQL's LSN comparison
                try:
                    conn_n2 = pg_manager.connect(port_n2)
                    comparison = pg_manager.fetch_sql(conn_n2, 
                        f"SELECT '{n2_lsn_saved}'::pg_lsn > '{n3_lsn}'::pg_lsn;")
                    conn_n2.close()
                    
                    if comparison and comparison[0] and comparison[0][0]:
                        # Verify subscriptions are enabled before crashing
                        try:
                            conn_n2_check = pg_manager.connect(port_n2)
                            sub_status = pg_manager.fetch_sql(conn_n2_check, 
                                "SELECT sub_name, sub_enabled FROM spock.subscription WHERE sub_name LIKE '%n1%' ORDER BY sub_name;")
                            conn_n2_check.close()
                            
                            if sub_status:
                                for sub_row in sub_status:
                                    sub_name, sub_enabled = sub_row
                                    if not sub_enabled:
                                        formatter.warning(
                                            f"Subscription {sub_name} is disabled - enabling before crash",
                                            port=port_n2, indent=1
                                        )
                                        conn_n2_enable = pg_manager.connect(port_n2)
                                        pg_manager.execute_sql(conn_n2_enable, 
                                            f"UPDATE spock.subscription SET sub_enabled = true WHERE sub_name = '{sub_name}';")
                                        conn_n2_enable.close()
                        except Exception as e:
                            if verbose:
                                formatter.warning(f"Could not check/enable subscriptions: {e}", port=port_n2, indent=1)
                        
                        formatter.success(
                            f"n2 LSN ({n2_lsn_saved}) > n3 LSN ({n3_lsn}) - crashing n1",
                            port=None, indent=1
                        )
                        # Step 6: Crash n1
                        if n1_process:
                            n1_process.terminate()
                            time.sleep(1)
                            if n1_process.poll() is None:
                                n1_process.kill()
                        else:
                            # Try to find and kill by port
                            import signal
                            try:
                                result = subprocess.run(
                                    ['lsof', '-ti', f':{port_n1}'],
                                    capture_output=True, text=True
                                )
                                if result.returncode == 0 and result.stdout.strip():
                                    pid = int(result.stdout.strip().split('\n')[0])
                                    os.kill(pid, signal.SIGTERM)
                                    time.sleep(1)
                                    try:
                                        os.kill(pid, signal.SIGKILL)
                                    except ProcessLookupError:
                                        pass
                            except Exception as e:
                                formatter.warning(f"Could not kill n1 process: {e}", port=port_n1, indent=1)
                        
                        formatter.success(
                            "n1 crashed. n2 has transactions that n3 missed. "
                            "Run recovery.sql manually to fix.",
                            port=None, indent=1
                        )
                        return
                    else:
                        # n3 caught up or passed n2, but n2 was ahead before, so crash anyway
                        if iteration >= 5:  # Give n3 a few iterations to process
                            # Verify subscriptions are enabled before crashing
                            try:
                                conn_n2_check = pg_manager.connect(port_n2)
                                sub_status = pg_manager.fetch_sql(conn_n2_check, 
                                    "SELECT sub_name, sub_enabled FROM spock.subscription WHERE sub_name LIKE '%n1%' ORDER BY sub_name;")
                                conn_n2_check.close()
                                
                                if sub_status:
                                    for sub_row in sub_status:
                                        sub_name, sub_enabled = sub_row
                                        if not sub_enabled:
                                            formatter.warning(
                                                f"Subscription {sub_name} is disabled - enabling before crash",
                                                port=port_n2, indent=1
                                            )
                                            conn_n2_enable = pg_manager.connect(port_n2)
                                            pg_manager.execute_sql(conn_n2_enable, 
                                                f"UPDATE spock.subscription SET sub_enabled = true WHERE sub_name = '{sub_name}';")
                                            conn_n2_enable.close()
                            except Exception as e:
                                if verbose:
                                    formatter.warning(f"Could not check/enable subscriptions: {e}", port=port_n2, indent=1)
                            
                            formatter.success(
                                f"n2 was ahead (LSN {n2_lsn_saved}), n3 current LSN ({n3_lsn}) - crashing n1",
                                port=None, indent=1
                            )
                            # Step 6: Crash n1
                            if n1_process:
                                n1_process.terminate()
                                time.sleep(1)
                                if n1_process.poll() is None:
                                    n1_process.kill()
                            else:
                                # Try to find and kill by port
                                import signal
                                try:
                                    result = subprocess.run(
                                        ['lsof', '-ti', f':{port_n1}'],
                                        capture_output=True, text=True
                                    )
                                    if result.returncode == 0 and result.stdout.strip():
                                        pid = int(result.stdout.strip().split('\n')[0])
                                        os.kill(pid, signal.SIGTERM)
                                        time.sleep(1)
                                        try:
                                            os.kill(pid, signal.SIGKILL)
                                        except ProcessLookupError:
                                            pass
                                except Exception as e:
                                    formatter.warning(f"Could not kill n1 process: {e}", port=port_n1, indent=1)
                            
                            formatter.success(
                                "n1 crashed. n2 has transactions that n3 missed. "
                                "Run recovery.sql manually to fix.",
                                port=None, indent=1
                            )
                            return
                except Exception as e:
                    if verbose:
                        formatter.warning(f"Error comparing LSNs: {e}", port=None, indent=2)
        
        formatter.warning(
            "Max iterations reached. n2 LSN never exceeded n3 LSN. "
            "n3 may be caught up or replication may be too fast.",
            port=None, indent=1
        )
        
    except Exception as e:
        formatter.error(f"Crash scenario failed: {e}", port=None, indent=1)
        if verbose:
            import traceback
            traceback.print_exc()
        raise


# ============================================================================
# Main Application
# ============================================================================

def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Create and verify a three-node Spock cluster',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument('--pgdata', type=str, default=None,
                       help='Path to PGDATA directory (will create subdirectories n1, n2, n3). Default: ~/data/spock-cluster')
    parser.add_argument('--postgres', type=str, default=None,
                       help='Path to PostgreSQL installation directory (optional, will search PATH if not provided)')
    parser.add_argument('--port-start', type=int, default=5451,
                       help='Starting port for node 1 (default: 5451)')
    parser.add_argument('-v', '--verbose', action='store_true',
                       help='Enable verbose output (v1: detailed with timestamps)')
    parser.add_argument('--quiet', action='store_true',
                       help='Disable verbose output (v0: statement only) [default]')
    parser.add_argument('--no-color', action='store_true',
                       help='Disable colored output')
    parser.add_argument('--crash', action='store_true',
                       help='Generate data on n1, monitor lag_tracker, and crash n1 when n2 LSN > n3 LSN')
    
    args = parser.parse_args()
    
    # Set default pgdata if not provided (use system user's home)
    if args.pgdata is None:
        user_home = os.path.expanduser("~")
        args.pgdata = os.path.join(user_home, "data", "spock-cluster")
    
    # Handle verbose/quiet flags (quiet is default, verbose overrides)
    verbose = args.verbose  # Default to quiet (v0) unless -v/--verbose is specified
    
    # Disable colors if requested
    if args.no_color:
        Colors.disable()
    
    # Initialize components
    config = ClusterConfig()
    formatter = OutputFormatter(verbose=verbose)
    cleanup_manager = CleanupManager(config, None, formatter)
    
    try:
        pg_manager = PostgresManager(config, formatter, args.pgdata, args.postgres)
        cleanup_manager.pg_manager = pg_manager
        spock_setup = SpockSetup(config, pg_manager, formatter)
        
        # Get system information for banner
        os_info = f"{platform.system()} {platform.release()}"
        pg_bin = pg_manager._find_postgres_binary()
        pg_version_cmd = [str(pg_bin / "postgres"), "--version"]
        try:
            pg_version_result = subprocess.run(pg_version_cmd, capture_output=True, text=True, timeout=5)
            pg_version = pg_version_result.stdout.strip() if pg_version_result.returncode == 0 else "Unknown"
        except Exception:
            pg_version = "Unknown"
        
        # Try to get Spock version from header file
        spock_version = "Unknown"
        spock_header = Path(__file__).parent.parent.parent / "include" / "spock.h"
        if spock_header.exists():
            try:
                with open(spock_header, 'r') as f:
                    for line in f:
                        if 'SPOCK_VERSION' in line and '"' in line:
                            # Extract version from #define SPOCK_VERSION "6.0.0-devel"
                            import re
                            match = re.search(r'"([^"]+)"', line)
                            if match:
                                spock_version = match.group(1)
                            break
            except Exception:
                pass
        
        # Print initial banner
        formatter.print_banner(os_info, pg_version, str(pg_bin), spock_version)
        
        # Handle --crash option: generate data and crash n1 when n2 LSN > n3 LSN
        # This skips all initialization and assumes cluster is already running
        if args.crash:
            formatter.success("Crash scenario mode - assuming cluster is already running", port=None, indent=0)
            # Verify nodes are running
            for i in range(config.NUM_NODES):
                port = args.port_start + i
                try:
                    test_conn = pg_manager.connect(port)
                    test_conn.close()
                except Exception as e:
                    formatter.error(f"Node on port {port} is not running: {e}", port=port, indent=1)
                    raise RuntimeError(f"Cluster must be running for --crash option. Node on port {port} is not accessible.")
            
            # Get process list (empty for crash mode since we don't manage them)
            processes = []
            _run_crash_scenario(pg_manager, spock_setup, config, formatter, args.port_start, processes, args.verbose)
            return
        
        # Step 0: Clean up any existing PostgreSQL processes on our ports
        formatter.success("Checking for existing processes", port=None, indent=0)
        for i in range(config.NUM_NODES):
            port = args.port_start + i
            port_in_use = False
            
            # Check if port is in use using multiple methods
            # Method 1: Try to connect
            try:
                test_conn = psycopg2.connect(
                    host="localhost",
                    port=port,
                    user=config.DB_USER,
                    password=config.DB_PASSWORD,
                    database="postgres",
                    connect_timeout=1
                )
                test_conn.close()
                port_in_use = True
            except psycopg2.OperationalError:
                # Try other methods to check port
                pass
            
            # Method 2: Use lsof if available
            if not port_in_use:
                try:
                    result = subprocess.run(
                        ["lsof", "-ti", f":{port}"],
                        capture_output=True,
                        timeout=2
                    )
                    if result.returncode == 0 and result.stdout.strip():
                        port_in_use = True
                except (FileNotFoundError, subprocess.TimeoutExpired):
                    pass
            
            # Method 3: Use ss if available
            if not port_in_use:
                try:
                    result = subprocess.run(
                        ["ss", "-tlnp"],
                        capture_output=True,
                        timeout=2,
                        text=True
                    )
                    if result.returncode == 0 and f":{port} " in result.stdout:
                        port_in_use = True
                except (FileNotFoundError, subprocess.TimeoutExpired):
                    pass
            
            # If port is in use, try to kill the process
            if port_in_use:
                formatter.warning(f"Port {port} is in use, attempting to stop existing process", port=port, indent=1)
                # Try multiple methods to kill the process
                killed = False
                
                # Method 1: Use lsof to find PID and kill
                try:
                    result = subprocess.run(
                        ["lsof", "-ti", f":{port}"],
                        capture_output=True,
                        timeout=2,
                        text=True
                    )
                    if result.returncode == 0:
                        pids = result.stdout.strip().split('\n')
                        for pid in pids:
                            if pid:
                                try:
                                    subprocess.run(["kill", "-TERM", pid], timeout=2, capture_output=True)
                                    killed = True
                                except:
                                    pass
                except (FileNotFoundError, subprocess.TimeoutExpired):
                    pass
                
                # Method 2: Use fuser if available
                if not killed:
                    try:
                        subprocess.run(
                            ["fuser", "-k", f"{port}/tcp"],
                            capture_output=True,
                            timeout=5
                        )
                        killed = True
                    except (FileNotFoundError, subprocess.TimeoutExpired):
                        pass
                
                # Wait for process to stop
                if killed:
                    time.sleep(2)
                    # Verify port is now free
                    for verify_attempt in range(5):
                        try:
                            test_conn = psycopg2.connect(
                                host="localhost",
                                port=port,
                                user=config.DB_USER,
                                password=config.DB_PASSWORD,
                                database="postgres",
                                connect_timeout=1
                            )
                            test_conn.close()
                            time.sleep(1)  # Still in use, wait more
                        except psycopg2.OperationalError:
                            break  # Port is free
        
        # Step 1: Initialize databases
        formatter.success("Creating Cluster", port=None, indent=0)
        datadirs = []
        for i in range(config.NUM_NODES):
            node_name = f"n{i+1}"
            port = args.port_start + i
            try:
                datadir = pg_manager.initdb(node_name, port)
                datadirs.append(datadir)
                cleanup_manager.register_datadir(datadir, port)
                formatter.success(f"initdb postgresql", port=port, indent=1)
            except Exception as e:
                formatter.error(f"initdb postgresql: {e}", port=port, indent=1)
                raise
        
        # Step 2: Optimize PostgreSQL configuration
        for i, datadir in enumerate(datadirs):
            node_name = f"n{i+1}"
            port = args.port_start + i
            try:
                pg_manager.optimize_postgresql_conf(datadir, port)
                formatter.success(f"Configuring postgresql", port=port, indent=1)
            except Exception as e:
                formatter.error(f"Configuring postgresql: {e}", port=port, indent=1)
                raise
        
        # Step 3: Start PostgreSQL instances
        processes = []
        for i, datadir in enumerate(datadirs):
            node_name = f"n{i+1}"
            port = args.port_start + i
            try:
                process = pg_manager.start_postgres(datadir, port)
                processes.append(process)
                cleanup_manager.register_process(process, port)
                formatter.success(f"Starting postgresql", port=port, indent=1)
            except Exception as e:
                formatter.error(f"Starting postgresql: {e}", port=port, indent=1)
                raise
        
        # Wait for PostgreSQL to be ready
        for i in range(config.NUM_NODES):
            node_name = f"n{i+1}"
            port = args.port_start + i
            process = processes[i]
            datadir = datadirs[i]
            if pg_manager.wait_for_postgres(port, process=process):
                formatter.success(f"PostgreSQL ready", port=port, indent=1)
            else:
                # Check log file for errors
                log_file = datadir / "postgresql.log"
                error_msg = f"PostgreSQL failed to start"
                if log_file.exists():
                    try:
                        with open(log_file, 'r') as f:
                            lines = f.readlines()
                            # Get last few error lines
                            error_lines = [l.strip() for l in lines[-50:] if any(keyword in l for keyword in ['ERROR', 'FATAL', 'PANIC', 'could not', 'failed'])]
                            if error_lines:
                                # Get the most relevant error line (prefer FATAL over others)
                                fatal_lines = [l for l in error_lines if 'FATAL' in l]
                                if fatal_lines:
                                    last_error = fatal_lines[-1]
                                else:
                                    last_error = error_lines[-1]
                                # Extract just the error message part (skip timestamp)
                                if 'FATAL:' in last_error:
                                    # Extract everything after FATAL:
                                    fatal_part = last_error.split('FATAL:', 1)[-1].strip()
                                    error_msg = f"PostgreSQL failed: {fatal_part[:70]}"
                                elif ':' in last_error:
                                    parts = last_error.split(':', 2)
                                    if len(parts) >= 3:
                                        error_part = parts[-1].strip()
                                        error_msg = f"PostgreSQL failed: {error_part[:70]}"
                                    else:
                                        error_msg = f"PostgreSQL failed: {last_error[:70]}"
                                else:
                                    error_msg = f"PostgreSQL failed: {last_error[:70]}"
                    except Exception as e:
                        error_msg = f"PostgreSQL failed to start (log read error: {str(e)[:40]})"
                formatter.error(error_msg, port=port, indent=1)
                raise RuntimeError(f"{node_name} not ready")
        
        # Create database and user
        for i in range(config.NUM_NODES):
            port = args.port_start + i
            node_name = f"n{i+1}"
            try:
                # Connect to postgres database first
                conn = psycopg2.connect(
                    host="localhost",
                    port=port,
                    user=config.DB_USER,
                    database="postgres",
                    connect_timeout=config.CONNECT_TIMEOUT
                )
                
                # Create user if not exists
                try:
                    pg_manager.execute_sql(conn, f"CREATE USER {config.DB_USER} WITH SUPERUSER PASSWORD '{config.DB_PASSWORD}';")
                except Exception as e:
                    if "already exists" not in str(e).lower():
                        formatter.warning(f"Creating user: {e}", port=port, indent=1)
                
                # Create pgedge database if not exists (this is the default database)
                # CREATE DATABASE cannot run inside a transaction block, so use autocommit
                try:
                    old_autocommit = conn.autocommit
                    conn.autocommit = True
                    pg_manager.execute_sql(conn, f"CREATE DATABASE {config.DB_NAME};")
                    conn.autocommit = old_autocommit
                    formatter.success(f"Creating pgedge database", port=port, indent=1)
                except Exception as e:
                    if "already exists" not in str(e).lower():
                        formatter.warning(f"Creating pgedge database: {e}", port=port, indent=1)
                    else:
                        formatter.success(f"Pgedge database exists", port=port, indent=1)
                    conn.autocommit = old_autocommit
                
                # Grant privileges (also needs autocommit for database-level grants)
                try:
                    old_autocommit = conn.autocommit
                    conn.autocommit = True
                    pg_manager.execute_sql(conn, f"GRANT ALL PRIVILEGES ON DATABASE {config.DB_NAME} TO {config.DB_USER};")
                    conn.autocommit = old_autocommit
                except Exception as e:
                    formatter.warning(f"Grant privileges: {e}", port=port, indent=1)
                    conn.autocommit = old_autocommit
                
                conn.close()
            except Exception as e:
                formatter.warning(f"Database/user setup: {e}", port=port, indent=1)
        
        # Step 4: Setup Spock cluster
        spock_setup.setup_cluster(args.port_start)
        
        # Step 5: Verify replication
        if spock_setup.verify_replication(args.port_start):
            formatter.success("All steps completed successfully!")
        else:
            formatter.warning("Setup completed with warnings")
            # Show logs to help debug replication issues (only if verbose)
            if args.verbose:
                print("\n")
                spock_setup.show_logs(args.port_start)
        
        # Step 6: Display replication status and lag from all nodes
        formatter.success("Getting replication status and lag from all nodes", port=None, indent=0)
        for i in range(config.NUM_NODES):
            port = args.port_start + i
            node_name = f"n{i+1}"
            try:
                conn = pg_manager.connect(port)
                
                # Get current WAL LSN for this node
                result = pg_manager.fetch_sql(conn, "SELECT pg_current_wal_lsn();")
                current_lsn = result[0][0] if result and result[0] else None
                
                # Get replication lag information from spock.lag_tracker
                lag_result = pg_manager.fetch_sql(conn, f"""
                    SELECT origin_name, receiver_name, commit_lsn, remote_insert_lsn, 
                           replication_lag_bytes, replication_lag
                    FROM spock.lag_tracker
                    WHERE receiver_name = '{node_name}'
                    ORDER BY origin_name;
                """)
                
                conn.close()
                
                if current_lsn:
                    formatter.success(f"Node {node_name} WAL LSN: {current_lsn}", port=port, indent=1)
                    
                    if lag_result:
                        for row in lag_result:
                            origin_name, receiver_name, commit_lsn, remote_insert_lsn, lag_bytes, lag_time = row
                            # Format lag bytes and time
                            if lag_bytes is not None:
                                lag_bytes_str = f"{lag_bytes:,} bytes" if lag_bytes > 0 else "0 bytes"
                            else:
                                lag_bytes_str = "N/A"
                            
                            if lag_time is not None:
                                # Convert interval to readable string
                                lag_time_str = str(lag_time)
                            else:
                                lag_time_str = "N/A"
                            
                            # Show replication status: caught up if lag is minimal
                            if lag_bytes is not None and lag_bytes < 1024:  # Less than 1KB is essentially caught up
                                status_icon = "✓"
                            else:
                                status_icon = "⚠"
                            
                            formatter.info(
                                f"  {status_icon} From {origin_name}: commit_lsn={commit_lsn}, lag={lag_bytes_str} ({lag_time_str})",
                                port=port, indent=2
                            )
                    else:
                        formatter.warning(f"No replication lag data found", port=port, indent=2)
                else:
                    formatter.warning(f"Could not get WAL LSN", port=port, indent=1)
            except Exception as e:
                formatter.error(f"Getting replication status: {e}", port=port, indent=1)
        
    except KeyboardInterrupt:
        formatter.error("Interrupted by user")
        cleanup_manager.cleanup()
        sys.exit(1)
    except Exception as e:
        formatter.error(f"Setup failed: {e}")
        if args.verbose:
            import traceback
            traceback.print_exc()
        cleanup_manager.cleanup()
        sys.exit(1)


if __name__ == '__main__':
    main()


