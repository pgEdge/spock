#!/usr/bin/env bash
# common.sh - packaging environment for Spock (v6 series → spock60 packages).
#
# Sourced by pkg/scripts/build.sh (via the common/build.sh bridge wrapper)
# before common-functions.sh. Sets the variables consumed by build-rpm.sh /
# build-deb.sh, pkg/rpm/spock.spec and pkg/deb/debian/*.
#
# Spock is a PostgreSQL extension: one build per PG major.
# pgedge-detect-build-matrix reads this to fan the matrix out over pg_versions.
PER_PG_VERSION=true

export PG_VERSION="${PG_VERSION:-17}"
export PG_MAJOR_VERSION="$(echo "$PG_VERSION" | cut -d. -f1)"

export PG_SPOCK_REPO="https://github.com/pgEdge/spock.git"
export SPOCK_BRANCH="${COMPONENT_BRANCH:-v6.0.0-beta.1}"

# Upstream version, suffix-stripped (e.g. 6.0.0). Used for the source
# tarball name, its internal directory, and the RPM Version.
export SPOCK_VERSION="${COMPONENT_VERSION:-6.0.0}"

# Appending 0 after 6 to create major version 60 even in case of 6.1.0
export SPOCK_MAJOR_VERSION=$(echo ${SPOCK_VERSION} | cut -d. -f1 | tr -d .)0
export SPOCK_BUILDNUM=${COMPONENT_BUILDNUM:-1}

export REPO_TYPE="${REPO_TYPE:-daily}"

# DEB only: move a pre-release pretag (COMPONENT_BUILDNUM='beta1_1') into the
# upstream version with a leading '~' so pre-releases sort BELOW stable in
# dpkg/reprepro: 6.0.0~beta1-1.noble < 6.0.0-1.noble.
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

stage_source() {
  local dest="$1"
  if [ -f "${ARTIFACT_DIR}/${SRC_TARBALL}" ]; then
    echo "Staging ${SRC_TARBALL} from ${ARTIFACT_DIR}"
    cp "${ARTIFACT_DIR}/${SRC_TARBALL}" "${dest}"
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
