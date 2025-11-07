# Troubleshooting Guide

Common issues and their solutions when deploying k3s-in-Kubernetes.

## Table of Contents

- [Installation Issues](#installation-issues)
- [Pod Startup Problems](#pod-startup-problems)
- [Connectivity Issues](#connectivity-issues)
- [Performance Problems](#performance-problems)
- [Storage Issues](#storage-issues)
- [Platform-Specific Issues](#platform-specific-issues)

---

## Installation Issues

### Error: "Insufficient permissions: cannot create namespaces"

**Cause**: Your kubectl context doesn't have sufficient RBAC permissions.

**Solution**:
```bash
# Check your permissions
kubectl auth can-i create namespaces

# If using a ServiceAccount, ensure it has cluster-admin or appropriate Role
kubectl create clusterrolebinding myuser-admin \
  --clusterrole=cluster-admin \
  --user=myuser@example.com
```

### Error: "No storage class found"

**Cause**: Cluster doesn't have a default StorageClass or the specified class doesn't exist.

**Solution**:
```bash
# List available storage classes
kubectl get storageclass

# Set a default if none exists
kubectl patch storageclass <name> \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Or specify a storage class explicitly
./install.sh --name dev --storage-class standard
```

### Error: "NodePort 30443 is already in use"

**Cause**: Another service is using the requested NodePort.

**Solution**:
```bash
# Find what's using the port
kubectl get svc --all-namespaces | grep 30443

# Use a different port
./install.sh --name dev --nodeport 30444

# Or remove the conflicting service
kubectl delete svc <service-name> -n <namespace>
```

---

## Pod Startup Problems

### Pod stuck in "ContainerCreating"

**Check**:
```bash
kubectl describe pod -n k3s-dev -l app=k3s
```

**Common Causes**:

1. **PVC not binding**
   ```bash
   kubectl get pvc -n k3s-dev

   # If pending, check events
   kubectl describe pvc k3s-data -n k3s-dev

   # Solution: Ensure storage provisioner is working
   kubectl get storageclass
   kubectl get pv
   ```

2. **Image pull issues**
   ```bash
   # Check image pull status
   kubectl get events -n k3s-dev --sort-by='.lastTimestamp'

   # If image not found, check image name
   kubectl get deployment k3s -n k3s-dev -o yaml | grep image:

   # Solution: Use specific image version
   ./install.sh --name dev --k3s-version v1.31.5-k3s1
   ```

3. **Privileged pods not allowed**
   ```bash
   # Check pod security policies
   kubectl get psp

   # For OpenShift, add SecurityContextConstraints
   oc adm policy add-scc-to-user privileged \
     -z default -n k3s-dev
   ```

### Pod CrashLoopBackOff

**Diagnose**:
```bash
# Check logs for both containers
kubectl logs -n k3s-dev -l app=k3s -c dind --tail=50
kubectl logs -n k3s-dev -l app=k3s -c k3d --tail=50

# Check previous logs if pod restarted
kubectl logs -n k3s-dev -l app=k3s -c k3d --previous
```

**Common Issues**:

1. **Docker daemon failed to start**
   ```bash
   # Check dind logs
   kubectl logs -n k3s-dev -l app=k3s -c dind

   # If cgroup errors, the cluster may not support privileged pods
   # Solution: Check with cluster admin about pod security policies
   ```

2. **k3d cluster creation timeout**
   ```bash
   # Check k3d logs
   kubectl logs -n k3s-dev -l app=k3s -c k3d

   # If timeout creating cluster, may need more time
   # Solution: Increase readiness probe timeout
   kubectl patch deployment k3s -n k3s-dev --type='json' \
     -p='[{"op": "replace", "path": "/spec/template/spec/containers/1/readinessProbe/initialDelaySeconds", "value":90}]'
   ```

3. **Out of memory**
   ```bash
   # Check if pod was OOMKilled
   kubectl get pod -n k3s-dev -l app=k3s -o jsonpath='{.items[0].status.containerStatuses[*].lastState.terminated.reason}'

   # Solution: Increase memory limits
   ./install.sh --name dev --memory-limit 6Gi --memory-request 3Gi
   ```

### Pod Running but not Ready (0/2 or 1/2)

**Check**:
```bash
# See which container isn't ready
kubectl get pod -n k3s-dev -l app=k3s

# Check readiness probe
kubectl describe pod -n k3s-dev -l app=k3s | grep -A 10 Readiness
```

**Solution**:
```bash
# Check if kubeconfig was generated
POD=$(kubectl get pod -n k3s-dev -l app=k3s -o name)
kubectl exec -n k3s-dev $POD -c k3d -- ls -la /output/

# If kubeconfig missing, k3d cluster creation may have failed
kubectl logs -n k3s-dev -l app=k3s -c k3d --tail=100
```

---

## Connectivity Issues

### Cannot connect with kubectl

**Error**: `Unable to connect to the server: dial tcp <ip>:<port>: i/o timeout`

**Diagnose**:
```bash
# Test basic connectivity
curl -k https://localhost:30443/version

# If that works, the issue is with kubeconfig
cat kubeconfigs/k3s-dev.yaml | grep server:

# Refresh kubeconfig
./manage.sh refresh-kubeconfig dev
```

**Solutions**:

1. **Wrong server URL**
   ```bash
   # For NodePort, should be localhost:<nodeport>
   # For LoadBalancer, should be external IP
   # For Ingress, should be hostname

   # Fix manually
   kubectl --kubeconfig=kubeconfigs/k3s-dev.yaml config view

   # Update server URL
   kubectl --kubeconfig=kubeconfigs/k3s-dev.yaml config set-cluster <cluster-name> \
     --server=https://localhost:30443
   ```

2. **LoadBalancer IP pending**
   ```bash
   kubectl get svc -n k3s-dev k3s-loadbalancer

   # If EXTERNAL-IP shows <pending>, LoadBalancer provisioning failed
   # Check cloud provider or MetalLB configuration
   kubectl describe svc -n k3s-dev k3s-loadbalancer
   ```

3. **Ingress not working**
   ```bash
   # Check ingress status
   kubectl get ingress -n k3s-dev
   kubectl describe ingress k3s-ingress -n k3s-dev

   # Verify ingress controller has SSL passthrough enabled
   kubectl get deployment -n ingress-nginx ingress-nginx-controller -o yaml | grep ssl-passthrough

   # Test DNS resolution
   nslookup k3s-dev.example.com

   # Add to /etc/hosts temporarily
   INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   echo "$INGRESS_IP k3s-dev.example.com" | sudo tee -a /etc/hosts
   ```

### Certificate errors

**Error**: `x509: certificate is valid for <hostnames>, not <your-hostname>`

**Cause**: TLS certificate doesn't include your access hostname.

**Solution**:
```bash
# Reinstall with correct TLS SANs
./install.sh --name dev --nodeport 30443

# For custom hostnames, modify deployment to add TLS SANs
# Edit k3d cluster create command to include:
# --k3s-arg "--tls-san=your-custom-hostname@server:0"
```

---

## Performance Problems

### Slow pod startup

**Causes**:
- Image pulling
- Storage provisioning
- Resource constraints

**Solutions**:
```bash
# 1. Pre-pull images (if possible)
kubectl run --rm -it preload --image=ghcr.io/k3d-io/k3d:latest -- echo "Pulled"
kubectl run --rm -it preload --image=docker:dind -- echo "Pulled"

# 2. Increase resource allocation
./install.sh --name dev --cpu-limit 4 --memory-limit 8Gi

# 3. Use faster storage class
kubectl get storageclass
./install.sh --name dev --storage-class fast-ssd

# 4. Check cluster resource availability
kubectl top nodes
kubectl describe node <node-name>
```

### Inner k3s cluster slow

**Check resource usage**:
```bash
# Outer cluster resources
kubectl top pod -n k3s-dev

# Inner cluster resources
export KUBECONFIG=kubeconfigs/k3s-dev.yaml
kubectl top nodes
kubectl top pods --all-namespaces
```

**Solutions**:
```bash
# Increase resource limits
./install.sh --name dev --cpu-limit 4 --memory-limit 8Gi

# Check for resource quotas
kubectl describe resourcequota -n k3s-dev

# Reduce inner cluster overhead (disable unnecessary components)
# Edit deployment to add k3s args:
# --disable-cloud-controller
# --disable-network-policy
```

---

## Storage Issues

### PVC stuck in Pending

**Diagnose**:
```bash
kubectl describe pvc k3s-data -n k3s-dev
kubectl get events -n k3s-dev --field-selector involvedObject.name=k3s-data
```

**Common Causes**:

1. **No storage provisioner**
   ```bash
   kubectl get storageclass
   # Should show at least one with (default)

   # Install local-path provisioner if needed
   kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
   ```

2. **Node selector not matching**
   ```bash
   # Check if PVC has node selectors
   kubectl get pvc k3s-data -n k3s-dev -o yaml | grep -A 5 selector

   # Check available nodes
   kubectl get nodes --show-labels
   ```

3. **Insufficient disk space**
   ```bash
   # Check node disk usage
   kubectl get nodes -o custom-columns=NAME:.metadata.name,DISK-PRESSURE:.status.conditions[?(@.type==\"DiskPressure\")].status
   ```

### Storage full / Out of space

**Check usage**:
```bash
# From outer cluster
kubectl exec -n k3s-dev <pod-name> -c dind -- df -h

# Clean up Docker in DinD
kubectl exec -n k3s-dev <pod-name> -c dind -- docker system prune -af
```

**Increase storage**:
```bash
# Delete and recreate with more storage
./manage.sh delete dev
./install.sh --name dev --storage-size 50Gi
```

---

## Platform-Specific Issues

### Google Kubernetes Engine (GKE)

**Issue**: Privileged pods blocked

**Solution**:
```bash
# GKE requires specific node pool configuration
# Create node pool with privileges:
gcloud container node-pools create privileged-pool \
  --cluster=my-cluster \
  --enable-autoupgrade \
  --enable-autorepair \
  --machine-type=n1-standard-4 \
  --num-nodes=1

# Or enable on existing cluster (less secure)
# Create PodSecurityPolicy and bind it
```

### Amazon EKS

**Issue**: LoadBalancer not provisioning

**Solution**:
```bash
# Ensure AWS Load Balancer Controller is installed
kubectl get deployment -n kube-system aws-load-balancer-controller

# Install if missing
# See: https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
```

### Azure AKS

**Issue**: Storage class not binding

**Solution**:
```bash
# Use AKS-specific storage class
kubectl get storageclass

# Use managed-premium or azurefile
./install.sh --name dev --storage-class managed-premium
```

### OpenShift

**Issue**: Security Context Constraints (SCC) blocking privileged pods

**Solution**:
```bash
# Add SCC to service account
oc adm policy add-scc-to-user privileged -z default -n k3s-dev

# Or create custom SCC
oc create -f - <<EOF
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: k3s-scc
allowPrivilegedContainer: true
allowHostDirVolumePlugin: true
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
fsGroup:
  type: RunAsAny
EOF

# Bind to service account
oc adm policy add-scc-to-user k3s-scc -z default -n k3s-dev
```

### MicroK8s

**Issue**: Privileged pods work but networking issues

**Solution**:
```bash
# Ensure required addons are enabled
microk8s enable dns storage

# If using ingress
microk8s enable ingress
```

---

## Getting Help

### Collect diagnostic information

```bash
# 1. Outer cluster resources
kubectl get all -n k3s-dev
kubectl describe pod -n k3s-dev -l app=k3s

# 2. Events
kubectl get events -n k3s-dev --sort-by='.lastTimestamp'

# 3. Logs
kubectl logs -n k3s-dev -l app=k3s -c dind --tail=100 > dind.log
kubectl logs -n k3s-dev -l app=k3s -c k3d --tail=100 > k3d.log

# 4. Configuration
./manage.sh status dev

# 5. Cluster info
kubectl cluster-info dump --namespaces k3s-dev --output-directory=cluster-dump
```

### Common kubectl commands for debugging

```bash
# Watch pod status
kubectl get pods -n k3s-dev -w

# Exec into container
kubectl exec -n k3s-dev <pod-name> -c k3d -it -- /bin/sh

# Check container logs with timestamp
kubectl logs -n k3s-dev <pod-name> -c k3d --timestamps

# Get previous container logs (after crash)
kubectl logs -n k3s-dev <pod-name> -c k3d --previous

# Check resource usage
kubectl top pod -n k3s-dev
kubectl top node

# Network debugging
kubectl run -n k3s-dev -it --rm debug --image=nicolaka/netshoot --restart=Never -- /bin/bash
```

---

## FAQ

**Q: Can I run k3s-in-k3s-in-Kubernetes?**

A: Yes! K3s inside k3s inside another cluster works. Each nesting level requires its own resources.

**Q: How do I upgrade the inner k3s version?**

A: Delete and recreate the instance with a newer version:
```bash
./manage.sh delete dev
./install.sh --name dev --k3s-version v1.32.0-k3s1
```

**Q: Can I use this in production?**

A: While technically possible, consider:
- Performance overhead of nested virtualization
- Additional complexity in troubleshooting
- Resource overhead
- Use cases like multi-tenancy might be better served by proper RBAC and namespaces

**Q: How do I expose services from inner k3s to external clients?**

A: You need double-exposure:
1. Service in inner k3s (e.g., NodePort)
2. Service in outer cluster forwarding to that port
   See examples for details.

**Q: Does this work with Istio/service mesh?**

A: Yes, but configuration is complex. The service mesh needs to be aware of the nested cluster's network topology.

---

For more help, check:
- GitHub Issues: [repository-url]
- Community Forums: [forum-url]
- Documentation: IMPLEMENTATION.md
