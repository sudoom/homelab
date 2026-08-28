# keepers: Synology NFS → TrueNAS NFS

Moves `keepers/keepers-data-pvc` (transmission's `/data`) off the Synology
DS418 and onto the TrueNAS box. First of three bulk migrations; the other two
(`media`, `immich`) follow the same shape but are **not** interchangeable —
see "Why keepers first".

## What we are moving (measured 2026-08-29, not estimated)

| | |
|---|---|
| Size | **1.7 TiB** |
| Files | **4,493** |
| Hardlinked files | **0** |
| Top level | `1812/`, `983/` (rutracker forum IDs) |
| Consumers | `transmission` only — `webtlo` does **not** mount it |
| Source | `nfs-csi` → Synology `192.168.1.2:/volume1/kubenfs/pvc-3f531e77-…` (frontnet, **1 G**) |
| Target | static PV `truenas-keepers-data` → `192.168.10.10:/mnt/tank/keepers` (backnet, **10 G**) |
| Both PVs | `reclaimPolicy: Retain` |

**Expected wall clock: 4–6 h.** The constraint is the Synology's 1 Gbit
frontnet link (~118 MB/s ceiling), not either disk system. The write side goes
out over the 10 G backnet and is not the bottleneck.

## Why keepers first

Not because it is smallest — it is half of media, not a rounding error. Because
it is the **cheapest to lose** and the simplest on every axis:

- **Zero hardlinks.** The constraint that shapes the media move (a single
  `rsync -H` process, no splitting the tree across parallel workers) does not
  apply. Any tool works.
- **NFS → NFS.** Same semantics both ends. No CephFS subvolume, no MDS, no EC
  read path, no `ceph fs new … --force` hazard.
- **One consumer.** Quiesce is one `scale --replicas=0`. Media has six.
- **Re-downloadable.** If this goes badly the cost is bandwidth, not data.
  Immich — the only irreplaceable payload — goes **last**, when this runbook is
  boring.

It is also the workload that answers the queued **Synology LACP** question,
being 1 G-capped with no hardlinks to constrain multi-stream copying.

## Prerequisites — both are blocking

**1. Remove the orphan rehearsal directory.** ✅ **DONE 2026-08-29.**
`/mnt/tank/keepers/pvc-342353d7-…` (≈19 MB, left by the 2026-08-28 OADP
rehearsal) sat *inside* the dataset the static PV hands to the PVC **as its
root** — left in place it would have appeared as a stray entry in
transmission's `/data` after cutover. Removed by the operator; verified empty.

Target state confirmed the same day:

```
/mnt/tank/keepers        empty (192K, directory only)
tank/keepers             14.4T avail, recordsize 1M
NFS export               enabled, maproot_user=root,
                         hosts=[192.168.10.2, .3, .4]   (node backnet only)
```

`recordsize: 1M` matches the workload (4,493 files averaging ~400 MiB), and the
host restriction is why the copy Job must run on a cluster node rather than
anywhere else — the export is not reachable from the frontnet at all.

**2. Confirm the Synology's offsite job.** If the DS418 runs Hyper Backup /
Cloud Sync over `/volume1/kubenfs`, migrating off it **silently drops keepers
out of that job**. Decide before cutover whether that matters for this dataset
(re-downloadable, so probably not) — but the same check is *mandatory* before
immich moves, and it is cheaper to learn the answer now.

## Sequence

Every mutation below is **operator-run**. Nothing here is applied by Claude.

### Step 0 — capture the before-state

```bash
oc -n keepers exec deploy/transmission -- sh -c \
  'find /data -type f | wc -l; du -sb /data | cut -f1'
```
Write both numbers down. They are the acceptance criteria in Step 5.

### Step 1 — publish the static PV  *(git)*

`components/storage/nfs-csi/values.yaml`:

```yaml
truenas:
  staticVolumes:
    enabled: true                 # master switch
    volumes:
      - name: keepers-data
        enabled: true             # this one only — media/immich stay false
```

Validate before pushing, then let ArgoCD sync:

```bash
helm template nfs-csi components/storage/nfs-csi/ | grep -c "^kind: PersistentVolume"   # expect 1
oc get pv truenas-keepers-data     # expect Available, 2Ti, claimRef keepers/keepers-data-nfs
```

### Step 2 — stage the second PVC  *(git)*

`components/apps/keepers/values.yaml` → `sharedData.truenasMigration.stagePvc: true`

```bash
oc -n keepers get pvc     # keepers-data-pvc Bound (old) AND keepers-data-nfs Bound (new)
```

Both PVCs now exist. **Nothing is consuming the new one.** Safe to sit here for
days. `cutover` without `stagePvc` is rejected at template render time.

### Step 3 — bulk copy, with transmission still running

```bash
oc -n keepers apply -f tests/keepers-truenas-migration/01-copy-job.yaml
oc -n keepers logs -f job/keepers-nfs-copy
```

Torrent data does not change once complete, so a live copy is safe; only
in-flight downloads will differ, and Step 4 reconciles them. Transmission keeps
seeding throughout.

**If it is interrupted** (node reboot, OVN egress break, stale mount — all have
happened on this cluster), just re-run it. rsync skips files whose size and
mtime already match, so a resumed run costs a 4,493-file re-scan, not 1.7 TiB:

```bash
oc -n keepers delete job keepers-nfs-copy
oc -n keepers apply -f tests/keepers-truenas-migration/01-copy-job.yaml
```

Optionally re-run once more while still live to shrink the Step 4 delta.

### Step 4 — quiesce and delta sync  *(the only downtime)*

```bash
oc -n keepers scale deploy/transmission --replicas=0
oc -n keepers wait --for=delete pod -l app=transmission --timeout=120s

# dry-run the deleting pass FIRST and read what it intends to remove
oc -n keepers delete job keepers-nfs-copy --ignore-not-found
# edit 01-copy-job.yaml: EXTRA = "--delete --dry-run"   -> apply, read the log
# then:                  EXTRA = "--delete"             -> apply, let it run
```

Minutes, not hours — only files that changed since Step 3. `--delete` is used
**only here**, after the dry run, so files transmission removed during the live
copy do not linger on the target.

### Step 5 — verify *before* cutting over

```bash
oc -n keepers apply -f tests/keepers-truenas-migration/02-verify-job.yaml
oc -n keepers logs -f job/keepers-nfs-verify
```

Accept only if **all** of:
- file and directory counts match Step 0,
- apparent bytes match,
- the itemize-changes difference count is **0**,
- the 20-file checksum sample reports `PASS`.

This is metadata-complete plus a content *sample* — not a full content
verification. A full one means re-reading 1.7 TiB twice over 1 Gbit (~8 h),
which is not proportionate for re-downloadable data. Said plainly so nobody
later believes more was proven than was.

### Step 6 — cut over  *(git)*

`components/apps/keepers/values.yaml` → `sharedData.truenasMigration.cutover: true`

```bash
oc -n keepers scale deploy/transmission --replicas=1
oc -n keepers get pod -l app=transmission -w
oc -n keepers exec deploy/transmission -- sh -c 'mount | grep /data; ls /data'
# expect 192.168.10.10:/mnt/tank/keepers  and  1812  983
```

`mountPath` stays `/data` and the layout is preserved, so transmission's torrent
paths are unchanged — **it should not re-verify anything.** Confirm in the UI
that torrents are seeding, not re-checking. Mass re-verification means the paths
moved and something is wrong; roll back rather than let it run.

### Step 7 — soak, then reclaim

Leave `keepers-data-pvc` and its Synology data **in place for at least a week**.
It is the only rollback that does not involve re-downloading 1.7 TiB. After the
soak:

```bash
oc -n keepers delete pvc keepers-data-pvc     # PV is Retain: data survives
oc get pv | grep Released                     # then clean on the Synology by hand
```

Only then remove the PVC template + `sharedData.storageClassName` from the chart.

## Rollback

| Stage reached | How to get back |
|---|---|
| Steps 1–3 | Nothing is consuming the new PVC. Set both flags false; delete the Job. |
| Step 4 (quiesced) | `--replicas=1`. Still pointed at the Synology. |
| Step 6 (cut over) | `cutover: false`, bounce the pod. Old PVC still Bound, data untouched. |
| After Step 7 | Only path is re-copying from the Retained PV, or re-downloading. **Do not run Step 7 early.** |

The old volume is mounted `readOnly: true` in the copy Job specifically so no
phase of this can write to the rollback.

## What this does not cover

- **Throughput comparison.** The queued CephFS-vs-TrueNAS benchmark needs the
  *media* path; this move is 1 G-capped at the source and says nothing about
  what TrueNAS NFS can do on the backnet.
- **Offsite coverage.** See prerequisite 2 — unresolved, and it matters more for
  immich than for this dataset.
- **The other two volumes.** `media` adds hardlinks (1,478 of 2,203 files), six
  consumers and a CephFS source. `immich` is small but irreplaceable. Same
  shape, different risk; do not copy-paste this runbook without re-reading it.
