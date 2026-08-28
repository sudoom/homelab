# keepers: Synology NFS → TrueNAS NFS

Moves `keepers/keepers-data-pvc` (transmission's `/data`) off the Synology
DS418 and onto the TrueNAS box. First of three bulk migrations; the other two
(`media`, `immich`) follow the same shape but are **not** interchangeable —
see "Why keepers first".

## What we are moving (measured 2026-08-28, not estimated)

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

**Expected wall clock: ~10 h** (measured 2026-08-28 during the real run:
**52.2 MB/s sustained**, 4.37 GiB over a 90 s window, from a 21:10 start → ~07:00).

An earlier version of this line said 4–6 h, derived from the Synology's 1 Gbit
link (~118 MB/s ceiling). That was wrong, and wrong in an instructive way:
**52 MB/s is 416 Mbps, so the link is not the bottleneck — the DS418 itself is**
(4-bay Realtek ARM box; its disks and NFS stack). Two lessons worth carrying to
the media and immich moves:

- A link rate is a ceiling, not a prediction. Do not plan against one.
- rsync's `--info=progress2` prints *instantaneous per-file* rates; during a
  large file it briefly showed 119 MB/s, which is what produced the bad estimate.
  The sustained figure is bytes-on-target over wall-clock, and the honest way to
  get it is two `zfs list -Hp -o used` samples 90 s apart.

**This also largely answers the queued Synology LACP item, negatively:** bonding
two 1 Gbit links cannot help a workload that does not saturate one. LACP may
still help *concurrent* clients — it cannot help this.

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

**1. Remove the orphan rehearsal directory.** ✅ **DONE 2026-08-28.**
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

**2. Confirm the Synology's offsite job.** ✅ **RESOLVED 2026-08-28 — there is
no Hyper Backup over `/volume1/kubenfs`.** So this migration loses no coverage,
because there is none to lose. Nothing blocks keepers.

It did surface something worse, recorded as a README TODO: **the immich photo
originals (114 GiB) have no backup of any kind.** No Hyper Backup, the Velero
`daily` Schedule is paused with an 81-day-old last backup, and nothing else
references the library. Immich's *database* is genuinely offsite (barman → R2,
`ContinuousArchiving=True`) — the photos are not. That gates the immich move,
not this one, but it is why the question was worth asking before touching
anything.

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

**Expected non-clean exits.** The Job classifies rsync's exit code rather than
trusting `set -e`:
- `0` — clean.
- `24` — some source files vanished mid-copy. **Expected on the bulk pass**,
  because transmission is live and removes files as torrents are managed. The
  Job treats this as success; step 4's quiesced delta pass reconciles it.
- anything else — stop and investigate before step 4. `23` means per-file
  errors (this is what a stray `-X` produced), `12` protocol, `30` timeout.

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
```

**A Job's pod template is immutable, so you must DELETE before EACH apply** —
a second `apply` over a live Job object is rejected, it does not re-run it.

```bash
# --- dry run: see exactly WHAT it intends to remove ---
oc -n keepers delete job keepers-nfs-copy --ignore-not-found
#   edit 01-copy-job.yaml:  EXTRA = "--delete --dry-run --info=del"
oc -n keepers apply -f tests/keepers-truenas-migration/01-copy-job.yaml
oc -n keepers logs -f job/keepers-nfs-copy | grep -E "^deleting |Number of deleted"
```

`--info=del` is **required** and was missing from an earlier version of this
runbook. rsync only emits per-path `deleting <path>` lines at verbosity ≥ 1
(`INFO_DEL`); with just `--info=progress2,stats2` the dry run printed a bare
count and nothing else — so the step told you to "read what it intends to
remove" while running a command that could not show you.

Read every line. Expect only files transmission removed during the live copy.
If you see anything you do not recognise, **stop**.

```bash
# --- the real pass ---
oc -n keepers delete job keepers-nfs-copy
#   edit 01-copy-job.yaml:  EXTRA = "--delete"
oc -n keepers apply -f tests/keepers-truenas-migration/01-copy-job.yaml
oc -n keepers logs -f job/keepers-nfs-copy
```

Minutes, not hours. The Job self-arms three guards whenever `--delete` is in
`EXTRA` — both paths must be NFS mounts and `/src` must be non-empty — so a
`--delete` against an unmounted or empty source aborts instead of wiping 1.7 TiB.

**`rc=24` means something different on this pass.** On the bulk pass it is
expected (transmission is live, files come and go). Here nothing should be
writing to `/src`, so files vanishing means **the quiesce failed** — the Job
says so and does *not* swallow it. Confirm `replicas=0` and re-run.

**Afterwards, put `EXTRA` back to `""`.** It is a checked-in file; leaving it
armed means the next person to apply this Job runs a destructive pass.

### Step 5 — verify *before* cutting over

```bash
oc -n keepers delete job keepers-nfs-verify --ignore-not-found
oc -n keepers apply -f tests/keepers-truenas-migration/02-verify-job.yaml
oc -n keepers logs -f job/keepers-nfs-verify
```

The Job now computes its own verdict and **exits non-zero if any check fails** —
you no longer eyeball five numbers against notes from Step 0. It prints
`ALL CHECKS PASSED` or `DO NOT CUT OVER`. What it gates on:

| check | why |
|---|---|
| `src files == dst files` and `src dirs == dst dirs` | self-contained; no Step 0 notes needed |
| metadata diff count `== 0` | every file matches on size, mtime, mode, ownership |
| **dst-only entries `== 0`** | section 3 has no `--delete`, so it proves src ⊆ dst, **not** equality. Without this, extra files on the target are invisible |
| 20-file checksum sample | actual bytes, on a `shuf` sample |

Two failure modes an earlier version had, both now closed: it piped rsync into
`wc -l`, so **a failed rsync printed `0` — the exact PASS value**; and it kept
the `-X` the copy Job had dropped, which would have produced ~4,493 spurious
differences against a "count must be 0" criterion.

Still metadata-complete plus a content *sample*, not a full byte check. A full
one re-reads 1.7 TiB twice at ~52 MB/s (~19 h) and is not proportionate for
re-downloadable data. Said plainly so nobody believes more was proven.

### Step 6 — cut over  *(git)*

`components/apps/keepers/values.yaml` → `sharedData.truenasMigration.cutover: true`

**Wait for ArgoCD before scaling up.** There is no webhook; the controller polls
(~3 min). Scaling up first gets you transmission back on the *Synology*, looking
like a successful cutover:

```bash
until [ "$(oc -n keepers get deploy transmission \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')" \
  = "keepers-data-nfs" ]; do echo "waiting for ArgoCD..."; sleep 20; done
echo "claim repointed"

oc -n keepers scale deploy/transmission --replicas=1
oc -n keepers exec deploy/transmission -- sh -c 'grep " /data " /proc/mounts; ls /data'
# expect 192.168.10.10:/mnt/tank/keepers  and  1812  983
```

`mountPath` stays `/data` and the layout is preserved, so transmission's torrent
paths are unchanged — **it should not re-verify.** Confirm in the UI that
torrents are seeding, not re-checking. Mass re-verification means paths moved;
roll back rather than let it run.

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
| Steps 1–3 | Nothing consumes the new PVC — sitting here is harmless. To actually unwind: `oc -n keepers delete job keepers-nfs-copy`, then delete `pvc/keepers-data-nfs` and `pv/truenas-keepers-data` **by hand** — both carry `Prune=false`, so flipping the flags back leaves the objects behind. |
| Step 4 (quiesced) | `--replicas=1`. Still pointed at the Synology. |
| Step 6 (cut over) | `cutover: false`, bounce the pod. Recovers the **pre-migration** payload only: `keepers-data-pvc` is still Bound and was never written (the copy Job mounts it `readOnly`). Anything downloaded *after* cutover lives on TrueNAS alone — not lost (`keepers-data-nfs` stays Bound, PV is Retain) but not visible on the Synology. Re-copy that delta before rolling back if it matters. |
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
