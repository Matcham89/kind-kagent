# Kind KAgent

Standalone kagent deployment for [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker), managed by **Flux CD v2 GitOps**.

This extracts **just the kagent agent platform** from the [home-cluster](https://github.com/Matcham89/home-cluster) Flux CD repo — no kgateway, no monitoring, no OAuth2 proxy, no webhook receiver, no ingress. Runs on a fresh Kind cluster with **direct LLM API access** (not through a gateway). Uses the **same Flux structure** as the home-cluster.

---

## What's Included

| Component | Source | Notes |
|---|---|---|
| **Flux Operator** | `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator` | Installs and manages Flux CD controllers via FluxInstance CRD |
| kagent CRDs (v0.10.0-rc3) | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` | CRDs for Agent, ModelConfig, RemoteMCPServer |
| kagent Controller + UI (v0.10.0-rc3) | `oci://ghcr.io/kagent-dev/kagent/helm/kagent` | All built-in agents disabled — harness-only cluster |
| **Providers (ModelConfigs)** | Direct API | Claude (Anthropic), OpenAI, OpenRouter, Gemini, Ollama |
| ~~Custom Agents~~ | Declarative Go agents | 7 `k8s-*` agents defined in `flux/apps/base/kagent/agents/`, **not deployed** |
| **GitHub MCP** | RemoteMCPServer | GitHub Copilot MCP — needs a GitHub PAT |
| **Secrets** | ExternalSecrets via Bitwarden (ESO) | Pulls from Bitwarden Secrets Manager — same items as home-cluster |
| **Agent Substrate (v0.0.21)** | `oci://ghcr.io/kagent-dev/substrate/helm/substrate` | gVisor sandbox runtime in `ate-system`; needs `kind-config.yaml` feature gates |
| **AgentHarness** | `kagent.dev/v1alpha2` | `hermes-shell` on the `kagent-default` WorkerPool |

---

## What's EXCLUDED (vs the full home-cluster deployment)

- **kgateway / agentgateway** — All providers point directly to LLM API endpoints
- **OAuth2 Proxy** — No auth for the kagent UI on local Kind
- **GitHub Webhook Receiver** — Not needed for standalone
- **OTel tracing/logging** — Disabled (no OTel collector on Kind)
- **Network Policies / Limit Ranges** — Not necessary on Kind's flat networking
- **Home-cluster-specific agents** — blog, youtube, PR agents, code agents, etc.

---

## Flux Structure

The repo follows the same three-layer GitOps pattern as the home-cluster:

```
flux/
├── clusters/dev/                    # Flux entrypoint
│   ├── flux-instance.yaml           # FluxInstance (Flux Operator self-upgrade + sync config)
│   ├── cluster-apps.yaml            # Root Kustomization → ./flux/apps/dev
│   └── flux-system/
│       ├── gotk-components.yaml     # Pre-generated Flux controller manifests (self-healing)
│       ├── gotk-sync.yaml           # GitRepository + Kustomization for self-sync
│       └── kustomization.yaml
├── apps/
│   ├── base/kagent/                 # Actual Kubernetes manifests
│   │   ├── crds/                    # OCIRepository + HelmRelease for kagent CRDs
│   │   ├── operator/                # OCIRepository + HelmRelease for kagent controller+UI
│   │   ├── secrets/                 # ExternalSecrets pulling API keys from Bitwarden
│   │   ├── providers/               # ModelConfigs (direct API mode)
│   │   ├── agents/                  # Declarative k8s agents
│   │   └── mcps/                    # RemoteMCPServer (GitHub MCP)
│   ├── dev/kagent/                  # Flux Kustomization resources (ks.yaml per component)
│   │       ├── kustomization.yaml       # Namespace component + resource list
│   │       ├── crds/ks.yaml
│   │       ├── operator/ks.yaml
│   │       ├── secrets/ks.yaml
│   │       ├── providers/ks.yaml
│   │       ├── agents/ks.yaml
│   │       └── mcps/ks.yaml
│   └── dev/kube-ops/                # Flux Kustomization resources for kube-ops
│       ├── kustomization.yaml       # Namespace component + resource list
│       └── external-secrets/
│           ├── operator/ks.yaml
│           └── store/ks.yaml
├── infra/                           # Reusable Kustomize Components
│   ├── namespace/                   # Restricted PSS namespace template
│   ├── namespace-privileged/        # Privileged PSS namespace template
│   └── kustomization.yaml
└── CLAUDE.md
```

### Dependency Chain

```
kagent-crds ──→ kagent-operator
                     ↓
external-secrets-operator ──→ external-secrets-store
                                     ↓
kagent-secrets ──→ kagent-providers ──→ kagent-agents
                     ↓
           kagent-mcps ──────────────→ kagent-agents
```

---

## Quick Start

```bash
# 1. Before running bootstrap — fill in your API keys
#    Edit flux/apps/base/kagent/secrets/kagent-secrets.yaml and replace
#    <YOUR_ANTHROPIC_API_KEY>, <YOUR_OPENAI_API_KEY>, etc.

# 2. Bootstrap everything
./bootstrap.sh

# 3. Wait for Flux to deploy everything (check progress with)
flux get kustomizations -A

# 4. Port-forward the UI once pods are ready
kubectl -n kagent port-forward --address 0.0.0.0 svc/kagent-ui 8080:8080
# Open http://<server-ip>:8080
```

The bootstrap script:
1. Creates a Kind cluster named `kagent` **using `kind-config.yaml`** — the
   substrate feature gates cannot be added to a cluster after the fact
2. Enables `proxy_arp`/`proxy_ndp` on the node (gVisor pod networking)
3. Creates the `kube-ops` namespace and Bitwarden access token secret
4. Runs `hack/substrate-bootstrap.sh` — builds `kubectl-ate` and generates the
   substrate CA pools, JWT authority, and API auth config
5. Installs **Flux Operator** via Helm
6. Applies **FluxInstance** — Flux Operator creates Flux controllers and syncs from this repo
7. Flux reconciles and deploys ESO, kagent CRDs, operator, providers, agents,
   MCP servers, substrate, and the AgentHarness

---

## Before You Start — Bitwarden Access Token

API keys come from Bitwarden Secrets Manager via External Secrets Operator. You need a Bitwarden access token.

```bash
export BITWARDEN_ACCESS_TOKEN="your-bitwarden-machine-account-token"
```

Or, because enabling substrate means the cluster gets recreated and an exported
variable does not survive a new shell, write it to a gitignored file that
`bootstrap.sh` picks up automatically:

```bash
printf %s 'your-bitwarden-machine-account-token' > .bitwarden-token
```

The bootstrap script creates the `kube-ops/bitwarden-access-token` secret from
whichever it finds (the environment variable wins).

### Bitwarden Item IDs (matching home-cluster)

| ExternalSecret | Bitwarden Item ID | Key |
|---|---|---|
| `kagent-anthropic` | `121df7d5-2478-4ca0-aa03-b36d00e1e52d` | ANTHROPIC_API_KEY |
| `kagent-openai` | `00800203-a8aa-445a-ac2f-b2d4013a4986` | OPENAI_API_KEY |
| `kagent-github` | `833987cf-91fa-40ee-8bcb-b35a0141e443` | GITHUB_PAT |
| `kagent-google` | `1e03f94f-1f66-4f1a-8a7c-b42501484e56` | GOOGLE_API_KEY |

---

## Option B — Non-Flux Direct Helm Install (legacy)

If you don't want GitOps and prefer direct Helm installs, the old bootstrap path still works:

```bash
kind create cluster --name kagent
# Edit manifests/secrets/kagent-secrets.yaml with keys
helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version 0.10.0-rc3 --namespace kagent-system --create-namespace --wait
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version 0.10.0-rc3 --namespace kagent --values helm/kagent-values.yaml --wait --timeout 10m
kubectl apply -f manifests/
```

---

## Verifying the Installation

```bash
# Check Flux controllers
kubectl -n flux-system get pods

# Check Flux Kustomizations
flux get kustomizations -A

# Check kagent pods
kubectl -n kagent get pods

# Check CRD resources
kubectl -n kagent get agents
kubectl -n kagent get modelconfigs
kubectl -n kagent get remotemcpservers

# Check the kagent UI
kubectl -n kagent port-forward --address 0.0.0.0 svc/kagent-ui 8080:8080
# Then open http://<server-ip>:8080 in your browser

  Be careful not to commit your API keys to git (they are already committed as placeholders).
```

---

## Rollback

```bash
# Uninstall everything
kind delete cluster --name kagent

# Or just kagent (Flux will reapply from git unless you remove the NS)
kubectl delete namespace kagent
```

---

## Agent Substrate / AgentHarness

Substrate and the `hermes-shell` AgentHarness are deployed by Flux from
`flux/apps/base/substrate/` and `flux/apps/base/kagent/agent-harnesses/`.
Substrate lives in the `ate-system` namespace — its API group is `ate.dev`, so
`ate-*` / `atelet` / `atenet` are the real upstream names, not truncated ones.

### Substrate does NOT work on a vanilla Kind cluster

Two prerequisites are easy to miss, and both fail the same silent way — every
substrate pod sits in `ContainerCreating` forever with:

```
MountVolume.SetUp failed for volume "podidentity" :
  [credential bundle is not issued yet,
   combination of signerName and labelSelector matched zero ClusterTrustBundles]
```

**1. Cluster feature gates (`kind-config.yaml`).** Substrate mounts pod
identity as projected `podCertificate` + `clusterTrustBundle` volumes, issued by
its own `podcertificate-controller`. That controller talks *exclusively* to
`certificates.k8s.io/v1beta1`, which Kubernetes v1.37 does not serve unless
asked. `kind-config.yaml` enables:

| Setting | Why |
|---|---|
| `featureGates: ClusterTrustBundle` | the CTB API objects |
| `featureGates: ClusterTrustBundleProjection` | the projected volume type |
| `featureGates: PodCertificateRequest` | per-pod cert issuance |
| `runtimeConfig: "certificates.k8s.io/v1beta1": "true"` | the only group-version podcertcontroller uses |
| `serializeImagePulls: false` | substrate pulls several hundred MB onto one node |

These **cannot be added to a running kind cluster** — the cluster must be
recreated. `bootstrap.sh` passes the config automatically; it also enables
`proxy_arp`/`proxy_ndp` on the node, which gVisor sandboxes need for
pod-to-pod traffic.

Verify:

```bash
kubectl get --raw /apis/certificates.k8s.io | grep v1beta1
```

**2. CA bootstrap secrets (`hack/substrate-bootstrap.sh`).** The substrate chart
*mounts* six things it never *creates*. They hold CA private keys, so they are
deliberately not in git and not templated — upstream generates them
imperatively with `kubectl ate admin`:

| Object | Namespace | Purpose |
|---|---|---|
| `service-dns-ca-pool` | `podcertificate-controller-system` | signs `servicedns.podcert.ate.dev/identity` |
| `pod-identity-ca-pool` | `podcertificate-controller-system` | signs `podidentity.podcert.ate.dev/identity` |
| `actor-id-ca-pool` | `ate-system` | actor mTLS identity CA (root + signing key) |
| `actor-id-jwt-pool` | `ate-system` | actor identity JWT authority |
| `actor-id-ca-certs` | `ate-system` | cert-only root, for the egress gateway |
| `ate-api-authentication` (ConfigMap) | `ate-system` | ateapi JWT provider config |

`hack/substrate-bootstrap.sh` creates all of them and is idempotent — an
existing secret is left alone, so re-running will not rotate a CA out from
under a live cluster (use `--force` to regenerate). It runs as step 0d of
`bootstrap.sh`, and can be re-run standalone at any time.

It needs `kubectl-ate`, which has no published binary or image and must be
built from source. With no Go toolchain assumed on the host, the script builds
it in a `golang:1.27` container into `./bin/kubectl-ate` (gitignored, cached).

Verify:

```bash
kubectl get clustertrustbundles          # expect the two podcert.ate.dev signers
kubectl -n ate-system get pods
```

### Resource budget on a single Kind node

A 4-vCPU node is genuinely tight. Substrate's only significant CPU *request* is
its postgres, which asks for a **full CPU** — so it is the first thing to go
`Pending` with `Insufficient cpu`. Everything else in the substrate chart is
request-less.

**All built-in kagent agents and all declarative agents are disabled** on this
cluster; it exists to run the hermes AgentHarness. That frees roughly 1.2 vCPU.

> **Gotcha:** the built-in agents are Helm **subcharts**, gated by
> `condition: <name>-agent.enabled` in the kagent `Chart.yaml`. Each key must
> therefore sit at the **top level** of `values:`. Nesting them under an
> `agents:` map is silently ignored by Helm and every agent stays at its chart
> default of `enabled: true`. Verify a change actually took effect:
>
> ```bash
> helm template kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
>   --version 0.10.0-rc3 -f your-values.yaml \
>   | grep '^# Source: kagent/charts/'
> ```

If postgres still will not schedule, lower its request:

```yaml
# flux/apps/base/substrate/substrate-operator/helmrelease.yaml
spec:
  values:
    postgres:
      resources:
        requests:
          cpu: 250m
```

To bring the declarative `k8s-*` agents back, rename
`flux/apps/dev/kagent/agents/ks.yaml.disabled` to `ks.yaml` and uncomment it in
`flux/apps/dev/kagent/kustomization.yaml`. On a 4-vCPU node they need
right-sizing via `spec.declarative.deployment.resources` (the default is
`100m`/`384Mi` each, ×7).

### AgentHarness

`AgentHarness` provisions a long-running coding-agent sandbox on substrate
rather than a kagent-managed runtime. `hermes-shell` uses the `hermes` backend
and the `kagent-default` WorkerPool (created by the kagent chart via
`substrateWorkerPool.create=true`; the name is the chart default and must match
`spec.substrate.workerPoolRef.name`).

Harnesses speak the Agent Client Protocol (ACP) over JSON-RPC: an in-sandbox
`acp-shim` bridges the agent's stdio to a WebSocket the kagent controller
exposes as an ordinary agent in the UI. It reports two conditions, `Accepted`
(kagent accepted the spec) and `Ready` (the ActorTemplate snapshot is live).

```bash
kubectl -n kagent get agentharness hermes-shell -o yaml
kubectl -n kagent get actortemplates
kubectl -n kagent get workerpool kagent-default
```

Docs: [Agent Substrate](https://kagent.dev/docs/kagent/concepts/agent-substrate/) ·
[Agent Harness](https://kagent.dev/docs/kagent/concepts/agent-harness/) ·
[architecture](https://github.com/agent-substrate/substrate/blob/main/docs/architecture.md)

---

## File Structure

```
kind-kagent/
├── README.md
├── bootstrap.sh                    # Flux Operator bootstrap
├── kind-config.yaml                # REQUIRED for substrate: feature gates + v1beta1
├── hack/
│   └── substrate-bootstrap.sh      # substrate CA pools / JWT authority / API auth
├── bin/                            # gitignored: locally built kubectl-ate
├── .gitignore
├── helm/
│   └── kagent-values.yaml         # Chart values (legacy direct-helm path)
├── manifests/                      # Legacy direct-apply manifests (migrated to flux/)
│   ├── namespace.yaml
│   ├── secrets/
│   │   └── kagent-secrets.yaml
│   ├── providers/                  # ModelConfigs
│   ├── agents/
│   │   └── k8s-agents.yaml
│   └── mcps/
│       └── github-mcp.yaml
├── flux/                           # Canonical GitOps structure
│   ├── CLAUDE.md
│   ├── infra/                      # Namespace components
│   ├── clusters/dev/               # Flux entrypoint
│   ├── apps/base/kube-ops/external-secrets/  # ESO operator + Bitwarden store
  ├── apps/base/kagent/                     # kagent manifests
│   └── apps/dev/kagent/            # Flux Kustomizations
```