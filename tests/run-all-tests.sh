#!/usr/bin/env bash

###############################################################################
# Master Test Runner for k3s-nested-installer
#
# Runs all test suites and generates a comprehensive report
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
declare -a FAILED_SUITE_NAMES=()

log() {
    echo -e "${BLUE}[RUNNER]${NC} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

run_test_suite() {
    local suite_name="$1"
    local suite_path="$2"
    
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    
    log "Running test suite: $suite_name"
    echo "─────────────────────────────────────────────────────────────"
    
    if bash "$suite_path"; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
        success "Test suite '$suite_name' PASSED"
    else
        FAILED_SUITES=$((FAILED_SUITES + 1))
        FAILED_SUITE_NAMES+=("$suite_name")
        error "Test suite '$suite_name' FAILED"
    fi
    
    echo ""
}

show_final_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Final Test Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Test Suites Run: $TOTAL_SUITES"
    success "Passed:          $PASSED_SUITES"
    
    if [[ $FAILED_SUITES -gt 0 ]]; then
        error "Failed:          $FAILED_SUITES"
        echo ""
        error "Failed Suites:"
        for suite in "${FAILED_SUITE_NAMES[@]}"; do
            echo "  - $suite"
        done
    fi
    
    echo ""
    
    if [[ $FAILED_SUITES -eq 0 ]]; then
        success "════════════════════════════════════════════════════════"
        success "  ALL TESTS PASSED! ✓"
        success "════════════════════════════════════════════════════════"
        return 0
    else
        error "════════════════════════════════════════════════════════"
        error "  SOME TESTS FAILED! ✗"
        error "════════════════════════════════════════════════════════"
        return 1
    fi
}

main() {
    log "k3s-nested-installer Test Runner"
    log "Running all test suites..."
    echo ""
    
    # Run registry configuration tests
    run_test_suite "Registry Configuration" "$SCRIPT_DIR/test-registry-config.sh"
    
    # Add more test suites here as they are created
    # run_test_suite "Installation Tests" "$SCRIPT_DIR/test-installation.sh"
    # run_test_suite "Management Tests" "$SCRIPT_DIR/test-management.sh"
    
    # Show final summary
    show_final_summary
}

main "$@"
