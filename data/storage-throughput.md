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
| **Synology DS418** | NFS over 1G frontnet | **52.2 MB/s** | — | 2026-08-28 | 1 client, bulk sequential |
| **CephFS-HDD** (EC 2+1) | kernel CephFS, 10G backnet | **76.6 MB/s** | 22.1 MB/s | 2026-06-12 | 1 client, 1 stream, `direct` |
| **CephFS-HDD** (EC 2+1) | kernel CephFS, 10G backnet | **124 MB/s** | — | 2026-08-28 | 1 client, 1 stream |
| **CephFS-HDD** (EC 2+1) | kernel CephFS, 10G backnet | **170 MiB/s** | — | 2026-08-28 | **3 parallel** streams, aggregate |
| **TrueNAS** (RAIDZ2 6-wide) | NFS over 10G backnet | **246 MB/s** | — | 2026-08-29 | **1 reader** |
| **TrueNAS** (RAIDZ2 6-wide) | NFS over 10G backnet | **431 MB/s** | — | 2026-08-30 | **2 readers**, aggregate |
| **TrueNAS** (RAIDZ2 6-wide) | SMB over 1G frontnet | — | **~114 MB/s** | 2026-08-31 | 2 Macs, Time Machine, link-saturating |
| *(reference)* cross-node pod | iperf3, 1G frontnet | 879 Mbit/s | — | 2026-05-21 | pre-IPsec baseline |

**TrueNAS NFS is ~2.2× CephFS-HDD read and ~5× the Synology.**

## Per-backend detail

### Synology DS418 — 52.2 MB/s, and the box is the bottleneck

Measured mid-run during the keepers migration (1.65 TiB, Synology → TrueNAS) from two
`zfs list -Hp -o used` samples 90 s apart on the destination. Bulk sequential reads of
large files.

52.2 MB/s is **416 Mbps** — the 1 Gbit link is not close to saturated, so **the DS418
itself is the constraint, not its network**.

That single figure settled a queued piece of work: bonding the DS418's two 1 GbE NICs
(802.3ad LACP) was on the TODO list to speed up moving data off it. **Bonding two links
you cannot fill one of buys nothing.** LACP also balances per *flow* — one NFS mount is
one TCP connection and stays capped at 1 Gbps no matter how many links are bonded. The
lever that would help a single mount is the client's `nconnect=N`, not the bond.

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

### TrueNAS — scales with concurrency, so a single-client number is not the ceiling

6-wide RAIDZ2 of HGST 4 TB drives, NFS exported on the 10G storage backnet
(`192.168.10.10`, MTU 9000).

- **1 reader: ~246 MB/s** (1.97 Gb/s on `enp2s0f0np0`), held for a full hour during the
  keepers post-cutover verification pass — so this is sustained, not a burst.
- **2 readers: ~431 MB/s** (3.45 Gb/s), both media transmissions verifying concurrently.

Neither is near 10G line rate. **246 MB/s is a per-client ceiling, not the NAS's** —
it nearly doubles with a second reader, which is the whole point of recording the client
count alongside the number.

Methodology note: these came from watching real work (migration verification passes)
rather than a synthetic benchmark. Same shape as the CephFS `dd` tests — sequential
large-file reads — so the comparison is fair.

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

The pattern in four of five: the number was fine, the **conditions** were invented.

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
- `CLAUDE.md` → "Network provider — `host`" — why the mon-on-frontnet / OSD-on-backnet
  split means client data never traversed the 1G link
