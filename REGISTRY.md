# K3s-Nested-Installer: Registry and Airgap Support - Deep Dive Analysis

## Executive Summary

This k3s-nested-installer project has a sophisticated registry and airgap support system with two parallel mechanisms:

1. **Legacy Mode**: Individual `--dind-image`, `--k3d-image`, `--k3s-image`, `--k3d-tools-image` flags
2. **Modern Mode**: `--private-registry`, `--registry-path`, `--registry-secret`, `--registry-insecure` flags

The modern mode uses containerd mirror configuration and k3s's `--system-default-registry` for comprehensive registry substitution.

---

## 1. PRIVATE REGISTRY CONFIGURATION FLOW

### 1.1 Command-Line Flags

```
--private-registry URL          Main registry domain (e.g., docker.local, artifactory.com:5000)
--registry-path PREFIX          Path prefix (e.g., "docker-sandbox/jmann")
--registry-secret NAME          K8s secret name with .dockerconfigjson
--registry-insecure             Allow HTTP/skip TLS verification
```

### 1.2 Configuration Validation (install.sh:371-389)

```bash
# Validations performed:
- Registry secret requires --private-registry (line 372-374)
- Insecure flag requires --private-registry (line 376-378)
- Warnings if using secret without it being in target namespace (line 386-388)
```

### 1.3 Image Resolution Process (install.sh:397-470)

The `resolve_images()` function converts public image references to private registry paths:

**For Docker-in-Docker:**
- Public: `docker:27-dind`
- With registry: `docker.local/library/docker:27-dind`
- With registry + path: `docker.local/docker-sandbox/jmann/library/docker:27-dind`

**For K3d CLI:**
- Public: `ghcr.io/k3d-io/k3d:5.8.3`
- With registry: `docker.local/k3d-io/k3d:5.8.3`
- With registry + path: `docker.local/docker-sandbox/jmann/k3d-io/k3d:5.8.3`

**For K3s Server:**
- Public: `rancher/k3s:v1.32.9-k3s1`
- With registry: `docker.local/rancher/k3s:v1.32.9-k3s1`
- With registry + path: `docker.local/docker-sandbox/jmann/rancher/k3s:v1.32.9-k3s1`

**For K3d Tools/Helpers:**
- Public: `ghcr.io/k3d-io/k3d-tools:5.8.3`
- With registry: `docker.local/k3d-io/k3d-tools:5.8.3`
- With registry + path: `docker.local/docker-sandbox/jmann/k3d-io/k3d-tools:5.8.3`

### 1.4 Registry Path Preservation Logic

The path structure is preserved intelligently (install.sh:280-293 in list-required-images.sh):

```
Input: ghcr.io/k3d-io/k3d-tools:5.8.3
↓ Extract "k3d-io/k3d-tools" (removes explicit registry)
With path prefix: docker.local/docker-sandbox/jmann/k3d-io/k3d-tools:5.8.3
```

---

## 2. REGISTRIES.YAML CONFIGURATION

### 2.1 Template Structure (install.sh:517-570)

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.local"
    rewrite:
      "(.*)" : "docker-sandbox/jmann/$1"
  ghcr.io:
    endpoint:
      - "https://docker.local"
    rewrite:
      "(.*)" : "docker-sandbox/jmann/$1"
  registry.k8s.io:
    endpoint:
      - "https://docker.local"
    rewrite:
      "(.*)" : "docker-sandbox/jmann/$1"
configs:
  "docker.local":
    tls:
      insecure_skip_verify: false
```

### 2.2 Dynamic Generation Logic

**Protocol Selection** (install.sh:522-533):
- Default: HTTPS (`https://`)
- With `--registry-insecure`: HTTP (`http://`)
- TLS configuration:
  - Insecure: `insecure_skip_verify: true`
  - Secure: `insecure_skip_verify: false`

**Rewrite Rules** (install.sh:535-540):
- Only generated when `REGISTRY_PATH` is set
- Format: `"(.*)" : "path/$1"` (regex with capture group)
- This prepends the path to any image requested through the mirror

### 2.3 Containerd Mirror Flow

1. Pod requests: `docker.io/library/nginx:latest`
2. Containerd checks mirrors for `docker.io`
3. Finds endpoint: `https://docker.local`
4. Applies rewrite: `docker-sandbox/jmann/library/nginx:latest`
5. Requests from registry: `https://docker.local/docker-sandbox/jmann/library/nginx:latest`

---

## 3. IMAGE MIRRORING PROCESS

### 3.1 list-required-images.sh Overview

**Purpose**: Generate a mapping file of source→target images for the private registry

**Command**:
```bash
./list-required-images.sh --registry docker.local [--registry-path path] --output required-images.txt
```

**Output Format** (mapping mode):
```
docker:27-dind=docker.local/library/docker:27-dind
ghcr.io/k3d-io/k3d:5.8.3=docker.local/k3d-io/k3d:5.8.3
rancher/k3s:v1.32.9-k3s1=docker.local/rancher/k3s:v1.32.9-k3s1
rancher/mirrored-coredns-coredns:1.12.3=docker.local/rancher/mirrored-coredns-coredns:1.12.3
...
```

**Images Included** (list-required-images.sh:179-256):

1. **Infrastructure Images**:
   - docker:27-dind
   - ghcr.io/k3d-io/k3d (CLI tool)
   - rancher/k3s (server)
   - ghcr.io/k3d-io/k3d-proxy
   - ghcr.io/k3d-io/k3d-tools

2. **K3s Internal Components** (version-dependent):
   - v1.32: rancher/mirrored-coredns-coredns:1.12.3
   - v1.31: rancher/mirrored-coredns-coredns:1.12.0
   - v1.30: registry.k8s.io/coredns/coredns:v1.11.1
   - rancher/mirrored-metrics-server
   - rancher/mirrored-pause
   - rancher/local-path-provisioner

### 3.2 mirror-images-to-nexus.sh Process

**Purpose**: Actually push images from public registries to private registry

**Two Modes**:

**Mode 1: Insecure (--insecure flag)**
```bash
docker pull docker:27-dind
docker tag docker:27-dind docker.local/library/docker:27-dind
docker push docker.local/library/docker:27-dind
```
- Simple pull→tag→push workflow
- Works with daemon.json insecure-registries config
- Converts multi-arch manifests to host architecture only

**Mode 2: Secure (default)**
- Attempts to preserve multi-arch manifests using docker buildx
- Falls back to pull→tag→push for single-arch images
- Uses buildx imagetools create for multi-arch images

**Verification**:
- Uses `docker manifest inspect` to verify pushed images
- Can skip with `--skip-verify`

**Progress Tracking**:
- Reports successes, skips, and failures
- Generates report file with mirror results

### 3.3 mirror-images-sequential.sh

Simple variant for Nexus/overloaded registries:
```bash
./mirror-images-sequential.sh <registry> <input-file> [delay-seconds]
```
- Includes configurable delays between image pushes
- Prevents overwhelming the target registry
- Good for Nexus with default connection limits

---

## 4. THE --system-default-registry FLAG

### 4.1 Purpose and Behavior

**Flag**: `--k3s-arg '--system-default-registry=${PRIVATE_REGISTRY}@server:0'` (install.sh:833)

**What it does**:
- Makes k3s prepend the private registry to ALL unqualified image names
- Applies to system components (coredns, metrics-server, pause, etc.)
- Doesn't prepend if image already has a registry domain

**Examples**:
```
coredns:latest → docker.local/coredns:latest
rancher/local-path-provisioner:v0.0.31 → docker.local/rancher/local-path-provisioner:v0.0.31
library/nginx:latest → docker.local/library/nginx:latest
```

### 4.2 Interaction with Containerd Mirrors

Two complementary mechanisms:

1. **--system-default-registry**: Modifies image pull request at k3s level
   - Changes what k3s asks containerd to pull
   
2. **registries.yaml mirrors**: Containerd intercepts and redirects
   - Further remaps if mirror rules apply

**Combined Effect**:
- K3s requests: `docker.local/coredns:latest`
- Containerd applies no-op mirror (already has registry)
- Result: Pulls from docker.local directly

### 4.3 Why Both Are Needed

Without registries.yaml:
- Images with explicit registry domains (ghcr.io/k3d-io/k3d) don't get prepended
- These images won't be found on private registry
- Deployment fails

With registries.yaml mirrors:
- Intercepts requests for docker.io, ghcr.io, registry.k8s.io
- Redirects to private registry with rewrite rules
- Comprehensive coverage for system components

---

## 5. HTTP vs HTTPS HANDLING

### 5.1 Protocol Selection (install.sh:522-533)

**HTTPS Mode (default)**:
```yaml
endpoint:
  - "https://docker.local"
configs:
  "docker.local":
    tls:
      insecure_skip_verify: false
```

**HTTP Mode (--registry-insecure)**:
```yaml
endpoint:
  - "http://docker.local"
configs:
  "docker.local":
    tls:
      insecure_skip_verify: true
```

### 5.2 Use Cases

**HTTPS with Valid Certificate**:
- Recommended for production
- `insecure_skip_verify: false`
- Requires valid TLS cert from trusted CA

**HTTPS with Self-Signed Certificate**:
- Use `--registry-insecure` flag
- Sets `insecure_skip_verify: true` in registries.yaml
- Allows containerd to skip certificate validation

**HTTP (Insecure)**:
- Use `--registry-insecure` flag
- Changes endpoint protocol to `http://`
- Only for development/testing
- Requires Docker daemon to have registry in insecure-registries config

### 5.3 Docker Daemon Configuration

For insecure registries, Docker daemon needs configuration:
```json
{
  "insecure-registries": ["docker.local:5000"]
}
```

The installer passes this via command flag in dind container (install.sh:622-625):
```bash
dockerd \
  --insecure-registry=${PRIVATE_REGISTRY} \
  ...
```

---

## 6. REGISTRY AUTHENTICATION MECHANISMS

### 6.1 Docker Config Mount (install.sh:598-603, 643-689)

**Mechanism**:
1. Create K8s secret with registry credentials:
   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=docker.local \
     --docker-username=admin \
     --docker-password=admin123 \
     --docker-email=admin@example.com
   ```

2. Specify via `--registry-secret regcred`

3. Secret mounted as:
   - Location: `/tmp/docker-secret/config.json`
   - Mode: readOnly
   - Containers: Both `dind` and `k3d`

**Usage in dind container** (install.sh:646-655):
```bash
if [ -f /tmp/docker-secret/config.json ]; then
  mkdir -p /root/.docker
  cp /tmp/docker-secret/config.json /root/.docker/config.json
  chmod 600 /root/.docker/config.json
fi
```

**Usage in k3d container** (install.sh:720-743):
- Same mount and copy logic
- Pre-pulls images to verify credentials before extracting k3d binary
- Fails early if authentication fails

### 6.2 Secret Mounting Strategy

**Volume Definition** (install.sh:933-939):
```yaml
volumes:
- name: registry-secret
  secret:
    secretName: regcred
    items:
    - key: .dockerconfigjson
      path: config.json
```

**Key Points**:
- Uses `.dockerconfigjson` key (standard docker-registry secret key)
- Maps to `config.json` for compatibility with Docker
- Mounted readOnly for security
- Available to both dind and k3d containers

### 6.3 Pre-Pull Verification (install.sh:728-743)

Before extracting k3d binary, images are pulled to verify:

```bash
echo "Pre-pulling required images from private registry..."
if ! docker pull ${RESOLVED_K3S_IMAGE}; then
  echo "ERROR: Failed to pull k3s image"
  exit 1
fi
if ! docker pull ${RESOLVED_K3D_TOOLS_IMAGE}; then
  echo "ERROR: Failed to pull k3d tools image"
  exit 1
fi
```

**Why**: If credentials are wrong, fail fast before creating k3d cluster

---

## 7. --registry-insecure FLAG MECHANICS

### 7.1 Five Points of Insecure Configuration

1. **registries.yaml protocol** (install.sh:522-526):
   ```yaml
   endpoint:
     - "http://docker.local"  # HTTP instead of HTTPS
   ```

2. **registries.yaml TLS config** (install.sh:528-529):
   ```yaml
   tls:
     insecure_skip_verify: true
   ```

3. **Docker daemon flag** (install.sh:622-625):
   ```bash
   dockerd \
     --insecure-registry=${PRIVATE_REGISTRY} \
     ...
   ```

4. **Mirror rewrite applies to all three registries** (install.sh:553-565):
   - docker.io → http://docker.local with rewrite
   - ghcr.io → http://docker.local with rewrite
   - registry.k8s.io → http://docker.local with rewrite

5. **Containerd honors skip_verify** (containerd behavior):
   - Allows HTTP connections without TLS
   - Skips certificate validation even if HTTPS

### 7.2 Image Mirror Preparation

For image mirroring with insecure registry:

```bash
./mirror-images-to-nexus.sh \
  --registry docker.local:5000 \
  --insecure \
  --input required-images.txt
```

**What --insecure does** (mirror-images-to-nexus.sh:268-271):
- Uses simple docker pull/tag/push
- Respects daemon.json insecure-registries config
- Doesn't attempt buildx multi-arch preservation
- Works when registry is HTTP or self-signed HTTPS

---

## 8. COMPLETE REGISTRY CONFIGURATION FLOW

### From install.sh Execution to K3s Runtime

```
1. PARSE & VALIDATE
   └─ install.sh:133-249: Parse --private-registry, --registry-path, etc.
   └─ install.sh:371-389: Validate combinations

2. RESOLVE IMAGES
   └─ install.sh:397-470: Convert public → private registry paths
   └─ Sets RESOLVED_DIND_IMAGE, RESOLVED_K3D_IMAGE, etc.

3. GENERATE MANIFESTS
   └─ install.sh:517-570: generate_registries_configmap()
      ├─ Create registries.yaml ConfigMap with mirrors
      ├─ Set protocol (http/https) based on --registry-insecure
      ├─ Add rewrite rules if --registry-path specified
      └─ Configure TLS settings in configs section

4. MOUNT & COPY REGISTRIES.YAML
   └─ install.sh:887-902: Mount ConfigMap to /etc/rancher/k3s/registries.yaml
   └─ install.sh:786-801: Copy from mounted location to /tmp/registries.yaml
      ├─ Happens in k3d container startup (line 790-800)
      └─ Required because k3d needs writable file for --registry-config flag

5. K3D CLUSTER CREATION
   └─ install.sh:825-835: Build k3d arguments
      ├─ --registry-config /tmp/registries.yaml (line 829)
      ├─ --system-default-registry=${PRIVATE_REGISTRY} (line 833)
      └─ eval "k3d cluster create ..." (line 844)

6. IMAGE PULL CONFIGURATION
   └─ K3s startup inside k3d container
      ├─ Reads /tmp/registries.yaml
      ├─ Passes to containerd
      ├─ Containerd applies mirrors & rewrites
      ├─ System default registry prepends to unqualified names
      └─ Successfully pulls from private registry

7. SECRET HANDLING (if --registry-secret specified)
   └─ install.sh:598-603: Add imagePullSecrets to Deployment
   └─ install.sh:933-939: Mount secret to /tmp/docker-secret/config.json
   └─ install.sh:646-655 & 720-743: Configure Docker credential files
      └─ Enables Docker to authenticate to private registry
```

---

## 9. REGISTRY CONFIGURATION MODES

### 9.1 Mode 1: No Private Registry

```bash
./install.sh --name dev
```

**Flow**:
- Uses public images from docker.io, ghcr.io, rancher repos
- No registries ConfigMap generated
- Requires external network access
- No authentication needed

**Image Resolution**:
```
RESOLVED_DIND_IMAGE=docker:27-dind
RESOLVED_K3D_IMAGE=ghcr.io/k3d-io/k3d:5.8.3
RESOLVED_K3S_IMAGE=rancher/k3s:v1.32.9-k3s1
RESOLVED_K3D_TOOLS_IMAGE=ghcr.io/k3d-io/k3d-tools:5.8.3
```

---

### 9.2 Mode 2: Private Registry No Auth, HTTPS

```bash
# First, mirror images
./list-required-images.sh --registry docker.local --output images.txt
./mirror-images-to-nexus.sh --registry docker.local --input images.txt

# Then deploy
./install.sh --name dev --private-registry docker.local
```

**Generated Configuration**:
- registries.yaml with https:// endpoints
- insecure_skip_verify: false (assumes valid cert)
- No secret mount
- No auth setup in containers

**Image Resolution**:
```
RESOLVED_DIND_IMAGE=docker.local/library/docker:27-dind
RESOLVED_K3D_IMAGE=docker.local/k3d-io/k3d:5.8.3
RESOLVED_K3S_IMAGE=docker.local/rancher/k3s:v1.32.9-k3s1
RESOLVED_K3D_TOOLS_IMAGE=docker.local/k3d-io/k3d-tools:5.8.3
```

---

### 9.3 Mode 3: Private Registry with Auth, HTTPS

```bash
# Create secret
kubectl create secret docker-registry regcred \
  --docker-server=docker.local \
  --docker-username=admin \
  --docker-password=admin123

# Mirror images (with auth)
./mirror-images-to-nexus.sh \
  --registry docker.local \
  --username admin \
  --password admin123 \
  --input images.txt

# Deploy with secret
./install.sh --name dev \
  --private-registry docker.local \
  --registry-secret regcred
```

**Generated Configuration**:
- Same registries.yaml as Mode 2
- imagePullSecrets added to Deployment
- Secret mounted to /tmp/docker-secret/config.json
- Both dind and k3d containers set up ~/.docker/config.json
- Pre-pulls images to verify auth

---

### 9.4 Mode 4: Private Registry with Path, HTTPS

```bash
./list-required-images.sh \
  --registry docker.local \
  --registry-path docker-sandbox/jmann \
  --output images.txt

./mirror-images-to-nexus.sh \
  --registry docker.local \
  --input images.txt

./install.sh --name dev \
  --private-registry docker.local \
  --registry-path docker-sandbox/jmann
```

**Generated Configuration**:
```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.local"
    rewrite:
      "(.*)": "docker-sandbox/jmann/$1"
  ghcr.io:
    endpoint:
      - "https://docker.local"
    rewrite:
      "(.*)": "docker-sandbox/jmann/$1"
```

**Image Resolution**:
```
RESOLVED_K3D_IMAGE=docker.local/docker-sandbox/jmann/k3d-io/k3d:5.8.3
```

**Mirror Flow**:
1. K3s requests coredns image
2. System-default-registry adds: docker.local/coredns
3. Containerd applies no-op (already has registry)
4. Requests direct from docker.local

---

### 9.5 Mode 5: Insecure HTTP Registry

```bash
./list-required-images.sh --registry docker.local:5000 --output images.txt

./mirror-images-to-nexus.sh \
  --registry docker.local:5000 \
  --insecure \
  --input images.txt

./install.sh --name dev \
  --private-registry docker.local:5000 \
  --registry-insecure
```

**Generated Configuration**:
```yaml
mirrors:
  docker.io:
    endpoint:
      - "http://docker.local:5000"  # HTTP not HTTPS
      
configs:
  "docker.local:5000":
    tls:
      insecure_skip_verify: true
```

**Key Differences**:
- Endpoint protocol is `http://` instead of `https://`
- tls.insecure_skip_verify: true (even though protocol is http)
- Docker daemon gets `--insecure-registry docker.local:5000`
- No TLS certificate needed

---

### 9.6 Legacy Mode: Individual Image Flags

```bash
./install.sh --name dev \
  --dind-image docker.local/docker:27-dind \
  --k3d-image docker.local/k3d-io/k3d:5.8.3 \
  --k3s-image docker.local/rancher/k3s:v1.32.9-k3s1 \
  --k3d-tools-image docker.local/k3d-io/k3d-tools:5.8.3
```

**Behavior**:
- No registries ConfigMap generated
- No mirror/rewrite rules
- Only specified images are used
- No system-default-registry
- System images (coredns, metrics-server) pull from public registries
- Good for minimal airgap (just infrastructure images)

---

## 10. COMMON REGISTRY CONFIGURATION ISSUES AND SOLUTIONS

### Issue 1: "failed to open registry config file at /tmp/registries.yaml"

**Cause**: registries.yaml not copied from ConfigMount to /tmp before k3d cluster create

**Solution in Code** (install.sh:786-801):
```bash
# MUST be in container startup, OUTSIDE credential setup block
if [[ -n "$PRIVATE_REGISTRY" ]]; then
    echo "Copying registries.yaml to /tmp for k3d..."
    if [ -f /etc/rancher/k3s/registries.yaml ]; then
      cp /etc/rancher/k3s/registries.yaml /tmp/registries.yaml
      chmod 644 /tmp/registries.yaml
    fi
fi
```

**Key**: This is ALWAYS done when using private registry, regardless of auth

---

### Issue 2: "ErrImagePull" or "ImagePullBackOff" with Private Registry

**Cause 1**: Registry not in mirrors configuration
- Solution: Ensure all source registries (docker.io, ghcr.io, registry.k8s.io) have endpoints

**Cause 2**: Wrong image path/structure
- Solution: Verify image was mirrored with correct path structure

**Cause 3**: Authentication failed
- Solution: 
  - Verify secret is created in correct namespace
  - Check ~/.docker/config.json in containers has correct credentials
  - Run pre-pull test: `docker pull <full-image-path>`

**Cause 4**: Insecure registry TLS issue
- Solution: 
  - Use `--registry-insecure` if self-signed cert
  - Ensure insecure_skip_verify: true in registries.yaml
  - Check Docker daemon has registry in insecure-registries

---

### Issue 3: System images not found in private registry

**Cause**: K3s version components not mirrored

**Solution** (list-required-images.sh:210-246):
- Script auto-detects k3s version from K3S_VERSION parameter
- Includes correct component versions:
  - v1.32: rancher/mirrored-coredns-coredns:1.12.3
  - v1.31: rancher/mirrored-coredns-coredns:1.12.0
  - v1.30: registry.k8s.io/coredns/coredns:v1.11.1

**Verification**:
```bash
./list-required-images.sh --registry docker.local --k3s-version v1.32.9+k3s1 --output images.txt
grep coredns images.txt  # Should show correct version
```

---

### Issue 4: Registry path prefix not working

**Cause 1**: Rewrite rules not generated
- Solution: Ensure `--registry-path` is provided to both list-required-images.sh AND install.sh

**Cause 2**: Rewrite rules have wrong format
- Correct format: `"(.*)" : "path/$1"`
- Incorrect: `"(.*)" = "path/$1"` (uses = instead of :)

**Cause 3**: Images mirrored without path, but deployment expects path
- Solution: Ensure list-required-images.sh and mirror-images-to-nexus.sh use same --registry-path

---

### Issue 5: Multi-arch images converted to single-arch

**Cause**: Using `--insecure` flag with mirror-images-to-nexus.sh

**Solution**:
- Default mode attempts to preserve multi-arch: `./mirror-images-to-nexus.sh --registry ...`
- Only use `--insecure` when necessary for HTTP/self-signed certs
- Can use `--insecure` with HTTPS: `./mirror-images-to-nexus.sh --registry ... --insecure`

---

### Issue 6: K3d binary extraction fails

**Cause**: K3d image pull failed due to bad credentials or missing image

**Solution** (install.sh:718-754):
- Pre-pull both k3s and k3d-tools images before extraction
- If pre-pull fails, container exits immediately (fail-fast)
- Check logs: `kubectl logs -n <namespace> <pod-name> -c k3d`

---

### Issue 7: "system-default-registry not recognized"

**Cause**: Old k3s version that doesn't support this flag

**Solution**:
- Flag requires k3s v1.24+ (widely supported now)
- Project uses v1.32.9, well beyond requirement
- If using older k3s, fall back to pure registries.yaml mirrors

---

## 11. REGISTRIES.YAML TEMPLATE BREAKDOWN

### 11.1 Mirrors Section

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.local"
    rewrite:
      "(.*)": "docker-sandbox/jmann/$1"
```

**Function**:
- `docker.io`: Source registry being mirrored
- `endpoint`: Where to actually pull from instead
- `rewrite`: Path transformation (only if path prefix used)

**Behavior**:
1. Image request: docker.io/library/nginx:latest
2. Endpoint redirect: https://docker.local/docker-sandbox/jmann/library/nginx:latest
3. Result: Pulls from private registry with path prefix

---

### 11.2 Configs Section

```yaml
configs:
  "docker.local":
    tls:
      insecure_skip_verify: false
```

**Function**:
- `"docker.local"`: Registry domain being configured
- `tls.insecure_skip_verify`:
  - true: Skip certificate validation
  - false: Validate certificate (default)

**Behavior**:
- Applies to any registry access to this domain
- Even if endpoint uses http://, this controls TLS behavior
- Works with containerd's registry client

---

### 11.3 Rewrite Rules Logic

**Without path prefix**:
```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.local"
    # No rewrite section
```

Request flow:
```
docker.io/library/nginx → https://docker.local/library/nginx
```

**With path prefix** (docker-sandbox/jmann):
```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.local"
    rewrite:
      "(.*)": "docker-sandbox/jmann/$1"
```

Request flow:
```
docker.io/library/nginx → 
  Apply rewrite: docker-sandbox/jmann/library/nginx →
  https://docker.local/docker-sandbox/jmann/library/nginx
```

---

### 11.4 Multiple Mirror Endpoints

Project supports single endpoint per source registry:
```yaml
docker.io:
  endpoint:
    - "https://docker.local"
```

**Could support multiple** (for failover):
```yaml
docker.io:
  endpoint:
    - "https://primary-registry.local"
    - "https://secondary-registry.local"
```

---

## 12. IMAGE MIRRORING WORKFLOW COMPLETE

### 12.1 Complete Example: Artifactory with Path Prefix

```bash
# Step 1: Generate image list with path structure
./list-required-images.sh \
  --registry artifactory.company.com \
  --registry-path docker-sandbox/jmann \
  --k3s-version v1.32.9+k3s1 \
  --output images.txt

# images.txt now contains:
# docker:27-dind=artifactory.company.com/docker-sandbox/jmann/library/docker:27-dind
# ghcr.io/k3d-io/k3d:5.8.3=artifactory.company.com/docker-sandbox/jmann/k3d-io/k3d:5.8.3
# ...
```

```bash
# Step 2: Mirror images (sequential to avoid overload)
./mirror-images-sequential.sh \
  artifactory.company.com/docker-sandbox/jmann \
  images.txt \
  5

# OR with authentication
./mirror-images-to-nexus.sh \
  --registry artifactory.company.com \
  --input images.txt \
  --username deploy-user \
  --password $(cat ~/.artifactory-token) \
  --output mirror-report.txt
```

```bash
# Step 3: Create registry secret
kubectl create secret docker-registry artifactory-cred \
  --docker-server=artifactory.company.com \
  --docker-username=deploy-user \
  --docker-password=$(cat ~/.artifactory-token) \
  --docker-email=deploy@company.com
```

```bash
# Step 4: Deploy k3s
./install.sh --name production \
  --private-registry artifactory.company.com \
  --registry-path docker-sandbox/jmann \
  --registry-secret artifactory-cred \
  --storage-size 50Gi \
  --cpu-limit 4 \
  --memory-limit 8Gi
```

```bash
# Step 5: Verify
./verify-airgap.sh \
  --name production \
  --registry artifactory.company.com \
  --output verify-report.txt
```

---

### 12.2 Verification Flow

verify-airgap.sh checks:

1. **Prerequisites**: kubectl, docker installed
2. **Deployment exists**: k3s deployment in namespace
3. **Pod running**: All containers ready
4. **Cluster operational**: Inner k3s nodes Ready
5. **CoreDNS running**: DNS available
6. **Registry ConfigMap**: k3s-registries exists
7. **registries.yaml content**: Registry configured in /tmp/registries.yaml
8. **Containerd config**: Registry in hosts.toml
9. **Images accessible**: Can inspect images in registry
10. **Image pull events**: Recent successful pulls

---

## 13. SUMMARY TABLE: REGISTRY CONFIGURATION MATRIX

| Aspect | No Registry | Public Registry | Private HTTPS | Private HTTP | With Path | With Auth |
|--------|-------------|-----------------|---------------|--------------|-----------|-----------|
| --private-registry | No | Yes | Yes | Yes | Yes | Yes |
| --registry-insecure | No | No | No | Yes | No | Yes/No |
| --registry-path | N/A | N/A | Optional | Optional | Yes | Optional |
| --registry-secret | N/A | N/A | Optional | Optional | Optional | Yes |
| ConfigMap generated | No | Yes | Yes | Yes | Yes | Yes |
| registries.yaml | No | Yes | Yes | Yes | Yes | Yes |
| Endpoint protocol | N/A | HTTPS | HTTPS | HTTP | HTTPS/HTTP | HTTPS/HTTP |
| TLS verification | N/A | false (?) | false | false | false (?) | false (?) |
| Rewrite rules | N/A | No | No | No | Yes | No |
| System-default-registry | No | Yes | Yes | Yes | Yes | Yes |
| Secret mount | No | No | No | No | No | Yes |
| Docker credential setup | No | No | No | No | No | Yes |
| Pre-pull verification | No | No | No | No | No | Yes |

---

## 14. KEY INSIGHTS AND BEST PRACTICES

### Best Practices:

1. **Always use --registry-path for enterprise registries** (Artifactory, Nexus, Harbor)
   - Creates clear namespace separation
   - Avoids conflicts with other teams
   - Makes permission management easier

2. **Use --registry-secret for production**
   - Pre-pull verification catches auth issues early
   - Fails fast if credentials wrong
   - Both dind and k3d containers have credentials

3. **For insecure registries, prefer HTTP over self-signed HTTPS**
   - HTTP+insecure_skip_verify is simpler
   - Self-signed HTTPS requires CA bundle configuration (not yet supported)
   - Only for dev/test environments anyway

4. **Mirror images closest to deployment**
   - Reduces bandwidth
   - Faster pulls
   - Better for airgapped environments

5. **Use list-required-images.sh for version-specific components**
   - Automatically includes correct coredns, metrics-server versions
   - Prevents "image not found" errors for system pods

6. **Test with dry-run first**
   - `./install.sh --dry-run` generates manifests
   - Review registries.yaml structure
   - Catch configuration errors before deployment

### Design Decisions Made:

1. **registries.yaml in ConfigMap, not in image**
   - Allows configuration without rebuilding container images
   - Easy to update via kubectl
   - Separates configuration from deployment

2. **Copy to /tmp, not direct mount at /tmp/registries.yaml**
   - k3d needs writable file (to potentially modify)
   - ConfigMap mount is read-only
   - /tmp on emptyDir allows modifications

3. **Both --system-default-registry and registries.yaml mirrors**
   - Dual mechanism ensures comprehensive coverage
   - Handles both qualified and unqualified image names
   - Provides flexibility for different image source registries

4. **Pre-pull in k3d container, not in dind**
   - k3d is what extracts the binary
   - If pull fails, extract fails
   - Immediate feedback on credential issues

5. **Separate --registry-path from image specification**
   - Path prefix applies consistently across all source registries
   - Single source of truth for path structure
   - Easier to manage than per-image paths

---

## 15. REFERENCES IN CODEBASE

### Main Implementation Files:
- `install.sh:204-219`: Flag parsing
- `install.sh:371-389`: Configuration validation  
- `install.sh:397-470`: Image resolution (resolve_images)
- `install.sh:517-570`: registries.yaml generation (generate_registries_configmap)
- `install.sh:598-603`: imagePullSecrets
- `install.sh:622-625`: Docker insecure-registry
- `install.sh:642-688`: Registry credential setup (dind)
- `install.sh:716-763`: Registry credential setup (k3d) with pre-pull
- `install.sh:786-801`: registries.yaml file copy
- `install.sh:824-835`: k3d cluster creation with registry args
- `install.sh:887-902`: Volume mounts for registries and secrets

### Registry Tooling:
- `list-required-images.sh`: Generate image mappings
- `mirror-images-to-nexus.sh`: Mirror images to private registry
- `mirror-images-sequential.sh`: Sequential mirroring with delays
- `verify-airgap.sh`: Verification of airgap deployment

### Testing:
- `tests/test-registry-config.sh`: Registry configuration tests

### Documentation:
- `AIRGAPPED-SETUP.md`: Airgap setup guide
- `TROUBLESHOOTING.md`: Common issues

