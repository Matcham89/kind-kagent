# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Flux CD v2 GitOps repository for a standalone kagent deployment on Kind (Kubernetes in Docker). Git is the source of truth; Flux reconciles the cluster state from this repo. No build system — all changes are applied by pushing to `main`.

## Common Operational Commands

```bash
# Check Flux reconciliation status
flux get kustomizations -A
flux get helmreleases -A

# Force immediate reconciliation
flux reconcile kustomization cluster-apps --with-source
flux reconcile helmrelease kagent -n kagent

# Validate manifests before pushing
flux build kustomization cluster-apps --path ./flux/apps/dev --dry-run
kubectl kustomize flux/apps/base/kagent/crds  # Preview rendered output

# Check why something isn't reconciling
flux logs --follow --level=error
kubectl describe kustomization kagent-operator -n flux-system

# Port-forward the kagent UI
kubectl -n kagent port-forward --address 0.0.0.0 svc/kagent-ui 8080:8080
```

## Architecture: Three-Layer GitOps

```
clusters/dev/           ← Flux entrypoint (FluxInstance + root Kustomization)
apps/
  base/                 ← Cluster-agnostic Kubernetes manifests (HelmReleases, ModelConfigs, Agents, Secrets)
  dev/                  ← Flux Kustomization resources (ks.yaml) that reference base paths
infra/                  ← Reusable Kustomize Components for namespace templates
```

**How it works:**
1. `clusters/dev/cluster-apps.yaml` — root Flux Kustomization, sources `./flux/apps/dev`
2. `clusters/dev/flux-instance.yaml` — FluxInstance managing Flux Operator self-upgrade; syncs from `github.com/Matcham89/kind-kagent` main branch at 1-minute intervals
3. `apps/dev/kagent/**/ks.yaml` — each is a Flux `Kustomization` resource pointing to a path in `apps/base/kagent/`
4. `apps/base/kagent/**/` — contains the actual Kubernetes manifests (HelmReleases, ModelConfigs, Agents, Secrets, MCP servers)

**File naming conventions:**
- `ks.yaml` — Flux Kustomization resource (lives in `apps/dev/`)
- `helmrelease-*.yaml` (or `helmrelease.yaml`) — HelmRelease + OCIRepository resource (lives in `apps/base/`)
- `kustomization.yaml` — Kustomize resource aggregation (both layers)

## Application Directory Pattern

```
apps/base/kagent/{crds,operator,secrets,providers,agents,mcps}/
├── <resource>.yaml              # The actual Kubernetes resource(s)
└── kustomization.yaml           # Aggregates resources

apps/dev/kagent/{component}/
├── ks.yaml                      # Flux Kustomization pointing at base path
└── (no other files)

apps/dev/kagent/
└── kustomization.yaml           # Namespace component + resources listing all ks.yaml
```

**Dependency chain (install order via dependsOn in ks.yaml):**
```
external-secrets-operator (ESO)
  └── external-secrets-store (Bitwarden ClusterSecretStore)
        └── kagent-secrets (ExternalSecrets — depends on store)
kagent-crds (OCIRepository + HelmRelease)
  └── kagent-secrets + external-secrets-operator
        └── kagent-operator (HelmRelease for kagent controller + UI)
              └── kagent-providers (ModelConfigs referencing secrets)
                    └── kagent-mcps (RemoteMCPServer)
                          └── kagent-agent-harnesses (hermes-shell)

NOTE: kagent-agents (the declarative k8s-* Agents) is NOT deployed. Its
ks.yaml is renamed to ks.yaml.disabled and commented out of
apps/dev/kagent/kustomization.yaml — this cluster is harness-only.
```

## Namespace Infra Components

| Component | PSS | Use For |
|---|---|---|
| `namespace` | restricted | general workloads |
| `namespace-privileged` | privileged | `kagent` AND `ate-system` |

`kagent` must be **privileged**: the `kagent-default` WorkerPool's
`ateom-gvisor` worker pods run there and request `SYS_ADMIN`, `NET_ADMIN`,
`SYS_PTRACE` and an unconfined AppArmor profile, which `restricted` and
`baseline` both reject.

One active Kustomize Component in `infra/` — include via `components:` in a namespace's `kustomization.yaml`.

## Agent Substrate — version pinning is load-bearing

kagent vendors the substrate Go module, so the two versions must match or the
AgentHarness looks healthy but chat fails with an opaque error. Derive the
correct substrate version from kagent's `go.mod`:

```bash
curl -sS https://raw.githubusercontent.com/kagent-dev/kagent/refs/tags/v<KAGENT>/go/go.mod \
  | grep substrate
# replace github.com/agent-substrate/substrate => github.com/kagent-dev/substrate v0.0.9
```

Currently kagent `0.10.0-rc3` <-> substrate `0.0.9`. Bump both together, and
keep `substrateWorkerPool.ateomImage` on the same substrate version. Substrate
runs `auth.mode: jwt`, which self-bootstraps its key material.

See [docs/agent-substrate.md](../docs/agent-substrate.md) for the full failure modes.

## Secret Management

Secrets are managed via **External Secrets Operator (ESO)** pulling from **Bitwarden Secrets Manager**.

- `ExternalSecret` resources live in `flux/apps/base/kagent/secrets/kagent-secrets.yaml`
- They reference the `bitwarden-secretsmanager` ClusterSecretStore and map Bitwarden item fields to Kubernetes secret keys
- The secrets `ks.yaml` has `dependsOn` set to `external-secrets-store` (namespace: kube-ops) so downstream app deployments only start after secrets are available
- The `openrouter-placeholder.yaml` is a plain, non-sensitive dummy Secret (OpenRouter auth is handled by the OpenAI-compatible client needing a non-empty Authorization value)

### Bootstrap prerequisite: Bitwarden access token

Before Flux deploys the ClusterSecretStore, create the Bitwarden access token:

```bash
export BITWARDEN_ACCESS_TOKEN="your-token"
kubectl create secret generic bitwarden-access-token \
  --namespace=kube-ops \
  --from-literal=token=$BITWARDEN_ACCESS_TOKEN
```

This is handled automatically by `bootstrap.sh` if `BITWARDEN_ACCESS_TOKEN` is set.

## Provider Architecture

All providers connect directly to their API endpoints (no kgateway):

| Provider | Protocol | Base URL | ModelConfig Name |
|---|---|---|---|
| Anthropic/Claude | Anthropic | `https://api.anthropic.com/v1` | claude-sonnet-config, claude-opus-config, claude-haiku-config |
| OpenAI | OpenAI | `https://api.openai.com/v1` | openai-gpt4o, openai-gpt4o-mini, openai-o3 |
| OpenRouter | OpenAI | `https://openrouter.ai/api/v1` | openrouter-deepseek-v4-flash, openrouter-deepseek-v3, openrouter-qwen-coder, openrouter-claude-sonnet, openrouter-gemini-3-flash |
| Gemini | OpenAI | `https://generativelanguage.googleapis.com/v1beta/openai/` | gemini-flash, gemini-pro |
| Ollama | Ollama | `http://ollama.ollama.svc.cluster.local:11434` | ollama-gemma4 |

## Bootstrap Flow

1. `kind create cluster --name kagent --config kind-config.yaml`
2. Install Flux Operator Helm chart
3. Apply `flux/clusters/dev/flux-instance.yaml`
4. Flux Operator provisions Flux controllers
5. Flux syncs from git and deploys kagent via HelmRelease
6. Flux deploys secrets, providers, agents, MCP servers

See `bootstrap.sh` for the full script.

## Key Dependencies (install order via dependsOn)

```
external-secrets-operator → external-secrets-store → kagent-secrets
kagent-crds → kagent-operator
kagent-secrets → kagent-providers → kagent-agent-harnesses
kagent-operator → kagent-mcps
cert-manager-operator → cert-manager-selfsigned → cert-manager-certificates
                                                → external-secrets-operator
substrate-crds → substrate-operator → kagent-agent-harnesses
```