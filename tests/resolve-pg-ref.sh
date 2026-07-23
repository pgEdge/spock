#!/bin/sh
# Resolve the PostgreSQL source ref to build for a given major version,
# per tests/postgres-build.conf.
#
# Prints the concrete ref (e.g. REL_17_STABLE or REL_16_9) to stdout.  All
# diagnostics go to stderr, so callers can safely capture the ref with
# `PG_REF=$(resolve-pg-ref.sh 17)`.
#
# Usage: resolve-pg-ref.sh <pg-major>
#
# Environment:
#   POSTGRES_BUILD_CONF  path to the config file
#                        (default: postgres-build.conf beside this script)
#   PG_GIT_REMOTE        remote queried for `tag` resolution
#                        (default: https://github.com/postgres/postgres.git)
set -eu

PG_GIT_REMOTE="${PG_GIT_REMOTE:-https://github.com/postgres/postgres.git}"

die() { echo "resolve-pg-ref: $1" >&2; exit "${2:-1}"; }

[ "$#" -eq 1 ] || die "usage: $(basename "$0") <pg-major>" 2

major="$1"
case "${major}" in
	'' | *[!0-9]*) die "major version must be numeric, got '${major}'" 2 ;;
esac

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
conf="${POSTGRES_BUILD_CONF:-${script_dir}/postgres-build.conf}"
[ -f "${conf}" ] || die "config not found: ${conf}"

# Extract the value of pg<major>_ref=, tolerating surrounding whitespace and
# trailing inline comments.  Last matching line wins.
mode="$(sed -n "s/^[[:space:]]*pg${major}_ref[[:space:]]*=[[:space:]]*//p" \
		"${conf}" \
	| sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' \
	| tail -n 1)"

[ -n "${mode}" ] || die "no entry 'pg${major}_ref=' in ${conf}"

case "${mode}" in
	branch)
		ref="REL_${major}_STABLE"
		;;
	tag)
		# Capture the remote listing first and check its status: a pipeline
		# only reports the last stage's exit code, so a failed or partial
		# ls-remote would otherwise feed a truncated list into the sort and
		# silently resolve an older/wrong tag.
		if ! tags="$(git ls-remote --tags --refs "${PG_GIT_REMOTE}" \
				"REL_${major}_*")"; then
			# Don't echo PG_GIT_REMOTE -- it may embed credentials.
			die "failed to query the configured remote (PG_GIT_REMOTE) for REL_${major}_* tags"
		fi
		# Newest tag by version sort (not lexical) so REL_16_10 beats
		# REL_16_9; the _._ round-trip lets sort -V compare the fields.
		ref="$(printf '%s\n' "${tags}" \
				| sed 's|.*refs/tags/||' \
				| tr '_' '.' \
				| sort -V \
				| tail -n 1 \
				| tr '.' '_')"
		[ -n "${ref}" ] || die "no REL_${major}_* tag at the configured remote (PG_GIT_REMOTE)"
		;;
	*)
		# Explicit pin: a PostgreSQL ref name (REL_*) or a commit SHA
		# (7-40 hex).  Reject anything else so a typo like "tga" fails
		# here with a clear message instead of as an obscure fetch error.
		if printf '%s' "${mode}" \
				| grep -Eq '^(REL_[0-9].*|[0-9a-fA-F]{7,40})$'; then
			ref="${mode}"
		else
			die "invalid pg${major}_ref '${mode}': expected tag, branch, a REL_* ref, or a commit SHA"
		fi
		;;
esac

echo "resolve-pg-ref: pg${major}_ref=${mode} -> ${ref}" >&2
printf '%s\n' "${ref}"
