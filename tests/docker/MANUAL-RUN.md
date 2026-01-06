# Manual Docker Container Scripts

This directory contains scripts to manually build and run Docker containers using `Dockerfile-step-1.el9`.

## Scripts

### `run-manual-container.sh`
Builds the Docker image and optionally runs a container.

**Usage:**
```bash
./run-manual-container.sh [PGVER] [CONTAINER_NAME]
```

**Arguments:**
- `PGVER` - PostgreSQL version (default: 17)
- `CONTAINER_NAME` - Name for the container (default: spock-manual)

**Example:**
```bash
# Build for PostgreSQL 17 (default)
./run-manual-container.sh

# Build for PostgreSQL 16
./run-manual-container.sh 16

# Build for PostgreSQL 15 with custom name
./run-manual-container.sh 15 my-spock-test
```

### `run-container-only.sh`
Runs a container using an already-built image (no rebuild).

**Usage:**
```bash
./run-container-only.sh [PGVER] [CONTAINER_NAME] [MODE]
```

**Arguments:**
- `PGVER` - PostgreSQL version (default: 17)
- `CONTAINER_NAME` - Name for the container (default: spock-manual)
- `MODE` - Run mode: `interactive`, `detached`, or `bash` (default: interactive)

**Examples:**
```bash
# Run interactively (default)
./run-container-only.sh

# Run in detached mode (background)
./run-container-only.sh 17 spock-manual detached

# Run with bash shell for debugging
./run-container-only.sh 17 spock-manual bash
```

## Container Configuration

The container is configured with:

### Environment Variables
- `PGVER` - PostgreSQL version (e.g., 17, 16, 15)
- `HOSTNAME` - Container hostname (default: n1)
- `PEER_NAMES` - Comma-separated list of peer nodes (default: n2,n3)
- `TZ` - Timezone (default: America/Toronto)
- Additional variables from `pgedge.env`:
  - `DBUSER=admin`
  - `DBPASSWD=testpass`
  - `DBNAME=demo`
  - `DBPORT=5432`

### Port Mapping
- Host port `15432` → Container port `5432`

### Volume Mounts
- Spock source code: `<project-root>:/home/pgedge/spock`
- Library list: `tests/docker/lib-list.txt:/home/pgedge/lib-list.txt`

## Quick Start

1. **Build and run interactively:**
   ```bash
   cd tests/docker
   ./run-manual-container.sh
   ```
   This will build the image and prompt you to run the container.

2. **Build only (no run):**
   ```bash
   ./run-manual-container.sh
   # Answer 'n' when prompted to run
   ```

3. **Run previously built container:**
   ```bash
   ./run-container-only.sh
   ```

## Docker Commands Reference

### Build Image Manually
```bash
docker build \
    --build-arg PGVER=17 \
    --build-arg MAKE_JOBS=4 \
    -f Dockerfile-step-1.el9 \
    -t spock-test:pg17 \
    ../../
```

### Run Container Manually
```bash
docker run -it --rm --name spock-manual \
    -e PGVER=17 \
    -e HOSTNAME=n1 \
    -e PEER_NAMES=n2,n3 \
    -e TZ=America/Toronto \
    --env-file pgedge.env \
    -p 15432:5432 \
    -v $(pwd)/../..:/home/pgedge/spock \
    -v $(pwd)/lib-list.txt:/home/pgedge/lib-list.txt \
    spock-test:pg17
```

### Exec into Running Container
```bash
docker exec -it spock-manual /bin/bash
```

### View Container Logs
```bash
docker logs -f spock-manual
```

### Stop and Remove Container
```bash
docker stop spock-manual
docker rm spock-manual
```

## Troubleshooting

### Image doesn't exist
If you see "Image does not exist", build it first:
```bash
./run-manual-container.sh
```

### Port already in use
If port 15432 is already in use, modify the port mapping:
```bash
docker run -it --rm --name spock-manual \
    -p 15433:5432 \  # Use a different host port
    ...
```

### Container keeps exiting
Run with bash to debug:
```bash
./run-container-only.sh 17 spock-manual bash
```

### Rebuild image after code changes
```bash
# Remove old image
docker rmi spock-test:pg17

# Rebuild
./run-manual-container.sh 17
```
