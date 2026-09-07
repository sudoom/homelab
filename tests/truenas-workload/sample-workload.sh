#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TrueNAS workload characterisation sampler. READ-ONLY.
#
# WHY THIS EXISTS: tests/storage-benchmark/ measures synthetic patterns very
# carefully and tells you nothing about what the apps actually do. Every tuning
# lever for this NAS -- SLOG, recordsize, special vdev, more RAM -- is chosen by
# the shape of the REAL workload, and choosing without that data is how eight
# throughput figures in this repo ended up wrong. This samples the real thing.
#
# THE DECISION IT EXISTS TO SETTLE, stated before the data arrives so it cannot
# be rationalised afterwards:
#   sync writes < ~5% of write bytes  -> NO SLOG, close the question for good
#   request sizes cluster >= 128k     -> recordsize is right, stop tuning
#   heavy small-file tail on immich   -> split thumbnails to a smaller recordsize
#   ARC hit stays > 95% under load    -> no more RAM, no L2ARC, ever
#
# All four are read off the outputs below without further judgement calls.
#
# INSTRUMENTS, and why each:
#   zpool iostat -r   request-size histogram SPLIT BY sync_write vs async_write.
#                     This is the SLOG answer directly -- no inference needed.
#   zpool iostat -w   latency histogram, for where the tail actually is.
#   objset-* kstats   PER-DATASET reads/writes/bytes. Each carries dataset_name,
#                     so "which dataset is hot" is measured, not guessed.
#   zil kstat         commit counts, cross-checks the sync figure independently.
#   arcstats          confirms the 97.8% idle hit ratio holds under real load.
#
# COUNTERS ARE CUMULATIVE AND EMITTED RAW. Deltas are computed at analysis time,
# deliberately: a sampler that pre-computes rates cannot be re-analysed over a
# different window, and every rate error in this repo's history came from
# dividing at capture time instead of subtracting two counters.
#
# Output goes to /var/tmp (boot-pool), NOT to tank -- so the sampler does not
# appear in the pool statistics it is measuring.
# ---------------------------------------------------------------------------
set -u
OUT="${1:-/var/tmp/zfs-workload}"
INTERVAL="${2:-60}"
MAX_HOURS="${3:-36}"
POOL=tank

mkdir -p "$OUT"
DS="$OUT/datasets.tsv"; GL="$OUT/global.tsv"
RQ="$OUT/reqsize.txt";  LT="$OUT/latency.txt"

[ -s "$DS" ] || printf 'epoch\tdataset\twrites\tnwritten\treads\tnread\tnunlinks\n' > "$DS"
[ -s "$GL" ] || printf 'epoch\tzil_commit\tzil_writer\tzil_error\tarc_hits\tarc_misses\tarc_size\tarc_c\n' > "$GL"

END=$(( $(date +%s) + MAX_HOURS * 3600 ))
echo "sampler started $(date -Is), interval ${INTERVAL}s, until $(date -Is -d @${END} 2>/dev/null || echo "+${MAX_HOURS}h")" >> "$OUT/run.log"

while [ "$(date +%s)" -lt "$END" ]; do
  T=$(date +%s)

  # --- per-dataset counters -------------------------------------------------
  for f in /proc/spl/kstat/zfs/${POOL}/objset-0x*; do
    [ -r "$f" ] || continue
    awk -v t="$T" '
      /^dataset_name/ {n=$3}
      /^writes/       {w=$3}
      /^nwritten/     {nw=$3}
      /^reads/        {r=$3}
      /^nread/        {nr=$3}
      /^nunlinks/     {nu=$3}
      END { if (n != "") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", t, n, w, nw, r, nr, nu }
    ' "$f" >> "$DS"
  done

  # --- global: ZIL + ARC ----------------------------------------------------
  ZC=$(awk '/^zil_commit_count/{print $3}'        /proc/spl/kstat/zfs/zil 2>/dev/null)
  ZW=$(awk '/^zil_commit_writer_count/{print $3}' /proc/spl/kstat/zfs/zil 2>/dev/null)
  ZE=$(awk '/^zil_commit_error_count/{print $3}'  /proc/spl/kstat/zfs/zil 2>/dev/null)
  AH=$(awk '/^hits /{print $3}'                   /proc/spl/kstat/zfs/arcstats 2>/dev/null)
  AM=$(awk '/^misses /{print $3}'                 /proc/spl/kstat/zfs/arcstats 2>/dev/null)
  AS=$(awk '/^size /{print $3}'                   /proc/spl/kstat/zfs/arcstats 2>/dev/null)
  AC=$(awk '/^c /{print $3}'                      /proc/spl/kstat/zfs/arcstats 2>/dev/null)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$T" "${ZC:-}" "${ZW:-}" "${ZE:-}" "${AH:-}" "${AM:-}" "${AS:-}" "${AC:-}" >> "$GL"

  # --- histograms: interval-only (-y), so each block is this window alone ----
  { echo "### epoch ${T}"; zpool iostat -ry "$POOL" 1 1 2>/dev/null; } >> "$RQ"
  { echo "### epoch ${T}"; zpool iostat -wy "$POOL" 1 1 2>/dev/null; } >> "$LT"

  sleep "$INTERVAL"
done
echo "sampler finished $(date -Is)" >> "$OUT/run.log"
