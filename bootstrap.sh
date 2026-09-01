#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Kind KAgent Bootstrap — Flux Operator + kagent GitOps
# ==============================================================================
# Creates a Kind cluster, installs Flux Operator, applies FluxInstance to
# bootstrap GitOps, and Flux deploys everything from this repo.
#
# Assumes:
#   - helm is installed
#   - kubectl is configured
#   - BITWARDEN_ACCESS_TOKEN is set in your environment, OR you create
#     the kube-ops/bitwarden-access-token secret manually before step 2
#
# Usage:
#   export BITWARDEN_ACCESS_TOKEN="your-bitwarden-access-token"
#   ./bootstrap.sh
#
# Or step-by-step:
#   kind create cluster --name kagent
#   ./bootstrap.sh
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "=============================================="
echo "  Kind KAgent Bootstrap — Flux Operator"
echo "=============================================="
echo ""

# Check prerequisites
echo "=== Checking prerequisites ==="
command -v kind >/dev/null 2>&1 || { echo "ERROR: kind is required but not installed."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm is required but not installed."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required but not installed."; exit 1; }
# docker builds kubectl-ate (no Go toolchain assumed); openssl converts the
# substrate CA roots from DER to PEM.
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required but not installed."; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required but not installed."; exit 1; }

# ==============================================================================
# Step 0: Create Kind cluster (if not already existing)
# ==============================================================================
if ! kind get clusters 2>/dev/null | grep -q "^kagent$"; then
  echo "=== Step 0: Create Kind cluster ==="
  # kind-config.yaml is NOT optional: it enables the ClusterTrustBundle /
  # PodCertificateRequest feature gates and the certificates.k8s.io/v1beta1
  # group-version that Agent Substrate's podcertificate-controller requires.
  kind create cluster --name kagent --config "${SCRIPT_DIR}/kind-config.yaml"
else
  echo "=== Step 0: Kind cluster 'kagent' already exists ==="
  echo "    NOTE: Agent Substrate needs the feature gates in kind-config.yaml."
  echo "    A cluster created before that config cannot run substrate; the gates"
  echo "    cannot be added to a running kind cluster. Recreate it with:"
  echo "      kind delete cluster --name kagent && ./bootstrap.sh"
fi

# ==============================================================================
# Step 0a: Enable Proxy ARP/NDP on the kind nodes
# ==============================================================================
# substrate's gVisor sandboxes (ateom-gvisor) route pod-to-pod traffic over a
# loopback path that needs the node to answer ARP for addresses it does not own.
# Without this, actor sandboxes start but cannot reach ateapi.
echo "=== Step 0a: Enable Proxy ARP/NDP on kind nodes ==="
for node in $(kind get nodes --name kagent); do
  docker exec "$node" sysctl -q net.ipv4.conf.all.proxy_arp=1
  # -e: skip proxy_ndp rather than fail on a kernel built without IPv6.
  docker exec "$node" sysctl -qe net.ipv6.conf.all.proxy_ndp=1
done

# ==============================================================================
# Step 0b: Ensure kube-ops namespace exists for Bitwarden access token
# ==============================================================================
echo "=== Step 0b: Create kube-ops namespace (for Bitwarden access token) ==="
kubectl create namespace kube-ops --dry-run=client -o yaml | kubectl apply -f -

# ==============================================================================
# Step 0c: Create Bitwarden access token secret
# ==============================================================================
# The External Secrets Operator (ESO) and its ClusterSecretStore need this
# secret to authenticate with Bitwarden Secrets Manager.
#
# Set BITWARDEN_ACCESS_TOKEN in your environment, or create the secret manually:
#   kubectl create secret generic bitwarden-access-token \
#     --namespace=kube-ops \
#     --from-literal=token=<your-token>
#
echo "=== Step 0c: Create Bitwarden access token secret ==="
# Fall back to a gitignored token file. Cluster recreation is routine here and
# an exported env var does not survive a new shell, so the file is the durable
# option: printf %s > .bitwarden-token (no trailing newline needed).
if [ -z "${BITWARDEN_ACCESS_TOKEN:-}" ] && [ -f "${SCRIPT_DIR}/.bitwarden-token" ]; then
  BITWARDEN_ACCESS_TOKEN="$(tr -d '\r\n' < "${SCRIPT_DIR}/.bitwarden-token")"
  echo "  Using token from ${SCRIPT_DIR}/.bitwarden-token"
fi
if [ -n "${BITWARDEN_ACCESS_TOKEN:-}" ]; then
  kubectl create secret generic bitwarden-access-token \
    --namespace=kube-ops \
    --from-literal=token="$BITWARDEN_ACCESS_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  Bitwarden access token secret created from \$BITWARDEN_ACCESS_TOKEN"
else
  echo "  WARNING: BITWARDEN_ACCESS_TOKEN is not set."
  echo "  Creating a placeholder — you MUST update this secret before ESO can pull secrets."
  echo "  Run: kubectl create secret generic bitwarden-access-token \\"
  echo "         --namespace=kube-ops \\"
  echo "         --from-literal=token=<your-token>"
  kubectl create secret generic bitwarden-access-token \
    --namespace=kube-ops \
    --from-literal=token="PLACEHOLDER-REPLACE-ME" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ==============================================================================
# Step 0d: Agent Substrate bootstrap (CA pools, JWT authority, API auth config)
# ==============================================================================
# The substrate Helm chart mounts these secrets but never creates them, so this
# must happen for substrate pods to leave ContainerCreating. It is independent
# of Flux and idempotent, so it runs before the GitOps sync rather than racing
# the HelmRelease.
echo "=== Step 0d: Agent Substrate bootstrap ==="
"${SCRIPT_DIR}/hack/substrate-bootstrap.sh"

# ==============================================================================
# Step 1: Install Flux Operator
# ==============================================================================
echo "=== Step 1: Install Flux Operator ==="
helm upgrade --install flux-operator \
  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version=0.52.0 \
  --namespace flux-system \
  --create-namespace \
  --wait \
  --timeout 5m

echo "=== Step 1b: Wait for flux-operator pod to be ready ==="
kubectl -n flux-system wait --for=condition=Available deployment/flux-operator --timeout=5m

# ==============================================================================
# Step 2: Apply FluxInstance
# ==============================================================================
echo "=== Step 2: Apply FluxInstance ==="
kubectl apply -f "${SCRIPT_DIR}/flux/clusters/dev/flux-instance.yaml"

echo "=== Step 2b: Wait for Flux controllers to be ready ==="
echo "    (this may take 2-3 minutes for the first sync...)"
sleep 15
kubectl -n flux-system wait --for=condition=Available deployment/source-controller --timeout=5m 2>/dev/null || true
kubectl -n flux-system wait --for=condition=Available deployment/kustomize-controller --timeout=5m 2>/dev/null || true
kubectl -n flux-system wait --for=condition=Available deployment/helm-controller --timeout=5m 2>/dev/null || true
kubectl -n flux-system wait --for=condition=Available deployment/notification-controller --timeout=5m 2>/dev/null || true

echo ""
echo "=== IMPORTANT ==="
echo "API keys are managed via External Secrets Operator pulling from Bitwarden."
echo "The kagent-secrets ExternalSecrets reference the bitwarden-secretsmanager"
echo "ClusterSecretStore. If the Bitwarden access token is correct, secrets"
echo "will be created automatically once ESO and the store are reconciled."
echo ""

# ==============================================================================
# Step 3: Wait for sync and verify
# ==============================================================================
echo "=== Step 3: Wait for Flux to sync (first sync may take 2-5 min) ==="
sleep 60

echo "=== Checking Flux Kustomizations ==="
flux get kustomizations -A 2>/dev/null || echo "(kubectl fallback)"
kubectl get kustomizations -A 2>/dev/null || true

echo ""
echo "=== Checking pods ==="
kubectl get pods -A 2>/dev/null

echo ""
echo "=============================================="
echo "  Bootstrap initiated!"
echo "=============================================="
echo ""
echo "Flux Operator is installed and FluxInstance is applied."
echo "Flux will now sync from this git repo and deploy:"
echo "  1. external-secrets-operator (ESO) + bitwarden ClusterSecretStore"
echo "  2. kagent-crds (HelmRelease)"
echo "  3. kagent-secrets (ExternalSecrets pulling from Bitwarden)"
echo "  4. kagent-operator (HelmRelease for kagent controller + UI)"
echo "  5. kagent-providers (ModelConfigs)"
echo "  6. kagent-mcps (RemoteMCPServers)"
echo "  7. kagent-agents (declarative k8s agents)"
echo ""
echo "Monitor progress with:"
echo "  flux get kustomizations -A"
echo "  kubectl -n kagent get pods -w"
echo "  kubectl -n kube-ops get pods -w     (ESO)"
echo ""
echo "To access the kagent UI once it's ready:"
echo "  kubectl -n kagent port-forward --address 0.0.0.0 svc/kagent-ui 8080:8080"
echo "  # Open http://<server-ip>:8080 in your browser"
echo ""
echo "If you see 'no git repository configured' errors, push this repo"
echo "to GitHub and FluxInstance will pick up the URL automatically."