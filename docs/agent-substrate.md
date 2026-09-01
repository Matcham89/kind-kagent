# Agent Substrate + AgentHarness on Kind

How this repo runs [Agent Substrate](https://kagent.dev/docs/kagent/concepts/agent-substrate/)
and a [hermes AgentHarness](https://kagent.dev/docs/kagent/concepts/agent-harness/)
on a single-node Kind cluster.

Three things, in order: **what is pinned**, **why it is pinned there**, and the
**caveats** that were needed to get a chat working end-to-end.

---

## 1. Pinned versions

| Component | Version | Pinned in |
|---|---|---|
| kagent CRDs | `0.10.0-rc3` | `flux/apps/base/kagent/crds/helmrelease.yaml` |
| kagent operator (controller + UI) | `0.10.0-rc3` | `flux/apps/base/kagent/operator/helmrelease.yaml` |
| **substrate CRDs** | **`0.0.9`** | `flux/apps/base/substrate/substate-crds/helmrelease.yaml` |
| **substrate chart** | **`0.0.9`** | `flux/apps/base/substrate/substrate-operator/helmrelease.yaml` |
| **`ateomImage` (gVisor worker)** | **`v0.0.9`** | `flux/apps/base/kagent/operator/helmrelease.yaml` |
| Flux distribution | `2.8.x` | `flux/clusters/dev/flux-instance.yaml` |
| Flux Operator | `0.52.0` | `bootstrap.sh` |
| cert-manager | `v1.16.2` | `flux/apps/base/kube-ops/cert-manager/helmrelease.yaml` |
| external-secrets | `1.0.0` | `flux/apps/base/kube-ops/external-secrets/operator/helmrelease.yaml` |
| Kubernetes / Kind node | `v1.37.0` | `kindest/node:v1.37.0` |

Non-version settings that are equally load-bearing:

| Setting | Value | Where |
|---|---|---|
| `auth.mode` | `jwt` | substrate HelmRelease |
| `substrateWorkerPool.replicas` | `4` | kagent HelmRelease |
| `controller.substrate.ateApiEndpoint` | `dns:///api.ate-system.svc:443` | kagent HelmRelease |
| PSS on `kagent` **and** `ate-system` | `privileged` | `flux/infra/namespace-privileged` |

---

## 2. Why these versions

### substrate 0.0.9 — dictated by kagent's vendored Go module

This is the single most important pin, and the one that is easiest to get
wrong. **kagent vendors the substrate Go module**, so its `ateapi` gRPC client
speaks one specific version of substrate's protobuf:

```bash
curl -sS https://raw.githubusercontent.com/kagent-dev/kagent/refs/tags/v0.10.0-rc3/go/go.mod | grep substrate
# replace github.com/agent-substrate/substrate => github.com/kagent-dev/substrate v0.0.9
```

kagent `0.10.0-rc3` **and** `0.10.0-rc5` both pin `v0.0.9`. This rule is not a
guess — applying it to kagent `0.9.9` yields substrate `v0.0.6`, which is
exactly the pair the
[official walkthrough](https://kagent.dev/docs/kagent/examples/agent-substrate/)
installs.

**Get this wrong and everything still looks healthy.** The AgentHarness reports
`Ready=True`, the ActorTemplate reaches `phase: Ready` with a golden snapshot,
gVisor sandboxes run. Only chat fails, as a bare *"An error occurred"* in the
UI. The real error is in the kagent controller:

```
ensure session actor failed ... substrate GetActor "ahr-kagent-<name>":
  rpc error: code = Internal desc = grpc: failed to unmarshal the received
  message: string field contains invalid UTF-8
```

The failure is purely client-side. `ate-api-server` logs the same call with
`err=null`, and a `kubectl-ate` built from substrate `main` decodes the
identical response without complaint.

Neighbouring versions break in *opposite* directions, so there is no slack:

| substrate | Result against kagent 0.10.0-rc3 |
|---|---|
| **0.0.9** | correct — CRDs ship `valueFrom`, `pauseImage` and `ateomImage` natively |
| 0.0.21 | ActorTemplate CRD lacks `valueFrom`/`pauseImage` (needs a CRD postRenderer), and `GetActor` fails to decode |
| 0.0.22 | WorkerPool CRD **drops** `spec.ateomImage`, which every current kagent chart sets and hard-fails without |

> A useful tell: if you find yourself patching substrate's CRDs to add fields
> kagent expects, you are on the wrong substrate version. This repo previously
> carried exactly such a postRenderer for 0.0.21; 0.0.9 needs none.

**`ateomImage` must move with the chart.** `ate-controller` and `ateom-gvisor`
are components of one release and their worker CLI flags are not a stable
cross-version contract — a mismatch crash-loops every worker on an unknown flag.

### Flux 2.8.x — a ceiling and a floor at the same time

- **Ceiling.** flux-operator patches the Flux CRDs it installs, and one patch
  adds an enum value at
  `/spec/versions/1/.../eventSources/items/properties/kind/enum/-` on the
  notification-controller `Receiver` CRD. Newer Flux serves only one Receiver
  version, so index `1` does not exist and the FluxInstance goes
  `Stalled=BuildFailed` having installed **no Flux CRDs at all** — nothing in
  the repo reconciles. Confirmed failing on 2.9.x under flux-operator `0.38.1`
  *and* `0.52.0`, so upgrading the operator alone does not help.
- **Floor.** The kagent HelmRelease uses `spec.install.strategy` /
  `spec.upgrade.strategy`, which helm-controller only accepts from v1.5.x
  (Flux 2.8). On 2.6.x it fails the dry-run with
  `field not declared in schema`.

`distribution.version: 2.x` floats straight into the ceiling. Always wait for a
terminal condition when testing a bump — sampling early reports a misleading
`Progressing`:

```bash
kubectl -n flux-system get fluxinstance flux \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
```

### auth.mode: jwt

substrate 0.0.9 offers `jwt` (its default) or `mtls`, and the choice changes
the cluster's requirements substantially:

| | `jwt` (used here) | `mtls` |
|---|---|---|
| Kind feature gates | **not required** | required (`ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest` + `certificates.k8s.io/v1beta1`) |
| `podcertificate-controller` | not rendered at all | deployed |
| CA pools | none | `service-dns-ca-pool`, `pod-identity-ca-pool`, `session-id-*` created out of band |
| Key material | chart self-bootstraps `ateapi-tls`, `session-id-jwt-pool`, `session-id-ca-pool` | manual |

jwt is why the official walkthrough can say "a vanilla kind cluster works". It
also drops postgres for valkey, so substrate declares **no CPU requests at
all** — worth having on a 4-vCPU node, where 0.0.21's 1-CPU postgres request
was the first thing to go `Pending`.

Switching to mtls means re-adding the feature gates (they are still in
`kind-config.yaml`, see below) **and** creating the CA pools yourself with
`kubectl ate admin make-ca-pool` / `make-jwt-pool` — upstream's
[`hack/install-ate.sh`](https://github.com/agent-substrate/substrate/blob/main/hack/install-ate.sh)
is the reference.

---

## 3. Caveats and workarounds

Everything below was required to get from "installed" to "a chat that answers".

### 3.1 `DisableChartDigestTracking` on helm-controller

Kubernetes 1.34+ rejects `+` in label values, but helm-controller appends the
chart's OCI digest to the version and writes it as a label. Every object the
kagent chart applies fails admission:

```
ServiceAccount "kagent-controller" is invalid: metadata.labels:
  Invalid value: "0.10.0-rc3+e9f54ef164de"
```

Fixed with a FluxInstance `kustomize.patches` entry adding
`--feature-gates=DisableChartDigestTracking=true` to the helm-controller
Deployment. See [fluxcd/flux2#4910](https://github.com/fluxcd/flux2/issues/4910).

### 3.2 Privileged PSS on the `kagent` namespace

Easy to miss, because the pods that need it are not in the obvious namespace.
The `kagent-default` WorkerPool's `ateom-gvisor` workers run in **`kagent`**,
not `ate-system`, and request `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE` and an
unconfined AppArmor profile. `SYS_ADMIN` alone is rejected under both
`restricted` and `baseline`, so an AgentHarness never gets a worker to run on.
Both namespaces use `flux/infra/namespace-privileged`.

### 3.3 A TLS certificate for `bitwarden-sdk-server`

Not substrate's fault, but it blocked the whole chain. The external-secrets
chart's `bitwarden-sdk-server` subchart mounts a `bitwarden-tls-certs` Secret
(`image.tls.enabled` defaults true) but ships **no Certificate template**, and
the parent chart's `certManager.enabled` only covers the ESO webhook. Nothing
creates it, so the pod sits in `ContainerCreating`:

```
MountVolume.SetUp failed for volume "bitwarden-tls-certs":
  secret "bitwarden-tls-certs" not found
```

That blocks external-secrets-operator, and behind it the store, `kagent-secrets`,
providers, the operator and the harness. Fixed with a cert-manager `Certificate`
in `flux/apps/dev/kube-ops/cert-manager/certificates/`, issued by the
`selfsigned` ClusterIssuer — which is its own CA, so cert-manager populates
`ca.crt`, the key the ClusterSecretStore's `caProvider` reads.

### 3.4 Worker pool headroom

**Each running actor occupies a whole worker**, and a harness transiently needs
two: its golden actor while a snapshot is taken, plus the session actor serving
chat. With `replicas: 2` and two harnesses the ate-controller loops on:

```
while resuming golden actor: rpc error: code = FailedPrecondition
  desc = no free workers available
```

Set to `4` here. 0.0.9 workers declare no CPU/memory requests, so headroom is
cheap.

### 3.5 `kind-config.yaml` is retained but not required

It carries the mtls feature gates, which `auth.mode: jwt` does not need. It is
kept anyway because those gates **cannot be added to a running kind cluster** —
dropping them would mean rebuilding the cluster to switch modes. It also sets
`serializeImagePulls: false`, which genuinely helps: substrate pulls several
hundred MB onto one node.

### 3.6 Recovering a wedged AgentHarness

Deleting an `ActorTemplate` while a session actor still references its old
golden snapshot leaves that actor stuck in `Resuming` **forever**:

```
ResumeActor: invalid snapshot URI prefix "<uuid>": missing bucket
```

The actor pins a worker, and the AgentHarness then cannot be deleted either —
its `kagent.dev/agent-harness-backend-cleanup` finalizer hangs on
`substrate cleanup exceeded timeout`. Recovery:

```bash
# 1. Break the stale worker assignment; the pool recreates the pod and the
#    actor drops from Resuming to Suspended.
kubectl -n kagent delete pod <worker pod holding the actor>

# 2. Clear the owned template, then the stuck finalizer.
kubectl -n kagent delete actortemplate <name>
kubectl -n kagent patch agentharness <name> --type=merge \
  -p '{"metadata":{"finalizers":null}}'

# 3. Let Flux recreate it; a fresh golden snapshot is taken.
flux reconcile kustomization kagent-agent-harnesses -n kagent
```

### 3.7 What the sandboxed hermes can and cannot do

Verified by driving the ACP endpoint directly. It is a real Hermes
(`agentInfo: hermes-agent 0.19.0`) — model calls to `api.anthropic.com` work
with prompt caching at 97–99%, the terminal tool executes inside gVisor, and it
can reach the internet (it downloaded a release binary mid-turn).

But the `hermes-acp` toolset defines **30 tools** and the sandbox registers
only **15**:

| Missing | Cause |
|---|---|
| `web_search`, `web_extract` | availability is gated on a search provider; only `ANTHROPIC_API_KEY` is injected |
| all 13 `browser_*` tools | no browser in the `acp-sandbox-hermes` image |

Three further limits:

- **Config is near-empty.** The ActorTemplate writes a `config.yaml` containing
  only `model` and `provider`, so every other Hermes setting runs at its
  default.
- **No messaging platforms.** The `channels` field on `AgentHarness` is
  documented as Telegram/Slack integration *for OpenClaw*, not hermes.
- **One ACP client at a time.** `acp-shim` logs
  `preempting stale client to admit a new connection` — a single shared actor
  serves all chat sessions, so there are no concurrent sessions.

`AgentHarness` has an `env` field, so injecting a search-provider key should be
enough to restore `web_search`/`web_extract`. The browser tools need a
different sandbox image.

---

## Verifying it actually works

`Ready=True` on the AgentHarness is **not** sufficient — that was true the
entire time chat was broken. Exercise the real path:

```bash
kubectl -n kagent port-forward svc/kagent-controller 18083:8083 &

# Expect HTTP 101 (websocket upgrade), not 503.
curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:18083/api/agentharnesses/kagent/hermes-shell/acp/new

# error:false, and the session actor should reach Running on a worker.
curl -s http://127.0.0.1:18083/api/substrate/status | python3 -m json.tool
```

Watching the worker pod is the most direct signal that a turn really ran:

```bash
kubectl -n kagent logs <worker pod> --since=5m | grep -iE 'api call|tool .* completed|turn ended'
```
