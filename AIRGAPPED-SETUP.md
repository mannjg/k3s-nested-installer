# Airgapped / Private Registry Setup

This guide explains how to deploy k3s-in-Kubernetes in airgapped environments or with private container registries.

## Overview

The k3s-in-Kubernetes solution uses several container images. For airgapped deployments, you need to:

1. Mirror all required images to your private registry
2. Use the custom image flags when installing

## Required Images

### 1. Docker-in-Docker (DinD)
- **Public image**: `docker:dind`
- **Purpose**: Runs the Docker daemon for k3d
- **Flag**: `--dind-image`

### 2. K3d CLI Tool
- **Public image**: `ghcr.io/k3d-io/k3d:v5.7.4` (check latest version)
- **Purpose**: Creates and manages the k3s cluster
- **Flag**: `--k3d-image`

### 3. K3s Server
- **Public image**: `rancher/k3s:v1.31.5-k3s1` (or your desired version)
- **Purpose**: The actual Kubernetes (k3s) server nodes
- **Flag**: `--k3s-image`

### 4. K3d Helper Containers
- **Public image**: `ghcr.io/k3d-io/k3d-proxy:v5.7.4` (match k3d version)
- **Purpose**: Proxy/loadbalancer, tools, and registry helpers
- **Flag**: `--k3d-tools-image`
- **Note**: This single flag controls three environment variables:
  - `K3D_IMAGE_LOADBALANCER` (proxy container)
  - `K3D_IMAGE_TOOLS` (initialization tools)
  - `K3D_IMAGE_REGISTRY` (optional registry helper)

## Step-by-Step Setup

### Step 1: Mirror Images to Your Registry

```bash
# Set your private registry
PRIVATE_REGISTRY="myregistry.company.com"

# Pull public images
docker pull docker:dind
docker pull ghcr.io/k3d-io/k3d:v5.7.4
docker pull rancher/k3s:v1.31.5-k3s1
docker pull ghcr.io/k3d-io/k3d-proxy:v5.7.4

# Tag for private registry
docker tag docker:dind ${PRIVATE_REGISTRY}/docker:dind
docker tag ghcr.io/k3d-io/k3d:v5.7.4 ${PRIVATE_REGISTRY}/k3d:v5.7.4
docker tag rancher/k3s:v1.31.5-k3s1 ${PRIVATE_REGISTRY}/k3s:v1.31.5-k3s1
docker tag ghcr.io/k3d-io/k3d-proxy:v5.7.4 ${PRIVATE_REGISTRY}/k3d-proxy:v5.7.4

# Push to private registry
docker push ${PRIVATE_REGISTRY}/docker:dind
docker push ${PRIVATE_REGISTRY}/k3d:v5.7.4
docker push ${PRIVATE_REGISTRY}/k3s:v1.31.5-k3s1
docker push ${PRIVATE_REGISTRY}/k3d-proxy:v5.7.4
```

### Step 2: Configure Image Pull Secrets (if needed)

If your private registry requires authentication, create an image pull secret:

```bash
kubectl create secret docker-registry regcred \
  --docker-server=${PRIVATE_REGISTRY} \
  --docker-username=<username> \
  --docker-password=<password> \
  --docker-email=<email> \
  -n k3s-dev
```

**Note**: The current installer doesn't automatically add imagePullSecrets to the deployment. You'll need to:

1. Use `--dry-run` to generate manifests
2. Manually add `imagePullSecrets` to the deployment spec
3. Apply manually, OR
4. Ensure your Kubernetes cluster has a default image pull secret configured

### Step 3: Install with Custom Images

```bash
PRIVATE_REGISTRY="myregistry.company.com"

./install.sh --name dev \
  --dind-image ${PRIVATE_REGISTRY}/docker:dind \
  --k3d-image ${PRIVATE_REGISTRY}/k3d:v5.7.4 \
  --k3s-image ${PRIVATE_REGISTRY}/k3s:v1.31.5-k3s1 \
  --k3d-tools-image ${PRIVATE_REGISTRY}/k3d-proxy:v5.7.4 \
  --access-method nodeport \
  --nodeport 30443
```

### Step 4: Verify

```bash
# Check pod status
kubectl get pods -n k3s-dev

# Check that correct images are being used
kubectl get pod -n k3s-dev -l app=k3s -o jsonpath='{.items[0].spec.containers[*].image}' | tr ' ' '\n'

# Should show your private registry images
```

## Troubleshooting

### Image Pull Errors

**Symptom**: `ImagePullBackOff` or `ErrImagePull`

**Solution**:
```bash
# Check events
kubectl get events -n k3s-dev --sort-by='.lastTimestamp'

# Check if secret exists
kubectl get secrets -n k3s-dev

# Verify image is accessible from cluster
kubectl run test --rm -it --image=${PRIVATE_REGISTRY}/docker:dind --restart=Never -- echo success
```

### k3d Still Trying to Pull Public Images

**Symptom**: Logs show attempts to pull from ghcr.io

**Solution**: Ensure you specified ALL four custom image flags, especially `--k3d-tools-image`

### Wrong Image Versions

**Symptom**: Version mismatches or compatibility errors

**Solution**: Ensure k3d and k3d-proxy versions match:
```bash
# Check k3d version
docker run --rm ${PRIVATE_REGISTRY}/k3d:v5.7.4 version

# k3d-proxy should be same version
```

## Version Compatibility

| K3s Version | K3d Version | Notes |
|-------------|-------------|-------|
| v1.31.x | v5.7.x | Recommended |
| v1.30.x | v5.6.x | Stable |
| v1.29.x | v5.6.x | Stable |

Always use matching versions for:
- `--k3d-image` and `--k3d-tools-image` (e.g., both v5.7.4)

## Example: Complete Airgapped Installation

```bash
#!/bin/bash

# Configuration
REGISTRY="harbor.company.internal"
K3D_VERSION="v5.7.4"
K3S_VERSION="v1.31.5-k3s1"
INSTANCE_NAME="production"

# Install
./install.sh \
  --name ${INSTANCE_NAME} \
  --dind-image ${REGISTRY}/docker:dind \
  --k3d-image ${REGISTRY}/k3d:${K3D_VERSION} \
  --k3s-image ${REGISTRY}/k3s:${K3S_VERSION} \
  --k3d-tools-image ${REGISTRY}/k3d-proxy:${K3D_VERSION} \
  --access-method ingress \
  --ingress-hostname k3s-${INSTANCE_NAME}.company.internal \
  --storage-size 50Gi \
  --cpu-limit 4 \
  --memory-limit 8Gi

# Verify installation
export KUBECONFIG=kubeconfigs/k3s-${INSTANCE_NAME}.yaml
kubectl get nodes
kubectl get pods --all-namespaces
```

## Security Considerations

1. **Image Scanning**: Scan all images for vulnerabilities before mirroring
2. **Image Signing**: Use image signing/verification if required by your policies
3. **Registry Access**: Limit who can push/pull images from your private registry
4. **Secret Management**: Securely store registry credentials
5. **Privileged Access**: Remember that DinD requires privileged containers (see TROUBLESHOOTING.md)

## Additional Resources

- [K3d Documentation](https://k3d.io)
- [K3s Documentation](https://docs.k3s.io)
- [Docker Hub - DinD](https://hub.docker.com/_/docker)
