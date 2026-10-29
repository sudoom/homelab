# OKD 4.20 → 4.21 → 4.22 upgrade — planning & runbook (draft)

Working notes for the OKD minor-version upgrade campaign. Goal stated by the operator:
reach **4.22**. OKD upgrades are **sequential by minor** (Cincinnati only ever offers the
adjacent minor), so the path is mandatorily **4.20 → 4.21 → 4.22** = Kubernetes
**1.33 → 1.34 → 1.35** (mapping: OKD `4.N` → Kube `1.(N+13)`). Two full all-node-reboot
windows, each with this cluster's complete blast radius (OVN-egress cascade, no-drain
3-OSD/3-mon degraded window, the LokiStack `MinAvailable=2`-with-2-replicas PDB blocker).

The upgrade *trigger* is **not** GitOps-managed and must not be — see "Why not a Helm chart"
below. Trigger stays an explicit `oc adm upgrade --to=…` operator action; this repo carries
the runbook + a `bin/` pre/post-flight helper + the one genuinely-GitOps change (catalog tag).

## Current state (captured 2026-06-11)

- Cluster: `4.20.0-okd-scos.17`, channel `stable-scos-4`, upstream = origin releases CI graph.
- OS: **CentOS Stream CoreOS 10** (RHEL10 lineage), kernel `6.12.0-142.el10`. cri-o 1.34.
- Offered targets in-channel: `4.21.0-okd-scos.0 … .11` (latest `.11`); `4.22.0-okd-scos.0/.1/.2` exist.
- Operator preference: **z-1** each hop (`4.21.0-okd-scos.10`, `4.22.0-okd-scos.1`) pending Slack/release-notes check.
- Hardware NICs (per node, identical chassis):
  - Backnet 10G (Ceph OSD↔OSD): Mellanox **ConnectX-4 Lx** `[15b3:1015]`, driver `mlx5_core`, **firmware 14.32.2004**.
  - Frontnet 1G (kubelet, br-ex): Intel **I219-LM** `[8086:15f9]`, driver `e1000e`.

## Compatibility matrix (workflow `okd-4.22-compat-matrix`, 2026-06-11, 19 agents, adversarially verified)

Binding constraint per component: clear **both** Kube 1.34 (4.21 intermediate) **and** 1.35 (4.22 destination).

| Component | Deployed | 1.34 | 1.35 | Verdict |
|---|---|---|---|---|
| Rook-Ceph operator + Ceph | **v1.19.5 / Squid 19.2.4** (Rook reverted from v1.20.0 on 2026-06-12 — v1.20 broke CSI, see `blog/blog-rook-ceph-draft.md`) | ✅ | needs-upgrade | Rook 1.19 covers Kube v1.30–**v1.35** (the floor) → 1.34 (4.21) **OK**, but **1.35 (4.22) is the exact TOP of the window, zero slack** — the "zero headroom at 1.35" concern is **OPEN, not resolved** (the v1.20.0 bump that would have given headroom was attempted and reverted for the CSI breakage). A supervised Rook bump to a CSI-coherent v1.20.x+ is required *before* the 4.22 hop. Ceph 19.2.4 was kept. Upstream-Helm delivery → not catalog-gated. |
| cert-manager-operator | v1.18.0 (okderators, alpha) | ⛔ | ⛔ | **BLOCKER both hops.** 1.18 EOL 2026-03-10, caps at Kube 1.33. → bump 1.20.2. |
| OpenShift GitOps (Argo CD) | v1.19.0 (Argo CD 3.1.x) | ✅ | ⛔ | 4.22-blocker (no GitOps release documents OCP 4.22 yet). Engine is fine; it's support-matrix/catalog paperwork. Bump to the 4.22-listing release (likely 1.21.x) on 4.21 first. |
| loki-operator + cluster-logging | v6.5.0 (okderators) | ✅ | needs-upgrade | **Currently DEGRADED on 4.20** — clear first. 6.5 in-matrix for 4.21; 4.22 needs Logging 6.6 (unreleased). okderators #44 OPEN. **Corrected 2026-10-20:** 6.5 covers 4.22 too, and 6.6 is released: Red Hat's operator update checker lists 6.5.3 (maxOCP 4.22) and 6.6.1 (maxOCP 4.23) on 4.20, 4.21 and 4.22 alike. The gate for this cluster is okderators, whose 4.22 index stops at 6.3.0. |
| OADP (Velero) | v1.5.0 (Velero 1.16) | ✅ | needs-upgrade | 1.5 caps at 4.21. → stable-1.6 channel (Velero 1.18) on 4.21 first. Backups paused → low-risk to bump early. |
| kubernetes-nmstate | v0.86.0 | ✅ | ✅ | Built against k8s 1.35 libs. **operatorhubio rolling index → NOT catalog-gated.** |
| CloudNativePG | v1.29.1 | ✅ | ✅ | 1.29.x adds 1.35. Outside OLM. (Upstream doesn't officially test OpenShift — posture note.) |
| grafana-operator | v5.24.0 | ✅ | ✅ | Built against k8s 1.36 libs. |
| sealed-secrets | 0.37.0 (chart 2.18.6) | ✅ | ✅ | In 1.33/1.34/1.35 CI. Key rotation disabled → Cloudflare SealedSecret stays valid. Back up the sealing-key Secret as insurance. |
| Kube built-in API surface | — | ✅ | ✅ | No served-API removals at 1.34/1.35 (last was flowcontrol v1beta3 at 1.32). VolumeAttributesClass GA at 1.34 (addition). |
| **OS / NIC drivers** | SCOS 10 / 6.12 | ✅ | ✅ | **CLEARED** — see driver gate below. |

### The two hard GATES (independent of the cluster itself)

**1. okderators catalog supply-chain — BLOCKS HOP 1.** `quay.io/okderators/catalog-index`
has **no `:4.21` and no `:4.22` tag** as of 2026-06-11 (only `4.20`/`testing-4.20`, `4.19`,
`4.18`, `4.15`); the GitHub repo has no `release-4.21`/`release-4.22` branch (newest
`release-4.20`, rebuilt 2026-06-04). The CatalogSource is pinned per-OKD-minor, so a 4.21
cluster references a tag that does not exist → OLM resolution stalls for **cert-manager**
(which issues every `*.apps` + api serving cert) and for **loki/logging**. okderators issue
**#44** (logging/loki not yet 4.21-compatible) is OPEN. okderators publishes a minor's tag
*well after* that OKD minor GAs (4.20 tag landed ~2026-06-04 for a Sept-2025 minor) → expect
significant lag; **re-verify the tag exists immediately before each hop.**
*Durable de-risk:* migrate cert-manager (and any load-bearing okderators operator) **off
okderators** to upstream sources — removes the cadence dependency entirely.

**2. NIC driver / OS layer — CLEARED for both hops (verifier refuted=false).** Not a
kernel-major jump: 4.20=`6.12.0-142.el10`, 4.21=`6.12.0-180.el10`, 4.22=`6.12.0-212.el10`,
all CentOS Stream CoreOS 10, kernel 6.12 LTS, z-stream only. RHEL9→10 cutover already
happened at 4.20. `mlx5_core`/ConnectX-4 Lx fully in-tree (only mlx4/ConnectX-3 removed in
RHEL 10); in-tree firmware floor 14.21.1000 → deployed **14.32.2004 clears it comfortably**,
firmware-mismatch trap does NOT apply; neither the -180 nor -212 kernel forces newer firmware.
`e1000e`/I219-LM supported on both. No OKD 4.20/4.21/4.22 release-note mentions any
mlx5/Mellanox/e1000e regression. **Operational guardrail (prior NIC-regression history):**
capture `ethtool -i` baseline per node before each hop (expect `mlx5_core` fw 14.32.2004 on
`enp1s0f0np0`, `e1000e` on the I219-LM iface); after each per-node reboot, re-run + confirm
clean bind with no `firmware version mismatch` / `reduced functionality` / `health
compromised` dmesg warnings, and verify backnet 10G link + Ceph HEALTH_OK before the next node.

## Recommended sequence

Operator/catalog readiness gates the cluster hop — **never advance the platform with a
downstream operator out of matrix.** One minor at a time, no skipping.

**PRE-HOP-1 (on 4.20, before touching the platform):**
1. Clear the loki/cluster-logging **Degraded** state on 4.20; confirm both Healthy on identical 6.5.0. (Root cause not yet diagnosed — may surface an unrelated issue.)
2. Resolve the okderators gap for cert-manager: **migrate cert-manager off okderators** (upstream OLM bundle or Helm chart) — recommended, removes the dependency — *or* wait for `:4.21` to publish with a 1.34-usable channel.
3. Bump cert-manager to **1.20.2** (NOT 1.19.0 — re-issuance bug; NOT 1.20.0 — OpenShift issuer-finalizer RBAC blocker; 1.20 covers Kube 1.32→1.35 so one bump clears both hops). Alternatively wait for cert-manager **1.21** (GA ~2026-06-24, maps Kube 1.33→1.36). Verify `oc get certificate -A` all Ready=True. Cloudflare DNS-01 solver config unchanged.
4. Recommended: bump OpenShift GitOps to **1.20.4** (Argo CD 3.3, also matrixed to 4.21).
5. Audit for `groupsnapshot.storage.k8s.io/v1beta1` VGS objects (**none expected** here) and confirm the live Rook v1.19.5 serves the VGS CRD at **v1beta2** (4.21 removes v1beta1 outright — distribution-specific; upstream only deprecates). Blast radius limited: CNPG backs up via the GA `snapshot.storage.k8s.io/v1` `ceph-rbd-snapshot` class, unaffected.
6. Run `kubent`/`pluto` over rendered manifests + `kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis` (expect zero hits).
7. Confirm all 3 nodes **cgroup v2**; capture the `ethtool -i` NIC baseline.

**HOP 1 (4.20 → latest 4.21 z-stream `…scos.11` / Kube 1.34):** reaching `.11` is effectively
required — the 4.22 upgrade edges are tested from `.11`. Treat as a 3-OSD no-drain
degraded-window event: gate on Ceph HEALTH_OK, schedule quiet-IO with 2+ h headroom, never
overlap another OSD-impacting change. **Per node reboot:** run the network pre-flight (scale
`loki-operator`→0, `IngressController`→1, watch/force-clear stuck VolumeAttachments, restart
**ALL 3** `ovnkube-node` + repo-server after each node settles, sweep cert-manager). Verify
`modprobe rbd` on the new kernel; verify mlx5/e1000e bind clean (driver guardrail above).

**POST-HOP-1 / PRE-HOP-2 (on 4.21):** verify cert-manager (1.20.2 already covers 1.35),
nmstate, CNPG, grafana, sealed-secrets, Rook all Healthy. Then bump the 4.22-blockers **on
4.21 first**: (a) GitOps → the OCP-4.22-documenting release (likely 1.21.x) — broken GitOps =
zero reconciliation, hard gate; (b) Logging → the 4.22-listing release (expected 6.6); (c)
OADP → stable-1.6 (Velero 1.18) + green backup/restore drill; (d) confirm a 4.22 okderators
tag (or alternative source) AND community-operators v4.22 index carry these bundles. Re-run
the deprecated-API sweep.

**HOP 2 (4.21 → 4.22 / Kube 1.35):** only after all four operator bumps land + verify on 4.21.
Re-confirm cgroup v2 (**a cgroup-v1 node hard-fails kubelet on 1.35 = a lost OSD on this
no-drain topology**). Same degraded-window discipline + per-node network pre-flight as Hop 1.
**DEFER** — see freshness below.

**BEFORE the 4.22 hop (OPEN):** bump Rook to a CSI-coherent **v1.20.x+** to clear the zero-headroom-at-1.35 cap. The 2026-06-12 Renovate auto-bump to v1.20.0 **was attempted and reverted** (v1.20's CSI ServiceAccount rename broke CSI — `blog/blog-rook-ceph-draft.md`), so this is a real open prerequisite, to be done supervised + version-coherent (operator + cluster charts together, `helm dependency update`, `oc diff` the CSI delta), *not* via Renovate.

### 4.22 freshness verdict: DEFER

4.22 exists only as `.0` (2026-05-11), `.1`, `.2` (2026-06-02) — ~4 weeks old. No okd.io
release-notes/known-issues page yet; 4.22 SCOS upgrade-edge CI shows flaky
failed-then-retried jobs; the two key downstream operators (GitOps for 4.22, Logging 6.6)
have no release documenting 4.22 yet. For a single bare-metal cluster with load-bearing
Rook-Ceph and zero drain headroom: **land on 4.21 now** (after pre-hop-1 fixes), then **sit on
the latest 4.21 z-stream** until 4.22 gains z-streams (~`scos.4+` + a published release-notes
page) AND GitOps/Logging 4.22-capable releases ship and are confirmed in their catalogs.

## Why not a Helm chart for the upgrade

The upgrade *trigger* must not be GitOps-managed:
- **selfHeal would fight a paused/stalled upgrade.** `ClusterVersion.spec.desiredUpdate` under the always-on root-app means an `oc adm upgrade --clear` to pause a stuck rollout (a *when*, not *if*, given the OVN cascade + no-drain Ceph) gets reverted within minutes.
- **A commit would become a cluster-wide upgrade** on next sync — the opposite of the "upgrade event, not routine edit" guardrail.

Version-controlled artifacts instead: this runbook; a `bin/okd-upgrade-preflight.sh` /
`-postflight.sh` for the *imperative, transient* steps that must NOT be GitOps (scale
`loki-operator`→0, `IngressController`→1, then restore); and the one genuinely-GitOps change —
the okderators `CatalogSource` image tag bump, applied as a normal commit *after* the control
plane is on the new minor (IF staying on okderators rather than migrating cert-manager off it).

## Residual risks (carry forward)

- okderators 4.21/4.22 tag could land with little lead time or never ship 4.22 — the cert-manager-off-okderators migration is the durable de-risk but is itself a non-trivial change to the operator backing all TLS; stage + verify independently of the hops.
- okderators #44 (logging/loki not 4.21-compatible) OPEN — a 4.21 tag may still ship unusable logging channels.
- Logging 6.6 + the GitOps OCP-4.22 release are UNRELEASED — the 4.22 hop is gated on releases that don't yet exist; minimums can't be pinned authoritatively.
- loki/cluster-logging is DEGRADED on 4.20 with root cause not yet diagnosed — clear + understand before any hop.
- OADP 1.6 GA tracks 4.22 — confirm the 1.6 bundle is actually PRESENT in the 4.22 community-operators index at upgrade time.
- **Rook v1.19.5 at the exact top of its window (Kube 1.35) with zero slack — OPEN.** The v1.20.0 bump that would have given headroom (Kube 1.31–1.36) was attempted via Renovate #134 and **reverted 2026-06-12** because v1.20 broke CSI (`blog/blog-rook-ceph-draft.md`). So a supervised, version-coherent Rook upgrade to a CSI-working v1.20.x+ remains a hard prerequisite for the 4.22 (Kube 1.35) hop. (Ceph 19.2.4 from #133 was kept.) Lesson logged: **Renovate must not auto-merge Rook/Ceph** — these need manual, compatibility-checked, re-vendored-together bumps.
- VGS v1beta1 removal at 4.21 — low blast radius (none used) but confirm Rook's bundled sidecar emits only v1beta2.
- CNPG upstream doesn't officially test OpenShift — runs fine but technically unvalidated on 4.21/4.22.
- Each per-node reboot (6 across the two hops) re-trips the OVN-egress + RBD-VA cascade and can re-expose the DDF false-etcd-alert symptom — operational, compounding on a no-drain cluster.

---

## Re-assessment 2026-09-08 (three months on) — hop 1 is now unblocked, hop 2 is not

The June plan's verdict was "land 4.21 after pre-fixes, defer 4.22". Re-verifying every gate against the live
cluster and the upstream catalogs today: **that verdict holds, but the reasons have moved.**

### The gate that cleared

**`quay.io/okderators/catalog-index:4.21` now EXISTS** — published **2026-07-13**, a month after the June capture.
The repo's default branch is now `release-4.21`. This was hop 1's #1 blocker and the reason the June plan pushed
migrating cert-manager off okderators as a "durable de-risk".

```
4.21          Mon, 13 Jul 2026 14:15:00
testing-4.21  Fri, 19 Jun 2026 11:37:43
4.20          Mon, 13 Jul 2026 14:17:21
4.22          — DOES NOT EXIST
```

**`:4.22` still does not exist.** So hop 2 remains hard-blocked at the supply-chain layer, exactly as predicted,
and the DEFER verdict for 4.22 stands on its own merits regardless of the operator matrix.

Caveat worth carrying: **okderators issue #44** ("logging-operator and loki-operator have to be updated to be
compatible with 4.21") is **still OPEN**, last touched 2026-05-14 — two months *before* the 4.21 tag was built. The
tag existing is not proof the logging bundles in it resolve. Verify by resolution, not by tag presence.

### The other gate that cleared, quietly

The June plan's pre-hop-1 step 1 was "clear the loki/cluster-logging **Degraded** state; root cause not yet
diagnosed". Today `oc get co` returns **zero** operators not `Available=True / Progressing=False / Degraded=False`.
It cleared at some point in the intervening months, root cause never established. Recording that honestly: this is
a blocker that went away rather than one that was fixed, so it could come back.

### What is still blocking hop 1

**cert-manager is still `v1.18.0`** — EOL since 2026-03-10, caps at Kube 1.33. It is the one unchanged hard
blocker, and it issues every `*.apps` and API serving cert. Bump target unchanged: **1.20.2** (not 1.19.0
— re-issuance bug; not 1.20.0 — OpenShift issuer-finalizer RBAC blocker), or 1.21.x if it has since GA'd.

### Two things the June plan could not have known

**1. The okderators dependency is WIDER than the plan says.** Five of eight subscriptions resolve from it:

```
cert-manager-operator   alpha  okderators   Automatic
gitops-operator         alpha  okderators   Automatic     <- ArgoCD itself
cluster-logging         alpha  okderators   Automatic
loki-operator           alpha  okderators   Automatic
oadp-operator           alpha  okderators   Automatic
```

The June draft framed this as a cert-manager and logging problem. **`gitops-operator` is on it too** — which means
a broken catalog on the new minor takes out the resolution path for the operator that runs the entire app-of-apps.
Installed CSVs keep running on a stale catalog, so this is not an instant outage; but it means no operator can be
*upgraded* on 4.21, which is precisely what the plan requires before hop 2.

**Also: every one of the eight is `installPlanApproval: Automatic`.** That is a live hazard during a multi-hour
upgrade window — an operator can auto-advance mid-hop, unsupervised, while the platform is in motion. The README
already carries a TODO to switch CNPG to Manual; the evidence it was right is that **CNPG has since auto-advanced
1.29.1 → 1.30.0** with nobody deciding to. We survived only because the barman-cloud *plugin* path was chosen over
in-tree `barmanObjectStore` — the exact scenario that choice was made for. Broaden the TODO: the load-bearing
subscriptions should be Manual **before** either hop.

**2. The storage blast radius has changed in both directions, because of the 2026-09-07/08 decommission.**

*Smaller:*
- **The RGW/router `:80` anti-affinity drain blocker is GONE** — the object store is retired. The June runbook's
  "only 1 router-free node for RGW" constraint no longer exists.
- **The CephFS stale-globalmount recovery hazard is GONE** — CephFS is retired.
- **3 OSDs instead of 6** — each per-node reboot has half the OSD surface to bring back.
- **Loki's chunks and Velero's backup target moved off Ceph to TrueNAS garage.** A Ceph problem during an upgrade
  no longer takes out logging and backups at the same time. That is a genuine, material improvement in upgrade
  safety, and it happened for unrelated reasons.

*Larger, and this is a NEW prerequisite the June plan does not contain:*

```
ceph_pool_max_avail{nvme-replicated}   92.58 GB  =  86.2 GiB
ceph_pool_stored  {nvme-replicated}   407.34 GB  = 379.3 GiB   -> ~81.5% full
```

**The NVMe pool is at ~81.5% with ~86 GiB free, and Ceph's `nearfull` trips at 85%.** The reboot itself does not
consume capacity — with failure domain `host` across exactly three hosts, a downed OSD cannot backfill anywhere, so
PGs sit `undersized` at 2/3 and serve at `min_size=2` without a rebalance storm. The risk is subtler: an upgrade is
a multi-hour window of continued normal writes, and **crossing 85% mid-hop does not break the cluster, it breaks
the signal you are steering by.** The runbook's per-node discipline is "gate on Ceph HEALTH_OK before touching the
next node". A pool that goes `nearfull` on its own makes HEALTH_WARN permanent and that gate meaningless.

So: **reclaim NVMe capacity before hop 1**, not as general hygiene but as an upgrade prerequisite. Levers, in
order: verify `node-fstrim` is actually returning freed RBD blocks, then audit the CNPG `ceph-rbd-snapshot` 7d
snapshots (`rbd du` showed 246 GiB allocated against 377 GiB pool-stored).

### Gates re-verified clean today

- **cgroup v2 (the Kube 1.35 hard gate):** `nodes.config.openshift.io/cluster` has `cgroupMode` unset = default,
  and the nodes run **CentOS Stream CoreOS 10** (`10.0.20251023-0`). RHEL 10 lineage **removed cgroup v1 support
  entirely**, so this gate is structurally satisfied rather than merely configured — a cgroup-v1 node is not
  constructible on this OS. Still worth an explicit check immediately before hop 2.
- **Deprecated APIs:** the only entry in `apiserver_requested_deprecated_apis` is
  `{group="", resource="endpoints", version="v1", removed_release=""}` — deprecated in favour of EndpointSlice but
  with **no removal release scheduled**. Zero blocking usage.
- **VolumeGroupSnapshot:** the June plan worried about `groupsnapshot.storage.k8s.io/v1beta1` being removed at
  4.21. The CRDs actually present are **`groupsnapshot.storage.openshift.io`** — a different API group,
  OpenShift-managed, serving `v1beta1` only, with **0 objects** in use. Different group, zero blast radius either
  way. The concern as written did not apply.
- **Available targets:** `4.21.0-okd-scos.4 … .11` offered in `stable-scos-4`; no 4.22 edge is offered from 4.20,
  which is Cincinnati behaving correctly (adjacent minor only).

### Revised sequence

**PRE-HOP-1 (on 4.20), in dependency order:**
1. **Reclaim NVMe capacity below ~75%** — new, and the one that gates the health signal. (fstrim → CNPG snapshots)
2. **Bump cert-manager 1.18.0 → 1.20.2** — the sole unchanged hard blocker. Verify `oc get certificate -A` all
   `Ready=True` afterwards; Cloudflare DNS-01 solver config unchanged.
3. **Switch load-bearing subscriptions to `installPlanApproval: Manual`** — at minimum gitops, cert-manager, CNPG,
   Rook-adjacent. Prevents an unsupervised operator advance inside the upgrade window.
4. **Confirm the 4.21 catalog actually resolves** logging/loki/gitops/oadp bundles (okderators #44 still open —
   test resolution, do not trust the tag).
5. Capture the `ethtool -i` NIC baseline per node; re-confirm cgroup v2.
6. **Bundle the `core` SSH-key MachineConfig** into this hop — it is an MCO reroll either way, and the README
   TODO explicitly says not to spend a standalone reroll on it.

**HOP 1 → `4.21.0-okd-scos.11`.** Unchanged discipline: network pre-flight per node, restart ALL 3
`ovnkube-node` + repo-server after each node settles, gate on Ceph HEALTH_OK between nodes, verify mlx5/e1000e
bind clean and the backnet 10G link before proceeding. Now materially safer than the June plan assumed: no RGW
scheduling constraint, no CephFS, half the OSDs, and logging/backups no longer sharing fate with Ceph.

**THEN SIT ON 4.21.** Hop 2 stays deferred, and now for a cleanly stateable reason: **`okderators:4.22` does not
exist.** Re-check that tag as the single trigger condition. Alongside it, the June prerequisites still stand —
a supervised, version-coherent **Rook bump to a CSI-working v1.20.x+** (v1.19.5 sits at the exact top of its Kube
window at 1.35, zero slack), plus GitOps/Logging releases that document 4.22.

---

## HOP 1 EXECUTED 2026-09-08 — 4.20 → 4.21.0-okd-scos.11

```
started   ~17:54   Working towards 4.21.0-okd-scos.11: 71 of 970 done (7%)
completed  19:29   history[0]: Completed 4.21.0-okd-scos.11 @ 2026-09-08T17:29:32Z
elapsed   ~95 min, of which ~20 was a single drain block
result    3/3 nodes Ready on v1.34.6 (Kube 1.34), zero degraded ClusterOperators
```

Note the pre-hop-1 checklist from the September re-assessment was **not** completed first — the capacity reclaim
and the cert-manager bump were both outstanding when the upgrade started. Neither turned out to be a stopper, for
reasons worth stating: Ceph had ~86 GiB of real headroom and a reboot consumes none of it on a 3-host failure
domain, and cert-manager degrades at *renewal* rather than at cutover. That was luck confirming a judgement, not a
vindication of skipping the list.

### What the runbook predicted vs what happened

| Predicted risk | Outcome |
|---|---|
| LokiStack `MinAvailable=2` PDB blocks the drain | **Did not fire.** All loki PDBs sat at `allowed=1` throughout — the `loki-pdb-override` CronJob is doing its job |
| `br-ex.forwarding` zeroed by each node reboot | **Never fired.** All three nodes read `1` after every reboot |
| Backnet NIC returns `linkdown` | **Did not fire** — including node6, which did exactly that on 2026-07-25 |
| RGW vs router `:80` scheduling squeeze | Gone; the object store was retired 2026-09-07 |
| — not predicted — | **A single-instance CNPG cluster blocked the drain for ~20 minutes** |

The `br-ex.forwarding` non-event deserves a note rather than a shrug. CLAUDE.md records it as reliably zeroed by a
reboot, confirmed three times on 2026-09-08 itself. The likely reconciliation: a full node reboot also restarts
`ovnkube-node`, which re-asserts the sysctl on start, whereas the cases that broke were NetworkManager reapplies
*without* a restart (a switch flap, a frontnet blip). The rule is probably better stated as **"an event that
changes host addresses without restarting ovnkube-node"** rather than "a reboot".

### The blocker nobody listed: single-instance CNPG

```
E0908 17:08:56 drain_controller: error when evicting pods/"immich-postgres-1" -n "immich"
  (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
...
E0908 17:17:16 Drain has been failing for more than 10 minutes. Waiting 5 minutes then retrying.
```

```
immich-postgres   instances=1  primary=immich-postgres-1   (on node6)
PDB               minAvailable=1  disruptionsAllowed=0  currentHealthy=1
```

CNPG creates a `minAvailable: 1` PDB over the primary. With **`instances: 1` there is no replica to fail over
to**, so the budget can never be satisfied and the eviction can never succeed — it retries forever. `media-postgres`
went through untouched because it runs 3 instances and CNPG simply moves the primary.

CLAUDE.md already described these two PDBs as "structural... permanently 0 by construction" and correctly noted
they "do NOT block draining a node that holds a *replica*". What it did not say is the corollary: **for a
single-instance cluster every node is the primary's node**, so it blocks unconditionally. That is the gap.

Fix was `oc -n immich delete pod immich-postgres-1` — CNPG recreated it on node4 (node6 being cordoned), the drain
resumed, and Immich's DB was down for about the length of one pod start. Two smaller lessons from doing it:

- The delete took **>120 s** (graceful Postgres shutdown + RBD unmount), long enough that the drain controller hit
  its 10-minute failure threshold and backed off to a 5-minute retry. The unblock is therefore not instant — expect
  to wait one backoff cycle after the pod moves.
- `oc` failed with `Unauthorized` at exactly the wrong moment: the `authentication` operator had updated during the
  upgrade and one `oauth-openshift` replica was `Pending` on the cordoned node. **This is what the break-glass
  kubeconfig is for** — it is an SA token, not OAuth, so it kept working throughout.

**Before hop 2:** either scale `immich-postgres` to 2 instances (needs NVMe headroom this cluster does not
currently have) or plan the pod deletion as an explicit runbook step. It will recur.

### Transient degradations that are NOT faults

Two things went `Degraded` mid-upgrade and cleared on their own; both are worth recognising rather than chasing:

- **`network`**, with `ApplyOperatorConfig: could not apply ClusterRole /multus-ancillary-tools: ... read tcp
  192.168.1.8:43802->192.168.1.240:6443: read: connection reset by peer`. `.240` is the API VIP; the reset is the
  VIP moving during the node cycle. `Available=True`, `Progressing=False`, all OVN pods fully ready.
- **`kube-apiserver` / `kube-controller-manager` / `kube-scheduler`**, all with
  `NodeControllerDegraded: The master nodes not ready: node6 not ready`. That is the three operators reporting the
  node that is mid-reboot, not a fault in any of them. `etcd` stayed `Available=True, Degraded=False` — quorum held
  at 2/3 throughout, which is the only one that would have mattered.

The API also blanked briefly on each drain (an `oc get nodes` returning nothing, and the `Unauthorized` above).
On a 3-node cluster every node is control-plane, so each drain removes an apiserver and can move the VIP. Expect
one blip per node.

### The catalog flip delivered nothing — and this changes the plan

With the control plane on 4.21, `quay.io/okderators/catalog-index` was bumped `4.20` → `4.21` (and the platform
moved `community-operator-index` to `v4.21` by itself). Both went `READY`. **Zero InstallPlans were generated**, and
the reason is that the 4.21 catalog is not newer:

```
cert-manager-operator   alpha head = v1.18.0-2025-12-25   <- IDENTICAL to installed
gitops-operator         alpha head = v1.19.0-2026-02-07   <- identical
cluster-logging         alpha head = v6.3.0-2025-08-08    <- OLDER than the installed v6.5.0
```

That last line is okderators issue #44 ("logging-operator and loki-operator have to be updated to be compatible
with 4.21", still open) showing up as a fact rather than a caveat. Nothing downgrades — OLM only walks the upgrade
graph forward, and every okderators subscription had been switched to `installPlanApproval: Manual` an hour
earlier — but the tag is not a source of operator upgrades.

**The consequence is the important part: the cert-manager bump is not reachable from any catalog on this cluster.**

```
okderators (4.21)          cert-manager-operator  v1.18.0   <- installed, caps at Kube 1.33
community-operators v4.21  cert-manager           v1.16.5   <- older
operatorhubio :latest      cert-manager           v1.16.5   <- older
```

cert-manager 1.18 is EOL and supports Kube ≤ 1.33; the cluster is now on 1.34. The September plan's step 2 ("bump
to 1.20.2") assumed a catalog would carry it. None does. So the June draft's "durable de-risk" — *migrate
cert-manager off okderators* — is no longer optional or merely tidier; **it is the only route**, and it now points
at the upstream Helm chart rather than a different catalog.

How much time that leaves, measured rather than guessed:

```
cert-manager pods            3/3 Running, 0 restarts   (survived the hop on Kube 1.34)
certificates                 5/5 Ready=True
barman-cloud-{client,server} renews 2026-09-10   <- 2 days; internal CA, low risk
homelab-wildcard             renews 2026-09-21   <- 13 days; FIRST ACME renewal, the real test
api-cert / okd-wildcard      renews 2026-10-06
```

So the canary is the 09-10 internal-CA renewal, and the meaningful deadline is **2026-09-21**, the first
Let's Encrypt DNS-01 renewal on an out-of-matrix cert-manager. It is running fine today; the risk is that renewal
exercises code paths a steady-state pod does not.

## 2026-10-22 — cert-manager 1.20 and the nmstate workflow merged upstream

Maintainer SupremeMortal merged three okd-operator-pipeline PRs today: #33 `[nmstate] Add deploy workflow for
release-4.21` (approved, 13:18Z), #28 `[cert-manager] Update to 1.20` on `main` (13:19Z) and #29 on `release-4.21`
(13:20Z). The logging PRs #35-#38 are still open with no reviews.

```
gh pr list -R okd-project/okd-operator-pipeline --state all --author @me
gh run list -R okd-project/okd-operator-pipeline
gh run view <id> --log-failed
```

- "Deploy Cert-Manager" on `release-4.21` (run 39785980679): success. It pushed
  `quay.io/okderators/cert-manager/operator-bundle:1.20.0-2026-10-22-132146`
  (sha256:71a5c372b229da8195f50249f4a43f23711bf56f97d1c8b2651bc4f117ef6cc4). That workflow has no catalog job.
- Bundle CSV `cert-manager-operator.v1.20.0-2026-10-22-132146`: `olm.skipRange: '>=1.0.0 <1.20.0-2026-10-22-132146'`,
  no `replaces`, minKubeVersion 1.31.0. I read it from the image through the quay.io v2 registry API: anonymous
  pull token, manifest, then the layer tar.
- "Deploy Cert-Manager" on `main` (run 39785787379): build succeeded (bundle `1.20.0-2026-10-22-132017`), but its
  "Catalog Index PR" job failed checking out okderators-catalog-index branch `release-5.0`, which does not exist.
  Already known: `main` has built OKD 5.0 since 2026-09-23. `release-4.22` still sets `OKD_VERSION=4.22.0-okd-scos.2`.
- nmstate: no "Deploy NMState" run. Its `release-4.21` workflow triggers only on a push touching `nmstate/**` or a
  manual `workflow_dispatch`, and #33 only added the workflow file. A maintainer has to run it by hand.
- `okderators-catalog-index` `release-4.21` and `release-4.22`: the `alpha` channel head in
  `catalog/cert-manager-operator/cert-manager-operator.yaml` is still `cert-manager-operator.v1.18.0-2025-12-25-214537`
  (identical files).

Next: a catalog-index PR adding the 1.20 bundle file and a channel entry
`name: cert-manager-operator.v1.20.0-2026-10-22-132146`, `replaces: cert-manager-operator.v1.18.0-2025-12-25-214537`
(not filed, no fork of the catalog repo yet). After it merges and `catalog-index:4.21` is rebuilt, the cluster gets a
Manual InstallPlan for 1.20 (the subscription is `installPlanApproval: Manual`), which the operator approves.

### Later the same day — the catalog-index PRs

Forked `okderators-catalog-index` to `sudoom/` and filed two drafts:
[#60](https://github.com/okd-project/okderators-catalog-index/pull/60) on `release-4.21` and
[#61](https://github.com/okd-project/okderators-catalog-index/pull/61) on `release-4.22`. Each is one commit, 2 files,
+132/-1: the bundle file plus the `alpha` entry replacing `cert-manager-operator.v1.18.0-2025-12-25-214537`, which is
exactly the CSV installed here (`oc get subscription -A` → channel `alpha`, source `okderators`, Manual).

- The bundle file is `opm render quay.io/okderators/cert-manager/operator-bundle:1.20.0-2026-10-22-132146 -o yaml`
  (opm v1.74.0, darwin-arm64 release binary), written as `hack/add-bundle.sh` does. The method reproduces the
  committed `1.18.0-2025-12-25-214537` file byte for byte. The maintainer's open #59 changes how that script reads
  the bundle name, not its output.
- `opm validate catalog` passes on both branches; the `alpha` head moves from `v1.18.0-2025-12-25-214537` to
  `v1.20.0-2026-10-22-132146` and every earlier entry reaches it. Negative control, bundle file without the
  channel entry: `bundle "cert-manager-operator.v1.20.0-2026-10-22-132146" not found in any channel entries`.
- One bundle for both catalogs: the pipeline's `release-4.22` branch never got the 1.20 bump, so 4.22 takes the
  `release-4.21` build. I decoded the embedded manifests of that bundle and of the `main` build (`…132017`, which
  targets OKD 5.0): identical apart from dates, digests and `relatedImages` order, same image set, no `okd-scos`
  reference anywhere.
- The catalog repo's only workflow, `deploy-catalog.yml`, runs on push to `release-*` (and by hand): it builds
  `catalog.Containerfile` (`opm serve --cache-only`) and pushes `catalog-index:<branch minus release->`. Nothing
  runs on a PR.

Next: the maintainer reviews #60/#61. After #60 merges, the `okderators` CatalogSource picks up the rebuilt
`catalog-index:4.21` within its 60-minute `registryPoll`, and a 1.20 InstallPlan appears for approval.

## 2026-10-22 — hop 2 re-assessed

The README said the hop "needs re-assessing against this list, not starting" once `catalog-index:4.22` existed
(pushed 2026-10-15). Done today, against live state.

**The platform side blocks nothing.**

```
oc get clusterversion version -o jsonpath='{.status.availableUpdates[*].version}'
4.22.0-okd-scos.10 … 4.22.0-okd-scos.0          # 11 edges from 4.21.0-okd-scos.11, channel stable-scos-4
```

ClusterVersion carries no `Upgradeable` condition, no ClusterOperator reports `Upgradeable=False`, and
`openshift-config-managed/admin-gates` is empty. No installed CSV declares an `olm.maxOpenShiftVersion` below 4.22:
the two logging 6.6 test-build CSVs say `4.23`, and the others declare none (the okderators OADP 1.5.0 build
included). So neither CVO nor OLM would refuse the hop; everything left is support-matrix work.

**Gates, re-checked:**

| Item | Now | For 4.22 (Kube 1.35) |
|---|---|---|
| cert-manager | 1.18.0, caps at Kube 1.33 | 1.20 supports 1.32-1.35. Catalog PRs #60 (4.21) / #61 (4.22) filed today. #61 must land before the `okderators` CatalogSource flips to `:4.22`, or the installed 1.20 CSV is missing from the new index. |
| Rook | v1.19.5 | `prerequisites.md` per tag: v1.19.12 supports Kube **1.30-1.35** (zero headroom), v1.20.9 **1.31-1.37**, v1.21.0 1.32-1.37. The June v1.20.0 CSI break was our own chart incoherence (`Chart.yaml` bumped by Renovate, charts never re-vendored, and v1.20 renamed the CSI ServiceAccounts), not a Rook defect, so the fix is a supervised, coherent bump of both charts and the operator together. It rolls all three OSDs. |
| OADP | 1.5.0 (okderators), daily Velero schedule to garage | **Post-hop, not pre-hop** (see below). Red Hat offers 1.5.8 on 4.20/4.21 and only 1.6.x on 4.22. Both okderators catalogs offer only 1.5.0, and the 4.22 one needs 1.6. |
| GitOps | 1.19.0, Argo CD 3.1.11 | Both catalogs offer only 1.19.0; the pipeline pins `MINOR=19`. (Corrected below: Argo CD 3.1 is tested up to 1.34, not on 1.35.) |
| Logging / Loki | 6.6 test build from zot | Fine for the hop: `maxOpenShiftVersion` 4.23, and the test catalog does not depend on the OKD version. The okderators route is pipeline #35-#38. |
| NVMe pool | was 81.5% full (2026-09-08) | `ceph_pool_stored` 242.2 GB vs `ceph_pool_max_avail` 246.1 GB, about 50%. Cleared. |
| CNPG, subscriptions | both clusters 2 instances; okderators subs Manual | Cleared (2026-09-15 and 2026-09-08). |
| descheduler, CNPG, nmstate, grafana-operator | v0.36.0, 1.30.1, 0.87.0 (community), 5.25.0 | No known issue at 1.35. |

**Runbook-day items that are new or still open:**

- Ceph sits at a permanent `HEALTH_WARN`: `MON_DISK_LOW` on mon c (node5's root disk) plus the BlueStore slow-op
  warning. The runbook gates each node on `HEALTH_OK`, which cannot be met. Either fix node5's disk first (README
  TODO "Stop the catalog image churn that fills node5": step 1 in git now, step 2 the KubeletConfig with the next
  node roll, which this hop is) or restate the gate as "no warning beyond the known two".
- SSH to the nodes still fails (README TODO). The hop is an MCO reroll anyway, so the `core` key MachineConfig
  belongs in it; without it a node that does not come back has no host access.
- Unchanged: the network pre-flight, `ethtool -i` NIC baseline, cgroup v2 re-check, restarting all three
  `ovnkube-node` plus the repo-server afterwards, then the `okderators` CatalogSource flip `:4.21` → `:4.22`.

Order: cert-manager 1.20 (#60, then approve the InstallPlan) → Rook coherent bump → the hop → OADP 1.6 from the
4.22 catalog. GitOps 1.20+ is a choice between a pipeline contribution and accepting the gap.

### OADP: the order is the hop first, then 1.6

The operator checked Red Hat's operator update checker (`access.redhat.com/labs/ocpouic/?operator=redhat-oadp-operator`,
upgrade path 4.20 → 4.22), channel `stable`:

```
OCP 4.20   current 1.5.8   (1.5.0 … 1.5.7)
OCP 4.21   current 1.5.8   (1.5.0 … 1.5.7)
OCP 4.22   current 1.6.1   (1.6.0)
```

1.6 is not in the 4.21 index and 1.5 is not in the 4.22 index, so the only path is: hop on 1.5, then 1.6 from the 4.22
catalog. The June matrix's "stable-1.6 channel on 4.21 first" was wrong. Upstream agrees on the edge:
`openshift/oadp-operator` `oadp-1.6` head is CSV 1.6.2 with `olm.skipRange: '>=1.5.0 <1.6.2'`, so any 1.5.x moves
straight to it. Neither branch's CSV sets `minKubeVersion` or `olm.maxOpenShiftVersion`; the OCP mapping lives only
in Red Hat's index. 1.6 brings Velero 1.18.4 (`k8s.io/api` v0.33) over 1.5's Velero 1.16.2 (v0.31).

okderators side: all three pipeline branches (`release-4.21`, `release-4.22`, `main`) pin every `oadp/*` submodule
to `oadp-1.5`, and the operator gitlink is `5520b16` (2026-02-26) on all three, 82 commits behind `oadp-1.5` head
(1.5.8):

```
gh api repos/openshift/oadp-operator/compare/oadp-1.5...5520b16ab3fc9f75280c729125ff39b2a97b8ba8
  -> behind  behind_by=82  ahead_by=0
```

So the contribution is two-part, mirroring Red Hat: `release-4.22` moves OADP to `oadp-1.6` (12 submodules, plus
whatever `oadp/build.sh` and `oadp/patches` need), and optionally `release-4.21` moves its gitlinks to `oadp-1.5`
head for 1.5.8. Then a catalog-index PR on each branch, as with cert-manager.

### GitOps: not a hop gate

Same checker, `openshift-gitops-operator`, upgrade path 4.20 → 4.22: every OCP version carries channels `gitops-1.6`
through `gitops-1.22` plus `latest` (default), and `latest` is **1.22.2 on 4.20, 4.21 and 4.22 alike**. The
`gitops-1.19` channel is still in the 4.22 index. Unlike OADP, nothing ties a GitOps minor to an OCP minor here, so
the 1.19 → 1.2x bump can land before or after the hop.

What each GitOps release builds, from `rh-gitops-midstream/release` `config.yaml` and the `sources/argo-cd` gitlink
resolved against `argoproj/argo-cd` `VERSION`:

```
release-1.19   Argo CD v3.1.16   (we run 1.19.0 = v3.1.11)
release-1.20   Argo CD v3.3.17
release-1.21   Argo CD v3.4.12
release-1.22   Argo CD v3.5.6
```

The pipeline still sets `MINOR=19` in `gitops/build.sh` and tracks `gitops/release` → `release-1.19` on
`release-4.21`, `release-4.22` and `main`. The target is a judgment call left open: 1.20 keeps the Argo CD jump to
two minors (3.1 → 3.3) and is the oldest release in Argo CD's tested table; 1.22 is current but crosses four Argo CD
minors' upgrade notes in one OLM step, on the operator that runs ArgoCD itself.

Revised order: cert-manager 1.20 → Rook coherent bump → the hop → OADP 1.6. GitOps runs on its own track.

### Correction, same day: Argo CD's tested table makes GitOps a pre-hop item

The two GitOps notes above lean on a claim carried since 2026-09-09, "Argo CD 3.1 is outside the tested matrix", read
off the docs site. That page only shows the newest Argo CD minors (it says "use the version selector"); each tag
carries its own `docs/operator-manual/tested-kubernetes-versions.md`:

```
gh api "repos/argoproj/argo-cd/contents/docs/operator-manual/tested-kubernetes-versions.md?ref=<tag>"
v3.1.11 / v3.1.16   3.1  v1.34, v1.33, v1.32, v1.31
v3.3.17             3.3  v1.35, v1.34, v1.33, v1.32
v3.4.12             3.4  v1.35, v1.34, v1.33, v1.32
v3.5.6              3.5  v1.36, v1.35, v1.34, v1.33
```

| GitOps | Argo CD | Kube 1.34 (4.21, now) | Kube 1.35 (4.22) | Kube 1.36 (4.23) |
|---|---|---|---|---|
| 1.19 (ours: 1.19.0) | 3.1.11 / 3.1.16 | tested | not tested | not tested |
| 1.20 | 3.3.17 | tested | tested | not tested |
| 1.21 | 3.4.12 | tested | tested | not tested |
| 1.22 | 3.5.6 | tested | tested | tested |

Two corrections follow. Today, on Kube 1.34, ArgoCD 3.1.11 is inside its tested matrix; the September finding was a
misreading. And GitOps **is** a 4.22 prerequisite after all: 3.1 is untested on 1.35, and 1.20 or 1.21 is tested on
both sides of the hop, so the bump belongs on 4.21 before it. Red Hat's index (1.22.2 on 4.20-4.22, `gitops-1.19`
kept on 4.22) does not force the order; Argo CD's matrix does. Of the four, 1.22 is the only one that also covers 4.23,
but it bundles Helm v4.2.4 (README re-check of 2026-10-20), a rendering change for every chart here, so 1.20 or 1.21 is
the first target.

Order, corrected: cert-manager 1.20 → GitOps 1.20/1.21 → Rook coherent bump → the hop → OADP 1.6.

## 2026-10-27 — cert-manager 1.20 installed

The maintainer merged okderators-catalog-index #60 (`release-4.21`, 16:03:43Z) and #61 (`release-4.22`, 16:03:49Z).
`deploy-catalog.yml` rebuilt both indexes (runs 40537179681 and 40537375524, success). The `okderators` CatalogSource
polled at 16:08:36Z, and the Subscription went `UpgradePending` with InstallPlan `install-g5zzp`, which named only
`cert-manager-operator.v1.20.0-2026-10-22-132146`.

Read-only checks before approval:

- InstallPlan steps: the new CSV and its RBAC, the 7 existing cert-manager CRDs updated, and three new CRDs
  (`trustmanagers.operator.openshift.io`, `istiocsrs.operator.openshift.io`, `bundles.trust.cert-manager.io`).
  Nothing is deleted.
- The CSV, decoded from the unpack ConfigMap in `openshift-marketplace` (binaryData, `olm.contentEncoding:
  gzip+base64`, base64 twice before gunzip): `minKubeVersion: 1.31.0`, `olm.skipRange: '>=1.0.0
  <1.20.0-2026-10-22-132146'`. All five images are referenced by digest and exist on quay with an amd64 manifest
  (`skopeo inspect --raw`): `okderators/cert-manager/{operator,cert-manager,acme-solver,istio-csr}` single-arch
  amd64, and `jetstack/trust-manager` (0.20.3) multi-arch.
- The CertManager CR `cluster` keeps `controllerConfig.overrideArgs` (the DNS-01 recursive nameservers) from git.
  All five Certificates were Ready.

The operator approved the InstallPlan in the console. The state at 16:18:58Z:

```
csv           cert-manager-operator.v1.20.0-2026-10-22-132146 Succeeded InstallSucceeded; Subscription AtLatestKnown
installplan   install-g5zzp Complete
operand       cert-manager, -cainjector, -webhook: cert-manager@sha256:56327631... (was 0077de5d...), 1/1, 0 restarts,
              started 16:16:53Z; app.kubernetes.io/version v1.20.4
args          --dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53 --dns01-recursive-nameservers-only (kept)
certmanager   every controller/webhook/cainjector condition Available=True, Degraded=False
clusterissuer letsencrypt-prod Ready=True ACMEAccountRegistered (unchanged since 2026-09-08)
certificates  5/5 Ready
apps          cert-manager-operator, cert-manager-config Synced Healthy
```

The controller logged three `"ACME client for issuer not initialised/available"` errors at 16:17:57, half a minute after
it started, and no errors after that. That is the start-up order: the ClusterIssuer's ACME client is not set up yet
when the first Certificates are queued. The controller reports `version="canary"` with an empty `git_commit`, so the
pipeline build stamps no version into the binary. That is cosmetic, and possibly worth a pipeline issue.

No renewal has run on 1.20 yet. The first is `homelab-wildcard` on 2026-11-20. The Helm fallback branch stays until
that succeeds. With cert-manager done, the remaining hop-2 item before the hop is the coherent Rook bump to v1.20.9.

## 2026-10-27 — hop 2 re-checked after cert-manager

All read-only, under the readonly SA:

```
clusterversion   4.21.0-okd-scos.11, channel stable-scos-4, no Upgradeable condition; updates up to 4.22.0-okd-scos.10
admin gates      openshift-config-managed/admin-gates empty, openshift-config/admin-acks empty
removed APIs     no apirequestcount with status.removedInRelease set
CSV caps         clusterkubedescheduleroperator.v5.3.0 max=4.22; no other CSV declares olm.maxOpenShiftVersion
rook             docker.io/rook/ceph:v1.19.5, Ceph 19.2.4
```

Rook's `Documentation/Getting-Started/Prerequisites/prerequisites.md` reads "Kubernetes versions **v1.30** through
**v1.35**" at both `v1.19.5` and `v1.19.12`, and "v1.31 through v1.37" at `v1.20.9`. So the running Rook is in matrix
for 4.22 (Kube 1.35). The earlier "Rook coherent bump before the hop" was about headroom, not support: on 1.19 the
cluster would sit at the top edge of Rook's matrix, with 4.23 (1.36) out of it. Nothing hard-blocks the hop now.
The open decision is whether the Rook bump happens before the hop (one change at a time, headroom in hand) or after
it (4.22 sooner, Rook at the edge until then).

## 2026-10-27 — HOP 2: pre-flight (4.21.0-okd-scos.11 → 4.22.0-okd-scos.10)

Decided today: the hop goes before the Rook bump (Rook v1.19.5 is in matrix for Kube 1.35), and the image-GC
KubeletConfig stays out of the hop and gets its own reroll later. Target `4.22.0-okd-scos.10` is the last 4.22
build (2026-09-09); OKD has released only 5.0 since then.

**Open OKD issues read before starting.** [okd#2339](https://github.com/okd-project/okd/issues/2339): after a 4.22
upgrade, a UEFI node stopped at `grub>` because `EFI/centos/grub.cfg` was missing. That reporter's nodes had been
migrated from FCOS (`ostree=/ostree/boot.1/fedora-coreos/...`, an `EFI/fedora` directory). Our nodes have no BMC, so
the operator checked each one (debug pod, ESP mounted read-only):

```
node4  ostree=/ostree/boot.0/scos/0498a9e7.../0  Boot0006 \EFI\centos\shimx64.efi  EFI/centos: grub.cfg bootuuid.cfg shimx64.efi grubx64.efi ...
node5  same deployment                            Boot0004 \EFI\centos\shimx64.efi  same files
node6  same deployment                            Boot0005 \EFI\centos\shimx64.efi  same files
```

All three are native SCOS installs, with no `EFI/fedora`, so this bug's precondition is absent here.
[okd#2357](https://github.com/okd-project/okd/issues/2357) (an etcd-operator `currentRevision` deadlock on scos.10) was
an install on AWS UPI where etcd could not reach its peers, stuck at revision 0; it does not match this cluster.

**Read-only gates, 16:37Z:** 3/3 nodes Ready (v1.34.6); 34 COs clean; MCP master Updated, 3/3, not paused; no
`Upgradeable=False`, no admin gates, no removed APIs in use; PDBs with 0 allowed are only the three CNPG primaries
(homebox, immich, media; each cluster runs 2 instances); LokiStack PDBs all 1; Rook PDBs `mgr=1 mon=1 osd=1`; no
pending InstallPlan; 33 VolumeAttachments; Ceph `HEALTH_WARN BLUESTORE_SLOW_OP_ALERT` only.

**zot is not at risk.** zot had 14.7 GiB free of 48.9 GiB. Its `_catalog` (read through the apiserver service proxy
under the readonly SA) has 162 repositories and no `okd/scos-content`: release images are pulled by digest, and zot
keeps no digest-only pulls. The 34 GiB in use are mostly our own `okd-test/*` and `okd-test/check-*` images
(cleanup later). `oc adm release info` was refused by the permission rules, so the payload size was not measured.

**node6's root disk was 62.5% used** (232 of 371 GB, almost all of it images; ephemeral storage was a few GB). A hop
pulls new images before the old ones are collected, and Ceph's mon warning starts at 70%. The operator pruned it:
`oc debug node/node6.okd.sudops.pl -- chroot /host crictl --timeout=600s rmi --prune` deleted 235 images, and the disk
went to 15% (55 GB). The deleted images included 4.21 `scos-content` digests and app images such as
`jellyfin:10.11.11` and `immich-server:v3.3.5`. node4 was at 44% and node5 at 15%.

**etcd backup** (operator): `oc debug -q node/node4.okd.sudops.pl -- chroot /host /usr/local/bin/cluster-backup.sh
/home/core/assets/backup` wrote `snapshot_2026-10-27_164318.db` (148 MB, revision 167562324, 9109 keys) plus the
static pod resources (kube-apiserver-pod-125, etcd-pod-11) on node4.

**Gating between nodes** comes from Rook, not from a manual pause: with one OSD down, Rook sets the other failure
domains' OSD PDB to 0, so the next node's drain waits until the PGs are clean.

**Watcher:** a readonly loop (`scratchpad/hop2/watch.sh`, every 20 s) writes one line per change in CV, bad COs,
MCP, nodes, Ceph, Rook PDBs, CNPG, NNCEs and stuck pods, and a Monitor follows that file.

## HOP 2 EXECUTED 2026-10-27 — 4.21.0-okd-scos.11 → 4.22.0-okd-scos.10

```
started    16:47:03Z   oc adm upgrade --to=4.22.0-okd-scos.10 (operator)
completed  18:10:17Z   history[0]: 4.22.0-okd-scos.10 Completed
elapsed    83 min      (hop 1: ~95 min, of which ~20 was a CNPG drain block)
result     34/34 COs on 4.22.0-okd-scos.10, none Degraded; 3/3 nodes Ready on kubelet v1.35.5 (Kube 1.35)
```

Timeline from the watcher (one line per change, readonly SA):

| time (Z) | event |
|---|---|
| 16:47:24 | CV desired 4.22.0-okd-scos.10, Progressing |
| 17:16 | 716 of 1019 done (70%), 14 of 34 COs on 4.22, none unavailable or degraded |
| 17:39:49 | MCP updating; node4 cordoned |
| 17:42:26 | osd.0 and mon a down: `OSD_DOWN`, `PG_DEGRADED` (129 PGs undersized, all active) |
| 17:46:08 → 17:48:20 | node4 rebooting → back on v1.35.5 → Ready; pool 1/3 (8.5 min cordon to Ready) |
| 17:48:45 | node5 cordoned while osd.0 was still recovering; Rook held node5's OSD |
| 17:49:55 | Ceph clean, so Rook released node5's OSD; 17:51:03 osd.1 down |
| 17:54:44 → 17:56:36 | node5 rebooting → Ready; pool 2/3; node6 cordoned |
| 17:58:34 / 17:59:41 | osd.1 caught up / osd.2 down |
| 18:03:40 | node6 drain complete after 430 s (stale VolumeAttachments, see below) |
| 18:07:04 → 18:09:19 | node6 rebooting → Ready; pool 3/3 |
| 18:10:17 | CV Completed |

**Gating worked without a manual pause.** Rook's OSD PDBs kept every drain's OSD eviction waiting until the previous
node's OSD had caught up, so only one OSD was ever down. The three CNPG clusters went 1/2 on each drain and back to
2/2 within a few minutes; their primaries switched over ahead of each drain. The mgr and the mons failed over each time.

**What slowed it down (nothing failed):**

- **zot moved twice.** zot-0 was on node4, and the node4 drain stopped it at 17:39:51. It came back on node5, and the
  node5 drain moved it to node4 (17:49:20 → Ready about 17:52). While zot was down, every pod that needs an
  `okd-test/` image and was rescheduled onto a node without it cached sat in `ImagePullBackOff`: the Loki gateway, the
  NMState and GitOps operators, and the Argo CD server, applicationset and dex pods. They had no fallback, because
  those images exist only in zot. Argo CD's application-controller and repo-server stayed up on node6 throughout.
  Pulls of mirrored images (docker.io, quay.io, ghcr.io) did not fail, but each took about 1m40s "including
  waiting": CRI-O tried zot, got `503 Service Unavailable`, then fell back to the source. More pulls than usual were
  needed because node5 (10-26) and node6 (today) had been pruned. **Next reroll: check which node zot is on, and
  expect `okd-test/` consumers to wait for it.**
- **Stale RBD VolumeAttachments cleared themselves after about 5 minutes.** zot's VA on node4 was deleting since
  17:40:03 with `attached=true`, while node4's `volumesInUse`/`volumesAttached` no longer listed the PV. It was gone
  by about 17:45 without a patch. The same happened on node6 with four media volumes (sonarr, bazarr, prowlarr,
  keepers transmission; 17:57:35-47 → cleared 18:02:18-18:03:03, `Multi-Attach error` on the replacements in
  between). node5's 14 VAs detached within a minute. The finalizer patch in the network pre-flight runbook was
  offered twice and was not needed either time. **Wait about 6 minutes before force-clearing one.**
- **OLM `ResolutionFailed` on 8 of 9 Subscriptions** right after completion: `error using catalogsource
  openshift-marketplace/community-operators: failed to list bundles: ... dial tcp 172.30.105.130:50051: connect:
  connection refused`. The marketplace catalog pod was being restarted, and OLM resolves against every global
  catalog, so one catalog's outage blocks resolution for all. The seven OLM operator apps read Degraded in Argo CD.
  All of it cleared by 18:11:55 with no action (0 `ResolutionFailed`, 53/53 Synced/Healthy).

**After the hop.** The operator read `br-ex.forwarding`: 1 on all three nodes, matching hop 1 (a reboot restarts
`ovnkube-node`, which re-asserts the sysctl). The runbook's restart of all three `ovnkube-node` pods, the repo-server
and the cert-manager controller (network-change steps 4, 5, 5b) was **skipped on the operator's decision**, because
the sysctl was 1 everywhere and every app was syncing. Ceph was back to `BLUESTORE_SLOW_OP_ALERT` only by 18:11:55.
The backnet came up on each node with its addresses and MTU 9000 (NNS), and each NNCE was re-applied and Available
within seconds of its node's handler starting.

Predicted and did not fire: okd#2339 (grub, not applicable), a CNPG drain block (2 instances everywhere), the LokiStack
PDB, a backnet NIC returning linkdown, and `MON_DOWN` from node6's disk (pruned beforehand).

## 2026-10-29 — `okderators` CatalogSource flipped to `catalog-index:4.22`

Follow-up (1) from the hop. Three Subscriptions still use `okderators`, all `installPlanApproval: Manual` and
`AtLatestKnown` before the flip:

| Namespace | Package | Installed CSV |
|---|---|---|
| `cert-manager-operator` | `cert-manager-operator` | `cert-manager-operator.v1.20.0-2026-10-22-132146` |
| `openshift-adp` | `oadp-operator` | `oadp-operator.v1.5.0-2026-01-05-165341` |
| `openshift-kube-descheduler-operator` | `cluster-kube-descheduler-operator` | `clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655` |

**What `:4.22` would deliver, checked before the flip.** `okderators-catalog-index` `release-4.22` head is `98c6d9d`
(#61, cert-manager 1.20, 2026-10-27 16:03Z), and its "Deploy Production Catalog" run for that commit succeeded at
16:04:59Z, so the `:4.22` image carries it. For all three packages the `catalog/<pkg>/` directories on `release-4.21`
and `release-4.22` hold the same files with the same git blob SHAs (6, 4 and 2 files):

```
GH_TOKEN=... gh api "repos/okd-project/okderators-catalog-index/contents/catalog/$pkg?ref=release-4.2{1,2}" \
  --jq '[.[] | "\(.name) \(.sha)"] | sort'
cert-manager-operator files=6 identical=yes
oadp-operator files=4 identical=yes
cluster-kube-descheduler-operator files=2 identical=yes
```

So the flip offers the same heads and was expected to generate no InstallPlans. It cannot move the descheduler past
its `maxOpenShiftVersion` 4.22 (follow-up 3) or bring OADP 1.6 (follow-up 1): neither build exists in okderators yet.

**Flip.** Commit `c8e3561` changed `bootstrap/phase0/01_catalog_source.yaml` to `quay.io/okderators/catalog-index:4.22`
and rewrote its comment. The live `operatorhubio-catalog` already matched the file (image `:latest`, poll 24h), so the
operator applied the whole file:

```
$ oc apply -f bootstrap/phase0/01_catalog_source.yaml
catalogsource.operators.coreos.com/okderators configured
catalogsource.operators.coreos.com/operatorhubio-catalog unchanged
```

```
12:05:40Z  okderators-jdxcm (node5, :4.21) Killing
12:05:41Z  okderators-kd8cr (node6) Pulling quay.io/okderators/catalog-index:4.22
12:05:46Z  okderators-kd8cr Started; CatalogSource READY
12:08:58Z  InstallPlans 22 before, 22 after, none new; all three Subscriptions AtLatestKnown on the same CSVs,
           no condition True
```

Zero InstallPlans, as expected. The catalog pod moved from node5 to node6. The `:4.21` image (132 MB) stays cached on
node5, which carries mon c, until image garbage collection removes it; not checked. One trap while checking: an `okderators-dhw67` pod in the events at 11:09Z
pulling `:4.21` was the hourly `registryPoll` check pod (pull, compare digest, delete), not a second catalog.
