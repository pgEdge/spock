#!/usr/bin/env bash
set -euo pipefail

COMPONENT_NAME=$1

# Resolve absolute, canonical paths. The common/build.sh bridge wrapper
# exec's this script with a relative $0 (./common/../pkg/scripts/build.sh),
# so `$(dirname "$0")/../${COMPONENT_NAME}/` would yield non-canonical paths
# that resolve wrong. cd+pwd gives stable absolute paths regardless of caller.
# Exported so common-functions.sh (sourced below) reuses them.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPONENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export SCRIPT_DIR COMPONENT_DIR

source "${COMPONENT_DIR}/common.sh"

COMMON_FILE="${SCRIPT_DIR}/common-functions.sh"
if [ -f "$COMMON_FILE" ]; then
  source "$COMMON_FILE"
else
  echo "Error: $COMMON_FILE not found!" >&2
  exit 1
fi

###########
# Main
###########
detect_os_type
prepare
build
post_build
