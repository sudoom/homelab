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
| OKD             | 4.20           | Kube API ≈ upstream 1.31                                              |
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

## Storage (Rook-Ceph)

The cluster's storage is **Rook-managed Ceph Squid (19.2.3)**. The operator is shipped via the upstream `rook-ceph` Helm chart; the `CephCluster` CR + pools + StorageClasses are vendored as raw manifests under `components/storage/` (not the `rook-ceph-cluster` subchart yet — see TODO). Suggestions and changes around storage need to respect the constraints below.

### Topology

- **3 OSDs total**, one per node, each on a single NVMe device. Failure domain is `host` (the failure-domain labels are `fd-a/fd-b/fd-c`, one per node).
- **No drain headroom.** Any rolling change to OSDs (rebuild, encrypt-at-rest, redeploy) goes through a degraded window — there is no fourth node to absorb the missing OSD. Plan accordingly: schedule during quiet IO, never run two OSD-impacting changes at once, never propose `oc cordon node{4,5,6}` without an explicit ask.
- **Mons:** 3-of-3, one per node. Same topology constraint applies.
- **Network:** Frontnet (VLAN 5) for clients; storage backnet (VLAN 10, 192.168.10.2-4) for OSD ↔ OSD replication. Multus migration in flight (2026-05-11): NADs + per-node macvlan host-shim (`ceph-shim`, IPs `.16/.17/.18`) shipped, pod range shifted to `192.168.10.128/25` with an explicit `/25 dev ceph-shim` route for the kernel-RBD-client hairpin fix. **CephCluster spec flip + mon/OSD roll still pending** (degraded-window event). Full design + ops history in `blog/blog-multus-ceph-migration-draft.md`. **Don't touch `enp1s0f0np0`, `ceph-shim`, or `192.168.10.0/24` routing without checking that draft first** — the routing setup is load-bearing: `/24 master metric 100`, `/24 shim metric 410`, `/25 dev shim static`. Reordering or simplifying breaks pod↔host reachability.

### Hardware: 3× Samsung PM9A1 512GB

- Migration from PNY CS1030 → PM9A1 completed 2026-05-07. Per-OSD `kv_commit_lat` dropped from ~95 ms (worn PNY lifetime) to ~3 ms (PM9A1). `BLUESTORE_SLOW_OP_ALERT` cleared and stays clear at the new hardware. Full chronology + bottleneck sweep in `blog/blog-rook-ceph-draft.md`.
- For future drive purchases at this cluster scale, stay on PM9A1-class consumer NVMe — full PLP enterprise (Micron 7450 PRO etc.) is not justified by the workload. The bottleneck post-swap is replication-amplification at `size=3`, not per-drive fsync latency.

### Pools and pg_num

- Primary pool: `nvme-replicated` (`size=3`, `min_size=2`, CRUSH rule on `device_class=nvme`, `bulk: true`). Backs the only block StorageClass today (`ceph-nvme-block`, RBD provisioner).
- **Target `pg_num` is 128** for `nvme-replicated`: 100 PGs/OSD × 3 OSDs / replication 3 = 100 → next pow2 = 128. Use `pg_num_min: 128` in the BlockPool to enforce — the autoscaler is **not** applying the `bulk` hint correctly (`ceph osd pool autoscale-status` returns `[]`; root cause likely a Squid 19.2.3 quirk, tracked as an open TODO). Same quirk hit the RGW data pool on 2026-05-10; same fix shape.
- When proposing pool changes: floor with `pg_num_min`, don't disable autoscale. Don't suggest manual `pg_num` bumps unless paired with the autoscaler diagnosis.
- **`pg_num_min` chicken-and-egg:** Ceph rejects `pg_num_min > current pg_num` with `EINVAL`. Pure-GitOps `pg_num_min` enforcement requires a **one-time toolbox bump** of `pg_num` to bootstrap each new pool past 1 (`ceph osd pool set <pool> pg_num <floor>; ceph osd pool set <pool> pgp_num <floor>`); the chart's `pg_num_min` then enforces the floor going forward. Confirmed twice (`nvme-replicated` originally, RGW data pool 2026-05-10). Capture the exact toolbox commands in the topical blog draft.

### Object storage (RGW)

- **`CephObjectStore` `ceph-objectstore` shipped 2026-05-01** — chart at `components/storage/ceph-object-store/`, single RGW gateway (`gateway.instances: 1`), HTTP-only on port 80; TLS terminated at the OpenShift Route `s3.apps.okd.sudops.pl`. **In-cluster S3 clients should use the in-cluster Service `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80`** — bypasses Route + edge TLS, faster + more reliable.
- **Pool tiers:** `metadataPool.deviceClass: nvme` permanently; `dataPool.deviceClass: nvme` interim, flips to `hdd` when bulk drives land (single-line CRUSH-rule change in `values.yaml`; rebalance is automatic, RGW endpoint + bucket names + client config unchanged).
- **`pg_num_min: "32"` floored on the data pool** (commit `32b2e64`); metadata pool stays at the chart-default 8 PGs (it's tiny and not on the hot path).
- **Active consumers:** Loki (33+ GiB / 53k+ chunks in `ceph-objectstore.rgw.buckets.data` as of 2026-05-10). OADP queued; CNPG `barmanObjectStore` will land on the same RGW with a separate `CephObjectStoreUser` per cluster.
- **Bucket-creds plumbing precedent:** Loki's `logging-stack` chart uses an `ObjectBucketClaim` + secret-translator pattern to land RGW credentials in a SealedSecret-shaped Secret. Reuse that pattern for OADP / CNPG / future S3 consumers — don't ship `CephObjectStoreUser` + manual SealedSecret.
- **Toolbox gotcha:** `radosgw-admin user list` / `bucket list` from the toolbox default to the orphan `default` zone (a leftover from RGW first-bring-up; cosmetic-cleanup TODO). Real data lives in the `ceph-objectstore` zone — pass `--rgw-realm=ceph-objectstore --rgw-zonegroup=ceph-objectstore --rgw-zone=ceph-objectstore` to inspect it, or just look at `ceph-objectstore.rgw.*` pools in `ceph df`.

### CephFS plan (not yet shipped)

- **Two storage classes** against a **single `CephFilesystem` CR** — not two filesystems.
- One filesystem with metadata pool on NVMe and **two `dataPools` entries**: `deviceClass: nvme` (low-latency RWX) + `deviceClass: hdd` (bulk RWX).
- Two `StorageClass` objects against the same filesystem, differing only in the `pool` parameter.
- **Sequencing:** the NVMe SC can ship before HDDs land — no HDD dependency for the NVMe tier. The HDD SC waits on bulk HDDs being added to the chassis.
- Don't propose pure-NVMe CephFS as the long-term answer; the two-tier shape is the chosen plan.

### RBD CSI quirks

- The CSI driver does **deferred delete**: PVC removal calls `rbd trash mv`, not `rbd rm`. Trashed images keep consuming pool space until purged. Manual purge in 04/2026 reclaimed ~600 GiB.
- Need a periodic `rbd trash purge schedule` (use Ceph's built-in scheduler, not a CronJob — it lives in mgr config).
- Occasionally an image refuses removal with `image has watchers` — usually a stuck CSI nodeplugin attachment; investigate the node, don't force-delete the image.
- **`operation already exists` mount lock can outlive plugin restarts.** When `NodeStageVolume` hangs (e.g., kRBD waiting on an unreachable OSD), the rbd-plugin's in-memory operation tracker locks the volume ID. Every retry returns `rpc error: code = Aborted desc = an operation with the given Volume ID ... already exists`. Restarting the rbd-nodeplugin pod usually clears the lock — but if the underlying cause (network unreachable, msgr2 silent drop) persists, the new plugin will hit the same hang on the first retry. **Don't chase the lock; chase what's keeping the first call stuck.** Check `/sys/bus/rbd/devices/` on the host via `oc debug node/<name>` — empty = the hang is in plugin userspace, not kernel.
- **Stuck VolumeAttachments need finalizer force-clear.** When CSI mount fails repeatedly, VAs accumulate with the `external-attacher/rook-ceph-rbd-csi-ceph-com` finalizer and `attached: true` even though no mount succeeded. If the PV is also gone (e.g., test PVC deleted), normal `oc delete` hangs forever. Unstick: `oc patch volumeattachment <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`. Same pattern can affect `rook-ceph-mon-endpoints` ConfigMap / `rook-ceph-mon` Secret after teardown — same force-clear works.
- **Orphan Released PVs block the csi-provisioner cluster-wide.** When CSI's `DeleteVolume` for a PV fails (e.g., earlier mount regression left an unfinishable rbd image), the PV stays `Released` and the provisioner re-attempts deletion forever. CSI plugins serialize operations cluster-wide, so a stuck DeleteVolume blocks every new CreateVolume too — symptom looks identical to the "operation already exists" lock from the per-volume tracker, but the cause is a different volume's stuck deletion. **Before applying any test PVC, check for orphan Released PVs**: `oc get pv | grep Released`. Clear them with `oc patch pv <name> -p '{"metadata":{"finalizers":[]}}' --type=merge && oc delete pv <name>`. Also clear any stale VolumeAttachments to the now-gone PV. The "stuck VA + stuck PV" duo can survive plugin restarts, controlplugin restarts, and operator restarts — must be manually cleared.
- **Fresh-bootstrap workaround: `client.csi-rbd-provisioner.<gen>` is missing its `osd` cap.** On every fresh `CephCluster` bootstrap, Rook 1.19.5 generates the CSI provisioner user (`client.csi-rbd-provisioner.1` on first bootstrap; suffix increments on key rotation) with **only** `mgr "allow rw"` + `mon "profile rbd, allow command 'osd blocklist'"` — no `osd` cap. CSI then authenticates fine but every `CreateVolume` hangs on the first RADOS op → gRPC `DeadlineExceeded → CANCEL` → "operation already exists" lock storm. The companion users (`csi-rbd-node.1`, both cephfs users) get correct caps; only the RBD provisioner template is buggy. **Confirmed Rook bug, filed locally at `bugs/upstream-rook-csi-rbd-provisioner-missing-osd-cap.md`.** Until upstream lands a fix, every fresh bootstrap needs this three-step workaround before the first PVC will bind:
  ```
  # 1. Fix the caps
  oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph auth caps client.csi-rbd-provisioner.1 \
      mgr "allow rw" \
      mon "profile rbd, allow command 'osd blocklist'" \
      osd "profile rbd"

  # 2. If a PVC was already attempted, clear orphan CSI omap state.
  # The failed CreateVolume leaves a half-written entry that re-triggers
  # "operation already exists" even after plugin restart.
  oc -n rook-ceph exec deploy/rook-ceph-tools -- rados -p nvme-replicated listomapkeys csi.volumes.default
  # → for each csi.volume.pvc-<uuid> key, read its value (the orphan UUID),
  #   then `rmomapkey` + `rm csi.volume.<orphan-uuid>`.

  # 3. Restart the rbd-csi ctrlplugin to clear the in-memory tracker
  oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-ctrlplugin
  ```
  After all three steps, the queued PVC binds within seconds. If a key rotation later creates `csi-rbd-provisioner.2`/`.3`, the same `ceph auth caps` needs to be re-run against the new generation suffix.

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
# 1. Rook's mon-tracking state (causes "detecting the ceph image version" hang on next bootstrap):
oc -n rook-ceph delete cm rook-ceph-mon-endpoints rook-ceph-pdbstatemap --ignore-not-found
oc -n rook-ceph delete secret rook-ceph-mon --ignore-not-found
# These usually need finalizer force-clear because Rook's finalizer can't reconcile against a deleted CR:
oc -n rook-ceph patch cm rook-ceph-mon-endpoints -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
oc -n rook-ceph patch secret rook-ceph-mon -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null

# 2. Bootstrap Jobs from previous cluster (immutable; ArgoCD can't re-apply, blocks sync):
# Every bootstrap Job in the rook-ceph-cluster chart is fair game here. As of
# 2026-05-15 there are TWO: rbd-trash-purge-schedule-bootstrap +
# csi-rbd-provisioner-caps-fix-bootstrap. Add new ones as the chart grows.
# The error you see if you skip this:
#   error when replacing "...": Job.batch "<name>" is invalid:
#   [spec.selector: Required value, spec.template.metadata.labels: Invalid value: ]
oc -n rook-ceph delete job rbd-trash-purge-schedule-bootstrap --ignore-not-found
oc -n rook-ceph delete job csi-rbd-provisioner-caps-fix-bootstrap --ignore-not-found
oc -n rook-ceph delete jobs -l rook-ceph-cleanup --ignore-not-found  # any cluster-cleanup-job-* still around

# 2b. Stuck Ceph CR finalizers — Rook's finalizer can't reconcile its own
# delete after the operator stops watching (which happens once the CR enters
# `Deleting` phase or once the operator pod is gone). Force-clear:
oc -n rook-ceph patch cephcluster rook-ceph -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
oc -n rook-ceph patch cephobjectstore ceph-objectstore -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
for bp in $(oc -n rook-ceph get cephblockpool -o name 2>/dev/null); do
  oc -n rook-ceph patch $bp -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 2c. Stale ObjectBuckets from prior cluster — these are cluster-scoped
# (objectbuckets.objectbucket.io) and survive RGW teardown. On a fresh
# bootstrap, the new OBC reconcile fails with:
#   "obc \"<name>\" bucketName has changed compared to ob \"<obc-ns-name>\""
# Operator log on rook-ceph-operator. Loki, OADP, CNPG OBCs stay Pending
# forever. Force-clear:
for ob in $(oc get objectbucket -o name 2>/dev/null); do
  oc patch $ob -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  oc delete $ob --ignore-not-found 2>/dev/null
done
# IMPORTANT: if the OBC also already exists (e.g., ArgoCD recreated it
# between the OB delete and now), the bucket-provisioner will recreate
# a new OB but record the OLD OBC's UID in its claimRef — perpetual
# mismatch loop. Delete the OBC too in the same step:
for obc in $(oc get obc -A --no-headers 2>/dev/null | awk '{print "-n "$1" "$2}'); do
  : # The for-loop construction above is wrong for namespaced OBC,
    # so handle the specific OBC names you know about (the Helm
    # charts in this repo create: logging-stack/loki, oadp/oadp once
    # OADP ships, etc.). Pattern per OBC:
done
oc -n openshift-logging patch obc loki -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
oc -n openshift-logging delete obc loki --ignore-not-found 2>/dev/null
# Then ArgoCD re-creates the OBC + the bucket-provisioner creates a
# fresh OB, UIDs match, OBC reaches Bound on the next reconcile.

# 2d. Stale clientprofiles.csi.ceph.io — blocks rook-ceph namespace
# termination on operator chart removal. Symptom in ns status:
#   "Some resources are remaining: clientprofiles.csi.ceph.io has 1 resource instances"
# Force-clear:
for cp in $(oc -n rook-ceph get clientprofiles.csi.ceph.io -o name 2>/dev/null); do
  oc -n rook-ceph patch $cp -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 3. Orphan PVs (Released or Failed status) — block csi-provisioner cluster-wide:
for PV in $(oc get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' | grep ceph-nvme); do
  oc patch pv $PV -p '{"metadata":{"finalizers":[]}}' --type=merge
  oc delete pv $PV --ignore-not-found
done

# 4. Orphan VolumeAttachments referencing now-gone PVs:
for VA in $(oc get volumeattachment -o name); do
  oc patch $VA -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 5. Test-namespace PVCs still around from prior runs:
oc -n default get pvc 2>/dev/null | awk 'NR>1 && $4=="ceph-nvme-block" {print $1}' | xargs -r -I {} oc -n default patch pvc {} -p '{"metadata":{"finalizers":[]}}' --type=merge

# 6. CSI plugin in-memory state — kill all 6 plugin pods, fresh start (operator recreates):
oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-nodeplugin --wait=false
oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-ctrlplugin --wait=false
oc -n rook-ceph delete pod -l app=rook-ceph.cephfs.csi.ceph.com-nodeplugin --wait=false
oc -n rook-ceph delete pod -l app=rook-ceph.cephfs.csi.ceph.com-ctrlplugin --wait=false

# 7. Bounce the rook-operator so it reconciles from a truly clean slate:
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

### Pre-flight for any change that might trigger an MCO master-pool reroll

Anything that changes `MachineConfig` content (directly or transitively via `Network/cluster`, `KubeletConfig`, `APIServer/cluster.spec.encryption`, etc.) triggers a serial reboot of all 3 masters. On this 3-OSD no-drain cluster that's a 30-45 min degraded window per attempt with multiple compounding failure modes. **Audit the change for transitive MachineConfig generation before applying** — render the operator's expected MC and diff it against current. Specific gotchas surfaced 2026-05-20:

- **OVN-K `Network/cluster` IPsec mode change DOES trigger an MCO reroll** (kernel modules + NetworkManager IPsec service install). The CR field looks small; the MachineConfig delivery is what costs you.
- **OVN-K MTU change does NOT (empirically, 2026-05-21).** Setting `defaultNetwork.ovnKubernetesConfig.mtu` (with or without the documented `spec.migration.mtu.{network,machine}` declare/clear dance) produces operator-side MC reconciles, but the resulting rendered MC converges to the SAME `rendered-master-…` name the cluster was on pre-change. The MCO events fire but cycle nodes without delivering any actual MachineConfig delta. MTU is a runtime-only knob (OVN-K reconfigures the geneve interface MTU directly). For future OVN-K MTU changes, consider `oc patch network.operator/cluster …mtu` directly without the migration field — verify on a smaller cluster first.
- **PDBs with `MinAvailable: N` where current replicas == N block ALL voluntary evictions.** The `logging-loki-ingester` PDB has MinAvailable=2 hardcoded in LokiStack; we run 2 replicas → 0 disruption budget → MCO drain stuck forever. The LokiStack CRD does NOT expose PDB tunables. Before any MCO event, verify `oc get pdb -A` ALLOWED DISRUPTIONS column has at least 1 for every pool — if not, fix that first or accept the manual force-delete-pod workaround during drain.
- **RGW + router anti-affinity contention on a 3-node cluster.** Routers default to 2 replicas with anti-affinity; RGW has `requiredDuringSchedulingIgnoredDuringExecution` against routers. When 2 routers occupy 2 nodes, only 1 node is router-free for RGW. If that node is the one being drained, RGW becomes unschedulable cluster-wide → Loki S3 puts fail → ingester readiness loops. Either scale routers to 1 pre-MCO-event or accept the cascade.
- **Cross-node host-network can break between mismatched-MC nodes during IPsec rollouts.** Empirically observed 2026-05-20: `openshift-apiserver` on the post-IPsec-reboot node couldn't reach etcd on host-network IPs (`192.168.1.{7,9}:2379`) of the still-old-MC nodes. Root cause TBD; do not re-attempt IPsec without diagnosing this.

If a MachineConfig-class change is unavoidable, schedule it with 2+ hour headroom, not after-hours. Storage chaos compounds with MCO chaos rapidly.

**Pre-flight runbook for any MCO event** (added 2026-05-21 after the second IPsec/MTU cascade re-tripped the same chain):

1. Scale `openshift-operators-redhat/loki-operator-controller-manager` to 0. The `loki-pdb-override` 5-min CronJob loses the race against operator reconciles during drain, blocking eviction; scaling the operator to 0 holds the PDB at `MinAvailable: 1` throughout.
2. Scale `openshift-ingress-operator` `IngressController/default` to `replicas: 1`. With 2 routers + RGW anti-affinity, every node-drain stranddes RGW. Reducing to 1 router ensures RGW always has a target node.
3. Apply the change. Monitor MCP master with `oc get mcp master -w`.
4. **During the rollout**, watch for stuck VolumeAttachments via `oc get volumeattachment | awk '$5=="true" && /node[X]/'` — RBD VAs frequently stay bound to the previous node after pod move. Force-clear via `oc patch volumeattachment <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`.
5. **After MCP `Updated=True`**, restart all 3 `ovnkube-node` pods one at a time (`oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node`). Pod-to-host-network egress consistently breaks across MCO events; restart restores it. Symptom: ArgoCD apps show `sync=Unknown` because repo-server can't reach github.com.
6. Restart `openshift-gitops` repo-server pod (`oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-repo-server`). Resolves the `DeadlineExceeded` on manifest generation that always lingers after the cluster has been thrashed.
7. Restore: scale `loki-operator` back to 1, `IngressController` back to 2, trigger one-shot run of `loki-pdb-override` CronJob to re-patch PDB if loki-operator has reconciled it.

Skipping any of these steps re-trips the cascade — observed 2026-05-20 (IPsec) and 2026-05-21 (MTU).

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

## Session hygiene

- Before the context window is compacted, run `/export` to preserve the full conversation.
- When diagnosing a live issue, paste real `oc` / `argocd` output into chat rather than describing it — diagnoses from raw output are much better than from paraphrase.
- **At session start and immediately after a context compaction**, re-read the markdown files that carry working state, in this order — don't rely on the post-compaction summary alone:
  1. `CLAUDE.md` (this file) — rules may have tightened since the snapshot.
  2. Any `blog/blog-*-draft.md` files relevant to the work in flight — these are the chronological notes for what was tried, what worked, and what's still open.
  3. The TODO list at the bottom of `README.md` — confirm what's still queued vs. shipped.
  4. Auto-memory `MEMORY.md` (loaded automatically) plus the linked memory files — re-skim before assuming a remembered fact still holds.

  Compaction summaries are lossy by design; the markdown is the source of truth.

- **Always run the cluster health sweep before the first real work in a new session.** Same procedure as the end-of-session sweep documented under "Ending a session" below (nodes / ArgoCD apps / CSVs / certificates / restart outliers / non-Running pods / Ceph health). Reason: starting work on a stale assumption about cluster state is how the 2026-05-13 RGW outage went unnoticed for 21h — bounding that to "one session length" requires *both* end-of-session and start-of-session checks. A clean sweep is one line in the first reply ("cluster sweep clean: HEALTH_OK / 31 apps Synced+Healthy / no outliers"); a dirty sweep blocks the user's requested work until investigated — even if the symptom looks unrelated, surface it before proceeding. Use the readonly kubeconfig (`KUBECONFIG=~/.kube/config-readonly`).

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