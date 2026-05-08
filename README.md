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
- [ ] **Investigate why `pg_autoscaler` returns empty status** — `ceph osd pool autoscale-status` returns `[]` even with `bulk: true` set; bouncing the active mgr didn't help. Likely a Squid 19.2.3 quirk; confirm and file upstream if reproducible. With `pg_num_min: 128` now landed on the live pool, this is no longer load-bearing for `nvme-replicated` sizing — but it still matters for any future pool that grows organically.

### Queued — observability
- [ ] **Logging stack read-path 504 (querier ↔ index-gateway gRPC pool)** — write path is verified end-to-end (Vector → gateway → ingester → RGW; bucket grew steady through diagnosis). Grafana queries against `Loki (infrastructure)` and `Loki (audit)` return 504 because the querier evicts the index-gateway from its connection pool every ~10s with `pool.go:250 reason="rpc error: code = DeadlineExceeded"`. TLS + mTLS handshake to the index-gateway succeeds independently (verified via debug pod with the querier's own grpc cert + Loki signing CA bundle). Failure is gRPC application-layer — most likely the index-gateway TSDB shipper blocking on slow Ceph reads (PNY OSDs still in path on osd.1/osd.2 → resolves with the PM9A1 swap), or a Loki Operator v6.3.0 bug at `1x.pico`. Full diagnosis chronology in `blog-loki-logging-draft.md`.
- [ ] **Logging stack `application` tenant — LOG-6894** — Red Hat upstream bug; `grafana-loki` SA gets `allowed: true` from cluster-side SAR for `loki.grafana.com/application/logs:get`, but observatorium-api's OPA still returns 403. KCS-7113062 has no fix at v6.3.0. Workaround: enable the OpenShift console plugin (different OAuth path) for application logs. Re-test on the next loki-operator bump.

### Queued — storage
- [ ] **Baseline NVMe SMART now** — initial node-by-node capture done 04/2026 (`data/pre-swap/nvme-smart-node{4,5,6}.txt`); PM9A1 standalone baseline + post-fio captured (`data/pre-swap/pm9a1-smart-{before,after}.txt`). Still missing: a **periodic** capture cadence to derive a real wear-rate trend. Capture incoming PM9A1 SMART before insertion into node5/node6 so the new drives have a clean t=0. Long-term replacement landed 04/2026: `smartctl_exporter` DaemonSet now exposes `percentage_used` + `data_units_written` per device for trend graphs.
- [ ] **Multus migration for Ceph clients** — drafted in `blog-multus-ceph-migration-draft.md`. Macvlan NAD over `enp1s0f0np0`, flip `network.provider: multus`, rolling daemon restart. Pre-flight already passes (Multus + whereabouts present). **Rationale flipped post-PM9A1 swap (2026-05-07)**: the 1 GbE frontnet is now genuinely close to saturating on 1M QD8 seqwrite (router peaked ~600 Mb/s during dd), so moving client→primary traffic onto the 10 GbE backnet is expected to lift 1M seqwrite ~173 MB/s → ~700 MB/s and random read 40 k → ~100 k IOPS. No effect on QD1 fsync or QD32 randwrite ceilings (per-op replication latency dominates those, network is < 5 % of the floor). Validate by re-running `tests/ceph-storage-test-libaio.yaml` post-migration and comparing the seqread/seqwrite numbers in the bottleneck-sweep table in `blog-rook-ceph-draft.md`.
- [ ] **CephFS storage class** for ReadWriteMany workloads (currently RWO-only). **Blocked on HDD addition** — CephFS data pool will live on bulk HDDs (NVMe stays for the metadata pool); deferred until the HDDs land in the chassis.
- [ ] **CephObjectStore (S3-compatible)** — net-new RGW workload via Rook's `CephObjectStore` CR. `metadataPool.deviceClass: nvme` permanently; `dataPool.deviceClass: nvme` interim, flip to `hdd` when the chassis has bulk drives (Ceph rebalances data via CRUSH-rule update; metadata + RGW endpoint unchanged). Unblocks the Loki/Logging stack and OADP backups in one shot.
- [ ] **OSD encryption at rest** — `encryptedDevice: true` on each OSD device entry; needs cluster-wide rolling redeploy of OSDs.
- [ ] **Migrate `ceph-cluster` + `ceph-storage-classes` to the upstream `rook-ceph-cluster` Helm subchart** — would consolidate operator + cluster + pools + StorageClasses + PrometheusRules under one Helm release with chart-driven defaults; future Ceph upgrades become a chart version bump. Deferred until **after node5+node6 PNY→PM9A1 swaps complete** because (a) we're 3-OSD with no drain headroom and any rolling change risks an unplanned degraded window, (b) the subchart wants to own BlockPool/StorageClass/CephFilesystem definitions which are currently split across two of our charts, and (c) doing it during the drive migration makes regressions harder to attribute. Migration path: add `helm.sh/resource-policy: keep` to existing CephCluster/BlockPool/StorageClass before swapping, render with kubeconform, `oc diff` should show only label/annotation deltas. Removes the vendored `files/ceph-prometheus-rules.yaml` shipped 04/2026.
- [ ] **PV cleanup when stuck `Released` / "image has watchers"** — separate from the periodic purge: occasionally a trashed RBD image refuses removal with `image has watchers`, meaning a CSI client (kernel rbd map on a node, or a leftover NodePlugin attachment) still holds it. Investigate the CSI delete flow; PVs accumulate finalizers (`external-provisioner`, `external-attacher`) and the underlying images become orphaned. One known stuck image as of 04/2026: `csi-vol-3af138f8-1b96-41e4-a05d-108896d26954` in `nvme-replicated`.

### Queued — platform plumbing
- [ ] **Drop `okd.sudops.pl` from the node-side DNS search list** — RHCOS nodes get `search okd.sudops.pl` in their `resolv.conf` from DHCP, so every name a host-side process resolves under `ndots:5` gets a `<name>.okd.sudops.pl` permutation tried first. This is what populates pi-hole's "Top Permitted Domains" with entries like `github.com.okd.sudops.pl` (141k) and `monitoring-plugin.openshift-monitoring.svc.cluster.local.okd.sudops.pl` (23k). `okd.sudops.pl` is a record domain (the cluster ingress), not a search domain; nothing legitimate should ever expand `<x>.okd.sudops.pl` from the host. Fix is a `MachineConfig` adjusting `NetworkManager` `dns-search`/`ignore-auto-dns` so the suffix doesn't land in node resolv.conf. Lower priority since pi-hole rate-limit is now off and the technetium migration is queued, but it's a permanent correctness fix that should outlive both.
- [ ] **GitHub OAuth IdP for cluster auth** — replaces ad-hoc `kube:admin` tokens that expire every session. Register a GitHub OAuth app with callback `https://oauth-openshift.apps.okd.sudops.pl/oauth2callback/github` pinned to a specific GitHub org/team, sealed-secret the client secret into `openshift-config`, patch `OAuth/cluster` with a `identityProviders[].type: GitHub` entry, grant cluster-admin to the GitHub username via `oc adm policy add-cluster-role-to-user`. Keep an `htpasswd` IdP alongside as permanent break-glass. Do not disable the `kubeadmin` user until end-to-end login is verified.

### Queued — operators / catalog
- [ ] **NMState operator: upstream PR for `okderators` ImageStream bug** — context in `nmstate-imagestream-bug.md`. Today we use `community-operators` as a workaround.
- [ ] **Cloudflare API token → sealed-secrets** — currently created manually. Convert to a sealed-secret committed via the cert-manager component chart so token rotation is a re-seal+commit instead of an out-of-band kubectl. Decided against ESO+Bitwarden for now: sealed-secrets is already deployed and sufficient at this scale; ESO is overkill until there are many more credentials to centralize.
- [ ] **OADP (OpenShift API for Data Protection, OKDerator)** — Velero-based PV + Kubernetes-resource backups to S3. Backs up app PVCs (CNPG dumps + WAL once that's wired, Loki chunks once that's running, future apps like Immich). Blocked on the same `CephObjectStore` rollout as the logging stack; install both operators in the same wave-1 batch and have OADP ready to take backups once the bucket exists.

### Queued — platform expansion
- [ ] **Service mesh evaluation(OKDerator)** — Istio (already in repo as `istio-values.yaml`) vs OpenShift Service Mesh vs nothing. Decide based on actual use cases: mTLS between namespaces, traffic shifting for app rollouts, request-level observability. Don't adopt without a workload that benefits.
- [ ] **KubeVirt** — run VMs alongside containers (nested control plane, legacy workloads, isolated dev environments). Needs CPU/RAM headroom audit first; OSDs already eat 5–6 GiB per node and the autoscaler is fragile under memory pressure.
- [ ] **Migrate apps from old cluster (media stack + keepers)** — port over the workloads still running on the previous cluster. Prerequisite: cluster-side fsync latency in single-digit ms (i.e. swap finished). Apps are mostly RWO PVC workloads — fits current `ceph-nvme-block` SC. Open question: keeper/secret migration path (sealed-secrets re-encrypt vs ESO/Bitwarden cutover).
- [ ] **Immich** — self-hosted photo library. Needs RWX (CephFS, queued) for the library mount + a Postgres PVC. Defer until CephFS is up and the swap is done.
- [ ] **CNPG follow-ups** — operator landed 2026-05-01 (Subscription-only, no clusters yet). Open work: (a) decide single-instance vs HA pattern per app — leaning `instances: 1` for everything until headroom audit, with Ceph 3-way replication as durability story; (b) backup target — interim `pg_dump` CronJobs to PVC until `CephObjectStore` lands, then flip CNPG `barmanObjectStore` config to S3 + WAL archiving; (c) first app to onboard (Immich is the obvious candidate once CephFS + swap are done).

### Documentation hygiene
- [ ] **Repo public-readiness pass** — drafts at `blog-*-draft.md` and `nmstate-imagestream-bug.md` currently committed; review for anything that shouldn't be public before next push to GitHub.