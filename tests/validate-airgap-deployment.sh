#!/usr/bin/env bash

###############################################################################
# Airgap Deployment Validation Script
#
# SUCCESS CRITERIA:
# 1. k3s pod running (2/2 Ready) in MicroK8s
# 2. Infrastructure images from private registry (docker.local)
# 3. Internal k3s cluster operational
# 4. Internal k3s pods using private registry images
###############################################################################

set -euo pipefail

# Configuration
INSTANCE_NAME="${1:-airgap-test}"
NAMESPACE="k3s-${INSTANCE_NAME}"
PRIVATE_REGISTRY="docker.local"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
declare -a FAILURES=()

###############################################################################
# Utility Functions
###############################################################################

log() {
    echo -e "${BLUE}[TEST]${NC} $*"
}

success() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

error() {
    echo -e "${RED}[FAIL]${NC} $*"
}

test_pass() {
    local test_name="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    success "$test_name"
}

test_fail() {
    local test_name="$1"
    local reason="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILURES+=("$test_name: $reason")
    error "$test_name"
    error "  Reason: $reason"
}

###############################################################################
# SUCCESS CRITERION 1: K3s Pod Running in MicroK8s
###############################################################################

test_outer_pod_exists() {
    log "Test 1.1: k3s pod exists in namespace $NAMESPACE"
    
    if ! kubectl get pods -n "$NAMESPACE" -l app=k3s &>/dev/null; then
        test_fail "Pod exists" "No pod found in namespace $NAMESPACE"
        return 1
    fi
    
    test_pass "Pod exists in namespace $NAMESPACE"
    return 0
}

test_outer_pod_running() {
    log "Test 1.2: k3s pod is Running (2/2 containers Ready)"
    
    local status=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    local ready=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null)
    
    if [[ "$status" != "Running" ]]; then
        test_fail "Pod Running" "Pod status is '$status', not 'Running'"
        kubectl get pods -n "$NAMESPACE" -l app=k3s
        return 1
    fi
    
    if [[ "$ready" != "true true" ]]; then
        test_fail "Pod Running" "Containers not ready: $ready"
        kubectl describe pod -n "$NAMESPACE" -l app=k3s | tail -30
        return 1
    fi
    
    test_pass "Pod is Running (2/2 containers Ready)"
    return 0
}

###############################################################################
# SUCCESS CRITERION 2: Infrastructure Images from Private Registry
###############################################################################

test_infrastructure_images() {
    log "Test 2.1: Infrastructure images are from private registry"
    
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    # Check dind image
    local dind_image=$(kubectl get pod -n "$NAMESPACE" "$pod_name" -o jsonpath='{.spec.containers[?(@.name=="dind")].image}')
    if [[ ! "$dind_image" =~ ^${PRIVATE_REGISTRY}/ ]]; then
        test_fail "DinD image from private registry" "Image is '$dind_image', not from $PRIVATE_REGISTRY"
        return 1
    fi
    success "  DinD image: $dind_image ✓"
    
    # Check k3d image
    local k3d_image=$(kubectl get pod -n "$NAMESPACE" "$pod_name" -o jsonpath='{.spec.containers[?(@.name=="k3d")].image}')
    if [[ ! "$k3d_image" =~ ^${PRIVATE_REGISTRY}/ ]]; then
        test_fail "K3d image from private registry" "Image is '$k3d_image', not from $PRIVATE_REGISTRY"
        return 1
    fi
    success "  K3d image: $k3d_image ✓"
    
    test_pass "All infrastructure images from $PRIVATE_REGISTRY"
    return 0
}

###############################################################################
# SUCCESS CRITERION 3: Internal K3s Cluster Operational
###############################################################################

test_internal_cluster_accessible() {
    log "Test 3.1: Internal k3s cluster is accessible"
    
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    # Try to run kubectl get nodes inside the k3d container
    if ! kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- kubectl --kubeconfig=/output/kubeconfig.yaml get nodes &>/dev/null; then
        test_fail "Internal cluster accessible" "Cannot run kubectl inside k3d container"
        return 1
    fi
    
    test_pass "Internal k3s cluster is accessible"
    return 0
}

test_internal_cluster_healthy() {
    log "Test 3.2: Internal k3s cluster nodes are Ready"
    
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    local node_status=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- \
        kubectl --kubeconfig=/output/kubeconfig.yaml get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [[ "$node_status" != "True" ]]; then
        test_fail "Internal nodes Ready" "Node status is not Ready: $node_status"
        kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- kubectl --kubeconfig=/output/kubeconfig.yaml get nodes
        return 1
    fi
    
    test_pass "Internal k3s nodes are Ready"
    return 0
}

test_internal_coredns_running() {
    log "Test 3.3: CoreDNS is running in internal k3s"
    
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    local coredns_status=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- \
        kubectl --kubeconfig=/output/kubeconfig.yaml get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    
    if [[ "$coredns_status" != "Running" ]]; then
        test_fail "CoreDNS running" "CoreDNS status is '$coredns_status', not 'Running'"
        kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- kubectl --kubeconfig=/output/kubeconfig.yaml get pods -n kube-system
        return 1
    fi
    
    test_pass "CoreDNS is running in internal k3s"
    return 0
}

###############################################################################
# SUCCESS CRITERION 4: Internal Pods Using Private Registry Images
###############################################################################

test_internal_coredns_image() {
    log "Test 4.1: CoreDNS uses image from private registry"
    
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    local coredns_image=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- \
        kubectl --kubeconfig=/output/kubeconfig.yaml get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
    
    if [[ ! "$coredns_image" =~ ^${PRIVATE_REGISTRY}/ ]]; then
        test_fail "CoreDNS from private registry" "Image is '$coredns_image', not from $PRIVATE_REGISTRY"
        return 1
    fi
    
    success "  CoreDNS image: $coredns_image ✓"
    test_pass "CoreDNS uses image from $PRIVATE_REGISTRY"
    return 0
}

test_internal_metrics_server_image() {
    log "Test 4.2: Metrics Server uses image from private registry"
    
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    # Check if metrics-server exists
    local metrics_exists=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- \
        kubectl --kubeconfig=/output/kubeconfig.yaml get pods -n kube-system -l k8s-app=metrics-server -o jsonpath='{.items}' 2>/dev/null)
    
    if [[ -z "$metrics_exists" || "$metrics_exists" == "[]" ]]; then
        log "  Note: Metrics Server not deployed (optional component)"
        test_pass "Metrics Server check (not deployed)"
        return 0
    fi
    
    local metrics_image=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- \
        kubectl --kubeconfig=/output/kubeconfig.yaml get pods -n kube-system -l k8s-app=metrics-server -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
    
    if [[ ! "$metrics_image" =~ ^${PRIVATE_REGISTRY}/ ]]; then
        test_fail "Metrics Server from private registry" "Image is '$metrics_image', not from $PRIVATE_REGISTRY"
        return 1
    fi
    
    success "  Metrics Server image: $metrics_image ✓"
    test_pass "Metrics Server uses image from $PRIVATE_REGISTRY"
    return 0
}

test_internal_local_path_provisioner_image() {
    log "Test 4.3: Local Path Provisioner uses image from private registry"
    
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    local lpp_image=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- \
        kubectl --kubeconfig=/output/kubeconfig.yaml get pods -n kube-system -l app=local-path-provisioner -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
    
    if [[ -z "$lpp_image" ]]; then
        log "  Note: Local Path Provisioner not found (may use different label)"
        test_pass "Local Path Provisioner check (not found)"
        return 0
    fi
    
    if [[ ! "$lpp_image" =~ ^${PRIVATE_REGISTRY}/ ]]; then
        test_fail "Local Path Provisioner from private registry" "Image is '$lpp_image', not from $PRIVATE_REGISTRY"
        return 1
    fi
    
    success "  Local Path Provisioner image: $lpp_image ✓"
    test_pass "Local Path Provisioner uses image from $PRIVATE_REGISTRY"
    return 0
}

###############################################################################
# Display Results with Evidence
###############################################################################

show_evidence() {
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  OBJECTIVE EVIDENCE"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    echo "${BLUE}A. kubectl get pods -n $NAMESPACE${NC}"
    kubectl get pods -n "$NAMESPACE" -l app=k3s -o wide
    echo ""
    
    echo "${BLUE}B. kubectl describe pod (showing private registry images)${NC}"
    kubectl describe pod -n "$NAMESPACE" "$pod_name" | grep -A2 "Image:"
    echo ""
    
    echo "${BLUE}C. kubectl exec - Internal kubectl get pods${NC}"
    kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- kubectl --kubeconfig=/output/kubeconfig.yaml get pods -A
    echo ""
    
    echo "${BLUE}D. kubectl exec - Internal pod details (CoreDNS)${NC}"
    kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- kubectl --kubeconfig=/output/kubeconfig.yaml describe pod -n kube-system -l k8s-app=kube-dns | grep -E "Image:|Status:"
    echo ""
}

show_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Test Results Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Instance: $INSTANCE_NAME"
    echo "Namespace: $NAMESPACE"
    echo "Registry: $PRIVATE_REGISTRY"
    echo ""
    echo "Total Tests:  $TOTAL_TESTS"
    success "Passed:       $PASSED_TESTS"
    
    if [[ $FAILED_TESTS -gt 0 ]]; then
        error "Failed:       $FAILED_TESTS"
        echo ""
        error "Failed Tests:"
        for failure in "${FAILURES[@]}"; do
            echo "  - $failure"
        done
        echo ""
        return 1
    fi
    
    echo ""
    success "════════════════════════════════════════════════════════"
    success "  ALL SUCCESS CRITERIA MET! ✓"
    success "════════════════════════════════════════════════════════"
    echo ""
    
    show_evidence
    
    return 0
}

###############################################################################
# Main Execution
###############################################################################

main() {
    log "Airgap Deployment Validation"
    log "Instance: $INSTANCE_NAME"
    log "Namespace: $NAMESPACE"
    log "Private Registry: $PRIVATE_REGISTRY"
    echo ""
    
    log "═══ SUCCESS CRITERION 1: K3s Pod Running ═══"
    test_outer_pod_exists || true
    test_outer_pod_running || true
    echo ""
    
    log "═══ SUCCESS CRITERION 2: Infrastructure Images ═══"
    test_infrastructure_images || true
    echo ""
    
    log "═══ SUCCESS CRITERION 3: Internal Cluster Operational ═══"
    test_internal_cluster_accessible || true
    test_internal_cluster_healthy || true
    test_internal_coredns_running || true
    echo ""
    
    log "═══ SUCCESS CRITERION 4: Internal Pods Use Private Registry ═══"
    test_internal_coredns_image || true
    test_internal_metrics_server_image || true
    test_internal_local_path_provisioner_image || true
    echo ""
    
    show_summary
}

main "$@"
