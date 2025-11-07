# Working Example - Original Prototype

This directory contains the original static YAML manifests that were used to develop and test the k3s-nested-installer concept.

## What This Is

This is the **prototype/proof-of-concept** that demonstrated k3s-in-Docker (k3d) running inside a Kubernetes cluster (microk8s). It successfully proved the architecture works before building the automated installer.

## Relationship to Installer

- **This directory**: Static manifests for manual deployment
- **install.sh**: Automated version with multi-instance support, based on these manifests

## Current Status

This deployment is currently **running in your microk8s cluster** in the `k3s-inner` namespace. You can verify with:

```bash
kubectl get pods -n k3s-inner
```

## When to Use

- **Reference**: See the original working configuration
- **Comparison**: Understand what the installer generates
- **Testing**: Quick manual deployment for testing

## When NOT to Use

For production or multi-instance deployments, use `../install.sh` instead. The installer provides:
- Multiple instances in separate namespaces
- Configurable resources and access methods
- Automated kubeconfig extraction
- Better error handling and validation

## Files

- `k3s-deployment.yaml` - DinD + k3d deployment with PVC
- `k3s-service.yaml` - ClusterIP service
- `k3s-nodeport-service.yaml` - NodePort on 30443
- `k3s-ingress.yaml` - Ingress configuration
- `access-inner-k3s.sh` - Helper script for kubeconfig extraction
- `README.md` - Original documentation
- `DEMO.md` - Step-by-step demo walkthrough
- `k3s-inner-kubeconfig.yaml` - Extracted kubeconfig (generated)

## Cleanup

To remove the running deployment:

```bash
kubectl delete namespace k3s-inner
```

This will **not** affect other k3s instances created by the installer, as they use different namespaces (e.g., `k3s-dev`, `k3s-test`).
