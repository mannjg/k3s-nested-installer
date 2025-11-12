# Custom DNS Configuration for Test Environment

## Overview

This directory contains tools to configure CoreDNS for resolving ingress hostnames in test environments. This makes the test environment DNS behave like production, where wildcard DNS (e.g., `*.mydomain.com`) routes to an external ingress controller.

**Problem:** K3s pods running inside the outer Kubernetes cluster need to resolve external hostnames like `docker.local` to pull images from the Nexus registry through ingress.

**Solution:** Configure CoreDNS to resolve `*.local` domains to the ingress controller IP, mimicking production wildcard DNS behavior.

## Why This Matters

In production environments:
- Applications use public DNS (e.g., `registry.mydomain.com`)
- DNS resolves to external load balancer
- Traffic routes through ingress to services

In our test environment:
- K3s pods (nested clusters) run inside the outer Kubernetes cluster
- Pods can't use `/etc/hosts` entries from the host machine
- Need DNS to resolve `docker.local` → ingress controller → Nexus service
- This mimics production behavior for realistic testing

## Architecture

```
Production Environment:                 Test Environment:
┌─────────────────────┐                ┌─────────────────────┐
│ *.mydomain.com      │                │ *.local domains     │
│     ↓               │                │     ↓               │
│ External DNS        │                │ CoreDNS (hosts)     │
│     ↓               │                │     ↓               │
│ Load Balancer       │                │ Ingress Controller  │
│     ↓               │                │     ↓               │
│ Ingress             │                │ Services            │
└─────────────────────┘                └─────────────────────┘
```

## Files in This Directory

- **`configure-dns.sh`** - Automated DNS configuration script
- **`verify-dns.sh`** - Verification and testing script
- **`coredns-ingress-dns.yaml`** - Manual ConfigMap template
- **`README.md`** - This file
- **`backups/`** - Directory for CoreDNS configuration backups (auto-created)

## Quick Start

### Automated Setup (Recommended)

```bash
# 1. Configure DNS
./configure-dns.sh

# 2. Verify configuration
./verify-dns.sh
```

### Manual Setup

```bash
# 1. Find your ingress controller IP
kubectl get pod -n ingress -l name=nginx-ingress-microk8s -o wide

# 2. Edit coredns-ingress-dns.yaml
# Update all IP addresses to match your ingress controller IP

# 3. Backup current config
kubectl get configmap coredns -n kube-system -o yaml > backups/coredns-backup.yaml

# 4. Apply configuration
kubectl apply -f coredns-ingress-dns.yaml

# 5. Wait for reload (automatic, ~5 seconds)
sleep 5

# 6. Verify
./verify-dns.sh
```

## Usage Guide

### 1. Initial Configuration

Run the automated configuration script:

```bash
cd auxiliary/dns
./configure-dns.sh
```

**What it does:**
- Detects ingress controller IP automatically
- Backs up current CoreDNS configuration
- Applies new configuration with custom DNS entries
- Waits for CoreDNS to reload
- Verifies DNS resolution

**Expected output:**
```
[INFO] Detecting ingress controller IP...
[SUCCESS] Found ingress controller at: 10.1.153.25
[INFO] Backing up current CoreDNS configuration...
[SUCCESS] Backup saved to: auxiliary/dns/backups/coredns-backup-20250111-120000.yaml
[INFO] Generating CoreDNS configuration with ingress DNS entries...
configmap/coredns configured
[SUCCESS] CoreDNS configuration applied successfully
[INFO] Waiting for CoreDNS to reload configuration...
[SUCCESS] CoreDNS reloaded successfully
[INFO] Verifying DNS resolution...
[SUCCESS] DNS resolution test passed!
Name:      docker.local
Address 1: 10.1.153.25

[SUCCESS] ═══════════════════════════════════════════════════════════
[SUCCESS]   CoreDNS configuration completed successfully!
[SUCCESS] ═══════════════════════════════════════════════════════════
```

### 2. Verification

Run the verification script to check DNS is working:

```bash
./verify-dns.sh
```

For detailed output:

```bash
./verify-dns.sh --verbose
```

**What it checks:**
- CoreDNS pods are healthy
- CoreDNS configuration has hosts entries
- Ingress controller is accessible
- Each hostname resolves correctly
- DNS works from test pods

### 3. Dry Run

Preview changes without applying:

```bash
./configure-dns.sh --dry-run
```

### 4. Rollback

Restore previous CoreDNS configuration:

```bash
./configure-dns.sh --rollback
```

## Configured Domains

After configuration, these domains resolve to the ingress controller:

- **`docker.local`** → Nexus Docker registry
- **`gitlab.local`** → GitLab
- **`nexus.local`** → Nexus Repository Manager
- **`jenkins.local`** → Jenkins
- **`argocd.local`** → ArgoCD

All domains resolve to the same ingress controller IP (e.g., `10.1.153.25`), and the ingress controller routes traffic to the appropriate backend service based on the hostname.

## Testing DNS Resolution

### From Command Line

```bash
# Quick test
kubectl run test-dns --image=busybox:1.28 --rm -it --restart=Never \
  --command -- nslookup docker.local

# Expected output:
# Server:    10.152.183.10
# Address 1: 10.152.183.10 kube-dns.kube-system.svc.cluster.local
#
# Name:      docker.local
# Address 1: 10.1.153.25
```

### From Existing Pod

```bash
# Get a pod name
POD=$(kubectl get pod -n k3s-test -l app=k3s -o name | head -1)

# Test DNS from inside the pod
kubectl exec -n k3s-test $POD -c k3d -- nslookup docker.local
```

### From K3s Inner Cluster

```bash
# Use the inner cluster kubeconfig
kubectl --kubeconfig=../../kubeconfigs/k3s-test.yaml \
  run test-dns --image=busybox:1.28 --rm -it --restart=Never \
  --command -- nslookup docker.local
```

## Troubleshooting

### DNS Resolution Fails

**Symptom:** `nslookup docker.local` returns `NXDOMAIN` or wrong IP

**Solutions:**

1. Check CoreDNS configuration:
   ```bash
   kubectl get configmap coredns -n kube-system -o yaml
   ```
   Look for the `hosts {` section with IP addresses.

2. Verify ingress controller IP hasn't changed:
   ```bash
   kubectl get pod -n ingress -o wide
   ```
   If IP changed, re-run `./configure-dns.sh`

3. Check CoreDNS pods are running:
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   ```

4. Force CoreDNS reload:
   ```bash
   kubectl rollout restart deployment/coredns -n kube-system
   ```

### CoreDNS Pods Not Ready

**Symptom:** CoreDNS pods stuck in `CrashLoopBackOff` or not ready

**Solution:**

1. Check CoreDNS logs:
   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns
   ```

2. Syntax error in Corefile? Rollback:
   ```bash
   ./configure-dns.sh --rollback
   ```

3. Restore from backup manually:
   ```bash
   ls -lt backups/
   kubectl apply -f backups/coredns-backup-YYYYMMDD-HHMMSS.yaml
   ```

### Ingress Controller IP Changed

**Symptom:** DNS was working but now fails

**Solution:**

Ingress controller IP can change if pods are rescheduled.

```bash
# Check current IP
kubectl get pod -n ingress -o wide

# Reconfigure DNS with new IP
./configure-dns.sh
```

### DNS Works But Registry Access Fails

**Symptom:** `docker.local` resolves but can't pull images

**Possible causes:**

1. Ingress not configured correctly:
   ```bash
   kubectl get ingress -n nexus
   ```

2. TLS certificate issues:
   ```bash
   curl -v https://docker.local/v2/
   ```

3. Nexus service not running:
   ```bash
   kubectl get pods -n nexus
   kubectl get svc -n nexus
   ```

## Production Deployment Considerations

When deploying to production clusters:

1. **Use External DNS:** Production clusters should use real DNS (external-dns, Route53, CloudDNS, etc.) instead of CoreDNS hosts entries.

2. **Wildcard Certificates:** Ensure TLS certificates cover wildcard domains (e.g., `*.mydomain.com`).

3. **Load Balancer:** Production should use external load balancers, not pod IPs.

4. **High Availability:** Multiple ingress controller replicas with proper load balancing.

5. **DNS Caching:** Consider DNS TTL and caching policies for your environment.

## Alternative Approaches

This solution uses CoreDNS hosts plugin (95% production similarity). Other options:

### Pod-Level hostAliases (60% similarity)

Add to pod spec:
```yaml
spec:
  hostAliases:
  - ip: "10.1.153.25"
    hostnames:
    - "docker.local"
```

**Pros:** Pod-level control
**Cons:** Not global, must add to every pod

### CoreDNS Rewrite Plugin (90% similarity)

For true wildcards:
```
rewrite name regex (.+)\.local {1}.local
```

**Pros:** Wildcard support
**Cons:** More complex

### External-DNS (85% similarity)

Automated DNS from ingress annotations.

**Pros:** Production-grade
**Cons:** Requires DNS server, more setup

## Configuration Details

### CoreDNS Hosts Plugin

The hosts plugin in CoreDNS works like `/etc/hosts`:
- Static hostname-to-IP mappings
- Checked before forwarding to upstream DNS
- `fallthrough` ensures normal DNS still works

### Reload Behavior

CoreDNS automatically reloads when ConfigMap changes:
- No pod restart required
- Takes ~5 seconds to pick up changes
- Uses inotify to watch ConfigMap

### Performance Impact

Minimal:
- Hosts plugin is very fast (local lookup)
- No external DNS queries for matched hosts
- Cache remains effective for other lookups

## Backup and Recovery

Backups are automatically created:
- Location: `auxiliary/dns/backups/`
- Format: `coredns-backup-YYYYMMDD-HHMMSS.yaml`
- Retention: Manual cleanup

To restore:
```bash
# List backups
ls -lt backups/

# Restore specific backup
kubectl apply -f backups/coredns-backup-20250111-120000.yaml

# Or use automated rollback
./configure-dns.sh --rollback
```

## Integration with k3s-nested-installer

This DNS configuration is a **prerequisite** for airgapped k3s deployments:

1. **Configure DNS first:**
   ```bash
   cd auxiliary/dns
   ./configure-dns.sh
   ./verify-dns.sh
   ```

2. **Then mirror images:**
   ```bash
   cd ../..
   ./mirror-images-to-nexus.sh --registry docker.local
   ```

3. **Deploy k3s cluster:**
   ```bash
   ./install.sh --name test \
     --private-registry docker.local \
     --registry-secret nexus-docker-creds
   ```

## Support and Troubleshooting

For issues or questions:

1. Run verification with verbose output:
   ```bash
   ./verify-dns.sh --verbose
   ```

2. Check CoreDNS logs:
   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
   ```

3. Review backup configurations:
   ```bash
   ls -lh backups/
   ```

4. Consult main project documentation:
   - `../../AIRGAP-NEXUS-SETUP.md`
   - `../../TROUBLESHOOTING.md`

## References

- [CoreDNS Documentation](https://coredns.io/manual/toc/)
- [CoreDNS Hosts Plugin](https://coredns.io/plugins/hosts/)
- [Kubernetes DNS](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [K3s Nested Installer Main README](../../README.md)
