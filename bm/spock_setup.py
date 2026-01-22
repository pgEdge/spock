"""
Spock extension installation and configuration module.
Handles building Spock from source and installing the extension.
"""

import os
from pathlib import Path
from typing import Optional

from .utils.logger import setup_logger
from .utils.ssh_client import SSHClient


class SpockSetup:
    """Manages Spock extension installation."""

    def __init__(
        self,
        ssh_client: SSHClient,
        spock_repo_path: Optional[str] = None,
        logger=None
    ):
        """
        Initialize Spock setup.

        Args:
            ssh_client: SSH client for remote execution
            spock_repo_path: Path to Spock repository (local or remote)
            logger: Logger instance (optional)
        """
        self.ssh = ssh_client
        self.spock_repo_path = spock_repo_path or "https://github.com/pgEdge/spock.git"
        self.logger = logger or setup_logger(__name__)
        self.pg_version = "18"
        self.build_dir = "/tmp/spock-build"

    def install_build_dependencies(self) -> None:
        """Install dependencies required to build Spock."""
        self.logger.info("Installing Spock build dependencies")

        # Detect OS
        try:
            _, stdout, _ = self.ssh.execute("cat /etc/os-release", check=True)
            if 'Ubuntu' in stdout or 'Debian' in stdout:
                self._install_deps_debian()
            elif 'CentOS' in stdout or 'Rocky' in stdout or 'AlmaLinux' in stdout or 'Red Hat' in stdout or 'Fedora' in stdout:
                self._install_deps_redhat()
            else:
                self.logger.warning("Unknown OS, trying Debian-style installation")
                self._install_deps_debian()
        except Exception as e:
            self.logger.error(f"Error installing dependencies: {e}")
            raise

    def _install_deps_debian(self) -> None:
        """Install build dependencies on Debian/Ubuntu."""
        self.ssh.execute_sudo(
            "apt-get update",
            timeout=300,
            check=True
        )

        deps = [
            "build-essential",
            "git",
            "libjansson-dev",
            "postgresql-server-dev-18",
            "make",
            "gcc",
            "libc6-dev"
        ]

        self.ssh.execute_sudo(
            f"apt-get install -y {' '.join(deps)}",
            timeout=600,
            check=True
        )

    def _install_deps_redhat(self) -> None:
        """Install build dependencies on RHEL/CentOS/Fedora."""
        deps = [
            "gcc",
            "make",
            "git",
            "jansson-devel",
            f"postgresql{self.pg_version}-devel"
        ]

        self.ssh.execute_sudo(
            f"yum install -y {' '.join(deps)}",
            timeout=600,
            check=True
        )

    def clone_spock_repo(self, local_repo_path: Optional[Path] = None) -> None:
        """
        Clone or copy Spock repository to remote host.

        Args:
            local_repo_path: Local path to Spock repo (if available)
        """
        self.logger.info("Setting up Spock repository")

        # Clean up any existing build directory
        self.ssh.execute_sudo(f"rm -rf {self.build_dir}", check=False)

        if local_repo_path and local_repo_path.exists():
            # Upload local repository
            self.logger.info(f"Uploading Spock repository from {local_repo_path}")
            # Create a tarball and upload
            import tarfile
            import tempfile

            with tempfile.NamedTemporaryFile(suffix='.tar.gz', delete=False) as tmp:
                tar_path = Path(tmp.name)
                with tarfile.open(tar_path, 'w:gz') as tar:
                    tar.add(local_repo_path, arcname='spock')

                # Upload tarball
                remote_tar = "/tmp/spock.tar.gz"
                self.ssh.upload_file(tar_path, remote_tar)
                tar_path.unlink()

                # Extract on remote
                self.ssh.execute_sudo(
                    f"mkdir -p {self.build_dir} && tar -xzf {remote_tar} -C {self.build_dir}",
                    check=True
                )
                self.ssh.execute(f"rm -f {remote_tar}", check=False)
        else:
            # Clone from GitHub
            self.logger.info(f"Cloning Spock repository from {self.spock_repo_path}")
            self.ssh.execute_sudo(
                f"mkdir -p {self.build_dir}",
                check=True
            )
            self.ssh.execute(
                f"git clone {self.spock_repo_path} {self.build_dir}",
                timeout=300,
                check=True
            )

    def apply_postgres_patches(self) -> None:
        """Apply PostgreSQL 18 patches to PostgreSQL source (if needed)."""
        # Note: This assumes PostgreSQL is already patched or we're using a pre-patched version
        # In practice, you'd need to patch PostgreSQL source before building PostgreSQL
        # For this script, we assume PostgreSQL 18 is already installed and may need
        # the patches applied if building from source, but since we're installing from packages,
        # we skip this step. The patches are for building PostgreSQL itself, not Spock.
        self.logger.info("Skipping PostgreSQL patching (using package installation)")

    def build_and_install_spock(self) -> None:
        """Build and install Spock extension."""
        self.logger.info("Building Spock extension")

        # Get pg_config path
        pg_config_path = self._get_pg_config_path()

        # Set PATH to include pg_config directory
        pg_bin_dir = str(Path(pg_config_path).parent)
        export_path = f"export PATH={pg_bin_dir}:$PATH"

        # Build Spock
        build_commands = [
            f"cd {self.build_dir}",
            export_path,
            "make clean || true",
            "make",
            "sudo make install"
        ]

        build_script = " && ".join(build_commands)
        self.ssh.execute_sudo(
            build_script,
            timeout=600,
            check=True
        )

        self.logger.info("Spock extension built and installed")

    def create_spock_extension(self, db_name: str = "postgres", db_user: str = "postgres") -> None:
        """
        Create Spock extension in database.

        Args:
            db_name: Database name
            db_user: Database user
        """
        self.logger.info(f"Creating Spock extension in database {db_name}")

        # Create extension
        create_sql = "CREATE EXTENSION IF NOT EXISTS spock;"
        self.ssh.execute_sudo(
            f"su - postgres -c \"psql -d {db_name} -c '{create_sql}'\"",
            check=True
        )

        # Verify installation
        verify_sql = "SELECT spock_version();"
        _, stdout, _ = self.ssh.execute_sudo(
            f"su - postgres -c \"psql -d {db_name} -t -c '{verify_sql}'\"",
            check=True
        )
        version = stdout.strip()
        self.logger.info(f"Spock extension created successfully. Version: {version}")

    def _get_pg_config_path(self) -> str:
        """Get path to pg_config binary."""
        # Try common locations
        possible_paths = [
            f"/usr/lib/postgresql/{self.pg_version}/bin/pg_config",
            f"/usr/pgsql-{self.pg_version}/bin/pg_config",
            "/usr/bin/pg_config"
        ]

        for path in possible_paths:
            _, stdout, _ = self.ssh.execute(f"which pg_config || echo {path}", check=False)
            if stdout.strip() and 'not found' not in stdout:
                result = stdout.strip()
                # Verify it exists
                exit_code, _, _ = self.ssh.execute(f"test -f {result} && echo exists", check=False)
                if exit_code == 0:
                    return result

        # Fallback: find in PATH
        _, stdout, _ = self.ssh.execute("which pg_config", check=True)
        return stdout.strip()

    def install(
        self,
        db_name: str = "postgres",
        db_user: str = "postgres",
        local_repo_path: Optional[Path] = None
    ) -> None:
        """
        Complete Spock installation process.

        Args:
            db_name: Database name
            db_user: Database user
            local_repo_path: Local path to Spock repository (optional)
        """
        self.logger.info("Starting Spock installation")
        self.install_build_dependencies()
        self.clone_spock_repo(local_repo_path)
        self.apply_postgres_patches()
        self.build_and_install_spock()
        self.create_spock_extension(db_name, db_user)
        self.logger.info("Spock installation completed")
