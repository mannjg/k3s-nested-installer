#!/usr/bin/env bash

#############################################################################
# K3s Required Images List Generator
#
# Generates a complete list of images required for k3s airgap deployment
# including infrastructure images and internal k3s components.
#
# Usage:
#   ./list-required-images.sh --registry docker.local [options]
#############################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
TARGET_REGISTRY=""
REGISTRY_PATH=""  # Optional path prefix (e.g., "docker-sandbox/jmann")
K3S_VERSION="v1.31.5-k3s1"
K3D_VERSION="v5.8.3"
DOCKER_VERSION="27-dind"
OUTPUT_FILE="required-images.txt"
FORMAT="mapping"  # mapping or list
VERBOSE=false

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

debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

#############################################################################
# Parse Arguments
#############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --registry)
                TARGET_REGISTRY="$2"
                shift 2
                ;;
            --registry-path)
                REGISTRY_PATH="$2"
                shift 2
                ;;
            --k3s-version)
                K3S_VERSION="$2"
                shift 2
                ;;
            --k3d-version)
                K3D_VERSION="$2"
                shift 2
                ;;
            --docker-version)
                DOCKER_VERSION="$2"
                shift 2
                ;;
            --output|-o)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --format)
                FORMAT="$2"
                shift 2
                ;;
            --verbose|-v)
                VERBOSE=true
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
Usage: $0 --registry <registry-url> [options]

Generates a list of all images required for airgapped k3s deployment.

Required:
  --registry URL          Target registry URL (e.g., docker.local, myregistry.com:5000)

Optional:
  --registry-path PATH    Path prefix within registry (e.g., "docker-sandbox/jmann")
                          Results in: registry/path/image-name:tag
  --k3s-version VERSION   K3s version (default: ${K3S_VERSION})
  --k3d-version VERSION   K3d version (default: ${K3D_VERSION})
  --docker-version VER    Docker version (default: ${DOCKER_VERSION})
  --output FILE           Output file (default: ${OUTPUT_FILE})
  --format FORMAT         Output format: mapping|list (default: ${FORMAT})
                          mapping: SOURCE=TARGET format
                          list: Just source images
  -v, --verbose           Show detailed output
  -h, --help              Show this help message

Examples:
  # Generate image list for docker.local registry
  $0 --registry docker.local

  # With custom path prefix (for Artifactory/Nexus with subdirectories)
  $0 --registry artifactory.company.com \\
    --registry-path docker-sandbox/jmann

  # Custom versions
  $0 --registry myregistry.com:5000 \\
    --k3s-version v1.30.0-k3s1 \\
    --k3d-version v5.7.4

  # Output to custom file
  $0 --registry docker.local --output my-images.txt

  # List format (source images only)
  $0 --registry docker.local --format list

EOF
}

validate_config() {
    if [[ -z "$TARGET_REGISTRY" ]]; then
        fatal "Target registry is required. Use --registry <url>"
    fi

    debug "Configuration validated:"
    debug "  Target Registry: $TARGET_REGISTRY"
    debug "  Registry Path: ${REGISTRY_PATH:-<none>}"
    debug "  K3s Version: $K3S_VERSION"
    debug "  K3d Version: $K3D_VERSION"
    debug "  Docker Version: $DOCKER_VERSION"
    debug "  Output File: $OUTPUT_FILE"
    debug "  Format: $FORMAT"
}

#############################################################################
# Image List Generation
#############################################################################

generate_image_list() {
    log "Generating required images list..."

    local temp_file=$(mktemp)

    # Infrastructure Images
    log "Adding infrastructure images..."

    # Docker-in-Docker
    add_image "docker" "docker:${DOCKER_VERSION}" "$temp_file"

    # K3d CLI tool
    add_image "ghcr.io/k3d-io/k3d" "ghcr.io/k3d-io/k3d:${K3D_VERSION}" "$temp_file"

    # K3s server
    add_image "rancher/k3s" "rancher/k3s:${K3S_VERSION}" "$temp_file"

    # K3d helper containers (proxy, tools, registry)
    add_image "ghcr.io/k3d-io/k3d-proxy" "ghcr.io/k3d-io/k3d-proxy:${K3D_VERSION}" "$temp_file"
    add_image "ghcr.io/k3d-io/k3d-tools" "ghcr.io/k3d-io/k3d-tools:${K3D_VERSION}" "$temp_file"

    # K3s Internal Components
    log "Adding k3s internal component images..."

    # Get k3s version components (e.g., v1.31.5-k3s1 -> 1.31)
    local k8s_minor=$(echo "$K3S_VERSION" | sed 's/v\([0-9]*\.[0-9]*\).*/\1/')
    debug "Kubernetes minor version: $k8s_minor"

    # CoreDNS (version depends on k3s/k8s version)
    case "$k8s_minor" in
        1.31)
            # K3s v1.31 uses rancher/mirrored-* images from docker.io
            add_image "rancher/mirrored-coredns-coredns" "rancher/mirrored-coredns-coredns:1.12.0" "$temp_file"
            add_image "rancher/mirrored-pause" "rancher/mirrored-pause:3.6" "$temp_file"
            add_image "rancher/mirrored-metrics-server" "rancher/mirrored-metrics-server:v0.7.2" "$temp_file"
            ;;
        1.30)
            add_image "registry.k8s.io/coredns/coredns" "registry.k8s.io/coredns/coredns:v1.11.1" "$temp_file"
            add_image "registry.k8s.io/pause" "registry.k8s.io/pause:3.9" "$temp_file"
            add_image "registry.k8s.io/metrics-server/metrics-server" "registry.k8s.io/metrics-server/metrics-server:v0.7.0" "$temp_file"
            ;;
        1.29)
            add_image "registry.k8s.io/coredns/coredns" "registry.k8s.io/coredns/coredns:v1.10.1" "$temp_file"
            add_image "registry.k8s.io/pause" "registry.k8s.io/pause:3.9" "$temp_file"
            add_image "registry.k8s.io/metrics-server/metrics-server" "registry.k8s.io/metrics-server/metrics-server:v0.6.4" "$temp_file"
            ;;
        *)
            warn "Unknown Kubernetes version $k8s_minor, using v1.31 component versions"
            add_image "rancher/mirrored-coredns-coredns" "rancher/mirrored-coredns-coredns:1.12.0" "$temp_file"
            add_image "rancher/mirrored-pause" "rancher/mirrored-pause:3.6" "$temp_file"
            add_image "rancher/mirrored-metrics-server" "rancher/mirrored-metrics-server:v0.7.2" "$temp_file"
            ;;
    esac

    # Local path provisioner (CSI driver for local storage)
    add_image "rancher/local-path-provisioner" "rancher/local-path-provisioner:v0.0.30" "$temp_file"

    # Traefik (if not disabled) - note: k3s disables it in our install.sh
    # add_image "rancher/mirrored-library-traefik" "rancher/mirrored-library-traefik:2.11.0" "$temp_file"

    # ServiceLB (if not disabled) - note: k3s disables it in our install.sh
    # ServiceLB uses k3s's internal image, no separate image needed

    # Sort and deduplicate
    sort -u "$temp_file" > "$OUTPUT_FILE"
    rm -f "$temp_file"

    local count=$(wc -l < "$OUTPUT_FILE")
    success "Generated list of $count images"
    success "Saved to: $OUTPUT_FILE"
}

add_image() {
    local name=$1
    local source=$2
    local output=$3

    debug "Adding image: $name ($source)"

    if [[ "$FORMAT" == "mapping" ]]; then
        # Parse source image to preserve path structure
        local source_without_tag="${source%:*}"  # Remove tag
        local tag="${source##*:}"                 # Extract tag
        
        # Determine if source has explicit registry domain
        local path_component=""
        if [[ "$source_without_tag" =~ ^([^/]+\.[^/]+)/(.+)$ ]]; then
            # Has explicit registry domain (contains dot before first slash)
            # e.g., "ghcr.io/k3d-io/k3d-tools" -> keep "k3d-io/k3d-tools"
            path_component="${BASH_REMATCH[2]}"
        elif [[ "$source_without_tag" =~ / ]]; then
            # Has slash but no explicit registry (implicit docker.io)
            # e.g., "rancher/k3s" -> keep "rancher/k3s"
            path_component="$source_without_tag"
        else
            # Single component name (implicit docker.io/library)
            # e.g., "docker" -> "library/docker"
            path_component="library/$source_without_tag"
        fi

        # Generate target image path preserving structure
        # If REGISTRY_PATH is set, prepend it
        local target
        if [[ -n "$REGISTRY_PATH" ]]; then
            target="${TARGET_REGISTRY}/${REGISTRY_PATH}/${path_component}:${tag}"
        else
            target="${TARGET_REGISTRY}/${path_component}:${tag}"
        fi

        echo "${source}=${target}" >> "$output"
    else
        # List format - just source images
        echo "$source" >> "$output"
    fi
}

#############################################################################
# Display Summary
#############################################################################

display_summary() {
    echo "" >&2
    success "═══════════════════════════════════════════════════════════" >&2
    success "  Image List Generation Complete!" >&2
    success "═══════════════════════════════════════════════════════════" >&2
    echo "" >&2
    log "Summary:" >&2
    log "  K3s Version:     $K3S_VERSION" >&2
    log "  K3d Version:     $K3D_VERSION" >&2
    log "  Docker Version:  docker:${DOCKER_VERSION}" >&2
    log "  Target Registry: $TARGET_REGISTRY" >&2
    log "  Output File:     $OUTPUT_FILE" >&2
    log "  Format:          $FORMAT" >&2
    echo "" >&2

    local count=$(wc -l < "$OUTPUT_FILE")
    log "Total images: $count" >&2
    echo "" >&2

    if [[ "$FORMAT" == "mapping" ]]; then
        log "Image mappings (first 5):" >&2
        head -5 "$OUTPUT_FILE" | sed 's/^/  /' >&2
        if [[ $count -gt 5 ]]; then
            log "  ... and $((count - 5)) more" >&2
        fi
    else
        log "Images (first 5):" >&2
        head -5 "$OUTPUT_FILE" | sed 's/^/  /' >&2
        if [[ $count -gt 5 ]]; then
            log "  ... and $((count - 5)) more" >&2
        fi
    fi

    echo "" >&2
    log "Next steps:" >&2
    echo "  1. Review the generated file: cat $OUTPUT_FILE" >&2
    echo "  2. Mirror images to your registry: ./mirror-images-to-nexus.sh --input $OUTPUT_FILE" >&2
    echo "" >&2
}

#############################################################################
# Main Execution
#############################################################################

main() {
    parse_args "$@"
    validate_config
    generate_image_list
    display_summary
}

# Run main function
main "$@"
