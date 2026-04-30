# okd-homelab-gitops

GitOps repository for a 3-node bare-metal OKD 4.20 homelab cluster managed by ArgoCD.

**Repo:** https://github.com/sudoom/homelab

## Architecture

```
Manual bootstrap (one-time)
  └── ArgoCD Operator + Instance
        └── Root App-of-Apps (Application)
              ├── Wave 0: CatalogSources (operatorhubio-catalog)
              ├── Wave 1: Operators (NMState, Rook-Ceph)
              ├── Wave 2: Cluster Config (NMState NNCPs)
              └── Wave 3: Storage (CephCluster, pools, StorageClasses)
```

## Bootstrap

Only the ArgoCD operator installation is manual. Everything else is Argo-managed.

```bash
# 1. Install ArgoCD operator
oc apply -f bootstrap/argocd/templates/namespace.yaml
oc apply -f bootstrap/argocd/templates/operatorgroup.yaml
oc apply -f bootstrap/argocd/templates/subscription.yaml

# 2. Wait for operator
oc get csv -n openshift-gitops -w
# Wait for Phase: Succeeded

# 3. Wait for default ArgoCD instance (the operator auto-creates one)
oc get pods -n openshift-gitops -w
# Wait for all pods Running

# 4. Apply the root App-of-Apps
oc apply -f bootstrap/root-app/root-application.yaml
```

## Repo Structure

```
bootstrap/
  argocd/           # ArgoCD operator (manual apply, one-time)
  root-app/         # Root Application pointing to all components
components/
  catalog-sources/  # OLM CatalogSources (operatorhubio)
  operators/
    nmstate/        # NMState operator subscription
    rook-ceph/      # Rook-Ceph operator via Helm
  cluster-config/
    nmstate-nncp/   # Storage network NNCPs per node
  storage/
    ceph-cluster/   # CephCluster CR, toolbox
    ceph-storage-classes/  # Block pools, StorageClasses
```

## Cluster

| Node | Frontnet (VLAN 5) | Backnet (VLAN 10) | Role |
|------|-------------------|-------------------|------|
| Node 4 | 192.168.1.7 | 192.168.10.2 | control-plane + worker |
| Node 5 | 192.168.1.8 | 192.168.10.3 | control-plane + worker |
| Node 6 | 192.168.1.9 | 192.168.10.4 | control-plane + worker |

- **API VIP:** 192.168.1.240
- **Ingress VIP:** 192.168.1.241
- **Domain:** okd.sudops.pl

## TODO

Tracked work — order is rough impact-per-effort, not strict sequencing.

### In flight
- [ ] **Finish the PNY → PM9A1 swap (node5, then node6)** — osd.0 swapped 04/2026 and validated (lifetime `kv_commit_lat` ~4 ms vs PNY ~95 ms, ~20× speedup). 2× more PM9A1 ordered late 04/2026; swap node5 first (was the slower of the two PNYs under fio — commit_latency hit 3.2 s). Reuse `data/pre-swap/swap-runbook.md`. After node6 lands, re-run `tests/ceph-storage-test.yaml` and expect cluster-side fsync ~30 ms (vs current 9.25 s with 2 PNYs in path).
- [ ] **Force `pg_num=32` on `nvme-replicated`** — `pg_num_min: "32"` shipped (commit `86580cd`); waiting for ArgoCD reconcile + PG split. Validate with `ceph osd pool ls detail`. Note: `BLUESTORE_SLOW_OP_ALERT` is hardware-bound on the PNYs (validated 04/2026), so this won't clear it on its own — only the drive swap will.
- [ ] **Investigate why `pg_autoscaler` returns empty status** — `ceph osd pool autoscale-status` returns `[]` even with `bulk: true` set; bouncing the active mgr didn't help. Likely a Squid 19.2.3 quirk; confirm and file upstream if reproducible.

### Queued — observability
- [ ] **Mikrotik metrics → Grafana** via `mktxp` exporter. New chart `components/cluster-config/mikrotik-exporter/` with Deployment + Service + ServiceMonitor + SealedSecret for the RouterOS API creds. Read-only RouterOS user, API service enabled. Grafana dashboard ID 13679. Lets us correlate Ceph throughput vs switch byte counters during benchmarks.
- [ ] **Loki logging stack (OKDerator)** — central log aggregation. Loki + Promtail (or the Vector alternative) deployed via the `loki-stack` Helm chart, backed by Ceph PVCs. Wire Grafana as the log datasource so logs and metrics live in one pane.

### Queued — storage
- [ ] **Baseline NVMe SMART now** — initial node-by-node capture done 04/2026 (`data/pre-swap/nvme-smart-node{4,5,6}.txt`); PM9A1 standalone baseline + post-fio captured (`data/pre-swap/pm9a1-smart-{before,after}.txt`). Still missing: a **periodic** capture cadence to derive a real wear-rate trend. Capture incoming PM9A1 SMART before insertion into node5/node6 so the new drives have a clean t=0. Long-term replacement landed 04/2026: `smartctl_exporter` DaemonSet now exposes `percentage_used` + `data_units_written` per device for trend graphs.
- [ ] **Multus migration for Ceph clients** — drafted in `blog-multus-ceph-migration-draft.md`. Macvlan NAD over `enp1s0f0np0`, flip `network.provider: multus`, rolling daemon restart. Pre-flight already passes (Multus + whereabouts present). No longer expected to lift throughput per Mikrotik traffic data — pursued for cleaner architecture, not bandwidth.
- [ ] **CephFS storage class** for ReadWriteMany workloads (currently RWO-only).
- [ ] **CephObjectStore (S3-compatible)** for backups; bucket-class wired into Velero or kopia.
- [ ] **OSD encryption at rest** — `encryptedDevice: true` on each OSD device entry; needs cluster-wide rolling redeploy of OSDs.
- [ ] **Periodic `rbd trash purge` schedule** — RBD CSI calls `rbd trash mv` (deferred delete) on PVC removal; the trashed images sit until something purges them and continue to consume pool space. A one-shot purge in 04/2026 reclaimed ~600 GiB. Use Ceph's built-in scheduler: `rbd trash purge schedule add --pool nvme-replicated 1d`. Validate with `rbd trash purge schedule status` and `rbd trash ls`.
- [ ] **Migrate `ceph-cluster` + `ceph-storage-classes` to the upstream `rook-ceph-cluster` Helm subchart** — would consolidate operator + cluster + pools + StorageClasses + PrometheusRules under one Helm release with chart-driven defaults; future Ceph upgrades become a chart version bump. Deferred until **after node5+node6 PNY→PM9A1 swaps complete** because (a) we're 3-OSD with no drain headroom and any rolling change risks an unplanned degraded window, (b) the subchart wants to own BlockPool/StorageClass/CephFilesystem definitions which are currently split across two of our charts, and (c) doing it during the drive migration makes regressions harder to attribute. Migration path: add `helm.sh/resource-policy: keep` to existing CephCluster/BlockPool/StorageClass before swapping, render with kubeconform, `oc diff` should show only label/annotation deltas. Removes the vendored `files/ceph-prometheus-rules.yaml` shipped 04/2026.
- [ ] **PV cleanup when stuck `Released` / "image has watchers"** — separate from the periodic purge: occasionally a trashed RBD image refuses removal with `image has watchers`, meaning a CSI client (kernel rbd map on a node, or a leftover NodePlugin attachment) still holds it. Investigate the CSI delete flow; PVs accumulate finalizers (`external-provisioner`, `external-attacher`) and the underlying images become orphaned. One known stuck image as of 04/2026: `csi-vol-3af138f8-1b96-41e4-a05d-108896d26954` in `nvme-replicated`.

### Queued — operators / catalog
- [ ] **NMState operator: upstream PR for `okderators` ImageStream bug** — context in `nmstate-imagestream-bug.md`. Today we use `community-operators` as a workaround.
- [ ] **Cloudflare API token → ESO + Bitwarden** — currently created manually. Migrate to External Secrets Operator with Bitwarden as backend.
- [ ] **Evaluate OKDerator-shipped operators for adoption** — Cluster Observability Operator, NetObserv Operator, Loki Operator, Node Feature Discovery, OADP, OKD Logging, OKD Pipelines, OKD Service Mesh 3 (Istio), Observability Operator. For each: decide replace-current / supplement / skip, based on whether it removes a custom Helm chart we're already maintaining. Don't adopt operators without a workload that benefits.

### Queued — platform expansion
- [ ] **Service mesh evaluation(OKDerator)** — Istio (already in repo as `istio-values.yaml`) vs OpenShift Service Mesh vs nothing. Decide based on actual use cases: mTLS between namespaces, traffic shifting for app rollouts, request-level observability. Don't adopt without a workload that benefits.
- [ ] **KubeVirt** — run VMs alongside containers (nested control plane, legacy workloads, isolated dev environments). Needs CPU/RAM headroom audit first; OSDs already eat 5–6 GiB per node and the autoscaler is fragile under memory pressure.
- [ ] **Migrate apps from old cluster (media stack + keepers)** — port over the workloads still running on the previous cluster. Prerequisite: cluster-side fsync latency in single-digit ms (i.e. swap finished). Apps are mostly RWO PVC workloads — fits current `ceph-nvme-block` SC. Open question: keeper/secret migration path (sealed-secrets re-encrypt vs ESO/Bitwarden cutover).
- [ ] **Immich** — self-hosted photo library. Needs RWX (CephFS, queued) for the library mount + a Postgres PVC. Defer until CephFS is up and the swap is done.

### Documentation hygiene
- [ ] **Refresh the rest of this README** — Architecture and Repo Structure sections list only the original components. Reality now includes `cluster-topology`, `kubelet-config`, `sealed-secrets`, `cert-manager`, monitoring/Grafana stack, ingress config, sample apps. Update both the wave list and the directory tree to match `bootstrap/root-app/values.yaml`.
- [ ] **Repo public-readiness pass** — drafts at `blog-*-draft.md` and `nmstate-imagestream-bug.md` currently committed; review for anything that shouldn't be public before next push to GitHub.