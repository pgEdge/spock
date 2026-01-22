# Spock Benchmark Suite for ProxMox

Automated tool for creating PostgreSQL 18 + Spock multi-master replication clusters on ProxMox VMs and running pgbench benchmarks.

## Features

- **Automated VM Provisioning**: Create multiple VMs on ProxMox from templates
- **PostgreSQL 18 Installation**: Automatic installation and configuration
- **Spock Extension Setup**: Build and install Spock from source
- **Multi-Master Replication**: Automatic cluster setup with full mesh topology
- **Benchmark Execution**: Run pgbench with custom scripts across all nodes
- **Results Collection**: Aggregate and export benchmark results

## Requirements

- Python 3.8+
- Access to ProxMox API
- ProxMox VM template with SSH access
- Network connectivity to ProxMox and VMs

## Installation

1. Install dependencies:
```bash
pip install -r bm/requirements.txt
```

2. Make the script executable:
```bash
chmod +x bm/benchmark.py
```

## Quick Start

### 1. Create a Cluster

Create a 3-node Spock cluster:

```bash
python -m bm.benchmark create \
    --proxmox-host 192.168.1.100:8006 \
    --proxmox-user admin@pam \
    --proxmox-password yourpassword \
    --template ubuntu-22.04 \
    --node-count 3 \
    --ssh-user root \
    --ssh-password vm_password
```

### 2. Run Benchmark

Run pgbench with a custom script:

```bash
python -m bm.benchmark benchmark \
    --pgbench-script /path/to/custom.sql \
    --clients 10 \
    --threads 4 \
    --duration 300 \
    --scale-factor 10
```

### 3. Check Status

View cluster status:

```bash
python -m bm.benchmark status
```

### 4. Destroy Cluster

Clean up all VMs:

```bash
python -m bm.benchmark destroy
```

## Configuration File

You can use a YAML or JSON configuration file to avoid passing credentials on the command line:

**config.yaml:**
```yaml
proxmox:
  host: "192.168.1.100:8006"
  user: "admin@pam"
  password: "yourpassword"

ssh:
  user: "root"
  password: "vm_password"

database:
  name: "postgres"
  user: "postgres"

spock:
  repo: "https://github.com/pgEdge/spock.git"
```

Then use it:
```bash
python -m bm.benchmark create --config config.yaml --template ubuntu-22.04 --node-count 3
```

## Command Reference

### Global Options

- `--config FILE`: Configuration file path (YAML or JSON)
- `--verbose, -v`: Enable verbose output
- `--output-dir DIR`: Output directory for results (default: ./benchmark_results)

### ProxMox Options

- `--proxmox-host HOST`: ProxMox API host (e.g., 192.168.1.100:8006)
- `--proxmox-user USER`: ProxMox username (format: user@realm)
- `--proxmox-password PASS`: ProxMox password
- `--template TEMPLATE`: VM template name or ID
- `--node-count N`: Number of nodes to create (default: 3)
- `--vm-cores N`: CPU cores per VM (default: 2)
- `--vm-memory N`: Memory per VM in MB (default: 4096)
- `--vm-disk-size SIZE`: Disk size per VM (default: 32G)

### Database Options

- `--db-name NAME`: Database name (default: postgres)
- `--db-user USER`: Database user (default: postgres)
- `--db-password PASS`: Database password (if required)

### SSH Options

- `--ssh-user USER`: SSH username (default: root)
- `--ssh-password PASS`: SSH password
- `--ssh-key FILE`: SSH private key file path

### Benchmark Options

- `--pgbench-script FILE`: Custom pgbench script file path
- `--scale-factor N`: pgbench scale factor (default: 1)
- `--clients N`: Number of pgbench clients (default: 1)
- `--threads N`: Number of pgbench threads (default: 1)
- `--duration SEC`: Benchmark duration in seconds (default: 60)

### Spock Options

- `--spock-repo PATH`: Spock repository path (local or GitHub URL)

## Examples

### Example 1: Full Workflow

```bash
# 1. Create cluster
python -m bm.benchmark create \
    --proxmox-host 192.168.1.100:8006 \
    --proxmox-user admin \
    --proxmox-password secret \
    --template ubuntu-22.04 \
    --node-count 3 \
    --vm-cores 4 \
    --vm-memory 8192

# 2. Wait for cluster to be ready (check status)
python -m bm.benchmark status

# 3. Run benchmark
python -m bm.benchmark benchmark \
    --pgbench-script samples/Z0DAN/n1.pgb \
    --clients 20 \
    --threads 4 \
    --duration 600 \
    --scale-factor 50

# 4. Clean up
python -m bm.benchmark destroy
```

### Example 2: Using SSH Keys

```bash
python -m bm.benchmark create \
    --proxmox-host 192.168.1.100:8006 \
    --proxmox-user admin \
    --proxmox-password secret \
    --template ubuntu-22.04 \
    --node-count 3 \
    --ssh-user ubuntu \
    --ssh-key ~/.ssh/id_rsa
```

### Example 3: Custom Configuration

```bash
# Create config.yaml with your settings
python -m bm.benchmark create --config config.yaml --template ubuntu-22.04 --node-count 5
python -m bm.benchmark benchmark --config config.yaml --clients 50 --duration 1200
```

## Architecture

The tool consists of modular components:

- **benchmark.py**: Main CLI entry point
- **proxmox_manager.py**: ProxMox VM lifecycle management
- **postgres_setup.py**: PostgreSQL 18 installation and configuration
- **spock_setup.py**: Spock extension building and installation
- **cluster_manager.py**: Multi-master replication setup
- **benchmark_runner.py**: pgbench execution and results collection
- **utils/**: Utility modules (SSH client, config, logging)

## How It Works

1. **VM Creation**: Clones VMs from template, configures resources, starts VMs
2. **PostgreSQL Setup**: Installs PostgreSQL 18, configures for logical replication
3. **Spock Installation**: Builds Spock from source, installs extension
4. **Cluster Setup**: Creates Spock nodes, sets up bi-directional subscriptions
5. **Benchmark**: Initializes pgbench, runs tests, collects results

## Output

Benchmark results are saved in JSON and CSV formats in the output directory:

- `benchmark_<timestamp>.json`: Detailed results with per-node metrics
- Results include: TPS, latency, transaction counts, aggregated statistics

## Troubleshooting

### VM IP Not Found

If VMs don't get IP addresses:
- Ensure ProxMox guest agent is installed in template
- Check network configuration in ProxMox
- Verify DHCP is working

### SSH Connection Failed

- Verify SSH credentials
- Check firewall rules
- Ensure SSH service is running in template

### Spock Build Failed

- Verify build dependencies are installed
- Check PostgreSQL development packages
- Ensure jansson library is available

### Replication Not Working

- Check PostgreSQL configuration (wal_level, etc.)
- Verify pg_hba.conf allows replication connections
- Check network connectivity between nodes
- Review Spock logs: `SELECT * FROM spock.sub_show_status();`

## License

This tool is part of the Spock project. See LICENSE.md for details.
