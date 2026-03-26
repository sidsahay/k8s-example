#!/usr/bin/env bash
# =============================================================================
# open-ports-worker.sh — Open Kubernetes worker node ports using ufw
# =============================================================================
# Run as root on each worker (Ubuntu) node.
# Usage:  sudo bash open-ports-worker.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "ERROR: Run as root (sudo)."; exit 1; }

info "Enabling ufw (if not already active)..."
ufw --force enable

info "Opening Kubernetes worker node ports..."

ufw allow 10250/tcp   comment 'k8s kubelet'
ufw allow 10256/tcp   comment 'k8s kube-proxy health'
ufw allow 8472/udp    comment 'k8s Flannel VXLAN'
ufw allow 30000:32767/tcp comment 'k8s NodePort range'

# Allow SSH so you don't lock yourself out
ufw allow 22/tcp      comment 'SSH'

ufw reload

info "Done. Current rules:"
ufw status verbose
