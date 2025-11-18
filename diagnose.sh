#!/bin/bash
#
# K3s Nested Installer - Diagnostic Tool
# Inspects all layers: Host -> DinD -> k3d -> k3s
# Identifies issues without making changes
#

set -o pipefail

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Counters for summary
ERRORS=0
WARNINGS=0
CHECKS_PASSED=0

# Usage
usage() {
    echo "Usage: $0 <instance-name>"
    echo ""
    echo "Diagnoses a k3s nested installation across all layers."
    echo ""
    echo "Example:"
    echo "  $0 demo"
    echo "  $0 test"
    exit 1
}

# Logging functions
header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}${BOLD}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

subheader() {
    echo ""
    echo -e "${CYAN}┌─ $1${NC}"
}

check_pass() {
    echo -e "${GREEN}  ✓ $1${NC}"
    ((CHECKS_PASSED++))
}

check_fail() {
    echo -e "${RED}  ✗ $1${NC}"
    ((ERRORS++))
}

check_warn() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
    ((WARNINGS++))
}

check_info() {
    echo -e "${WHITE}  ℹ $1${NC}"
}

check_detail() {
    echo -e "${WHITE}    └─ $1${NC}"
}

# Get instance name
INSTANCE_NAME="${1:-}"
if [[ -z "$INSTANCE_NAME" ]]; then
    usage
fi

NAMESPACE="k3s-${INSTANCE_NAME}"

header "K3s Nested Installer Diagnostics"
echo -e "${WHITE}  Instance: ${CYAN}${INSTANCE_NAME}${NC}"
echo -e "${WHITE}  Namespace: ${CYAN}${NAMESPACE}${NC}"
echo -e "${WHITE}  Time: ${CYAN}$(date)${NC}"

# ============================================================================
# LAYER 1: Host/Outer Kubernetes
# ============================================================================
header "LAYER 1: Host Kubernetes"

subheader "Namespace Status"
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    check_pass "Namespace '$NAMESPACE' exists"
    NS_STATUS=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [[ "$NS_STATUS" == "Active" ]]; then
        check_pass "Namespace is Active"
    else
        check_fail "Namespace status: $NS_STATUS"
    fi
else
    check_fail "Namespace '$NAMESPACE' does not exist"
    echo -e "${RED}Cannot continue diagnostics without namespace${NC}"
    exit 1
fi

subheader "Pod Status"
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$POD_NAME" ]]; then
    check_fail "No k3s pod found in namespace"
else
    check_pass "Pod found: $POD_NAME"

    # Get pod phase
    POD_PHASE=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath='{.status.phase}')
    if [[ "$POD_PHASE" == "Running" ]]; then
        check_pass "Pod phase: Running"
    else
        check_fail "Pod phase: $POD_PHASE"
    fi

    # Check each container
    CONTAINERS=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath='{.spec.containers[*].name}')
    for container in $CONTAINERS; do
        READY=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].ready}")
        RESTART_COUNT=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].restartCount}")
        STATE=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].state}" | grep -o '"[^"]*":' | head -1 | tr -d '":')

        if [[ "$READY" == "true" ]]; then
            check_pass "Container '$container': Ready (restarts: $RESTART_COUNT)"
        else
            check_fail "Container '$container': Not ready (state: $STATE, restarts: $RESTART_COUNT)"

            # Get more details on why it's not ready
            WAITING_REASON=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].state.waiting.reason}" 2>/dev/null)
            if [[ -n "$WAITING_REASON" ]]; then
                check_detail "Waiting reason: $WAITING_REASON"

                # Special handling for common issues
                case "$WAITING_REASON" in
                    "ImagePullBackOff"|"ErrImagePull")
                        check_detail "Image pull failed - check registry connectivity and credentials"
                        IMAGE=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath="{.spec.containers[?(@.name=='$container')].image}")
                        check_detail "Image: $IMAGE"
                        ;;
                    "CrashLoopBackOff")
                        check_detail "Container is crash looping - check container logs"
                        ;;
                esac
            fi

            TERMINATED_REASON=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].state.terminated.reason}" 2>/dev/null)
            if [[ -n "$TERMINATED_REASON" ]]; then
                check_detail "Terminated reason: $TERMINATED_REASON"
                EXIT_CODE=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].state.terminated.exitCode}" 2>/dev/null)
                check_detail "Exit code: $EXIT_CODE"
            fi
        fi

        if [[ "$RESTART_COUNT" -gt 5 ]]; then
            check_warn "High restart count ($RESTART_COUNT) for container '$container'"
        fi
    done
fi

subheader "PVC Status"
PVC_NAME=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$PVC_NAME" ]]; then
    check_warn "No PVC found in namespace"
else
    PVC_STATUS=$(kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" -o jsonpath='{.status.phase}')
    PVC_SIZE=$(kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" -o jsonpath='{.spec.resources.requests.storage}')
    if [[ "$PVC_STATUS" == "Bound" ]]; then
        check_pass "PVC '$PVC_NAME' is Bound ($PVC_SIZE)"
    else
        check_fail "PVC '$PVC_NAME' status: $PVC_STATUS"
        check_detail "Check storage class and provisioner"
    fi
fi

subheader "Service Status"
SVC_NAME=$(kubectl get svc -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$SVC_NAME" ]]; then
    check_warn "No service found for k3s"
else
    SVC_TYPE=$(kubectl get svc -n "$NAMESPACE" "$SVC_NAME" -o jsonpath='{.spec.type}')
    if [[ "$SVC_TYPE" == "NodePort" ]]; then
        NODEPORT=$(kubectl get svc -n "$NAMESPACE" "$SVC_NAME" -o jsonpath='{.spec.ports[0].nodePort}')
        check_pass "Service '$SVC_NAME' (NodePort: $NODEPORT)"
    else
        check_pass "Service '$SVC_NAME' ($SVC_TYPE)"
    fi
fi

subheader "Recent Events (Warnings/Errors)"
EVENTS=$(kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' --field-selector type!=Normal -o custom-columns=TIME:.lastTimestamp,TYPE:.type,REASON:.reason,MESSAGE:.message --no-headers 2>/dev/null | tail -10)
if [[ -n "$EVENTS" ]]; then
    check_warn "Found warning/error events:"
    echo "$EVENTS" | while read -r line; do
        check_detail "$line"
    done
else
    check_pass "No warning/error events in namespace"
fi

# ============================================================================
# LAYER 2: DinD Container
# ============================================================================
header "LAYER 2: Docker-in-Docker Container"

if [[ -z "$POD_NAME" ]]; then
    check_fail "Cannot inspect DinD - no pod found"
else
    subheader "Docker Daemon Status"
    DOCKER_INFO=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- docker info 2>&1)
    if echo "$DOCKER_INFO" | grep -q "Server Version"; then
        DOCKER_VERSION=$(echo "$DOCKER_INFO" | grep "Server Version" | awk '{print $3}')
        check_pass "Docker daemon running (version: $DOCKER_VERSION)"

        # Check storage driver
        STORAGE_DRIVER=$(echo "$DOCKER_INFO" | grep "Storage Driver" | awk '{print $3}')
        check_info "Storage driver: $STORAGE_DRIVER"

        # Check available storage
        if echo "$DOCKER_INFO" | grep -q "Data Space Available"; then
            DATA_SPACE=$(echo "$DOCKER_INFO" | grep "Data Space Available" | awk '{print $4, $5}')
            check_info "Data space available: $DATA_SPACE"
        fi
    else
        check_fail "Docker daemon not responding"
        check_detail "Error: $(echo "$DOCKER_INFO" | head -3)"
    fi

    subheader "Docker Images in DinD"
    IMAGES=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -v '<none>')
    if [[ -n "$IMAGES" ]]; then
        IMAGE_COUNT=$(echo "$IMAGES" | wc -l)
        check_pass "Found $IMAGE_COUNT images in DinD"

        # Check for key images
        if echo "$IMAGES" | grep -q "rancher/k3s"; then
            K3S_IMAGE=$(echo "$IMAGES" | grep "rancher/k3s" | head -1)
            check_pass "k3s image present: $K3S_IMAGE"
        else
            check_fail "k3s image not found in DinD"
        fi

        if echo "$IMAGES" | grep -q "k3d-tools"; then
            check_pass "k3d-tools image present"
        else
            check_warn "k3d-tools image not found"
        fi

        # Check image sources
        PRIVATE_IMAGES=$(echo "$IMAGES" | grep -v "^docker.io" | grep -v "^ghcr.io" | grep -v "^rancher/" | grep -v "^registry.k8s.io" || true)
        PUBLIC_IMAGES=$(echo "$IMAGES" | grep -E "^docker.io|^ghcr.io|^registry.k8s.io" || true)

        if [[ -n "$PUBLIC_IMAGES" ]]; then
            check_warn "Some images from public registries (may fail in airgap):"
            echo "$PUBLIC_IMAGES" | head -5 | while read -r img; do
                check_detail "$img"
            done
        fi
    else
        check_fail "No images found in DinD"
    fi

    subheader "Docker Network"
    NETWORKS=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- docker network ls --format "{{.Name}}" 2>/dev/null)
    if echo "$NETWORKS" | grep -q "k3d-${INSTANCE_NAME}"; then
        check_pass "k3d network exists: k3d-${INSTANCE_NAME}"
    else
        check_warn "k3d network not found (may not be created yet)"
    fi

    subheader "Registry Configuration"
    if kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- cat /etc/rancher/k3s/registries.yaml &>/dev/null; then
        check_pass "registries.yaml present in container"

        # Parse registry config
        MIRRORS=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- cat /etc/rancher/k3s/registries.yaml 2>/dev/null | grep -A1 "mirrors:" | tail -1 | tr -d ' "' | cut -d: -f1)
        if [[ -n "$MIRRORS" ]]; then
            check_info "Configured mirrors: $MIRRORS"
        fi

        # Check for TLS skip
        if kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- cat /etc/rancher/k3s/registries.yaml 2>/dev/null | grep -q "skip_verify"; then
            check_info "TLS verification: disabled (insecure registry)"
        fi
    else
        check_warn "registries.yaml not found"
    fi
fi

# ============================================================================
# LAYER 3: k3d Cluster
# ============================================================================
header "LAYER 3: k3d Cluster"

if [[ -z "$POD_NAME" ]]; then
    check_fail "Cannot inspect k3d - no pod found"
else
    subheader "k3d Cluster Status"
    K3D_LIST=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- /usr/local/bin/k3d cluster list 2>&1)
    if echo "$K3D_LIST" | grep -q "$INSTANCE_NAME"; then
        SERVERS=$(echo "$K3D_LIST" | grep "$INSTANCE_NAME" | awk '{print $2}')
        AGENTS=$(echo "$K3D_LIST" | grep "$INSTANCE_NAME" | awk '{print $3}')
        check_pass "k3d cluster '$INSTANCE_NAME' exists (servers: $SERVERS, agents: $AGENTS)"
    else
        check_fail "k3d cluster '$INSTANCE_NAME' not found"
        check_detail "k3d output: $K3D_LIST"
    fi

    subheader "k3d Node Status"
    K3D_NODES=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- /usr/local/bin/k3d node list 2>&1)
    if [[ -n "$K3D_NODES" ]]; then
        RUNNING_NODES=$(echo "$K3D_NODES" | grep -c "running" || true)
        TOTAL_NODES=$(echo "$K3D_NODES" | grep -c "k3d-${INSTANCE_NAME}" || true)

        if [[ "$RUNNING_NODES" -eq "$TOTAL_NODES" ]] && [[ "$TOTAL_NODES" -gt 0 ]]; then
            check_pass "All k3d nodes running ($RUNNING_NODES/$TOTAL_NODES)"
        else
            check_fail "Some k3d nodes not running ($RUNNING_NODES/$TOTAL_NODES)"
            echo "$K3D_NODES" | grep "k3d-${INSTANCE_NAME}" | while read -r line; do
                check_detail "$line"
            done
        fi
    fi

    subheader "Kubeconfig Availability"
    if kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- test -f /output/kubeconfig.yaml; then
        check_pass "Kubeconfig file exists at /output/kubeconfig.yaml"
    else
        check_fail "Kubeconfig not found at /output/kubeconfig.yaml"
    fi
fi

# ============================================================================
# LAYER 4: Interior k3s Cluster
# ============================================================================
header "LAYER 4: Interior k3s Cluster"

if [[ -z "$POD_NAME" ]]; then
    check_fail "Cannot inspect k3s - no pod found"
else
    # Get kubeconfig path
    KUBECONFIG_PATH="kubeconfigs/k3s-${INSTANCE_NAME}.yaml"

    subheader "API Server Connectivity"
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        check_pass "Kubeconfig available locally: $KUBECONFIG_PATH"

        # Test API server
        if KUBECONFIG="$KUBECONFIG_PATH" kubectl cluster-info &>/dev/null; then
            check_pass "API server is accessible"

            # Get cluster info
            K8S_VERSION=$(KUBECONFIG="$KUBECONFIG_PATH" kubectl version --short 2>/dev/null | grep "Server" | awk '{print $3}')
            check_info "Kubernetes version: $K8S_VERSION"
        else
            check_fail "Cannot connect to API server"
            check_detail "Try: KUBECONFIG=$KUBECONFIG_PATH kubectl cluster-info"
        fi
    else
        check_warn "Local kubeconfig not found: $KUBECONFIG_PATH"
        check_detail "Run './manage.sh kubeconfig $INSTANCE_NAME' to extract it"
    fi

    subheader "Interior Node Status"
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        NODES=$(KUBECONFIG="$KUBECONFIG_PATH" kubectl get nodes --no-headers 2>/dev/null)
        if [[ -n "$NODES" ]]; then
            TOTAL_NODES=$(echo "$NODES" | wc -l)
            READY_NODES=$(echo "$NODES" | awk '$2=="Ready" {count++} END {print count+0}')

            if [[ "$READY_NODES" -eq "$TOTAL_NODES" ]] && [[ "$TOTAL_NODES" -gt 0 ]]; then
                check_pass "All interior nodes ready ($READY_NODES/$TOTAL_NODES)"
            else
                check_fail "Some interior nodes not ready ($READY_NODES/$TOTAL_NODES)"
            fi

            # Show node details
            echo "$NODES" | while read -r line; do
                NODE_NAME=$(echo "$line" | awk '{print $1}')
                NODE_STATUS=$(echo "$line" | awk '{print $2}')
                if [[ "$NODE_STATUS" == "Ready" ]]; then
                    check_detail "$NODE_NAME: $NODE_STATUS"
                else
                    check_detail "$NODE_NAME: $NODE_STATUS (PROBLEM)"
                fi
            done
        else
            check_fail "Cannot get interior nodes"
        fi
    fi

    subheader "Interior System Pods"
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        SYSTEM_PODS=$(KUBECONFIG="$KUBECONFIG_PATH" kubectl get pods -n kube-system --no-headers 2>/dev/null)
        if [[ -n "$SYSTEM_PODS" ]]; then
            RUNNING_PODS=$(echo "$SYSTEM_PODS" | grep -c "Running" || true)
            TOTAL_PODS=$(echo "$SYSTEM_PODS" | wc -l)

            if [[ "$RUNNING_PODS" -eq "$TOTAL_PODS" ]]; then
                check_pass "All system pods running ($RUNNING_PODS/$TOTAL_PODS)"
            else
                check_warn "Some system pods not running ($RUNNING_PODS/$TOTAL_PODS)"

                # Show non-running pods
                echo "$SYSTEM_PODS" | grep -v "Running" | while read -r line; do
                    POD=$(echo "$line" | awk '{print $1}')
                    STATUS=$(echo "$line" | awk '{print $3}')
                    check_detail "$POD: $STATUS"
                done
            fi

            # Check specific components
            if echo "$SYSTEM_PODS" | grep -q "coredns.*Running"; then
                check_pass "CoreDNS is running"
            else
                check_fail "CoreDNS is not running (DNS will fail)"
            fi

            if echo "$SYSTEM_PODS" | grep -q "traefik.*Running"; then
                check_pass "Traefik ingress is running"
            elif echo "$SYSTEM_PODS" | grep -q "traefik"; then
                check_warn "Traefik is present but not running"
            fi

            if echo "$SYSTEM_PODS" | grep -q "metrics-server.*Running"; then
                check_pass "Metrics server is running"
            fi

            if echo "$SYSTEM_PODS" | grep -q "local-path-provisioner.*Running"; then
                check_pass "Local path provisioner is running"
            fi
        else
            check_fail "Cannot get system pods"
        fi
    fi

    subheader "Interior Images (from private registry)"
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        # Get images used by system pods
        INTERIOR_IMAGES=$(KUBECONFIG="$KUBECONFIG_PATH" kubectl get pods -n kube-system -o jsonpath='{.items[*].spec.containers[*].image}' 2>/dev/null | tr ' ' '\n' | sort -u)

        if [[ -n "$INTERIOR_IMAGES" ]]; then
            # Analyze image sources
            PRIVATE_COUNT=0
            PUBLIC_COUNT=0

            while read -r img; do
                if [[ -n "$img" ]]; then
                    if echo "$img" | grep -qE "^docker\.io|^ghcr\.io|^registry\.k8s\.io|^quay\.io"; then
                        ((PUBLIC_COUNT++))
                    else
                        ((PRIVATE_COUNT++))
                    fi
                fi
            done <<< "$INTERIOR_IMAGES"

            if [[ "$PUBLIC_COUNT" -gt 0 ]]; then
                check_warn "Found $PUBLIC_COUNT images from public registries"
                check_detail "This may cause issues in airgap environments"

                echo "$INTERIOR_IMAGES" | grep -E "^docker\.io|^ghcr\.io|^registry\.k8s\.io|^quay\.io" | head -5 | while read -r img; do
                    check_detail "Public: $img"
                done
            else
                check_pass "All system images from private registry"
            fi
        fi
    fi
fi

# ============================================================================
# LAYER 5: Network Connectivity
# ============================================================================
header "LAYER 5: Network & Registry Connectivity"

if [[ -z "$POD_NAME" ]]; then
    check_fail "Cannot test connectivity - no pod found"
else
    subheader "Registry Connectivity from DinD"

    # Get registry from config - try different sources
    # First try the PRIVATE_REGISTRY key (older format)
    REGISTRY=$(kubectl get configmap -n "$NAMESPACE" -l app=k3s -o jsonpath='{.items[0].data.PRIVATE_REGISTRY}' 2>/dev/null)

    # If not found, extract from registries.yaml (newer format)
    if [[ -z "$REGISTRY" ]]; then
        # Extract the first endpoint from registries.yaml configs section
        REGISTRIES_YAML=$(kubectl get configmap -n "$NAMESPACE" k3s-registries -o jsonpath='{.data.registries\.yaml}' 2>/dev/null)
        if [[ -n "$REGISTRIES_YAML" ]]; then
            # Try to get from configs section (contains the actual registry hostname)
            REGISTRY=$(echo "$REGISTRIES_YAML" | grep -A1 "^configs:" | grep -oP '^\s+"\K[^"]+' | head -1)
            # If that fails, try to get from endpoint in mirrors
            if [[ -z "$REGISTRY" ]]; then
                REGISTRY=$(echo "$REGISTRIES_YAML" | grep -oP 'endpoint:\s*\n\s+-\s+"https?://\K[^"]+' | head -1)
            fi
        fi
    fi

    if [[ -n "$REGISTRY" ]]; then
        check_info "Configured registry: $REGISTRY"

        # Test registry connectivity
        REGISTRY_HOST=$(echo "$REGISTRY" | cut -d: -f1)
        REGISTRY_PORT=$(echo "$REGISTRY" | cut -d: -f2)
        [[ -z "$REGISTRY_PORT" || "$REGISTRY_PORT" == "$REGISTRY_HOST" ]] && REGISTRY_PORT="80"

        # Test TCP connectivity
        if kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- timeout 5 bash -c "echo > /dev/tcp/$REGISTRY_HOST/$REGISTRY_PORT" 2>/dev/null; then
            check_pass "TCP connection to $REGISTRY successful"
        else
            check_fail "Cannot connect to registry at $REGISTRY"
            check_detail "Check network policies, DNS, and firewall rules"
        fi

        # Test HTTP(S) connectivity - try HTTPS first (handles redirects)
        CURL_RESULT=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- curl -s -o /dev/null -w "%{http_code}" -k "https://$REGISTRY/v2/" 2>/dev/null || true)

        # If HTTPS connection failed completely, try HTTP
        if [[ "$CURL_RESULT" == "000" || -z "$CURL_RESULT" ]]; then
            CURL_RESULT=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- curl -s -o /dev/null -w "%{http_code}" "http://$REGISTRY/v2/" 2>/dev/null || true)
        fi

        if [[ "$CURL_RESULT" == "200" ]]; then
            check_pass "Registry API responding (status: $CURL_RESULT) - no auth required"
        elif [[ "$CURL_RESULT" == "401" ]]; then
            check_warn "Registry API responding but requires authentication (status: $CURL_RESULT)"

            # Check if registry secret exists in namespace
            subheader "Registry Authentication Validation"

            # Look for docker-registry secrets in the namespace
            REGISTRY_SECRETS=$(kubectl get secrets -n "$NAMESPACE" -o jsonpath='{range .items[?(@.type=="kubernetes.io/dockerconfigjson")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

            if [[ -z "$REGISTRY_SECRETS" ]]; then
                check_fail "No docker-registry secrets found in namespace $NAMESPACE"
                check_detail "Registry requires authentication but no credentials are available"
                check_detail "Create a secret with: kubectl create secret docker-registry <name> --docker-server=$REGISTRY --docker-username=<user> --docker-password=<pass> -n $NAMESPACE"
            else
                check_pass "Found docker-registry secret(s): $(echo $REGISTRY_SECRETS | tr '\n' ' ')"

                # Try to test authentication with each secret
                AUTH_SUCCESS=false
                for SECRET_NAME in $REGISTRY_SECRETS; do
                    # Extract credentials from secret
                    DOCKER_CONFIG=$(kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null)

                    if [[ -n "$DOCKER_CONFIG" ]]; then
                        # Extract auth for this registry (try various registry name formats)
                        AUTH_STRING=""
                        for REG_KEY in "$REGISTRY" "https://$REGISTRY" "http://$REGISTRY" "${REGISTRY_HOST}"; do
                            AUTH_STRING=$(echo "$DOCKER_CONFIG" | jq -r ".auths[\"$REG_KEY\"].auth // empty" 2>/dev/null)
                            [[ -n "$AUTH_STRING" ]] && break
                        done

                        if [[ -n "$AUTH_STRING" ]]; then
                            check_pass "Secret '$SECRET_NAME' contains credentials for registry"

                            # Test actual authentication
                            AUTH_TEST=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- curl -s -o /dev/null -w "%{http_code}" -k -H "Authorization: Basic $AUTH_STRING" "https://$REGISTRY/v2/" 2>/dev/null || true)

                            # If HTTPS failed, try HTTP
                            if [[ "$AUTH_TEST" == "000" || -z "$AUTH_TEST" ]]; then
                                AUTH_TEST=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Basic $AUTH_STRING" "http://$REGISTRY/v2/" 2>/dev/null || true)
                            fi

                            if [[ "$AUTH_TEST" == "200" ]]; then
                                check_pass "Authentication successful with secret '$SECRET_NAME'"
                                AUTH_SUCCESS=true
                                break
                            elif [[ "$AUTH_TEST" == "401" ]]; then
                                check_fail "Authentication failed with secret '$SECRET_NAME' (invalid credentials)"
                            else
                                check_warn "Could not verify authentication (status: $AUTH_TEST)"
                            fi
                        else
                            check_warn "Secret '$SECRET_NAME' does not contain credentials for registry '$REGISTRY'"
                        fi
                    else
                        check_warn "Could not extract docker config from secret '$SECRET_NAME'"
                    fi
                done

                if [[ "$AUTH_SUCCESS" != "true" ]]; then
                    check_fail "No valid registry credentials found"
                    check_detail "Ensure a docker-registry secret with valid credentials exists for $REGISTRY"
                fi
            fi
        elif [[ -n "$CURL_RESULT" ]]; then
            check_warn "Registry API returned status: $CURL_RESULT"
        else
            check_warn "Could not test registry API connectivity"
        fi
    else
        check_info "No private registry configured (using defaults)"
    fi

    subheader "DNS Resolution"
    # Test DNS from DinD
    if kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
        check_pass "DNS resolution working in DinD"
    else
        check_warn "DNS resolution may have issues in DinD"
    fi
fi

# ============================================================================
# COMMON ISSUES DETECTION
# ============================================================================
header "Common Issues Analysis"

subheader "Automated Problem Detection"

# Check for image pull issues
if kubectl get events -n "$NAMESPACE" --field-selector reason=Failed 2>/dev/null | grep -qi "pull"; then
    check_fail "DETECTED: Image pull failures"
    check_detail "Check registry connectivity and credentials"
    check_detail "Verify images are mirrored to private registry"
fi

# Check for crash loops
if kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null | tr ' ' '\n' | awk '{sum+=$1} END {if(sum>10) exit 1}'; then
    : # No issues
else
    check_warn "DETECTED: High container restart count"
    check_detail "Check container logs for errors"
fi

# Check for pending pods
PENDING=$(kubectl get pods -n "$NAMESPACE" --field-selector status.phase=Pending --no-headers 2>/dev/null | wc -l)
if [[ "$PENDING" -gt 0 ]]; then
    check_fail "DETECTED: $PENDING pending pods"
    check_detail "Check resource limits, node selectors, and PVC status"
fi

# Check for storage issues
if kubectl get events -n "$NAMESPACE" 2>/dev/null | grep -qi "FailedMount\|FailedAttach"; then
    check_fail "DETECTED: Storage mount issues"
    check_detail "Check PVC status and storage class"
fi

# ============================================================================
# SUMMARY
# ============================================================================
header "Diagnostic Summary"

echo ""
TOTAL_CHECKS=$((ERRORS + WARNINGS + CHECKS_PASSED))

if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  ✓ ALL CHECKS PASSED ($CHECKS_PASSED checks)${NC}"
    echo ""
    echo -e "${WHITE}  Your k3s nested installation appears healthy!${NC}"
elif [[ $ERRORS -eq 0 ]]; then
    echo -e "${YELLOW}${BOLD}  ⚠ PASSED WITH WARNINGS${NC}"
    echo ""
    echo -e "${WHITE}  Passed: $CHECKS_PASSED | Warnings: $WARNINGS | Errors: $ERRORS${NC}"
    echo ""
    echo -e "${WHITE}  Review warnings above - they may not be critical but could${NC}"
    echo -e "${WHITE}  indicate potential issues.${NC}"
else
    echo -e "${RED}${BOLD}  ✗ ISSUES DETECTED${NC}"
    echo ""
    echo -e "${WHITE}  Passed: $CHECKS_PASSED | Warnings: $WARNINGS | Errors: $ERRORS${NC}"
    echo ""
    echo -e "${WHITE}  Common fixes:${NC}"
    echo -e "${WHITE}  • Image pull issues: Check registry mirroring and credentials${NC}"
    echo -e "${WHITE}  • Pod not starting: Check 'kubectl logs -n $NAMESPACE $POD_NAME -c k3d'${NC}"
    echo -e "${WHITE}  • Storage issues: Verify storage class and PVC provisioner${NC}"
    echo -e "${WHITE}  • Network issues: Check DNS and registry connectivity${NC}"
fi

echo ""
echo -e "${CYAN}┌─ Quick Debug Commands${NC}"
echo -e "${WHITE}  View k3d logs:${NC}"
echo -e "${WHITE}    kubectl logs -n $NAMESPACE $POD_NAME -c k3d --tail=100${NC}"
echo ""
echo -e "${WHITE}  View kubectl-proxy logs:${NC}"
echo -e "${WHITE}    kubectl logs -n $NAMESPACE $POD_NAME -c kubectl-proxy --tail=50${NC}"
echo ""
echo -e "${WHITE}  Exec into DinD container:${NC}"
echo -e "${WHITE}    kubectl exec -it -n $NAMESPACE $POD_NAME -c k3d -- bash${NC}"
echo ""
echo -e "${WHITE}  Check interior cluster:${NC}"
echo -e "${WHITE}    KUBECONFIG=kubeconfigs/k3s-${INSTANCE_NAME}.yaml kubectl get pods -A${NC}"
echo ""

exit $ERRORS
