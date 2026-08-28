# OADP storage-class migration rehearsal

Proves `cephfs-hdd` → `nfs-truenas-keepers` end to end with Velero's
`change-storage-class` RestoreItemAction, against the **garage BSL on TrueNAS**,
at ~20 MB instead of 3.21 TiB.

This is the design the real `media-data-pvc` migration uses. Everything here is
operator-run: every step is a cluster mutation.

## Why rehearse at all

OADP 1.5 has been installed for 91 days and has taken **zero backups** — the
daily `Schedule` is `paused: true` since the 2026-06-08 incident. The restore
path is completely unproven. A migration is a bad first exercise of an untested
restore.

## Gates — each must pass before the next

```bash
# 0a. target StorageClass exists (was the blocker: truenas.enabled was false)
oc get sc nfs-truenas-keepers

# 0b. garage BSL is Available (needs the SealedSecret; see the oadp chart values)
oc -n openshift-adp get bsl truenas-garage -o jsonpath='{.status.phase}{"\n"}'

# 0c. CSI pre-flight per CLAUDE.md — a stray Released PV blocks the provisioner
#     cluster-wide and will present as a Velero bug
oc get pv | grep -E "Released|Failed"
oc get volumeattachment | awk '$5=="true"'
```

## Run

```bash
oc apply -f 01-source.yaml
oc -n scmigrate-src wait --for=condition=Ready pod/writer --timeout=120s

# populate + record the ground truth
oc -n scmigrate-src exec writer -- sh -c '
  mkdir -p /data/tree/a /data/tree/b
  for i in $(seq 1 300); do dd if=/dev/urandom of=/data/tree/a/f$i.bin bs=64k count=1 2>/dev/null; done
  echo sentinel > /data/SENTINEL
  cd /data && find . -type f ! -name MANIFEST.sha256 -exec sha256sum {} + | sort -k2 > MANIFEST.sha256
  echo "files=$(find . -type f ! -name MANIFEST.sha256 | wc -l)"
  echo "bytes=$(du -sb /data | cut -f1)"
  echo "manifest_digest=$(sha256sum MANIFEST.sha256 | cut -d" " -f1)"'

oc apply -f 03-backup.yaml
oc -n openshift-adp wait --for=jsonpath='{.status.phase}'=Completed backup/scmigrate-1 --timeout=600s

# GATE: exactly one PodVolumeBackup, Completed, non-zero bytes.
# Zero PVBs == a green backup containing nothing. Stop and fix; do not restore.
oc -n openshift-adp get podvolumebackups -l velero.io/backup-name=scmigrate-1 \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,BYTES:.status.progress.totalBytes

oc apply -f 02-changesc-configmap.yaml
oc apply -f 04-restore.yaml
oc -n openshift-adp wait --for=jsonpath='{.status.phase}'=Completed restore/scmigrate-1-to-nfs --timeout=900s

# DELETE THE CONFIGMAP NOW — it is cluster-wide and unscoped.
oc delete -f 02-changesc-configmap.yaml
```

## Verify — four layers

The first layer is the one that matters: it distinguishes *"the SC field was
rewritten"* from *"the bytes are actually on the NAS"*.

```bash
# 1. backend identity
PV=$(oc -n scmigrate-dst get pvc scmigrate-data -o jsonpath='{.spec.volumeName}')
oc get pv $PV -o jsonpath='{.spec.csi.driver} {.spec.csi.volumeAttributes.server}:{.spec.csi.volumeAttributes.share}{"\n"}'
# want: nfs.csi.k8s.io 192.168.10.10:/mnt/tank/keepers
# rook-ceph.cephfs.csi.ceph.com == the Retain branch fired, NOTHING MOVED

# 2. checksum replay
oc -n scmigrate-dst exec writer -- sh -c '
  cd /data && sha256sum -c MANIFEST.sha256 > /tmp/c 2>&1
  echo "ok=$(grep -c ": OK$" /tmp/c)"; grep -v ": OK$" /tmp/c || echo ALL-OK'

# 3. byte reconciliation across subsystems that cannot collude
oc -n openshift-adp get podvolumerestores -l velero.io/restore-name=scmigrate-1-to-nfs \
  -o custom-columns=PHASE:.status.phase,BYTES:.status.progress.totalBytes
# zero PodVolumeRestores == empty PVC, visible without exec

# 4. ground truth on the NAS
ssh truenas_admin@192.168.1.25 "ls -la /mnt/tank/keepers/$PV/"
```

## Executed 2026-08-28 — PASSED

All four verification layers passed. Results in
`blog/blog-truenas-migration-draft.md`. Two things the run taught that are now
folded into the commands above:

**`oc get backup` is AMBIGUOUS on this cluster.** It resolves to CNPG's
`backups.postgresql.cnpg.io`, not Velero's. Every status query must name the
kind explicitly — `backups.velero.io` / `restores.velero.io` — or you get
`Error from server (NotFound)` on a backup that is running perfectly and a wait
loop that never matches.

**Teardown of the NFS orphan needs root ON THE NAS.** Restored files are owned
by the source namespace's SCC uid (kopia preserves uid/gid), so
`truenas_admin` cannot remove them:
```
rm: cannot remove '.../SENTINEL': Permission denied
```
Use `ssh truenas_admin@192.168.1.25 'sudo rm -rf /mnt/tank/keepers/<pv>'`.

**Purging the CephFS orphan is the dangerous step — identify positively.**
`ceph fs subvolume ls cephfs csi` lists the rehearsal subvolume *next to the one
backing the live 3.21 TiB media library*. Confirm three ways before removing
anything: the media PV names its own subvolume
(`oc get pv <media-pv> -o jsonpath='{.spec.csi.volumeAttributes.subvolumeName}'`),
only one CephFS PV exists cluster-wide, and `ceph fs subvolume info` shows
`bytes_used` ~19 MB for the orphan versus ~3.5 TB for media.

## Failure modes worth knowing

The two **silent** ones are more dangerous than the loud ones.

| Symptom | Cause |
|---|---|
| Backup `Completed`, no PodVolumeBackups | FSB never ran — annotation names the PVC instead of the pod volume, or no pod mounts it |
| Restore `Completed`, PVC still on `cephfs-hdd` | velero log: `Restoring persistent volume as-is because it doesn't have a snapshot and its reclaim policy is not Delete` — the Retain branch. Reachable only when FSB did not run |
| Backup `PartiallyFailed` | CSI snapshot attempted on CephFS — `snapshotVolumes: false` missing |
| `No storage class mappings found` | ConfigMap absent, wrong namespace, or missing a label |
| `error getting storage class ... from API` | target SC does not exist |
| PVC `Pending`, `access denied by server while mounting` | node IP not in the export host list |
| PVC `Pending`, `mkdir ...: permission denied` | root squash — `maproot_user: root` missing on the export |
| Restored pod `Init:0/1` | `restore-wait` polling for the kopia sentinel. Read the PodVolumeRestore, not the init container |
| `DataUpload` CRs appear | category error — those belong to the CSI data mover. Your Backup did not use FSB |

## Teardown — not optional

```bash
oc delete ns scmigrate-src scmigrate-dst
# BOTH cephfs-hdd and nfs-truenas-* are reclaimPolicy: Retain -> two orphan PVs
oc get pv | grep Released
oc delete pv <cephfs-pv> <nfs-pv>
oc -n openshift-adp delete backup scmigrate-1 restore scmigrate-1-to-nfs
oc -n openshift-adp get cm change-storage-class-config    # MUST be NotFound
# purge what Retain left behind: the CephFS subvolume (toolbox) and
# /mnt/tank/keepers/<pv>/ on the NAS
```
