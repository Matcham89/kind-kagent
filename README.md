# Kind KAgent

Standalone kagent deployment for [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker).

This extracts **just the kagent agent platform** from the [home-cluster](https://github.com/Matcham89/home-cluster) Flux CD repo — no Substrate, no kgateway, no monitoring, no OAuth2 proxy, no webhook receiver, no ingress. Runs on a fresh Kind cluster with **direct LLM API access** (not through a gateway).

---

## What's Included

| Component | Source | Notes |
|-----------|--------|-------|
| kagent CRDs (v0.10.0-rc3) | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` | CRDs for Agent, ModelConfig, RemoteMCPServer |
| kagent Controller + UI (v0.10.0-rc3) | `oci://ghcr.io/kagent-dev/kagent/helm/kagent` | Built-in agents: k8s, kgateway, promql, helm, observability |
| **Providers (ModelConfigs)** | Direct API | Claude (Anthropic), OpenAI, OpenRouter, Gemini, Ollama |
| **Custom Agents** | Declarative Go agents | 7 k8s agents: ops, health, exec, logs, events, network, inspector |
| **GitHub MCP** | RemoteMCPServer | GitHub Copilot MCP — needs a GitHub PAT |
| **Secrets** | Plain Kubernetes Secrets (with placeholders) | Fill in your API keys before deploying |

Home-cluster secrets reference Bitwarden Secrets Manager (bitwarden-secretsmanager ClusterSecretStore). This repo provides plain secrets with the same item IDs documented in comments, so you can wire up ESO if you have it.

---

## What's EXCLUDED (vs the full home-cluster deployment)

- **Agent Substrate + gVisor sandboxes** — This is the root cause of the Talos compatibility issues (Talos limits user namespaces and has read-only cgroup v2 mounts, which block gVisor). On Kind, Substrate works out of the box, but this deploy is **kagent-only** — no Substrate, no AgentHarnesses.
- **kgateway / agentgateway** — All providers point directly to LLM API endpoints (https://api.anthropic.com, https://api.openai.com, etc.).
- **OAuth2 Proxy** — No auth for the kagent UI on local Kind (it's a dedicated dev machine).
- **GitHub Webhook Receiver** — Included in home-cluster for PR auto-triggering; excluded here for simplicity.
- **Agent Sandbox controller** — Not needed without Substrate.
- **OTel tracing/logging** — Disabled (the chart defaults are overridden in values.yaml).
- **Network Policies / Limit Ranges** — Not necessary on Kind's flat networking.
- **Qdrant MCP** — Only needed if you run Qdrant.
- **Flux MCP** — Only relevant in a Flux CD context.
- **Home-cluster-specific agents** — blog, youtube, PR agents, code agents, content-scout, flux-health — these depend on cluster-specific infra (qdrant, kmcp, webhook receivers).

---

## Two Ways to Use This

### Option A: Helm deploy on Kind (primary — this repo's bootstrap)

Create a Kind cluster, install via Helm, apply the manifests. This matches the repo's intended workflow.

### Option B: kagent CLI (local development)

The official kagent docs recommend the CLI for development:
[Local development with kagent CLI](https://kagent.dev/docs/kagent/getting-started/local-development/)

```bash
brew install kagent
export OPENAI_API_KEY="sk-..."
kagent install --profile minimal   # or --profile demo for default agents
kagent dashboard
```

For building custom agents, use:

```bash
kagent init adk python myagent --model-name claude-sonnet-4-5 --model-provider Anthropic
cd myagent
kagent build
kagent run    # runs locally via Docker compose — no cluster needed!
```

To deploy the built agent to your Kind cluster:

```bash
kagent deploy . --env-file .env.production
```

---

## Quick Start (Option A — Helm on Kind)

```bash
# 1. Create a Kind cluster
kind create cluster --name kagent

# 2. Before running bootstrap — fill in your API keys
#    Edit manifests/secrets/kagent-secrets.yaml and replace
#    <YOUR_ANTHROPIC_API_KEY>, <YOUR_OPENAI_API_KEY>, etc.

# 3. Bootstrap everything
./bootstrap.sh

# 4. Port-forward the UI
kubectl -n kagent port-forward svc/kagent-ui 8080:8080

# 5. Open http://localhost:8080 in your browser
```

---

## Before You Start — Fill in API Keys

Edit `manifests/secrets/kagent-secrets.yaml` and replace the placeholders. At minimum you need **one** working provider:

| File | Secret Name | Key | Provider |
|------|------------|-----|----------|
| `manifests/secrets/kagent-secrets.yaml` (all in one) | `kagent-anthropic` | `ANTHROPIC_API_KEY` | Claude models |
| same | `kagent-openai` | `OPENAI_API_KEY` | OpenAI models (also used for OpenRouter) |
| same | `kagent-google` | `GOOGLE_API_KEY` | Gemini models |
| same | `kagent-github` | `GITHUB_PAT` | GitHub MCP (classic PAT with repo scope) |

The `kagent-openrouter-placeholder` secrets is a dummy — OpenRouter keys go in the `kagent-openai` secret and use the OpenAI-compatible endpoint.

---

## Bootstrap Script Details

The `bootstrap.sh` script runs these steps:

1. **Create `kagent` namespace**
2. **Install kagent CRDs** from the OCI Helm chart (v0.10.0-rc3, matches home-cluster)
3. **Install kagent controller + UI** with standalone values (substrate disabled, OTel off, no kgateway integration)
4. **Apply plain secrets** with your API keys
5. **Apply ModelConfig providers** — directly connecting to LLM APIs (no agentgateway)
6. **Apply custom agents** — 7 k8s declarative agents
7. **Apply MCP servers** — GitHub Copilot MCP

The chart's default provider is set to `anthropic`. Change `default: anthropic` in `helm/kagent-values.yaml` to switch.

---

## Provider Architecture

Unlike the home-cluster deployment (which routes all LLM traffic through kgateway), this standalone deployment connects providers **directly** to their API endpoints:

| Provider | Protocol | Base URL | ModelConfig Name |
|----------|----------|----------|-----------------|
| Anthropic/Claude | Anthropic | `https://api.anthropic.com/v1` | `claude-sonnet-config`, `claude-opus-config`, `claude-haiku-config` |
| OpenAI | OpenAI | `https://api.openai.com/v1` | `openai-gpt4o`, `openai-gpt4o-mini`, `openai-o3` |
| OpenRouter | OpenAI | `https://openrouter.ai/api/v1` | `openrouter-deepseek-v4-flash`, `openrouter-deepseek-v3-2`, `openrouter-qwen3-flash`, `openrouter-gemini-3-flash`, `openrouter-claude-sonnet-4-6` |
| Gemini | OpenAI | `https://generativelanguage.googleapis.com/v1beta/openai/` | `gemini-flash`, `gemini-pro` |
| Ollama | Ollama | `http://ollama.ollama.svc.cluster.local:11434` | `ollama-gemma4` |

---

## Adding Agent Substrate / AgentHarness (optional, for later)

The official kagent docs describe running kagent **with** Agent Substrate on a Kind cluster as the recommended local environment. Substrate works on a vanilla Kind cluster with zero extra config (no feature gates needed). The home-cluster struggled because Talos has gVisor-incompatible kernel settings.

If you later want Substrate sandboxes (for AgentHarness/OpenClaw/Hermes or SandboxAgent):

1. Install Substrate CRDs + chart:
```bash
helm upgrade --install substrate-crds \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds \
  --version 0.0.21 \
  --namespace ate-system --create-namespace --wait

helm upgrade --install substrate \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.0.21 \
  --namespace ate-system --wait --timeout 10m
```

2. Upgrade kagent with substrate enabled:
```bash
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
├── bootstrap.sh                        # kind + helm + kubectl apply
├── helm/
│   └── kagent-values.yaml             # chart values (kagent-only, no substrate)
└── manifests/
    ├── namespace.yaml                  # kagent namespace
    ├── secrets/
    │   └── kagent-secrets.yaml         # plain secrets with placeholders
    ├── providers/
    │   ├── claude-provider.yaml        # Anthropic ModelConfigs
    │   ├── openai-provider.yaml        # OpenAI ModelConfigs
    │   ├── openrouter-provider.yaml    # OpenRouter ModelConfigs
    │   ├── gemini-provider.yaml        # Gemini ModelConfigs
    │   └── ollama-provider.yaml        # Ollama ModelConfig
    ├── agents/
    │   └── k8s-agents.yaml            # 7 declarative k8s agents
    └── mcps/
        └── github-mcp.yaml            # GitHub Copilot MCP
```

---

## Verifying the Installation

```bash
# Check pods are running
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
helm uninstall kagent -n kagent
helm uninstall kagent-crds -n kagent-system
kubectl delete namespace kagent
kubectl delete namespace kagent-system
kind delete cluster --name kagent
```