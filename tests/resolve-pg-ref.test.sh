#!/bin/sh
# Tests for resolve-pg-ref.sh.
#
# The offline cases are deterministic (they use a temp config via
# POSTGRES_BUILD_CONF and never touch the network).  The `tag` case needs
# to reach a Postgres git remote; if the network is unavailable it is
# reported as SKIP rather than failing the suite.
#
# Usage: tests/resolve-pg-ref.test.sh
# Exit:  0 all assertions passed (skips allowed), non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="${SCRIPT_DIR}/resolve-pg-ref.sh"

pass=0
fail=0
skip=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
no()   { fail=$((fail + 1)); echo "FAIL - $1"; }
skipt(){ skip=$((skip + 1)); echo "skip - $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

CONF="${WORK}/postgres-build.conf"
cat > "${CONF}" <<'EOF'
# sample config for tests
pg15_ref=branch
pg16_ref=REL_16_9
pg17_ref=tag
pg18_ref = branch
pg20_ref=tga
pg21_ref=bb0a3ca8d218b6c0792235d7306117e5bc36294a
EOF

# ---- branch mode --------------------------------------------------------
out="$(POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 15 2>/dev/null)"
if [ "${out}" = "REL_15_STABLE" ]; then
	ok "branch -> REL_15_STABLE"
else
	no "branch -> REL_15_STABLE (got '${out}')"
fi

# ---- explicit pin emitted verbatim -------------------------------------
out="$(POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 16 2>/dev/null)"
if [ "${out}" = "REL_16_9" ]; then
	ok "explicit pin -> REL_16_9"
else
	no "explicit pin -> REL_16_9 (got '${out}')"
fi

# ---- a commit-SHA pin is emitted verbatim ------------------------------
out="$(POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 21 2>/dev/null)"
if [ "${out}" = "bb0a3ca8d218b6c0792235d7306117e5bc36294a" ]; then
	ok "commit-SHA pin emitted verbatim"
else
	no "commit-SHA pin emitted verbatim (got '${out}')"
fi

# ---- an unknown value (typo) is rejected, not treated as a pin ---------
if POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 20 >/dev/null 2>&1; then
	no "unknown ref value is rejected"
else
	ok "unknown ref value is rejected"
fi

# ---- surrounding whitespace tolerated ----------------------------------
out="$(POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 18 2>/dev/null)"
if [ "${out}" = "REL_18_STABLE" ]; then
	ok "whitespace around '=' tolerated"
else
	no "whitespace around '=' tolerated (got '${out}')"
fi

# ---- missing major -> non-zero -----------------------------------------
if POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 99 >/dev/null 2>&1; then
	no "missing major exits non-zero"
else
	ok "missing major exits non-zero"
fi

# ---- non-numeric arg -> non-zero ---------------------------------------
if POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" abc >/dev/null 2>&1; then
	no "non-numeric major exits non-zero"
else
	ok "non-numeric major exits non-zero"
fi

# ---- no arg -> non-zero -------------------------------------------------
if POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" >/dev/null 2>&1; then
	no "missing arg exits non-zero"
else
	ok "missing arg exits non-zero"
fi

# ---- missing config file -> non-zero -----------------------------------
if POSTGRES_BUILD_CONF="${WORK}/does-not-exist.conf" "${RESOLVER}" 15 \
		>/dev/null 2>&1; then
	no "missing config file exits non-zero"
else
	ok "missing config file exits non-zero"
fi

# ---- stdout stays clean (diagnostics go to stderr) ---------------------
out="$(POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 15 2>/dev/null)"
lines="$(printf '%s' "${out}" | wc -l)"
if [ "${out}" = "REL_15_STABLE" ] && [ "${lines}" -eq 0 ]; then
	ok "stdout carries only the ref"
else
	no "stdout carries only the ref (got '${out}')"
fi

# ---- tag mode (needs network; skips gracefully) ------------------------
out="$(POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 17 2>/dev/null)"
rc=$?
if [ "${rc}" -ne 0 ] || [ -z "${out}" ]; then
	skipt "tag -> newest REL_17_* (network unavailable)"
elif echo "${out}" | grep -Eq '^REL_17_[0-9]+$'; then
	ok "tag -> newest REL_17_* (${out})"
else
	no "tag -> newest REL_17_* (got '${out}')"
fi

# ---- tag mode fails closed when ls-remote errors (stubbed git) ---------
stubdir="${WORK}/stubbin"
mkdir -p "${stubdir}"
cat > "${stubdir}/git" <<'GIT'
#!/bin/sh
# Emit some tags, then fail partway -- a partial/dropped remote listing.
if [ "$1" = "ls-remote" ]; then
	printf '%s\trefs/tags/REL_17_1\n' 0000000000000000000000000000000000000000
	printf '%s\trefs/tags/REL_17_2\n' 1111111111111111111111111111111111111111
	exit 1
fi
exit 0
GIT
chmod +x "${stubdir}/git"
if PATH="${stubdir}:${PATH}" POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 17 \
		>/dev/null 2>&1; then
	no "tag mode fails closed when ls-remote errors"
else
	ok "tag mode fails closed when ls-remote errors"
fi

# ---- a credentialed remote URL is never written to logs ----------------
leakdir="${WORK}/leakbin"
mkdir -p "${leakdir}"
cat > "${leakdir}/git" <<'GIT'
#!/bin/sh
# ls-remote succeeds but lists no matching tags, so the resolver hits its
# "no tag found" error path.
exit 0
GIT
chmod +x "${leakdir}/git"
err="$(PATH="${leakdir}:${PATH}" \
	PG_GIT_REMOTE="https://u:SECRETTOKEN@example.invalid/pg.git" \
	POSTGRES_BUILD_CONF="${CONF}" "${RESOLVER}" 17 2>&1 >/dev/null)"
if printf '%s' "${err}" | grep -q "SECRETTOKEN"; then
	no "credentialed remote URL is not logged"
else
	ok "credentialed remote URL is not logged"
fi

echo "---"
echo "pass=${pass} fail=${fail} skip=${skip}"
[ "${fail}" -eq 0 ]
