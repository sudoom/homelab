# Driver reconcile continues when the Driver CR is not found, and recreates its CSIDriver

**Upstream:** https://github.com/ceph/ceph-csi-operator
**Component:** Driver controller, `LoadAndValidateDesiredState` / `reconcile` (`internal/controller/driver_controller.go`)
**Affected version:** v1.1.0 (`quay.io/cephcsi/ceph-csi-operator:v1.1.0`, deployed by Rook v1.21.1 through the
`ceph-csi-drivers` 1.1.0 chart), Kubernetes 1.35 (OKD 4.22). The same code is on `main` (lines 437-441 as of 2026-11-07).
**Status:** draft, not filed.

---

## Title

Driver reconcile runs all reconcilers when the Driver CR is not found

## Body

Since #612 (9111aa67, "controller: skip if the driver CR is not present"), `LoadAndValidateDesiredState` returns nil
when the Driver is not found:

```go
if err := r.Get(r.ctx, client.ObjectKeyFromObject(&r.driver), &r.driver); err != nil {
    r.log.Error(err, "Unable to load driver.csi.ceph.io", "name", client.ObjectKeyFromObject(&r.driver))
    //return nil if the driver is not present or else return err
    return client.IgnoreNotFound(err)
}
```

`reconcile()` only stops on an error from it, so for a missing Driver it goes on and runs every reconciler against an
empty `Driver` with only name and namespace set. The reconcile is not skipped.

**Observed.** A `CSIDriver` `rook-ceph.cephfs.csi.ceph.com` was left from a Driver deleted earlier. It carries
`csi.ceph.io/ownerref: {"Namespace":"rook-ceph","Name":"rook-ceph.cephfs.csi.ceph.com"}`, so the `CSIDriver` watch
enqueues that Driver. On every operator start:

```
ERROR Unable to load driver.csi.ceph.io {"name": "rook-ceph.cephfs.csi.ceph.com", "namespace": "rook-ceph"} ... Driver.csi.ceph.io "rook-ceph.cephfs.csi.ceph.com" not found
ERROR Failed creating controller plugin deployment ... Deployment.apps "rook-ceph.cephfs.csi.ceph.com-ctrlplugin" is invalid: [metadata.ownerReferences.uid: Invalid value: "": must not be empty, ...
ERROR Failed creating node plugin daemonset ... DaemonSet.apps "rook-ceph.cephfs.csi.ceph.com-nodeplugin" is invalid: [metadata.ownerReferences.uid: Invalid value: "": must not be empty, ...
ERROR Failed creating NetworkPolicy ... NetworkPolicy.networking.k8s.io "rook-ceph.cephfs.csi.ceph.com-ctrlplugin" is invalid: metadata.ownerReferences.uid: Invalid value: "": must not be empty
ERROR Failed updating CSI Config Map ... ConfigMap "ceph-csi-config" is invalid: metadata.ownerReferences.uid: Invalid value: "": must not be empty
```

42 `CSI Driver reconciliation failed` lines in the first minute, then the usual backoff. The namespaced objects are
rejected only because the empty Driver has no UID. `reconcileK8sCsiDriver` needs no owner UID, so it succeeds:
deleting the leftover `CSIDriver` brings it back in the same second.

```
$ oc delete csidriver rook-ceph.cephfs.csi.ceph.com      # 21:27:04Z
$ oc get csidriver rook-ceph.cephfs.csi.ceph.com -o jsonpath='{.metadata.creationTimestamp}'
2026-11-07T21:27:04Z
```

The delete event enqueues the Driver through the ownerref annotation, and the reconcile recreates the object. It could
only be removed by deleting the operator pod and then the `CSIDriver` before the new pod started.

**Reproduce.** With no Driver `<ns>/<ns>.cephfs.csi.ceph.com`, create a `CSIDriver` of that name with the annotation
`csi.ceph.io/ownerref: {"Namespace":"<ns>","Name":"<ns>.cephfs.csi.ceph.com"}`, then delete it. It is recreated, and
the operator log shows the create attempts above.

**Expected.** A missing Driver ends the reconcile with nothing created, as #612 intended. For example, have `reconcile()`
return nil when the Driver was not found (a found flag from `LoadAndValidateDesiredState`, or `r.driver.UID == ""`
after it) instead of continuing to the reconcilers.
