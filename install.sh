#!/usr/bin/env bash

#############################################################################
# K3s-in-Kubernetes Installer
#
# Deploys a k3s cluster inside an existing Kubernetes cluster with external
# kubectl access via NodePort, LoadBalancer, or Ingress.
#
# Usage:
#   ./install.sh --name mydev [options]
#   ./install.sh --config config.yaml
#   ./install.sh --batch instances.yaml
#############################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
KUBECONFIGS_DIR="${SCRIPT_DIR}/kubeconfigs"

# Default values
INSTANCE_NAME=""
NAMESPACE=""
K3S_VERSION="v1.32.9+k3s1"
STORAGE_SIZE="10Gi"
STORAGE_CLASS=""
ACCESS_METHOD="nodeport"
NODEPORT="30443"
INGRESS_HOSTNAME=""
INGRESS_CLASS="nginx"
CPU_LIMIT="2"
MEMORY_LIMIT="4Gi"
CPU_REQUEST="1"
MEMORY_REQUEST="2Gi"
CONFIG_FILE=""
BATCH_FILE=""
DRY_RUN=false
VERBOSE=false
WAIT_TIMEOUT=300

# Private Registry Configuration
PRIVATE_REGISTRY=""           # Private registry URL (e.g., docker.local)
REGISTRY_PATH=""              # Optional path prefix (e.g., "docker-sandbox/jmann")
REGISTRY_SECRET=""             # K8s secret name for registry auth
REGISTRY_INSECURE=false        # Allow insecure (HTTP) registry

# Image versions (used with or without private registry)
DOCKER_VERSION="27-dind"
K3D_VERSION="v5.8.3"
K3D_TOOLS_VERSION="5.8.3"

# Legacy image override support (deprecated - use private registry instead)
DIND_IMAGE=""
K3D_IMAGE=""
K3S_IMAGE=""
K3D_TOOLS_IMAGE=""

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
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
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
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

#############################################################################
# Prerequisites Check
#############################################################################

check_prerequisites() {
    log "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        fatal "kubectl is not installed or not in PATH"
    fi

    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        fatal "Cannot connect to Kubernetes cluster. Check your kubeconfig."
    fi

    # Check for required permissions
    if ! kubectl auth can-i create namespaces &> /dev/null; then
        fatal "Insufficient permissions: cannot create namespaces"
    fi

    # Check for storageclass if not specified
    if [[ -z "$STORAGE_CLASS" ]]; then
        if ! kubectl get storageclass -o name &> /dev/null | grep -q .; then
            fatal "No storage class found. Please specify --storage-class or create a default storage class."
        fi
    fi

    success "Prerequisites check passed"
}

#############################################################################
# Configuration Parsing
#############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                INSTANCE_NAME="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --k3s-version)
                K3S_VERSION="$2"
                shift 2
                ;;
            --storage-size)
                STORAGE_SIZE="$2"
                shift 2
                ;;
            --storage-class)
                STORAGE_CLASS="$2"
                shift 2
                ;;
            --access-method)
                ACCESS_METHOD="$2"
                shift 2
                ;;
            --nodeport)
                NODEPORT="$2"
                shift 2
                ;;
            --ingress-hostname)
                INGRESS_HOSTNAME="$2"
                shift 2
                ;;
            --ingress-class)
                INGRESS_CLASS="$2"
                shift 2
                ;;
            --cpu-limit)
                CPU_LIMIT="$2"
                shift 2
                ;;
            --memory-limit)
                MEMORY_LIMIT="$2"
                shift 2
                ;;
            --cpu-request)
                CPU_REQUEST="$2"
                shift 2
                ;;
            --memory-request)
                MEMORY_REQUEST="$2"
                shift 2
                ;;
            --dind-image)
                DIND_IMAGE="$2"
                shift 2
                ;;
            --k3d-image)
                K3D_IMAGE="$2"
                shift 2
                ;;
            --k3s-image)
                K3S_IMAGE="$2"
                shift 2
                ;;
            --k3d-tools-image)
                K3D_TOOLS_IMAGE="$2"
                shift 2
                ;;
            --private-registry)
                PRIVATE_REGISTRY="$2"
                shift 2
                ;;
            --registry-path)
                REGISTRY_PATH="$2"
                shift 2
                ;;
            --registry-secret)
                REGISTRY_SECRET="$2"
                shift 2
                ;;
            --registry-insecure)
                REGISTRY_INSECURE=true
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --batch)
                BATCH_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --wait-timeout)
                WAIT_TIMEOUT="$2"
                shift 2
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
Usage: $0 --name <instance-name> [options]

Required:
  --name NAME                Instance name (e.g., 'dev', 'staging')

Optional:
  --namespace NAMESPACE      Kubernetes namespace (default: k3s-<name>)
  --k3s-version VERSION      K3s version (default: ${K3S_VERSION})
  --storage-size SIZE        PVC size (default: ${STORAGE_SIZE})
  --storage-class CLASS      Storage class name (default: cluster default)

Access Method:
  --access-method METHOD     Access method: nodeport|loadbalancer|ingress (default: nodeport)
  --nodeport PORT           NodePort number (default: ${NODEPORT}, range: 30000-32767)
  --ingress-hostname HOST   Hostname for Ingress (required if using ingress)
  --ingress-class CLASS     Ingress class (default: ${INGRESS_CLASS})

Resources:
  --cpu-limit CPU           CPU limit (default: ${CPU_LIMIT})
  --memory-limit MEM        Memory limit (default: ${MEMORY_LIMIT})
  --cpu-request CPU         CPU request (default: ${CPU_REQUEST})
  --memory-request MEM      Memory request (default: ${MEMORY_REQUEST})

Private Registry (for airgapped environments):
  --private-registry URL    Private registry URL (e.g., docker.local, myregistry.com:5000)
  --registry-path PATH      Path prefix within registry (e.g., "docker-sandbox/jmann")
                            Results in: registry/path/image-name:tag
  --registry-secret NAME    K8s secret name for registry authentication
                            Create with: kubectl create secret docker-registry <name> ...
  --registry-insecure       Allow insecure (HTTP) registry connections

Custom Images (legacy - prefer --private-registry):
  --dind-image IMAGE        Docker-in-Docker image override
  --k3d-image IMAGE         K3d CLI tool image override
  --k3s-image IMAGE         K3s server image override
  --k3d-tools-image IMAGE   K3d helper containers image override

Advanced:
  --config FILE             Load configuration from YAML file
  --batch FILE              Install multiple instances from file
  --dry-run                 Generate manifests without applying
  --verbose                 Enable verbose output
  --wait-timeout SECONDS    Wait timeout for pod ready (default: ${WAIT_TIMEOUT})
  -h, --help                Show this help message

Examples:
  # Quick start with defaults
  $0 --name dev

  # Custom configuration
  $0 --name staging --nodeport 30444 --storage-size 20Gi

  # Using LoadBalancer
  $0 --name prod --access-method loadbalancer

  # Using Ingress
  $0 --name dev --access-method ingress --ingress-hostname k3s-dev.example.com

  # Private registry with all images
  # First, mirror images using list-required-images.sh and mirror-images-to-nexus.sh
  $0 --name dev --private-registry artifactory.company.com

  # Private registry with custom path (Artifactory/Nexus subdirectories)
  $0 --name dev \\
    --private-registry artifactory.company.com \\
    --registry-path docker-sandbox/jmann

  # Custom images (legacy - prefer --private-registry)
  $0 --name dev \\
    --dind-image myregistry.com/docker:dind \\
    --k3d-image myregistry.com/k3d:v5.8.3 \\
    --k3s-image myregistry.com/k3s:v1.31.5-k3s1 \\
    --k3d-tools-image myregistry.com/k3d-tools:v5.8.3

  # From config file
  $0 --config examples/single-instance.yaml

  # Batch installation
  $0 --batch examples/multi-instance.yaml

EOF
}

validate_config() {
    if [[ -z "$INSTANCE_NAME" ]]; then
        fatal "Instance name is required. Use --name or --config"
    fi

    # Set default namespace if not specified
    if [[ -z "$NAMESPACE" ]]; then
        NAMESPACE="k3s-${INSTANCE_NAME}"
    fi

    # Update K3S_IMAGE if only k3s-version was specified
    if [[ "$K3S_IMAGE" == "rancher/k3s:"* ]] && [[ "$K3S_VERSION" != "v1.31.5-k3s1" ]]; then
        K3S_IMAGE="rancher/k3s:${K3S_VERSION}"
    fi

    # Validate access method
    case "$ACCESS_METHOD" in
        nodeport)
            if [[ ! "$NODEPORT" =~ ^[0-9]+$ ]] || [[ "$NODEPORT" -lt 30000 ]] || [[ "$NODEPORT" -gt 32767 ]]; then
                fatal "NodePort must be between 30000 and 32767"
            fi
            ;;
        ingress)
            if [[ -z "$INGRESS_HOSTNAME" ]]; then
                fatal "Ingress hostname is required when using ingress access method"
            fi
            ;;
        loadbalancer)
            # No additional validation needed
            ;;
        *)
            fatal "Invalid access method: $ACCESS_METHOD. Must be nodeport, loadbalancer, or ingress"
            ;;
    esac

    # Validate private registry configuration
    if [[ -n "$REGISTRY_SECRET" && -z "$PRIVATE_REGISTRY" ]]; then
        fatal "Registry secret specified but no private registry URL provided. Use --private-registry <url>"
    fi

    if [[ "$REGISTRY_INSECURE" == "true" && -z "$PRIVATE_REGISTRY" ]]; then
        fatal "Registry insecure flag set but no private registry URL provided. Use --private-registry <url>"
    fi

    if [[ -n "$PRIVATE_REGISTRY" ]]; then
        log "Private registry configuration detected"
        log "  Registry: $PRIVATE_REGISTRY"
        log "  Secret: ${REGISTRY_SECRET:-<none - will use public images>}"
        log "  Insecure: $REGISTRY_INSECURE"

        if [[ -z "$REGISTRY_SECRET" ]]; then
            warn "No registry secret specified. Images must be publicly accessible or authentication must be pre-configured."
        fi
    fi

    debug "Configuration validated:"
    debug "  Instance: $INSTANCE_NAME"
    debug "  Namespace: $NAMESPACE"
    debug "  Access Method: $ACCESS_METHOD"
}

resolve_images() {
    # Normalize version formats for Docker image tags
    # K3d images use versions without "v" prefix (e.g., 5.8.3 not v5.8.3)
    local K3D_IMAGE_VERSION="${K3D_VERSION#v}"
    # K3d tools also use version without "v" prefix
    local K3D_TOOLS_IMAGE_VERSION="${K3D_TOOLS_VERSION#v}"
    # K3s images use dash instead of plus (e.g., v1.32.9-k3s1 not v1.32.9+k3s1)
    local K3S_IMAGE_VERSION="${K3S_VERSION//+/-}"

    # Resolve final image references based on private registry or legacy overrides

    # Docker-in-Docker image
    if [[ -n "$DIND_IMAGE" ]]; then
        # Legacy override takes precedence
        RESOLVED_DIND_IMAGE="$DIND_IMAGE"
    elif [[ -n "$PRIVATE_REGISTRY" ]]; then
        # docker:27-dind is shorthand for docker.io/library/docker:27-dind
        if [[ -n "$REGISTRY_PATH" ]]; then
            RESOLVED_DIND_IMAGE="${PRIVATE_REGISTRY}/${REGISTRY_PATH}/library/docker:${DOCKER_VERSION}"
        else
            RESOLVED_DIND_IMAGE="${PRIVATE_REGISTRY}/library/docker:${DOCKER_VERSION}"
        fi
    else
        RESOLVED_DIND_IMAGE="docker:${DOCKER_VERSION}"
    fi

    # K3d CLI tool image
    if [[ -n "$K3D_IMAGE" ]]; then
        RESOLVED_K3D_IMAGE="$K3D_IMAGE"
    elif [[ -n "$PRIVATE_REGISTRY" ]]; then
        # ghcr.io/k3d-io/k3d:5.8.3 -> registry/k3d-io/k3d:5.8.3
        if [[ -n "$REGISTRY_PATH" ]]; then
            RESOLVED_K3D_IMAGE="${PRIVATE_REGISTRY}/${REGISTRY_PATH}/k3d-io/k3d:${K3D_IMAGE_VERSION}"
        else
            RESOLVED_K3D_IMAGE="${PRIVATE_REGISTRY}/k3d-io/k3d:${K3D_IMAGE_VERSION}"
        fi
    else
        RESOLVED_K3D_IMAGE="ghcr.io/k3d-io/k3d:${K3D_IMAGE_VERSION}"
    fi

    # K3s server image
    if [[ -n "$K3S_IMAGE" ]]; then
        RESOLVED_K3S_IMAGE="$K3S_IMAGE"
    elif [[ -n "$PRIVATE_REGISTRY" ]]; then
        # rancher/k3s:v1.32.9-k3s1 -> registry/rancher/k3s:v1.32.9-k3s1
        if [[ -n "$REGISTRY_PATH" ]]; then
            RESOLVED_K3S_IMAGE="${PRIVATE_REGISTRY}/${REGISTRY_PATH}/rancher/k3s:${K3S_IMAGE_VERSION}"
        else
            RESOLVED_K3S_IMAGE="${PRIVATE_REGISTRY}/rancher/k3s:${K3S_IMAGE_VERSION}"
        fi
    else
        RESOLVED_K3S_IMAGE="rancher/k3s:${K3S_IMAGE_VERSION}"
    fi

    # K3d tools/helper image
    if [[ -n "$K3D_TOOLS_IMAGE" ]]; then
        RESOLVED_K3D_TOOLS_IMAGE="$K3D_TOOLS_IMAGE"
    elif [[ -n "$PRIVATE_REGISTRY" ]]; then
        # ghcr.io/k3d-io/k3d-tools:5.8.3 -> registry/k3d-io/k3d-tools:5.8.3
        if [[ -n "$REGISTRY_PATH" ]]; then
            RESOLVED_K3D_TOOLS_IMAGE="${PRIVATE_REGISTRY}/${REGISTRY_PATH}/k3d-io/k3d-tools:${K3D_TOOLS_IMAGE_VERSION}"
        else
            RESOLVED_K3D_TOOLS_IMAGE="${PRIVATE_REGISTRY}/k3d-io/k3d-tools:${K3D_TOOLS_IMAGE_VERSION}"
        fi
    else
        RESOLVED_K3D_TOOLS_IMAGE="ghcr.io/k3d-io/k3d-tools:${K3D_TOOLS_IMAGE_VERSION}"
    fi

    debug "Resolved images:"
    debug "  DIND: $RESOLVED_DIND_IMAGE"
    debug "  K3D: $RESOLVED_K3D_IMAGE"
    debug "  K3S: $RESOLVED_K3S_IMAGE"
    debug "  K3D_TOOLS: $RESOLVED_K3D_TOOLS_IMAGE"
}

#############################################################################
# Manifest Generation
#############################################################################

generate_namespace() {
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app: k3s-nested
    instance: ${INSTANCE_NAME}
    # PodSecurity labels: Allow privileged pods (required for Docker-in-Docker)
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF
}

generate_pvc() {
    local storage_class_line=""
    if [[ -n "$STORAGE_CLASS" ]]; then
        storage_class_line="  storageClassName: ${STORAGE_CLASS}"
    fi

    cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: k3s-data
  namespace: ${NAMESPACE}
  labels:
    app: k3s
    instance: ${INSTANCE_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE_SIZE}
${storage_class_line}
EOF
}

generate_registries_configmap() {
    if [[ -z "$PRIVATE_REGISTRY" ]]; then
        return 0
    fi

    local tls_config=""
    if [[ "$REGISTRY_INSECURE" == "true" ]]; then
        tls_config="      tls:
        insecure_skip_verify: true"
    fi

    # If REGISTRY_PATH is set, we need to use rewrite rules to prepend the path
    local rewrite_rules=""
    if [[ -n "$REGISTRY_PATH" ]]; then
        rewrite_rules="        rewrite:
          \"(.*)\": \"${REGISTRY_PATH}/\$1\""
    fi

    cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: k3s-registries
  namespace: ${NAMESPACE}
  labels:
    app: k3s
    instance: ${INSTANCE_NAME}
data:
  registries.yaml: |
    mirrors:
      docker.io:
        endpoint:
          - "https://${PRIVATE_REGISTRY}"
${rewrite_rules}
      ghcr.io:
        endpoint:
          - "https://${PRIVATE_REGISTRY}"
${rewrite_rules}
      registry.k8s.io:
        endpoint:
          - "https://${PRIVATE_REGISTRY}"
${rewrite_rules}
    configs:
      "${PRIVATE_REGISTRY}":
${tls_config}
EOF
}

generate_deployment() {
    cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: k3s
  namespace: ${NAMESPACE}
  labels:
    app: k3s
    instance: ${INSTANCE_NAME}
spec:
  strategy:
    type: Recreate
  replicas: 1
  selector:
    matchLabels:
      app: k3s
      instance: ${INSTANCE_NAME}
  template:
    metadata:
      labels:
        app: k3s
        instance: ${INSTANCE_NAME}
    spec:
EOF

    # Add imagePullSecrets if using private registry with secret
    if [[ -n "$PRIVATE_REGISTRY" && -n "$REGISTRY_SECRET" ]]; then
        cat <<EOF
      imagePullSecrets:
      - name: ${REGISTRY_SECRET}
EOF
    fi

    cat <<EOF
      containers:
      - name: dind
        image: ${RESOLVED_DIND_IMAGE}
        command:
          - /bin/sh
          - -c
        args:
          - |
            # Start dockerd in background
            dockerd \\
              --host=unix:///var/run/docker.sock \\
              --host=tcp://0.0.0.0:2375 \\
EOF

    # Add insecure-registry flag if configured
    if [[ "$REGISTRY_INSECURE" == "true" && -n "$PRIVATE_REGISTRY" ]]; then
        cat <<EOF
              --insecure-registry=${PRIVATE_REGISTRY} \\
EOF
    fi

    cat <<EOF
              &

            # Wait for Docker to be ready
            echo "Waiting for Docker daemon to be ready..."
            for i in \$(seq 1 30); do
              if docker info >/dev/null 2>&1; then
                echo "Docker daemon is ready"
                break
              fi
              sleep 1
            done
EOF

    # Add docker config setup if registry secret is configured
    if [[ -n "$PRIVATE_REGISTRY" && -n "$REGISTRY_SECRET" ]]; then
        cat <<EOF

            # Setup Docker registry credentials
            echo "Setting up Docker registry credentials..."
            if [ -f /tmp/docker-secret/config.json ]; then
              mkdir -p /root/.docker
              cp /tmp/docker-secret/config.json /root/.docker/config.json
              chmod 600 /root/.docker/config.json
              echo "Docker credentials configured for ${PRIVATE_REGISTRY}"
            else
              echo "WARNING: Registry secret not found at /tmp/docker-secret/config.json"
            fi
EOF
    fi

    cat <<EOF

            # Keep container running
            wait
        env:
        - name: DOCKER_TLS_CERTDIR
          value: ""
        securityContext:
          privileged: true
        resources:
          limits:
            cpu: "1"
            memory: 2Gi
          requests:
            cpu: "500m"
            memory: 1Gi
        volumeMounts:
        - name: docker-storage
          mountPath: /var/lib/docker
        - name: docker-sock
          mountPath: /var/run
EOF

    # Add registry secret mount to dind if configured
    if [[ -n "$PRIVATE_REGISTRY" && -n "$REGISTRY_SECRET" ]]; then
        cat <<EOF
        - name: registry-secret
          mountPath: /tmp/docker-secret
          readOnly: true
EOF
    fi

    cat <<EOF
      - name: k3d
        image: ${RESOLVED_DIND_IMAGE}
        command:
          - /bin/sh
          - -c
        args:
          - |
            echo "Waiting for Docker to be ready..."
            for i in \$(seq 1 60); do
              if docker info >/dev/null 2>&1; then
                echo "Docker is ready!"
                break
              fi
              echo "Waiting for Docker... (\$i/60)"
              sleep 2
            done

            if ! docker info >/dev/null 2>&1; then
              echo "ERROR: Docker failed to start"
              exit 1
            fi

EOF

    # Add docker credentials setup if private registry is configured with secret (BEFORE extracting k3d binary)
    if [[ -n "$PRIVATE_REGISTRY" && -n "$REGISTRY_SECRET" ]]; then
        cat <<EOF

            # Setup Docker registry credentials for k3d
            echo "Setting up Docker registry credentials for k3d..."
            if [ -f /tmp/docker-secret/config.json ]; then
              mkdir -p /root/.docker
              cp /tmp/docker-secret/config.json /root/.docker/config.json
              chmod 600 /root/.docker/config.json
              echo "Docker credentials configured for k3d"

              # Pre-pull all required images to verify credentials
              echo "Pre-pulling required images from private registry..."

              echo "Pulling k3s image..."
              if ! docker pull ${RESOLVED_K3S_IMAGE}; then
                echo "ERROR: Failed to pull k3s image"
                exit 1
              fi

              echo "Pulling k3d tools image..."
              if ! docker pull ${RESOLVED_K3D_TOOLS_IMAGE}; then
                echo "ERROR: Failed to pull k3d tools image"
                exit 1
              fi

              echo "All images pre-pulled successfully"
            else
              echo "WARNING: Registry secret not found at /tmp/docker-secret/config.json"
            fi

            # Extract k3d binary from k3d image (after credentials are configured)
            echo "Extracting k3d binary from ${RESOLVED_K3D_IMAGE}..."
            CONTAINER_ID=\$(docker create ${RESOLVED_K3D_IMAGE})
            docker cp \$CONTAINER_ID:/bin/k3d /usr/local/bin/k3d
            docker rm \$CONTAINER_ID
            chmod +x /usr/local/bin/k3d
            echo "k3d binary extracted successfully"

            # Extract kubectl binary from k3d-tools image (needed for readiness probe)
            echo "Extracting kubectl binary from ${RESOLVED_K3D_TOOLS_IMAGE}..."
            CONTAINER_ID=\$(docker create ${RESOLVED_K3D_TOOLS_IMAGE})
            docker cp \$CONTAINER_ID:/bin/kubectl /usr/local/bin/kubectl
            docker rm \$CONTAINER_ID
            chmod +x /usr/local/bin/kubectl
            echo "kubectl binary extracted successfully"
EOF
    else
        # No private registry credentials, extract k3d binary directly
        cat <<EOF

            # Extract k3d binary from k3d image
            echo "Extracting k3d binary from ${RESOLVED_K3D_IMAGE}..."
            CONTAINER_ID=\$(docker create ${RESOLVED_K3D_IMAGE})
            docker cp \$CONTAINER_ID:/bin/k3d /usr/local/bin/k3d
            docker rm \$CONTAINER_ID
            chmod +x /usr/local/bin/k3d
            echo "k3d binary extracted successfully"

            # Extract kubectl binary from k3d-tools image (needed for readiness probe)
            echo "Extracting kubectl binary from ${RESOLVED_K3D_TOOLS_IMAGE}..."
            CONTAINER_ID=\$(docker create ${RESOLVED_K3D_TOOLS_IMAGE})
            docker cp \$CONTAINER_ID:/bin/kubectl /usr/local/bin/kubectl
            docker rm \$CONTAINER_ID
            chmod +x /usr/local/bin/kubectl
            echo "kubectl binary extracted successfully"
EOF
    fi

    # Copy registries.yaml to writable location for k3d (always needed when using private registry)
    if [[ -n "$PRIVATE_REGISTRY" ]]; then
        cat <<EOF

            # Copy registries.yaml to writable location for k3d volume mount
            echo "Copying registries.yaml to /tmp for k3d..."
            if [ -f /etc/rancher/k3s/registries.yaml ]; then
              cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml
              chmod 644 /tmp/registries.yaml
              echo "Registry configuration copied successfully"
            else
              echo "ERROR: Registry configuration not found at /etc/rancher/k3s/registries.yaml"
              exit 1
            fi
EOF
    fi

    cat <<EOF

            # Build k3d args
            K3D_ARGS="--api-port 0.0.0.0:6443 \\
              --servers 1 \\
              --agents 0 \\
              --no-lb \\
              --wait \\
              --timeout 5m \\
              --k3s-arg '--tls-san=${INSTANCE_NAME}@server:0' \\
              --k3s-arg '--tls-san=k3s-service@server:0' \\
              --k3s-arg '--tls-san=k3s-service.${NAMESPACE}.svc.cluster.local@server:0' \\
              --k3s-arg '--tls-san=127.0.0.1@server:0' \\
              --k3s-arg '--tls-san=localhost@server:0'"

            # Add ingress hostname TLS SAN if set
            if [ -n "${INGRESS_HOSTNAME}" ]; then
              K3D_ARGS="\$K3D_ARGS --k3s-arg '--tls-san=${INGRESS_HOSTNAME}@server:0'"
            fi
EOF

    # Add registries.yaml configuration if private registry is configured
    if [[ -n "$PRIVATE_REGISTRY" ]]; then
        cat <<EOF

            # Add private registry configuration using k3d's native flag
            K3D_ARGS="\$K3D_ARGS --registry-config /tmp/registries.yaml"
EOF
    fi

    cat <<EOF

            K3D_ARGS="\$K3D_ARGS \\
              --k3s-arg '--disable=traefik@server:0' \\
              --k3s-arg '--disable=servicelb@server:0' \\
              --image=${RESOLVED_K3S_IMAGE}"

            eval "k3d cluster create ${INSTANCE_NAME} \$K3D_ARGS"
            k3d kubeconfig get ${INSTANCE_NAME} > /output/kubeconfig.yaml
            chmod 666 /output/kubeconfig.yaml
            echo "K3s cluster '${INSTANCE_NAME}' is ready!"
            tail -f /dev/null
        env:
        - name: DOCKER_HOST
          value: tcp://localhost:2375
EOF

    # Add k3d image override env vars if using private registry or custom tools image
    # These control all helper containers that k3d creates (proxy, tools, registry)
    if [[ -n "$RESOLVED_K3D_TOOLS_IMAGE" ]]; then
        cat <<EOF
        - name: K3D_IMAGE_LOADBALANCER
          value: ${RESOLVED_K3D_TOOLS_IMAGE}
        - name: K3D_IMAGE_TOOLS
          value: ${RESOLVED_K3D_TOOLS_IMAGE}
        - name: K3D_IMAGE_REGISTRY
          value: ${RESOLVED_K3D_TOOLS_IMAGE}
EOF
    fi

    cat <<EOF
        ports:
        - containerPort: 6443
          name: api
          protocol: TCP
        resources:
          limits:
            cpu: "${CPU_LIMIT}"
            memory: ${MEMORY_LIMIT}
          requests:
            cpu: "${CPU_REQUEST}"
            memory: ${MEMORY_REQUEST}
        volumeMounts:
        - name: docker-sock
          mountPath: /var/run
        - name: k3s-config
          mountPath: /output
EOF

    # Add registries config mount to k3d if configured
    if [[ -n "$PRIVATE_REGISTRY" ]]; then
        cat <<EOF
        - name: registries-config
          mountPath: /etc/rancher/k3s/registries.yaml
          subPath: registries.yaml
          readOnly: true
EOF
        # Also mount registry secret if configured
        if [[ -n "$REGISTRY_SECRET" ]]; then
            cat <<EOF
        - name: registry-secret
          mountPath: /tmp/docker-secret
          readOnly: true
EOF
        fi
    fi

    cat <<EOF
        readinessProbe:
          exec:
            command:
            - sh
            - -c
            - kubectl --kubeconfig=/output/kubeconfig.yaml get nodes 2>/dev/null | grep -q Ready
          initialDelaySeconds: 90
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
      volumes:
      - name: docker-storage
        emptyDir: {}
      - name: docker-sock
        emptyDir: {}
      - name: k3s-config
        emptyDir: {}
EOF

    # Add private registry volumes if configured
    if [[ -n "$PRIVATE_REGISTRY" ]]; then
        cat <<EOF
      - name: registries-config
        configMap:
          name: k3s-registries
EOF
        if [[ -n "$REGISTRY_SECRET" ]]; then
            cat <<EOF
      - name: registry-secret
        secret:
          secretName: ${REGISTRY_SECRET}
          items:
          - key: .dockerconfigjson
            path: config.json
EOF
        fi
    fi
}

generate_service_nodeport() {
    cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: k3s-nodeport
  namespace: ${NAMESPACE}
  labels:
    app: k3s
    instance: ${INSTANCE_NAME}
spec:
  type: NodePort
  selector:
    app: k3s
    instance: ${INSTANCE_NAME}
  ports:
  - name: api
    port: 6443
    targetPort: 6443
    protocol: TCP
    nodePort: ${NODEPORT}
EOF
}

generate_service_loadbalancer() {
    cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: k3s-loadbalancer
  namespace: ${NAMESPACE}
  labels:
    app: k3s
    instance: ${INSTANCE_NAME}
spec:
  type: LoadBalancer
  selector:
    app: k3s
    instance: ${INSTANCE_NAME}
  ports:
  - name: api
    port: 6443
    targetPort: 6443
    protocol: TCP
EOF
}

generate_service_clusterip() {
    cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: k3s-service
  namespace: ${NAMESPACE}
  labels:
    app: k3s
    instance: ${INSTANCE_NAME}
spec:
  type: ClusterIP
  selector:
    app: k3s
    instance: ${INSTANCE_NAME}
  ports:
  - name: api
    port: 6443
    targetPort: 6443
    protocol: TCP
EOF
}

generate_ingress() {
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k3s-ingress
  namespace: ${NAMESPACE}
  labels:
    app: k3s
    instance: ${INSTANCE_NAME}
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
  - host: ${INGRESS_HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: k3s-service
            port:
              number: 6443
EOF
}

#############################################################################
# Deployment Functions
#############################################################################

deploy_instance() {
    log "Deploying k3s instance '${INSTANCE_NAME}' in namespace '${NAMESPACE}'..."

    # Resolve final image references
    resolve_images

    # Create temporary manifest file
    local manifest_file=$(mktemp)

    # Generate all manifests
    {
        generate_namespace
        echo "---"
        generate_pvc
        echo "---"

        # Generate registries ConfigMap if using private registry
        if [[ -n "$PRIVATE_REGISTRY" ]]; then
            generate_registries_configmap
            echo "---"
        fi

        generate_deployment
        echo "---"
        generate_service_clusterip
        echo "---"

        case "$ACCESS_METHOD" in
            nodeport)
                generate_service_nodeport
                ;;
            loadbalancer)
                generate_service_loadbalancer
                ;;
            ingress)
                generate_service_clusterip  # Still need ClusterIP for ingress backend
                echo "---"
                generate_ingress
                ;;
        esac
    } > "$manifest_file"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run mode - manifests:"
        cat "$manifest_file"
        rm "$manifest_file"
        return 0
    fi

    # Apply manifests
    if kubectl apply -f "$manifest_file"; then
        success "Manifests applied successfully"
    else
        error "Failed to apply manifests"
        rm "$manifest_file"
        return 1
    fi

    rm "$manifest_file"

    # Wait for pod to be ready
    wait_for_pod

    # Extract kubeconfig
    extract_kubeconfig

    # Display success message
    show_success_message
}

wait_for_pod() {
    log "Waiting for k3s pod to be ready (timeout: ${WAIT_TIMEOUT}s)..."

    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do
        local status=$(kubectl get pods -n "$NAMESPACE" -l "app=k3s,instance=${INSTANCE_NAME}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

        local ready=$(kubectl get pods -n "$NAMESPACE" -l "app=k3s,instance=${INSTANCE_NAME}" \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

        if [[ "$status" == "Running" && "$ready" == "True" ]]; then
            success "Pod is ready!"
            return 0
        fi

        debug "Pod status: $status, Ready: $ready"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    error "Timeout waiting for pod to be ready"
    kubectl get pods -n "$NAMESPACE" -l "app=k3s,instance=${INSTANCE_NAME}"
    kubectl describe pod -n "$NAMESPACE" -l "app=k3s,instance=${INSTANCE_NAME}"
    return 1
}

extract_kubeconfig() {
    log "Extracting kubeconfig..."

    mkdir -p "$KUBECONFIGS_DIR"
    local kubeconfig_file="${KUBECONFIGS_DIR}/k3s-${INSTANCE_NAME}.yaml"

    # Get pod name
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l "app=k3s,instance=${INSTANCE_NAME}" \
        -o jsonpath='{.items[0].metadata.name}')

    if [[ -z "$pod_name" ]]; then
        error "Could not find pod"
        return 1
    fi

    # Extract kubeconfig from pod
    kubectl cp "$NAMESPACE/$pod_name:/output/kubeconfig.yaml" "${kubeconfig_file}.tmp" -c k3d

    # Validate the file was extracted
    if [[ ! -s "${kubeconfig_file}.tmp" ]]; then
        error "Failed to extract kubeconfig from pod (file is empty or missing)"
        return 1
    fi

    # Modify server URL based on access method
    case "$ACCESS_METHOD" in
        nodeport)
            sed "s|https://[^:]*:6443|https://localhost:${NODEPORT}|g" "${kubeconfig_file}.tmp" > "$kubeconfig_file"
            ;;
        loadbalancer)
            # Wait for external IP
            log "Waiting for LoadBalancer external IP..."
            local external_ip=""
            for i in {1..60}; do
                external_ip=$(kubectl get svc -n "$NAMESPACE" k3s-loadbalancer \
                    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
                if [[ -n "$external_ip" && "$external_ip" != "null" ]]; then
                    break
                fi
                sleep 2
            done

            if [[ -z "$external_ip" ]]; then
                warn "Could not get LoadBalancer IP. Please update kubeconfig manually."
                cp "${kubeconfig_file}.tmp" "$kubeconfig_file"
            else
                sed "s|https://[^:]*:6443|https://${external_ip}:6443|g" "${kubeconfig_file}.tmp" > "$kubeconfig_file"
            fi
            ;;
        ingress)
            sed "s|https://[^:]*:6443|https://${INGRESS_HOSTNAME}|g" "${kubeconfig_file}.tmp" > "$kubeconfig_file"
            ;;
    esac

    rm "${kubeconfig_file}.tmp"

    success "Kubeconfig saved to: $kubeconfig_file"

    # Test connection
    if kubectl --kubeconfig="$kubeconfig_file" cluster-info &>/dev/null; then
        success "Successfully verified connection to inner k3s cluster"
    else
        warn "Could not verify connection to inner k3s cluster. It may take a moment to be fully ready."
    fi
}

show_success_message() {
    echo ""
    success "═══════════════════════════════════════════════════════════"
    success "  K3s instance '${INSTANCE_NAME}' deployed successfully!"
    success "═══════════════════════════════════════════════════════════"
    echo ""
    log "Instance Details:"
    log "  Name:       ${INSTANCE_NAME}"
    log "  Namespace:  ${NAMESPACE}"
    log "  Access:     ${ACCESS_METHOD}"

    case "$ACCESS_METHOD" in
        nodeport)
            log "  URL:        https://localhost:${NODEPORT}"
            ;;
        loadbalancer)
            local external_ip=$(kubectl get svc -n "$NAMESPACE" k3s-loadbalancer \
                -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
            log "  External IP: ${external_ip}"
            ;;
        ingress)
            log "  Hostname:   ${INGRESS_HOSTNAME}"
            ;;
    esac

    echo ""
    log "To access your k3s cluster:"
    echo ""
    echo "  export KUBECONFIG=${KUBECONFIGS_DIR}/k3s-${INSTANCE_NAME}.yaml"
    echo "  kubectl get nodes"
    echo ""
    log "Or use the management script:"
    echo ""
    echo "  ./manage.sh access ${INSTANCE_NAME}"
    echo ""
}

#############################################################################
# Main Execution
#############################################################################

main() {
    # Parse arguments
    parse_args "$@"

    # Handle batch mode
    if [[ -n "$BATCH_FILE" ]]; then
        fatal "Batch mode not yet implemented. Please install instances individually."
    fi

    # Validate configuration
    validate_config

    # Check prerequisites
    check_prerequisites

    # Deploy instance
    deploy_instance
}

# Run main function
main "$@"
