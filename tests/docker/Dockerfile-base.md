# pgEdge Base Test Image

## Overview

This document describes the **pgEdge Base Test Image** (`ghcr.io/pgedge/base-test-image`), a foundational Docker image designed for building and testing PostgreSQL extensions, specifically the pgEdge Spock logical replication extension.

**Image Registry**: `ghcr.io/pgedge/base-test-image:latest`
**Base OS**: Rocky Linux 9
**Platforms**: linux/amd64 (x86_64), linux/arm64 (Apple Silicon)
**Purpose**: Development and testing environment for PostgreSQL extension development

## Purpose

This image provides a **complete, reproducible build environment** for PostgreSQL and its extensions. It eliminates the need to manually install dozens of dependencies and ensures consistent builds across different development machines and CI/CD environments.

### Key Use Cases

1. **PostgreSQL Extension Development**: Build and test custom PostgreSQL extensions with all necessary compilation tools and libraries
2. **CI/CD Integration**: Use as a base image for automated testing pipelines
3. **Multi-version Testing**: Easily test extensions against different PostgreSQL versions
4. **Consistent Build Environment**: Reproducible builds across different systems and CI/CD platforms

## What This Image Provides

### 1. Complete Development Toolchain

- **Compilers**: GCC, Clang, LLVM with LLVM-dev support
- **Build Tools**: GNU Make, CMake, Autoconf, Automake, Bison, Flex
- **Version Control**: Git for cloning PostgreSQL and extension sources
- **Debugging Tools**: GDB and debugging symbols support

### 2. PostgreSQL Build Dependencies

The image includes **all** libraries required to build PostgreSQL with maximum feature set:

| Library | Purpose | Configure Flag |
|---------|---------|----------------|
| `zstd-devel` | Zstandard compression | `--with-zstd` |
| `lz4-devel` | LZ4 compression | `--with-lz4` |
| `libicu-devel` | Unicode and internationalization | `--with-icu` |
| `libxml2-devel` | XML support | `--with-libxml` |
| `libxslt-devel` | XSLT transformations | `--with-libxslt` |
| `openssl-devel` | SSL/TLS connections | `--with-openssl` |
| `krb5-devel` | Kerberos authentication | `--with-gssapi` |
| `openldap-devel` | LDAP authentication | `--with-ldap` |
| `pam-devel` | PAM authentication | `--with-pam` |
| `systemd-devel` | Systemd integration | `--with-systemd` |
| `python3-devel` | PL/Python language | `--with-python` |
| `readline-devel` | Enhanced psql CLI | Built-in |
| `llvm-devel` | JIT compilation | `--with-llvm` |
| `libuuid-devel` | UUID generation | `--with-uuid=ossp` |

### 3. Testing Infrastructure

- **Perl Testing Framework**: `perl-IPC-Run`, `Test::More` for PostgreSQL TAP tests
- **SSH Configuration**: Pre-configured SSH keys for multi-node testing scenarios
- **Network Tools**: `nc` (netcat), `bind-utils` (dig, nslookup) for connectivity testing
- **Process Tools**: `procps` for monitoring and debugging

### 4. User Configuration

- **Non-root user**: `pgedge` user with sudo privileges (password: `asdf`)
- **Home directory**: `/home/pgedge`
- **SSH keys**: Ed25519 key pair pre-generated and authorized for localhost
- **Working directory**: Set to `/home/pgedge` by default

## Build Inputs

### Required at Build Time

- **Base Image**: `rockylinux:9` (pulled from Docker Hub)
- **Build Arguments**:
  - `PGEDGE_USER` (default: `pgedge`) - Name of the non-root user

### Downloaded During Build

1. **System Packages** (~500MB compressed):
   - Rocky Linux 9 base system updates
   - Development Tools group install
   - 40+ development packages and their dependencies

2. **Perl Modules** (via CPAN):
   - `Test::More` - PostgreSQL TAP test framework

## Image Size and Optimization

**Expected Size**: ~1.5-2GB uncompressed

This large size is **intentional and appropriate** for a development/testing base image because:
- Contains complete compilation toolchain (LLVM alone is ~300MB)
- Includes headers and development libraries for all PostgreSQL features
- Prioritizes developer convenience over minimal size
- Enables building PostgreSQL with all features without additional dependencies

**Optimization**: The image performs aggressive cleanup:
```dockerfile
dnf clean all
rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*
rm -rf /root/.cpanm
```

## Usage Examples

### Basic Usage: Interactive Development

```bash
# Pull the image
docker pull ghcr.io/pgedge/base-test-image:latest

# Start an interactive session
docker run -it --rm ghcr.io/pgedge/base-test-image:latest /bin/bash

# Now inside the container as 'pgedge' user
git clone https://github.com/postgres/postgres.git
cd postgres
./configure --prefix=/home/pgedge/pg17 --enable-debug
make -j4
make install
```

### Use as Base Image for Extension Development

```dockerfile
FROM ghcr.io/pgedge/base-test-image:latest

# Switch to root for installation
USER root

# Copy your extension source
COPY . /home/pgedge/my-extension
RUN chown -R pgedge:pgedge /home/pgedge/my-extension

# Clone and build PostgreSQL
RUN git clone --branch REL_16_STABLE --depth 1 \
        https://github.com/postgres/postgres /home/pgedge/postgres && \
    cd /home/pgedge/postgres && \
    ./configure --prefix=/home/pgedge/pg16 && \
    make -j4 && make install

# Build your extension
WORKDIR /home/pgedge/my-extension
RUN make PG_CONFIG=/home/pgedge/pg16/bin/pg_config && \
    make install PG_CONFIG=/home/pgedge/pg16/bin/pg_config

# Switch back to non-root
USER pgedge
```

### CI/CD Integration

```yaml
# .github/workflows/test.yml
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/pgedge/base-test-image:latest
    steps:
      - uses: actions/checkout@v4
      - name: Build and test
        run: |
          cd /home/pgedge
          make PG_CONFIG=/path/to/pg_config
          make installcheck PG_CONFIG=/path/to/pg_config
```

## Platform Support

The image is built as a **multiplatform manifest** supporting:
- **linux/amd64** - Intel/AMD x86_64 systems
- **linux/arm64** - Apple Silicon Macs (M1/M2/M3/M4), AWS Graviton

Docker automatically selects the appropriate architecture when pulling the image:

```bash
# Docker automatically selects correct architecture
docker pull ghcr.io/pgedge/base-test-image:latest

# On Apple Silicon Mac → pulls linux/arm64 (native performance)
# On Intel/AMD → pulls linux/amd64 (native performance)
docker run -it ghcr.io/pgedge/base-test-image:latest /bin/bash
```

To explicitly pull a specific platform:

```bash
# Force ARM64 variant
docker pull --platform linux/arm64 ghcr.io/pgedge/base-test-image:latest

# Force AMD64 variant
docker pull --platform linux/amd64 ghcr.io/pgedge/base-test-image:latest
```

## Build Reproducibility

Every image build includes comprehensive metadata for exact reproduction:

### Build Information Embedded in Image

Each image contains a `/etc/pgedge/build-info.txt` file with:
- Build timestamp (ISO 8601 format)
- Git commit SHA used to build the image
- Git branch name
- Rocky Linux version
- Exact reproduction commands

View this information from any image:
```bash
docker run --rm ghcr.io/pgedge/base-test-image:latest cat /etc/pgedge/build-info.txt
```

### OCI Image Labels

Images include standard OCI labels and custom metadata:
```bash
docker inspect ghcr.io/pgedge/base-test-image:latest | jq '.[0].Config.Labels'
```

Labels include:
- `org.opencontainers.image.created` - Build timestamp
- `org.opencontainers.image.revision` - Git commit SHA
- `org.opencontainers.image.source` - Source repository URL
- `com.pgedge.base-os.version` - Rocky Linux version
- `com.pgedge.git.branch` - Git branch name

### Commit-Tagged Images

Each build is tagged with both:
- `:latest` - Always points to the most recent build
- `:${GIT_COMMIT}` - Immutable tag referencing the exact git commit

Pull a specific build:
```bash
# Replace with actual commit SHA from build output
docker pull ghcr.io/pgedge/base-test-image:a1b2c3d4e5f6...
```

### Reproducing a Build

To reproduce an image exactly:

1. **Find the git commit** from the image:
   ```bash
   docker inspect ghcr.io/pgedge/base-test-image:latest | \
     jq -r '.[0].Config.Labels."org.opencontainers.image.revision"'
   ```

2. **Checkout that commit**:
   ```bash
   git clone https://github.com/pgedge/spock.git
   cd spock
   git checkout <commit-sha>
   ```

3. **Build with the same parameters**:
   ```bash
   docker build -f tests/docker/Dockerfile-base.el9 \
     --build-arg BUILD_DATE=<timestamp> \
     --build-arg GIT_COMMIT=<commit> \
     --build-arg GIT_BRANCH=<branch> \
     --build-arg ROCKYLINUX_VERSION=<version> .
   ```

The exact build command is also printed in `/etc/pgedge/build-info.txt` within the image.

## Maintenance and Updates

### Rebuild Strategy

The base image should be rebuilt when:

1. **Security Updates**: Critical CVEs in Rocky Linux 9 base packages
2. **Dependency Updates**: New versions of PostgreSQL require updated libraries
3. **Tool Updates**: Major LLVM or compiler version updates
4. **Monthly**: Regular rebuild for non-critical updates

### Workflow

The image is built using GitHub Actions workflow:
- **Workflow**: `.github/workflows/cache-base-image.yml`
- **Trigger**: Manual dispatch (`workflow_dispatch`)
- **Cache**: Uses GitHub Actions cache for layer caching
- **Registry**: Published to GitHub Container Registry (GHCR)

To trigger a rebuild:
1. Navigate to Actions tab in GitHub
2. Select "Update base OS image" workflow
3. Click "Run workflow"

## Downstream Images

This base image is used by:

1. **Dockerfile-step-1.el9**: Builds PostgreSQL with Spock patches and compiles Spock extension
2. **CI/CD pipelines**: Automated testing workflows
3. **Developer environments**: Local development containers

## References

- **Source**: `tests/docker/Dockerfile-base.el9`
- **Registry**: https://github.com/pgedge/spock/pkgs/container/base-test-image
- **Rocky Linux**: https://rockylinux.org/
- **PostgreSQL Build Requirements**: https://www.postgresql.org/docs/current/install-requirements.html
- **Docker Multiplatform**: https://docs.docker.com/build/building/multi-platform/

---

**Maintained by**: pgEdge Team
**Contact**: andrei.lepikhov@pgedge.com
**License**: BSD
