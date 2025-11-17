#!/usr/bin/env bash
#############################################################################
# Comprehensive Airgap Installation End-to-End Test
#
# Tests the complete workflow:
# 1. List required images
# 2. Mirror images to Nexus
# 3. Install k3s cluster with private registry
# 4. Validate all success criteria
# 5. Test manage.sh operations
# 6. Clean up (delete instance)
#
# This script runs fully automated from clean state to clean state.
#############################################################################

set -euo pipefail

# Configuration
INSTANCE_NAME="airgap-e2e-test"
NAMESPACE="k3s-${INSTANCE_NAME}"
PRIVATE_REGISTRY="docker.local"
REGISTRY_SECRET="nexus-docker-secret"
STORAGE_CLASS="microk8s-hostpath"
STORAGE_SIZE="2Gi"
NODEPORT="30447"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[TEST]${NC} $*"; }
success() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

PASS_COUNT=0
FAIL_COUNT=0

pass_test() {
    success "$1"
    ((PASS_COUNT++))
    return 0
}

fail_test() {
    fail "$1"
    ((FAIL_COUNT++))
    return 1
}

#############################################################################
# Phase 0: Clean State
#############################################################################

phase_clean_state() {
    log "═══ PHASE 0: Ensuring Clean State ═══"

    # Delete namespace if it exists
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        warn "Namespace $NAMESPACE exists, deleting..."
        kubectl delete namespace "$NAMESPACE" --wait=true --timeout=120s || true
        sleep 5
    fi

    # Remove kubeconfig if it exists
    local kubeconfig="${PROJECT_DIR}/kubeconfigs/k3s-${INSTANCE_NAME}.yaml"
    if [[ -f "$kubeconfig" ]]; then
        rm -f "$kubeconfig"
    fi

    success "Clean state verified"
}

#############################################################################
# Phase 1: List Required Images
#############################################################################

phase_list_images() {
    log "═══ PHASE 1: Listing Required Images ═══"

    cd "$PROJECT_DIR"

    if ! ./list-required-images.sh --registry "$PRIVATE_REGISTRY" --output /tmp/airgap-e2e-images.txt; then
        fail_test "Failed to list required images"
        return 1
    fi

    if [[ ! -f /tmp/airgap-e2e-images.txt ]]; then
        fail_test "Image list file not created"
        return 1
    fi

    local image_count=$(grep -v "^$" /tmp/airgap-e2e-images.txt | wc -l)
    pass_test "Listed $image_count required images"
}

#############################################################################
# Phase 2: Mirror Images to Nexus
#############################################################################

phase_mirror_images() {
    log "═══ PHASE 2: Mirroring Images to Nexus ═══"

    cd "$PROJECT_DIR"

    if ! ./mirror-images-to-nexus.sh \
        --registry "$PRIVATE_REGISTRY" \
        --input /tmp/airgap-e2e-images.txt \
        --username admin \
        --password admin123 \
        --insecure; then
        fail_test "Failed to mirror images"
        return 1
    fi

    pass_test "Images mirrored to Nexus"
}

#############################################################################
# Phase 3: Install K3s Cluster
#############################################################################

phase_install_cluster() {
    log "═══ PHASE 3: Installing K3s Cluster ═══"

    cd "$PROJECT_DIR"

    # Create registry secret first
    kubectl create namespace "$NAMESPACE" || true
    kubectl create secret docker-registry "$REGISTRY_SECRET" \
        --docker-server="$PRIVATE_REGISTRY" \
        --docker-username=admin \
        --docker-password=admin123 \
        --namespace="$NAMESPACE" || true

    # Install cluster
    if ! ./install.sh \
        --name "$INSTANCE_NAME" \
        --private-registry "$PRIVATE_REGISTRY" \
        --registry-secret "$REGISTRY_SECRET" \
        --registry-insecure \
        --storage-class "$STORAGE_CLASS" \
        --storage-size "$STORAGE_SIZE" \
        --nodeport "$NODEPORT" \
        --wait-timeout 600; then
        fail_test "Failed to install k3s cluster"
        return 1
    fi

    pass_test "K3s cluster installed"
}

#############################################################################
# Phase 4: Validation - Criterion 1 (Pod Running)
#############################################################################

validate_criterion_1() {
    log "═══ CRITERION 1: K3s Pod Running (2/2 Ready) ═══"

    # Wait for pod to be ready
    if ! kubectl wait --for=condition=ready pod -l app=k3s -n "$NAMESPACE" --timeout=300s &>/dev/null; then
        fail_test "Pod did not become ready within timeout"
        return 1
    fi

    local ready=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].status.containerStatuses[*].ready}')
    local status=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].status.phase}')

    if [[ "$status" == "Running" ]] && [[ "$ready" == "true true" ]]; then
        pass_test "Pod is Running (2/2 containers Ready)"
    else
        fail_test "Pod status: $status, ready: $ready"
        return 1
    fi
}

#############################################################################
# Phase 5: Validation - Criterion 2 (Infrastructure Images)
#############################################################################

validate_criterion_2() {
    log "═══ CRITERION 2: Infrastructure Images from Private Registry ═══"

    local dind_image=$(kubectl get pod -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].spec.containers[?(@.name=="dind")].image}')
    local k3d_image=$(kubectl get pod -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].spec.containers[?(@.name=="k3d")].image}')

    if [[ "$dind_image" =~ ^${PRIVATE_REGISTRY}/ ]] && [[ "$k3d_image" =~ ^${PRIVATE_REGISTRY}/ ]]; then
        pass_test "DinD: $dind_image"
        pass_test "K3d: $k3d_image"
    else
        fail_test "Images not from private registry: dind=$dind_image, k3d=$k3d_image"
        return 1
    fi
}

#############################################################################
# Phase 6: Validation - Criterion 3 (Internal Cluster)
#############################################################################

validate_criterion_3() {
    log "═══ CRITERION 3: Internal K3s Cluster Operational ═══"

    # Get pod name
    local pod_name=$(kubectl get pod -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')

    # Check internal nodes
    local nodes=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- \
        kubectl --kubeconfig=/output/kubeconfig.yaml get nodes --no-headers 2>/dev/null | wc -l)

    if [[ "$nodes" -ge 1 ]]; then
        pass_test "Internal k3s cluster has $nodes node(s)"
    else
        fail_test "No nodes found in internal cluster"
        return 1
    fi

    # Check internal pods
    local pod_count=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c k3d -- \
        kubectl --kubeconfig=/output/kubeconfig.yaml get pods -A --no-headers 2>/dev/null | wc -l)

    if [[ "$pod_count" -ge 3 ]]; then
        pass_test "Internal cluster has $pod_count system pods running"
    else
        fail_test "Expected at least 3 system pods, found $pod_count"
        return 1
    fi
}

#############################################################################
# Phase 7: Validation - Criterion 4 (Registry Mirrors)
#############################################################################

validate_criterion_4() {
    log "═══ CRITERION 4: Registry Mirror Configuration ═══"

    # Check ConfigMap exists
    if ! kubectl get configmap k3s-registries -n "$NAMESPACE" &>/dev/null; then
        fail_test "Registry ConfigMap not found"
        return 1
    fi

    # Verify mirror configuration
    local config=$(kubectl get configmap k3s-registries -n "$NAMESPACE" -o jsonpath='{.data.registries\.yaml}')

    if echo "$config" | grep -q "docker.local"; then
        pass_test "Registry mirror configured for docker.local"
    else
        fail_test "Registry mirror not properly configured"
        return 1
    fi

    # Verify images exist in Nexus
    if curl -s -k "https://${PRIVATE_REGISTRY}/v2/rancher/mirrored-coredns-coredns/tags/list" | grep -q "1.12.0"; then
        pass_test "CoreDNS image available in Nexus"
    else
        fail_test "CoreDNS image not found in Nexus"
        return 1
    fi
}

#############################################################################
# Phase 8: Validation - Criterion 5 (manage.sh Operations)
#############################################################################

validate_criterion_5() {
    log "═══ CRITERION 5: manage.sh Operations ═══"

    cd "$PROJECT_DIR"

    # Test list
    local list_output=$(./manage.sh list 2>&1)
    if echo "$list_output" | grep -q "$INSTANCE_NAME"; then
        pass_test "manage.sh list works"
    else
        fail_test "manage.sh list failed"
        return 1
    fi

    # Test status
    local status_output=$(./manage.sh status "$INSTANCE_NAME" 2>&1)
    if echo "$status_output" | grep -q "Pod Status"; then
        pass_test "manage.sh status works"
    else
        fail_test "manage.sh status failed"
        return 1
    fi

    # Test refresh-kubeconfig
    local refresh_output=$(./manage.sh refresh-kubeconfig "$INSTANCE_NAME" 2>&1)
    if echo "$refresh_output" | grep -q "SUCCESS"; then
        pass_test "manage.sh refresh-kubeconfig works"
    else
        fail_test "manage.sh refresh-kubeconfig failed"
        return 1
    fi

    # Test access
    local access_output=$(./manage.sh access "$INSTANCE_NAME" 2>&1)
    if echo "$access_output" | grep -q "control plane"; then
        pass_test "manage.sh access works"
    else
        fail_test "manage.sh access failed"
        return 1
    fi

    # Test exec
    local exec_output=$(./manage.sh exec "$INSTANCE_NAME" -- get nodes 2>&1)
    if echo "$exec_output" | grep -q "k3d"; then
        pass_test "manage.sh exec works"
    else
        fail_test "manage.sh exec failed"
        return 1
    fi

    # Test logs
    local logs_output=$(./manage.sh logs "$INSTANCE_NAME" k3d 2>&1 | head -5)
    if echo "$logs_output" | grep -qE "Waiting|Docker|K3s"; then
        pass_test "manage.sh logs works"
    else
        fail_test "manage.sh logs failed"
        return 1
    fi

    # Test resources
    local resources_output=$(./manage.sh resources 2>&1)
    if echo "$resources_output" | grep -q "$INSTANCE_NAME"; then
        pass_test "manage.sh resources works"
    else
        fail_test "manage.sh resources failed"
        return 1
    fi
}

#############################################################################
# Phase 9: Cleanup
#############################################################################

phase_cleanup() {
    log "═══ PHASE 9: Cleanup (Delete Instance) ═══"

    # Delete namespace
    if kubectl delete namespace "$NAMESPACE" --wait=true --timeout=120s; then
        pass_test "Namespace deleted successfully"
    else
        fail_test "Failed to delete namespace"
        return 1
    fi

    # Remove kubeconfig
    local kubeconfig="${PROJECT_DIR}/kubeconfigs/k3s-${INSTANCE_NAME}.yaml"
    if [[ -f "$kubeconfig" ]]; then
        rm -f "$kubeconfig"
    fi

    # Verify namespace is gone
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        fail_test "Namespace still exists after deletion"
        return 1
    fi

    pass_test "Clean state restored"
}

#############################################################################
# Main Execution
#############################################################################

main() {
    log "════════════════════════════════════════════════════════════"
    log "  Comprehensive Airgap Installation End-to-End Test"
    log "════════════════════════════════════════════════════════════"
    log "Instance: $INSTANCE_NAME"
    log "Registry: $PRIVATE_REGISTRY"
    log ""

    # Execute all phases
    phase_clean_state || exit 1
    phase_list_images || exit 1
    phase_mirror_images || exit 1
    phase_install_cluster || exit 1

    sleep 10  # Give cluster time to stabilize

    validate_criterion_1 || exit 1
    validate_criterion_2 || exit 1
    validate_criterion_3 || exit 1
    validate_criterion_4 || exit 1
    validate_criterion_5 || exit 1

    phase_cleanup || exit 1

    # Final summary
    echo ""
    log "════════════════════════════════════════════════════════════"
    log "  Test Results Summary"
    log "════════════════════════════════════════════════════════════"
    log "Total Passed: $PASS_COUNT"
    log "Total Failed: $FAIL_COUNT"
    log ""

    if [[ $FAIL_COUNT -eq 0 ]]; then
        success "════════════════════════════════════════════════════════════"
        success "  ALL TESTS PASSED! ✓"
        success "  End-to-end airgap installation verified successfully"
        success "════════════════════════════════════════════════════════════"
        exit 0
    else
        fail "════════════════════════════════════════════════════════════"
        fail "  TESTS FAILED"
        fail "════════════════════════════════════════════════════════════"
        exit 1
    fi
}

# Run main function
main "$@"
