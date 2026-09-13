# `Driver` reconcile ignores `deletionTimestamp`, recreates the owned DaemonSet/Deployment, and livelocks foreground deletion

**Upstream:** https://github.com/ceph/ceph-csi-operator
**Component:** Driver controller (`Driver.csi.ceph.io` reconcile)
**Affected version:** ceph-csi-operator v0.6.0 (`quay.io/cephcsi/ceph-csi-operator:v0.6.0`) as deployed by Rook v1.19.5, Kube 1.34 (OKD 4.21.0-okd-scos.11), ArgoCD v3.1.11
**Severity:** Operational — a `Driver` deleted with `propagationPolicy: Foreground` never finishes deleting. Its plugin DaemonSet and Deployment are garbage-collected and recreated every ~45 s until an operator clears the finalizer by hand. ArgoCD prunes with foreground propagation by default, so any GitOps-managed `Driver` hits this on removal.

## Summary

The Driver controller reconciles a `Driver` whose `metadata.deletionTimestamp` is already set, and "ensures" its owned plugin DaemonSet and Deployment exist. With foreground deletion the API server keeps the `Driver` alive under a `foregroundDeletion` finalizer until every dependent with `blockOwnerDeletion: true` is gone. The garbage collector deletes the DaemonSet and Deployment; the next reconcile recreates them, owned by the terminating `Driver` with `blockOwnerDeletion: true`; the GC deletes them again. Nothing converges.

## Observed

Rook had already disabled the driver (`ROOK_CSI_ENABLE_CEPHFS=false`) and stopped managing it:

```
2026-09-13 12:02:59.279614 I | op-k8sutil: operator setting "ROOK_CSI_ENABLE_CEPHFS" = "false"
2026-09-13 12:02:59.376221 I | ceph-csi: successfully removed CSI CephFS driver
2026-09-13 12:02:59.515019 I | ceph-csi: Creating RBD driver resources
```

The `Driver` had been deleted with foreground propagation at 12:01:51 (ArgoCD prune) and was still present four minutes later:

```
$ oc -n rook-ceph get drivers.csi.ceph.io rook-ceph.cephfs.csi.ceph.com \
    -o jsonpath='created={.metadata.creationTimestamp} deleting={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}'
created=2026-05-15T10:49:23Z deleting=2026-09-13T12:01:51Z finalizers=["foregroundDeletion"]
```

Its DaemonSet was created and deleted in the same second, owned by the terminating `Driver`:

```
$ oc -n rook-ceph get ds rook-ceph.cephfs.csi.ceph.com-nodeplugin \
    -o jsonpath='created={.metadata.creationTimestamp} owner={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name} block={.metadata.ownerReferences[0].blockOwnerDeletion} deleting={.metadata.deletionTimestamp}'
created=2026-09-13T12:05:25Z owner=Driver/rook-ceph.cephfs.csi.ceph.com block=true deleting=2026-09-13T12:05:25Z
```

The operator log for that second shows a full, successful reconcile of the terminating object:

```
2026-09-13T12:05:25Z  INFO  Starting reconcile iteration for Ceph CSI driver   {"Driver": {"name":"rook-ceph.cephfs.csi.ceph.com","namespace":"rook-ceph"}}
2026-09-13T12:05:25Z  INFO  Reconciling node plugin deployment
2026-09-13T12:05:25Z  INFO  Reconciling controller plugin deployment
2026-09-13T12:05:25Z  INFO  controller plugin deployment updated successfully
2026-09-13T12:05:25Z  INFO  node plugin daemonset updated successfully
2026-09-13T12:05:25Z  INFO  CSI Driver reconciliation completed successfully
```

The replacement nodeplugin pods never schedule, because the previous generation is still terminating on the same host ports:

```
Warning  FailedScheduling  pod/rook-ceph.cephfs.csi.ceph.com-ctrlplugin-656bf598f8-4xzlq
  0/3 nodes are available: 3 node(s) didn't match pod anti-affinity rules.
```

The DaemonSet accumulated 135 `SuccessfulCreate` pod events within the hour.

## Expected

One of:

- the reconcile returns early when `metadata.deletionTimestamp` is set, so foreground GC can finish; or
- the controller owns its own finalizer, tears down the DaemonSet, Deployment, Service and `CSIDriver` object itself, and removes the finalizer afterwards.

Either makes `kubectl delete driver <name> --cascade=foreground` terminate.

## Reproduction

1. Rook v1.19.5 with `ROOK_USE_CSI_OPERATOR` (the default), any `Driver` with running plugins.
2. Set the matching `ROOK_CSI_ENABLE_<DRIVER>` to `"false"` so Rook stops managing the `Driver` (optional; it only removes Rook from the picture).
3. `kubectl -n rook-ceph delete driver.csi.ceph.io <name> --cascade=foreground`.
4. Watch `kubectl -n rook-ceph get ds,deploy -w`: the plugin objects are deleted and recreated indefinitely; the `Driver` keeps `foregroundDeletion`.

## Workaround

Clear the finalizer; with the owner gone the background GC removes the children and there is nothing left to reconcile:

```
kubectl -n rook-ceph patch driver.csi.ceph.io <name> --type=merge -p '{"metadata":{"finalizers":null}}'
```

Prevention under ArgoCD: annotate the `Driver` `argocd.argoproj.io/sync-options: PrunePropagationPolicy=background`, sync, and only then remove it from the manifest.
