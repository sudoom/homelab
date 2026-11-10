#!/usr/bin/env bash
# Readonly go/no-go gates for the OKD 4.22 -> 5.0 hop (runbook README.md, section 1.3).
#
#   bash tests/okd-5.0-upgrade/gates.sh [--defrag-off --frag-file FILE] [--fixture-dir DIR]
#
# One `GATE PASS|FAIL <name> <detail>` line per gate, then `GATES PASS` or `GATES FAIL (<n> failed)`.
# `GATE INFO` lines are context and never fail. Exit 0 only if every gate passed. A failed or empty read is a FAIL.
# Reads only, with the readonly kubeconfig (RO_KUBECONFIG overrides the path): `oc get` and `oc get --raw`
# (kubelet stats summary, Ceph mgr metrics). No exec, no Secret read, no Prometheus.
#
#   --defrag-off     the etcd defrag switch must be set: DefragControllerDisabled=True on etcd/cluster, ConfigMap
#                    openshift-etcd-operator/etcd-disable-defrag present, and every member under 45% fragmentation.
#   --frag-file FILE the fragmentation read: the output of the README's OPERATOR PromQL line (`<member><TAB><percent>`,
#                    one row per member), at most 60 minutes old. Required with --defrag-off (this script cannot read
#                    Prometheus); without --defrag-off it is printed as INFO.
#   --fixture-dir D  test only: a read named <name> comes from D/<name>.json when that file exists.
set -u -o pipefail

usage() { sed -n '2,16p' "$0" >&2; exit 2; }
DEFRAG_OFF=0; FRAG_FILE=""; FIXTURE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --defrag-off) DEFRAG_OFF=1 ;;
    --frag-file) [ $# -ge 2 ] || usage; FRAG_FILE="$2"; shift ;;
    --fixture-dir) [ $# -ge 2 ] || usage; FIXTURE_DIR="$2"; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done
command -v oc >/dev/null 2>&1 || { echo "oc not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
export KUBECONFIG="${RO_KUBECONFIG:-$HOME/.kube/config-readonly}"

NODES_EXPECTED=3
WINDOW_MIN=150            # the hop plus checks: no part of the next 150 min may fall on Monday 19:00-23:00Z
ZOT_MIN_FREE=10737418240  # 10 GiB
ROOTFS_MAX_PCT=60
CNPG_BACKUP_MAX_H=26
FRAG_MAX_PCT=45
FRAG_MAX_AGE_S=3600
# Ceph's standing state: BLUESTORE_SLOW_OP_ALERT plus the four AUTH_INSECURE_* checks muted in
# components/storage/rook-ceph-cluster/values.yaml (healthCheck.muteHealthWarning).
CEPH_ALLOWED='["BLUESTORE_SLOW_OP_ALERT","AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE","AUTH_INSECURE_CLIENT_KEY_TYPE","AUTH_INSECURE_KEYS_ALLOWED","AUTH_INSECURE_KEYS_CREATABLE"]'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/okd50-gates.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT

FAILS=0
gate() { # gate PASS|FAIL|INFO <name> <detail>
  [ "$1" = FAIL ] && FAILS=$((FAILS + 1))
  echo "GATE $1 $2 ${3:-<empty>}"
}

# kget <name> <oc get args...>: JSON into $TMP/<name>.json, or no file on a failed or non-JSON read.
# with_timeout <seconds> <cmd...>: run cmd, kill it after <seconds> (bash 3.2 has no timeout(1)). Used for the Ceph mgr
# metrics read: on a --raw read kubectl sends --request-timeout as a ?timeout= query, and the proxied mgr answers 404.
with_timeout() {
  local s="$1" pid n=0 rc; shift
  "$@" & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge $((s * 5)) ]; then kill "$pid" 2>/dev/null; break; fi
    sleep 0.2; n=$((n + 1))
  done
  { wait "$pid"; } 2>/dev/null; rc=$?
  return "$rc"
}
kget() {
  local name="$1" f; shift
  f="$TMP/$name.json"
  if [ -n "$FIXTURE_DIR" ] && [ -f "$FIXTURE_DIR/$name.json" ]; then cp "$FIXTURE_DIR/$name.json" "$f"; return 0; fi
  if oc get "$@" --request-timeout=30s -o json > "$f" 2>/dev/null && jq -e . "$f" >/dev/null 2>&1; then return 0; fi
  rm -f "$f"; return 1
}
# kraw <name> <api path>: JSON from `oc get --raw` into $TMP/<name>.json.
kraw() {
  local name="$1" api="$2" f
  f="$TMP/$name.json"
  if [ -n "$FIXTURE_DIR" ] && [ -f "$FIXTURE_DIR/$name.json" ]; then cp "$FIXTURE_DIR/$name.json" "$f"; return 0; fi
  if oc get --raw "$api" --request-timeout=30s > "$f" 2>/dev/null && jq -e . "$f" >/dev/null 2>&1; then return 0; fi
  rm -f "$f"; return 1
}
# kmgr <name>: Ceph mgr Prometheus metrics folded into {"up","in","pg","active","clean"}.
kmgr() {
  local name="$1" f out
  f="$TMP/$name.json"
  if [ -n "$FIXTURE_DIR" ] && [ -f "$FIXTURE_DIR/$name.json" ]; then cp "$FIXTURE_DIR/$name.json" "$f"; return 0; fi
  out="$(with_timeout 30 oc get --raw /api/v1/namespaces/rook-ceph/services/http:rook-ceph-mgr:9283/proxy/metrics 2>/dev/null | awk '
    /^ceph_osd_up\{/ {u+=$NF} /^ceph_osd_in\{/ {i+=$NF}
    /^ceph_pg_total\{/ {t+=$NF; seen=1} /^ceph_pg_active\{/ {a+=$NF} /^ceph_pg_clean\{/ {c+=$NF}
    END {if (seen) printf "{\"up\":%d,\"in\":%d,\"pg\":%d,\"active\":%d,\"clean\":%d}\n", u, i, t, a, c}')"
  if [ -n "$out" ]; then printf '%s\n' "$out" > "$f"; return 0; fi
  return 1
}

JQDEFS='
def cond($t): (((.status.conditions // []) | map(select(.type == $t)) | .[0].status) // "Unknown");
def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def ageh: (((now - ts) / 360) | floor) / 10;
def opver: ([.status.versions[]? | select(.name == "operator") | .version] | first) // "";
def short: split(".")[0];
'
# jall <prog> <name>...: run <prog> over {<name>: <doc>, ...}; prints its output, or nothing on a missing read.
jall() {
  local prog="$1" n files=""; shift
  for n in "$@"; do [ -f "$TMP/$n.json" ] || return 1; files="$files $TMP/$n.json"; done
  # shellcheck disable=SC2086  # $files is a space-separated list of mktemp paths
  jq -n -r --arg off "$DEFRAG_OFF" --argjson cephok "$CEPH_ALLOWED" \
    "$JQDEFS reduce inputs as \$x ({}; . + {(input_filename | split(\"/\") | last | rtrimstr(\".json\")): \$x}) | $prog" $files
}
# run_gate <gate> <prog printing "PASS|FAIL|INFO <detail>"> <name>...
run_gate() {
  local g="$1" prog="$2" n res; shift 2
  for n in "$@"; do [ -f "$TMP/$n.json" ] || { gate FAIL "$g" "read failed: $n"; return; }; done
  res="$(jall "$prog" "$@" 2>&1)" || res="jq error: $(printf '%s' "$res" | head -1)"
  case "$res" in
    "PASS "*) gate PASS "$g" "${res#PASS }" ;;
    "FAIL "*) gate FAIL "$g" "${res#FAIL }" ;;
    "INFO "*) gate INFO "$g" "${res#INFO }" ;;
    *) gate FAIL "$g" "unexpected result: $(printf '%s' "$res" | head -1)" ;;
  esac
}

# ---- reads -----------------------------------------------------------------------------------------------------
kget nodes nodes
kget cv clusterversion version
kget co clusteroperators
kget mcp machineconfigpools
kget apps -n openshift-gitops applications.argoproj.io
kget subs subscriptions.operators.coreos.com -A
kget installplans installplans.operators.coreos.com -A
kget csvs clusterserviceversions.operators.coreos.com -A
kget cnpg clusters.postgresql.cnpg.io -A
kget cnpgbackups backups.postgresql.cnpg.io -A
kget ceph -n rook-ceph cephclusters.ceph.rook.io
kmgr mgr
kget pdb poddisruptionbudgets -A
kget okdbuildjobs -n okd-build jobs
kget okdbuildpods -n okd-build pods
kget zotpod -n zot pods --field-selector metadata.name=zot-0
kget admingates -n openshift-config-managed configmap admin-gates
kget adminacks -n openshift-config configmap admin-acks
kget oadpbackups -n openshift-adp backups.velero.io
kget oadpschedules -n openshift-adp schedules.velero.io
kget etcd etcd.operator.openshift.io cluster
kget etcdpods -n openshift-etcd pods -l app=etcd
kget defragcm -n openshift-etcd-operator configmaps --field-selector metadata.name=etcd-disable-defrag
kget certs certificates.cert-manager.io -A
STATS_NAMES=""
if [ -f "$TMP/nodes.json" ]; then
  for n in $(jq -r '.items[].metadata.name' "$TMP/nodes.json"); do
    s="stats_${n%%.*}"
    kraw "$s" "/api/v1/nodes/$n/proxy/stats/summary"
    STATS_NAMES="$STATS_NAMES $s"
  done
fi

# ---- cluster -----------------------------------------------------------------------------------------------------
run_gate nodes '
  .nodes.items as $n
  | [$n[] | select(cond("Ready") != "True") | .metadata.name | short] as $nr
  | [$n[] | select(.spec.unschedulable == true) | .metadata.name | short] as $cd
  | if ($n | length) == '"$NODES_EXPECTED"' and ($nr | length) == 0 and ($cd | length) == 0
    then "PASS \($n | length)/\($n | length) Ready, none cordoned, kubelet \([$n[].status.nodeInfo.kubeletVersion] | unique | join(","))"
    else "FAIL nodes=\($n | length) (expect '"$NODES_EXPECTED"') notReady=[\($nr | join(","))] cordoned=[\($cd | join(","))]" end' nodes

run_gate clusterversion '
  .cv | cond("Available") as $a | cond("Progressing") as $p | cond("Failing") as $f
  | if $a == "True" and $p == "False" and $f == "False"
    then "PASS \(.status.desired.version) Available=True Progressing=False Failing=False"
    else "FAIL \(.status.desired.version) Available=\($a) Progressing=\($p) Failing=\($f)" end' cv

run_gate clusteroperators '
  .co.items as $c
  | [$c[] | select(cond("Available") != "True" or cond("Progressing") != "False" or cond("Degraded") != "False")
      | "\(.metadata.name)(Available=\(cond("Available")),Progressing=\(cond("Progressing")),Degraded=\(cond("Degraded")))"] as $bad
  | if ($c | length) > 0 and ($bad | length) == 0
    then "PASS \($c | length)/\($c | length) True/False/False"
    else "FAIL \($bad | length) of \($c | length) off True/False/False: \($bad | join(" "))" end' co

run_gate upgradeable '
  [.co.items[] | select(cond("Upgradeable") == "False") | .metadata.name] as $b
  | (.cv | cond("Upgradeable")) as $u
  | if ($b | length) == 0 and $u != "False"
    then "PASS no Upgradeable=False (ClusterVersion Upgradeable=\($u))"
    else "FAIL Upgradeable=False on [\($b | join(","))], ClusterVersion Upgradeable=\($u)" end' co cv

run_gate machineconfigpools '
  .mcp.items as $p
  | [$p[] | select(.spec.paused == true or cond("Updated") != "True" or cond("Updating") == "True" or cond("Degraded") == "True"
        or .status.updatedMachineCount != .status.machineCount or .status.configuration.name != .spec.configuration.name)
      | "\(.metadata.name)(paused=\(.spec.paused // false),Updated=\(cond("Updated")),Degraded=\(cond("Degraded")),\(.status.updatedMachineCount)/\(.status.machineCount))"] as $bad
  | if ($p | length) > 0 and ($bad | length) == 0
    then "PASS " + ([$p[] | "\(.metadata.name) \(.status.updatedMachineCount)/\(.status.machineCount) updated, not paused"] | join(", "))
    else "FAIL \($bad | join(" "))" end' mcp

run_gate argocd-apps '
  .apps.items as $a
  | [$a[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
      | "\(.metadata.name)=\(.status.sync.status)/\(.status.health.status)"] as $bad
  | if ($a | length) > 0 and ($bad | length) == 0
    then "PASS \($a | length)/\($a | length) Synced/Healthy"
    else "FAIL \($bad | length) of \($a | length): \($bad | join(" "))" end' apps

# ---- OLM -----------------------------------------------------------------------------------------------------------
run_gate subscriptions-manual '
  .subs.items as $s
  | [$s[] | select((.spec.installPlanApproval // "Automatic") != "Manual")
      | "\(.metadata.namespace)/\(.metadata.name)=\(.spec.installPlanApproval // "Automatic(unset)")"] as $bad
  | if ($s | length) > 0 and ($bad | length) == 0
    then "PASS \($s | length)/\($s | length) installPlanApproval=Manual"
    else "FAIL not Manual: \($bad | join(" "))" end' subs

run_gate installplans '
  .installplans.items as $i
  | [$i[] | select(.spec.approved == true and .status.phase != "Complete") | "\(.metadata.namespace)/\(.metadata.name)=\(.status.phase)"] as $bad
  | ([$i[] | select(.spec.approved != true)] | length) as $pend
  | if ($bad | length) == 0
    then "PASS no approved InstallPlan short of Complete (\($i | length) total, \($pend) awaiting approval, see INFO)"
    else "FAIL approved but not Complete: \($bad | join(" "))" end' installplans
if [ -f "$TMP/installplans.json" ]; then
  jall '.installplans.items[] | select(.spec.approved != true)
    | "\(.metadata.namespace)/\(.metadata.name) \(.spec.clusterServiceVersionNames | join(",")) phase=\(.status.phase) created=\(.metadata.creationTimestamp) (normal on Manual; approve nothing during the window)"' installplans \
    | while IFS= read -r l; do gate INFO installplan-awaiting-approval "$l"; done
fi

run_gate csvs '
  [.csvs.items[] | select(.metadata.labels["olm.copiedFrom"] == null)] as $c
  | [$c[] | select(.status.phase != "Succeeded") | "\(.metadata.namespace)/\(.metadata.name)=\(.status.phase)"] as $bad
  | if ($c | length) > 0 and ($bad | length) == 0
    then "PASS \($c | length)/\($c | length) Succeeded"
    else "FAIL \($bad | join(" "))" end' csvs

# ---- workloads and storage -----------------------------------------------------------------------------------------
run_gate cnpg '
  .cnpg.items as $c
  | [$c[] | "\(.metadata.namespace)/\(.metadata.name) \(.status.readyInstances // 0)/\(.spec.instances) archiving=\(cond("ContinuousArchiving"))"] as $all
  | [$c[] | select(.spec.instances != 2 or (.status.readyInstances // 0) != 2 or cond("ContinuousArchiving") != "True")] as $bad
  | if ($c | length) == 3 and ($bad | length) == 0
    then "PASS \($all | join(", "))"
    else "FAIL \($c | length) clusters (expect 3, each 2/2 archiving=True): \($all | join(", "))" end' cnpg

run_gate cnpg-backups '
  . as $d | now as $now
  | [$d.cnpg.items[] | .metadata.namespace as $ns | .metadata.name as $cl
      | ([$d.cnpgbackups.items[] | select(.metadata.namespace == $ns and .spec.cluster.name == $cl and .status.phase == "completed" and .status.stoppedAt != null)]
         | sort_by(.status.stoppedAt) | last) as $b
      | {cl: $cl, name: ($b.metadata.name // "none"), age: (if $b then ($b.status.stoppedAt | ageh) else null end)}] as $r
  | [$r[] | select(.age == null or .age >= '"$CNPG_BACKUP_MAX_H"')] as $bad
  | ($r | map("\(.cl) \(.name) \(if .age == null then "none" else "\(.age)h" end)") | join(", ")) as $txt
  | if ($r | length) > 0 and ($bad | length) == 0 then "PASS newest completed: \($txt) (limit '"$CNPG_BACKUP_MAX_H"'h)"
    else "FAIL newest completed: \($txt) (limit '"$CNPG_BACKUP_MAX_H"'h)" end' cnpg cnpgbackups

run_gate oadp-backup '
  (.oadpbackups.items | sort_by(.status.startTimestamp // .metadata.creationTimestamp) | last) as $l
  | if $l == null then "FAIL no backups.velero.io in openshift-adp"
    elif $l.status.phase == "Completed"
    then "PASS newest \($l.metadata.name) Completed \($l.status.completionTimestamp), \($l.status.completionTimestamp | ageh)h ago"
    else "FAIL newest \($l.metadata.name) phase=\($l.status.phase) started \($l.status.startTimestamp)" end' oadpbackups
if [ -f "$TMP/oadpschedules.json" ]; then
  jall '.oadpschedules.items[] | "\(.metadata.name) \(.spec.schedule) paused=\(.spec.paused // false) lastBackup=\(.status.lastBackup // "never")"' oadpschedules \
    | while IFS= read -r l; do gate INFO oadp-schedule "$l"; done
fi

run_gate ceph '
  .ceph.items[0] as $c
  | ($c.status.ceph.details // {} | keys) as $k
  | ($k - $cephok) as $extra
  | if $c == null then "FAIL no CephCluster in rook-ceph"
    elif $c.status.phase == "Ready" and $c.status.ceph.health != "HEALTH_ERR" and ($extra | length) == 0
    then "PASS \($c.status.phase) \($c.status.ceph.health) details=[\($k | join(","))]"
    else "FAIL phase=\($c.status.phase) health=\($c.status.ceph.health) unexpected=[\($extra | join(","))]" end' ceph

run_gate ceph-mgr-metrics '
  .mgr | if .up == 3 and .in == 3 and .pg > 0 and .active == .pg and .clean == .pg
    then "PASS osd up=3 in=3, pgs=\(.pg) active+clean"
    else "FAIL osd up=\(.up) in=\(.in), pgs=\(.pg) active=\(.active) clean=\(.clean)" end' mgr

run_gate pdbs-zero-allowed '
  [.cnpg.items[] | "\(.metadata.namespace)/\(.metadata.name)-primary"] as $ok
  | [.pdb.items[] | select(.status.disruptionsAllowed == 0) | "\(.metadata.namespace)/\(.metadata.name)"] as $z
  | ($z - $ok) as $extra
  | if ($extra | length) == 0 then "PASS only CNPG primaries at 0: [\($z | join(","))]"
    else "FAIL other PDBs at 0 allowed: [\($extra | join(","))]" end' pdb cnpg

run_gate okd-build '
  [.okdbuildjobs.items[] | select((.status.active // 0) > 0) | .metadata.name] as $j
  | [.okdbuildpods.items[] | select(.status.phase == "Running" or .status.phase == "Pending") | .metadata.name] as $p
  | if ($j | length) == 0 and ($p | length) == 0 then "PASS no active Job, no running pod in okd-build"
    else "FAIL active Jobs=[\($j | join(","))] pods=[\($p | join(","))]" end' okdbuildjobs okdbuildpods

run_gate zot-0 '
  .zotpod.items[0] as $z
  | if $z == null then "FAIL zot-0 not found"
    elif $z.status.phase == "Running" and ($z | cond("Ready")) == "True"
    then "PASS node=\($z.spec.nodeName) Running Ready (it moves when that node drains; okd-test/ images wait for it)"
    else "FAIL node=\($z.spec.nodeName) phase=\($z.status.phase) Ready=\($z | cond("Ready"))" end' zotpod

# shellcheck disable=SC2086  # STATS_NAMES is a space-separated list of read names
run_gate zot-pvc-free '
  . as $d | ($d.zotpod.items[0].spec.nodeName // "none" | short) as $zn
  | ([$d["stats_" + $zn].pods[]? | select(.podRef.namespace == "zot" and .podRef.name == "zot-0")
      | .volume[]? | select(.pvcRef.name == "data-zot-0")] | first) as $v
  | if $v == null then "FAIL data-zot-0 not in the kubelet stats of \($zn)"
    else (($v.availableBytes / 107374182.4 | floor) / 10) as $g | (($v.capacityBytes / 107374182.4 | floor) / 10) as $c
      | if $v.availableBytes >= '"$ZOT_MIN_FREE"' then "PASS \($g) GiB free of \($c) GiB (limit 10 GiB)"
        else "FAIL \($g) GiB free of \($c) GiB (limit 10 GiB)" end end' zotpod $STATS_NAMES

# shellcheck disable=SC2086
run_gate node-rootfs '
  . as $d
  | [$d.nodes.items[] | .metadata.name | short | . as $n | $d["stats_" + $n].node.fs as $fs
      | {n: $n, pct: (if ($fs.capacityBytes // 0) > 0 then (((($fs.capacityBytes - $fs.availableBytes) * 1000 / $fs.capacityBytes) | floor) / 10) else null end)}] as $r
  | [$r[] | select(.pct == null or .pct >= '"$ROOTFS_MAX_PCT"')] as $bad
  | ($r | map("\(.n) \(.pct // "unread")%") | join(", ")) as $txt
  | if ($r | length) == '"$NODES_EXPECTED"' and ($bad | length) == 0 then "PASS \($txt) (limit '"$ROOTFS_MAX_PCT"'%)"
    else "FAIL \($txt) (limit '"$ROOTFS_MAX_PCT"'%)" end' nodes $STATS_NAMES

# ---- calendar and admin gates --------------------------------------------------------------------------------------
dow=$(date -u +%u); hh=$(date -u +%H); mm=$(date -u +%M)
m=$(( (dow - 1) * 1440 + 10#$hh * 60 + 10#$mm )); hit=""; k=0
while [ "$k" -le "$WINDOW_MIN" ]; do
  x=$(( (m + k) % 10080 ))
  if [ "$x" -ge 1140 ] && [ "$x" -lt 1380 ]; then hit="+${k}min"; break; fi
  k=$((k + 5))
done
if [ -z "$hit" ]; then
  gate PASS not-monday-evening "now $(date -u +%a) ${hh}:${mm}Z; the next ${WINDOW_MIN} min stay clear of Monday 19:00-23:00Z"
else
  gate FAIL not-monday-evening "now $(date -u +%a) ${hh}:${mm}Z; Monday 19:00-23:00Z (descheduler roll, aescbc rewrite) starts within ${hit}"
fi

run_gate admin-gates '
  (.admingates.data // {}) as $g | (.adminacks.data // {}) as $a
  | if ($g | length) == 0 then "PASS openshift-config-managed/admin-gates has no data"
    else "FAIL admin-gates: " + ($g | to_entries | map("\(.key) (ack=\($a[.key] // "none"))") | join("; ")) end' admingates adminacks

# ---- etcd ----------------------------------------------------------------------------------------------------------
run_gate etcd '
  ([.etcdpods.items[] | select(.status.phase == "Running" and cond("Ready") == "True") | .spec.nodeName | short]) as $r
  | (.etcd | cond("EtcdMembersAvailable")) as $m
  | if ($r | length) == 3 and $m == "True" then "PASS 3/3 etcd pods Ready (\($r | join(","))), EtcdMembersAvailable=True"
    else "FAIL etcd pods Ready=[\($r | join(","))] EtcdMembersAvailable=\($m)" end' etcdpods etcd

run_gate etcd-defrag-switch '
  (.etcd | cond("DefragControllerDisabled")) as $d | (.defragcm.items | length) as $cm
  | "DefragControllerDisabled=\($d), ConfigMap openshift-etcd-operator/etcd-disable-defrag \(if $cm > 0 then "present" else "absent" end)" as $txt
  | if $off != "1" then "INFO \($txt) (required only with --defrag-off)"
    elif $d == "True" and $cm > 0 then "PASS \($txt)"
    else "FAIL \($txt); --defrag-off needs True and the ConfigMap (runbook, before the window)" end' etcd defragcm

FRAG_LINE="oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- wget -qO- --post-data=\"query=\$(jq -rn --arg q 'round(100 * (1 - etcd_mvcc_db_total_size_in_use_in_bytes{job=\"etcd\"} / etcd_mvcc_db_total_size_in_bytes{job=\"etcd\"}), 0.01)' '\$q|@uri')\" 'http://localhost:9090/api/v1/query' | jq -r '.data.result[] | [(.metric.pod // .metric.instance), .value[1]] | @tsv' > etcd-frag.tsv"
frag_read() { # prints "<n-rows> <n-at-or-over-limit> <rows text>" from FRAG_FILE
  awk -F'\t' -v lim="$FRAG_MAX_PCT" '
    NF >= 2 && $2 ~ /^[0-9]+(\.[0-9]+)?$/ { n++; t = t " " $1 "=" $2 "%"; if ($2 + 0 >= lim) b++ }
    END { printf "%d %d%s\n", n, b, t }' "$FRAG_FILE"
}
if [ -z "$FRAG_FILE" ]; then
  if [ "$DEFRAG_OFF" = 1 ]; then
    gate FAIL etcd-fragmentation "no --frag-file: every member must be under ${FRAG_MAX_PCT}% before the switch is relied on; OPERATOR: $FRAG_LINE"
  else
    gate INFO etcd-fragmentation "not read (needs Prometheus); required with --defrag-off. OPERATOR: $FRAG_LINE"
  fi
elif [ ! -r "$FRAG_FILE" ]; then
  gate FAIL etcd-fragmentation "--frag-file $FRAG_FILE not readable"
else
  mt=$(stat -c %Y "$FRAG_FILE" 2>/dev/null || stat -f %m "$FRAG_FILE" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - mt ))
  set -- $(frag_read)
  rows="${1:-0}"; over="${2:-0}"; shift 2 2>/dev/null; txt="$*"
  st=PASS
  if [ "$rows" -ne 3 ] || [ "$over" -ne 0 ] || [ "$age" -gt "$FRAG_MAX_AGE_S" ]; then st=FAIL; fi
  [ "$DEFRAG_OFF" = 1 ] || st=INFO
  gate "$st" etcd-fragmentation "rows=$rows (expect 3):$txt; limit <${FRAG_MAX_PCT}%; file age $((age / 60)) min (limit $((FRAG_MAX_AGE_S / 60)))"
fi

# ---- context (never fails) -----------------------------------------------------------------------------------------
if [ -f "$TMP/cv.json" ]; then
  gate INFO clusterversion-spec "$(jall '.cv | "channel=\(.spec.channel) upstream=\(.spec.upstream) availableUpdates=[\([.status.availableUpdates[]?.version] | join(","))] conditionalUpdates=[\([.status.conditionalUpdates[]?.release.version] | join(","))] history[0]=\(.status.history[0].version)/\(.status.history[0].state) verified=\(.status.history[0].verified)"' cv)"
fi
if [ -f "$TMP/certs.json" ]; then
  gate INFO cert-renewal "$(jall '[.certs.items[] | select(.metadata.namespace == "cert-manager" and .metadata.name == "homelab-wildcard")][0]
    | if . == null then "homelab-wildcard not found" else "homelab-wildcard Ready=\(cond("Ready")) notBefore=\(.status.notBefore) renewalTime=\(.status.renewalTime); the go/no-go needs a renewal on or after 2026-11-20: \(if (.status.notBefore // "") >= "2026-11-20" then "yes" else "not yet" end)" end' certs)"
fi
gate INFO operator-only "not checked here (OPERATOR lines in the README): br-ex.forwarding=1 on all nodes; zot-only per-node images cached on all three nodes (crictl); etcd snapshot copied off the node; off-cluster inputs of the worst case (sealed-secrets key backup, CNPG object-store and OADP/garage credentials, this repo)"

if [ "$FAILS" -eq 0 ]; then echo "GATES PASS"; exit 0; fi
echo "GATES FAIL ($FAILS failed)"
exit 1
