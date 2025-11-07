# Quick Start Guide

Get a k3s cluster running inside your Kubernetes cluster in 3 minutes.

## Prerequisites Check

```bash
# 1. Check kubectl access
kubectl cluster-info

# 2. Check you can create namespaces
kubectl auth can-i create namespaces

# 3. Check for storage provisioner
kubectl get storageclass
```

If all checks pass, you're ready to go!

## Method 1: Fastest Start (NodePort)

```bash
# Install
./install.sh --name dev

# Access
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml
kubectl get nodes

# Deploy something
kubectl create deployment nginx --image=nginx:alpine
kubectl get pods
```

**Done!** Your k3s cluster is running at `https://localhost:30443`

## Method 2: LoadBalancer (Cloud)

```bash
# Install
./install.sh --name prod --access-method loadbalancer

# Get external IP
kubectl get svc -n k3s-prod k3s-loadbalancer

# Access
export KUBECONFIG=./kubeconfigs/k3s-prod.yaml
kubectl get nodes
```

## Method 3: Ingress (Most Scalable)

```bash
# Setup DNS first
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$INGRESS_IP k3s-dev.example.com" | sudo tee -a /etc/hosts

# Install
./install.sh \
  --name dev \
  --access-method ingress \
  --ingress-hostname k3s-dev.example.com

# Access
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml
kubectl get nodes
```

## Common Next Steps

### Deploy an Application

```bash
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml

# Create namespace
kubectl create namespace myapp

# Deploy
kubectl create deployment web --image=nginx:alpine -n myapp
kubectl expose deployment web --port=80 --type=NodePort -n myapp

# Check
kubectl get all -n myapp
```

### Run Multiple Instances

```bash
# Dev
./install.sh --name dev --nodeport 30443

# Staging
./install.sh --name staging --nodeport 30444

# Prod
./install.sh --name prod --nodeport 30445

# List all
./manage.sh list

# Switch between them
./manage.sh access dev
./manage.sh access staging
./manage.sh access prod
```

### Customize Resources

```bash
./install.sh \
  --name bigcluster \
  --cpu-limit 4 \
  --memory-limit 8Gi \
  --storage-size 50Gi
```

## Verification

```bash
# Check outer cluster
kubectl get all -n k3s-dev

# Check inner cluster
export KUBECONFIG=./kubeconfigs/k3s-dev.yaml
kubectl cluster-info
kubectl get nodes
kubectl get pods --all-namespaces
```

## Management Commands

```bash
# List all instances
./manage.sh list

# Get status
./manage.sh status dev

# View logs
./manage.sh logs dev

# Refresh kubeconfig
./manage.sh refresh-kubeconfig dev

# Delete instance
./manage.sh delete dev
```

## Troubleshooting

### Pod not starting?

```bash
kubectl describe pod -n k3s-dev -l app=k3s
kubectl logs -n k3s-dev -l app=k3s -c k3d
```

### Can't connect?

```bash
# Refresh kubeconfig
./manage.sh refresh-kubeconfig dev

# Test connectivity
curl -k https://localhost:30443/version
```

### Need help?

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for detailed solutions.

## What's Next?

- **Configuration**: See [IMPLEMENTATION.md](IMPLEMENTATION.md) for detailed configuration options
- **Examples**: Check `examples/` directory for different scenarios
- **Advanced**: Learn about multi-tenancy, backups, and production deployment

Happy clustering! 🚀
