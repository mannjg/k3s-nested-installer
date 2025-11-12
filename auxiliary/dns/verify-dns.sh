#!/usr/bin/env bash

#############################################################################
# DNS Verification Script
#
# Verifies that CoreDNS is correctly resolving ingress hostnames
#
# Usage:
#   ./verify-dns.sh [--verbose]
#############################################################################

set -euo pipefail

# Options
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#############################################################################
# Utility Functions
#############################################################################

log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

error() {
    echo -e "${RED}[✗]${NC} $*" >&2
}

fatal() {
    error "$*"
    exit 1
}

debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

#############################################################################
# Parse Arguments
#############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                fatal "Unknown option: $1"
                ;;
        esac
    done
}

show_usage() {
    cat << EOF
Usage: $0 [options]

Verifies that DNS resolution for ingress hostnames is working correctly.

Options:
  -v, --verbose  Show detailed output
  -h, --help     Show this help message

Examples:
  # Quick verification
  $0

  # Detailed verification
  $0 --verbose

EOF
}

#############################################################################
# Verification Functions
#############################################################################

check_prerequisites() {
    debug "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        fatal "kubectl is not installed or not in PATH"
    fi

    if ! kubectl cluster-info &> /dev/null; then
        fatal "Cannot connect to Kubernetes cluster"
    fi

    debug "Prerequisites OK"
}

get_coredns_config() {
    debug "Checking CoreDNS configuration..."

    local coredns_config
    coredns_config=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")

    if [[ -z "$coredns_config" ]]; then
        error "Could not retrieve CoreDNS configuration"
        return 1
    fi

    if echo "$coredns_config" | grep -q "hosts {"; then
        debug "CoreDNS has hosts configuration"
        return 0
    else
        error "CoreDNS does not have custom hosts configuration"
        return 1
    fi
}

get_ingress_ip() {
    debug "Getting ingress controller IP..."

    local ingress_ip
    ingress_ip=$(kubectl get pod -n ingress -l name=nginx-ingress-microk8s \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")

    if [[ -z "$ingress_ip" ]]; then
        ingress_ip=$(kubectl get pod -n ingress -l app.kubernetes.io/name=ingress-nginx \
            -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
    fi

    if [[ -z "$ingress_ip" ]]; then
        error "Could not find ingress controller IP"
        return 1
    fi

    echo "$ingress_ip"
}

test_dns_resolution() {
    local hostname=$1
    local expected_ip=$2

    debug "Testing DNS resolution for $hostname..."

    # Create a unique test pod name
    local pod_name="dns-test-$(date +%s)-$$"

    # Run nslookup in a temporary pod
    local result
    result=$(kubectl run "$pod_name" \
        --image=busybox:1.28 \
        --rm -i --restart=Never \
        --command -- nslookup "$hostname" 2>&1 || true)

    # Check if the resolution succeeded
    if echo "$result" | grep -q "Address.*$expected_ip"; then
        success "$hostname resolves to $expected_ip"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$result" | sed 's/^/    /'
        fi
        return 0
    else
        error "$hostname does not resolve correctly"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$result" | sed 's/^/    /'
        fi
        return 1
    fi
}

test_dns_from_existing_pod() {
    local hostname=$1

    debug "Testing DNS from existing pod (if available)..."

    # Try to find a running pod to test from
    local test_pod
    test_pod=$(kubectl get pod -A --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$test_pod" ]]; then
        debug "No existing pods found, skipping this test"
        return 0
    fi

    local test_ns
    test_ns=$(kubectl get pod -A --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")

    debug "Testing from pod $test_pod in namespace $test_ns"

    local result
    result=$(kubectl exec -n "$test_ns" "$test_pod" -- \
        nslookup "$hostname" 2>&1 || true)

    if echo "$result" | grep -q "Address:"; then
        success "DNS resolution works from existing pod"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$result" | sed 's/^/    /'
        fi
        return 0
    else
        warn "DNS resolution failed from existing pod"
        return 1
    fi
}

check_coredns_health() {
    debug "Checking CoreDNS health..."

    local ready_pods
    ready_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

    if echo "$ready_pods" | grep -q "True"; then
        success "CoreDNS pods are healthy"
        return 0
    else
        error "CoreDNS pods are not healthy"
        return 1
    fi
}

#############################################################################
# Main Execution
#############################################################################

main() {
    parse_args "$@"

    echo ""
    log "═══════════════════════════════════════════════════════════"
    log "  DNS Configuration Verification"
    log "═══════════════════════════════════════════════════════════"
    echo ""

    local failed=0

    # Check prerequisites
    check_prerequisites || ((failed++))

    # Check CoreDNS health
    echo ""
    log "Checking CoreDNS health..."
    check_coredns_health || ((failed++))

    # Check CoreDNS configuration
    echo ""
    log "Checking CoreDNS configuration..."
    get_coredns_config || ((failed++))

    # Get ingress IP
    echo ""
    log "Getting ingress controller IP..."
    local ingress_ip
    if ingress_ip=$(get_ingress_ip); then
        success "Ingress controller IP: $ingress_ip"
    else
        ((failed++))
    fi

    # Test DNS resolution for each hostname
    echo ""
    log "Testing DNS resolution..."
    local hostnames=("docker.local" "gitlab.local" "nexus.local" "jenkins.local" "argocd.local")

    for hostname in "${hostnames[@]}"; do
        test_dns_resolution "$hostname" "$ingress_ip" || ((failed++))
        sleep 1  # Brief pause between tests
    done

    # Test from existing pod if available
    echo ""
    log "Testing from existing pod..."
    test_dns_from_existing_pod "docker.local" || true  # Don't count this as failure

    # Summary
    echo ""
    log "═══════════════════════════════════════════════════════════"
    if [[ $failed -eq 0 ]]; then
        success "All DNS verification checks passed!"
        log "═══════════════════════════════════════════════════════════"
        echo ""
        log "DNS is configured correctly. Ingress hostnames resolve to: $ingress_ip"
        echo ""
        exit 0
    else
        error "$failed verification check(s) failed"
        log "═══════════════════════════════════════════════════════════"
        echo ""
        error "DNS configuration needs attention. Run with --verbose for details."
        echo ""
        exit 1
    fi
}

# Run main function
main "$@"
