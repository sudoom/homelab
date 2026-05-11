# Multus migration for Rook-Ceph — planning notes

Working notes for moving Ceph client traffic off the 1G frontend and back onto the 10G storage backnet, without re-creating the CSI-SDN reachability trap. **Plan, not implementation.** Sequencing and exact commands are queued; nothing here is committed yet.

## Why we're doing this

Today's `CephCluster` runs `network.provider: host` with:

```yaml
network:
  provider: host
  addressRanges:
    public:  ["192.168.1.0/24"]    # SDN-reachable, 1G — temporary
    cluster: ["192.168.10.0/24"]   # 10G replication
```

This unblocks the `csi-rbdplugin` (it lives on the OVN SDN and needs to reach OSDs), but caps client throughput at ~118 MB/s sustained — what the 1G NIC can do. The 10G backnet sits idle from the client's perspective.

Multus lets us attach a second NIC to specific pods (mons, OSDs, **and** CSI plugins) so they can speak directly to the storage backnet. With that in place we put `public_network` back on `192.168.10.0/24` and clients hit the NVMe drives at line rate.

Rook supports this directly: <https://rook.io/docs/rook/latest-release/CRDs/Cluster/network-providers/#multus>.

## Target topology

```yaml
network:
  provider: multus
  selectors:
    public:  rook-ceph/ceph-public
    cluster: rook-ceph/ceph-cluster
  addressRanges:
    public:  ["192.168.10.0/24"]
    cluster: ["192.168.10.0/24"]   # OK to coexist on same subnet (or split later)
```

`public` and `cluster` can share a NAD when there's only one storage NIC — Rook documents this as supported. We can split into two NADs later if we add a second 10G interface.

## Pieces to build

### 1. NetworkAttachmentDefinition chart

New chart: `components/cluster-config/ceph-network-attachments/`. Two NADs in `rook-ceph` namespace, both backed by the existing 10G interface (`enp1s0f0np0`, already configured by the NMState NNCP).

Driver options (pick one):

- **macvlan + whereabouts IPAM** — what Rook upstream recommends. Each pod with the NAD attached gets its own MAC + IP from the whereabouts pool. Works with any L2 bridge.
- **bridge + whereabouts** — needs a Linux bridge on the host. Currently we don't have one; the NNCP configures `enp1s0f0np0` directly with a static IP, no bridge.
- **host-device** — would steal the NIC from the host; not viable since OSDs already use it via host networking today, and the host needs it for its own .10.x address.

Going with **macvlan**. It can attach to an interface that already has an IP without taking it over.

Sketch:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ceph-public
  namespace: rook-ceph
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "enp1s0f0np0",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "192.168.10.0/24",
        "range_start": "192.168.10.100",
        "range_end":   "192.168.10.199",
        "exclude": [
          "192.168.10.2/32",
          "192.168.10.3/32",
          "192.168.10.4/32"
        ]
      }
    }
```

Excludes pin out the host static IPs from the NMState NNCP so whereabouts never hands them to a pod.

`ceph-cluster` is a duplicate of `ceph-public` for now — different name, same config — so we can split them later without re-rolling daemons.

**Open question:** does OKD 4.20 ship Multus + whereabouts by default? OVN-Kubernetes does ship Multus; whereabouts is a separate plugin. Need to verify before assuming `"type": "whereabouts"` will resolve. Fallback is `"type": "static"` per-pod, but that doesn't work with Rook (it scales NAD attachments dynamically).

### 2. NMState — likely no change

The NNCP at `components/cluster-config/nmstate-nncp/` already brings `enp1s0f0np0` up with a static IP per host. Macvlan attaches over the top of this without disturbing the host config. No NNCP change expected.

The unused interface `enp1s0f1np1` stays unused — until we want to split public/cluster onto separate NICs.

### 3. CephCluster flip

In `components/storage/ceph-cluster/templates/cephcluster.yaml`:

```diff
   network:
-    provider: host
+    provider: multus
+    selectors:
+      public:  rook-ceph/ceph-public
+      cluster: rook-ceph/ceph-cluster
     addressRanges:
       public:
-        - "192.168.1.0/24"
+        - "192.168.10.0/24"
       cluster:
         - "192.168.10.0/24"
```

This is the change that triggers the rolling daemon restart. Same gotcha as last time: Rook reconciles the config, but daemons need to be rolled manually if they're already running.

### 4. CSI-side wiring

Rook's CSI driver picks up the NAD selectors from the CephCluster spec automatically when `provider: multus` is set, and adds the NAD to the CSI plugin pod templates. No separate config file in our chart should be needed.

Verification step (after migration): `oc get pod -n rook-ceph <csi-plugin-pod> -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks}'` should show `ceph-public`.

## Sequencing

Order matters. Rolling everything at once will break quorum.

1. **Pre-flight**
   - Verify Multus is active: `oc get pods -n openshift-multus`
   - Verify whereabouts is installed: `oc get pods -A | grep whereabouts`
   - If missing, install whereabouts or pick an alternative IPAM. Block migration on this.
2. **Apply NADs only.** Adds two `NetworkAttachmentDefinition` objects, no pod changes. Safe to commit and let ArgoCD reconcile.
3. **Smoke test the NAD**: launch a throwaway pod with the `ceph-public` annotation, confirm it gets a `192.168.10.x` IP and can `ping 192.168.10.2`. If this fails, stop — the migration won't work either.
4. **Flip CephCluster.** Commit `provider: multus` + the address-range swap. Rook updates ceph config but won't roll daemons.
5. **Roll mons one at a time.**
   ```bash
   for m in a b c; do
     oc -n rook-ceph delete pod -l app=rook-ceph-mon,mon=$m
     until oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s | grep -q HEALTH_OK; do sleep 5; done
   done
   ```
   After each: `ceph mon dump` to confirm the mon's address is now `192.168.10.x`.
6. **Roll OSDs one at a time** (same loop, `app=rook-ceph-osd,osd=$i`). Verify each with `ceph osd metadata $i | jq '.front_addr'`.
7. **Roll mgr.** Less critical, but want it on the new network too.
8. **CSI plugins** — Rook restarts these itself when the CephCluster spec changes, but a `oc rollout restart deploy/...` belt-and-braces sweep doesn't hurt.
9. **End-to-end test.** Recreate the 200 GB write test (`tests/ceph-storage-test.yaml`). Compare throughput against the 1G-link baseline (~118 MB/s sustained). Target: saturate NVMe, expect 800+ MB/s sustained on a single client.

## Validation gates

Each step has a stop condition. Don't proceed past one if it fails.

- After NAD apply: `oc describe net-attach-def ceph-public -n rook-ceph` shows the spec, no errors.
- After smoke pod: pod gets a `192.168.10.x` second IP, can ping a node's storage IP.
- After CephCluster flip: `ceph -s` still shows quorum and HEALTH_OK / HEALTH_WARN (only the slow-op alert, no new warnings).
- After each mon roll: `ceph mon stat` shows quorum of 3.
- After each OSD roll: `ceph osd tree` shows all up + in.
- After CSI verification: provision a tiny PVC in `default`, confirm it binds inside 30s.

## Rollback plan

If anything breaks at step 4–7, revert the CephCluster change in git, let ArgoCD roll it back, then manually delete and recreate any daemon pod that's stuck on Multus annotations:

```bash
oc -n rook-ceph patch cephcluster rook-ceph --type=merge -p \
  '{"spec":{"network":{"provider":"host","selectors":null,"addressRanges":{"public":[{"cidr":"192.168.1.0/24"}],"cluster":[{"cidr":"192.168.10.0/24"}]}}}}'
```

(Actual git revert preferred — this command is the break-glass version if ArgoCD can't sync.)

CSI plugins should fall back to host networking automatically when `provider: host` is set; if they don't, delete the plugin daemonset pods and let Rook recreate them.

NADs left in place after rollback are harmless — nothing references them.

## Risks worth flagging up-front

- **Whereabouts not installed.** This is the most likely blocker. Resolve before anything else.
- **MTU mismatch.** If the 10G interface is set to MTU 9000 anywhere and macvlan defaults to 1500, large I/O will fragment. Need to check `ip link show enp1s0f0np0` on each node and either match it in the NAD config or normalize on 1500.
- **OVN egress IP / EgressFirewall** — if any cluster-wide egress policy blocks `192.168.10.0/24` from OVN pods, the SDN-side communication still happens (Rook talks to mons via SDN endpoints for some control-plane RPCs?). Need to verify no block exists.
- **Pod restarts during the roll** — recovery I/O during OSD rolls will compete with whatever workloads are running. Schedule during a quiet window or accept the brief perf dip.
- **Mon address change semantics.** Mons changing IPs is an operationally heavy event in Ceph. Rook handles it, but if quorum is lost mid-roll the cluster is hard to recover. **Strict one-at-a-time, wait-for-HEALTH_OK between each.**

## Out of scope for this migration

- Splitting public and cluster onto separate physical NICs — leave for later if `enp1s0f1np1` ever gets cabled.
- Encryption-on-the-wire (Ceph msgr2 secure mode) — orthogonal, can layer on after Multus.
- IPv6 — not enabled on the storage VLAN, no plan to add.

## Pre-flight — 2026-05-11

All five gates from the previous section came up green; capturing the exact observations here.

**1. Multus operational.** `oc get pods -n openshift-multus -o wide`:

```
multus-{4pgpr,gndgl,nxxpf}                       1/1 Running   node{4,5,6} (host-net)
multus-additional-cni-plugins-{hl8dx,n8tvh,qpffp} 1/1 Running   node{4,5,6}
multus-admission-controller-756dbc4cc-{2x76t,6crpr} 2/2 Running
network-metrics-daemon-{db7r5,rkjfx,s9bvr}       2/2 Running
```

3-node DaemonSet up, admission controller healthy. The `multus-additional-cni-plugins` DS is what ships the macvlan + whereabouts binaries onto each node on OpenShift — there is no standalone `whereabouts` DaemonSet on OKD; the CNI binary lives under `/var/lib/cni/bin` after the additional-plugins pod runs once.

**2. Whereabouts present.** No DS, but the CRDs are installed (`oc get crd | grep whereabouts`):

```
ippools.whereabouts.cni.cncf.io                 2026-04-03T11:54:58Z
nodeslicepools.whereabouts.cni.cncf.io          2026-04-03T11:54:58Z
overlappingrangeipreservations.whereabouts.cni.cncf.io  2026-04-03T11:54:58Z
```

Installed at cluster bring-up. `"type": "whereabouts"` in the NAD config will resolve.

**3. MTU.** `oc get nodenetworkstate node4.okd.sudops.pl -o json | jq` showed `enp1s0f0np0` at MTU 1500. NMState NNCP at `components/cluster-config/nmstate-nncp/templates/nncp.yaml` doesn't set MTU explicitly, so all three nodes inherit the NIC default (1500). Macvlan default is also 1500 — no MTU adjustment needed. Jumbo frames on the 10G backnet would be a nice future optimization but it's out of scope for this migration (separate NNCP change, separate risk).

**4. Rook v1.19 selector syntax.** Confirmed against <https://rook.io/docs/rook/v1.19/CRDs/Cluster/network-providers/>:

```yaml
network:
  provider: multus
  selectors:
    public:  <namespace>/<name>     # e.g. rook-ceph/ceph-public
    cluster: <namespace>/<name>
  addressRanges:
    public:  ["192.168.10.0/24"]
    cluster: ["192.168.10.0/24"]
```

Matches the target topology in this draft. Critical prerequisite from the docs: *"No IP address assigned to a node can overlap with any IP address assigned to a pod on the Multus public network"* — the whereabouts `exclude` for `.2/.3/.4` already handles this.

**5. OKD 4.20 + OVN-Kubernetes + Multus + macvlan.** No SDN-specific gotcha: NADs in user/operator namespaces with `type: macvlan` are first-class on OpenShift's Multus stack; the `multus-admission-controller` is what gates them. `network.operator.openshift.io/cluster` does not need an `additionalNetworks` entry for user-namespace NADs.

**Bonus useful nugget:** Rook ships a `rook multus validation` CLI tool that exercises NAD plumbing across all relevant nodes. Plan to run it between Phase 1 (NADs land) and Phase 2 (CephCluster flip) as an extra gate.

## Phase 1 — NAD chart shipped (2026-05-11)

Chart at `components/cluster-config/ceph-network-attachments/`. Two NADs (`ceph-public`, `ceph-cluster`) in `rook-ceph` ns, both macvlan over `enp1s0f0np0`, mode `bridge`, MTU 1500, whereabouts IPAM in `192.168.10.0/24` excluding the host static IPs (.2/.3/.4), allocation range `.100–.199`.

**Important detail: shared `network_name: ceph-storage`.** Both NADs draw from the same logical whereabouts allocation pool. Without this, two NADs sharing a CIDR could each hand out the same IP to a pod from each NAD — collision on the wire. With `network_name` shared, whereabouts dedupes across both NADs. This matters even before we point Rook at the NADs, because OSD pods get both attachments simultaneously.

Wired into `bootstrap/root-app/values.yaml` at `syncWave: "2"` (alongside `nmstate-nncp`, `cert-manager-config`, `oauth-idp`), namespace `rook-ceph` (already exists from the operator install).

Validation gates all green:

- `helm lint`: 1 chart linted, 0 failed.
- `helm template` renders cleanly, two NADs with identical config except `metadata.name`.
- `kubeconform -summary`: `2 resources found parsing stdin - Valid: 2, Invalid: 0, Errors: 0, Skipped: 0`.
- `oc diff -f -` against the live cluster: purely additive, both NADs new (cluster has zero NADs in `rook-ceph` today).
- `helm template root-app …` shows the new `Application` with `argocd.argoproj.io/sync-wave: "2"`, retry policy + sync options inherited from the defaults.

Phase 2 (CephCluster flip + mon/OSD roll) is a separate session — it's the degraded-window step and wants quiet IO, plus a `rook multus validation` run first.

## Smoke test — 2026-05-11 (Phase 1 verification)

Pod manifest at `tests/multus-nad-smoke.yaml`: single pod in `rook-ceph` annotated `k8s.v1.cni.cncf.io/networks: ceph-public,ceph-cluster`, scheduled on `node4`. First run used `quay.io/ceph/ceph:v19.2.3` but that image lacks `ip` / `ping` — swapped to `nicolaka/netshoot` for the actual reachability checks.

### What worked

`network-status` annotation:

```
ovn-kubernetes  eth0  10.130.0.59
ceph-public     net1  192.168.10.100  6a:c5:a7:b2:cd:c3
ceph-cluster    net2  192.168.10.101  c6:19:96:a0:7e:b8
```

- **Distinct IPs from a shared pool.** `network_name=ceph-storage` dedup is working as designed — without it, both NADs sharing `192.168.10.0/24` could have handed out the same IP.
- **Distinct MACs** confirm macvlan creates a per-attachment virtual NIC, not just an IP alias.
- **Routes** look right: `192.168.10.0/24 dev net1 src 192.168.10.100` and `192.168.10.0/24 dev net2 src 192.168.10.101`, plus the default via OVN SDN unchanged.
- **Cross-host reachability** is line-rate: `ping -I net1 192.168.10.3` → 0.17 ms, `192.168.10.4` → 0.13 ms.

### What broke — Phase 2 blocker

`ping -I net1 192.168.10.2` (pod's own host node4): **Destination Host Unreachable, 100 % loss.**

This is the macvlan **same-host loopback restriction** — well-documented Linux kernel behaviour in bridge mode. When a macvlan pod tries to talk to its own host's primary IP on the same physical NIC, the bridge code drops the frame because the destination MAC equals the source-side master MAC. Pod↔pod (same or different host) works, pod↔other-host works, pod↔own-host does not.

I missed this in the original pre-flight. The smoke test caught it before Phase 2 made it expensive.

**Why this matters for Ceph specifically:** The Rook CSI plugin runs as a host-network DaemonSet and uses the **host kernel's** `rbd` module to map RBD volumes. When the kernel resolves a mon's address and that mon happens to be on the same node as the CSI plugin (in a 3-mon / 3-node topology this is always the case for one of the three mons), the kernel tries pod-IP→host-loopback and gets ENETUNREACH. Result: mounting PVCs intermittently fails depending on which mon the client connects to.

Pod-to-pod replication traffic (OSD↔OSD on different hosts) is unaffected. The block is specifically the kernel-on-host side of the CSI mount path.

### Resolution options

Two known fixes; deferring the decision to a separate session:

**A. Macvlan host-shim per node.** Documented in Rook's network-providers page. Adds a second macvlan sub-interface on the host that lives in the same /24 (or a parallel range), plus a route directing pod-IPs through the shim. Bypasses the kernel's hairpin drop because the shim has a different MAC than the master interface.
- Implementation: extend `components/cluster-config/nmstate-nncp/templates/nncp.yaml` with a per-node shim interface (e.g. `enp1s0f0np0.shim` macvlan over `enp1s0f0np0`, IP `192.168.10.{20,21,22}/24` or similar). NMState handles the creation declaratively.
- Pros: stays on macvlan, no NAD config change, isolated to NMState.
- Cons: extra interface per node, IP allocation discipline (must not clash with whereabouts range).

**B. Switch to ipvlan L2.** Replace `"type": "macvlan"` with `"type": "ipvlan", "mode": "l2"` in both NADs. ipvlan shares the host's MAC and has no hairpin drop — pod-to-own-host works directly.
- Pros: single-line NAD change, no host-side state, no NMState NNCP edit.
- Cons: all pod traffic egresses with the host's MAC; switches doing port-security/anti-spoof would block this. Mikrotik on the storage VLAN isn't doing port-security in this lab, so it's a non-issue here.
- Subtle: ipvlan in L2 mode does not support DHCP (irrelevant — we use whereabouts) and cannot do MAC-based filtering downstream (irrelevant).

**Leaning B.** Less moving parts, less host-side state, less coordination with the NMState chart. The MAC-sharing concern doesn't apply to our environment. Will validate with the same smoke pod after flipping the NADs.

### State of Phase 1 after the smoke test

Phase 1 NADs (macvlan, `network_name=ceph-storage`, range `.100-.199`) are committed and live, but **must be reshaped before Phase 2** — either by flipping to ipvlan or by adding the host shim. The current NADs aren't *wrong*, they just won't carry the CSI mount path correctly. Leaving them in place to keep the chart shape and ArgoCD reconciliation tested while the decision is made.

### Validation pod manifest

Kept at `tests/multus-nad-smoke.yaml` for re-runs after each NAD change. Re-run pattern: `oc apply` → `oc wait Ready` → `ping -I net1` to each storage IP → `oc delete`.

## Picking macvlan + host-shim (Option A) over ipvlan L2 (Option B) — 2026-05-11

Fetched the v1.19 network-providers doc end-to-end. The relevant quote, verbatim:

> "CNI type macvlan is highly recommended. It has less CPU and memory overhead compared to traditional Linux bridge configurations."

ipvlan is **not mentioned anywhere** in Rook's network-providers documentation. Not a deprecation, not a "use at your own risk" — it's simply outside Rook's documented and tested path. For a 3-OSD, no-drain-headroom storage layer, going off-doc to save one NMState edit isn't worth it. Going with **Option A: macvlan + per-node host shim**.

Also surfaced from the doc, separately worth flagging:

> "Daemons leveraging Kubernetes service IPs (Monitors, Managers, Rados Gateways) are not listening on the NAD specified in the selectors... There is work in progress to fix this issue."

So the RGW/mgr/mon-via-Service paths continue to ride the OVN SDN even after Phase 2. The seqwrite/random-read throughput projection only applies to RBD direct traffic (OSD ↔ client) and OSD-to-OSD replication. In-cluster S3 clients hitting `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80` (Loki + future CNPG/OADP) won't see the uplift — RGW frontend listens on a Service IP, not the NAD.

### Shim design

The Rook canonical example uses `/22` for the shim and a wide `/16` route, with the shim and pods in a subnet that doesn't overlap the host's master interface. Our master sits at `192.168.10.{2,3,4}/24` on the same `/24` that pod allocations would live on. Two ways to make this coexist:

1. Move pods to a different subnet (router-side change on the Mikrotik) — too heavy for tonight.
2. **Split the storage `/24` into two `/25`s.** Master + shim in the lower half (`.0–.127`), pods in the upper half (`.128–.254`). Per-node route `192.168.10.128/25 dev ceph-shim` is more specific than the master's `/24` connected route, so longest-prefix-match unambiguously sends pod traffic through the shim while host-to-host replication keeps using the master.

Going with option 2. No router config change required.

Concrete assignments:

| Node  | Master IP            | Shim IP              | Pod range          |
|-------|----------------------|----------------------|--------------------|
| node4 | 192.168.10.2/24      | 192.168.10.16/24     | 192.168.10.128–.254 (shared) |
| node5 | 192.168.10.3/24      | 192.168.10.17/24     | (whereabouts pool) |
| node6 | 192.168.10.4/24      | 192.168.10.18/24     | (whereabouts pool) |

Shim is a `mac-vlan` type interface in NMState, parented to `enp1s0f0np0`, mode `bridge`, `promiscuous: true`. Route added in the same NNCP under `routes.config`.

### Applying the NNCP — operational impact

NetworkManager has to re-apply the storage interface's connection profile per node to bring the new macvlan child up. The nmstate operator sequences NNCP applications one node at a time. Expected blip per node: ~1–3 s on the storage backnet while NM reconfigures. OSDs use this interface for replication — expect a few seconds of heartbeat hiccups and possibly a `slow ops` flag, but not a full OSD restart. Total degraded window across three NNCP reconciles: ~5–10 s in three short bursts, not contiguous (each NNCP waits for the previous to settle).

Per the 3-OSD-no-drain rule, schedule during quiet IO. There's no fourth node to absorb a hiccup.

### Side-finding during Phase 2 apply: nmstate-handler SCC regression

When the shim NNCP commit hit master, ArgoCD reconciled, and `nmstate-nncp` advanced to gen=2 on **node5 and node6 only**. node4's NNCP went to `Available=False, reason=NoMatchingNode`.

Diagnosis: the `nmstate-handler` DaemonSet in the `nmstate` namespace reports `DESIRED 3 / CURRENT 2 / READY 2` — node4 has no handler pod, and the DS controller has been retrying for ~4 hours (55 attempts pre-discovery) with:

```
Error creating: pods "nmstate-handler-" is forbidden:
  unable to validate against any security context constraint
  ... provider "privileged": Forbidden: not usable by user or serviceaccount
```

`nmstate-handler` ClusterRole has rules for the operator's CRs, pods/nodes/namespaces, secrets/configmaps, webhook configs, and TokenReview / SubjectAccessReview — but **no rule granting `use` on `securitycontextconstraints/privileged`**. The currently-running pods on node5/node6 (15 days old) were admitted when the SCC binding evidently still existed; SCC admission only runs at pod creation, so they're grandfathered. When node4's pod was lost at some point, the recreate path failed because the SA can no longer obtain the privileged SCC.

This is **pre-existing**, not introduced by today's commits. The Multus migration just surfaced it: under the old gen=1 NNCP nothing was changing on disk, so the DS retry-loop was invisible. The gen=2 apply needs the handler to actually be running on node4 — exposing the broken state.

Fix shipped as part of this session: add a `ClusterRoleBinding` in `components/operators/nmstate/templates/handler-scc-binding.yaml` that grants the auto-generated `system:openshift:scc:privileged` ClusterRole to `system:serviceaccount:nmstate:nmstate-handler`. Sync wave 1, alongside the Subscription. The community-operators CSV doesn't ship this binding, so we ship it as a static manifest in the operator chart. Standalone follow-up: upstream the missing binding to the community-operators CSV (separate work — see README TODO).

After the binding lands, the DS controller's next retry should succeed, the handler pod schedules on node4, the gen=2 NNCP reconciles, and the storage backnet flips through the same brief blip that node5 and node6 already absorbed.

### Rendered diff summary (pre-commit)

`oc diff` after `helm template` on both charts:

- **NNCP** (per node): adds `ceph-shim` mac-vlan interface and the `192.168.10.128/25 dev ceph-shim` route. Master interface config untouched. `generation` bumps 1→2.
- **NAD** (per attachment): `range_start` `.100→.128`, `range_end` `.199→.254`, `exclude` `[.2,.3,.4]→[]` (host IPs now sit outside the pod range, no exclude needed). `network_name=ceph-storage` and macvlan config unchanged. `generation` bumps 1→2.

Both changes intended to land together so the route exists before any pod could be allocated in the upper `/25`. After commit, smoke-test pattern shifts to:

1. From a host shell on node4 (e.g. `oc debug node/node4`), `ping 192.168.10.128` (a known pod IP) — should succeed via `ceph-shim`. This is the direction Rook's CSI plugin needs (kernel-RBD client → mon pod).
2. From inside the test pod, `ping -I net1 192.168.10.3/.4` (other-host master IPs) — should still succeed at line rate.
3. Pod → own-host (`ping -I net1 192.168.10.2`) may still fail with destination-unreachable. That's fine — Rook's CSI client side is always host-network, so the missing direction is HOST→POD, which the shim solves.
