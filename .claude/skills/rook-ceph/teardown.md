# Rook-Ceph teardown and rebuild

Moved verbatim from the root `CLAUDE.md` on 2026-09-24. Sections the moved text refers to by name now live here:

- "network pre-flight", "restart ALL 3 ovnkube-node", `br-ex.forwarding`, "Node drain" → `.claude/skills/network-change/SKILL.md`
- Health sweep and alert triage → `.claude/skills/cluster-health/SKILL.md`
- Guardrails, "Blog notes", "Validation workflow" → root `CLAUDE.md`

## Clean teardown procedure — "fresh install" means **fresh**

`cleanupPolicy.confirmation: "yes-really-destroy-data"` + disabling the app zaps OSD disks via Rook's cleanup-jobs, but leaves a long tail of namespace-level state that the next fresh bootstrap inherits and gets confused by. **Each item below bit us individually on 2026-05-14 — clean ALL of them as part of every teardown, not after symptoms appear.**

After the cleanup-jobs complete (verify with `oc -n rook-ceph get jobs | grep cluster-cleanup-job` — all `Complete`), run the full sweep:

```bash
# 1. Rook mon-tracking state (else next bootstrap hangs at "detecting the ceph image version"):
oc -n rook-ceph delete cm rook-ceph-mon-endpoints rook-ceph-pdbstatemap --ignore-not-found
oc -n rook-ceph delete secret rook-ceph-mon --ignore-not-found
oc -n rook-ceph patch cm rook-ceph-mon-endpoints -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
oc -n rook-ceph patch secret rook-ceph-mon -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null

# 2. Bootstrap Jobs from prior cluster (immutable; ArgoCD can't re-apply, blocks sync).
# Every bootstrap Job in components/storage/rook-ceph-cluster/templates/*.yaml is fair game.
# Current list as of 2026-09-24 (templates and live agree):
for j in csi-rbd-provisioner-caps-fix-bootstrap mgr-pool-crush-rule-bootstrap pg-num-floor-bootstrap rbd-trash-purge-schedule-bootstrap; do
  oc -n rook-ceph delete job $j --ignore-not-found
done
oc -n rook-ceph delete jobs -l rook-ceph-cleanup --ignore-not-found

# 2b. Stuck Ceph CR finalizers — Rook can't reconcile its own delete once the CR is in Deleting:
oc -n rook-ceph patch cephcluster rook-ceph -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
for bp in $(oc -n rook-ceph get cephblockpool -o name 2>/dev/null); do
  oc -n rook-ceph patch $bp -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 2c. Stale cluster-scoped ObjectBuckets (else a new OBC stays Pending with "bucketName has changed compared to ob").
# Only relevant if the object store was re-enabled — RGW and every OBC were retired 2026-09-07, so this is normally a no-op:
for ob in $(oc get objectbucket -o name 2>/dev/null); do
  oc patch $ob -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  oc delete $ob --ignore-not-found 2>/dev/null
done

# 2d. Stale clientprofiles.csi.ceph.io (else rook-ceph namespace stuck Terminating):
for cp in $(oc -n rook-ceph get clientprofiles.csi.ceph.io -o name 2>/dev/null); do
  oc -n rook-ceph patch $cp -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 3. Orphan Released PVs (block csi-provisioner cluster-wide):
for PV in $(oc get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' | grep ceph-nvme); do
  oc patch pv $PV -p '{"metadata":{"finalizers":[]}}' --type=merge
  oc delete pv $PV --ignore-not-found
done

# 4. Orphan VolumeAttachments:
for VA in $(oc get volumeattachment -o name); do
  oc patch $VA -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 5. Test-namespace PVCs still around from prior runs:
oc -n default get pvc 2>/dev/null | awk 'NR>1 && $4=="ceph-nvme-block" {print $1}' | xargs -r -I {} oc -n default patch pvc {} -p '{"metadata":{"finalizers":[]}}' --type=merge

# 6. CSI plugin in-memory state — bounce the RBD plugin pods (operator recreates; the CephFS driver is off since 2026-09-13):
oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-nodeplugin --wait=false
oc -n rook-ceph delete pod -l app=rook-ceph.rbd.csi.ceph.com-ctrlplugin --wait=false

# 7. Bounce the rook-operator for a fully clean reconcile slate:
oc -n rook-ceph delete pod -l app=rook-ceph-operator
```

The SA dockercfg secrets (`builder-dockercfg-*`, `ceph-csi-*-dockercfg-*`, `rook-ceph-*-dockercfg-*`) are cosmetic OpenShift-managed artifacts; they get regenerated when the SAs are next used. Leave them alone.

**Symptom map — which leftover causes which symptom:**

| Symptom | Likely leftover |
|---|---|
| Bootstrap hangs at `"detecting the ceph image version"` | `rook-ceph-mon-endpoints` CM + `rook-ceph-mon` Secret |
| ArgoCD app stuck `OutOfSync`, `Job is invalid: spec.selector: Required value` | Any bootstrap Job from prior cluster — `rbd-trash-purge-schedule-bootstrap`, `csi-rbd-provisioner-caps-fix-bootstrap`, etc. (immutable; can't be `kubectl replace`'d) |
| Teardown stops with `CephObjectStore` / `CephBlockPool` / `CephCluster` stuck in `Deleting` for >5min | Rook finalizer can't reconcile (operator stopped watching) — force-clear `metadata.finalizers` to `[]` |
| `CephFilesystem` / `CephObjectStore` stuck `Deleting` right after their daemons were removed | **Rook's dependent check needs the daemon it already tore down.** It lists buckets via the RGW admin API (`no such host` once the Service is gone) and subvolumegroups via the MDS (`exec timeout` once zero MDS pods remain), so the finalizer can NEVER clear. Confirmed 2026-09-07. Force-clear is the only exit; verify the dependents are empty BEFORE the daemons go down, because afterwards you cannot. Every CephFS/object-store retirement here ends this way |
| A purged OSD **reappears** a few minutes later, often with a blank `CLASS` in `ceph osd tree` | **`ceph osd purge` does not remove the on-disk BlueStore signature.** `cephClusterSpec.storage.nodes[].devices` gates only NEW provisioning; on every reconcile Rook also runs `ceph-volume raw list` and re-adopts ANY disk still carrying a signature, allowlist or not (`cephosd: N ceph-volume raw osd devices configured on this node` in the osd-prepare log). Confirmed 2026-09-08 — osd.3 came back 25 min after a clean purge, on the reconcile triggered by an unrelated node's device removal. **Removing an OSD needs a fourth step: kill the signature.** Either zap the disk (no reboot — the right call if the drive is STAYING) or physically pull it (no zap — the right call if it is leaving anyway, since the 3.5" bay is not hot-swap). Purge AFTER the signature is gone, never before |
| Pools survive after their CR is pruned | `preservePoolsOnDelete: true` (and `preserveFilesystemOnDelete`) — working as intended. Deleting the CR removes the daemons and stops Rook managing them; the pools are deleted deliberately from the toolbox behind `mon_allow_pool_delete`. Skipping this leaves PGs on OSDs you are about to remove |
| An OBC takes ~an hour to delete and looks stalled | The provisioner sends `DELETE /admin/bucket?purge-objects=true` as ONE synchronous call with a client timeout it cannot meet at ~20k objects on HDD. It progresses only by timing out and retrying; once workqueue backoff stretches it looks dead **while the bucket is already gone**. Restart `rook-ceph-operator` to reset the backoff |
| ObjectBucketClaim (OBC) stays `Pending`, operator log says `"bucketName has changed compared to ob"` | Stale cluster-scoped `ObjectBucket` from prior cluster — delete it |
| `rook-ceph` namespace stuck `Terminating`, status says `clientprofiles.csi.ceph.io has 1 resource instances` | Stale `clientprofile.csi.ceph.io` finalizer — force-clear |
| csi-provisioner spins forever on volume IDs unrelated to current PVCs | Orphan Released PVs |
| New PVC stuck `Pending` even after provisioner restart | Combination of orphan PVs + stale VAs blocking the serialized provisioner |
| `NodeStageVolume` returns "operation already exists" immediately on first mount | Stale VA + plugin in-memory tracker on a volume that no longer exists |
| Every `CreateVolume` returns "operation already exists" on a freshly-bootstrapped cluster | `client.csi-rbd-provisioner.<gen>` missing `osd profile rbd` cap (Rook 1.19.5 bug — see RBD CSI quirks above; chart-shipped Job auto-fixes on next sync if it ran) |
| A pruned `Driver.csi.ceph.io` sits in `Deleting` while its plugin DaemonSet/Deployment are recreated every ~45 s, new pods Pending on anti-affinity against their own terminating predecessors | **Foreground-prune livelock (found 2026-09-13, disabling the CephFS driver).** ArgoCD prunes with `foreground` propagation, so the CR carries only the `foregroundDeletion` finalizer and waits for its dependents; ceph-csi-operator keeps reconciling the terminating Driver and recreates the owned DaemonSet/Deployment (`blockOwnerDeletion: true`), so the GC never finishes. Rook is NOT the culprit once `ROOK_CSI_ENABLE_<X>` reads false. Unstick (user-run): `oc -n rook-ceph patch driver.csi.ceph.io <name> --type=merge -p '{"metadata":{"finalizers":null}}'` — the owner vanishes, background GC removes the children, the operator has nothing left to reconcile. Prevention: annotate the resource `argocd.argoproj.io/sync-options: PrunePropagationPolicy=background` and let that sync BEFORE removing it from the manifest. Applies to any operator-owned CR ArgoCD prunes while the operator still reconciles it |

If you're tearing down, run the full sweep. If you discover one of these symptoms during a botched bootstrap, the table above tells you which subset of the sweep to apply.
