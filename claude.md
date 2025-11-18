# K3s-Nested-Installer: Architecture & Codebase Guide

**Last Updated**: 2025-11-18  
**Project Status**: Production-ready with active development  
**Latest Version**: v1.32.9+k3s1 (k3s), v5.8.3 (k3d)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Project Architecture](#project-architecture)
3. [Directory Structure](#directory-structure)
4. [Entry Points & Scripts](#entry-points--scripts)
5. [Key Functions & Code Patterns](#key-functions--code-patterns)
6. [Configuration System](#configuration-system)
7. [Deployment Model](#deployment-model)
8. [Component Interactions](#component-interactions)
9. [Important Environment Variables](#important-environment-variables)
10. [Common Gotchas & Pitfalls](#common-gotchas--pitfalls)

---

## Executive Summary

**K3s-Nested-Installer** deploys fully functional, isolated k3s Kubernetes clusters inside any existing Kubernetes cluster (GKE, EKS, AKS, MicroK8s, Kind, vanilla Kubernetes, etc.). Each nested k3s instance:

- Runs in its own pod within a dedicated namespace
- Uses Docker-in-Docker (DinD) + k3d for cluster creation
- Is accessible externally via kubectl using standard kubeconfigs
- Supports multiple access methods: NodePort, LoadBalancer, or Ingress
- Can be used for development, testing, multi-tenancy, or training

**Core Use Case**: Create isolated development/test Kubernetes environments without provisioning separate infrastructure.

---

## Project Architecture

### Nesting Model

```
Host Kubernetes Cluster (Any Distribution)
├── Namespace: k3s-{instance-name}
│   ├── PersistentVolumeClaim: k3s-data (10-50Gi)
│   └── Deployment: k3s
│       └── Pod: k3s-xxxxx
│           ├── Container: dind (Docker daemon)
│           │   └── Docker socket: /var/run/docker.sock
│           └── Container: k3d (k3s cluster operator)
│               └── k3s Cluster (v1.32.9+k3s1)
│                   ├── API Server: :6443 (exposed via Service)
│                   ├── Node: k3d-{instance-name}-server-0
│                   └── Internal Services/Pods
│
├── Service: k3s-service (ClusterIP:6443) [Internal access]
├── Service: k3s-nodeport (NodePort:30XXX) [External via NodePort]
├── Service: k3s-loadbalancer (LoadBalancer) [External via cloud LB]
├── Service: k3s-ingress (Ingress) [External via hostname]
└── ConfigMap: k3s-registries (Private registry config)
```

### Key Architectural Decisions

1. **Docker-in-Docker**: Provides complete Docker environment for k3d to operate
2. **k3d**: Lightweight k3s cluster creator that runs as a set of Docker containers
3. **Single Pod Deployment**: Entire k3s cluster runs in one Kubernetes pod (not HA)
4. **Privileged Containers**: DinD requires privileged security context
5. **Persistent Storage**: PVC stores k3s data (server state, logs, configs)
6. **Multiple Access Methods**: Flexibility for different deployment scenarios

---

## Directory Structure

```
k3s-nested-installer/
├── install.sh                          # Main installation script (1291 lines)
├── manage.sh                           # Management CLI utility (473 lines)
├── list-required-images.sh             # Image enumeration for airgap (366 lines)
├── mirror-images-to-nexus.sh           # Image mirroring for private registries
├── mirror-images-sequential.sh         # Sequential image mirror (fallback)
├── verify-airgap.sh                    # Validates airgap deployment
│
├── templates/                          # [CURRENTLY EMPTY - used for future template files]
│
├── examples/                           # Configuration examples
│   ├── single-instance.yaml            # Basic single k3s instance config
│   ├── loadbalancer.yaml               # LoadBalancer access method config
│   └── ingress.yaml                    # Ingress access method config
│
├── tests/                              # Test suite
│   ├── run-all-tests.sh                # Test runner script
│   ├── test-registry-config.sh         # Registry configuration tests
│   ├── test-airgap-end-to-end.sh       # Complete airgap workflow test
│   └── validate-airgap-deployment.sh   # Airgap deployment validation
│
├── auxiliary/dns/                      # DNS configuration helpers
│   ├── configure-dns.sh                # DNS setup script
│   ├── verify-dns.sh                   # DNS verification script
│   └── coredns-ingress-dns.yaml        # CoreDNS config for Ingress
│
├── kubeconfigs/                        # [GENERATED] kubeconfig files
│   └── k3s-{instance-name}.yaml        # One per deployed instance
│
├── reports/                            # [GENERATED] Test reports
│
├── working-example/                    # Live example deployment (MicroK8s)
│   ├── k3s-deployment.yaml             # Manifest files
│   ├── k3s-service.yaml
│   └── access-inner-k3s.sh             # Helper script for access
│
├── Documentation (*.md files)
│   ├── README.md                       # Quick start & overview
│   ├── QUICKSTART.md                   # 5-minute quick start
│   ├── IMPLEMENTATION.md               # Detailed implementation guide (785 lines)
│   ├── AIRGAPPED-SETUP.md              # Private registry setup
│   ├── TROUBLESHOOTING.md              # Common issues & solutions (569 lines)
│   ├── TESTING.md                      # Test documentation
│   ├── DEPLOYMENT_SUMMARY.md           # Deployment overview
│   ├── BUG_FIX_SUMMARY.md              # Recent critical fixes
│   └── TEST_RESULTS.md                 # Test results documentation
│
├── .github/workflows/                  # CI/CD Pipeline
│   └── test.yml                        # GitHub Actions test suite
│
└── .serena/                            # Project metadata
    └── project.yml                     # Project configuration

```

### Purpose of Key Directories

| Directory | Purpose | Auto-Generated |
|-----------|---------|-----------------|
| `templates/` | Future: Template files for custom deployments | No |
| `examples/` | Configuration YAML examples for different scenarios | No |
| `tests/` | Shell script test suite with unit & integration tests | No |
| `auxiliary/dns/` | DNS configuration utilities for Ingress access method | No |
| `kubeconfigs/` | Generated kubeconfig files for each deployed instance | Yes |
| `reports/` | Generated test result reports | Yes |
| `working-example/` | Live deployment example in MicroK8s environment | Mixed |

---

## Entry Points & Scripts

### 1. `install.sh` (1291 lines) - Main Deployment Script

**Purpose**: Creates and deploys a new k3s instance in an existing Kubernetes cluster

**Main Entry Point**: `main()` function (line 1271)

**Key Functions**:
- `check_prerequisites()` - Validates kubectl, cluster connectivity, RBAC permissions
- `parse_args()` - Command-line argument parsing
- `validate_config()` - Configuration validation (access methods, versions, etc.)
- `resolve_images()` - Resolves final image references with registry prefixes
- `generate_*()` functions - Generate Kubernetes manifests:
  - `generate_namespace()` - Creates namespace with pod security labels
  - `generate_pvc()` - Persistent volume claim for k3s data
  - `generate_registries_configmap()` - Private registry configuration
  - `generate_deployment()` - Main deployment with DinD + k3d containers
  - `generate_service_*()` - Services (ClusterIP, NodePort, LoadBalancer)
  - `generate_ingress()` - Ingress for hostname-based access
- `deploy_instance()` - Applies manifests and waits for readiness
- `wait_for_pod()` - Polls pod status until Ready condition
- `extract_kubeconfig()` - Extracts kubeconfig from pod and adjusts endpoint
- `show_success_message()` - Displays deployment summary

**Execution Flow**:
```
main()
  ├─> parse_args()           # Parse --name, --access-method, etc.
  ├─> validate_config()      # Check for conflicts/requirements
  ├─> check_prerequisites()  # kubectl connectivity, RBAC, storage
  └─> deploy_instance()
       ├─> resolve_images()  # Determine final image references
       ├─> generate_*()      # Create all K8s manifests
       ├─> kubectl apply     # Deploy to cluster
       ├─> wait_for_pod()    # Wait for pod Ready
       ├─> extract_kubeconfig()  # Get kubeconfig from pod
       └─> show_success_message()
```

### 2. `manage.sh` (473 lines) - Management CLI

**Purpose**: Manage deployed k3s instances (list, access, delete, etc.)

**Key Commands**:
- `manage.sh list` - List all deployed k3s instances with status
- `manage.sh access <name>` - Show connection info and test access
- `manage.sh refresh-kubeconfig <name>` - Re-extract kubeconfig from running pod
- `manage.sh delete <name>` - Delete an instance (with confirmation)
- `manage.sh delete-all` - Delete all instances
- `manage.sh logs <name> [container]` - Stream logs from dind or k3d container
- `manage.sh exec <name> -- <kubectl-cmd>` - Execute kubectl on instance
- `manage.sh status <name>` - Show detailed status (pod, resources, services)
- `manage.sh resources` - Show resource usage across all instances

**Key Functions**:
- `cmd_list()` - Enumerates all namespaces with `app=k3s-nested` label
- `cmd_access()` - Tests connectivity and displays cluster info
- `cmd_refresh_kubeconfig()` - Extracts kubeconfig from pod
- `cmd_delete()` - Cascading delete of namespace and kubeconfig
- `cmd_logs()` - Streams container logs with tail
- `cmd_exec()` - Proxies kubectl commands through the instance's kubeconfig
- `cmd_status()` - Shows pod status, service details, storage info
- `cmd_resources()` - Aggregates resource usage metrics

### 3. `list-required-images.sh` (366 lines) - Image Enumeration

**Purpose**: Generate list of all container images required for installation

**Usage**:
```bash
./list-required-images.sh --registry docker.local --output required-images.txt
```

**Key Functions**:
- Generates complete image inventory including:
  - Docker DinD image
  - k3d CLI image
  - k3s server image
  - k3d helper images (proxy, tools, registry)
- Outputs in formats: `mapping` (source→destination) or `list` (destination only)
- Supports registry path prefixes for enterprise registries

### 4. `mirror-images-to-nexus.sh` - Image Mirroring

**Purpose**: Mirror public images to private registry for airgap deployments

**Key Capabilities**:
- Pulls images from public registries (Docker Hub, ghcr.io, etc.)
- Pushes to private registry with authentication
- Progress tracking and error handling
- Dry-run mode for validation
- Report generation

### 5. Other Utility Scripts

| Script | Purpose |
|--------|---------|
| `mirror-images-sequential.sh` | Fallback sequential image mirroring (slower but more reliable) |
| `verify-airgap.sh` | Validates airgap environment is properly configured |
| `auxiliary/dns/configure-dns.sh` | Sets up CoreDNS for Ingress hostname resolution |
| `auxiliary/dns/verify-dns.sh` | Tests DNS resolution for ingress hostnames |
| `tests/test-registry-config.sh` | Unit tests for registry configuration |
| `tests/test-airgap-end-to-end.sh` | Full airgap workflow integration test |

---

## Key Functions & Code Patterns

### Container Command Generation Pattern

The most complex function is `generate_deployment()` (starting line 572). It generates a Kubernetes Deployment with two containers using shell scripts embedded in YAML:

**Pattern**: Inline shell scripts within YAML args

```bash
generate_deployment() {
    cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: k3s
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: dind
    image: ${RESOLVED_DIND_IMAGE}
    args:
      - |
        # Shell script starts here
        dockerd --host=unix:///var/run/docker.sock &
        wait
```

**Why This Pattern**:
- Inline scripts are self-contained in YAML
- No need for separate ConfigMaps or init containers
- Easier to debug (full script in one place)
- Shell variable substitution happens at manifest generation time

### Image Resolution Pattern

The `resolve_images()` function (line 397) demonstrates a sophisticated image resolution strategy:

```bash
resolve_images() {
    # Handle three different ways to specify images:
    # 1. Legacy: --dind-image, --k3d-image, --k3s-image flags (deprecated)
    # 2. Private registry: --private-registry with optional --registry-path
    # 3. Default: Public images from ghcr.io, docker.io, rancher
    
    # Priority order:
    if [[ -n "$DIND_IMAGE" ]]; then
        RESOLVED_DIND_IMAGE="$DIND_IMAGE"  # Legacy override wins
    elif [[ -n "$PRIVATE_REGISTRY" ]]; then
        # Construct: ${REGISTRY}/${REGISTRY_PATH}/library/docker:${TAG}
        RESOLVED_DIND_IMAGE="${PRIVATE_REGISTRY}/${REGISTRY_PATH}/library/docker:${DOCKER_VERSION}"
    else
        RESOLVED_DIND_IMAGE="docker:${DOCKER_VERSION}"  # Public default
    fi
}
```

**Design Rationale**:
- Backward compatible with legacy per-image flags
- Modern approach: single `--private-registry` flag
- Supports enterprise registries with path prefixes

### Version Normalization

Important transformations happen in `resolve_images()`:

```bash
# Input: v5.8.3 → Output: 5.8.3 (remove leading 'v')
local K3D_IMAGE_VERSION="${K3D_VERSION#v}"

# Input: v1.32.9+k3s1 → Output: v1.32.9-k3s1 (replace '+' with '-')
local K3S_IMAGE_VERSION="${K3S_VERSION//+/-}"
```

**Why**: Container image tags use `-` not `+`, but k3s versions use `+`

### Registry Configuration Pattern

For private registries, `install.sh` creates a ConfigMap with `registries.yaml`:

```bash
generate_registries_configmap() {
    # Generates containerd mirror configuration:
    # - Mirrors docker.io, ghcr.io, registry.k8s.io to private registry
    # - Optionally adds path rewrite rules for Artifactory/Nexus
    # - Handles TLS configuration (insecure_skip_verify)
    
    # If REGISTRY_PATH="docker-sandbox/team" is set:
    # - All image pulls get rewritten with path prefix
    # - E.g., docker.io/library/ubuntu:22.04 →
    #        registry/docker-sandbox/team/library/ubuntu:22.04
}
```

### Wait-for-Readiness Pattern

The `wait_for_pod()` function (line 1135) uses polling with exponential backoff:

```bash
wait_for_pod() {
    local elapsed=0
    local interval=5  # Check every 5 seconds
    
    while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do  # Default 300s (5 min)
        local status=$(kubectl get pods ... -o jsonpath='{.items[0].status.phase}')
        local ready=$(kubectl get pods ... -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
        
        if [[ "$status" == "Running" && "$ready" == "True" ]]; then
            return 0  # Success
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    # Timeout - show debugging info
    kubectl describe pod ...
    return 1
}
```

**Gotcha**: Initial delay is long (90s) because DinD startup + Docker daemon init takes time

### Kubeconfig Endpoint Rewriting

The `extract_kubeconfig()` function (line 1164) adapts the kubeconfig based on access method:

```bash
extract_kubeconfig() {
    # All k3s clusters initially have: https://localhost:6443
    # This needs to be rewritten based on access method:
    
    case "$ACCESS_METHOD" in
        nodeport)
            # Rewrite: https://localhost:6443 → https://localhost:${NODEPORT}
            sed "s|https://[^:]*:6443|https://localhost:${NODEPORT}|g"
            ;;
        loadbalancer)
            # Rewrite: https://localhost:6443 → https://${EXTERNAL_IP}:6443
            # Must wait for external IP to be assigned (polling)
            ;;
        ingress)
            # Rewrite: https://localhost:6443 → https://${INGRESS_HOSTNAME}
            sed "s|https://[^:]*:6443|https://${INGRESS_HOSTNAME}|g"
            ;;
    esac
}
```

---

## Configuration System

### Command-Line Arguments

The `parse_args()` function (line 133) handles ~20 different flags:

**Core Instance Parameters**:
```bash
--name <name>                    # Required: instance identifier
--namespace <ns>                 # Optional: K8s namespace (default: k3s-{name})
--k3s-version <version>          # Optional: K3s version (default: v1.32.9+k3s1)
```

**Storage Parameters**:
```bash
--storage-size <size>            # Optional: PVC size (default: 10Gi)
--storage-class <class>          # Optional: storage class name
```

**Resource Parameters**:
```bash
--cpu-limit <cpu>                # Optional: pod CPU limit (default: 2)
--memory-limit <mem>             # Optional: pod memory limit (default: 4Gi)
--cpu-request <cpu>              # Optional: pod CPU request (default: 1)
--memory-request <mem>           # Optional: pod memory request (default: 2Gi)
```

**Access Method Parameters**:
```bash
--access-method <method>         # nodeport|loadbalancer|ingress (default: nodeport)
--nodeport <port>                # NodePort number (default: 30443, range: 30000-32767)
--ingress-hostname <hostname>    # Required for ingress access method
--ingress-class <class>          # Ingress controller class (default: nginx)
```

**Private Registry Parameters**:
```bash
--private-registry <url>         # Private registry URL (e.g., docker.local, artifactory.com:5000)
--registry-path <path>           # Optional path prefix (e.g., "docker-sandbox/team")
--registry-secret <name>         # K8s secret for registry auth
--registry-insecure              # Allow HTTP (insecure) connections
```

**Legacy Image Override Parameters** (deprecated):
```bash
--dind-image <image>             # DinD image override
--k3d-image <image>              # k3d CLI image override
--k3s-image <image>              # k3s server image override
--k3d-tools-image <image>        # k3d helper image override
```

**Advanced Parameters**:
```bash
--config <file>                  # Load from YAML config file
--batch <file>                   # Batch installation (not yet implemented)
--dry-run                        # Generate manifests without applying
--verbose                        # Enable debug output
--wait-timeout <seconds>         # Pod readiness timeout (default: 300s)
```

### YAML Configuration Files

Configuration can be loaded from YAML files (see `examples/`):

```yaml
instance:
  name: dev
  namespace: k3s-dev

k3s:
  version: v1.32.9+k3s1

storage:
  size: 10Gi
  storageClass: ""

resources:
  cpu:
    limit: "2"
    request: "1"
  memory:
    limit: 4Gi
    request: 2Gi

access:
  method: nodeport
  nodeport:
    port: 30443
```

**Note**: YAML config parsing is NOT yet implemented in install.sh (parse_args only handles flags)

### Environment Variables

Key environment variables set during deployment:

| Variable | Set By | Used By | Purpose |
|----------|--------|---------|---------|
| `DOCKER_HOST` | k3d container startup | k3d binary | Unix socket for Docker daemon |
| `DOCKER_TLS_CERTDIR` | Deployment manifest | DinD startup | Disable TLS (empty value) |
| `K3D_IMAGE_LOADBALANCER` | install.sh | k3d process | Override k3d proxy image |
| `K3D_IMAGE_TOOLS` | install.sh | k3d process | Override k3d tools image |
| `K3D_IMAGE_REGISTRY` | install.sh | k3d process | Override k3d registry image |

---

## Deployment Model

### Two-Container Architecture

**Container 1: dind (Docker-in-Docker)**
- Image: `docker:27-dind`
- Purpose: Run Docker daemon
- Security: `privileged: true`
- Resources: 1 CPU request, 0.5-2Gi memory
- Volumes: `/var/lib/docker`, `/var/run`

**Container 2: k3d (k3s Cluster Operator)**
- Image: `docker:27-dind` (same as dind, used to extract k3d binary)
- Purpose: Run k3d to create/manage k3s cluster
- Security: No special requirements (unprivileged)
- Resources: User-configurable (default: 1 CPU request, 2 CPU limit, 2-4Gi memory)
- Volumes: Docker socket (shared with dind), kubeconfig output directory

### Execution Sequence

1. **DinD Container Starts**
   - Launches Docker daemon on Unix socket
   - Waits up to 30 seconds for daemon to be ready
   - Sets up registry credentials if private registry configured

2. **k3d Container Starts**
   - Waits up to 60 seconds for Docker daemon to be ready
   - Extracts k3d binary from k3d image (via docker create/cp)
   - Extracts kubectl binary from k3d-tools image
   - Pre-pulls k3s and k3d-tools images (if using private registry)
   - Copies `registries.yaml` to `/tmp` for k3d to use
   - Builds k3d arguments with TLS SANs, registry config, etc.
   - Runs: `k3d cluster create {instance-name} <args>`
   - Extracts kubeconfig to `/output/kubeconfig.yaml`
   - Keeps container running with `tail -f /dev/null`

3. **Readiness Probe**
   - Periodically checks: `docker exec k3d-{instance-name}-server-0 kubectl get nodes`
   - Pod Ready when inner cluster has Ready nodes

### Network Connectivity

```
User Machine
    ↓ kubectl --kubeconfig=k3s-dev.yaml
    ↓ (connects to localhost:30443 for NodePort)
Host Kubernetes Cluster
    ↓ Routes to Pod IP:6443
Outer K3s Pod (Port 6443)
    ↓ Docker network bridge
k3d Docker Container
    ↓ containerd/Docker networks
k3s API Server (Port 6443)
```

**Important**: Services only expose port 6443 (inner k3s API), not 2375 (Docker daemon)

---

## Component Interactions

### Script Call Graph

```
install.sh [entry point]
├── check_prerequisites()
│   ├── kubectl cluster-info
│   ├── kubectl auth can-i
│   └── kubectl get storageclass
│
├── parse_args()
│   └── show_usage() [if --help]
│
├── validate_config()
│
├── resolve_images()
│   └── [Constructs final image references]
│
├── deploy_instance()
│   ├── generate_namespace()
│   ├── generate_pvc()
│   ├── generate_registries_configmap()
│   ├── generate_deployment()
│   ├── generate_service_clusterip()
│   ├── generate_service_nodeport() [if nodeport]
│   ├── generate_service_loadbalancer() [if loadbalancer]
│   ├── generate_ingress() [if ingress]
│   ├── kubectl apply [ALL manifests]
│   ├── wait_for_pod()
│   │   └── kubectl get pods [polling loop]
│   ├── extract_kubeconfig()
│   │   ├── kubectl cp [from pod]
│   │   ├── sed [rewrite endpoint based on access method]
│   │   └── kubectl --kubeconfig cluster-info [verify]
│   └── show_success_message()
│
└── main()
    └── deploy_instance()

manage.sh [entry point - CLI dispatcher]
├── cmd_list()
│   ├── kubectl get namespaces [find all k3s-nested instances]
│   └── kubectl get svc [determine access method]
│
├── cmd_access()
│   ├── kubectl cluster-info [with kubeconfig]
│   └── kubectl get nodes [with kubeconfig]
│
├── cmd_refresh_kubeconfig()
│   ├── kubectl get namespaces [find instance]
│   ├── kubectl cp [extract from pod]
│   ├── sed [rewrite endpoint]
│   └── kubectl --kubeconfig cluster-info [verify]
│
├── cmd_delete()
│   ├── kubectl delete namespace [cascade]
│   └── rm [kubeconfig file]
│
├── cmd_logs()
│   └── kubectl logs [streaming with -f]
│
├── cmd_exec()
│   └── kubectl [proxied with kubeconfig]
│
├── cmd_status()
│   ├── kubectl get pods
│   ├── kubectl get svc
│   └── kubectl get pvc
│
├── cmd_delete_all()
│   └── [loops cmd_delete for each instance]
│
├── cmd_resources()
│   └── kubectl top pods [resource metrics]
│
└── main()
    └── [Dispatcher to appropriate cmd_* function]

list-required-images.sh
├── parse_args()
├── add_image() [utility function]
├── generate_image_list()
│   ├── Add docker image
│   ├── Add k3d images (k3d, k3d-proxy, k3d-tools)
│   └── Add k3s image
└── format_output() [mapping or list format]
```

### Template System

Currently **no templates are used** - all manifests are generated inline in `generate_deployment()` and related functions. Future enhancement may move these to `templates/` directory.

### Configuration Propagation

```
Command-line args → parse_args()
                    ↓
BASH Variables (INSTANCE_NAME, NAMESPACE, etc.)
                    ↓
generate_deployment() & generate_*() functions
                    ↓
Kubernetes Manifests (YAML with substituted variables)
                    ↓
kubectl apply
                    ↓
Running pod with environment variables + ConfigMaps + Secrets
```

---

## Important Environment Variables

### Instance-Level Variables (in Kubernetes Manifest)

Set in the Deployment spec's env section:

| Variable | Value | Used By | Purpose |
|----------|-------|---------|---------|
| `DOCKER_HOST` | `unix:///var/run/docker.sock` | k3d container | Connect to Docker daemon |
| `K3D_IMAGE_LOADBALANCER` | `${RESOLVED_K3D_TOOLS_IMAGE}` | k3d binary | Override loadbalancer image |
| `K3D_IMAGE_TOOLS` | `${RESOLVED_K3D_TOOLS_IMAGE}` | k3d binary | Override tools image |
| `K3D_IMAGE_REGISTRY` | `${RESOLVED_K3D_TOOLS_IMAGE}` | k3d binary | Override registry image |

### Script-Level Variables (in install.sh)

These control behavior during manifest generation:

| Variable | Default | Purpose |
|----------|---------|---------|
| `K3S_VERSION` | `v1.32.9+k3s1` | K3s cluster version |
| `K3D_VERSION` | `v5.8.3` | k3d tool version |
| `K3D_TOOLS_VERSION` | `5.8.3` | k3d helper images version |
| `DOCKER_VERSION` | `27-dind` | Docker DinD image tag |
| `ACCESS_METHOD` | `nodeport` | How to expose the API (nodeport/loadbalancer/ingress) |
| `NODEPORT` | `30443` | K8s NodePort number (if using NodePort) |
| `WAIT_TIMEOUT` | `300` | Pod readiness wait timeout in seconds |
| `PRIVATE_REGISTRY` | Empty | Private registry URL for airgap deployments |
| `REGISTRY_PATH` | Empty | Path prefix within private registry |
| `REGISTRY_INSECURE` | `false` | Allow insecure (HTTP) registry |
| `REGISTRY_SECRET` | Empty | K8s secret name for registry authentication |
| `CPU_LIMIT` | `2` | Pod CPU limit |
| `MEMORY_LIMIT` | `4Gi` | Pod memory limit |
| `CPU_REQUEST` | `1` | Pod CPU request (reservation) |
| `MEMORY_REQUEST` | `2Gi` | Pod memory request |

### k3d CLI Arguments (Generated in Manifest)

Built in the k3d container and passed to `k3d cluster create`:

```bash
K3D_ARGS="--api-port 0.0.0.0:6443"              # API endpoint
K3D_ARGS="$K3D_ARGS --servers 1 --agents 0"     # 1 server (control plane), 0 agents
K3D_ARGS="$K3D_ARGS --no-lb"                    # Don't create internal load balancer
K3D_ARGS="$K3D_ARGS --wait"                     # Wait for cluster ready
K3D_ARGS="$K3D_ARGS --timeout 5m"               # Creation timeout
K3D_ARGS="$K3D_ARGS --k3s-arg '--tls-san=...'" # TLS SANs for certificates
K3D_ARGS="$K3D_ARGS --image=${RESOLVED_K3S_IMAGE}"  # K3s server image
K3D_ARGS="$K3D_ARGS --k3s-arg '--disable=traefik'"  # No Traefik (use your own ingress)
K3D_ARGS="$K3D_ARGS --k3s-arg '--disable=servicelb'"  # No service LB (use K8s LB)
K3D_ARGS="$K3D_ARGS --registry-config /tmp/registries.yaml"  # Private registry config
K3D_ARGS="$K3D_ARGS --k3s-arg '--system-default-registry=<registry>'"  # System image registry
```

---

## Common Gotchas & Pitfalls

### 1. **Privileged Pods Required**

**Issue**: Deployment fails with `CrashLoopBackOff` or Docker daemon won't start

**Cause**: DinD (Docker-in-Docker) requires privileged security context, but some clusters restrict privileged pods

**Solution**:
```bash
# Check if privileged pods are allowed
kubectl auth can-i create pods --as=system:serviceaccount:default:default

# If using Pod Security Policies or Pod Security Standards, add exceptions
# The installer adds pod-security.kubernetes.io/enforce: privileged labels to namespace
```

**Note**: OpenShift requires SecurityContextConstraints instead:
```bash
oc adm policy add-scc-to-user privileged -z default -n k3s-dev
```

### 2. **Storage Class Must Exist**

**Issue**: Installation fails with "No storage class found"

**Cause**: Cluster has no default StorageClass or specified class doesn't exist

**Solution**:
```bash
# List storage classes
kubectl get storageclass

# If none exist, create one (example for local storage)
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/local
EOF

# Or specify explicitly
./install.sh --name dev --storage-class fast-ssd
```

### 3. **Private Registry: registries.yaml Not Found**

**Issue** (Recently Fixed): When using `--private-registry` without `--registry-secret`, deployment fails with `registries.yaml: no such file or directory`

**Root Cause** (BUG_FIX_SUMMARY.md): The `cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml` command was inside the `if [[ -n "$REGISTRY_SECRET" ]]` block, so it only ran when auth was configured. But k3d ALWAYS uses `--registry-config /tmp/registries.yaml` when a private registry is set.

**Solution**: Move the file copy outside the secret conditional (already fixed in current version)

### 4. **Docker Daemon Not Ready in Time**

**Issue**: Pod logs show "Docker is not ready" even after 60-second wait

**Cause**: Extremely slow disk I/O or resource contention

**Solution**:
```bash
# Increase pod resources
./install.sh --name dev --cpu-request 2 --memory-request 4Gi

# Check node disk speed
kubectl top nodes

# Or increase wait timeout
./install.sh --name dev --wait-timeout 600  # 10 minutes
```

### 5. **NodePort Already in Use**

**Issue**: Service creation fails: "port 30443 is already allocated"

**Solution**:
```bash
# Check what's using the port
kubectl get svc --all-namespaces | grep 30443

# Use a different port
./install.sh --name dev --nodeport 30444

# Or use LoadBalancer instead
./install.sh --name dev --access-method loadbalancer
```

### 6. **Ingress Hostname Resolution Fails**

**Issue**: Can't connect to k3s API at ingress hostname

**Causes**:
- DNS not configured (need A record pointing to ingress IP)
- Ingress controller not installed
- Ingress TLS not configured

**Solution**:
```bash
# Get ingress IP
kubectl get ingress -n k3s-dev k3s-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Add to /etc/hosts or DNS
echo "10.0.0.100 k3s-dev.example.com" >> /etc/hosts

# Verify with curl
curl -k https://k3s-dev.example.com/version
```

### 7. **Image Pull Errors with Private Registry**

**Issue**: Pod shows `ImagePullBackOff`, `ErrImagePull`, or `InvalidImageName`

**Causes**:
- Registry credentials not configured
- Wrong image path/version
- Network isolation (can't reach registry)

**Solution**:
```bash
# Create docker registry secret
kubectl create secret docker-registry regcred \
  --docker-server=docker.local \
  --docker-username=user \
  --docker-password=pass \
  -n k3s-dev

# Use it in install.sh
./install.sh --name dev \
  --private-registry docker.local \
  --registry-secret regcred

# Verify secret exists
kubectl get secret regcred -n k3s-dev
```

### 8. **kubectl Can't Connect to Inner Cluster**

**Issue**: `kubectl --kubeconfig=kubeconfigs/k3s-dev.yaml get nodes` hangs or times out

**Causes**:
- Inner cluster not fully initialized (readiness probe still waiting)
- Endpoint rewriting failed (kubeconfig points to wrong address)
- Network routing issue (NodePort/LoadBalancer not accessible)

**Solution**:
```bash
# Wait for pod to be fully ready
kubectl get pods -n k3s-dev -w

# Test raw API access
curl -k https://localhost:30443/version

# Re-extract kubeconfig
./manage.sh refresh-kubeconfig dev

# Check service details
kubectl get svc -n k3s-dev -o wide
```

### 9. **Pod Eviction on Node Resource Pressure**

**Issue**: Pod suddenly killed with "Evicted" status

**Cause**: Node running low on disk space, memory, or PVC filling up

**Solution**:
```bash
# Check PVC usage
kubectl describe pvc k3s-data -n k3s-dev

# Increase PVC size (if storage class supports expansion)
./install.sh --name dev --storage-size 50Gi

# Check node disk
kubectl describe node <node-name>

# Clean up old instances
./manage.sh delete-all
```

### 10. **TLS Certificate Errors**

**Issue**: `kubectl` shows: `x509: certificate signed by unknown authority`

**Cause**: Self-signed k3s certificates; kubeconfig has wrong endpoint

**Solution**:
```bash
# Ignore CA verification (insecure, for testing only)
kubectl --kubeconfig=k3s-dev.yaml --insecure-skip-tls-verify get nodes

# Or fix kubeconfig if endpoint is wrong
./manage.sh refresh-kubeconfig dev

# Get exact cert details
openssl s_client -connect localhost:30443 -showcerts
```

### 11. **Batch Installation Not Implemented**

**Issue**: `./install.sh --batch instances.yaml` fails with "Batch mode not yet implemented"

**Workaround**: Install instances individually in a loop

```bash
for name in dev staging prod; do
  ./install.sh --name $name --nodeport $((30443 + i++))
done
```

### 12. **Version Mismatch Errors**

**Issue**: "k3d-version does not match k3s-version" or similar

**Cause**: Using incompatible k3d and k3s versions

**Solution**: Keep versions synchronized

```bash
# Matching versions
K3D=v5.8.3
K3S=v1.32.9+k3s1

./install.sh --name dev --k3s-version $K3S \
  --k3d-image ghcr.io/k3d-io/k3d:${K3D#v}
```

---

## Key Files & Locations Summary

| File | Lines | Purpose | Key Functions |
|------|-------|---------|---|
| `install.sh` | 1291 | Main deployment | `main()`, `deploy_instance()`, `generate_deployment()` |
| `manage.sh` | 473 | Instance management | `cmd_list()`, `cmd_delete()`, `cmd_logs()` |
| `list-required-images.sh` | 366 | Image enumeration | `generate_image_list()`, `format_output()` |
| `mirror-images-to-nexus.sh` | ~400 | Image mirroring | Mirror logic, progress tracking |
| `.github/workflows/test.yml` | 181 | CI/CD pipeline | Lint, unit tests, integration tests |
| `examples/*.yaml` | Various | Config examples | Configuration patterns |
| `IMPLEMENTATION.md` | 785 | Detailed guide | Setup, troubleshooting, examples |
| `TROUBLESHOOTING.md` | 569 | Issue resolution | Common problems and fixes |

---

## Testing & Quality Assurance

### Test Suite Structure

Located in `tests/` directory:

1. **Unit Tests** (`test-registry-config.sh`)
   - Tests registry configuration YAML generation
   - Tests image path rewriting
   - Tests TLS configuration

2. **Integration Tests** (GitHub Actions)
   - Deploys to Kind cluster
   - Tests actual pod startup
   - Tests kubeconfig extraction
   - Tests management commands

3. **Airgap Tests** (`test-airgap-end-to-end.sh`)
   - Tests private registry workflow
   - Tests image mirroring
   - Tests authentication

4. **Linting** (Shellcheck)
   - Static analysis of all shell scripts
   - Checks for common shell script errors

### CI/CD Pipeline

GitHub Actions workflow (`.github/workflows/test.yml`):
- Runs on push to main/develop and on PRs
- Stages: Lint → Unit Tests → Integration Tests → Dry-Run Tests
- Generates artifacts: test results, logs, manifests

---

## Recent Major Features & Fixes

### Latest Versions

- **K3s**: v1.32.9+k3s1 (upgraded from v1.31.5)
- **K3d**: v5.8.3 (stable)
- **Docker**: 27-dind

### Recent Critical Fixes

1. **Registry Configuration File Bug** (BUG_FIX_SUMMARY.md)
   - Fixed missing `/tmp/registries.yaml` when using unauthenticated private registry
   - Impact: Private registry feature now works without credentials

2. **Registry Path Prefix Support** (IMPLEMENTATION.md)
   - Added `--registry-path` for enterprise registries with directory structure
   - Enables Artifactory/Nexus deployments with nested paths

3. **System Default Registry** (IMPLEMENTATION.md)
   - Uses k3s `--system-default-registry` for more reliable image handling
   - Fallback mirror configuration for better airgap support

---

## Quick Reference for Future Development

### Adding a New Command to manage.sh

1. Create `cmd_newcommand()` function
2. Parse arguments and find instance namespace
3. Execute kubectl command
4. Return 0 (success) or 1 (failure)
5. Add dispatch in `main()` case statement

### Modifying Deployment Manifest

1. Find corresponding `generate_*()` function in install.sh
2. Modify the heredoc to change YAML structure
3. Update `deploy_instance()` if adding new resources
4. Test with `--dry-run` flag first

### Adding New Configuration Option

1. Add variable declaration at top of install.sh
2. Add argument parsing in `parse_args()`
3. Add validation in `validate_config()`
4. Use variable in appropriate `generate_*()` function
5. Update `show_usage()` with new flag

---

## Performance Considerations

- **Initial Startup**: 90+ seconds (Docker daemon init takes time)
- **Pod Ready**: 300+ seconds (default timeout, configurable)
- **Storage I/O**: DinD disk usage grows with running containers in k3s
- **Memory**: DinD + k3d + k3s system overhead approximately 2-3Gi
- **Network**: Double NAT for service exposure (outer K8s → pod → inner k3s)

---

## Production Deployment Checklist

- [ ] Verify cluster supports privileged pods
- [ ] Ensure storage class exists and has fast I/O
- [ ] Set appropriate resource limits based on workload
- [ ] Configure private registry if airgapped
- [ ] Plan NodePort allocation or set up LoadBalancer/Ingress
- [ ] Set up monitoring for outer pod resource usage
- [ ] Configure RBAC if using non-admin kubeconfig
- [ ] Document instance naming convention
- [ ] Set up backup strategy for k3s-data PVC
- [ ] Test kubeconfig extraction and external access
- [ ] Validate network policies if present

---

**End of Architecture Guide**

For detailed implementation steps, see IMPLEMENTATION.md  
For troubleshooting, see TROUBLESHOOTING.md  
For quick start, see QUICKSTART.md
