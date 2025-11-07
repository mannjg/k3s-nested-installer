#!/bin/bash

# Helper script to access the inner k3s cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="${SCRIPT_DIR}/k3s-inner-kubeconfig.yaml"

echo "=== Accessing Inner K3s Cluster ==="
echo

# Check if pod is running
echo "1. Checking if k3s pod is running..."
POD_NAME=$(kubectl get pods -n k3s-inner -l app=k3s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
    echo "ERROR: K3s pod not found in k3s-inner namespace"
    echo "Please deploy the k3s cluster first:"
    echo "  kubectl apply -f ${SCRIPT_DIR}/"
    exit 1
fi

POD_STATUS=$(kubectl get pod -n k3s-inner "$POD_NAME" -o jsonpath='{.status.phase}')
if [ "$POD_STATUS" != "Running" ]; then
    echo "ERROR: K3s pod is not running (status: $POD_STATUS)"
    exit 1
fi

echo "   ✓ Pod $POD_NAME is running"
echo

# Extract kubeconfig
echo "2. Extracting kubeconfig from pod..."
kubectl exec -n k3s-inner "$POD_NAME" -c k3d -- cat /output/kubeconfig.yaml > "${KUBECONFIG_FILE}.tmp" 2>/dev/null

if [ ! -s "${KUBECONFIG_FILE}.tmp" ]; then
    echo "ERROR: Failed to extract kubeconfig"
    rm -f "${KUBECONFIG_FILE}.tmp"
    exit 1
fi

# Modify for external access
sed 's/localhost:6443/localhost:30443/g' "${KUBECONFIG_FILE}.tmp" > "${KUBECONFIG_FILE}"
rm -f "${KUBECONFIG_FILE}.tmp"

echo "   ✓ Kubeconfig saved to: ${KUBECONFIG_FILE}"
echo

# Test connection
echo "3. Testing connection to inner k3s..."
if kubectl --kubeconfig="${KUBECONFIG_FILE}" get nodes &>/dev/null; then
    echo "   ✓ Connection successful!"
else
    echo "ERROR: Failed to connect to inner k3s"
    exit 1
fi

echo
echo "=== Inner K3s Cluster Info ==="
kubectl --kubeconfig="${KUBECONFIG_FILE}" get nodes -o wide

echo
echo "=== Usage ==="
echo "To use kubectl with the inner k3s cluster:"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
echo "  kubectl get nodes"
echo
echo "Or use the --kubeconfig flag:"
echo "  kubectl --kubeconfig=${KUBECONFIG_FILE} get pods --all-namespaces"
echo
echo "=== Quick Commands ==="
echo "# Set context for this terminal session"
echo "export KUBECONFIG=${KUBECONFIG_FILE}"
echo
echo "# View all namespaces"
echo "kubectl get namespaces"
echo
echo "# Deploy test pod"
echo "kubectl run test-pod --image=nginx:alpine"
echo
