#!/usr/bin/env bash
#
# Build the Antithesis images for this machine's architecture and run
# snouty validate against them.
#
# Antithesis runs x86-64, so config/docker-compose.yaml pins
# platform: linux/amd64.  On an ARM host without amd64 emulation those images
# cannot run, so this script renders a copy of the config with the native
# platform and ":local" image tags into antithesis/.local-config/ and
# validates that.  The ":local" tags keep native images away from the
# ":latest" tags that snouty pushes, so an arm64 image is never submitted.
#
# Usage: antithesis/local-validate.sh [--no-build] [extra snouty validate args]
#
# Environment:
#   SNOUTY_CONTAINER_ENGINE  podman or docker (default: podman if installed,
#                            matching snouty's own preference)
#   VALIDATE_TIMEOUT         seconds to reach setup_complete (default 600)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${here}/.local-config"

build=1
if [ "${1:-}" = "--no-build" ]; then
	build=0
	shift
fi

case "$(uname -m)" in
	x86_64 | amd64) platform=linux/amd64 ;;
	aarch64 | arm64) platform=linux/arm64 ;;
	*) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

if [ -z "${SNOUTY_CONTAINER_ENGINE:-}" ]; then
	if command -v podman > /dev/null; then
		SNOUTY_CONTAINER_ENGINE=podman
	else
		SNOUTY_CONTAINER_ENGINE=docker
	fi
fi
export SNOUTY_CONTAINER_ENGINE
engine="${SNOUTY_CONTAINER_ENGINE}"

# Same depth as config/, so the relative build context still names the
# repository root.
mkdir -p "${out}"
sed -e "s|platform: linux/amd64|platform: ${platform}|" \
	-e 's|image: \(spock-[a-z]*\):latest|image: \1:local|' \
	"${here}/config/docker-compose.yaml" > "${out}/docker-compose.yaml"

compose=("${engine}" compose -f "${out}/docker-compose.yaml")

if [ "${build}" = 1 ]; then
	echo "building ${platform} images with ${engine}"
	# n1-n4 share one image.  Build it once, then the workload (which reuses
	# the cached build stage); podman would otherwise run every build at once
	# with no sharing.
	"${compose[@]}" build n1
	"${compose[@]}" build workload
fi

# Start from empty data volumes.
"${compose[@]}" down -v --remove-orphans > /dev/null 2>&1 || true

snouty validate "${out}" --timeout "${VALIDATE_TIMEOUT:-600}" "$@"
