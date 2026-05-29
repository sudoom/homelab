# Graceful cluster shutdown — vacation procedure

Working draft. Captures the pre-shutdown sequence and the return runbook for a hyperconverged 3-node Ceph+OKD cluster, where the standard `oc adm drain` doesn't apply (no headroom for pods to land elsewhere). Tested 2026-05-29.

## Framing

`oc adm drain` is the wrong tool for this cluster. Every node is both a control-plane master AND a worker AND a Ceph OSD host. There's nowhere for evicted workloads to go. The right procedure is to put the cluster into a maintenance posture, cordon nodes (informational only, since nothing can move), and shut down the OS on each.

The two state mutations that matter are:

1. **Ceph maintenance flags** — `noout`, `nobackfill`, `norecover`, `norebalance`. Without `noout`, the first node down triggers Ceph's 10-min OSD-out timer → CRUSH starts trying to rebalance against 0 available targets → bad state on power-up.
2. **ArgoCD auto-sync paused** — so it doesn't fight any drift while the cluster is being brought back up.

Everything else (cordon, schedule pause, etcd order) is hygiene.

## Pre-shutdown sequence (2026-05-29 run)

```bash
# 1. Fresh OADP backup so last-known-good state lives in RGW (which also goes down,
#    but the metadata is captured for if anything fails to come back).
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: pre-shutdown-$(date -u +%Y%m%d-%H%M%S)
  namespace: openshift-adp
spec:
  storageLocation: default
  ttl: 720h0m0s          # 30 days
  snapshotMoveData: false
  includeClusterResources: true
EOF

# 2. Pause the OADP daily Schedule (else it fires at 02:00 UTC while the cluster
#    is down → cron-backoff cascade on first power-up).
oc -n openshift-adp patch schedule daily --type=merge -p '{"spec":{"paused":true}}'

# 3. Set Ceph maintenance flags.
for f in noout nobackfill norecover norebalance; do
  oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set $f
done
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s   # verify "flags noout,nobackfill,norebalance,norecover"

# 4. Pause ArgoCD root-app auto-sync.
oc -n openshift-gitops patch application root-app \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 5. Cordon all 3 nodes (informational — pods can't move anyway).
for n in node4 node5 node6; do oc adm cordon ${n}.okd.sudops.pl; done
```

## OS-level shutdown (must be done from a workstation with SSH access)

```bash
ssh core@node6.okd.sudops.pl 'sudo systemctl poweroff'
sleep 30
ssh core@node5.okd.sudops.pl 'sudo systemctl poweroff'
sleep 30
ssh core@node4.okd.sudops.pl 'sudo systemctl poweroff'
```

Order is `node6 → node5 → node4`. Etcd quorum stays at 3 → 2 → 1 → 0 with ~30s between transitions; cleaner than all three losing the API simultaneously. node4 last because the API VIP usually lands there.

Wait ~2 min after the last `poweroff` returns before pulling wall power — OS needs to flush + sync.

## Return-from-vacation runbook

```bash
# 1. Power on all 3 nodes (any order — etcd forms quorum once 2 are up).

# 2. Wait for SSH on node4.
until ssh core@node4.okd.sudops.pl true; do sleep 10; done

# 3. Re-login (oc token will be expired).
oc login --token=<new-token> --server=https://api.okd.sudops.pl:6443

# 4. Wait for all 3 nodes Ready (still SchedulingDisabled from cordon).
oc get nodes -w   # Ctrl+C when all 3 show Ready,SchedulingDisabled

# 5. Uncordon.
for n in node4 node5 node6; do oc adm uncordon ${n}.okd.sudops.pl; done

# 6. Clear Ceph maintenance flags.
for f in noout nobackfill norecover norebalance; do
  oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset $f
done

# 7. Wait for Ceph HEALTH_OK or HEALTH_WARN with only BLUESTORE_SLOW_OP_ALERT.
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s

# 8. Re-enable ArgoCD auto-sync.
oc -n openshift-gitops patch application root-app \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# 9. Un-pause OADP Schedule.
oc -n openshift-adp patch schedule daily --type=merge -p '{"spec":{"paused":false}}'

# 10. Standard start-of-session sweep per CLAUDE.md to confirm clean recovery.
```

## What we learned this run

- **`PartiallyFailed` on the pre-shutdown backup is expected** because of the NFS-CSI snapshot mismatch. Velero tries to take a CSI snapshot of `media/media-data-pvc` (provisioned by `nfs.csi.k8s.io`), fails because there's no `VolumeSnapshotClass` labelled `velero.io/csi-volumesnapshot-class` for the NFS-CSI driver. NFS is a file-share, not a block device — no native snapshot support. All 29 actual Ceph-RBD CSI snapshots completed. The error is logged, the rest of the backup succeeds.
- **Recoverable from RGW for 30 days.** The `ttl: 720h` on the pre-shutdown backup keeps it well past any reasonable vacation length.
- **`automated: null` is the SSA-safe way to pause sync.** `automated: {}` doesn't disable it (empty struct still means "automated enabled with defaults"); `null` removes the field entirely.

## Open items (post-vacation)

- Either ship a `VolumeSnapshotClass` for `nfs.csi.k8s.io` (probably with `csi.storage.k8s.io/snapshotter-secret-name` pointing at the Synology DSM creds, since DSM does support snapshots for shares) OR exclude NFS-backed PVCs from CSI snapshot consideration in the Schedule spec via `snapshotVolumes: false` for those PVCs. Lower priority — the data lives on Synology and is durable independent of Ceph.
- Document the BMC/IPMI auto-power-on settings (if any) — current shutdown requires SSH + `systemctl poweroff`; if BMC could auto-resume on AC restore, that's a simpler "kick the breaker" model for power-cut scenarios.
