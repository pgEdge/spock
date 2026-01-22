"""
pgbench benchmark execution and results collection module.
Handles running pgbench with custom scripts and collecting metrics.
"""

import json
import re
import time
from pathlib import Path
from typing import Dict, List, Optional

from .utils.logger import setup_logger
from .utils.ssh_client import SSHClient


class BenchmarkRunner:
    """Manages pgbench benchmark execution and results collection."""

    def __init__(self, logger=None):
        """
        Initialize benchmark runner.

        Args:
            logger: Logger instance (optional)
        """
        self.logger = logger or setup_logger(__name__)

    def initialize_pgbench(
        self,
        ssh_client: SSHClient,
        db_name: str = "postgres",
        scale_factor: int = 1,
        db_user: str = "postgres"
    ) -> None:
        """
        Initialize pgbench database.

        Args:
            ssh_client: SSH client for remote execution
            db_name: Database name
            scale_factor: pgbench scale factor
            db_user: Database user
        """
        self.logger.info(f"Initializing pgbench database with scale factor {scale_factor}")

        # Get PostgreSQL bin directory
        pg_bin = self._get_pg_bin_path(ssh_client)

        # Initialize pgbench
        cmd = (
            f"{pg_bin}/pgbench -i "
            f"-s {scale_factor} "
            f"-U {db_user} "
            f"-d {db_name}"
        )

        ssh_client.execute_sudo(
            cmd,
            timeout=600,
            check=True
        )

        self.logger.info("pgbench database initialized")

    def run_benchmark(
        self,
        ssh_client: SSHClient,
        db_name: str = "postgres",
        db_user: str = "postgres",
        custom_script: Optional[Path] = None,
        clients: int = 1,
        threads: int = 1,
        duration: int = 60,
        host: str = "localhost",
        port: int = 5432
    ) -> Dict:
        """
        Run pgbench benchmark.

        Args:
            ssh_client: SSH client for remote execution
            db_name: Database name
            db_user: Database user
            custom_script: Path to custom pgbench script (local or remote)
            clients: Number of clients
            threads: Number of threads
            duration: Duration in seconds
            host: Database host
            port: Database port

        Returns:
            Dictionary with benchmark results
        """
        self.logger.info(
            f"Running pgbench: {clients} clients, {threads} threads, {duration}s duration"
        )

        pg_bin = self._get_pg_bin_path(ssh_client)

        # Handle custom script
        script_arg = ""
        if custom_script:
            if custom_script.exists():
                # Upload script to remote
                remote_script = f"/tmp/pgbench_script_{int(time.time())}.sql"
                ssh_client.upload_file(custom_script, remote_script)
                script_arg = f"-f {remote_script}"
            else:
                # Assume it's already on remote
                script_arg = f"-f {custom_script}"

        # Build pgbench command
        cmd_parts = [
            f"{pg_bin}/pgbench",
            "-n",  # No vacuum before tests
            script_arg,
            f"-c {clients}",
            f"-j {threads}",
            f"-T {duration}",
            f"-h {host}",
            f"-p {port}",
            f"-U {db_user}",
            f"-d {db_name}"
        ]

        cmd = " ".join([p for p in cmd_parts if p])  # Remove empty parts

        # Execute and capture output
        exit_code, stdout, stderr = ssh_client.execute_sudo(
            cmd,
            timeout=duration + 60,
            check=False
        )

        if exit_code != 0:
            self.logger.error(f"pgbench failed: {stderr}")
            raise RuntimeError(f"pgbench execution failed: {stderr}")

        # Parse results
        results = self._parse_pgbench_output(stdout, stderr)

        # Clean up uploaded script
        if custom_script and custom_script.exists():
            ssh_client.execute(f"rm -f {remote_script}", check=False)

        return results

    def _parse_pgbench_output(self, stdout: str, stderr: str) -> Dict:
        """
        Parse pgbench output to extract metrics.

        Args:
            stdout: Standard output from pgbench
            stderr: Standard error from pgbench

        Returns:
            Dictionary with parsed metrics
        """
        results = {
            'tps': None,
            'latency_ms': None,
            'stddev_ms': None,
            'transactions': None,
            'raw_output': stdout + stderr
        }

        # Parse TPS (transactions per second)
        tps_match = re.search(r'tps = ([\d.]+)', stdout)
        if tps_match:
            results['tps'] = float(tps_match.group(1))

        # Parse latency
        latency_match = re.search(r'latency = ([\d.]+) ms', stdout)
        if latency_match:
            results['latency_ms'] = float(latency_match.group(1))

        # Parse standard deviation
        stddev_match = re.search(r'stddev = ([\d.]+)', stdout)
        if stddev_match:
            results['stddev_ms'] = float(stddev_match.group(1))

        # Parse number of transactions
        trans_match = re.search(r'number of transactions actually processed: (\d+)', stdout)
        if trans_match:
            results['transactions'] = int(trans_match.group(1))

        # Parse more detailed stats if available
        # Client execution time
        exec_time_match = re.search(r'execution time = ([\d.]+) s', stdout)
        if exec_time_match:
            results['execution_time_s'] = float(exec_time_match.group(1))

        return results

    def run_parallel_benchmark(
        self,
        nodes: List[Dict],
        db_name: str = "postgres",
        db_user: str = "postgres",
        custom_script: Optional[Path] = None,
        clients: int = 1,
        threads: int = 1,
        duration: int = 60
    ) -> Dict:
        """
        Run benchmark on multiple nodes in parallel.

        Args:
            nodes: List of node dictionaries with 'ssh', 'name', 'dsn' keys
            db_name: Database name
            db_user: Database user
            custom_script: Path to custom pgbench script
            clients: Number of clients per node
            threads: Number of threads per node
            duration: Duration in seconds

        Returns:
            Dictionary with aggregated results
        """
        self.logger.info(f"Running parallel benchmark on {len(nodes)} nodes")

        import concurrent.futures
        import threading

        results = {}
        results_lock = threading.Lock()

        def run_on_node(node):
            """Run benchmark on a single node."""
            node_name = node['name']
            ssh = node['ssh']
            # Extract host and port from DSN
            host, port = self._parse_dsn(node.get('dsn', ''))
            if not host:
                host = "localhost"
            if not port:
                port = 5432

            try:
                result = self.run_benchmark(
                    ssh,
                    db_name=db_name,
                    db_user=db_user,
                    custom_script=custom_script,
                    clients=clients,
                    threads=threads,
                    duration=duration,
                    host=host,
                    port=port
                )
                with results_lock:
                    results[node_name] = result
                self.logger.info(f"Benchmark completed on {node_name}: {result.get('tps', 0):.2f} TPS")
            except Exception as e:
                self.logger.error(f"Benchmark failed on {node_name}: {e}")
                with results_lock:
                    results[node_name] = {'error': str(e)}

        # Run benchmarks in parallel
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(nodes)) as executor:
            futures = [executor.submit(run_on_node, node) for node in nodes]
            concurrent.futures.wait(futures)

        # Aggregate results
        aggregated = self._aggregate_results(results)
        return aggregated

    def _aggregate_results(self, results: Dict[str, Dict]) -> Dict:
        """
        Aggregate results from multiple nodes.

        Args:
            results: Dictionary mapping node names to their results

        Returns:
            Aggregated results dictionary
        """
        aggregated = {
            'nodes': results,
            'total_tps': 0.0,
            'avg_tps': 0.0,
            'avg_latency_ms': 0.0,
            'total_transactions': 0,
            'node_count': len(results)
        }

        valid_results = [
            r for r in results.values()
            if 'error' not in r and r.get('tps') is not None
        ]

        if valid_results:
            aggregated['total_tps'] = sum(r.get('tps', 0) for r in valid_results)
            aggregated['avg_tps'] = aggregated['total_tps'] / len(valid_results)
            aggregated['avg_latency_ms'] = sum(
                r.get('latency_ms', 0) for r in valid_results
            ) / len(valid_results)
            aggregated['total_transactions'] = sum(
                r.get('transactions', 0) for r in valid_results
            )

        return aggregated

    def _parse_dsn(self, dsn: str) -> tuple:
        """
        Parse DSN to extract host and port.

        Args:
            dsn: Database connection string

        Returns:
            Tuple of (host, port)
        """
        host = None
        port = None

        for part in dsn.split():
            if part.startswith('host='):
                host = part.split('=')[1]
            elif part.startswith('port='):
                port = int(part.split('=')[1])

        return host, port

    def _get_pg_bin_path(self, ssh_client: SSHClient) -> str:
        """Get PostgreSQL binary directory path."""
        # Try common locations
        possible_paths = [
            "/usr/lib/postgresql/18/bin",
            "/usr/pgsql-18/bin",
            "/usr/bin"
        ]

        for path in possible_paths:
            exit_code, _, _ = ssh_client.execute(
                f"test -f {path}/pgbench && echo exists",
                check=False
            )
            if exit_code == 0:
                return path

        # Fallback: find in PATH
        _, stdout, _ = ssh_client.execute("which pgbench", check=True)
        return str(Path(stdout.strip()).parent)

    def save_results(self, results: Dict, output_file: Path) -> None:
        """
        Save benchmark results to file.

        Args:
            results: Results dictionary
            output_file: Output file path (JSON or CSV)
        """
        output_file.parent.mkdir(parents=True, exist_ok=True)

        if output_file.suffix == '.json':
            with open(output_file, 'w') as f:
                json.dump(results, f, indent=2)
        elif output_file.suffix == '.csv':
            # Create CSV format
            import csv
            with open(output_file, 'w', newline='') as f:
                writer = csv.writer(f)
                writer.writerow(['Node', 'TPS', 'Latency (ms)', 'Transactions'])
                for node_name, node_results in results.get('nodes', {}).items():
                    if 'error' not in node_results:
                        writer.writerow([
                            node_name,
                            node_results.get('tps', ''),
                            node_results.get('latency_ms', ''),
                            node_results.get('transactions', '')
                        ])
                # Add aggregated row
                writer.writerow([
                    'TOTAL',
                    results.get('total_tps', ''),
                    results.get('avg_latency_ms', ''),
                    results.get('total_transactions', '')
                ])
        else:
            # Default to JSON
            output_file = output_file.with_suffix('.json')
            with open(output_file, 'w') as f:
                json.dump(results, f, indent=2)

        self.logger.info(f"Results saved to {output_file}")
