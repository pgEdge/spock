# syntax=docker/dockerfile:1
#
# Antithesis images for Spock.  Build context is the repository root.
#
#   build     PostgreSQL (pgEdge-patched) and Spock, with Spock compiled with
#             Antithesis assertions and coverage instrumentation
#   node      one Spock node: postgres under a restart wrapper (n1..n4)
#   workload  client: psql, Python with the Antithesis SDK, cluster setup,
#             test templates under /opt/antithesis/test/v1
#
# Builds on amd64 (what Antithesis runs) and on arm64 (local validation on
# ARM hosts, see antithesis/local-validate.sh).
#
# PostgreSQL is not instrumented; only spock.so is, so the coverage signal
# stays on Spock.

ARG BASE_IMAGE=docker.io/rockylinux/rockylinux:9.6

# ------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS build

ARG PGVER=18
# Pinned so amd64 and arm64 builds get the same PostgreSQL.  Empty: resolve
# the newest REL_<PGVER>_* tag per tests/postgres-build.conf.
ARG PG_REF=REL_18_6
ARG MAKE_JOBS=8
ARG ANTITHESIS_SDK_CPP_VERSION=v0.5.0
ARG ANTITHESIS_INSTRUMENTATION_SHA256=977603ef6ff1a77aea8e738013a13ac4b109eaf926d1612a7f5a8e581c9ff7ae

ENV NO_COLOR=1

RUN set -eux; \
	dnf -y install --setopt=install_weak_deps=False \
		bison clang diffutils findutils flex git make patch perl \
		readline-devel zlib-devel; \
	dnf clean all

# PostgreSQL source with the pgEdge patches for this major version.
COPY tests/resolve-pg-ref.sh tests/postgres-build.conf /src/spock/tests/
COPY patches/ /src/spock/patches/
RUN set -eux; \
	ref="${PG_REF:-$(/src/spock/tests/resolve-pg-ref.sh "${PGVER}")}"; \
	echo "PostgreSQL ref: ${ref}"; \
	git init -q /src/postgres; \
	git -C /src/postgres remote add origin https://github.com/postgres/postgres.git; \
	git -C /src/postgres fetch -q --depth 1 origin "${ref}"; \
	git -C /src/postgres checkout -q --detach FETCH_HEAD; \
	echo "${ref}" > /src/pg-ref; \
	cd /src/postgres; \
	for p in /src/spock/patches/${PGVER}/*.diff; do \
		echo "applying $(basename "$p")"; \
		patch -p1 --quiet < "$p"; \
	done

# clang for PostgreSQL too, so Spock's compile flags (taken from pg_config)
# match the compiler that instruments it.
RUN set -eux; \
	cd /src/postgres; \
	./configure --prefix=/usr/local/pgsql \
		--enable-cassert --enable-debug --without-icu \
		CC=clang CFLAGS="-O2 -g -fno-omit-frame-pointer" > /dev/null; \
	make -j"${MAKE_JOBS}" > /dev/null; \
	make install > /dev/null; \
	make -C contrib/dblink install > /dev/null

# Coverage instrumentation header from the Antithesis C++ SDK (C-compatible).
RUN set -eux; \
	mkdir -p /opt/antithesis-sdk; \
	curl -fsSL -o /opt/antithesis-sdk/antithesis_instrumentation.h \
		"https://raw.githubusercontent.com/antithesishq/antithesis-sdk-cpp/${ANTITHESIS_SDK_CPP_VERSION}/antithesis_instrumentation.h"; \
	if [ -n "${ANTITHESIS_INSTRUMENTATION_SHA256}" ]; then \
		echo "${ANTITHESIS_INSTRUMENTATION_SHA256}  /opt/antithesis-sdk/antithesis_instrumentation.h" | sha256sum -c -; \
	fi

# Only what the Spock build needs, so edits elsewhere (docs, the scratchbook,
# antithesis/ scripts) do not force a rebuild.
COPY Makefile spock.control.in /src/spock/
COPY include/ /src/spock/include/
COPY src/ /src/spock/src/
COPY sql/ /src/spock/sql/
COPY tests/tap/schedule /src/spock/tests/tap/schedule
RUN set -eux; \
	cd /src/spock; \
	export PATH=/usr/local/pgsql/bin:$PATH; \
	make clean > /dev/null; \
	make -j"${MAKE_JOBS}" CC=clang ANTITHESIS=1 \
		ANTITHESIS_SDK_INCLUDE=/opt/antithesis-sdk > /dev/null; \
	make install > /dev/null; \
	so="$(pg_config --pkglibdir)/spock.so"; \
	nm "${so}" | grep -q antithesis_load_libvoidstar; \
	if nm -D --undefined-only "${so}" | grep __sanitizer_cov; then \
		echo "spock.so has unresolved coverage hooks and would not load"; \
		exit 1; \
	fi; \
	echo "spock.so is instrumented"

# ------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime-base

ENV NO_COLOR=1 \
	PATH=/usr/local/pgsql/bin:$PATH \
	LD_LIBRARY_PATH=/usr/local/pgsql/lib \
	PGUSER=admin \
	PGDATABASE=demo \
	PGPORT=5432

RUN set -eux; \
	dnf -y install --setopt=install_weak_deps=False \
		findutils hostname procps-ng readline zlib; \
	dnf clean all

COPY --from=build /usr/local/pgsql /usr/local/pgsql
COPY --from=build /src/pg-ref /usr/local/pgsql/PG_REF

RUN useradd -m -u 1000 postgres

# ------------------------------------------------------------------------------
FROM runtime-base AS node

# gdb for backtraces from the multiverse debugger.  PostgreSQL and spock.so
# are built with -g, so frames resolve without debuginfo packages.
RUN set -eux; \
	dnf -y install --setopt=install_weak_deps=False gdb; \
	dnf clean all

# The unstripped spock.so carries its own debug info; Antithesis reads it
# from /symbols.
RUN set -eux; \
	mkdir -p /symbols; \
	ln -s "$(pg_config --pkglibdir)/spock.so" /symbols/spock.so; \
	mkdir -p /data /opt/antithesis; \
	chown postgres:postgres /data

COPY --chmod=755 antithesis/node/node-entrypoint.sh /usr/local/bin/
# Node-side test commands only (pg_ctl, postmaster kill), kept apart from
# antithesis/test: a command found in several containers may run in any of
# them, and the workload's Python commands cannot run in a node image (no
# Python).
COPY --chmod=755 antithesis/node/test/ /opt/antithesis/test/

# The entrypoint starts as root and drops to postgres itself.
VOLUME /data
EXPOSE 5432
ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]

# ------------------------------------------------------------------------------
FROM runtime-base AS workload

ARG ANTITHESIS_PY_VERSION=0.4.0
ARG PSYCOPG_VERSION=3.3.6

ENV PYTHONUNBUFFERED=1 \
	PYTHONDONTWRITEBYTECODE=1

RUN set -eux; \
	dnf -y install --setopt=install_weak_deps=False python3.12 python3.12-pip; \
	dnf clean all; \
	python3.12 -m pip install --no-cache-dir \
		"antithesis==${ANTITHESIS_PY_VERSION}" \
		"psycopg[binary]==${PSYCOPG_VERSION}"

COPY samples/Z0DAN/ /opt/spock/Z0DAN/
COPY --chmod=755 antithesis/setup-complete.sh /usr/local/bin/setup-complete.sh
COPY --chmod=755 antithesis/workload/workload-entrypoint.sh /usr/local/bin/
COPY antithesis/test/ /opt/antithesis/test/

# Python assertions in test commands are cataloged from here.
RUN ln -s /opt/antithesis/test/v1 /opt/antithesis/catalog

# Runs as root: the Antithesis output directory is root-owned.
ENTRYPOINT ["/usr/local/bin/workload-entrypoint.sh"]
