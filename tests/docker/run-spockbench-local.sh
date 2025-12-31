#!/bin/bash
set -e

# Local Spockbench test runner
# Usage: ./run-spockbench-local.sh [PGVER]
# Example: ./run-spockbench-local.sh 17

PGVER=${1:-17}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=========================================="
echo "Running Spockbench for PostgreSQL ${PGVER}"
echo "=========================================="

# Set environment variables
export GITHUB_WORKSPACE="${REPO_ROOT}"
export PG_VER="${PGVER}"

# Clean up any previous runs
echo ""
echo "==> Cleaning up previous runs..."
cd "${SCRIPT_DIR}"
docker compose down -v 2>/dev/null || true

# Build the Docker image
echo ""
echo "==> Building Docker image..."
cd "${REPO_ROOT}"
docker build \
  --build-arg PGVER=${PGVER} \
  -t spock \
  -f tests/docker/Dockerfile-step-1.el9 \
  .

# Prepare environment file
echo ""
echo "==> Preparing environment..."
cd "${SCRIPT_DIR}"
echo "PG_VER=${PGVER}" > pgedge.env

# Build with docker compose
echo ""
echo "==> Building with docker compose..."
docker compose build --build-arg PGVER=${PGVER}

# Run Spockbench
echo ""
echo "==> Starting Spockbench containers..."
echo "This will run the tests. Watch the output below."
echo "=========================================="
docker compose up

# Check for completion
COMPOSE_EXIT_CODE=$?

echo ""
echo "=========================================="
if [ $COMPOSE_EXIT_CODE -eq 0 ]; then
  echo "==> Checking test outputs..."
  ./check-outputs.sh
  CHECK_EXIT_CODE=$?

  if [ $CHECK_EXIT_CODE -eq 0 ]; then
    echo "✓ Spockbench tests PASSED"
  else
    echo "✗ Spockbench tests FAILED (check-outputs.sh returned $CHECK_EXIT_CODE)"
  fi
else
  echo "✗ Docker compose exited with code $COMPOSE_EXIT_CODE"
  CHECK_EXIT_CODE=$COMPOSE_EXIT_CODE
fi

# Collect artifacts
echo ""
echo "==> Collecting artifacts..."
ARTIFACT_DIR="${REPO_ROOT}/spockbench-artifacts-local"
mkdir -p "${ARTIFACT_DIR}"

for container in n1 n2 n3; do
  echo "Collecting from $container..."

  # Copy PostgreSQL logfile
  docker cp "$container:/home/pgedge/pgedge/data/pg${PGVER}/logfile" \
    "${ARTIFACT_DIR}/${container}-logfile.log" 2>/dev/null && \
    echo "  ✓ Logfile saved" || \
    echo "  ✗ No logfile found"

  # Copy postgresql.conf
  docker cp "$container:/home/pgedge/pgedge/data/pg${PGVER}/postgresql.conf" \
    "${ARTIFACT_DIR}/${container}-postgresql.conf" 2>/dev/null && \
    echo "  ✓ postgresql.conf saved" || \
    echo "  ✗ No postgresql.conf found"

  # Copy docker container logs
  docker logs "$container" > "${ARTIFACT_DIR}/${container}-docker.log" 2>&1 && \
    echo "  ✓ Docker logs saved" || \
    echo "  ✗ Could not get docker logs"
done

echo ""
echo "Artifacts saved to: ${ARTIFACT_DIR}"
ls -lh "${ARTIFACT_DIR}/"

# Cleanup
echo ""
echo "==> Cleaning up containers..."
docker compose down -v || true

echo ""
echo "=========================================="
if [ $CHECK_EXIT_CODE -eq 0 ]; then
  echo "✓ Spockbench completed successfully!"
  exit 0
else
  echo "✗ Spockbench failed. Check artifacts in: ${ARTIFACT_DIR}"
  exit 1
fi
