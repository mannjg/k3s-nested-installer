# K3s Nested Inside MicroK8s

This setup deploys a k3s cluster running inside your microk8s cluster, accessible from external kubectl clients.

## Architecture

The setup consists of:
- **Namespace**: `k3s-inner` - Isolated namespace for the k3s deployment
- **Deployment**: Uses Docker-in-Docker (DinD) + k3d to create a k3s cluster inside a pod
  - DinD container: Runs the Docker daemon
  - k3d container: Uses k3d to create and manage the k3s cluster
- **Services**:
  - `k3s-service` (ClusterIP): Internal cluster access
  - `k3s-nodeport` (NodePort:30443): External access via NodePort
- **Ingress**: `k3s-ingress` (optional) for hostname-based access

## Deployment

All manifests are already applied. The k3s cluster is running in the `k3s-inner` namespace.

To view the deployment:
```bash
kubectl get all -n k3s-inner
```

## Accessing the Inner K3s Cluster

### 1. Extract the kubeconfig

The kubeconfig is stored inside the pod. To extract it:

```bash
POD_NAME=$(kubectl get pods -n k3s-inner -l app=k3s -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n k3s-inner $POD_NAME -c k3d -- cat /output/kubeconfig.yaml > k3s-inner-kubeconfig.yaml
```

### 2. Modify for external access

Update the server URL to use the NodePort:

```bash
sed -i 's/localhost:6443/localhost:30443/g' k3s-inner-kubeconfig.yaml
```

### 3. Use kubectl with the inner cluster

```bash
kubectl --kubeconfig=k3s-inner-kubeconfig.yaml get nodes
kubectl --kubeconfig=k3s-inner-kubeconfig.yaml get pods --all-namespaces
```

## Example Usage

```bash
# View the inner k3s cluster info
kubectl --kubeconfig=/tmp/k3s-external-kubeconfig.yaml cluster-info

# Get nodes in the inner cluster
kubectl --kubeconfig=/tmp/k3s-external-kubeconfig.yaml get nodes -o wide

# Deploy a test application
kubectl --kubeconfig=/tmp/k3s-external-kubeconfig.yaml run nginx --image=nginx:alpine --port=80

# Check the pod
kubectl --kubeconfig=/tmp/k3s-external-kubeconfig.yaml get pods
```

## Verification

Current setup verification results:

```
# Inner k3s node:
NAME                 STATUS   ROLES                  AGE   VERSION
k3d-inner-server-0   Ready    control-plane,master   5m    v1.31.5+k3s1

# Test pod deployed:
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          6s
```

## Access Methods

1. **NodePort (Recommended for external access)**:
   - URL: `https://localhost:30443`
   - Kubeconfig: Use the modified kubeconfig with port 30443

2. **ClusterIP (Internal only)**:
   - Service: `k3s-service.k3s-inner.svc.cluster.local:6443`
   - Only accessible from within the microk8s cluster

3. **Ingress (Optional)**:
   - Host: `k3s.local`
   - Requires DNS/hosts file entry pointing to your microk8s node IP

## Troubleshooting

### Check pod status
```bash
kubectl get pods -n k3s-inner
```

### View k3d container logs
```bash
kubectl logs -n k3s-inner -l app=k3s -c k3d
```

### View dind container logs
```bash
kubectl logs -n k3s-inner -l app=k3s -c dind
```

### Test API connectivity
```bash
curl -k https://localhost:30443/version
```

## Clean Up

To remove the k3s nested deployment:

```bash
kubectl delete namespace k3s-inner
```

Note: This will delete all resources in the k3s-inner namespace, including the inner k3s cluster.

## More Information

For complete documentation, see the parent directory:
- **[../README.md](../README.md)** - Project overview
- **[../IMPLEMENTATION.md](../IMPLEMENTATION.md)** - Full implementation guide
- **[../TROUBLESHOOTING.md](../TROUBLESHOOTING.md)** - Common issues and solutions
