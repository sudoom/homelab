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
| Rook-Ceph operator + Ceph | **v1.20.0 / Squid 19.2.4** (Renovate-bumped 2026-06-12) | ✅ | ✅ | Ready **with headroom**. Rook 1.20 supports Kube v1.31–v1.36 → covers both 1.34 and 1.35 with margin (the prior "zero headroom at 1.35" concern on v1.19.6 is **RESOLVED** — v1.20.0 landed via Renovate #134 + Ceph 19.2.4 via #133, rolled all daemons cleanly). Upstream-Helm delivery → not catalog-gated. |
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
5. Audit for `groupsnapshot.storage.k8s.io/v1beta1` VGS objects (**none expected** here) and confirm Rook v1.20.0 serves the VGS CRD at **v1beta2** (4.21 removes v1beta1 outright — distribution-specific; upstream only deprecates). Blast radius limited: CNPG backs up via the GA `snapshot.storage.k8s.io/v1` `ceph-rbd-snapshot` class, unaffected.
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

**AFTER 4.22 settles (non-blocking):** ~~bump Rook to v1.20.x to regain headroom past 1.35~~ — **DONE 2026-06-12** (Renovate bumped Rook → v1.20.0 / Ceph → 19.2.4; Rook 1.20 covers Kube 1.31–1.36, so headroom for both hops is already in place).

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
- ~~Rook v1.19.6 at the exact top of its window (1.35) with zero slack~~ — **RESOLVED 2026-06-12**: now on Rook v1.20.0 (Kube 1.31–1.36) + Ceph 19.2.4, both via Renovate auto-merge. NB: that Ceph patch bump rolled all 3 OSDs (a degraded-window event) unsupervised — decide whether Renovate should auto-merge storage/Ceph image bumps or gate them behind a scheduled window.
- VGS v1beta1 removal at 4.21 — low blast radius (none used) but confirm Rook's bundled sidecar emits only v1beta2.
- CNPG upstream doesn't officially test OpenShift — runs fine but technically unvalidated on 4.21/4.22.
- Each per-node reboot (6 across the two hops) re-trips the OVN-egress + RBD-VA cascade and can re-expose the DDF false-etcd-alert symptom — operational, compounding on a no-drain cluster.
