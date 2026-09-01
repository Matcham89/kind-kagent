# Running Agent Substrate on Talos — handover from the Kind build

**Audience:** an agent or engineer working on the `home-cluster` repo (Talos
v1.13.9, Kubernetes v1.36.3, 5 nodes).

**Provenance:** everything here was learned while getting substrate + a hermes
`AgentHarness` working end-to-end on a single-node Kind cluster
(`kind-kagent`, Kubernetes v1.37.0). That build reached a **working chat**.
This document translates it.

**How to read the confidence markers** — they matter, do not treat them alike:

| Marker | Meaning |
|---|---|
| **[VERIFIED]** | Observed directly on the Kind cluster, or read from source/registry metadata |
| **[INFERRED]** | Strong evidence chain, but not directly observed on Talos |
| **[UNKNOWN]** | Genuinely untested — plan for it to be wrong |

---

## 1. The headline

home-cluster currently runs **kagent `0.10.0-rc3` + substrate `0.0.21`**.
That pairing cannot work, and it explains *two* separate open problems in
`docs/substrate-bootstrap-requirements.md` at once.

**The single change: substrate `0.0.21` → `0.0.9`, with `auth.mode: jwt`.**

Doing that should:

1. Fix AgentHarness chat (currently broken by a protobuf mismatch). **[VERIFIED on Kind]**
2. Make §6b (cgroup v2 delegation) disappear. **[INFERRED — the main thing to validate]**
3. Let you *delete* the feature gates from Talos machine config — the change your
   §1 records as having caused a brief cluster-wide outage. **[VERIFIED on Kind]**
4. Remove the need for every out-of-band CA pool in §2. **[VERIFIED on Kind]**

**No Kubernetes upgrade is required.** 1.36.3 is fine — see §5.

---

## 2. Root cause A: kagent vendors the substrate Go module

**[VERIFIED]** kagent does not merely talk to substrate over a stable API — it
vendors substrate's Go module, so its `ateapi` gRPC client is compiled against
one specific protobuf version:

```bash
curl -sS https://raw.githubusercontent.com/kagent-dev/kagent/refs/tags/v0.10.0-rc3/go/go.mod | grep substrate
# replace github.com/agent-substrate/substrate => github.com/kagent-dev/substrate v0.0.9
```

kagent `0.10.0-rc3` **and** `0.10.0-rc5` both pin `v0.0.9`.

Sanity check on the rule: kagent `0.9.9` yields substrate `v0.0.6`, which is
exactly the pair the
[official walkthrough](https://kagent.dev/docs/kagent/examples/agent-substrate/)
installs. The rule holds.

### Why this is nasty

**Every health signal stays green.** The AgentHarness reports `Ready=True`, the
ActorTemplate reaches `phase: Ready` with a golden snapshot, gVisor sandboxes
run. Only chat fails, surfacing in the UI as a bare *"An error occurred"*.

The real error is in the kagent controller:

```
ensure session actor failed ... substrate GetActor "ahr-kagent-<name>":
  rpc error: code = Internal desc = grpc: failed to unmarshal the received
  message: string field contains invalid UTF-8
```

It is purely **client-side**: `ate-api-server` logs the same call with
`err=null`, and a `kubectl-ate` built from substrate `main` decodes the
identical response fine.

> This very likely explains why the `openclaw` harness has been stuck since
> 2026-08-27. Your notes attribute it to an ActorTemplate env validation error;
> that may be real *as well*, but the proto skew would break chat regardless.

### A tell you already hit

`docs/substrate-bootstrap-requirements.md` records a `substrate-crds`
postRenderer adding `valueFrom` and `pauseImage` to the ActorTemplate CRD,
"required for kagent 0.10.0-rc3 AgentHarness support". **[VERIFIED]** substrate
0.0.9 ships both natively. Patching substrate's CRDs to add fields kagent
expects is the symptom of being on the wrong substrate version.

### Do not go forwards instead

**[VERIFIED]** Tried and reverted on Kind: substrate `0.0.22` **removes**
`spec.ateomImage` from the WorkerPool CRD, which every current kagent chart
sets and hard-fails without:

```
server-side apply failed for object kagent/kagent-default ate.dev/v1alpha1,
  Kind=WorkerPool: .spec.ateomImage: field not declared in schema
```

0.0.21 and 0.0.22 break in opposite directions. 0.0.9 is the only version that
fits kagent 0.10.0-rc3.

---

## 3. Root cause B: your §6b cgroup blocker is a substrate regression

This is the part most worth your attention, because §6b is recorded as an open,
unresolved blocker attributed to Talos.

**[VERIFIED]** Substrate commit `2c327172`, dated **2026-07-24**:

> **ateom gvisor: drop `privileged: true` (#496)**
>
> - Dropping `privileged: true`, which also ensures we're in a **private
>   cgroupns** (we assume cgroups v2 container ecosystem which does this)
> - Enabling a lot of capabilities and unconfining apparmor
> - **Setting up interior leaf cgroups** and moving ateom itself into one
> - Configuring the gvisor containers to run in leaf cgroups

Timeline **[VERIFIED from registry metadata]**:

```
2026-07-10   substrate 0.0.9   released      <- predates the change
2026-07-24   commit 2c327172   drops privileged
2026-08-25   substrate 0.0.21  released      <- includes the change
```

Corroborating observations:

- **[VERIFIED]** On Kind running 0.0.9, the worker pod reports
  `securityContext.privileged: true`.
- **[VERIFIED]** Your §6b records `privileged: false` on 0.0.21, checked with
  `kubectl get pod <worker> -o jsonpath='{.spec.containers[0].securityContext.privileged}'`.
- Your §6b failure is
  `open /sys/fs/cgroup/cgroup.subtree_control: read-only file system` — exactly
  the leaf-cgroup delegation the commit introduced.

**[INFERRED]** On 0.0.9 the worker is simply privileged, so there is no cgroup
delegation to fail. §6b should not reproduce.

### Validate this in one command, before changing anything

On home-cluster today:

```bash
kubectl -n kagent get pod \
  -l kagent.dev/worker-pool=kagent-default \
  -o jsonpath='{.items[0].spec.containers[0].securityContext.privileged}{"\n"}'
# expect: false   (0.0.21)
# after moving to 0.0.9 the same command should print: true
```

If it already prints `true` on 0.0.21, this whole theory is wrong — stop and
re-investigate rather than proceeding.

### The trade you are making

**This is a genuine security regression.** `privileged: true` on the pods that
execute actor payloads is precisely the posture upstream deliberately moved
away from. You are accepting it to get a working harness on a version kagent
can actually talk to. When kagent ships a release vendoring a newer substrate,
§6b becomes live again and needs a real fix (privileged WorkerPool template,
a `runsc --ignore-cgroups`-style knob, or containerd cgroup delegation).

---

## 4. Root cause C: 0.0.21 is mtls-only; 0.0.9 offers jwt

**[VERIFIED]** substrate 0.0.9 has an `auth.mode` value (`jwt` | `mtls`),
defaulting to `jwt`. 0.0.21 has no such value — it is mtls-only, which is
consistent with your §7a finding that no 0.0.21 template reads `.Values.auth`.

Everything in your §1 and §2 was forced by being on an mtls-only version.

| | `jwt` (0.0.9 default) | `mtls` (0.0.21, forced) |
|---|---|---|
| Feature gates | **not required** | required |
| `certificates.k8s.io/v1beta1` | **not required** | required |
| `podcertificate-controller` | **not rendered at all** | deployed |
| CA pools | **none** | `service-dns-ca-pool`, `pod-identity-ca-pool`, `session-id-*` by hand |
| Signer `use` RBAC (§3) | **not needed** | required |
| Key material | chart self-bootstraps `ateapi-tls`, `session-id-jwt-pool`, `session-id-ca-pool` | manual |

**[VERIFIED on Kind]** Under jwt: zero podCertificate projections, zero
ClusterTrustBundles, no CA bootstrap of any kind.

---

## 5. Kubernetes version: 1.36.3 is fine, do not upgrade for this

**[VERIFIED]** From Kubernetes'
[`versioned_feature_list.yaml`](https://github.com/kubernetes/kubernetes/blob/master/test/compatibility_lifecycle/reference/versioned_feature_list.yaml):

| Feature gate | Alpha | Beta | GA (default on) |
|---|---|---|---|
| `ClusterTrustBundle` | 1.27 | 1.33 | 1.37 |
| `ClusterTrustBundleProjection` | 1.29 | 1.33 | 1.37 |
| `PodCertificateRequest` | 1.34 | 1.35 | 1.37 |

Two conclusions:

1. Under **jwt**, none of these are used, so they impose **no version floor at
   all**.
2. **[VERIFIED]** substrate 0.0.9's chart renders only stable APIs —
   `admissionregistration.k8s.io/v1`, `apps/v1`, `batch/v1`,
   `rbac.authorization.k8s.io/v1`, `v1`. The practical floor is ~1.30
   (ValidatingAdmissionPolicy GA).

If you ever *do* return to mtls: on 1.37 the three gates are GA and on by
default, so the only line that matters there is
`runtime-config: certificates.k8s.io/v1beta1=true` — substrate's
`podcertcontroller` imports the v1beta1 client exclusively. On your 1.36 they
are Beta and off, so you would need both.

---

## 6. The change set for home-cluster

Ordered. Paths are home-cluster's.

### 6.1 Pin substrate to 0.0.9

```
flux/apps/base/substrate/substate-crds/helmrelease.yaml       tag: 0.0.21 -> 0.0.9
flux/apps/base/substrate/substrate-operator/helmrelease.yaml  tag: 0.0.21 -> 0.0.9
```

### 6.2 Set jwt mode

`flux/apps/base/substrate/substrate-operator/helmrelease.yaml` has no `values:`
block today. Add one:

```yaml
spec:
  values:
    auth:
      mode: jwt
      jwt:
        # MUST match the cluster. Talos mints SA tokens with the API-server
        # endpoint as issuer, NOT the stock in-cluster URL — your §7a already
        # documents this. Verify, do not assume:
        #   kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
        issuer: <output of the command above>
        audience: api.ate-system.svc
        bootstrap:
          enabled: true
```

> **[UNKNOWN] — highest-risk step.** On Kind the chart default
> (`https://kubernetes.default.svc.cluster.local`) matched exactly. On Talos it
> almost certainly will **not**. Your §7a records the Talos issuer quirk. Get
> this wrong and ateapi rejects every actor identity JWT.

### 6.3 Keep ateomImage in lockstep

`flux/apps/base/kagent/operator/helmrelease.yaml`:

```yaml
substrateWorkerPool:
  ateomImage: ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.9   # was v0.0.21
```

**[VERIFIED]** `v0.0.9` exists. Confirm before pushing:
`docker manifest inspect ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.9`

Mismatched `ate-controller`/`ateom` pairs crash-loop every worker on an unknown
flag — your §4 already documents this.

### 6.4 Delete what 0.0.9 makes unnecessary

| Delete | Why |
|---|---|
| The `substrate-crds` postRenderer (`valueFrom`/`pauseImage` CRD patch) | 0.0.9 ships both natively **[VERIFIED]** |
| `flux/apps/base/substrate/substrate-operator/rbac-podcert-signer-use.yaml` + its kustomization entry | jwt renders no podCertificate projections, so it grants nothing **[VERIFIED on Kind]** |
| The 6 CA-pool secrets + `ate-api-authentication` ConfigMap (§2) | Not consumed by 0.0.9/jwt. Leave them until it works, then clean up |

### 6.5 Simplify Talos machine config

**[VERIFIED as unnecessary under jwt]** — remove from
`/Users/macbook/talos-config/{controlplane,worker}.yaml`:

```yaml
# apiServer.extraArgs
feature-gates: ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true
runtime-config: certificates.k8s.io/v1beta1=true
# kubelet.extraArgs (all 5 nodes)
feature-gates: ClusterTrustBundle=true,...
```

**Do this last, and separately from the substrate change.** Your §1 records
that mis-patching these gates crash-looped kubelet cluster-wide. Removing all
three together is the safe direction (the dependents go with the dependency),
but there is no reason to bundle it with the change you actually need. Get
substrate working first; treat this as cleanup.

### 6.6 Keep these

| Keep | Why |
|---|---|
| `user.max_user_namespaces=65536` on all 5 nodes | **Still required.** runsc creates a userns during sandbox setup; Talos defaults to 0. Unrelated to the privileged change |
| Privileged PSS on `kagent` **and** `ate-system` | More necessary now, not less — the worker is literally `privileged: true` on 0.0.9 |
| `rustfs` Deployment `Recreate` postRenderer | **[VERIFIED]** the `rustfs` Deployment still exists in 0.0.9, so the Longhorn RWO Multi-Attach reasoning still applies |
| valkey hostname-announcement postRenderer | **[VERIFIED]** `valkey-cluster` StatefulSet still exists in 0.0.9, patch target still valid |

---

## 7. Storage changes — plan for this on Longhorn

**[VERIFIED]** 0.0.9 uses **valkey instead of postgres**. On Kind it created:

```
rustfs-data              1Gi RWO
data-valkey-cluster-0..5 1Gi RWO   (6 PVCs, StatefulSet volumeClaimTemplates)
```

Implications for home-cluster:

- You gain **6 RWO Longhorn volumes**. Check capacity and replica settings.
- The existing `data-postgres-0` PVC becomes **orphaned** — it is not deleted by
  the upgrade. On Kind it sat `Bound` and unused. Clean it up once stable.
- **[VERIFIED]** 0.0.9 declares **no CPU requests at all**; 0.0.21's postgres
  requested a full CPU. Scheduling pressure goes down, not up.

---

## 8. Validation — `Ready=True` is not evidence

This is the single most important operational lesson from the Kind build. The
harness reported `Ready=True` for hours while chat was completely broken.

```bash
# 1. Substrate control plane
kubectl -n ate-system get pods
kubectl -n kagent get agentharness,workerpool,actortemplate

# 2. The worker must be privileged on 0.0.9 (the §6b hypothesis)
kubectl -n kagent get pod -l kagent.dev/worker-pool=kagent-default \
  -o jsonpath='{.items[0].spec.containers[0].securityContext.privileged}{"\n"}'

# 3. Substrate status through kagent — expect error:false
kubectl -n kagent port-forward svc/kagent-controller 18083:8083 &
curl -s http://127.0.0.1:18083/api/substrate/status | python3 -m json.tool

# 4. THE REAL TEST — ACP websocket must return 101, not 503
curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:18083/api/agentharnesses/kagent/hermes-shell/acp/new

# 5. Prove a turn actually ran, end to end
kubectl -n kagent logs <worker pod> --since=5m \
  | grep -iE 'api call|tool .* completed|turn ended'
```

Step 5 is the real proof. On Kind a successful turn logs:

```
API call #1: model=claude-sonnet-4-5 provider=anthropic in=11680 out=73 latency=2.0s
tool terminal completed (1.87s, 129 chars)
Turn ended: reason=text_response(finish_reason=stop) api_calls=2/90
```

---

## 9. Failure signatures cheat-sheet

| Symptom | Cause | Fix |
|---|---|---|
| UI: "An error occurred"; everything else green | proto skew (kagent vs substrate) | §2 — pin substrate to kagent's `go.mod` version |
| `failed to unmarshal ... string field contains invalid UTF-8` | same | same |
| `runsc create: exit status 128` + `unshare: Operation not permitted` | `user.max_user_namespaces=0` | sysctl 65536, then **restart worker pods** |
| `/sys/fs/cgroup/cgroup.subtree_control: read-only file system` | substrate ≥0.0.21 non-privileged worker | §3 — 0.0.9, or make the worker privileged |
| `.spec.ateomImage: field not declared in schema` | substrate 0.0.22+ | do not use 0.0.22 with current kagent |
| `no free workers available` | one actor occupies one whole worker | raise `substrateWorkerPool.replicas` (Kind needed 4 for 2 harnesses; you have 6) |
| Pods `ContainerCreating`, `matched zero ClusterTrustBundles` | mtls without gates/CA pools | switch to jwt, or complete §1+§2 |
| `signerName` silently stripped, empty cert projections | missing signer `use` RBAC | mtls only — your §3 |
| Harness stuck `Resuming` forever; finalizer hangs | stale snapshot ref after template recreation | see §10 |

---

## 10. Recovering a wedged AgentHarness

**[VERIFIED on Kind]** Deleting an `ActorTemplate` while a session actor still
references its old golden snapshot wedges the actor in `Resuming` permanently:

```
ResumeActor: invalid snapshot URI prefix "<uuid>": missing bucket
```

The actor pins a worker, and the AgentHarness then cannot be deleted — its
`kagent.dev/agent-harness-backend-cleanup` finalizer hangs on
`substrate cleanup exceeded timeout`. It sat like that for 7 hours.

```bash
# 1. Break the stale worker assignment; pool recreates the pod,
#    actor drops Resuming -> Suspended.
kubectl -n kagent delete pod <worker pod holding the actor>

# 2. Clear the owned template, then the stuck finalizer.
kubectl -n kagent delete actortemplate <name>
kubectl -n kagent patch agentharness <name> --type=merge \
  -p '{"metadata":{"finalizers":null}}'

# 3. Let Flux recreate it; a fresh golden snapshot is taken.
flux reconcile kustomization kagent-agent-harnesses -n kagent
```

---

## 11. What the sandboxed hermes can and cannot do

**[VERIFIED]** by driving the ACP endpoint directly on Kind. It is a real
Hermes (`agentInfo: hermes-agent 0.19.0`): model calls to `api.anthropic.com`
work with prompt caching at 97–99%, the terminal tool executes inside gVisor,
and it reaches the internet (it downloaded a release binary mid-turn).

But the `hermes-acp` toolset defines **30 tools** and the sandbox registers **15**:

| Missing | Cause |
|---|---|
| `web_search`, `web_extract` | gated on a search provider; only `ANTHROPIC_API_KEY` is injected |
| all 13 `browser_*` tools | no browser in the `acp-sandbox-hermes` image |

Also:

- **Config is near-empty** — the ActorTemplate writes a `config.yaml` with only
  `model` and `provider`; every other Hermes setting runs at default.
- **No messaging platforms.** The `channels` field on `AgentHarness` is
  documented as Telegram/Slack *for OpenClaw*, not hermes.
- **One ACP client at a time.** `acp-shim` logs
  `preempting stale client to admit a new connection`; a single shared actor
  serves all chat sessions.

`AgentHarness` has an `env` field, so injecting a search-provider key should
restore `web_search`/`web_extract`. Browser tools need a different image.

---

## 12. Rollback

The substrate change is two version pins plus a values block, all in Git.

```bash
git revert <commit>
flux reconcile kustomization cluster-apps --with-source
```

Caveats:

- **Golden snapshots do not survive the round trip.** 0.0.9 and 0.0.21 disagree
  on snapshot URI format (`missing bucket`, §10). After reverting, delete the
  ActorTemplates so fresh snapshots are taken.
- Talos machine-config changes are separate — that is why §6.5 says do them
  last.
- The orphaned `data-postgres-0` PVC means reverting to 0.0.21 will find its
  data still there.

---

## 13. Unknowns, ranked

1. **[UNKNOWN] The JWT issuer on Talos** (§6.2). Highest risk. Your §7a already
   documents that Talos uses the API-server endpoint, not the stock URL. Read it
   off the cluster; do not take the chart default.
2. **[INFERRED] §6b actually clearing.** The evidence is strong but the one-line
   `privileged` check in §3 is the cheap way to find out early.
3. **[UNKNOWN] gVisor pod networking on Talos.** Upstream's Kind script sets
   `net.ipv4.conf.all.proxy_arp=1` for gVisor's loopback pod-to-pod path, and
   the Kind build does the same. Nothing equivalent is recorded for Talos. Your
   cluster reached sandbox *creation* before, so it may be fine — but if actors
   start yet cannot reach ateapi, look here first.
4. **[UNKNOWN] Longhorn with 6 new RWO valkey volumes** (§7).
5. **[UNKNOWN] 0.0.9 on a 5-node cluster.** The Kind validation was single-node.
   Multi-node scheduling of actors across workers is untested by this work.
6. **Latent, unrelated:** home-cluster's FluxInstance uses
   `distribution.version: 2.x`. On the Kind build that floated onto a Flux whose
   Receiver CRD broke flux-operator's patch, stalling the FluxInstance with
   **zero Flux CRDs installed** — nothing reconciled at all. Your cluster is
   fine today, but a floating pin is a live grenade. Consider pinning.

---

## 14. Reference: the Kind configuration that works

```
kagent (crds + operator)   0.10.0-rc3
substrate (crds + chart)   0.0.9          auth.mode: jwt
ateomImage                 v0.0.9
substrateWorkerPool        replicas: 4    (2 harnesses)
Kubernetes                 v1.37.0 (Kind)
PSS                        privileged on kagent AND ate-system
```

Full detail, including the Kind-specific caveats and the audit trail of how
this was arrived at: [`agent-substrate.md`](agent-substrate.md) in this repo.
