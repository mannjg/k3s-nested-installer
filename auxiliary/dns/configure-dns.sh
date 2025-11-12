#!/usr/bin/env bash

#############################################################################
# CoreDNS Configuration for Ingress DNS Resolution
#
# Configures CoreDNS to resolve *.local hostnames to the ingress controller
# This mimics production wildcard DNS behavior where *.mydomain.com routes
# to an external load balancer.
#
# Usage:
#   ./configure-dns.sh [--dry-run] [--rollback]
#############################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Options
DRY_RUN=false
ROLLBACK=false
BACKUP_DIR="${SCRIPT_DIR}/backups"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#############################################################################
# Utility Functions
#############################################################################

log() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

fatal() {
    error "$*"
    exit 1
}

#############################################################################
# Parse Arguments
#############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --rollback)
                ROLLBACK=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                fatal "Unknown option: $1"
                ;;
        esac
    done
}

show_usage() {
    cat << EOF
Usage: $0 [options]

Configures CoreDNS to resolve ingress hostnames (*.local) to the ingress
controller IP address. This enables k3s pods to access registries and services
through their external ingress hostnames.

Options:
  --dry-run    Show what would be done without making changes
  --rollback   Restore the previous CoreDNS configuration
  -h, --help   Show this help message

Examples:
  # Configure DNS
  $0

  # Preview changes
  $0 --dry-run

  # Restore previous configuration
  $0 --rollback

EOF
}

#############################################################################
# Main Functions
#############################################################################

get_ingress_ip() {
    log "Detecting ingress controller IP..."

    # Try to find nginx-ingress-microk8s controller pod
    local ingress_ip
    ingress_ip=$(kubectl get pod -n ingress -l name=nginx-ingress-microk8s \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")

    if [[ -z "$ingress_ip" ]]; then
        # Try alternative ingress controller labels
        ingress_ip=$(kubectl get pod -n ingress -l app.kubernetes.io/name=ingress-nginx \
            -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
    fi

    if [[ -z "$ingress_ip" ]]; then
        fatal "Could not find ingress controller pod. Please verify ingress is installed."
    fi

    success "Found ingress controller at: $ingress_ip"
    echo "$ingress_ip"
}

backup_coredns_config() {
    log "Backing up current CoreDNS configuration..."

    mkdir -p "$BACKUP_DIR"
    local backup_file="${BACKUP_DIR}/coredns-backup-$(date +%Y%m%d-%H%M%S).yaml"

    if kubectl get configmap coredns -n kube-system -o yaml > "$backup_file"; then
        success "Backup saved to: $backup_file"
        echo "$backup_file"
    else
        fatal "Failed to backup CoreDNS configuration"
    fi
}

apply_coredns_config() {
    local ingress_ip=$1
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log "Generating CoreDNS configuration with ingress DNS entries..."

    # Create temporary file for the configuration
    local temp_config=$(mktemp)

    # Generate the new CoreDNS configuration with inline variable substitution
    cat >"$temp_config" <<EOF_CONFIG
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
  labels:
    addonmanager.kubernetes.io/mode: EnsureExists
    k8s-app: kube-dns
  annotations:
    description: "Custom CoreDNS config for resolving ingress domains"
    configured-by: "k3s-nested-installer/auxiliary/dns/configure-dns.sh"
    ingress-ip: "${ingress_ip}"
    configured-at: "${timestamp}"
data:
  Corefile: |
    .:53 {
        errors
        health {
          lameduck 5s
        }
        ready
        log . {
          class error
        }

        # CUSTOM DNS FOR TEST ENVIRONMENT
        # Resolves *.local domains to ingress controller
        # This mimics production wildcard DNS (*.mydomain.com)
        #
        # Update INGRESS_IP if ingress controller is redeployed
        hosts {
            ${ingress_ip} docker.local
            ${ingress_ip} gitlab.local
            ${ingress_ip} nexus.local
            ${ingress_ip} jenkins.local
            ${ingress_ip} argocd.local
            fallthrough
        }

        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
EOF_CONFIG

    # Apply the configuration
    if kubectl apply -f "$temp_config"; then
        success "CoreDNS configuration applied successfully"
        rm -f "$temp_config"
    else
        error "Failed to apply CoreDNS configuration"
        rm -f "$temp_config"
        return 1
    fi
}

wait_for_coredns_reload() {
    log "Waiting for CoreDNS to reload configuration..."

    # CoreDNS automatically reloads ConfigMap changes
    # Give it a few seconds to pick up the changes
    sleep 5

    # Check if CoreDNS pods are ready
    if kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=30s &>/dev/null; then
        success "CoreDNS reloaded successfully"
    else
        warn "CoreDNS reload verification timed out, but this may be normal"
    fi
}

verify_dns_resolution() {
    log "Verifying DNS resolution..."

    # Create a temporary test pod to verify DNS
    local test_result
    test_result=$(kubectl run dns-test-$(date +%s) \
        --image=busybox:1.28 \
        --rm -i --restart=Never \
        --command -- nslookup docker.local 2>&1 || true)

    if echo "$test_result" | grep -q "Address:"; then
        success "DNS resolution test passed!"
        echo "$test_result" | grep -A2 "Name:"
    else
        error "DNS resolution test failed!"
        echo "$test_result"
        return 1
    fi
}

rollback_coredns_config() {
    log "Rolling back CoreDNS configuration..."

    if [[ ! -d "$BACKUP_DIR" ]]; then
        fatal "No backups found in $BACKUP_DIR"
    fi

    # Find the most recent backup
    local latest_backup
    latest_backup=$(ls -t "$BACKUP_DIR"/coredns-backup-*.yaml 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        fatal "No backup files found"
    fi

    log "Restoring from: $latest_backup"

    if kubectl apply -f "$latest_backup"; then
        success "CoreDNS configuration rolled back successfully"
        wait_for_coredns_reload
    else
        fatal "Failed to rollback CoreDNS configuration"
    fi
}

#############################################################################
# Main Execution
#############################################################################

main() {
    parse_args "$@"

    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        fatal "kubectl is not installed or not in PATH"
    fi

    if ! kubectl cluster-info &> /dev/null; then
        fatal "Cannot connect to Kubernetes cluster"
    fi

    # Handle rollback
    if [[ "$ROLLBACK" == "true" ]]; then
        rollback_coredns_config
        exit 0
    fi

    # Get ingress IP
    ingress_ip=$(get_ingress_ip)

    # Backup current config
    backup_file=$(backup_coredns_config)

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN - would configure CoreDNS with ingress IP: $ingress_ip"
        log "Backup would be saved to: $backup_file"
        exit 0
    fi

    # Apply new configuration
    apply_coredns_config "$ingress_ip"

    # Wait for reload
    wait_for_coredns_reload

    # Verify
    echo ""
    if verify_dns_resolution; then
        echo ""
        success "═══════════════════════════════════════════════════════════"
        success "  CoreDNS configuration completed successfully!"
        success "═══════════════════════════════════════════════════════════"
        echo ""
        log "Ingress hostnames now resolve to: $ingress_ip"
        echo ""
        log "Configured domains:"
        echo "  - docker.local"
        echo "  - gitlab.local"
        echo "  - nexus.local"
        echo "  - jenkins.local"
        echo "  - argocd.local"
        echo ""
        log "To rollback: $0 --rollback"
        echo ""
    else
        error "DNS verification failed. You may need to troubleshoot."
        error "To rollback: $0 --rollback"
        exit 1
    fi
}

# Run main function
main "$@"
