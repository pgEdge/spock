"""
PostgreSQL 18 installation and configuration module.
Handles installation, configuration, and service management.
"""

import re
from pathlib import Path
from typing import Optional, Tuple

from .utils.logger import setup_logger
from .utils.ssh_client import SSHClient


class PostgresSetup:
    """Manages PostgreSQL 18 installation and configuration."""

    def __init__(self, ssh_client: SSHClient, logger=None):
        """
        Initialize PostgreSQL setup.

        Args:
            ssh_client: SSH client for remote execution
            logger: Logger instance (optional)
        """
        self.ssh = ssh_client
        self.logger = logger or setup_logger(__name__)
        self.os_type: Optional[str] = None
        self.pg_version = "18"

    def detect_os(self) -> str:
        """
        Detect operating system type.

        Returns:
            OS type ('ubuntu', 'debian', 'centos', 'rhel', 'fedora')
        """
        if self.os_type:
            return self.os_type

        try:
            _, stdout, _ = self.ssh.execute("cat /etc/os-release", check=True)
            if 'Ubuntu' in stdout or 'Debian' in stdout:
                if 'Ubuntu' in stdout:
                    self.os_type = 'ubuntu'
                else:
                    self.os_type = 'debian'
            elif 'CentOS' in stdout or 'Rocky' in stdout or 'AlmaLinux' in stdout:
                self.os_type = 'centos'
            elif 'Red Hat' in stdout:
                self.os_type = 'rhel'
            elif 'Fedora' in stdout:
                self.os_type = 'fedora'
            else:
                self.os_type = 'ubuntu'  # Default assumption

            self.logger.info(f"Detected OS: {self.os_type}")
            return self.os_type
        except Exception as e:
            self.logger.warning(f"Could not detect OS, assuming Ubuntu: {e}")
            self.os_type = 'ubuntu'
            return self.os_type

    def install_postgresql(self) -> None:
        """Install PostgreSQL 18 from official repository."""
        os_type = self.detect_os()
        self.logger.info(f"Installing PostgreSQL {self.pg_version} on {os_type}")

        if os_type in ['ubuntu', 'debian']:
            self._install_postgresql_debian()
        elif os_type in ['centos', 'rhel', 'fedora']:
            self._install_postgresql_redhat()
        else:
            raise RuntimeError(f"Unsupported OS type: {os_type}")

        self.logger.info("PostgreSQL installation completed")

    def _install_postgresql_debian(self) -> None:
        """Install PostgreSQL on Debian/Ubuntu."""
        # Install prerequisites
        self.ssh.execute_sudo(
            "apt-get update",
            timeout=300,
            check=True
        )

        self.ssh.execute_sudo(
            "apt-get install -y wget ca-certificates",
            timeout=300,
            check=True
        )

        # Add PostgreSQL official repository
        self.ssh.execute_sudo(
            f"sh -c 'echo \"deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main\" > /etc/apt/sources.list.d/pgdg.list'",
            check=True
        )

        # Import repository signing key
        self.ssh.execute_sudo(
            "wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -",
            check=True
        )

        # Update and install
        self.ssh.execute_sudo(
            "apt-get update",
            timeout=300,
            check=True
        )

        self.ssh.execute_sudo(
            f"apt-get install -y postgresql-{self.pg_version} postgresql-client-{self.pg_version}",
            timeout=600,
            check=True
        )

    def _install_postgresql_redhat(self) -> None:
        """Install PostgreSQL on RHEL/CentOS/Fedora."""
        # Install prerequisites
        self.ssh.execute_sudo(
            "yum install -y wget",
            timeout=300,
            check=True
        )

        # Add PostgreSQL repository
        if self.os_type == 'fedora':
            repo_url = f"https://download.postgresql.org/pub/repos/yum/reporpms/F-$(rpm -E %fedora)-x86_64/pgdg-fedora-repo-latest.noarch.rpm"
        else:
            repo_url = f"https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %rhel)-x86_64/pgdg-redhat-repo-latest.noarch.rpm"

        self.ssh.execute_sudo(
            f"yum install -y {repo_url}",
            timeout=300,
            check=True
        )

        # Disable default PostgreSQL module (if exists)
        self.ssh.execute_sudo(
            "yum module disable -y postgresql",
            check=False  # May not exist
        )

        # Install PostgreSQL
        self.ssh.execute_sudo(
            f"yum install -y postgresql{self.pg_version}-server postgresql{self.pg_version}",
            timeout=600,
            check=True
        )

        # Initialize database (if not already initialized)
        self.ssh.execute_sudo(
            f"/usr/pgsql-{self.pg_version}/bin/postgresql-{self.pg_version}-setup initdb",
            check=False  # May already be initialized
        )

    def configure_postgresql(self, db_name: str = "postgres", db_user: str = "postgres") -> None:
        """
        Configure PostgreSQL for Spock replication.

        Args:
            db_name: Database name
            db_user: Database user
        """
        self.logger.info("Configuring PostgreSQL for Spock")

        os_type = self.detect_os()
        if os_type in ['ubuntu', 'debian']:
            config_file = f"/etc/postgresql/{self.pg_version}/main/postgresql.conf"
            hba_file = f"/etc/postgresql/{self.pg_version}/main/pg_hba.conf"
            data_dir = f"/var/lib/postgresql/{self.pg_version}/main"
        else:
            config_file = f"/var/lib/pgsql/{self.pg_version}/data/postgresql.conf"
            hba_file = f"/var/lib/pgsql/{self.pg_version}/data/pg_hba.conf"
            data_dir = f"/var/lib/pgsql/{self.pg_version}/data"

        # Configure postgresql.conf
        self._configure_postgresql_conf(config_file)
        self._configure_pg_hba(hba_file)

        # Create database if it doesn't exist
        self._create_database(db_name, db_user)

        # Restart PostgreSQL
        self._restart_postgresql()

        self.logger.info("PostgreSQL configuration completed")

    def _configure_postgresql_conf(self, config_file: str) -> None:
        """Configure postgresql.conf for Spock."""
        config_updates = {
            "wal_level": "logical",
            "max_worker_processes": "10",
            "max_replication_slots": "10",
            "max_wal_senders": "10",
            "shared_preload_libraries": "spock",
            "track_commit_timestamp": "on",
            "spock.enable_ddl_replication": "on",
            "spock.include_ddl_repset": "on",
            "spock.allow_ddl_from_functions": "on"
        }

        # Read current config
        _, stdout, _ = self.ssh.execute_sudo(f"cat {config_file}", check=True)
        config_lines = stdout.split('\n')

        # Update or add settings
        for key, value in config_updates.items():
            pattern = re.compile(rf'^\s*#?\s*{re.escape(key)}\s*=')
            found = False
            for i, line in enumerate(config_lines):
                if pattern.match(line):
                    config_lines[i] = f"{key} = '{value}'"
                    found = True
                    break
            if not found:
                config_lines.append(f"{key} = '{value}'")

        # Write updated config
        config_content = '\n'.join(config_lines)
        temp_file = "/tmp/postgresql.conf.new"
        self.ssh.execute(f"cat > {temp_file} << 'EOF'\n{config_content}\nEOF", check=True)
        self.ssh.execute_sudo(f"mv {temp_file} {config_file}", check=True)
        self.ssh.execute_sudo(f"chown postgres:postgres {config_file}", check=True)

    def _configure_pg_hba(self, hba_file: str) -> None:
        """Configure pg_hba.conf for replication."""
        # Add replication entries if not present
        hba_entries = [
            "host all all 0.0.0.0/0 md5",
            "local replication all trust",
            "host replication all 0.0.0.0/0 md5"
        ]

        _, stdout, _ = self.ssh.execute_sudo(f"cat {hba_file}", check=True)
        existing_content = stdout

        for entry in hba_entries:
            if entry not in existing_content:
                self.ssh.execute_sudo(
                    f"echo '{entry}' >> {hba_file}",
                    check=True
                )

    def _create_database(self, db_name: str, db_user: str) -> None:
        """Create database if it doesn't exist."""
        # Check if database exists
        _, stdout, _ = self.ssh.execute_sudo(
            f"su - postgres -c \"psql -lqt | cut -d \\| -f 1 | grep -qw {db_name}\"",
            check=False
        )

        # Create database if needed (using default postgres database)
        self.ssh.execute_sudo(
            f"su - postgres -c \"psql -c 'SELECT 1 FROM pg_database WHERE datname = \\'{db_name}\\'' | grep -q 1 || createdb {db_name}\"",
            check=False
        )

    def _restart_postgresql(self) -> None:
        """Restart PostgreSQL service."""
        os_type = self.detect_os()
        if os_type in ['ubuntu', 'debian']:
            service_name = f"postgresql@{self.pg_version}-main"
        else:
            service_name = f"postgresql-{self.pg_version}"

        self.ssh.execute_sudo(
            f"systemctl restart {service_name}",
            check=True
        )

        self.ssh.execute_sudo(
            f"systemctl enable {service_name}",
            check=True
        )

        # Wait for PostgreSQL to be ready
        self._wait_for_postgresql()

    def _wait_for_postgresql(self, max_wait: int = 60) -> None:
        """Wait for PostgreSQL to be ready."""
        import time
        start_time = time.time()
        while time.time() - start_time < max_wait:
            try:
                self.ssh.execute_sudo(
                    f"su - postgres -c 'pg_isready'",
                    check=True
                )
                self.logger.info("PostgreSQL is ready")
                return
            except Exception:
                time.sleep(2)

        raise RuntimeError(f"PostgreSQL did not become ready within {max_wait} seconds")

    def get_connection_string(self, db_name: str = "postgres", db_user: str = "postgres", host: str = "localhost", port: int = 5432) -> str:
        """
        Get PostgreSQL connection string.

        Args:
            db_name: Database name
            db_user: Database user
            host: Database host
            port: Database port

        Returns:
            Connection string (DSN format)
        """
        return f"host={host} port={port} dbname={db_name} user={db_user}"

    def get_pg_config_path(self) -> str:
        """
        Get path to pg_config binary.

        Returns:
            Path to pg_config
        """
        os_type = self.detect_os()
        if os_type in ['ubuntu', 'debian']:
            return f"/usr/lib/postgresql/{self.pg_version}/bin/pg_config"
        else:
            return f"/usr/pgsql-{self.pg_version}/bin/pg_config"
