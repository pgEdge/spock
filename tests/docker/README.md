# Docker infrastructure for the Spock testing

This document describes how the Docker infrastructure is organized, how to use it for
testing locally and as a part of a GitHub Actions workflow.

## Structure

The Spock Docker environment provides one `stable` image cached by the URL ghcr.io/pgedge/base-test-image:latest and a `floating` one, created on the fly during the tests.

The `stable` image is created according to the `Dockerfile-base.el9` file and should be built manually by the `cache-base-image.yml` workflow. It contains a Rocky Linux image with a complete set of libraries necessary for the Postgres build and passing regression and TAP tests.

The `floating` image is defined by the `Dockerfile-step-1.el9` file and is intended to be used in tests.

### Main parameters of the `stable` image
* Base OS: Rocky Linux 9
* Default user: `pgedge` (with sudo privileges, password: `asdf`)
* Current working directory: `/home/pgedge`
* SSH keys: id_ed25519 and corresponding id_ed25519.pub in the folder `~/.ssh` are provided (authorized for passwordless SSH as pgedge user)
* Includes complete PostgreSQL build dependencies (LLVM, ICU, SSL, etc.)
* Testing tools: Perl Test::More, SSH server/client configured

### Main parameters of the `floating` image
* Based on the `stable` image
* Build argument: `PGVER` - PostgreSQL version to build against
* Build argument: `MAKE_JOBS=4` - number of parallel make jobs (default: 4)
* Default user: `pgedge`
* Defined environment variables:
  * `PGVER` - PostgreSQL version
  * `PATH` - includes `/home/pgedge/pgedge/pg${PGVER}/bin`
  * `LD_LIBRARY_PATH` - includes `/home/pgedge/pgedge/pg${PGVER}/lib`
  * `PG_CONFIG` - points to `/home/pgedge/pgedge/pg${PGVER}/bin/pg_config`
  * `SPOCK_SOURCE_DIR` - set to `/home/pgedge/spock`
* Includes compiled Spock extension installed against PostgreSQL
* Test scripts from `tests/docker/*.sh` are available in `/home/pgedge/`
* Default entrypoint: `/home/pgedge/entrypoint.sh`

## Notes

* If you need an extra package, add it to the `Dockerfile-base.el9` file, updating the library list. Afterwards, re-run the workflow to rebuild the image.

## References

* See the [pgedge-docker repo](https://github.com/pgedge/pgedge-docker) for container guidance
