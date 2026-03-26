#!/usr/bin/env bash
# =============================================================================
# configure-registry-client.sh — Configure a worker node to pull from the
#                                 local Docker registry
# =============================================================================
# Run as root on EACH WORKER node so that containerd (and optionally Docker)
# can pull images from the insecure local registry.
#
# Usage:  sudo bash configure-registry-client.sh
# =============================================================================

set -euo pipefail

REGISTRY_HOST="terminus.lan.local.cmu.edu"
REGISTRY_PORT="5000"
REGISTRY="${REGISTRY_HOST}:${REGISTRY_PORT}"
IMAGE_NAME="kvstore"
TAG="${1:-latest}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "ERROR: Run as root (sudo)."; exit 1; }

# ── 1. Configure containerd to trust the insecure registry ──────────────────
info "Configuring containerd to trust ${REGISTRY}..."
CONTAINERD_HOSTS_DIR="/etc/containerd/certs.d/${REGISTRY}"
mkdir -p "${CONTAINERD_HOSTS_DIR}"
cat <<EOF > "${CONTAINERD_HOSTS_DIR}/hosts.toml"
server = "http://${REGISTRY}"

[host."http://${REGISTRY}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# Ensure containerd config references the hosts dir
# Add config_path if not already set
CONTAINERD_CONFIG="/etc/containerd/config.toml"
if [[ -f "${CONTAINERD_CONFIG}" ]]; then
    if ! grep -q 'config_path' "${CONTAINERD_CONFIG}"; then
        info "Adding registry mirror config_path to containerd config..."
        sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]/a\        config_path = "/etc/containerd/certs.d"' \
            "${CONTAINERD_CONFIG}" 2>/dev/null || true
    fi
fi

systemctl restart containerd

# ── 2. Configure Docker daemon (if Docker is present) ───────────────────────
if command -v docker &>/dev/null; then
    info "Configuring Docker daemon for insecure registry..."
    DOCKER_DAEMON="/etc/docker/daemon.json"
    mkdir -p /etc/docker
    if [[ -f "${DOCKER_DAEMON}" ]]; then
        if ! grep -q "${REGISTRY}" "${DOCKER_DAEMON}"; then
            if command -v jq &>/dev/null; then
                jq --arg reg "${REGISTRY}" \
                    '.["insecure-registries"] += [$reg] | .["insecure-registries"] |= unique' \
                    "${DOCKER_DAEMON}" > /tmp/daemon.json && mv /tmp/daemon.json "${DOCKER_DAEMON}"
            else
                warn "jq not found — overwriting daemon.json"
                echo "{\"insecure-registries\": [\"${REGISTRY}\"]}" > "${DOCKER_DAEMON}"
            fi
        fi
    else
        echo "{\"insecure-registries\": [\"${REGISTRY}\"]}" > "${DOCKER_DAEMON}"
    fi
    systemctl restart docker 2>/dev/null || true
fi

# ── 3. Test pull ─────────────────────────────────────────────────────────────
info "Testing: pulling ${FULL_IMAGE} via crictl..."
if command -v crictl &>/dev/null; then
    crictl pull "${FULL_IMAGE}" && info "✔ Pull successful!" \
        || warn "Pull failed — the image may not be pushed yet. Run build-and-push.sh on the control-plane first."
else
    warn "crictl not found. containerd is configured — images will be pulled when K8s pods start."
fi

echo ""
echo "============================================================"
info "Worker node configured to pull from ${REGISTRY}"
echo "  containerd: /etc/containerd/certs.d/${REGISTRY}/hosts.toml"
if command -v docker &>/dev/null; then
    echo "  docker:     /etc/docker/daemon.json"
fi
echo "============================================================"
