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
| loki-operator + cluster-logging | v6.5.0 (okderators) | ✅ | needs-upgrade | **Currently DEGRADED on 4.20** — clear first. 6.5 in-matrix for 4.21; 4.22 needs Logging 6.6 (unreleased). okderators #44 OPEN. |
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
