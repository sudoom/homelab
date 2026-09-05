# Storage benchmark harness

Repeatable, comparable throughput/IOPS/metadata measurement across every storage
backend this homelab has. Runs **from inside the OKD cluster**, which is the only
place with a path to all three locations at once.

## Why this exists

Not because the numbers were missing — because they were **unreliable in a
specific way**. Five figures in this repo have been wrong and four failed
identically: *the measurement was real and the conditions were invented.*

| Claimed | Actual | Failure |
|---|---|---|
| "246 MB/s sustained" TrueNAS | 246 = **one reader**; 431 for two | real number, wrong label |
| "~270 MB/s peak" TrueNAS | neither a peak nor a ceiling | guess dressed as measurement |
| 76.6 MB/s CephFS read | 124 MB/s | real, but 2 months stale |
| "~200 MB/s" CephFS read | 76.6, later 124 | unmeasured, 2.6× high |
| "~190 MB/s" Time Machine | ~114 MB/s, 1G-capped | derived from a *guessed elapsed time* |

So the harness's job is not to produce numbers. It is to make the **conditions
inseparable from the number**: the same code that runs the test emits the result
row, so backend, workload, client count, node placement, file size, runtime and
date cannot drift from the figure they describe. Full history in
`data/storage-throughput.md`.

## What it measures

Six workloads, pinned in `fio-jobs.yaml` so results stay comparable across
backends **and across dates**:

| id | shape | answers |
|---|---|---|
| `seq-read-1m` | 1 MiB sequential read, QD8 | Jellyfin streaming, migrations |
| `seq-write-1m` | 1 MiB sequential write, QD8 | bulk import |
| `rand-read-4k` | 4 KiB random read, QD32 | IOPS ceiling / DB-ish read |
| `rand-write-4k` | 4 KiB random write, QD32 | IOPS ceiling / DB-ish write |
| `smallfile-write` | N × 64 KiB files, fsync | *arr library writes, metadata path |
| `smallfile-read` | N × 64 KiB files | *arr library scans |

**`rand-*` and `smallfile-*` are different questions and are routinely
conflated.** `rand-read-4k` does random IO *within one file* and never touches
the filesystem's metadata path; `smallfile-read` walks thousands of separate
files and is almost entirely metadata. Expect the backend ranking to differ
between them — TrueNAS NFS pays a round trip per file where CephFS has a
metadata server.

**Changing a workload's parameters invalidates comparison with every prior
result under that id.** Add a new id (`seq-read-1m-v2`) instead of editing.

## Backends

| backend | layout | tolerance | spindles | link |
|---|---|---|---|---|
| `ceph-nvme-block` | Ceph RBD, replicated ×3 | 2 of 3 | 3 NVMe (PM9A1) | 10G backnet |
| `cephfs-hdd` | CephFS EC 2+1, 1 OSD/node | 1 chunk | 3 HDD | 10G backnet |
| `nfs-truenas-bench` | ZFS RAIDZ2 6-wide | 2 drives | 6 × HGST 4 TB | 10G backnet |
| `nfs-csi` | Synology DS418 SHR (≈RAID5) | 1 drive | 4 × 3.6 TB | **1G frontnet** |

Layout is recorded in every result row, because it is what makes the numbers
make sense: **the DS418 has more spindles than CephFS-HDD (4 vs 3) and measures
~2.4× slower** — one box behind a 1 Gbit link beats disk count. Without the
layout in the row that reads like a contradiction.

## Safety

The harness refuses rather than warns. In order:

1. **Production shares are rejected by name.** `nfs-truenas-{media,immich,keepers}`
   cannot be benchmarked. csi-driver-nfs provisions one subdirectory *per PV
   inside the share*, and every NFS class here is `Retain` — so a run against
   the media class would write `pvc-<uuid>` directories into the live 3.39 TiB
   library and orphan them afterwards. `tank/bench` (200 GiB quota) exists so
   this is never necessary.
2. **Client count vs access mode.** `ceph-nvme-block` is RWO, so `--clients 3`
   is refused. It would not produce a slow result — it would leave pods Pending,
   which reads like a hung benchmark rather than a physical impossibility.
3. **Ceph health.** `HEALTH_ERR` aborts. `HEALTH_WARN` prints the actual detail
   lines so you can tell the two known-benign ones (`BLUESTORE_SLOW_OP_ALERT`,
   `CephPGImbalance`) from something that means your number describes a degraded
   cluster.
4. **Capacity, actually queried.** Needs `filesize × clients × 4` and *checks*
   it — Ceph via the mgr metrics proxy, TrueNAS via `zfs list` over SSH.
   `nvme-replicated` had only 152 GiB free on 2026-09-05, so this is a real
   constraint, not a formality. The Synology has no credentialed probe and
   degrades to a loud warning.

Plus `activeDeadlineSeconds` (a hung benchmark must not hold a PVC forever),
`backoffLimit: 0` (a failed run is a result, not something to retry), and each
client writing to its own subdirectory (or N clients would measure lock
contention on shared filenames rather than the storage).

## Prerequisites

The TrueNAS backend needs `tank/bench` + its NFS export + the
`nfs-truenas-bench` StorageClass. All three are committed but **not yet
applied**:

```bash
cd ansible/truenas && ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass
# ArgoCD syncs components/storage/nfs-csi/ for the StorageClass
```

`cephfs-hdd`, `ceph-nvme-block` and `nfs-csi` need nothing.

## Usage

```bash
cd tests/storage-benchmark
export KUBECONFIG=~/.kube/config          # needs write; the readonly SA cannot apply

./run.sh --list                                        # backends + workloads
./run.sh --backend cephfs-hdd --dry-run                # gates + rendered manifest
./run.sh --backend cephfs-hdd                          # full matrix, 1 client
./run.sh --backend nfs-truenas-bench --clients 3       # the multi-client dimension
./run.sh --backend nfs-csi --workload smallfile-read   # one workload
```

Tunables: `--runtime` (default 60s), `--filesize` (8G), `--clients` (1), and
`BENCH_NRFILES` (2000), `BENCH_IMAGE`, `BENCH_IOENGINE`, `BENCH_NAMESPACE`.

**This applies to the cluster, so it is operator-run** — `oc apply` is
guardrail-denied for Claude.

## Results

Appended to `data/storage-benchmark-results.tsv`, one row per workload:

```
run_id  date  backend  storage_class  layout  workload  clients  nodes
filesize  runtime_s  ioengine  read_MBps  write_MBps  read_iops  write_iops  lat_ms_p99
```

Parsed from fio's JSON by the same run that produced it, never transcribed.
Across clients, **bandwidth and IOPS are summed** (3 clients at 100 MB/s each is
300 MB/s of storage throughput) while **latency p99 is the worst client, not the
mean** — a mean p99 hides the starved client, which on shared storage is the
interesting one. If fewer client blocks parse than were requested, the row is
recorded with the count actually observed rather than the count asked for.

`nodes` matters: 3 clients on 3 nodes and 3 clients on 1 node are different
measurements.

## The Synology LACP question — what the multi-client runs decide

Long-standing open item (README TODO): would bonding the DS418's two 1 GbE NICs
help? The harness answers it, but only if the mechanism is understood first.

**LACP balances per *flow*, hashed on src/dst MAC/IP/port.** One NFS mount is
one TCP connection is one flow, and it stays pinned to a single link no matter
how many are bonded. Bonding never makes one mount faster.

**But the clients here do produce distinct flows** — for a reason that is easy
to get wrong. NFS is kernel-mounted by the **hostNetwork `csi-nfs-node`
DaemonSet**, so the mount is per *node*, not per pod. csi-driver-nfs stages a
volume once per (node, volume) and bind-mounts it into each pod. Therefore:

- 3 clients on **3 nodes** → 3 mounts → 3 TCP connections → **3 flows**, which
  LACP can spread across links.
- 3 clients on **1 node** → 1 shared mount → 1 connection → **1 flow**, which
  LACP cannot help at all.

This is why `nodes` is a column and not a footnote, and it makes the experiment
**self-validating**: if throughput scales with clients spread across 3 nodes but
not with 3 clients on 1 node, that confirms the per-node mount is the flow unit.

### The decision criterion

A single 1 GbE link is ~118 MB/s practical. Single-client read on the DS418 was
measured at **52.2 MB/s (416 Mbps) — 44% of one link**, so at one client the
*box* is the bottleneck and the link is not.

Run `seq-read-1m` at `--clients 1`, `2`, `3` (spread across nodes) and read the
aggregate:

| aggregate plateaus at | meaning | LACP verdict |
|---|---|---|
| **well below ~118 MB/s** (e.g. 60–70) | DS418 CPU / SHR spindles are the limit | **worthless** — bonding a link you cannot fill buys nothing |
| **at ~118 MB/s** | the single 1 GbE link is saturated | **would help** — a second link has somewhere to go |
| scales past 118 MB/s | more than one link is already active | re-check the current bond config first |

Only `seq-read-1m` is informative here. `rand-*` and `smallfile-*` will be
spindle- and latency-bound on 4 SHR drives long before they are link-bound, so
they cannot distinguish the two cases.

**If it turns out link-bound**, the cheaper lever to test before buying into
LACP is the NFS client's **`nconnect=N`** (multiple TCP connections per mount,
Linux 5.3+) — that alone multiplies flows without touching the switch, and LACP
can then spread them. It needs a second StorageClass carrying
`nconnect=4` in `mountOptions` (they are immutable on an existing class), which
is a small addition if the data justifies it.

**Do this while the DS418 still exists.** It is being sold, and it is the only
baseline for "was the TrueNAS migration worth it".

## Pending fixes (found while running, 2026-09-05 — apply after the matrix)

Deliberately NOT applied mid-matrix: the driver actively reads `run.sh`,
`fio-jobs.yaml`, `bench-job.yaml.tpl` and `parse-results.py`, and a partial
write during a run would corrupt it. None of these affect the fio columns —
they are cross-check recording issues.

1. **The switch-window arithmetic reaches back before the job started.**
   `WIN=$(( $(date +%s) - JOB_START + 60 ))` is then used as
   `max_over_time(rate(...)[WIN:30s])`, which looks back `WIN` seconds *from
   now* — i.e. ~60 s before the job began — and the inner `rate(...[1m])`
   adds another 60 s on top. So a run picks up the tail of the PREVIOUS run.
   Observed: a `seq-write-1m` row recorded `wire rx 972.0 Mb/s`, which is
   meaningless for a write test and was the preceding `seq-read-1m` bleeding in.
   Fix: query `query_range` with explicit `start=JOB_START&end=JOB_END` instead
   of a look-back window, so the bounds are the job's own.

2. **The "fio claims more than the wire" threshold is too loose.** It is 1.15;
   an observed 1.20 discrepancy passed unflagged. Tighten to ~1.05.

3. **fio's multi-client aggregate assumes the clients overlap, and they don't.**
   Each pod independently does `dnf install fio`, the layout check, then runs
   its own 60 s window, so the three drift apart. Summing their bandwidths
   therefore counts intervals when only one or two clients were actually
   reading — which is the likely cause of fio reporting 133.0 MiB/s
   (1115 Mb/s payload) against a 1 GbE link whose wire ceiling is ~941 Mb/s.
   The switch counter has no such problem: it measures concurrency by
   construction.
   **Consequence worth internalising: for MULTI-CLIENT aggregate throughput the
   wire number is the more trustworthy of the two, not fio's sum.**
   Proper fix is a start barrier so all clients begin measuring together (fio
   has `--startdelay`, or a shared file on the PVC all clients poll).

## Known gaps

- **The Synology writes into `/volume1/kubenfs`** alongside production PVCs
  (immich, keepers). There is no credentialed path to give it a dedicated share
  and it is being sold, so this is accepted — but delete the benchmark PVC and
  its `pvc-<uuid>` directory afterwards. It is the only backend where the
  harness cannot fully isolate itself.
- **SMB is not covered.** Time Machine's path (Macs → 1G frontnet → SMB) has no
  in-cluster equivalent, so its figures stay hand-measured.
- **`dnf install fio`** needs pod egress, which breaks on this cluster whenever
  a host address changes (`br-ex.forwarding`). The container says so explicitly
  rather than failing with a bare dnf error.
- **The PVC is retained between runs** so repeat runs don't re-provision. Delete
  it when finished: `oc -n default delete pvc storage-bench-<backend>`.

## Files

| file | purpose |
|---|---|
| `run.sh` | gates, renders, applies, collects, records |
| `fio-jobs.yaml` | ConfigMap of the six pinned workloads |
| `bench-job.yaml.tpl` | PVC + Job template (`__TOKEN__` substitution; not valid YAML as-is) |
| `parse-results.py` | fio JSON → one result row with conditions |
