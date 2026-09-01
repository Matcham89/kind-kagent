# Kind KAgent

Standalone kagent deployment for [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker), managed by **Flux CD v2 GitOps**.

This extracts **just the kagent agent platform** from the [home-cluster](https://github.com/Matcham89/home-cluster) Flux CD repo — no Substrate, no kgateway, no monitoring, no OAuth2 proxy, no webhook receiver, no ingress. Runs on a fresh Kind cluster with **direct LLM API access** (not through a gateway). Uses the **same Flux structure** as the home-cluster.

---

## What's Included

| Component | Source | Notes |
|---|---|---|
| **Flux Operator** | `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator` | Installs and manages Flux CD controllers via FluxInstance CRD |
| kagent CRDs (v0.10.0-rc3) | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` | CRDs for Agent, ModelConfig, RemoteMCPServer |
| kagent Controller + UI (v0.10.0-rc3) | `oci://ghcr.io/kagent-dev/kagent/helm/kagent` | Built-in agents: k8s, promql, helm, observability |
| **Providers (ModelConfigs)** | Direct API | Claude (Anthropic), OpenAI, OpenRouter, Gemini, Ollama |
| **Custom Agents** | Declarative Go agents | 6 k8s agents: ops, health, exec, logs, events, network, inspector |
| **GitHub MCP** | RemoteMCPServer | GitHub Copilot MCP — needs a GitHub PAT |
| **Secrets** | ExternalSecrets via Bitwarden (ESO) | Pulls from Bitwarden Secrets Manager — same items as home-cluster |

---

## What's EXCLUDED (vs the full home-cluster deployment)

- **Agent Substrate + gVisor sandboxes** — Not needed for basic kagent; Substrate works on Kind if you want it later
- **kgateway / agentgateway** — All providers point directly to LLM API endpoints
- **OAuth2 Proxy** — No auth for the kagent UI on local Kind
- **GitHub Webhook Receiver** — Not needed for standalone
- **Agent Sandbox controller** — Not needed without Substrate
- **OTel tracing/logging** — Disabled (no OTel collector on Kind)
- **Network Policies / Limit Ranges** — Not necessary on Kind's flat networking
- **External Secrets Operator** — Pulls API keys from Bitwarden via ESO
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
kubectl -n kagent port-forward svc/kagent-ui 8080:8080

# 5. Open http://localhost:8080
```

The bootstrap script:
1. Creates a Kind cluster named `kagent`
2. Creates the `kube-ops` namespace and Bitwarden access token secret
3. Installs **Flux Operator** via Helm
4. Applies **FluxInstance** — Flux Operator creates Flux controllers and syncs from this repo
5. Flux reconciles and deploys ESO, kagent CRDs, operator, providers, agents, and MCP servers

---

## Before You Start — Bitwarden Access Token

API keys come from Bitwarden Secrets Manager via External Secrets Operator. You need a Bitwarden access token.

```bash
export BITWARDEN_ACCESS_TOKEN="your-bitwarden-machine-account-token"
```

The bootstrap script creates the `kube-ops/bitwarden-access-token` secret from this variable.

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
kubectl -n kagent port-forward svc/kagent-ui 8080:8080
# Open http://localhost:8080
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

## Adding Agent Substrate / AgentHarness (optional)

Substrate works on vanilla Kind with zero extra config. For sandboxed agents:

```bash
# 1. Install Substrate CRDs + chart
helm upgrade --install substrate-crds \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds \
  --version 0.0.21 --namespace ate-system --create-namespace --wait

helm upgrade --install substrate \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.0.21 --namespace ate-system --wait --timeout 10m

# 2. Upgrade kagent with substrate enabled
helm upgrade kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version 0.10.0-rc3 --namespace kagent --reuse-values \
  --set controller.substrate.enabled=true \
  --set controller.substrate.ateApiEndpoint=dns:///api.ate-system.svc:443 \
  --set controller.substrate.ateApiInsecure=true \
  --set substrateWorkerPool.create=true \
  --set substrateWorkerPool.replicas=1 \
  --set substrateWorkerPool.ateomImage=ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.21
```

For the full upstream walkthrough, see the [official Agent Substrate example](https://kagent.dev/docs/kagent/examples/agent-substrate).

---

## File Structure

```
kind-kagent/
├── README.md
├── bootstrap.sh                    # Flux Operator bootstrap
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