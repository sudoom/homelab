# okd-homelab-gitops

GitOps repository for a 3-node bare-metal OKD 4.20 homelab cluster managed by ArgoCD.

**Repo:** https://github.com/sudoom/homelab

## Architecture

```
Manual bootstrap (one-time, bootstrap/phase0/)
  └── CatalogSource + GitOps Operator + cluster-admin RBAC + root Application
        └── Root App-of-Apps (bootstrap/root-app/, Helm chart)
              ├── Wave 0: Cluster topology (node-labels, kubelet-config)
              ├── Wave 1: Operators
              │     └── NMState, cert-manager, Rook-Ceph, Grafana, sealed-secrets, CNPG
              ├── Wave 2: Cluster config that depends on operator CRDs
              │     └── NMState NNCPs, ClusterIssuer + Certificates
              ├── Wave 3: TLS consumers + Storage
              │     └── IngressController cert, APIServer cert, CephCluster
              ├── Wave 4: Storage classes
              │     └── Ceph BlockPool + StorageClass, NFS CSI
              ├── Wave 5: Monitoring + observability
              │     └── grafana-config (dashboards, datasources),
              │         monitoring-config (UWM, alert routes),
              │         smartctl-exporter, mikrotik-exporter, gatus
              └── Wave 6: Applications
                    └── media stack
```

## Bootstrap

Only the four numbered files in `bootstrap/phase0/` are applied manually. Everything past that is Argo-managed.

```bash
# 1. Apply the OLM catalog sources, OpenShift GitOps operator,
#    cluster-admin RBAC, and the credential template
oc apply -f bootstrap/phase0/01_catalog_source.yaml
oc apply -f bootstrap/phase0/02_gitops_operator.yaml
oc apply -f bootstrap/phase0/03_cluster_admin_rbac.yaml
oc apply -f bootstrap/phase0/04_credential_template.yaml

# 2. Wait for the GitOps operator + default ArgoCD instance
oc get csv -n openshift-gitops -w           # wait for Phase: Succeeded
oc get pods -n openshift-gitops -w          # wait for all pods Running

# 3. Apply the root App-of-Apps. ArgoCD then syncs everything else.
oc apply -f bootstrap/phase0/05_root_application.yaml
```

See `bootstrap/phase0/readme.md` for the full first-time bootstrap notes.

## Repo Structure

```
bootstrap/
  phase0/                  # One-time manual bootstrap (numbered files, applied in order)
  root-app/                # Helm chart that renders one Application per managed component
components/
  cluster-config/
    node-labels/           # Wave 0 — failure-domain + role labels
    kubelet-config/        # Wave 0 — kubelet tweaks (eviction thresholds, etc.)
    nmstate-nncp/          # Wave 2 — storage backnet NNCPs per node
    cert-manager-config/   # Wave 2 — ClusterIssuer (LE prod, DNS-01 Cloudflare) + Certificates
    ingress-controller/    # Wave 3 — wildcard cert wired to openshift-ingress
    api-server/            # Wave 3 — APIServer serving cert
    grafana-config/        # Wave 5 — dashboards, datasources, Grafana CR
    monitoring-config/     # Wave 5 — user-workload-monitoring + alert routing
    smartctl-exporter/     # Wave 5 — NVMe + SATA SMART metrics DaemonSet
    mikrotik-exporter/     # Wave 5 — mktxp / RouterOS metrics for the router + switch
    gatus/                 # Wave 5 — uptime dashboard
  operators/
    nmstate/               # NMState operator (community-operators catalog)
    cert-manager/          # cert-manager operator (okderators catalog)
    rook-ceph/             # Rook-Ceph via upstream Helm chart
    grafana/               # Grafana operator (operatorhubio-catalog)
    sealed-secrets/        # Bitnami sealed-secrets controller
    cnpg/                  # CloudNativePG operator (operatorhubio-catalog)
  storage/
    ceph-cluster/          # CephCluster CR, toolbox, RBD trash purge schedule Job, PrometheusRules
    ceph-storage-classes/  # CephBlockPool + StorageClass (ceph-nvme-block)
    nfs-csi/               # NFS CSI driver for legacy/external mounts
  apps/
    media/                 # Media stack (sample app)
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
- [ ] **Investigate why `pg_autoscaler` returns empty status** — `ceph osd pool autoscale-status` returns `[]` even with `bulk: true` set; bouncing the active mgr didn't help. **Two pools have now confirmed the quirk**: `nvme-replicated` (originally) and `ceph-objectstore.rgw.buckets.data` (2026-05-10) — both stuck at `pg_num: 1` until a manual toolbox bump bootstrapped them past Ceph's `pg_num_min > pg_num` EINVAL guardrail. Pure-GitOps `pg_num_min` enforcement requires that one-time manual nudge per new pool. Worth filing upstream now (Squid 19.2.3); workaround is captured in `blog/blog-ceph-object-store-draft.md`.

### Queued — observability
- [ ] **Logging stack `application` tenant — LOG-6894** — Red Hat upstream bug; `grafana-loki` SA gets `allowed: true` from cluster-side SAR for `loki.grafana.com/application/logs:get`, but observatorium-api's OPA still returns 403. KCS-7113062 has no fix at v6.3.0. Workaround: enable the OpenShift console plugin (different OAuth path) for application logs. Re-test on the next loki-operator bump.

### Queued — storage
- [ ] **Baseline NVMe SMART now** — initial node-by-node capture done 04/2026 (`data/pre-swap/nvme-smart-node{4,5,6}.txt`); PM9A1 standalone baseline + post-fio captured (`data/pre-swap/pm9a1-smart-{before,after}.txt`). Still missing: a **periodic** capture cadence to derive a real wear-rate trend. Capture incoming PM9A1 SMART before insertion into node5/node6 so the new drives have a clean t=0. Long-term replacement landed 04/2026: `smartctl_exporter` DaemonSet now exposes `percentage_used` + `data_units_written` per device for trend graphs.
- [ ] **Multus migration for Ceph clients — CephCluster flip + daemon roll remaining** — Phase 1 (NADs) and Phase 2 prep (per-node `ceph-shim` macvlan + `192.168.10.128/25 dev ceph-shim` route + whereabouts range shift) shipped 2026-05-11. Picked Rook's documented `macvlan + host-shim` pattern (Option A) over `ipvlan L2` because Rook upstream "highly recommends" macvlan and doesn't mention ipvlan at all — going off-doc on a 3-OSD-no-drain storage layer wasn't worth saving one NMState edit. Smoke-tested end-to-end: shared-pool whereabouts dedup confirmed, cross-host reachability at line rate (0.06–0.12 ms), and the previously-broken host→pod-on-same-node path now works at 0.03–0.05 ms via the shim. **Remaining**: flip `CephCluster.spec.network.provider` from `host` to `multus` with `selectors.public/cluster: rook-ceph/ceph-public,ceph-cluster`, roll mons one at a time, then OSDs, then mgr. Pre-flight with `rook multus validation` CLI before the spec change. Expected uplift (per pre-PM9A1 bottleneck-sweep): 1M seqwrite ~173 MB/s → ~700 MB/s, random read 40 k → ~100 k IOPS; no effect on QD1 fsync or QD32 randwrite (per-op replication latency dominates, network <5% of the floor). Caveat: per Rook docs, daemons listening on Service IPs (mgr, RGW, mon-via-Service) keep riding the OVN SDN even post-flip; the uplift applies to RBD direct traffic, not in-cluster S3 to `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc`. Full design + ops history in `blog/blog-multus-ceph-migration-draft.md`; baseline numbers to compare against captured in `blog/blog-rook-ceph-draft.md`.
- [ ] **CephFS storage class** for ReadWriteMany workloads (currently RWO-only). **Blocked on HDD addition** — CephFS data pool will live on bulk HDDs (NVMe stays for the metadata pool); deferred until the HDDs land in the chassis.
- [ ] **Flip RGW `dataPool.deviceClass` from `nvme` to `hdd`** — once bulk HDDs land in the chassis. Single-line values change in `components/storage/ceph-object-store`; Rook updates the CRUSH rule, Ceph rebalances over the storage backnet, RGW endpoint + bucket names + client config unchanged. Metadata pool stays NVMe permanently.
- [ ] **OSD encryption at rest** — `encryptedDevice: true` on each OSD device entry; needs cluster-wide rolling redeploy of OSDs.
- [ ] **Migrate `ceph-cluster` + `ceph-storage-classes` to the upstream `rook-ceph-cluster` Helm subchart** — would consolidate operator + cluster + pools + StorageClasses + PrometheusRules under one Helm release with chart-driven defaults; future Ceph upgrades become a chart version bump. Migration path: add `helm.sh/resource-policy: keep` to existing CephCluster/BlockPool/StorageClass before swapping, render with kubeconform, `oc diff` should show only label/annotation deltas. Removes the vendored `files/ceph-prometheus-rules.yaml` shipped 04/2026. Still needs care because we're 3-OSD with no drain headroom — any rolling restart goes through a degraded window — but the migration itself is a metadata refactor, not an OSD-impacting change, so it's lower risk than it sounds.
- [ ] **PV cleanup when stuck `Released` / "image has watchers"** — separate from the periodic purge: occasionally a trashed RBD image refuses removal with `image has watchers`, meaning a CSI client (kernel rbd map on a node, or a leftover NodePlugin attachment) still holds it. Investigate the CSI delete flow; PVs accumulate finalizers (`external-provisioner`, `external-attacher`) and the underlying images become orphaned. One known stuck image as of 04/2026: `csi-vol-3af138f8-1b96-41e4-a05d-108896d26954` in `nvme-replicated`.
- [ ] **Cosmetic: remove orphan `default.rgw.*` pools + zone/zonegroup** — surfaced 2026-05-10 during RGW health-check. Three empty pools (`default.rgw.log/.control/.meta`) plus a `default` zone definition and `default` zonegroup live alongside the real `ceph-objectstore` zone (created during RGW first-bring-up, ignored by Rook ever since). Removal requires temporarily flipping `mon_allow_pool_delete=true`, `radosgw-admin zone delete + zonegroup delete`, then `ceph osd pool delete x3`. Purely cosmetic — `radosgw-admin` from the toolbox just defaults to the orphan zone (which is why earlier `bucket list` runs returned `[]`); Loki + future S3 consumers run cleanly against `ceph-objectstore`. Defer until there's slack.

### Queued — platform plumbing
- [ ] **Migrate DNS from pi-hole (`192.168.1.12`) to "technetium"** — *priority bumped 2026-05-12 after the cluster overwhelmed pi-hole with a search-suffix leak storm: ~700 k queries in 18 h, sustained ~11 qps, on-host CoreDNS logs full of `read udp 192.168.1.X->192.168.1.12:53: i/o timeout`.* Root cause is structural and cluster-wide: pods inherit `search ... okd.sudops.pl` from the host resolv.conf via `dnsPolicy: ClusterFirst`, so with `ndots:5` every `<svc>.<ns>.svc.cluster.local` lookup search-expands to `<...>.svc.cluster.local.okd.sudops.pl`. That falls through cluster CoreDNS (`forward . /etc/resolv.conf`) → on-host baremetal CoreDNS → its `DNSUpstreams` → pi-hole → pi-hole's `okd.sudops.pl` conditional forwarder → timeout → caller retries. Amplifier: `dns.operator.openshift.io/default` ships with `cache: { negativeTTL: 0s, positiveTTL: 0s }`, so nothing is cached and every miss hits the upstream chain again. Heavy emitters are Loki memberlist (`gossip-ring`, `query-frontend-grpc`) and ArgoCD `repo-server-grpc`, but the leak applies to every cluster service lookup. **Decision (2026-05-12):** live with the leak; pi-hole is going away anyway, don't fix on a box that won't exist next month. **Carry-over rules to apply on technetium at cutover** (don't ship technetium without them): `local=/cluster.local/` (existing, inherited from current pi-hole) **plus** `local=/svc.cluster.local.okd.sudops.pl/` (new, identified 2026-05-12) — both make dnsmasq authoritatively NXDOMAIN cluster-internal names that escape the cluster, so cluster CoreDNS gets a fast denial it can cache. Also reconsider during cutover whether on-host CoreDNS `DNSUpstreams` and `dns.operator` upstreams should point at `gw.home.lab` directly instead of at the DNS box, so the cluster's own domain doesn't round-trip through a recursive resolver. Carry-over also includes the `RATE_LIMIT` bump that worked around the earlier per-client refused-storm.

### Queued — operators / catalog
- [ ] **NMState operator: upstream PR for `okderators` ImageStream bug** — context in `nmstate-imagestream-bug.md`. Today we use `community-operators` as a workaround.
- [ ] **Upstream missing nmstate-handler bindings to community-operators CSV** — two grandfathered-only RBAC bindings discovered 2026-05-11: (a) `use` on the `privileged` SCC, missing → new handler pods rejected at admission; (b) `get/list/watch apiservers.config.openshift.io`, missing → handler crashes on startup fetching the cluster TLS profile. Existing pods (15 days old, 20-36 restarts) survived because once admitted and past the startup TLS read, the watch loop doesn't re-check either permission. Working around both locally in `components/operators/nmstate/templates/handler-scc-binding.yaml` and `handler-apiserver-rbac.yaml`. The CSV's `clusterPermissions` is the proper home; file upstream when there's slack. **If a third permission surfaces on a future fresh handler pod, audit the full set rather than patching incrementally.**
- [ ] **OADP (OpenShift API for Data Protection, OKDerator)** — Velero-based PV + Kubernetes-resource backups to S3. Backs up app PVCs and Kubernetes manifests; target is a dedicated bucket on the existing `ceph-objectstore` RGW (separate `CephObjectStoreUser` from Loki). Subscription at wave 1, `DataProtectionApplication` CR at wave 5 referencing a SealedSecret with the user's S3 keys. Loki's bucket-creation pattern (OBC + secret-translator) is the precedent to follow.

### Queued — platform expansion
- [ ] **Service mesh evaluation(OKDerator)** — Istio (already in repo as `istio-values.yaml`) vs OpenShift Service Mesh vs nothing. Decide based on actual use cases: mTLS between namespaces, traffic shifting for app rollouts, request-level observability. Don't adopt without a workload that benefits.
- [ ] **KubeVirt** — run VMs alongside containers (nested control plane, legacy workloads, isolated dev environments). Needs CPU/RAM headroom audit first; OSDs already eat 5–6 GiB per node and the autoscaler is fragile under memory pressure.
- [ ] **Migrate apps from old cluster (media stack + keepers)** — port over the workloads still running on the previous cluster. Storage prerequisite met (3+0 PM9A1, cluster-side fsync p50 ~14 ms — see `blog/blog-rook-ceph-draft.md` bottleneck sweep). Apps are mostly RWO PVC workloads — fits current `ceph-nvme-block` SC. Secret migration path: re-seal each keeper Secret on the new cluster's sealed-secrets controller (the public key is per-controller, so the existing sealed blobs can't transplant directly). The pattern is the same as the in-repo Cloudflare token + GitHub OAuth client secret.
- [ ] **Immich** — self-hosted photo library. Needs RWX (CephFS, queued on HDDs) for the library mount + a Postgres PVC. Defer until CephFS is up.
- [ ] **CNPG follow-ups** — operator landed 2026-05-01 (Subscription-only, no clusters yet). Open work: (a) decide single-instance vs HA pattern per app — leaning `instances: 1` for everything until headroom audit, with Ceph 3-way replication as durability story; (b) backup target — wire `barmanObjectStore` straight to the existing `ceph-objectstore` RGW (S3 + WAL archiving + PITR) on the first cluster; no `pg_dump`-to-PVC interim needed; (c) first app to onboard (Immich is the obvious candidate once CephFS lands).

