#!/usr/bin/env bash
# =============================================================================
# build-and-push.sh — Build the kvstore image and push to the local registry
# =============================================================================
# Run from the project root (or anywhere — it finds the Dockerfile).
#
# Usage:  bash build-and-push.sh [TAG]
#   TAG defaults to "latest"
#
# Example:
#   bash scripts/build-and-push.sh
#   bash scripts/build-and-push.sh v1.2
# =============================================================================

set -euo pipefail

REGISTRY="terminus.lan.local.cmu.edu:5000"
IMAGE_NAME="kvstore"
TAG="${1:-latest}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }

# ── 1. Build ─────────────────────────────────────────────────────────────────
info "Building ${IMAGE_NAME}:${TAG} from ${PROJECT_ROOT}/app ..."
docker build -t "${IMAGE_NAME}:${TAG}" "${PROJECT_ROOT}/app"

# ── 2. Tag for registry ──────────────────────────────────────────────────────
info "Tagging as ${FULL_IMAGE} ..."
docker tag "${IMAGE_NAME}:${TAG}" "${FULL_IMAGE}"

# ── 3. Push ──────────────────────────────────────────────────────────────────
info "Pushing to ${REGISTRY} ..."
docker push "${FULL_IMAGE}"

# ── 4. Verify ────────────────────────────────────────────────────────────────
info "Verifying image in registry..."
if curl -sf "http://${REGISTRY}/v2/${IMAGE_NAME}/tags/list" 2>/dev/null; then
    echo ""
fi

echo ""
info "✔ Image pushed: ${FULL_IMAGE}"
echo ""
echo "To deploy to Kubernetes, update k8s/deployment.yaml:"
echo "  image: ${FULL_IMAGE}"
echo "  imagePullPolicy: Always"
