#!/bin/bash

# =============================================================================
# Spock Extension Test Suite Runner
# =============================================================================
# This script provides a comprehensive test runner for the Spock PostgreSQL
# extension with TAP (Test Anything Protocol) support, elapsed time tracking,
# code coverage reporting, and professional test result formatting.
#
# Features:
# - Automated test discovery from schedule file
# - Real-time test execution with clean output
# - TAP-compliant test results
# - Code coverage reporting (optional)
# - Detailed logging and error reporting
# - Test result summaries with statistics
#
# Usage:
#   ./run_tests.sh                    # Run all tests
#   COVERAGE_ENABLED=true ./run_tests.sh  # Run with code coverage
#   COVERAGE_THRESHOLD=90 ./run_tests.sh  # Set coverage threshold
#
# Code Coverage:
#   Coverage is optional and requires lcov and genhtml tools
#   Install with: brew install lcov (macOS) or apt-get install lcov (Linux)
#   Coverage data is saved to coverage/ directory

set -euo pipefail

# Export current directory to PATH for spock tools
export PATH="$(pwd):$PATH"

# These variables are set to defaults for running in github action
if [ -n "${PGVER:-}" ]; then
    export PG_CONFIG=/home/pgedge/pgedge/pg${PGVER}/bin/pg_config
    export LD_LIBRARY_PATH=/home/pgedge/pgedge/pg${PGVER}/lib/
    export PATH="/home/pgedge/pgedge/pg${PGVER}/bin:$PATH"
fi

# Ensure PostgreSQL binaries are available in PATH
if ! command -v psql >/dev/null 2>&1; then
    echo "ERROR: PostgreSQL binaries not found in PATH"
    echo "Please ensure PostgreSQL is installed and accessible via PATH"
    echo "  - Add PostgreSQL bin directory to PATH, or"
    echo "  - Use 'pg_config --bindir' to find the correct path"
    exit 1
fi

# Ensure other required PostgreSQL binaries are available
if ! command -v initdb >/dev/null 2>&1; then
    echo "ERROR: initdb not found in PATH"
    echo "Please ensure PostgreSQL is properly installed"
    exit 1
fi

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1"
}

log_test() {
    echo "[TEST] $1"
}


# =============================================================================
# Configuration
# =============================================================================

# Test configuration
readonly TEST_DIR="t"
readonly LOG_DIR="logs"
readonly SCHEDULE_FILE="schedule"
readonly TEST_EXTENSION=".pl"

# Export TESTLOGDIR for SpockTest.pm to use (absolute path)
export TESTLOGDIR="$(pwd)/$LOG_DIR"

# Code coverage configuration
COVERAGE_ENABLED="${COVERAGE_ENABLED:-false}"
readonly COVERAGE_DIR="coverage"
readonly COVERAGE_REPORT_DIR="$COVERAGE_DIR/reports"
readonly COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-80}"  # Minimum coverage percentage

# No colors - plain text output

# =============================================================================
# Test Suite Configuration
# =============================================================================

# Test suite will be auto-discovered from t/ directory
TEST_SUITE_IDS=()
TEST_SUITE_NAMES=()

# =============================================================================
# Test Discovery
# =============================================================================

discover_tests() {
    # Clear arrays
    TEST_SUITE_IDS=()
    TEST_SUITE_NAMES=()
    
    # Read test cases from schedule file
    if [ -f "$SCHEDULE_FILE" ]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            case "$line" in
                \#*) continue ;;
                "") continue ;;
            esac
            
            # Parse test: lines
            case "$line" in
                *test:[[:space:]]*)
                    local test_id=$(echo "$line" | sed 's/.*test:[[:space:]]*\([^[:space:]]*\).*/\1/')
                    local test_name=$(echo "$test_id" | sed 's/_/ /g' | sed 's/\b\w/\U&/g')
                    
                    # Check if test file exists
                    if [ -f "$TEST_DIR/${test_id}${TEST_EXTENSION}" ]; then
                        TEST_SUITE_IDS+=("$test_id")
                        TEST_SUITE_NAMES+=("$test_name")
                    else
                        log_warning "Test file not found: $TEST_DIR/${test_id}${TEST_EXTENSION} (listed in schedule)"
                    fi
                    ;;
            esac
        done < "$SCHEDULE_FILE"
    else
        log_warning "Schedule file not found: $SCHEDULE_FILE, falling back to auto-discovery"
        
        # Fallback to auto-discovery
        local test_files=($(find "$TEST_DIR" -name "*${TEST_EXTENSION}" -type f | sort))
        
        for test_file in "${test_files[@]}"; do
            local test_id=$(basename "$test_file" "${TEST_EXTENSION}")
            local test_name=$(basename "$test_file" "${TEST_EXTENSION}" | sed 's/_/ /g' | sed 's/\b\w/\U&/g')
            
            TEST_SUITE_IDS+=("$test_id")
            TEST_SUITE_NAMES+=("$test_name")
        done
    fi
}

# =============================================================================
# Code Coverage Functions
# =============================================================================

setup_coverage() {
    if [ "$COVERAGE_ENABLED" = "true" ]; then
        log_info "Setting up code coverage..."
        
        # Check for coverage tools
        local missing_tools=()
        if ! command -v lcov >/dev/null 2>&1; then
            missing_tools+=("lcov")
        fi
        if ! command -v genhtml >/dev/null 2>&1; then
            missing_tools+=("genhtml")
        fi
        
        if [ ${#missing_tools[@]} -gt 0 ]; then
            log_warning "Coverage tools not found: ${missing_tools[*]}"
            log_warning "Code coverage disabled - required tools not available"
            log_info "Install missing tools: brew install lcov (macOS) or apt-get install lcov (Linux)"
            return 1
        fi
        
        # All tools available, proceed with coverage setup
        mkdir -p "$COVERAGE_DIR"
        mkdir -p "$COVERAGE_REPORT_DIR"
        
        # Enable PostgreSQL coverage
        export PG_COVERAGE=1
        local coverage_data_dir="$COVERAGE_DIR/data"
        export COVERAGE_DATA_DIR="$coverage_data_dir"
        mkdir -p "$coverage_data_dir"
        
        log_info "Code coverage enabled. Data will be saved to $coverage_data_dir"
        return 0
    fi
    return 1
}

generate_coverage_report() {
    if [ "$COVERAGE_ENABLED" = "true" ]; then
        log_info "Generating code coverage report..."
        
        # Check if coverage data exists
        if [ -d "$COVERAGE_DATA_DIR" ] && [ "$(ls -A "$COVERAGE_DATA_DIR" 2>/dev/null)" ]; then
            # Generate HTML report if genhtml is available
            if command -v genhtml >/dev/null 2>&1; then
                genhtml "$COVERAGE_DATA_DIR"/*.info -o "$COVERAGE_REPORT_DIR/html" 2>/dev/null || true
                log_info "HTML coverage report generated: $COVERAGE_REPORT_DIR/html/index.html"
            else
                log_warning "genhtml not found - HTML coverage report not generated"
            fi
            
            # Generate text report if lcov is available
            if command -v lcov >/dev/null 2>&1; then
                lcov --summary "$COVERAGE_DATA_DIR"/*.info > "$COVERAGE_REPORT_DIR/summary.txt" 2>/dev/null || true
                log_info "Coverage summary: $COVERAGE_REPORT_DIR/summary.txt"
            else
                log_warning "lcov not found - coverage summary not generated"
            fi
            
            # Show basic coverage stats
            echo ""
            echo "Code Coverage Summary:"
            echo "======================"
            if [ -f "$COVERAGE_REPORT_DIR/summary.txt" ]; then
                cat "$COVERAGE_REPORT_DIR/summary.txt"
            else
                echo "Coverage data collected but coverage tools not available"
                echo "Install lcov and genhtml for detailed coverage reports"
            fi
        else
            log_warning "No coverage data found"
        fi
    fi
}

# =============================================================================
# Environment Setup
# =============================================================================

setup_environment() {
    # Create logs directory
    mkdir -p "$LOG_DIR"

    # Setup coverage if enabled
    if ! setup_coverage; then
        # Coverage setup failed, disable it
        COVERAGE_ENABLED="false"
    fi

    # Clean up any running processes
    pkill -f postgres 2>/dev/null || true
    sleep 2
    rm -rf /tmp/tmp_* 2>/dev/null || true
    rm -f /tmp/.s.PGSQL.* 2>/dev/null || true
}

# =============================================================================
# System Information
# =============================================================================

get_system_info() {
    # Get system information
    local os_name=$(uname -s)
    local os_version=$(uname -r)
    local arch=$(uname -m)
    local hostname=$(hostname)
    local user=$(whoami)
    
    # Get PostgreSQL version and PATH
    local pg_version=$(psql --version 2>/dev/null | head -1 | sed 's/psql (PostgreSQL) //' | sed 's/ .*//')
    local pg_bin_path=$(which psql 2>/dev/null | sed 's|/psql$||')
    
    # Get coverage tool versions
    local lcov_version=""
    local genhtml_version=""
    local prove_version=""
    if command -v lcov >/dev/null 2>&1; then
        lcov_version=$(lcov --version 2>/dev/null | head -1 | sed 's/.*version //' | sed 's/ .*//')
    fi
    if command -v genhtml >/dev/null 2>&1; then
        genhtml_version=$(genhtml --version 2>/dev/null | head -1 | sed 's/.*version //' | sed 's/ .*//')
    fi
    if command -v prove >/dev/null 2>&1; then
        prove_version=$(prove --version 2>/dev/null | head -1 | sed 's/.*version //' | sed 's/ .*//')
    fi
    
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    Spock Test Suite Runner                   ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Operating System: $os_name $os_version ($arch)"
    echo "║  Hostname: $hostname"
    echo "║  User: $user"
    
    if [ -n "$pg_version" ]; then
        echo "║  PostgreSQL Version: $pg_version"
    else
        echo "║  PostgreSQL Version: Not found in PATH"
    fi
    
    if [ -n "$pg_bin_path" ]; then
        echo "║  PostgreSQL Bin Path: $pg_bin_path"
    else
        echo "║  PostgreSQL Bin Path: Not found in PATH"
    fi
    
    if [ -n "$lcov_version" ]; then
        echo "║  LCOV Version: $lcov_version"
    else
        echo "║  LCOV Version: Not available"
    fi
    
    if [ -n "$genhtml_version" ]; then
        echo "║  GenHTML Version: $genhtml_version"
    else
        echo "║  GenHTML Version: Not available"
    fi
    
    if [ -n "$prove_version" ]; then
        echo "║  Prove Version: $prove_version"
    else
        echo "║  Prove Version: Not available"
    fi
    
    echo "║  Test Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "║  Log Directory: $LOG_DIR/"
    echo "║  Test Framework: Spock Testing Framework (TAP)"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

# =============================================================================
# TAP Dependencies Check
# =============================================================================

check_tap_dependencies() {
    local missing_deps=()
    
    # Check for prove
    if ! command -v prove >/dev/null 2>&1; then
        missing_deps+=("prove")
    fi
    
    # Check for Test::More
    if ! perl -MTest::More -e "1" 2>/dev/null; then
        missing_deps+=("Test::More")
    fi
    
    # Check for Test::Harness
    if ! perl -MTest::Harness -e "1" 2>/dev/null; then
        missing_deps+=("Test::Harness")
    fi
    
    # Check for TAP::Harness
    if ! perl -MTAP::Harness -e "1" 2>/dev/null; then
        missing_deps+=("TAP::Harness")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warning "Missing TAP dependencies: ${missing_deps[*]}"
        log_info "Installing missing dependencies..."
        
        for dep in "${missing_deps[@]}"; do
            if [ "$dep" = "prove" ]; then
                log_info "prove is usually included with Perl. Check your Perl installation."
            elif command -v cpanm >/dev/null 2>&1; then
                cpanm "$dep" || log_error "Failed to install $dep"
            elif command -v cpan >/dev/null 2>&1; then
                cpan "$dep" || log_error "Failed to install $dep"
            else
                log_error "No Perl package manager found. Please install: $dep"
            fi
        done
    fi
}

# =============================================================================
# Test Execution
# =============================================================================

run_single_test() {
    local test_file="$1"
    local test_name="$2"
    local test_description="$3"
    local log_file="$LOG_DIR/${test_name}.log"       # executables log
    local tap_log_file="$LOG_DIR/${test_name}.tap"   # TAP/prove output log
    
    local start_time=$(date +%s.%N)
    
    echo "┌─ Running $test_name${TEST_EXTENSION}..."
    
    # Run test with TAP output and capture timing
    local exit_code
    
    # Set PERL5LIB to include the test directory so SpockTest.pm can be found
    export PERL5LIB="$TEST_DIR:${PERL5LIB:-}"
    
    # Prepare per-test logs
    : > "$log_file"     # truncate executables log
    : > "$tap_log_file" # truncate tap log
    export SPOCKTEST_LOG_FILE="$log_file"
    # Run test using prove for better TAP handling
    echo "Running test..."
    
    # Run test with prove and capture both output and exit code properly
    set +e  # Temporarily disable exit on error
    prove --timer --trap --verbose "$test_file" > "$tap_log_file" 2>&1
    exit_code=$?
    set -e  # Re-enable exit on error
    
    local end_time=$(date +%s.%N)
    local elapsed_time=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Parse TAP output from tap log and clean variables
    local plan_line total_tests passed_tests failed_tests skipped_tests
    plan_line=$(grep -E '^1\.\.[0-9]+' "$tap_log_file" | tail -1 2>/dev/null || true)
    total_tests=$(echo "$plan_line" | sed -n 's/^1\.\.\([0-9]\+\).*$/\1/p' 2>/dev/null || echo "0")
    [ -z "$total_tests" ] && total_tests=0
    passed_tests=$(grep -cE '^ok ' "$tap_log_file" 2>/dev/null || echo "0")
    failed_tests=$(grep -cE '^not ok ' "$tap_log_file" 2>/dev/null || echo "0")
    skipped_tests=$(grep -cE '^ok .*# SKIP' "$tap_log_file" 2>/dev/null || echo "0")
    
    # If total_tests is still 0, try alternative parsing
    if [ "$total_tests" = "0" ] && [ -n "$plan_line" ]; then
        total_tests=$(echo "$plan_line" | grep -o '[0-9]\+' | tail -1)
        [ -z "$total_tests" ] && total_tests=0
    fi
    
    # Clean variables of any whitespace
    total_tests=$(echo "$total_tests" | tr -d ' \n\r')
    passed_tests=$(echo "$passed_tests" | tr -d ' \n\r')
    failed_tests=$(echo "$failed_tests" | tr -d ' \n\r')
    skipped_tests=$(echo "$skipped_tests" | tr -d ' \n\r')
    

    
    # Determine test status
    local status
    if [ "$exit_code" -eq 0 ] && [ "$failed_tests" -eq 0 ]; then
        status="PASSED"
    elif [ "$exit_code" -eq 0 ] && [ "$failed_tests" -gt 0 ]; then
        status="PARTIAL"
    else
        status="FAILED"
    fi
    
    # Store results
    eval "test_${test_id}_status=\"$status\""
    eval "test_${test_id}_passed=\"$passed_tests\""
    eval "test_${test_id}_failed=\"$failed_tests\""
    eval "test_${test_id}_skipped=\"$skipped_tests\""
    eval "test_${test_id}_elapsed=\"$elapsed_time\""
    eval "test_${test_id}_log_file=\"$log_file\""
    eval "test_${test_id}_total=\"$total_tests\""
    

    
    echo "└─ Log: $log_file (${elapsed_time}s)"
    echo ""
    
    return $exit_code
}

# =============================================================================
# Test Suite Execution
# =============================================================================

run_test_suite() {
    local total_start_time=$(date +%s.%N)
    local exit_code=0
    
    for i in "${!TEST_SUITE_IDS[@]}"; do
        local test_id="${TEST_SUITE_IDS[$i]}"
        local test_description="${TEST_SUITE_NAMES[$i]}"
        # numeric ID only for display
        local test_file="$TEST_DIR/${test_id}${TEST_EXTENSION}"
        
        if [ -f "$test_file" ]; then
            set +e  # Don't exit on test failure
            run_single_test "$test_file" "$test_id" "$test_description"
            local test_exit_code=$?
            set -e
            
            if [ $test_exit_code -ne 0 ]; then
                log_error "Test $test_id failed with exit code $test_exit_code"
            fi
        else
            log_warning "Test file not found: $test_file"
        fi
    done
    
    local total_end_time=$(date +%s.%N)
    local total_elapsed=$(echo "$total_end_time - $total_start_time" | bc -l 2>/dev/null || echo "0")
    
    eval "total_elapsed_time=\"$total_elapsed\""
    return $exit_code
}

# =============================================================================
# Results Summary
# =============================================================================

generate_summary() {
    echo "Test Results Summary"
    
    local total_tests=0
    local total_passed=0
    local total_failed=0
    local total_skipped=0
    
    for i in "${!TEST_SUITE_IDS[@]}"; do
        local test_id="${TEST_SUITE_IDS[$i]}"
        local test_description="${TEST_SUITE_NAMES[$i]}"
        local var_name="test_${test_id}"
        
        # Get test results with defaults
        local status passed failed skipped elapsed
        eval "status=\"\${${var_name}_status:-UNKNOWN}\""
        eval "passed=\"\${${var_name}_passed:-0}\""
        eval "failed=\"\${${var_name}_failed:-0}\""
        eval "skipped=\"\${${var_name}_skipped:-0}\""
        eval "elapsed=\"\${${var_name}_elapsed:-0}\""
        

        
        # Clean variables
        status=$(echo "$status" | tr -d '\n\r')
        passed=$(echo "$passed" | tr -d ' \n\r')
        failed=$(echo "$failed" | tr -d ' \n\r')
        skipped=$(echo "$skipped" | tr -d ' \n\r')
        elapsed=$(echo "$elapsed" | tr -d ' \n\r')
        
        # Ensure numeric values
        passed=${passed:-0}
        failed=${failed:-0}
        skipped=${skipped:-0}
        
        if [ -n "$status" ] && [ "$status" != "UNKNOWN" ]; then
                            case $status in
                "PASSED")
                    echo "  [ok] $test_id - $passed/$passed tests passed, ${elapsed}s"
                    total_passed=$((total_passed + passed))
                    ;;
                "PARTIAL")
                    echo "  [ok] $test_id - $passed/$((passed + failed)) tests passed, ${elapsed}s"
                    total_passed=$((total_passed + passed))
                    total_failed=$((total_failed + failed))
                    ;;
                "FAILED")
                    echo "  [failed] $test_id - $passed/$((passed + failed)) tests passed, ${elapsed}s"
                    total_passed=$((total_passed + passed))
                    total_failed=$((total_failed + failed))
                    ;;
            esac
            
            if [ "$skipped" -gt 0 ]; then
                total_skipped=$((total_skipped + skipped))
            fi
            
            total_tests=$((total_tests + passed + failed + skipped))
        fi
    done
    
    echo ""
    echo "Overall Statistics:"
    echo "  Total Tests: $total_tests"
    echo "  Passed: $total_passed"
    echo "  Failed: $total_failed"
    echo "  Skipped: $total_skipped"
    if [ $total_tests -gt 0 ]; then
        echo "  Success Rate: $(( (total_passed * 100) / total_tests ))%"
    else
        echo "  Success Rate: 0%"
    fi
    echo "  Total Time: ${total_elapsed_time}s"
    echo ""
    echo "Log files saved in: $LOG_DIR/"
    echo "Test completed at: $(date '+%Y-%m-%d %H:%M:%S')"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    local exit_code=0

    # Setup environment
    setup_environment
    
    # Display system information
    get_system_info
    
    # Check TAP dependencies
    check_tap_dependencies
    
    # Discover test files
    discover_tests
    
    # Run test suite
    run_test_suite
    exit_code=$?
    
    # Generate test summary
    generate_summary
    
    # Generate coverage report if enabled
    generate_coverage_report
    
    return $exit_code
}


# =============================================================================
# Script Execution
# =============================================================================

# Run main function
main "$@"
