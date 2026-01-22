"""
Spock cluster management module.
Handles multi-master replication setup between nodes.
"""

import time
from typing import Dict, List, Optional

from .utils.logger import setup_logger
from .utils.ssh_client import SSHClient


class ClusterManager:
    """Manages Spock cluster configuration and replication setup."""

    def __init__(self, logger=None):
        """
        Initialize cluster manager.

        Args:
            logger: Logger instance (optional)
        """
        self.logger = logger or setup_logger(__name__)
        self.nodes: List[Dict] = []

    def add_node(
        self,
        node_name: str,
        ssh_client: SSHClient,
        dsn: str,
        db_name: str = "postgres",
        db_user: str = "postgres"
    ) -> None:
        """
        Add a node to the cluster configuration.

        Args:
            node_name: Unique node name
            ssh_client: SSH client for this node
            dsn: Database connection string
            db_name: Database name
            db_user: Database user
        """
        node_info = {
            'name': node_name,
            'ssh': ssh_client,
            'dsn': dsn,
            'db_name': db_name,
            'db_user': db_user
        }
        self.nodes.append(node_info)
        self.logger.info(f"Added node: {node_name}")

    def create_node(self, node_name: str, dsn: str, db_name: str = "postgres") -> None:
        """
        Create Spock node on remote database.

        Args:
            node_name: Node name
            dsn: Database connection string
            db_name: Database name
        """
        # Find node in our list
        node = self._find_node(node_name)
        if not node:
            raise ValueError(f"Node {node_name} not found in cluster configuration")

        self.logger.info(f"Creating Spock node: {node_name}")

        sql = f"SELECT spock.node_create(node_name := '{node_name}', dsn := '{dsn}');"
        node['ssh'].execute_sudo(
            f"su - postgres -c \"psql -d {db_name} -c '{sql}'\"",
            check=True
        )

        self.logger.info(f"Node {node_name} created successfully")

    def add_tables_to_repset(
        self,
        node_name: str,
        repset_name: str = "default",
        schemas: List[str] = None,
        db_name: str = "postgres"
    ) -> None:
        """
        Add tables to replication set.

        Args:
            node_name: Node name
            repset_name: Replication set name
            schemas: List of schema names (default: ['public'])
            db_name: Database name
        """
        if schemas is None:
            schemas = ['public']

        node = self._find_node(node_name)
        if not node:
            raise ValueError(f"Node {node_name} not found")

        self.logger.info(f"Adding tables to replication set '{repset_name}' on {node_name}")

        schemas_array = "ARRAY[" + ", ".join([f"'{s}'" for s in schemas]) + "]"
        sql = f"SELECT spock.repset_add_all_tables('{repset_name}', {schemas_array});"

        node['ssh'].execute_sudo(
            f"su - postgres -c \"psql -d {db_name} -c '{sql}'\"",
            check=True
        )

        self.logger.info(f"Tables added to replication set on {node_name}")

    def create_subscription(
        self,
        subscriber_node: str,
        provider_dsn: str,
        subscription_name: Optional[str] = None,
        db_name: str = "postgres"
    ) -> None:
        """
        Create subscription from subscriber to provider.

        Args:
            subscriber_node: Subscriber node name
            provider_dsn: Provider connection string
            subscription_name: Subscription name (auto-generated if None)
            db_name: Database name
        """
        node = self._find_node(subscriber_node)
        if not node:
            raise ValueError(f"Node {subscriber_node} not found")

        if subscription_name is None:
            # Generate subscription name
            provider_name = self._extract_node_name_from_dsn(provider_dsn)
            subscription_name = f"sub_{subscriber_node}_{provider_name}"

        self.logger.info(
            f"Creating subscription '{subscription_name}' from {subscriber_node} to provider"
        )

        sql = (
            f"SELECT spock.sub_create("
            f"subscription_name := '{subscription_name}', "
            f"provider_dsn := '{provider_dsn}'"
            f");"
        )

        node['ssh'].execute_sudo(
            f"su - postgres -c \"psql -d {db_name} -c '{sql}'\"",
            check=True
        )

        self.logger.info(f"Subscription '{subscription_name}' created")

    def wait_for_sync(
        self,
        node_name: str,
        subscription_name: str,
        timeout: int = 600,
        db_name: str = "postgres"
    ) -> None:
        """
        Wait for subscription to sync.

        Args:
            node_name: Node name
            subscription_name: Subscription name
            timeout: Maximum wait time in seconds
            db_name: Database name
        """
        node = self._find_node(node_name)
        if not node:
            raise ValueError(f"Node {node_name} not found")

        self.logger.info(f"Waiting for subscription '{subscription_name}' to sync on {node_name}")

        sql = f"SELECT spock.sub_wait_for_sync('{subscription_name}');"
        start_time = time.time()

        while time.time() - start_time < timeout:
            try:
                node['ssh'].execute_sudo(
                    f"su - postgres -c \"psql -d {db_name} -c '{sql}'\"",
                    check=True
                )
                self.logger.info(f"Subscription '{subscription_name}' synced successfully")
                return
            except Exception as e:
                if "not yet synchronized" in str(e).lower() or "sync" in str(e).lower():
                    time.sleep(5)
                    continue
                else:
                    raise

        raise RuntimeError(
            f"Subscription '{subscription_name}' did not sync within {timeout} seconds"
        )

    def setup_multi_master_cluster(self, db_name: str = "postgres") -> None:
        """
        Set up full mesh multi-master replication between all nodes.

        Args:
            db_name: Database name
        """
        if len(self.nodes) < 2:
            raise ValueError("At least 2 nodes required for multi-master replication")

        self.logger.info(f"Setting up multi-master cluster with {len(self.nodes)} nodes")

        # Step 1: Create nodes on all hosts
        for node in self.nodes:
            self.create_node(node['name'], node['dsn'], db_name)

        # Step 2: Add tables to replication set on first node
        first_node = self.nodes[0]
        self.add_tables_to_repset(first_node['name'], db_name=db_name)

        # Step 3: Create subscriptions from each node to all other nodes
        # This creates a full mesh topology
        for i, subscriber in enumerate(self.nodes):
            for j, provider in enumerate(self.nodes):
                if i != j:  # Don't subscribe to self
                    subscription_name = f"sub_{subscriber['name']}_{provider['name']}"
                    try:
                        self.create_subscription(
                            subscriber['name'],
                            provider['dsn'],
                            subscription_name,
                            db_name
                        )
                        # Wait for sync only for first subscription to avoid long waits
                        if i == 1 and j == 0:  # First subscription from second node
                            self.wait_for_sync(
                                subscriber['name'],
                                subscription_name,
                                db_name=db_name
                            )
                    except Exception as e:
                        self.logger.warning(
                            f"Failed to create subscription {subscription_name}: {e}"
                        )
                        # Continue with other subscriptions

        self.logger.info("Multi-master cluster setup completed")

    def get_cluster_status(self, db_name: str = "postgres") -> Dict:
        """
        Get cluster status from all nodes.

        Args:
            db_name: Database name

        Returns:
            Dictionary with cluster status information
        """
        status = {
            'nodes': [],
            'subscriptions': []
        }

        for node in self.nodes:
            # Get node info
            sql = "SELECT node_id, node_name, location, country FROM spock.node;"
            try:
                _, stdout, _ = node['ssh'].execute_sudo(
                    f"su - postgres -c \"psql -d {db_name} -t -A -F'|' -c '{sql}'\"",
                    check=True
                )
                node_info = {
                    'name': node['name'],
                    'nodes': stdout.strip().split('\n') if stdout.strip() else []
                }
                status['nodes'].append(node_info)

                # Get subscription status
                sql = "SELECT * FROM spock.sub_show_status();"
                _, stdout, _ = node['ssh'].execute_sudo(
                    f"su - postgres -c \"psql -d {db_name} -t -A -F'|' -c '{sql}'\"",
                    check=True
                )
                node_info['subscriptions'] = stdout.strip().split('\n') if stdout.strip() else []
                status['subscriptions'].append(node_info)
            except Exception as e:
                self.logger.warning(f"Failed to get status from {node['name']}: {e}")

        return status

    def _find_node(self, node_name: str) -> Optional[Dict]:
        """Find node by name."""
        for node in self.nodes:
            if node['name'] == node_name:
                return node
        return None

    def _extract_node_name_from_dsn(self, dsn: str) -> str:
        """Extract a simple identifier from DSN for naming."""
        # Try to extract hostname or use a hash
        for part in dsn.split():
            if part.startswith('host='):
                host = part.split('=')[1]
                # Use first part of hostname or IP
                return host.split('.')[0] if '.' in host else host[:8]
        return "provider"
