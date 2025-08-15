# Spock Regression Test Framework (TAP)

Regression test suite for the Spock PostgreSQL extension.

## Dependencies

- **Perl** (5.10+)
- **PostgreSQL** (in PATH)
- **Bash**
- **Test::More** (usually included with Perl)

## Quick Start

1. **Check dependencies**:
   ```bash
   which psql && which initdb && perl --version
   ```

2. **Run tests**:
   ```bash
   cd regression
   ./run_tests.sh
   ```

## Test Files

- `001_basic.pl` - Basic functionality
- `002_create_subscriber.pl` - Subscriber creation
- `003_cascade_replication.pl` - Cascade replication
- `004_non_default_repset.pl` - Non-default replication sets

## Options

```bash
COVERAGE_ENABLED=true ./run_tests.sh      # With code coverage
COVERAGE_THRESHOLD=90 ./run_tests.sh     # Set coverage threshold
```

## Troubleshooting

**PostgreSQL not found**: Add to PATH
```bash
export PATH="/path/to/postgresql/bin:$PATH"
```

**Test::More missing**: Install via package manager or CPAN
```bash
# Ubuntu/Debian
sudo apt-get install libtest-more-perl

# macOS
brew install perl

# CPAN
cpan Test::More
```

## Output

- TAP-compliant test results
- Logs in `logs/` directory
- Code coverage reports (when enabled)
