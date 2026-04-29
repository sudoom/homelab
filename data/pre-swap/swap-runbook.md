# Single-OSD swap runbook: PNY CS1030 → Samsung PM9A1 on node4

**Goal:** validate `kv_commit_lat` is drive-bound by replacing a single PNY with a known-different drive (Samsung PM9A1 512 GB) and watching whether the affected OSD's commit latency diverges from the other two.

**Target:** node4 / osd.0. node4 has the most powered-on hours in the baseline (`nvme-smart-node4.txt`: 41h, 61 unsafe shutdowns) and is already documented.

**Drive layout note:** the cluster uses positional `/dev/nvme0n1` (per `components/storage/ceph-cluster/values.yaml` decision documented in CLAUDE.md). The replacement drive will appear at the same path on first boot, so no values change required.

---

## 0. Pre-swap snapshot (record everything that's going to change)

```bash
# Per-OSD lifetime counters BEFORE the swap — preserve under data/pre-swap/
for i in 0 1 2; do
  oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph daemon osd.$i perf dump > data/pre-swap/osd-$i-perf-dump-pre-swap.json
done

oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd df         > data/pre-swap/osd-df-pre-swap.txt
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree       > data/pre-swap/osd-tree-pre-swap.txt
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s              > data/pre-swap/ceph-status-pre-swap.txt
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail   > data/pre-swap/health-detail-pre-swap.txt
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg dump pgs_brief | head -50 > data/pre-swap/pgs-pre-swap.txt
```

Verify health is `HEALTH_OK` and no scrubs in progress. **Do not start the swap if cluster is degraded** — you'd be running effectively `size=2` plus `size=2` on the same data.

---

## 1. Drain osd.0 (cluster stays online, just remaps PGs off osd.0)

```bash
# Tell Ceph to stop placing data on osd.0
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out 0

# Watch backfill — this is where the cluster spends 1–2 h depending on data volume
watch -n 5 'oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s'
```

Expect ~315 GiB to drain off osd.0. Frontnet is the choke point during backfill (200–250 Mbps observed). At that rate: **~3 h walltime**.

**Wait until** `ceph -s` shows `HEALTH_OK` and `pgs: ... active+clean` only (no `backfilling`, no `recovering`).

---

## 2. Stop and purge osd.0

The OSD is still **UP** at this point — `out` only changes data placement weight. Now take it down.

```bash
# Pause Rook so it doesn't try to recreate the OSD mid-procedure
oc -n rook-ceph patch cephcluster rook-ceph --type merge -p '{"spec":{"disruptionManagement":{"managePodBudgets":false}}}'
oc scale deploy/rook-ceph-operator -n rook-ceph --replicas=0

# Stop the OSD daemon
oc scale deploy/rook-ceph-osd-0 -n rook-ceph --replicas=0

# Remove from CRUSH and OSD map
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd down 0
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 0 --yes-i-really-mean-it

# Delete the deployment so Rook doesn't try to resurrect it
oc delete deploy/rook-ceph-osd-0 -n rook-ceph
```

Verify:
```bash
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
# Should show only osd.1 and osd.2; osd.0 entry gone.
```

---

## 3. Physical swap

1. **Cordon node4** to prevent rescheduling during reboot:
   ```bash
   oc adm cordon node4.okd.sudops.pl
   ```
2. **Drain non-OSD workloads** (OSD pod is already gone from step 2):
   ```bash
   oc adm drain node4.okd.sudops.pl --ignore-daemonsets --delete-emptydir-data --force
   ```
3. **Power off** node4 cleanly:
   ```bash
   oc debug node/node4.okd.sudops.pl -- chroot /host shutdown -h now
   ```
4. **Physically swap** the PNY CS1030 in the M.2 slot for the PM9A1 (same slot — keeps positional `/dev/nvme0n1` stable).
5. **Power on** node4. Wait for it to rejoin (~3–5 min).
6. `oc adm uncordon node4.okd.sudops.pl`.

---

## 4. Wipe the new drive and recreate the OSD

The PM9A1 has prior data (it was a working drive — partition table will exist). Rook's `osd-prepare` will refuse to provision a non-empty device.

```bash
# Wipe partition table and any LVM/superblock signatures
oc debug node/node4.okd.sudops.pl -- chroot /host /bin/bash -c '
  sgdisk --zap-all /dev/nvme0n1
  blkdiscard /dev/nvme0n1 || dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=100 oflag=direct
  wipefs -a /dev/nvme0n1
  partprobe /dev/nvme0n1
'

# Verify
oc debug node/node4.okd.sudops.pl -- chroot /host lsblk /dev/nvme0n1
# Expect: nvme0n1 with no children
```

Resume Rook:
```bash
oc scale deploy/rook-ceph-operator -n rook-ceph --replicas=1
```

The operator will detect the empty device and trigger `rook-ceph-osd-prepare-node4` → creates a new OSD (likely re-uses ID 0).

```bash
# Watch the prepare job
oc -n rook-ceph logs -l app=rook-ceph-osd-prepare,topology-location-host=node4.okd.sudops.pl -f

# Then the new OSD pod
oc -n rook-ceph get pods -l app=rook-ceph-osd -w
```

---

## 5. Backfill back, then measure

Once the new OSD is up:
```bash
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd in 0
watch -n 5 'oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s'
```

Wait for `HEALTH_OK`. Backfill direction is now *into* osd.0 — same volume (~315 GiB), same duration as drain.

**Let the cluster run normal load for ~24 h.** Without sustained workload, `kv_commit_lat` won't accumulate enough samples for a meaningful comparison. The media stack PVCs writing continuously is sufficient.

---

## 6. Post-swap measurements

```bash
mkdir -p data/post-swap

# Per-OSD lifetime counters AFTER ~24 h of normal load
for i in 0 1 2; do
  oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph daemon osd.$i perf dump > data/post-swap/osd-$i-perf-dump.json
done

# Quick A/B summary
for i in 0 1 2; do
  echo "=== osd.$i ==="
  oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph daemon osd.$i perf dump \
    | jq '.bluestore | {kv_commit_lat, kv_sync_lat, commit_lat}'
done
```

**Decision criterion:**
- `osd.0.kv_commit_lat.avgtime` < 0.010 s (10 ms) AND `osd.{1,2}.kv_commit_lat.avgtime` ≈ 0.130 s → **diagnosis confirmed**, hardware swap is the fix. Buy 2× more PM9A1 (or 7450 PRO) and finish the swap.
- `osd.0.kv_commit_lat.avgtime` ≈ same as osd.1/osd.2 → something else is the bottleneck. Re-investigate (kernel I/O scheduler? Ceph version regression? Filesystem alignment?).

Re-run the dd test in `tests/ceph-storage-test.yaml` and compare client throughput against pre-swap ~25 MB/s baseline.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| PM9A1 fails during test (it's mid-life) | size=3 still has 2 replicas; recreate OSD on a new drive, no data loss |
| Backfill saturates frontnet, impacts media stack | Run backfill during off-hours; throttle with `osd_recovery_max_active` if needed |
| `osd-prepare` fails because device wasn't fully wiped | `wipefs -a && sgdisk --zap-all && blkdiscard` covers all known cases for nvme |
| Operator scales osd-0 back up before purge completes | Operator scaled to 0 in step 2 — verify `oc get pods -n rook-ceph | grep operator` shows 0 replicas before any rook-ceph-osd-N work |
| Wrong drive pulled physically | node4 has only one NVMe slot per `nvme-id-ctrl-node6.txt` baseline; verify `nvme list` on each node before the swap to confirm |

## Rollback

If the swap goes wrong (PM9A1 dies, prepare fails, etc.) — same procedure in reverse with the original PNY. Keep it labeled. Ceph treats the new OSD identically regardless of drive model.
