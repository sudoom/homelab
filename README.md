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
- [ ] **Force `pg_num=32` on `nvme-replicated`** — `pg_num_min: "32"` shipped (commit `86580cd`); waiting for ArgoCD reconcile + PG split. Validate with `ceph osd pool ls detail` and that `BLUESTORE_SLOW_OP_ALERT` clears under load.
- [ ] **Investigate why `pg_autoscaler` returns empty status** — `ceph osd pool autoscale-status` returns `[]` even with `bulk: true` set; bouncing the active mgr didn't help. Likely a Squid 19.2.3 quirk; confirm and file upstream if reproducible.

### Queued — observability
- [ ] **Mikrotik metrics → Grafana** via `mktxp` exporter. New chart `components/cluster-config/mikrotik-exporter/` with Deployment + Service + ServiceMonitor + SealedSecret for the RouterOS API creds. Read-only RouterOS user, API service enabled. Grafana dashboard ID 13679. Lets us correlate Ceph throughput vs switch byte counters during benchmarks.
- [ ] **NVMe SMART metrics → Grafana** via `smartctl_exporter` DaemonSet. Surfaces `percentage_used`, `data_units_written`, media errors per device. Goal: a wear-rate panel that catches consumer NVMe burning through TBW under Ceph write amp before failure (~5–10× amplification = a 600 TBW drive can wear out in weeks under sustained load).
- [ ] **Ceph alerting rules** — `monitoring.enabled: true` only creates ServiceMonitors, not PrometheusRules. Add `OSDDown`, `PGDegraded`, `OSDNearFull`, `MGRsDown`, `MonClockSkew` at minimum.
- [ ] **Loki logging stack (OKDerator)** — central log aggregation. Loki + Promtail (or the Vector alternative) deployed via the `loki-stack` Helm chart, backed by Ceph PVCs. Wire Grafana as the log datasource so logs and metrics live in one pane.

### Queued — storage
- [ ] **Baseline NVMe SMART now** — one-shot capture per node: `oc debug node/<n>` → `chroot /host nvme smart-log /dev/nvme0n1`. Record `data_units_written` + `percentage_used` and pin in the rook-ceph blog draft. Re-run weekly to derive an actual wear rate; informs when (not if) the consumer drives need replacing with PLP-equipped enterprise NVMe.
- [ ] **Multus migration for Ceph clients** — drafted in `blog-multus-ceph-migration-draft.md`. Macvlan NAD over `enp1s0f0np0`, flip `network.provider: multus`, rolling daemon restart. Pre-flight already passes (Multus + whereabouts present). No longer expected to lift throughput per Mikrotik traffic data — pursued for cleaner architecture, not bandwidth.
- [ ] **CephFS storage class** for ReadWriteMany workloads (currently RWO-only).
- [ ] **CephObjectStore (S3-compatible)** for backups; bucket-class wired into Velero or kopia.
- [ ] **OSD encryption at rest** — `encryptedDevice: true` on each OSD device entry; needs cluster-wide rolling redeploy of OSDs.
- [ ] **PV cleanup when stuck `Released`** — investigate CSI delete flow; PVs accumulate finalizers (`external-provisioner`, `external-attacher`) and the underlying RBD images become orphaned.

### Queued — operators / catalog
- [ ] **NMState operator: upstream PR for `okderators` ImageStream bug** — context in `nmstate-imagestream-bug.md`. Today we use `community-operators` as a workaround.
- [ ] **Cloudflare API token → ESO + Bitwarden** — currently created manually. Migrate to External Secrets Operator with Bitwarden as backend.

### Queued — platform expansion
- [ ] **Service mesh evaluation(OKDerator)** — Istio (already in repo as `istio-values.yaml`) vs OpenShift Service Mesh vs nothing. Decide based on actual use cases: mTLS between namespaces, traffic shifting for app rollouts, request-level observability. Don't adopt without a workload that benefits.
- [ ] **KubeVirt** — run VMs alongside containers (nested control plane, legacy workloads, isolated dev environments). Needs CPU/RAM headroom audit first; OSDs already eat 5–6 GiB per node and the autoscaler is fragile under memory pressure.

### Documentation hygiene
- [ ] **Refresh the rest of this README** — Architecture and Repo Structure sections list only the original components. Reality now includes `cluster-topology`, `kubelet-config`, `sealed-secrets`, `cert-manager`, monitoring/Grafana stack, ingress config, sample apps. Update both the wave list and the directory tree to match `bootstrap/root-app/values.yaml`.
- [ ] **Repo public-readiness pass** — drafts at `blog-*-draft.md` and `nmstate-imagestream-bug.md` currently committed; review for anything that shouldn't be public before next push to GitHub.

- loki-logging grafana connection


- evaluate OKDerator:
Cluster Observability Operator
NetObserv Operator
Loki Operator
Node Feature Discovery Operator
OADP Operator
OKD Logging
OKD Pipelines
OKD Service Mesh 3 (Istio)
Observability Operator
