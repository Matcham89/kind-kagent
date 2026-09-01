#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Agent Substrate bootstrap — CA pools, JWT authority, API auth config
# ==============================================================================
# The substrate Helm chart MOUNTS these secrets but never CREATES them. They
# hold CA private keys, so they are deliberately not in git and not templated:
# upstream generates them imperatively with `kubectl ate admin`. Without them
# every substrate pod sits at ContainerCreating forever:
#
#   podcertificate-controller-system/
#     service-dns-ca-pool      signs servicedns.podcert.ate.dev/identity
#     pod-identity-ca-pool     signs podidentity.podcert.ate.dev/identity
#   ate-system/
#     actor-id-ca-pool         actor mTLS identity CA (root + signing key)
#     actor-id-jwt-pool        actor identity JWT authority
#     actor-id-ca-certs        cert-only root, for the egress gateway
#     ate-api-authentication   (ConfigMap) ateapi JWT provider config
#
# Every step is idempotent: an existing secret is left alone, so re-running
# this will not rotate a CA out from under a live cluster. Use --force to
# regenerate.
#
# Mirrors upstream hack/install-ate.sh from agent-substrate/substrate.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${ROOT}/bin"
ATECTL="${BIN}/kubectl-ate"

# Upstream publishes chart 0.0.21 to GHCR but tags no matching git ref (only
# v0.0.0 exists), so kubectl-ate is pinned to an explicit main commit rather
# than a floating branch.
SUBSTRATE_REPO="${SUBSTRATE_REPO:-https://github.com/agent-substrate/substrate.git}"
SUBSTRATE_COMMIT="${SUBSTRATE_COMMIT:-71df8c96497c06fcf99446d50a01a995468b256b}"
GO_IMAGE="${GO_IMAGE:-golang:1.27}"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

log() { echo "  -> $*"; }

# ------------------------------------------------------------------------------
# Build kubectl-ate
# ------------------------------------------------------------------------------
# There is no published kubectl-ate binary or image, and this host has no Go
# toolchain, so it is built inside a container. Cached in ./bin (gitignored).
build_atectl() {
  if [[ -x "${ATECTL}" ]]; then
    log "kubectl-ate already built at ${ATECTL}"
    return
  fi
  command -v docker >/dev/null 2>&1 || {
    echo "ERROR: docker is required to build kubectl-ate (no Go toolchain on this host)." >&2
    exit 1
  }
  mkdir -p "${BIN}"
  echo "=== Building kubectl-ate (${SUBSTRATE_COMMIT:0:12}) in ${GO_IMAGE} ==="
  # Go's module and build caches are kept in a named volume; without it every
  # re-build re-downloads the whole dependency graph.
  docker volume create ate-gocache >/dev/null
  docker run --rm \
    -v ate-gocache:/root/.cache \
    -v "${BIN}:/out" \
    -e CGO_ENABLED=0 \
    -e GOFLAGS=-buildvcs=false \
    "${GO_IMAGE}" \
    bash -euo pipefail -c "
      git clone --filter=blob:none --no-checkout '${SUBSTRATE_REPO}' /src
      cd /src
      git fetch --depth 1 origin '${SUBSTRATE_COMMIT}'
      git checkout --detach '${SUBSTRATE_COMMIT}'
      go build -o /out/kubectl-ate ./cmd/kubectl-ate
    "
  chmod +x "${ATECTL}"
  log "built ${ATECTL}"
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
ensure_ns() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

secret_exists() {
  kubectl get secret -n "$2" "$1" >/dev/null 2>&1
}

# Skip generation unless the secret is missing (or --force was passed).
need_secret() {
  local name="$1" ns="$2"
  if secret_exists "${name}" "${ns}" && [[ "${FORCE}" -eq 0 ]]; then
    log "secret ${ns}/${name} already exists — skipping"
    return 1
  fi
  return 0
}

# Extract a CA pool secret's RootCertificateDER and emit it as a PEM cert.
ca_pool_root_pem() {
  local secret="$1" namespace="$2"
  kubectl get secret -n "${namespace}" "${secret}" -o jsonpath='{.data.pool}' \
    | base64 --decode \
    | grep -o '"RootCertificateDER":"[^"]*' \
    | sed 's/"RootCertificateDER":"//' \
    | base64 --decode \
    | openssl x509 -inform der -outform pem
}

# ------------------------------------------------------------------------------
# 1. podcertificate-controller signer CAs
# ------------------------------------------------------------------------------
create_podcert_cas() {
  echo "=== podcertificate-controller CA pools ==="
  ensure_ns podcertificate-controller-system
  local ns=podcertificate-controller-system
  for name in service-dns-ca-pool pod-identity-ca-pool; do
    if need_secret "${name}" "${ns}"; then
      "${ATECTL}" admin make-ca-pool --ca-id="1" --name="${name}" --secret-namespace="${ns}"
      log "created ${ns}/${name}"
    fi
  done
}

# ------------------------------------------------------------------------------
# 2. ateapi actor-identity pools
# ------------------------------------------------------------------------------
create_actor_identity() {
  echo "=== ate-system actor identity pools ==="
  ensure_ns ate-system

  if need_secret actor-id-jwt-pool ate-system; then
    "${ATECTL}" admin make-jwt-pool --key-id="1" --name="actor-id-jwt-pool" --secret-namespace=ate-system
    log "created ate-system/actor-id-jwt-pool"
  fi

  if need_secret actor-id-ca-pool ate-system; then
    "${ATECTL}" admin make-ca-pool --ca-id="1" --name="actor-id-ca-pool" --secret-namespace=ate-system
    log "created ate-system/actor-id-ca-pool"
  fi

  # The egress gateway verifies actor client certs, so it needs the actor CA
  # root on its own. actor-id-ca-pool holds root + signing key; derive a
  # cert-only secret from it.
  if need_secret actor-id-ca-certs ate-system; then
    # Extract into a variable first: with errexit a failing substitution inside
    # the create-secret argument list would silently yield an empty trust
    # bundle and an egress gateway that rejects every actor.
    local actorid_root=""
    actorid_root=$(ca_pool_root_pem actor-id-ca-pool ate-system)
    if [[ -z "${actorid_root}" ]]; then
      echo "ERROR: failed to extract the actor-identity CA root for actor-id-ca-certs" >&2
      return 1
    fi
    kubectl create secret generic actor-id-ca-certs \
      --from-literal=ca.crt="${actorid_root}" \
      -n ate-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    log "created ate-system/actor-id-ca-certs"
  fi
}

# ------------------------------------------------------------------------------
# 3. ateapi authentication config
# ------------------------------------------------------------------------------
create_api_auth_config() {
  echo "=== ate-system/ate-api-authentication ConfigMap ==="
  ensure_ns ate-system

  local jwt_issuer=""
  jwt_issuer=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null \
    | grep -o '"issuer":"[^"]*' | sed 's/"issuer":"//' || true)
  [[ -z "${jwt_issuer}" ]] && jwt_issuer="https://kubernetes.default.svc"

  # For the in-cluster issuer, ateapi must be told which CA and token to use
  # for OIDC discovery; an external (e.g. GKE) issuer is publicly resolvable.
  local discovery_config=""
  case "${jwt_issuer}" in
    https://kubernetes.default.svc|https://kubernetes.default.svc.cluster.local)
      discovery_config=$'  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt\n  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token\n'
      ;;
  esac

  local authentication_config
  authentication_config=$(printf 'actorIdentityJWTProvider: kubernetes\njwtProviders:\n- name: kubernetes\n  issuer: %s\n  audiences: [api.ate-system.svc]\n%s' \
    "${jwt_issuer}" "${discovery_config}")

  kubectl create configmap -n ate-system ate-api-authentication \
    --from-literal=authentication.yaml="${authentication_config}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "applied ate-api-authentication (issuer: ${jwt_issuer})"
}

# ------------------------------------------------------------------------------
# 4. Preflight — the cluster must actually serve what substrate needs
# ------------------------------------------------------------------------------
preflight() {
  echo "=== Preflight: substrate API prerequisites ==="
  local fail=0
  if ! kubectl get --raw /apis/certificates.k8s.io 2>/dev/null | grep -q 'certificates.k8s.io/v1beta1'; then
    echo "ERROR: certificates.k8s.io/v1beta1 is not served by this cluster." >&2
    echo "       podcertcontroller uses v1beta1 exclusively. Recreate the cluster with" >&2
    echo "       kind-config.yaml (runtimeConfig + featureGates)." >&2
    fail=1
  else
    log "certificates.k8s.io/v1beta1 is served"
  fi
  if ! kubectl api-resources --api-group=certificates.k8s.io 2>/dev/null | grep -q clustertrustbundles; then
    echo "ERROR: ClusterTrustBundle is not available (feature gate off)." >&2
    fail=1
  else
    log "ClusterTrustBundle is available"
  fi
  [[ "${fail}" -eq 0 ]] || exit 1
}

# ------------------------------------------------------------------------------
main() {
  echo ""
  echo "=============================================="
  echo "  Agent Substrate bootstrap"
  echo "=============================================="
  preflight
  build_atectl
  create_podcert_cas
  create_actor_identity
  create_api_auth_config
  echo ""
  echo "Substrate bootstrap complete. The podcertificate-controller should now"
  echo "publish its ClusterTrustBundles; substrate pods leave ContainerCreating"
  echo "once it does:"
  echo "  kubectl get clustertrustbundles"
  echo "  kubectl -n ate-system get pods -w"
  echo ""
}

main "$@"
