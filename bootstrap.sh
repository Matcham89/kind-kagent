#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Kind KAgent Bootstrap
# ==============================================================================
# Installs kagent CRDs + controller with standalone values on a Kind cluster.
# Assumes:
#   - kind cluster named "kagent" already exists (or create one first)
#   - helm is installed
#   - kubectl is configured to talk to the Kind cluster
#
# Usage:
#   ./bootstrap.sh
#
# Or step-by-step:
#   kind create cluster --name kagent
#   ./bootstrap.sh
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Step 1: Create kagent namespace ==="
kubectl create namespace kagent --dry-run=client -o yaml | kubectl apply -f -

echo "=== Step 2: Install kagent CRDs ==="
helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version 0.10.0-rc3 \
  --namespace kagent-system \
  --create-namespace \
  --wait \
  --timeout 5m

echo "=== Step 3: Install kagent Controller + UI ==="
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version 0.10.0-rc3 \
  --namespace kagent \
  --values "${SCRIPT_DIR}/helm/kagent-values.yaml" \
  --wait \
  --timeout 10m

echo "=== Step 4: Apply API key secrets ==="
kubectl apply -f "${SCRIPT_DIR}/manifests/secrets/"

echo "=== Step 5: Apply ModelConfig providers ==="
kubectl apply -f "${SCRIPT_DIR}/manifests/providers/"

echo "=== Step 6: Apply custom agents ==="
kubectl apply -f "${SCRIPT_DIR}/manifests/agents/"

echo "=== Step 7: Apply MCP servers ==="
kubectl apply -f "${SCRIPT_DIR}/manifests/mcps/"

echo ""
echo "========================================"
echo "  Bootstrap complete!"
echo "========================================"
echo ""
echo "  Port-forward the UI:"
echo "    kubectl -n kagent port-forward svc/kagent-ui 8080:8080"
echo ""
echo "  Then open: http://localhost:8080"
echo ""

# Verify
echo "=== Verification ==="
kubectl -n kagent get pods
echo ""
kubectl -n kagent get agents 2>/dev/null || echo "(no agents CRD or no agents yet)"
echo ""
kubectl -n kagent get modelconfigs 2>/dev/null || echo "(no modelconfigs CRD or no providers yet)"