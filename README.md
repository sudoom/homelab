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
    nm-search-strip/       # Wave 0 — MC: NM dispatcher strips okd.sudops.pl from resolv.conf search list
    automation-sa/         # Wave 0 — claude-reader read-only ServiceAccount
    cluster-network-config/ # Wave 0 — OVN-K routingViaHost: true (pod→backnet hairpin)
    nmstate-nncp/          # Wave 2 — storage backnet NNCPs per node
    cert-manager-config/   # Wave 2 — ClusterIssuer (LE prod, DNS-01 Cloudflare) + Certificates
    oauth-idp/             # Wave 2 — OAuth IDP wiring (GitHub OAuth)
    csi-driver-config/     # Wave 2 — SSA-patches Driver CR's controllerPlugin.hostNetwork
    ceph-network-attachments/ # Wave 2 — Multus NADs (DISABLED; for future multus retry)
    ingress-controller/    # Wave 3 — wildcard cert wired to openshift-ingress
    api-server/            # Wave 3 — APIServer serving cert + etcd encryption at rest
    grafana-config/        # Wave 5 — dashboards, datasources, Grafana CR
    monitoring-config/     # Wave 5 — user-workload-monitoring + alert routing
    logging-stack/         # Wave 5 — LokiStack + ClusterLogForwarder + OBC for RGW chunks
    loki-pdb-override/     # Wave 6 — CronJob keeping ingester PDB at MinAvailable=1 (drain headroom)
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
    loki-operator/         # Loki operator (Red Hat)
    cluster-logging/       # Cluster Logging operator (Red Hat)
  storage/
    rook-ceph-cluster/     # CephCluster CR via upstream rook-ceph-cluster subchart + local extras
                           # (toolbox, dashboard Route, mgr ServiceMonitor, RBD trash purge,
                           # CSI provisioner caps-fix, pg_num floor, object bucket SC)
    ceph-object-store/     # CephObjectStore (RGW) + Route + PrometheusRule
    nfs-csi/               # NFS CSI driver for legacy/external mounts
  apps/
    cnpg-clusters/         # Per-namespace CNPG Cluster CRs (currently: media-postgres,
                           #   3-instance PG 18, 6 DBs for the .NET servarrs)
    media/                 # Media stack: 4 servarrs (sonarr/radarr/prowlarr/bazarr) + jellyfin
                           #   + transmission (master/slave); first 3 on Postgres via media-postgres
    keepers/               # Keepers stack: transmission (VPN) + webtlo (rutracker keeper).
                           #   Shipped enabled: false until vpn-creds is re-sealed for the ns.
ansible/                   # Non-OKD home infra managed by Ansible (outside ArgoCD)
  technitium/              # Technitium DNS Server (replaces pi-hole) — primary + future secondary
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
- [ ] **File upstream: `pg_autoscaler` returns empty status with `bulk: true` on Squid 19.2.3** — `ceph osd pool autoscale-status` returns `[]` even with `bulk: true` set; bouncing the active mgr didn't help. Confirmed on two pools (`nvme-replicated` and `ceph-objectstore.rgw.buckets.data`, both stuck at `pg_num: 1` until a one-time toolbox bump past Ceph's `pg_num_min > pg_num` EINVAL guardrail). **Bug report drafted** at `bugs/upstream-ceph-pg-autoscaler-bulk-ignored.md` — ready to paste as a tracker.ceph.com issue. Workaround context in `blog/blog-ceph-object-store-draft.md`.

### Queued — observability
- [ ] **PrometheusRule: alert when Ceph cluster utilization > 80%** — the 2026-05-20 OSD_FULL incident went undetected for 5 days because the only signal was the 95% mon_osd_full_ratio backstop tripping (which by then had already blocked all cluster writes). Expression: `ceph_cluster_total_used_bytes / ceph_cluster_total_bytes > 0.80`, `for: 1h` to avoid flapping on transient deltas, severity warning. Same exporter set already in cluster (rook-ceph-mgr metrics). Should be the next observability follow-up. Full incident writeup in `blog/blog-rook-ceph-draft.md` (2026-05-20 section).
- [ ] **Logging stack `application` tenant — LOG-6894** — Red Hat upstream bug; `grafana-loki` SA gets `allowed: true` from cluster-side SAR for `loki.grafana.com/application/logs:get`, but observatorium-api's OPA still returns 403. KCS-7113062 has no fix at v6.3.0. Workaround: enable the OpenShift console plugin (different OAuth path) for application logs. Re-test on the next loki-operator bump.

### Queued — storage
- [ ] **Baseline NVMe SMART now** — initial node-by-node capture done 04/2026 (`data/pre-swap/nvme-smart-node{4,5,6}.txt`); PM9A1 standalone baseline + post-fio captured (`data/pre-swap/pm9a1-smart-{before,after}.txt`). Still missing: a **periodic** capture cadence to derive a real wear-rate trend. Capture incoming PM9A1 SMART before insertion into node5/node6 so the new drives have a clean t=0. Long-term replacement landed 04/2026: `smartctl_exporter` DaemonSet now exposes `percentage_used` + `data_units_written` per device for trend graphs.
- [ ] **Investigate elevated cluster-wide `kv_commit_lat`** — post-rebuild 2026-05-15 baseline is 8-17ms across OSDs vs the post-PM9A1-swap reference ~3ms from 2026-05-07. Read-side fine; affects sustained seqwrite (today's bench: 119 MB/s on a freshly-bootstrapped cluster vs morning's 163 MB/s on a warm cluster). Hypotheses: BlueStore RocksDB compaction overhead post-pg_num bump still settling; node6's higher `percentage_used` (11% vs 4-6% on node4/5) accelerating; thermal under sustained burst. Next step: re-bench in a few days on a steady-state cluster; if delta persists, dig into `ceph daemon osd.N perf dump` over time.
- [ ] **File upstream: Rook generates `csi-rbd-provisioner.<gen>` with missing `osd profile rbd` cap on fresh bootstrap** — discovered 2026-05-15 during the post-teardown re-bootstrap. `client.csi-rbd-provisioner.1` ends up with only `mgr "allow rw"` + `mon "profile rbd, allow command 'osd blocklist'"`; the companion `csi-rbd-node.1` (and both cephfs users) get correct caps including `osd profile rbd`. Without the osd cap CSI authenticates fine but every `CreateVolume` hangs at the first RADOS op → gRPC `DeadlineExceeded` → "operation already exists" lock storm. **Bug report drafted** at `bugs/upstream-rook-csi-rbd-provisioner-missing-osd-cap.md` — ready to paste as a github.com/rook/rook issue. Workaround is a one-time `ceph auth caps` per fresh bootstrap (also documented in CLAUDE.md "RBD CSI quirks").
- [ ] **File upstream: Rook doesn't propagate `CSI_ENABLE_HOST_NETWORK` to `Driver.csi.ceph.io.spec.controllerPlugin.hostNetwork`** — discovered 2026-05-15 right after the cap bug above. `rook-ceph-operator-config.CSI_ENABLE_HOST_NETWORK: "true"` correctly puts the **nodeplugin** DaemonSet on hostNetwork, but the **ctrlplugin** Deployment is left on the pod network because the Driver CR field never gets set. On this cluster (OSDs bound to the 10G backnet via `addressRanges`), pod-network ctrlplugin can't reach cross-node OSDs and every CreateVolume hangs. Filed locally at `bugs/upstream-rook-csi-enable-host-network-not-propagated.md`. Workaround chart `components/cluster-config/csi-driver-config/` (commit `345cb1b`) SSA-patches `controllerPlugin.hostNetwork: true` on both rbd + cephfs Driver CRs; obsolete the moment Rook lands the propagation fix.
- [ ] **File upstream: Rook tracks pod IP for mon-endpoint advertisement, ignores `network.addressRanges` for mons** — observed 2026-05-15: with `provider: host` + `addressRanges.public/cluster: ["192.168.10.0/24"]`, OSDs correctly bind to the backnet, but `ceph mon dump` shows mons at the frontnet `192.168.1.{7,8,9}:6789` (kubelet-registered nodeIP). `rook-ceph-mon-endpoints` ConfigMap propagates the frontnet IPs to clients via the CSI config. Mon traffic is small per-op but every client opens with the mon first → consistent path over 1G. Need to confirm whether Rook intentionally uses pod IP for mon endpoints (because mons need stable advertised endpoints across pod restart) or whether this is a bug in the `addressRanges` honoring. Draft pending — capture repro + needs-investigation note before filing.
- [ ] **File upstream: Rook operator doesn't clear `public_network` / `cluster_network` from Ceph config DB on `network.provider` change** — surfaced during the 2026-05-12 Multus rollback. When `provider` changes from `host` to `""`, Rook updates daemon Deployments but leaves the stale CIDR settings in the Ceph config DB. The first OSD rolled to the new shape then crashloops with `unable to find any IPv4 address in networks '<old-CIDR>' interfaces ''`. Manual workaround: `ceph config rm global public_network` (+ `cluster_network`) from the toolbox before the transition. **Bug report drafted** at `bugs/upstream-rook-network-provider-config-db-stale.md` — ready to paste as a github.com/rook/rook issue. Also documents the cascading `ok-to-stop` deadlock on low-OSD-count clusters as a related but separable concern.
- [ ] **CephFS storage class** for ReadWriteMany workloads (currently RWO-only). **Blocked on HDD addition** — CephFS data pool will live on bulk HDDs (NVMe stays for the metadata pool); deferred until the HDDs land in the chassis.
- [ ] **Flip RGW `dataPool.deviceClass` from `nvme` to `hdd`** — once bulk HDDs land in the chassis. Single-line values change in `components/storage/ceph-object-store`; Rook updates the CRUSH rule, Ceph rebalances over the storage backnet, RGW endpoint + bucket names + client config unchanged. Metadata pool stays NVMe permanently.
- [ ] **OSD encryption at rest** — `encryptedDevice: true` on each OSD device entry; needs cluster-wide rolling redeploy of OSDs.
- [ ] **Ceph msgr2 secure mode (encryption in transit)** — flip `network.connections.encryption.enabled: true` on the `CephCluster` CR + corresponding `ms_cluster_mode=secure` / `ms_client_mode=secure` Ceph daemon-config keys. Encrypts OSD↔OSD replication on the storage backnet (today CRC integrity only, no confidentiality). Backnet is a dedicated VLAN with no other hosts, so threat is theoretical — but it's a single config knob and pairs naturally with OVN-K IPsec (`Queued — platform plumbing`) for end-to-end in-transit cover. Cost: 5-10% small-IO latency. Requires daemon roll on each MON/MGR/OSD — degraded-window event, same constraint as any OSD-touching change.
- [ ] **PV cleanup when stuck `Released` / "image has watchers"** — separate from the periodic purge: occasionally a trashed RBD image refuses removal with `image has watchers`, meaning a CSI client (kernel rbd map on a node, or a leftover NodePlugin attachment) still holds it. Investigate the CSI delete flow; PVs accumulate finalizers (`external-provisioner`, `external-attacher`) and the underlying images become orphaned. One known stuck image as of 04/2026: `csi-vol-3af138f8-1b96-41e4-a05d-108896d26954` in `nvme-replicated`.
- [ ] **Cosmetic: remove orphan `default.rgw.*` pools + zone/zonegroup** — surfaced 2026-05-10 during RGW health-check. Three empty pools (`default.rgw.log/.control/.meta`) plus a `default` zone definition and `default` zonegroup live alongside the real `ceph-objectstore` zone (created during RGW first-bring-up, ignored by Rook ever since). Removal requires temporarily flipping `mon_allow_pool_delete=true`, `radosgw-admin zone delete + zonegroup delete`, then `ceph osd pool delete x3`. Purely cosmetic — `radosgw-admin` from the toolbox just defaults to the orphan zone (which is why earlier `bucket list` runs returned `[]`); Loki + future S3 consumers run cleanly against `ceph-objectstore`. Defer until there's slack.

### Queued — platform plumbing
- [ ] **Pi-hole → Technitium DNS migration — cutover + soak + purge SHIPPED; loose ends remaining** — `dns-master` (RPi 3B+ at `192.168.1.12`, same physical box, fresh SD card) serves DNS via Technitium DNS Server with an authoritative split-horizon zone for `okd.sudops.pl` (replaces pi-hole's old conditional-forwarder chain to gw.home.lab). `cluster.local` + `svc.cluster.local.okd.sudops.pl` ship as authoritative-empty NXDOMAIN zones; the StevenBlack/hosts blocklist (~82.6k domains) is wired in. Forwarder zones for `home.lab` + `homelab.net` delegate to MikroTik (192.168.1.1). Ansible playbook lives at `ansible/technitium/` (all `ansible.builtin.*`, vault-encrypted secrets, run manually from a workstation). 2026-05-13 soak check: 19h continuous uptime, 0 errors/warns in journal, 270MiB RSS, load avg 0.05, all four DNS-path tests pass (auth / forwarder / blocklist / recursive). Pi-hole purge codified in the `base` role's `pihole-cleanup` block (apt purge `pihole-meta` + file:state=absent across the installer-managed paths + daemon-reload); applied to `dns-master` and verified 0 pi-hole packages / 0 paths remaining. Full chronology + post-cutover bug log in `blog/blog-technitium-dns-migration-draft.md`. **Loose ends remaining:**
  - On MikroTik: delete the disabled static DNS entries for `api.okd.sudops.pl` / `api-int.okd.sudops.pl` / `apps.sno.home.lab` / `*.apps.okd.sudops.pl` regex (already X-disabled so functionally already cleaned up — just clutter); update DHCP lease record for `192.168.1.12` from `pi-hole-master` to `dns-master`. All cosmetic. Manual on the router — MikroTik is not Ansible-managed.
  - Procure RPi Zero 2W for the `dns-secondary` secondary (not blocking)
  - Monitoring: wire Technitium's Prometheus exporter into the cluster's stack (low priority)
- [ ] **`homelab.sudops.pl` zone + wildcard cert + Synology auto-import** — new authoritative LAN-only zone for non-OKD appliances (NAS, dns-master, etc.). Three pieces: (a) Ansible task adds `homelab.sudops.pl` zone to Technitium with A records per appliance, (b) cert-manager `Certificate` for `*.homelab.sudops.pl` via the existing letsencrypt-prod ClusterIssuer + Cloudflare DNS-01 (token already covers `sudops.pl`), (c) daily CronJob mounts the cert Secret and pushes any change to Synology DSM via its API (creds in a SealedSecret). LAN-only resolution via Technitium; no public A records on Cloudflare = no LAN-IP leak. **Design doc** at `blog/blog-homelab-sudops-zone-draft.md`. Open inputs before implementation: full hostname list + LAN IPs, DSM cert-import user creds to seal.
- [ ] **Jellyfin: in-cluster vs Mac mini — decision + migrate to official image** — primary Jellyfin currently runs on a Mac mini outside the cluster; the in-cluster `lscr.io/linuxserver/jellyfin` (configured 2026-05-15 with PUID=0 NFS-root-squash bypass, /config on ceph-nvme-block, /data on NFS) is at this point a parallel instance. **Decision needed**: (1) decommission Mac mini, make in-cluster the canonical Jellyfin, OR (2) keep Mac mini as canonical, remove the in-cluster one + free the 30Gi config PVC, OR (3) keep both running with different roles (e.g., Mac mini for HW transcoding, cluster for library indexing). If we go with (1), also migrate from `lscr.io/linuxserver/jellyfin` to the official `jellyfin/jellyfin:<tag>` image (no PUID/PGID env — use `securityContext.runAsUser: 0` instead; add `/cache` emptyDir for transcoding scratch; keep `/config` + `/data` paths). Renovate already tracks both image families. Tradeoff: linuxserver has community fixes shipped faster; official has fewer abstractions + closer-to-upstream behavior. Defer until usage pattern is clear.
- [ ] **Encryption in transit — OVN-Kubernetes IPsec — ATTEMPT 1 ROLLED BACK 2026-05-20.** Enabling `mode: Full` triggered an MCO master-pool reroll (kernel modules + NM service install via MachineConfig — wasn't flagged pre-apply) which then surfaced multiple cluster-breaking interactions: (a) Loki ingester PDB MinAvailable=2 with 2 replicas blocked drain permanently, (b) image pulls extremely slow across IPsec (~15-19 min for ceph images), (c) RGW + router anti-affinity left only 1 schedulable node when routers re-balanced, (d) post-IPsec-reboot node could not reach etcd on host-network IPs (`192.168.1.7:2379`, `192.168.1.9:2379`) cross-node — root cause TBD. Rolled back via `oc patch network.operator/cluster` directly (ArgoCD repo-server was timing out under cluster stress). Pre-flight checklist for next attempt — full chronology + lessons in `blog/blog-security-hardening-draft.md` 2026-05-20 section. Pre-IPsec baseline measurements (cleartext geneve tcpdump, iperf3 cross-node 879 Mbits/sec, RGW HTTP latency p50 2.0ms) captured 2026-05-21 in `data/ipsec-baseline-2026-05-21/`. **Do not re-enable until**: ~~(1) Loki ingester drain headroom restored~~ DONE 2026-05-21 via `components/cluster-config/loki-pdb-override/`; (2) Kube Descheduler installed (next-priority, see below); (3) cross-node host-network IPsec interaction diagnosed; (4) MTU pre-flight (try `ovnKubernetesConfig.mtu: 1340` to leave room for ESP overhead — note MTU change is itself an MCO event so consolidate with IPsec into a single rollout).
- [ ] **Upstream feature request: expose PDB tunables on LokiStack `spec.template.<component>`** — the LokiStack CRD only exposes `replicas`/`nodeSelector`/`podAntiAffinity`/`tolerations` on each component; the PDB is hardcoded by the size-class renderer (e.g. ingester MinAvailable=2 in `1x.pico`). Tracked here because the local workaround chart `components/cluster-config/loki-pdb-override/` (CronJob that re-patches the PDB every 5 min, shipped 2026-05-21 — verified loki-operator does NOT actively reconcile the PDB, so 5 min is enough) becomes obsolete if upstream lands the tunable. Drop the chart + remove the upstream-bug TODO when that happens.
- [ ] **Sealed-secrets master key rotation** — `bitnami-labs/sealed-secrets` controller generates its master key on first start and never auto-rotates. The controller can hold a key history (old keys decrypt existing blobs; new key signs new blobs), so the operational shape is: rotate quarterly, re-seal every in-repo `SealedSecret` against the new key, leave the old key in the controller's history for one rotation cycle, then drop. Currently zero rotations done. Not urgent — homelab threat model — but worth a one-time procedure run + writing the runbook into the security blog draft so the next rotation is mechanical.
- [ ] **Power consumption reduction** — 3 nodes + Mac mini + RPi run 24/7; idle waste is the easiest thing to cut once we can measure it. **Telemetry shipped 2026-05-20**: Shelly plug on node6 wall socket (see Shelly Prometheus exporter TODO below). Once a 24h idle baseline is captured, the lever order is (1) custom Tuned profile (governor=powersave + intel_pstate=passive + deeper C-states, ~15-25W/node), (2) Mac mini Jellyfin decommission (separate TODO, ~10-30W), (3) NVMe APST + PCIe ASPM + 10G EEE (small but free). Don't bundle changes — A/B each against baseline. Full design + ranked levers + stop-list in `blog/blog-power-consumption-draft.md`.
- [ ] **Shelly Prometheus exporter for power telemetry** — node6 has a Shelly plug as of 2026-05-20; need to scrape its power readings into the cluster's existing Prometheus + Grafana stack so the power-tuning work can A/B against a real wattage number. Smallest path: a single Deployment running a Shelly-Prometheus-exporter image (e.g. `geerlingguy/shelly-plug-prometheus` or similar) pointed at the plug's LAN IP, plus a ServiceMonitor for the user-workload Prometheus to scrape it. Pure observability — adds a `shelly_power_watts` gauge series, no automation. If broader home-automation needs appear later, install Home Assistant separately and use HA's native Shelly integration (different use case, can coexist).

### Queued — operators / catalog
- [ ] **NMState operator: upstream PR for `okderators` ImageStream bug** — context in `nmstate-imagestream-bug.md`. Today we use `community-operators` as a workaround.
- [ ] **Track upstream PR for `kubernetes-nmstate-operator` (community-operators) CSV missing two `clusterPermissions`** — discovered 2026-05-11: (a) `use` on the `privileged` SCC, missing → new handler pods rejected at admission; (b) `get/list/watch apiservers.config.openshift.io`, missing → handler crashes on startup fetching the cluster TLS profile. Existing pods (15 days old, 20-36 restarts) survived because once admitted and past the startup TLS read, the watch loop doesn't re-check either permission. **PR filed at https://github.com/okd-project/okd-operator-pipeline/pull/19** — track to merge, then bump the local subscription past the fixed version and remove the workaround chart pieces (`components/operators/nmstate/templates/handler-scc-binding.yaml` + `handler-apiserver-rbac.yaml`).
- [ ] **OADP (OpenShift API for Data Protection, OKDerator)** — Velero-based PV + Kubernetes-resource backups to S3. Backs up app PVCs and Kubernetes manifests; target is a dedicated bucket on the existing `ceph-objectstore` RGW (separate `CephObjectStoreUser` from Loki). Subscription at wave 1, `DataProtectionApplication` CR at wave 5 referencing a SealedSecret with the user's S3 keys. Loki's bucket-creation pattern (OBC + secret-translator) is the precedent to follow.

### Queued — platform expansion
- [ ] **Service mesh evaluation(OKDerator)** — Istio (already in repo as `istio-values.yaml`) vs OpenShift Service Mesh vs nothing. Decide based on actual use cases: mTLS between namespaces, traffic shifting for app rollouts, request-level observability. Don't adopt without a workload that benefits.
- [ ] **KubeVirt** — run VMs alongside containers (nested control plane, legacy workloads, isolated dev environments). Needs CPU/RAM headroom audit first; OSDs already eat 5–6 GiB per node and the autoscaler is fragile under memory pressure.
- [ ] **Migrate apps from old cluster (media stack + keepers)** — port over the workloads still running on the previous cluster. Media stack now lives in tree (`components/apps/media/`); 3 of the 4 servarrs (Sonarr/Radarr/Prowlarr) on shared CNPG Postgres as of 2026-05-15. **Keepers stack ported 2026-05-15** (`components/apps/keepers/`, transmission + webtlo, shipped `enabled: false` pending `vpn-creds` SealedSecret re-seal for the keepers namespace). Remaining migration work is **config-only** (no DB data to bring across): re-apply each app's config via its web UI on the new cluster, re-seal each keeper Secret on the new cluster's sealed-secrets controller (per-controller pubkey means old blobs don't transplant). Pattern matches the in-repo Cloudflare token + GitHub OAuth client secret.
- [ ] **Evaluate Bazarr on Postgres once upstream marks it stable** — Bazarr added Postgres support in v1.4 (env vars `POSTGRES_ENABLED` / `POSTGRES_HOST` / `POSTGRES_DATABASE` / `POSTGRES_USERNAME` / `POSTGRES_PASSWORD` — Python/Flask shape, not the `.NET Sonarr__Postgres__*` form used by the other servarrs), but the project README still calls SQLite the supported backend and upstream issues report scheduler / background-task flakiness on Postgres. SQLite on `ceph-nvme-block` is fine for the current single-instance workload — don't migrate until upstream signals stable. If we do migrate later: needs a template branch in `components/apps/media/templates/apps.yaml` for the Python/Flask env shape.
- [ ] **File upstream: Sonarr v4 leaks Postgres password in cleartext in migration log** — `MigrationController: *** Migrating Database=sonarr-main;Host=...;Username=media;Password=<plaintext> ***` on every fresh boot. Radarr v5+ redacts the same line (`Username=(removed);Password=(removed)`); only Sonarr has the leak. Anyone with `kubectl logs` access (or read on Loki application tenant) sees the credential. **Bug report drafted** at `bugs/upstream-sonarr-password-leak-in-migration-log.md` — ready to paste as a github.com/Sonarr/Sonarr issue. No application-level workaround; operational mitigation is restricting log access + rotating the password on Sonarr boot events.
- [ ] **Immich** — self-hosted photo library. Needs RWX (CephFS, queued on HDDs) for the library mount; can use the shared `media-postgres` Cluster for the metadata DB (add `immich-main` / `immich-log` to the cluster's `postInitApplicationSQL`). Defer until CephFS is up.
- [ ] **KEDA** (CNCF graduated) — Event-driven autoscaling. Augments HPA with scalers for Prometheus metrics, queue depth, Kafka lag, S3 object counts, etc.; supports scale-to-zero for rare-use workloads. Single-operator install via OLM, ~3 pods, low footprint. No current consumer — install speculatively so it's ready when a use case appears (e.g. scale transmission-slave on torrent queue depth, scale a future batch-transcode worker on Sonarr queue, scale-to-zero a rarely-hit service). Cheap to keep installed without using.
- [ ] **Litmus** (CNCF incubating) — Chaos engineering operator. Inject pod kills / network latency / disk pressure / node drain to validate the cluster's known weak spots (3-OSD no-drain headroom, RGW anti-affinity collision, CSI mount-lock paths). Run as a quarterly drill, not continuous chaos. Real value: surfaces the next "21h outage discovered post-hoc" failure mode under controlled conditions. Single-operator install; park it after a one-time drill if appetite is low.
- [ ] **Kube Descheduler (OKDerator) — NEXT PRIORITY** — bumped from "evaluate later" 2026-05-20 after the IPsec rollout cascade. Exact symptom the queue rationale called out: anti-affinity-preferring workloads (routers, RGW, Loki ingesters) clustered onto suboptimal nodes during the MCO reroll and made the drain unrecoverable. Install with the `AffinityAndTaints` profile; **skip `LowNodeUtilization` + `PodLifeTime`** (the former is meaningless on a 3-node cluster, the latter is chaos-style without a reason). Exclusion list is load-bearing — must exempt `priorityClassName: system-cluster-critical`, namespaces `rook-ceph` / `openshift-gitops` / `openshift-monitoring` / `openshift-logging`, and CNPG-labeled pods. Without exclusions, descheduler will happily evict the CNPG primary or a Rook OSD.

