# media: CephFS → TrueNAS NFS

Moves the media stack's shared `/data` off `cephfs-hdd` onto TrueNAS. **Third of
the four consolidation moves, scheduled first** — see
`blog/blog-truenas-migration-draft.md` 2026-08-29 for why.

Forked from `tests/keepers-truenas-migration/` **after** that migration completed
and verified byte-identical. Read that runbook first; this one documents only
what differs, and the differences are the whole risk.

## What we are moving (measured 2026-08-28)

| | |
|---|---|
| Size | **3.2155 TiB** (`ceph_pool_stored{pool_id="17"}` 3,535,497,592,832 B vs kubelet usedBytes 3,535,487,893,504 B — 9.7 MB apart) |
| Files | **2,203** |
| **Hardlinked** | **1,478** ← the entire risk of this migration |
| Layout | `downloads/` `media/` `jellyfin-cache/`(0) `transcodes/`(0) |
| Consumers | **six** — bazarr, jellyfin, radarr, sonarr, transmission-master, transmission-slave; all mount `/data`, no subPath |
| Source | `cephfs-hdd`, sole consumer of the `cephfs-bulk-hdd` EC 2+1 pool |
| Target | static PV `truenas-media-data` → `192.168.10.10:/mnt/tank/media` |

**Wall clock: 8–12 h bulk** (3,535,497,592,832 B ÷ 124 MB/s = **7.9 h floor**,
measured 2026-08-28 single-stream), then ~1 h of downtime, then hours of
transmission re-verification that is *not* downtime.

## The three things that differ from keepers

### 1. Hardlinks — and the failure is silent

`/data/media` and `/data/downloads` each measure 2.8T apparent against 3.3T
actual, so **~2.3 TiB exists once on disk under two paths**. That is radarr and
sonarr hardlinking on import so a file can be in the library *and* still seeding.

Without `-H`: rsync writes **5.6 TiB instead of 3.3**, and every imported file
decouples from its torrent — the library and transmission diverge permanently,
and deleting from one no longer frees the other.

**Every other check still passes.** rsync exits 0. File counts match. Per-file
byte totals match. This is why `02-verify-job.yaml` gates on the **unique-inode
count** and on `du -sb /dst` staying under 4.4 TB. Those three gates are not
optional and not decoration — they are the only thing standing between a
defeated `-H` and a green migration.

**Do not parallelise by splitting the tree.** Hardlinks span `downloads/` and
`media/`, so one worker per top-level directory breaks every link that crosses
the split. Parallel reads buy only ~1.44× here anyway (170 MiB/s across 3 vs
124 MB/s single), which does not pay for that. **One rsync process.** 2,203
files is a trivial inode map.

### 2. Six consumers, and the quiesce order matters

```bash
# radarr/sonarr CREATE the hardlinks -- they must be down before the --delete pass
oc -n media scale deploy/transmission-master deploy/transmission-slave --replicas=0
oc -n media scale deploy/radarr deploy/sonarr --replicas=0
oc -n media scale deploy/bazarr --replicas=0
oc -n media scale deploy/jellyfin --replicas=0
oc -n media get pods
```

`oc scale` is the correct mechanism here and nothing fights it: `root-app`
renders `ignoreDifferences` on `.spec.replicas` for every Deployment, so ArgoCD
never reconciles a replica count on this cluster. (The keepers run lost a window
learning this the wrong way round — see `14327d4`.) No HPA exists in `media`.

**jellyfin may stay up during the bulk pass.** It competes for the same EC read
path and will stretch the 8 h, which is the better trade against an evening
without playback. It must be down for the delta.

### 3. The source is the constraint, not the target

keepers was capped by the Synology at 52 MB/s. Here the source reads at
**124 MB/s** and TrueNAS writes at ~270 MB/s, so CephFS EC 2+1 across three
spindles is the limit. `activeDeadlineSeconds` is **86400**, not 43200 — the
keepers Job's own comment already said 12 h was not enough for this leg.

## Before you start

```bash
# unique-inode baseline -- the keepers artifacts have no equivalent and this is
# the number the verify Job compares against
oc -n media exec deploy/radarr -- sh -c \
  'echo "paths:  $(find /data -type f | wc -l)"; \
   echo "inodes: $(find /data -type f -printf "%i\n" | sort -u | wc -l)"; \
   echo "bytes:  $(du -sb /data | cut -f1)"'

# confirm the hardlink set really is the radarr/sonarr import pattern:
# same inode, one path under downloads/, one under media/
oc -n media exec deploy/radarr -- sh -c \
  'f=$(find /data/media -type f -links +1 | head -1); \
   echo "$f"; find /data -samefile "$f"'
```

## Sequence

Identical to keepers steps 1–7, with the substitutions above. Enable the static
PV (`components/storage/nfs-csi/values.yaml`, `media-data` `enabled: false → true`
— its `8Ti` capacity label over-declares against 3.2155 TiB, which is the safe
direction), port the `stagePvc`/`cutover` pattern into `components/apps/media`,
bulk-copy overnight with all six consumers live, then quiesce in the order above.

**Expect mass re-verification** on both transmissions after cutover, exactly as
keepers saw (89 of 105 torrents, all passed). It is not a rollback signal — see
the keepers runbook. Here it is also a free, exhaustive hardlink check: if `-H`
had failed, the seeding copies would be different inodes and transmission would
still verify them fine, so **do not** treat a clean re-verify as evidence about
hardlinks. Section 3c is that evidence.

## What this unblocks

`media-data-pvc` is the **sole** consumer of `cephfs-bulk-hdd`. After the move
that pool is empty and the three HDD OSDs serve only the RGW data pool (Loki +
OADP). With the queued Loki→garage move done, the whole HDD tier has no purpose:
retiring it frees one 3.5" bay per node and ~15–20 W, and `CephPGImbalance`
disappears because it exists *only* because two device classes are averaged
together.

**Availability trade, stated plainly:** media today survives losing a whole node
(EC 2+1 across three hosts). On TrueNAS it survives two disk failures but sits in
**one chassis**, already sharing the backnet failure domain with Ceph. That is a
real reduction, accepted for capacity and simplicity. Media is re-downloadable
and gets no offsite leg — 3.21 TiB at R2 would be ~$53/mo, which the offsite
design explicitly refused.
