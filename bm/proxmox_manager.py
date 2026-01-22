"""
ProxMox VM management module.
Handles VM creation, configuration, and lifecycle management.
"""

import time
from typing import Dict, List, Optional

from proxmoxer import ProxmoxAPI

from .utils.logger import setup_logger


class ProxMoxManager:
    """Manages ProxMox VMs for Spock cluster."""

    def __init__(
        self,
        host: str,
        user: str,
        password: str,
        verify_ssl: bool = False,
        logger=None
    ):
        """
        Initialize ProxMox manager.

        Args:
            host: ProxMox API host (e.g., '192.168.1.100:8006')
            user: ProxMox username (format: 'user@realm' or 'user')
            password: ProxMox password
            verify_ssl: Whether to verify SSL certificates
            logger: Logger instance (optional)
        """
        self.host = host
        self.user = user
        self.password = password
        self.verify_ssl = verify_ssl
        self.logger = logger or setup_logger(__name__)

        # Parse user@realm format
        if '@' in user:
            self.username, self.realm = user.split('@', 1)
        else:
            self.username = user
            self.realm = 'pam'

        # Initialize ProxMox API connection
        self.proxmox = ProxmoxAPI(
            host,
            user=self.username,
            password=password,
            verify_ssl=verify_ssl,
            auth_type='password'
        )

        # Extract node name (first available node)
        nodes = self.proxmox.nodes.get()
        if not nodes:
            raise RuntimeError("No ProxMox nodes available")
        self.node_name = nodes[0]['node']

        self.logger.info(f"Connected to ProxMox node: {self.node_name}")

    def find_template(self, template_name: str) -> Optional[Dict]:
        """
        Find VM template by name or ID.

        Args:
            template_name: Template name or VMID

        Returns:
            Template info dict or None
        """
        try:
            # Try as VMID first
            vmid = int(template_name)
            vms = self.proxmox.nodes(self.node_name).qemu.get()
            for vm in vms:
                if vm['vmid'] == vmid:
                    return vm
        except ValueError:
            # Search by name
            vms = self.proxmox.nodes(self.node_name).qemu.get()
            for vm in vms:
                if vm.get('name') == template_name or str(vm['vmid']) == template_name:
                    return vm

        return None

    def get_next_vmid(self) -> int:
        """
        Get next available VM ID.

        Returns:
            Next available VMID
        """
        vms = self.proxmox.nodes(self.node_name).qemu.get()
        used_vmids = {vm['vmid'] for vm in vms}
        vmid = 100
        while vmid in used_vmids:
            vmid += 1
        return vmid

    def create_vm(
        self,
        name: str,
        template: str,
        vmid: Optional[int] = None,
        cores: int = 2,
        memory: int = 4096,
        disk_size: str = "32G",
        storage: str = "local-lvm"
    ) -> int:
        """
        Create VM by cloning from template.

        Args:
            name: VM name
            template: Template name or VMID
            vmid: VM ID (auto-assigned if None)
            cores: Number of CPU cores
            memory: Memory in MB
            disk_size: Disk size (e.g., "32G")
            storage: Storage name

        Returns:
            Created VM ID
        """
        template_vm = self.find_template(template)
        if not template_vm:
            raise ValueError(f"Template not found: {template}")

        template_vmid = template_vm['vmid']
        if vmid is None:
            vmid = self.get_next_vmid()

        self.logger.info(f"Cloning template {template_vmid} to VM {vmid} ({name})")

        # Clone VM
        clone_params = {
            'newid': vmid,
            'name': name,
            'full': 1  # Full clone
        }
        task = self.proxmox.nodes(self.node_name).qemu(template_vmid).clone.post(**clone_params)
        task_id = task['data']

        # Wait for clone to complete
        self._wait_for_task(task_id)

        # Configure VM resources
        self.logger.info(f"Configuring VM {vmid} resources")
        config_params = {
            'cores': cores,
            'memory': memory
        }
        self.proxmox.nodes(self.node_name).qemu(vmid).config.put(**config_params)

        # Resize disk if needed
        if disk_size:
            self._resize_disk(vmid, disk_size, storage)

        self.logger.info(f"VM {vmid} created successfully")
        return vmid

    def _resize_disk(self, vmid: int, disk_size: str, storage: str) -> None:
        """Resize VM disk."""
        try:
            # Get current disk info
            config = self.proxmox.nodes(self.node_name).qemu(vmid).config.get()
            scsi0 = config.get('scsi0', '')
            if not scsi0:
                self.logger.warning(f"No disk found for VM {vmid}, skipping resize")
                return

            # Extract current size and resize
            disk_name = scsi0.split(',')[0]
            resize_params = {
                'disk': disk_name,
                'size': disk_size
            }
            task = self.proxmox.nodes(self.node_name).qemu(vmid).resize.put(**resize_params)
            self._wait_for_task(task['data'])
        except Exception as e:
            self.logger.warning(f"Failed to resize disk for VM {vmid}: {e}")

    def start_vm(self, vmid: int) -> None:
        """
        Start VM.

        Args:
            vmid: VM ID
        """
        self.logger.info(f"Starting VM {vmid}")
        task = self.proxmox.nodes(self.node_name).qemu(vmid).status.start.post()
        self._wait_for_task(task['data'])

        # Wait for VM to be running
        max_wait = 60
        start_time = time.time()
        while time.time() - start_time < max_wait:
            status = self.get_vm_status(vmid)
            if status == 'running':
                self.logger.info(f"VM {vmid} is running")
                return
            time.sleep(2)

        raise RuntimeError(f"VM {vmid} failed to start within {max_wait} seconds")

    def stop_vm(self, vmid: int) -> None:
        """
        Stop VM.

        Args:
            vmid: VM ID
        """
        self.logger.info(f"Stopping VM {vmid}")
        try:
            task = self.proxmox.nodes(self.node_name).qemu(vmid).status.stop.post()
            self._wait_for_task(task['data'])
        except Exception as e:
            self.logger.warning(f"Error stopping VM {vmid}: {e}")

    def destroy_vm(self, vmid: int) -> None:
        """
        Destroy VM.

        Args:
            vmid: VM ID
        """
        self.logger.info(f"Destroying VM {vmid}")
        try:
            # Stop if running
            status = self.get_vm_status(vmid)
            if status == 'running':
                self.stop_vm(vmid)
                time.sleep(5)

            # Delete VM
            task = self.proxmox.nodes(self.node_name).qemu(vmid).delete()
            self._wait_for_task(task['data'])
            self.logger.info(f"VM {vmid} destroyed")
        except Exception as e:
            self.logger.error(f"Error destroying VM {vmid}: {e}")

    def get_vm_status(self, vmid: int) -> str:
        """
        Get VM status.

        Args:
            vmid: VM ID

        Returns:
            Status string (e.g., 'running', 'stopped')
        """
        try:
            status = self.proxmox.nodes(self.node_name).qemu(vmid).status.current.get()
            return status.get('status', 'unknown')
        except Exception:
            return 'unknown'

    def get_vm_ip(self, vmid: int, interface: str = "net0", timeout: int = 300) -> Optional[str]:
        """
        Get VM IP address from QEMU guest agent.

        Args:
            vmid: VM ID
            interface: Network interface name
            timeout: Maximum wait time in seconds

        Returns:
            IP address or None if not available
        """
        self.logger.info(f"Waiting for IP address for VM {vmid}")
        start_time = time.time()

        while time.time() - start_time < timeout:
            try:
                # Try to get IP from guest agent
                network = self.proxmox.nodes(self.node_name).qemu(vmid).agent('network-get-interfaces').get()
                if network and 'result' in network:
                    for iface in network['result']:
                        if iface.get('name') == interface or 'ip-addresses' in iface:
                            for ip_info in iface.get('ip-addresses', []):
                                ip = ip_info.get('ip-address')
                                if ip and not ip.startswith('127.') and not ip.startswith('::1'):
                                    # Prefer IPv4
                                    if ':' not in ip:
                                        self.logger.info(f"VM {vmid} IP: {ip}")
                                        return ip

                # Alternative: try to get from config
                config = self.proxmox.nodes(self.node_name).qemu(vmid).config.get()
                # This is a fallback - actual IP detection may vary
            except Exception:
                pass

            time.sleep(5)

        self.logger.warning(f"Could not get IP for VM {vmid} within {timeout} seconds")
        return None

    def _wait_for_task(self, task_id: str, timeout: int = 300) -> None:
        """
        Wait for ProxMox task to complete.

        Args:
            task_id: Task ID
            timeout: Maximum wait time in seconds
        """
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                status = self.proxmox.nodes(self.node_name).tasks(task_id).status.get()
                if status.get('status') == 'stopped':
                    if status.get('exitstatus') == 'OK':
                        return
                    else:
                        raise RuntimeError(f"Task {task_id} failed: {status.get('exitstatus')}")
            except Exception:
                pass
            time.sleep(2)

        raise RuntimeError(f"Task {task_id} timed out after {timeout} seconds")

    def list_vms(self, name_prefix: str = "spock-node") -> List[Dict]:
        """
        List VMs with given name prefix.

        Args:
            name_prefix: VM name prefix to filter

        Returns:
            List of VM info dicts
        """
        vms = self.proxmox.nodes(self.node_name).qemu.get()
        return [vm for vm in vms if vm.get('name', '').startswith(name_prefix)]
