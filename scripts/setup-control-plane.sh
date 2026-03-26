#!/usr/bin/env bash
# =============================================================================
# setup-control-plane.sh — Bootstrap a Kubernetes control-plane node
# =============================================================================
# Supported OS: Ubuntu 22.04 / 24.04, Fedora 43
#
# Run this script AS ROOT on the machine you want to be the Kubernetes
# control-plane node.
#
# Usage:
#   sudo bash setup-control-plane.sh
#
# After it completes, it will print a `kubeadm join` command.
# Copy that command and use it in setup-worker.sh on each worker node.
# =============================================================================

set -euo pipefail

# ── Configurable variables ───────────────────────────────────────────────────
K8S_VERSION="1.30"          # Kubernetes minor version to install
POD_CIDR="10.244.0.0/16"   # Flannel default; change if using a different CNI
FLANNEL_VERSION="v0.25.4"
# ────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "This script must be run as root (use sudo)."

# ── Detect OS ────────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID}"           # ubuntu | fedora
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

# ══════════════════════════════════════════════════════════════════════════════
# Helper: wait for apt lock (Ubuntu's unattended-upgrades can hold it)
# ══════════════════════════════════════════════════════════════════════════════

wait_for_apt_lock() {
    local max_wait=120
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null || \
          fuser /var/lib/dpkg/lock &>/dev/null || \
          fuser /var/lib/apt/lists/lock &>/dev/null; do
        if [[ $waited -eq 0 ]]; then
            warn "Waiting for apt lock (another process like unattended-upgrades is running)..."
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $waited -ge $max_wait ]]; then
            error "Timed out after ${max_wait}s waiting for apt lock. Kill the holding process or try again."
        fi
    done
    if [[ $waited -gt 0 ]]; then
        info "apt lock released after ~${waited}s"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Helper: package install functions
# ══════════════════════════════════════════════════════════════════════════════

install_prerequisites_apt() {
    wait_for_apt_lock
    apt-get update -qq
    wait_for_apt_lock
    apt-get install -y -qq \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        socat \
        conntrack \
        ipset \
        jq
}

install_prerequisites_dnf() {
    dnf install -y -q \
        ca-certificates \
        curl \
        gnupg2 \
        socat \
        conntrack-tools \
        ipset \
        jq \
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

    wait_for_apt_lock
    apt-get update -qq
    wait_for_apt_lock
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

    wait_for_apt_lock
    apt-get update -qq
    wait_for_apt_lock
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

    # Pin versions — install versionlock plugin if needed
    if ! dnf versionlock list &>/dev/null; then
        dnf install -y -q 'dnf-command(versionlock)' || dnf install -y -q python3-dnf-plugin-versionlock || true
    fi
    dnf versionlock add kubelet kubeadm kubectl 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# Main setup steps
# ══════════════════════════════════════════════════════════════════════════════

# ── 1. System prerequisites ──────────────────────────────────────────────────
info "Step 1/9 — Installing system prerequisites..."
case "${PKG_MGR}" in
    apt) install_prerequisites_apt ;;
    dnf) install_prerequisites_dnf ;;
esac

# ── 2. Configure kubelet to tolerate swap ─────────────────────────────────────
info "Step 2/9 — Configuring kubelet to allow swap..."
mkdir -p /etc/default
# Tell kubelet not to fail if swap is on (--fail-swap-on=false)
cat <<EOF > /var/lib/kubelet/config-patches.yaml
failSwapOn: false
EOF
# Also set via environment for older kubelet versions
if [[ -f /etc/default/kubelet ]]; then
    grep -q 'fail-swap-on' /etc/default/kubelet || \
        echo 'KUBELET_EXTRA_ARGS="--fail-swap-on=false"' >> /etc/default/kubelet
else
    echo 'KUBELET_EXTRA_ARGS="--fail-swap-on=false"' > /etc/default/kubelet
fi

# ── 3. Load kernel modules ───────────────────────────────────────────────────
info "Step 3/9 — Loading kernel modules..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# ── 4. Kernel networking parameters ─────────────────────────────────────────
info "Step 4/9 — Configuring sysctl for Kubernetes networking..."
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q

# ── 5. Install containerd (CRI) ──────────────────────────────────────────────
info "Step 5/9 — Installing containerd..."
case "${PKG_MGR}" in
    apt) install_containerd_apt ;;
    dnf) install_containerd_dnf ;;
esac

# Configure containerd to use systemd cgroup driver (same on both distros)
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ── 6. Disable SELinux to permissive (Fedora) or skip (Ubuntu) ───────────────
if [[ "${OS_ID}" == "fedora" ]]; then
    info "Step 5.5/9 — Setting SELinux to permissive..."
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
fi

# ── 6. Install kubeadm, kubelet, kubectl ─────────────────────────────────────
info "Step 6/9 — Installing kubeadm, kubelet, kubectl (v${K8S_VERSION})..."
case "${PKG_MGR}" in
    apt) install_k8s_apt ;;
    dnf) install_k8s_dnf ;;
esac

systemctl enable --now kubelet

# ── 7. Open firewall ports (Fedora) ──────────────────────────────────────────
if [[ "${OS_ID}" == "fedora" ]] && command -v firewall-cmd &>/dev/null; then
    info "Step 6.5/9 — Opening firewall ports for Kubernetes..."
    firewall-cmd --permanent --add-port=6443/tcp      # API server
    firewall-cmd --permanent --add-port=2379-2380/tcp  # etcd
    firewall-cmd --permanent --add-port=10250/tcp      # kubelet
    firewall-cmd --permanent --add-port=10259/tcp      # kube-scheduler
    firewall-cmd --permanent --add-port=10257/tcp      # kube-controller-manager
    firewall-cmd --permanent --add-port=8472/udp       # Flannel VXLAN
    firewall-cmd --reload
fi

# ── 7. Initialize the control plane ─────────────────────────────────────────
info "Step 7/9 — Initializing Kubernetes control plane..."
NODE_IP=$(hostname -I | awk '{print $1}')
info "  Detected control-plane IP: ${NODE_IP}"

kubeadm init \
    --pod-network-cidr="${POD_CIDR}" \
    --apiserver-advertise-address="${NODE_IP}" \
    --cri-socket unix:///run/containerd/containerd.sock \
    | tee /tmp/kubeadm-init.log

# ── 8. Configure kubectl for the current user ────────────────────────────────
info "Step 8/9 — Configuring kubectl..."
SUDO_USER_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
mkdir -p "${SUDO_USER_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${SUDO_USER_HOME}/.kube/config"
chown "$(id -u "${SUDO_USER:-root}"):$(id -g "${SUDO_USER:-root}")" \
    "${SUDO_USER_HOME}/.kube/config"

# Also set up for root in this shell session
export KUBECONFIG=/etc/kubernetes/admin.conf

# ── 9. Install Flannel CNI ───────────────────────────────────────────────────
info "Step 9/9 — Installing Flannel CNI (${FLANNEL_VERSION})..."
kubectl apply -f \
    "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"

# ── Done — print the join command ────────────────────────────────────────────
echo ""
echo "============================================================"
echo -e "${GREEN}✔ Control plane initialized successfully!${NC}"
echo "============================================================"
echo ""
echo "Run the following to check node status (may take ~60s):"
echo "  kubectl get nodes"
echo ""
echo ">>> WORKER JOIN COMMAND (save this): <<<"
echo ""
# Extract and display the join command
grep -A2 "kubeadm join" /tmp/kubeadm-init.log | tail -3
echo ""
echo "Or re-generate it at any time with:"
echo "  kubeadm token create --print-join-command"
echo "============================================================"
