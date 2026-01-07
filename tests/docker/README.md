# Docker infrastructure for the Spock testing

This document describes how the Docker infrastructure is organized, how to use it for
testing locally and as a part of a GitHub Actions workflow.

## Structure

The Spock Docker environment provides one `stable` image cached by the URL ghcr.io/pgedge/base-test-image:latest and a `floating` one, created on the fly during the tests.

The `stable` image is created according to the `Dockerfile-base.el9` file and should be built manually by the `cache-base-image.yml` workflow. It contains a Rocky Linux image with a complete set of libraries necessary for the Postgres build and passing regression and TAP tests. This image does not define an entry point.

The `floating` image is defined by the `Dockerfile-step-1.el9` file and is intended to be used in tests. This image defines a default `tests/docker/entrypoint.sh` entry point.

### Main parameters of the `stable` image
* Base OS: Rocky Linux 9
* Default user: `pgedge` (with sudo privileges, password: `asdf`)
* Current working directory: `/home/pgedge`
* SSH keys: id_ed25519 and corresponding id_ed25519.pub in the folder `~/.ssh` are provided (authorized for passwordless SSH as pgedge user)
* Includes complete PostgreSQL build dependencies (LLVM, ICU, SSL, etc.)
* Testing tools: Perl Test::More, SSH server/client configured

### Main parameters of the `floating` image
* Based on the `stable` image
* Build arguments:
  * `PGVER` - PostgreSQL major version to build (e.g., 15, 16, 17, 18)
  * `MAKE_JOBS=4` - number of parallel make jobs (default: 4)
* Default user: `pgedge`
* Current working directory: `/home/pgedge`
* PostgreSQL installation:
  * Source: Cloned from official PostgreSQL GitHub repository (latest stable tag for specified major version)
  * Location: `/home/pgedge/postgres` (source code)
  * Install prefix: `/home/pgedge/pgedge/pg${PGVER}`
  * Patches: Spock-specific patches from `/home/pgedge/spock/patches/${PGVER}/` are applied before compilation
  * Build configuration: Debug mode enabled (`-g -O0`), with TAP tests, LLVM, assertions, dtrace, and full extension support
* pgEdge CLI tool:
  * Installed via `https://pgedge-download.s3.amazonaws.com/REPO/install.py`
  * Location: `/home/pgedge/pgedge/pgedge`
* Spock extension:
  * Source: Copied from build context to `/home/pgedge/spock`
  * Compiled and installed against the patched PostgreSQL
* Environment variables:
  * `PGVER` - PostgreSQL major version
  * `PATH` - includes `/home/pgedge/pgedge/pg${PGVER}/bin`
  * `LD_LIBRARY_PATH` - includes `/home/pgedge/pgedge/pg${PGVER}/lib`
  * `PG_CONFIG` - points to `/home/pgedge/pgedge/pg${PGVER}/bin/pg_config`
* Test scripts: All `tests/docker/*.sh` scripts available in `/home/pgedge/`
* Default entrypoint: `/home/pgedge/entrypoint.sh`

## Usage

Each test type - regression, TAP tests, spockbech or any new one must employ the `Dockerfile-step-1` docker image in tests. An instance initialisation and launch commands must be implemented in an entry point. If test builds custom environment (like regression or TAP tests) it have to define separate docker entry point.

For example, `tests/docker/run-spock-regress.sh` is an entry point for regression tests; `tests/tap/run_tests.sh` is an entry point for TAP tests. In opposite, spockbench creates three-node infrastructure based on the `docker/tests/docker-compose.yml` script and default entry point.

## Notes

* If you need an extra package, add it to the `Dockerfile-base.el9` file, updating the library list. Afterwards, re-run the workflow to rebuild the image.
* **OpenSSL compatibility**: Rocky Linux 9 ships with OpenSSL 3.5.1, while pgEdge's PostgreSQL may include OpenSSL 3.4.0. To avoid library conflicts, Python commands during build and runtime should temporarily unset `LD_LIBRARY_PATH` using `env -u LD_LIBRARY_PATH python3 ...`

## References

* See the [pgedge-docker repo](https://github.com/pgedge/pgedge-docker) for container guidance
