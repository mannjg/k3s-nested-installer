#!/usr/bin/env bash

#############################################################################
# K3s-in-Kubernetes Management Utility
#
# Manage multiple k3s instances deployed in a Kubernetes cluster
#
# Usage:
#   ./manage.sh list
#   ./manage.sh access <instance-name>
#   ./manage.sh delete <instance-name>
#############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIGS_DIR="${SCRIPT_DIR}/kubeconfigs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal() { error "$*"; exit 1; }

#############################################################################
# Commands
#############################################################################

cmd_list() {
    log "Listing all k3s instances..."
    echo ""

    # Find all namespaces with k3s instances
    local namespaces=$(kubectl get namespaces -l app=k3s-nested -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$namespaces" ]]; then
        warn "No k3s instances found"
        return 0
    fi

    # Print header
    printf "%-15s %-20s %-12s %-8s %-30s\n" "NAME" "NAMESPACE" "STATUS" "AGE" "ACCESS"
    printf "%-15s %-20s %-12s %-8s %-30s\n" "----" "---------" "------" "---" "------"

    # List each instance
    for ns in $namespaces; do
        local instance=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.instance}' 2>/dev/null || echo "unknown")
        local pod_status=$(kubectl get pods -n "$ns" -l app=k3s -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
        local age=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")

        if [[ -n "$age" ]]; then
            age=$(echo "$age" | xargs -I {} date -d {} +%s 2>/dev/null || echo "0")
            local now=$(date +%s)
            local diff=$((now - age))
            local days=$((diff / 86400))
            local hours=$(((diff % 86400) / 3600))
            local minutes=$(((diff % 3600) / 60))

            if [[ $days -gt 0 ]]; then
                age="${days}d"
            elif [[ $hours -gt 0 ]]; then
                age="${hours}h"
            else
                age="${minutes}m"
            fi
        else
            age="unknown"
        fi

        # Determine access method
        local access="Unknown"
        if kubectl get svc -n "$ns" k3s-nodeport &>/dev/null; then
            local nodeport=$(kubectl get svc -n "$ns" k3s-nodeport -o jsonpath='{.spec.ports[0].nodePort}')
            access="NodePort:${nodeport}"
        elif kubectl get svc -n "$ns" k3s-loadbalancer &>/dev/null; then
            local lb_ip=$(kubectl get svc -n "$ns" k3s-loadbalancer -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
            access="LoadBalancer:${lb_ip}"
        elif kubectl get ingress -n "$ns" k3s-ingress &>/dev/null; then
            local hostname=$(kubectl get ingress -n "$ns" k3s-ingress -o jsonpath='{.spec.rules[0].host}')
            access="Ingress:${hostname}"
        fi

        printf "%-15s %-20s %-12s %-8s %-30s\n" "$instance" "$ns" "$pod_status" "$age" "$access"
    done

    echo ""
    log "Total instances: $(echo "$namespaces" | wc -w)"
}

cmd_access() {
    local instance_name="${1:-}"
    if [[ -z "$instance_name" ]]; then
        fatal "Usage: $0 access <instance-name>"
    fi

    local kubeconfig="${KUBECONFIGS_DIR}/k3s-${instance_name}.yaml"

    if [[ ! -f "$kubeconfig" ]]; then
        error "Kubeconfig not found: $kubeconfig"
        error "Run: $0 refresh-kubeconfig ${instance_name}"
        return 1
    fi

    log "Accessing k3s instance '${instance_name}'..."
    log "Kubeconfig: $kubeconfig"
    echo ""

    # Test connection
    if ! kubectl --kubeconfig="$kubeconfig" cluster-info &>/dev/null; then
        error "Cannot connect to instance '${instance_name}'"
        return 1
    fi

    # Show cluster info
    kubectl --kubeconfig="$kubeconfig" cluster-info
    echo ""
    kubectl --kubeconfig="$kubeconfig" get nodes -o wide
    echo ""

    success "Instance is accessible!"
    echo ""
    log "To use this instance, run:"
    echo "  export KUBECONFIG=$kubeconfig"
    echo "  kubectl get nodes"
}

cmd_refresh_kubeconfig() {
    local instance_name="${1:-}"
    if [[ -z "$instance_name" ]]; then
        fatal "Usage: $0 refresh-kubeconfig <instance-name>"
    fi

    # Find namespace
    local namespace=$(kubectl get namespaces -l "app=k3s-nested,instance=${instance_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$namespace" ]]; then
        fatal "Instance '${instance_name}' not found"
    fi

    log "Refreshing kubeconfig for instance '${instance_name}' in namespace '${namespace}'..."

    # Get pod name
    local pod_name=$(kubectl get pods -n "$namespace" -l app=k3s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$pod_name" ]]; then
        fatal "Pod not found for instance '${instance_name}'"
    fi

    mkdir -p "$KUBECONFIGS_DIR"
    local kubeconfig="${KUBECONFIGS_DIR}/k3s-${instance_name}.yaml"

    # Extract kubeconfig
    kubectl exec -n "$namespace" "$pod_name" -c k3d -- cat /output/kubeconfig.yaml > "${kubeconfig}.tmp"

    # Determine access method and update server URL
    if kubectl get svc -n "$namespace" k3s-nodeport &>/dev/null; then
        local nodeport=$(kubectl get svc -n "$namespace" k3s-nodeport -o jsonpath='{.spec.ports[0].nodePort}')
        sed "s|https://0.0.0.0:6443|https://localhost:${nodeport}|g" "${kubeconfig}.tmp" > "$kubeconfig"
    elif kubectl get svc -n "$namespace" k3s-loadbalancer &>/dev/null; then
        local lb_ip=$(kubectl get svc -n "$namespace" k3s-loadbalancer -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        if [[ -n "$lb_ip" && "$lb_ip" != "null" ]]; then
            sed "s|https://0.0.0.0:6443|https://${lb_ip}:6443|g" "${kubeconfig}.tmp" > "$kubeconfig"
        else
            warn "LoadBalancer IP not yet assigned"
            cp "${kubeconfig}.tmp" "$kubeconfig"
        fi
    elif kubectl get ingress -n "$namespace" k3s-ingress &>/dev/null; then
        local hostname=$(kubectl get ingress -n "$namespace" k3s-ingress -o jsonpath='{.spec.rules[0].host}')
        sed "s|https://0.0.0.0:6443|https://${hostname}|g" "${kubeconfig}.tmp" > "$kubeconfig"
    else
        cp "${kubeconfig}.tmp" "$kubeconfig"
    fi

    rm "${kubeconfig}.tmp"

    success "Kubeconfig refreshed: $kubeconfig"

    # Test connection
    if kubectl --kubeconfig="$kubeconfig" cluster-info &>/dev/null; then
        success "Connection verified"
    else
        warn "Could not verify connection. The cluster may still be initializing."
    fi
}

cmd_delete() {
    local instance_name="${1:-}"
    if [[ -z "$instance_name" ]]; then
        fatal "Usage: $0 delete <instance-name>"
    fi

    # Find namespace
    local namespace=$(kubectl get namespaces -l "app=k3s-nested,instance=${instance_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$namespace" ]]; then
        fatal "Instance '${instance_name}' not found"
    fi

    warn "This will delete instance '${instance_name}' in namespace '${namespace}'"
    warn "All data will be lost!"
    echo -n "Are you sure? (yes/no): "
    read -r confirmation

    if [[ "$confirmation" != "yes" ]]; then
        log "Deletion cancelled"
        return 0
    fi

    log "Deleting instance '${instance_name}'..."

    if kubectl delete namespace "$namespace"; then
        success "Instance deleted"

        # Remove kubeconfig
        local kubeconfig="${KUBECONFIGS_DIR}/k3s-${instance_name}.yaml"
        if [[ -f "$kubeconfig" ]]; then
            rm "$kubeconfig"
            log "Kubeconfig removed"
        fi
    else
        error "Failed to delete instance"
        return 1
    fi
}

cmd_logs() {
    local instance_name="${1:-}"
    local container="${2:-k3d}"

    if [[ -z "$instance_name" ]]; then
        fatal "Usage: $0 logs <instance-name> [container]"
    fi

    # Find namespace
    local namespace=$(kubectl get namespaces -l "app=k3s-nested,instance=${instance_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$namespace" ]]; then
        fatal "Instance '${instance_name}' not found"
    fi

    log "Showing logs for instance '${instance_name}' container '${container}'..."
    kubectl logs -n "$namespace" -l app=k3s -c "$container" --tail=100 -f
}

cmd_exec() {
    local instance_name="${1:-}"
    shift || true
    local cmd_args=("$@")

    if [[ -z "$instance_name" ]]; then
        fatal "Usage: $0 exec <instance-name> -- <command>"
    fi

    local kubeconfig="${KUBECONFIGS_DIR}/k3s-${instance_name}.yaml"

    if [[ ! -f "$kubeconfig" ]]; then
        error "Kubeconfig not found. Run: $0 refresh-kubeconfig ${instance_name}"
        return 1
    fi

    # Execute command with kubeconfig
    kubectl --kubeconfig="$kubeconfig" "${cmd_args[@]}"
}

cmd_status() {
    local instance_name="${1:-}"
    if [[ -z "$instance_name" ]]; then
        fatal "Usage: $0 status <instance-name>"
    fi

    # Find namespace
    local namespace=$(kubectl get namespaces -l "app=k3s-nested,instance=${instance_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$namespace" ]]; then
        fatal "Instance '${instance_name}' not found"
    fi

    log "Status for instance '${instance_name}':"
    echo ""

    # Pod status
    echo "=== Pod Status ==="
    kubectl get pods -n "$namespace" -l app=k3s
    echo ""

    # Services
    echo "=== Services ==="
    kubectl get svc -n "$namespace"
    echo ""

    # PVC
    echo "=== Storage ==="
    kubectl get pvc -n "$namespace"
    echo ""

    # Ingress (if exists)
    if kubectl get ingress -n "$namespace" &>/dev/null; then
        echo "=== Ingress ==="
        kubectl get ingress -n "$namespace"
        echo ""
    fi

    # Inner cluster status
    local kubeconfig="${KUBECONFIGS_DIR}/k3s-${instance_name}.yaml"
    if [[ -f "$kubeconfig" ]] && kubectl --kubeconfig="$kubeconfig" cluster-info &>/dev/null; then
        echo "=== Inner K3s Cluster ==="
        kubectl --kubeconfig="$kubeconfig" get nodes -o wide
        echo ""
        echo "Namespaces:"
        kubectl --kubeconfig="$kubeconfig" get namespaces
    fi
}

cmd_delete_all() {
    warn "This will delete ALL k3s instances!"
    echo -n "Are you sure? (yes/no): "
    read -r confirmation

    if [[ "$confirmation" != "yes" ]]; then
        log "Deletion cancelled"
        return 0
    fi

    local namespaces=$(kubectl get namespaces -l app=k3s-nested -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$namespaces" ]]; then
        warn "No instances found"
        return 0
    fi

    for ns in $namespaces; do
        log "Deleting namespace: $ns"
        kubectl delete namespace "$ns" &
    done

    wait

    success "All instances deleted"

    # Clean up kubeconfigs
    if [[ -d "$KUBECONFIGS_DIR" ]]; then
        rm -rf "${KUBECONFIGS_DIR:?}/"*
        log "Kubeconfigs cleaned up"
    fi
}

cmd_resources() {
    log "Resource usage across all instances:"
    echo ""

    local namespaces=$(kubectl get namespaces -l app=k3s-nested -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$namespaces" ]]; then
        warn "No instances found"
        return 0
    fi

    printf "%-15s %-20s %-15s %-15s %-15s\n" "INSTANCE" "NAMESPACE" "CPU" "MEMORY" "STORAGE"
    printf "%-15s %-20s %-15s %-15s %-15s\n" "--------" "---------" "---" "------" "-------"

    for ns in $namespaces; do
        local instance=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.instance}')

        # Get pod metrics (if metrics-server is installed)
        local cpu=$(kubectl top pod -n "$ns" -l app=k3s 2>/dev/null | tail -n 1 | awk '{print $2}' || echo "N/A")
        local memory=$(kubectl top pod -n "$ns" -l app=k3s 2>/dev/null | tail -n 1 | awk '{print $3}' || echo "N/A")

        # Get storage usage
        local storage=$(kubectl get pvc -n "$ns" k3s-data -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "N/A")

        printf "%-15s %-20s %-15s %-15s %-15s\n" "$instance" "$ns" "$cpu" "$memory" "$storage"
    done
}

show_usage() {
    cat << EOF
Usage: $0 <command> [arguments]

Commands:
  list                           List all k3s instances
  access <instance>              Access a k3s instance
  status <instance>              Show detailed status of an instance
  refresh-kubeconfig <instance>  Refresh kubeconfig for an instance
  exec <instance> -- <command>   Execute kubectl command on instance
  logs <instance> [container]    Show logs (default container: k3d)
  delete <instance>              Delete an instance
  delete-all                     Delete all instances
  resources                      Show resource usage across instances

Examples:
  $0 list
  $0 access dev
  $0 status dev
  $0 exec dev -- get pods --all-namespaces
  $0 logs dev k3d
  $0 delete dev

EOF
}

#############################################################################
# Main
#############################################################################

main() {
    local command="${1:-}"

    if [[ -z "$command" ]]; then
        show_usage
        exit 1
    fi

    shift || true

    case "$command" in
        list)
            cmd_list
            ;;
        access)
            cmd_access "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        refresh-kubeconfig|refresh)
            cmd_refresh_kubeconfig "$@"
            ;;
        exec)
            cmd_exec "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        delete)
            cmd_delete "$@"
            ;;
        delete-all)
            cmd_delete_all
            ;;
        resources|res)
            cmd_resources
            ;;
        help|-h|--help)
            show_usage
            ;;
        *)
            error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
