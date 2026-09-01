# Agent Substrate + AgentHarness on Kind

How this repo runs [Agent Substrate](https://kagent.dev/docs/kagent/concepts/agent-substrate/)
and a [hermes AgentHarness](https://kagent.dev/docs/kagent/concepts/agent-harness/)
on a single-node Kind cluster.

Three things, in order: **what is pinned**, **why it is pinned there**, and the
**caveats** that were needed to get a chat working end-to-end.

> Porting this to Talos / home-cluster? See
> [`substrate-on-talos.md`](substrate-on-talos.md) — a self-contained handover
> covering what transfers, what does not, and which of home-cluster's recorded
> blockers turn out to be substrate version artifacts rather than Talos issues.

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

### ClusterTrustBundle is a dead requirement here — and a Kubernetes version floor

Substrate's `mtls` mode depends on `ClusterTrustBundle`,
`ClusterTrustBundleProjection` and `PodCertificateRequest`. Two things are worth
being precise about, because both are easy to state wrongly.

**They are recent.** From Kubernetes' own
[`versioned_feature_list.yaml`](https://github.com/kubernetes/kubernetes/blob/master/test/compatibility_lifecycle/reference/versioned_feature_list.yaml):

| Feature gate | Alpha | Beta | GA (on by default) |
|---|---|---|---|
| `ClusterTrustBundle` | 1.27 | 1.33 | **1.37** |
| `ClusterTrustBundleProjection` | 1.29 | 1.33 | **1.37** |
| `PodCertificateRequest` | **1.34** | 1.35 | **1.37** |

`PodCertificateRequest` does not exist at all before **1.34**, so substrate's
mtls mode is simply not available on an older cluster — that is a hard floor on
where substrate can run in that mode, independent of anything in this repo.

**On this cluster the gates are redundant.** We run Kubernetes **1.37**, where
all three are **GA and default-enabled**. Listing them in `kind-config.yaml`
changes nothing.

> **Correction to earlier notes in this repo.** The original diagnosis said a
> vanilla Kind cluster was missing "three feature gates". That was wrong for
> 1.37. Evidence: on the pre-rebuild vanilla cluster,
> `kubectl api-resources --api-group=certificates.k8s.io` already listed
> `clustertrustbundles` and `podcertificaterequests`, while
> `kubectl get --raw /apis/certificates.k8s.io` returned **only** `v1`.
>
> The single thing actually missing was
> `runtimeConfig: "certificates.k8s.io/v1beta1": "true"` — substrate's
> `podcertcontroller` imports `k8s.io/api/certificates/v1beta1` exclusively, and
> 1.37 does not serve that group-version unless asked. So on 1.37 the gates are
> noise and the runtimeConfig was the real requirement.

Net effect for this repo: with `auth.mode: jwt` **none of it is needed** — no
gates, no `v1beta1`, no `podcertificate-controller`, no ClusterTrustBundles.
The signer RBAC that existed for the mtls path was removed once jwt was adopted
(see the audit below), and the leftover `podcert.ate.dev` ClusterTrustBundles
were deleted from the cluster.

`kind-config.yaml` still carries the gates. On 1.37 they are a no-op; they are
kept only so the file stays correct if this is ever run against 1.34–1.36,
where they are Alpha/Beta and off by default. If you switch to mtls on 1.37,
the line that matters is the `runtimeConfig`, not the gates.

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

The feature gates it carries are a no-op on Kubernetes 1.37 (all three are GA
and default-on) and are unused under `auth.mode: jwt` regardless — see
"ClusterTrustBundle is a dead requirement here" above. They are kept only so
the file remains correct against 1.34–1.36, where they are Alpha/Beta and off
by default, and because `runtimeConfig`/`featureGates` **cannot be added to a
running kind cluster** — changing them means rebuilding.

The part of this file that earns its place today is
`serializeImagePulls: false` / `maxParallelImagePulls: 4`: substrate pulls
several hundred MB onto a single node, and kubelet serialises pulls by default,
so whichever workload lands at the back of the queue can miss its readiness
deadline.

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

---

## Audit trail

Kept deliberately: if this breaks later, this is what was changed, why, and how
to undo it. Every commit below is on `main`; nothing was force-pushed, so
`git show <sha>` always recovers the full reasoning and any deleted file.

### Chronology

| Commit | Change | Driver |
|---|---|---|
| `e52400c` | kind feature gates + CA bootstrap script; disabled all built-in agents | Substrate pods stuck `ContainerCreating` on `matched zero ClusterTrustBundles`; also found the `agents:` values were nested wrongly and every agent was silently running at chart default |
| `dd4b50e` | podcert signer-use RBAC; privileged PSS on `kagent` | Cross-referenced from the home-cluster deployment |
| `2e396b0` → `af441e5` → `2aeb813` | Flux pinned 2.9.x → 2.6.x → **2.8.x**; flux-operator → 0.52.0 | FluxInstance `Stalled=BuildFailed`, **zero** Flux CRDs installed. 2.6.x cleared the stall but was too old for `spec.install.strategy`. 2.8.x satisfies both ends |
| `8265414` | cert-manager `Certificate` for `bitwarden-sdk-server` | Pod stuck on missing `bitwarden-tls-certs`, blocking the whole ESO → kagent chain |
| `5640f95` | `DisableChartDigestTracking` on helm-controller | k8s 1.34+ rejects `+` in the chart-version label |
| `89f2e57` → `c8d120b` | substrate 0.0.22, then **reverted** | Wrong direction: 0.0.22 removes `spec.ateomImage` from the WorkerPool CRD, which kagent still sets |
| `49f6d2c` | substrate **0.0.9** + `auth.mode: jwt` | The actual fix. kagent vendors substrate `v0.0.9`; 0.0.21's proto broke `GetActor` |
| `048fbb0` | worker pool 2 → 4 replicas | `no free workers available` — one actor per worker |
| `3351ec6`, `170e135`, `0f7f25a` | Documentation; removed dead paths | Cleanup once the shape was settled |

### Removed, and how to get it back

Nothing here is lost — `git show <sha>:<path>` restores any of it.

| Removed in | What | Why it went | Restore if… |
|---|---|---|---|
| `170e135` | `hack/substrate-bootstrap.sh` | Dead under jwt, and already wrong for 0.0.9 — it created 0.0.21's `actor-id-*` secrets, not `session-id-*` | You switch to mtls. Prefer upstream's [`hack/install-ate.sh`](https://github.com/agent-substrate/substrate/blob/main/hack/install-ate.sh) as the reference |
| `170e135` | `manifests/`, `helm/kagent-values.yaml` | Legacy non-Flux path duplicating `flux/apps/base/kagent/*` while drifting from it; held placeholder API keys | You want a non-GitOps install path — but regenerate it rather than restoring stale copies |
| `0f7f25a` | `flux/apps/base/substrate/substrate-operator/rbac-podcert-signer-use.yaml` | jwt renders no podCertificate projections at all (verified zero on the live cluster), so it grants nothing | You switch to mtls — then it is **required**, or Kubernetes silently strips `signerName` and pods come up with empty cert projections |

Also deleted from the cluster (not from git — they were never in it): the
orphaned `podidentity.podcert.ate.dev` / `servicedns.podcert.ate.dev`
ClusterTrustBundles and the `podcert-ate-dev-signer-use` ClusterRole/Binding,
all created during the 0.0.21/mtls attempt.

### Still parked, deliberately

| Thing | State | Note |
|---|---|---|
| Seven declarative `k8s-*` agents | `flux/apps/base/kagent/agents/` present; `flux/apps/dev/kagent/agents/ks.yaml.disabled` renamed and commented out of the parent kustomization | The `.disabled` suffix matters: where a directory has no `kustomization.yaml`, Flux generates one from the `*.yaml` it finds, so a stray `ks.yaml` could be picked up even when unlisted |
| `kind-config.yaml` feature gates | Present, no-op on 1.37 | See §3.5 |
| `gotk-components.yaml` | Pinned v2.9.5 while the operator installs 2.8.x | Inert — the operator owns the controllers — but should be regenerated |
| `test` AgentHarness | Running in-cluster, not in git | Created manually; occupies a worker. `kubectl -n kagent delete agentharness test` |

### If it breaks again — first three checks

```bash
# 1. Version pairing. This is the failure that looks like success.
curl -sS https://raw.githubusercontent.com/kagent-dev/kagent/refs/tags/v<KAGENT>/go/go.mod | grep substrate
kubectl -n ate-system get helmrelease substrate -o jsonpath='{.status.lastAppliedRevision}{"\n"}'

# 2. Is Flux itself actually installed? A stalled FluxInstance installs no CRDs.
kubectl -n flux-system get fluxinstance flux \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'

# 3. The real chat path — not `Ready`.
kubectl -n kagent logs <worker pod> --since=5m | grep -iE 'api call|tool .* completed|turn ended'
```
