#!/usr/bin/env bash
# Operator-run per-OSD latency capture for the Rook/Ceph upgrade series (needs `oc exec`, so the operator
# runs it, never an agent). Read-only: it queries Prometheus and appends rows to a TSV.
#
#   bash tests/rook-ceph-upgrade/metrics/ceph-latency.sh --end 2026-11-06T08:00:00Z --window 24h --label baseline
#   bash tests/rook-ceph-upgrade/metrics/ceph-latency.sh --end 2026-11-06T08:00:00Z --window 24h --label baseline --dry-run
#
# --end     RFC3339 instant the window ends at (the query is evaluated there)
# --window  Prometheus duration, e.g. 24h
# --label   stage label written in the first column ([A-Za-z0-9._-]+)
# --dry-run print the queries and exit; no oc call
#
# Appends to data/ceph-osd-latency.tsv (created with a header on the first run):
#   label  window_end  osd  metric  avg  p99
#
# p99 is "-" on every row: all of these are per-OSD latency counters (_sum/_count) or gauges and carry no
# histogram buckets, so there is no honest p99. avg for the *_lat_ms rows is the window average:
# increase(_sum) / increase(_count) for the counters (seconds, scaled to ms here), avg_over_time for the
# gauges. slow_ops_max is the highest slow-op count the daemon reported at any scrape in the window.
#
# Metric names come only from metric-names.txt (captured from the exporter and mgr endpoints on 2026-11-03);
# the script refuses to run a query whose metric is not listed there.
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
NAMES="$HERE/metric-names.txt"
OUT="$ROOT/data/ceph-osd-latency.tsv"

END="" WINDOW="" LABEL="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --end)     [ $# -ge 2 ] || { echo "--end needs a value" >&2; exit 2; }; END="$2"; shift 2 ;;
    --window)  [ $# -ge 2 ] || { echo "--window needs a value" >&2; exit 2; }; WINDOW="$2"; shift 2 ;;
    --label)   [ $# -ge 2 ] || { echo "--label needs a value" >&2; exit 2; }; LABEL="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$END" ] && [ -n "$WINDOW" ] && [ -n "$LABEL" ] || { echo "usage: $0 --end <RFC3339> --window <dur> --label <stage> [--dry-run]" >&2; exit 2; }
case "$LABEL" in *[!A-Za-z0-9._-]*) echo "label must match [A-Za-z0-9._-]+" >&2; exit 2 ;; esac
printf '%s' "$END" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' \
  || { echo "--end must be RFC3339, e.g. 2026-11-03T00:00:00Z" >&2; exit 2; }
printf '%s' "$WINDOW" | grep -Eq '^[0-9]+[smhdw]$' || { echo "--window must look like 24h, 90m, 7d" >&2; exit 2; }
[ -r "$NAMES" ] || { echo "missing $NAMES" >&2; exit 2; }

# Queries. One-to-one vector matching on the full label set keeps every series per OSD without naming a label,
# so the per-OSD split comes from the series labels in the result.
WIN="$WINDOW"
QNAMES="op_r_latency_ms op_w_latency_ms commit_latency_ms apply_latency_ms kv_commit_lat_ms slow_ops_max"
query_for() {
  case "$1" in
    op_r_latency_ms)   echo "increase(ceph_osd_op_r_latency_sum[$WIN]) / increase(ceph_osd_op_r_latency_count[$WIN]) * 1000" ;;
    op_w_latency_ms)   echo "increase(ceph_osd_op_w_latency_sum[$WIN]) / increase(ceph_osd_op_w_latency_count[$WIN]) * 1000" ;;
    commit_latency_ms) echo "avg_over_time(ceph_osd_commit_latency_ms[$WIN])" ;;
    apply_latency_ms)  echo "avg_over_time(ceph_osd_apply_latency_ms[$WIN])" ;;
    kv_commit_lat_ms)  echo "increase(ceph_bluestore_kv_commit_lat_sum[$WIN]) / increase(ceph_bluestore_kv_commit_lat_count[$WIN]) * 1000" ;;
    slow_ops_max)      echo "max_over_time(ceph_daemon_health_metrics{type=\"SLOW_OPS\"}[$WIN])" ;;
  esac
}

# Every metric a query mentions must be in metric-names.txt.
for name in $QNAMES; do
  for metric in $(query_for "$name" | grep -o 'ceph_[a-z_]*'); do
    grep -qx "$metric" "$NAMES" || { echo "metric $metric (query $name) is not in metric-names.txt" >&2; exit 2; }
  done
done

if [ "$DRY" = 1 ]; then
  echo "# evaluated at $END, window $WINDOW, label $LABEL"
  for name in $QNAMES; do printf '%s\t%s\n' "$name" "$(query_for "$name")"; done
  exit 0
fi

command -v oc >/dev/null 2>&1 || { echo "oc not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || printf 'label\twindow_end\tosd\tmetric\tavg\tp99\n' > "$OUT"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
FAILED=0
for name in $QNAMES; do
  q="$(query_for "$name")"
  enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlencode({"query": sys.argv[1], "time": sys.argv[2]}))' "$q" "$END")"
  resp="$(oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
            wget -qO- --post-data="$enc" 'http://localhost:9090/api/v1/query')" || { echo "FAILED: $name (oc exec)" >&2; FAILED=1; continue; }
  printf '%s' "$resp" | python3 -c '
import json, sys
label, end, metric = sys.argv[1:4]
try:
    d = json.load(sys.stdin)
    if d.get("status") != "success":
        raise ValueError(d.get("error", "status " + str(d.get("status"))))
    per = {}
    for s in d["data"]["result"]:
        osd = s["metric"].get("ceph_daemon", "")
        if not osd.startswith("osd."):
            continue
        v = float(s["value"][1])
        if v != v:   # NaN: no samples or zero ops in the window
            continue
        per.setdefault(osd, []).append(v)
except Exception as e:
    print("PARSE-FAILED %s: %s" % (metric, e), file=sys.stderr)
    sys.exit(1)
for osd in sorted(per):
    vals = per[osd]
    print("\t".join([label, end, osd, metric, "%.4f" % (sum(vals) / len(vals)), "-"]))
' "$LABEL" "$END" "$name" >> "$TMP" || FAILED=1
done

if [ "$FAILED" != 0 ]; then
  echo "At least one query failed; nothing appended to $OUT" >&2
  exit 1
fi
if [ ! -s "$TMP" ]; then
  echo "No OSD rows returned (empty window or wrong --end?); nothing appended" >&2
  exit 1
fi
cat "$TMP" >> "$OUT"
echo "appended $(wc -l < "$TMP" | tr -d ' ') rows to ${OUT#"$ROOT"/}"
cat "$TMP"
