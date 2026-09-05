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
# 20000 x 4 jobs = 80,000 files, ~5 GiB per client.
#
# RAISED FROM 2000 (= 500 MiB) because at that size the whole corpus fits in
# every backend's cache -- the same trap min_filesize fixes for the big-file
# workloads, which does NOT protect these: they ignore BENCH_FILESIZE and size
# themselves from nrfiles x 64k.
#
# BE HONEST ABOUT WHAT THIS STILL IS: 5 GiB exceeds the DS418's 2 GB RAM but
# NOT TrueNAS's 31.3 GiB ARC, so smallfile-* measures the METADATA PATH against
# a partly-warm cache, not cold storage. That is deliberate -- an *arr library
# scan really does stat files the NAS has been serving, so warm metadata is the
# realistic shape -- but it means these numbers are NOT comparable to the
# cache-defeating seq/rand figures and must not be read as "storage speed".
# Defeating a 31 GiB ARC with 64k files needs ~512,000 of them, which is
# 500k+ synchronous NFS round trips and hours of setup, for a question nobody
# has asked yet.
NRFILES="${BENCH_NRFILES:-20000}"
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
# PVC is 400Gi because a 3-client run at 64G lays out 192 GiB. NFS does not
# enforce the request, but CephFS does -- a 100Gi PVC would have failed there
# partway through the third client's layout, ~20 minutes in.
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
# cephfs-hdd is "-" on purpose: its traffic is node-to-node across the backnet,
# so it appears on three ports at once and each byte is counted twice (once
# leaving the sender, once arriving at the reader). There is no single port
# whose counter means "CephFS throughput".
BACKENDS_TABLE="\
cephfs-hdd|cephfs-hdd|ReadWriteMany|400Gi|6|-|CephFS EC 2+1 across 3 HDD OSDs (1/node), 10G backnet
nfs-truenas-bench|nfs-truenas-bench|ReadWriteMany|400Gi|6|home-switch/TrueNAS|TrueNAS RAIDZ2 6-wide HGST 4TB over NFS, 10G backnet
nfs-csi|nfs-csi|ReadWriteMany|400Gi|6|home-router/nas|Synology DS418 SHR (~RAID5 1-drive tol) 4x3.6TB over NFS, 1G frontnet"

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
to_bytes() {
  local v="$1" n u
  n="${v%%[!0-9]*}"
  u="${v#$n}"
  case "$u" in
    ""|B)        echo $(( n )) ;;
    K|KiB|k)     echo $(( n * 1024 )) ;;
    M|MiB|m)     echo $(( n * 1024 * 1024 )) ;;
    G|GiB|g)     echo $(( n * 1024 * 1024 * 1024 )) ;;
    T|TiB|t)     echo $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
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
# 50 MB/s is a deliberately pessimistic layout rate (the DS418 writes at ~120
# MB/s; the slowest plausible backend is what has to fit).
LAYOUT_BYTES=$(( $(to_bytes "$FILESIZE") * CLIENTS ))
LAYOUT_SECS=$(( LAYOUT_BYTES / 50000000 ))
DEADLINE=$(( LAYOUT_SECS + RUNTIME + 600 ))
echo "  info deadline ${DEADLINE}s (layout of $(human "$LAYOUT_BYTES") allowed ${LAYOUT_SECS}s at a pessimistic 50 MB/s)"

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
  printf 'run_id\tdate\tbackend\tstorage_class\tlayout\tworkload\tclients\tnodes\tfilesize\truntime_s\tioengine\tread_MBps\twrite_MBps\tread_iops\twrite_iops\tlat_ms_p99\tswitch_if\tsw_peak_rx_Mbps\tsw_peak_tx_Mbps\n' > "$RESULTS"
fi

# ---- Switch-side cross-check ----------------------------------------------
# mktxp metrics live in USER-WORKLOAD monitoring, not platform, so this queries
# prometheus-user-workload-0 rather than prometheus-k8s-0. There is no
# read-only HTTP path to it (the service ports are behind oauth-proxy and the
# API service-proxy is rejected), so this execs into the pod -- a read, but it
# does need exec rights. Fails soft: a missing cross-check must never lose an
# otherwise-good benchmark result.
#
# max_over_time of the 1m rate, not an average: the job window includes fio's
# layout phase and any ramp, and what we want to compare against fio's number
# is the SUSTAINED PLATEAU, which is what the max of a smoothed rate finds.
#
# Both directions are recorded because which one matters depends on the
# workload -- reads show up as traffic FROM the device (the router's rx on that
# port), writes as traffic TO it (tx). Recording both means the row is
# interpretable without knowing which workload produced it.
switch_rate() {   # $1 = rx|tx, $2 = window seconds -> Mb/s, empty on failure
  [[ "$SWITCH_IF" == "-" ]] && return 0
  local rb="${SWITCH_IF%%/*}" ifn="${SWITCH_IF##*/}" dir="$1" win="$2"
  local q="max_over_time(rate(mktxp_interface_${dir}_byte_total{routerboard_name=\"${rb}\",name=\"${ifn}\"}[1m])[${win}s:30s])*8/1e6"
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
      -e "s|__FILESIZE_BYTES__|$(to_bytes "$FILESIZE")|g" \
      "${HERE}/bench-job.yaml.tpl"
}

PVC_NAME="storage-bench-${BACKEND}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo ">>> DRY RUN — rendered manifest for the first workload, nothing applied"
  render "$(echo "$WORKLOADS" | awk '{print $1}')" "$PVC_NAME" "${RUN_ID}-first"
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

  WIN=$(( $(date +%s) - JOB_START + 60 ))
  SW_RX="$(switch_rate rx "$WIN")"
  SW_TX="$(switch_rate tx "$WIN")"
  if [[ -n "$SW_RX$SW_TX" ]]; then
    echo "  switch ${SWITCH_IF}: peak rx ${SW_RX:-?} Mb/s, peak tx ${SW_TX:-?} Mb/s (over ${WIN}s)"
  fi

  # One log stream per client pod; the parser aggregates across them, which is
  # what "3 clients did X MB/s" has to mean.
  for POD in $(oc -n "$NAMESPACE" get pods -l "job-name=${JOB_NAME}" -o name 2>/dev/null); do
    oc -n "$NAMESPACE" logs "$POD" 2>/dev/null
  done | python3 "${HERE}/parse-results.py" \
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
