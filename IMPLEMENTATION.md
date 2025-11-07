# K3s-in-Kubernetes Implementation Guide

This guide walks you through deploying one or more k3s clusters inside an existing Kubernetes cluster, with full external access via kubectl.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Detailed Installation Steps](#detailed-installation-steps)
5. [Multi-Instance Deployment](#multi-instance-deployment)
6. [Access Methods](#access-methods)
7. [Configuration Reference](#configuration-reference)
8. [Post-Installation](#post-installation)
9. [Advanced Topics](#advanced-topics)

---

## Overview

### What This Does

Deploys a fully functional k3s Kubernetes cluster running inside a pod within your existing Kubernetes cluster. Each k3s instance:

- Runs in its own namespace
- Has its own API server accessible externally
- Supports standard Kubernetes workloads
- Is isolated from other k3s instances
- Can be accessed via kubectl with custom kubeconfig

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Existing Kubernetes Cluster (Any Distribution)              │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Namespace: k3s-{instance-name}                         │ │
│  │                                                         │ │
│  │  ┌────────────────────────────────────────────────┐   │ │
│  │  │ Pod: k3s-{instance-name}                       │   │ │
│  │  │                                                 │   │ │
│  │  │  [DinD Container] + [k3d Container]           │   │ │
│  │  │         │                    │                  │   │ │
│  │  │         └──── Docker ────────┤                  │   │ │
│  │  │                              │                  │   │ │
│  │  │                    ┌─────────▼────────┐       │   │ │
│  │  │                    │  K3s Cluster     │       │   │ │
│  │  │                    │  API: 6443       │       │   │ │
│  │  │                    └──────────────────┘       │   │ │
│  │  └────────────────────────────────────────────────┘   │ │
│  │                                                         │ │
│  │  Access via:                                           │ │
│  │  • NodePort (e.g., 30XXX)                             │ │
│  │  • LoadBalancer (cloud providers)                      │ │
│  │  • Ingress (hostname-based)                           │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ kubectl --kubeconfig=...
                           ▼
                   Your Local Machine
```

### Use Cases

- **Development Environments**: Isolated k8s clusters for each developer/team
- **CI/CD**: Ephemeral clusters for testing
- **Multi-Tenancy**: Separate clusters per tenant
- **Training**: Safe environments for learning Kubernetes
- **Testing**: Test cluster upgrades, operators, or manifests

---

## Prerequisites

### Required

1. **Kubernetes Cluster Access**
   - kubectl configured and working
   - Cluster version: 1.24+ recommended
   - RBAC enabled

2. **Permissions**
   - Create namespaces
   - Create deployments, services, PVCs
   - Create ingress resources (if using Ingress access method)

3. **Cluster Capabilities**
   - Support for privileged pods (required for DinD)
   - Storage provisioner with dynamic PV provisioning
   - Ingress controller (only if using Ingress access method)

4. **Local Tools**
   - `kubectl` (v1.24+)
   - `bash` (4.0+)
   - Standard utilities: `sed`, `grep`, `curl`

### Optional but Recommended

- `yq` or `jq` for YAML/JSON processing
- Helm 3 (if you want to package as Helm chart)

### Cluster Compatibility

Tested and verified on:
- ✅ Vanilla Kubernetes 1.24+
- ✅ MicroK8s
- ✅ K3s (yes, k3s in k3s!)
- ✅ GKE (Google Kubernetes Engine)
- ✅ EKS (Amazon Elastic Kubernetes Service)
- ✅ AKS (Azure Kubernetes Service)
- ✅ Kind
- ⚠️ OpenShift (requires SecurityContextConstraints modification)

---

## Quick Start

### Single Instance - Default Configuration

```bash
# 1. Download the installer
git clone <repo-url> k3s-nested-installer
cd k3s-nested-installer

# 2. Run the installer with defaults
./install.sh --name dev

# 3. Access your k3s cluster
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml
kubectl get nodes
```

That's it! You now have a k3s cluster accessible via kubectl.

### Multiple Instances

```bash
# Deploy dev, staging, and prod instances
./install.sh --name dev --nodeport 30443
./install.sh --name staging --nodeport 30444
./install.sh --name prod --nodeport 30445

# List all instances
./manage.sh list

# Access specific instance
./manage.sh access dev
kubectl get nodes
```

---

## Detailed Installation Steps

### Step 1: Verify Prerequisites

```bash
# Check kubectl access
kubectl cluster-info

# Check for dynamic storage provisioner
kubectl get storageclass

# Check for ingress controller (if using Ingress)
kubectl get ingressclass

# Verify you can create privileged pods (test in a temp namespace)
kubectl create namespace test-privileged
kubectl run test --image=alpine --rm -it --restart=Never \
  --overrides='{"spec":{"securityContext":{"privileged":true}}}' \
  -- echo "Privileged pods are supported"
kubectl delete namespace test-privileged
```

### Step 2: Download and Prepare Installer

```bash
# Clone or download the installer package
git clone <repo-url> k3s-nested-installer
cd k3s-nested-installer

# Make scripts executable
chmod +x install.sh manage.sh

# Review the example configurations
cat examples/single-instance.yaml
```

### Step 3: Configure Your Instance

**Option A: Command Line Arguments (Quick)**

```bash
./install.sh \
  --name mydev \
  --namespace k3s-mydev \
  --nodeport 30443 \
  --k3s-version v1.31.5-k3s1 \
  --storage-size 10Gi
```

**Option B: Configuration File (Recommended)**

Create a config file `my-instance.yaml`:

```yaml
# Instance configuration
instance:
  name: mydev
  namespace: k3s-mydev

# K3s configuration
k3s:
  version: v1.31.5-k3s1
  serverArgs:
    - --disable=traefik
    - --disable=servicelb

# Resources
resources:
  storage:
    size: 10Gi
    storageClass: ""  # Empty means default
  limits:
    cpu: "2"
    memory: 4Gi
  requests:
    cpu: "1"
    memory: 2Gi

# Access method (choose one)
access:
  method: nodeport  # Options: nodeport, loadbalancer, ingress
  nodeport:
    port: 30443
  # loadbalancer: {}
  # ingress:
  #   hostname: k3s-mydev.example.com
  #   tlsSecret: ""
```

Then install:

```bash
./install.sh --config my-instance.yaml
```

### Step 4: Monitor Deployment

```bash
# Watch the deployment
kubectl get pods -n k3s-mydev -w

# Check logs if there are issues
kubectl logs -n k3s-mydev -l app=k3s -c k3d --tail=50
kubectl logs -n k3s-mydev -l app=k3s -c dind --tail=50

# The pod should reach 2/2 Running in 1-2 minutes
```

### Step 5: Extract and Configure Access

The installer automatically extracts the kubeconfig, but if you need to do it manually:

```bash
# Extract kubeconfig
POD_NAME=$(kubectl get pods -n k3s-mydev -l app=k3s -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n k3s-mydev $POD_NAME -c k3d -- cat /output/kubeconfig.yaml > k3s-mydev.yaml

# Update server URL based on access method
# For NodePort:
sed -i 's|https://0.0.0.0:6443|https://localhost:30443|g' k3s-mydev.yaml

# For LoadBalancer:
EXTERNAL_IP=$(kubectl get svc -n k3s-mydev k3s-loadbalancer -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
sed -i "s|https://0.0.0.0:6443|https://${EXTERNAL_IP}:6443|g" k3s-mydev.yaml

# For Ingress:
sed -i 's|https://0.0.0.0:6443|https://k3s-mydev.example.com|g' k3s-mydev.yaml
```

### Step 6: Test Access

```bash
# Set the kubeconfig
export KUBECONFIG=./kubeconfigs/k3s-mydev.yaml

# Verify connection
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods --all-namespaces

# Deploy a test application
kubectl create deployment nginx --image=nginx:alpine
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get all
```

Success! Your k3s cluster is now fully operational.

---

## Multi-Instance Deployment

### Planning Multiple Instances

When deploying multiple k3s instances, consider:

1. **Namespace Strategy**: One namespace per instance (recommended)
2. **Port Allocation**: Each NodePort needs a unique port (30000-32767)
3. **Resource Allocation**: Ensure cluster has enough CPU/memory
4. **Storage**: Each instance needs its own PVC
5. **Naming Convention**: Use consistent naming (e.g., k3s-dev, k3s-staging, k3s-prod)

### Deploying Multiple Instances

**Method 1: Sequential Installation**

```bash
# Install dev
./install.sh --name dev --nodeport 30443 --storage-size 5Gi

# Install staging
./install.sh --name staging --nodeport 30444 --storage-size 10Gi

# Install prod
./install.sh --name prod --nodeport 30445 --storage-size 20Gi
```

**Method 2: Batch Installation from Config**

Create `instances.yaml`:

```yaml
instances:
  - name: dev
    namespace: k3s-dev
    nodeport: 30443
    storage: 5Gi

  - name: staging
    namespace: k3s-staging
    nodeport: 30444
    storage: 10Gi

  - name: prod
    namespace: k3s-prod
    nodeport: 30445
    storage: 20Gi
```

```bash
# Install all instances
./install.sh --batch instances.yaml
```

### Managing Multiple Instances

```bash
# List all k3s instances
./manage.sh list

# Output:
# NAME      NAMESPACE     STATUS    AGE     ACCESS
# dev       k3s-dev       Running   10m     NodePort:30443
# staging   k3s-staging   Running   5m      NodePort:30444
# prod      k3s-prod      Running   2m      NodePort:30445

# Switch context to specific instance
./manage.sh use dev
kubectl get nodes

# Access specific instance without switching
./manage.sh exec staging -- kubectl get pods --all-namespaces

# Get kubeconfig for specific instance
./manage.sh kubeconfig prod > prod-kubeconfig.yaml
```

### Resource Monitoring

```bash
# View resource usage across all instances
./manage.sh resources

# Output per instance:
# INSTANCE  NAMESPACE    CPU      MEMORY    STORAGE
# dev       k3s-dev      0.5/2    1.2Gi/4Gi 2Gi/5Gi
# staging   k3s-staging  0.8/2    2.1Gi/4Gi 4Gi/10Gi
# prod      k3s-prod     1.2/2    3.5Gi/4Gi 8Gi/20Gi
```

---

## Access Methods

### NodePort (Default)

**Pros:**
- Works on any Kubernetes cluster
- No additional infrastructure required
- Easy to configure

**Cons:**
- Port range limited (30000-32767)
- Must track port assignments
- Not ideal for many instances

**Configuration:**

```yaml
access:
  method: nodeport
  nodeport:
    port: 30443  # Choose unused port
```

**Access:**
```bash
kubectl --kubeconfig=k3s-mydev.yaml --server=https://localhost:30443 get nodes
```

### LoadBalancer

**Pros:**
- Clean external IP
- Standard HTTPS port (443 or 6443)
- Better for production

**Cons:**
- Requires cloud provider or MetalLB
- May incur costs
- Limited by IP allocation

**Configuration:**

```yaml
access:
  method: loadbalancer
  loadbalancer:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"  # Example for AWS
```

**Access:**
```bash
# Get the external IP
kubectl get svc -n k3s-mydev k3s-loadbalancer

# Use it in kubeconfig
kubectl --kubeconfig=k3s-mydev.yaml --server=https://<EXTERNAL-IP>:6443 get nodes
```

### Ingress (Most Scalable)

**Pros:**
- Hostname-based routing
- Single ingress controller serves many instances
- Can use proper TLS certificates
- Most elegant solution

**Cons:**
- Requires ingress controller with SSL passthrough
- More complex configuration
- DNS setup needed

**Configuration:**

```yaml
access:
  method: ingress
  ingress:
    hostname: k3s-mydev.example.com
    ingressClass: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-passthrough: "true"
      nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    tls:
      enabled: true
      secretName: ""  # Optional: provide your own cert
```

**Setup DNS:**

```bash
# Get ingress IP
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Add to /etc/hosts or configure DNS
echo "$INGRESS_IP k3s-mydev.example.com" | sudo tee -a /etc/hosts
```

**Access:**
```bash
kubectl --kubeconfig=k3s-mydev.yaml --server=https://k3s-mydev.example.com get nodes
```

---

## Configuration Reference

### Complete Configuration Schema

```yaml
# Instance identification
instance:
  name: myinstance           # Required: unique instance name
  namespace: k3s-myinstance  # Optional: defaults to k3s-{name}
  labels: {}                 # Optional: custom labels for all resources

# K3s configuration
k3s:
  version: v1.31.5-k3s1     # Optional: specific k3s version
  image: rancher/k3s:latest  # Optional: override k3s image
  serverArgs:                # Optional: additional k3s server arguments
    - --disable=traefik
    - --disable=servicelb
    - --write-kubeconfig-mode=666
  tlsSans:                   # Optional: additional TLS SANs
    - k3s-custom.example.com

# Resource allocation
resources:
  storage:
    size: 10Gi              # PVC size
    storageClass: ""        # Empty = default, or specify class name
  dind:
    limits:
      cpu: "1"
      memory: 2Gi
    requests:
      cpu: "500m"
      memory: 1Gi
  k3d:
    limits:
      cpu: "2"
      memory: 4Gi
    requests:
      cpu: "1"
      memory: 2Gi

# Access configuration (choose one method)
access:
  method: nodeport          # Required: nodeport|loadbalancer|ingress

  nodeport:
    port: 30443             # Port number (30000-32767)

  loadbalancer:
    annotations: {}         # Cloud-specific annotations
    loadBalancerIP: ""      # Optional: request specific IP

  ingress:
    hostname: k3s.example.com     # Required for ingress
    ingressClass: nginx           # Ingress class to use
    annotations:                  # Ingress annotations
      nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    tls:
      enabled: true
      secretName: ""              # Optional: custom TLS secret

# Security
security:
  enableAnonymousAuth: false      # Disable anonymous API access
  podSecurityContext:
    fsGroup: 1000

# Advanced options
advanced:
  enableMetrics: false            # Install metrics-server in k3s
  installHelm: true               # Pre-install Helm in k3s
  preloadImages: []               # Images to preload
    # - nginx:alpine
    # - postgres:14
```

---

## Post-Installation

### Verification Checklist

```bash
# 1. Check outer cluster resources
kubectl get all -n k3s-mydev

# 2. Verify pod is running
kubectl get pods -n k3s-mydev
# Should show: k3s-xxxx   2/2   Running

# 3. Test inner k3s API
curl -k https://localhost:30443/version

# 4. Verify kubectl access
export KUBECONFIG=./kubeconfigs/k3s-mydev.yaml
kubectl get nodes
kubectl get pods --all-namespaces

# 5. Deploy test workload
kubectl create deployment test --image=nginx:alpine
kubectl get pods -w
```

### Initial Configuration

```bash
# Set default namespace
kubectl config set-context --current --namespace=default

# Create additional namespaces
kubectl create namespace myapp-dev
kubectl create namespace myapp-prod

# Set up RBAC (example)
kubectl create serviceaccount myapp
kubectl create clusterrolebinding myapp-admin \
  --clusterrole=admin \
  --serviceaccount=default:myapp
```

### Installing Additional Components

```bash
# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Install a simple ingress controller (traefik)
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v2.10/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml

# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

---

## Advanced Topics

### Exposing Inner K3s Services Externally

Services running in the inner k3s cluster need special handling to be externally accessible:

**Method 1: Port Forwarding (Development)**

```bash
# Forward from outer cluster to inner service
kubectl port-forward -n k3s-mydev svc/k3s-service 8080:6443

# Or use the manage script
./manage.sh port-forward mydev 8080:80 my-app-service
```

**Method 2: Double NodePort (Production)**

1. Service in inner k3s uses NodePort
2. Create service in outer cluster that forwards to inner NodePort

Example: See `examples/expose-service.yaml`

### Persistent Storage in Inner K3s

The inner k3s cluster has its own storage system:

```bash
# Check storage classes in inner k3s
export KUBECONFIG=./kubeconfigs/k3s-mydev.yaml
kubectl get storageclass

# Default: local-path provisioner
# This stores data in the inner k3s container filesystem
# Which is backed by the outer cluster PVC

# For production: Configure external storage CSI drivers
```

### Backup and Restore

```bash
# Backup inner k3s cluster data
./manage.sh backup mydev

# Creates: backups/k3s-mydev-20241106-120000.tar.gz

# Restore to a new instance
./install.sh --name mydev-restored --restore-from backups/k3s-mydev-20241106-120000.tar.gz
```

### Resource Limits and Quotas

Manage resources for k3s instances:

```bash
# View current resource usage
./manage.sh resources mydev

# Update resource limits (requires restart)
./manage.sh update mydev --cpu-limit 4 --memory-limit 8Gi

# Set ResourceQuota in outer namespace
kubectl create -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: k3s-mydev-quota
  namespace: k3s-mydev
spec:
  hard:
    pods: "100"
    requests.cpu: "4"
    requests.memory: 8Gi
    persistentvolumeclaims: "10"
EOF
```

### Monitoring and Logging

```bash
# View k3s container logs
kubectl logs -n k3s-mydev -l app=k3s -c k3d --tail=100

# Stream logs
kubectl logs -n k3s-mydev -l app=k3s -c k3d -f

# Get k3s events
kubectl get events -n k3s-mydev --sort-by='.lastTimestamp'

# Access metrics (if metrics-server installed)
kubectl top pods -n k3s-mydev
```

### Networking Deep Dive

Understanding the network layers:

```
External kubectl
       ↓
NodePort/LB/Ingress (Outer Cluster)
       ↓
k3s Pod (k3d container)
       ↓
k3d Proxy (Docker network)
       ↓
k3s API Server (Inner Cluster)
       ↓
Inner k3s Pods
```

### Cleanup and Removal

```bash
# Remove a single instance
./manage.sh delete mydev

# Or manually
kubectl delete namespace k3s-mydev

# Remove all k3s instances
./manage.sh delete-all

# Cleanup orphaned resources
./manage.sh cleanup
```

---

## Next Steps

1. **Review Examples**: Check `examples/` directory for common configurations
2. **Read TROUBLESHOOTING.md**: Familiarize yourself with common issues
3. **Explore Architecture**: Read `ARCHITECTURE.md` for deep dive
4. **Production Setup**: Review `examples/production.yaml` for production-grade configuration
5. **Integration**: See how to integrate with CI/CD pipelines

---

## Support and Contributing

- **Issues**: Report bugs and request features
- **Documentation**: Help improve this guide
- **Examples**: Share your configurations
- **Testing**: Test on different platforms

For questions and support, see the main README.md.
