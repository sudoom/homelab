# HDD tier rollout — working draft

Adding bulk HDDs to the cluster for the first time. The cluster has
been NVMe-only since bootstrap (3× Samsung PM9A1 512GB, one OSD per
node, single device class `nvme`). Two queued items have been blocked
on bulk drives landing:

- **CephFS storage class** — RWX workloads (Immich, Jellyfin library,
  anything that needs shared filesystems). Plan per CLAUDE.md: one
  `CephFilesystem` CR, metadata pool on NVMe, two data pools (NVMe +
  HDD) with one StorageClass each.
- **Flip RGW `dataPool.deviceClass` from `nvme` to `hdd`** — Loki's
  ~50 GiB/week ingest doesn't need NVMe latency, and the data is
  already cold (most queries hit recent chunks; older chunks are
  archive). Free up NVMe capacity for hot workloads.

This draft is the chronology for that work — pre-arrival prep, install,
post-install validation, lessons.

## 2026-05-26 — Drives ordered, prep starts

### Hardware choice

Ordered **10× Hitachi/HGST HUS726040ALE610 Ultrastar 7K6000** at 50
EUR/drive (used, eBay / OEM resale channel). Why this drive:

| Attribute | Value | Why it matters |
|---|---|---|
| Capacity | 4 TB each | 40 TB raw across 10 drives; ~12 TB usable after size=3 replication. Right ballpark for Loki + library RWX. |
| Recording | **CMR (perpendicular)** | NOT SMR. Critical for Ceph — SMR's shingled writes wreck BlueStore's small-write pattern (write amplification, sustained stalls during compaction). Always verify CMR before buying. |
| Interface | SATA 6 Gb/s | Cluster nodes have free SATA bays + cabling. Cheaper than SAS-HBA route. |
| Speed | 7200 RPM, ~155-180 MB/s sustained | Fast enough for bulk; not competing with NVMe on latency-sensitive paths. |
| Helium fill | Yes (Ultrastar 7K6000 series) | Lower idle power (~4.5 W vs ~7-8 W for air-filled 7200 RPM 4 TB), less heat. |
| Cache | 128 MB | Decent for spinning rust. |
| TLER / ERC | Supported (enterprise drive) | Drive bounds its own error-recovery time. Without TLER, RAID/Ceph-style stacks see a drive hung "rechecking sector" for 2+ minutes during transient bad-read events, then mark it failed unnecessarily. |
| MTBF | 2M hours (datacenter rating) | These were originally datacenter pulls. Used hours unknown until SMART reveals it. |
| Rated workload | 550 TB/year | Comfortably above what a homelab Ceph cluster generates. |
| Power: active / idle / standby | ~6.4 W / ~4.5 W / ~0.8 W | 9 OSDs × 4.5 W idle = ~40 W extra continuous (acceptable on the new post-power-tuning baseline of ~227 W rack). |
| Age | 9 years since launch (2015-2016) | Worth checking power-on hours on arrival. >70,000 h = end-of-life territory. |

50 EUR/drive is well under typical resale (60-100 EUR is normal for
these on the used market). Net cost: 500 EUR for 40 TB raw / ~12 TB
size=3 usable. Comparable new SATA enterprise (Toshiba MG08, Seagate
Exos) is ~120-150 EUR/4TB = 1200-1500 EUR for the same array.

The age is the obvious risk. Pre-install burn-in is mandatory (next
section). Plan for failures: keep 1 drive as a hot spare; if any
drive's SMART comes back marginal during burn-in, return-to-seller or
swap with the spare.

### Topology decision

**Chassis constraint: each P5090 has only one 3.5" bay.** Three
chassis × 1 bay = **3 active HDDs, 7 shelf spares**. Same per-host
OSD count as the NVMe tier; no within-node redundancy options.

| Topology fact | Implication |
|---|---|
| 3 active HDD OSDs (1 per host) | CRUSH `host` failure domain with size=3 = minimum viable; PGs forced to 1-per-host distribution. |
| 7 shelf spares | Generous failure budget. Pre-tested, burn-in-clean spares = drive swap is a chassis-pull + reseat, not a procurement window. Worth keeping all 7 burned-in even if it takes 1-2 weeks. |
| 12 TB raw / ~4 TB usable post-size=3 | Smaller than I initially planned. Loki's ~50 GiB/week + Immich library + Jellyfin metadata fits comfortably; bulk media (Jellyfin video) on NFS-CSI (Synology) instead of CephFS-HDD. |
| Same no-drain-headroom shape as NVMe | Single-OSD restart is a degraded window (1/3 HDD capacity gone). Same operating rules as NVMe pool — schedule HDD maintenance one at a time, never overlap with NVMe OSD restarts. |

With 3 HDD OSDs:
- target_pgs_per_osd ≈ 100, replication 3, 3 OSDs → 100 × 3 / 3 = 100,
  round to power-of-2 = **128**
- This is the `pg_num_min` floor for any HDD-backed pool. Split between
  RGW data pool and CephFS HDD data pool, both sharing the same 3 OSDs.

### Capacity allocation (~4 TB usable across both HDD-backed pools)

Splitting 4 TB usable between RGW data and CephFS-HDD data is a
choice — Ceph doesn't reserve per-pool, capacity is fungible across
the shared OSDs. But the QoS implications:

| Consumer | Estimated steady draw | Burst | Notes |
|---|---|---|---|
| Loki chunks (RGW data) | ~50 GiB/week steady, retention TBD | one-time backfill if changing retention | Mostly compressed log chunks; size grows linearly with retention |
| Immich (CephFS-HDD) | ~10-50 GiB/month per active user | first import is bursty | Photos + thumbs. Stays under control if libraries aren't huge. |
| Jellyfin metadata + thumbs (CephFS-HDD) | ~5-20 GiB | one-time | Library scan cache; bulk media stays on NFS-CSI/Synology. |
| OADP backups (RGW data) | ~5-10 GiB/week | full-cluster snapshot ~5 GiB | Velero PV + manifest backups; deletes old as new lands. |

Total expected ~1-2 TB used over the next year, well under the 4 TB
ceiling. If pressure rises, the spare drives are right there — swap
one in to grow capacity (just the OSD device list update + a rebuild
window).

## Pre-arrival burn-in procedure

These are used enterprise drives at unknown wear. Burn-in before
inserting into the cluster — capture SMART baseline, run drive's own
long self-test, optionally do a full-surface write-test with
`badblocks`, capture SMART again, decide fate.

Run this on a workstation with a single drive at a time (or a
multi-bay USB dock; SATA-over-USB works fine for SMART + selftests).
**Do not run on a drive plugged into the cluster nodes** — the
selftests + badblocks generate significant IO that will affect Ceph
performance, and accidentally running badblocks on the wrong device
ID would be catastrophic.

### Step 1 — Identify and baseline

```bash
# WARNING: a bare /dev/sdX is acceptable ONLY on a dedicated burn-in box whose
# only disks ARE the targets. On node4 (the actual 2026-06 setup) NEVER paste a
# bare /dev/sdX — the boot+etcd disk is also SATA (/dev/sda) and /dev/sd* order is
# unstable. Use the hardened by-id gate in "## 2026-06-10 - burn-in execution" below.
DRIVE=/dev/sdX                          # dedicated-box placeholder only; node4 uses the gate
SERIAL=$(sudo smartctl -i $DRIVE | awk '/Serial Number/{print $3}')

# Full SMART dump — includes vendor attributes, error log, selftest log,
# power-on hours, temperature history if supported.
sudo smartctl -x $DRIVE > "smart-baseline-${SERIAL}-$(date +%Y%m%d).txt"

# Quick summary check
sudo smartctl -i $DRIVE | grep -E "Model|Serial|Firmware|User Capacity|Form Factor|Rotation"
sudo smartctl -A $DRIVE | grep -E "Power_On_Hours|Reallocated_Sector|Current_Pending|Offline_Uncorrectable|UDMA_CRC"
sudo smartctl -H $DRIVE   # overall health
```

Fail-fast checks (return-to-seller if any of these trip on baseline):
- `SMART overall-health self-assessment` reports anything other than `PASSED`
- `Reallocated_Sector_Ct` > 50 (drive's already shedding sectors)
- `Current_Pending_Sector` > 0 (sectors waiting to be reallocated — they
  WILL fail soon)
- `Offline_Uncorrectable` > 0 (drive can't read these sectors at all)
- `UDMA_CRC_Error_Count` > 0 (cable/link errors — could be cabling, but
  worth flagging)
- `Power_On_Hours` > 70,000 (>8 years powered on; remaining life is a
  coin flip)

These drives are used so non-zero `Reallocated_Sector_Ct` is expected
— a small handful (<10) is fine, the threshold is "stable over time"
not "zero".

### Step 2 — Short self-test (~2 min)

```bash
sudo smartctl -t short $DRIVE
sleep 130
sudo smartctl -l selftest $DRIVE | head -10
# Expect: "Completed without error"
```

If the short test fails, the long test will too. Don't waste 8 hours;
return the drive.

### Step 3 — Long self-test (~8 hours for 4 TB)

The drive's own surface scan + servo/mechanical checks. Runs at
read-only speed; no risk to existing data on the drive (but burn-in
slots are empty drives anyway). The drive does this internally, not
the host kernel.

```bash
sudo smartctl -t long $DRIVE

# Check progress periodically:
sudo smartctl -A $DRIVE | grep "remaining"
# OR look at selftest log:
sudo smartctl -l selftest $DRIVE | head -5
```

Long test typically takes ~8 hours per 4 TB on a 7200 RPM drive
(internal scan rate ~140 MB/s effective). When complete:

```bash
sudo smartctl -l selftest $DRIVE | head -5
sudo smartctl -x $DRIVE > "smart-postlong-${SERIAL}-$(date +%Y%m%d).txt"
diff "smart-baseline-${SERIAL}-*.txt" "smart-postlong-${SERIAL}-*.txt" | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"
```

Fail criteria after long test:
- Selftest result != `Completed without error`
- Any new `Reallocated_Sector_Ct` increment from baseline
- Any new `Current_Pending_Sector`
- Any new `Offline_Uncorrectable`

### Step 4 — Optional: badblocks full-surface write test (~24-30 h per 4 TB)

The long self-test is a READ test from the drive's perspective. To
also exercise the WRITE path and force the drive to read back what
it wrote, run `badblocks` in destructive write-mode. This is the most
thorough check; it's also the slowest.

```bash
# Destructive — wipes the drive. Use only on blank drives.
sudo badblocks -wsv -b 4096 $DRIVE 2>&1 | tee "badblocks-${SERIAL}-$(date +%Y%m%d).log"
```

What this does: writes 4 different patterns to every block, reads
each back, compares. Any byte mismatch = drive can't store data
reliably at that block. Takes ~24-30 hours on a 4 TB drive (read +
write speed both required for each pass).

When done, re-read SMART one more time:

```bash
sudo smartctl -x $DRIVE > "smart-postbadblocks-${SERIAL}-$(date +%Y%m%d).txt"
sudo smartctl -A $DRIVE | grep -E "Reallocated_Sector_Ct|Current_Pending|Offline_Uncorrectable"
```

If `badblocks` reports zero bad blocks AND none of the failure
counters incremented, the drive is good for Ceph.

Skip this step if pressed for time + the long selftest already
passed cleanly. The long test catches >95% of drives that would also
fail badblocks; the badblocks delta is mostly "drive forgets a write
under sustained pressure" type failures, which on enterprise SATA at
this age are rare (consumer drives without TLER are different).

### Step 5 — Stash the SMART captures

Per the existing pattern in `data/`, save all baseline + post-test
SMART dumps into a new subdirectory:

```
data/hdd-burnin-2026-05-XX/
  HUS726040ALA610-K7G5MZBE-smart-baseline.txt
  HUS726040ALA610-K7G5MZBE-smart-postlong.txt
  HUS726040ALA610-K7G5MZBE-smart-postbadblocks.txt
  HUS726040ALA610-K7G5MZBE-badblocks.log
  ... (10 drives × 3-4 files each)
  SUMMARY.md      # one-line per-drive verdict + the post-install OSD mapping
```

The `SUMMARY.md` is the artifact future-me (or anyone debugging a
failing OSD 18 months from now) will reach for first. Format suggestion:

```markdown
| Drive serial | Slot (node:bay) | OSD ID | Pre-Hours | Reallocated | Pending | Verdict |
|---|---|---|---|---|---|---|
| K7G5MZBE | node4:1 | osd.3 | 45,231 | 0 | 0 | ✓ in service |
| K7H1ABCD | node4:2 | osd.4 | 51,892 | 12 | 0 | ✓ in service (stable across long+badblocks) |
| K7G8XYZ1 | spare    | -    | 38,100 | 0 | 0 | ✓ shelf spare |
| K7G2BAD0 | rejected | -    | 67,400 | 184 | 7 | ✗ returned |
```

## Install sequence (when drives arrive + burn-in done)

When 9 drives have passed burn-in and 1 is parked as the spare, the
in-cluster work splits into 4 phases. Each phase is a separate
commit; don't bundle.

### Phase 1 — Add HDDs to CephCluster device list

The `CephCluster` CR currently has explicit per-node device entries
for the NVMe only:

```yaml
storage:
  useAllDevices: false
  useAllNodes: false
  nodes:
    - name: node4.okd.sudops.pl
      devices:
        - name: /dev/nvme0n1
    # ... node5, node6 same
```

Add the HDD device paths once installed. The exact paths depend on
which SATA controllers see the drives — most likely `/dev/sda`,
`/dev/sdb`, `/dev/sdc` per node, but verify with `lsblk` from each
node before committing:

```bash
oc debug node/node4.okd.sudops.pl --quiet -- chroot /host lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL | grep -i hus726040
```

Then update `components/storage/rook-ceph-cluster/values.yaml`:

```yaml
storage:
  useAllDevices: false
  useAllNodes: false
  nodes:
    - name: node4.okd.sudops.pl
      devices:
        - name: /dev/nvme0n1
        - name: /dev/disk/by-id/wwn-0x5000cca252abc123  # HDD (only 3.5" bay)
    # node5 + node6 same shape: one NVMe + one HDD device each
```

**Use `/dev/disk/by-id/` paths, not `/dev/sdX`.** SATA enumeration
order isn't stable across reboots; `/dev/sda` might become `/dev/sdb`
after a maintenance event. The `wwn-` symlinks are derived from
hardware serials and are stable. Find them with:

```bash
oc debug node/node4 --quiet -- chroot /host ls -l /dev/disk/by-id/ | grep -E "wwn.*sda"
```

Once committed, Rook's operator picks up the new device entry and
spawns a `rook-ceph-osd-prepare-<node>-<uuid>` job per new device.
Each job formats the drive with BlueStore, registers the OSD with
Ceph, and brings it up. Per-OSD provisioning takes ~3-5 minutes;
parallel across the 3 nodes.

Verify post-deploy:

```bash
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
# Expect: 3 NVMe OSDs (existing) + 3 HDD OSDs (new), 1 per host
# CRUSH should auto-detect device_class=hdd for the new ones.
```

**Executed 2026-06-12 — Phase 1 + 2 done, clean and additive.** Devices added by-id (burn-in-validated, seated raw + DDF-wiped): node4 `wwn-0x5000cca25df55694` (K4KTAEDL), node5 `wwn-0x5000cca25df55cf3` (K4KTD40L), node6 `wwn-0x5000cca269c62bb6` (K7GEKUBR). Source is the wrapper chart `components/storage/rook-ceph-cluster/values.yaml` `cephClusterSpec.storage.nodes[].devices` (NOT a raw manifest — the migration to the upstream-subchart wrapper has landed). Commit `dfb706b`; `helm template … | oc diff -n rook-ceph` showed exactly `+3 devices` (generation 5→6), nothing else; kubeconform 38/38.

After ArgoCD synced (one ~3-min poll cycle later), Rook spawned 3 fresh `osd-prepare` jobs (all Complete in ~40 s) and brought the OSDs up:

```
ID  CLASS  WEIGHT    STATUS   host
 3   hdd   3.63869    up      node4   (osd.3)
 4   hdd   3.63869    up      node5   (osd.4)
 5   hdd   3.63869    up      node6   (osd.5)
 0/1/2 nvme 0.46579   up      (existing)
ceph osd crush class ls  ->  ["nvme","hdd"]
ceph -s  ->  6 osds: 6 up, 6 in; 220 pgs active+clean; HEALTH_WARN (known slow-op + stale mgr crash)
```

**Phase 2 needed no manual reclassify** — Ceph auto-detected `device_class=hdd` on osd.3/4/5 from the rotational flag (the `crush rm/set-device-class` fallback below was not needed). The load-bearing observation: **`220 pgs active+clean` the entire time** — the additive prediction held exactly. The `device_class=nvme` CRUSH rule on `nvme-replicated` kept all existing data on NVMe, so **no rebalance, no degraded window** despite the no-drain 3-OSD topology. New raw HDD capacity: 3× 3.64 TiB ≈ **10.9 TiB raw (~3.6 TiB usable at size=3)**, in the `hdd` device class, **idle until a pool targets it** (Phase 3 RGW flip / Phase 4 CephFS).

### Phase 2 — Verify CRUSH device classes

Rook/Ceph auto-detects device class via SMART (HDD vs SSD) at OSD
bring-up. Should be fine for spinning rust, but verify:

```bash
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd crush class ls
# Expected output:
#   nvme
#   hdd
```

If `hdd` isn't there, the OSDs got classified as something else
(some older drives report as `unknown` or `ssd` if the rotational
flag is misread). Fix manually for the 3 new OSDs (assuming
they're osd.3 / osd.4 / osd.5):

```bash
oc -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd crush rm-device-class osd.3 osd.4 osd.5
oc -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd crush set-device-class hdd osd.3 osd.4 osd.5
```

### Phase 3 — Flip RGW dataPool to HDD

Single-line `values.yaml` change in `components/storage/ceph-object-store/`:

```diff
   dataPool:
     failureDomain: host
-    deviceClass: nvme
+    deviceClass: hdd
     replicated:
       size: 3
     parameters:
       pg_num_min: "32"
```

`deviceClass: nvme → hdd` — Ceph re-creates the CRUSH rule for the
pool to select `hdd` OSDs. ALL existing data in the pool (Loki's
~50 GiB) migrates from NVMe OSDs to HDD OSDs over the storage
backnet. Background recovery, doesn't block IO, takes ~20-30 minutes
at backnet line rate.

`pg_num_min` stays at 32 — with only 3 HDD OSDs sharing the budget
with CephFS-HDD, 32 PGs is the right floor for the RGW slice. Bump
later if Loki retention grows or OADP traffic ramps up.

Apply, then monitor migration:

```bash
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool ls detail | grep -A 5 buckets.data
oc -n rook-ceph exec deploy/rook-ceph-tools -- watch -n 5 'ceph -s'
# Watch %recovery_objects + pgs not active+clean
```

The RGW endpoint, bucket names, and client config don't change.
Loki keeps writing while the data migrates underneath. No downtime.

**Executed 2026-06-12 — surfaced a Rook gotcha: a `deviceClass` change on an
EXISTING pool is a no-op at the Ceph layer.** The single-line `deviceClass:
nvme → hdd` committed (`a119cc1`) + synced fine — the CephObjectStore CR showed
`dataPool.deviceClass: hdd`, and the operator even logged `reconciling
replicated pool ceph-objectstore.rgw.buckets.data succeeded` with the diff
`DeviceClass: "nvme" → "hdd"`. **But the pool's CRUSH rule was never touched** —
`ceph osd crush rule dump ceph-objectstore.rgw.buckets.data` still did `step
take default class nvme`, no data moved (all 220 pgs `active+clean`, hdd tier
empty). **Rook sets a pool's device class at CREATION and does not reconcile a
`deviceClass` change on an existing pool**; an operator restart just re-runs the
same no-op. (Same family as the documented "Rook doesn't clear `public_network`
on provider change" gotcha.)

Manual completion (toolbox, one-time, operator-confirmed Ceph mutation):

```bash
ceph osd crush rule create-replicated rgw-buckets-data-hdd default host hdd
ceph osd pool set ceph-objectstore.rgw.buckets.data crush_rule rgw-buckets-data-hdd
```

Created an hdd-targeting rule + repointed the pool → backfill kicked off
immediately. ~16 GiB stored / 47 GiB raw / ~21.7k objects migrated NVMe→HDD over
~30 min (HDD-write-bound, ~16–20 MiB/s, one backfilling PG at a time on the
no-drain topology). Loki kept writing + the RGW endpoint/buckets were unchanged
throughout (RGW pod `Running` every tick). `ceph df` before → after:

```
CLASS   before               after                 delta
nvme    81.8% (260 GiB avail) 78.6% (306 GiB avail) ~47 GiB raw freed
hdd     0.13% (214 MiB used)  0.43% (48 GiB used)   data now on hdd tier (3.4 TiB avail)
```

Bonus: freed ~47 GiB raw on the 81.8%-full NVMe class (nvme-replicated was at
85.6% used) — the tiering doubles as NVMe-pressure relief. **Leftover:** the old
Rook-created rule `ceph-objectstore.rgw.buckets.data` (`default~nvme`) is now
orphaned (cosmetic; Rook won't reconcile it). Bug drafted at
`bugs/upstream-rook-deviceclass-change-not-propagated-existing-pool.md`.
**Implication for Phase 4:** brand-new pools get their device class correctly at
creation — this only bites deviceClass *changes* on *existing* pools, so CephFS
(fresh pools) is unaffected.

### Phase 4 — Ship CephFS chart

New chart at `components/storage/cephfs/`. One `CephFilesystem` CR
with the two-tier shape from CLAUDE.md:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: cephfs
  namespace: rook-ceph
spec:
  metadataPool:
    failureDomain: host
    deviceClass: nvme              # always NVMe for metadata
    replicated:
      size: 3

  dataPools:
    - name: replicated-nvme        # low-latency tier
      failureDomain: host
      deviceClass: nvme
      replicated:
        size: 3
      parameters:
        pg_num_min: "32"

    - name: replicated-hdd         # bulk tier
      failureDomain: host
      deviceClass: hdd
      replicated:
        size: 3
      parameters:
        pg_num_min: "32"

  preservePoolsOnDelete: true
  preserveFilesystemOnDelete: true

  metadataServer:
    activeCount: 1
    activeStandby: true
    placement:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: rook-ceph-mds
              topologyKey: kubernetes.io/hostname
```

Two StorageClasses, pointing at the same FS, differing only in `pool`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: cephfs-nvme }
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  fsName: cephfs
  pool: cephfs-replicated-nvme    # the rendered Ceph pool name is <fs>-<dataPool>
  ...
reclaimPolicy: Delete
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: cephfs-hdd }
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  fsName: cephfs
  pool: cephfs-replicated-hdd
  ...
reclaimPolicy: Delete
allowVolumeExpansion: true
```

Enable in root-app at wave 4 (storage), after `rook-ceph-cluster`
which is at wave 3.

**Executed 2026-06-12 — and the plan above changed a lot in flight.** Three operator
corrections + a Rook gotcha + a CSI incident reshaped it:

- **Packaging:** NOT a new `components/storage/cephfs/` chart — shipped **inside the
  `rook-ceph-cluster` wrapper** (`cephFileSystems` + a local `templates/cephfs-storageclasses.yaml`
  + `pgNumFloor` entry). No new root-app entry. The wrapper already owns the CephCluster + pools.
- **Bulk tier is erasure-coded, not size=3** (operator's call, mid-rollout): one data pool
  `bulk-hdd` = **EC 2+1** (`k=2,m=1` — the only profile that fits 3 hosts at failureDomain=host;
  66% usable vs 33%). **`min_size 2`** (Ceph EC defaults k+1=3, which would make the tier
  read-only on any host-down incl. upgrade reboots; 2 keeps it writable at the redundancy floor).
  The NVMe RWX tier was **dropped**. `ec_overwrites` is auto-set by Rook on the EC data pool.
- **OSD devices → `/dev/disk/by-path/pci-…-ata-N`** (the SATA bay port) instead of by-id WWN:
  slot-stable so a drive swap reuses the OSD (NVMe is already `/dev/nvme0n1`). The switch was
  transparent — `osd.3/4/5` survived it (Rook matches OSDs by on-disk metadata, not path).
- **Rook can't transition a live FS's default data pool / replicated→EC in place** — the first
  (replicated, NVMe+HDD) FS had to be **torn down** (`ceph fs fail`/`rm` + delete the 3 pools,
  operator-confirmed) and recreated as EC. Same gotcha family as deviceClass-on-existing-pool.
- **`ceph fs new` with an EC pool as the *default* data pool needs `--force`** (Ceph discourages
  it), and **Rook does NOT pass `--force`** → Rook's reconcile created the pools + logged
  "ReconcileSucceeded" but the FS never got created. Resolution: **one-time manual**
  `ceph fs new cephfs cephfs-metadata cephfs-bulk-hdd --force`; Rook then **adopts** the FS and
  manages the MDS (1 active `cephfs-a` + 1 standby on different hosts via the required
  podAntiAffinity). This is a discouraged-but-supported config (EC default data pool + ec_overwrites).
  **Caveat for any future CephFS teardown/recreate: the FS must be re-created manually with
  `--force` — Rook won't.**
- **pg_num floor:** the bootstrap Job didn't catch the fresh pool; bumped manually
  `ceph osd pool set cephfs-bulk-hdd pg_num 32` (+ pgp_num) — the documented bootstrap shape.
- **StorageClass immutability bit us:** the `cephfs-hdd` SC's `pool` changed
  `cephfs-replicated-hdd`→`cephfs-bulk-hdd`, but SC params are immutable → ArgoCD stalled
  `OutOfSync/Missing` ("updates to parameters are forbidden") + the SC pointed at a dead pool.
  Fix: `Replace=true` sync-option on the SC template (`d85f7fd`) + delete the stale SC → ArgoCD
  recreated it with the right pool.
- **Mid-rollout CSI incident** (separate, see `blog/blog-rook-ceph-draft.md`): Renovate had
  auto-bumped Rook 1.19.6→**1.20.0**, whose CSI ServiceAccount renaming left `ceph-csi-*-sa`
  missing → CSI broken for new pods. Reverted to coherent **v1.19.5** (`49406f5`); the operator
  version change rolled all 6 OSDs one-at-a-time (clean). Also cleared 28-day-old stale CSI
  nodeplugin pods referencing a deleted dockercfg secret.

**End state:** `cephfs` active, EC 2+1 `cephfs-bulk-hdd` (min_size 2, pg_num 32, ec_overwrites),
metadata replicated on NVMe, MDS active+standby on different hosts, SC `cephfs-hdd`→`cephfs-bulk-hdd`,
ArgoCD Synced+Healthy, 253 pgs active+clean.

**The CR `phase: Failure` was NOT cosmetic — it blocked Phase 5.** Rook's CephFilesystem reconcile
had wedged on a `ceph-file-controller-detect-version` CmdReporter timeout (during the CSI churn),
so it never created the **`csi` CephFilesystemSubVolumeGroup** — and the CephFS CSI provisioner
puts every subvolume in that group. So the first Phase-5 PVC sat `Pending` with
`ProvisioningFailed: rados ret=-2 … "subvolume group 'csi' does not exist"`, and both the
CephFilesystem and `cephfs-csi` SubVolumeGroup CRs were in `Failure`. **Fix: restart the rook-ceph
operator** (safe at the same version v1.19.5 — only a version *change* rolls OSDs; verified 6 OSDs
stayed up). The fresh reconcile's detect-version job **succeeded** (it was flaky, not persistently
broken) → Rook created the `csi` subvolumegroup, and the FS + SVG CRs went `Ready`. Lesson: a
CephFilesystem stuck in `Failure` can block CSI provisioning even when `ceph fs status` shows the
FS active — don't dismiss it as cosmetic.

**Phase 5 — validated 2026-06-12.** Test RWX PVC on `cephfs-hdd`: **Bound** in ~5s
(`ReadWriteMany`). IO from a pod: write 200 MiB @ **22.1 MB/s** + read @ **76.6 MB/s** (both
`direct`; write is EC-2+1-on-HDD-amplified, fine for a bulk/cold tier). Clean teardown — PVC
delete → CSI removed the subvolume + PV, **no orphan PV/Released, `ceph fs subvolume ls = []`**.
End-to-end path proven: SC → EC pool → provision → mount → IO → reclaim. **HDD-tier rollout
COMPLETE (Phases 1-5).**

### Phase 5 — Validate

Test PVC against each StorageClass:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-cephfs-nvme, namespace: default }
spec:
  accessModes: [ ReadWriteMany ]
  resources: { requests: { storage: 1Gi } }
  storageClassName: cephfs-nvme
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-cephfs-hdd, namespace: default }
spec:
  accessModes: [ ReadWriteMany ]
  resources: { requests: { storage: 1Gi } }
  storageClassName: cephfs-hdd
EOF

# Both should bind within ~10 seconds.
oc -n default get pvc

# Quick IO test from a pod
oc -n default run cephfs-test --rm -it --image=busybox --overrides='{
  "spec":{"containers":[{
    "name":"x","image":"busybox","command":["sh"],"stdin":true,"tty":true,
    "volumeMounts":[{"name":"v","mountPath":"/data"}]
  }],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"test-cephfs-hdd"}}]}}' -- sh
# inside:
# dd if=/dev/zero of=/data/test bs=1M count=100 oflag=direct
# Expect ~80-100 MB/s (one client, one stream, HDD OSD primary).
```

Once both pass, delete the test PVCs. Don't leave them around — they
end up as orphan Released PVs on PVC removal (per the CSI quirk in
CLAUDE.md).

## Concerns + things to monitor

- **3 HDDs × 4.5 W idle = ~14 W extra continuous draw.** Small dent
  in the ~146 W lever-1 power savings. Net post-HDD-rollout rack
  should be ~241 W vs current 227 W. Still well below the pre-tuning
  372 W baseline.
- **Used drives, unknown lifespan.** Watch `smartctl_attribute_value{name="Reallocated_Sector_Ct"}`
  trends in Prometheus (already exposed by `smartctl-exporter`). Set
  a Prometheus alert if any drive's count climbs by >5 in any 24h
  window. With 7 burned-in shelf spares, a failure = chassis pull +
  reseat + redeploy as a new OSD, no waiting on shipping.
- **Same no-drain-headroom story as the NVMe tier.** 3 OSDs, host
  failure domain, size=3 = losing 1 OSD = degraded window with no
  rebalance target (each remaining host already has its 1 HDD OSD).
  Plan HDD maintenance like NVMe maintenance: one at a time, never
  overlapping, schedule during quiet IO windows.
- **4 TB usable ceiling.** Smaller than the original 12 TB I'd
  budgeted for. Bulk media (Jellyfin video, the big eater) stays on
  the existing NFS-CSI/Synology path; CephFS-HDD is for things that
  need RWX + Ceph guarantees but aren't huge (Immich, Jellyfin
  metadata, OADP). Capacity-pressure escape valve = swap a shelf
  spare into a node and grow that OSD's capacity, but that's a
  per-host scaling story; can't grow horizontally past 3 OSDs without
  a chassis change.
- **Long-tail recovery times.** Spinning rust + size=3 replication
  means a host failure during recovery takes longer to converge than
  the NVMe-only setup. Plan maintenance windows around backups, not
  during peak ingest hours.
- **No host-network HBA conflicts.** Unlike the NVMe-tied 10G NIC
  (which has the multus/host-network rabbit hole documented in
  CLAUDE.md), SATA HDDs just plug into the on-board controllers.
  No network stack interaction.

## 2026-06-10 - burn-in execution (node4, single internal bay, full depth)

This is the concrete, copy-pasteable execution of the generic burn-in procedure (Steps 1-5 above) on the actual hardware we have: **node4's single internal 3.5" bay, on a live cluster node**. We run one drive at a time, full depth (SMART baseline -> short -> long -> destructive `badblocks` -> post-diff), per the decision to burn all 10 drives to full depth rather than sampling. The burn-in HDD is a transient SATA device in the bay; it is **not** an OSD, Ceph stays untouched, node4 is **not** cordoned. The only costs are extra CPU/IO load on node4 and the device-targeting risk — and that risk is lethal, which is the whole reason the gate below exists.

### CRITICAL: node4's boot/etcd disk is SATA too — and the names ALREADY swapped

node4 is the maximum-blast-radius node in the cluster: control-plane master **and** worker, the NVMe Ceph OSD host, an etcd member, and it usually holds the API VIP. Its OS/boot/etcd disk is an **INTEL SSDSC2BX40 SATA SSD**, WWN `0x55cd2e404c20c200`, serial `BTHC615501ED400VGN`, carrying `/boot`, `/sysroot`, and etcd's data dir (`/var/lib/etcd` under `/sysroot`). It is in the **same `/dev/sd*` family** the burn-in HDD enumerates into.

**This is not hypothetical — it happened on the first drive (2026-06-10).** The internal 3.5" bay is **not hot-swap**, so installing drive #1 required powering node4 down. On the reboot, the HDD enumerated *first*:

| Device | At session start | After drive-1 install + reboot |
|---|---|---|
| `/dev/sda` | Intel boot/etcd SSD (ROTA=0) | **HUS726040ALA610 HDD** (ROTA=1, wwn-0x5000cca25df55694) |
| `/dev/sdb` | — | **Intel boot/etcd SSD** (moved here!) |
| `/dev/nvme0n1` | Samsung NVMe OSD | Samsung NVMe OSD (unchanged) |

A hardcoded "the HDD is `/dev/sdb`" would now `badblocks` the **boot/etcd disk** — simultaneously-degraded etcd and Ceph on a zero-drain-headroom cluster, in one keystroke. **Never type a literal `/dev/sdX` in this runbook.** The target is resolved by `/dev/disk/by-id/wwn-*` only, validated by the gate, and re-verified by serial immediately before every write. Because names are proven unstable, the gate must NOT trust `/dev/sdX` names for *either* allow or deny — it leans on **WWN denylist + `ROTA=1` + ~4 TB size + by-id resolution**, all name-independent. Default-deny: anything the gate cannot positively prove safe is refused.

### 1. Execution environment

SCOS is immutable — there is no `smartctl`, `badblocks`, or `e2fsprogs` on the host PATH, and we do **not** `rpm-ostree install` them (that mutates the OS image and needs a reboot, and node4 is the worst node to reboot casually). The tools come from a container that bind-mounts the host's `/dev` and `/sys`.

**Preferred path — toolbox over SSH.** `toolbox` ships in SCOS; it launches a privileged CentOS Stream `support-tools` container in the host namespaces with `/dev`, `/sys`, `/proc`, and the host root bind-mounted, so ATA/SCSI passthrough ioctls reach the real drive.

```bash
ssh core@node4.okd.sudops.pl          # key auth, same key used for cert recovery

sudo toolbox                          # first run pulls support-tools (~1-2 min); then instant
# base support-tools has smartctl but NOT badblocks; badblocks lives in e2fsprogs:
dnf install -y smartmontools e2fsprogs util-linux   # idempotent, re-run safe
smartctl --version | head -1
badblocks -V 2>&1 | head -1
```

`smartctl` needs **no `-d` flag** on node4's on-board SATA HBA (default autodetect works). Note for the spare campaign later: **the future USB3 dock needs `-d sat`** on every invocation — USB-SATA bridges don't pass ATA commands transparently. On node4's internal bay, no `-d`.

**Fallback — privileged debug pod.** If you'd rather drive everything through `oc` (no SSH), a privileged pod pinned to node4 with host `/dev` bind-mounted does the same job. It's the fallback, not the default — it leaves a privileged pod on the max-blast-radius node, and **for the destructive step you must `chroot /host` and re-run the gate inside the chroot** (an `oc debug` pod's `/dev` is the container's, not the host's, unless chrooted — see the `/dev` vs `/sys` self-check in the gate below).

```yaml
# hdd-burnin-pod.yaml — apply with the OPERATOR kubeconfig (privileged pod needs it;
# this is a deliberate mutation that touches NO cluster/Ceph state, only spawns a tool pod).
apiVersion: v1
kind: Pod
metadata: { name: hdd-burnin, namespace: default }
spec:
  nodeName: node4.okd.sudops.pl
  serviceAccountName: hdd-burnin            # see SCC grant below
  restartPolicy: Never
  containers:
    - name: tools
      image: registry.access.redhat.com/rhel9/support-tools
      command: ["sleep", "infinity"]
      securityContext: { privileged: true }   # ATA/SCSI passthrough ioctls
      volumeMounts:
        - { name: dev, mountPath: /dev }
        - { name: sys, mountPath: /sys }
        - { name: hostlog, mountPath: /host-logs }
  volumes:
    - { name: dev,     hostPath: { path: /dev } }
    - { name: sys,     hostPath: { path: /sys } }
    - { name: hostlog, hostPath: { path: /var/tmp } }   # logs land on host, retrievable
  tolerations: [ { operator: Exists } ]                 # node4 is a master; tolerate taints
```

```bash
# operator kubeconfig — OpenShift rejects privileged:true without an SCC grant:
oc -n default create sa hdd-burnin
oc adm policy add-scc-to-user privileged -z hdd-burnin -n default
oc apply -f hdd-burnin-pod.yaml
oc -n default exec -it hdd-burnin -- bash
#   inside: dnf install -y smartmontools e2fsprogs util-linux tmux
#   then run the same gate + sequence. For the destructive write the pod path is
#   keep-alive-trivial: badblocks is parented to the pod's PID 1, so a `nohup ... &`
#   survives the exec disconnect on its own — no tmux/systemd gymnastics.
#   Do NOT `oc delete pod hdd-burnin` until the run finishes and logs are copied off.
```

**Keep-alive (multi-hour runs must survive SSH drop).** Full depth is ~32-38 h/drive: the long self-test (~8 h) is disconnect-safe because the drive runs it internally (you only poll), but `badblocks` (~24-30 h) runs in the container and dies with its parent process. Pick one:

- **`tmux` (preferred, reattachable):** `dnf install -y tmux; tmux new -s burnin`, run badblocks inside, detach `Ctrl-b d`. **Caveat:** a second `sudo toolbox` may spawn a *fresh* container rather than re-entering the running one — reattach via `sudo podman ps --filter name=toolbox` then `sudo podman exec -it <ctr> tmux attach -t burnin`.
- **`systemd-run --scope` on the host (most robust):** decouples the run from both SSH and the toolbox shell. From the host: `sudo systemd-run --scope --unit=hdd-burnin podman exec <toolbox-ctr> bash -c '...badblocks...'`. Monitor `journalctl -u hdd-burnin.scope -f`, stop `sudo systemctl stop hdd-burnin.scope`.
- **`nohup ... &`** in the pod path (process parented to pod PID 1).

**If the keep-alive context is lost** (tmux pane dies, pod restarts), do **not** reattach-and-rerun `badblocks` against a saved `$DRIVE` from notes — the device topology may have changed. **Re-run the gate (Step 3) from scratch.** A badblocks that dies mid-run is never auto-restarted.

Write all logs to a host-visible path (`/var/tmp` is bind-mounted in both paths) so captures can be pulled off node4 into `data/hdd-burnin-2026-06-10/` per Step 5.

### 2. Device-safety pre-flight gate (hardened)

This gate is the **only** way `DRIVE` gets set, and **nothing destructive or even identity-capturing runs before it passes.** It fails closed on anything it cannot positively evaluate. Paste the whole function into the toolbox shell.

**Step 2a — empty-bay/full-bay diff to find the new device.** Snapshot rotational devices with the bay empty, insert one drive, snapshot again, assert exactly one new rotational device appeared. node4's only rotational device is the HDD (`/dev/sda` is ROTA=0, `nvme0n1` is NVMe), so the HDD stands out. **These checks return, they don't just print:**

```bash
BEFORE=$(mktemp); AFTER=$(mktemp)     # per-session files; stale /tmp can't be reused
# --- BEFORE insertion (bay empty) ---
lsblk -dno NAME,ROTA,TYPE | awk '$2==1 && $3=="disk"{print $1}' | sort > "$BEFORE"
[ -s "$BEFORE" ] && echo "WARN: rotational disks already present before insert — confirm bay was empty:" && cat "$BEFORE"

# --- INSERT one HDD into the single 3.5" bay, wait ~10s for SATA hotplug ---

# --- AFTER insertion ---
lsblk -dno NAME,ROTA,TYPE | awk '$2==1 && $3=="disk"{print $1}' | sort > "$AFTER"
NEW_ROTA=$(comm -13 "$BEFORE" "$AFTER")
NEW_COUNT=$(printf '%s\n' "$NEW_ROTA" | grep -c .)
[ "$NEW_COUNT" -eq 1 ] || { echo "STOP: expected exactly 1 new rotational device, got $NEW_COUNT. REFUSING." >&2; return 1 2>/dev/null || exit 1; }
[ -n "$NEW_ROTA" ]     || { echo "STOP: no new rotational device — drive not seated. REFUSING." >&2; return 1 2>/dev/null || exit 1; }
echo "new rotational disk: /dev/$NEW_ROTA"

# Resolve to a stable by-id wwn-*/ata-* symlink that points at exactly the new device:
BYID=""
for L in /dev/disk/by-id/wwn-* /dev/disk/by-id/ata-*; do
  [ -e "$L" ] || continue
  case "$L" in *-part*) continue ;; esac          # whole-disk symlinks only
  [ "$(basename "$(readlink -f "$L")")" = "$NEW_ROTA" ] && { BYID="$L"; break; }
done
[ -n "$BYID" ] || { echo "STOP: no whole-disk wwn-/ata- symlink resolves to /dev/$NEW_ROTA. REFUSING." >&2; return 1 2>/dev/null || exit 1; }
echo "by-id path: $BYID  ->  /dev/$NEW_ROTA"
```

**Step 2b — `assert_burnin_target`.** Returns 0 only on a fully-positive identity match plus a typed-serial confirmation. Every failure path `return`s; `_fail` is fatal-by-caller. On success it stamps the resolved identity into `GATE_*` globals the caller **must** use by value (closes the re-resolution TOCTOU).

```bash
assert_burnin_target() {
  local RED=$'\e[1;31m' GRN=$'\e[1;32m' YEL=$'\e[1;33m' NC=$'\e[0m'
  _fail() { printf '%s[GATE DENIED]%s %s\n' "$RED" "$NC" "$*" >&2; return 1; }
  _ok()   { printf '%s[ok]%s %s\n' "$GRN" "$NC" "$*"; }

  # ---- node4 invariants (this gate is node4-specific) ----
  # NO boot-disk NAME constant: /dev/sd* names are PROVEN unstable here (2026-06-10 the
  # HDD took /dev/sda and the boot SSD moved to /dev/sdb after a reboot). The boot SSD is
  # rejected by WWN denylist + ROTA=0 + 372 GB size — all name-independent. Names are
  # NEVER trusted for allow or deny; only the nvme* pattern is name-stable enough to use.
  # System-disk WWNs across ALL nodes (boot SSDs + NVMe OSDs), normalized bare hex (no 0x/eui.).
  # Defense-in-depth backstop only — the PRIMARY guards are ROTA=1 + model + ~4TB size + unmounted,
  # all node-agnostic. Confirmed by probe each time a node's bay is opened (names + WWNs differ per node):
  #   node4: Intel boot 55cd2e404c20c200, Samsung OSD 002538ba11b25345
  #   node5: Toshiba boot 500080d910e743a6, Samsung OSD 36483330529183340025384600000001
  #   node6: Toshiba boot 500080d910e71bba, Samsung OSD 36483330547252560025385800000001
  local DENY_WWNS="55cd2e404c20c200 002538ba11b25345 500080d910e743a6 36483330529183340025384600000001 500080d910e71bba 36483330547252560025385800000001"
  local MODEL_RE='HUS726040'                # FAMILY match: real drives are ALA610 (512n), the
                                            # order said ALE610 — match the family, not the suffix.
  local MIN_BYTES=3900000000000 MAX_BYTES=4100000000000
  local ARG="$1"
  _norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' :' | sed -E 's/^0x//; s/^eui\.//'; }

  [ -n "$ARG" ] || { _fail "no device path. Usage: assert_burnin_target /dev/disk/by-id/wwn-..."; return 1; }

  # Check 1: by-id wwn-/ata- SYMLINK only — bare /dev/sdX forbidden (enumeration unstable):
  case "$ARG" in /dev/disk/by-id/wwn-*|/dev/disk/by-id/ata-*) : ;;
    *) _fail "'$ARG' is not a /dev/disk/by-id/{wwn,ata}-* path. Bare /dev/sdX REFUSED."; return 1 ;; esac
  [ -L "$ARG" ] || { _fail "'$ARG' is not a symlink. REFUSING."; return 1; }

  local REAL SDX
  REAL=$(readlink -f "$ARG" 2>/dev/null) || { _fail "cannot readlink '$ARG'."; return 1; }
  [ -b "$REAL" ] || { _fail "'$REAL' is not a block device."; return 1; }
  SDX=$(basename "$REAL")
  [ -e "/sys/block/$SDX/queue/rotational" ] || { _fail "no /sys/block/$SDX — not a whole disk."; return 1; }
  # partition guard (the sysfs 'partition' file exists iff it's a partition):
  [ -e "/sys/class/block/$SDX/partition" ] && { _fail "'$SDX' is a partition, not a whole disk."; return 1; }

  # /dev vs /sys same-namespace self-check (catches toolbox/debug-pod divergence; fail closed):
  local DEVT SYST
  DEVT=$(stat -c '%t:%T' "$REAL" 2>/dev/null); SYST=$(cat "/sys/block/$SDX/dev" 2>/dev/null)
  [ -n "$DEVT" ] && [ -n "$SYST" ] || { _fail "cannot cross-check /dev vs /sys for $SDX (container ns mismatch?)."; return 1; }
  printf '%s[ok]%s /dev maj:min(hex)=%s  /sys=%s — operator: confirm these reference the same disk\n' "$GRN" "$NC" "$DEVT" "$SYST"

  # Reject name-stable device families only (NVMe naming never collides with sdX; rbd/nbd/dm/
  # loop/sr are virtual). The boot SSD is NOT rejected by name here (it can be any sdX) — it
  # is caught by the WWN denylist (Check 3), ROTA=1 requirement (Check 4) and size (Check 5).
  case "$SDX" in
    nvme*) _fail "resolved '$SDX' is an NVMe device (the OSD). ABSOLUTE NO."; return 1 ;;
    rbd*|nbd*|dm-*|loop*|sr*) _fail "resolved '$SDX' is a live/virtual device (RBD/NBD/dm/loop). REFUSING."; return 1 ;;
  esac

  # Identity via smartctl (fail closed if unreadable):
  local SMART MODEL SERIAL WWN
  SMART=$(smartctl -i "$REAL" 2>/dev/null) || { _fail "smartctl -i failed on '$REAL' — cannot identify. REFUSING."; return 1; }
  MODEL=$(printf '%s\n' "$SMART" | sed -n -E 's/^(Device Model|Model Number):[[:space:]]+//p' | head -1)
  SERIAL=$(printf '%s\n' "$SMART" | sed -n -E 's/^Serial Number:[[:space:]]+//p' | head -1)
  WWN=$(printf '%s\n' "$SMART" | sed -n -E 's/^LU WWN Device Id:[[:space:]]+//p' | head -1)
  [ -n "$MODEL" ] && [ -n "$SERIAL" ] || { _fail "could not read Model/Serial from smartctl. REFUSING."; return 1; }

  # Check 2: exact model:
  printf '%s' "$MODEL" | grep -qiE "$MODEL_RE" || { _fail "model '$MODEL' != expected ($MODEL_RE). REFUSING."; return 1; }
  _ok "model: $MODEL"

  # Check 3 (WWN denylist) — normalize BOTH sides (strip 0x/eui./spaces) so smartctl's
  # space-separated no-0x form still matches. Sources: smartctl, by-id path, udev:
  local WWN_BYID WWN_UDEV
  WWN_BYID=$(printf '%s' "$ARG" | sed -n -E 's#.*/wwn-(0x[0-9a-fA-F]+).*#\1#p')
  WWN_UDEV=$(udevadm info --query=property --name="$REAL" 2>/dev/null | sed -n -E 's/^ID_WWN(_WITH_EXTENSION)?=//p' | head -1)
  for w in "$WWN" "$WWN_BYID" "$WWN_UDEV"; do
    n=$(_norm "$w"); [ -n "$n" ] || continue
    for d in $DENY_WWNS; do
      case "$n" in *"$d"*) _fail "WWN '$w' matches a system-disk DENYLIST entry ($d). ABSOLUTE NO."; return 1 ;; esac
    done
  done
  _ok "WWN not in denylist"

  # Check 4: rotational == 1 (the ONLY spinning device in node4):
  [ "$(cat "/sys/block/$SDX/queue/rotational" 2>/dev/null)" = "1" ] || { _fail "$SDX rotational != 1 (boot SSD + NVMe OSD are 0). REFUSING."; return 1; }
  _ok "rotational = 1"

  # Check 5: size ~4 TB:
  local SIZE_BYTES; SIZE_BYTES=$(blockdev --getsize64 "$REAL" 2>/dev/null)
  case "$SIZE_BYTES" in ''|*[!0-9]*) _fail "blockdev returned non-numeric '$SIZE_BYTES'. REFUSING."; return 1 ;; esac
  { [ "$SIZE_BYTES" -ge "$MIN_BYTES" ] && [ "$SIZE_BYTES" -le "$MAX_BYTES" ]; } || { _fail "size $SIZE_BYTES outside ~4TB window. REFUSING."; return 1; }
  _ok "size ~4TB: $(numfmt --to=iec --suffix=B "$SIZE_BYTES" 2>/dev/null || echo "$SIZE_BYTES B")"

  # Check 6: not mounted / swap / claimed (authority = /proc/mounts + /proc/swaps + sysfs holders;
  # lsblk MOUNTPOINTS is advisory — false-negative-prone on old util-linux):
  grep -qE "^/dev/$SDX([0-9]+)?[[:space:]]" /proc/mounts && { _fail "/dev/$SDX is mounted. REFUSING."; return 1; }
  grep -qE "^/dev/$SDX([0-9]+)?[[:space:]]" /proc/swaps  && { _fail "/dev/$SDX is swap. REFUSING."; return 1; }
  [ -n "$(ls "/sys/block/$SDX/holders" 2>/dev/null)" ] && { _fail "/dev/$SDX has holders (dm/md/LVM). REFUSING."; return 1; }
  local FSTYPE; FSTYPE=$(lsblk -nro FSTYPE "$REAL" 2>/dev/null | sed '/^$/d' | sort -u | paste -sd, -)
  printf '%s' "$FSTYPE" | grep -qiE 'ceph_bluestore|LVM2_member' && { _fail "carries '$FSTYPE' (Ceph/LVM) — in-use device. REFUSING."; return 1; }
  [ -z "$FSTYPE" ] && _ok "blank (no fs/raid signature)" || printf '%s[note]%s existing signature(s): %s — badblocks will destroy them.\n' "$YEL" "$NC" "$FSTYPE"

  # ---- resolved identity ----
  printf '\n%s========= RESOLVED BURN-IN TARGET =========%s\n' "$GRN" "$NC"
  printf '  by-id : %s\n  dev   : %s (/dev/%s)\n  model : %s\n  serial: %s\n  WWN   : %s\n  size  : %s\n%s===========================================%s\n\n' \
    "$ARG" "$REAL" "$SDX" "$MODEL" "$SERIAL" "${WWN:-$WWN_BYID}" \
    "$(numfmt --to=iec --suffix=B "$SIZE_BYTES" 2>/dev/null || echo "$SIZE_BYTES B")" "$GRN" "$NC"

  # Final human gate — type the serial exactly (last gate before DESTRUCTIVE badblocks -w):
  printf '%sType the drive SERIAL exactly to confirm (serial> )%s ' "$YEL" "$NC"
  local TYPED; IFS= read -r TYPED
  [ "$TYPED" = "$SERIAL" ] || { _fail "typed '$TYPED' != resolved '$SERIAL'. REFUSING."; return 1; }

  # Stamp resolved identity for the caller to use BY VALUE (no re-resolution):
  GATE_REAL="$REAL"; GATE_BYID="$ARG"; GATE_SERIAL="$SERIAL"; GATE_WWN="${WWN:-$WWN_BYID}"
  printf '%s[GATE PASSED]%s %s  serial=%s\n' "$GRN" "$NC" "$REAL" "$SERIAL"
  return 0
}
```

Why default-deny holds (name-independent — because names swap): the **Intel boot/etcd SSD** fails the WWN denylist (`0x55cd2e404c20c200`, normalized to match smartctl's no-`0x` form) **and** `ROTA=0` (Check 4) **and** the 372 GB size (Check 5) **and** the mount/holders check — four independent gates, *none* of which depend on it being `/dev/sda` vs `/dev/sdb`. The **NVMe OSD** fails the `nvme*` pattern, the denylist, `ROTA=0`, and size. A bare `/dev/sdX` argument fails Check 1. RBD/NBD/dm/loop fail the family check. The real HDD (`HUS726040`, ROTA=1, ~4 TB, WWN not in denylist) passes all, then requires the operator to read the serial off the printout (which came from the drive via `smartctl`, not from a stale variable). Anything unreadable — `smartctl` won't talk, `blockdev` non-numeric, `/sys/block/$SDX` missing, `/dev`↔`/sys` mismatch — is a **refusal**. On a no-drain cluster, "I'm not sure" means "no."

Before relying on this gate, unit-test it once: run `assert_burnin_target` against `/dev/disk/by-id/wwn-<boot-ssd>`, against the NVMe's by-id, and against a bare `/dev/sdb` — all three must return exit 1.

### 3. Per-drive full-depth sequence

Run the gate, then chain into the depth steps using **`$DRIVE` bound to the gate's by-id path** and **`$REAL` to the gate's resolved device** — never reassign `DRIVE=/dev/sdX` (that would undo the gate; the generic Step 1 in this draft opens with such a line — **do not paste it**, use the bound values below).

```bash
# Gate is the SOLE path to setting DRIVE. Nothing runs if it fails.
if assert_burnin_target "$BYID"; then
  DRIVE="$GATE_BYID"; REAL="$GATE_REAL"; SERIAL="$GATE_SERIAL"
  echo "Gate passed. DRIVE=$DRIVE REAL=$REAL serial=$SERIAL — proceeding full depth."
else
  echo "GATE DENIED — do not run any destructive command. Re-check the drive." >&2
  return 1 2>/dev/null || exit 1
fi
OUT=/var/tmp   # host-visible; pulled into data/hdd-burnin-2026-06-10/ in Step 5
```

**Step 3a — baseline SMART (~1 min).** Diff anchor for the post-pass. Fail-fast: return-to-seller (skip the 8 h + 30 h tests) if any trip.

```bash
smartctl -x "$DRIVE" > "$OUT/smart-baseline-${SERIAL}.txt"
smartctl -H "$DRIVE"
smartctl -A "$DRIVE" | grep -E 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count|Power_On_Hours'
```

| Check | Reject threshold |
|---|---|
| SMART overall-health | anything other than `PASSED` |
| `Reallocated_Sector_Ct` | `> 50` |
| `Current_Pending_Sector` | `> 0` |
| `Offline_Uncorrectable` | `> 0` |
| `UDMA_CRC_Error_Count` | `> 0` |
| `Power_On_Hours` | `> 70000` |

These are used datacenter pulls — a small **stable** non-zero `Reallocated_Sector_Ct` is acceptable; the bar is "stable across long+badblocks," not "zero." Baseline records the start; Steps 3d/3e check for new increments.

**Step 3b — short self-test (~2 min).** Cheapest filter; if it fails, the long test will too — return the drive, don't waste 8 h.

```bash
smartctl -t short "$DRIVE"; sleep 130
smartctl -l selftest "$DRIVE" | head -10    # latest line must read "Completed without error"
```

**Step 3c — long self-test (~8 h).** Internal surface scan; runs **inside the drive firmware**, near-zero host load, so this step does **not** stress node4's HBA — no etcd concern here. Poll, don't block. Disconnect-safe on its own.

```bash
smartctl -t long "$DRIVE"
# poll every ~30 min:
smartctl -A "$DRIVE" | grep -i remaining
smartctl -l selftest "$DRIVE" | head -5      # PASS = latest line "Completed without error"
```

**Step 3d — destructive badblocks under ionice, with etcd watch (~24-30 h).** This is the **write**-path test and the only step that loads node4's SATA HBA — the same HBA `/dev/sda` (etcd) hangs off. Run it as the keep-alive-protected command (tmux / systemd-run / nohup per Step 1).

Re-confirm the serial **immediately before the write** — closes the TOCTOU / re-enumeration window between gate and `open()`:

```bash
NOW_SERIAL=$(smartctl -i "$REAL" | sed -n -E 's/^Serial Number:[[:space:]]+//p' | head -1)
[ "$NOW_SERIAL" = "$SERIAL" ] || { echo "DEVICE UNDER $REAL CHANGED SERIAL ($NOW_SERIAL != $SERIAL) — ABORT, re-run Step 2/3." >&2; return 1 2>/dev/null || exit 1; }

# ionice -c3 = idle I/O class. NOTE: effectiveness is scheduler-dependent — verify first:
cat /sys/block/$(basename "$REAL")/queue/scheduler   # if [none]/[mq-deadline], ionice is ~no-op;
                                                      # then the etcd-fsync watch below is the REAL net.
ionice -c3 badblocks -wsv -b 4096 "$REAL" 2>&1 | tee "$OUT/badblocks-${SERIAL}.log"
```

`-w` destructive (fine, blank target), `-s` progress, `-v` per-pattern bad-block count, `-b 4096` matches the 4K sector.

**Watch node4's etcd member specifically the whole time** (not the aggregate — it hides node4's excursion behind two healthy members). Automate the abort rather than eyeballing for 30 h:

```bash
# workstation, KUBECONFIG=~/.kube/config-readonly (exec needs operator kubeconfig);
# verify the etcd metrics port for THIS pod before relying on it:
oc -n openshift-etcd get pod etcd-node4.okd.sudops.pl -o jsonpath='{.spec.containers[?(@.name=="etcd-metrics")].ports[*].containerPort}'; echo
# sample p99 WAL fsync for node4's member:
oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(etcd_disk_wal_fsync_duration_seconds_bucket{pod=~"etcd-node4.*"}[5m]))' \
  | jq -r '.data.result[].value[1]'   # seconds
```

Healthy p99 on this etcd-on-SATA-SSD is single-digit ms (~8-15 ms). The slow-fsync danger zone is a **sustained p99 > ~25 ms** during the badblocks pass — that means `ionice` isn't holding the HBA (likely `none`/`mq-deadline` scheduler). When it climbs and stays there: pause/kill badblocks (`kill -STOP` the PID, or `Ctrl-C` in the tmux pane), let etcd settle, and **finish that drive on the USB3 dock off-node instead** (no shared HBA, no etcd risk). etcd health on node4 outranks burn-in throughput every time. The long self-test (3c) is exempt — it doesn't touch the HBA.

**Step 3e — post-badblocks SMART + diff (~1 min).**

```bash
smartctl -x "$DRIVE" > "$OUT/smart-postbadblocks-${SERIAL}.txt"
for f in Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable UDMA_CRC_Error_Count; do
  printf '%-26s baseline=%s  post=%s\n' "$f" \
    "$(grep "$f" "$OUT/smart-baseline-${SERIAL}.txt"     | awk '{print $10}')" \
    "$(grep "$f" "$OUT/smart-postbadblocks-${SERIAL}.txt" | awk '{print $10}')"
done
```

**Per-drive PASS verdict** — all must hold: baseline clean (or only small *stable* reallocated); short = `Completed without error`; long = `Completed without error`; badblocks final log line = `0/0/0 errors`; post-diff = **zero new** reallocated / pending / offline / CRC vs baseline. Any new reallocated/pending/offline sector = reject even if badblocks reported 0 bad blocks (the drive silently remapped a marginal sector — imminent decline on a 9-year-old drive). PASS -> eligible for install or shelf-spare; FAIL -> return-to-seller.

Then power down the bay, pull the drive, insert the next, and **start again at Step 2** — re-run the empty/full diff and `assert_burnin_target` for **every** drive. Never assume the by-id symlink or `/dev/sdX` is the same across swaps.

### 4. Capture & bookkeeping

All artifacts for the whole campaign (10 drives) go in **one** directory keyed by serial, so an OSD's burn-in history is unambiguous 18 months later:

```
data/hdd-burnin-2026-06-10/
  HUS726040ALA610-<serial>-baseline.txt        # smartctl -x, pre-test
  HUS726040ALA610-<serial>-postbadblocks.txt   # smartctl -x, post-destructive
  HUS726040ALA610-<serial>-badblocks.log       # full badblocks -wsv output
  ... (PASS drives × 3 files)
  SUMMARY.md
```

Use the **exact** serial string `smartctl -i` prints — it matches the Prometheus `smartctl_device{serial_number=...}` labels and the physical drive label. Pull the captures off node4 into the repo:

```bash
# instantaneous SMART dumps — pipe straight into the keyed file (no host temp):
cd ~/Projects/homelab/data/hdd-burnin-2026-06-10
scp core@node4.okd.sudops.pl:/var/tmp/smart-baseline-${SERIAL}.txt     "HUS726040ALA610-${SERIAL}-baseline.txt"
scp core@node4.okd.sudops.pl:/var/tmp/smart-postbadblocks-${SERIAL}.txt "HUS726040ALA610-${SERIAL}-postbadblocks.txt"
# multi-hour badblocks log — was tee'd to /var/tmp so it survived SSH drop; pull then tidy:
scp core@node4.okd.sudops.pl:/var/tmp/badblocks-${SERIAL}.log "HUS726040ALA610-${SERIAL}-badblocks.log"
ssh core@node4.okd.sudops.pl "rm -f /var/tmp/*-${SERIAL}.txt /var/tmp/badblocks-${SERIAL}.log"
```

`SUMMARY.md` — one row per drive. Record the `wwn-` symlink **alongside** the serial at burn-in time so Phase 1's device path is chosen from the burn-in record, not re-discovered after a physical move. `OSD ID` / `Slot` stay `spare` until install assigns them.

```markdown
| Drive serial | wwn- (as burned-in) | Slot node:bay | OSD ID | Pre POH | Realloc | Pending | Verdict |
|---|---|---|---|---|---|---|---|
| <serial-1> | wwn-0x5000cca... | node4:bay1 | osd.3 | 45,231 | 0  | 0 | in service |
| <serial-2> | wwn-0x5000cca... | node5:bay1 | osd.4 | 51,892 | 12 | 0 | in service (stable long+bb) |
| <serial-3> | wwn-0x5000cca... | node6:bay1 | osd.5 | 38,100 | 0  | 0 | in service |
| <serial-4> | wwn-0x5000cca... | spare      | -      | 40,775 | 4  | 0 | shelf spare |
| <serial-5> | wwn-0x5000cca... | rejected   | -      | 67,400 | 184| 7 | returned to seller |
```

Commit the directory — these captures are the live source of truth alongside `smartctl-exporter`. **Copy off-node before deleting the host temp files or the burn-in pod** (`oc -n default cp hdd-burnin:/host-logs/badblocks-${SERIAL}.log ...` in the pod path), and only then `oc -n default delete pod hdd-burnin`.

### 5. Sequencing

Full-depth serial on a single bay is **~32-38 h/drive**; all 10 serially is **~13-16 days** of bay occupancy on node4. The HDD tier does **not** wait two weeks — only 3 drives go live (1 per node).

1. **Burn 3 drives fully** (the in-service trio) — ~4-5 days.
2. **Run the install** (Phase 1-5 in this draft, unchanged) with those 3 — HDD tier **live in ~4-5 days**, not ~16.
3. **Burn the remaining 7 shelf spares in the background**, single-bay serial on node4, while the tier is already serving. They never block anything.
4. **Parallelize on USB3-dock arrival.** A dock makes the spare campaign N-way: each drive runs its **own internal** long self-test concurrently (near-zero host cost), and `badblocks` becomes USB3-bandwidth-bound rather than serial. Run the dock **off node4** — once the 3 live drives are installed, the spare burn-in never touches node4's HBA, removing the etcd-contention concern entirely. Every dock invocation uses **`smartctl -d sat`** (USB-SATA bridge). The dock is also the **fallback** whenever Step 3d's etcd-fsync watch shows the on-node HBA can't be kept quiet under `ionice`.

**Relocate-verification (the sharp edge):** two of the three live drives are burned in on node4's bay then **physically carried to node5/node6**. The captures and `SUMMARY.md` are keyed by serial; if serials get transposed during the move (3 near-identical 50-EUR HGST pulls), node5's `values.yaml` stanza could name a drive physically in node6 — or a *rejected* drive could be swapped in by mistake. Before committing each node's `wwn-` into `components/storage/rook-ceph-cluster/values.yaml`:

```bash
# on the destination node, confirm the seated serial matches a PASS row for THIS node:bay:
oc debug node/node5.okd.sudops.pl --quiet -- chroot /host \
  lsblk -dno SERIAL,MODEL,WWN | grep -i hus726040
# only then write that verified wwn- into the node5 stanza.
```

Label each PASS drive physically with its serial before it leaves the bench, and record `node:bay -> serial -> wwn` in `SUMMARY.md` **as installed** (post-move, verified present in that chassis), not as planned. Every live OSD must trace back to a specific burned-in, verdict-`in service` serial.

### 2026-06-10 run log (actual — what reality corrected)

Bringing the 3 in-service drives through burn-in. Several runbook assumptions were corrected on first contact.

**Execution vehicle pivot.** The runbook's primary path (`sudo toolbox`) and its debug-pod fallback both use `registry.access.redhat.com/rhel9/support-tools` — which **will not pull on node4** (`ImagePullBackOff`, ~9 min stuck; not in the Zot mirror set, direct pull blocked). Pivoted to `oc exec` into the existing on-node **`smartctl-exporter` DaemonSet pod** (node4 `smartctl-exporter-6zs2k`, node5 `-jn87j`, node6 `-7sc69`) — already has `smartctl` + host device access, zero pull. **Caveat that matters for Step 3d:** that image has `smartctl` but **not `badblocks`**, so the exporter pod covers Steps 3a–3c (baseline + short + long self-test) only. The destructive write test needs a badblocks-capable image — and since support-tools won't pull on node4, the realistic path is the USB3 dock off-node (the §5 fallback) or pre-mirroring a tool image. badblocks NOT yet run (also gated on operator go).

**Every node was power-cycled to seat the drive → `/dev` re-enumerated, per node.** The 3.5" bay is not hot-swap, so node4/node5/node6 were each rebooted. `/dev/sd*` assignment differed: HDD took **`sda` on node4**, **`sdb` on node5 and node6** (boot SSD enumerated first there). Proves the by-id gate is mandatory cluster-wide. Per-node system disks also differ — node4 boot = Intel SSDSC2BX40, node5/node6 boot = Toshiba THNSF8, each with distinct WWNs — hence the multi-node WWN denylist in the gate.

**Each node reboot re-tripped the ArgoCD OVN-egress cascade** (the same one in CLAUDE.md "Pre-flight for any network-stack change" — an HDD bay install is now a known trigger). The node5 reboot took all 42 ArgoCD apps to `sync=Unknown` with repo-server `DeadlineExceeded` on manifest generation. A bare repo-server bounce did **not** fix it (egress, not cold-cache). Fix: restart node5's `ovnkube-node` (resolved via `--field-selector spec.nodeName=` — an awk-column lookup broke on the `RESTARTS (x ago)` field shift) + bounce repo-server → recovered 42 → 11 → 0.

**The 3 in-service drives — all gate-passed, baselines clean:**

| Drive | Node | Serial | WWN | Pre POH | Realloc/Pend/Off/CRC | Long-test ETA |
|---|---|---|---|---|---|---|
| 1 | node4 | K4KTAEDL | 0x5000cca25df55694 | 43,725 (~5.0 yr) | 0/0/0/0 | 21:29Z |
| 2 | node5 | K4KTD40L | 0x5000cca25df55cf3 | 43,707 (~5.0 yr) | 0/0/0/0 | 21:57Z |
| 3 | node6 | K7GEKUBR | 0x5000cca269c62bb6 | 43,348 (~4.95 yr) | 0/0/0/0 | 23:29Z |

All short self-tests "Completed without error"; long self-tests running (drive-internal, zero etcd-HBA load). Delivered model is **HUS726040ALA610** (512n), not the **ALE610** the listing named — caught at SMART baseline; CMR either way, fine for Ceph. Serial caution: drive 1 `K4KTAEDL` vs drive 2 `K4KTD40L` are near-identical — everything keyed by WWN.

**Pending:** long-test completions (21:30–23:30Z) → per-drive post-long SMART diff → badblocks go/no-go (gated). These 3 *are* the in-service trio, so once they pass: install per Phases 1–5; the 7 shelf spares burn in after (parallelized when the USB3 dock lands + a badblocks-capable image is sorted).

### 2026-06-10 — DDF firmware-RAID metadata on used drives hangs cAdvisor (false alerts)

Mid-spare-campaign, ~31 Prometheus alerts fired — including **critical** `etcdMembersDown`, `etcdInsufficientMembers`, `ClusterVersionOperatorDown`, plus 16× `TargetDown`. The cluster was **healthy**: `etcdctl endpoint health --cluster` showed all 3 members up (~24 ms), all nodes Ready, ArgoCD clean. The alerts were **false** — Prometheus couldn't *scrape* node4/node5 host-metrics (kubelet `:10250`, etc.) with `context deadline exceeded`, and the etcd/CVO "down" criticals are *inferred* from those failed scrapes.

**Root cause: DDF (firmware-RAID) metadata on the used HGST pulls.** These datacenter drives carry leftover DDF superblocks. On insertion the host auto-assembles a raid0 from them (`md124`/`md126` …); when a drive is later pulled (hot-swap) its array goes `broken raid0`, and the kernel's per-block-device disk-stats read — which kubelet's cAdvisor + node-exporter consume — **blocks for the full 30 s scrape timeout** on the broken array. Every used drive hot-swapped re-creates this.

**Diagnosis trail (for next time):**
- `etcd*Down`/`CVO down` *critical* but `etcdctl endpoint health --cluster` = all healthy → scrape-inferred, not real. Confirm etcd directly before panicking.
- `/api/v1/targets` → `lastError: context deadline exceeded`, `lastScrapeDuration: 30.000s` (the endpoint *hangs*, isn't unreachable); down instances all on the hot-swapped nodes' host IPs.
- `cat /proc/mdstat` on the node → `md126 : broken raid0 sdX[0]` + DDF containers (`super external:ddf`).

**Fix (per node, guarded to the HUS726040 rotational drive only — never the OS SSD/NVMe):**
```bash
for md in /dev/md[0-9] /dev/md[0-9][0-9] /dev/md[0-9][0-9][0-9]; do [ -b "$md" ] && mdadm --stop "$md"; done   # host-side, no write
wipefs -a /dev/<HUS726040-rotational-disk>                                                                    # erase DDF + part sigs
```
`mdadm --stop` first (releases the device), then `wipefs` (erased `ddf_raid_member` near end-of-disk + `gpt`/`PMBR`; tiny write, safe during a running self-test). **Caveat:** a node whose cAdvisor has been wedged for *hours* may need `systemctl restart kubelet` to clear the stuck collector even after the md is gone — node6 (briefly affected) self-recovered; node4/node5 needed the kubelet kick.

**Procedure change — wipe DDF FIRST on every spare.** Per-spare flow is now: seat drive → **`mdadm --stop` + `wipefs -a` the DDF (FIRST)** → gate → baseline → short → long. Stops the cAdvisor hang before it starts.

**Shelf-spare storage policy (decided 2026-06-10): store burned-in spares RAW** — no partition, no RAID/DDF metadata (the wipe above already leaves them that way). Why: (a) a raw drive won't auto-assemble a stale md array on re-insertion → this whole class of false alerts can't recur; (b) Rook/Ceph BlueStore wants raw block devices → clean OSD provisioning, no zap step; (c) no stale filesystem to confuse anything. The drive's validated-ness lives in the SMART serial + a physical label (serial + "burn-in PASS <date>") + the `SUMMARY.md` record keyed by serial — not in any on-disk metadata.

### 2026-06-11 — same etcd-critical symptom, second cause: node6 ovnkube-node broken egress (two-cause storm)

Attempted the deferred `systemctl restart kubelet` (node4+node5) to clear the DDF-residue cAdvisor hang — but ~31 alerts **persisted**, including critical `etcdMembersDown`/`etcdInsufficientMembers`/`ClusterVersionOperatorDown` + 16× `TargetDown`. It turned out to be **two stacked causes** sharing one symptom, only one of which a kubelet restart addresses:

- **(a) DDF residue** (yesterday's cause) — broken md arrays hanging cAdvisor; already cleared with `mdadm --stop` + `wipefs`.
- **(b) node6's `ovnkube-node` had broken pod→*remote*-host-IP egress** lingering since its morning HDD-install reboot. The morning OVN-cascade fix only restarted **node5's** ovnkube-node (where repo-server lived); node6's stayed broken. A node like that still reaches its OWN host IP, so it looks healthy — it was **silent until `prometheus-k8s-0` rescheduled onto node6** and couldn't scrape node4/node5 host-metrics (`:10250`/`:9100`/`:9979`/… all hung the full 30 s scrape timeout) → ~20 false `TargetDown` + the etcd/CVO criticals (inferred from the failed scrapes).

Two kubelet restarts + a full Prometheus restart were **red herrings** — all aimed at cause (a)'s residue, none touching node6's egress. The same broken egress also explains the `KubeJobFailed` on `kube-descheduler` (its pod on node6 couldn't `dial 172.30.0.1:443` — pod→service-IP, same path).

**Diagnosis that nailed it — per-source-node reachability test.** Host services were fast locally (node-exporter 0.15 s) and reachable from a pod *on node5* (kubelet `:10250` → 401 in 40 ms), but Prometheus hung. The discriminator was running the test *from the suspect node's pod*:

```bash
# from prometheus-k8s-0 (on node6):
oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
  sh -c 'for ip in 192.168.1.7 192.168.1.8 192.168.1.9; do time wget -qO- -T8 http://$ip:9100/metrics >/dev/null 2>&1; done'
# -> .9 (own host) = 0.011s ; .7/.8 (remote hosts) = 5min hang  ==>  node6 ovnkube-node egress broken
```

**Fix:** restart node6's `ovnkube-node` (`--field-selector spec.nodeName=node6.okd.sudops.pl`). k8s-0 → .7/.8 dropped from a 5-minute hang to **11 ms**; **0 down targets**; alerts **31 → 11** (baseline: Watchdog/AlertmanagerReceiversNotConfigured/KubeCPUOvercommit/PDB/UpdateAvailable/transient KubeJobFailed). etcd was 3/3 healthy throughout — `etcdctl endpoint health --cluster` is the disconfirmation for the critical etcd alerts, always check it first.

**Lesson (committed to CLAUDE.md):** after any node event, restart **ALL 3** `ovnkube-node`, not a targeted subset — an un-restarted node stays silently broken until a pod lands on it. Two distinct root causes (DDF-cAdvisor and ovnkube-node-egress) throw the *identical* false-etcd-critical symptom; rule out both, and confirm etcd is real first.

**Follow-up (next-morning monitor tick, ~07:20Z) — a third symptom of the same egress break: `CephMgrModuleCrash`.** The firing-alert count was up to 16 (from the 12 baseline). Three were known noise (`PrometheusRuleFailures` ×2 = the Rook-shipped `…;pools` rule group; `PrometheusOperatorRejectedResources` = the NMState `controller-manager-metrics-monitor` ServiceMonitor's bearer-token-file quirk — *our* `smartctl-device-health` rule is loaded and accepted; `KubeJobFailed` ×4 = marketplace catalog-extract + OLM `collect-profiles`, collateral of the 3 Degraded OLM operators). The one worth chasing was **`CephMgrModuleCrash`**: `ceph crash ls` showed the **`rook` mgr module** crashed 5× on `mgr.b` (node4) between **14:27–20:43Z on 06-10** — and the backtrace is the same egress fingerprint:

```
urllib3.exceptions.MaxRetryError: HTTPSConnectionPool(host='172.30.0.1', port=443):
  Max retries exceeded with url: /api/v1/namespaces/rook-ceph/pods
  (Caused by NewConnectionError(...))
```

`172.30.0.1` is the kube-API ClusterIP — so the Rook orchestrator mgr module crashed because it couldn't reach the API during the egress-broken window (same pod→service path as the descheduler's `dial 172.30.0.1:443 i/o timeout`). So the 2026-06-10 OVN-egress break had **three** distinct symptoms: false `TargetDown`/etcd-criticals (Prometheus scrape), `KubeJobFailed` (descheduler), and `CephMgrModuleCrash` (rook mgr module). **No crashes since 20:43Z**; `mgr.b` active 18h with standby `mgr.a`; module healthy now. The crashes are stale-and-unacknowledged — `RECENT_MGR_MODULE_CRASH` self-clears after `mgr/crash/warn_recent_interval` (~2 weeks) or immediately with `ceph crash archive-all` (a Ceph mutation — operator-confirmed, not auto-run). The remaining `HEALTH_WARN` is the long-known `BLUESTORE_SLOW_OP_ALERT` + this stale-crash warning.

## 2026-06-11 — Batch 3: mixed (1 HDD + 2 Intel DC SATA SSDs) + the SSD-erase gate hazard

Batch 3 is the **last HDD spare (10th)** plus **two used Intel datacenter SATA SSDs**, run
across the three bays in parallel once batch 2 is pulled. It is a **mixed batch — two
different procedures at once**:

| Drive | Model | Class | Destination | Procedure |
|---|---|---|---|---|
| Last HDD (10th) | HUS726040ALA610 4TB | 7K6000 | shelf spare (Ceph HDD tier) | **unchanged HDD flow** — DDF-wipe → `assert_burnin_target` → baseline → short → long self-test → postlong diff |
| Intel **DC S3510 480GB** | `INTEL SSDSC2BB480G6` | read-intensive 0.3 DWPD, MLC, ~275 TBW, PLP, ~2015 | **spare for boot/etcd drives** | SSD flow + **secure-erase** (gated) |
| Intel **D3-S4610 960GB** | `INTEL SSDSC2KG960G8` | mixed-use 3 DWPD, 3D TLC, ~5.5 PBW, PLP, ~2018 | **backup target** — USB box on Synology, Hyper Backup ("kinda offsite") | SSD flow + **wipe** (gated), then Synology formats it |

The S4610-as-Ceph-WAL/DB idea is **dropped** — its role is now the Synology backup box, not the
cluster. The S3510 becomes a cold spare for the boot/etcd SSDs.

### The hazard: for SATA SSDs the `ROTA=1` discriminator that protects the boot disk is GONE

The HDD gate (`assert_burnin_target`) leans on **`ROTA=1`** as a primary, name-independent guard:
the boot/etcd disk is a SATA SSD (`ROTA=0`), so it can *never* match an HDD gate. That safety
property **vanishes the moment the burn-in target is itself a SATA SSD** — the target and the
boot/etcd disk are now the same device class (`ROTA=0`, SATA, similar models). And batch 3
**writes** to the SSDs (secure-erase, per the boot-spare/backup purposes), so a wrong by-id on an
erase = **boot/etcd disk wiped on a zero-drain-headroom cluster**, in one keystroke. The drive
being erased is also *destined to become a boot disk*, which makes the confusion class very real.

**Therefore the SSD gate must be ALLOWLIST-driven, not denylist+attribute.** For HDDs, "it's the
rotational ~4 TB non-system disk" is a sufficient positive identity. For SSDs there is no such
negative-space identity — the only safe affirmative guard is **the exact WWN of the specific SSD
being tested**. `assert_ssd_burnin_target` below fails closed on an empty allowlist and refuses
any device whose WWN is not explicitly listed. The boot-SSD + NVMe-OSD denylist is kept as a
defense-in-depth backstop (it already covers all three nodes' system disks).

### Flow per SSD (validate first, THEN erase)

Capture prior wear/errors *before* destroying anything, then erase to deliver clean:

1. **Capture identity (read-only)** — `smartctl -i` → paste the SSD's bare-hex WWN into `ALLOW_WWNS`.
2. **`assert_ssd_burnin_target /dev/disk/by-id/wwn-…`** — positive WWN allowlist + model (`SSDSC2(BB|KG)`) + size window + `ROTA=0` + by-id-only + not-in-denylist + typed-serial confirm.
3. **SMART `-x` wear baseline** (read-only) → `Media_Wearout_Indicator`/`Percentage_Used`, `Total_LBAs_Written` → host TBW vs rated endurance (the make-or-break for the decade-old S3510), `Reallocated_Sector_Ct`, `Available_Reserved_Space`, `Unsafe_Shutdown_Count`, `End-to-End_Error`, overall health. Capture to `…-SERIAL-ssd-baseline.txt`.
4. **Short self-test** (2 min, drive-internal).
5. **Full-drive read pass** `dd if=/dev/disk/by-id/wwn-… of=/dev/null bs=1M status=progress` (~16 min 480GB / ~32 min 960GB) — non-destructive, surfaces any pending/uncorrectable LBA across the whole device.
6. **Clear stale RAID/DDF metadata** (used DC pulls carry it — same lesson as the HDDs): `mdadm --stop` any assembled array on the device, then `wipefs -a` — gated.
7. **Wipe — `blkdiscard`, NOT `hdparm` on SCOS.** *Confirmed 2026-06-11: `hdparm` is NOT installed on SCOS* (`rc=127` in `oc debug node` chroot — minimal immutable OS; `wipefs`/`lsblk`/`blkdiscard` are present as util-linux, `hdparm` is not). So ATA secure-erase (`hdparm --security-erase`) is unavailable on-node — don't plan around it. Use `blkdiscard -f /dev/disk/by-id/wwn-…` (whole-device TRIM, ~20-50 s) + `wipefs -a` instead, guarded identically (rota=0 + model + exact WWN + not-mounted). Caveat: if `lsblk -dno DISC-ZERO <dev>` is `0` (these Intel DC drives), TRIM gives no deterministic-read-zero guarantee → it's a **clean-slate-for-reuse** wipe (data unmapped + signatures cleared + NAND background-reclaimed), not forensic/cryptographic erase. Correct for boot-spare/backup reuse; for true secure-erase, pull the drive to a workstation that has `hdparm` (frozen-state caveat there: needs direct SATA + not `SEC_FROZEN`, hot-replug to clear). The frozen-check/`hdparm` path in the gate template above is retained only for the off-node/workstation case.
8. **Post-erase SMART confirm** → health PASS, no new defects, partition table gone. Capture `…-SERIAL-ssd-posterase.txt`.

### Connection caveat (bay vs USB dock)

- **Direct SATA (3.5" bay + 2.5"→3.5" caddy):** hot-plug works, secure-erase works, the gate's `ROTA`/size/serial probes are accurate. **Required for `hdparm` secure-erase.** This is the path for batch 3.
- **USB3 dock:** fine for read-only triage but needs `smartctl -d sat`; `hdparm` secure-erase usually **won't pass through** (drive reports frozen / SAT can't issue SECURITY ERASE). `blkdiscard` *may* work depending on the bridge. Since both SSDs need a real wipe, prefer the bay.

### `assert_ssd_burnin_target` — allowlist-driven SSD gate (template; FILL `ALLOW_WWNS` at seat time)

```bash
# Parallel to assert_burnin_target, but the affirmative guard is a POSITIVE WWN ALLOWLIST
# (ROTA can no longer separate target from boot). Fails closed on empty allowlist.
assert_ssd_burnin_target() {
  local RED=$'\e[1;31m' GRN=$'\e[1;32m' NC=$'\e[0m'
  _fail() { printf '%s[SSD-GATE DENIED]%s %s\n' "$RED" "$NC" "$*" >&2; return 1; }
  _ok()   { printf '%s[ok]%s %s\n' "$GRN" "$NC" "$*"; }

  # *** FILL at seat time: bare-hex (no 0x) LU WWN of the EXACT SSD being tested. ***
  # *** EMPTY = deny-all. Add ONLY the drive currently in the bay, remove when pulled. ***
  local ALLOW_WWNS=""          # e.g. "55cd2e41________  55cd2e41________"  (S3510 / S4610)
  # System disks across ALL nodes — boot SSDs + NVMe OSDs (same as the HDD gate). Backstop only.
  local DENY_WWNS="55cd2e404c20c200 002538ba11b25345 500080d910e743a6 36483330529183340025384600000001 500080d910e71bba 36483330547252560025385800000001"
  local MODEL_RE='SSDSC2(BB|KG)'              # S3510=SSDSC2BB, S4610=SSDSC2KG (Intel DC SATA)
  local MIN_BYTES=440000000000 MAX_BYTES=1000000000000   # 480GB..960GB; well below the 4TB HDD
  local ARG="$1"
  _norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' :' | sed -E 's/^0x//; s/^eui\.//'; }

  [ -n "$ALLOW_WWNS" ] || { _fail "ALLOW_WWNS is EMPTY — fail-closed. Paste the seated SSD's WWN first."; return 1; }
  [ -n "$ARG" ] || { _fail "no device path. Usage: assert_ssd_burnin_target /dev/disk/by-id/wwn-..."; return 1; }
  case "$ARG" in /dev/disk/by-id/wwn-*|/dev/disk/by-id/ata-*) : ;;
    *) _fail "'$ARG' not a by-id wwn/ata path. Bare /dev/sdX REFUSED."; return 1 ;; esac
  [ -L "$ARG" ] || { _fail "'$ARG' not a symlink."; return 1; }
  local REAL SDX; REAL=$(readlink -f "$ARG") || { _fail "cannot readlink."; return 1; }
  [ -b "$REAL" ] || { _fail "'$REAL' not a block device."; return 1; }
  SDX=$(basename "$REAL")
  [ -e "/sys/class/block/$SDX/partition" ] && { _fail "'$SDX' is a partition."; return 1; }
  case "$SDX" in nvme*) _fail "'$SDX' is NVMe (OSD). ABSOLUTE NO."; return 1 ;;
    rbd*|nbd*|dm-*|loop*|sr*) _fail "'$SDX' is virtual/live. REFUSING."; return 1 ;; esac

  # SSD requires ROTA=0 — but this is NECESSARY, NOT SUFFICIENT (boot disk is also 0).
  [ "$(cat /sys/block/$SDX/queue/rotational 2>/dev/null)" = "0" ] || { _fail "$SDX ROTA!=0 — not an SSD."; return 1; }

  local SMART MODEL SERIAL WWN
  SMART=$(smartctl -i "$REAL" 2>/dev/null) || { _fail "smartctl -i failed. REFUSING."; return 1; }
  MODEL=$(printf '%s\n' "$SMART"  | sed -n -E 's/^(Device Model|Model Number):[[:space:]]+//p' | head -1)
  SERIAL=$(printf '%s\n' "$SMART" | sed -n -E 's/^Serial Number:[[:space:]]+//p' | head -1)
  WWN=$(printf '%s\n' "$SMART"    | sed -n -E 's/^LU WWN Device Id:[[:space:]]+//p' | head -1)
  [ -n "$MODEL" ] && [ -n "$SERIAL" ] || { _fail "no Model/Serial. REFUSING."; return 1; }
  printf '%s' "$MODEL" | grep -qiE "$MODEL_RE" || { _fail "model '$MODEL' != $MODEL_RE."; return 1; }
  _ok "model: $MODEL"

  # DENY backstop (boot/OSD), THEN positive ALLOW (the real guard):
  local WWN_BYID; WWN_BYID=$(printf '%s' "$ARG" | sed -n -E 's#.*/wwn-(0x[0-9a-fA-F]+).*#\1#p')
  local n hit=""
  for w in "$WWN" "$WWN_BYID"; do n=$(_norm "$w"); [ -n "$n" ] || continue
    for d in $DENY_WWNS; do case "$n" in *"$d"*) _fail "WWN '$w' in system-disk DENYLIST ($d). ABSOLUTE NO."; return 1 ;; esac; done
    for a in $ALLOW_WWNS; do case "$n" in *"$(_norm "$a")"*) hit="$w" ;; esac; done
  done
  [ -n "$hit" ] || { _fail "WWN not in ALLOWLIST — refusing (this is the SSD safety guard)."; return 1; }
  _ok "WWN in allowlist: $hit"

  local BYTES; BYTES=$(blockdev --getsize64 "$REAL" 2>/dev/null)
  [ "$BYTES" -ge "$MIN_BYTES" ] && [ "$BYTES" -le "$MAX_BYTES" ] || { _fail "size $BYTES outside 480-960GB window."; return 1; }
  _ok "size: $BYTES"

  # Typed-serial confirmation (TOCTOU-closing): operator must type the serial shown by the drive.
  printf 'Type the serial to confirm ERASE target [%s]: ' "$SERIAL" >&2; local TYPED; read -r TYPED
  [ "$TYPED" = "$SERIAL" ] || { _fail "typed serial != $SERIAL."; return 1; }
  GATE_REAL="$REAL"; GATE_SERIAL="$SERIAL"; GATE_WWN="$WWN"; GATE_MODEL="$MODEL"
  _ok "GATE PASS — $MODEL / $SERIAL / $REAL"; return 0
}
```

**Procedure rule going forward:** any future SATA-SSD wipe/erase on these nodes (boot-spare prep,
backup-drive prep, OSD-journal SSDs) uses `assert_ssd_burnin_target` with the target's WWN
allowlisted — never the HDD gate, never a bare `/dev/sdX`. The HDD gate's `ROTA=1` does not
protect an SSD operation.

## 2026-06-15 — first consumer of the CephFS bulk RWX tier: media stack `/data`

The media stack (`components/apps/media/`, servarr + jellyfin + transmission) shared its
`/data` RWX volume over **Synology NFS** (`media-data-pvc`, `nfs-csi`, `192.168.1.2:/volume1/kubenfs`).
Moved it onto the in-cluster **CephFS EC-2+1 HDD tier** (`cephfs-hdd`) — the first real
consumer of the bulk RWX tier built in Phases 1–5.

### Capacity scare → false alarm (read the right number)

`df -h /data` inside a media pod reported **7.0 TiB used / 11 TiB**, which looked fatal: the
`cephfs-bulk-hdd` EC pool has only **6.9 TiB usable** (and shares the 3 HDD OSDs with the
replicated RGW object pool — Loki chunks + future OADP/CNPG backups). 7 TiB of EC media =
~10.5 TiB raw ≈ the entire HDD class → would blow `full_ratio` on a no-drain cluster.

But NFS `df` reports the **whole Synology volume**, not the PVC's subdir. `du -h --max-depth=1 /data`
(after fixing the `du -s --max-depth=1` conflict that silently errored to `/dev/null`) showed the
truth: **~90 GiB total, all in `/data/downloads`; `/data/media` empty.** The 7 TiB bulk library
lives elsewhere on the NAS, not in this PVC. So the shared working volume fits CephFS trivially.
Decision (operator): move this PVC to CephFS with a **2 Ti quota** (a real quota now — NFS ignored
the old `500Gi` nominal), keep the bulk library on NAS, migrate a hot subset later.

### The immutable-StorageClass cutover (and the ArgoCD race that bit)

A PVC's `storageClassName` is **immutable** — you can't flip `nfs-csi → cephfs-hdd` in place.
Two options: rename the PVC (clean, single-commit, ArgoCD create+prune) or keep the name + a
one-time manual delete. Operator chose **keep the name** (`media-data-pvc`). Deliberately **no
`Replace=true`** on the PVC — on a `reclaimPolicy=Delete` data volume that sync-option is a
footgun (any future diff → delete+recreate → data wiped).

Chart change: `storage.dataClass: nfs-csi → cephfs-hdd`, `dataSize: 500Gi → 2Ti`, PUID=0
comments rewritten (now "root-on-CephFS subvolume root 0755", previously the Synology NFSv4
root-squash workaround). Pushed (`5682c59`).

Cutover (break-glass, OAuth token expired):
```bash
# NFS PV reclaim=Retain confirmed first (safety gate) — data survives PVC delete
oc -n media delete pvc media-data-pvc --wait=false
oc -n media patch pvc media-data-pvc -p '{"metadata":{"finalizers":[]}}' --type=merge   # force-clear, pods held it
# -> old NFS PV pvc-565f80ed Released (Retain) — 90 GiB preserved on NAS
```
**The race:** I deleted the PVC while ArgoCD was still rendering the *old* (nfs) revision, so its
selfHeal recreated `media-data-pvc` as **nfs-csi 500Gi** before auto-syncing `5682c59`. ArgoCD
then got stuck: live `nfs-csi` vs desired `cephfs-hdd`, `spec is immutable` on every retry, and
it exhausted its 5 retries (`phase=Failed`). Lesson: deleting a managed resource mid-refresh
lets selfHeal restore the *previous* desired state.

**Fix** — once ArgoCD was confirmed on `5682c59` (desired = cephfs), delete the nfs PVC again
(force-clear finalizer) and trigger an explicit sync (refresh alone wasn't enough — retries were
exhausted; needed an `operation`):
```bash
oc -n openshift-gitops patch application media --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{}},"revision":"5682c59..."}}}'
# -> media-data-pvc recreated as cephfs-hdd 2Ti, Bound within ~15s
for a in bazarr sonarr radarr jellyfin transmission-master transmission-slave; do
  oc -n media delete pod -l app=$a --wait=false   # bounce to remount cephfs
done
```

### Verification

```
mount | grep /data
  ...cephfs=/volumes/csi/csi-vol-271e7ed8.../... on /data type ceph (rw,...,mon_addr=192.168.1.9:6789/...)
df -hT /data → ceph 2.0T 0 2.0T 0% /data
# write as root (PUID=0): touch + mkdir /data/{media,downloads} → WRITE-OK, owned root:root
```
media ArgoCD app **Synced + Healthy**; all 6 data-consumer pods Running+Ready on CephFS. The mon
endpoints advertise frontnet IPs (`192.168.1.x`) — the known Rook `addressRanges`-mon quirk
(OSD data still rides the backnet); cosmetic for CephFS clients.

### Side effect: RWX removed volume pinning → all media pods packed onto one node

After the cutover I bounced all 6 data-consumers at once — and they **all landed
on node6**. Two causes compounded: (1) RWX CephFS `/data` means any node can mount
it, so there's no RWO-RBD volume-locality pinning to anchor a pod to a node; (2)
the media deployments had **no `topologySpreadConstraints`/anti-affinity**, so the
scheduler packed all 6 onto the emptiest node — node6, which had just rebooted at
07:52 (63 running pods vs node4 97, node5 132). The cluster descheduler skips
PVC pods, so it would never rebalance them. A node6 failure would have taken the
whole media stack down at once.

Fix (`7f256b0`): a shared `stack: media` pod label + soft
`topologySpreadConstraints` (`maxSkew: 1`, `topologyKey: kubernetes.io/hostname`,
`whenUnsatisfiable: ScheduleAnyway`) on all 7 media deployments. The
template change rolled them (Recreate) and they rescheduled **2-2-3** across
node4/node5/node6. Soft (not `DoNotSchedule`) so pods still schedule on this
no-drain 3-node cluster if a node is cordoned. **General lesson: moving any
multi-pod app from RWO/NFS to RWX CephFS removes the implicit volume-locality
spread — add an explicit spread constraint at the same time.**

### Reclaim-policy: `Delete` → `Retain` (don't lose bulk data to a stray PVC delete)

The old NFS backing was `reclaimPolicy: Retain` — deleting the PVC left the data
as a Released PV (that's how the 90 GiB survived this very cutover). But the
`cephfs-hdd` SC defaulted to **`Delete`**, so post-cutover a `media-data-pvc`
deletion would **destroy the CephFS subvolume + all data immediately** — no
safety net. That's a regression in data-safety from the migration, easy to miss.

Hardened it (`<next commit>`):
- **SC `cephfs-hdd` → `reclaimPolicy: Retain`** (template; `reclaimPolicy` is an
  immutable SC field, so the SC's existing `Replace=true` sync-option recreates
  it). Only `ceph-nvme-block` (RWO block, transient app configs) stays `Delete`.
- **Patched the live media PV → Retain** (`oc patch pv … persistentVolumeReclaimPolicy=Retain`)
  — the SC change only affects *newly* provisioned PVs, so the already-bound one
  needed a direct patch.
- **`Prune=false` on the PVC** — defense in depth so ArgoCD can't prune the PVC
  object out from under the running apps on a stray manifest change.

Cost of Retain: an intentional PVC delete now leaves a Released PV + orphan
CephFS subvolume to purge by hand. Acceptable for a bulk-data tier where the
data is the whole point.

### Loose ends

- **Two Released `nfs-csi` PVs** (both Retain): `pvc-565f80ed` = the original **~90 GiB, keep**
  for the operator's later hot-subset migration; `pvc-9c423498` = the transient empty one from
  the race, **safe to delete**.
- Hot-subset migration NAS→CephFS is the operator's deferred task; raise the 2 Ti quota only
  after checking `ceph df` HDD headroom (CephFS EC ×1.5 raw + RGW replicated ×3 raw must stay
  under ~10.9 TiB with nearfull headroom).

### HDD pool PG bump 32→64 (while near-empty)

`ceph osd df tree` showed ~68 PGs/OSD on the 3 HDD OSDs — below Ceph's ~100/OSD guideline. With
only 3 OSDs the benefit is marginal (EC 2+1 already places one shard per host), but doing it
**while the pool was ~26 GiB** made the split nearly free vs a degraded-window rebalance after
TiB of media. Toolbox `ceph osd pool set cephfs-bulk-hdd pg_num 64; pgp_num 64` first (past the
`pg_num_min` EINVAL guard), then chart `pg_num_min`/`pgNumFloor` 32→64. Split completed to
`active+clean` in ~2 min, no degraded window. Kept RGW data pool at 32. → ~96 PGs/OSD on HDD.

### Jellyfin QSV HW transcoding — and the 10.11 migration crash saga

**The plan:** the 3 nodes are i7-11700 / Intel UHD 750. `vainfo` (iHD 25.4.6) in-pod confirmed
QSV decode for H264/HEVC/HEVC10/VP9(0-3)/VC1/AV1(Profile0) + `EncSliceLP` (Low-Power encode ⇒
HuC loaded). Wired it GitOps-side: `hwAccel: true` on jellyfin only → hostPath `/dev/dri`
(privileged + root + renderD128 0666, no device-plugin) + a 20Gi `/transcode` emptyDir
(node-local scratch, off the EC HDD pool + the 30Gi config PVC). All nodes have the iGPU so no
nodeSelector; works with the `stack: media` topologySpread.

**The crash:** the moment the chart rolled jellyfin, it crash-looped — `JellyfinMigrationService:
Old migration style migration.xml detected. Migrate now.` → `[FTL] Failed to apply migrations:
Sequence contains no elements at ... CheckFirstTimeRunOrMigration`. The s6 init showed the GPU
mounts were fine (`permissions for /dev/dri/renderD128 are good`) — the crash is purely in
jellyfin's `/config` migration, before any transcoding. Git blame: the image was bumped to
10.11.8 in #108 (`1666132`), *before* this session — so **not caused by the HW-accel change**;
the restart just surfaced it.

**Root cause (4-agent web research, high confidence):** an **unguarded `.Last()`** in the
legacy-`migrations.xml`→EF-Core bridge — it filters the ~23 applied GUIDs down to ones still
mapping to a not-yet-applied code migration, then `.Last()` on the (empty) result throws.
**Unfixed through 10.11.11/master** (jellyfin/jellyfin#15388 under #15686) — so a forward image
bump is NOT a fix.

**Rollback to 10.10.7 turned out BLOCKED:** 10.11.8 had already forward-migrated `jellyfin.db`'s
EF schema (the users/config DB) before the *other* migration crashed, and **no pre-10.11 backup
existed** (`SQLiteBackups/` empty; off-host copy declined). So 10.10.7 errored `no such column:
u.MaxParentalAgeRating` — the data is only in 10.11 format now. The situation flipped: **forward
became the data-preserving path.**

**Forward-fix (the recovery that worked):**
1. In-PVC backup → `/config/_jf-db-backup-2026-06-15` (jellyfin.db, library.db.old, migrations.xml).
2. Image back to 10.11.8 (revert the brief 10.10.7 pin); removed the Renovate `<10.11` pin
   (10.11.x is safe once the legacy migrations.xml is gone).
3. **`mv /config/migrations.xml /config/migrations.xml.broken`** (one-time, in-PVC) so 10.11.x
   skips the crashing legacy-conversion branch.
4. Restart → `Startup complete 0:00:29` (tiny library = fast EF migration), `ready=true`, 0
   migration crashes, migrations.xml NOT recreated. Users/config preserved.

Also moved jellyfin's `CachePath` `/data/jellyfin-cache` → `/config/cache` (NVMe) — the cutover
had emptied the CephFS `/data` cache dir; cache belongs on NVMe anyway (system.xml backed up to
`system.xml.bak-2026-06-15`). Lesson: a Renovate image bump (#108) silently armed a crash-on-next-
restart that only detonated when an unrelated change (the QSV chart roll) restarted the pod —
and a "safe rollback" can be blocked by a one-way forward DB migration with no backup. Take the
cold DB backup BEFORE the first restart on any major Jellyfin bump.
