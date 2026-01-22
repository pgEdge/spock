"""
SSH client utilities for remote command execution.
Uses Paramiko for SSH connections with connection pooling.
"""

import time
from pathlib import Path
from typing import List, Optional, Tuple

import paramiko


class SSHClient:
    """SSH client with connection pooling and retry logic."""

    def __init__(
        self,
        hostname: str,
        username: str = "root",
        password: Optional[str] = None,
        key_file: Optional[Path] = None,
        port: int = 22,
        timeout: int = 30
    ):
        """
        Initialize SSH client.

        Args:
            hostname: Remote hostname or IP
            username: SSH username
            password: SSH password (if not using key)
            key_file: Path to SSH private key file
            port: SSH port
            timeout: Connection timeout in seconds
        """
        self.hostname = hostname
        self.username = username
        self.password = password
        self.key_file = key_file
        self.port = port
        self.timeout = timeout
        self._client: Optional[paramiko.SSHClient] = None

    def connect(self, retries: int = 3, delay: int = 5) -> None:
        """
        Establish SSH connection with retry logic.

        Args:
            retries: Number of retry attempts
            delay: Delay between retries in seconds

        Raises:
            paramiko.SSHException: If connection fails after retries
        """
        for attempt in range(retries):
            try:
                self._client = paramiko.SSHClient()
                self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

                # Prepare authentication
                auth_kwargs = {
                    'hostname': self.hostname,
                    'username': self.username,
                    'port': self.port,
                    'timeout': self.timeout
                }

                if self.key_file:
                    auth_kwargs['key_filename'] = str(self.key_file)
                elif self.password:
                    auth_kwargs['password'] = self.password

                self._client.connect(**auth_kwargs)
                return
            except Exception as e:
                if attempt < retries - 1:
                    time.sleep(delay)
                else:
                    raise paramiko.SSHException(
                        f"Failed to connect to {self.hostname} after {retries} attempts: {e}"
                    )

    def disconnect(self) -> None:
        """Close SSH connection."""
        if self._client:
            self._client.close()
            self._client = None

    def execute(
        self,
        command: str,
        timeout: Optional[int] = None,
        check: bool = True
    ) -> Tuple[int, str, str]:
        """
        Execute command on remote host.

        Args:
            command: Command to execute
            timeout: Command timeout in seconds
            check: If True, raise exception on non-zero exit code

        Returns:
            Tuple of (exit_code, stdout, stderr)

        Raises:
            RuntimeError: If check=True and command fails
        """
        if not self._client:
            self.connect()

        stdin, stdout, stderr = self._client.exec_command(command, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        stdout_text = stdout.read().decode('utf-8')
        stderr_text = stderr.read().decode('utf-8')

        if check and exit_code != 0:
            raise RuntimeError(
                f"Command failed: {command}\n"
                f"Exit code: {exit_code}\n"
                f"Stderr: {stderr_text}"
            )

        return exit_code, stdout_text, stderr_text

    def execute_sudo(
        self,
        command: str,
        password: Optional[str] = None,
        timeout: Optional[int] = None,
        check: bool = True
    ) -> Tuple[int, str, str]:
        """
        Execute command with sudo.

        Args:
            command: Command to execute
            password: Sudo password (if required)
            timeout: Command timeout
            check: If True, raise exception on failure

        Returns:
            Tuple of (exit_code, stdout, stderr)
        """
        sudo_cmd = f"sudo -S {command}"
        if password:
            sudo_cmd = f"echo '{password}' | {sudo_cmd}"

        return self.execute(sudo_cmd, timeout=timeout, check=check)

    def upload_file(
        self,
        local_path: Path,
        remote_path: str,
        mode: int = 0o644
    ) -> None:
        """
        Upload file to remote host.

        Args:
            local_path: Local file path
            remote_path: Remote file path
            mode: File permissions (octal)
        """
        if not self._client:
            self.connect()

        sftp = self._client.open_sftp()
        try:
            sftp.put(str(local_path), remote_path)
            sftp.chmod(remote_path, mode)
        finally:
            sftp.close()

    def download_file(
        self,
        remote_path: str,
        local_path: Path
    ) -> None:
        """
        Download file from remote host.

        Args:
            remote_path: Remote file path
            local_path: Local file path
        """
        if not self._client:
            self.connect()

        sftp = self._client.open_sftp()
        try:
            sftp.get(remote_path, str(local_path))
        finally:
            sftp.close()

    def wait_for_ssh(self, max_wait: int = 300, interval: int = 5) -> bool:
        """
        Wait for SSH to become available.

        Args:
            max_wait: Maximum wait time in seconds
            interval: Check interval in seconds

        Returns:
            True if SSH becomes available, False if timeout
        """
        start_time = time.time()
        while time.time() - start_time < max_wait:
            try:
                test_client = paramiko.SSHClient()
                test_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                auth_kwargs = {
                    'hostname': self.hostname,
                    'username': self.username,
                    'port': self.port,
                    'timeout': 5
                }
                if self.key_file:
                    auth_kwargs['key_filename'] = str(self.key_file)
                elif self.password:
                    auth_kwargs['password'] = self.password

                test_client.connect(**auth_kwargs)
                test_client.close()
                return True
            except Exception:
                time.sleep(interval)

        return False

    def __enter__(self):
        """Context manager entry."""
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.disconnect()
