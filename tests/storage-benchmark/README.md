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

## State as of 2026-09-05 (paused for review)

**The harness works end to end** — one row carries `note=ok`, having gone job →
parse → switch cross-check → record. Before that the chain had never completed
once. **There is still no usable dataset**: all other rows are annotated
`NOT QUOTABLE`, `SUPERSEDED` or `SUSPECT`, and the 18-cell Synology grid was
stopped part-way.

### Settled, don't re-litigate

- **O_DIRECT works over NFS here.** fio and the switch agree at a 0.93
  payload/L2 ratio, exactly what 1500-byte framing predicts. Every earlier
  "fio exceeds the wire" was a defect in *my cross-check*, not caching. I built
  a client-page-cache theory (94 GB node RAM) on an artifact of my own
  instrument — the checker was wrong, not the thing being checked.
- **The wire figure must be a counter delta over the pod-reported fio window.**
  `rate(...[1m])` is unusable: mktxp scrapes every 30s, so a 60s burst
  straddling a scrape boundary averages with idle time and reads ~25% low.
- **Corpus sizing is derived, not chosen.** All six workloads share one 64 GiB
  corpus, set by the largest server cache in scope (TrueNAS's 31.3 GiB ARC).

### Defects found by running it, all fixed

| defect | why inspection missed it |
|---|---|
| `declare -A` | bash 3.2 on macOS has no associative arrays |
| `numfmt` | GNU coreutils only |
| `envsubst` | not in the ceph image |
| `sort \| head` + `pipefail` | SIGPIPE only once output exceeds the pipe buffer |
| column-0 heredoc in a YAML block scalar | valid bash, valid-looking YAML, invalid manifest |
| `oc wait --for=condition=complete` | cannot observe failure; blocks for the full deadline |
| filesize < server RAM | returns cache figures *silently* |
| deadline ignoring layout | killed a run mid-layout, poisoning the next two |
| **dangling `${WIN}`** | **killed 12 runs after Completion but before parse/cleanup** |

### The method that actually worked

Every one of the last four was found by **running one cell with the driver's
display filter removed**. The filter was concealing the errors, and separately
could not match two-hyphen workload names, so successes were invisible too —
two bugs hiding each other behind a third. When this harness goes quiet, take
the filter off before theorising.

### Open for the review

1. **Was any of this worth it** versus hand-measuring during real work, which
   is where every historical figure in `data/storage-throughput.md` came from.
2. **`dnf install fio` costs ~90s per pod per Job** and depends on pod egress.
   Mirroring an fio-bearing image through the zot pullthrough removes both.
3. **CephFS may not be worth running at all** — ~1 hour of EC 2+1 layout on
   three HDD spindles, for a tier that now has no production consumers.
4. **fio's multi-client sum assumes the clients overlap** and they don't; each
   pod installs fio and checks layout independently before its own 60s window.
   A start barrier would fix it. Until then the switch counter is the better
   aggregate for multi-client runs.

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
