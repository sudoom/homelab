# TrueNAS workload characterisation

Read-only sampler answering one question: **what do the real workloads actually
do**, so that tuning this NAS is decided by evidence rather than instinct.

`tests/storage-benchmark/` measures synthetic patterns carefully and says nothing
about real use. Every lever available here — SLOG, recordsize, special vdev, more
RAM — is chosen by the *shape* of the real workload, and choosing without that is
how eight throughput figures in this repo ended up wrong.

## Why the obvious tuning moves are already ruled out

Measured 2026-09-07 before sampling started:

| observation | consequence |
|---|---|
| ARC hit ratio **97.8%**, 16 GB RAM free, `arc_max=0` | more RAM and L2ARC buy nothing; L2ARC would *hurt* (headers consume ARC) |
| seq read 481–530 MiB/s, pool-bound not link- or CPU-bound | 10G network and the Xeon are not constraints |
| `rand-write-4k` 104 iops @16K recordsize, p99 608 ms | the only measured weakness, and it is **sync-write on a ZIL with no SLOG** |
| Synology comparison: 7143 iops @ p99 21.9 ms | not a fair comparison — ~15× four spindles' capability, and its 1.67 GiB test fits in 2 GB RAM. It buffers; TrueNAS commits. |

So the open question is narrow: **does the real workload actually issue sync
writes in volume?** If not, the measured weakness describes a workload that does
not run here and no hardware is warranted.

## Decision rule — fixed BEFORE the data arrives

Written down first so it cannot be rationalised afterwards:

- sync writes **< ~5%** of write bytes → **no SLOG**, close the question permanently
- request sizes cluster **≥128k** → recordsize is correct, stop tuning
- heavy small-file tail on **immich** → split thumbnails to a smaller-recordsize dataset
- ARC hit stays **>95%** under real load → no more RAM, no L2ARC, ever

## Instruments

| source | why |
|---|---|
| `zpool iostat -r` | request-size histogram **split by `sync_write` vs `async_write`** — the SLOG answer directly, no inference |
| `zpool iostat -w` | latency histogram, locating the tail |
| `objset-*` kstats | **per-dataset** reads/writes/bytes; each carries `dataset_name`, so "which dataset is hot" is measured |
| `zil` kstat | commit counts — independent cross-check on the sync figure |
| `arcstats` | confirms the idle 97.8% holds under load |

**Counters are emitted raw and cumulative; deltas are computed at analysis time.**
Deliberate: a sampler that pre-computes rates cannot be re-analysed over a
different window, and every rate error in this repo's history came from dividing
at capture time instead of subtracting two counters.

Output lands in `/var/tmp` (boot-pool), never on `tank`, so the sampler does not
appear in the statistics it measures.

## Running

```bash
ssh truenas_admin@192.168.1.25 "cat > /var/tmp/sample-workload.sh && chmod +x /var/tmp/sample-workload.sh" \
  < tests/truenas-workload/sample-workload.sh
ssh truenas_admin@192.168.1.25 \
  'setsid nohup /var/tmp/sample-workload.sh /var/tmp/zfs-workload 60 36 >/var/tmp/zfs-workload.out 2>&1 </dev/null &'
```

Args: `<outdir> <interval_s> <max_hours>`. It stops itself at `max_hours`.

Check on it, and collect when done:

```bash
ssh truenas_admin@192.168.1.25 'pgrep -f "[s]ample-workload" && tail -2 /var/tmp/zfs-workload/run.log'
ssh truenas_admin@192.168.1.25 'tar -C /var/tmp -cz zfs-workload' > data/truenas-workload-$(date +%Y%m%d).tar.gz
```

## Coverage matters more than duration

A day of idle sampling answers nothing. The run must span a Jellyfin playback,
an \*arr import, an immich upload **with thumbnail generation**, and a Time
Machine backup — then the histograms can be sliced per workload instead of
averaged into mush. Note the wall-clock of those events while they happen; the
samples are timestamped and can be cut to match.

Started 2026-09-07 11:19 local, 60s interval, 36h cap.
