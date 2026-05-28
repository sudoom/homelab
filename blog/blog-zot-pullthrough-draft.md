# Zot pull-through OCI cache — rollout notes

Working draft. Captures the decision tree + the actual rollout sequence so a future post (and future-me) can retrace what got shipped and why.

## Framing

The 3-node OKD cluster pulls images from four upstream registries on every workload schedule: `quay.io` (OKD, OLM operators), `docker.io` (most upstream Helm charts), `ghcr.io` (some operators), `registry.k8s.io` (kube-state-metrics, descheduler, etc.). Each pod restart that crosses a cold-image boundary hits the network. Any upstream registry hiccup mid-MCO-reroll leaves pods Pending until it recovers — observed during the 2026-05-20 IPsec MCO event where ceph image pulls took 15-19 min cross-IPsec.

A local pull-through cache solves this for everything except the cluster's own bootstrap images (which need to be available *before* any in-cluster service is). It's a workload-availability win, not a self-sufficient-restart win.

## Why Zot, not Harbor

Harbor is the obvious answer if you also want CVE scanning, fine-grained access control, and replication policies. For a 3-node homelab, that's about 10 pods (core, registry, redis, postgres, trivy, jobservice, …) for ~zero value above pure pull-through.

Zot is a single Go binary, ~100 MB RSS, CNCF, OCI-native, supports on-demand sync from upstreams (the pull-through mode). One pod, one PVC, one Route. Match the problem to the tool.

## Design tweak from the original TODO

The README TODO originally specced an S3-backed Zot pointing at a `zot-cache` bucket on the existing `ceph-objectstore` RGW (same OBC + secret-translator pattern Loki uses). When it came time to ship, I went with **PVC-backed on `ceph-nvme-block`** instead:

- Simpler — no OBC + secret-translator chain, no per-bucket user lifecycle.
- Lower cache-hit latency — kernel page cache + Zot's inode-based dedupe vs an S3 GET on every pull.
- 50 GiB on NVMe is plenty for the cache footprint (a handful of GB of working set).
- Migration to RGW-S3 is always available later if PVC pressure or multi-replica need shows up.

Tradeoff accepted. Documented in the README TODO update so the deviation is intentional, not drift.

## Two-phase rollout

**Phase A (this commit) — deploy Zot as a standalone registry.** Validates everything except the cluster-wide wiring:
- StatefulSet, single replica, on `ceph-nvme-block` 50 Gi PVC
- Service ClusterIP :5000
- Route at `zot.apps.okd.sudops.pl` (edge-terminated, wildcard cert)
- Anonymous reads enabled, no auth required for pulls
- Sync sources: quay.io, registry-1.docker.io, ghcr.io, registry.k8s.io — all `onDemand: true`, `tlsVerify: true`

Phase A is **zero-blast-radius**. The cluster still pulls upstream by default; Zot just exists alongside, fillable on demand by `podman pull zot.apps.okd.sudops.pl/<image>`.

**Phase B (queued, separate session) — wire as cluster image mirror.** Ship `ImageDigestMirrorSet` + `ImageTagMirrorSet` to route the four upstream registries through Zot, with `mirrorSourcePolicy: AllowContactingSource` for fallback when Zot is unreachable (chicken-and-egg solved). Triggers a 3-master MCO reroll → full cascade pre-flight runbook (CLAUDE.md), ~30-45 min degraded window.

## What shipped — file inventory

```
components/apps/zot/
├── Chart.yaml               # Helm chart metadata
├── values.yaml              # image + storage + upstreams
└── templates/
    ├── namespace.yaml       # zot namespace
    ├── configmap.yaml       # Zot config.json with sync registries
    ├── statefulset.yaml     # zot StatefulSet + volumeClaimTemplate
    ├── service.yaml         # ClusterIP :5000
    └── route.yaml           # zot.apps.okd.sudops.pl edge-terminated
```

Plus `bootstrap/root-app/values.yaml` entry at Wave 6.

## Zot config shape

```json
{
  "distSpecVersion": "1.1.0",
  "storage": {
    "rootDirectory": "/var/lib/registry",
    "dedupe": true,
    "gc": true,
    "gcDelay": "1h",
    "gcInterval": "24h"
  },
  "http": { "address": "0.0.0.0", "port": "5000" },
  "extensions": {
    "search": { "enable": true },
    "sync": {
      "enable": true,
      "registries": [
        { "urls": ["https://quay.io"],              "onDemand": true, "tlsVerify": true, "content": [{ "prefix": "**" }] },
        { "urls": ["https://registry-1.docker.io"], "onDemand": true, "tlsVerify": true, "content": [{ "prefix": "**" }] },
        { "urls": ["https://ghcr.io"],              "onDemand": true, "tlsVerify": true, "content": [{ "prefix": "**" }] },
        { "urls": ["https://registry.k8s.io"],      "onDemand": true, "tlsVerify": true, "content": [{ "prefix": "**" }] }
      ]
    }
  }
}
```

`prefix: "**"` on every entry means Zot tries each upstream in order on a cache miss. Order matters when paths exist in multiple upstreams (rare; `library/*` is docker-only, etc.) — Phase B's `ImageDigestMirrorSet` will pin per-source mapping deterministically.

`dedupe: true` shares blob storage across repos that pull the same layer (very common — base images repeated everywhere). `gc` runs every 24h with a 1h delay before reclaiming an unreferenced blob.

## Validation steps (post-ArgoCD sync)

```bash
# 1. Pod is Running + Ready
oc -n zot get pods -l app=zot

# 2. PVC bound
oc -n zot get pvc

# 3. Route serves the OCI distribution v2 API
curl -sI https://zot.apps.okd.sudops.pl/v2/    # expect 200 + WWW-Authenticate or 200

# 4. Sync probe — pull a small upstream image through Zot
podman pull zot.apps.okd.sudops.pl/library/alpine:latest
# (with Phase A only, you need this explicit zot.apps prefix; with Phase B
# in place, the cluster's container runtime will rewrite quay.io/foo/bar
# to zot.apps.okd.sudops.pl/foo/bar via ImageDigestMirrorSet)

# 5. Verify image landed in Zot
curl -s https://zot.apps.okd.sudops.pl/v2/_catalog | jq .
```

## 2026-05-28 — Phase B shipped (IDMS+ITMS, MCO event)

Phase B ran cleanly. Total wall time pre-flight start → restore done was ~30 minutes; MCO master roll proper was 12 minutes (18:20 → 18:32 local).

### Chart shipped

`components/cluster-config/image-mirror-zot/` — Helm chart with `ImageDigestMirrorSet` + `ImageTagMirrorSet`. One entry per upstream registry (quay.io, docker.io, ghcr.io, registry.k8s.io), each mirrored to a single endpoint:

```yaml
- source: quay.io
  mirrors:
    - zot.apps.okd.sudops.pl
  mirrorSourcePolicy: AllowContactingSource
```

`AllowContactingSource` is what makes the chicken-and-egg solvable — if Zot is down, the runtime falls back to upstream.

### Timeline (local time, UTC+2)

| Time | Event |
|---|---|
| 18:18 | Push `02af154` (Phase B chart enabled in root-app values) |
| 18:18-18:20 | Pre-flight: `loki-operator` → 0, `IngressController/default` → 1, both settled |
| 18:19 | ArgoCD synced IDMS+ITMS into cluster (CR `creationTimestamp: 16:19:40Z`) |
| 18:20 | MCO rendered new MachineConfig, master MCP entered UPDATING=True |
| 18:23 | node4 rolled (1/3) |
| 18:27 | node5 rolled (2/3) |
| 18:32 | node6 rolled (3/3) — new config `rendered-master-056bb4f5a72eddfd9c66a560eede2bd8` |
| 18:32-18:33 | Post-cascade: rolled all 3 `ovnkube-node` pods (one at a time), restart repo-server |
| 18:33 | Restore: `loki-operator` → 1, `IngressController` → 2 |
| 18:47 | T+15 long-fuse sweep — clean. No cert-manager retry stuck, no app Degraded |

### What got cached organically

Within minutes of the rollout completing, `/v2/_catalog` showed:

```json
{"repositories":["okd/scos-content","okderators/catalog-index","openshift/origin-jenkins","operatorhubio/catalog"]}
```

All four are quay.io paths — confirms the IDMS rewrite is active for the cluster's own bootstrap and operator-catalog images. Subsequent pulls of any quay.io image will be cache hits.

### What went well

- **Pre-flight worked.** No Loki drain block. No RGW reschedule storm (only 1 router pre-set). No cross-node host-network breakage (consistent with the 2026-05-21 OVN-K MTU finding — non-IPsec MCO events don't trip that specific cascade).
- **`mirrorSourcePolicy: AllowContactingSource` is doing its job.** Even during the brief windows when individual nodes were rebooting and Zot was momentarily unreachable from their kubelet, pulls succeeded by falling back to upstream.
- **MCO event was fast.** 12 minutes for 3 masters; CLAUDE.md budgets 30-45 min, so we came in well under.
- **T+15 sweep clean** — cert-manager survived. Bootloader-cmdline-class changes are where 6b matters most; an IDMS-class change has more general egress activity that keeps connections fresh.

### What I'd do differently

- **`ovnkube-node` serial restart loop was buggy.** My `until ... sort -u | tr` check exited the moment surviving pods showed 8/8 — didn't actually verify the replacement for the just-deleted pod was back. There were brief windows where two replacement pods were starting concurrently. No data plane impact (ovnkube-node is hostNetwork, OVS runs on the host), but the principle "one at a time" was violated. Fix for next time: count nodes with exactly N=3 pods in `Running` phase AND `READY=8/8`, not a unique value check.
- **MCP `status.configuration.name` lags individual node progress.** The field only updates when the whole pool is converged. During rollout it shows the old name even as `updatedMachineCount` advances. Don't trust it as a per-node progress indicator — only as the final "all done" signal.

### UI extension

Phase A shipped only `extensions.search`. Followed Phase B with `9b96903` to also enable `extensions.ui` + `extensions.mgmt` — the latter required so the UI can hit the `/v2/_zot/ext/mgmt` config endpoint. Pod restart picked up the new ConfigMap via the `checksum/config` annotation pattern; PVC stayed bound, cache contents preserved.

Browse the UI at `https://zot.apps.okd.sudops.pl/`. Shows the cached repos, tag inspection, layer details, search.

## Open items

- Trivy/CVE scanning — still not added; appetite low, footprint cost high.
- Off-cluster mirror for bootstrap images (etcd, kube-apiserver) — separate, bigger project; only matters for cold-cluster restart scenarios.
- RGW-S3-backed storage migration — only if PVC pressure shows up or a multi-replica need surfaces. 50 GiB on NVMe has plenty of headroom for the steady-state cache.
- Capture pull-time before/after measurements at some point (no rush — the win is structural, not perf).
