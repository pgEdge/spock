#!/bin/bash

# Script to run an already-built Docker container (without rebuilding)
# Usage: ./run-container-only.sh [PGVER] [CONTAINER_NAME] [MODE]
#   MODE: interactive (default), detached, or bash

set -e

# Default values
PGVER=${1:-17}
CONTAINER_NAME=${2:-spock-manual}
MODE=${3:-interactive}
IMAGE_NAME="spock-test:pg${PGVER}"

# Get the script's directory (tests/docker)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Check if image exists
if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    echo "Error: Image ${IMAGE_NAME} does not exist!"
    echo "Please build it first using:"
    echo "  ./run-manual-container.sh ${PGVER}"
    exit 1
fi

echo "Running container: ${CONTAINER_NAME}"
echo "Using image: ${IMAGE_NAME}"
echo "Mode: ${MODE}"
echo ""

case "${MODE}" in
    interactive)
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
        ;;
    detached)
        docker run -d --name "${CONTAINER_NAME}" \
            -e PGVER="${PGVER}" \
            -e HOSTNAME=n1 \
            -e PEER_NAMES=n2,n3 \
            -e TZ=America/Toronto \
            --env-file "${SCRIPT_DIR}/pgedge.env" \
            -p 15432:5432 \
            -v "${PROJECT_ROOT}:/home/pgedge/spock" \
            -v "${SCRIPT_DIR}/lib-list.txt:/home/pgedge/lib-list.txt" \
            "${IMAGE_NAME}"
        echo ""
        echo "Container started in detached mode."
        echo "To view logs: docker logs -f ${CONTAINER_NAME}"
        echo "To exec into container: docker exec -it ${CONTAINER_NAME} /bin/bash"
        echo "To stop container: docker stop ${CONTAINER_NAME}"
        ;;
    bash)
        docker run -it --rm --name "${CONTAINER_NAME}" \
            -e PGVER="${PGVER}" \
            -e HOSTNAME=n1 \
            -e PEER_NAMES=n2,n3 \
            -e TZ=America/Toronto \
            --env-file "${SCRIPT_DIR}/pgedge.env" \
            -p 15432:5432 \
            -v "${PROJECT_ROOT}:/home/pgedge/spock" \
            -v "${SCRIPT_DIR}/lib-list.txt:/home/pgedge/lib-list.txt" \
            "${IMAGE_NAME}" /bin/bash
        ;;
    *)
        echo "Error: Unknown mode '${MODE}'"
        echo "Valid modes: interactive, detached, bash"
        exit 1
        ;;
esac
