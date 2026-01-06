# Manual Docker Testing Guide

This guide explains how to manually build and run Docker containers for Spock testing using `run-manual.sh`.

## Quick Start

```bash
cd tests/docker

# Interactive shell (default)
./run-manual.sh shell

# Run regression tests
./run-manual.sh regress

# Run TAP tests
./run-manual.sh tap

# Clean up everything
./run-manual.sh clean
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PGVER` | PostgreSQL major version (15, 16, 17, 18) | `17` |
| `MAKE_JOBS` | Number of parallel make jobs | `4` |

## Usage Examples

### 1. Interactive Shell with Different PostgreSQL Versions

```bash
# PostgreSQL 17 (default)
./run-manual.sh shell

# PostgreSQL 16
PGVER=16 ./run-manual.sh shell

# PostgreSQL 18
PGVER=18 ./run-manual.sh shell
```

Inside the container:
```bash
# Check PostgreSQL version
psql --version

# Navigate to Spock source
cd /home/pgedge/spock

# Rebuild Spock after changes
make clean && make && make install

# Start PostgreSQL and test
pg_ctl -D /tmp/test_data initdb
pg_ctl -D /tmp/test_data start
```

### 2. Run Tests

```bash
# Regression tests
./run-manual.sh regress

# TAP tests
./run-manual.sh tap

# With different PostgreSQL version
PGVER=16 ./run-manual.sh regress
```

### 3. Run Custom Commands

```bash
# Check PostgreSQL configuration
./run-manual.sh cmd pg_config --version

# Run psql
./run-manual.sh cmd psql --version

# List installed extensions
./run-manual.sh cmd "ls -la /home/pgedge/pgedge/pg17/share/extension/"

# Run a custom SQL script
./run-manual.sh cmd "psql -f /home/pgedge/spock/test.sql"
```

### 4. Build Only (Without Running)

```bash
# Build image for PostgreSQL 17
PGVER=17 ./run-manual.sh build

# Build with more parallel jobs
MAKE_JOBS=8 PGVER=16 ./run-manual.sh build
```

### 5. Debug Build Issues

```bash
# Build with verbose output
PGVER=17 ./run-manual.sh build 2>&1 | tee build.log

# Enter shell to inspect failed build
./run-manual.sh shell
```

### 6. Cleanup

```bash
# Remove containers and images for current PGVER
./run-manual.sh clean

# Clean up specific version
PGVER=16 ./run-manual.sh clean

# Clean all spock-manual images
docker images | grep spock-manual | awk '{print $3}' | xargs docker rmi
```

## Container Details

### Image Information

- **Base image**: `ghcr.io/pgedge/base-test-image:latest`
- **Built image**: `spock-manual:pg${PGVER}`
- **Container name**: `spock-manual-pg${PGVER}`

### Directory Structure

```
/home/pgedge/
├── postgres/              # PostgreSQL source code (cloned from upstream)
├── pgedge/                # pgEdge installation
│   ├── pg15/             # PostgreSQL 15 installation (if built)
│   ├── pg16/             # PostgreSQL 16 installation (if built)
│   ├── pg17/             # PostgreSQL 17 installation (if built)
│   └── pg18/             # PostgreSQL 18 installation (if built)
└── spock/                 # Spock source (mounted from host)
```

### Environment Variables in Container

- `PGVER` - PostgreSQL major version
- `PATH` - includes `/home/pgedge/pgedge/pg${PGVER}/bin`
- `LD_LIBRARY_PATH` - includes `/home/pgedge/pgedge/pg${PGVER}/lib`
- `PG_CONFIG` - points to `/home/pgedge/pgedge/pg${PGVER}/bin/pg_config`

### Available Test Scripts

- `/home/pgedge/run-spock-regress.sh` - Regression tests entry point
- `/home/pgedge/spock/tests/tap/run_tests.sh` - TAP tests entry point
- `/home/pgedge/entrypoint.sh` - Default entrypoint (for spockbench)

## Troubleshooting

### Build Fails with "Could not find PostgreSQL tag"

```bash
# Check if PGVER is set correctly
echo $PGVER

# Verify available tags on GitHub
git ls-remote --tags https://github.com/postgres/postgres.git | grep "REL_17_"
```

### Container Exits Immediately

```bash
# Check container logs
docker logs spock-manual-pg17

# Run with interactive shell to debug
./run-manual.sh shell
```

### Permission Issues with Mounted Volume

```bash
# Inside container, files are owned by pgedge user
# On host, you may need to adjust permissions

# Fix on host:
sudo chown -R $USER:$USER .

# Or run container as root (not recommended):
docker run -it --rm --user root -v $(pwd):/home/pgedge/spock spock-manual:pg17 /bin/bash
```

### Rebuild After Code Changes

The script mounts the Spock source directory from the host, so changes are immediately available. However, you need to rebuild the extension:

```bash
# In container:
cd /home/pgedge/spock
make clean && make && make install
```

Or from host:
```bash
./run-manual.sh cmd "cd /home/pgedge/spock && make clean && make && make install"
```

## Comparison with docker-compose

| Aspect | run-manual.sh | docker-compose |
|--------|---------------|----------------|
| Use case | Single container testing | Multi-node spockbench tests |
| Image | Builds on demand | Uses pre-built or builds |
| Container count | 1 | 3 (n1, n2, n3) |
| Networking | Isolated | Compose network |
| Persistence | Removed on exit | Can persist with volumes |
| Best for | Development, debugging | Integration tests |

## Advanced Usage

### Keep Container Running for Multiple Commands

```bash
# Start container in background
docker run -d --name spock-dev \
  -e PGVER=17 \
  -v $(pwd)/../..:/home/pgedge/spock \
  spock-manual:pg17 \
  tail -f /dev/null

# Execute commands
docker exec -it spock-dev bash
docker exec spock-dev make -C /home/pgedge/spock install

# Cleanup when done
docker rm -f spock-dev
```

### Build with Custom PostgreSQL Source

```bash
# Modify Dockerfile-step-1.el9 to use local PostgreSQL source
# Or mount it:
docker run -it --rm \
  -v $(pwd)/../..:/home/pgedge/spock \
  -v /path/to/postgres:/home/pgedge/postgres \
  spock-manual:pg17 /bin/bash
```

### Share Built Images

```bash
# Save image to tar
docker save spock-manual:pg17 | gzip > spock-pg17.tar.gz

# Load on another machine
gunzip -c spock-pg17.tar.gz | docker load
```

## See Also

- [README.md](./README.md) - Docker infrastructure overview
- [DOCKER-README.md](./DOCKER-README.md) - Original Docker documentation
- [.github/workflows/spockbench.yml](../../.github/workflows/spockbench.yml) - CI/CD workflow
