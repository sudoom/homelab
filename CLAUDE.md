# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Repository overview

Homelab GitOps repository for a **3-node bare-metal OKD 4.21 cluster** (OpenShift Kubernetes Distribution), managed declaratively by **ArgoCD** with an app-of-apps pattern and Helm templating.

- **Cluster domain:** `okd.sudops.pl`
- **Nodes:** 3 control-plane+worker; frontend `192.168.1.7–9`, storage backnet `192.168.10.2–4`
- **Failure domains** (`topology.kubernetes.io/zone`): `fd-a → node4`, `fd-b → node5`, `fd-c → node6`
- **Ingress:** `*.apps.okd.sudops.pl` (wildcard, cert-manager)
- **API:** `api.okd.sudops.pl`
- **Git:** `git@github.com:sudoom/homelab.git` — `master` = production (ArgoCD tracks). Commits go straight to `master`; there is no working branch (see "Commit and branch conventions").

## Stack and tool versions

Pin these when generating manifests or commands — mismatched versions are the single largest source of wrong suggestions.

| Tool            | Version        | Notes                                                                 |
|---|---|---|
| OKD             | **4.21.0-okd-scos.11** (upgraded from 4.20 on 2026-09-08) | Kube API ≈ upstream **1.34** (mapping: OKD `4.N` → Kube `1.(N+13)`, so 4.22→1.35). SCOS 10, kubelet v1.34.6, cri-o 1.33.4. **4.22 is DEFERRED — `quay.io/okderators/catalog-index:4.22` does not exist.** |
| Helm            | local **v4.3.0**; ArgoCD uses its own bundled Helm 3 | Upstream ArgoCD v3.1.11 pins Helm 3.18.4 (`hack/tool-versions.sh`), so a local `helm template` can differ from what ArgoCD renders — check a version-sensitive change with `oc diff` against live. Helm v2 syntax is invalid; no Tiller |
| ArgoCD          | v3.1.11+cc053b2     | Server-side apply + sync-wave annotations used throughout             |
| OLM             | OKD-bundled    | `okderators` + `community-operators` CatalogSources                   |
| cert-manager    | v1.18.2     | OLM from `okderators`. **OUT OF MATRIX + EOL:** 1.18 supports Kube 1.29–1.33 and died 2026-03-10; we are on Kube 1.34. **No catalog offers newer** (okderators 1.18.0, community-operators 1.16.5, operatorhubio 1.16.5), so the only routes are the upstream Helm chart (built + parked on branch `cert-manager-helm-fallback`) or the upstream pipeline. **The pipeline route is now filed (2026-09-09): [okd-operator-pipeline#29](https://github.com/okd-project/okd-operator-pipeline/pull/29) bumps cert-manager to 1.20 on `release-4.21`, which is the branch that builds `catalog-index:4.21`; [#28](https://github.com/okd-project/okd-operator-pipeline/pull/28) does the same on `main` for 4.22. Neither helps until merged AND a catalog is rebuilt, so the Helm fallback stays the answer if the renewal date gets close.** **First ACME renewal on the out-of-matrix version: `homelab-wildcard` 2026-09-21.** |
| oc / kubectl    | client **4.22.14** (cluster 4.21) | One minor of client skew is within kubectl's support policy. Prefer `oc` for OpenShift-only kinds (Route, SCC, ImageStream) |
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
│   ├── technitium/          # Technitium DNS Server — dns-master + dns-slave (2× RPi 3B+), CLUSTERED
│   └── truenas/             # TrueNAS SCALE NAS config via midclt over SSH (replacing the Synology)
├── blog/                    # Working notes / draft posts — see "Blog notes" rule below
├── bugs/                    # Drafted upstream-issue bodies (filing-ready)
├── tests/                   # Manual-apply test artifacts not yet promoted to a chart
├── data/                    # Captured benchmark / SMART / log artifacts referenced from blog drafts
│                            # └── storage-throughput.md — ALL measured throughput figures, with conditions
├── docs/superpowers/specs/  # Design specs from brainstorming, reviewed before any implementation
└── CLAUDE.md
```

### Non-cluster infrastructure — `ansible/` vs `components/`

- `components/` + `bootstrap/` are what ArgoCD applies to the cluster. `ansible/` holds things outside the cluster
  that still need versioned, idempotent config — Technitium DNS (`dns-master` `.12` + `dns-slave` `.13`) and the
  TrueNAS NAS — kept off ArgoCD so DNS and the NAS never depend on the cluster being up.
- **Code-only: never propose a web-UI or manual fix for an Ansible-managed box.** Change the role, re-run the playbook.
- `ansible.builtin.*` modules only. Vault passwords are interactive, so **I can't run `ansible/technitium/playbook.yml`
  or `ansible/truenas/playbook.yml`**; `--syntax-check`, technitium `base-only.yml` and truenas `check.yml` I can.
- Full rules and the TrueNAS middleware traps: `ansible/CLAUDE.md`, which loads automatically when I read a file
  under `ansible/`.

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

- `okderators` (`quay.io/okderators/catalog-index:4.21` — bumped 2026-09-08 after the 4.21 hop) — OKD community operators. Use for **cert-manager**. **The tag flip delivered NOTHING**: cert-manager head is still v1.18.0, gitops still v1.19.0, and `cluster-logging` head is v6.3.0 — *older* than the installed v6.5.0. Zero InstallPlans generated. **All five okderators subscriptions were switched to `installPlanApproval: Manual` before the flip** (cert-manager, gitops, cluster-logging, loki, oadp) — do not revert that; on Automatic a tag flip auto-upgrades all five at once, including the operator running ArgoCD.
- `community-operators` — upstream OperatorHub.io. Use for **NMState** (the okderators build has an ImageStream bug).
- **The okderators build chain is per-OKD-release, and `main` is NOT the branch that builds our catalog (found 2026-09-09).** `okd-operator-pipeline` has `main` plus `release-4.18`/`release-4.20`/`release-4.21` branches. **`main` builds 4.22** (`common.sh` sets `OKD_VERSION=4.22.0-okd-scos.2`, 39 submodules pin `release-4.22`); **`release-4.21` builds our catalog** (`OKD_VERSION=4.21.0-okd-scos.10`) and is 34 commits behind main. So a fix contributed to `main` does NOT reach `catalog-index:4.21` — it has to land on `release-4.21` too. Same for `okderators-catalog-index`, which has its own `release-4.1x`/`release-4.21` branches.
- **A submodule's `.gitmodules` `branch =` is NOT what gets built.** `submodule_reset()` in the pipeline's `common.sh` ignores its `branch` argument and resets each submodule to the **recorded gitlink hash**; only `update` (not run by default) consults the branch. So a repo can declare `branch = release-4.21` while the gitlink is a 4.20 commit and every build silently produces 4.20 content — exactly the state nmstate was in on both branches (our PR #30). **When checking what an operator is pinned to, resolve the gitlink against the upstream branches (`gh api repos/<o>/<r>/compare/<branch>...<sha>`), don't read `.gitmodules`.**
- **OLM v1 (catalogd + operator-controller) is installed and unused (2026-09-14).** Zero `ClusterExtension`s; every operator here is an OLM v0 `Subscription`. The three Red Hat default `ClusterCatalog`s (`openshift-redhat-operators`, `-certified-operators`, `-redhat-marketplace`) are held at `availabilityMode: Unavailable` by `components/cluster-config/olm-v1-catalogs/` — no entitlement for their content, and the redhat one leaked 79 MB of catalog temp dirs per failed 10-minute poll into operator-controller's emptyDir on node5 (42 GiB in six days, Ceph `MON_DISK_LOW`; upstream fix operator-framework/operator-controller#2574 not in the 4.21 payload). `openshift-community-operators` stays Available. Do not "fix" the Unavailable catalogs back; do not confuse them with the OLM v0 `CatalogSource`s in `openshift-marketplace`, which are untouched.

### Operator patterns

- Every operator component = `Namespace + OperatorGroup + Subscription` (+ CR in a later sync wave if needed).
- **Cluster-scoped** operators (cert-manager): `OperatorGroup` with `spec: {}`.
- **NMState**: `OperatorGroup` with `spec: {}` too (AllNamespaces) — installed into `openshift-nmstate` (`.Values.namespace`), but its *operand* (handler DaemonSet, ServiceMonitor, RBAC) lands in a separate hardcoded `nmstate` namespace (`HANDLER_NAMESPACE`, baked into the CSV). **Two namespaces, both real** — a namespaced resource added to that chart MUST set `metadata.namespace: nmstate` explicitly, because the ArgoCD Application's `destination.namespace` is `openshift-nmstate` and it would otherwise land there, report Synced+Healthy, and grant nothing. (Corrected 2026-08-06: this line previously claimed `targetNamespaces`; the chart has always shipped `spec: {}`.)

### TLS / cert-manager

- Let's Encrypt **production**, DNS-01 via **Cloudflare**.
- The DNS-01 resolver uses public nameservers (`1.1.1.1`, `8.8.8.8`) — cluster DNS can't resolve external domains, and without this override the challenge fails.
- Wildcard cert `*.apps.okd.sudops.pl` → `openshift-ingress`.
- API cert `api.okd.sudops.pl` → `openshift-config`.
- Cloudflare API token is provisioned via the SealedSecret in `components/cluster-config/cert-manager-config/templates/sealed-cloudflare-api-token.yaml`. Rotation = re-`kubeseal` + commit (one-liner in that chart's `values.yaml`).
- **sealed-secrets controller runs `--key-renew-period=720h` (auto-rotation) — NEVER set it to `0`.** `0` disables rotation, which silently let the single sealing key's cert **expire 2026-05-28** with no replacement → `kubeseal` failed `expired certificate`, blocking ALL new sealing cluster-wide (existing SealedSecrets kept decrypting fine — expiry only breaks *sealing*, not decryption). Fixed 2026-06-27 (`720h` → controller minted a fresh 10-year key, old key retained for decryption). The controller's **public sealing cert is committed at `components/operators/sealed-secrets/sealed-secrets-pub.pem`** for offline `kubeseal --cert` (public key = seal-only, safe to commit; refresh after a rotation via `kubeseal --fetch-cert`).

## Storage (Rook-Ceph)

The cluster's storage is **Rook v1.19.5 managing Ceph Squid 19.2.4**. (Ceph was bumped 19.2.3→19.2.4 via Renovate 2026-06-12 and rolled the 3 OSDs cleanly — kept. Rook was bumped 1.19.6→**1.20.0** by Renovate the same day and it **broke CSI** — the v1.20 operator changed CSI ServiceAccount naming, leaving `ceph-csi-*-sa` missing so RBD+CephFS CSI couldn't create new pods; reverted to a coherent **v1.19.5** in `49406f5`. See "Upgrading Rook/Ceph" below + `blog/blog-rook-ceph-draft.md`.) Two Rook charts: **operator** = `components/operators/rook-ceph/` (deploys the Rook operator), **cluster** = the wrapper `components/storage/rook-ceph-cluster/` (owns the `CephCluster` CR + block pools + StorageClasses + CephFS, rendered from `cephClusterSpec`/`cephFileSystems`/`cephBlockPools` in its `values.yaml`). **To change OSD devices, pools, or CRUSH, edit `components/storage/rook-ceph-cluster/values.yaml`.** OSD device list = `cephClusterSpec.storage.nodes[].devices` — uses **`/dev/disk/by-path/pci-…-ata-N`** (the SATA bay PORT, slot-stable so a drive swap reuses the OSD; NVMe = `/dev/nvme0n1`); by-id WWN stays the ref for drive-SPECIFIC ops (wipe/SMART/gate). **THE HDD TIER, CephFS AND THE OBJECT STORE WERE ALL RETIRED 2026-09-07.** Ceph now serves exactly two pools — `nvme-replicated` (RBD, the `ceph-nvme-block` SC) and `.mgr` — on the three NVMe OSDs. There is no CephFS, no `cephfs-hdd` SC, no `CephObjectStore`, no `ceph-bucket` SC, and no in-cluster S3. RWX is served by the NFS classes (`nfs-csi`, `nfs-truenas-*`); S3 is garage on TrueNAS. **PHASE 4 COMPLETE 2026-09-08: `osd.3/4/5` are purged and the drives are physically out.** Ceph is now a 3-OSD all-NVMe cluster (`ceph osd crush class ls` returns `["nvme"]` — the `hdd` class no longer exists), and the 11 orphan CRUSH rules left by the retired pools were dropped, leaving only `replicated_rule` and `nvme-replicated`. Rollout-to-retirement history, and the four teardown traps worth knowing before touching Ceph again, are in `blog/blog-hdd-tier-rollout-draft.md`.

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

### Node drain — a single-instance CNPG cluster blocks it unconditionally (immich FIXED 2026-09-15 by going to 2 instances)

Found the hard way during the 4.20 → 4.21 upgrade (2026-09-08): node6's drain stalled ~20 minutes and would
never have completed on its own.

```
E0908 drain_controller: error when evicting pods/"immich-postgres-1" -n "immich"
  (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

CNPG creates a `minAvailable: 1` PDB over the **primary**. CLAUDE.md already noted these are "permanently 0 by
construction" and "do NOT block draining a node that holds a *replica*" — both true, and both miss the corollary:
**`immich-postgres` is `instances: 1`, so every node is the primary's node.** The budget can never be satisfied
and the eviction retries forever. `media-postgres` (3 instances) drained fine — CNPG just moved the primary.

**Unblock:** `oc -n immich delete pod immich-postgres-1` — CNPG recreates it on another node (the draining one is
cordoned). Two gotchas: the delete takes **>120 s** (graceful Postgres shutdown + RBD unmount), long enough that
the drain controller hits its 10-minute threshold and backs off to a **5-minute retry** — so the unblock is not
instant. And `oc` may fail `Unauthorized` at that exact moment, because the `authentication` operator updates
during the upgrade and an `oauth-openshift` replica can be Pending on the cordoned node: **this is what the
break-glass kubeconfig is for** (SA token, not OAuth).

**It recurred on 2026-09-14, and not on an upgrade.** An unplanned MCO reroll (next paragraph) selected node4 at
12:09Z; the drain sat on `immich-postgres-1` for 5+ hours, the MCD went Degraded after the first hour
(`failed to drain node: node4.okd.sudops.pl after 1 hour`), and five control-plane replicas plus mon-a and osd.0
were Pending the whole time. **Every master-pool MachineConfig change hits this, not just the 4.22 hop.**

**Resolved 2026-09-15: `immich-postgres` runs `instances: 2`** (`components/apps/immich/values.yaml`, commit
`e460c61`). With two or more instances CNPG performs a switchover ahead of the drain when the primary's node is
cordoned, and the old primary is then evicted as a replica — the documented 1.30 behaviour and what
`media-postgres` already did. The replica PDB (`<cluster>`, `minAvailable: instances-2`) is only created at
three or more instances (`pkg/specs/poddisruptionbudget.go`), so the lone replica is freely evictable and the
only PDB left is the structural `immich-postgres-primary`, which no longer blocks because the primary can move.
Cost: one more 10Gi RBD image and 512Mi/1Gi memory; the daily volume snapshot now comes from the standby
(`backup.target` default `prefer-standby`), which is a valid restore source. **The unblock recipe above stays
valid for any FUTURE single-instance CNPG cluster** — the rule is "never run a 1-instance CNPG cluster on the
master pool", not "delete the pod". Chronology: `blog/blog-cnpg-draft.md` 2026-09-15.

**What starts a reroll without a commit — never delete the `powersave-experimental` Tuned CR by hand (2026-09-14).**
NTO turns that CR's `[bootloader]` line into `50-nto-master`. Delete the CR and NTO deletes the MachineConfig within
a second; MCO renders a master config without `intel_pstate=passive processor.max_cstate=9` and selects a node
inside the next minute (`render_controller: now targeting rendered-master-d9509ea…` at 12:08:59Z, node4 cordoned
at 12:09:10Z). ArgoCD selfHeal recreates the Tuned, NTO recreates `50-nto-master`, and the pool target flips back
to the original rendered config — but **the node already selected keeps the transient `desiredConfig`**: the node
controller never reassigns a node it counts as unavailable, so that node reboots onto the argument-less config
and then a second time back onto the real one. To turn power tuning off, change `bootArgs` in
`components/cluster-config/power-tuning/values.yaml` and run the network pre-flight — one controlled reroll.
Side effect seen the same minute: the cordon made Rook re-reconcile CSI (12:09:21Z), which rewrote the RBD
`Driver` CR; `csi-driver-config` re-applied `hostNetwork` (12:09:27Z) and both RBD ctrlplugin pods restarted.
Chronology: `blog/blog-power-consumption-draft.md` 2026-09-14.

### Topology

- **3 NVMe OSDs, one per node — that is the whole cluster (`osd.0-2`).** The 3 HDD OSDs (`osd.3-5`, added 2026-06-12) were purged and physically pulled 2026-09-08; root `default` weight is now 1.39737 (3 x 0.46579). Failure domain is `host` (labels `fd-a/fd-b/fd-c`, one per node), so the no-drain constraint below applies to every OSD. **CAPACITY WAS THE BINDING CONSTRAINT AND IS NOT RIGHT NOW, but the reason it eased is worth knowing:** `nvme-replicated` peaked at **84.53% / MAX AVAIL 70 GiB** on 2026-09-08, half a point off the 85% `nearfull` threshold, having climbed from 76.6% inside a few hours. It read **59.39% / 183 GiB** on 2026-09-09 and **28.42% / 324 GiB** on 2026-09-11 — the decline kept going for two days with nothing added and only the retention CronJob's daily deletions (2 snapshots on 09-11). Daily `node-fstrim` and Ceph's own snapshot trimming are the candidates; not attributed. Nothing was added to the cluster — 182 unpruned CNPG volume snapshots were deleted, and Ceph then trimmed for hours afterwards (stored 396 -> 269 GiB, ~127 GiB total). **Re-measure hours after any snapshot deletion, not minutes: the immediate reading understated that reclaim by 2.5x.** The 11 TiB of empty HDD used to sit in `ceph -s`'s totals and hid this completely — do NOT read cluster-level `avail` as headroom, read the per-pool `MAX AVAIL` from `ceph df`. Reclaim levers, in order: `fstrim` (the `node-fstrim` DaemonSet — freed RBD blocks are not returned without discard, see RBD CSI quirks), then the CNPG `ceph-rbd-snapshot` volume snapshots. **That guess was correct and the cause is now fixed: `Cluster.spec.backup.retentionPolicy` governs the barman object-store path ONLY — for `method: volumeSnapshot` CNPG creates the VolumeSnapshot and the Backup CR and never collects either.** 182 had accumulated over 110 days under a policy reading `7d`. `components/cluster-config/cnpg-snapshot-retention/` (root-app wave 6) now prunes them daily: older than 7d, with a hard floor of 7 newest per cluster so a stalled backup schedule can never empty the set, scoped by `cnpg.io/scheduled-backup` so manual and restore-drill snapshots are untouched. **Deleting a `Backup` CR does NOT cascade to its `VolumeSnapshot` — the ownerReference is the Cluster — so both objects must be deleted.** Full diagnosis: `blog/blog-cnpg-draft.md` 2026-09-08/09.
- **No drain headroom.** Any rolling change to OSDs (rebuild, encrypt-at-rest, redeploy) goes through a degraded window — there is no fourth node to absorb the missing OSD. Plan accordingly: schedule during quiet IO, never run two OSD-impacting changes at once, never propose `oc cordon node{4,5,6}` without an explicit ask.
- **Mons:** 3-of-3, one per node. Same topology constraint applies.
- **Network:** Frontnet (VLAN 5) for clients; storage backnet (VLAN 10, 192.168.10.2-4) for OSD ↔ OSD replication.
  **The backnet is no longer Ceph-only (changed 2026-08-26): TrueNAS sits on it at `192.168.10.10`, MTU 9000**, so its NFS exports reach the nodes on-link with no NNCP change — which is precisely why that address was chosen over a dedicated NFS VLAN (a new VLAN would have needed `enp1s0f1np1` brought up = an nmstate enactment = the `br-ex.forwarding` cascade). `.10` is clear of the nodes (`.2-.4`), the `ceph-shim` macvlans (`.16-.18`) and the `192.168.10.128/25` Multus pod range. **Accepted cost: Ceph and the NAS now share a failure domain** — a backnet incident takes out both (two in two months: node6's NIC back DOWN 2026-07-25, the 10G switch firmware flap 2026-08-07). **The Multus migration is parked, not in flight.** The host side shipped 2026-05-11 and is still live in the `storage-node4/5/6` NNCPs: a per-node macvlan host-shim (`ceph-shim`, IPs `.16/.17/.18`) and an explicit `192.168.10.128/25 dev ceph-shim` route (the kernel-RBD-client hairpin fix). The NADs (`ceph-network-attachments`) are disabled in root-app and the CephCluster stays on `provider: host` — see "Network provider" for why both multus attempts failed. Full design + ops history in `blog/blog-multus-ceph-migration-draft.md`. **Don't touch `enp1s0f0np0`, `ceph-shim`, or `192.168.10.0/24` routing without checking that draft first** — the routing setup is load-bearing: `/24 master metric 100`, `/24 shim metric 410`, `/25 dev shim static`. Reordering or simplifying breaks pod↔host reachability.

### Hardware: 3× Samsung PM9A1 512GB

- Migration from PNY CS1030 → PM9A1 completed 2026-05-07. Per-OSD `kv_commit_lat` dropped from ~95 ms (worn PNY lifetime) to ~3 ms (PM9A1); **average stays ~3.7 ms** (confirmed 2026-06-15). The worn-drive pathology is gone — **watch the *average* `kv_commit_lat`, not the alert latch.** **`BLUESTORE_SLOW_OP_ALERT` does still appear** and is **benign**: it's hair-trigger (`bluestore_slow_ops_warn_threshold=1` / `lifetime=86400` / `log_op_age=5s` → a single op >5 s in 24 h latches it), and an occasional fsync/FUA stall on no-PLP consumer NVMe is expected hardware-class behaviour (2026-06-15: NVMe osd.0/osd.1, 355/874 slow KV commits out of ~1.72 M = 0.02–0.05 %, avg latency healthy). **Don't read "N OSDs slow" as "the HDDs" — check `ceph osd tree` for the device class first** (2026-06-15 I guessed HDD; it was NVMe osd.0/osd.1). Lever if it ever becomes pure noise: raise `bluestore_slow_ops_warn_threshold` (don't suppress — it's a real signal). Full chronology + bottleneck sweep in `blog/blog-rook-ceph-draft.md`.
- **`CephPGImbalance` — SHOULD NOW SELF-RESOLVE (2026-09-08).** It was a false positive ONLY because Rook's rule averages `ceph_osd_numpg` across device classes; with the HDD tier gone there is one class and three OSDs at 129 PGs each, so the cross-class mean is no longer meaningless. **If it keeps firing, it is worth a real look rather than the old dismissal.** Historical rationale, kept because it explains the rule's defect:  Rook's `prometheus-ceph-rules` averages `ceph_osd_numpg` across *all* OSDs with no device-class grouping; NVMe OSDs carry ~185 PGs, HDD OSDs ~68, so both tiers deviate ±46 % from the cross-class mean (126.5) and all six trip the 30 % threshold. **Within each class the distribution is perfect** (185/186/185 nvme, 68/67/68 hdd) and `ceph balancer status` reports `no_optimization_needed: true, "distribution is already perfect"`. Proper fix (device-class-aware expr) requires `monitoring.createPrometheusRules: false` + vendoring the full corrected rule set — deferred (cosmetic; README TODO). Firing since 2026-06-13 (HDD-tier rebalance settled).
- For future drive purchases at this cluster scale, stay on PM9A1-class consumer NVMe — full PLP enterprise (Micron 7450 PRO etc.) is not justified by the workload. The bottleneck post-swap is replication-amplification at `size=3`, not per-drive fsync latency.
- **BMH inventory is stale and cannot be refreshed on this cluster.** The OpenShift console's BareMetalHost "Disks" tab still shows the pre-swap PNY CS1030 drives because BMHs are in `state=unmanaged` with `externallyProvisioned=true` — Metal3 doesn't manage them (no BMC credentials configured), so it can't trigger re-inspection. The `inspect.metal3.io` annotation is a no-op in this state. The `smartctl-exporter` dashboard + the `smartctl_device_*` Prometheus metrics are the **live** source of truth for current hardware. Nothing in ArgoCD, Ceph, or operator reconciliation reads the BMH `.status.hardware.storage`, so the staleness is purely cosmetic.
- **On-node disk tooling — use the `smartctl-exporter` pod, not a pulled image.** `registry.access.redhat.com/rhel9/support-tools` does NOT pull on node4 (`ImagePullBackOff`, observed 2026-06-10). For on-node `smartctl` / SMART self-tests, `oc exec` into the existing `smartctl-exporter` DaemonSet pod (per node: it already has `smartctl` + host device access, zero pull). That image lacks `badblocks` — destructive write-tests need a USB3 dock off-node or a pre-mirrored tool image. **Always reference disks by `/dev/disk/by-id/wwn-*`, never `/dev/sdX`**: HDD bay installs power-cycle the node and `/dev/sd*` re-enumerates (2026-06-10: the new HDD took `sda` on node4 but `sdb` on node5/node6; the boot/etcd SSD is also SATA, so a wrong `/dev/sdX` is one typo from the boot disk).
- **SATA-SSD wipe/erase — the `ROTA=1` boot-disk guard does NOT apply; use an allowlist gate.** The HDD burn-in gate (`assert_burnin_target`) leans on `ROTA=1` to separate the 4TB HDD target from the boot/etcd disk (a SATA SSD, `ROTA=0`). That discriminator **vanishes when the target is itself a SATA SSD** — boot/etcd disk and burn-in SSD are the same device class. Any SATA-SSD *write* (secure-erase for the boot-spare/backup-drive prep, 2026-06-11 batch 3; future OSD-journal SSDs) must go through **`assert_ssd_burnin_target`** — a **positive WWN-allowlist** gate (fail-closed on empty allowlist; paste the seated SSD's WWN in first), keeping the boot/NVMe WWN denylist as backstop. Never the HDD gate, never a bare `/dev/sdX` — a wrong by-id on an SSD erase = boot/etcd disk wiped on a no-drain cluster. On-node wipe = **`blkdiscard -f` + `wipefs -a`, NOT `hdparm`** — `hdparm` is **not installed on SCOS** (confirmed 2026-06-11, `rc=127`; `wipefs`/`lsblk`/`blkdiscard` are present, `hdparm` isn't), so ATA secure-erase isn't an on-node option. `blkdiscard` (whole-device TRIM) is a clean-slate-for-reuse wipe; `DISC-ZERO=0` on these Intel DC drives means no read-zero guarantee (fine for reuse, not forensic — pull to a workstation w/ hdparm for that). Gate template + SSD flow (SMART wear triage → read pass → `blkdiscard`/`wipefs` → post-wipe confirm) in `blog/blog-hdd-tier-rollout-draft.md` (2026-06-11 Batch 3; **S4610 backup-target burn-in via USB enclosure done 2026-06-26**). USB-enclosure lessons from that run: the USB-SATA bridge needs **`smartctl -d sat` on every call** but passes TRIM + self-tests fine (use the drive-internal long self-test as the surface scan — no `dd`-over-USB needed); the `smartctl-exporter` pod has `blkdiscard`/`dd`/`blockdev`/`partprobe` but **NOT `wipefs`/`lsblk`/`mdadm`**, so clear the partition table by **`dd`-zeroing the first 10 MiB (MBR + GPT primary) + last 1 MiB (GPT backup) *after* `blkdiscard`** (after, because `DISC-ZERO=0` → TRIM gives no read-zero guarantee); and **run `blkdiscard` in the background — whole-device TRIM over a USB bridge exceeds a 2-min foreground exec and gets SIGTERM'd mid-wipe** (the front zeroing + table re-read still landed, but re-run in the background to complete the full-device TRIM). The wipe script bakes the gate's typed-serial check in programmatically (re-resolve by-id symlink + re-assert model/serial/WWN + denylist at execution time) since the pod has no interactive TTY. Drive roles: S3510 480GB → boot/etcd spare; S4610 960GB → Synology USB-box backup target (not Ceph WAL/DB).
- **Used-drive hot-swap → false CRITICAL etcd/CVO alerts (DDF firmware-RAID, 2026-06-10).** The used HUS726040 datacenter pulls carry DDF (firmware-RAID) superblocks; the host auto-assembles an md raid0 on insertion, and a *broken* array (after a pull) makes the kernel disk-stats read **hang kubelet cAdvisor for the 30s scrape timeout** → Prometheus can't scrape that node's host-metrics → ~31 **false** alerts incl. **critical** `etcdMembersDown` / `etcdInsufficientMembers` / `ClusterVersionOperatorDown` + 16× `TargetDown`. **These are scrape-inferred, not real — confirm with `oc -n openshift-etcd exec <etcd-pod> -c etcdctl -- etcdctl endpoint health --cluster` (all members up) before touching etcd.** Fix per node, guarded to the HUS726040 rotational disk only: `mdadm --stop` the stale `/dev/md*` arrays, then `wipefs -a` the DDF; a node whose cAdvisor has been wedged for hours additionally needs `systemctl restart kubelet`. Prevention: wipe DDF **first** on every used-drive insertion, store shelf spares **raw**. Full diagnosis: `blog/blog-hdd-tier-rollout-draft.md` (2026-06-10 DDF section). **A node's `ovnkube-node` with broken pod→remote-host egress throws the *same* false etcd-critical symptom — rule out both** (see "restart ALL 3 ovnkube-node" in the network pre-flight section).

### Pools and pg_num

- **Only two pools exist since 2026-09-07:** `nvme-replicated` (`size=3`, `min_size=2`, CRUSH rule on `device_class=nvme`, `bulk: true`) backing the `ceph-nvme-block` RBD StorageClass, and `.mgr`.
- **`.mgr` is pinned to the NVMe CRUSH rule** by `components/storage/rook-ceph-cluster/templates/mgr-pool-crush-rule.yaml`. Ceph creates `.mgr` itself, so no CR owns it and it defaults to `replicated_rule`, which targets bare `default` — every device class. That made it the last thing holding PGs on the HDD OSDs after every HDD pool was deleted, and it appears in no list of "HDD pools" because it is not one. A fresh bootstrap recreates it on the default rule, hence the Job. **Since 2026-09-08 the hazard is structural rather than operational:** with the HDD OSDs gone, `default` contains only nvme, so `replicated_rule` and `nvme-replicated` select the same devices and the trap cannot recur. The Job is kept anyway — it costs nothing, and it documents the hazard for whoever re-adds a second device class.
- **Target `pg_num` is 128** for `nvme-replicated`: 100 PGs/OSD × 3 OSDs / replication 3 = 100 → next pow2 = 128. Use `pg_num_min: 128` in the BlockPool to enforce — the autoscaler is **not** applying the `bulk` hint correctly (`ceph osd pool autoscale-status` returns `[]`; root cause likely a Squid 19.2.x quirk, tracked as an open TODO). Same quirk hit the RGW data pool on 2026-05-10; same fix shape.
- When proposing pool changes: floor with `pg_num_min`, don't disable autoscale. Don't suggest manual `pg_num` bumps unless paired with the autoscaler diagnosis.
- **`pg_num_min` chicken-and-egg:** Ceph rejects `pg_num_min > current pg_num` with `EINVAL`. Pure-GitOps `pg_num_min` enforcement requires a **one-time toolbox bump** of `pg_num` to bootstrap each new pool past 1 (`ceph osd pool set <pool> pg_num <floor>; ceph osd pool set <pool> pgp_num <floor>`); the chart's `pg_num_min` then enforces the floor going forward. Confirmed twice (`nvme-replicated` originally, RGW data pool 2026-05-10). Capture the exact toolbox commands in the topical blog draft.

### Object storage (RGW) — RETIRED 2026-09-07

The `CephObjectStore` `ceph-objectstore`, all nine `ceph-objectstore.rgw.*` pools, `.rgw.root`, the three orphan `default.rgw.*` pools and the `ceph-bucket` / `ceph-bucket-retain` StorageClasses are **gone**. There is no in-cluster S3.

Both tenants moved to **garage on TrueNAS** (`http://192.168.1.25:30188`, frontnet — pods cannot reach the backnet): Loki's chunks and OADP's BackupStorageLocation. Garage buckets and access keys are managed by `ansible/truenas` (`truenas_garage.s3_tenants`), one key per consumer so a rotation cannot take out backups and logging together.

**If in-cluster S3 is ever wanted again**, re-enable `ceph-object-store` in `bootstrap/root-app/values.yaml` — but note it brought two standing costs: the RGW-vs-router `:80` anti-affinity permanently consumes one schedulable node, and Rook does not propagate a `deviceClass` change to an existing pool (`bugs/upstream-rook-deviceclass-change-not-propagated-existing-pool.md`).

### CephFS — RETIRED 2026-09-07 (was the HDD bulk RWX tier)

The `CephFilesystem` `cephfs`, its `cephfs-metadata` + `cephfs-bulk-hdd` pools, the `cephfs-csi` subvolume group and the `cephfs-hdd` StorageClass are **gone**. Its only consumer, `media/media-data-pvc`, moved to TrueNAS NFS on 2026-08-30; the retained 3.5 TiB was reclaimed 2026-09-07. **RWX is served by the NFS classes now** — do not propose CephFS for a new RWX need without an explicit decision to rebuild the tier. **The CephFS CSI driver is off as well (2026-09-13):** `csi.enableCephfsDriver: false` in `components/operators/rook-ceph/values.yaml`, and the cephfs `Driver` hostNetwork patch is gone from `components/cluster-config/csi-driver-config/`. A rebuild re-enables both in one commit. Disabling was NOT clean: the pruned Driver CR livelocked under ArgoCD's foreground prune (symptom map row in the teardown section) and needed its finalizer cleared by hand.

**Rebuilding is NOT a chart change.** Ceph requires `--force` for an EC default data pool and Rook will not pass it, so it needs a one-time manual `ceph fs new cephfs <metadata> <data> --force` BEFORE Rook can adopt and manage the MDS.

**UNEXPLAINED AT RETIREMENT, and it may not be CephFS-specific.** The tier could not serve concurrent multi-node RWX: two pods on two nodes, one client getting persistent `EACCES` on `statx` — **293 failures in 300 s, no recovery until the concurrency stopped**. Not the MDS (fs Ready, no evictions since August). Not one bad node (node4 first, then node5 on a directory it had just used successfully four times). Consistent with a **blocklisted kernel client**. It was never root-caused and is now unreproducible. **The same mechanism could affect RBD**, which is production — every config PVC, both Postgres clusters, Loki's WAL. If RBD ever shows persistent EACCES on a multi-node claim, start here rather than from scratch.

Also worth carrying forward: fio renders a failed `stat()` as `fio: /path is not a directory` for a directory that demonstrably exists, which sends you looking at paths instead of client sessions.

### RBD CSI quirks

- The CSI driver does **deferred delete**: PVC removal calls `rbd trash mv`, not `rbd rm`. Trashed images keep consuming pool space until purged. Manual purge in 04/2026 reclaimed ~600 GiB.
- Need a periodic `rbd trash purge schedule` (use Ceph's built-in scheduler, not a CronJob — it lives in mgr config).
- **Freed blocks aren't returned to the pool without TRIM/discard** (separate from trash). `ceph-nvme-block` has no `discard` mountOption, so a filesystem deleting data leaves the RBD blocks allocated. 2026-06-18: `rbd du` showed ~245 GiB of stale Loki-WAL allocation (106+140 GiB) vs ~0.5 GiB FS-used — most of `nvme-replicated`'s 82% fill. Reclaim is **`fstrim`**, NOT `rbd sparsify` (freed blocks aren't zeroed). Shipped + enabled `components/cluster-config/node-fstrim/` — a privileged hostPID DaemonSet running `nsenter -t1 -m -- fstrim -av` weekly per node (first pass also does the one-off reclaim). In-cluster `oc debug node … fstrim` is guardrail-denied (host node-shell), so a manual one-off is operator-run. Full diagnosis: `blog/blog-rook-ceph-draft.md` 2026-06-18.
- Occasionally an image refuses removal with `image has watchers` — usually a stuck CSI nodeplugin attachment; investigate the node, don't force-delete the image.
- **`operation already exists` mount lock can outlive plugin restarts.** When `NodeStageVolume` hangs (e.g., kRBD waiting on an unreachable OSD), the rbd-plugin's in-memory operation tracker locks the volume ID. Every retry returns `rpc error: code = Aborted desc = an operation with the given Volume ID ... already exists`. Restarting the rbd-nodeplugin pod usually clears the lock — but if the underlying cause (network unreachable, msgr2 silent drop) persists, the new plugin will hit the same hang on the first retry. **Don't chase the lock; chase what's keeping the first call stuck.** Check `/sys/bus/rbd/devices/` on the host via `oc debug node/<name>` — empty = the hang is in plugin userspace, not kernel.
- **Stuck VolumeAttachments need finalizer force-clear.** When CSI mount fails repeatedly, VAs accumulate with the `external-attacher/rook-ceph-rbd-csi-ceph-com` finalizer and `attached: true` even though no mount succeeded. If the PV is also gone (e.g., test PVC deleted), normal `oc delete` hangs forever. Unstick: `oc patch volumeattachment <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`. Same pattern can affect `rook-ceph-mon-endpoints` ConfigMap / `rook-ceph-mon` Secret after teardown — same force-clear works.
- **Orphan Released PVs block the csi-provisioner cluster-wide.** When CSI's `DeleteVolume` for a PV fails (e.g., earlier mount regression left an unfinishable rbd image), the PV stays `Released` and the provisioner re-attempts deletion forever. CSI plugins serialize operations cluster-wide, so a stuck DeleteVolume blocks every new CreateVolume too — symptom looks identical to the "operation already exists" lock from the per-volume tracker, but the cause is a different volume's stuck deletion. **Before applying any test PVC, check for orphan Released PVs**: `oc get pv | grep Released`. Clear them with `oc patch pv <name> -p '{"metadata":{"finalizers":[]}}' --type=merge && oc delete pv <name>`. Also clear any stale VolumeAttachments to the now-gone PV. The "stuck VA + stuck PV" duo can survive plugin restarts, controlplugin restarts, and operator restarts — must be manually cleared.
- **Fresh-bootstrap workaround: `client.csi-rbd-provisioner.<gen>` is missing its `osd` cap** (Rook 1.19.5 bug). The provisioner user gets `mgr "allow rw"` + `mon "profile rbd, ..."` but no `osd` cap → every `CreateVolume` hangs on the first RADOS op → "operation already exists" lock storm. **Auto-fixed on each bootstrap by** `components/storage/rook-ceph-cluster/templates/csi-rbd-provisioner-caps-fix.yaml`. Bug filed at `bugs/upstream-rook-csi-rbd-provisioner-missing-osd-cap.md`; full chronology + manual recovery steps in `blog/blog-rook-ceph-draft.md`. If a key rotation creates `csi-rbd-provisioner.2`/`.3`, the same `ceph auth caps … osd "profile rbd"` needs to be re-run against the new generation suffix.
- **CephFS post-node-outage recovery (2026-07-26) — historical; CephFS was retired 2026-09-07.** A wedged node-level CephFS stage mount survived plugin restarts. The fix was moving its consumers off the node, then `systemctl restart kubelet` there — not hand-unmounting the staging dirs (that corrupted ceph-csi's staging state) and not a reboot. Full saga: `blog/blog-ntp-dns-cluster-outage-draft.md` Part 3.

### Network provider — `host` (with required `addressRanges`)

The `CephCluster.spec.network.provider` is `host`. Two ways this rule has been validated:

**1. In-place `host → multus` migration is forbidden.** A 2026-05-12 attempt to follow Rook's documented `host → "" → multus` two-step deadlocks on this 3-OSD no-drain topology. During the intermediate `provider: ""` state, the first-rolled OSD goes onto the pod network while the other two stay on host; **PG peering hangs indefinitely** under that mixed-network shape (msgr2 between asymmetric-address peers stalls); Rook's `ceph osd ok-to-stop` then refuses to roll any further OSD because peering is hung, including the one that needs to roll back. Chicken-and-egg with no Rook-native escape. Bonus snag: the operator does NOT clear `public_network` from the Ceph config DB across provider changes — the first OSD on the new shape crashloops because it can't find an interface matching the stale CIDR.

**2. Multus fresh-rebuild on a clean cluster (2026-05-14) also failed.** Skipped the in-place migration entirely; tore down and rebuilt on `provider: multus` from the first daemon. Initial measurements were promising (1.6 GB/s 1M seqread vs. ~118 MB/s baseline), but the moment we tried to refine the design (Phase 6.5 — split the two NADs onto disjoint /26 IPAM ranges + pin explicit public/cluster_network CIDRs), kRBD mount silently broke: the host-side `ceph-shim` macvlan IP (`.16`) ended up outside the narrowed public `/26`, so msgr2 from the host stack hung. **The regression survived a clean chart revert** — CSI plugin restarts, ctrlplugin restarts, operator restart, VA finalizer force-clears, none of it cleared the stuck `NodeStageVolume` goroutine in the rbd-plugin. Recovery required full teardown.

**Mons advertise FRONTNET addresses while OSDs advertise BACKNET — this is CORRECT, do not "fix" it.** `rook-ceph-mon-endpoints` and `ceph mon dump` both show `192.168.1.7/8/9`, which looks like `addressRanges` failing to apply. It is not. `public_network` = `cluster_network` = `192.168.10.0/24` (`ceph config get mon`, verified 2026-08-28), and **all three OSDs advertise `192.168.10.2/3/4` as both public and cluster address** (re-verified 2026-09-24 from the mgr's `ceph_osd_metadata` metric, readable under the readonly SA). A client contacts a mon once over the frontnet to fetch the OSDMap (a few KB of control plane), then does all data IO directly against the OSDs on the 10G backnet. **Client data has never traversed the 1G link** — on 2026-08-28 a 3-stream read of the since-retired CephFS tier measured 170 MiB/s (1.43 Gbps), above 1G line rate. **Quote the date with any throughput number and re-measure before sizing on it: every measured figure lives in `data/storage-throughput.md` with its client/stream count and method; add new ones there, not inline.** (Corollary: both networks are load-bearing for storage — frontnet down = no mon contact, backnet down = no OSD IO, which is why a single node's backnet NIC coming up DOWN after a reboot breaks all its RBD mounts.)

**POD-NETWORK → STORAGE-BACKNET EGRESS DOES NOT WORK (found 2026-08-28).** Everything that reaches `192.168.10.0/24` today does so from the **host stack**: Ceph is `network.provider: host`, and `csi-nfs-node` + `csi-nfs-controller` are both `hostNetwork: true`. A pod on the OVN pod network (podIP `10.128.0.0/14`) **cannot** reach `192.168.10.x`. Confirmed when the Velero `truenas-garage` BSL failed `dial tcp 192.168.10.10:30188: i/o timeout` and a 90-second `ss` watch **on the NAS saw ZERO inbound SYNs** — the packets never arrive, so this is an egress-side drop, not an asymmetric-reply problem (TrueNAS *would* also misroute the reply: `ip route get 10.130.1.157` → `via 192.168.1.1 dev eno1`, the frontnet gateway, which has no route to the pod CIDR — but that never comes into play). **Pod → frontnet LAN works fine** (`synology-cert-sync` reaches `192.168.1.2` nightly), so the workaround for any pod-network client of a LAN service is to reach it on `192.168.1.x`. **Practical rule: if a POD (not the kubelet, not a hostNetwork DaemonSet) needs to talk to the NAS, point it at `192.168.1.25`, not `192.168.10.10`.** The data path is unaffected — NFS is kernel-mounted by hostNetwork CSI pods, so media/immich/keepers traffic still rides the 10G backnet; only pod-originated traffic (Velero's S3 client) takes the 1G frontnet.

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

**If RGW (or any Ceph daemon binding host ports) comes back, it must avoid router nodes.** With `network.provider: host`, RGW binds `:80`, which the two hostNetwork `router-default` replicas already hold on 2 of 3 nodes. On 2026-05-13 RGW rescheduled onto a router node and crashlooped on `EADDRINUSE` for ~21 h. The disabled `components/storage/ceph-object-store/` chart keeps a `required` podAntiAffinity against the router pods — **don't downgrade it to `preferred`**. Multi-instance RGW, NFS-ganesha or an NVMe-oF gateway would need the same.

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
# Current list as of 2026-09-24 (templates and live agree):
for j in csi-rbd-provisioner-caps-fix-bootstrap mgr-pool-crush-rule-bootstrap pg-num-floor-bootstrap rbd-trash-purge-schedule-bootstrap; do
  oc -n rook-ceph delete job $j --ignore-not-found
done
oc -n rook-ceph delete jobs -l rook-ceph-cleanup --ignore-not-found

# 2b. Stuck Ceph CR finalizers — Rook can't reconcile its own delete once the CR is in Deleting:
oc -n rook-ceph patch cephcluster rook-ceph -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
for bp in $(oc -n rook-ceph get cephblockpool -o name 2>/dev/null); do
  oc -n rook-ceph patch $bp -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 2c. Stale cluster-scoped ObjectBuckets (else a new OBC stays Pending with "bucketName has changed compared to ob").
# Only relevant if the object store was re-enabled — RGW and every OBC were retired 2026-09-07, so this is normally a no-op:
for ob in $(oc get objectbucket -o name 2>/dev/null); do
  oc patch $ob -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  oc delete $ob --ignore-not-found 2>/dev/null
done

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

# 6. CSI plugin in-memory state — bounce the RBD plugin pods (operator recreates; the CephFS driver is off since 2026-09-13):
oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-nodeplugin --wait=false
oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-ctrlplugin --wait=false

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
| `CephFilesystem` / `CephObjectStore` stuck `Deleting` right after their daemons were removed | **Rook's dependent check needs the daemon it already tore down.** It lists buckets via the RGW admin API (`no such host` once the Service is gone) and subvolumegroups via the MDS (`exec timeout` once zero MDS pods remain), so the finalizer can NEVER clear. Confirmed 2026-09-07. Force-clear is the only exit; verify the dependents are empty BEFORE the daemons go down, because afterwards you cannot. Every CephFS/object-store retirement here ends this way |
| A purged OSD **reappears** a few minutes later, often with a blank `CLASS` in `ceph osd tree` | **`ceph osd purge` does not remove the on-disk BlueStore signature.** `cephClusterSpec.storage.nodes[].devices` gates only NEW provisioning; on every reconcile Rook also runs `ceph-volume raw list` and re-adopts ANY disk still carrying a signature, allowlist or not (`cephosd: N ceph-volume raw osd devices configured on this node` in the osd-prepare log). Confirmed 2026-09-08 — osd.3 came back 25 min after a clean purge, on the reconcile triggered by an unrelated node's device removal. **Removing an OSD needs a fourth step: kill the signature.** Either zap the disk (no reboot — the right call if the drive is STAYING) or physically pull it (no zap — the right call if it is leaving anyway, since the 3.5" bay is not hot-swap). Purge AFTER the signature is gone, never before |
| Pools survive after their CR is pruned | `preservePoolsOnDelete: true` (and `preserveFilesystemOnDelete`) — working as intended. Deleting the CR removes the daemons and stops Rook managing them; the pools are deleted deliberately from the toolbox behind `mon_allow_pool_delete`. Skipping this leaves PGs on OSDs you are about to remove |
| An OBC takes ~an hour to delete and looks stalled | The provisioner sends `DELETE /admin/bucket?purge-objects=true` as ONE synchronous call with a client timeout it cannot meet at ~20k objects on HDD. It progresses only by timing out and retrying; once workqueue backoff stretches it looks dead **while the bucket is already gone**. Restart `rook-ceph-operator` to reset the backoff |
| ObjectBucketClaim (OBC) stays `Pending`, operator log says `"bucketName has changed compared to ob"` | Stale cluster-scoped `ObjectBucket` from prior cluster — delete it |
| `rook-ceph` namespace stuck `Terminating`, status says `clientprofiles.csi.ceph.io has 1 resource instances` | Stale `clientprofile.csi.ceph.io` finalizer — force-clear |
| csi-provisioner spins forever on volume IDs unrelated to current PVCs | Orphan Released PVs |
| New PVC stuck `Pending` even after provisioner restart | Combination of orphan PVs + stale VAs blocking the serialized provisioner |
| `NodeStageVolume` returns "operation already exists" immediately on first mount | Stale VA + plugin in-memory tracker on a volume that no longer exists |
| Every `CreateVolume` returns "operation already exists" on a freshly-bootstrapped cluster | `client.csi-rbd-provisioner.<gen>` missing `osd profile rbd` cap (Rook 1.19.5 bug — see RBD CSI quirks above; chart-shipped Job auto-fixes on next sync if it ran) |
| A pruned `Driver.csi.ceph.io` sits in `Deleting` while its plugin DaemonSet/Deployment are recreated every ~45 s, new pods Pending on anti-affinity against their own terminating predecessors | **Foreground-prune livelock (found 2026-09-13, disabling the CephFS driver).** ArgoCD prunes with `foreground` propagation, so the CR carries only the `foregroundDeletion` finalizer and waits for its dependents; ceph-csi-operator keeps reconciling the terminating Driver and recreates the owned DaemonSet/Deployment (`blockOwnerDeletion: true`), so the GC never finishes. Rook is NOT the culprit once `ROOK_CSI_ENABLE_<X>` reads false. Unstick (user-run): `oc -n rook-ceph patch driver.csi.ceph.io <name> --type=merge -p '{"metadata":{"finalizers":null}}'` — the owner vanishes, background GC removes the children, the operator has nothing left to reconcile. Prevention: annotate the resource `argocd.argoproj.io/sync-options: PrunePropagationPolicy=background` and let that sync BEFORE removing it from the manifest. Applies to any operator-owned CR ArgoCD prunes while the operator still reconciles it |

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
6. Commit directly to `master`; ArgoCD picks it up on its next poll.

## Debugging order of operations

When an Application is `OutOfSync`, `Degraded`, or just "stuck", check in this order — don't skip ahead:

1. `oc -n openshift-gitops get application <name> -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}{.status.operationState.message}{"\n"}'` — sync status, health, last operation message. (The `argocd` CLI is installed but not logged in, and `argocd login` is denied.)
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
- **Any full node power-cycle** (e.g. installing a non-hot-swap 3.5" HDD) — re-trips the same OVN-egress cascade *per reboot* (observed 2026-06-10: node5 reboot → all 42 ArgoCD apps `sync=Unknown`, repo-server `DeadlineExceeded` on manifest gen). Fix = restart that node's `ovnkube-node` (look it up via `--field-selector spec.nodeName=...`, NOT awk columns — the `RESTARTS (x ago)` field shifts positions) + bounce repo-server; a bare repo-server bounce alone does NOT fix it (egress, not cold-cache). **After a multi-node disruption, restart EVERY disrupted node's `ovnkube-node`, and re-verify — a "Ready" ovnkube-node can still have broken egress AND broken pod→ClusterIP (172.30.0.1) service routing; the second is what stalled a CNPG barman sidecar (couldn't reach the kube API) even after the first restart. It can take a *second* clean ovnkube-node restart once the underlying fabric is stable (2026-07-25).**
- **A node reboot can bring the Ceph storage-backnet NIC (`enp1s0f0np0`, VLAN 10) back up `DOWN`/`linkdown`** (observed 2026-07-25: node6's came back down after the others rebooted). Because `public_network`/`cluster_network` are both `192.168.10.0/24`, a single node's backnet NIC being down = **that node's OSDs can't heartbeat (marked down) AND its kRBD client can't map ANY image** → every RBD pod on that node hangs `MountVolume.MountDevice … DeadlineExceeded`, and other nodes' OSD logs show `heartbeat_check: no reply from 192.168.10.<x>`. **Post-reboot storage check: `ip -br a show enp1s0f0np0` UP with its `192.168.10.x` IP on every node + cross-node `ping 192.168.10.2/3/4`.** Fix a down one with `nmcli device connect enp1s0f0np0` (restores the managed IP + the load-bearing `/24` routes — NOT a bare `ip link up`). Then the post-outage RBD cleanup dance is needed on that node (stuck VAs → nodeplugin op-lock → re-verify pod→ClusterIP), none of which self-heals.

**Cluster-shape gotchas to remember**:
- **`MinAvailable: N` PDB with replicas == N blocks ALL voluntary evictions.** LokiStack hardcodes ingester `MinAvailable=2` with 2 replicas → 0 disruption budget → drain hangs forever. CRD doesn't expose PDB tunables. Pre-flight: `oc get pdb -A`, ALLOWED DISRUPTIONS ≥ 1 everywhere **except the two structural CNPG primary PDBs** (`media/media-postgres-primary`, `immich/immich-postgres-primary`) — CNPG's per-cluster primary PDB is `minAvailable: 1` over exactly the one primary pod, so `disruptionsAllowed` is permanently 0 by construction (on `media-postgres` too, whatever its instance count). Those do NOT block draining a node that holds a *replica*, and with 2+ instances CNPG switches the primary over ahead of the drain. **Both clusters run 2 instances since 2026-09-15** (media was 3 until then), so neither has the replica PDB (`<cluster>`, created only at 3+ instances) and the lone replica is freely evictable. A 1-instance CNPG cluster is the one shape that stalls a drain — never run one on the master pool (see "Node drain" above). Any OTHER 0 is a real blocker.
- **Cross-node host-network breakage between mismatched-MC nodes during IPsec rollouts** (observed 2026-05-20, root cause TBD). Don't re-attempt IPsec without diagnosing. **CANDIDATE EXPLANATION (2026-08-07, unverified):** this may be the `br-ex.forwarding=0` bug above. An IPsec rollout is an MCO reroll → node reboots → host-address changes → OVN gateway reconcile → `br-ex.forwarding` zeroed, which breaks pod→remote-host-IP exactly as described. **Before relying on this, resolve the one distinguishing detail the 2026-05-20 notes don't record: was the failing source a POD-network pod or a genuinely host-network pod?** Only the former is explained by `br-ex.forwarding` (host-network traffic never traverses `ovn-k8s-mp0`). If it was pod-network, this TBD is closed and the check is a one-liner; if host-network, it is still a separate unknown.
- **Storage chaos compounds with MCO chaos rapidly.** Schedule with 2+ hour headroom.

**Pre-flight runbook** (run for any of the trigger shapes above):

1. Scale `openshift-operators-redhat/loki-operator-controller-manager` → 0. The 5-min `loki-pdb-override` CronJob loses the race against operator reconciles; scaling the operator to 0 holds the PDB at `MinAvailable: 1` throughout.
2. Apply the change. Monitor `oc get mcp master -w` (MC-class) OR `oc get nncp` (nmstate-class).
3. **During the rollout**, watch for stuck VolumeAttachments (`oc get volumeattachment | awk '$5=="true"'`) and force-clear with `oc patch volumeattachment <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`. RBD VAs frequently stay bound to the previous node after pod move.
4. **After the change settles**, restart all 3 `ovnkube-node` pods one at a time (`oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node`). Pod→host-network egress breaks; restart restores it. Symptom: ArgoCD `sync=Unknown` (repo-server can't reach github.com), etcd CO degrades (`EtcdMembersAvailable: 1 of 3`) though etcd itself is healthy. **Restart ALL 3 — not a targeted subset (2026-06-11 lesson).** A node whose `ovnkube-node` isn't restarted keeps **broken pod→*remote*-host-IP egress** (it can still reach its OWN host IP, so it looks fine) and the breakage stays **silent until a pod lands on it** — that day, only node5's `ovnkube-node` got restarted in the morning cascade fix; node6's stayed broken all day and only surfaced when `prometheus-k8s-0` rescheduled onto node6 and couldn't scrape node4/node5 host-metrics (`:10250`/`:9100`/etc. hung 30s), throwing ~20 **false** `TargetDown` + critical `etcdMembersDown`/`etcdInsufficientMembers`/`ClusterVersionOperatorDown`. Diagnose with a per-source-node reachability test: `oc -n <ns> exec <pod-on-suspect-node> -- sh -c 'time wget -qO- -T8 http://<remote-host-ip>:9100/metrics'` — fast to own host IP + 30s+ hang to remote host IPs == that node's `ovnkube-node` needs a restart. (Distinct from the DDF-cAdvisor false-alert cause in the storage section — both throw the same etcd-critical symptom; rule out etcd-real with `etcdctl endpoint health --cluster` first.)

   **MECHANISM (found 2026-08-07 — this entry was symptom-only for months).** The "ovnkube-node egress break" is a **host-kernel return-path** failure, not an egress failure: **`net.ipv4.conf.br-ex.forwarding` gets reset to `0`.** This cluster runs OVN-K **local gateway mode** (`gatewayConfig.routingViaHost: true`), so pod north-south traffic leaves via `ovn-k8s-mp0` into the host kernel, is masqueraded, and exits `br-ex` — making the **reply** an ordinary kernel forward (in `br-ex` → out `mp0`). With `conf.br-ex.forwarding=0` the kernel drops the reply *during routing*, before the nftables FORWARD hook: silent hang, no RST, no counter moves. Packets really do go out (host conntrack zone 0 shows `SYN_RECV` with the reply tuple `dst=<node-IP>`) while the pod-side OVS zone 19 entry sits `SYN_SENT [UNREPLIED]` forever. `ip_forward=0` globally is **correct and deliberate** here (ovnkube-node runs with `--disable-forwarding`, OpenShift's `ipForwarding: Restricted` default) — forwarding is enabled per-interface, so healthy state is **`br-ex=1`, `mp0=1`, `all=0`, `ip_forward=0`**. `mp0` survives because it's an OVS internal port owned by OVN-K; `br-ex` is NetworkManager-managed, so an NM reapply resets its per-interface sysctls to the `default` (`0`) and leaves `mp0` alone. Restarting `ovnkube-node` works because it re-asserts `br-ex.forwarding=1` on start.

   **Use the sysctl as the pre/post check — it is instant and unambiguous, unlike an 8-30s `wget` hang:**
   ```bash
   for p in $(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node \
       -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.nodeName}{"\n"}{end}'); do
     echo "${p##*:} $(oc -n openshift-ovn-kubernetes exec ${p%%:*} -c ovnkube-controller -- \
       sysctl -n net.ipv4.conf.br-ex.forwarding 2>/dev/null)"      # 0 = BROKEN, 1 = healthy
   done
   ```
   This also explains the entry's odd footnotes: each node's sysctl is independent (**hence restart ALL 3**); a *second* restart is sometimes needed because NM can clobber it again; a "Ready" `ovnkube-node` can still be broken because nothing in its readiness probe reads that sysctl; and the pod→ClusterIP `172.30.0.1` breakage is ~1-in-3 flapping because only the **node-local** host-network backend needs no forwarding. **TRIGGER (confirmed 2026-08-07): ANY host-address change on ANY interface — including the Ceph storage backnet.** That day the **Mikrotik 10G switch was rebooted for a firmware upgrade**; all 3 nodes logged `mlx5_core ... enp1s0f0np0: Link down` at **09:24:35Z** and `Link up` at **09:28:15Z**, and 6 s after the drop every node's `ovnkube-controller` logged `Setting annotations map[k8s.ovn.org/host-cidrs:[...] k8s.ovn.org/l3-gateway-config:{...}]` — OVN-K's **gateway reconcile**, fired because the backnet address vanished. That reconcile leaves `br-ex.forwarding=0` (the restricted-forwarding setup zeroes `net.ipv4.ip_forward`, and writing `conf.all.forwarding` **propagates to every interface**; it then re-asserts `mp0=1` but not `br-ex=1`, which only happens on full gateway init = ovnkube-node start). **The trigger is on VLAN 10; the damage is on VLAN 5** — the two have no logical connection, which is exactly why this is easy to misdiagnose. This also retro-explains this entry's whole trigger list (reboot / MCO reroll / nmstate change): each changes the host address set, so each was an instance of *this*, not a separate cause. **Every future 10G-switch firmware upgrade will re-break pod egress cluster-wide** — treat a backnet link flap as a mandatory post-check of the sysctl above. **SECOND INSTANCE (2026-09-08), CAUSE PARTLY MIS-ATTRIBUTED AT FIRST — READ THE RETRACTION BELOW.** No reboot, no MCO reroll, no nmstate enactment, no switch event — just a tie-break at 05:09 that moved the API VIP (`192.168.1.240`) and the ingress VIP (`.241`) off node4 (`(okd_API_0) Master received advert from 192.168.1.8 with same priority 68 but higher IP address than ours` → `Entering BACKUP STATE`, `oc -n openshift-kni-infra logs keepalived-<node> -c keepalived`). Two addresses moving across three hosts inside a second is a host-address change on every node, so `br-ex.forwarding` went to 0 cluster-wide. **RETRACTED SAME DAY.** I wrote that up as "a bare VRRP failover is a sufficient trigger". Later that morning node5 was powered down for phase 4, the ingress VIP failed over to node6 (`(okd_INGRESS_0) Entering MASTER STATE`, node6 ending up with BOTH `.240` and `.241`) — and `br-ex.forwarding` stayed **1** on both surviving nodes. A VIP move alone does **not** do it. What the 09-08 evidence actually supports is that the ~05:09 **frontnet blip** hit all three nodes at once, and the VIP re-election was a *sibling symptom* of that blip, not its cause — which also explains why Ceph lost mon quorum and marked all 6 OSDs down in the same minute. That fits the confirmed 2026-08-07 mechanism (a link event flapping host addresses on every node) rather than adding a new one. **What IS confirmed by both 09-08 reboots: a node reboot reliably zeroes THAT NODE'S `br-ex.forwarding`, and only that node's** — node4's reboot left node5/node6 at 1. So blast radius = the set of nodes whose addresses actually changed, and a single-node reboot is a single-node fix (measure all three with the sysctl, then restart what reads 0). The standing alert (README TODO) remains the right mitigation because the cluster-wide variant is still triggered by link events nobody schedules. Same blip also cost Ceph its mon quorum and marked all 6 OSDs down (mons advertise FRONTNET addresses — a frontnet blip IS a Ceph event) and crashed the `rook` mgr module; Ceph self-recovered, PGs back to `active+clean`. **Symptom trap from that day: `oc get csv -A` showed `cloudnative-pg.v1.30.0` flapping `Failed`/`InstallReady`, which reads as a broken operator upgrade and is not** — it is OLM's install-plan check failing to reach `172.30.0.1`. Likewise a `ContinuousArchiving=False` on BOTH CNPG clusters (not one) is the all-three-nodes shape of this bug. Ruled out that day: nmstate (no enactment since 07-30, 0 handler restarts), MCO (no rendered MC since 05-28), Tuned, repo manifests, NM touching br-ex (**zero** br-ex journal events on any node), clock. Full diagnosis: `blog/blog-ovn-brex-forwarding-outage-draft.md`; upstream bug draft: `bugs/upstream-ovn-kubernetes-gateway-reconcile-drops-br-ex-forwarding.md`.

   **Measurement trap:** `node_network_carrier_changes_total` showed node4/node5 as having NO carrier flap that day — false. `prometheus-k8s-0` (on node6) could not scrape them from 09:24 *because of this outage*, so their flap was never recorded. **When a monitoring gap and the incident share a start time, absence of a metric is not evidence of absence of the event** — go to the node journal (`chroot /rootfs journalctl -k` via the MCD pod; `oc adm node-logs` is guardrail-denied).

   **Diagnostic trap — `PodNetworkConnectivityCheck` cannot localise this.** `network-check-source` is a **`replicas: 1` Deployment** (only `network-check-target` is a DaemonSet), so *every* check in the cluster is sourced from whichever single node hosts that pod. "All DOWN checks have source nodeX" is a **tautology**, not evidence that nodeX is the broken one — and it gives **zero** information about the other two nodes. Localise with the per-node sysctl check above, or a `curl --max-time 8` matrix from a pod on each node.
5. Restart `openshift-gitops` repo-server pod (`oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-repo-server`). Clears the `DeadlineExceeded` on manifest generation.
5b. **Sweep for long-fuse external-egress retriers** at T+10-15 min. Pods polling external endpoints on schedules longer than the cascade window (cert-manager → LE ACME, anything calling Cloudflare, etc.) keep retrying with stale connections and don't recover. Symptom: ArgoCD app `Synced/Degraded` with `dial tcp ...: i/o timeout` in conditions. Known one: `oc -n cert-manager delete pod -l app.kubernetes.io/name=cert-manager,app.kubernetes.io/component=controller`. Critical for cmdline-only changes (early-symptom cascade is silent there).
6. Restore: scale `loki-operator` back to 1, trigger `loki-pdb-override` CronJob one-shot if needed. (A step that scaled `IngressController/default` to 1 replica was removed 2026-09-24: it only existed to leave RGW a router-free node, and RGW is retired.)

Skipping 4-5 re-trips the cascade; skipping 5b leaves cert-manager in a degraded loop until the next renewal attempt times out.

## Guardrails — do not do these

Claude should refuse these actions and explain why briefly:

- **No mutating cluster commands.** No `oc apply/delete/patch/scale/replace`, `kubectl apply/delete/patch`, `helm install/upgrade/uninstall/rollback`. ArgoCD owns cluster state; direct edits cause drift and are reverted.
- **No state mutation on external tools** (`terraform apply/destroy`, `terraform state mv/rm`, `argocd app sync --force` with prune).
- **No committed secrets.** No Cloudflare tokens, kubeconfigs, TLS private keys, OLM pull secrets. Reference secrets by name and assume they exist out-of-band.
- **No editing generated files**: `Chart.lock`, rendered manifest dumps, `*.orig`.
- **No OKD version bumps or cluster-wide CR changes** without an explicit ask — those are upgrade events, not routine edits.
- **Do not disable `automated.prune` or `selfHeal`** to "fix" a sync issue. Fix the manifest instead.

## Skills — the `superpowers` plugin

Installed 2026-09-09. Not every skill fits this repo; three of them contradict rules stated elsewhere in this
file. **A skill never overrides a guardrail.** If a skill's instructions conflict with the Guardrails section or
with a rule below, the repo rule wins and I say which one I am following and why.

**Use these by default, without being asked:**

- **`systematic-debugging`** — before proposing a fix for any incident, failed sync, or unexpected output. It
  guards against exactly this repo's recurring failure: guessing a cause from a plausible-looking signal. Real
  examples that would have been caught — reading "N OSDs slow" as "the HDDs" when it was NVMe osd.0/osd.1
  (2026-06-15); reading `.gitmodules` and concluding nmstate was on 4.21 when the gitlinks were 4.20
  (2026-09-09); assuming `PodNetworkConnectivityCheck` localises a `br-ex.forwarding` break when its source is a
  single-replica Deployment.
- **`verification-before-completion`** — before claiming anything is done, fixed, or passing, and before every
  commit. Pair it with the Validation workflow. This repo has repeatedly shipped a confident claim that was
  wrong: "27 of 27 orphaned VolumeAttachments" (my own broken check), "the collector is crashing" (my own manual
  run, not cron), the 2026-09-08 `br-ex.forwarding` cause I wrote up and retracted the same day.
- **`brainstorming`** — before designing something new: a new chart, a monitoring surface, a migration plan, an
  upstream contribution's shape. Not for routine edits, version bumps, or doc updates.
- **`writing-plans` / `executing-plans`** — multi-step supervised work with a degraded window or a rollback
  story: OKD minor upgrades, Rook/Ceph bumps, storage migrations, teardown+rebuild. These pair with the
  "no drain headroom" and "30-minute cap" rules rather than replacing them.
- **`requesting-code-review` / `receiving-code-review`** — upstream PR work, and any change to a chart that a
  degraded-window procedure depends on.

**These conflict with existing rules — the repo rule wins:**

- **`using-git-worktrees`, `finishing-a-development-branch`** assume a feature-branch workflow. This repo commits
  **direct to `master`** (ArgoCD watches it) — no feature branches, no PRs, per the standing instruction. Do not
  create a branch or worktree for homelab changes. **Exception:** upstream contribution clones under the
  scratchpad (`okd-operator-pipeline`, etc.) are separate repos with their own conventions, and there branches
  are correct.
- **`dispatching-parallel-agents`, `subagent-driven-development`** assume spawning subagents. The operating
  instructions for this project say not to use the Agent tool or workflows unless the user asks for it. Do not
  invoke these on my own initiative; suggest one if a task genuinely warrants it and let the user decide.
- **`test-driven-development`** assumes a unit-test suite. There isn't one. The analogue here is the
  **Validation workflow** (`helm lint` → `helm template` → `kubeconform` → `oc diff`) and, for upstream work,
  actually running `build_containers` / `make bundle` / `opm validate` before claiming a change works. Apply the
  spirit — demonstrate the failure, then demonstrate the fix — not the letter. The 2026-09-09 cert-manager PR is
  the model: `opm validate` was shown failing on the unfixed graph *and* passing on the fixed one.

**`using-superpowers`** is the meta-index for finding the others. **`writing-skills`** only applies when
authoring a new skill.

## Upstream PRs and comments

Every upstream PR is opened with `--draft` and stays draft — marking it ready and merging are the user's calls.
Write the change plainly: what changed, why, how it was checked; no debugging narrative. **Load the `upstream-pr`
skill (`.claude/skills/upstream-pr/SKILL.md`) before drafting any upstream PR, issue or comment** — it holds the
full writing rules.

## Commit and branch conventions

- Commit directly to `master` — ArgoCD watches it. No feature branches and no PRs for this repo; the only branches are upstream-contribution clones and the parked `cert-manager-helm-fallback`.
- Commit messages: `<scope>: <imperative summary>` — e.g. `cert-manager: bump to v1.16.2`, `root-app: add monitoring stack`, `storage: enable fd-b zone`.
- One logical change per commit. The rendered-manifest diff should be predictable from the message alone.
- Renovate PRs (label `dependencies`) are reviewed, not rewritten.

## Communication preferences

- Be concise and technically precise. Skip hedging, flattery, and recap of what I just said.
- Surface trade-offs honestly. If there's a simpler or more idiomatic approach than what I asked for, say so before implementing.
- When proposing a change, include the exact commands to validate it locally.
- Cite OKD, Helm, ArgoCD, or cert-manager docs by version when version-specific behavior matters.
- Prefer a short correct answer with one follow-up question over a long answer that guessed at my intent.
- **If something is unclear, ask — don't assume.** When a request, an unpicked option, or a fact I can't verify
  leaves more than one reasonable reading, stop and ask before acting on it. A "go ahead" covers what was
  actually decided, not a choice I left open: on 2026-09-24 I offered "replace the GitHub MCP server or drop
  it", got "go ahead", and dropped it without asking which.

## MCP servers

`.mcp.json` declares one project-scoped MCP server, launched via `npx` when Claude Code starts in this repo.

- **`kubernetes`** (`mcp-server-kubernetes@4.1.7`, pinned) — structured `kubectl_get` / `kubectl_describe` / `kubectl_logs` / `explain_resource` / `list_api_resources` tools. It runs as the **readonly `claude-reader` SA** (`KUBECONFIG_PATH=${HOME}/.kube/config-readonly`), so it keeps working when the operator's OAuth login expires. `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS=true` only removes the delete-type tools; `kubectl_apply`, `kubectl_patch`, `kubectl_scale` and `exec_in_pod` are still listed, and the SA's RBAC is what refuses them. That SA can read Secrets — never read a secret value through it either. Verified 2026-09-24: the server listed the three nodes while `oc whoami` on the operator kubeconfig returned `Unauthorized`.
- **GitHub: use `gh`, not an MCP server.** `@modelcontextprotocol/server-github` was removed 2026-09-24 — npm marks it deprecated ("Package no longer supported"), last release 2025.4.8. `gh` is not logged in on this workstation, so pass the token inline: `GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN" gh …`. Upstream cross-referencing works the same way (`gh issue view -R <owner>/<repo> <n>`, `gh search issues …`).

For mutations against the cluster (apply/delete/patch/scale, etc.), still go through the user.

Permissions: `.claude/settings.json` is tracked (since 2026-09-24) and holds the read-only allowlist plus the **guardrail deny list** — `oc`/`kubectl` mutating verbs in both `oc <verb>` and `oc -n <ns> <verb>` forms, `helm install/upgrade/uninstall/rollback`, `argocd app sync`, `gh pr merge/ready/review/close`, force-push/hard-reset, the token-printing `oc whoami -t` / `oc config view --raw`, and reads of kubeconfigs/`.env`/secrets. Deny beats allow, and a deny rule matches past a leading `KUBECONFIG=…` assignment. `.claude/settings.local.json` stays untracked (git, gh reads, ssh, WebFetch domains, MCP tool approvals). Editing either file from a session is blocked by auto mode as self-modification — the user applies settings changes.

## Reviewing open PRs (`sudoom/homelab`)

Check open PRs at session start and whenever a dependency PR is relevant, and give **APPROVE / HOLD / NOT-APPROVE**
per PR with a one-line reason. Storage version bumps (Rook, Ceph) default to NOT-APPROVE. I advise; the user merges.
Verdict rules and the `gh` commands: `cluster-health` skill.

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

- **Session start: run the `cluster-health` skill before the first real work** — health sweep (readonly
  kubeconfig), open-PR verdicts, firing-alert triage. A dirty sweep or an actionable alert blocks the requested work
  until it is surfaced.

- **Before proposing anything that might already exist, check the docs first.** Re-reading at session start (above) isn't enough — when you're about to suggest "we should ship X" or "let's add Y", grep `blog/`, `CLAUDE.md`, `README.md`, `MEMORY.md`, and the relevant `components/<area>/` first. The 2026-06-08 incident: I proposed shipping CNPG `barmanObjectStore` as a follow-up — when CNPG-native backup had already been shipped 2026-05-18 with a passing 2026-05-20 restore drill, fully documented in `blog/blog-cnpg-draft.md`. The user shouldn't have to be the verifier-of-last-resort that I read what they already wrote down. Specifically: any "we should add Z" or "follow-up: ship Z" claim is a search trigger — `grep -ri "Z" blog/ CLAUDE.md README.md components/` before saying it. Same applies for "this isn't done yet" / "this is missing" / "we need to think about" — if the docs say it's done, it's done; trust the docs over your own model.

## Ending a session ("call it")

On "call it", "wrap up", "end of session" or similar, run the `cluster-health` skill's wrap-up before saying goodbye:
(1) docs drift — README TODO, CLAUDE.md, chart READMEs, blog drafts; (2) repo cleanup; (3) the cluster health sweep,
expected clean. Each pass is its own commit. End with a one-paragraph session ledger (commits + final state).

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

This repo's `.claude/settings.json` whitelists `Read(~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notatki/**)`; the vault's `.claude/settings.json` whitelists `Read(~/Projects/homelab/**)`. **Absolute paths in a permission rule need `~/` or `//` — a single leading `/` is relative to the project root.** Both files used `/Users/…` until 2026-09-24, so none of those rules ever matched, including the vault's `ask` rule meant to guard `Personal/**` edits. **One `Read(path)` rule covers every file-reading tool (Read, Glob, Grep) — separate `Glob(path)`/`Grep(path)` entries are no-ops** and Claude Code warns about them at startup (they were removed here 2026-07-27). Native Read works on absolute paths in both directions — no MCP needed for cross-repo reads.

### Downstream: the published blog (sudops.pl)

The `blog/*-draft.md` files in this repo are the **upstream raw material** for the public homelab blog at **[sudops.pl](https://sudops.pl)** — repo `/Users/vadzimdziadziulia-laptop/Projects/sudops.pl` ([sudoom/sudops.pl](https://github.com/sudoom/sudops.pl), Astro).

- Pipeline: this repo's `blog/*-draft.md` (raw session chronology) → `sudops.pl/posts/*.md` (gitignored raw draft) → `sudops.pl/src/content/blog/*.mdx` (published).
- The blog repo reads THIS repo for ground truth (manifests, versions, commands) and the vault for the "why". You don't push to the blog from here — keep the drafts current per the "Blog notes" rule above; the blog repo pulls from them.
- Same secret-hygiene rule applies: drafts feed a public site, so never put real tokens/keys/kubeconfigs in `blog/*-draft.md`.
