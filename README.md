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
| **Agent Substrate (0.0.9)** | `oci://ghcr.io/kagent-dev/substrate/helm/substrate` | gVisor sandbox runtime in `ate-system`, `auth.mode: jwt`. Version must match kagent's vendored module |
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
│   ├── flux-instance.yaml           # FluxInstance: pins Flux 2.8.x + helm-controller patch
│   ├── cluster-apps.yaml            # Root Kustomization → ./flux/apps/dev
│   └── flux-system/                 # Pre-generated Flux manifests (see note)
├── apps/
│   ├── base/                        # Actual Kubernetes manifests
│   │   ├── kagent/
│   │   │   ├── crds/                # OCIRepository + HelmRelease, kagent CRDs
│   │   │   ├── operator/            # kagent controller + UI; all built-in agents off
│   │   │   ├── secrets/             # ExternalSecrets pulling keys from Bitwarden
│   │   │   ├── providers/           # ModelConfigs (direct API mode)
│   │   │   ├── mcps/                # RemoteMCPServer (GitHub MCP)
│   │   │   ├── agents/              # Declarative k8s agents — NOT deployed
│   │   │   └── agent-harnesses/     # hermes-shell AgentHarness
│   │   ├── substrate/
│   │   │   ├── substate-crds/       # ate.dev CRDs, pinned 0.0.9
│   │   │   └── substrate-operator/  # substrate chart (auth.mode: jwt) + signer RBAC
│   │   └── kube-ops/
│   │       ├── cert-manager/        # cert-manager operator
│   │       └── external-secrets/    # ESO operator + Bitwarden ClusterSecretStore
│   └── dev/                         # Flux Kustomization resources (ks.yaml per component)
│       ├── kagent/                  # agents/ks.yaml.disabled — renamed, not listed
│       ├── substrate/
│       └── kube-ops/                # incl. cert-manager/certificates (bitwarden TLS)
├── infra/                           # Reusable Kustomize Components
│   ├── namespace/                   # Restricted PSS namespace template
│   └── namespace-privileged/        # Privileged PSS — used by kagent AND ate-system
└── CLAUDE.md
```

> `flux/clusters/dev/flux-system/gotk-components.yaml` is still pinned at
> v2.9.5 while the FluxInstance installs 2.8.x. The operator owns the
> controllers, so the file is inert — but it should be regenerated at 2.8.x.

### Dependency Chain

`dependsOn` between Flux Kustomizations, all of which must be satisfied before
the AgentHarness can come up:

```
cert-manager-operator ──→ cert-manager-selfsigned ──→ cert-manager-certificates
                                                              ↓  (bitwarden TLS cert)
                                          external-secrets-operator
                                                              ↓
                                             external-secrets-store
                                                              ↓
kagent-crds ─┐                                        kagent-secrets
substrate-crds ─┴──→ kagent-operator ←────────────────────────┘
      ↓                    ↓
substrate-operator    kagent-providers, kagent-mcps
      └──────────┬─────────┘
                 ↓
        kagent-agent-harnesses
```

---

## Quick Start

```bash
# 1. Provide the Bitwarden access token (see next section).
#    API keys themselves come from Bitwarden via ExternalSecrets — there is
#    nothing to paste into a manifest.
printf %s 'your-bitwarden-machine-account-token' > .bitwarden-token

# 2. Bootstrap everything
./bootstrap.sh

# 3. Wait for Flux to deploy everything (check progress with)
flux get kustomizations -A

# 4. Port-forward the UI once pods are ready
kubectl -n kagent port-forward --address 0.0.0.0 svc/kagent-ui 8080:8080
# Open http://<server-ip>:8080
```

The bootstrap script:
1. Creates a Kind cluster named `kagent` using `kind-config.yaml`
2. Enables `proxy_arp`/`proxy_ndp` on the node (gVisor pod networking)
3. Creates the `kube-ops` namespace and the Bitwarden access token secret
4. Installs **Flux Operator** via Helm (pinned 0.52.0)
5. Applies **FluxInstance** — the operator then creates the Flux controllers
   and syncs this repo
6. Flux reconciles everything else: cert-manager, ESO + Bitwarden store, kagent
   CRDs/operator/providers/MCPs, substrate, and the AgentHarness

Substrate needs no imperative bootstrap in `auth.mode: jwt` — the chart
generates its own key material.

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

# Check the AgentHarness and its backing substrate objects
kubectl -n kagent get agentharness,workerpool,actortemplate
kubectl -n ate-system get pods

# Check the kagent UI
kubectl -n kagent port-forward --address 0.0.0.0 svc/kagent-ui 8080:8080
# Then open http://<server-ip>:8080 in your browser
```

No API keys live in this repo — every provider credential is an ExternalSecret
resolved from Bitwarden at runtime.

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
Substrate lives in `ate-system` — its API group is `ate.dev`, so `ate-*`,
`atelet` and `atenet` are the real upstream names, not truncated ones.

**Full detail, including every pinned version and why: [`docs/agent-substrate.md`](docs/agent-substrate.md).**

The one thing to know before touching any version here:

> **kagent vendors the substrate Go module, so the two versions are a matched
> pair.** kagent `0.10.0-rc3` pins substrate `v0.0.9` in its `go.mod`. Run a
> different substrate and the AgentHarness still reports `Ready=True`, the
> ActorTemplate still takes a golden snapshot, gVisor sandboxes still run — and
> chat fails with a bare "An error occurred". Derive the correct version:
>
> ```bash
> curl -sS https://raw.githubusercontent.com/kagent-dev/kagent/refs/tags/v<VER>/go/go.mod | grep substrate
> ```
>
> Bump both together, keep `substrateWorkerPool.ateomImage` on the same
> substrate version, and verify by **opening a chat** — not by checking `Ready`.

Current pairing: kagent `0.10.0-rc3` <-> substrate `0.0.9`, `auth.mode: jwt`.

```bash
kubectl -n kagent get agentharness,workerpool,actortemplate
kubectl -n ate-system get pods
```

`AgentHarness` provisions a long-running coding-agent sandbox on substrate
rather than a kagent-managed runtime. It speaks the Agent Client Protocol
(ACP): an in-sandbox `acp-shim` bridges the agent's stdio to a WebSocket the
kagent controller exposes as an ordinary agent in the UI. The sandboxed hermes
is a real Hermes 0.19.0 with shell, file, skills, memory and delegation tools,
but **no web search and no browser tools**, and it serves **one chat session at
a time** — see the doc for specifics.

---

## File Structure

```
kind-kagent/
├── README.md
├── bootstrap.sh                    # Kind cluster + Flux Operator bootstrap
├── kind-config.yaml                # Kind cluster config (see note below)
├── .gitignore                      # ignores .bitwarden-token and bin/
├── docs/
│   └── agent-substrate.md          # substrate/AgentHarness: pins, rationale, caveats
└── flux/                           # canonical GitOps tree — everything else lives here
    ├── CLAUDE.md
    ├── clusters/dev/               # Flux entrypoint: FluxInstance + root Kustomization
    ├── infra/                      # namespace components (restricted / privileged PSS)
    ├── apps/base/                  # actual manifests
    │   ├── kagent/{crds,operator,secrets,providers,mcps,agents,agent-harnesses}
    │   ├── substrate/{substate-crds,substrate-operator}
    │   └── kube-ops/{cert-manager,external-secrets}
    └── apps/dev/                   # Flux Kustomizations (ks.yaml per component)
        ├── kagent/
        ├── substrate/
        └── kube-ops/
```

`kind-config.yaml` is not strictly required with `auth.mode: jwt` — it carries
the `ClusterTrustBundle` / `PodCertificateRequest` feature gates that only
`mtls` needs. It is kept because those gates **cannot be added to a running
kind cluster**, so dropping them would mean rebuilding to switch modes. It also
sets parallel image pulls, which substrate benefits from. See
[`docs/agent-substrate.md`](docs/agent-substrate.md).
