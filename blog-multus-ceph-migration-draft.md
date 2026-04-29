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

## What I still need to verify before starting

1. `oc get pods -n openshift-multus` — Multus operational.
2. `oc get pods -A | grep -i whereabouts` — whereabouts installed, or pick an alternative.
3. `ip link show enp1s0f0np0` on each node — confirm MTU; match in NAD config.
4. Read latest Rook docs for v1.19 specifically on the multus selector syntax (the field name has shifted between versions).
5. Confirm OKD 4.20 + OVN-Kubernetes + Multus + macvlan combination is supported (no SDN-specific gotcha).

Once those are answered: build the NAD chart, smoke-test, then plan the maintenance window for the daemon roll.
