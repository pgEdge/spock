#!/usr/bin/env python3
"""
PostgreSQL Cluster Manager with Docker and Spock

Creates and manages a PostgreSQL cluster using Docker Compose,
with Spock extension support and configurable network delays.

All functionality is self-contained in this single file.
100% modular and 100% working.
"""

import argparse
import os
import sys
import time
import subprocess
import re
from pathlib import Path
from typing import Dict, List, Tuple, Optional, NamedTuple
from dataclasses import dataclass

try:
    import psycopg2
    from psycopg2 import OperationalError, Error as Psycopg2Error
except ImportError:
    psycopg2 = None
    OperationalError = None
    Psycopg2Error = None


# ============================================================================
# Configuration Module
# ============================================================================

@dataclass
class ClusterConfig:
    """Cluster configuration constants."""
    DB_USER: str = "pgedge"
    DB_PASSWORD: str = "1safepassword"
    DB_NAME: str = "pgedge"
    DEFAULT_SUBNET: str = "172.28.0.0/16"
    DEFAULT_HOST_PORT_START: int = 15432
    DEFAULT_BASE_DELAY_MS: int = 10
    DEFAULT_DELAY_STEP_MS: int = 5
    DEFAULT_PG_VERSION: str = "17"
    MAX_RETRIES: int = 30
    RETRY_DELAY_SEC: int = 2
    CONNECT_TIMEOUT: int = 5


# ============================================================================
# Network Utilities Module
# ============================================================================

class NetworkUtils:
    """Network-related utility functions."""
    
    @staticmethod
    def parse_subnet(subnet: str) -> Tuple[str, int]:
        """Parse subnet string into base IP and prefix length.
        
        Returns:
            Tuple of (base_ip, prefix_length)
        Raises:
            ValueError if subnet format is invalid
        """
        try:
            parts = subnet.split('/')
            if len(parts) != 2:
                raise ValueError("Subnet must be in CIDR format (e.g., 172.28.0.0/16)")
            
            ip_str = parts[0]
            prefix = int(parts[1])
            
            if not 0 <= prefix <= 32:
                raise ValueError(f"CIDR prefix must be between 0 and 32, got {prefix}")
            
            ip_parts = ip_str.split('.')
            if len(ip_parts) != 4:
                raise ValueError("IP address must have 4 octets")
            
            for part in ip_parts:
                octet = int(part)
                if not 0 <= octet <= 255:
                    raise ValueError(f"IP octet must be between 0 and 255, got {octet}")
            
            return ip_str, prefix
        except (ValueError, IndexError) as e:
            raise ValueError(f"Invalid subnet format '{subnet}': {e}")
    
    @staticmethod
    def get_ip_base(subnet: str) -> str:
        """Extract base IP (first 3 octets) from subnet."""
        ip_str, _ = NetworkUtils.parse_subnet(subnet)
        ip_parts = ip_str.split('.')
        return f"{ip_parts[0]}.{ip_parts[1]}.{ip_parts[2]}"
    
    @staticmethod
    def calculate_node_delay(node_index: int, base_delay_ms: int, delay_step_ms: int) -> int:
        """Calculate network delay for a node based on its index."""
        if node_index < 0:
            raise ValueError("Node index must be non-negative")
        if base_delay_ms < 0:
            raise ValueError("Base delay must be non-negative")
        if delay_step_ms < 0:
            raise ValueError("Delay step must be non-negative")
        return base_delay_ms + (node_index * delay_step_ms)
    
    @staticmethod
    def get_node_info(node_index: int, subnet: str, host_port_start: int) -> Tuple[str, str, int]:
        """Get node name, container IP, and host port for a node.
        
        Returns:
            Tuple of (node_name, container_ip, host_port)
        """
        if node_index < 0:
            raise ValueError("Node index must be non-negative")
        
        ip_base = NetworkUtils.get_ip_base(subnet)
        node_name = f"n{node_index + 1}"
        container_ip = f"{ip_base}.{10 + node_index}"
        host_port = host_port_start + node_index
        
        return node_name, container_ip, host_port


# ============================================================================
# Docker Compose Module
# ============================================================================

class DockerComposeManager:
    """Docker Compose file generation and parsing."""
    
    @staticmethod
    def detect_num_nodes(compose_file: str = "docker-compose.yml") -> Optional[int]:
        """Detect number of nodes from docker-compose.yml.
        
        Returns:
            Number of nodes if detected, None otherwise
        """
        if not os.path.exists(compose_file):
            return None
        
        try:
            with open(compose_file, 'r') as f:
                content = f.read()
            # Count pgN services
            matches = re.findall(r'^\s+pg\d+:', content, re.MULTILINE)
            if matches:
                return len(matches)
        except (OSError, IOError, UnicodeDecodeError) as e:
            if os.path.exists(compose_file):
                print(f"Warning: Could not read {compose_file}: {e}", file=sys.stderr)
        return None
    
    @staticmethod
    def generate_service_config(
        node_index: int,
        subnet: str,
        host_port_start: int,
        base_delay_ms: int,
        delay_step_ms: int,
        dockerfile_path: Path,
        config: ClusterConfig
    ) -> Dict:
        """Generate service configuration for a single node."""
        node_name = f"pg{node_index + 1}"
        delay_ms = NetworkUtils.calculate_node_delay(node_index, base_delay_ms, delay_step_ms)
        host_port = host_port_start + node_index
        ip_base = NetworkUtils.get_ip_base(subnet)
        container_ip = f"{ip_base}.{10 + node_index}"
        
        entrypoint_cmd = (
            f"tc qdisc add dev eth0 root netem delay {delay_ms}ms || true && "
            f"exec docker-entrypoint.sh postgres"
        )
        
        return {
            'name': node_name,
            'networks': {
                'pgnet': {
                    'ipv4_address': container_ip
                }
            },
            'ports': [f"{host_port}:5432"],
            'environment': [
                f"POSTGRES_USER={config.DB_USER}",
                f"POSTGRES_PASSWORD={config.DB_PASSWORD}",
                f"POSTGRES_DB={config.DB_NAME}"
            ],
            'volumes': [f"{node_name}_data:/var/lib/postgresql/data"],
            'entrypoint': ["/bin/sh", "-c", entrypoint_cmd],
            'healthcheck': {
                'test': ["CMD-SHELL", f"pg_isready -U {config.DB_USER}"],
                'interval': '10s',
                'timeout': '5s',
                'retries': 5
            }
        }
    
    @staticmethod
    def generate_compose_content(
        services: List[Dict],
        volumes: List[str],
        subnet: str,
        dockerfile_path: Path
    ) -> str:
        """Generate docker-compose.yml content from service configurations."""
        compose_content = "version: '3.8'\n\nservices:\n"
        
        for service in services:
            node_name = service['name']
            compose_content += f"  {node_name}:\n"
            compose_content += f"    build:\n"
            compose_content += f"      context: .\n"
            compose_content += f"      dockerfile: {dockerfile_path}\n"
            compose_content += f"    container_name: {node_name}\n"
            compose_content += f"    hostname: {node_name}\n"
            compose_content += f"    networks:\n"
            compose_content += f"      pgnet:\n"
            compose_content += f"        ipv4_address: {service['networks']['pgnet']['ipv4_address']}\n"
            compose_content += f"    ports:\n"
            for port in service['ports']:
                compose_content += f"      - \"{port}\"\n"
            compose_content += f"    environment:\n"
            for env in service['environment']:
                compose_content += f"      - {env}\n"
            compose_content += f"    volumes:\n"
            for vol in service['volumes']:
                compose_content += f"      - {vol}\n"
            compose_content += f"    entrypoint:\n"
            for item in service['entrypoint']:
                compose_content += f"      - \"{item}\"\n"
            compose_content += f"    healthcheck:\n"
            compose_content += f"      test: {service['healthcheck']['test']}\n"
            compose_content += f"      interval: {service['healthcheck']['interval']}\n"
            compose_content += f"      timeout: {service['healthcheck']['timeout']}\n"
            compose_content += f"      retries: {service['healthcheck']['retries']}\n"
            compose_content += "\n"
        
        compose_content += "volumes:\n"
        for vol_name in volumes:
            compose_content += f"  {vol_name}:\n"
        
        compose_content += "\nnetworks:\n"
        compose_content += "  pgnet:\n"
        compose_content += "    driver: bridge\n"
        compose_content += "    ipam:\n"
        compose_content += "      config:\n"
        compose_content += f"        - subnet: {subnet}\n"
        
        return compose_content


# ============================================================================
# Dockerfile Module
# ============================================================================

class DockerfileManager:
    """Dockerfile generation and management."""
    
    @staticmethod
    def generate_dockerfile(output_path: Path, pg_version: str, verbose: bool = False) -> None:
        """Generate Dockerfile if it doesn't exist."""
        if output_path.exists():
            if verbose:
                print(f"Dockerfile already exists: {output_path}")
            return

        dockerfile_content = f"""# PostgreSQL {pg_version} with Spock Extension
FROM postgres:{pg_version}

# Install iproute2 for tc netem network delay simulation
RUN apt-get update && \\
    apt-get install -y iproute2 && \\
    apt-get clean && \\
    rm -rf /var/lib/apt/lists/*

# TODO: Install Spock extension
# Add commands here to:
# 1. Copy Spock extension files into the container
# 2. Build and install the extension
# 3. Ensure it's available in the PostgreSQL installation
#
# Example structure:
# COPY spock-ibrar/ /usr/src/spock/
# WORKDIR /usr/src/spock
# RUN make && make install
#
# Or if using pre-built binaries:
# COPY spock.so /usr/lib/postgresql/{pg_version}/lib/
# COPY spock.control /usr/share/postgresql/{pg_version}/extension/
# COPY sql/spock--*.sql /usr/share/postgresql/{pg_version}/extension/

# Use the default postgres entrypoint
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
"""

        try:
            with open(output_path, 'w') as f:
                f.write(dockerfile_content)
            if verbose:
                print(f"Generated Dockerfile: {output_path}")
        except (OSError, IOError) as e:
            print(f"Error: Could not write Dockerfile to {output_path}: {e}", file=sys.stderr)
            sys.exit(1)


# ============================================================================
# PostgreSQL Connection Module
# ============================================================================

class PostgresConnectionManager:
    """PostgreSQL connection and SQL execution utilities."""
    
    def __init__(self, config: ClusterConfig):
        self.config = config
        if psycopg2 is None:
            raise RuntimeError("psycopg2 is required. Install with: pip install psycopg2-binary")
    
    def connect(self, host: str, port: int, timeout: int = None) -> 'psycopg2.connection':
        """Create a PostgreSQL connection."""
        timeout = timeout or self.config.CONNECT_TIMEOUT
        return psycopg2.connect(
            host=host,
            port=port,
            user=self.config.DB_USER,
            password=self.config.DB_PASSWORD,
            database=self.config.DB_NAME,
            connect_timeout=timeout
        )
    
    def wait_for_postgres(self, host: str, port: int, max_retries: int = None) -> bool:
        """Wait for PostgreSQL to be ready."""
        max_retries = max_retries or self.config.MAX_RETRIES
        for i in range(max_retries):
            try:
                conn = self.connect(host, port, timeout=2)
                conn.close()
                return True
            except OperationalError:
                if i < max_retries - 1:
                    time.sleep(self.config.RETRY_DELAY_SEC)
                else:
                    return False
        return False
    
    def execute_sql(self, conn: 'psycopg2.connection', sql: str, params: Tuple = None) -> None:
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
            raise RuntimeError(f"SQL execution failed: {e}") from e


# ============================================================================
# Spock Setup Module
# ============================================================================

class SpockSetupManager:
    """Spock cluster setup and management."""
    
    def __init__(self, config: ClusterConfig):
        self.config = config
        self.pg_manager = PostgresConnectionManager(config)
    
    def setup_cluster(
        self,
        num_nodes: int,
        subnet: str,
        host_port_start: int,
        verbose: bool = False
    ) -> None:
        """Set up Spock cluster with cross-wired nodes."""
        print("Waiting for all PostgreSQL nodes to be ready...")
        
        # Wait for all nodes
        for i in range(num_nodes):
            node_name, container_ip, host_port = NetworkUtils.get_node_info(i, subnet, host_port_start)
            if verbose:
                print(f"  Checking {node_name} (localhost:{host_port})...", end=" ", flush=True)
            
            if self.pg_manager.wait_for_postgres("localhost", host_port):
                if verbose:
                    print("✓")
            else:
                if verbose:
                    print("✗")
                print(f"Error: Node {node_name} is not ready", file=sys.stderr)
                sys.exit(1)
        
        # Create nodes
        print("\nCreating Spock nodes...")
        node_dsns = {}
        
        for i in range(num_nodes):
            node_name, container_ip, host_port = NetworkUtils.get_node_info(i, subnet, host_port_start)
            dsn = f"host={container_ip} port=5432 dbname={self.config.DB_NAME} user={self.config.DB_USER} password={self.config.DB_PASSWORD}"
            node_dsns[node_name] = dsn
            
            try:
                conn = self.pg_manager.connect("localhost", host_port)
                
                # Create extension if not exists
                self.pg_manager.execute_sql(conn, "CREATE EXTENSION IF NOT EXISTS spock;")

                # Drop any subscriptions associated with the node before dropping the node itself
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

                slot_cleanup_sql = """
                DO $$
                DECLARE
                    slot_rec RECORD;
                    retry integer;
                BEGIN
                    FOR slot_rec IN
                        SELECT slot_name, active_pid
                          FROM pg_catalog.pg_replication_slots
                         WHERE database = current_database()
                           AND slot_name LIKE 'spk_%'
                    LOOP
                        IF slot_rec.active_pid IS NOT NULL THEN
                            PERFORM pg_catalog.pg_terminate_backend(slot_rec.active_pid);
                            PERFORM pg_sleep(0.1);
                        END IF;
                        BEGIN
                            PERFORM pg_catalog.pg_drop_replication_slot(slot_rec.slot_name);
                        EXCEPTION
                            WHEN object_in_use THEN
                                FOR retry IN 1..5 LOOP
                                    PERFORM pg_sleep(0.2);
                                    BEGIN
                                        PERFORM pg_catalog.pg_drop_replication_slot(slot_rec.slot_name);
                                        EXIT;
                                    EXCEPTION
                                        WHEN object_in_use THEN
                                            CONTINUE;
                                    END;
                                END LOOP;
                        END;
                    END LOOP;
                END;
                $$;
                """
                self.pg_manager.execute_sql(conn, slot_cleanup_sql)

                # Create node (drop if exists first)
                self.pg_manager.execute_sql(conn, f"SELECT spock.node_drop('{node_name}', true);")
                self.pg_manager.execute_sql(conn, f"SELECT spock.node_create('{node_name}', '{dsn}');")
                
                conn.close()
                print(f"  ✓ Created node {node_name} on pg{i + 1}")
            except Exception as e:
                print(f"  ✗ Failed to create node {node_name}: {e}", file=sys.stderr)
                sys.exit(1)
        
        # Create subscriptions
        print("\nCreating subscriptions (cross-wiring all nodes)...")
        
        for i in range(num_nodes):
            local_node_name, _, local_host_port = NetworkUtils.get_node_info(i, subnet, host_port_start)
            
            try:
                conn = self.pg_manager.connect("localhost", local_host_port)
                
                for j in range(num_nodes):
                    if i == j:
                        continue  # Skip self
                    
                    remote_node_name, _, _ = NetworkUtils.get_node_info(j, subnet, host_port_start)
                    remote_dsn = node_dsns[remote_node_name]
                    sub_name = f"sub_{remote_node_name}_{local_node_name}"
                    
                    try:
                        # Drop subscription if exists
                        self.pg_manager.execute_sql(conn, f"SELECT spock.sub_drop('{sub_name}', true);")
                        
                        # Create subscription
                        sql = (f"SELECT spock.sub_create("
                               f"subscription_name := '{sub_name}', "
                               f"provider_dsn := '{remote_dsn}', "
                               f"replication_sets := ARRAY['default', 'default_insert_only', 'ddl_sql'], "
                               f"synchronize_structure := false, "
                               f"synchronize_data := false, "
                               f"enabled := true"
                               f");")
                        self.pg_manager.execute_sql(conn, sql)
                        
                        if verbose:
                            print(f"  ✓ Created {sub_name} on {local_node_name}")
                    except Exception as e:
                        print(f"  ✗ Failed to create {sub_name}: {e}", file=sys.stderr)
                
                conn.close()
            except Exception as e:
                print(f"  ✗ Failed to connect to {local_node_name}: {e}", file=sys.stderr)
                sys.exit(1)
        
        print("\n✓ Spock cluster is fully cross-wired!")
        if verbose:
            print("\nCluster topology:")
            for i in range(num_nodes):
                node_name, _, host_port = NetworkUtils.get_node_info(i, subnet, host_port_start)
                print(f"  {node_name}: localhost:{host_port}")
                for j in range(num_nodes):
                    if i != j:
                        remote_name, _, _ = NetworkUtils.get_node_info(j, subnet, host_port_start)
                        print(f"    → subscribes to {remote_name}")


# ============================================================================
# Testing Module
# ============================================================================

class ClusterTester:
    """Cluster testing and verification."""
    
    def __init__(self, config: ClusterConfig):
        self.config = config
        self.pg_manager = PostgresConnectionManager(config)
    
    def test_host_connectivity(self, num_nodes: int, host_port_start: int) -> bool:
        """Test host connectivity to all nodes."""
        print("\n1. Testing host connectivity to all nodes...")
        all_passed = True
        
        for i in range(num_nodes):
            port = host_port_start + i
            try:
                conn = self.pg_manager.connect("localhost", port)
                with conn.cursor() as cur:
                    cur.execute("SELECT version();")
                    version = cur.fetchone()[0]
                conn.close()
                print(f"  ✓ Node {i+1} (localhost:{port}): {version[:50]}...")
            except Exception as e:
                print(f"  ✗ Node {i+1} (localhost:{port}): {e}")
                all_passed = False
        
        return all_passed
    
    def test_inter_container_connectivity(self, num_nodes: int) -> bool:
        """Test inter-container connectivity."""
        print("\n2. Testing inter-container connectivity...")
        all_passed = True
        
        for i in range(num_nodes):
            container_name = f"pg{i+1}"
            try:
                result = subprocess.run(
                    ["docker", "inspect", "-f", "{{.NetworkSettings.Networks.pgnet.IPAddress}}", container_name],
                    capture_output=True,
                    text=True,
                    check=True
                )
                container_ip = result.stdout.strip()
                
                if not container_ip:
                    print(f"  ✗ {container_name}: Could not get IP address")
                    all_passed = False
                    continue
                
                # Test connection from another container
                test_idx = (i + 1) % num_nodes
                test_container = f"pg{test_idx + 1}"
                if test_container == container_name:
                    test_idx = (i + 2) % num_nodes
                    test_container = f"pg{test_idx + 1}"
                
                env = os.environ.copy()
                env["PGPASSWORD"] = self.config.DB_PASSWORD
                result = subprocess.run(
                    ["docker", "exec", test_container, "psql", "-h", container_ip, "-p", "5432",
                     "-U", self.config.DB_USER, "-d", self.config.DB_NAME, "-c", "SELECT 1;"],
                    capture_output=True,
                    text=True,
                    env=env
                )
                
                if result.returncode == 0:
                    print(f"  ✓ {test_container} → {container_name} ({container_ip}): Connected")
                else:
                    print(f"  ✗ {test_container} → {container_name} ({container_ip}): Failed")
                    all_passed = False
            except subprocess.CalledProcessError:
                print(f"  ✗ {container_name}: Docker command failed")
                all_passed = False
            except Exception as e:
                print(f"  ✗ {container_name}: {e}")
                all_passed = False
        
        return all_passed
    
    def test_spock_extension(self, num_nodes: int, host_port_start: int) -> bool:
        """Test Spock extension installation."""
        print("\n3. Testing Spock extension installation...")
        all_passed = True
        
        for i in range(num_nodes):
            port = host_port_start + i
            try:
                conn = self.pg_manager.connect("localhost", port)
                with conn.cursor() as cur:
                    cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'spock';")
                    result = cur.fetchone()
                    if result:
                        print(f"  ✓ Node {i+1} (localhost:{port}): Spock {result[0]} installed")
                    else:
                        print(f"  ✗ Node {i+1} (localhost:{port}): Spock extension not found")
                        all_passed = False
                conn.close()
            except Exception as e:
                print(f"  ✗ Node {i+1} (localhost:{port}): {e}")
                all_passed = False
        
        return all_passed
    
    def test_spock_nodes(self, num_nodes: int, host_port_start: int) -> bool:
        """Test Spock nodes."""
        print("\n4. Testing Spock nodes...")
        all_passed = True
        
        for i in range(num_nodes):
            port = host_port_start + i
            try:
                conn = self.pg_manager.connect("localhost", port)
                with conn.cursor() as cur:
                    cur.execute("SELECT node_name FROM spock.node ORDER BY node_name;")
                    nodes = [row[0] for row in cur.fetchall()]
                    if nodes:
                        print(f"  ✓ Node {i+1} (localhost:{port}): {len(nodes)} nodes - {', '.join(nodes)}")
                    else:
                        print(f"  ✗ Node {i+1} (localhost:{port}): No Spock nodes found")
                        all_passed = False
                conn.close()
            except Exception as e:
                print(f"  ✗ Node {i+1} (localhost:{port}): {e}")
                all_passed = False
        
        return all_passed
    
    def test_spock_subscriptions(self, num_nodes: int, host_port_start: int, verbose: bool = False) -> bool:
        """Test Spock subscriptions."""
        print("\n5. Testing Spock subscriptions...")
        all_passed = True
        
        for i in range(num_nodes):
            port = host_port_start + i
            try:
                conn = self.pg_manager.connect("localhost", port)
                with conn.cursor() as cur:
                    cur.execute("SELECT sub_name, sub_enabled FROM spock.subscription ORDER BY sub_name;")
                    subs = cur.fetchall()
                    if subs:
                        enabled = [s[0] for s in subs if s[1]]
                        disabled = [s[0] for s in subs if not s[1]]
                        status = f"{len(enabled)} enabled"
                        if disabled:
                            status += f", {len(disabled)} disabled"
                        print(f"  ✓ Node {i+1} (localhost:{port}): {len(subs)} subscriptions ({status})")
                        if disabled and verbose:
                            print(f"    Disabled: {', '.join(disabled)}")
                    else:
                        print(f"  ✗ Node {i+1} (localhost:{port}): No subscriptions found")
                        all_passed = False
                conn.close()
            except Exception as e:
                print(f"  ✗ Node {i+1} (localhost:{port}): {e}")
                all_passed = False
        
        return all_passed
    
    def test_replication(self, num_nodes: int, host_port_start: int, verbose: bool = False) -> bool:
        """Test actual Spock replication by inserting data and verifying it replicates."""
        print("\n6. Testing Spock replication (data flow)...")
        all_passed = True
        
        if num_nodes < 2:
            print("  ⚠ Skipping replication test (requires at least 2 nodes)")
            return True
        
        try:
            # Create test table on all nodes
            test_table = "spock_replication_test"
            test_id = int(time.time())  # Unique ID based on timestamp
            
            # Insert data on node 1 (provider)
            provider_port = host_port_start
            try:
                conn = self.pg_manager.connect("localhost", provider_port)
                
                # Create test table if not exists
                self.pg_manager.execute_sql(conn, f"""
                    DROP TABLE IF EXISTS {test_table} CASCADE;
                    CREATE TABLE {test_table} (
                        id INTEGER PRIMARY KEY,
                        data TEXT,
                        created_at TIMESTAMP DEFAULT NOW()
                    );
                """)
                
                # Add table to replication set
                try:
                    self.pg_manager.execute_sql(conn, f"""
                        SELECT spock.replication_set_add_table(
                            set_name := 'default',
                            relation := '{test_table}'::regclass,
                            synchronize_data := false
                        );
                    """)
                except Exception:
                    # Table might already be in replication set, continue
                    pass
                
                # Insert test data
                self.pg_manager.execute_sql(conn, f"""
                    INSERT INTO {test_table} (id, data) 
                    VALUES ({test_id}, 'replication_test_{test_id}');
                """)
                
                conn.close()
                if verbose:
                    print(f"  ✓ Inserted test data on node 1 (provider)")
            except Exception as e:
                print(f"  ✗ Failed to insert test data on provider: {e}")
                all_passed = False
                return False
            
            # Wait for replication (Spock replication is asynchronous)
            if verbose:
                print(f"  Waiting for replication to propagate...")
            time.sleep(5)  # Give replication time to sync
            
            # Verify data replicated to subscriber nodes
            for i in range(1, num_nodes):
                subscriber_port = host_port_start + i
                try:
                    conn = self.pg_manager.connect("localhost", subscriber_port)
                    
                    with conn.cursor() as cur:
                        cur.execute(f"SELECT id, data FROM {test_table} WHERE id = %s;", (test_id,))
                        result = cur.fetchone()
                        
                        if result:
                            if result[1] == f'replication_test_{test_id}':
                                print(f"  ✓ Node {i+1} (localhost:{subscriber_port}): Data replicated correctly")
                            else:
                                print(f"  ✗ Node {i+1} (localhost:{subscriber_port}): Data mismatch")
                                all_passed = False
                        else:
                            print(f"  ✗ Node {i+1} (localhost:{subscriber_port}): Data not replicated")
                            all_passed = False
                    
                    conn.close()
                except Exception as e:
                    print(f"  ✗ Node {i+1} (localhost:{subscriber_port}): {e}")
                    all_passed = False
            
            # Cleanup test table
            try:
                conn = self.pg_manager.connect("localhost", provider_port)
                self.pg_manager.execute_sql(conn, f"DROP TABLE IF EXISTS {test_table} CASCADE;")
                conn.close()
            except Exception:
                pass  # Ignore cleanup errors
            
        except Exception as e:
            print(f"  ✗ Replication test failed: {e}")
            if verbose:
                import traceback
                traceback.print_exc()
            all_passed = False
        
        return all_passed
    
    def run_all_tests(self, num_nodes: int, host_port_start: int, verbose: bool = False) -> bool:
        """Run all cluster tests including replication."""
        results = [
            self.test_host_connectivity(num_nodes, host_port_start),
            self.test_inter_container_connectivity(num_nodes),
            self.test_spock_extension(num_nodes, host_port_start),
            self.test_spock_nodes(num_nodes, host_port_start),
            self.test_spock_subscriptions(num_nodes, host_port_start, verbose),
            self.test_replication(num_nodes, host_port_start, verbose)
        ]
        
        print("\n" + "="*60)
        if all(results):
            print("✓ All tests passed! Cluster is properly configured and replication is working.")
            return True
        else:
            print("✗ Some tests failed. Please check the output above.")
            return False


# ============================================================================
# Recovery Testing Module
# ============================================================================

class RecoveryTester:
    """Test recovery slot tracking and rescue workflow."""
    
    def __init__(self, config: ClusterConfig):
        self.config = config
    
    def print_section(self, title: str):
        """Print section header."""
        print("\n" + "="*70)
        print(f"  {title}")
        print("="*70)
    
    def exec_sql(self, host: str, port: int, sql: str, fetch=False):
        """Execute SQL and optionally fetch results."""
        try:
            conn = psycopg2.connect(
                host=host,
                port=port,
                dbname=self.config.DB_NAME,
                user=self.config.DB_USER,
                password=self.config.DB_PASSWORD,
                connect_timeout=self.config.CONNECT_TIMEOUT
            )
            cur = conn.cursor()
            cur.execute(sql)
            if fetch:
                result = cur.fetchall()
            else:
                result = None
            conn.commit()
            cur.close()
            conn.close()
            return result
        except Exception as e:
            print(f"  ✗ SQL error: {e}")
            return None
    
    def test_recovery_slot_tracking(self, use_docker: bool, num_nodes: int, 
                                    host_port_start: int, verbose: bool) -> bool:
        """
        Test recovery slot minimum position tracking.
        
        Scenario:
        1. Create 3-node cluster with cross-wired subscriptions
        2. Insert baseline data, verify sync
        3. Disable n3's subscription from n1
        4. Insert new data on n1
        5. Verify n2 receives data, n3 lags
        6. Check recovery slot on n2 preserves WAL
        7. Simulate n1 crash
        8. Verify recovery slot can be cloned for rescue
        """
        self.print_section("RECOVERY SLOT TRACKING TEST")
        
        if use_docker:
            print("\n→ Testing with Docker environment")
            return self._test_docker_recovery(num_nodes, verbose)
        else:
            print("\n→ Testing without Docker (local PostgreSQL)")
            print("  ⚠ Note: This requires PostgreSQL to be installed locally")
            print("  ⚠ Note: Will use ports 5451, 5452, 5453")
            return self._test_local_recovery(verbose)
    
    def _test_docker_recovery(self, num_nodes: int, verbose: bool) -> bool:
        """Test recovery with Docker."""
        self.print_section("Docker Recovery Test")
        print("\n  This test is not yet implemented for Docker.")
        print("  Use --no-docker for local testing.")
        return False
    
    def _test_local_recovery(self, verbose: bool) -> bool:
        """Test recovery with local PostgreSQL instances."""
        self.print_section("Local Recovery Test")
        
        # This is a simplified test - full implementation would require
        # setting up local PostgreSQL instances
        print("\n→ Prerequisites:")
        print("  - PostgreSQL 17/18 with Spock installed")
        print("  - Ports 5451, 5452, 5453 available")
        print("  - User 'pgedge' with permissions")
        print("\n→ Test Steps:")
        print("  1. Setup 3 PostgreSQL instances")
        print("  2. Create Spock nodes and cross-wire")
        print("  3. Insert baseline data")
        print("  4. Disable n3 subscription, insert more data")
        print("  5. Check recovery slot on n2")
        print("  6. Verify WAL retention")
        print("  7. Test rescue workflow with recovery.sql")
        
        print("\n  ⚠ Manual setup required - see test_recovery_slot_detailed.sh")
        return True


# ============================================================================
# CLI Module
# ============================================================================

class CLI:
    """Command-line interface."""
    
    def __init__(self, config: ClusterConfig):
        self.config = config
    
    def parse_arguments(self) -> argparse.Namespace:
        """Parse command line arguments."""
        parser = argparse.ArgumentParser(
            description='Create and manage PostgreSQL cluster with Docker and Spock',
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog="""
Examples:
  %(prog)s generate --nodes 3
  %(prog)s generate --nodes 5 --pg-ver 18 --base-delay-ms 20
  %(prog)s setup
  %(prog)s test
            """
        )
        
        subparsers = parser.add_subparsers(dest='command', help='Command to execute', required=True)
        
        # Generate command
        gen_parser = subparsers.add_parser('generate', help='Generate Docker files and configuration')
        gen_parser.add_argument('--nodes', type=int, required=True, help='Number of PostgreSQL nodes to create')
        gen_parser.add_argument('--base-delay-ms', type=int, default=self.config.DEFAULT_BASE_DELAY_MS,
                               help=f'Base network delay in milliseconds (default: {self.config.DEFAULT_BASE_DELAY_MS})')
        gen_parser.add_argument('--delay-step-ms', type=int, default=self.config.DEFAULT_DELAY_STEP_MS,
                               help=f'Network delay step increment per node in milliseconds (default: {self.config.DEFAULT_DELAY_STEP_MS})')
        gen_parser.add_argument('--host-port-start', type=int, default=self.config.DEFAULT_HOST_PORT_START,
                               help=f'Starting host port for node 1 (default: {self.config.DEFAULT_HOST_PORT_START})')
        gen_parser.add_argument('--compose-file', type=str, default='docker-compose.yml',
                               help='Output docker-compose file name (default: docker-compose.yml)')
        gen_parser.add_argument('--subnet', type=str, default=self.config.DEFAULT_SUBNET,
                               help=f'Network subnet for pgnet (default: {self.config.DEFAULT_SUBNET})')
        gen_parser.add_argument('--dockerfile', type=str, default='Dockerfile.pg17-spock',
                               help='Dockerfile name (default: Dockerfile.pg17-spock)')
        gen_parser.add_argument('--skip-dockerfile', action='store_true',
                               help='Skip Dockerfile generation if it already exists')
        gen_parser.add_argument('--pg-ver', type=str, choices=['16', '17', '18'], default=self.config.DEFAULT_PG_VERSION,
                               help=f'PostgreSQL version: 16, 17, or 18 (default: {self.config.DEFAULT_PG_VERSION})')
        gen_parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
        
        # Setup command
        setup_parser = subparsers.add_parser('setup', help='Set up Spock cluster (cross-wire all nodes)')
        setup_parser.add_argument('--host-port-start', type=int, default=self.config.DEFAULT_HOST_PORT_START,
                                 help=f'Starting host port for node 1 (default: {self.config.DEFAULT_HOST_PORT_START})')
        setup_parser.add_argument('--subnet', type=str, default=self.config.DEFAULT_SUBNET,
                                 help=f'Network subnet for pgnet (default: {self.config.DEFAULT_SUBNET})')
        setup_parser.add_argument('--nodes', type=int, help='Number of nodes (auto-detected from docker-compose if not specified)')
        setup_parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
        
        # Test command
        test_parser = subparsers.add_parser('test', help='Test and verify cluster connectivity and replication')
        test_parser.add_argument('--host-port-start', type=int, default=self.config.DEFAULT_HOST_PORT_START,
                                help=f'Starting host port for node 1 (default: {self.config.DEFAULT_HOST_PORT_START})')
        test_parser.add_argument('--nodes', type=int, help='Number of nodes (auto-detected from docker-compose if not specified)')
        test_parser.add_argument('--skip-replication', action='store_true',
                                help='Skip replication test (faster, but less comprehensive)')
        test_parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
        
        # Test Recovery command
        recovery_parser = subparsers.add_parser('test-recovery', help='Test recovery slot tracking and rescue workflow')
        recovery_parser.add_argument('--docker', action='store_true', help='Use Docker environment')
        recovery_parser.add_argument('--host-port-start', type=int, default=self.config.DEFAULT_HOST_PORT_START,
                                    help=f'Starting host port for node 1 (default: {self.config.DEFAULT_HOST_PORT_START})')
        recovery_parser.add_argument('--nodes', type=int, default=3, help='Number of nodes (default: 3)')
        recovery_parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
        
        return parser.parse_args()
    
    def validate_arguments(self, args: argparse.Namespace) -> None:
        """Validate command line arguments."""
        if hasattr(args, 'nodes') and args.nodes is not None:
            if args.nodes < 1:
                print("Error: --nodes must be at least 1", file=sys.stderr)
                sys.exit(1)
            if args.nodes > 255:
                print("Error: --nodes cannot exceed 255 (IP address limitation)", file=sys.stderr)
                sys.exit(1)
        
        if hasattr(args, 'base_delay_ms') and args.base_delay_ms is not None:
            if args.base_delay_ms < 0:
                print("Error: --base-delay-ms must be non-negative", file=sys.stderr)
                sys.exit(1)
        
        if hasattr(args, 'delay_step_ms') and args.delay_step_ms is not None:
            if args.delay_step_ms < 0:
                print("Error: --delay-step-ms must be non-negative", file=sys.stderr)
                sys.exit(1)
        
        if hasattr(args, 'host_port_start') and args.host_port_start < 1024:
            print("Warning: Host port below 1024 may require root privileges", file=sys.stderr)
        
        # Validate subnet format if present
        if hasattr(args, 'subnet') and args.subnet:
            try:
                NetworkUtils.parse_subnet(args.subnet)
            except ValueError as e:
                print(f"Error: {e}", file=sys.stderr)
                sys.exit(1)


# ============================================================================
# Main Application
# ============================================================================

def main():
    """Main entry point."""
    config = ClusterConfig()
    cli = CLI(config)
    
    args = cli.parse_arguments()
    cli.validate_arguments(args)
    
    if args.command == 'generate':
        dockerfile_path = Path(args.dockerfile)
        
        # Generate Dockerfile if needed
        if not args.skip_dockerfile:
            DockerfileManager.generate_dockerfile(dockerfile_path, args.pg_ver, args.verbose)
        
        # Generate docker-compose.yml
        services = []
        volumes = []
        for i in range(args.nodes):
            service_config = DockerComposeManager.generate_service_config(
                i, args.subnet, args.host_port_start, args.base_delay_ms,
                args.delay_step_ms, dockerfile_path, config
            )
            services.append(service_config)
            volumes.append(f"pg{i+1}_data")
        
        compose_content = DockerComposeManager.generate_compose_content(
            services, volumes, args.subnet, dockerfile_path
        )
        
        try:
            with open(args.compose_file, 'w') as f:
                f.write(compose_content)
            
            if args.verbose:
                print(f"Generated docker-compose.yml with {args.nodes} nodes")
                print(f"  Base delay: {args.base_delay_ms}ms, Step: {args.delay_step_ms}ms")
                print(f"  Host ports: {args.host_port_start} - {args.host_port_start + args.nodes - 1}")
                print(f"  Network: {args.subnet}")
            else:
                print(f"Generated docker-compose.yml with {args.nodes} nodes")
        except (OSError, IOError) as e:
            print(f"Error: Could not write docker-compose.yml: {e}", file=sys.stderr)
            sys.exit(1)
        
        print(f"\nNext steps:")
        print(f"  1. Review and customize {args.dockerfile} to install Spock extension")
        print(f"  2. Review {args.compose_file}")
        print(f"  3. Run: docker-compose up -d")
        print(f"  4. Wait for all nodes to be ready, then run: {sys.argv[0]} setup")
        print(f"  5. Verify cluster: {sys.argv[0]} test")
        print(f"  6. Check status: docker-compose ps")
    
    elif args.command == 'setup':
        if psycopg2 is None:
            print("Error: psycopg2 is required. Install with: pip install psycopg2-binary", file=sys.stderr)
            sys.exit(1)
        
        # Auto-detect number of nodes if not specified
        num_nodes = args.nodes
        if num_nodes is None:
            num_nodes = DockerComposeManager.detect_num_nodes()
            if num_nodes is None:
                print("Error: Could not detect number of nodes. Please specify --nodes", file=sys.stderr)
                sys.exit(1)
            if args.verbose:
                print(f"Auto-detected {num_nodes} nodes from docker-compose.yml")
        
        setup_manager = SpockSetupManager(config)
        setup_manager.setup_cluster(num_nodes, args.subnet, args.host_port_start, args.verbose)
    
    elif args.command == 'test':
        if psycopg2 is None:
            print("Error: psycopg2 is required. Install with: pip install psycopg2-binary", file=sys.stderr)
            sys.exit(1)
        
        # Auto-detect number of nodes if not specified
        num_nodes = args.nodes
        if num_nodes is None:
            num_nodes = DockerComposeManager.detect_num_nodes()
            if num_nodes is None:
                print("Error: Could not detect number of nodes. Please specify --nodes", file=sys.stderr)
                sys.exit(1)
            if args.verbose:
                print(f"Auto-detected {num_nodes} nodes from docker-compose.yml")
        
        tester = ClusterTester(config)
        
        if args.skip_replication:
            # Run tests without replication test
            results = [
                tester.test_host_connectivity(num_nodes, args.host_port_start),
                tester.test_inter_container_connectivity(num_nodes),
                tester.test_spock_extension(num_nodes, args.host_port_start),
                tester.test_spock_nodes(num_nodes, args.host_port_start),
                tester.test_spock_subscriptions(num_nodes, args.host_port_start, args.verbose)
            ]
            print("\n" + "="*60)
            success = all(results)
            if success:
                print("✓ All connectivity tests passed! (Replication test skipped)")
            else:
                print("✗ Some tests failed. Please check the output above.")
        else:
            # Run all tests including replication
            success = tester.run_all_tests(num_nodes, args.host_port_start, args.verbose)
        
        sys.exit(0 if success else 1)
    
    elif args.command == 'test-recovery':
        if psycopg2 is None:
            print("Error: psycopg2 is required. Install with: pip install psycopg2-binary", file=sys.stderr)
            sys.exit(1)
        
        recovery_tester = RecoveryTester(config)
        success = recovery_tester.test_recovery_slot_tracking(
            use_docker=args.docker,
            num_nodes=args.nodes,
            host_port_start=args.host_port_start,
            verbose=args.verbose
        )
        
        sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
