#!/usr/bin/env python3
"""
Spock Benchmark Suite for ProxMox
Main entry point for creating Spock clusters and running benchmarks.
"""

import argparse
import sys
from pathlib import Path
from typing import Optional

from .benchmark_runner import BenchmarkRunner
from .cluster_manager import ClusterManager
from .postgres_setup import PostgresSetup
from .proxmox_manager import ProxMoxManager
from .spock_setup import SpockSetup
from .utils.config import Config
from .utils.logger import setup_logger
from .utils.ssh_client import SSHClient


class BenchmarkCLI:
    """Main CLI interface for Spock benchmark suite."""

    def __init__(self):
        """Initialize CLI."""
        self.logger = None
        self.config = None
        self.proxmox = None
        self.vms = []

    def parse_args(self) -> argparse.Namespace:
        """Parse command line arguments."""
        parser = argparse.ArgumentParser(
            description='Spock Benchmark Suite for ProxMox',
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog="""
Examples:
  # Create a 3-node cluster
  %(prog)s create --proxmox-host 192.168.1.100:8006 \\
      --proxmox-user admin --proxmox-password secret \\
      --template ubuntu-22.04 --node-count 3

  # Run benchmark
  %(prog)s benchmark --pgbench-script custom.sql \\
      --clients 10 --duration 300

  # Check cluster status
  %(prog)s status

  # Destroy cluster
  %(prog)s destroy
            """
        )

        # Global options
        parser.add_argument(
            '--config',
            type=Path,
            help='Configuration file path (YAML or JSON)'
        )
        parser.add_argument(
            '--verbose', '-v',
            action='store_true',
            help='Enable verbose output'
        )
        parser.add_argument(
            '--output-dir',
            type=Path,
            default=Path('./benchmark_results'),
            help='Output directory for results (default: ./benchmark_results)'
        )

        # ProxMox options
        proxmox_group = parser.add_argument_group('ProxMox Options')
        proxmox_group.add_argument(
            '--proxmox-host',
            help='ProxMox API host (e.g., 192.168.1.100:8006)'
        )
        proxmox_group.add_argument(
            '--proxmox-user',
            help='ProxMox username (format: user@realm)'
        )
        proxmox_group.add_argument(
            '--proxmox-password',
            help='ProxMox password'
        )
        proxmox_group.add_argument(
            '--template',
            help='VM template name or ID'
        )
        proxmox_group.add_argument(
            '--node-count',
            type=int,
            default=3,
            help='Number of nodes to create (default: 3)'
        )
        proxmox_group.add_argument(
            '--vm-cores',
            type=int,
            default=2,
            help='CPU cores per VM (default: 2)'
        )
        proxmox_group.add_argument(
            '--vm-memory',
            type=int,
            default=4096,
            help='Memory per VM in MB (default: 4096)'
        )
        proxmox_group.add_argument(
            '--vm-disk-size',
            default='32G',
            help='Disk size per VM (default: 32G)'
        )

        # Database options
        db_group = parser.add_argument_group('Database Options')
        db_group.add_argument(
            '--db-name',
            default='postgres',
            help='Database name (default: postgres)'
        )
        db_group.add_argument(
            '--db-user',
            default='postgres',
            help='Database user (default: postgres)'
        )
        db_group.add_argument(
            '--db-password',
            help='Database password (if required)'

        # SSH options
        ssh_group = parser.add_argument_group('SSH Options')
        ssh_group.add_argument(
            '--ssh-user',
            default='root',
            help='SSH username (default: root)'
        )
        ssh_group.add_argument(
            '--ssh-password',
            help='SSH password'
        )
        ssh_group.add_argument(
            '--ssh-key',
            type=Path,
            help='SSH private key file path'
        )

        # Benchmark options
        benchmark_group = parser.add_argument_group('Benchmark Options')
        benchmark_group.add_argument(
            '--pgbench-script',
            type=Path,
            help='Custom pgbench script file path'
        )
        benchmark_group.add_argument(
            '--scale-factor',
            type=int,
            default=1,
            help='pgbench scale factor (default: 1)'
        )
        benchmark_group.add_argument(
            '--clients',
            type=int,
            default=1,
            help='Number of pgbench clients (default: 1)'
        )
        benchmark_group.add_argument(
            '--threads',
            type=int,
            default=1,
            help='Number of pgbench threads (default: 1)'
        )
        benchmark_group.add_argument(
            '--duration',
            type=int,
            default=60,
            help='Benchmark duration in seconds (default: 60)'
        )

        # Spock options
        spock_group = parser.add_argument_group('Spock Options')
        spock_group.add_argument(
            '--spock-repo',
            help='Spock repository path (local or GitHub URL)'
        )

        # Subcommands
        subparsers = parser.add_subparsers(dest='command', help='Command to execute')

        # Create command
        create_parser = subparsers.add_parser(
            'create',
            help='Create and configure VMs with Spock cluster'
        )

        # Destroy command
        destroy_parser = subparsers.add_parser(
            'destroy',
            help='Destroy all created VMs'
        )

        # Benchmark command
        benchmark_parser = subparsers.add_parser(
            'benchmark',
            help='Run pgbench benchmark'
        )

        # Status command
        status_parser = subparsers.add_parser(
            'status',
            help='Show cluster status'
        )

        return parser.parse_args()

    def load_config(self, config_file: Optional[Path], args: argparse.Namespace) -> None:
        """Load configuration from file and merge with command line arguments."""
        self.config = Config(config_file) if config_file else Config()

        # Override config with command line arguments
        if args.proxmox_host:
            self.config.set('proxmox.host', args.proxmox_host)
        if args.proxmox_user:
            self.config.set('proxmox.user', args.proxmox_user)
        if args.proxmox_password:
            self.config.set('proxmox.password', args.proxmox_password)

    def setup_logging(self, verbose: bool) -> None:
        """Set up logging."""
        log_file = self.config.get('log_file') if self.config else None
        self.logger = setup_logger(
            __name__,
            log_file=Path(log_file) if log_file else None,
            verbose=verbose
        )

    def get_proxmox_manager(self, args: argparse.Namespace) -> ProxMoxManager:
        """Get or create ProxMox manager instance."""
        if not self.proxmox:
            host = args.proxmox_host or self.config.get('proxmox.host')
            user = args.proxmox_user or self.config.get('proxmox.user')
            password = args.proxmox_password or self.config.get('proxmox.password')

            if not all([host, user, password]):
                raise ValueError(
                    "ProxMox credentials required. "
                    "Provide --proxmox-host, --proxmox-user, --proxmox-password "
                    "or use config file."
                )

            self.proxmox = ProxMoxManager(
                host=host,
                user=user,
                password=password,
                logger=self.logger
            )

        return self.proxmox

    def create_cluster(self, args: argparse.Namespace) -> None:
        """Create and configure Spock cluster."""
        self.logger.info("Starting cluster creation")

        proxmox = self.get_proxmox_manager(args)
        template = args.template or self.config.get('proxmox.template')
        if not template:
            raise ValueError("Template required. Provide --template or set in config.")

        node_count = args.node_count
        self.logger.info(f"Creating {node_count} VMs from template {template}")

        # Create VMs
        vms = []
        for i in range(1, node_count + 1):
            vm_name = f"spock-node-{i}"
            self.logger.info(f"Creating VM: {vm_name}")

            vmid = proxmox.create_vm(
                name=vm_name,
                template=template,
                cores=args.vm_cores,
                memory=args.vm_memory,
                disk_size=args.vm_disk_size
            )

            proxmox.start_vm(vmid)
            ip = proxmox.get_vm_ip(vmid)

            if not ip:
                raise RuntimeError(f"Could not get IP for VM {vmid}")

            vms.append({
                'vmid': vmid,
                'name': vm_name,
                'ip': ip
            })

            self.logger.info(f"VM {vm_name} (ID: {vmid}) is ready at {ip}")

        self.vms = vms

        # Wait for SSH to be available on all VMs
        self.logger.info("Waiting for SSH to be available on all VMs")
        for vm in vms:
            ssh = SSHClient(
                hostname=vm['ip'],
                username=args.ssh_user,
                password=args.ssh_password,
                key_file=args.ssh_key
            )
            if not ssh.wait_for_ssh():
                raise RuntimeError(f"SSH not available on {vm['name']} ({vm['ip']})")
            ssh.connect()
            vm['ssh'] = ssh

        # Install and configure PostgreSQL on all nodes
        self.logger.info("Installing PostgreSQL 18 on all nodes")
        for vm in vms:
            pg_setup = PostgresSetup(vm['ssh'], logger=self.logger)
            pg_setup.install_postgresql()
            pg_setup.configure_postgresql(
                db_name=args.db_name,
                db_user=args.db_user
            )

        # Install Spock on all nodes
        self.logger.info("Installing Spock extension on all nodes")
        spock_repo = args.spock_repo or self.config.get('spock.repo')
        local_repo = Path(spock_repo) if spock_repo and Path(spock_repo).exists() else None

        for vm in vms:
            spock_setup = SpockSetup(
                vm['ssh'],
                spock_repo_path=spock_repo,
                logger=self.logger
            )
            spock_setup.install(
                db_name=args.db_name,
                db_user=args.db_user,
                local_repo_path=local_repo
            )

        # Set up multi-master replication
        self.logger.info("Setting up multi-master replication")
        cluster = ClusterManager(logger=self.logger)

        for vm in vms:
            dsn = f"host={vm['ip']} port=5432 dbname={args.db_name} user={args.db_user}"
            cluster.add_node(
                node_name=vm['name'],
                ssh_client=vm['ssh'],
                dsn=dsn,
                db_name=args.db_name,
                db_user=args.db_user
            )

        cluster.setup_multi_master_cluster(db_name=args.db_name)

        self.logger.info("Cluster creation completed successfully")

    def destroy_cluster(self, args: argparse.Namespace) -> None:
        """Destroy all VMs in cluster."""
        self.logger.info("Destroying cluster")

        proxmox = self.get_proxmox_manager(args)
        vms = proxmox.list_vms(name_prefix="spock-node")

        if not vms:
            self.logger.info("No VMs found to destroy")
            return

        for vm in vms:
            try:
                proxmox.destroy_vm(vm['vmid'])
            except Exception as e:
                self.logger.error(f"Error destroying VM {vm['vmid']}: {e}")

        self.logger.info("Cluster destruction completed")

    def run_benchmark(self, args: argparse.Namespace) -> None:
        """Run pgbench benchmark."""
        self.logger.info("Starting benchmark")

        # Get cluster nodes
        proxmox = self.get_proxmox_manager(args)
        vms = proxmox.list_vms(name_prefix="spock-node")

        if not vms:
            raise RuntimeError("No cluster nodes found. Create cluster first.")

        # Set up SSH connections
        nodes = []
        for vm in vms:
            ip = proxmox.get_vm_ip(vm['vmid'])
            if not ip:
                self.logger.warning(f"Could not get IP for VM {vm['vmid']}, skipping")
                continue

            ssh = SSHClient(
                hostname=ip,
                username=args.ssh_user,
                password=args.ssh_password,
                key_file=args.ssh_key
            )
            ssh.connect()

            dsn = f"host={ip} port=5432 dbname={args.db_name} user={args.db_user}"
            nodes.append({
                'name': vm.get('name', f"spock-node-{vm['vmid']}"),
                'ssh': ssh,
                'dsn': dsn
            })

        if not nodes:
            raise RuntimeError("No accessible nodes found")

        # Initialize pgbench on first node
        runner = BenchmarkRunner(logger=self.logger)
        self.logger.info("Initializing pgbench database")
        runner.initialize_pgbench(
            nodes[0]['ssh'],
            db_name=args.db_name,
            scale_factor=args.scale_factor,
            db_user=args.db_user
        )

        # Wait for replication
        self.logger.info("Waiting for replication to complete")
        import time
        time.sleep(10)  # Give replication time to sync

        # Run benchmark
        custom_script = args.pgbench_script
        if custom_script and not custom_script.exists():
            self.logger.warning(f"Custom script not found: {custom_script}")
            custom_script = None

        results = runner.run_parallel_benchmark(
            nodes=nodes,
            db_name=args.db_name,
            db_user=args.db_user,
            custom_script=custom_script,
            clients=args.clients,
            threads=args.threads,
            duration=args.duration
        )

        # Save results
        output_file = args.output_dir / f"benchmark_{int(time.time())}.json"
        runner.save_results(results, output_file)

        # Print summary
        self.logger.info("Benchmark completed")
        self.logger.info(f"Total TPS: {results.get('total_tps', 0):.2f}")
        self.logger.info(f"Average TPS: {results.get('avg_tps', 0):.2f}")
        self.logger.info(f"Results saved to: {output_file}")

    def show_status(self, args: argparse.Namespace) -> None:
        """Show cluster status."""
        # Get cluster nodes
        proxmox = self.get_proxmox_manager(args)
        vms = proxmox.list_vms(name_prefix="spock-node")

        if not vms:
            print("No cluster nodes found.")
            return

        print(f"Found {len(vms)} cluster nodes:")
        for vm in vms:
            status = proxmox.get_vm_status(vm['vmid'])
            ip = proxmox.get_vm_ip(vm['vmid'])
            print(f"  {vm.get('name', 'unknown')} (ID: {vm['vmid']}): {status} - {ip or 'N/A'}")

    def run(self) -> int:
        """Main entry point."""
        args = self.parse_args()

        if not args.command:
            self.parse_args().print_help()
            return 1

        try:
            self.load_config(args.config, args)
            self.setup_logging(args.verbose)

            if args.command == 'create':
                self.create_cluster(args)
            elif args.command == 'destroy':
                self.destroy_cluster(args)
            elif args.command == 'benchmark':
                self.run_benchmark(args)
            elif args.command == 'status':
                self.show_status(args)
            else:
                self.logger.error(f"Unknown command: {args.command}")
                return 1

            return 0
        except KeyboardInterrupt:
            self.logger.info("Interrupted by user")
            return 130
        except Exception as e:
            if self.logger:
                self.logger.error(f"Error: {e}", exc_info=args.verbose)
            else:
                print(f"Error: {e}", file=sys.stderr)
            return 1
        finally:
            # Clean up SSH connections
            for vm in getattr(self, 'vms', []):
                if 'ssh' in vm:
                    try:
                        vm['ssh'].disconnect()
                    except Exception:
                        pass


def main():
    """Entry point for command line execution."""
    cli = BenchmarkCLI()
    sys.exit(cli.run())


if __name__ == '__main__':
    main()
