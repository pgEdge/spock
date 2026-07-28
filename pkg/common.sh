#!/usr/bin/env bash
# common.sh - packaging environment for Spock (v5 series → spock50 packages).
#
# Sourced by pkg/scripts/build.sh (via the common/build.sh bridge wrapper)
# before common-functions.sh. Sets the variables consumed by build-rpm.sh /
# build-deb.sh, pkg/rpm/spock.spec and pkg/deb/debian/*.
#
# Adapted from pgedge-enterprise-packages/spock50/common.sh — the difference
# is that the source now comes from THIS repo's checkout (staged by
# release.yml into release-artifacts/) instead of a fresh clone of
# github.com/pgEdge/spock.

# Spock is a PostgreSQL extension: one build per PG major.
# pgedge-detect-build-matrix reads this to fan the matrix out over pg_versions.
PER_PG_VERSION=true

# Default PostgreSQL version and derived values. release.yml passes the real
# value per matrix cell via the builder action's pg_version input; the matrix
# carries bare majors (16/17/18), and `cut -d. -f1` is a no-op on those while
# still handling a full 17.10-style version.
export PG_VERSION="${PG_VERSION:-17}"
export PG_MAJOR_VERSION="$(echo "$PG_VERSION" | cut -d. -f1)"

# Spock repo + ref. SPOCK_BRANCH is the full tag (e.g. v5.0.11-rc.1) and is
# only used as the clone fallback when release-artifacts/ has no staged
# tarball (i.e. a local build outside the workflow).
export PG_SPOCK_REPO="https://github.com/pgEdge/spock.git"
export SPOCK_BRANCH="${COMPONENT_BRANCH:-v5.0.11-rc.1}"

# Upstream version, suffix-stripped (e.g. 5.0.11). Used for the source
# tarball name, its internal directory, and the RPM Version.
export SPOCK_VERSION="${COMPONENT_VERSION:-5.0.11}"

# Appending 0 after 5 to create major version 50 even in case of 5.1.0
export SPOCK_MAJOR_VERSION=$(echo ${SPOCK_VERSION} | cut -d. -f1 | tr -d .)0
export SPOCK_BUILDNUM=${COMPONENT_BUILDNUM:-1}

export REPO_TYPE="${REPO_TYPE:-daily}"

# DEB only: move a pre-release pretag (COMPONENT_BUILDNUM='rc1_1') into the
# upstream version with a leading '~' so pre-releases sort BELOW stable in
# dpkg/reprepro: 5.0.11~rc1-1.noble < 5.0.11-1.noble.
#
# The '~' form goes in a SEPARATE variable used only by the debian/changelog:
# SPOCK_VERSION itself must stay clean because it names the source tarball and
# its unpack directory (a '~' there would break %setup and the DEB extract).
export SPOCK_DEB_VERSION="${SPOCK_VERSION}"
if command -v apt-get &>/dev/null; then
    if [[ "$SPOCK_BUILDNUM" == *_* ]]; then
        SPOCK_PRETAG="${SPOCK_BUILDNUM%%_*}"
        export SPOCK_DEB_VERSION="${SPOCK_VERSION}~${SPOCK_PRETAG}"
        SPOCK_BUILDNUM="${SPOCK_BUILDNUM##*_}"
    fi
fi

# release.yml stages the source tarball built from THIS run's checkout here.
export ARTIFACT_DIR="${ARTIFACT_DIR:-$(pwd)/release-artifacts}"
export SRC_TARBALL="spock-${SPOCK_VERSION}.tar.gz"

# stage_source <dest-path> — shared by build-rpm.sh and build-deb.sh. It lives
# here rather than in common-functions.sh, which is a shared verbatim copy that
# must stay diffable against the canonical one.
#
# Prefer the workflow-staged tarball (so branch / simulate_tag runs build the
# exact commit under test and need no network). The SPOCK_BRANCH clone is an
# opt-in fallback for local builds: set SPOCK_ALLOW_CLONE_FALLBACK=1.
stage_source() {
  local dest="$1"
  if [ -f "${ARTIFACT_DIR}/${SRC_TARBALL}" ]; then
    echo "Staging ${SRC_TARBALL} from ${ARTIFACT_DIR}"
    cp "${ARTIFACT_DIR}/${SRC_TARBALL}" "${dest}"
  elif [ -z "${SPOCK_ALLOW_CLONE_FALLBACK:-}" ]; then
    # A staged tarball is required by default: cloning SPOCK_BRANCH instead would
    # ship a package built from a different commit than COMPONENT_VERSION claims.
    echo "::error::${ARTIFACT_DIR}/${SRC_TARBALL} not found. release.yml stages it with git archive; for a local build, stage it yourself or set SPOCK_ALLOW_CLONE_FALLBACK=1 to clone ${SPOCK_BRANCH} instead." >&2
    return 1
  else
    echo "Fetching Spock source code (${SPOCK_BRANCH})"
    rm -rf "spock-${SPOCK_VERSION}"
    git clone --depth=1 --branch "$SPOCK_BRANCH" "$PG_SPOCK_REPO" "spock-${SPOCK_VERSION}"
    rm -rf "spock-${SPOCK_VERSION}/.git"
    tar -czf "${SRC_TARBALL}" "spock-${SPOCK_VERSION}"
    rm -rf "spock-${SPOCK_VERSION}"
    mv "${SRC_TARBALL}" "${dest}"
  fi
}
