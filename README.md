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
Substrate lives in the `ate-system` namespace — its API group is `ate.dev`, so
`ate-*` / `atelet` / `atenet` are the real upstream names, not truncated ones.

### The kagent <-> substrate version pairing is load-bearing

**kagent 0.10.0-rc3 and rc5 both vendor the substrate Go module `v0.0.9`**:

```
# kagent go/go.mod
replace github.com/agent-substrate/substrate => github.com/kagent-dev/substrate v0.0.9
```

So kagent's `ateapi` gRPC client speaks v0.0.9's protobuf, and substrate must be
**0.0.9** to match. This is the single most expensive thing to get wrong,
because *everything looks healthy* when it is: the AgentHarness reports
`Ready=True`, the ActorTemplate reaches `phase: Ready` with a golden snapshot,
gVisor sandboxes run. Only chatting fails, as a bare "An error occurred" in the
UI. The real error is in the controller:

```
ensure session actor failed ... substrate GetActor "ahr-kagent-<name>":
  rpc error: code = Internal desc = grpc: failed to unmarshal the received
  message: string field contains invalid UTF-8
```

Note it is purely client-side — `ate-api-server` logs the same call with
`err=null`, and a `kubectl-ate` built from substrate `main` decodes the
identical response fine.

Neighbouring versions fail in opposite directions, so there is no room to drift:

| substrate | Result with kagent 0.10.0-rc3 |
|---|---|
| **0.0.9** | **correct pairing** — CRDs ship `valueFrom` + `pauseImage` + `ateomImage` natively |
| 0.0.21 | ActorTemplate CRD lacks `valueFrom`/`pauseImage` (needs a postRenderer), and `GetActor` fails to decode |
| 0.0.22 | WorkerPool CRD drops `spec.ateomImage`, which every current kagent chart sets and hard-fails without |

If you bump either side, bump both, and verify by actually opening a chat — not
by checking that the harness is `Ready`.

### auth.mode: jwt vs mtls

substrate 0.0.9 has an `auth.mode` value that changes the cluster's
requirements substantially. This repo uses **jwt**:

| | `jwt` (used here) | `mtls` |
|---|---|---|
| Feature gates in `kind-config.yaml` | not required | required |
| CA pools / `podcertificate-controller` | not rendered at all | must be created out of band |
| Key material | chart self-bootstraps `ateapi-tls`, `session-id-jwt-pool`, `session-id-ca-pool` | manual |
| Secret naming | `session-id-*` | `service-dns-ca-pool`, `pod-identity-ca-pool`, `session-id-*` |

Switching to `mtls` is therefore not just a value change: you would need the
`kind-config.yaml` feature gates (already present) **and** to create
`service-dns-ca-pool`, `pod-identity-ca-pool` and the `session-id-*` pools
yourself with `kubectl ate admin make-ca-pool` / `make-jwt-pool` from the
[substrate repo](https://github.com/agent-substrate/substrate), whose
`hack/install-ate.sh` is the reference for those commands. There is no script
for that here — the one this repo used to carry targeted 0.0.21's `actor-id-*`
naming and was deleted rather than left to rot.

0.0.9 also uses **valkey rather than postgres**, so the 1-CPU postgres request
is gone and the chart declares no CPU requests at all.

### Recovering a wedged AgentHarness

Deleting an `ActorTemplate` while a session actor still references its old
golden snapshot leaves that actor stuck in `Resuming` forever:

```
ResumeActor: invalid snapshot URI prefix "<uuid>": missing bucket
```

The actor pins a worker, and the AgentHarness then cannot be deleted either —
its `kagent.dev/agent-harness-backend-cleanup` finalizer hangs on
`substrate cleanup exceeded timeout`. To recover:

```bash
# 1. Break the stale worker assignment; the pool recreates the pod.
#    The actor drops from Resuming to Suspended.
kubectl -n kagent delete pod <the worker pod holding the actor>

# 2. Clear the owned template, then the stuck finalizer.
kubectl -n kagent delete actortemplate <name>
kubectl -n kagent patch agentharness <name> --type=merge -p '{"metadata":{"finalizers":null}}'

# 3. Let Flux recreate it; a fresh golden snapshot is taken.
flux reconcile kustomization kagent-agent-harnesses -n kagent
```

Each running actor occupies one whole worker, and a harness transiently needs
two (golden + session), so keep `substrateWorkerPool.replicas` comfortably
above the number of harnesses or the ate-controller loops on
`FailedPrecondition desc = no free workers available`.

### Verifying chat actually works

`Ready=True` on the AgentHarness is not sufficient. Exercise the real path:

```bash
kubectl -n kagent port-forward svc/kagent-controller 18083:8083 &

# Expect HTTP 101 (websocket upgrade), not 503.
curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:18083/api/agentharnesses/kagent/hermes-shell/acp/new

# The session actor should reach Running on a worker.
curl -s http://127.0.0.1:18083/api/substrate/status | python3 -m json.tool
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
├── bootstrap.sh                    # Kind cluster + Flux Operator bootstrap
├── kind-config.yaml                # Kind cluster config (see note below)
├── .gitignore                      # ignores .bitwarden-token and bin/
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

`kind-config.yaml` is not strictly required in the current `auth.mode: jwt`
setup — it carries the `ClusterTrustBundle` / `PodCertificateRequest` feature
gates that only `mtls` needs. It is kept because those gates **cannot be added
to a running kind cluster**, so dropping them would mean rebuilding the cluster
to switch modes. It also sets parallel image pulls, which substrate's image
pulls benefit from.
