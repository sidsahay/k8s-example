# Node Setup Scripts

These scripts install and configure Kubernetes on bare-metal nodes. They auto-detect the OS and use the correct package manager.

## Supported Operating Systems

| OS | Version | Package Manager |
|----|---------|-----------------|
| Ubuntu | 22.04, 24.04 | `apt` |
| Fedora | 43+ | `dnf` |

## Prerequisites

- Root / sudo access on every node
- All nodes can reach each other over the network
- Ports open between nodes: `6443` (API), `10250` (kubelet), `8472/udp` (Flannel VXLAN)
  - On Fedora, the scripts open firewall ports automatically via `firewall-cmd`

---

## Step 1 — Set up the Control-Plane Node

Run **once** on the node you designate as the control-plane:

```bash
sudo bash setup-control-plane.sh
```

The script will:
1. Detect OS (Ubuntu or Fedora) and use the correct package manager
2. Install system prerequisites (`curl`, `socat`, `conntrack`, etc.)
3. Disable swap (including zram on Fedora)
4. Load required kernel modules (`overlay`, `br_netfilter`)
5. Configure sysctl for K8s networking
6. Install and configure **containerd** with the systemd cgroup driver
7. Set SELinux to permissive (Fedora only)
8. Install **kubeadm**, **kubelet**, **kubectl** (pinned to v1.30)
9. Open firewall ports (Fedora only, via `firewall-cmd`)
10. Run `kubeadm init` to initialise the control plane
11. Configure `~/.kube/config` for the invoking user
12. Install **Flannel** CNI

At the end, the script prints a `kubeadm join` command — **save this output**.

### Re-generate the join command later

```bash
kubeadm token create --print-join-command
```

---

## Step 2 — Join Worker Nodes

Run on **each worker node**, substituting the values from the control-plane output:

```bash
sudo MASTER_IP=<control-plane-ip> \
     JOIN_TOKEN=<token> \
     CA_HASH=sha256:<hash> \
     bash setup-worker.sh
```

Example:

```bash
sudo MASTER_IP=192.168.1.10 \
     JOIN_TOKEN=abc123.xyz789abcdef0123 \
     CA_HASH=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
     bash setup-worker.sh
```

The script repeats the same pre-flight steps (swap, kernel modules, containerd, k8s binaries, SELinux/firewall on Fedora), then calls `kubeadm join`.

> [!NOTE]
> You can mix Ubuntu and Fedora nodes in the same cluster — the scripts handle each OS independently.

---

## Step 3 — Verify the Cluster

Back on the **control-plane node**:

```bash
kubectl get nodes
```

Expected output (~60s after last worker joined):

```
NAME           STATUS   ROLES           AGE   VERSION
control-plane  Ready    control-plane   5m    v1.30.x
worker-01      Ready    <none>          3m    v1.30.x
worker-02      Ready    <none>          2m    v1.30.x
```

---

## Step 4 — Run the Load Test

From the project root (requires `kubectl` configured and kvstore deployed):

```bash
bash scripts/run-load-test.sh
```

See the top-level [README.md](../README.md) for the full deployment workflow.
