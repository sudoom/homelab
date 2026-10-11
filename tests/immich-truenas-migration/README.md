# immich: Synology NFS → TrueNAS NFS

Moves the Immich photo library from the DS418 (`192.168.1.2:/volume1/kubenfs/pvc-57345d42-…`,
PVC `immich-library`) to TrueNAS (`192.168.10.10:/mnt/tank/immich`, PVC `immich-library-nfs`).
Postgres does not move: it stays on `ceph-nvme-block`, and because `mountPath` (`/data`) does
not change, every path stored in the database stays valid.

Same shape as `tests/keepers-truenas-migration/` — read that README for the reasoning behind
the two-PVC approach, the Job guards and the verify gates. This file only records what is
different for immich.

## Result — DONE 2026-10-11

| step | when (UTC) | outcome |
|---|---|---|
| 1–3 PV, second PVC, HPA removed | 17:23 | `truenas-immich-library` and `immich-library-nfs` Bound, no HPA |
| 4 quiesce | 17:32 | `immich-server` at 0, no pod, nothing to scale it back |
| 4 copy | 17:32–17:40 | `rsync exit 0`, 487 files + 6,134 directories, 1.39 GB in 7 m 05 s; ran as 1000980000 under `restricted-v2` |
| 4 verify | 17:41–17:49 | `ALL CHECKS PASSED`: 487/487 files, 6,135/6,135 dirs, 1,389,025,561 bytes both sides, metadata diff 0, dst-only 0, 487 of 487 checksums identical |
| 5 cutover | 17:51–17:52 | `541eb15`; server Ready on node6, 0 restarts, mounting `immich-library-nfs`; log: "Successfully verified system mount folder checks" |
| 6 HPA back | after 17:53 | `6a41fa8` |

Immich was down for about 20 minutes. Most of the copy time went on creating 6,134 mostly empty
directories from the DS418, not on the 1.39 GB of data. Step 7 (reclaiming the Synology copy) is
open on purpose.

## What is being moved (measured 2026-10-11, over SMB)

| | files | size |
|---|---|---|
| `library/` | 145 | 0.87 GiB |
| `backups/` (nightly DB dumps) | 15 | 0.37 GiB |
| `thumbs/` | 321 | 0.04 GiB |
| `encoded-video/`, `upload/`, `profile/` | 6 | 0.01 GiB |
| **total** | **487 files, 6,135 directories** | **1.3 GiB** |

The library is this small on purpose: the operator deleted the 1,966 photos of the old single
account on 2026-10-11, ahead of re-importing everything under the multi-user design
(`blog/blog-immich-draft.md`, 2026-10-11). The 2026-08-29 figures (1,969 assets, 0.134 TiB)
no longer apply. Most of the 6,135 directories are the empty date folders that deletion left
behind; they are copied as they are.

## Target state (verified 2026-10-11, read-only `midclt`)

```
tank/immich              191.81 KiB used, 6.14 TiB available, recordsize 1M, LZ4
/mnt/tank/immich         empty, owner 1000980000:1000980000, mode 0755
NFS export               enabled, hosts=[192.168.10.2, .3, .4], maproot_user=root
snapshot task            daily at 02:00, recursive, kept 30 days, enabled
immich namespace         sa.scc.uid-range=1000980000/10000, PSA baseline
immich-server            runs as 1000980000, fsGroup 1000980000, SCC restricted-v2
```

## What differs from keepers

1. **The copy cannot run as root.** The namespace has no privileged binding. Both Jobs run as
   the namespace UID, which already owns every file, and use `quay.io/openshift/origin-cli`,
   which ships rsync, instead of `apk add rsync` on alpine.
2. **The HPA has to go first.** ArgoCD ignores `.spec.replicas`, so `oc scale` sticks — but a
   live HPA with `minReplicas: 1` scales the server back up within about 30 s. Set
   `hpa.enabled: false` in git and wait for the HPA object to disappear before scaling to 0.
3. **Cutover is an edit, not a flag.** `immich.persistence.library.existingClaim` is a value
   for the upstream subchart; change `immich-library` to `immich-library-nfs`.
4. **One quiesced pass is enough.** At 1.3 GiB there is no point in a live bulk copy followed
   by a `--delete` delta: stop the server, copy, verify every byte, cut over.

## Offsite coverage — the gate, and what was decided

`components/apps/immich/values.yaml` says an offsite path from TrueNAS must exist before
cutover, because Hyper Backup task `Synology_C2_immich_photos_task` backs up a *path on the
Synology* and will keep reporting green against a directory that no longer changes.

On 2026-10-11 the operator chose to move anyway, without the UPS and before the OVH job
exists, with this order: move the library → build and check the TrueNAS → Synology copy into
`photo/backups` → only then the full archive import → OVH when the account is sorted.
Exposure in between: photos uploaded after cutover exist on TrueNAS (RAIDZ2, nightly
snapshots) and on the phone that took them, and nowhere else. The database is unaffected
(continuous archive to R2).

## Sequence

Cluster mutations (`oc apply`, `oc scale`, `oc delete`) are **operator-run**. Git changes are
validated and pushed as usual.

### Step 1 — publish the static PV  *(git)*

`components/storage/nfs-csi/values.yaml` → `staticVolumes.volumes[immich-library].enabled: true`

```bash
helm template nfs-csi components/storage/nfs-csi/ | grep -c "^kind: PersistentVolume"   # expect 3
oc get pv truenas-immich-library     # Available, 2Ti, claimRef immich/immich-library-nfs
```

### Step 2 — stage the second PVC  *(git)*

`components/apps/immich/values.yaml` → `library.truenasMigration.stagePvc: true`

```bash
oc -n immich get pvc     # immich-library Bound (old) AND immich-library-nfs Bound (new)
```

Nothing consumes the new PVC. Safe to sit here.

### Step 3 — remove the HPA  *(git)*

`components/apps/immich/values.yaml` → `hpa.enabled: false`

```bash
oc -n immich get hpa     # expect: No resources found
```

### Step 4 — quiesce, copy, verify  *(the downtime starts here)*

```bash
oc -n immich scale deploy/immich-server --replicas=0
oc -n immich wait --for=delete pod -l app.kubernetes.io/name=server --timeout=120s

oc -n immich delete job immich-nfs-copy --ignore-not-found
oc -n immich apply -f tests/immich-truenas-migration/01-copy-job.yaml
oc -n immich logs -f job/immich-nfs-copy          # want: "=== rsync exit 0 ===" and "clean."

oc -n immich delete job immich-nfs-verify --ignore-not-found
oc -n immich apply -f tests/immich-truenas-migration/02-verify-job.yaml
oc -n immich logs -f job/immich-nfs-verify        # want: "ALL CHECKS PASSED"
```

Check the `MOUNTS` lines at the top of the copy log: `/src` must be `192.168.1.2:…` and `/dst`
`192.168.10.10:/mnt/tank/immich`. If the verify Job prints `DO NOT CUT OVER`, stop: scale the
server back to 1 and it is still on the Synology, untouched.

Exit codes from the copy Job: `90` a tool is missing from the image, `91`/`92` a mount is not
NFS, `93` the source is empty, `95` the target is not writable by this UID.

### Step 5 — cut over  *(git, then operator)*

`components/apps/immich/values.yaml` → `immich.persistence.library.existingClaim: immich-library-nfs`

Wait for ArgoCD before scaling up — scaling up first brings the server back on the Synology,
looking like a successful cutover:

```bash
until [ "$(oc -n immich get deploy immich-server \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')" \
  = "immich-library-nfs" ]; do echo "waiting for ArgoCD..."; sleep 20; done

oc -n immich scale deploy/immich-server --replicas=1
oc -n immich rollout status deploy/immich-server --timeout=300s
oc -n immich exec deploy/immich-server -- sh -c 'grep " /data " /proc/mounts'
# expect 192.168.10.10:/mnt/tank/immich
```

Smoke test in the web UI: open an existing photo at full size and upload one new photo. The
server only starts if the `.immich` marker files in each folder are present, so a Ready pod
already says the copy brought them across.

### Step 6 — put the HPA back  *(git)*

`hpa.enabled: true`.

### Step 7 — soak, then reclaim

Leave `immich-library` and the Synology directory alone until the TrueNAS → Synology copy has
run and been checked. Then remove the old PVC template and `library.storageClass` from the
chart, delete the Released PV, and clean the directory on the Synology by hand. Hyper Backup
task `Synology_C2_immich_photos_task` backs up a stale directory from the moment of cutover;
repoint or retire it as part of the backup work, not here.

## Rollback

| Stage reached | How to get back |
|---|---|
| Steps 1–3 | Nothing consumes the new PVC. To unwind: `hpa.enabled: true`, delete the Jobs, then delete `pvc/immich-library-nfs` and `pv/truenas-immich-library` by hand (both are `Prune=false`). |
| Step 4 (quiesced) | `oc -n immich scale deploy/immich-server --replicas=1`. Still on the Synology. |
| Step 5 (cut over) | Scale to 0, set `existingClaim` back to `immich-library`, wait for ArgoCD, scale to 1. That returns to the library as it was at the copy; anything uploaded after cutover is on TrueNAS only and the database will list it as missing until it is copied back. |

The old volume is mounted read-only in both Jobs, so no step here can write to the rollback.
