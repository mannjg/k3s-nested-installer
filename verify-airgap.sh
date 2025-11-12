#!/usr/bin/env bash

#############################################################################
# Airgap Deployment Verification Script
#
# Verifies that a k3s airgap deployment is properly configured and
# operational with a private registry.
#
# Usage:
#   ./verify-airgap.sh --name <instance-name> --registry <registry-url>
#############################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
INSTANCE_NAME=""
REGISTRY=""
NAMESPACE=""
VERBOSE=false
OUTPUT_REPORT=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Verification results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
declare -a FAILURES

#############################################################################
# Utility Functions
#############################################################################

log() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

fatal() {
    error "$*"
    exit 1
}

debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $*" >&2
    fi
}

check_pass() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    success "✓ $*"
}

check_fail() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    FAILURES+=("$*")
    error "✗ $*"
}

#############################################################################
# Parse Arguments
#############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name|-n)
                INSTANCE_NAME="$2"
                shift 2
                ;;
            --registry|-r)
                REGISTRY="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --output|-o)
                OUTPUT_REPORT="$2"
                shift 2
                ;;
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
Usage: $0 --name <instance-name> --registry <registry-url> [options]

Verifies airgap k3s deployment configuration and operation.

Required:
  --name NAME             K3s instance name
  --registry URL          Private registry URL (e.g., docker.local)

Optional:
  --namespace NS          Kubernetes namespace (default: k3s-<name>)
  --output FILE           Output verification report file
  --verbose               Show detailed output
  -h, --help              Show this help message

Examples:
  # Basic verification
  $0 --name test --registry docker.local

  # With custom namespace and output
  $0 --name prod --registry myregistry.com:5000 --namespace production --output verify-report.txt

EOF
}

validate_config() {
    if [[ -z "$INSTANCE_NAME" ]]; then
        fatal "Instance name is required. Use --name <name>"
    fi

    if [[ -z "$REGISTRY" ]]; then
        fatal "Registry URL is required. Use --registry <url>"
    fi

    # Set namespace if not provided
    if [[ -z "$NAMESPACE" ]]; then
        NAMESPACE="k3s-${INSTANCE_NAME}"
    fi

    debug "Configuration:"
    debug "  Instance: $INSTANCE_NAME"
    debug "  Registry: $REGISTRY"
    debug "  Namespace: $NAMESPACE"
}

#############################################################################
# Verification Checks
#############################################################################

check_prerequisites() {
    log "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        check_fail "kubectl is not installed"
        return 1
    fi
    check_pass "kubectl is installed"

    # Check docker
    if ! command -v docker &> /dev/null; then
        check_fail "docker is not installed"
        return 1
    fi
    check_pass "docker is installed"

    return 0
}

check_deployment_exists() {
    log "Checking k3s deployment..."

    if ! kubectl get deployment k3s -n "$NAMESPACE" &> /dev/null; then
        check_fail "k3s deployment not found in namespace $NAMESPACE"
        return 1
    fi
    check_pass "k3s deployment exists"

    # Check pod is running
    local pod_status=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].status.phase}')
    if [[ "$pod_status" != "Running" ]]; then
        check_fail "k3s pod is not running (status: $pod_status)"
        return 1
    fi
    check_pass "k3s pod is running"

    # Check containers are ready
    local ready=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="k3d")].ready}')
    if [[ "$ready" != "true" ]]; then
        check_fail "k3d container is not ready"
        return 1
    fi
    check_pass "k3d container is ready"

    return 0
}

check_cluster_operational() {
    log "Checking inner k3s cluster..."

    # Check if we can access the cluster
    local node_status=$(kubectl exec -n "$NAMESPACE" deployment/k3s -c k3d -- kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Failed")

    if [[ "$node_status" != "True" ]]; then
        check_fail "k3s node is not Ready"
        return 1
    fi
    check_pass "k3s node is Ready"

    # Check system pods
    local coredns_status=$(kubectl exec -n "$NAMESPACE" deployment/k3s -c k3d -- kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Failed")
    if [[ "$coredns_status" != "Running" ]]; then
        check_fail "CoreDNS pod is not running"
        return 1
    fi
    check_pass "CoreDNS pod is running"

    return 0
}

check_registry_configuration() {
    log "Checking registry mirror configuration..."

    # Check registries ConfigMap exists
    if ! kubectl get configmap k3s-registries -n "$NAMESPACE" &> /dev/null; then
        check_fail "registries ConfigMap not found"
        return 1
    fi
    check_pass "registries ConfigMap exists"

    # Check registries.yaml content in k3d container
    local registries_content=$(kubectl exec -n "$NAMESPACE" deployment/k3s -c k3d -- cat /tmp/registries.yaml 2>/dev/null || echo "")
    if [[ -z "$registries_content" ]]; then
        check_fail "registries.yaml not found in k3d container"
        return 1
    fi
    check_pass "registries.yaml exists in k3d container"

    # Check if registry is configured in registries.yaml
    if ! echo "$registries_content" | grep -q "$REGISTRY"; then
        check_fail "Registry $REGISTRY not configured in registries.yaml"
        return 1
    fi
    check_pass "Registry $REGISTRY configured in registries.yaml"

    # Check containerd registry configuration
    local docker_io_config=$(kubectl exec -n "$NAMESPACE" deployment/k3s -c k3d -- docker exec k3d-${INSTANCE_NAME}-server-0 cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/docker.io/hosts.toml 2>/dev/null || echo "")
    if [[ -z "$docker_io_config" ]]; then
        warn "Could not verify containerd registry configuration"
    elif echo "$docker_io_config" | grep -q "$REGISTRY"; then
        check_pass "Containerd configured to use $REGISTRY as mirror"
    else
        check_fail "Containerd not configured to use $REGISTRY as mirror"
        return 1
    fi

    return 0
}

check_images_in_registry() {
    log "Checking required images in private registry..."

    # List of required images (based on k3s v1.31)
    local required_images=(
        "docker:27-dind"
        "k3d:latest"
        "k3d-proxy:latest"
        "k3d-tools:latest"
        "k3s:v1.31.5-k3s1"
        "local-path-provisioner:v0.0.30"
        "mirrored-coredns-coredns:1.12.0"
        "mirrored-metrics-server:v0.7.2"
        "mirrored-pause:3.6"
    )

    local missing_images=0
    for img in "${required_images[@]}"; do
        # Check if image exists locally with docker.local prefix
        if docker image inspect "${REGISTRY}/${img}" &> /dev/null; then
            debug "Found: ${REGISTRY}/${img}"
        else
            warn "Missing: ${REGISTRY}/${img}"
            missing_images=$((missing_images + 1))
        fi
    done

    if [[ $missing_images -eq 0 ]]; then
        check_pass "All ${#required_images[@]} required images found in registry"
    else
        check_fail "$missing_images of ${#required_images[@]} required images missing from registry"
        return 1
    fi

    return 0
}

check_image_pull_events() {
    log "Checking image pull events..."

    # Get recent image pull events from k3s cluster
    local pull_events=$(kubectl exec -n "$NAMESPACE" deployment/k3s -c k3d -- kubectl get events -A --sort-by='.lastTimestamp' 2>/dev/null | grep -i 'pulled' | tail -5 || echo "")

    if [[ -z "$pull_events" ]]; then
        warn "No recent image pull events found"
    else
        local pull_count=$(echo "$pull_events" | wc -l)
        check_pass "Found $pull_count recent image pull events"
        debug "Recent pulls:"
        echo "$pull_events" | while read line; do
            debug "  $line"
        done
    fi

    return 0
}

#############################################################################
# Reporting
#############################################################################

generate_report() {
    if [[ -z "$OUTPUT_REPORT" ]]; then
        OUTPUT_REPORT="verify-airgap-${INSTANCE_NAME}-$(date +%Y%m%d-%H%M%S).txt"
    fi

    log "Generating verification report..."

    cat > "$OUTPUT_REPORT" << EOF
#############################################################################
# Airgap Deployment Verification Report
# Generated: $(date)
#############################################################################

Instance: $INSTANCE_NAME
Namespace: $NAMESPACE
Registry: $REGISTRY

VERIFICATION SUMMARY
═══════════════════════════════════════════════════════════
Total Checks:  $TOTAL_CHECKS
Passed:        $PASSED_CHECKS
Failed:        $FAILED_CHECKS

EOF

    if [[ $FAILED_CHECKS -gt 0 ]]; then
        cat >> "$OUTPUT_REPORT" << EOF
FAILED CHECKS
═══════════════════════════════════════════════════════════
EOF
        for failure in "${FAILURES[@]}"; do
            echo "  - $failure" >> "$OUTPUT_REPORT"
        done
        echo "" >> "$OUTPUT_REPORT"
    fi

    cat >> "$OUTPUT_REPORT" << EOF
VERIFICATION DETAILS
═══════════════════════════════════════════════════════════

$(kubectl get deployment k3s -n "$NAMESPACE" -o wide 2>&1 || echo "Failed to get deployment info")

Inner K3s Cluster Status:
$(kubectl exec -n "$NAMESPACE" deployment/k3s -c k3d -- kubectl get nodes 2>&1 || echo "Failed to get node info")

$(kubectl exec -n "$NAMESPACE" deployment/k3s -c k3d -- kubectl get pods -A 2>&1 || echo "Failed to get pod info")

Registry Configuration:
$(kubectl exec -n "$NAMESPACE" deployment/k3s -c k3d -- cat /tmp/registries.yaml 2>&1 || echo "Failed to get registries.yaml")

EOF

    success "Report saved to: $OUTPUT_REPORT"
}

display_summary() {
    echo "" >&2
    if [[ $FAILED_CHECKS -eq 0 ]]; then
        success "═══════════════════════════════════════════════════════════" >&2
        success "  Airgap Deployment Verification: PASSED" >&2
        success "═══════════════════════════════════════════════════════════" >&2
        echo "" >&2
        success "All $TOTAL_CHECKS verification checks passed!" >&2
        echo "" >&2
        log "Your k3s airgap deployment is properly configured and operational." >&2
        log "Images are being served from the private registry: $REGISTRY" >&2
    else
        error "═══════════════════════════════════════════════════════════" >&2
        error "  Airgap Deployment Verification: FAILED" >&2
        error "═══════════════════════════════════════════════════════════" >&2
        echo "" >&2
        error "$FAILED_CHECKS of $TOTAL_CHECKS checks failed:" >&2
        for failure in "${FAILURES[@]}"; do
            echo "  - $failure" >&2
        done
        echo "" >&2
        log "Please review the verification report for details: $OUTPUT_REPORT" >&2
        exit 1
    fi
    echo "" >&2
}

#############################################################################
# Main Execution
#############################################################################

main() {
    parse_args "$@"
    validate_config

    log "Starting airgap deployment verification..."
    echo "" >&2

    check_prerequisites
    check_deployment_exists
    check_cluster_operational
    check_registry_configuration
    check_images_in_registry
    check_image_pull_events

    generate_report
    display_summary
}

# Run main function
main "$@"
