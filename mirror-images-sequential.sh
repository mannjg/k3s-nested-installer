#!/usr/bin/env bash
# Sequential image mirroring with delays to avoid Nexus overload

set -euo pipefail

REGISTRY="$1"
INPUT_FILE="${2:-required-images.txt}"
DELAY="${3:-5}"  # Seconds between pushes

if [[ -z "$REGISTRY" ]]; then
    echo "Usage: $0 <registry> [input-file] [delay-seconds]"
    echo "Example: $0 docker.local required-images.txt 5"
    exit 1
fi

echo "Sequential mirroring to: $REGISTRY"
echo "Input file: $INPUT_FILE"
echo "Delay between images: ${DELAY}s"
echo ""

count=0
success=0
failed=0

while IFS='=' read -r source target; do
    count=$((count + 1))
    echo "[$count] Processing: $source"

    echo "  → Pulling..."
    if docker pull "$source"; then
        echo "  → Tagging..."
        if docker tag "$source" "$target"; then
            echo "  → Pushing..."
            if docker push "$target"; then
                echo "  ✓ Success"
                success=$((success + 1))
            else
                echo "  ✗ Push failed"
                failed=$((failed + 1))
            fi
        else
            echo "  ✗ Tag failed"
            failed=$((failed + 1))
        fi
    else
        echo "  ✗ Pull failed"
        failed=$((failed + 1))
    fi

    echo ""

    # Delay before next image to avoid overwhelming Nexus
    if [[ $DELAY -gt 0 ]]; then
        echo "Waiting ${DELAY}s before next image..."
        sleep "$DELAY"
        echo ""
    fi

done < "$INPUT_FILE"

echo "========================================="
echo "Mirroring Complete"
echo "  Total: $count"
echo "  Success: $success"
echo "  Failed: $failed"
echo "========================================="

if [[ $failed -gt 0 ]]; then
    exit 1
fi
