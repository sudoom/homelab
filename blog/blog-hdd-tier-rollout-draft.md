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
DRIVE=/dev/sdX                          # adjust per drive
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
  HUS726040ALE610-K7G5MZBE-smart-baseline.txt
  HUS726040ALE610-K7G5MZBE-smart-postlong.txt
  HUS726040ALE610-K7G5MZBE-smart-postbadblocks.txt
  HUS726040ALE610-K7G5MZBE-badblocks.log
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
