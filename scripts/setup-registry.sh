#!/usr/bin/env bash
# =============================================================================
# setup-registry.sh — Run a local Docker registry on the control-plane node
# =============================================================================
# Starts a Docker registry container on port 5000, backed by /bucket/docker-registry.
# Registry URL: terminus.lan.local.cmu.edu:5000
#
# Usage:  sudo bash setup-registry.sh
# =============================================================================

set -euo pipefail

REGISTRY_HOST="terminus.lan.local.cmu.edu"
REGISTRY_PORT="5000"
REGISTRY_STORAGE="/bucket/docker-registry"
REGISTRY_NAME="docker-registry"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "ERROR: Run as root (sudo)."; exit 1; }

# ── 1. Ensure Docker is available ────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is not installed. Install Docker first."
    exit 1
fi

# ── 2. Create storage directory ──────────────────────────────────────────────
info "Creating registry storage at ${REGISTRY_STORAGE}..."
mkdir -p "${REGISTRY_STORAGE}"

# ── 3. Stop existing registry container if running ───────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
    info "Stopping existing registry container..."
    docker stop "${REGISTRY_NAME}" 2>/dev/null || true
    docker rm "${REGISTRY_NAME}" 2>/dev/null || true
fi

# ── 4. Start the registry ───────────────────────────────────────────────────
info "Starting Docker registry on ${REGISTRY_HOST}:${REGISTRY_PORT}..."
docker run -d \
    --name "${REGISTRY_NAME}" \
    --restart=always \
    -p "${REGISTRY_PORT}:5000" \
    -v "${REGISTRY_STORAGE}:/var/lib/registry" \
    registry:2

# ── 5. Configure containerd to trust insecure registry ──────────────────────
# This is needed because we're not using TLS for the local registry.
info "Configuring containerd to trust insecure registry..."
CONTAINERD_HOSTS_DIR="/etc/containerd/certs.d/${REGISTRY_HOST}:${REGISTRY_PORT}"
mkdir -p "${CONTAINERD_HOSTS_DIR}"
cat <<EOF > "${CONTAINERD_HOSTS_DIR}/hosts.toml"
server = "http://${REGISTRY_HOST}:${REGISTRY_PORT}"

[host."http://${REGISTRY_HOST}:${REGISTRY_PORT}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

# Also configure Docker daemon for insecure registry (for docker push/pull)
info "Configuring Docker daemon for insecure registry..."
DOCKER_DAEMON="/etc/docker/daemon.json"
mkdir -p /etc/docker
if [[ -f "${DOCKER_DAEMON}" ]]; then
    # Add insecure registry if not already present
    if ! grep -q "${REGISTRY_HOST}:${REGISTRY_PORT}" "${DOCKER_DAEMON}"; then
        # Use python3/jq to merge, or just overwrite if simple
        if command -v jq &>/dev/null; then
            jq --arg reg "${REGISTRY_HOST}:${REGISTRY_PORT}" \
                '.["insecure-registries"] += [$reg] | .["insecure-registries"] |= unique' \
                "${DOCKER_DAEMON}" > /tmp/daemon.json && mv /tmp/daemon.json "${DOCKER_DAEMON}"
        else
            warn "jq not found — overwriting daemon.json"
            echo "{\"insecure-registries\": [\"${REGISTRY_HOST}:${REGISTRY_PORT}\"]}" > "${DOCKER_DAEMON}"
        fi
    fi
else
    echo "{\"insecure-registries\": [\"${REGISTRY_HOST}:${REGISTRY_PORT}\"]}" > "${DOCKER_DAEMON}"
fi

systemctl restart docker 2>/dev/null || true
systemctl restart containerd 2>/dev/null || true

# ── 6. Open firewall port ───────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    info "Opening port ${REGISTRY_PORT} in ufw..."
    ufw allow "${REGISTRY_PORT}/tcp" comment 'Docker registry' || true
fi

# ── 7. Verify ────────────────────────────────────────────────────────────────
info "Waiting for registry to come up..."
sleep 3
if curl -sf "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null; then
    info "✔ Registry is running at http://${REGISTRY_HOST}:${REGISTRY_PORT}"
else
    warn "Registry may still be starting. Check: docker logs ${REGISTRY_NAME}"
fi

echo ""
echo "============================================================"
echo "Registry:  http://${REGISTRY_HOST}:${REGISTRY_PORT}"
echo "Storage:   ${REGISTRY_STORAGE}"
echo ""
echo "IMPORTANT: On each worker node, run:"
echo "  sudo bash configure-registry-client.sh"
echo "to trust this insecure registry before pulling images."
echo "============================================================"
