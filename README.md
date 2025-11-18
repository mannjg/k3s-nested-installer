# K3s-in-Kubernetes Installer

Deploy fully functional k3s Kubernetes clusters inside any existing Kubernetes cluster, accessible via external kubectl.

## Overview

This installer deploys k3s clusters as pods within your existing Kubernetes cluster using Docker-in-Docker (DinD) and k3d. Each k3s instance runs in its own namespace and is fully accessible via kubectl using standard kubeconfig files.

### Key Features

- ✅ **Works on any Kubernetes cluster** - vanilla K8s, GKE, EKS, AKS, MicroK8s, Kind, etc.
- ✅ **Multiple access methods** - NodePort, LoadBalancer, or Ingress
- ✅ **Multi-instance support** - Run multiple isolated k3s clusters
- ✅ **Full kubectl access** - Standard kubeconfig-based access
- ✅ **Production-ready** - Configurable resources, storage, and security
- ✅ **Easy management** - Built-in CLI for managing instances
- ✅ **Well-documented** - Comprehensive guides and examples

### Use Cases

- 🔧 **Development**: Isolated k8s environments for each developer/team
- 🧪 **Testing**: Ephemeral clusters for CI/CD pipelines
- 🏢 **Multi-Tenancy**: Separate clusters per tenant/customer
- 📚 **Training**: Safe environments for learning Kubernetes
- 🔬 **Experimentation**: Test operators, controllers, and cluster configurations

## Quick Start

### Prerequisites

- Kubernetes cluster (1.24+) with kubectl access
- Cluster supports privileged pods
- Storage provisioner with dynamic PV provisioning
- (Optional) Ingress controller for Ingress access method

### Installation

```bash
# 1. Clone the installer
git clone <repo-url> k3s-nested-installer
cd k3s-nested-installer

# 2. Deploy a k3s instance
./install.sh --name dev

# 3. Access your k3s cluster
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml
kubectl get nodes

# 4. Deploy something
kubectl create deployment nginx --image=nginx:alpine
kubectl get pods
```

That's it! You now have a fully functional k3s cluster.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Your Existing Kubernetes Cluster                            │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Namespace: k3s-{instance-name}                         │ │
│  │                                                         │ │
│  │  ┌────────────────────────────────────────────────┐   │ │
│  │  │ Pod: k3s Deployment                            │   │ │
│  │  │                                                 │   │ │
│  │  │  [DinD Container]  ◄──────►  [k3d Container]  │   │ │
│  │  │         │                           │          │   │ │
│  │  │         └────── Docker ─────────────┤          │   │ │
│  │  │                                     │          │   │ │
│  │  │                           ┌─────────▼────────┐ │   │ │
│  │  │                           │  K3s Cluster     │ │   │ │
│  │  │                           │  v1.31.5+k3s1    │ │   │ │
│  │  │                           └──────────────────┘ │   │ │
│  │  └────────────────────────────────────────────────┘   │ │
│  │                                                         │ │
│  │  Exposed via: NodePort | LoadBalancer | Ingress       │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ kubectl --kubeconfig=...
                           ▼
                   Your Local Machine
```

## Documentation

| Document | Purpose |
|----------|---------|
| **[IMPLEMENTATION.md](IMPLEMENTATION.md)** | Complete step-by-step implementation guide |
| **[REGISTRY.md](REGISTRY.md)** | Private registry and airgap deployment |
| **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** | Common issues and solutions |
| **[TESTING.md](TESTING.md)** | Test procedures and validation |
| **[claude.md](claude.md)** | Technical architecture reference (for developers) |
| **[examples/](examples/)** | Configuration examples for different scenarios |

## Usage

### Basic Commands

```bash
# Deploy a single instance with defaults
./install.sh --name dev

# Deploy with custom configuration
./install.sh --name staging --nodeport 30444 --storage-size 20Gi

# Deploy using LoadBalancer
./install.sh --name prod --access-method loadbalancer

# Deploy using Ingress
./install.sh --name dev --access-method ingress --ingress-hostname k3s-dev.example.com

# Deploy from config file
./install.sh --config examples/single-instance.yaml
```

### Management Commands

```bash
# List all k3s instances
./manage.sh list

# Access a specific instance
./manage.sh access dev

# Show detailed status
./manage.sh status dev

# Refresh kubeconfig
./manage.sh refresh-kubeconfig dev

# Execute kubectl command on instance
./manage.sh exec dev -- get pods --all-namespaces

# View logs
./manage.sh logs dev

# Delete an instance
./manage.sh delete dev

# Show resource usage
./manage.sh resources
```

### Accessing Your K3s Cluster

After installation, your kubeconfig is saved in `kubeconfigs/`:

```bash
# Method 1: Export KUBECONFIG
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml
kubectl get nodes

# Method 2: Use --kubeconfig flag
kubectl --kubeconfig=./kubeconfigs/k3s-dev.yaml get nodes

# Method 3: Use the management script
./manage.sh access dev
```

## Configuration Options

### Command Line Arguments

```bash
./install.sh \
  --name <instance-name>         # Required: instance identifier
  --namespace <namespace>        # Optional: k8s namespace (default: k3s-{name})
  --k3s-version <version>        # Optional: k3s version (default: latest)
  --storage-size <size>          # Optional: PVC size (default: 10Gi)
  --storage-class <class>        # Optional: storage class (default: cluster default)
  --access-method <method>       # Optional: nodeport|loadbalancer|ingress
  --nodeport <port>              # Optional: port number (default: 30443)
  --ingress-hostname <hostname>  # Required if using ingress
  --cpu-limit <cpu>              # Optional: CPU limit (default: 2)
  --memory-limit <memory>        # Optional: memory limit (default: 4Gi)
```

### Configuration File

Create a YAML configuration file:

```yaml
instance:
  name: mydev
  namespace: k3s-mydev

k3s:
  version: v1.31.5-k3s1

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

Then install:

```bash
./install.sh --config my-config.yaml
```

## Access Methods Comparison

| Method | Pros | Cons | Best For |
|--------|------|------|----------|
| **NodePort** | ✅ Works everywhere<br>✅ Simple setup | ❌ Limited port range<br>❌ Manual port tracking | Development, small deployments |
| **LoadBalancer** | ✅ Clean external IP<br>✅ Standard ports | ❌ Requires cloud provider<br>❌ May incur costs | Production, cloud environments |
| **Ingress** | ✅ Hostname-based<br>✅ Single ingress controller<br>✅ Most scalable | ❌ Requires SSL passthrough<br>❌ DNS setup needed | Production, many instances |

## Examples

### Single Development Instance

```bash
./install.sh --name dev --nodeport 30443 --storage-size 5Gi
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml
kubectl create namespace myapp
```

### Multiple Environments

```bash
# Development
./install.sh --name dev --nodeport 30443 --storage-size 5Gi

# Staging
./install.sh --name staging --nodeport 30444 --storage-size 10Gi

# Production
./install.sh --name prod --access-method loadbalancer --storage-size 50Gi

# List all
./manage.sh list
```

### Production with Ingress

```bash
# Deploy
./install.sh \
  --name prod \
  --access-method ingress \
  --ingress-hostname k3s-prod.example.com \
  --storage-size 50Gi \
  --storage-class fast-ssd \
  --cpu-limit 4 \
  --memory-limit 8Gi

# Setup DNS
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# Create DNS A record: k3s-prod.example.com -> $INGRESS_IP

# Access
export KUBECONFIG=./kubeconfigs/k3s-prod.yaml
kubectl get nodes
```

## Multiple Instances

You can run multiple k3s instances simultaneously:

```bash
# Deploy three instances
./install.sh --name dev --nodeport 30443
./install.sh --name staging --nodeport 30444
./install.sh --name prod --access-method loadbalancer

# List all instances
./manage.sh list

# Output:
# NAME      NAMESPACE      STATUS    AGE    ACCESS
# dev       k3s-dev        Running   10m    NodePort:30443
# staging   k3s-staging    Running   5m     NodePort:30444
# prod      k3s-prod       Running   2m     LoadBalancer:203.0.113.10

# Access each instance
./manage.sh access dev
./manage.sh access staging
./manage.sh access prod
```

## Verification

After installation, verify your k3s cluster:

```bash
# 1. Check outer cluster resources
kubectl get all -n k3s-dev

# 2. Check pod is running
kubectl get pods -n k3s-dev
# Should show: k3s-xxxxx   2/2   Running

# 3. Access inner k3s
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml

# 4. Verify inner cluster
kubectl cluster-info
kubectl get nodes -o wide
kubectl get namespaces

# 5. Deploy test workload
kubectl create deployment nginx --image=nginx:alpine
kubectl get pods -w
```

## Resource Requirements

### Minimum Per Instance

- **CPU**: 1 core (request), 2 cores (limit)
- **Memory**: 2Gi (request), 4Gi (limit)
- **Storage**: 5Gi
- **Ports**: 1 NodePort (if using NodePort access)

### Recommended for Production

- **CPU**: 2 cores (request), 4 cores (limit)
- **Memory**: 4Gi (request), 8Gi (limit)
- **Storage**: 20-50Gi
- **Storage Class**: Fast SSD-backed storage

## Limitations & Considerations

### Known Limitations

1. **Privileged Pods Required**: Cluster must allow privileged pods for DinD
2. **Performance Overhead**: Additional layer adds ~10-15% overhead
3. **Networking Complexity**: Double NAT for exposing inner services
4. **Single Node**: Each instance runs on one node (not HA by default)

### Best Practices

1. **Resource Allocation**: Don't over-provision - start small and scale up
2. **Storage**: Use fast storage classes for better performance
3. **Monitoring**: Monitor both outer and inner cluster resources
4. **Cleanup**: Delete unused instances to free resources
5. **Backups**: Regular backups of k3s data PVC

## Troubleshooting

Common issues and solutions:

### Pod Won't Start

```bash
# Check pod status
kubectl describe pod -n k3s-dev -l app=k3s

# Check logs
kubectl logs -n k3s-dev -l app=k3s -c k3d
kubectl logs -n k3s-dev -l app=k3s -c dind

# Common causes:
# - Privileged pods not allowed
# - Storage class not available
# - Insufficient resources
```

### Can't Connect with kubectl

```bash
# Refresh kubeconfig
./manage.sh refresh-kubeconfig dev

# Test connectivity
curl -k https://localhost:30443/version

# Check service
kubectl get svc -n k3s-dev
```

See **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** for complete troubleshooting guide. For private registry/airgap issues, see **[REGISTRY.md](REGISTRY.md)**.

## Platform-Specific Notes

### Google Kubernetes Engine (GKE)

```bash
# May need specific node pool for privileged pods
# Or configure PodSecurityPolicy
```

### Amazon EKS

```bash
# LoadBalancer requires AWS Load Balancer Controller
# https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
```

### Azure AKS

```bash
# Use AKS-managed storage classes
./install.sh --name dev --storage-class managed-premium
```

### OpenShift

```bash
# Add SecurityContextConstraints
oc adm policy add-scc-to-user privileged -z default -n k3s-dev
```

See **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** for platform-specific details.

## Cleanup

Remove an instance:

```bash
./manage.sh delete dev
```

Remove all instances:

```bash
./manage.sh delete-all
```

## Advanced Topics

### Exposing Inner K3s Services

Services in the inner k3s need special handling to be externally accessible. See examples/ for detailed configurations.

### Backup and Restore

```bash
# Backup k3s data
kubectl cp k3s-dev/<pod-name>:/var/lib/rancher/k3s ./backup/ -c dind

# Restore: Deploy new instance and copy data back
```

### Custom K3s Configuration

Edit the generated manifest to add custom k3s server arguments:

```bash
./install.sh --dry-run --name dev > my-k3s.yaml
# Edit my-k3s.yaml to add custom k3s args
kubectl apply -f my-k3s.yaml
```

## Contributing

Contributions welcome! Areas for improvement:

- Additional platform testing and documentation
- Helm chart packaging
- GitOps integration examples
- Performance optimization
- HA multi-server support

## License

[Your License Here]

## Support

- **Issues**: [GitHub Issues URL]
- **Discussions**: [GitHub Discussions URL]
- **Documentation**: See IMPLEMENTATION.md

## Credits

Built with:
- [k3s](https://k3s.io/) - Lightweight Kubernetes
- [k3d](https://k3d.io/) - k3s in Docker
- [Docker-in-Docker](https://hub.docker.com/_/docker) - DinD

---

**Made with ❤️ for the Kubernetes community**
