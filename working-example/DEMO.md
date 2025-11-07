# K3s-in-MicroK8s Demonstration

## What Was Built

A complete nested Kubernetes setup where a k3s cluster runs inside a microk8s cluster, fully accessible from external kubectl clients.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ MicroK8s Cluster (Outer)                                    │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Namespace: k3s-inner                                   │ │
│  │                                                         │ │
│  │  ┌────────────────────────────────────────────────┐   │ │
│  │  │ Pod: k3s-xxxxx                                 │   │ │
│  │  │                                                 │   │ │
│  │  │  ┌──────────────┐    ┌───────────────────┐   │   │ │
│  │  │  │   DinD       │    │   k3d             │   │   │ │
│  │  │  │  Container   │<-->│  Container        │   │   │ │
│  │  │  │              │    │                   │   │   │ │
│  │  │  │ Docker       │    │  ┌─────────────┐ │   │   │ │
│  │  │  │ Daemon       │    │  │ K3s Cluster │ │   │   │ │
│  │  │  │              │    │  │ (Inner)     │ │   │   │ │
│  │  │  │              │    │  └─────────────┘ │   │   │ │
│  │  │  └──────────────┘    └───────────────────┘   │   │ │
│  │  │                                                 │   │ │
│  │  └────────────────────────────────────────────────┘   │ │
│  │                                                         │ │
│  │  Services:                                             │ │
│  │  - k3s-service (ClusterIP: 6443)                      │ │
│  │  - k3s-nodeport (NodePort: 30443)                     │ │
│  │                                                         │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ kubectl --kubeconfig=...
                           │ https://localhost:30443
                           ▼
                   External kubectl Client
```

## Cluster Comparison

### Outer Cluster (MicroK8s)
- **Node**: ubuntu-dev
- **Version**: v1.28.15
- **Runtime**: containerd 1.6.28
- **Access**: Default kubectl context

### Inner Cluster (K3s)
- **Node**: k3d-inner-server-0
- **Version**: v1.31.5+k3s1
- **Runtime**: containerd 1.7.23-k3s2
- **Access**: Via custom kubeconfig on port 30443

## Quick Start

### 1. Access the Inner Cluster

Run the helper script:
```bash
./k3s-nested/access-inner-k3s.sh
```

This will:
- Extract the kubeconfig from the pod
- Configure it for external access
- Save it to `k3s-nested/k3s-inner-kubeconfig.yaml`
- Test the connection

### 2. Use the Inner Cluster

```bash
# Set the KUBECONFIG environment variable
export KUBECONFIG=/home/jmann/git/mannjg/deployment-pipeline/k3s-nested/k3s-inner-kubeconfig.yaml

# Now kubectl commands target the inner k3s cluster
kubectl get nodes
kubectl get pods --all-namespaces
```

### 3. Deploy Applications

Deploy a test application in the inner k3s:
```bash
kubectl create deployment nginx --image=nginx:alpine
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get all
```

## Demonstration Results

### Successfully Tested

✅ **Deployment**: k3s cluster deployed inside microk8s pod
✅ **Networking**: Inner k3s API accessible via NodePort (30443)
✅ **kubectl Access**: External kubectl client can connect to inner cluster
✅ **Pod Deployment**: Test nginx pod successfully running in inner cluster

### Current Status

```
# Inner K3s Node
NAME                 STATUS   ROLES                  AGE   VERSION
k3d-inner-server-0   Ready    control-plane,master   7m    v1.31.5+k3s1

# Test Pod Running
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          6s
```

## Key Features

1. **Complete Isolation**: Inner k3s cluster is fully isolated within the microk8s namespace
2. **External Access**: Accessible via NodePort service on port 30443
3. **Persistent Storage**: Uses PVC for k3s data persistence
4. **Docker-in-Docker**: Uses DinD to enable container runtime inside pod
5. **k3d Management**: Leverages k3d for easy k3s cluster management

## Access Methods

### NodePort (Recommended)
```bash
kubectl --kubeconfig=k3s-nested/k3s-inner-kubeconfig.yaml get nodes
```

### Direct API Access
```bash
curl -k https://localhost:30443/version
```

### From Within MicroK8s
```bash
curl -k https://k3s-service.k3s-inner.svc.cluster.local:6443/version
```

## Files Created

- `k3s-nested/k3s-deployment.yaml` - Main deployment with DinD and k3d
- `k3s-nested/k3s-service.yaml` - ClusterIP service
- `k3s-nested/k3s-nodeport-service.yaml` - NodePort service (30443)
- `k3s-nested/k3s-ingress.yaml` - Ingress configuration
- `k3s-nested/access-inner-k3s.sh` - Helper script for easy access
- `k3s-nested/README.md` - Detailed documentation
- `k3s-nested/DEMO.md` - This demonstration guide

## Troubleshooting

### Check Pod Status
```bash
kubectl get pods -n k3s-inner
kubectl describe pod -n k3s-inner <pod-name>
```

### View Logs
```bash
# k3d container
kubectl logs -n k3s-inner -l app=k3s -c k3d

# DinD container
kubectl logs -n k3s-inner -l app=k3s -c dind
```

### Test Connectivity
```bash
# Test NodePort
curl -k https://localhost:30443/version

# Test from pod
kubectl exec -n k3s-inner <pod-name> -c k3d -- curl -k https://localhost:6443/version
```

## Next Steps

You can now:
1. Deploy applications in the inner k3s cluster
2. Test multi-cluster scenarios
3. Practice Kubernetes administration in an isolated environment
4. Develop and test operators or controllers
5. Create CI/CD pipelines that provision temporary clusters

## Clean Up

To remove everything:
```bash
kubectl delete namespace k3s-inner
```

This will delete:
- The k3s deployment
- All inner k3s cluster resources
- PersistentVolumeClaim
- Services and Ingress
