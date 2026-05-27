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

## Phase B preparation notes (not yet shipped)

When scheduling Phase B:
1. Confirm Zot has been up for >1 day with no restarts and PVC headroom OK.
2. Confirm there are no other queued MCO-event-class changes.
3. Run the full pre-flight cascade per CLAUDE.md "Pre-flight for any network-stack change":
   - `loki-operator` → 0
   - `IngressController/default` replicas → 1
   - Apply the IDMS/ITMS manifests (this is the trigger)
   - `oc get mcp master -w` until rolled
   - Post-cascade: restart all 3 `ovnkube-node` pods, repo-server, cert-manager controller
   - Restore: scale `loki-operator` and `IngressController` back
4. Validate by pulling a freshly-pulled image and confirming it appears in Zot's `_catalog`.
5. Capture node-level pull times before/after to make the win measurable.

## Open items

- Phase B (cluster-wide mirror wiring) — queued.
- Trivy/CVE scanning — not added; appetite low, footprint cost high.
- Off-cluster mirror for bootstrap images (etcd, kube-apiserver) — separate, bigger project.
- RGW-S3-backed storage migration — only if PVC pressure shows up or a multi-replica need surfaces.
