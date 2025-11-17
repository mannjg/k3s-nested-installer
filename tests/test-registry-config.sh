#!/usr/bin/env bash

###############################################################################
# Registry Configuration Test Suite
#
# Tests the private registry feature to ensure:
# 1. registries.yaml is properly created and mounted
# 2. The file is copied to /tmp/registries.yaml correctly
# 3. Works with and without authentication
# 4. Works with registry path prefixes
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test configuration
TEST_INSTANCE_NAME="test-registry-$$"
TEST_NAMESPACE="k3s-${TEST_INSTANCE_NAME}"
CLEANUP_ON_SUCCESS=true
CLEANUP_ON_FAILURE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results tracking
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

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
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
    error "$test_name: $reason"
}

cleanup_test_instance() {
    local instance="$1"
    log "Cleaning up test instance: $instance"
    "$PROJECT_DIR/manage.sh" delete "$instance" 2>/dev/null || true
    kubectl delete namespace "k3s-$instance" --ignore-not-found=true 2>/dev/null || true
}

###############################################################################
# Test Cases
###############################################################################

test_configmap_generation() {
    log "Test 1: ConfigMap generation with private registry"
    
    local temp_manifest=$(mktemp)
    
    # Generate manifest with private registry (no auth)
    "$PROJECT_DIR/install.sh" \
        --name "$TEST_INSTANCE_NAME" \
        --private-registry docker.local \
        --storage-class standard \
        --dry-run > "$temp_manifest" 2>/dev/null || {
        test_fail "ConfigMap generation" "Failed to generate manifest"
        rm -f "$temp_manifest"
        return 1
    }
    
    # Check if ConfigMap was generated
    if ! grep -q "kind: ConfigMap" "$temp_manifest"; then
        test_fail "ConfigMap generation" "ConfigMap not found in manifest"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check if registries.yaml is in the ConfigMap
    if ! grep -q "registries.yaml:" "$temp_manifest"; then
        test_fail "ConfigMap generation" "registries.yaml not found in ConfigMap"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check if the registry is configured
    if ! grep -q "docker.local" "$temp_manifest"; then
        test_fail "ConfigMap generation" "Private registry not configured"
        rm -f "$temp_manifest"
        return 1
    fi
    
    test_pass "ConfigMap generation with private registry"
    rm -f "$temp_manifest"
    return 0
}

test_file_copy_without_secret() {
    log "Test 2: File copy logic without registry secret (THE BUG FIX TEST)"
    
    local temp_manifest=$(mktemp)
    
    # Generate manifest with private registry but NO secret
    "$PROJECT_DIR/install.sh" \
        --name "$TEST_INSTANCE_NAME" \
        --private-registry docker.local \
        --storage-class standard \
        --dry-run > "$temp_manifest" 2>/dev/null || {
        test_fail "File copy without secret" "Failed to generate manifest"
        rm -f "$temp_manifest"
        return 1
    }
    
    # Check that the copy operation exists
    if ! grep -q "cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml" "$temp_manifest"; then
        test_fail "File copy without secret" "File copy operation not found in manifest"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check that it happens BEFORE k3d cluster create
    local copy_line=$(grep -n "cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml" "$temp_manifest" | cut -d: -f1)
    local create_line=$(grep -n "k3d cluster create" "$temp_manifest" | cut -d: -f1)
    
    if [[ $copy_line -ge $create_line ]]; then
        test_fail "File copy without secret" "File copy happens after k3d create (wrong order)"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check that k3d uses the copied file
    if ! grep -q -- "--registry-config /tmp/registries.yaml" "$temp_manifest"; then
        test_fail "File copy without secret" "k3d not configured to use /tmp/registries.yaml"
        rm -f "$temp_manifest"
        return 1
    fi
    
    test_pass "File copy without secret (BUG FIX VERIFIED)"
    rm -f "$temp_manifest"
    return 0
}

test_file_copy_with_secret() {
    log "Test 3: File copy logic with registry secret"
    
    local temp_manifest=$(mktemp)
    
    # Generate manifest with private registry AND secret
    "$PROJECT_DIR/install.sh" \
        --name "$TEST_INSTANCE_NAME" \
        --private-registry docker.local \
        --registry-secret my-registry-secret \
        --storage-class standard \
        --dry-run > "$temp_manifest" 2>/dev/null || {
        test_fail "File copy with secret" "Failed to generate manifest"
        rm -f "$temp_manifest"
        return 1
    }
    
    # Check that the copy operation exists
    if ! grep -q "cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml" "$temp_manifest"; then
        test_fail "File copy with secret" "File copy operation not found in manifest"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check that credential setup also exists
    if ! grep -q "Setting up Docker registry credentials" "$temp_manifest"; then
        test_fail "File copy with secret" "Credential setup not found"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check that both imagePullSecrets and volume mounts are configured
    if ! grep -q "imagePullSecrets:" "$temp_manifest"; then
        test_fail "File copy with secret" "imagePullSecrets not configured"
        rm -f "$temp_manifest"
        return 1
    fi
    
    test_pass "File copy with secret (credential setup included)"
    rm -f "$temp_manifest"
    return 0
}

test_volume_mounts() {
    log "Test 4: Verify ConfigMap volume mounts"
    
    local temp_manifest=$(mktemp)
    
    "$PROJECT_DIR/install.sh" \
        --name "$TEST_INSTANCE_NAME" \
        --private-registry docker.local \
        --storage-class standard \
        --dry-run > "$temp_manifest" 2>/dev/null || {
        test_fail "Volume mounts" "Failed to generate manifest"
        rm -f "$temp_manifest"
        return 1
    }
    
    # Check that the ConfigMap volume is defined
    if ! grep -q "name: registries-config" "$temp_manifest"; then
        test_fail "Volume mounts" "registries-config volume not defined"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check that it references the ConfigMap
    if ! grep -q "name: k3s-registries" "$temp_manifest"; then
        test_fail "Volume mounts" "ConfigMap reference not found"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check that it's mounted to /etc/rancher/k3s/registries.yaml
    if ! grep -q "mountPath: /etc/rancher/k3s/registries.yaml" "$temp_manifest"; then
        test_fail "Volume mounts" "ConfigMap not mounted to correct path"
        rm -f "$temp_manifest"
        return 1
    fi
    
    test_pass "ConfigMap volume mounts correctly configured"
    rm -f "$temp_manifest"
    return 0
}

test_registry_path_prefix() {
    log "Test 5: Registry path prefix support"
    
    local temp_manifest=$(mktemp)
    
    "$PROJECT_DIR/install.sh" \
        --name "$TEST_INSTANCE_NAME" \
        --private-registry artifactory.company.com \
        --registry-path docker-sandbox/team \
        --storage-class standard \
        --dry-run > "$temp_manifest" 2>/dev/null || {
        test_fail "Registry path prefix" "Failed to generate manifest"
        rm -f "$temp_manifest"
        return 1
    }
    
    # Check that the rewrite rule is present
    if ! grep -q "rewrite:" "$temp_manifest"; then
        test_fail "Registry path prefix" "Rewrite rules not found"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check that the path prefix is in the rewrite rule
    if ! grep -q "docker-sandbox/team" "$temp_manifest"; then
        test_fail "Registry path prefix" "Path prefix not found in rewrite rules"
        rm -f "$temp_manifest"
        return 1
    fi
    
    test_pass "Registry path prefix support verified"
    rm -f "$temp_manifest"
    return 0
}

test_insecure_registry() {
    log "Test 6: Insecure registry configuration"
    
    local temp_manifest=$(mktemp)
    
    "$PROJECT_DIR/install.sh" \
        --name "$TEST_INSTANCE_NAME" \
        --private-registry insecure-registry.local \
        --registry-insecure \
        --storage-class standard \
        --dry-run > "$temp_manifest" 2>/dev/null || {
        test_fail "Insecure registry" "Failed to generate manifest"
        rm -f "$temp_manifest"
        return 1
    }
    
    # Check that insecure_skip_verify is set
    if ! grep -q "insecure_skip_verify: true" "$temp_manifest"; then
        test_fail "Insecure registry" "insecure_skip_verify not set"
        rm -f "$temp_manifest"
        return 1
    fi
    
    # Check that Docker daemon has insecure-registry flag
    if ! grep -q -- "--insecure-registry=" "$temp_manifest"; then
        test_fail "Insecure registry" "Docker insecure-registry flag not set"
        rm -f "$temp_manifest"
        return 1
    fi
    
    test_pass "Insecure registry configuration verified"
    rm -f "$temp_manifest"
    return 0
}

###############################################################################
# Integration Tests (optional - requires actual cluster)
###############################################################################

test_actual_deployment() {
    if [[ "${RUN_INTEGRATION_TESTS:-false}" != "true" ]]; then
        log "Skipping integration test (set RUN_INTEGRATION_TESTS=true to enable)"
        return 0
    fi
    
    log "Test 7: Actual deployment with private registry (no auth)"
    
    # This test requires a working Kubernetes cluster
    if ! kubectl cluster-info &>/dev/null; then
        warn "Integration test skipped - no Kubernetes cluster available"
        return 0
    fi
    
    log "Deploying test instance..."
    "$PROJECT_DIR/install.sh" \
        --name "$TEST_INSTANCE_NAME" \
        --private-registry docker.local \
        --storage-size 1Gi \
        --wait-timeout 300 || {
        test_fail "Actual deployment" "Deployment failed"
        cleanup_test_instance "$TEST_INSTANCE_NAME"
        return 1
    }
    
    # Wait for pod to be ready
    log "Waiting for pod to be ready..."
    if ! kubectl wait --for=condition=ready pod \
        -n "$TEST_NAMESPACE" \
        -l app=k3s \
        --timeout=300s; then
        test_fail "Actual deployment" "Pod failed to become ready"
        kubectl describe pod -n "$TEST_NAMESPACE" -l app=k3s
        kubectl logs -n "$TEST_NAMESPACE" -l app=k3s -c k3d --tail=100
        cleanup_test_instance "$TEST_INSTANCE_NAME"
        return 1
    fi
    
    # Verify /tmp/registries.yaml exists in the pod
    log "Verifying /tmp/registries.yaml exists in pod..."
    local pod_name=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}')
    
    if ! kubectl exec -n "$TEST_NAMESPACE" "$pod_name" -c k3d -- test -f /tmp/registries.yaml; then
        test_fail "Actual deployment" "/tmp/registries.yaml not found in pod"
        cleanup_test_instance "$TEST_INSTANCE_NAME"
        return 1
    fi
    
    # Verify the file has correct content
    log "Verifying registries.yaml content..."
    local content=$(kubectl exec -n "$TEST_NAMESPACE" "$pod_name" -c k3d -- cat /tmp/registries.yaml)
    
    if ! echo "$content" | grep -q "docker.local"; then
        test_fail "Actual deployment" "Registry not found in registries.yaml"
        cleanup_test_instance "$TEST_INSTANCE_NAME"
        return 1
    fi
    
    test_pass "Actual deployment with private registry (no auth)"
    
    if [[ "$CLEANUP_ON_SUCCESS" == "true" ]]; then
        cleanup_test_instance "$TEST_INSTANCE_NAME"
    fi
    
    return 0
}

###############################################################################
# Test Execution
###############################################################################

show_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Test Results Summary"
    echo "═══════════════════════════════════════════════════════════"
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
    fi
    
    echo ""
    
    if [[ $FAILED_TESTS -eq 0 ]]; then
        success "All tests passed! ✓"
        return 0
    else
        error "Some tests failed! ✗"
        return 1
    fi
}

main() {
    log "Starting Registry Configuration Test Suite"
    log "Project: k3s-nested-installer"
    log "Test Focus: Private registry feature validation"
    echo ""
    
    # Run all tests
    test_configmap_generation
    test_file_copy_without_secret
    test_file_copy_with_secret
    test_volume_mounts
    test_registry_path_prefix
    test_insecure_registry
    test_actual_deployment
    
    # Show results
    show_summary
}

main "$@"
