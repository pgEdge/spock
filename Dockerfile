FROM debian:bullseye

# Install dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    libreadline-dev \
    zlib1g-dev \
    bison \
    flex \
    curl \
    ca-certificates \
    git \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Set PostgreSQL version (passed from GitHub Actions matrix)
ARG PG_VERSION
ARG PG_SOURCE_URL="https://ftp.postgresql.org/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz"

# Create build directory
WORKDIR /usr/src/postgresql

# Download and extract PostgreSQL source
RUN wget -O postgresql.tar.gz "${PG_SOURCE_URL}" && tar xzvf postgresql.tar.gz --strip-components=1
    # rm postgresql.tar.gz

# Copy all patches into the container
COPY patches /usr/src/postgresql/patches/

# Apply all patches matching the version (e.g., pg15_*.patch for PostgreSQL 15)
RUN PATCH_PREFIX="pg${PG_VERSION%%.*}_" && \
    echo "Applying patches with prefix: $PATCH_PREFIX" && \
    for patch in patches/${PATCH_PREFIX}*.patch; do \
        if [ -f "$patch" ]; then \
            echo "Applying patch: $patch"; \
            patch -p1 < "$patch"; \
        else \
            echo "No patches found for $PATCH_PREFIX"; \
        fi \
    done

# Configure and build PostgreSQL
RUN ./configure --prefix=/usr/local/pgsql && \
    make -j$(nproc) && \
    make install

# Create PostgreSQL data directory
RUN mkdir -p /var/lib/postgresql/data && \
    chown -R root:root /var/lib/postgresql

# Set PATH for PostgreSQL binaries
ENV PATH="/usr/local/pgsql/bin:$PATH"

# Default command
CMD ["postgres", "-D", "/var/lib/postgresql/data"]

