# `CSI_ENABLE_HOST_NETWORK: "true"` not propagated to `Driver.csi.ceph.io.spec.controllerPlugin.hostNetwork`

**Upstream:** https://github.com/rook/rook
**Component:** `pkg/operator/ceph/csi/` (CSI Driver CR reconciliation / OperatorConfig → Driver CR translation)
**Affected version:** Rook v1.19.5 (latest at time of writing) on Ceph Squid 19.2.3 (deployed via OKD 4.20 / Kube 1.31)
**Severity:** Functional — on clusters with `network.provider: host` + `network.addressRanges` pinning Ceph daemons to a non-K8s-default subnet, CSI ctrlplugin pods land on the pod network and cannot reach OSDs across nodes. Every `CreateVolume` hangs.

## Summary

Rook 1.19 split CSI plugin management into a separate `ceph-csi-operator` that reconciles `Driver.csi.ceph.io` CRs into the actual `Deployment` (ctrlplugin) and `DaemonSet` (nodeplugin) objects. The legacy operator-config ConfigMap (`rook-ceph-operator-config`) still carries `CSI_ENABLE_HOST_NETWORK` as a documented knob, but Rook **only** translates it to the **nodeplugin DaemonSet** — the **ctrlplugin Deployment** stays on the pod network because `Driver.spec.controllerPlugin.hostNetwork` is never set.

Observed live state with `CSI_ENABLE_HOST_NETWORK: "true"` set:

```
$ oc -n rook-ceph get cm rook-ceph-operator-config -o jsonpath='{.data.CSI_ENABLE_HOST_NETWORK}'
true

$ oc -n rook-ceph get ds rook-ceph.rbd.csi.ceph.com-nodeplugin -o jsonpath='{.spec.template.spec.hostNetwork}'
true            ← correctly applied

$ oc -n rook-ceph get deploy rook-ceph.rbd.csi.ceph.com-ctrlplugin -o jsonpath='{.spec.template.spec.hostNetwork}'
(empty)         ← NOT applied

$ oc -n rook-ceph get driver.csi.ceph.io rook-ceph.rbd.csi.ceph.com -o jsonpath='{.spec.controllerPlugin.hostNetwork}'
(empty)         ← Driver CR field never set by Rook
```

The CRD schema for `csi.ceph.io/v1` Driver explicitly supports `spec.controllerPlugin.hostNetwork` (verified with `oc explain drivers.csi.ceph.io.spec.controllerPlugin --recursive | grep hostNetwork` → `hostNetwork <boolean>`), so it's a translation gap, not a missing capability.

## Why this matters on multi-network clusters

On a homelab with two host NICs (1G frontnet + 10G storage backnet), the typical recommended shape is:

```yaml
spec:
  network:
    provider: host
    addressRanges:
      public:
        - "192.168.10.0/24"     # backnet
      cluster:
        - "192.168.10.0/24"     # backnet
```

OSDs/mgrs/mons honor this (modulo a separate mon-binding quirk — see `bugs/upstream-rook-csi-rbd-provisioner-missing-osd-cap.md` for the cap bug story; mon-on-frontnet is filing-worthy separately). OSDs bind to `192.168.10.X:6800` etc.

But the CSI ctrlplugin is on the pod network (CNI-managed `10.128.0.0/14` on OpenShift OVN-K). Pod-network → cross-node `192.168.10.0/24` is not reachable under OVN-K shared-gateway mode (the default) — even `routingViaHost: true` only fixes the same-node case because remote OSDs can't route the pod-CIDR source IP back without an overlay path. So `CreateVolume` hangs at the omap-write step (the gRPC handler's first RADOS call hangs trying to reach an OSD over the backnet), the gRPC stream times out, and the rbd-plugin's per-volume operation tracker is now stuck. Symptom is the well-known "operation already exists" lock storm on every retry, but the root cause is the network shape, not the tracker.

## Steps to reproduce

1. Deploy a fresh `CephCluster` on a multi-NIC cluster with `provider: host` + `network.addressRanges` set to a subnet that is NOT the K8s-registered nodeIP subnet.
2. Confirm `rook-ceph-operator-config.CSI_ENABLE_HOST_NETWORK` is `"true"`.
3. After `HEALTH_OK`, apply a PVC against the RBD StorageClass.
4. Watch the PVC stay `Pending` forever. `csi-rbdplugin` sidecar log shows the `DeadlineExceeded → CANCEL` chain, then `Aborted: operation already exists` on every retry.
5. `oc -n rook-ceph get pod -l app=rook-ceph.rbd.csi.ceph.com-ctrlplugin -o jsonpath='{.items[*].spec.hostNetwork}'` returns empty — pods are NOT hostNetwork.

## Expected behavior

When `CSI_ENABLE_HOST_NETWORK: "true"` is set in `rook-ceph-operator-config`, Rook should propagate the setting to BOTH the nodeplugin AND ctrlplugin via the Driver CR:

```yaml
spec:
  controllerPlugin:
    hostNetwork: true
  nodePlugin:
    hostNetwork: true   # already applied today
```

(Or — preferably — split into two knobs since these have different security implications and may need to be tuned independently. The ctrlplugin binds host ports for metrics and the leader-elect socket, which is a more visible footprint than the nodeplugin's mount-handler.)

## Actual behavior

Only `nodePlugin.hostNetwork` is honored. `controllerPlugin.hostNetwork` stays empty on the Driver CR, so the ctrlplugin Deployment's pod template doesn't set `hostNetwork: true`, and pods land on the pod network.

## Workaround

Patch the Driver CRs directly via SSA. In our repo this lives in `components/cluster-config/csi-driver-config/` (chart with one template that emits both Driver CRs with `spec.controllerPlugin.hostNetwork: true`). ArgoCD with ServerSideApply merges the patch with the live Driver CR; Rook leaves the field alone on subsequent reconciles (verified across the operator's reconciliation loop on our cluster).

Equivalent imperative form:

```
oc -n rook-ceph patch driver.csi.ceph.io rook-ceph.rbd.csi.ceph.com \
  --type=merge \
  -p '{"spec":{"controllerPlugin":{"hostNetwork":true}}}'

oc -n rook-ceph patch driver.csi.ceph.io rook-ceph.cephfs.csi.ceph.com \
  --type=merge \
  -p '{"spec":{"controllerPlugin":{"hostNetwork":true}}}'
```

After the patch, the ctrlplugin Deployment's pod template gains `hostNetwork: true` on the next reconcile, fresh pods come up with `podIP == hostIP`, and CreateVolume completes within seconds.

## Notes

- This bug compounds with `bugs/upstream-rook-csi-rbd-provisioner-missing-osd-cap.md` on a fresh bootstrap. Symptoms look identical (both produce "operation already exists" lock storms); but they are independent and both need their respective workarounds applied before CSI works again.
- `CSI_ENABLE_HOST_NETWORK` is documented in the Rook 1.x helm chart values as the canonical way to enable host networking for CSI plugins. The 1.19 refactor introduces the new Driver CR but the documented knob's contract should still hold — otherwise the chart's values reference is misleading.
- Verified that Rook does NOT revert the manual patch — the controllerPlugin.hostNetwork field is owned by the SSA field manager once applied, and Rook leaves it alone on subsequent reconciles. So a one-time SSA patch survives operator restarts.

## Local context where this was observed

- 3-node OKD 4.20 bare-metal cluster, 3× Samsung PM9A1 NVMe (one OSD per node).
- Rook v1.19.5, ceph-csi-operator from the same release.
- Ceph image: `quay.io/ceph/ceph:v19.2.3`.
- `network.provider: host` with `addressRanges.public/cluster: ["192.168.10.0/24"]` (10G backnet binding).
- OVN-Kubernetes default shared-gateway mode (`routingViaHost: false`); later set to `true` but the cross-node case still needed the Driver CR patch (`routingViaHost` only fixes same-node pod→backnet, not cross-node).
- Full chronology + benchmark numbers in `blog/blog-multus-ceph-migration-draft.md` (2026-05-15 section).
