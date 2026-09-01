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
kubectl -n kagent port-forward svc/kagent-ui 8080:8080
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
                          └── kagent-agents (declarative Agents)
```

## Namespace Infra Components

| Component | PSS | Use For |
|---|---|---|
| `namespace` | restricted | kagent namespace |

One active Kustomize Component in `infra/` — include via `components:` in a namespace's `kustomization.yaml`.

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

1. `kind create cluster --name kagent`
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
kagent-secrets → kagent-providers → kagent-agents
kagent-operator → kagent-mcps → kagent-agents
```