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
    libicu-dev \
    && rm -rf /var/lib/apt/lists/*

# Create a postgres user and data directory
RUN useradd -m postgres && \
    mkdir -p /var/lib/postgresql/data && \
    chown -R postgres:postgres /var/lib/postgresql

# Set environment variables
ENV PATH="/usr/local/pgsql/bin:$PATH"
ENV PGDATA="/var/lib/postgresql/data"

# Set PostgreSQL version (passed from GitHub Actions matrix)
ARG PG_VERSION
ARG PG_SOURCE_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz"

# Create build directory
WORKDIR /usr/src/postgresql

# Download and extract PostgreSQL source
RUN wget -O postgresql.tar.gz "${PG_SOURCE_URL}" && tar xzf postgresql.tar.gz --strip-components=1
    # rm postgresql.tar.gz

# Copy patches into the container
COPY ./patches /usr/src/postgresql/patches/

# Apply all patches matching the version (e.g., pg15_*.patch for PostgreSQL 15)
RUN PATCH_PREFIX="pg${PG_VERSION%%.*}-" && \
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
RUN ./configure --prefix=/usr/local/pgsql --without-icu && \
    make -j$(nproc) && \
    make install

# Switch to postgres user for cluster initialization
USER postgres

# Initialize the PostgreSQL cluster
RUN initdb -D /var/lib/postgresql/data

# Configure PostgreSQL to listen on all IP addresses and use trust authentication
RUN echo "listen_addresses='*'" >> /var/lib/postgresql/data/postgresql.conf && \
    echo "host all all 0.0.0.0/0 trust" >> /var/lib/postgresql/data/pg_hba.conf

# Expose PostgreSQL default port
EXPOSE 5432

ENTRYPOINT ["docker-entrypoint.sh"]

# Start PostgreSQL server with TCP/IP and trust authentication
CMD ["postgres", "-D", "/var/lib/postgresql/data"]




