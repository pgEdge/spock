#!/bin/bash

# =============================================================================
# Spock Test Suite Runner - Professional TAP Test Runner
# =============================================================================
# This script provides a comprehensive test runner for the Spock extension
# with TAP (Test Anything Protocol) support, elapsed time tracking,
# and professional reporting.

set -euo pipefail

# Export PostgreSQL PATH and current directory for spock tools
export PATH="/usr/local/pgsql.16/bin:$(pwd):$PATH"

# Ensure PostgreSQL binaries are available
if ! command -v psql >/dev/null 2>&1; then
    echo "ERROR: PostgreSQL binaries not found in PATH"
    echo "Please ensure /usr/local/pgsql.16/bin is in your PATH"
    exit 1
fi

# =============================================================================
# Configuration
# =============================================================================

# Test configuration
readonly TEST_DIR="t"
readonly LOG_DIR="logs"
readonly CONFIG_FILE="test_config.json"
readonly SCHEDULE_FILE="schedule"

# No colors - plain text output

# =============================================================================
# Test Suite Configuration
# =============================================================================

# Test suite will be auto-discovered from t/ directory
TEST_SUITE_IDS=()
TEST_SUITE_NAMES=()

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
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            
            # Parse test: lines
            if [[ "$line" =~ ^[[:space:]]*test:[[:space:]]*([^[:space:]]+) ]]; then
                local test_id="${BASH_REMATCH[1]}"
                local test_name=$(echo "$test_id" | sed 's/_/ /g' | sed 's/\b\w/\U&/g')
                
                # Check if test file exists
                if [ -f "$TEST_DIR/${test_id}.pl" ]; then
                    TEST_SUITE_IDS+=("$test_id")
                    TEST_SUITE_NAMES+=("$test_name")
                else
                    log_warning "Test file not found: $TEST_DIR/${test_id}.pl (listed in schedule)"
                fi
            fi
        done < "$SCHEDULE_FILE"
    else
        log_warning "Schedule file not found: $SCHEDULE_FILE, falling back to auto-discovery"
        
        # Fallback to auto-discovery
        local test_files=($(find "$TEST_DIR" -name "*.pl" -type f | sort))
        
        for test_file in "${test_files[@]}"; do
            local test_id=$(basename "$test_file" .pl)
            local test_name=$(basename "$test_file" .pl | sed 's/_/ /g' | sed 's/\b\w/\U&/g')
            
            TEST_SUITE_IDS+=("$test_id")
            TEST_SUITE_NAMES+=("$test_name")
        done
    fi
}

# =============================================================================
# Environment Setup
# =============================================================================

setup_environment() {
    # Create logs directory
    mkdir -p "$LOG_DIR"
    
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
            if command -v cpanm >/dev/null 2>&1; then
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
    local log_file="$LOG_DIR/${test_name}.log"
    
    local start_time=$(date +%s.%N)
    
    echo "┌─ Running $test_id.pl..."
    
    # Run test with TAP output and capture timing
    local test_output
    local exit_code
    
    # Change to the test directory so the tests can find SpockTest.pm
    local test_dir=$(dirname "$test_file")
    
    # Set PERL5LIB to include the test directory so SpockTest.pm can be found
    export PERL5LIB="$test_dir:${PERL5LIB:-}"
    
    # Run test and capture all output to log, but only show TAP output on screen
    echo "Running test..."
    cd "$test_dir"
    
    # Run test and capture all output
    if test_output=$(perl "$(basename "$test_file")" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi
    
    # Show only TAP output on screen (filter out PostgreSQL logs)
    echo "$test_output" | grep -E "^(ok|not ok|#|1\.\.|Bail out!)" || true
    
    cd - > /dev/null
    
    local end_time=$(date +%s.%N)
    local elapsed_time=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
    
    # Save output to log file
    echo "$test_output" > "$log_file"
    
    # Parse TAP output and clean variables
    local total_tests=$(echo "$test_output" | grep -c "^1\.\." || echo "0")
    local passed_tests=$(echo "$test_output" | grep -c "^ok " || echo "0")
    local failed_tests=$(echo "$test_output" | grep -c "^not ok " || echo "0")
    local skipped_tests=$(echo "$test_output" | grep -c "# TODO & SKIP" || echo "0")
    
    # Clean variables of any newlines
    total_tests=$(echo "$total_tests" | tr -d '\n')
    passed_tests=$(echo "$passed_tests" | tr -d '\n')
    failed_tests=$(echo "$failed_tests" | tr -d '\n')
    skipped_tests=$(echo "$skipped_tests" | tr -d '\n')
    
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
    eval "test_${test_name}_status=\"$status\""
    eval "test_${test_name}_passed=\"$passed_tests\""
    eval "test_${test_name}_failed=\"$failed_tests\""
    eval "test_${test_name}_skipped=\"$skipped_tests\""
    eval "test_${test_name}_elapsed=\"$elapsed_time\""
    eval "test_${test_name}_log_file=\"$log_file\""
    
    # Show only summary TAP output (hide individual test results)
    local tap_summary=$(echo "$test_output" | grep -E "^(1\.\.|Bail out!)" || true)
    if [ -n "$tap_summary" ]; then
        echo "$tap_summary"
    fi
    
    echo "└─ Log: $log_file (${elapsed_time}s)"
    echo ""
    
    return $exit_code
}

# =============================================================================
# Test Suite Execution
# =============================================================================

run_test_suite() {
    local total_start_time=$(date +%s.%N)
    
    for i in "${!TEST_SUITE_IDS[@]}"; do
        local test_id="${TEST_SUITE_IDS[$i]}"
        local test_description="${TEST_SUITE_NAMES[$i]}"
        local test_file="$TEST_DIR/${test_id}.pl"
        
        if [ -f "$test_file" ]; then
            run_single_test "$test_file" "$test_id" "$test_description" || {
                log_error "Test $test_id failed with exit code $?"
                continue
            }
        else
            log_warning "Test file not found: $test_file"
        fi
    done
    
    local total_end_time=$(date +%s.%N)
    local total_elapsed=$(echo "$total_end_time - $total_start_time" | bc -l 2>/dev/null || echo "0")
    
    eval "total_elapsed_time=\"$total_elapsed\""
}

# =============================================================================
# Results Summary
# =============================================================================

generate_summary() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                      Test Results Summary                    ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    
    local total_tests=0
    local total_passed=0
    local total_failed=0
    local total_skipped=0
    
    for i in "${!TEST_SUITE_IDS[@]}"; do
        local test_id="${TEST_SUITE_IDS[$i]}"
        local test_description="${TEST_SUITE_NAMES[$i]}"
        local var_name="test_${test_id}"
        
        # Get test results
        eval "status=\"\$${var_name}_status\""
        eval "passed=\"\$${var_name}_passed\""
        eval "failed=\"\$${var_name}_failed\""
        eval "skipped=\"\$${var_name}_skipped\""
        eval "elapsed=\"\$${var_name}_elapsed\""
        
        # Clean variables
        status=$(echo "$status" | tr -d '\n')
        passed=$(echo "$passed" | tr -d '\n')
        failed=$(echo "$failed" | tr -d '\n')
        skipped=$(echo "$skipped" | tr -d '\n')
        elapsed=$(echo "$elapsed" | tr -d '\n')
        
        if [ -n "$status" ]; then
            case $status in
                "PASSED")
                    echo "║  [ok] $test_id - $passed/$passed test passed, ${elapsed}s"
                    total_passed=$((total_passed + passed))
                    ;;
                "PARTIAL")
                    echo "║  [ok] $test_id - $passed/$((passed + failed)) test passed, ${elapsed}s"
                    total_passed=$((total_passed + passed))
                    total_failed=$((total_failed + failed))
                    ;;
                "FAILED")
                    echo "║  [failed] $test_id - $passed/$((passed + failed)) test passed, ${elapsed}s"
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
    echo "  Success Rate: $([ $total_tests -gt 0 ] && echo "$(( (total_passed * 100) / total_tests ))%" || echo "0%")"
    echo "  Total Time: ${total_elapsed_time}s"
    echo ""
    echo "Log files saved in: $LOG_DIR/"
    echo "Test completed at: $(date '+%Y-%m-%d %H:%M:%S')"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
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
    
    # Generate summary
    generate_summary
    

}

# =============================================================================
# Script Execution
# =============================================================================

# Run main function
main "$@"
