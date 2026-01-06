#!/bin/bash

set -e

# Script to manually build and run Docker container with Dockerfile-step-1.el9
# This is useful for local testing and debugging

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default values
PGVER="${PGVER:-17}"
MAKE_JOBS="${MAKE_JOBS:-4}"
CONTAINER_NAME="spock-manual-pg${PGVER}"
IMAGE_NAME="spock-manual:pg${PGVER}"
MODE="${1:-shell}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
    cat <<EOF
Usage: $0 [MODE] [COMMAND...]

Build and run Docker container with Dockerfile-step-1.el9 manually.

Environment Variables:
  PGVER       PostgreSQL version (default: 17)
  MAKE_JOBS   Parallel make jobs (default: 4)

Modes:
  shell       Start interactive bash shell (default)
  regress     Run regression tests
  tap         Run TAP tests
  cmd         Run custom command (pass as additional arguments)
  build       Only build the image, don't run
  clean       Remove image and any running containers

Examples:
  # Interactive shell with PostgreSQL 16
  PGVER=16 $0 shell

  # Run regression tests
  $0 regress

  # Run custom command
  $0 cmd psql --version

  # Just build the image
  PGVER=18 $0 build

  # Clean up
  $0 clean

Container Details:
  Image name:      $IMAGE_NAME
  Container name:  $CONTAINER_NAME
  Work directory:  /home/pgedge
  PostgreSQL:      /home/pgedge/pgedge/pg${PGVER}
  Spock source:    /home/pgedge/spock

EOF
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

build_image() {
    print_info "Building Docker image..."
    print_info "  PGVER: $PGVER"
    print_info "  MAKE_JOBS: $MAKE_JOBS"
    print_info "  Image: $IMAGE_NAME"

    cd "$REPO_ROOT"

    docker build \
        --build-arg PGVER="$PGVER" \
        --build-arg MAKE_JOBS="$MAKE_JOBS" \
        -t "$IMAGE_NAME" \
        -f tests/docker/Dockerfile-step-1.el9 \
        .

    print_success "Image built: $IMAGE_NAME"
}

cleanup_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Removing existing container: $CONTAINER_NAME"
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}

run_shell() {
    print_info "Starting interactive shell..."
    cleanup_container

    docker run -it --rm \
        --name "$CONTAINER_NAME" \
        -e PGVER="$PGVER" \
        -v "$REPO_ROOT:/home/pgedge/spock" \
        -w /home/pgedge \
        "$IMAGE_NAME" \
        /bin/bash
}

run_regression() {
    print_info "Running regression tests..."
    cleanup_container

    docker run --rm \
        --name "$CONTAINER_NAME" \
        -e PGVER="$PGVER" \
        -v "$REPO_ROOT:/home/pgedge/spock" \
        "$IMAGE_NAME" \
        /home/pgedge/run-spock-regress.sh

    print_success "Regression tests completed"
}

run_tap() {
    print_info "Running TAP tests..."
    cleanup_container

    docker run --rm \
        --name "$CONTAINER_NAME" \
        -e PGVER="$PGVER" \
        -v "$REPO_ROOT:/home/pgedge/spock" \
        --workdir=/home/pgedge/spock/tests/tap \
        "$IMAGE_NAME" \
        /home/pgedge/spock/tests/tap/run_tests.sh

    print_success "TAP tests completed"
}

run_command() {
    local cmd="$*"
    print_info "Running command: $cmd"
    cleanup_container

    docker run --rm \
        --name "$CONTAINER_NAME" \
        -e PGVER="$PGVER" \
        -v "$REPO_ROOT:/home/pgedge/spock" \
        -w /home/pgedge \
        "$IMAGE_NAME" \
        bash -c "$cmd"
}

clean_all() {
    print_info "Cleaning up..."

    # Remove containers
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Removing container: $CONTAINER_NAME"
        docker rm -f "$CONTAINER_NAME" || true
    fi

    # Remove image
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
        print_info "Removing image: $IMAGE_NAME"
        docker rmi "$IMAGE_NAME" || true
    fi

    print_success "Cleanup complete"
}

# Main script
case "$MODE" in
    -h|--help|help)
        print_usage
        exit 0
        ;;

    build)
        build_image
        ;;

    shell)
        if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
            print_warning "Image not found, building first..."
            build_image
        fi
        run_shell
        ;;

    regress)
        if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
            print_warning "Image not found, building first..."
            build_image
        fi
        run_regression
        ;;

    tap)
        if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
            print_warning "Image not found, building first..."
            build_image
        fi
        run_tap
        ;;

    cmd)
        if [ $# -lt 2 ]; then
            print_error "No command provided for 'cmd' mode"
            print_usage
            exit 1
        fi
        shift # Remove 'cmd' from arguments
        if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
            print_warning "Image not found, building first..."
            build_image
        fi
        run_command "$@"
        ;;

    clean)
        clean_all
        ;;

    *)
        print_error "Unknown mode: $MODE"
        print_usage
        exit 1
        ;;
esac
