# Deploying to a New Kubernetes Cluster

This guide walks you through deploying the k3s-in-Kubernetes installer to a brand new cluster.

## Prerequisites

Before starting, ensure you have:

- ✅ Access to a Kubernetes cluster (1.24+)
- ✅ kubectl installed and configured
- ✅ Cluster supports privileged pods
- ✅ Storage provisioner available
- ✅ (Optional) Ingress controller if using Ingress access

## Step 1: Transfer the Installer Package

### Option A: Git Clone (if in a repository)

```bash
git clone <your-repo-url> k3s-nested-installer
cd k3s-nested-installer
```

### Option B: Manual Copy

```bash
# On source machine
tar -czf k3s-installer.tar.gz k3s-nested-installer/

# Transfer to target machine (scp, rsync, etc.)
scp k3s-installer.tar.gz user@target-machine:/path/to/destination/

# On target machine
tar -xzf k3s-installer.tar.gz
cd k3s-nested-installer
```

### Option C: Direct Copy (if accessible)

```bash
cp -r /path/to/k3s-nested-installer /destination/path/
cd /destination/path/k3s-nested-installer
```

## Step 2: Verify Prerequisites

```bash
# Check kubectl connectivity
kubectl cluster-info

# Check cluster version
kubectl version --short

# Check for storage classes
kubectl get storageclass

# Check if you can create namespaces
kubectl auth can-i create namespaces

# Test privileged pod support
kubectl create namespace test-privileged
kubectl run test --image=alpine --rm -it --restart=Never \
  --overrides='{"spec":{"securityContext":{"privileged":true}}}' \
  -- echo "Success"
kubectl delete namespace test-privileged
```

If all checks pass, proceed to Step 3.

## Step 3: Choose Your Configuration

### Quick Start (Development)

Use defaults with NodePort access:

```bash
./install.sh --name dev
```

### Cloud Environment (LoadBalancer)

Best for GKE, EKS, AKS:

```bash
./install.sh --name prod --access-method loadbalancer
```

### Production (Ingress)

Most scalable, requires ingress controller:

```bash
# First, setup DNS or /etc/hosts
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$INGRESS_IP k3s.yourdomain.com" | sudo tee -a /etc/hosts

# Then install
./install.sh \
  --name prod \
  --access-method ingress \
  --ingress-hostname k3s.yourdomain.com
```

### Custom Configuration

Create a config file:

```yaml
# my-config.yaml
instance:
  name: myinstance
  namespace: k3s-myinstance

k3s:
  version: v1.31.5-k3s1

storage:
  size: 20Gi
  storageClass: ""  # Use default, or specify: fast-ssd

resources:
  cpu:
    limit: "3"
    request: "1.5"
  memory:
    limit: 6Gi
    request: 3Gi

access:
  method: nodeport
  nodeport:
    port: 30443
```

Then install:

```bash
./install.sh --config my-config.yaml
```

## Step 4: Monitor Deployment

```bash
# Watch the deployment
kubectl get pods -n k3s-<your-instance-name> -w

# If issues, check logs
kubectl logs -n k3s-<your-instance-name> -l app=k3s -c k3d
kubectl logs -n k3s-<your-instance-name> -l app=k3s -c dind

# Check events
kubectl get events -n k3s-<your-instance-name> --sort-by='.lastTimestamp'
```

The deployment typically takes 1-2 minutes. Wait for the pod to show `2/2 Running`.

## Step 5: Access Your K3s Cluster

The installer automatically creates a kubeconfig file:

```bash
# Set kubeconfig
export KUBECONFIG=./kubeconfigs/k3s-<your-instance-name>.yaml

# Verify access
kubectl cluster-info
kubectl get nodes -o wide

# Check namespaces
kubectl get namespaces
```

## Step 6: Verify Functionality

Deploy a test application:

```bash
# Deploy nginx
kubectl create deployment nginx --image=nginx:alpine

# Wait for pod
kubectl get pods -w

# Expose it
kubectl expose deployment nginx --port=80 --type=NodePort

# Check everything
kubectl get all
```

Success! Your k3s cluster is fully operational.

## Platform-Specific Instructions

### Google Kubernetes Engine (GKE)

```bash
# Connect to cluster
gcloud container clusters get-credentials <cluster-name> --zone <zone>

# Install with LoadBalancer (recommended)
./install.sh --name prod --access-method loadbalancer

# Note: May need specific node pool for privileged pods
# See TROUBLESHOOTING.md for details
```

### Amazon EKS

```bash
# Connect to cluster
aws eks update-kubeconfig --name <cluster-name> --region <region>

# Install with LoadBalancer
./install.sh --name prod --access-method loadbalancer

# Note: Ensure AWS Load Balancer Controller is installed
# https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
```

### Azure AKS

```bash
# Connect to cluster
az aks get-credentials --resource-group <rg> --name <cluster-name>

# Use AKS storage classes
kubectl get storageclass

# Install with specific storage class
./install.sh --name prod \
  --access-method loadbalancer \
  --storage-class managed-premium
```

### MicroK8s

```bash
# Ensure required addons are enabled
microk8s enable dns storage ingress

# Export kubeconfig
microk8s config > ~/.kube/microk8s-config
export KUBECONFIG=~/.kube/microk8s-config

# Install
./install.sh --name dev
```

### OpenShift

```bash
# Login to cluster
oc login <cluster-url>

# Add SecurityContextConstraints
oc adm policy add-scc-to-user privileged -z default -n k3s-dev

# Install
./install.sh --name dev
```

### Kind (Kubernetes in Docker)

```bash
# Create kind cluster if needed
kind create cluster --name test

# Install (NodePort works best with Kind)
./install.sh --name dev --nodeport 30443
```

## Multiple Instances

To deploy multiple k3s instances:

```bash
# Development
./install.sh --name dev --nodeport 30443 --storage-size 5Gi

# Staging
./install.sh --name staging --nodeport 30444 --storage-size 10Gi

# Production
./install.sh --name prod --access-method loadbalancer --storage-size 50Gi

# List all instances
./manage.sh list

# Access specific instance
./manage.sh access dev
./manage.sh access staging
./manage.sh access prod
```

## Common Issues During Deployment

### Issue: "Insufficient permissions"

```bash
# Check your permissions
kubectl auth can-i create namespaces
kubectl auth can-i create deployments
kubectl auth can-i create services

# If insufficient, contact cluster admin or use a service account with appropriate RBAC
```

### Issue: "No storage class found"

```bash
# List storage classes
kubectl get storageclass

# If none exist, install one:
# For local testing (hostPath)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# Set as default
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Issue: "Privileged pods not allowed"

```bash
# Check pod security policies
kubectl get psp

# For OpenShift
oc adm policy add-scc-to-user privileged -z default -n k3s-<name>

# For other platforms, consult platform documentation
# See TROUBLESHOOTING.md for platform-specific solutions
```

### Issue: "Pod stuck in Pending"

```bash
# Check pod status
kubectl describe pod -n k3s-<name> -l app=k3s

# Common causes:
# 1. No nodes available - check: kubectl get nodes
# 2. Resource constraints - check: kubectl top nodes
# 3. PVC not binding - check: kubectl get pvc -n k3s-<name>
```

### Issue: "Cannot connect with kubectl"

```bash
# Refresh kubeconfig
./manage.sh refresh-kubeconfig <name>

# Test basic connectivity
curl -k https://localhost:<nodeport>/version

# Check service
kubectl get svc -n k3s-<name>

# Verify pod is running
kubectl get pods -n k3s-<name>
```

For more issues, see **TROUBLESHOOTING.md**.

## Post-Deployment

### Recommended Next Steps

1. **Deploy Applications**: Start deploying your workloads
2. **Configure Monitoring**: Set up monitoring for both outer and inner clusters
3. **Backup Strategy**: Plan backup strategy for k3s data
4. **Documentation**: Document your specific configuration
5. **Team Access**: Share kubeconfig files with team members

### Example: Deploy a Full Application

```bash
export KUBECONFIG=./kubeconfigs/k3s-<name>.yaml

# Create namespace
kubectl create namespace myapp

# Deploy database
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: myapp
spec:
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:14-alpine
        env:
        - name: POSTGRES_PASSWORD
          value: secretpassword
        ports:
        - containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: myapp
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
EOF

# Deploy application
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: myapp
spec:
  type: NodePort
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF

# Check deployment
kubectl get all -n myapp
```

## Cleanup

To remove an instance:

```bash
./manage.sh delete <instance-name>
```

To remove all instances:

```bash
./manage.sh delete-all
```

## Support

If you encounter issues:

1. Check **TROUBLESHOOTING.md** for your platform
2. Review **IMPLEMENTATION.md** for detailed explanations
3. Use `./manage.sh status <name>` to diagnose
4. Collect logs: `./manage.sh logs <name>`
5. Check GitHub issues (if applicable)

## Success Criteria

You've successfully deployed when:

✅ Pod shows `2/2 Running` status
✅ Kubeconfig file exists in `kubeconfigs/`
✅ `kubectl get nodes` shows the k3s node
✅ You can deploy test workloads
✅ `./manage.sh list` shows your instance

---

**Next Steps**: Review IMPLEMENTATION.md for advanced configurations and best practices.

**Questions?**: See TROUBLESHOOTING.md or check the main README.md.
