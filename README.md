# k8s-example — Kubernetes HPA Scaling Demo

A self-contained demo showing a Python **key-value store** service that Kubernetes automatically scales up and down based on CPU load, powered by a fake traffic generator.

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                              │
│  ┌──────────────┐    ┌─────────────────────────────────┐    │
│  │ load-gen Job │───▶│  kvstore Service (ClusterIP)    │    │
│  └──────────────┘    └──────────┬──────────────────────┘    │
│                                 │                            │
│                    ┌────────────▼──────────────┐            │
│                    │  kvstore Pod (replica 1)  │            │
│                    │  kvstore Pod (replica 2)  │  ←─ HPA   │
│                    │  kvstore Pod (replica N)  │            │
│                    └───────────────────────────┘            │
│                                 ▲                            │
│                    ┌────────────┴──────────────┐            │
│                    │   HorizontalPodAutoscaler  │            │
│                    │  CPU target: 50%           │            │
│                    │  min: 1  max: 10           │            │
│                    └───────────────────────────┘            │
└─────────────────────────────────────────────────────────────┘
```

## Project Structure

```
k8s-example/
├── app/
│   ├── main.py            # Flask key-value store service
│   ├── requirements.txt
│   └── Dockerfile
├── load-generator/
│   └── load_gen.py        # Fake traffic generator
├── k8s/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml    # kvstore Deployment (1–10 replicas)
│   ├── service.yaml       # ClusterIP + NodePort
│   ├── hpa.yaml           # HorizontalPodAutoscaler
│   ├── metrics-server.yaml
│   └── load-generator-job.yaml
└── scripts/
    ├── setup-control-plane.sh     # Bootstrap control-plane node
    ├── setup-worker.sh            # Join worker nodes
    ├── setup-registry.sh          # Run a local Docker registry on the control-plane
    ├── configure-registry-client.sh # Configure worker nodes to pull from the registry
    ├── build-and-push.sh          # Build the kvstore image and push to the registry
    ├── open-ports-control-plane.sh
    ├── open-ports-worker.sh
    ├── run-load-test.sh           # Deploy load generator + watch HPA
    └── README.md
```

---

## Quick Start

### 1. Set up the cluster

Follow **[scripts/README.md](scripts/README.md)** to install Kubernetes on your nodes.

**Control-plane node:**
```bash
sudo bash scripts/setup-control-plane.sh
# Note the `kubeadm join` command in the output!
```

**Each worker node:**
```bash
sudo MASTER_IP=<master-ip> \
     JOIN_TOKEN=<token> \
     CA_HASH=sha256:<hash> \
     bash scripts/setup-worker.sh
```

Verify:
```bash
kubectl get nodes    # All nodes should be Ready
```

### 2. Set up the local Docker registry

A private registry on the control-plane node lets you push once and pull from every node — no manual `docker save / scp` required.

**On the control-plane node:**
```bash
sudo bash scripts/setup-registry.sh
```

This starts a `registry:2` container on port **5000**, backed by `/bucket/docker-registry`, and configures both containerd and Docker to trust it.

**On each worker node:**
```bash
sudo bash scripts/configure-registry-client.sh
```

This configures containerd (and Docker if present) to pull from `terminus.lan.local.cmu.edu:5000` as an insecure registry.

### 3. Build and push the kvstore image

From the project root (on any machine that has Docker and can reach the registry):

```bash
bash scripts/build-and-push.sh          # pushes kvstore:latest
bash scripts/build-and-push.sh v1.2      # pushes kvstore:v1.2
```

Then update `k8s/deployment.yaml`:
```yaml
image: terminus.lan.local.cmu.edu:5000/kvstore:latest
imagePullPolicy: Always
```

### 4. Install metrics-server (required for HPA)

> Run all remaining `kubectl` commands on the **control-plane node** (or any machine with a valid kubeconfig).

```bash
kubectl apply -f k8s/metrics-server.yaml
# Wait ~60s, then verify:
kubectl top nodes
```

### 5. Deploy the kvstore

Still on the **control-plane node**:

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml
```

Check everything is running:
```bash
kubectl get all -n kvstore
kubectl get hpa -n kvstore
```

### 6. Test the service manually

```bash
# Get any node's IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')

# Set a key
curl -X POST http://${NODE_IP}:30000/set \
  -H 'Content-Type: application/json' \
  -d '{"key":"hello","value":"world"}'

# Get it back
curl http://${NODE_IP}:30000/get/hello

# List all keys
curl http://${NODE_IP}:30000/keys

# Health check
curl http://${NODE_IP}:30000/health
```

### 7. Run the load test and watch HPA scale up

```bash
bash scripts/run-load-test.sh
```

In a separate terminal:
```bash
# Watch HPA make scaling decisions in real time
kubectl get hpa -n kvstore -w

# Watch pod count change
kubectl get pods -n kvstore -w

# Follow load-generator logs
kubectl logs -n kvstore -l app=load-generator -f
```

You should see replicas climb from **1 → ~5–8** within 1–2 minutes, then scale back down to **1** roughly 60–90s after the Job completes.

---

## Key-Value Store API

| Method | Path | Body | Description |
|--------|------|------|-------------|
| `GET` | `/health` | — | Liveness / readiness check |
| `POST` | `/set` | `{"key":"k","value":"v"}` | Create or update a key |
| `GET` | `/get/<key>` | — | Retrieve a key's value |
| `DELETE` | `/delete/<key>` | — | Remove a key |
| `GET` | `/keys` | — | List all keys |

---

## HPA Tuning

Edit `k8s/hpa.yaml` to adjust scaling behaviour:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `minReplicas` | 1 | Never scale below this |
| `maxReplicas` | 10 | Never scale above this |
| `averageUtilization` | 50% | Scale up when CPU > 50% of request |
| `scaleUp.stabilizationWindowSeconds` | 30s | How long to wait before scaling up again |
| `scaleDown.stabilizationWindowSeconds` | 60s | Cooldown before scaling down (prevents thrashing) |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `kubectl top nodes` fails | `kubectl apply -f k8s/metrics-server.yaml`; wait 60s |
| HPA shows `<unknown>` for CPU | metrics-server not ready yet; also check `--kubelet-insecure-tls` flag |
| Pods stuck `Pending` | Not enough nodes/resources; lower `requests.cpu` in deployment.yaml |
| Image pull error | Image not loaded on all nodes — see Step 2 above |
| `kubeadm join` token expired | On master: `kubeadm token create --print-join-command` |
