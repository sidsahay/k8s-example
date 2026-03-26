#!/usr/bin/env bash
# =============================================================================
# setup-worker.sh — Join a worker node to an existing Kubernetes cluster
# =============================================================================
# Supported OS: Ubuntu 22.04 / 24.04, Fedora 43
#
# Run this script AS ROOT on EACH worker node you want to add to the cluster.
#
# Required environment variables (set before running):
#   MASTER_IP   — IP address of the control-plane node
#   JOIN_TOKEN  — Token printed by setup-control-plane.sh
#                 (e.g. abc123.xyz789abcdef0123)
#   CA_HASH     — CA cert hash printed by setup-control-plane.sh
#                 (e.g. sha256:0123456789abcdef...)
#
# Usage:
#   sudo MASTER_IP=192.168.1.10 \
#        JOIN_TOKEN=abc123.xyz789abcdef0123 \
#        CA_HASH=sha256:0123456789abcdef... \
#        bash setup-worker.sh
#
# Or export vars first:
#   export MASTER_IP=192.168.1.10
#   export JOIN_TOKEN=abc123.xyz789abcdef0123
#   export CA_HASH=sha256:0123456789abcdef...
#   sudo -E bash setup-worker.sh
# =============================================================================

set -euo pipefail

# ── Configurable variables ───────────────────────────────────────────────────
K8S_VERSION="1.30"   # Must match the control-plane version
# ────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root (use sudo)."

# ── Validate required env vars ───────────────────────────────────────────────
: "${MASTER_IP:?  ERROR: MASTER_IP env var is required (IP of the control-plane node)}"
: "${JOIN_TOKEN:?  ERROR: JOIN_TOKEN env var is required (from kubeadm init output)}"
: "${CA_HASH:?    ERROR: CA_HASH env var is required (from kubeadm init output, sha256:...)}"

# ── Detect OS ────────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
    else
        error "Cannot detect OS — /etc/os-release not found."
    fi

    case "${OS_ID}" in
        ubuntu)
            if [[ "${OS_VERSION}" != "22.04" && "${OS_VERSION}" != "24.04" ]]; then
                warn "Tested on Ubuntu 22.04 / 24.04 — your version (${OS_VERSION}) may work but is untested."
            fi
            PKG_MGR="apt"
            ;;
        fedora)
            if [[ "${OS_VERSION}" -lt 43 ]]; then
                warn "Tested on Fedora 43 — your version (${OS_VERSION}) may work but is untested."
            fi
            PKG_MGR="dnf"
            ;;
        *)
            error "Unsupported OS: ${OS_ID} ${OS_VERSION}. Supported: Ubuntu 22.04/24.04, Fedora 43."
            ;;
    esac
    info "Detected OS: ${OS_ID} ${OS_VERSION} (package manager: ${PKG_MGR})"
}
detect_os

info "Joining cluster at ${MASTER_IP} ..."

# ══════════════════════════════════════════════════════════════════════════════
# Helper: package install functions (same as setup-control-plane.sh)
# ══════════════════════════════════════════════════════════════════════════════

install_prerequisites_apt() {
    apt-get update -qq
    apt-get install -y -qq \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        socat \
        conntrack \
        ipset
}

install_prerequisites_dnf() {
    dnf install -y -q \
        ca-certificates \
        curl \
        gnupg2 \
        socat \
        conntrack-tools \
        ipset \
        iproute-tc
}

install_containerd_apt() {
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq containerd.io
}

install_containerd_dnf() {
    dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
        || dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
        || true
    dnf install -y -q containerd.io
}

install_k8s_apt() {
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
        | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
        https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list

    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
}

install_k8s_dnf() {
    cat <<REPO > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
REPO
    dnf install -y -q kubelet kubeadm kubectl

    if ! dnf versionlock list &>/dev/null; then
        dnf install -y -q 'dnf-command(versionlock)' || dnf install -y -q python3-dnf-plugin-versionlock || true
    fi
    dnf versionlock add kubelet kubeadm kubectl 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# Main setup steps
# ══════════════════════════════════════════════════════════════════════════════

# ── 1. System prerequisites ──────────────────────────────────────────────────
info "Step 1/8 — Installing system prerequisites..."
case "${PKG_MGR}" in
    apt) install_prerequisites_apt ;;
    dnf) install_prerequisites_dnf ;;
esac

# ── 2. Disable swap ──────────────────────────────────────────────────────────
info "Step 2/8 — Disabling swap..."
swapoff -a || true
sed -i '/\sswap\s/s/^/#/' /etc/fstab 2>/dev/null || true
if [[ "${OS_ID}" == "fedora" ]]; then
    systemctl disable --now zram-generator-defaults.target 2>/dev/null || true
    systemctl stop dev-zram0.swap 2>/dev/null || true
    rm -f /etc/systemd/zram-generator.conf 2>/dev/null || true
    if [[ -d /usr/lib/systemd/zram-generator.conf.d ]]; then
        rm -f /usr/lib/systemd/zram-generator.conf.d/*.conf 2>/dev/null || true
    fi
fi

# ── 3. Kernel modules & sysctl ───────────────────────────────────────────────
info "Step 3/8 — Loading kernel modules and setting sysctl parameters..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q

# ── 4. Install containerd ────────────────────────────────────────────────────
info "Step 4/8 — Installing containerd..."
case "${PKG_MGR}" in
    apt) install_containerd_apt ;;
    dnf) install_containerd_dnf ;;
esac

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ── 5. SELinux (Fedora only) ─────────────────────────────────────────────────
if [[ "${OS_ID}" == "fedora" ]]; then
    info "Step 4.5/8 — Setting SELinux to permissive..."
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
fi

# ── 5. Install kubeadm, kubelet, kubectl ─────────────────────────────────────
info "Step 5/8 — Installing kubeadm, kubelet, kubectl (v${K8S_VERSION})..."
case "${PKG_MGR}" in
    apt) install_k8s_apt ;;
    dnf) install_k8s_dnf ;;
esac

systemctl enable --now kubelet

# ── 6. Open firewall ports (Fedora) ──────────────────────────────────────────
if [[ "${OS_ID}" == "fedora" ]] && command -v firewall-cmd &>/dev/null; then
    info "Step 5.5/8 — Opening firewall ports for Kubernetes worker..."
    firewall-cmd --permanent --add-port=10250/tcp      # kubelet
    firewall-cmd --permanent --add-port=10256/tcp      # kube-proxy health
    firewall-cmd --permanent --add-port=30000-32767/tcp # NodePort range
    firewall-cmd --permanent --add-port=8472/udp       # Flannel VXLAN
    firewall-cmd --reload
fi

# ── 7. Join the cluster ──────────────────────────────────────────────────────
info "Step 6/8 — Joining Kubernetes cluster..."
kubeadm join "${MASTER_IP}:6443" \
    --token "${JOIN_TOKEN}" \
    --discovery-token-ca-cert-hash "${CA_HASH}" \
    --cri-socket unix:///run/containerd/containerd.sock

# ── 8. Verify kubelet is running ─────────────────────────────────────────────
info "Step 7/8 — Verifying kubelet status..."
sleep 5
if systemctl is-active --quiet kubelet; then
    info "kubelet is active ✔"
else
    warn "kubelet does not appear to be running. Check: journalctl -u kubelet -n 50"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo -e "${GREEN}✔ Worker node joined the cluster successfully!${NC}"
echo "============================================================"
echo ""
echo "On the CONTROL-PLANE node, verify with:"
echo "  kubectl get nodes"
echo ""
echo "The node may take ~60s to transition from NotReady → Ready"
echo "while Flannel initialises the pod network on this node."
echo "============================================================"
