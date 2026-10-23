#!/bin/bash

install_syft(){

  # Pin the installer to a tagged ref (not mutable main) AND pin the installed
  # version, so release builds are reproducible and not exposed to upstream
  # changes on syft's main branch. Override SYFT_VERSION to bump.
  SYFT_VERSION="${SYFT_VERSION:-v1.45.1}"
  echo "Installing syft ${SYFT_VERSION}..."
  curl -sSfL "https://raw.githubusercontent.com/anchore/syft/${SYFT_VERSION}/install.sh" | sudo sh -s -- -b /usr/local/bin "${SYFT_VERSION}"
}

# Remove the temporary copies install_repo_client_cert made from the
# environment. A no-op when the material came from files on disk, which must
# survive.
_cleanup_staged_client_cert() {
  [ "$1" = 1 ] || return 0
  rm -f "$2" "$3"
}

# Install the client certificate the pgEdge repos require.
#
# dnf.pgedge.com and apt.pgedge.com authenticate clients with mutual TLS, and
# pgedge-release writes ssl directives into the repo config. Both package
# managers then hard-fail EVERY repository operation if those directives point
# at files that are not there -- "could not load PEM client certificate" on dnf,
# "Could not load client certificate" on apt -- so this runs before the repo is
# configured, and fails loudly rather than leaving that to be diagnosed later.
#
# Three sources, so CI and a manual run use the same code path:
#
#   /run/pgedge-repo-client/{client.crt,client.key}   mounted read-only into the
#       build container by the workflow, or copied in with `docker cp` for a
#       local container test. Takes precedence. Override the directory with
#       PGEDGE_REPO_CLIENT_DIR.
#
#   common/client.crt and common/client.key           files beside this script,
#       for a local run. Same convention as the GPG keys.
#
#   PGEDGE_REPO_CLIENT_CRT / PGEDGE_REPO_CLIENT_KEY   the PEM contents in the
#       environment. Last resort, and NOT how CI passes them: the environment is
#       inherited by every build process, so an upstream build script dumping
#       `env` would print the private key into the log. A mount is not.
#
# The certificate file must be the CHAIN -- the leaf followed by the issuing
# intermediate. A leaf alone cannot be built into a path at the edge and fails
# as an opaque TLS error.
#
# Unlike import_gpg_keys, the installed files are NOT removed afterwards: dnf
# and apt read them on every transaction. Only the staging copies go.
install_repo_client_cert() {
  local crt_src="" key_src="" staged=0
  local src_dir
  src_dir=$(dirname "$0")

  local mount_dir="${PGEDGE_REPO_CLIENT_DIR:-/run/pgedge-repo-client}"

  if [ -f "$mount_dir/client.crt" ] && [ -f "$mount_dir/client.key" ]; then
    crt_src="$mount_dir/client.crt"; key_src="$mount_dir/client.key"
    echo "Using the repo client certificate from $mount_dir."
  elif [ -f "$src_dir/client.crt" ] && [ -f "$src_dir/client.key" ]; then
    crt_src="$src_dir/client.crt"; key_src="$src_dir/client.key"
    echo "Using the repo client certificate from $src_dir."
  elif [ -n "${PGEDGE_REPO_CLIENT_CRT:-}" ] && [ -n "${PGEDGE_REPO_CLIENT_KEY:-}" ]; then
    crt_src=$(mktemp); key_src=$(mktemp); staged=1
    printf '%s\n' "$PGEDGE_REPO_CLIENT_CRT" > "$crt_src"
    printf '%s\n' "$PGEDGE_REPO_CLIENT_KEY" > "$key_src"
    chmod 600 "$crt_src" "$key_src"
    echo "Using the repo client certificate from the environment."
  else
    echo "Error: no repo client certificate available." >&2
    echo "       Mount or copy client.crt and client.key into $mount_dir, or" >&2
    echo "       place them in $src_dir." >&2
    return 1
  fi

  # Never print the key. A bad PEM here surfaces much later as an unhelpful
  # curl error, so check the shape now.
  if ! grep -q 'BEGIN CERTIFICATE' "$crt_src"; then
    echo "Error: the client certificate is not a PEM certificate." >&2
    _cleanup_staged_client_cert "$staged" "$crt_src" "$key_src"
    return 1
  fi
  if [ "$(grep -c 'BEGIN CERTIFICATE' "$crt_src")" -lt 2 ]; then
    echo "Error: the client certificate holds one certificate; the chain is required." >&2
    echo "       It must be the leaf followed by the issuing intermediate." >&2
    _cleanup_staged_client_cert "$staged" "$crt_src" "$key_src"
    return 1
  fi
  if ! grep -qE 'BEGIN [A-Z ]*PRIVATE KEY' "$key_src"; then
    echo "Error: the client key is not a PEM private key." >&2
    _cleanup_staged_client_cert "$staged" "$crt_src" "$key_src"
    return 1
  fi

  # Both files can be valid PEM and still not belong together. That mismatch
  # would survive to the first package download and surface as a TLS error that
  # never mentions the key, so compare the public keys now. Compared as TEXT
  # with explicit non-empty checks: hashing the two openssl outputs would make
  # two unreadable files hash equal and report a match.
  if command -v openssl >/dev/null 2>&1; then
    local crt_pub key_pub
    crt_pub=$(openssl x509 -in "$crt_src" -noout -pubkey 2>/dev/null)
    key_pub=$(openssl pkey -in "$key_src" -pubout 2>/dev/null)
    if [ -z "$crt_pub" ] || [ -z "$key_pub" ]; then
      echo "Error: could not read the public key from the certificate or the key." >&2
      _cleanup_staged_client_cert "$staged" "$crt_src" "$key_src"
      return 1
    fi
    if [ "$crt_pub" != "$key_pub" ]; then
      echo "Error: the client key does not match the client certificate." >&2
      _cleanup_staged_client_cert "$staged" "$crt_src" "$key_src"
      return 1
    fi
  else
    echo "Warning: openssl not found; cannot check that the key matches the certificate." >&2
  fi

  # Build containers often run as root with no sudo installed. An array rather
  # than a string so the empty case expands to nothing instead of relying on
  # unquoted word splitting.
  local -a sudo_cmd=()
  if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "Error: not root and sudo is not available." >&2
      _cleanup_staged_client_cert "$staged" "$crt_src" "$key_src"
      return 1
    fi
    sudo_cmd=(sudo)
  fi

  local dest
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    dest=/etc/pki/pgedge
  elif command -v apt-get >/dev/null 2>&1; then
    dest=/etc/pgedge
  else
    echo "Error: neither dnf/yum nor apt-get found; cannot place the client" >&2
    echo "       certificate for this platform." >&2
    _cleanup_staged_client_cert "$staged" "$crt_src" "$key_src"
    return 1
  fi

  local rc=0
  if ! "${sudo_cmd[@]}" install -d -m 0755 "$dest"; then
    rc=1
  elif ! "${sudo_cmd[@]}" install -m 0644 "$crt_src" "$dest/client.crt"; then
    rc=1
  elif [ "$dest" = /etc/pgedge ]; then
    # apt drops privileges to _apt before fetching, so a root-only key is
    # unreadable at the moment it is needed. Always by NAME: the uid is 42 on
    # bookworm/trixie/noble/resolute and 100 on jammy.
    "${sudo_cmd[@]}" install -o _apt -g root -m 0400 "$key_src" "$dest/client.key" || rc=1
  else
    "${sudo_cmd[@]}" install -m 0600 "$key_src" "$dest/client.key" || rc=1
  fi

  _cleanup_staged_client_cert "$staged" "$crt_src" "$key_src"

  if [ "$rc" -ne 0 ]; then
    echo "Error: failed to install the client certificate into $dest." >&2
    return 1
  fi
  echo "Client certificate installed at $dest/."
  return 0
}

setup_dnf_build_env(){

  echo "Installing required packages..."
  dnf groupinstall "Development Tools" -y
  dnf install -y rpm-build rpmdevtools yum-utils tar wget git gnupg2 sudo openssl

  echo "📦 Enabling additional repositories..."
  dnf install -y epel-release
  if [ "$RHEL" = "8" ]; then
    dnf config-manager --set-enabled powertools
  else
    dnf config-manager --set-enabled crb
  fi

  echo "Installing the repo client certificate..."
  install_repo_client_cert || return 1

  echo "Configuring pgEdge repository..."
  configure_pgedge_dnf_repo $REPO_TYPE

  echo "Setting up RPM build environment..."
  rpmdev-setuptree

  install_syft
}

setup_apt_build_env(){

  echo "Installing build tools and dependencies..."
  sudo ln -fs /usr/share/zoneinfo/UTC /etc/localtime

  sudo apt-get update
  sudo apt-get install -y devscripts build-essential pkg-config fakeroot git curl \
    ca-certificates debhelper dpkg-dev gnupg2 wget sudo lsb-release openssl

  echo "Installing the repo client certificate..."
  install_repo_client_cert || return 1

  echo "Configuring pgEdge repository..."
  configure_pgedge_apt_repo $REPO_TYPE

  install_syft
}

rename_ddeb_packages(){
  # Rename any *.ddeb (debug-symbol packages) to *.deb. Uses find -print0 so it
  # is safe under `set -euo pipefail` when there are NO .ddeb files (no grep
  # non-zero exit) and tolerates filenames with spaces.
  local build_dir="$1" f
  find "$build_dir" -maxdepth 1 -type f -name '*.ddeb' -print0 | while IFS= read -r -d '' f; do
    mv -- "$f" "${f%.ddeb}.deb"
  done
}

configure_pgedge_dnf_repo() {
  local REPO_TYPE="${1:-daily}"       # "daily" or "staging"

  # Bootstrapped from downloads.pgedge.com, NOT dnf.pgedge.com: the gated repos
  # require a client certificate, and this package is what configures the repo,
  # so it cannot live behind the gate it sets up.
  sudo dnf install -y https://downloads.pgedge.com/reporpm/pgedge-release-latest.noarch.rpm
  sudo sed -i "s|release|$REPO_TYPE|g" /etc/yum.repos.d/pgedge.repo

  # pgedge-release ships its stanzas disabled; srpm stays that way.
  sudo sed -i "s|^enabled=0$|enabled=1|" /etc/yum.repos.d/pgedge.repo
  sudo sed -i "/^\[pgedge-srpm\]/,\$s|^enabled=1$|enabled=0|" /etc/yum.repos.d/pgedge.repo

  echo "Repo configured at /etc/yum.repos.d/pgedge.repo"
}

configure_pgedge_apt_repo(){
  local REPO_TYPE="${1:-daily}"       # "daily" or "staging"
  local REPO_PATH="repodeb"

  # downloads.pgedge.com, not apt.pgedge.com -- see configure_pgedge_dnf_repo.
  curl -sSL https://downloads.pgedge.com/${REPO_PATH}/pgedge-release_latest_all.deb -o /tmp/pgedge-release.deb && sudo dpkg -i /tmp/pgedge-release.deb && rm -f /tmp/pgedge-release.deb || true
  sed -i "s|release|$REPO_TYPE|g" /etc/apt/sources.list.d/pgedge.sources
  sed -i "s|^Enabled: no$|Enabled: yes|" /etc/apt/sources.list.d/pgedge.sources
  apt-get update

  echo "Repo configured at /etc/apt/sources.list.d/pgedge.sources"
}

detect_os_type(){
  if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    echo "Detected RPM-based system"
    source "${COMPONENT_DIR}/build-rpm.sh"
  elif command -v apt-get &>/dev/null; then
    echo "Detected Debian-based system"
    source "${COMPONENT_DIR}/build-deb.sh"
  else
    echo "Unsupported platform: No known package manager found" >&2
    exit 1
  fi
}

import_gpg_keys() {
  if ! command -v rpm &>/dev/null || ! command -v gpg &>/dev/null; then
    echo "Installing rpm or gpg"
    if command -v dnf &>/dev/null; then
      sudo dnf install -y rpm gnupg2
    elif command -v apt-get &>/dev/null; then
      sudo apt-get install -y rpm gnupg2
    fi
    if [ $? -ne 0 ]; then
      echo "Error: Failed to install rpm or gnupg2"
      return 1
    fi
  fi

  PRI_FILE="${SCRIPT_DIR}/public.key"
  PUB_FILE="${SCRIPT_DIR}/private.key"

  GPG_PUBLIC_KEY=$(cat $PRI_FILE)
  GPG_PRIVATE_KEY=$(cat $PUB_FILE)
  rm -f $PRI_FILE $PUB_FILE

  [ -z "$GPG_PUBLIC_KEY" ] && { echo "Error: GPG_PUBLIC_KEY is unset"; return 1; }
  [ -z "$GPG_PRIVATE_KEY" ] && { echo "Error: GPG_PRIVATE_KEY is unset"; return 1; }

  PUBLIC_KEY_FILE=$(mktemp)
  echo "$GPG_PUBLIC_KEY" > "$PUBLIC_KEY_FILE"

  gpg --import "$PUBLIC_KEY_FILE" || {
    echo "Error: Failed to import public key"
    rm -f "$PUBLIC_KEY_FILE"
    return 1
  }

  rpm --import "$PUBLIC_KEY_FILE" || {
    echo "Error: Failed to import public key to RPM"
    rm -f "$PUBLIC_KEY_FILE"
    return 1
  }

  PRIVATE_KEY_FILE=$(mktemp)
  echo "$GPG_PRIVATE_KEY" > "$PRIVATE_KEY_FILE"
  gpg --import "$PRIVATE_KEY_FILE" || {
    echo "Error: Failed to import private key"
    rm -f "$PRIVATE_KEY_FILE"
    rm -f "$PUBLIC_KEY_FILE"
    return 1
  }
  rm -f "$PRIVATE_KEY_FILE"
  rm -f "$PUBLIC_KEY_FILE"
  return 0
}

sign_rpms() {
  local rc=0

  # Check if at least one file is provided
  if [ $# -eq 0 ]; then
    echo "Error: No files provided to sign."
    return 1
  fi

  # Check if rpmsign and gpg are installed, install if not
  if ! command -v rpmsign &>/dev/null; then
    echo "rpmsign not found. Installing rpm-sign"
    if command -v sudo &>/dev/null; then
      sudo dnf install -y rpm-sign
    else
      dnf install -y rpm-sign
    fi
    if [ $? -ne 0 ]; then
      echo "Error: Failed to install rpm-sign"
      return 1
    fi
  fi

  # Get the key ID of the imported private key
  KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1)
  if [ -z "$KEY_ID" ]; then
    echo "Error: No private key found after import."
    rm -f "$PRIVATE_KEY_FILE"
    rm -rf "$GNUPGHOME"
    return 1
  fi

  echo "=======================Signing RPMs======================="
  # Sign each RPM file. Any per-file failure flips rc to 1 so the caller sees a
  # non-zero exit; we keep iterating so the operator gets the full list of
  # failures in one run rather than aborting on the first bad file.
  for file in "$@"; do
    # Ensure the file has /output/ prefix if relative
    if [[ ! "$file" = /* ]]; then
      file="/output/$file"
    fi

    if [ ! -f "$file" ]; then
      echo "Error: File '$file' does not exist."
      rc=1
      continue
    fi

    # Check if the file is an RPM
    if ! file "$file" | grep -q "RPM"; then
      echo "Error: File '$file' is not an RPM file."
      rc=1
      continue
    fi

    # Sign the RPM using rpmsign, using passphrase if provided
    if rpmsign --define "_gpg_name $KEY_ID" --addsign "$file" >/dev/null 2>&1; then
      echo "Successfully signed '$file'."
    else
      echo "Error: Failed to sign '$file'."
      rc=1
    fi
  done
  echo "=======================Signing Completes=================="

  # Clean up
  rm -f "$PRIVATE_KEY_FILE"
  return $rc
}

validate_signatures() {

  # Check if files are provided
  if [ $# -eq 0 ]; then
    echo "Error: No files provided to validate."
    return 1
  fi

  # Install dependencies
  if ! command -v rpm &>/dev/null; then
    echo "Installing rpm"
    if command -v sudo &>/dev/null; then
      sudo dnf install -y rpm
    else
      dnf install -y rpm
    fi
    if [ $? -ne 0 ]; then
      echo "Error: Failed to install rpm"
      return 1
    fi
  fi

  # Validate each RPM
  local all_valid=0
  echo "=======================Starting validation======================="
  for file in "$@"; do
    if [[ ! "$file" = /* ]]; then
      file="/output/$file"
    fi

    if [ ! -f "$file" ]; then
      echo "Error: File '$file' does not exist."
      all_valid=1
      continue
    fi

    if ! file "$file" | grep -q "RPM"; then
      echo "Error: File '$file' is not an RPM file."
      all_valid=1
      continue
    fi

    CHECKSIG_OUTPUT=$(rpm --checksig "$file" 2>&1)
    echo "$CHECKSIG_OUTPUT"
    if echo "$CHECKSIG_OUTPUT" | grep -q "digests signatures OK"; then
      echo "Signature for '$file' is valid."
    else
      echo "Error: Signature for '$file' is invalid or missing."
      all_valid=1
    fi
  done
  echo "=======================Validation completes======================"
  # Clean up
  rm -f "$PUBLIC_KEY_FILE"

  return $all_valid
}
