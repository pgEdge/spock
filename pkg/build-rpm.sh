#!/bin/bash
set -euo pipefail

RHEL="$(rpm --eval %rhel)"

# stage_source(), ARTIFACT_DIR and SRC_TARBALL come from pkg/common.sh, which
# build.sh sources before this file.

prepare() {
  setup_dnf_build_env
  echo "Copying packaging files..."
  cp ${COMPONENT_NAME}/rpm/spock.spec ~/rpmbuild/SPECS/

  stage_source ~/rpmbuild/SOURCES/${SRC_TARBALL}

  # This function is for debugging purpose if you have your own keys. GH workflow does not need it.
  #import_gpg_keys

  echo "🔧 Installing RPM build dependencies..."
  dnf builddep -y \
    --define "spock_version ${SPOCK_VERSION}" \
    --define "spock_buildnum ${SPOCK_BUILDNUM}" \
    --define "pgmajorversion ${PG_MAJOR_VERSION}" \
    --define "spockmajorversion ${SPOCK_MAJOR_VERSION}" \
    ~/rpmbuild/SPECS/spock.spec
}

build() {
  echo "Building RPM and SRPM..."
  QA_RPATHS=$(( 0xffff )) rpmbuild -ba ~/rpmbuild/SPECS/spock.spec \
    --define "spock_version ${SPOCK_VERSION}" \
    --define "spock_buildnum ${SPOCK_BUILDNUM}" \
    --define "spockmajorversion ${SPOCK_MAJOR_VERSION}" \
    --define "pgmajorversion ${PG_MAJOR_VERSION}"

}

post_build() {
  echo "📤 Copying built RPMs to /output..."
  mkdir -p /output
  cp -v ~/rpmbuild/RPMS/*/*.rpm /output/ || echo "No binary RPMs found"
  cp -v ~/rpmbuild/SRPMS/*.src.rpm /output/ || echo "No SRPM found"

  sign_rpms /output/*.rpm
  validate_signatures /output/*.rpm
}
