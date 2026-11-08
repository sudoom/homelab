# Storage throughput — measured figures across all three backends

Consolidated record of every throughput measurement taken on this homelab's storage
paths. Written 2026-09-05 because the numbers had scattered across `CLAUDE.md`, the
`README.md` TODO list and three blog drafts, and were being quoted forward without
their conditions.

## The rule this file exists to enforce

**A measurement is only meaningful with its conditions attached — not just its date.**

Two separate incidents made this a rule rather than a preference:

- `cephfs-hdd` read was quoted as **76.6 MB/s** for over two months. Re-measured on
  2026-08-28 it was **124 MB/s** — the old figure was stale by ~1.6× and had been used
  to size a migration ETA.
- TrueNAS NFS read was labelled three different things in four days: "~270 MB/s peak"
  (an unmeasured guess), then "246 MB/s sustained" (real, but *one client* — described
  as if it were the NAS's ceiling), finally "246 / 431 MB/s for one / two readers"
  (the actual shape: it scales with concurrency).

So every row below carries **what was measured, when, with how many clients/streams,
over which path, by which method**. A number without those is not reusable.

## Summary

| Backend | Path | Read | Write | Date | Conditions |
|---|---|---:|---:|---|---|
| **Synology DS418** | NFS over 1G frontnet | **112.6 MiB/s** | **110.3 MiB/s** | 2026-09-05 | 3 clients/3 nodes, fio `seq-*-1m`, **link-saturated** |
| **Synology DS418** | NFS over 1G frontnet | **109.2 MiB/s** | **105.1 MiB/s** | 2026-09-05 | 1 client, fio `seq-*-1m` |
| ~~Synology DS418~~ | ~~NFS over 1G frontnet~~ | ~~52.2 MB/s~~ | — | ~~2026-08-28~~ | **SUPERSEDED — see corrections log** |
| **CephFS-HDD** (EC 2+1) | kernel CephFS, 10G backnet | **76.6 MB/s** | 22.1 MB/s | 2026-06-12 | 1 client, 1 stream, `direct` |
| **CephFS-HDD** (EC 2+1) | kernel CephFS, 10G backnet | **124 MB/s** | — | 2026-08-28 | 1 client, 1 stream |
| **CephFS-HDD** (EC 2+1) | kernel CephFS, 10G backnet | **170 MiB/s** | — | 2026-08-28 | **3 parallel** streams, aggregate |
| **TrueNAS** (RAIDZ2 6-wide) | NFS over 10G backnet | **530.3 MiB/s** | **102.7 MiB/s** | 2026-09-06 | 2 clients, fio `seq-*-1m`, **pool-bound not link-bound** |
| **TrueNAS** (RAIDZ2 6-wide) | NFS over 10G backnet | **519.3 MiB/s** | **86.8 MiB/s** | 2026-09-06 | 1 client, fio `seq-*-1m` |
| **TrueNAS** (RAIDZ2 6-wide) | NFS over 10G backnet | 246 MB/s | — | 2026-08-29 | 1 reader, migration-derived (superseded by fio) |
| **TrueNAS** (RAIDZ2 6-wide) | NFS over 10G backnet | 431 MB/s | — | 2026-08-30 | 2 readers, migration-derived (superseded by fio) |
| **TrueNAS** (RAIDZ2 6-wide) | SMB over 1G frontnet | — | **~114 MB/s** | 2026-08-31 | 2 Macs, Time Machine, link-saturating |
| **Ceph RBD** `ceph-nvme-block` (×3, 3 NVMe) | kernel RBD, 10G backnet | **400.2 MiB/s** | **62.7 MiB/s** | 2026-11-05 | 1 client (node4), fio `seq-*-1m`, one 24G file, mean of 3 runs; Rook/Ceph upgrade series, compare only within it |
| **Ceph RBD** `ceph-nvme-block` (×3, 3 NVMe) | kernel RBD, 10G backnet | **390.4 MiB/s** | **64.0 MiB/s** | 2026-11-06 | same method, after upgrade stage 1 (Rook v1.20.9); mean of 3 runs |
| **Ceph RBD** `ceph-nvme-block` (×3, 3 NVMe) | kernel RBD, 10G backnet | **334.3 MiB/s** | **61.6 MiB/s** | 2026-11-07 | same method, after upgrade stage 2 (Rook v1.21.1, cephcsi v3.18.1); mean of 3 runs, two outside the slot |
| **Ceph RBD** `ceph-nvme-block` (×3, 3 NVMe) | kernel RBD, 10G backnet | **359.7 MiB/s** | **69.1 MiB/s** | 2026-11-08 | same method, after upgrade stage 3 (msgr2 required); mean of 3 runs, all in the slot |
| *(reference)* cross-node pod | iperf3, 1G frontnet | 879 Mbit/s | — | 2026-05-21 | pre-IPsec baseline |

**TrueNAS NFS is ~4.3× CephFS-HDD read and ~4.7× the Synology on sequential reads —
and roughly the SAME as the Synology on sequential writes** (102.7 vs 110.3 MiB/s). The
read advantage is real and large; the write advantage does not exist. Do not carry "5×
faster" forward as a general statement.

## Per-backend detail

### Synology DS418 — the link is the wall, in both directions

Twelve cells from `tests/storage-benchmark/`, 2026-09-05, 64 GiB corpora, clients
synchronised by a rendezvous barrier, every row cross-checked byte-for-byte against the
MikroTik `home-router/nas` counter.

| workload | 3 clients | 2 clients | 1 client | wire (corrected) |
|---|---:|---:|---:|---|
| `seq-read-1m` | 112.6 | 111.1 | 109.2 MiB/s | 984 / 982 / 961 Mb/s |
| `seq-write-1m` | 110.3 | 110.3 | 105.1 MiB/s | 968 / 962 / 914 Mb/s |
| `rand-read-4k` | 1.4 (360 iops) | 2.0 (519) | 1.8 (471) | 13 / 26 / 29 Mb/s |
| `rand-write-4k` | 30.0 (7690 iops) | 25.0 (6402) | 27.9 (7143) | 298 / 253 / 264 Mb/s |

**Sequential is flat across client count and pinned at the link.** 112.6 MiB/s is 945
Mb/s of payload; a 1 GbE link at MTU 1500 with TCP timestamps on (`br-ex` measured at
1500, `net.ipv4.tcp_timestamps=1`, so 1448 payload bytes per 1538 on the wire) tops out
near 941 Mb/s. A *single* client already fills it.

**This reverses the LACP verdict this file previously carried.** The old entry said the
DS418 ran at 52.2 MB/s = 416 Mbps and therefore "the box is the constraint, not its
network", and concluded that bonding two links you cannot fill buys nothing. That
premise was wrong: the box fills the link with one client and has more to give. Bonding
**would** help multi-client sequential — 3 clients on 3 nodes are 3 NFS mounts, so 3 TCP
flows, which LACP can spread. It would still do nothing for a single mount (one flow,
one link), where `nconnect=N` remains the lever.

**It would also do nothing for random 4k**, which is spindle-bound long before it is
link-bound: `rand-read-4k` peaks at 2 clients (2.0 MB/s, 519 iops) and *falls* at three
(1.4 MB/s, 360 iops) — four SHR drives thrashing on seek while using 13-29 Mb/s of a
1000 Mb/s link. Adding a second link to that changes nothing.

Why the old figure was wrong: it was derived from two `zfs list` samples 90 s apart on
the *destination* during the keepers migration — a real measurement of that migration,
which was rsync-over-one-stream with small files in the mix, not of what the DS418 can
do. Real number, invented conditions, which is the failure mode this whole file exists
to prevent.

### CephFS-HDD — EC 2+1 across three spindles, and not a network cap

`cephfs-bulk-hdd`, erasure-coded 2+1 across the three HDD OSDs (one per node).

- **2026-06-12** (Phase 5 validation): read **76.6 MB/s**, write **22.1 MB/s**, one
  client, one stream, `direct`. Write is low because EC 2+1 amplifies writes ×1.5.
- **2026-08-28** (re-measure before the media migration): read **124 MB/s** single
  stream, **170 MiB/s** aggregate across 3 parallel streams.

**Neither figure is a network limit.** 170 MiB/s is 1.43 Gbps — above 1 Gbps line rate —
which independently proves the read path is on the 10G backnet, not the frontnet. This
is simply what EC 2+1 over three spinning disks delivers. Do not go looking for a 1G
bottleneck to explain it.

The 2026-06-12 → 2026-08-28 gap is the cautionary tale: **the same pool, the same
config, measured 1.6× faster** two months later. Nothing changed about the storage; the
first measurement was taken on a freshly-built tier under different conditions. Re-measure
before sizing anything.

### TrueNAS — pool-bound, and the 4k figures do not describe the hardware

6-wide RAIDZ2 of HGST 4 TB drives, NFS exported on the 10G storage backnet
(`192.168.10.10`, MTU 9000). Twelve cells from `tests/storage-benchmark/`, 2026-09-06,
64 GiB corpora, barrier-synchronised clients.

| workload | 3 clients | 2 clients | 1 client | cross-check |
|---|---:|---:|---:|---|
| `seq-read-1m` | 463.7 | 530.3 | 519.3 MiB/s | ok, wire 1.09-1.11x |
| `seq-write-1m` | 104.0 | 102.7 | 86.8 MiB/s | ok (one row noisy) |
| `rand-read-4k` | 0.8 (205 iops) | 0.8 (209) | 1.5 (375) | **uncorroborated** |
| `rand-write-4k` | 0.2 (61 iops) | 0.2 (60) | 0.2 (60) | **uncorroborated** |

**Sequential reads are pool-bound, not link-bound.** 530 MiB/s is 4.45 Gb/s on a 10 GbE
link, and adding a third client makes it *worse* (463.7). The old "scales with
concurrency, so a single-client number is not the ceiling" framing was drawn from two
migration passes; with a real client sweep the curve is flat-to-falling. One client
already gets essentially all of it.

**Sequential writes are ~5x slower than reads** (86.8-104.0 vs 463.7-530.3) and are
level with the Synology, which is link-capped at ~110 MiB/s. RAIDZ2 parity on spinning
disks, and no SLOG.

**The 4k rows measure the DATASET, not the box — do not quote them as a TrueNAS
capability.** `tank/bench` is `recordsize=1M`, `sync=standard`, and `zpool status tank`
shows a bare `raidz2-0` with **no log vdev**. So:

- a 4 KiB request touches a whole 1 MiB record — **256x amplification** in both
  directions. 375 iops x 1 MiB is ~375 MB/s of real disk work, which is exactly what
  this pool does sequentially. The disks are not slow; they are moving 256 bytes of
  record per byte requested.
- every NFS sync write commits to the ZIL on those same six spinning disks.

The Synology sits on a 4 KiB-block filesystem, so `rand-write-4k` "TrueNAS 0.2 MB/s vs
Synology 30.0 MB/s" is a comparison of **record sizes**, not of hardware. A 16K-recordsize
dataset (and an SLOG) would produce a completely different number. Queued as a README
TODO; until then these four rows carry the caveat inline in the results TSV.

Also note the cross-check is weaker here than on the Synology: the 10G port carries the
live media/immich/keepers NFS mounts too, so on the low-payload `rand-*` rows background
traffic dwarfs the benchmark and the wire cannot isolate it. Those rows are recorded
`UNCORROBORATED` — the fio figure stands, nothing independent confirms it.

### Ceph RBD `ceph-nvme-block` — the Rook/Ceph upgrade baseline (2026-11-05)

`tests/storage-benchmark/run.sh --backend ceph-nvme-block`, 1 client (node4), `BENCH_FILESIZE=24G` with
`BENCH_ALLOW_SMALL=1` (above the OSDs' ~12 GiB aggregate cache), one shared bulk file, 60 s per workload,
`libaio`, Rook v1.19.5 / Ceph Squid 19.2.4, pool `nvme-replicated` size 3. Three runs in the 12:00-14:00Z slot.
A series of its own: compare these rows only with later `ceph-nvme-block` rows carrying the same
`BENCH_LAYOUT_NOTE` shape (`shared-bulk BENCH_ALLOW_SMALL=1 rep=<n>/3 stage=<label>`), never with the NFS rows.

| workload | run 1 | run 2 | run 3 | mean |
|---|---|---|---|---|
| `seq-read-1m` | 406.1 MiB/s, p99 49.0 ms | 393.6, p99 50.1 | 400.9, p99 48.5 | **400.2 MiB/s** |
| `seq-write-1m` | 65.8 MiB/s, p99 248.5 ms | 68.0, p99 244.3 | 54.2, p99 337.6 | **62.7 MiB/s** |
| `rand-read-4k` | 15,478 iops (60.5 MiB/s), p99 6.26 ms | 16,380 (64.0), p99 5.67 | 17,820 (69.6), p99 4.69 | **16,559 iops** |
| `rand-write-4k` | 2,395 iops (9.4 MiB/s), p99 31.1 ms | 1,987 (7.8), p99 48.0 | 2,457 (9.6), p99 28.7 | **2,280 iops** |

- **Writes vary most between runs** (seq-write 54.2-68.0 MiB/s, rand-write p99 28.7-48.0 ms), which is why each
  point is three runs. `BLUESTORE_SLOW_OP_ALERT` went from 2 OSDs to 3 between run 1 and run 2.
- **The harness's wire check does not fit RBD.** Wire against fio, reads: seq-read 2877/3327 (86%), 2800/3224 (87%), 2085/3284 (63%); rand-read 408.8/495 (83%), 510.7/524 (97%, not flagged), 455.4/570 (80%); one write cell was
  flagged too (run 2 `seq-write-1m`, 94%). Likely cause: the client node's own OSD serves the objects whose primary
  it holds, which never cross the switch (about a third would predict ~67%); the 63-97% spread is not explained.
  Not a cache effect (O_DIRECT, 24G above the OSD cache).
- **Sequential writes are ~6x slower than reads**, with p99 near 250 ms: likely because each 1 MiB write is replicated to
  three consumer NVMe drives without power-loss protection (PM9A1, `blog/blog-rook-ceph-draft.md` hardware table). Recorded, not judged: the series exists to see how the
  upgrade moves these numbers.

### Ceph RBD `ceph-nvme-block` — after stage 1, Rook v1.20.9 (2026-11-06)

Same method as the baseline above (label `stage=s1`), one day after stage 1 (Rook v1.19.5 → v1.20.9, CSI from the
`ceph-csi-drivers` subchart, cephcsi v3.17.1; Ceph unchanged at Squid 19.2.4). Three runs in the 12:00-14:00Z slot,
client again on node4. `BLUESTORE_SLOW_OP_ALERT` latched on all 3 OSDs during run 1's `seq-write-1m` (12:10:04Z), as at
the baseline.

| workload | run 1 | run 2 | run 3 | mean | vs baseline |
|---|---|---|---|---|---|
| `seq-read-1m` | 409.9 MiB/s, p99 45.9 ms | 362.1, p99 80.2 | 399.1, p99 46.9 | **390.4 MiB/s** | −2.5% |
| `seq-write-1m` | 62.3 MiB/s, p99 242.2 ms | 64.9, p99 256.9 | 64.7, p99 308.3 | **64.0 MiB/s** | +2.0% |
| `rand-read-4k` | 15,262 iops (59.6 MiB/s), p99 6.78 ms | 14,090 (55.0), p99 8.16 | 16,642 (65.0), p99 5.6 | **15,331 iops** | −7.4% |
| `rand-write-4k` | 2,288 iops (8.9 MiB/s), p99 37.5 ms | 2,352 (9.2), p99 32.4 | 2,319 (9.1), p99 31.9 | **2,320 iops** | +1.7% |

- **Writes did not move** (±2%, and the run-to-run spread was smaller than at the baseline).
- **The read dip is mostly run 2.** Run 2 is below every baseline run (seq-read 362.1 vs 393.6-406.1 MiB/s, rand-read
  14,090 vs 15,478-17,820 iops); runs 1 and 3 sit at or inside the baseline range. Not attributed: the readonly
  account cannot read Prometheus history, and the paperless work on TrueNAS at the same time does not touch Ceph.
- **Wire against fio, reads:** seq-read 2541/3358 (76%), 3002/2966 (101%), 2872/3270 (88%); rand-read 386/488 (79%),
  437/451 (97%), 517/533 (97%). Run 2 has the highest wire share of the three. Other traffic into node4's backnet port
  during run 2 would both raise that figure and compete with fio; not checked.

### Ceph RBD `ceph-nvme-block` — after stage 2, Rook v1.21.1 (2026-11-07)

Same method as the baseline (label `stage=s2`), the day after stage 2 (Rook v1.20.9 → v1.21.1, ceph-csi-operator
v1.1.0, cephcsi v3.18.1; Ceph unchanged at Squid 19.2.4, the OSDs restarted in the stage-2 roll). Client again on
node4. **Only run 1 is in the 12:00-14:00Z slot:** the point started at 13:31Z, and runs 2 (16:01Z) and 3 (18:56Z)
ran outside it because the operator chose to finish the point the same day. `BLUESTORE_SLOW_OP_ALERT` latched on all
3 OSDs during run 1's `seq-write-1m`, as before.

| workload | run 1 (13:31Z) | run 2 (16:01Z) | run 3 (18:56Z) | mean | vs baseline | vs s1 |
|---|---|---|---|---|---|---|
| `seq-read-1m` | 361.1 MiB/s, p99 82.3 ms | 269.5, p99 137.4 | 372.3, p99 67.6 | **334.3 MiB/s** | −16.5% | −14.4% |
| `seq-write-1m` | 63.9 MiB/s, p99 265.3 ms | 63.5, p99 231.7 | 57.5, p99 244.3 | **61.6 MiB/s** | −1.7% | −3.7% |
| `rand-read-4k` | 17,048 iops (66.6 MiB/s), p99 5.34 ms | 15,127 (59.1), p99 6.19 | 17,100 (66.8), p99 5.8 | **16,425 iops** | −0.8% | +7.1% |
| `rand-write-4k` | 2,585 iops (10.1 MiB/s), p99 27.7 ms | 2,299 (9.0), p99 41.2 | 2,123 (8.3), p99 40.1 | **2,336 iops** | +2.4% | +0.7% |

- **Writes and random reads did not move** (within ±3% of the baseline).
- **Sequential read is down in every run, not in one.** All three runs are below every baseline run (393.6-406.1
  MiB/s), and every seq-read p99 is higher (67.6-137.4 ms against 48.5-50.1 ms at the baseline). Run 2 is the deepest;
  without it the mean is 366.7 MiB/s (−8.4%). Not attributed: two runs fall outside the slot, the readonly account
  cannot read Prometheus history, and a 20 s sample of the pool's traffic right after run 2 read idle (0.0 MiB/s
  read), which says nothing about the run itself. The next point, after stage 3, shows whether it persists.
- **Wire against fio, reads:** seq-read 2394/2958 (81%), 2072/2208 (94%), 2728/3050 (89%); rand-read 473/546 (87%),
  487/484 (101%), 545/547 (100%).

### Ceph RBD `ceph-nvme-block` — after stage 3, msgr2 required (2026-11-08)

Same method (label `stage=s3`), about four hours after stage 3 (`requireMsgr2: true` on Rook v1.21.1; Ceph unchanged
at Squid 19.2.4; every kernel mapping was already on msgr2 `prefer-crc` before the change). All three runs in the
12:00-14:00Z slot this time, client again on node4. `BLUESTORE_SLOW_OP_ALERT` latched on all 3 OSDs during run 1's
`seq-write-1m`, as before.

| workload | run 1 (12:00Z) | run 2 (12:22Z) | run 3 (12:36Z) | mean | vs baseline | vs s2 |
|---|---|---|---|---|---|---|
| `seq-read-1m` | 357.6 MiB/s, p99 81.3 ms | 381.0, p99 51.6 | 340.4, p99 83.4 | **359.7 MiB/s** | −10.1% | +7.6% |
| `seq-write-1m` | 60.7 MiB/s, p99 299.9 ms | 78.3, p99 189.8 | 68.2, p99 278.9 | **69.1 MiB/s** | +10.2% | +12.1% |
| `rand-read-4k` | 16,293 iops (63.6 MiB/s), p99 6.06 ms | 15,998 (62.5), p99 6.32 | 16,875 (65.9), p99 5.54 | **16,389 iops** | −1.0% | −0.2% |
| `rand-write-4k` | 2,528 iops (9.9 MiB/s), p99 26.6 ms | 2,494 (9.7), p99 27.4 | 2,266 (8.9), p99 30.3 | **2,429 iops** | +6.5% | +4.0% |

- **Sequential read stays below the baseline, now with every run in the slot.** All three runs are under the
  baseline range (393.6-406.1 MiB/s); two of three have p99 above 80 ms against 48.5-50.1 ms at the baseline. So the
  stage-2 dip was not the time of day. s1 (390.4) was still at the baseline, so it appeared with stage 2 (Rook
  v1.21.1, ceph-csi-operator 1.1.0, cephcsi v3.18.1). Stage 3 cannot be the cause on the client side: the kernel
  mappings were on msgr2 before it. Not attributed; record-only.
- **Writes and random reads did not move down;** sequential write is the best mean in the series (+10.2%).
- **Wire against fio, reads:** seq-read 2992/2930 (102%), 3149/3121 (101%), 2522/2789 (90%); rand-read 449/521 (86%),
  507/512 (99%), 476/540 (88%).

### TrueNAS SMB (Time Machine) — the 1G frontnet is the constraint here

2026-08-31, both Macs running their first Time Machine backup concurrently: `eno1`
peaked at **912 Mb/s received**, i.e. the 1 Gbit frontnet essentially saturated
(~114 MB/s aggregate).

**This is a different path from everything above.** The Macs are on the frontnet; only
the cluster reaches the NAS over the 10G backnet. So Time Machine is bounded by the 1G
link, and the NAS's 246/431 MB/s NFS figures do not apply to it.

## Corrections log

Wrong numbers that were live in the docs, and why — kept so the same mistakes are
recognisable next time:

| Claimed | Actual | What went wrong |
|---|---|---|
| "~200 MB/s" CephFS read | 76.6 MB/s (then 124) | Unmeasured guess, 2.6× too high, quoted forward for months |
| 76.6 MB/s CephFS read | 124 MB/s | Real measurement, but two months stale and never re-taken |
| "~270 MB/s peak" TrueNAS | not a peak, not a ceiling | A guess dressed as a measurement; it was one client's pull rate |
| "246 MB/s sustained" TrueNAS | 246 = **one reader**; 431 for two | Real number, wrong label — "sustained" implied it was the NAS's limit |
| "~190 MB/s" Time Machine aggregate | ~114 MB/s (1G capped) | Derived from a *guessed elapsed time*, not a measured interval |
| "52.2 MB/s, the box is the bottleneck" Synology | 109-113 MiB/s, the **link** is the bottleneck | Measured the keepers *migration* (one rsync stream, small files mixed in) and labelled it the DS418's capability. It reversed the LACP verdict for months. |
| Synology wire figures 1017 / 1264 / 1039 Mb/s | 982 / 961 / 962 Mb/s | Three recorded figures **exceeded the line rate of the link they described**. `increase(counter[span+30s]) / span` against a counter that refreshes every 30 s, extrapolating across 2-3 samples. |
| `seq-read-1m` c3 = 120.6 MiB/s | 112.6 MiB/s | Clients were not synchronised, so their bandwidth was summed across partially non-overlapping windows. At `rand-write-4k` the same defect summed three *strictly sequential* runs and inflated the figure 3x. |

The pattern in five of eight: the number was fine, the **conditions** were invented. The
other three are newer and worse — the *instrument* was wrong, and in two of them it
reported something physically impossible (more payload than the link can frame; more
bytes than crossed the wire) without anything stopping to notice. Hence the two checks
now in the harness: a physical-ceiling screen derived from a measured MTU, and a
byte-for-byte counter comparison that never divides by a window.

## Still unmeasured

- **TrueNAS NFS write** throughput. Every figure above is read. The migrations wrote to
  it, but the copies were read-bound at the source, so they bound the source and not the
  destination.
- **TrueNAS with 3+ concurrent readers.** It scaled 1→2 nearly linearly; where it stops
  is unknown, and 431 MB/s is still only 34% of 10G.
- **`nconnect=N` on any NFS mount.** Never tested on any backend.
- **Small-file / metadata** performance anywhere. Every measurement here is bulk
  sequential large-file. The *arr* library scans are a metadata workload and nothing
  characterises it.

## Where the raw context lives

- `blog/blog-hdd-tier-rollout-draft.md` — CephFS Phase 5 (2026-06-12) original figures
- `blog/blog-truenas-migration-draft.md` — keepers + media migrations, the re-measures,
  and the Time Machine apply
- `.claude/skills/rook-ceph/SKILL.md` → "Network provider — `host`" — why the mon-on-frontnet / OSD-on-backnet
  split means client data never traversed the 1G link
