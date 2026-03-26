#!/usr/bin/env bash
# =============================================================================
# open-ports-control-plane.sh — Open Kubernetes control-plane ports using ufw
# =============================================================================
# Run as root on the control-plane (Ubuntu) node.
# Usage:  sudo bash open-ports-control-plane.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "ERROR: Run as root (sudo)."; exit 1; }

info "Enabling ufw (if not already active)..."
ufw --force enable

info "Opening Kubernetes control-plane ports..."

ufw allow 6443/tcp    comment 'k8s API server'
ufw allow 2379:2380/tcp comment 'k8s etcd'
ufw allow 10250/tcp   comment 'k8s kubelet'
ufw allow 10259/tcp   comment 'k8s kube-scheduler'
ufw allow 10257/tcp   comment 'k8s kube-controller-manager'
ufw allow 8472/udp    comment 'k8s Flannel VXLAN'
ufw allow 30000:32767/tcp comment 'k8s NodePort range'

# Allow SSH so you don't lock yourself out
ufw allow 22/tcp      comment 'SSH'

ufw reload

info "Done. Current rules:"
ufw status verbose
