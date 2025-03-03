# Use Ubuntu as the base image
FROM ubuntu:22.04

# Set non-interactive mode for package installations
ENV DEBIAN_FRONTEND=noninteractive

# Install required dependencies
RUN apt-get update && apt-get install -y \
    sudo \
    openssh-server \
    && rm -rf /var/lib/apt/lists/*

# Ensure SSH directory exists
RUN mkdir -p /var/run/sshd

# Create the 'postgres' user
RUN useradd -m -s /bin/bash postgres

# Allow passwordless sudo for the postgres user inside the container
RUN echo "postgres ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/postgres && \
    chmod 0440 /etc/sudoers.d/postgres

# Expose SSH port
EXPOSE 22

# Set working directory
WORKDIR /home/postgres

# Allow installation of software from GitHub Actions
RUN chmod -R 777 /usr/local /opt /var/tmp /tmp

# Start SSH service at container startup
CMD ["/usr/sbin/sshd", "-D"]



