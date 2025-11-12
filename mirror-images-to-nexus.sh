#!/usr/bin/env bash

#############################################################################
# Image Mirroring Script for Nexus/Private Registry
#
# Mirrors container images from public registries to a private registry.
# Supports authentication, progress tracking, and verification.
#
# Usage:
#   ./mirror-images-to-nexus.sh --registry docker.local --input required-images.txt
#############################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
TARGET_REGISTRY=""
INPUT_FILE="required-images.txt"
USERNAME=""
PASSWORD=""
DRY_RUN=false
VERBOSE=false
SKIP_VERIFY=false
FORCE=false
INSECURE=false
OUTPUT_REPORT=""

# Statistics
TOTAL_IMAGES=0
SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
declare -a FAILED_IMAGES

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
        echo -e "${CYAN}[DEBUG]${NC} $*" >&2
    fi
}

progress() {
    echo -e "${CYAN}[PROGRESS]${NC} $*" >&2
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
            --input|-i)
                INPUT_FILE="$2"
                shift 2
                ;;
            --username|-u)
                USERNAME="$2"
                shift 2
                ;;
            --password|-p)
                PASSWORD="$2"
                shift 2
                ;;
            --output|-o)
                OUTPUT_REPORT="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-verify)
                SKIP_VERIFY=true
                shift
                ;;
            --insecure)
                INSECURE=true
                shift
                ;;
            --force)
                FORCE=true
                shift
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

Mirrors container images from public registries to a private registry.

Required:
  --registry URL          Target registry URL (e.g., docker.local, myregistry.com:5000)

Optional:
  --input FILE            Input file with image mappings (default: ${INPUT_FILE})
                          Format: SOURCE_IMAGE=TARGET_IMAGE
  --username USER         Registry username (will prompt if not provided)
  --password PASS         Registry password (will prompt if not provided)
  --output FILE           Output report file (default: mirrored-images-TIMESTAMP.txt)
  --dry-run               Show what would be done without actually mirroring
  --skip-verify           Skip verification of pushed images
  --insecure              Allow insecure HTTPS connections \(for self-signed certs\)
  --force                 Force push even if image already exists
  --verbose               Show detailed output
  -h, --help              Show this help message

Examples:
  # Interactive (will prompt for credentials)
  $0 --registry docker.local

  # With credentials
  $0 --registry docker.local --username admin --password admin123

  # Dry run to preview
  $0 --registry docker.local --dry-run

  # Force re-push all images
  $0 --registry docker.local --force

  # Custom input file
  $0 --registry docker.local --input my-images.txt

Notes:
  - Requires Docker to be installed and running
  - Input file should contain one image mapping per line (SOURCE=TARGET)
  - Use --dry-run first to preview operations
  - Authentication is required for pushing to private registries

EOF
}

validate_config() {
    if [[ -z "$TARGET_REGISTRY" ]]; then
        fatal "Target registry is required. Use --registry <url>"
    fi

    if [[ ! -f "$INPUT_FILE" ]]; then
        fatal "Input file not found: $INPUT_FILE"
    fi

    debug "Configuration validated:"
    debug "  Target Registry: $TARGET_REGISTRY"
    debug "  Input File: $INPUT_FILE"
    debug "  Dry Run: $DRY_RUN"
    debug "  Skip Verify: $SKIP_VERIFY"
    debug "  Insecure: $INSECURE"
    debug "  Force: $FORCE"
}

#############################################################################
# Docker Prerequisites
#############################################################################

setup_insecure_buildx() {
    log "Configuring buildx for insecure registry..."
    
    local builder_name="insecure-builder"
    local config_file="/tmp/buildkitd-${TARGET_REGISTRY//[:\/.]/-}.toml"
    
    # Create buildkitd.toml configuration for insecure registry
    cat > "$config_file" << EOF
# BuildKit configuration for insecure registries
[registry."${TARGET_REGISTRY}"]
  http = true
  insecure = true
EOF
    
    debug "Created buildkitd config at: $config_file"
    
    # Check if builder already exists
    if docker buildx inspect "$builder_name" &> /dev/null; then
        debug "Builder '$builder_name' already exists, removing it..."
        docker buildx rm "$builder_name" &> /dev/null || true
    fi
    
    # Create new builder with insecure registry support
    log "Creating buildx builder with insecure registry support..."
    if docker buildx create \
        --name "$builder_name" \
        --driver docker-container \
        --buildkitd-config "$config_file" \
        --use &> /dev/null; then
        success "Buildx builder configured for insecure registry: $TARGET_REGISTRY"
    else
        warn "Failed to create buildx builder - will attempt without it"
        warn "Multi-arch images may fail to mirror if registry uses self-signed certs"
    fi
    
    # Bootstrap the builder
    debug "Bootstrapping builder..."
    docker buildx inspect --bootstrap &> /dev/null || true
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check Docker
    if ! command -v docker &> /dev/null; then
        fatal "Docker is not installed or not in PATH"
    fi

    # Check Docker is running
    if ! docker info &> /dev/null; then
        fatal "Docker is not running. Please start Docker and try again."
    fi

    # Check for Docker Buildx (needed for multi-arch support)
    if ! docker buildx version &> /dev/null; then
        warn "Docker buildx not available - multi-arch images will be converted to single-arch"
        warn "To enable multi-arch support: docker buildx create --use"
    else
        debug "Docker buildx available for multi-arch image support"
        
        # Configure buildx for insecure registry if requested
        if [[ "$INSECURE" == "true" ]]; then
            setup_insecure_buildx
        fi
    fi

    # Check input file format
    if ! grep -q "=" "$INPUT_FILE"; then
        fatal "Input file format invalid. Expected format: SOURCE_IMAGE=TARGET_IMAGE"
    fi

    TOTAL_IMAGES=$(grep -c "=" "$INPUT_FILE" || echo "0")
    if [[ $TOTAL_IMAGES -eq 0 ]]; then
        fatal "No images found in input file"
    fi

    success "Prerequisites check passed"
    log "Found $TOTAL_IMAGES images to mirror"
}

#############################################################################
# Authentication
#############################################################################

authenticate_registry() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN - skipping authentication"
        return 0
    fi

    log "Authenticating to registry: $TARGET_REGISTRY"

    # Prompt for credentials if not provided
    if [[ -z "$USERNAME" ]]; then
        read -p "Username: " USERNAME
    fi

    if [[ -z "$PASSWORD" ]]; then
        read -sp "Password: " PASSWORD
        echo "" >&2
    fi

    # Perform docker login
    if echo "$PASSWORD" | docker login "$TARGET_REGISTRY" --username "$USERNAME" --password-stdin &> /dev/null; then
        success "Successfully authenticated to $TARGET_REGISTRY"
    else
        fatal "Authentication failed. Please check your credentials."
    fi
}

#############################################################################
# Image Mirroring
#############################################################################

mirror_images() {
    log "Starting image mirroring..."
    echo "" >&2

    local current=0

    while IFS='=' read -r source target; do
        current=$((current + 1))
        progress "[$current/$TOTAL_IMAGES] Processing: $source"

        if [[ "$DRY_RUN" == "true" ]]; then
            log "  DRY RUN: Would mirror $source -> $target"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            continue
        fi

        # Check if image already exists (unless --force)
        if [[ "$FORCE" != "true" ]] && check_image_exists "$target"; then
            warn "  Image already exists in registry (use --force to re-push)"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi

        # Mirror the image
        if mirror_single_image "$source" "$target"; then
            success "  ✓ Successfully mirrored"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            error "  ✗ Failed to mirror"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_IMAGES+=("$source")
        fi

        echo "" >&2
    done < "$INPUT_FILE"
}

check_image_exists() {
    local target=$1

    debug "Checking if image exists: $target"

    # Try to inspect the image in the registry
    # This is a basic check - might need adjustment based on registry type
    if docker manifest inspect "$target" &> /dev/null; then
        debug "Image exists in registry"
        return 0
    else
        debug "Image does not exist in registry"
        return 1
    fi
}

mirror_single_image() {
    local source=$1
    local target=$2

    debug "Mirroring: $source -> $target"

    # Check if source image is multi-arch
    local is_multiarch=false
    if docker manifest inspect "$source" 2>/dev/null | grep -q "manifests"; then
        local manifest_count=$(docker manifest inspect "$source" 2>/dev/null | grep -c '"platform":')
        if [[ $manifest_count -gt 1 ]]; then
            is_multiarch=true
            log "  Detected multi-arch image with $manifest_count platforms"
        fi
    fi

    if [[ "$is_multiarch" == "true" ]]; then
        # Use buildx imagetools for multi-arch images (preserves all platforms)
        log "  Using buildx imagetools to preserve multi-arch manifest..."
        if ! docker buildx imagetools create --tag "$target" "$source" 2>&1 | grep -v "^$" || true; then
            error "Failed to mirror multi-arch image $source"
            return 1
        fi
    else
        # Use traditional pull/tag/push for single-arch images
        log "  Single-arch image, using pull/tag/push..."
        
        # Step 1: Pull source image
        log "    Pulling from public registry..."
        if ! docker pull "$source" 2>&1 | grep -v "Pulling from" | grep -v "Digest:" | grep -v "Status:" || true; then
            error "Failed to pull $source"
            return 1
        fi

        # Step 2: Tag for target registry
        debug "  Tagging image..."
        if ! docker tag "$source" "$target" 2>&1; then
            error "Failed to tag image"
            return 1
        fi

        # Step 3: Push to target registry
        log "    Pushing to private registry..."
        if ! docker push "$target" 2>&1 | grep -v "Pushing" | grep -v "Pushed" | grep -v "digest:" || true; then
            error "Failed to push $target"
            return 1
        fi
    fi

    # Step 4: Verify (unless skipped)
    if [[ "$SKIP_VERIFY" != "true" ]]; then
        debug "Verifying pushed image..."
        if ! verify_pushed_image "$target"; then
            error "Verification failed for $target"
            return 1
        fi
    fi

    return 0
}

verify_pushed_image() {
    local target=$1

    # Verify by inspecting the manifest
    if docker manifest inspect "$target" &> /dev/null; then
        debug "Verification successful"
        return 0
    else
        debug "Verification failed"
        return 1
    fi
}

#############################################################################
# Reporting
#############################################################################

generate_report() {
    # Set default output file if not specified
    if [[ -z "$OUTPUT_REPORT" ]]; then
        OUTPUT_REPORT="mirrored-images-$(date +%Y%m%d-%H%M%S).txt"
    fi

    log "Generating report..."

    cat > "$OUTPUT_REPORT" << EOF
#############################################################################
# Image Mirroring Report
# Generated: $(date)
#############################################################################

Registry: $TARGET_REGISTRY
Input File: $INPUT_FILE
Total Images: $TOTAL_IMAGES
Successful: $SUCCESS_COUNT
Skipped: $SKIP_COUNT
Failed: $FAIL_COUNT

#############################################################################
# Successfully Mirrored Images
#############################################################################

EOF

    # Add successfully mirrored images
    local current=0
    while IFS='=' read -r source target; do
        current=$((current + 1))
        # Check if this image was in the failed list
        local failed=false
        if [[ $FAIL_COUNT -gt 0 ]]; then
            for failed_img in "${FAILED_IMAGES[@]}"; do
                if [[ "$failed_img" == "$source" ]]; then
                    failed=true
                    break
                fi
            done
        fi

        if [[ "$failed" != "true" ]]; then
            echo "$source -> $target" >> "$OUTPUT_REPORT"
        fi
    done < "$INPUT_FILE"

    # Add failed images section if any
    if [[ $FAIL_COUNT -gt 0 ]]; then
        cat >> "$OUTPUT_REPORT" << EOF

#############################################################################
# Failed Images
#############################################################################

EOF
        for img in "${FAILED_IMAGES[@]}"; do
            echo "$img" >> "$OUTPUT_REPORT"
        done
    fi

    success "Report saved to: $OUTPUT_REPORT"
}

display_summary() {
    echo "" >&2
    success "═══════════════════════════════════════════════════════════" >&2
    success "  Image Mirroring Complete!" >&2
    success "═══════════════════════════════════════════════════════════" >&2
    echo "" >&2
    log "Summary:" >&2
    log "  Total Images:    $TOTAL_IMAGES" >&2
    log "  Successful:      $SUCCESS_COUNT" >&2
    if [[ $SKIP_COUNT -gt 0 ]]; then
        log "  Skipped:         $SKIP_COUNT (already exist)" >&2
    fi
    if [[ $FAIL_COUNT -gt 0 ]]; then
        error "  Failed:          $FAIL_COUNT" >&2
    fi
    echo "" >&2

    if [[ $FAIL_COUNT -gt 0 ]]; then
        error "Some images failed to mirror:" >&2
        for img in "${FAILED_IMAGES[@]}"; do
            echo "  - $img" >&2
        done
        echo "" >&2
        error "Please review errors above and retry failed images" >&2
        echo "" >&2
        exit 1
    else
        if [[ "$DRY_RUN" != "true" ]]; then
            success "All images mirrored successfully!" >&2
            echo "" >&2
            log "Next steps:" >&2
            echo "  1. Verify images in registry: docker image ls | grep $TARGET_REGISTRY" >&2
            echo "  2. Update k3s installation to use private registry" >&2
            echo "  3. Deploy k3s: ./install.sh --name test --private-registry $TARGET_REGISTRY" >&2
        else
            log "DRY RUN complete. Use without --dry-run to actually mirror images." >&2
        fi
        echo "" >&2
    fi
}

#############################################################################
# Cleanup
#############################################################################

cleanup_local_images() {
    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    log "Cleaning up local Docker images..."

    local cleaned=0
    while IFS='=' read -r source target; do
        # Remove source image (optional - saves disk space)
        if docker rmi "$source" &> /dev/null; then
            cleaned=$((cleaned + 1))
        fi

        # Keep target image tagged (optional - could remove to save space)
        # docker rmi "$target" &> /dev/null || true
    done < "$INPUT_FILE"

    if [[ $cleaned -gt 0 ]]; then
        debug "Cleaned up $cleaned source images"
    fi
}

#############################################################################
# Main Execution
#############################################################################

main() {
    parse_args "$@"
    validate_config
    check_prerequisites

    if [[ "$DRY_RUN" != "true" ]]; then
        authenticate_registry
    fi

    mirror_images
    generate_report
    display_summary

    # Optional: cleanup local images to save disk space
    # cleanup_local_images
}

# Run main function
main "$@"
