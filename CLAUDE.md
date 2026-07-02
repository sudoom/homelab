# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Repository overview

Homelab GitOps repository for a **3-node bare-metal OKD 4.20 cluster** (OpenShift Kubernetes Distribution), managed declaratively by **ArgoCD** with an app-of-apps pattern and Helm templating.

- **Cluster domain:** `okd.sudops.pl`
- **Nodes:** 3 control-plane+worker; frontend `192.168.1.7–9`, storage backnet `192.168.10.2–4`
- **Failure domains** (`topology.kubernetes.io/zone`): `fd-a → node4`, `fd-b → node5`, `fd-c → node6`
- **Ingress:** `*.apps.okd.sudops.pl` (wildcard, cert-manager)
- **API:** `api.okd.sudops.pl`
- **Git:** `git@github.com:sudoom/homelab.git` — `master` = production (ArgoCD tracks), `develop` = working branch

## Stack and tool versions

Pin these when generating manifests or commands — mismatched versions are the single largest source of wrong suggestions.

| Tool            | Version        | Notes                                                                 |
|---|---|---|
| OKD             | 4.20.0-okd-scos.17 | Kube API ≈ upstream **1.33** (mapping: OKD `4.N` → Kube `1.(N+13)`, so 4.21→1.34, 4.22→1.35). SCOS 10 / kernel 6.12.0-142.el10 |
| Helm            | v3             | Helm v2 syntax is invalid; no Tiller                                  |
| ArgoCD          | v3.1.11+cc053b2     | Server-side apply + sync-wave annotations used throughout             |
| OLM             | OKD-bundled    | `okderators` + `community-operators` CatalogSources                   |
| cert-manager    | v1.18.2     | Installed via OLM from `okderators`                                   |
| oc / kubectl    | matching 4.20  | Prefer `oc` for OpenShift-only kinds (Route, SCC, ImageStream)        |
| kubeconform     | latest         | Use with OpenShift CRD schema location (see Validation)               |
| Renovate        | GitHub App     | Handles image tag bumps; PRs labeled `dependencies`                   |

## Repository layout

```
.
├── bootstrap/
│   ├── phase0/              # One-time manual bootstrap: CatalogSource, GitOps operator, RBAC, root App
│   └── root-app/            # Helm chart that generates all child Applications
│       ├── values.yaml      # ← central registry of managed apps (enable/disable + sync wave)
│       └── templates/applications.yaml
├── components/              # Everything ArgoCD deploys; one Helm chart per component
│   ├── cluster-topology/    # Wave 0 — node labels, failure domains
│   ├── operators/           # Wave 1 — OLM Subscriptions (cert-manager, NMState)
│   ├── cluster-config/      # Wave 2 — ClusterIssuer, Certificates, NNCPs
│   └── storage/             # Wave 3+ — storage + TLS consumers
├── ansible/                 # Non-cluster home infra, NOT ArgoCD-managed (see below)
│   └── technitium/          # Technitium DNS Server (replaces pi-hole; RPi 3B+ on the LAN)
├── *-values.yaml            # Helm values for tools installed OUTSIDE the root app
│                            # (Cilium, Istio, Prometheus, ArgoCD itself, Kiali)
├── blog/                    # Working notes / draft posts — see "Blog notes" rule below
├── bugs/                    # Drafted upstream-issue bodies (filing-ready)
├── tests/                   # Manual-apply test artifacts not yet promoted to a chart
├── data/                    # Captured benchmark / SMART / log artifacts referenced from blog drafts
└── CLAUDE.md
```

### Non-cluster infrastructure — when to use `ansible/` vs `components/`

- `components/` and `bootstrap/` are for things ArgoCD applies to the OKD cluster. Single source of truth, automated sync, selfHeal, etc.
- `ansible/` is for things that live **outside the cluster** but still need version-controlled, idempotent configuration — e.g. the home DNS server (`technitium/dns-master` on an RPi 3B+ on the LAN).
- **Why split this way:** DNS (and similar foundational LAN services) must not be circularly dependent on the OKD cluster being up. If the cluster's storage hangs (2026-05-12 incident), the dashboards go dark — losing DNS at the same time would compound the outage.
- Each `ansible/<topic>/` directory is a self-contained Ansible playbook: `inventory.yml`, `playbook.yml`, role dirs, and a `README.md` with the bootstrap walkthrough + day-2 flow. Apply manually from a workstation; do not wire into ArgoCD.
- **All-builtin invariant**: `ansible/` playbooks use `ansible.builtin.*` modules only — no `community.general` / `ansible.posix` / etc. Keeps the operator workstation setup to a single `ansible-core` install.
- Secrets live in `vars/vault.yml` (Ansible Vault encrypted, gitignored). A `vars/vault.yml.example` template is committed alongside.
- **Vault password is interactive each run** (`--ask-vault-pass`). No `--vault-password-file`, no env-var, no on-disk password file — deliberate. Practical consequence for Claude: **I can't run vault-requiring playbooks** (`playbook.yml`, `upgrade.yml`) on the user's behalf via Bash, because Bash tool calls aren't interactive. The operator runs those manually. Claude *can* run `base-only.yml` (validates SSH + sudo + base role end-to-end without the vault) and `--syntax-check` on anything; that's the scoped subset.
- **Code-only changes — never propose web UI / manual fixes for `ansible/`-managed boxes.** If a change needs to happen on `dns-master` (or any future Ansible-managed host), it goes through the Ansible role + a playbook re-run. Don't suggest "fix it in the Technitium web UI now" as a quick path — even when it's faster — because the next playbook run won't preserve the manual change unless it's also in the role. If the playbook isn't doing what's expected, debug the role; don't bypass it. Same principle as ArgoCD for the cluster: code is the source of truth.

## Architecture

### App-of-apps + sync waves

The root app at `bootstrap/root-app/` reads `values.yaml` and renders one `Application` per enabled entry. Sync waves enforce ordering:

- **Wave 0** — Cluster topology (node labels, failure domains)
- **Wave 1** — Operators via OLM (Subscription only)
- **Wave 2** — Cluster config that depends on operator CRDs (ClusterIssuer, Certificates, NNCPs)
- **Wave 3** — TLS consumers (IngressController default cert, APIServer serving cert) + storage

For operators bringing CRDs, use **intra-chart** sync-wave annotations: `Subscription` at wave 1, CR (`Certificate`, `NodeNetworkConfigurationPolicy`, …) at wave 5. This avoids CRD-not-yet-installed races on first sync.

### Sync policy (default for all managed Applications)

`automated` (prune + selfHeal), `ServerSideApply=true`, `SkipDryRunOnMissingResource=true`, `CreateNamespace=true`, retry 5× with exponential backoff (5s → 3m).

### OLM catalogs

- `okderators` (`quay.io/okderators/catalog-index:4.20`) — OKD community operators. Use for **cert-manager**.
- `community-operators` — upstream OperatorHub.io. Use for **NMState** (the okderators build has an ImageStream bug).

### Operator patterns

- Every operator component = `Namespace + OperatorGroup + Subscription` (+ CR in a later sync wave if needed).
- **Cluster-scoped** operators (cert-manager): `OperatorGroup` with `spec: {}`.
- **Namespace-scoped** operators (NMState): `OperatorGroup` with `targetNamespaces`.

### TLS / cert-manager

- Let's Encrypt **production**, DNS-01 via **Cloudflare**.
- The DNS-01 resolver uses public nameservers (`1.1.1.1`, `8.8.8.8`) — cluster DNS can't resolve external domains, and without this override the challenge fails.
- Wildcard cert `*.apps.okd.sudops.pl` → `openshift-ingress`.
- API cert `api.okd.sudops.pl` → `openshift-config`.
- Cloudflare API token is provisioned via the SealedSecret in `components/cluster-config/cert-manager-config/templates/sealed-cloudflare-api-token.yaml`. Rotation = re-`kubeseal` + commit (one-liner in that chart's `values.yaml`).
- **sealed-secrets controller runs `--key-renew-period=720h` (auto-rotation) — NEVER set it to `0`.** `0` disables rotation, which silently let the single sealing key's cert **expire 2026-05-28** with no replacement → `kubeseal` failed `expired certificate`, blocking ALL new sealing cluster-wide (existing SealedSecrets kept decrypting fine — expiry only breaks *sealing*, not decryption). Fixed 2026-06-27 (`720h` → controller minted a fresh 10-year key, old key retained for decryption). The controller's **public sealing cert is committed at `components/operators/sealed-secrets/sealed-secrets-pub.pem`** for offline `kubeseal --cert` (public key = seal-only, safe to commit; refresh after a rotation via `kubeseal --fetch-cert`).

## Storage (Rook-Ceph)

The cluster's storage is **Rook v1.19.5 managing Ceph Squid 19.2.4**. (Ceph was bumped 19.2.3→19.2.4 via Renovate 2026-06-12 and rolled the 3 OSDs cleanly — kept. Rook was bumped 1.19.6→**1.20.0** by Renovate the same day and it **broke CSI** — the v1.20 operator changed CSI ServiceAccount naming, leaving `ceph-csi-*-sa` missing so RBD+CephFS CSI couldn't create new pods; reverted to a coherent **v1.19.5** in `49406f5`. See "Upgrading Rook/Ceph" below + `blog/blog-rook-ceph-draft.md`.) Two Rook charts: **operator** = `components/operators/rook-ceph/` (deploys the Rook operator), **cluster** = the wrapper `components/storage/rook-ceph-cluster/` (owns the `CephCluster` CR + block pools + StorageClasses + CephFS, rendered from `cephClusterSpec`/`cephFileSystems`/`cephBlockPools` in its `values.yaml`). **To change OSD devices, pools, or CRUSH, edit `components/storage/rook-ceph-cluster/values.yaml`.** OSD device list = `cephClusterSpec.storage.nodes[].devices` — uses **`/dev/disk/by-path/pci-…-ata-N`** (the SATA bay PORT, slot-stable so a drive swap reuses the OSD; NVMe = `/dev/nvme0n1`); by-id WWN stays the ref for drive-SPECIFIC ops (wipe/SMART/gate). HDD tier is **CephFS EC 2+1 (`cephfs-bulk-hdd`, min_size 2)** + the RGW data pool on HDD. The CephFS was created by a **one-time manual `ceph fs new cephfs cephfs-metadata cephfs-bulk-hdd --force`** — Rook won't pass `--force`, which Ceph requires for an EC *default* data pool, so **any future CephFS teardown/recreate needs that manual step** (Rook then adopts + manages the MDS). The `cephfs-hdd` SC carries `Replace=true,Force=true` (SC params + `reclaimPolicy` are immutable; `Replace=true` ALONE is insufficient — it runs `kubectl replace`, still an update → still forbidden on immutable fields; `Force=true` adds `--force` = delete+recreate, confirmed 2026-06-15). Full Phase-1-4 saga + the Rook gotchas (deviceClass-on-existing-pool, can't-transition-default-pool, EC-default-needs-force) in `blog/blog-hdd-tier-rollout-draft.md`.

### Upgrading Rook / Ceph — version coherence (READ before approving any Rook/Ceph bump)

The 2026-06-12 CSI outage was a **version-coherence** failure. The mechanics that make this fragile, and the rules:

- **`charts/` + `Chart.lock` are gitignored** in both Rook charts → ArgoCD does NOT use a vendored/pinned subchart; it runs `helm dependency update` and **pulls whatever version `Chart.yaml` names, fresh, at sync time.** So a one-line `Chart.yaml` version bump = an immediate live chart change, no review of the rendered delta. (Local `helm template` uses the local `charts/` tgz, which can be a DIFFERENT stale version → local render ≠ what ArgoCD deploys. Don't trust local render alone for version changes.)
- **Not every version string has a published Helm chart.** Renovate bumped `Chart.yaml` to `v1.19.6`, which has NO chart on `charts.rook.io` → `helm dependency update` fails → ArgoCD kept the prior render. Then `v1.20.0` (which DOES have a chart) deployed for real. **Always `helm dependency update` locally first to confirm the target version's chart actually exists.**
- **Operator and cluster charts must be the SAME Rook version, bumped together.** They're separate charts (operator lifecycle vs cluster lifecycle — can't merge) but a split version = collision. Pin both `components/operators/rook-ceph/Chart.yaml` and `components/storage/rook-ceph-cluster/Chart.yaml` to the same `vX.Y.Z`.
- **Rook ↔ Ceph compatibility is a hard gate.** A given Rook minor supports a bounded Ceph range (Rook 1.19 → Ceph Squid 19.2.x; Ceph 20/Tentacle needs a newer Rook). `allowUnsupported: false` makes the CephCluster REFUSE an unsupported Ceph → never bump Ceph major ahead of a Rook that supports it.
- **Order:** bump Rook (operator first, then cluster) to a version that supports the target Ceph → verify CSI + health → then bump Ceph (a degraded-window OSD roll on the no-drain topology).

**Procedure for an intentional Rook/Ceph upgrade:**
1. Confirm the target Rook version supports the target Ceph version (Rook release notes' Ceph support matrix). Confirm both have published Helm charts (`helm dependency update` succeeds for the new version).
2. Bump BOTH `Chart.yaml` deps to the same Rook version; `helm dependency update` both; commit `Chart.lock` too (stop gitignoring it — pins the version for review).
3. `helm template … | oc diff -n rook-ceph` the operator chart — **review the CSI SA / RBAC / DaemonSet delta** (this is exactly where the v1.20 break hid).
4. Sync the OPERATOR app first; verify operator image + `oc -n rook-ceph get sa | grep ceph-csi` (the 4 `ceph-csi-{rbd,cephfs}-{node,ctrl}plugin-sa` present) + CSI pods Running, before touching the cluster app or Ceph.
5. Only then bump the Ceph image (`cephClusterSpec`/`cephImage.tag`) — gate on Ceph HEALTH_OK, quiet IO, 2h+ headroom (rolls all 3 OSDs in series, degraded-window each).
6. **Renovate must NOT auto-bump Rook or Ceph.** These are manual, supervised, version-coherent, compatibility-checked bumps. **Enforced 2026-06-18 in `renovate.json`**: `packageRules` → `enabled: false` for `rook-ceph` + `rook-ceph-cluster` + `quay.io/ceph/ceph`, and both Rook `Chart.lock` files are now committed (un-gitignored) so the deployed subchart version is pinned + reviewable. (Was the third storage-version Renovate incident in one day before the lockdown.)

### Topology

- **6 OSDs total: 1 NVMe + 1 HDD per node** (`osd.0-2` NVMe, `osd.3-5` HDD — HDD tier added 2026-06-12 via `/dev/disk/by-path/pci-…-ata-N` SATA-bay refs in `cephClusterSpec.storage.nodes[].devices`). Failure domain is `host` (labels `fd-a/fd-b/fd-c`, one per node) — still one node per failure domain for *both* device classes, so the no-drain constraint below applies to NVMe and HDD OSDs alike.
- **No drain headroom.** Any rolling change to OSDs (rebuild, encrypt-at-rest, redeploy) goes through a degraded window — there is no fourth node to absorb the missing OSD. Plan accordingly: schedule during quiet IO, never run two OSD-impacting changes at once, never propose `oc cordon node{4,5,6}` without an explicit ask.
- **Mons:** 3-of-3, one per node. Same topology constraint applies.
- **Network:** Frontnet (VLAN 5) for clients; storage backnet (VLAN 10, 192.168.10.2-4) for OSD ↔ OSD replication. Multus migration in flight (2026-05-11): NADs + per-node macvlan host-shim (`ceph-shim`, IPs `.16/.17/.18`) shipped, pod range shifted to `192.168.10.128/25` with an explicit `/25 dev ceph-shim` route for the kernel-RBD-client hairpin fix. **CephCluster spec flip + mon/OSD roll still pending** (degraded-window event). Full design + ops history in `blog/blog-multus-ceph-migration-draft.md`. **Don't touch `enp1s0f0np0`, `ceph-shim`, or `192.168.10.0/24` routing without checking that draft first** — the routing setup is load-bearing: `/24 master metric 100`, `/24 shim metric 410`, `/25 dev shim static`. Reordering or simplifying breaks pod↔host reachability.

### Hardware: 3× Samsung PM9A1 512GB

- Migration from PNY CS1030 → PM9A1 completed 2026-05-07. Per-OSD `kv_commit_lat` dropped from ~95 ms (worn PNY lifetime) to ~3 ms (PM9A1); **average stays ~3.7 ms** (confirmed 2026-06-15). The worn-drive pathology is gone — **watch the *average* `kv_commit_lat`, not the alert latch.** **`BLUESTORE_SLOW_OP_ALERT` does still appear** and is **benign**: it's hair-trigger (`bluestore_slow_ops_warn_threshold=1` / `lifetime=86400` / `log_op_age=5s` → a single op >5 s in 24 h latches it), and an occasional fsync/FUA stall on no-PLP consumer NVMe is expected hardware-class behaviour (2026-06-15: NVMe osd.0/osd.1, 355/874 slow KV commits out of ~1.72 M = 0.02–0.05 %, avg latency healthy). **Don't read "N OSDs slow" as "the HDDs" — check `ceph osd tree` for the device class first** (2026-06-15 I guessed HDD; it was NVMe osd.0/osd.1). Lever if it ever becomes pure noise: raise `bluestore_slow_ops_warn_threshold` (don't suppress — it's a real signal). Full chronology + bottleneck sweep in `blog/blog-rook-ceph-draft.md`.
- **`CephPGImbalance` (all 6 OSDs) is a known false positive on this 2-tier cluster — ignore it as a balance signal.** Rook's `prometheus-ceph-rules` averages `ceph_osd_numpg` across *all* OSDs with no device-class grouping; NVMe OSDs carry ~185 PGs, HDD OSDs ~68, so both tiers deviate ±46 % from the cross-class mean (126.5) and all six trip the 30 % threshold. **Within each class the distribution is perfect** (185/186/185 nvme, 68/67/68 hdd) and `ceph balancer status` reports `no_optimization_needed: true, "distribution is already perfect"`. Proper fix (device-class-aware expr) requires `monitoring.createPrometheusRules: false` + vendoring the full corrected rule set — deferred (cosmetic; README TODO). Firing since 2026-06-13 (HDD-tier rebalance settled).
- For future drive purchases at this cluster scale, stay on PM9A1-class consumer NVMe — full PLP enterprise (Micron 7450 PRO etc.) is not justified by the workload. The bottleneck post-swap is replication-amplification at `size=3`, not per-drive fsync latency.
- **BMH inventory is stale and cannot be refreshed on this cluster.** The OpenShift console's BareMetalHost "Disks" tab still shows the pre-swap PNY CS1030 drives because BMHs are in `state=unmanaged` with `externallyProvisioned=true` — Metal3 doesn't manage them (no BMC credentials configured), so it can't trigger re-inspection. The `inspect.metal3.io` annotation is a no-op in this state. The `smartctl-exporter` dashboard + the `smartctl_device_*` Prometheus metrics are the **live** source of truth for current hardware. Nothing in ArgoCD, Ceph, or operator reconciliation reads the BMH `.status.hardware.storage`, so the staleness is purely cosmetic.
- **On-node disk tooling — use the `smartctl-exporter` pod, not a pulled image.** `registry.access.redhat.com/rhel9/support-tools` does NOT pull on node4 (`ImagePullBackOff`, observed 2026-06-10). For on-node `smartctl` / SMART self-tests, `oc exec` into the existing `smartctl-exporter` DaemonSet pod (per node: it already has `smartctl` + host device access, zero pull). That image lacks `badblocks` — destructive write-tests need a USB3 dock off-node or a pre-mirrored tool image. **Always reference disks by `/dev/disk/by-id/wwn-*`, never `/dev/sdX`**: HDD bay installs power-cycle the node and `/dev/sd*` re-enumerates (2026-06-10: the new HDD took `sda` on node4 but `sdb` on node5/node6; the boot/etcd SSD is also SATA, so a wrong `/dev/sdX` is one typo from the boot disk).
- **SATA-SSD wipe/erase — the `ROTA=1` boot-disk guard does NOT apply; use an allowlist gate.** The HDD burn-in gate (`assert_burnin_target`) leans on `ROTA=1` to separate the 4TB HDD target from the boot/etcd disk (a SATA SSD, `ROTA=0`). That discriminator **vanishes when the target is itself a SATA SSD** — boot/etcd disk and burn-in SSD are the same device class. Any SATA-SSD *write* (secure-erase for the boot-spare/backup-drive prep, 2026-06-11 batch 3; future OSD-journal SSDs) must go through **`assert_ssd_burnin_target`** — a **positive WWN-allowlist** gate (fail-closed on empty allowlist; paste the seated SSD's WWN in first), keeping the boot/NVMe WWN denylist as backstop. Never the HDD gate, never a bare `/dev/sdX` — a wrong by-id on an SSD erase = boot/etcd disk wiped on a no-drain cluster. On-node wipe = **`blkdiscard -f` + `wipefs -a`, NOT `hdparm`** — `hdparm` is **not installed on SCOS** (confirmed 2026-06-11, `rc=127`; `wipefs`/`lsblk`/`blkdiscard` are present, `hdparm` isn't), so ATA secure-erase isn't an on-node option. `blkdiscard` (whole-device TRIM) is a clean-slate-for-reuse wipe; `DISC-ZERO=0` on these Intel DC drives means no read-zero guarantee (fine for reuse, not forensic — pull to a workstation w/ hdparm for that). Gate template + SSD flow (SMART wear triage → read pass → `blkdiscard`/`wipefs` → post-wipe confirm) in `blog/blog-hdd-tier-rollout-draft.md` (2026-06-11 Batch 3; **S4610 backup-target burn-in via USB enclosure done 2026-06-26**). USB-enclosure lessons from that run: the USB-SATA bridge needs **`smartctl -d sat` on every call** but passes TRIM + self-tests fine (use the drive-internal long self-test as the surface scan — no `dd`-over-USB needed); the `smartctl-exporter` pod has `blkdiscard`/`dd`/`blockdev`/`partprobe` but **NOT `wipefs`/`lsblk`/`mdadm`**, so clear the partition table by **`dd`-zeroing the first 10 MiB (MBR + GPT primary) + last 1 MiB (GPT backup) *after* `blkdiscard`** (after, because `DISC-ZERO=0` → TRIM gives no read-zero guarantee); and **run `blkdiscard` in the background — whole-device TRIM over a USB bridge exceeds a 2-min foreground exec and gets SIGTERM'd mid-wipe** (the front zeroing + table re-read still landed, but re-run in the background to complete the full-device TRIM). The wipe script bakes the gate's typed-serial check in programmatically (re-resolve by-id symlink + re-assert model/serial/WWN + denylist at execution time) since the pod has no interactive TTY. Drive roles: S3510 480GB → boot/etcd spare; S4610 960GB → Synology USB-box backup target (not Ceph WAL/DB).
- **Used-drive hot-swap → false CRITICAL etcd/CVO alerts (DDF firmware-RAID, 2026-06-10).** The used HUS726040 datacenter pulls carry DDF (firmware-RAID) superblocks; the host auto-assembles an md raid0 on insertion, and a *broken* array (after a pull) makes the kernel disk-stats read **hang kubelet cAdvisor for the 30s scrape timeout** → Prometheus can't scrape that node's host-metrics → ~31 **false** alerts incl. **critical** `etcdMembersDown` / `etcdInsufficientMembers` / `ClusterVersionOperatorDown` + 16× `TargetDown`. **These are scrape-inferred, not real — confirm with `oc -n openshift-etcd exec <etcd-pod> -c etcdctl -- etcdctl endpoint health --cluster` (all members up) before touching etcd.** Fix per node, guarded to the HUS726040 rotational disk only: `mdadm --stop` the stale `/dev/md*` arrays, then `wipefs -a` the DDF; a node whose cAdvisor has been wedged for hours additionally needs `systemctl restart kubelet`. Prevention: wipe DDF **first** on every used-drive insertion, store shelf spares **raw**. Full diagnosis: `blog/blog-hdd-tier-rollout-draft.md` (2026-06-10 DDF section). **A node's `ovnkube-node` with broken pod→remote-host egress throws the *same* false etcd-critical symptom — rule out both** (see "restart ALL 3 ovnkube-node" in the network pre-flight section).

### Pools and pg_num

- Primary pool: `nvme-replicated` (`size=3`, `min_size=2`, CRUSH rule on `device_class=nvme`, `bulk: true`). Backs the only block StorageClass today (`ceph-nvme-block`, RBD provisioner).
- **Target `pg_num` is 128** for `nvme-replicated`: 100 PGs/OSD × 3 OSDs / replication 3 = 100 → next pow2 = 128. Use `pg_num_min: 128` in the BlockPool to enforce — the autoscaler is **not** applying the `bulk` hint correctly (`ceph osd pool autoscale-status` returns `[]`; root cause likely a Squid 19.2.x quirk, tracked as an open TODO). Same quirk hit the RGW data pool on 2026-05-10; same fix shape.
- When proposing pool changes: floor with `pg_num_min`, don't disable autoscale. Don't suggest manual `pg_num` bumps unless paired with the autoscaler diagnosis.
- **`pg_num_min` chicken-and-egg:** Ceph rejects `pg_num_min > current pg_num` with `EINVAL`. Pure-GitOps `pg_num_min` enforcement requires a **one-time toolbox bump** of `pg_num` to bootstrap each new pool past 1 (`ceph osd pool set <pool> pg_num <floor>; ceph osd pool set <pool> pgp_num <floor>`); the chart's `pg_num_min` then enforces the floor going forward. Confirmed twice (`nvme-replicated` originally, RGW data pool 2026-05-10). Capture the exact toolbox commands in the topical blog draft.

### Object storage (RGW)

- **`CephObjectStore` `ceph-objectstore` shipped 2026-05-01** — chart at `components/storage/ceph-object-store/`, single RGW gateway (`gateway.instances: 1`), HTTP-only on port 80; TLS terminated at the OpenShift Route `s3.apps.okd.sudops.pl`. **In-cluster S3 clients should use the in-cluster Service `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80`** — bypasses Route + edge TLS, faster + more reliable.
- **Pool tiers:** `metadataPool.deviceClass: nvme` permanently; `dataPool.deviceClass` **FLIPPED `nvme`→`hdd` 2026-06-12 (Phase 3, HDD tier live)**. The chart change alone **no-ops at the Ceph layer** — Rook does NOT propagate a `deviceClass` change to an *existing* pool (`bugs/upstream-rook-deviceclass-change-not-propagated-existing-pool.md`); it needed a **manual CRUSH-rule change** (`ceph osd crush rule create-replicated rgw-buckets-data-hdd default host hdd` + `ceph osd pool set …buckets.data crush_rule …`). Rebalance was then automatic; RGW endpoint + bucket names + client config unchanged.
- **`pg_num_min: "32"` floored on the data pool** (commit `32b2e64`); metadata pool stays at the chart-default 8 PGs (it's tiny and not on the hot path).
- **Active consumers:** Loki (33+ GiB / 53k+ chunks in `ceph-objectstore.rgw.buckets.data` as of 2026-05-10). OADP queued. (**CNPG backups did NOT land on RGW** — RGW is on-cluster, not a valid *offsite* target. They went OFFSITE to **Cloudflare R2** via the **barman-cloud plugin** 2026-06-27: `components/operators/cnpg-barman-plugin/` + per-cluster `ObjectStore`/`plugins:` for media-postgres + immich-postgres. Gotchas — ObjectStore `compression` must be `gzip` (CRD rejects `zstd`); `serverName` goes in `Cluster.spec.plugins[].parameters`, not the ObjectStore; the boto3≥1.36 checksum env is required; the sidecar is a NATIVE sidecar (initContainer, invisible in `.spec.containers`) with per-command creds, so **verify via the bucket + sidecar logs, NOT CNPG status conditions**. Full saga: `blog/blog-cnpg-draft.md`.) **WAL archiving depends on pod→external egress** — a node outage re-trips the OVN `ovnkube-node` egress break (see network pre-flight) and **silently kills R2 archiving on BOTH clusters** with no alert; a long-enough outage then fills the WAL PVC → CNPG **`Not enough disk space`** safe-mode deadlock (**CNPG will NOT auto-expand from that state** — its reconcile bails on the unreachable `/pg/status` before the resize step, so bumping `Cluster.spec.storage.size` alone no-ops; PVCs stay `requested=<old>`). **Recovery order:** restart all 3 `ovnkube-node` → manually `oc patch` each instance PVC `spec.resources.requests.storage` larger (RBD `allowVolumeExpansion=true`; matches the committed CR size = no drift) → delete the crashlooping pods to remount the grown fs + clear the kubelet backoff → Postgres starts, flushes the WAL backlog. **`media-postgres` PVC grown 10Gi→20Gi permanently 2026-07-02** after exactly this (2-day node4 power outage); full chronology in `blog/blog-cnpg-draft.md` 2026-07-02.
- **Bucket-creds plumbing precedent:** Loki's `logging-stack` chart uses an `ObjectBucketClaim` + secret-translator pattern to land RGW credentials in a SealedSecret-shaped Secret. Reuse that pattern for OADP / CNPG / future S3 consumers — don't ship `CephObjectStoreUser` + manual SealedSecret.
- **Toolbox gotcha:** `radosgw-admin user list` / `bucket list` from the toolbox default to the orphan `default` zone (a leftover from RGW first-bring-up; cosmetic-cleanup TODO). Real data lives in the `ceph-objectstore` zone — pass `--rgw-realm=ceph-objectstore --rgw-zonegroup=ceph-objectstore --rgw-zone=ceph-objectstore` to inspect it, or just look at `ceph-objectstore.rgw.*` pools in `ceph df`.

### CephFS — shipped (HDD bulk RWX tier, Phase 4 2026-06-12)

- **Single `CephFilesystem` `cephfs`**: metadata pool replicated on NVMe + **one bulk data pool `cephfs-bulk-hdd` = erasure-coded 2+1** (`dataChunks: 2, codingChunks: 1`, deviceClass hdd, `pg_num_min 32`, `min_size 2`, `ec_overwrites`). **ONE StorageClass `cephfs-hdd`** → the EC pool. Shipped *inside* the `rook-ceph-cluster` wrapper chart (`cephFileSystems` + `cephfsStorageClasses` in `values.yaml` + `templates/cephfs-storageclasses.yaml`), not a separate chart.
- **First/only consumer (2026-06-15): the media stack's shared `/data`** (`media/media-data-pvc`, RWX, **4 Ti** quota — raised 2→3→4 Ti over 06-15…06-19, each gated on `ceph df`) — moved off Synology NFS (a move *back* to NFS is the considered next step, deferred — likely with a future Synology→TrueNAS migration; see README). So the `cephfs-hdd` tier is now **load-bearing for media**; a CephFS teardown/recreate (which needs the manual `ceph fs new … --force`) takes the media stack's `/data` with it. The EC pool **shares the 3 HDD OSDs with the replicated RGW data pool** (Loki + backups), so CephFS-used (×1.5 raw) + RGW-used (×3 raw) must stay under ~10.9 TiB HDD raw with nearfull headroom — don't raise the media quota without checking `ceph df`. PVC `storageClassName` is immutable: a backend re-flip needs a one-time manual PVC delete (NFS PV was Retain), **not** `Replace=true` on the data PVC (footgun: would delete+recreate the PVC on any future diff).
- **`cephfs-hdd` is `reclaimPolicy: Retain`** (changed 2026-06-15 — was Delete by default, which would destroy the CephFS subvolume on PVC deletion; the old NFS backing was Retain, so this matches). Implications: (a) deleting a `cephfs-hdd` PVC leaves a **Released PV + orphan CephFS subvolume to purge manually** (`oc delete pv` + clean the subvolume) — the cost of the safety net; (b) `reclaimPolicy` is an immutable SC field, so the SC template carries `Replace=true,Force=true` (Replace alone runs `kubectl replace` which still fails on immutable fields; Force adds `--force` = delete+recreate); (c) the SC change only affects **newly-provisioned** PVs — existing PVs keep their provisioned policy, so the live `media-data-pvc` PV was patched to Retain separately. The `media-data-pvc` also carries `argocd.argoproj.io/sync-options: Prune=false` so a stray manifest change can't prune the PVC object out from under the running apps.
- **The NVMe low-latency RWX tier was intentionally dropped** (operator's call). Add it back later *only* if a hot/small-IO RWX need appears — and as a **replicated** pool (EC is wrong for hot/small-IO). The old "two-tier nvme+hdd, two StorageClasses" plan is **not** what was built.
- **EC-as-default-data-pool needs `ceph fs new … --force`, which Rook won't pass** — so the FS was created by a one-time manual `ceph fs new cephfs cephfs-metadata cephfs-bulk-hdd --force` (Rook then adopts + manages the MDS: 1 active + 1 standby on different hosts). **Any future CephFS teardown/recreate needs that manual `--force` step.** Rook also can't transition a live FS's default pool / replicated→EC in place (teardown+recreate required).
- The `cephfs-hdd` SC carries `Replace=true,Force=true` (SC params + `reclaimPolicy` are immutable; `Replace=true` ALONE is insufficient — it runs `kubectl replace`, still an update → still forbidden on immutable fields; `Force=true` adds `--force` = delete+recreate, confirmed 2026-06-15). The `csi` CephFilesystemSubVolumeGroup must exist or provisioning fails (`subvolume group 'csi' does not exist`) — a CephFilesystem stuck in CR `phase: Failure` (e.g. a wedged detect-version reconcile) blocks that even when `ceph fs status` shows the FS active; an operator restart (safe at the same version) clears it.
- Full Phase 1-5 saga + every gotcha: `blog/blog-hdd-tier-rollout-draft.md`.

### RBD CSI quirks

- The CSI driver does **deferred delete**: PVC removal calls `rbd trash mv`, not `rbd rm`. Trashed images keep consuming pool space until purged. Manual purge in 04/2026 reclaimed ~600 GiB.
- Need a periodic `rbd trash purge schedule` (use Ceph's built-in scheduler, not a CronJob — it lives in mgr config).
- **Freed blocks aren't returned to the pool without TRIM/discard** (separate from trash). `ceph-nvme-block` has no `discard` mountOption, so a filesystem deleting data leaves the RBD blocks allocated. 2026-06-18: `rbd du` showed ~245 GiB of stale Loki-WAL allocation (106+140 GiB) vs ~0.5 GiB FS-used — most of `nvme-replicated`'s 82% fill. Reclaim is **`fstrim`**, NOT `rbd sparsify` (freed blocks aren't zeroed). Shipped + enabled `components/cluster-config/node-fstrim/` — a privileged hostPID DaemonSet running `nsenter -t1 -m -- fstrim -av` weekly per node (first pass also does the one-off reclaim). In-cluster `oc debug node … fstrim` is guardrail-denied (host node-shell), so a manual one-off is operator-run. Full diagnosis: `blog/blog-rook-ceph-draft.md` 2026-06-18.
- Occasionally an image refuses removal with `image has watchers` — usually a stuck CSI nodeplugin attachment; investigate the node, don't force-delete the image.
- **`operation already exists` mount lock can outlive plugin restarts.** When `NodeStageVolume` hangs (e.g., kRBD waiting on an unreachable OSD), the rbd-plugin's in-memory operation tracker locks the volume ID. Every retry returns `rpc error: code = Aborted desc = an operation with the given Volume ID ... already exists`. Restarting the rbd-nodeplugin pod usually clears the lock — but if the underlying cause (network unreachable, msgr2 silent drop) persists, the new plugin will hit the same hang on the first retry. **Don't chase the lock; chase what's keeping the first call stuck.** Check `/sys/bus/rbd/devices/` on the host via `oc debug node/<name>` — empty = the hang is in plugin userspace, not kernel.
- **Stuck VolumeAttachments need finalizer force-clear.** When CSI mount fails repeatedly, VAs accumulate with the `external-attacher/rook-ceph-rbd-csi-ceph-com` finalizer and `attached: true` even though no mount succeeded. If the PV is also gone (e.g., test PVC deleted), normal `oc delete` hangs forever. Unstick: `oc patch volumeattachment <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`. Same pattern can affect `rook-ceph-mon-endpoints` ConfigMap / `rook-ceph-mon` Secret after teardown — same force-clear works.
- **Orphan Released PVs block the csi-provisioner cluster-wide.** When CSI's `DeleteVolume` for a PV fails (e.g., earlier mount regression left an unfinishable rbd image), the PV stays `Released` and the provisioner re-attempts deletion forever. CSI plugins serialize operations cluster-wide, so a stuck DeleteVolume blocks every new CreateVolume too — symptom looks identical to the "operation already exists" lock from the per-volume tracker, but the cause is a different volume's stuck deletion. **Before applying any test PVC, check for orphan Released PVs**: `oc get pv | grep Released`. Clear them with `oc patch pv <name> -p '{"metadata":{"finalizers":[]}}' --type=merge && oc delete pv <name>`. Also clear any stale VolumeAttachments to the now-gone PV. The "stuck VA + stuck PV" duo can survive plugin restarts, controlplugin restarts, and operator restarts — must be manually cleared.
- **Fresh-bootstrap workaround: `client.csi-rbd-provisioner.<gen>` is missing its `osd` cap** (Rook 1.19.5 bug). The provisioner user gets `mgr "allow rw"` + `mon "profile rbd, ..."` but no `osd` cap → every `CreateVolume` hangs on the first RADOS op → "operation already exists" lock storm. **Auto-fixed on each bootstrap by** `components/storage/rook-ceph-cluster/templates/csi-rbd-provisioner-caps-fix.yaml`. Bug filed at `bugs/upstream-rook-csi-rbd-provisioner-missing-osd-cap.md`; full chronology + manual recovery steps in `blog/blog-rook-ceph-draft.md`. If a key rotation creates `csi-rbd-provisioner.2`/`.3`, the same `ceph auth caps … osd "profile rbd"` needs to be re-run against the new generation suffix.

### Network provider — `host` (with required `addressRanges`)

The `CephCluster.spec.network.provider` is `host`. Two ways this rule has been validated:

**1. In-place `host → multus` migration is forbidden.** A 2026-05-12 attempt to follow Rook's documented `host → "" → multus` two-step deadlocks on this 3-OSD no-drain topology. During the intermediate `provider: ""` state, the first-rolled OSD goes onto the pod network while the other two stay on host; **PG peering hangs indefinitely** under that mixed-network shape (msgr2 between asymmetric-address peers stalls); Rook's `ceph osd ok-to-stop` then refuses to roll any further OSD because peering is hung, including the one that needs to roll back. Chicken-and-egg with no Rook-native escape. Bonus snag: the operator does NOT clear `public_network` from the Ceph config DB across provider changes — the first OSD on the new shape crashloops because it can't find an interface matching the stale CIDR.

**2. Multus fresh-rebuild on a clean cluster (2026-05-14) also failed.** Skipped the in-place migration entirely; tore down and rebuilt on `provider: multus` from the first daemon. Initial measurements were promising (1.6 GB/s 1M seqread vs. ~118 MB/s baseline), but the moment we tried to refine the design (Phase 6.5 — split the two NADs onto disjoint /26 IPAM ranges + pin explicit public/cluster_network CIDRs), kRBD mount silently broke: the host-side `ceph-shim` macvlan IP (`.16`) ended up outside the narrowed public `/26`, so msgr2 from the host stack hung. **The regression survived a clean chart revert** — CSI plugin restarts, ctrlplugin restarts, operator restart, VA finalizer force-clears, none of it cleared the stuck `NodeStageVolume` goroutine in the rbd-plugin. Recovery required full teardown.

**Rule for re-attempting multus:** if a future session wants multus, **mandatory pre-flight is `kubectl-rook-ceph multus validation run`**. OpenShift-compatible RBAC ships in upstream Rook at `deploy/examples/multus-validation-test-openshift.yaml` (grants `hostnetwork-v2` SCC to a dedicated SA the tool uses). Skipping this step burned a full session day. The validation tool exists exactly to catch the host↔pod reachability + source-IP issues that bit us in Phase 6.5. Do not propose multus changes without committing to running the tool first.

**Critical for `provider: host` on this cluster: `addressRanges` is required.** Without it, Rook uses each node's K8s-registered IP as the mon endpoint. On nodes with both a frontnet (1G, kubelet-registered) and backnet (10G, storage-dedicated), that means **mons + OSDs bind to the 1G frontnet IP** by default — which caps Ceph throughput at ~118 MB/s. This was the original source of the "host caps at 1G" diagnosis. The fix is not multus; it's:

```yaml
network:
  provider: host
  addressRanges:
    public:
      - "192.168.10.0/24"
    cluster:
      - "192.168.10.0/24"
```

`addressRanges` tells Rook to set Ceph `public_network`/`cluster_network` to the backnet CIDR. Daemons then bind to whichever interface has an IP in that subnet (the 10G `enp1s0f0np0`). The host still has its kubelet-registered frontnet IP for K8s control-plane traffic; only Ceph daemon msgr2 traffic moves to the backnet.

If a future change to `addressRanges` is needed, daemons need a rollout restart (`oc rollout restart deploy -l app=rook-ceph-{mon,mgr,osd,rgw} -n rook-ceph`) — Rook applies the cephConfig keys to the Ceph config DB but does NOT auto-roll daemons on a network-only change. Also clear stale config DB entries first: `ceph config rm global public_network ; ceph config rm global cluster_network` from the toolbox.

**Scheduling implication of host network: RGW must avoid router-co-located nodes.** With `network.provider: host`, every Ceph daemon binds the node's host ports. RGW listens on `:80` (`gateway.port: 80`). The cluster's edge `openshift-ingress/router-default` IngressController also runs hostNetwork on `:80/:443`, and the default HA mode places 2 router replicas on a 3-node bare-metal cluster — meaning 2 of 3 nodes have host port 80 occupied at all times. RGW therefore has exactly one collision-free node available. 2026-05-13 incident: a Multus rollback rescheduled RGW onto a router-co-located node, RGW crashlooped silently for ~21h with `EADDRINUSE` (exit 98), and Loki's S3 path was non-functional throughout. The `components/storage/ceph-object-store/` chart carries a `required` podAntiAffinity selecting on `ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default` in `openshift-ingress` namespace; **don't remove or downgrade to `preferred`** — co-residence is functionally broken and Pending+observable is the right alarm shape. Any future RGW-class daemon (multi-instance RGW, NFS-ganesha, an NVMe-of gateway) binding host ports needs the same anti-affinity treatment.

### Clean teardown procedure — "fresh install" means **fresh**

`cleanupPolicy.confirmation: "yes-really-destroy-data"` + disabling the app zaps OSD disks via Rook's cleanup-jobs, but leaves a long tail of namespace-level state that the next fresh bootstrap inherits and gets confused by. **Each item below bit us individually on 2026-05-14 — clean ALL of them as part of every teardown, not after symptoms appear.**

After the cleanup-jobs complete (verify with `oc -n rook-ceph get jobs | grep cluster-cleanup-job` — all `Complete`), run the full sweep:

```bash
# 1. Rook mon-tracking state (else next bootstrap hangs at "detecting the ceph image version"):
oc -n rook-ceph delete cm rook-ceph-mon-endpoints rook-ceph-pdbstatemap --ignore-not-found
oc -n rook-ceph delete secret rook-ceph-mon --ignore-not-found
oc -n rook-ceph patch cm rook-ceph-mon-endpoints -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
oc -n rook-ceph patch secret rook-ceph-mon -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null

# 2. Bootstrap Jobs from prior cluster (immutable; ArgoCD can't re-apply, blocks sync).
# Every bootstrap Job in components/storage/rook-ceph-cluster/templates/*.yaml is fair game.
# Current list as of 2026-05-15: rbd-trash-purge-schedule-bootstrap, csi-rbd-provisioner-caps-fix-bootstrap.
oc -n rook-ceph delete job rbd-trash-purge-schedule-bootstrap --ignore-not-found
oc -n rook-ceph delete job csi-rbd-provisioner-caps-fix-bootstrap --ignore-not-found
oc -n rook-ceph delete jobs -l rook-ceph-cleanup --ignore-not-found

# 2b. Stuck Ceph CR finalizers — Rook can't reconcile its own delete once the CR is in Deleting:
oc -n rook-ceph patch cephcluster rook-ceph -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
oc -n rook-ceph patch cephobjectstore ceph-objectstore -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
for bp in $(oc -n rook-ceph get cephblockpool -o name 2>/dev/null); do
  oc -n rook-ceph patch $bp -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 2c. Stale cluster-scoped ObjectBuckets + their OBCs (else new OBC stays Pending with "bucketName has changed compared to ob"):
for ob in $(oc get objectbucket -o name 2>/dev/null); do
  oc patch $ob -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  oc delete $ob --ignore-not-found 2>/dev/null
done
# Plus each known OBC by name (Helm charts in this repo create: logging-stack/loki, oadp/oadp once shipped):
oc -n openshift-logging patch obc loki -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
oc -n openshift-logging delete obc loki --ignore-not-found 2>/dev/null

# 2d. Stale clientprofiles.csi.ceph.io (else rook-ceph namespace stuck Terminating):
for cp in $(oc -n rook-ceph get clientprofiles.csi.ceph.io -o name 2>/dev/null); do
  oc -n rook-ceph patch $cp -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 3. Orphan Released PVs (block csi-provisioner cluster-wide):
for PV in $(oc get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' | grep ceph-nvme); do
  oc patch pv $PV -p '{"metadata":{"finalizers":[]}}' --type=merge
  oc delete pv $PV --ignore-not-found
done

# 4. Orphan VolumeAttachments:
for VA in $(oc get volumeattachment -o name); do
  oc patch $VA -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 5. Test-namespace PVCs still around from prior runs:
oc -n default get pvc 2>/dev/null | awk 'NR>1 && $4=="ceph-nvme-block" {print $1}' | xargs -r -I {} oc -n default patch pvc {} -p '{"metadata":{"finalizers":[]}}' --type=merge

# 6. CSI plugin in-memory state — bounce all 6 plugin pods (operator recreates):
oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-nodeplugin --wait=false
oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-ctrlplugin --wait=false
oc -n rook-ceph delete pod -l app=rook-ceph.cephfs.csi.ceph.com-nodeplugin --wait=false
oc -n rook-ceph delete pod -l app=rook-ceph.cephfs.csi.ceph.com-ctrlplugin --wait=false

# 7. Bounce the rook-operator for a fully clean reconcile slate:
oc -n rook-ceph delete pod -l app=rook-ceph-operator
```

The SA dockercfg secrets (`builder-dockercfg-*`, `ceph-csi-*-dockercfg-*`, `rook-ceph-*-dockercfg-*`) are cosmetic OpenShift-managed artifacts; they get regenerated when the SAs are next used. Leave them alone.

**Symptom map — which leftover causes which symptom:**

| Symptom | Likely leftover |
|---|---|
| Bootstrap hangs at `"detecting the ceph image version"` | `rook-ceph-mon-endpoints` CM + `rook-ceph-mon` Secret |
| ArgoCD app stuck `OutOfSync`, `Job is invalid: spec.selector: Required value` | Any bootstrap Job from prior cluster — `rbd-trash-purge-schedule-bootstrap`, `csi-rbd-provisioner-caps-fix-bootstrap`, etc. (immutable; can't be `kubectl replace`'d) |
| Teardown stops with `CephObjectStore` / `CephBlockPool` / `CephCluster` stuck in `Deleting` for >5min | Rook finalizer can't reconcile (operator stopped watching) — force-clear `metadata.finalizers` to `[]` |
| ObjectBucketClaim (OBC) stays `Pending`, operator log says `"bucketName has changed compared to ob"` | Stale cluster-scoped `ObjectBucket` from prior cluster — delete it |
| `rook-ceph` namespace stuck `Terminating`, status says `clientprofiles.csi.ceph.io has 1 resource instances` | Stale `clientprofile.csi.ceph.io` finalizer — force-clear |
| csi-provisioner spins forever on volume IDs unrelated to current PVCs | Orphan Released PVs |
| New PVC stuck `Pending` even after provisioner restart | Combination of orphan PVs + stale VAs blocking the serialized provisioner |
| `NodeStageVolume` returns "operation already exists" immediately on first mount | Stale VA + plugin in-memory tracker on a volume that no longer exists |
| Every `CreateVolume` returns "operation already exists" on a freshly-bootstrapped cluster | `client.csi-rbd-provisioner.<gen>` missing `osd profile rbd` cap (Rook 1.19.5 bug — see RBD CSI quirks above; chart-shipped Job auto-fixes on next sync if it ran) |

If you're tearing down, run the full sweep. If you discover one of these symptoms during a botched bootstrap, the table above tells you which subset of the sweep to apply.

### `CephCluster` SSA gotcha — `managedFields: []` makes field removal sticky

The live `CephCluster/rook-ceph` resource has empty `metadata.managedFields` (it was created via non-SSA apply originally, never migrated). Server-side apply removes fields only for the manager that *owns* them — with no ownership tracked, fields rendered out of the Helm manifest **don't get removed from the live spec** on apply. ArgoCD's `selfHeal` may eventually clear them on a re-establish-ownership cycle, but timing is unpredictable (minutes, not seconds).

Practical implication: when a chart change *removes* a field from the rendered `CephCluster` spec, expect the live spec to keep the old value. `oc diff` will look empty even though the manifest no longer contains the field, which is confusing. The 2026-05-12 Multus attempt hit this with `addressRanges`.

If a future spec change needs guaranteed field removal: either re-establish SSA ownership first (`oc apply --server-side --force-conflicts -f -` on a hand-rendered manifest, once, to make ArgoCD the canonical owner) or do a direct `oc patch --type=json` `op: remove` (after confirming nothing else depends on the field). Plain Helm-template-removal alone is not reliable.

### When proposing storage changes

- Always state the impact on the degraded window first. "Rolling restart of OSDs" = degraded cluster, not a free operation.
- For pool/CRUSH changes: `helm template … | oc diff -f -` against the live `CephCluster` / `CephBlockPool` so the deltas are inspected before commit.
- The toolbox is `oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph …`. Read-only `ceph` commands are fine; Ceph-internal mutations (e.g. `ceph mgr fail`, `ceph orch ...`, `rbd trash purge schedule add`) are different from K8s mutations and may be appropriate — but flag them and confirm before running.
- **30-minute cap on storage-mode debugging.** If a `network.provider` change, `addressRanges` change, NAD/IPAM change, or other cluster-level network/topology mutation breaks CSI mounts and isn't recovered within ~30 min of focused debugging, **stop and teardown** instead of continuing to debug. The 2026-05-14 multus-rebuild round spent 4+ hours trying to recover a CSI mount regression that survived a clean code revert; teardown + rebuild took ~10 min. Teardown is cheap on a no-client-load cluster (Phase 7 not done yet) and the polluted state is harder to debug than a fresh bootstrap. If client workloads are active, the trade-off is different — but then you wouldn't be making a network-mode change in the first place.
- **`network.provider` or multus changes require running `kubectl-rook-ceph multus validation run` first.** OpenShift-compatible RBAC ships in upstream Rook at `deploy/examples/multus-validation-test-openshift.yaml`. No exceptions — skipping this step was the 2026-05-14 process failure that cost a session day.
- **Observability stack is on Ceph-RBD PVCs** (Prometheus TSDB, Grafana, Loki, ArgoCD repo cache). When Ceph I/O hangs, all dashboards go dark — confirmed by the 2026-05-12 incident. Don't rely on Grafana to debug a storage incident; use the toolbox + `oc -n rook-ceph logs/exec` directly. If observability is dark during an incident, that's a *symptom* of the storage problem, not a separate failure to chase.

### Storage actions are always blog-worthy

Storage is the most load-bearing, hardest-to-roll-back part of this cluster. **Every storage action must be captured in a blog draft — no judgement call, no "is this big enough to write up."** This is stricter than the general "Blog notes" rule below: storage doesn't get the "non-trivial" qualifier.

- **Scope:** any change to `components/storage/`, any `ceph` / `rbd` / `rados` command beyond pure read-only inspection, any pool/CRUSH/StorageClass/CephFilesystem edit, any OSD operation, any hardware swap, any CSI / SealedSecret change touching storage credentials.
- **Drafts:** prefer to extend the existing topical draft (`blog/blog-rook-ceph-draft.md`, `blog/blog-multus-ceph-migration-draft.md`) over creating a new one. Create a new draft only when the topic is genuinely new (e.g. CephFS rollout when it lands).
- **What to capture:** the exact `ceph -s` / `ceph osd pool ls detail` / `rbd trash ls` output that drove the decision, the exact mutation command, the post-state output, and the *why*. Storage debugging six months later relies on this — paraphrase doesn't survive.
- **No exceptions for "small" actions.** A `ceph mgr fail` to refresh orchestrator inventory is small but it's still a mutation on the storage layer; write it up. Future-you will thank current-you when an unrelated symptom turns out to be the same root cause.

## Validation workflow

Every change to a chart must pass **lint → template → schema-validate → diff** before commit. Don't skip steps.

```bash
# 1. Lint the chart
helm lint components/<category>/<name>/

# 2. Render templates (catches missing values, bad Go templating)
helm template <release> components/<category>/<name>/ \
  -n <target-ns> -f components/<category>/<name>/values.yaml

# 3. Schema-validate (including CRDs) against upstream + OpenShift schemas
helm template <release> components/<category>/<name>/ | \
  kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# 4. Read-only diff against the live cluster before committing
helm template ... | oc diff -f -
```

Render the root app itself to inspect generated `Application` resources:

```bash
helm template root-app bootstrap/root-app/ -f bootstrap/root-app/values.yaml
```

## Adding a new ArgoCD-managed component

1. Create the Helm chart at `components/<category>/<name>/` (`operators`, `cluster-config`, `storage`, `cluster-topology`).
2. Add an entry in `bootstrap/root-app/values.yaml` with `enabled: true` and the correct sync wave.
3. Render `bootstrap/root-app/` locally and confirm the generated `Application` looks right.
4. If it installs an operator with CRDs: `Subscription` at wave 1, CRs at wave 5 (intra-chart annotations).
5. Run the full validation workflow above.
6. Commit on `develop`, open PR into `master`.

## Debugging order of operations

When an Application is `OutOfSync`, `Degraded`, or just "stuck", check in this order — don't skip ahead:

1. `argocd app get <name>` — sync status, health, last operation error.
2. `oc get events -n <namespace> --sort-by=.lastTimestamp | tail -30` — admission/validation failures.
3. `oc describe <kind> <name> -n <ns>` — per-resource conditions.
4. For operator-managed resources: `oc get csv -n <operator-ns>` and `oc get subscription -n <operator-ns>` first — a stuck CSV blocks everything downstream.
5. For cert-manager: `oc describe certificate <name> -n <ns>` → `CertificateRequest` → `Order` → `Challenge`. DNS-01 failures are almost always Cloudflare token expired or wrong zone.

### Pre-flight checks for any CSI-mount-dependent work

Before applying a test PVC, re-running a failed test, or debugging "operation already exists" / mount-hang symptoms, run these checks first — they catch cluster-wide CSI poison that survives plugin restarts:

```bash
# 1. Orphan PVs (Released or stuck-Bound to a deleted namespace)
oc get pv | grep -E "Released|Failed"

# 2. Stuck VolumeAttachments (especially with attached=true for a PV that no longer exists)
oc get volumeattachment | awk '$5 == "true" {print}'

# 3. Stuck PVCs with finalizers that never clear
oc get pvc -A | grep -v "Bound\|NAME"

# 4. Stale CSI controlplugin retry loops (look for "operation already exists" on volume IDs that don't correspond to any current PVC)
oc -n rook-ceph logs -l app=rook-ceph.rbd.csi.ceph.com-ctrlplugin -c csi-provisioner --tail=20
```

If any are found, clear them BEFORE retrying the work:

```bash
# PVs (Released status, no claimant):
oc patch pv <name> -p '{"metadata":{"finalizers":[]}}' --type=merge && oc delete pv <name>
# VolumeAttachments (orphan / no underlying PV):
oc patch volumeattachment <name> -p '{"metadata":{"finalizers":[]}}' --type=merge
# PVCs:
oc -n <ns> patch pvc <name> -p '{"metadata":{"finalizers":[]}}' --type=merge
```

Why this matters: the csi-provisioner serializes operations cluster-wide. A stuck `DeleteVolume` for an orphan PV blocks every new `CreateVolume` for unrelated PVCs — symptom looks identical to the per-volume "operation already exists" lock from the rbd-plugin's in-memory tracker, but the root cause is across PVs. Skipping this check sent us down a multi-hour rabbit hole on 2026-05-14 chasing the wrong symptom.

### Pre-flight for any network-stack change (MCO reroll OR nmstate-only)

Full chronology + per-incident detail: `blog/blog-security-hardening-draft.md`.

**Scope** — the cascade triggers on any change that reloads NetworkManager / OVS gateway state, not just MachineConfig events:
- IPsec mode flip on `Network/cluster` (MC delta)
- OVN-K pod-overlay MTU change (operator-side MC churn even when final MC is identical)
- nmstate NNCP applying any interface change incl. MTU-only (no MC at all)
- Probably any future `Network/cluster` mutation, NNCP, multus NAD change
- **Any full node power-cycle** (e.g. installing a non-hot-swap 3.5" HDD) — re-trips the same OVN-egress cascade *per reboot* (observed 2026-06-10: node5 reboot → all 42 ArgoCD apps `sync=Unknown`, repo-server `DeadlineExceeded` on manifest gen). Fix = restart that node's `ovnkube-node` (look it up via `--field-selector spec.nodeName=...`, NOT awk columns — the `RESTARTS (x ago)` field shifts positions) + bounce repo-server; a bare repo-server bounce alone does NOT fix it (egress, not cold-cache).

**Cluster-shape gotchas to remember**:
- **`MinAvailable: N` PDB with replicas == N blocks ALL voluntary evictions.** LokiStack hardcodes ingester `MinAvailable=2` with 2 replicas → 0 disruption budget → drain hangs forever. CRD doesn't expose PDB tunables. Pre-flight: `oc get pdb -A`, ALLOWED DISRUPTIONS ≥ 1 everywhere.
- **RGW + router anti-affinity on 3 nodes**: 2 routers + RGW `required` anti-affinity → only 1 router-free node for RGW. Drain that node → RGW unschedulable → Loki S3 puts fail → ingester readiness loops.
- **Cross-node host-network breakage between mismatched-MC nodes during IPsec rollouts** (observed 2026-05-20, root cause TBD). Don't re-attempt IPsec without diagnosing.
- **Storage chaos compounds with MCO chaos rapidly.** Schedule with 2+ hour headroom.

**Pre-flight runbook** (run for any of the trigger shapes above):

1. Scale `openshift-operators-redhat/loki-operator-controller-manager` → 0. The 5-min `loki-pdb-override` CronJob loses the race against operator reconciles; scaling the operator to 0 holds the PDB at `MinAvailable: 1` throughout.
2. Scale `openshift-ingress-operator` `IngressController/default` replicas → 1. Ensures RGW always has a target node.
3. Apply the change. Monitor `oc get mcp master -w` (MC-class) OR `oc get nncp` (nmstate-class).
4. **During the rollout**, watch for stuck VolumeAttachments (`oc get volumeattachment | awk '$5=="true"'`) and force-clear with `oc patch volumeattachment <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`. RBD VAs frequently stay bound to the previous node after pod move.
5. **After the change settles**, restart all 3 `ovnkube-node` pods one at a time (`oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node`). Pod→host-network egress breaks; restart restores it. Symptom: ArgoCD `sync=Unknown` (repo-server can't reach github.com), etcd CO degrades (`EtcdMembersAvailable: 1 of 3`) though etcd itself is healthy. **Restart ALL 3 — not a targeted subset (2026-06-11 lesson).** A node whose `ovnkube-node` isn't restarted keeps **broken pod→*remote*-host-IP egress** (it can still reach its OWN host IP, so it looks fine) and the breakage stays **silent until a pod lands on it** — that day, only node5's `ovnkube-node` got restarted in the morning cascade fix; node6's stayed broken all day and only surfaced when `prometheus-k8s-0` rescheduled onto node6 and couldn't scrape node4/node5 host-metrics (`:10250`/`:9100`/etc. hung 30s), throwing ~20 **false** `TargetDown` + critical `etcdMembersDown`/`etcdInsufficientMembers`/`ClusterVersionOperatorDown`. Diagnose with a per-source-node reachability test: `oc -n <ns> exec <pod-on-suspect-node> -- sh -c 'time wget -qO- -T8 http://<remote-host-ip>:9100/metrics'` — fast to own host IP + 30s+ hang to remote host IPs == that node's `ovnkube-node` needs a restart. (Distinct from the DDF-cAdvisor false-alert cause in the storage section — both throw the same etcd-critical symptom; rule out etcd-real with `etcdctl endpoint health --cluster` first.)
6. Restart `openshift-gitops` repo-server pod (`oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-repo-server`). Clears the `DeadlineExceeded` on manifest generation.
6b. **Sweep for long-fuse external-egress retriers** at T+10-15 min. Pods polling external endpoints on schedules longer than the cascade window (cert-manager → LE ACME, anything calling Cloudflare, etc.) keep retrying with stale connections and don't recover. Symptom: ArgoCD app `Synced/Degraded` with `dial tcp ...: i/o timeout` in conditions. Known one: `oc -n cert-manager delete pod -l app.kubernetes.io/name=cert-manager,app.kubernetes.io/component=controller`. Critical for cmdline-only changes (early-symptom cascade is silent there).
7. Restore: scale `loki-operator` back to 1, `IngressController` back to 2, trigger `loki-pdb-override` CronJob one-shot if needed.

Skipping 5-6 re-trips the cascade; skipping 6b leaves cert-manager in a degraded loop until the next renewal attempt times out.

## Guardrails — do not do these

Claude should refuse these actions and explain why briefly:

- **No mutating cluster commands.** No `oc apply/delete/patch/scale/replace`, `kubectl apply/delete/patch`, `helm install/upgrade/uninstall/rollback`. ArgoCD owns cluster state; direct edits cause drift and are reverted.
- **No state mutation on external tools** (`terraform apply/destroy`, `terraform state mv/rm`, `argocd app sync --force` with prune).
- **No committed secrets.** No Cloudflare tokens, kubeconfigs, TLS private keys, OLM pull secrets. Reference secrets by name and assume they exist out-of-band.
- **No editing generated files**: `Chart.lock`, rendered manifest dumps, `*.orig`.
- **No OKD version bumps or cluster-wide CR changes** without an explicit ask — those are upgrade events, not routine edits.
- **Do not disable `automated.prune` or `selfHeal`** to "fix" a sync issue. Fix the manifest instead.

## Commit and branch conventions

- Work on `develop`, PR into `master`. ArgoCD watches `master`.
- Commit messages: `<scope>: <imperative summary>` — e.g. `cert-manager: bump to v1.16.2`, `root-app: add monitoring stack`, `storage: enable fd-b zone`.
- One logical change per commit. The rendered-manifest diff should be predictable from the message alone.
- Renovate PRs (label `dependencies`) are reviewed, not rewritten.

## Communication preferences

- Be concise and technically precise. Skip hedging, flattery, and recap of what I just said.
- Surface trade-offs honestly. If there's a simpler or more idiomatic approach than what I asked for, say so before implementing.
- When proposing a change, include the exact commands to validate it locally.
- Cite OKD, Helm, ArgoCD, or cert-manager docs by version when version-specific behavior matters.
- Prefer a short correct answer with one follow-up question over a long answer that guessed at my intent.

## MCP servers

`.mcp.json` declares two project-scoped MCP servers. They auto-launch via `npx -y` when Claude Code starts in this repo.

- **`kubernetes`** (`mcp-server-kubernetes`) — structured `kubectl_get` / `kubectl_describe` / `kubectl_logs` / `kubectl_explain` / `kubectl_diff` tools that talk to whatever cluster is in `~/.kube/config` (i.e. the OKD cluster after `oc login`). Prefer these over shelling out to `oc` for read-only inspection — fewer permission prompts (allowlist already covers `kubectl_*` reads), and the model gets structured JSON instead of parsing terminal output.
- **`github`** (`@modelcontextprotocol/server-github`) — read-only access to the `sudoom/homelab` repo and any other GitHub repo (good for cross-referencing upstream Rook / cert-manager / loki-operator issues). Requires `GITHUB_PERSONAL_ACCESS_TOKEN` exported in the shell before `claude` launches; minimum scope `public_repo` + `read:org`. Allowlisted: `mcp__github__get_*`, `mcp__github__list_*`, `mcp__github__search_*`. Mutations (`create_*`, `update_*`, `delete_*`, `merge_*`, `push_*`) are NOT allowlisted — they'll prompt; never approve them without an explicit user request.

For mutations against the cluster (apply/delete/patch/scale, etc.), still go through the user — `kubectl_apply` and friends from the kubernetes MCP are denied by the same guardrails as `oc apply` in plain Bash.

## Reviewing open PRs (`sudoom/homelab`) — suggest approve / not-approve

When asked to look at the repo, when starting a session, or whenever a Renovate/dependency PR is relevant, **check the open PRs and give an explicit approve / not-approve recommendation per PR** (read-only via the `github` MCP: `mcp__github__list_pull_requests` state=open, then `get_pull_request` + `get_pull_request_files` for the diff). I can review + recommend; I never merge (merge is a mutation, user-only).

For each PR, recommend **APPROVE / HOLD / NOT-APPROVE** with a one-line reason, judged against the guardrails + the relevant procedure:

- **Storage version bumps (Rook, Ceph, `rook-ceph-cluster`/`rook-ceph` charts, `quay.io/ceph/ceph`)** → **default NOT-APPROVE**. These must follow "Upgrading Rook/Ceph" above (version coherence + Rook↔Ceph compatibility + manual supervised window). A **major** bump (e.g. Ceph 19→20) is always NOT-APPROVE via Renovate. (Live example 2026-06-12: PR #117 `quay.io/ceph/ceph v19.2.4→v20.2.1` — NOT-APPROVE: major Squid→Tentacle, and Rook 1.19.5 doesn't support Ceph 20 with `allowUnsupported: false`.) Renovate should be configured to stop proposing these.
- **Other operator/CRD-bearing bumps** (cert-manager, loki/logging, cnpg, OADP, nmstate, gitops) → check the OKD/Kube compatibility (see `blog/blog-okd-4.22-upgrade-draft.md` matrix) + whether the okderators/community catalog has the build; HOLD if it crosses a support matrix or needs a catalog that doesn't exist yet.
- **App image tag bumps** (media stack, exporters, etc.) → usually APPROVE if it's a patch/minor with no CRD/schema change and the app is non-load-bearing; skim the changelog for breaking changes.
- **Anything touching `components/storage/`, `cert-manager`, networking, or a degraded-window path** → at least HOLD pending the relevant pre-flight.

Lead with the verdict, cite the file/diff, name the guardrail or procedure it trips. The user merges; I advise.

## Session hygiene

- **Minimize Bash output tokens.** Long sessions on this repo routinely eat 20%+ of context on diagnostic dumps. Pipe through `head`, `tail`, `grep`, `awk` to extract only the lines that drive a decision. For files, use `Read` with `offset`/`limit` instead of `cat`. Specifically avoid: `oc describe pod ...` without a grep filter (the events tail is what matters, the spec block isn't), `oc get xxx -o yaml` for anything bigger than a small CR (jsonpath-targeted reads instead), `oc adm top` or `ceph -s` dumps where a single-line jsonpath would do. The 2026-05-20 / 2026-05-21 sessions both hit context-pressure warnings before reaching natural end of day specifically because of unfiltered diagnostic captures.
- Before the context window is compacted, run `/export` to preserve the full conversation.
- When diagnosing a live issue, paste real `oc` / `argocd` output into chat rather than describing it — diagnoses from raw output are much better than from paraphrase.
- **At session start and immediately after a context compaction**, re-read the markdown files that carry working state, in this order — don't rely on the post-compaction summary alone:
  1. `CLAUDE.md` (this file) — rules may have tightened since the snapshot.
  2. Any `blog/blog-*-draft.md` files relevant to the work in flight — these are the chronological notes for what was tried, what worked, and what's still open.
  3. The TODO list at the bottom of `README.md` — confirm what's still queued vs. shipped.
  4. Auto-memory `MEMORY.md` (loaded automatically) plus the linked memory files — re-skim before assuming a remembered fact still holds.

  Compaction summaries are lossy by design; the markdown is the source of truth.

- **Always run the cluster health sweep before the first real work in a new session.** Same procedure as the end-of-session sweep documented under "Ending a session" below (nodes / ArgoCD apps / CSVs / certificates / restart outliers / non-Running pods / Ceph health). Reason: starting work on a stale assumption about cluster state is how the 2026-05-13 RGW outage went unnoticed for 21h — bounding that to "one session length" requires *both* end-of-session and start-of-session checks. A clean sweep is one line in the first reply ("cluster sweep clean: HEALTH_OK / 31 apps Synced+Healthy / no outliers"); a dirty sweep blocks the user's requested work until investigated — even if the symptom looks unrelated, surface it before proceeding. Use the readonly kubeconfig (`KUBECONFIG=~/.kube/config-readonly`).

- **Also re-pull the open PRs and re-verdict at session start** (right after the health sweep). `mcp__github__list_pull_requests` (sudoom/homelab, state=open), then an explicit **APPROVE / HOLD / NOT-APPROVE** per PR per the "Reviewing open PRs" section below (guardrails + the relevant procedure). Renovate opens/refreshes these between sessions, so surfacing them at start keeps the dependency queue from going stale and catches a risky storage/operator/major bump before it's blindly merged. One short line if nothing changed since last check; call out anything new or anything that crosses a guardrail. I advise; the user merges (merge is user-only).

- **Also triage firing Prometheus alerts at session start** — *triage*, not just list (the health sweep lists; this classifies + resolves). Pull firing alerts: the canonical query needs the operator kubeconfig logged in (`oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/alerts'`), or break-glass exec into `prometheus-k8s-0` when OAuth is down (reading `/api/v1/alerts` is a read, not a mutation; it does NOT dump credentials). For each firing alert, classify **known-benign** vs **actionable**: documented false positives on this cluster include `BLUESTORE_SLOW_OP_ALERT` (hair-trigger consumer-NVMe fsync), `CephPGImbalance` (no device-class grouping in the rule), `nmstate-handler`/`multus`/`haproxy` cumulative restarts, and `KubeJobFailed` on completed one-shot bootstrap Jobs — see the storage + network sections. For each **actionable** alert give a one-line root cause + a suggested resolution (and whether it's a guardrail-gated mutation = user-run). A clean board is one line; an actionable alert blocks the user's requested work until surfaced.

- **Before proposing anything that might already exist, check the docs first.** Re-reading at session start (above) isn't enough — when you're about to suggest "we should ship X" or "let's add Y", grep `blog/`, `CLAUDE.md`, `README.md`, `MEMORY.md`, and the relevant `components/<area>/` first. The 2026-06-08 incident: I proposed shipping CNPG `barmanObjectStore` as a follow-up — when CNPG-native backup had already been shipped 2026-05-18 with a passing 2026-05-20 restore drill, fully documented in `blog/blog-cnpg-draft.md`. The user shouldn't have to be the verifier-of-last-resort that I read what they already wrote down. Specifically: any "we should add Z" or "follow-up: ship Z" claim is a search trigger — `grep -ri "Z" blog/ CLAUDE.md README.md components/` before saying it. Same applies for "this isn't done yet" / "this is missing" / "we need to think about" — if the docs say it's done, it's done; trust the docs over your own model.

## Ending a session ("call it")

When the user says **"call it"**, **"call it for the night"**, **"wrap up"**, **"end of session"**, or anything semantically equivalent, treat it as a trigger to do a final pass *before* the goodbye summary — don't just summarize and stop. Three things, in order:

1. **Doublecheck docs for drift from today's work.**
   - `README.md` TODO: every shipped item removed; every newly-discovered item added; every still-queued item refreshed (rationale, blockers, status) if today changed it.
   - `CLAUDE.md`: any subsystem that today's work made load-bearing or whose constraints changed should be reflected here. Today's stack-shape changes belong here, not buried in the blog.
   - Per-chart `README.md` files for any chart touched: commands, paths, file tables match `git ls-files` reality.
   - Blog drafts: the relevant `blog/blog-*-draft.md` has a section covering today's work; "to be filled in once X reconciles" placeholders are filled in with actual observed state.
   - Run a targeted grep for the kinds of staleness today's commits would create — phrases like `blocked on <thing-that-just-shipped>`, `<thing> is queued`, old resource names, old field names.
2. **Clean up the repo.**
   - Stale comments in code / templates / values files (e.g. `# TODO ...` that's now done, `# old: ...` markers, debug commentary).
   - Unused `values.yaml` keys that no template references; dead Helm template branches behind `if` conditions that can never be true given current values.
   - Temporary experiment files / one-off scripts / dump artifacts left in the repo root or `tests/` that shouldn't be checked in long-term — propose deletion with rationale, don't silently delete.
   - Unused imports, dead-letter Kustomize patches, etc.
   - Use `git status --short` + `git ls-files --others --exclude-standard` to check for tracked-but-orphaned and untracked files.
3. **Cluster health sweep — expected result is no error.**

   The 2026-05-13 RGW outage existed for 21 h because no one ran a sweep. Doing it at end-of-session bounds that window to "one session length" instead of "however long until I happen to notice." Use the readonly kubeconfig (`KUBECONFIG=~/.kube/config-readonly`) — every read below works under it, no `oc login` required.

   Check, in order:
   - **Nodes:** `oc get nodes` — all `Ready`. Anything else (`NotReady`, `SchedulingDisabled` not introduced by today) → flag.
   - **ArgoCD apps:** `oc -n openshift-gitops get applications` — every app `Synced` + `Healthy`. `OutOfSync` is normal right after a push; if it persists past 5 min, dig.
   - **CSVs:** `oc get csv -A | awk 'NR==1 || $NF!="Succeeded"'` — only the header line should print.
   - **Certificates:** `oc get certificate -A` — every entry `Ready=True`. cert-manager renewal failures are silent otherwise.
   - **Pod restart-count outliers:** `oc get pods -A -o jsonpath='{range .items[?(@.status.containerStatuses[0].restartCount>10)]}{.metadata.namespace}/{.metadata.name} restarts={.status.containerStatuses[0].restartCount}{"\n"}{end}'` — every entry should be a known recurring item (`nmstate-handler` — open CSV-RBAC upstream bug; `multus-*`, `haproxy-node*`, `router-default` — long-uptime cumulative). Anything new = investigate.
   - **Non-Running pods:** `oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded` — empty.
   - **Ceph health:** `oc -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}'` — `HEALTH_OK` or `HEALTH_WARN` with only the known `BLUESTORE_SLOW_OP_ALERT`. Anything else, especially `HEALTH_ERR` or unfamiliar warning codes → flag. **Don't use the toolbox-exec form (`oc exec deploy/rook-ceph-tools -- ceph -s`) — pods/exec is denied under the readonly SA; the CR status field carries the same answer.**
   - **Active Prometheus alerts:** there's no read-only path to `/api/v1/alerts` under the SA token (Thanos requires `prometheuses/api` CREATE). If the operator kubeconfig is logged in, `oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/alerts' | jq '.data.alerts[] | select(.state=="firing") | .labels.alertname'` is the canonical query. If it isn't logged in, skip this check rather than block goodbye on it — the previous checks already catch most issues, and the alert layer is downstream of them.

   The expected result of every line above is "no surprise." If any check surfaces a new outlier today's session caused or didn't notice, that's a goodbye-blocker — investigate before the session ledger, even if it means another commit. A clean sweep is one short paragraph in the ledger ("cluster sweep clean: …"); a dirty sweep gets its own paragraph (with the symptom + what was done).

All three passes are *additional* commits on top of whatever the session shipped. End with a one-paragraph session ledger (commits + final state) — that part stays as-is.

## Blog notes — keep them current

Every session that diagnoses an issue, changes infrastructure, or runs a non-trivial benchmark should be captured in a blog-style draft at the repo root. These drafts are the working memory for future write-ups.

- **File naming:** `blog/blog-<topic>-draft.md` (e.g. `blog/blog-rook-ceph-draft.md`, `blog/blog-cert-manager-draft.md`). One file per topic, appended over time.
- **If a relevant draft exists:** update it. Add new sections rather than rewriting old ones, so the chronology survives.
- **If no relevant draft exists:** create one. Lead with a one-paragraph framing, then the technical content.
- **What to capture:**
  - Every meaningful command run (with the exact invocation, not paraphrased — `oc -n rook-ceph exec ...`, full `helm template` lines, etc.).
  - Raw output snippets that drove a decision (errors, `ceph -s`, `oc describe` excerpts).
  - The decision made and *why*, including alternatives ruled out.
  - Sequencing: a rolling restart, a network change, a PG bump — list the steps in order so it can be retraced.
- **Tone:** technical, first-person, no marketing fluff. These are notes that may become posts later, not the posts themselves.
- **Not to capture:** secrets, tokens, raw kubeconfigs, anything that would be a problem if the draft were committed publicly. Reference secrets by name.

Update the draft as you work, not at the end. If a session does something undocumented, that's a regression — flag it.

**Don't ask for permission to create or update blog drafts, READMEs, or any documentation that this CLAUDE.md says to keep current.** Just do it as part of the work, in the same commit/series as the change that prompted it. Asking "should I write this up?" is friction; the answer is always yes when the rule applies.

## TODO list lives at the bottom of README.md

The repo's TODO list is the structured section at the bottom of `README.md` (categories: In flight, Queued — observability, Queued — storage, Queued — operators / catalog, Queued — platform expansion, Documentation hygiene). Treat it as the single source of truth for tracked work.

- **When you suggest a new TODO** (e.g. you spot a gap during a session and the user agrees it should be tracked): add it to the appropriate category in `README.md`. Do not invent a separate TODO file. Match the existing item style — bold lead-in, then the *why* / *what* / *how to validate* in one or two sentences.
- **When the user gives input that refines an existing TODO** (more context, a chosen approach, a deadline, a reason it's deprioritized): update that item in place rather than appending a duplicate. Preserve chronology only when it matters; otherwise rewrite for clarity.
- **When a TODO ships:** remove it from the README in the same commit that lands the change. Don't leave checked-off items as historical record — the git log is the historical record.
- **Don't reorganize categories or split items into subsections without an explicit ask** — the existing structure is deliberate.

## README files — keep them current

Whenever you change something that a `README.md` describes, update that README in the same change. READMEs that drift out of sync are worse than no README at all — readers trust them and end up running stale commands.

- **Scope:** every `README.md` in the repo (root, `components/<component>/README.md`, `bootstrap/<thing>/README.md`, etc.). Find them with `find . -name README.md -not -path './charts/*'` before assuming there's only one.
- **Triggers that require a README update:**
  - Bootstrap steps changed (commands, file paths, prerequisites).
  - A component's purpose, sync wave, or values surface changed.
  - Architecture diagram in the README no longer reflects what's deployed.
  - Repository layout changed (directory moved/renamed).
  - A new component was added that belongs in the top-level overview.
- **What good looks like:** the README's commands, paths, and version pins match `git ls-files` reality. Sync waves listed in the README match `bootstrap/root-app/values.yaml`. If you can't run a command from the README copy-paste and have it succeed, the README is broken.
- **If a README is wrong but unrelated to your change:** flag it, don't silently fix it in an unrelated commit. Open a separate `docs(readme): …` commit.

Treat outdated READMEs the same as undocumented sessions — a regression to flag.

## Companion knowledge base — Obsidian vault

This codebase pairs with a personal+work Obsidian vault that holds long-form context this repo's CLAUDE.md / READMEs intentionally don't.

- **Vault path:** `/Users/vadzimdziadziulia-laptop/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notatki/`
- The vault is its own git repo with auto-commit on save; iCloud handles cross-device sync.

### What lives there (not here)

- **Decisions journal** for homelab work — `_memory/chats/homelab/YYYY-MM-DD-<topic>.md`. Use for non-trivial decisions whose "why" is worth preserving past a commit message (drive choice, NAS migration plan, capacity sizing).
- **Synthesized knowledge** — `wiki/{sources,entities,concepts,domains}/` — built up over time from `/wiki-ingest` of READMEs, ADRs, conversations.
- **Operating-state notes** — `Infrastructure/Homelab.md` (IP plan, VLAN plan, rack layout, port plan). Excalidraw diagram lives in `Excalidraw/`.
- **Navigation back to this repo** — `Infrastructure/Homelab repo.md` (where in the codebase to look for what).

### When to read from the vault from here

- Looking for the **rationale** behind a hardware/architecture decision that isn't obvious from the manifests (e.g., "why these NVMe drives", "why this VLAN plan"). The commit message usually points; the decision lives in vault `_memory/chats/homelab/`.
- Looking for **operating state** the repo doesn't track — what's racked vs on the shelf, last burn-in date, drive serials.
- Looking for **cross-domain context** the repo doesn't own (interactions with personal finance buckets, broader IP plan beyond the cluster, etc.).

### When to write to the vault from here

- After a non-trivial homelab decision: file a `_memory/chats/homelab/YYYY-MM-DD-<topic>.md` chat-memory note (preferred via vault `/save`; or write directly with the frontmatter required by the vault's `CLAUDE.md`).
- After a meaningful architectural change: trigger `/wiki-ingest` against the changed README or component from within the vault.

### Read permissions

This repo's `.claude/settings.json` whitelists Read/Glob/Grep on the vault path; the vault's `.claude/settings.json` whitelists the same on this repo. Native Read works on absolute paths in both directions — no MCP needed for cross-repo reads.

### Downstream: the published blog (sudops.pl)

The `blog/*-draft.md` files in this repo are the **upstream raw material** for the public homelab blog at **[sudops.pl](https://sudops.pl)** — repo `/Users/vadzimdziadziulia-laptop/Projects/sudops.pl` ([sudoom/sudops.pl](https://github.com/sudoom/sudops.pl), Astro).

- Pipeline: this repo's `blog/*-draft.md` (raw session chronology) → `sudops.pl/posts/*.md` (gitignored raw draft) → `sudops.pl/src/content/blog/*.mdx` (published).
- The blog repo reads THIS repo for ground truth (manifests, versions, commands) and the vault for the "why". You don't push to the blog from here — keep the drafts current per the "Blog notes" rule above; the blog repo pulls from them.
- Same secret-hygiene rule applies: drafts feed a public site, so never put real tokens/keys/kubeconfigs in `blog/*-draft.md`.
