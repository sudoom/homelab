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

**Second pre-existing RBAC gap discovered immediately after.** The SCC fix let the new handler pod admit. It then crashed on startup with:

```
unable to fetch TLS configuration ... apiservers.config.openshift.io
"cluster" is forbidden: User "system:serviceaccount:nmstate:nmstate-handler"
cannot get resource "apiservers" in API group "config.openshift.io"
at the cluster scope
```

The handler reads the cluster's TLS profile from `apiservers/cluster` at startup. The CSV doesn't grant `get apiservers` to the handler SA either. Existing pods on node5/node6 (15 days old, 20+/36 restarts) survived this code path long enough to enter their watch loop, which doesn't need the permission — so the gap was invisible until a fresh handler pod tried to start.

Second workaround shipped alongside the SCC binding: `components/operators/nmstate/templates/handler-apiserver-rbac.yaml` adds a small ClusterRole granting `get/list/watch apiservers.config.openshift.io` and a ClusterRoleBinding to the handler SA. Same upstreaming note as before — both should land in the community-operators CSV.

Lesson for future fresh-pod regressions on this operator: the 15-day-old grandfathered pods are hiding multiple missing bindings. If a third missing permission shows up at the next code path, it's likely from the same lost binding set. Worth doing a wider audit if any more handler pod needs to be recreated.

## Post-shim smoke test — 2026-05-11 (Phase 2 prerequisite validated)

After all three NNCPs reached `gen=2 / TrueSuccessfullyConfigured`, re-ran the smoke pod with the new pod range. Pod scheduled on node4, got `net1=192.168.10.128` (ceph-public) and `net2=192.168.10.129` (ceph-cluster) — first two addresses of the shifted whereabouts range. Same dual-attachment annotation as the prior test.

**Two reachability paths tested**:

1. Pod → other-host primary IP (sanity, was already working):
   ```
   ping -I net1 192.168.10.3 from pod
   → 0.062–0.123 ms, 0% loss
   ```

2. **Host on `node4` → pod's `net1` (`192.168.10.128`) — the path that previously failed**:
   ```
   oc debug node/node4 -- chroot /host ping 192.168.10.128
   → 0.030–0.055 ms, 0% loss
   ```

This is the host→pod direction Rook's CSI plugin uses when the kernel `rbd` module on a node talks to a mon pod on that same node. Previously it returned `Destination Host Unreachable` because of the macvlan hairpin drop on the master interface. With the shim in place and the kernel selecting it for the `/25` pod range, the frame egresses with the shim's MAC and macvlan bridges between the two children on the same master. Works as designed.

Route table state on each node (uniform across node4/5/6, modulo the shim IP):

```
192.168.10.0/24 dev enp1s0f0np0 proto kernel scope link src 192.168.10.2 metric 100
192.168.10.0/24 dev ceph-shim   proto kernel scope link src 192.168.10.16 metric 410
192.168.10.128/25 dev ceph-shim proto static scope link
```

Three routes deliberately:

- `/24 via master, metric 100` — host-to-other-host primary IPs (`.3`, `.4`) keep using the master.
- `/24 via ceph-shim, metric 410` — the shim's auto-installed connected route; lower preference than master so it doesn't intercept host-to-host traffic.
- `/25 via ceph-shim, static` — explicit, more specific, wins via longest-prefix-match for any destination in `192.168.10.128–.254` (the pod range).

Phase 2 prerequisites are now fully satisfied. The remaining step is the CephCluster spec flip itself + the mon/OSD roll — that's the actual degraded-window operation and worth scheduling as a dedicated session with a quiet IO window and a `rook multus validation` pre-flight.

### Rendered diff summary (pre-commit)

`oc diff` after `helm template` on both charts:

- **NNCP** (per node): adds `ceph-shim` mac-vlan interface and the `192.168.10.128/25 dev ceph-shim` route. Master interface config untouched. `generation` bumps 1→2.
- **NAD** (per attachment): `range_start` `.100→.128`, `range_end` `.199→.254`, `exclude` `[.2,.3,.4]→[]` (host IPs now sit outside the pod range, no exclude needed). `network_name=ceph-storage` and macvlan config unchanged. `generation` bumps 1→2.

Both changes intended to land together so the route exists before any pod could be allocated in the upper `/25`. After commit, smoke-test pattern shifts to:

1. From a host shell on node4 (e.g. `oc debug node/node4`), `ping 192.168.10.128` (a known pod IP) — should succeed via `ceph-shim`. This is the direction Rook's CSI plugin needs (kernel-RBD client → mon pod).
2. From inside the test pod, `ping -I net1 192.168.10.3/.4` (other-host master IPs) — should still succeed at line rate.
3. Pod → own-host (`ping -I net1 192.168.10.2`) may still fail with destination-unreachable. That's fine — Rook's CSI client side is always host-network, so the missing direction is HOST→POD, which the shim solves.

## Phase 2 — the actual flip (2026-05-12)

### Pre-flight: `kubectl rook-ceph multus validation` doesn't work on OpenShift

Installed the `kubectl-rook-ceph` krew plugin and ran:

```
kubectl rook-ceph multus validation run \
  --public-network=rook-ceph/ceph-public \
  --cluster-network=rook-ceph/ceph-cluster
```

It timed out at the host-checker-pod stage. Admission rejection:

```
pods "multus-validation-test-host-checker-shared-storage-and-worker-nodes-" is forbidden:
  unable to validate against any security context constraint:
  - restricted-v2: .spec.securityContext.hostNetwork: Invalid value: true: Host network is not allowed
  - provider "hostnetwork": Forbidden: not usable by user or serviceaccount
  - provider "privileged": Forbidden: not usable by user or serviceaccount
  - pod.metadata.annotations[seccomp.security.alpha.kubernetes.io/pod]: Forbidden: seccomp may not be set
```

Two OpenShift-specific blockers in the tool's pod spec: (a) the validation tool runs the host-checker DaemonSet as the namespace's `default` SA, which doesn't have `hostnetwork`/`privileged` SCC, and (b) the tool sets the legacy `seccomp.security.alpha.kubernetes.io/pod` annotation that `restricted-v2` rejects outright. Both would need patching to get the tool through OpenShift admission. The marginal value is iperf throughput across all node pairs, which we'll measure with fio post-flip anyway — skipping the formal validation. Yesterday's smoke test already verified the dimensions that actually matter (whereabouts allocation, cross-host reachability, host→pod via the shim).

Cleaned up stranded test resources with `kubectl rook-ceph multus validation cleanup --namespace rook-ceph`.

### Discovery: the flip is a two-step, not one-step

Rendered the target chart change (`provider: host → multus`, add `selectors`, flip `public` CIDR `192.168.1.0/24 → 192.168.10.0/24`) and ran `helm template ... | oc diff -f -`. Admission rejected it:

```
The CephCluster "rook-ceph" is invalid: spec.network.provider: Invalid value: "string":
  network provider must be disabled (reverted to empty string) before a new provider is enabled
```

Rook's CephCluster controller has a deliberate guard against direct provider transitions — you can't go from one provider to another in a single commit. Forces an intermediate `provider: ""` state so the operator's network reconfiguration is explicit, not silent. No bypass flag in v1.18 / Squid 19.2.3.

So the migration becomes two commits:

1. **Step 1**: `provider: host → provider: ""`. Daemons re-roll onto pod-only networking (OVN SDN). HEALTH_OK throughout the roll; throughput temporarily on encapsulated SDN (~6-8 Gbps effective) for both directions.
2. **Step 2**: `provider: "" → provider: multus` with selectors and `public: 192.168.10.0/24`. Daemons re-roll onto Multus. End state: clients on 10G storage backnet directly, OSD↔OSD also on the backnet.

Two daemon rolls (mons → mgrs → OSDs each time), serialized via PDB (`managePodBudgets: true`). Two degraded windows. ~25-30 min total wall-clock for a 3-OSD cluster.

### Step 1 commit — provider blanked

Chart edit: `components/storage/ceph-cluster/values.yaml` set `network.provider: ""`, addressRanges left untouched. Template already conditional on `provider == "multus"` for the `selectors:` block — no template change needed for step 1.

Rendered `oc diff` against live:

```
@@ -72,7 +72,6 @@
       public:
       - 192.168.1.0/24
     multiClusterService: {}
-    provider: host
   placement:
```

Exactly one line: `provider: host` → `provider: ""`. No other deltas.

**Helm rendering gotcha** caught on the first push: template was `provider: {{ .Values.network.provider }}` (unquoted). With `values.yaml: provider: ""`, that renders as `provider: ` (bare, no value), which YAML parses as literal `null` — and the CephCluster CRD enum accepts `""`, `"host"`, `"multus"`, or *absent*, but **not** `null`. ArgoCD's first 5 sync attempts failed with `spec.network.provider: Unsupported value: "null"` before I caught it. Fix is `provider: {{ .Values.network.provider | quote }}` so the empty string renders as `""` explicitly. No cluster churn — the rejection was at admission, never reached the controller.

**Second rendering gotcha** caught on the next push: with `provider: ""` accepted by admission, the Rook **operator** (not admission webhook) then rejected the resulting spec because `addressRanges` was still set:

```
failed to validate network spec for cluster in namespace "rook-ceph":
network ranges can only be specified for "host" and "multus" network providers
```

The operator's own reconcile-time validator refuses `addressRanges` when provider is neither host nor multus. Operator went into a tight retry loop (~1 reconcile/sec) emitting this error. Fix: gate the `addressRanges:` block in the template behind a non-empty provider, so the field is *absent* when `provider: ""`:

```yaml
{{- if .Values.network.provider }}
addressRanges:
  public:
    - {{ .Values.network.public | quote }}
  cluster:
    - {{ .Values.network.cluster | quote }}
{{- end }}
```

Wrinkle: `oc diff` showed the diff as empty even though the live spec still had `addressRanges` and the rendered manifest didn't. Reason: the CephCluster resource was originally created with non-SSA apply and had **`metadata.managedFields: []`** (no field manager ownership tracked). Server-side apply only removes fields it owns; with no ownership recorded, it can't remove `addressRanges` even when the manifest omits it. ArgoCD's selfHeal eventually cleared the field on a later cycle (mechanism unclear — possibly a full re-establish of SSA ownership), but it took several minutes. Lesson: any CephCluster spec field that was originally created via non-SSA path is sticky and may not be removable via Helm template alone.

### Daemon roll begins — mgrs swap cleanly

Once the operator stopped erroring, Rook started the daemon roll:

- `mgr-a` swapped first: new pod `57fc6c4dd8-87226` replaced old `d7db75d8-qjvfh`, deployment template now `hostNetwork: false` + pod-only network. ~15s.
- `mgr-b` followed: new pod `ff4cdbc9-xjkrr` replaced old `7fc5f7d84c-b2stf`. ~15s.
- Both mgrs healthy, active mgr migrated from `b` to `a` during the swap.

Mons did NOT roll next (despite being typically the natural next phase). Operator went straight to OSDs.

### OSD-0 crashloop — stale `public_network` in config DB

OSD-0 rolled (replaced with new pod `5659dcd494-rlzsd` on `hostNetwork: false` + pod IP `10.130.1.8`), then immediately crashlooped. Container log told the whole story in one line:

```
unable to find any IPv4 address in networks '192.168.1.0/24' interfaces ''
Failed to pick public address.
```

Root cause: when running with `provider: host`, the operator had set `public_network = 192.168.1.0/24` in the Ceph **config database** (mons' KV store) so daemons would bind to the frontnet on the host. When provider changed to `""`, **the operator did not clear `public_network` from the config DB.** The OSD daemon read `public_network = 192.168.1.0/24` from the mons, looked for an interface with a `192.168.1.x` address on the pod's net namespace, found none (pod IP was `10.130.1.8`), and refused to start.

This is the silent assumption in Rook's "host → empty" transition: the operator updates the *Deployment* shape but not the *Ceph config DB* settings that the daemon reads at startup. The two had drifted into mutual incompatibility.

Fixed by clearing from the toolbox:

```
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph config rm global public_network
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph config rm global cluster_network
oc -n rook-ceph delete pod -l osd=0 -n rook-ceph
```

New OSD-0 pod came up clean on its pod IP within ~15s — no `public_network` filter, daemon bound to the first available interface, which on a pod-network pod is just `eth0` with the assigned `10.130.x.x` IP.

### The real failure mode: peering hung indefinitely with mixed network shapes

Now the cluster had:

- **OSD-0**: pod network, address `10.130.1.10` only
- **OSD-1**: still on host network (hadn't rolled yet), addresses `192.168.1.8` (frontnet) + `192.168.10.3` (backnet)
- **OSD-2**: same shape as OSD-1, addresses `192.168.1.9` + `192.168.10.4`
- **mons**: all still on host network, `192.168.1.7/.8/.9`

Mons advertised the new OSD-0 address (`10.130.1.10`) to the cluster, OSD-1 and OSD-2 saw it, and **PG peering started.** Then it hung. 220/220 PGs `peering`, no progress for 4+ minutes. Slow ops climbed monotonically: 10 → 269 → 521 → 770. Client I/O was effectively blocked.

The connectivity *should* have worked — OVN SDN passes pod↔host traffic in both directions, and the host network gets a default route back to pod IPs. But peering involves repeated multi-message handshakes per PG; if even a few percent of those messages drop or arrive at the wrong source-address (due to OVN's SNAT for pod→external traffic), cephx session establishment between OSDs stalls, and the PG never finishes peering. Worse, msgr2 sessions retry indefinitely without ever timing out hard enough for Ceph to give up and try a different path.

Other observability casualties as the storage froze:

- **Prometheus**: TSDB lives on a Ceph RBD PVC. Disk writes blocked, pod went `5/6 Running, 6 restarts`. Scrapes accumulated in memory until WAL pressure caused container restarts.
- **Grafana dashboards** ("Ceph Cluster", "Node Exporter Full", "Mikrotik" — though Mikrotik kept working): all "No data" because Prometheus stopped persisting samples.
- **ArgoCD UI/Server**: laggy but functional (its repo cache is on Ceph too).

### The deadlock — Rook's safety check refused to roll OSDs while peering was stuck

When peering hung, Rook's operator queued updates for OSD-0/1/2 Deployments but blocked all three on its `ceph osd ok-to-stop` safety check. Logs showed:

```
op-osd: [rook-ceph] OSD 0 is not ok-to-stop. will try updating it again later
op-osd: [rook-ceph] OSD 1 is not ok-to-stop. will try updating it again later
op-osd: [rook-ceph] OSD 2 is not ok-to-stop. will try updating it again later
```

…in a tight loop, indefinitely. Classic chicken-and-egg:

- Peering hung *because* OSD-0 advertised a pod IP that the other OSDs/mons couldn't establish reliable msgr2 sessions to
- Rook wouldn't roll OSD-0 back to hostNetwork *because* the ok-to-stop check requires peering to be healthy
- → No path forward without manual intervention

This is **the failure mode that breaks Rook's documented "host → empty → multus" path on a 3-OSD-no-drain cluster.** With 4+ OSDs and drain headroom, the safety check would still block, but you'd have replication margin to force-roll one. With 3 OSDs and `min_size: 2`, force-rolling two simultaneously risks I/O outage.

### Recovery — rollback + manual OSD-0 Deployment patch

Committed `provider: host` rollback (`2ddd69f`). ArgoCD synced the CephCluster CR back to `provider: host` with the original `addressRanges`. Rook's operator picked up the change and *tried* to update OSD-0/1/2 Deployments back to `hostNetwork: true` — but the same ok-to-stop check blocked all three.

So Rook re-applying its own desired state was *also* deadlocked by its own safety check. The CR was healthy, the Deployment specs were stale, and the operator was stuck.

Broke the deadlock with a direct kubectl patch on the OSD-0 Deployment, bypassing Rook:

```
oc -n rook-ceph patch deploy rook-ceph-osd-0 --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/hostNetwork","value":true}]'
```

The patched state matched what Rook *wanted* to apply, just without Rook's blocked safety gate. New OSD-0 pod came up with `hostNetwork: true`, bound to `192.168.1.7`, mons learned the new (host) address, peering resumed almost immediately:

- `220 peering` → `198 active+undersized+degraded` + `22 active+undersized` within seconds
- Slow ops `770 → 2` within ~30s
- Client I/O resumed; Prometheus recovered; Grafana dashboards repopulated

Note: `public_network = 192.168.1.0/24` was already back in the config DB by then — the operator had set it during its CephCluster reconcile (just couldn't update the Deployment). So OSD-0's restart picked the right interface automatically. The earlier `ceph config rm` to fix the original crash had been undone by Rook's reconcile already.

Backfill to clear the 33% objects-degraded ran in the background after recovery.

### Lessons + revised approach

1. **The Rook-documented `host → empty → multus` path is NOT safe on a 3-OSD-no-drain cluster.** The empty-intermediate state creates a network-shape heterogeneity (one OSD on pod network, others on host network) that hangs peering. Rook's own safety check then refuses to homogenize forward. The only escape is manual Deployment surgery, which defeats the purpose of using a managed operator.

2. **Rook's operator updates Deployment shape but not Ceph config DB on a network provider change.** The `public_network` setting in the mons' KV store survives a `provider` change and causes the new daemon shape to crash. This is at minimum surprising; possibly an upstream bug. Even if you successfully homogenized the network shape, you'd still hit this on every OSD restart until the operator (or someone) updates the config DB to match.

3. **`metadata.managedFields: []` makes SSA-driven field removal a no-op.** Resources created pre-SSA carry forever-sticky fields. We may want to do a one-time `oc apply --server-side --force-conflicts` on the CephCluster CR to establish ArgoCD as the field manager before the next risky spec change — or just stop expecting SSA removal to work for this resource.

4. **Observability stack is tightly coupled to storage.** When Ceph hung, Prometheus/Grafana/Loki all went dark in the same window, blinding us mid-incident. That's a real exposure — we should think about whether the monitoring stack should live on a different storage class (or at least how to inspect cluster state without the dashboards working).

**Revised path forward for client throughput uplift:**

Picking option (d) from the recovery decision tree: **abandon the Multus migration for now.** Reasons:

- The 10G storage backnet is already in use for OSD↔OSD replication, which was the dominant bottleneck in the bottleneck-sweep (per `blog/blog-rook-ceph-draft.md`).
- The expected client-throughput uplift from Multus (~118 MB/s → ~700 MB/s on 1M seqwrite) is real but doesn't justify the cost of working around the deadlock on a 3-OSD topology.
- Revisit when there's drain headroom (4+ nodes, or a hot-spare OSD), or when there's a path that doesn't require the empty-intermediate state.

Files left in place: NADs (`components/cluster-config/ceph-network-attachments/`) and the NNCP `ceph-shim` interface (`components/cluster-config/nmstate-nncp/`). They're harmless to keep — the NADs aren't referenced by any CephCluster spec anymore, and the shim+routing setup is dormant. Removing them is queued as a cleanup TODO but not urgent.

The README TODO line for the Multus migration will be revised to reflect this — moving the item from "in flight" to "queued, blocked on drain headroom" with the rationale captured here.




---

## 2026-05-13 evening: take 2 — fresh-rebuild on `provider: multus` from the start

**Premise change.** The 2026-05-12 rollback ruled out the `host → "" → multus` two-step on this topology. But the failure mode that closed that door — PG peering stalling under an asymmetric-address shape during the empty-provider intermediate — only exists *because* you're transitioning a live cluster through an intermediate state. A **fresh** cluster that comes up on `provider: multus` from the first daemon doesn't pass through that intermediate. No mixed-network peering shape can form because every daemon was born on the pod network.

The cost: nuke and pave. Every PVC on `ceph-nvme-block` (~255 GiB provisioned) is gone. RGW data pool with 46 GiB of Loki S3 chunks is gone. Prometheus's 15d of metrics is gone. The user signed off explicitly ("start with 2" — meaning skip the optional pre-flight backup and start at consumer-disable).

This is the kind of homelab call you can only make when the cluster's actual business value is small and replaceable: every workload reconstructs from git on next sync.

### Phase 2 — disable Ceph-PVC-consuming consumers (shipped, commit `2a20805`)

Disabled in `bootstrap/root-app/values.yaml`:
- `media` — 6 config PVCs (radarr/sonarr/etc) + the 500 GiB `media-data-pvc` (NFS, RetainPolicy=Retain → data survives even though the PV will end up Released)
- `logging-stack` — LokiStack CR + 9 PVCs (ingester storage + WAL + index-gateway + compactor) + Loki OBC against RGW
- `grafana-config` — Grafana CR + 1 PVC
- `gatus` — 1 PVC + status check history
- `monitoring-config` — ConfigMaps only (Prometheus/Alertmanager PVCs are operator-managed)
- `ceph-object-store` — CephObjectStore CR + RGW Deployment + Route

Left enabled: `smartctl-exporter` + `mikrotik-exporter` (no PVCs), `ceph-network-attachments` (the NADs are needed for Phase 4 bootstrap), `nmstate-nncp` (the ceph-shim is still load-bearing for storage backnet routing), `rook-ceph-operator` (needs to be alive to handle the teardown AND the new cluster bootstrap).

**Surprise**: the cluster drained itself harder than expected. Within 8 minutes:
- All 6 Applications gone via ArgoCD cascade-delete.
- Loki-operator + grafana-operator + media app cascade-cleaned their PVCs cleanly via CSI (pool-side RBD images properly deleted).
- **CMO recreated `prometheus-k8s` and `alertmanager-main` StatefulSets without volumeClaimTemplates** when the `cluster-monitoring-config` ConfigMap disappeared, switching them to emptyDir storage. This auto-deleted the four Prometheus + two Alertmanager PVCs that I'd assumed would need manual cleanup. (Bonus discovery: CMO's reaction to a missing ConfigMap is more aggressive than I'd expected — worth remembering.)
- End state before Phase 3: only `image-registry-storage` (NFS) and `media-data-pvc` (NFS, Released, data on disk) remained. `oc -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls -p nvme-replicated` returned empty. RGW pools still held 46 GiB Loki chunks + ~14 MiB metadata, which would get wiped on teardown anyway.

### Phase 3a — authorize Ceph cleanup (shipped, commit `9de2a34`)

`cleanupPolicy.confirmation: "yes-really-destroy-data"` set on the rook-ceph-cluster chart (with `sanitizeDisks.method: quick` left at the upstream default). ArgoCD applied it within seconds; live CR confirmed. No daemon impact — this string alone just authorizes Rook to zap disks on the next CR delete.

### Phase 3b — trigger teardown (shipped, commit `ff39676`)

`rook-ceph-cluster` disabled in root-app. ArgoCD cascade-deleted the Application; the CephCluster CR went with it; Rook's cleanup flow spawned a `cluster-cleanup-job-<node>` per node. Each one:

```
2026-05-13 18:06:39 I | cleanup: starting cluster clean up
2026-05-13 18:06:39 I | cleanup: successfully cleaned up "/var/lib/rook/rook-ceph" directory
2026-05-13 18:06:39 I | cleanup: successfully cleaned up the mon directory "/var/lib/rook/mon-a" on the dataDirHostPath "/var/lib/rook"
2026-05-13 18:06:39 I | cleanup: successfully cleaned up exporter directory "/var/lib/rook/exporter"
2026-05-13 18:06:41 I | cephosd: 1 ceph-volume raw osd devices configured on this node
2026-05-13 18:06:41 I | cleanup: sanitizing osd 0 disk "/dev/nvme0n1"
2026-05-13 18:06:41 I | cleanup: --> Zapping: /dev/nvme0n1
  Running command: /usr/bin/ceph-bluestore-tool zap-device --dev /dev/nvme0n1 --yes-i-really-really-mean-it
  Running command: /usr/bin/dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=10 conv=fsync
2026-05-13 18:06:41 I | cleanup: successfully executed sanitization command for osd disk "/dev/nvme0n1"
```

Each job finished in 4-5 seconds (small because the cluster had almost no data to wipe — the dd-zero of the first 10MB is what actually removes the BlueStore signature, and the partition table is overwritten implicitly). All three completed at ~18:07 UTC.

**End-of-night state (20:09 CEST):**
- 0 CephCluster / CephBlockPool / CephObjectStore / CephFilesystem CRs.
- `rook-ceph` namespace contains only the operator + CSI plugins.
- All 3 OSD disks (`/dev/nvme0n1` × node{4,5,6}) zapped and ready for fresh bootstrap.
- 21 ArgoCD apps Synced+Healthy (10 disabled but expected: ceph-cluster/ceph-storage-classes/rook-ceph-cluster/ceph-object-store/media/logging-stack/grafana-config/gatus/monitoring-config + the new rook-ceph-cluster wrapper).
- All nodes Ready. Zero non-Running pods cluster-wide.
- Both NFS-backed PVs persist (image-registry bound, media-data-pvc Released — data still on the NFS share at /volume1/kubenfs).
- Multus NADs (`ceph-cluster`, `ceph-public`) intact for Phase 4. ceph-shim NNCPs intact.

### Phase 4 — flip the chart to multus (shipped, 2026-05-14)

Pre-flight verified clean: NNCPs `storage-node{4,5,6}` Available; NADs `ceph-public` + `ceph-cluster` present in `rook-ceph`; zero Ceph CRs; only stale ConfigMap left is `rook-ceph-pdbstatemap` (operator will rewrite); no leftover monmap/auth secrets; CSI plugins + operator healthy.

Edit `components/storage/rook-ceph-cluster/values.yaml`:
- `network.provider: host` → `multus`
- Added `network.selectors.public: rook-ceph/ceph-public` + `network.selectors.cluster: rook-ceph/ceph-cluster` (explicit `<ns>/<name>` form even though the NADs are in the CephCluster's own namespace — same-namespace shorthand works, but the explicit form is what Rook prints in events and what survives a future namespace move)
- Removed `network.addressRanges` (Multus NAD IPAM owns the IPs; passing both is redundant + ambiguous)
- `cleanupPolicy.confirmation: "yes-really-destroy-data"` → `""` (close the loaded weapon)

Render check (`helm template … | kubeconform -strict -summary`) → 10 valid / 0 invalid / 1 skipped (the CRD without a catalog schema, expected). Rendered `CephCluster.spec.network`:

```
network:
  connections:
    compression: { enabled: false }
    encryption:  { enabled: false }
    requireMsgr2: false
  provider: multus
  selectors:
    cluster: rook-ceph/ceph-cluster
    public:  rook-ceph/ceph-public
```

No `addressRanges` block in the rendered output — confirmed clean.

### Phase 5+ — queued (next move in this session)

- **Phase 5**: `rook-ceph-cluster.enabled: false` → `true` in `bootstrap/root-app/values.yaml`. One-line commit; ArgoCD picks it up and bootstraps a fresh CephCluster on multus from the first daemon. Expected: mons come up with annotated pod IPs from the `ceph-public` NAD; OSDs get both `ceph-public` (client) and `ceph-cluster` (replication) NADs. Watch for the operator + cluster going Ready, `ceph -s` → HEALTH_OK, and pool autocreate honouring `pg_num_min: 128` on `nvme-replicated`.
- **Phase 6**: re-enable `ceph-object-store`. Also drop the router-anti-affinity hack from its values.yaml in the same commit — with RGW binding a pod IP (not `hostNetwork` on `:80`), the router co-residence collision that motivated the hack can't happen anymore. ObjectBucketClaims from Loki etc. need to re-create their buckets, since teardown nuked the RGW data pool too.
- **Phase 7**: re-enable `monitoring-config`, `logging-stack`, `grafana-config`, `gatus`, `media`. Loki ingester PVCs come back empty; Prometheus/Alertmanager StatefulSets re-acquire volumeClaimTemplates once `cluster-monitoring-config` ConfigMap returns (CMO will switch them off emptyDir).
- **Phase 8**: rebind `media-data-pvc` to the Released `nfs-csi` PV — preserves the 500 GiB media library across the rebuild (data was always on NFS, never on Ceph).

**Rollback plan if multus-bootstrap fails**: revert `provider: multus` → `host` in the chart values, restore `addressRanges`, drop `selectors`, commit. Fresh cluster comes up on host networking. Worst case +1 h.
