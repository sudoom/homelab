#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Storage benchmark runner. OPERATOR-RUN — this applies to the cluster.
#
# WHY THIS EXISTS: five throughput figures in this repo have been wrong, and
# four failed the same way — the number was real and the CONDITIONS were
# invented ("246 MB/s sustained" was one reader; "~190 MB/s" came from a guessed
# elapsed time). See data/storage-throughput.md. A harness fixes that by making
# the conditions structural: every result row is emitted by the same code that
# ran the test, so backend / workload / client-count / node placement / date
# cannot drift from the number they describe.
#
# Usage:
#   ./run.sh --list                                  # show backends + workloads
#   ./run.sh --backend cephfs-hdd --dry-run          # gates + rendered manifest
#   ./run.sh --backend cephfs-hdd                    # full matrix, 1 client
#   ./run.sh --backend nfs-truenas-bench --clients 3 # multi-client
#   ./run.sh --backend cephfs-hdd --workload smallfile-write --clients 2
#   ./run.sh --backend nfs-csi --clean                 # remove retained layout files
#
# Results append to data/storage-benchmark-results.tsv (machine-readable) and
# are summarised to stdout.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${REPO_ROOT}/data/storage-benchmark-results.tsv"

NAMESPACE="${BENCH_NAMESPACE:-default}"
IMAGE="${BENCH_IMAGE:-quay.io/ceph/ceph:v19.2.3}"
IOENGINE="${BENCH_IOENGINE:-libaio}"
RUNTIME="${BENCH_RUNTIME:-60}"
# ONE FILESIZE FOR EVERY BACKEND, deliberately. Comparability is the whole
# point of this harness, and a figure taken at 8G is not comparable to one
# taken at 64G no matter how carefully both are labelled.
#
# 64G is not arbitrary -- it is set by the LARGEST server cache in scope:
#   Synology DS418      2    GB RAM
#   Ceph OSDs        ~  4    GiB osd_memory_target x3
#   TrueNAS            31.3  GiB ECC  <-- binding constraint
# A file at or below a server's RAM is served from that server's cache, so the
# result measures RAM and network instead of storage. Proven here, not assumed:
# an 1G file against the DS418 returned 104.6 MiB/s (878 Mbps, near 1G line
# rate) while the same box does 52.2 MB/s on cold data.
#
# direct=1 bypasses the CLIENT page cache and does nothing about the server's.
FILESIZE="${BENCH_FILESIZE:-64G}"
MIN_FILESIZE="${BENCH_MIN_FILESIZE:-64G}"
# smallfile corpus is DERIVED from FILESIZE, not set independently.
#
# It used to be a standalone 20000 (= ~5 GiB), which cleared the DS418's 2 GB
# but NOT TrueNAS's 31.3 GiB ARC -- so the smallfile cells would have measured
# warm metadata on one backend and cold storage on another, and the two would
# have sat in the same table looking comparable. Deriving it means the corpus
# is the same 64 GiB as every other workload and cannot drift out of step.
#
# COST, because it is not small: 64 GiB of 64k files is 1,048,576 files PER
# CLIENT -- ~3M at c=3 -- and at the ~684 files/sec/client measured on the
# DS418 that is ~25 minutes of one-time layout. The persistent layout is what
# makes it affordable: paid once per backend, reused by every later run.
#
# SPACE: 192 GiB of big files + 192 GiB of small files = 384 GiB per backend at
# c=3. Fits the 400Gi PVC and tank/bench's 500G quota, but not by much.
SMALLFILE_BYTES=65536
NRFILES="${BENCH_NRFILES:-}"
CLIENTS=1
WORKLOADS=""
BACKEND=""
DRY_RUN=0
CLEAN=0

# ---- Backend registry ------------------------------------------------------
# name|storage_class|access_mode|pvc_size|max_clients|switch_if|layout
#
# A PIPE-DELIMITED STRING, NOT AN ASSOCIATIVE ARRAY, deliberately: `declare -A`
# is bash 4+, and macOS ships bash 3.2.57 -- where `[name]=value` is parsed as
# an arithmetic array index and the first word becomes an unbound variable.
# This script has to run on the operator's Mac, so it stays bash-3.2 clean.
# (Found the hard way: the first draft used declare -A and died on `--list`.)
#
# max_clients is a REAL constraint, not a policy: an RWO volume cannot be
# mounted by pods on two nodes, so asking for 3 clients on ceph-nvme-block does
# not produce a slow result -- it produces pods stuck Pending, which reads like
# a hung benchmark rather than a scheduling impossibility.
#
# LAYOUT IS PART OF THE RESULT. Three backends, three different shapes, and the
# shape explains the numbers: the DS418 has MORE spindles than CephFS-HDD (4 vs
# 3) and measured 2.4x slower, because it is one box behind a 1G link. Without
# the layout in the row, that looks like a contradiction.
#
# ceph-nvme-block IS DELIBERATELY ABSENT (2026-09-05). It is RWO, so it can
# never take part in the multi-client dimension, and it is NVMe against three
# HDD-backed backends -- a comparison that tells you the device class differs,
# which nobody needed a benchmark to learn. Add it back only for an
# NVMe-vs-NVMe question.
#
# PVC SIZE IS DERIVED FROM THE CORPUS COUNT, and the count is not one per
# client. fio's default filename_format is $jobname.$jobnum.$filenum, so each
# of the FOUR bulk workloads keeps its OWN 64 GiB file. The two smallfile jobs
# share a single corpus, but only because fio-jobs.yaml pins filename_format
# explicitly. Per client that is 4 x 64 GiB bulk + 64 GiB smallfile = 320 GiB,
# so a 3-client 18-cell grid needs 960 GiB.
#
# MEASURED, not derived: after the 12-cell TrueNAS bulk grid completed,
# `zfs list tank/bench` read USED 767G with exactly 256 GiB in each of c0/c1/c2
# -- 4 x 64 GiB per client, smallfile corpus not yet built.
#
# This read 600Gi until 2026-09-06, with a comment claiming "TWO 64 GiB corpora
# per client -- so 384 GiB total". That undercounts the bulk side 4:1. It never
# failed because on NFS the PVC size is ADVISORY -- csi-driver-nfs provisions a
# subdirectory inside the share and nothing enforces the request, so the real
# limits were the DS418 volume and tank/bench's quota. CephFS ENFORCES it, so
# cephfs-hdd at 600Gi would have hit ENOSPC mid-layout around cell 9 of 12,
# hours in, presenting as a CephFS fault rather than a sizing error.
#
# The two NFS entries STAY at 600Gi deliberately: their PVCs are already Bound
# with corpora in them, and run.sh re-applies the PVC on every run -- raising
# the request on a live PVC is an expansion, which csi-driver-nfs does not
# support, so it would break every future NFS run to fix a number that has no
# effect there. cephfs-hdd is sized correctly because it is enforced and the
# PVC does not exist yet.
#
# switch_if is the MikroTik port carrying this backend's traffic, as
# routerboard/interface, or "-" when there is no single port to watch. It gives
# an INDEPENDENT measurement: fio reports what the client believes it got, the
# switch reports what actually crossed the wire. Disagreement means one of them
# is wrong, and historically it has been the client.
#
# It would have caught the 1G smoke test instantly -- 104.6 MiB/s of "disk"
# read while the NAS port showed near-zero is obviously cache-served.
#
# THE TWO TrueNAS PORTS ARE NOT A NAMING TYPO -- they are two physical links,
# and picking the wrong one measures nothing. Resolved by mktxp_interface_rate:
#   home-switch/TrueNAS  link_rate=10000  <- 10G backnet, carries NFS (this one)
#   home-router/TrueNas  link_rate= 1000  <- 1G frontnet, carries Time Machine SMB
#   home-router/nas      link_rate= 1000  <- Synology
# Check the link rate, not the spelling, if these ever need revisiting.
#
# bench and bench16 share the SAME physical port, because they are the same NAS
# on the same 10G link -- the twin differs only in ZFS record size. So the wire
# cross-check cannot tell them apart, and the two must not be measured
# concurrently or each will corroborate against the other's bytes.
#
# cephfs-hdd WAS "-" -- no cross-check at all -- reasoning that its traffic is
# node-to-node, shows on three ports at once, and is double counted (once leaving
# the sender, once arriving at the reader), so no single port means "CephFS
# throughput". That is right about the SWITCH and wrong about the conclusion:
# Ceph publishes per-pool byte counters, a BETTER instrument than a switch port
# because it measures the storage layer directly instead of the network.
#
# The exemption cost a real result on 2026-09-06. Cell 1 of the CephFS grid
# reported 1081.8 MiB/s seq-read from three HDD OSDs -- ~90% of 10 GbE line rate,
# 8.7x the last measured figure for the tier -- and nothing flagged it, because
# this was the one backend with no independent instrument. The pool counter said
# 10.83 GB over the 66s window: 164.1 MB/s, ratio 0.145. The figure was 86% cache.
#
# "cephpool/<pool>" routes switch_rate() at the mgr metrics instead of mktxp.
#
# The old note, still true of the switch itself: its traffic is node-to-node across the backnet,
# so it appears on three ports at once and each byte is counted twice (once
# leaving the sender, once arriving at the reader). There is no single port
# whose counter means "CephFS throughput".
BACKENDS_TABLE="\
cephfs-hdd|cephfs-hdd|ReadWriteMany|1000Gi|6|cephpool/cephfs-bulk-hdd|CephFS EC 2+1 across 3 HDD OSDs (1/node), 10G backnet, quota ENFORCED
nfs-truenas-bench|nfs-truenas-bench|ReadWriteMany|600Gi|6|home-switch/TrueNAS|TrueNAS RAIDZ2 6-wide HGST 4TB over NFS, 10G backnet, recordsize 1M, no SLOG
nfs-truenas-bench16|nfs-truenas-bench16|ReadWriteMany|1000Gi|6|home-switch/TrueNAS|TrueNAS RAIDZ2 6-wide HGST 4TB over NFS, 10G backnet, recordsize 16K, no SLOG
nfs-csi|nfs-csi|ReadWriteMany|600Gi|6|home-router/nas|Synology DS418 SHR (~RAID5 1-drive tol) 4x3.6TB over NFS, 1G frontnet"

backend_row() { echo "$BACKENDS_TABLE" | grep "^$1|" || true; }

ALL_WORKLOADS="seq-read-1m seq-write-1m rand-read-4k rand-write-4k smallfile-write smallfile-read"

die() { echo "ERROR: $*" >&2; exit 1; }

usage_list() {
  echo "Backends:"
  echo "$BACKENDS_TABLE" | while IFS='|' read -r b sc am size maxc swif desc; do
    [ -n "$b" ] || continue
    printf "  %-20s %-16s max_clients=%-2s  %s\n" "$b" "$am" "$maxc" "$desc"
  done
  echo
  echo "Workloads: ${ALL_WORKLOADS}"
  echo
  echo "All backends run at the SAME filesize (${FILESIZE}) so results are comparable."
  echo
  echo "NOTE: nfs-csi is the Synology, which is being sold. Measure it while it"
  echo "      still exists — it is the only baseline for 'was the migration worth it'."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)     usage_list; exit 0 ;;
    --backend)  BACKEND="$2"; shift 2 ;;
    --workload) WORKLOADS="$2"; shift 2 ;;
    --clients)  CLIENTS="$2"; shift 2 ;;
    --runtime)  RUNTIME="$2"; shift 2 ;;
    --filesize) FILESIZE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --clean)    CLEAN=1; shift ;;
    *) die "unknown arg: $1 (try --list)" ;;
  esac
done

[[ -n "$BACKEND" ]] || die "--backend required (try --list)"

# Refuse a PRODUCTION share BEFORE the registry lookup, so someone who reaches
# for the obvious name gets told why rather than a bare "unknown backend".
# csi-driver-nfs provisions one subdirectory per PV INSIDE the share, and every
# NFS class here is Retain -- so a run against nfs-truenas-media would write
# pvc-<uuid> dirs into the live 3.39 TiB media library and leave them there.
case "$BACKEND" in
  nfs-truenas-media|nfs-truenas-immich|nfs-truenas-keepers)
    die "'$BACKEND' is a PRODUCTION dataset, and benchmarking it would write
  into live data: csi-driver-nfs creates a pvc-<uuid> subdirectory inside the
  share, and the class is Retain, so the directory is orphaned afterwards.
  Use --backend nfs-truenas-bench instead (tank/bench, 200G quota, exists for
  exactly this)." ;;
esac

ROW="$(backend_row "$BACKEND")"
[[ -n "$ROW" ]] || die "unknown backend '$BACKEND' (try --list)"
[[ -n "$WORKLOADS" ]] || WORKLOADS="$ALL_WORKLOADS"

IFS='|' read -r _NAME SC ACCESS_MODE PVC_SIZE MAX_CLIENTS SWITCH_IF LAYOUT <<< "$ROW"

# BENCH_LAYOUT_NOTE appends a CONDITION to the layout column. The registry
# describes the backend's permanent shape; this describes the state of the
# world during the run, which is the other half of what makes a number mean
# something. Without it two runs of the same cell under materially different
# conditions produce rows that look identical and cannot be told apart later --
# the exact failure the corrections log is full of.
#
# Added 2026-09-06 when media/immich/keepers were scaled to zero and Time
# Machine set to manual, giving the first genuinely idle window TrueNAS has
# been measured in. Every prior TrueNAS row was taken against a live NAS.
[[ -n "${BENCH_LAYOUT_NOTE:-}" ]] && LAYOUT="${LAYOUT}, ${BENCH_LAYOUT_NOTE}"

# ---- Gates: fail closed, before anything is applied -----------------------
echo ">>> gates"

# 1. Client count vs access mode. RWO physically cannot span nodes.
if [[ "$CLIENTS" -gt "$MAX_CLIENTS" ]]; then
  die "backend '$BACKEND' is $ACCESS_MODE, max_clients=$MAX_CLIENTS, asked for $CLIENTS.
  An RWO volume cannot be mounted by pods on different nodes — the extra pods
  would sit Pending forever and look like a hung benchmark."
fi
echo "  ok   clients=$CLIENTS within max_clients=$MAX_CLIENTS for $ACCESS_MODE"

# 2. StorageClass must actually exist.
oc get sc "$SC" >/dev/null 2>&1 || die "StorageClass '$SC' not found on this cluster."
echo "  ok   storageclass $SC present"

# 3. Ceph must not already be unhealthy. Benchmarking a degraded cluster
#    produces a number that describes the degradation, not the storage — and
#    on a 3-node no-drain topology it also ADDS load during a recovery.
CEPH_HEALTH="$(oc -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo UNKNOWN)"
case "$CEPH_HEALTH" in
  HEALTH_OK) echo "  ok   ceph $CEPH_HEALTH" ;;
  HEALTH_WARN)
    echo "  WARN ceph $CEPH_HEALTH — known-benign warnings on this cluster are"
    echo "       BLUESTORE_SLOW_OP_ALERT and CephPGImbalance. Anything else means"
    echo "       the number you are about to take describes a degraded cluster:"
    oc -n rook-ceph get cephcluster rook-ceph -o jsonpath='{range .status.ceph.details.*}{"         "}{@.message}{"\n"}{end}' 2>/dev/null
    ;;
  *) die "ceph health is '$CEPH_HEALTH' — refusing to add benchmark load." ;;
esac

# 4. Capacity headroom -- ACTUALLY CHECKED, not just recommended.
#    A benchmark that fills a pool is an outage, not a test. nvme-replicated had
#    only 152 GiB max_avail on 2026-09-05, small enough that an unchecked
#    multi-client big-file run could genuinely hurt. An advisory "please verify"
#    is what everyone skips at 2am, so this queries and refuses.
#
#    numfmt is GNU coreutils and does NOT exist on macOS, so sizes are parsed in
#    pure bash. (Same portability class as the declare -A bug above.)
#
#    Accepts BOTH the fio spelling (64G) and the Kubernetes one (1000Gi). Only
#    fio sizes reached it until the grid gate below started parsing pvc_size,
#    which is a Kubernetes quantity -- "1000Gi" left "Gi" as the unit and fell
#    through to die(). Same number, different dialect, in one script.
to_bytes() {
  local v="$1" n u
  n="${v%%[!0-9]*}"
  u="${v#$n}"
  case "$u" in
    ""|B)           echo $(( n )) ;;
    K|Ki|KiB|k)     echo $(( n * 1024 )) ;;
    M|Mi|MiB|m)     echo $(( n * 1024 * 1024 )) ;;
    G|Gi|GiB|g)     echo $(( n * 1024 * 1024 * 1024 )) ;;
    T|Ti|TiB|t)     echo $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
    *) die "cannot parse size '$v' (use e.g. 8G, 512M)" ;;
  esac
}

ceph_pool_avail() {   # $1 = pool name -> bytes, or empty if unavailable
  oc get --raw "/api/v1/namespaces/rook-ceph/services/http:rook-ceph-mgr:9283/proxy/metrics" 2>/dev/null \
    | python3 -c "
import sys,re
t=sys.stdin.read(); want='$1'
ids={d['pool_id']:d.get('name') for d in (dict(re.findall(r'(\w+)=\"([^\"]*)\"',m.group(1))) for m in re.finditer(r'ceph_pool_metadata\{([^}]*)\}',t)) if 'pool_id' in d}
for m in re.finditer(r'^ceph_pool_max_avail\{([^}]*)\}\s+([0-9.e+]+)',t,re.M):
    d=dict(re.findall(r'(\w+)=\"([^\"]*)\"',m.group(1)))
    if ids.get(d.get('pool_id'))==want: print(int(float(m.group(2)))); break
" 2>/dev/null
}

# 5. Cache-defeat gate. A file that fits in the SERVER's RAM measures the
#    server's RAM. See the min_filesize note in the registry above.
if [[ "${BENCH_ALLOW_SMALL:-0}" != "1" && "$(to_bytes "$FILESIZE")" -lt "$(to_bytes "$MIN_FILESIZE")" ]]; then
  die "--filesize $FILESIZE is too small for '$BACKEND' (minimum $MIN_FILESIZE).
  A file smaller than the server's RAM is served from its cache, so the result
  measures the network and the cache rather than the storage. Measured proof:
  filesize=1G against the DS418 (2 GB RAM) returned 104.6 MiB/s = 878 Mbps,
  near 1G line rate, while the same box does 52.2 MB/s on cold data.
  Override deliberately with BENCH_ALLOW_SMALL=1 if you actually want the
  cache-served ceiling -- and label the result as such."
fi
echo "  ok   filesize $FILESIZE >= $MIN_FILESIZE (defeats server cache)"

# filesize x clients x 2. Each client lays out exactly one file of this size;
# x2 is slack, not headroom for a second copy.: the file itself, fio's write pass over
# it, per-client subdirectories, and slack so a benchmark never takes a pool to
# its limit.
NEED_BYTES=$(( $(to_bytes "$FILESIZE") * CLIENTS * 2 ))
AVAIL_BYTES=""
AVAIL_SRC=""
case "$BACKEND" in
  ceph-nvme-block)   AVAIL_BYTES="$(ceph_pool_avail nvme-replicated)"; AVAIL_SRC="ceph pool nvme-replicated" ;;
  cephfs-hdd)        AVAIL_BYTES="$(ceph_pool_avail cephfs-bulk-hdd)"; AVAIL_SRC="ceph pool cephfs-bulk-hdd" ;;
  # MUST probe the DATASET, not the pool. tank/bench carries a quota, and
  # `zfs list -o available` on a quota'd dataset reports the quota-bounded
  # figure while the pool reports the whole 8.88 TiB. Probing the pool would
  # wave through a 3-client 64G run (needs 384 GiB) against a 200 GiB quota and
  # fail it two thirds of the way into layout -- about 20 minutes in.
  # Measured 2026-09-05: tank=9766991880320, tank/bench=214748168384.
  nfs-truenas-bench) AVAIL_BYTES="$(ssh -o ConnectTimeout=8 truenas_admin@192.168.1.25 \
                        'zfs list -Hp -o available tank/bench' 2>/dev/null || true)"; AVAIL_SRC="zfs tank/bench (quota-bounded)" ;;
  nfs-truenas-bench16) AVAIL_BYTES="$(ssh -o ConnectTimeout=8 truenas_admin@192.168.1.25 \
                        'zfs list -Hp -o available tank/bench16' 2>/dev/null || true)"; AVAIL_SRC="zfs tank/bench16 (quota-bounded)" ;;
  nfs-csi)           AVAIL_SRC="Synology (no credentialed probe -- check DSM by hand)" ;;
esac

human() { python3 -c "print('%.2f GiB' % ($1/1024**3))" 2>/dev/null || echo "$1 B"; }

if [[ -n "$AVAIL_BYTES" ]]; then
  if [[ "$AVAIL_BYTES" -lt "$NEED_BYTES" ]]; then
    die "not enough headroom on $AVAIL_SRC.
  need  $(human "$NEED_BYTES")  (filesize $FILESIZE x $CLIENTS clients x 2 safety factor)
  have  $(human "$AVAIL_BYTES")
  Lower --filesize or --clients, or pick another backend. Refusing to run a
  benchmark that could fill the pool."
  fi
  echo "  ok   headroom $(human "$AVAIL_BYTES") available on $AVAIL_SRC, need $(human "$NEED_BYTES")"
else
  echo "  WARN could not probe capacity for $AVAIL_SRC."
  echo "       Need $(human "$NEED_BYTES"). VERIFY BY HAND before a large run."
fi

# 6. PVC QUOTA vs the WHOLE GRID, not just this cell.
#
# Gate 4 asks "does the pool have room for this invocation". That is the wrong
# question on a backend whose PVC is enforced, because the corpora are RETAINED
# and accumulate across cells: each of the four bulk workloads keeps its own
# 64 GiB file per client, and the two smallfile jobs share one more. A grid
# therefore lands at 320 GiB x clients even though no single cell needs more
# than 64 GiB x clients.
#
# Checked against the PVC REQUEST rather than the pool because that is what
# CephFS enforces -- the pool had 3753 GiB free on 2026-09-06 while the PVC
# would have cut the run off at 600.
#
# Advisory on NFS (nothing enforces the request there), so it warns instead of
# dying unless the class actually enforces it.
GRID_BYTES=$(( $(to_bytes "$FILESIZE") * 5 * CLIENTS ))
PVC_BYTES=$(to_bytes "$PVC_SIZE")
if [[ "$GRID_BYTES" -gt "$PVC_BYTES" ]]; then
  MSG="a full 18-cell grid at clients=$CLIENTS retains $(human "$GRID_BYTES") of corpora
  (4 bulk corpora + 1 shared smallfile corpus, 64G each, per client) but the PVC
  is only $(human "$PVC_BYTES")."
  case "$BACKEND" in
    cephfs-hdd)
      die "$MSG
  CephFS ENFORCES the quota, so this fails with ENOSPC partway through layout --
  hours in, looking like a CephFS fault. Raise pvc_size in the backend registry
  BEFORE the PVC is created (it is immutable-ish afterwards: csi-driver-nfs
  cannot expand, and a CephFS expansion needs the PV patched too)." ;;
    *)
      echo "  WARN $MSG"
      echo "       Advisory here -- $SC does not enforce the request, so the real"
      echo "       limits are the share's own quota. Not fatal." ;;
  esac
else
  echo "  ok   PVC $PVC_SIZE covers a full grid at clients=$CLIENTS ($(human "$GRID_BYTES") of retained corpora)"
fi

# --clean removes the retained layout files (and only those). They are kept by
# default because at 64G per client they are the expensive part of a run, but
# they DO occupy real space on a production-adjacent share -- notably the
# Synology, where the benchmark PVC lives in /volume1/kubenfs beside the immich
# and keepers PVCs and cannot be isolated.
if [[ "$CLEAN" == "1" ]]; then
  echo ">>> cleaning retained layout files for $BACKEND"
  CLEAN_JOB="storage-bench-clean-$(date +%s)"
  cat <<CLEANEOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${CLEAN_JOB}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: storage-benchmark
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 600
  template:
    spec:
      restartPolicy: Never
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: storage-bench-${BACKEND}
      containers:
        - name: clean
          image: ${IMAGE}
          command: ["/bin/bash","-c"]
          args:
            - |
              echo "before:"; du -sh /data/${BACKEND} 2>/dev/null || echo "  (nothing)"
              rm -rf /data/${BACKEND}
              echo "after:";  du -sh /data/${BACKEND} 2>/dev/null || echo "  (removed)"
          volumeMounts:
            - name: data
              mountPath: /data
CLEANEOF
  oc -n "$NAMESPACE" wait --for=condition=complete "job/${CLEAN_JOB}" --timeout=600s || true
  oc -n "$NAMESPACE" logs "job/${CLEAN_JOB}" 2>/dev/null || true
  oc -n "$NAMESPACE" delete "job/${CLEAN_JOB}" --wait=false >/dev/null 2>&1 || true
  echo ">>> done. The PVC itself is untouched: oc -n ${NAMESPACE} delete pvc storage-bench-${BACKEND}"
  exit 0
fi

# 4 jobs per client, so each job gets a quarter of the corpus.
if [[ -z "$NRFILES" ]]; then
  NRFILES=$(( $(to_bytes "$FILESIZE") / SMALLFILE_BYTES / 4 ))
fi

RUN_ID="bench-$(date +%Y%m%d-%H%M%S)"
# THE DEADLINE MUST COVER LAYOUT, WHICH DOMINATES AT THESE FILE SIZES.
# Original formula was (RUNTIME+300)*2 = 720s at runtime=60, while laying out
# 3 x 64 GiB across a 1G link takes ~27 MINUTES. The clients=3 run was killed
# mid-layout by that deadline -- and worse, the PARTIAL FILES it left behind
# poisoned the next run: clients=2 read short files that fit in the DS418's
# cache and reported 127.1 MiB/s (1066 Mb/s) against a wire that peaked at
# 969.5 Mb/s. Physically impossible, and only visible because of the switch
# cross-check.
#
# THE PESSIMISTIC LAYOUT RATE IS PER BACKEND, because "the slowest plausible
# backend" is not one number. 50 MB/s covers the two NFS backends (the DS418
# writes at ~110 MiB/s, TrueNAS at ~87-104), but cephfs-hdd is EC 2+1 across
# three spindles and its last measured sequential write is 22.1 MB/s
# (2026-06-12, data/storage-throughput.md) -- EC amplifies writes x1.5.
#
# At 50 MB/s the c=1 deadline works out to 2634s while a 64 GiB layout at
# 22 MB/s needs ~3120s, so the FIRST cell would have been killed mid-layout.
# That failure is not merely a lost cell: a killed layout leaves a PARTIAL
# file, and the next run reads it, fits it in cache, and reports something
# physically impossible -- which is exactly how the Synology produced a
# 127.1 MiB/s row against a wire that peaked at 969.5 Mb/s.
#
# 15 MB/s for cephfs-hdd rather than the measured 22.1: the figure is nearly
# three months old, and the retained media PVC still occupies the same pool,
# so the OSDs are not the empty ones that measurement was taken against.
#
# SMALLFILE LAYOUT IS METADATA-BOUND, NOT BANDWIDTH-BOUND, and costing it in
# MB/s is how you kill a 3-hour layout at the 80-minute mark. A 64 GiB corpus of
# 64 KiB files is 1,048,576 files PER CLIENT; over NFS each is a synchronous
# create, so the honest unit is files/second. 100/s is deliberately pessimistic.
# Clients lay out in parallel, so the wall-clock does not scale with CLIENTS.
case "$WORKLOADS" in
  *smallfile*)
    FILES_PER_CLIENT=$(( $(to_bytes "$FILESIZE") / SMALLFILE_BYTES ))
    LAYOUT_SECS=$(( FILES_PER_CLIENT / 100 ))
    LAYOUT_DESC="${FILES_PER_CLIENT} files/client allowed ${LAYOUT_SECS}s at a pessimistic 100 files/s"
    ;;
  *)
    case "$BACKEND" in
      cephfs-hdd) LAYOUT_MBPS=15 ;;
      *)          LAYOUT_MBPS=50 ;;
    esac
    LAYOUT_BYTES=$(( $(to_bytes "$FILESIZE") * CLIENTS ))
    LAYOUT_SECS=$(( LAYOUT_BYTES / (LAYOUT_MBPS * 1000000) ))
    LAYOUT_DESC="layout of $(human "$LAYOUT_BYTES") allowed ${LAYOUT_SECS}s at a pessimistic ${LAYOUT_MBPS} MB/s"
    ;;
esac
# The barrier waits out the SLOWEST client's layout, so its timeout is the
# layout budget plus slack -- and it must expire BEFORE activeDeadlineSeconds,
# otherwise the Job is killed instead of reporting which client never arrived.
BARRIER_TIMEOUT=$(( LAYOUT_SECS + 900 ))
DEADLINE=$(( LAYOUT_SECS + RUNTIME + 1200 ))
echo "  info deadline ${DEADLINE}s (${LAYOUT_DESC}; barrier timeout ${BARRIER_TIMEOUT}s)"

echo
echo ">>> plan"
echo "  run_id    $RUN_ID"
echo "  backend   $BACKEND  ($LAYOUT)"
echo "  class     $SC / $ACCESS_MODE / $PVC_SIZE"
echo "  clients   $CLIENTS"
echo "  workloads $WORKLOADS"
echo "  filesize  $FILESIZE   runtime ${RUNTIME}s   nrfiles $NRFILES"
echo

mkdir -p "$(dirname "$RESULTS")"
if [[ ! -f "$RESULTS" ]]; then
  printf 'run_id\tdate\tbackend\tstorage_class\tlayout\tworkload\tclients\tnodes\tfilesize\truntime_s\tioengine\tread_MBps\twrite_MBps\tread_iops\twrite_iops\tlat_ms_p99\tswitch_if\tsw_peak_rx_Mbps\tsw_peak_tx_Mbps\tnote\n' > "$RESULTS"
fi

# ---- Switch-side cross-check ----------------------------------------------
# mktxp metrics live in USER-WORKLOAD monitoring, not platform, so this queries
# prometheus-user-workload-0 rather than prometheus-k8s-0. There is no
# read-only HTTP path to it (the service ports are behind oauth-proxy and the
# API service-proxy is rejected), so this execs into the pod -- a read, but it
# does need exec rights. Fails soft: a missing cross-check must never lose an
# otherwise-good benchmark result.
#
# An exact counter delta over the window the POD reports for its fio run.
# The first version used max_over_time of a rate()[1m] across a guessed window;
# that was wrong twice over -- it reached back into the previous job, and mktxp
# only scrapes every 30s, so a 1m rate has two samples and a 60s burst
# straddling a scrape boundary is averaged with idle time and reads ~25% low.
#
# Both directions are recorded because which one matters depends on the
# workload -- reads show up as traffic FROM the device (the router's rx on that
# port), writes as traffic TO it (tx). Recording both means the row is
# interpretable without knowing which workload produced it.
switch_rate() {   # $1 = rx|tx, $2 = start epoch, $3 = end epoch -> Mb/s
  [[ "$SWITCH_IF" == "-" ]] && return 0
  [[ -n "${2:-}" && -n "${3:-}" ]] || return 0
  local rb="${SWITCH_IF%%/*}" ifn="${SWITCH_IF##*/}" dir="$1" a="$2" b="$3"
  local span=$(( b - a ))
  [[ "$span" -gt 0 ]] || return 0
  # Ceph pool counters for backends no switch port can isolate. Same contract as
  # the mktxp path -- a counter DELTA over the exact fio window, never a rate.
  # rx == bytes read out of the pool, tx == bytes written into it. The pool_id is
  # resolved inside PromQL via ceph_pool_metadata rather than in shell, which
  # avoids a third level of quoting inside an already-quoted python -c.
  if [[ "$rb" == "cephpool" ]]; then
    local metric="ceph_pool_rd_bytes"
    [[ "$dir" == "tx" ]] && metric="ceph_pool_wr_bytes"
    # The @ modifier attaches to a SELECTOR, not to a parenthesised binary
    # expression -- "(expr) @ t" returns an empty vector with no error, which is
    # how this first shipped and silently produced no cross-check at all. Each
    # side carries its own @, and the metadata join resolves pool_id inside
    # PromQL so no third level of shell quoting is needed.
    local j="on(pool_id) group_left ceph_pool_metadata{name=\"${ifn}\"}"
    local cq="${metric} @ ${b} * ${j} @ ${b} - (${metric} @ ${a} * ${j} @ ${a})"
    oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
       wget -qO- --post-data="query=${cq}" 'http://localhost:9090/api/v1/query' 2>/dev/null \
     | python3 -c "
import json,sys
try:
    r=json.load(sys.stdin)['data']['result']
    print('%.1f' % (float(r[0]['value'][1])*8/${span}/1e6) if r else '')
except Exception:
    print('')
" 2>/dev/null
    return 0
  fi
  # increase() over the EXACT fio window, not max_over_time of a rate. This is
  # alignment-free: it is a counter delta across a known interval, so a 30s
  # scrape cadence cannot smear a 60s burst into neighbouring idle time.
  # The extra 30s of span covers one scrape's worth of quantisation.
  local q="increase(mktxp_interface_${dir}_byte_total{routerboard_name=\"${rb}\",name=\"${ifn}\"}[$((span+30))s] @ ${b})*8/${span}/1e6"
  oc -n openshift-user-workload-monitoring exec prometheus-user-workload-0 -c prometheus -- \
     wget -qO- --post-data="query=${q}" 'http://localhost:9090/api/v1/query' 2>/dev/null \
   | python3 -c "
import json,sys
try:
    r=json.load(sys.stdin)['data']['result']
    print('%.1f' % float(r[0]['value'][1]) if r else '')
except Exception:
    print('')
" 2>/dev/null
}

render() {
  local workload="$1" pvc="$2" job="$3"
  sed -e "s|__NAMESPACE__|${NAMESPACE}|g" \
      -e "s|__PVC_NAME__|${pvc}|g" \
      -e "s|__JOB_NAME__|${job}|g" \
      -e "s|__BACKEND__|${BACKEND}|g" \
      -e "s|__STORAGE_CLASS__|${SC}|g" \
      -e "s|__ACCESS_MODE__|${ACCESS_MODE}|g" \
      -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
      -e "s|__WORKLOAD__|${workload}|g" \
      -e "s|__CLIENTS__|${CLIENTS}|g" \
      -e "s|__RUN_ID__|${RUN_ID}|g" \
      -e "s|__FILESIZE__|${FILESIZE}|g" \
      -e "s|__RUNTIME__|${RUNTIME}|g" \
      -e "s|__NRFILES__|${NRFILES}|g" \
      -e "s|__IOENGINE__|${IOENGINE}|g" \
      -e "s|__IMAGE__|${IMAGE}|g" \
      -e "s|__DEADLINE__|${DEADLINE}|g" \
      -e "s|__BARRIER_TIMEOUT__|${BARRIER_TIMEOUT}|g" \
      -e "s|__FILESIZE_BYTES__|$(to_bytes "$FILESIZE")|g" \
      "${HERE}/bench-job.yaml.tpl"
}

PVC_NAME="storage-bench-${BACKEND}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo ">>> DRY RUN — rendered manifest for the first workload, nothing applied"
  render "$(echo "$WORKLOADS" | awk '{print $1}')" "$PVC_NAME" "${RUN_ID}-first" > /tmp/bench-render.yaml
  cat /tmp/bench-render.yaml

  # SHELL-LINT THE POD SCRIPT. kubeconform validates the YAML and is blind to
  # what is inside a block scalar -- which is where every line of this harness's
  # runtime logic lives.
  #
  # HONEST SCOPE: this would NOT have caught the 2026-09-05 breakage that
  # prompted it. A patch inserted a second `sed` where an extra `-e` clause
  # belonged, so the render became `sed -e "..." sed -e "..."` and sed read the
  # word "sed" as an input filename. That is valid shell -- a command with
  # arguments -- so `bash -n` passes it happily. What caught it was the driver's
  # row check, on the first cell, at a cost of three cells rather than an
  # evening. This lint covers a different class (unbalanced quotes, a missing
  # `fi`, a truncated heredoc) which is cheap to exclude and has bitten this file
  # before -- see the column-0 heredoc that silently produced an invalid
  # manifest. Keep both: a syntax check and an outcome check answer different
  # questions, and only the second one knows whether a run produced anything.
  python3 - /tmp/bench-render.yaml > /tmp/bench-podscript.sh <<'PYEOF'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
i = next(n for n, l in enumerate(lines) if l.strip() == "- |")
indent = len(lines[i + 1]) - len(lines[i + 1].lstrip())
out = []
for l in lines[i + 1:]:
    if l.strip() and (len(l) - len(l.lstrip())) < indent:
        break
    out.append(l[indent:])
print("\n".join(out))
PYEOF
  if bash -n /tmp/bench-podscript.sh 2>/tmp/bench-lint.err; then
    echo ">>> ok   pod script passes bash -n ($(wc -l < /tmp/bench-podscript.sh) lines)"
  else
    echo ">>> FAIL pod script is not valid shell:" >&2
    cat /tmp/bench-lint.err >&2
    exit 1
  fi
  exit 0
fi

echo ">>> applying fio job definitions"
oc apply -f "${HERE}/fio-jobs.yaml"

for W in $WORKLOADS; do
  JOB_NAME="${RUN_ID}-${W}"
  echo
  echo "=== $W (clients=$CLIENTS) ==="
  JOB_START=$(date +%s)
  # Check the apply. Previously an invalid manifest was swallowed here and
  # surfaced 20 minutes later as an unexplained "job did not complete", which
  # is how a YAML block-scalar bug went unnoticed through three whole runs.
  if ! render "$W" "$PVC_NAME" "$JOB_NAME" | oc apply -f -; then
    echo "  FAILED TO APPLY the manifest for $W -- not a storage problem." >&2
    echo "  Render it and inspect:  ./run.sh --backend $BACKEND --workload $W --dry-run" >&2
    exit 1
  fi

  # Job pod templates are IMMUTABLE — a second apply over an existing Job is
  # silently rejected. Unique job names per run avoid that; this wait is what
  # actually blocks until the result exists.
  # Wait for EITHER outcome. `--for=condition=complete` alone sits out the full
  # deadline on a Job that has already Failed -- observed 2026-09-05, where a
  # job that died in seconds left the driver blocked for its 4783s deadline.
  # There is no "complete or failed" selector, so poll both.
  END=$(( $(date +%s) + DEADLINE ))
  JOB_OK=0
  while [ "$(date +%s)" -lt "$END" ]; do
    if oc -n "$NAMESPACE" get "job/${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q True; then
      JOB_OK=1; break
    fi
    if oc -n "$NAMESPACE" get "job/${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null | grep -q True; then
      echo "  job FAILED (not a timeout) -- surfacing immediately"
      break
    fi
    sleep 15
  done
  if [ "$JOB_OK" != "1" ]; then
    echo "  job did not complete; recent events:"
    oc -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | grep "$JOB_NAME" | tail -5
    oc -n "$NAMESPACE" logs "job/${JOB_NAME}" --tail=30 || true
    echo "  SKIPPING result for $W"
    # Delete it here too. The failed clients=3 job sat around for 20 minutes
    # because only the success path cleaned up, which made it harder to see
    # which run had actually failed.
    oc -n "$NAMESPACE" delete "job/${JOB_NAME}" --wait=false >/dev/null 2>&1 || true
    continue
  fi

  NODES="$(oc -n "$NAMESPACE" get pods -l "job-name=${JOB_NAME}" \
            -o jsonpath='{range .items[*]}{.spec.nodeName}{","}{end}' 2>/dev/null | sed 's/,$//')"

  LOGS="$(for POD in $(oc -n "$NAMESPACE" get pods -l "job-name=${JOB_NAME}" -o name 2>/dev/null); do
            oc -n "$NAMESPACE" logs "$POD" 2>/dev/null; done)"

  # Read the fio window the POD reported, so the counter delta covers exactly
  # the measured run and nothing else.
  # awk, NOT `grep | awk`. Under `set -euo pipefail` a grep that matches nothing
  # exits 1, pipefail propagates it, and set -e kills run.sh AT THIS LINE --
  # before the result is parsed and before the job is deleted. That is exactly
  # what happened on 2026-09-05: twelve jobs ran to Completion, produced no
  # rows, were never cleaned up, and the driver advanced to the next cell as if
  # nothing had gone wrong. Silent, and indistinguishable from success.
  # awk exits 0 whether or not it matches.
  FIO_A=$(echo "$LOGS" | awk '/FIO_START_EPOCH/{print $3; exit}')
  FIO_B=$(echo "$LOGS" | awk '/FIO_END_EPOCH/{print $3; exit}')
  SW_RX="$(switch_rate rx "${FIO_A:-}" "${FIO_B:-}")"
  SW_TX="$(switch_rate tx "${FIO_A:-}" "${FIO_B:-}")"
  if [[ -n "$SW_RX$SW_TX" ]]; then
    echo "  switch ${SWITCH_IF}: rx ${SW_RX:-?} Mb/s, tx ${SW_TX:-?} Mb/s (fio window $(( ${FIO_B:-0} - ${FIO_A:-0} ))s)"
  fi

  # One log stream per client pod; the parser aggregates across them, which is
  # what "3 clients did X MB/s" has to mean.
  echo "$LOGS" | python3 "${HERE}/parse-results.py" \
        --run-id "$RUN_ID" --backend "$BACKEND" --storage-class "$SC" \
        --layout "$LAYOUT" --workload "$W" --clients "$CLIENTS" \
        --nodes "$NODES" --filesize "$FILESIZE" --runtime "$RUNTIME" \
        --ioengine "$IOENGINE" --results "$RESULTS" \
        --switch-if "$SWITCH_IF" --switch-rx-mbps "${SW_RX:-}" --switch-tx-mbps "${SW_TX:-}"

  oc -n "$NAMESPACE" delete "job/${JOB_NAME}" --wait=false >/dev/null 2>&1 || true
done

echo
echo ">>> done. Results appended to ${RESULTS#$REPO_ROOT/}"
echo ">>> the benchmark PVC ${PVC_NAME} is RETAINED for reuse across runs."
echo "    Delete it when finished:  oc -n ${NAMESPACE} delete pvc ${PVC_NAME}"
column -t -s $'\t' "$RESULTS" | tail -n $(( $(echo "$WORKLOADS" | wc -w) + 1 ))
