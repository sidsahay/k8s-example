#!/usr/bin/env bash
# =============================================================================
# run-load-test.sh — Build the load-generator ConfigMap and launch the K8s Job
# =============================================================================
#
# Run this from the project root AFTER the kvstore is deployed:
#   bash scripts/run-load-test.sh
#
# To re-run: delete the old job first:
#   kubectl delete job load-generator -n kvstore
#   bash scripts/run-load-test.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

echo "[run-load-test] Creating load-generator-script ConfigMap..."
kubectl create configmap load-generator-script \
  --from-file=load_gen.py="${ROOT_DIR}/load-generator/load_gen.py" \
  -n kvstore \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[run-load-test] Applying load-generator Job..."
kubectl apply -f "${ROOT_DIR}/k8s/load-generator-job.yaml"

echo "[run-load-test] Watching HPA (Ctrl-C to stop watching):"
echo "  In another terminal run: kubectl logs -n kvstore -l app=load-generator -f"
echo ""
kubectl get hpa -n kvstore -w
