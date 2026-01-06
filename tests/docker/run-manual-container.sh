#!/bin/bash

# Script to manually build and run a Docker container with Dockerfile-step-1.el9
# Usage: ./run-manual-container.sh [PGVER] [CONTAINER_NAME]

set -e

# Default values
PGVER=${1:-17}
CONTAINER_NAME=${2:-spock-manual}
IMAGE_NAME="spock-test:pg${PGVER}"

# Get the script's directory (tests/docker)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================"
echo "Building Docker image for PostgreSQL ${PGVER}"
echo "============================================"

# Build the image
docker build \
    --build-arg PGVER=${PGVER} \
    --build-arg MAKE_JOBS=4 \
    -f "${SCRIPT_DIR}/Dockerfile-step-1.el9" \
    -t "${IMAGE_NAME}" \
    "${PROJECT_ROOT}"

echo ""
echo "============================================"
echo "Build complete: ${IMAGE_NAME}"
echo "============================================"
echo ""
echo "To run the container, use:"
echo "  docker run -it --rm --name ${CONTAINER_NAME} \\"
echo "    -e PGVER=${PGVER} \\"
echo "    -e HOSTNAME=n1 \\"
echo "    -e PEER_NAMES=n2,n3 \\"
echo "    -e TZ=America/Toronto \\"
echo "    --env-file ${SCRIPT_DIR}/pgedge.env \\"
echo "    -p 15432:5432 \\"
echo "    -v ${PROJECT_ROOT}:/home/pgedge/spock \\"
echo "    -v ${SCRIPT_DIR}/lib-list.txt:/home/pgedge/lib-list.txt \\"
echo "    ${IMAGE_NAME}"
echo ""
echo "Or to run in detached mode:"
echo "  docker run -d --name ${CONTAINER_NAME} \\"
echo "    -e PGVER=${PGVER} \\"
echo "    -e HOSTNAME=n1 \\"
echo "    -e PEER_NAMES=n2,n3 \\"
echo "    -e TZ=America/Toronto \\"
echo "    --env-file ${SCRIPT_DIR}/pgedge.env \\"
echo "    -p 15432:5432 \\"
echo "    -v ${PROJECT_ROOT}:/home/pgedge/spock \\"
echo "    -v ${SCRIPT_DIR}/lib-list.txt:/home/pgedge/lib-list.txt \\"
echo "    ${IMAGE_NAME}"
echo ""
echo "Or run with bash shell (for debugging):"
echo "  docker run -it --rm --name ${CONTAINER_NAME} \\"
echo "    -e PGVER=${PGVER} \\"
echo "    -e HOSTNAME=n1 \\"
echo "    -e PEER_NAMES=n2,n3 \\"
echo "    -e TZ=America/Toronto \\"
echo "    --env-file ${SCRIPT_DIR}/pgedge.env \\"
echo "    -p 15432:5432 \\"
echo "    -v ${PROJECT_ROOT}:/home/pgedge/spock \\"
echo "    -v ${SCRIPT_DIR}/lib-list.txt:/home/pgedge/lib-list.txt \\"
echo "    ${IMAGE_NAME} /bin/bash"
echo ""
echo "To exec into a running container:"
echo "  docker exec -it ${CONTAINER_NAME} /bin/bash"
echo ""

read -p "Do you want to run the container now in interactive mode? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Starting container in interactive mode..."
    docker run -it --rm --name "${CONTAINER_NAME}" \
        -e PGVER="${PGVER}" \
        -e HOSTNAME=n1 \
        -e PEER_NAMES=n2,n3 \
        -e TZ=America/Toronto \
        --env-file "${SCRIPT_DIR}/pgedge.env" \
        -p 15432:5432 \
        -v "${PROJECT_ROOT}:/home/pgedge/spock" \
        -v "${SCRIPT_DIR}/lib-list.txt:/home/pgedge/lib-list.txt" \
        "${IMAGE_NAME}"
fi
