#!/usr/bin/env bash
# Readonly post-hop verify for the OKD 4.22 -> 5.0 hop (runbook README.md, section 2 step 5): the target running
# (ClusterVersion Available, not Failing, not Progressing), every ClusterOperator on it and clean, three nodes Ready on
# the new machine-os, MCPs updated, every Argo CD app Synced/Healthy, CNPG x3 2/2 archiving, Ceph in its standing
# state, 3 etcd members; plus ClusterVersion history[0].verified == true (the start was not forced).
#
#   bash tests/okd-5.0-upgrade/verify.sh <target-version> [--defrag-off [--since <UTC ISO time>]] [--fixture-dir DIR]
#
# Prints one `CHECK PASS|FAIL <name> <detail>` line per check, `INFO` lines, then `RESULT PASS|FAIL <target>`.
# Exit 0 only if every check passed. A failed or empty read is a FAIL, never a pass.
# Reads only, with the readonly kubeconfig (RO_KUBECONFIG overrides the path). No exec, no Secret read.
#
#   --defrag-off   also require DefragControllerDisabled=True on etcd/cluster, and no DefragControllerDefragment* or
#                  DefragControllerLeaderTransfer* event in openshift-etcd-operator newer than --since (default: any
#                  retained event; events age out, the watcher is the record for the whole window).
#   --fixture-dir  test only: a read named <name> comes from DIR/<name>.json when that file exists.
#
# "On the new machine-os" is checked as: each node's currentConfig == desiredConfig == its pool's
# spec.configuration.name, state Done, and that rendered MachineConfig carries annotation
# machineconfiguration.openshift.io/release-image-version == <target>, has no annotation
# machineconfiguration.openshift.io/os-image-url-overridden (the MCO sets it when osImageURL is not the base image it
# chose), and its spec.osImageURL equals either baseOSContainerImage of ConfigMap
# openshift-machine-config-operator/machine-config-osimageurl (releaseVersion == <target>), or, where the OSStreams
# feature is on (5.0 default; MCO release-5.0 GetBaseImageContainer), the osImage of the pool's stream in
# osimagestreams.machineconfiguration.openshift.io/cluster (the pool's spec.osImageStream.name, else
# status.defaultStream). On 4.22 that resource type does not exist and the ConfigMap alone decides.
set -u -o pipefail

usage() { sed -n '2,26p' "$0" >&2; exit 2; }
TARGET=""; DEFRAG_OFF=0; SINCE=""; FIXTURE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --defrag-off) DEFRAG_OFF=1 ;;
    --since) [ $# -ge 2 ] || usage; SINCE="$2"; shift ;;
    --fixture-dir) [ $# -ge 2 ] || usage; FIXTURE_DIR="$2"; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$TARGET" ] || usage; TARGET="$1" ;;
  esac
  shift
done
[ -n "$TARGET" ] || usage
command -v oc >/dev/null 2>&1 || { echo "oc not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
export KUBECONFIG="${RO_KUBECONFIG:-$HOME/.kube/config-readonly}"

NODES_EXPECTED=3
CEPH_ALLOWED='["BLUESTORE_SLOW_OP_ALERT","AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE","AUTH_INSECURE_CLIENT_KEY_TYPE","AUTH_INSECURE_KEYS_ALLOWED","AUTH_INSECURE_KEYS_CREATABLE"]'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/okd50-verify.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT

FAILS=0
check() { # check PASS|FAIL <name> <detail>
  [ "$1" = FAIL ] && FAILS=$((FAILS + 1))
  echo "CHECK $1 $2 ${3:-<empty>}"
}
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
kget() { # kget <name> <oc get args...> -> $TMP/<name>.json, no file on a failed read
  local name="$1" f; shift
  f="$TMP/$name.json"
  if [ -n "$FIXTURE_DIR" ] && [ -f "$FIXTURE_DIR/$name.json" ]; then cp "$FIXTURE_DIR/$name.json" "$f"; return 0; fi
  if oc get "$@" --request-timeout=30s -o json > "$f" 2>"$TMP/$name.err" && jq -e . "$f" >/dev/null 2>&1; then return 0; fi
  rm -f "$f"; return 1
}
kmgr() { # kmgr <name>: Ceph mgr metrics folded into {"up","in","pg","active","clean"}
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
def opver: ([.status.versions[]? | select(.name == "operator") | .version] | first) // "";
def short: split(".")[0];
def rshort: (capture("^rendered-(?<p>.+)-(?<h>[0-9a-f]{8})") | "\(.p)-\(.h)") // .;
def evtime: (.series.lastObservedTime // .lastTimestamp // .eventTime // .metadata.creationTimestamp) // "";
def dshort: ((split("@") | .[1]) // .) | .[0:19];
'
jall() { # jall <prog> <name>...: run <prog> over {<name>: <doc>, ...}
  local prog="$1" n files=""; shift
  for n in "$@"; do [ -f "$TMP/$n.json" ] || return 1; files="$files $TMP/$n.json"; done
  # shellcheck disable=SC2086  # $files is a space-separated list of mktemp paths
  jq -n -r --arg t "$TARGET" --arg since "$SINCE" --argjson cephok "$CEPH_ALLOWED" \
    "$JQDEFS reduce inputs as \$x ({}; . + {(input_filename | split(\"/\") | last | rtrimstr(\".json\")): \$x}) | $prog" $files
}
run_check() { # run_check <name> <prog printing "PASS|FAIL <detail>"> <read-name>...
  local c="$1" prog="$2" n res; shift 2
  for n in "$@"; do [ -f "$TMP/$n.json" ] || { check FAIL "$c" "read failed: $n"; return; }; done
  res="$(jall "$prog" "$@" 2>&1)" || res="jq error: $(printf '%s' "$res" | head -1)"
  case "$res" in
    "PASS "*) check PASS "$c" "${res#PASS }" ;;
    "FAIL "*) check FAIL "$c" "${res#FAIL }" ;;
    *) check FAIL "$c" "unexpected result: $(printf '%s' "$res" | head -1)" ;;
  esac
}

# ---- reads -----------------------------------------------------------------------------------------------------
kget cv clusterversion version
kget co clusteroperators
kget nodes nodes
kget mcp machineconfigpools
kget osimage -n openshift-machine-config-operator configmap machine-config-osimageurl
kget apps -n openshift-gitops applications.argoproj.io
kget cnpg clusters.postgresql.cnpg.io -A
kget ceph -n rook-ceph cephclusters.ceph.rook.io
kmgr mgr
kget etcd etcd.operator.openshift.io cluster
kget etcdpods -n openshift-etcd pods -l app=etcd
kget etcdevents -n openshift-etcd-operator events
kget csvs clusterserviceversions.operators.coreos.com -A
kget subs subscriptions.operators.coreos.com -A
# OSImageStream (5.0, OSStreams feature). Absent as a resource type on 4.22: then {"absent": "<why>"}.
if ! kget osis osimagestreams.machineconfiguration.openshift.io cluster; then
  why="read failed: $(head -1 "$TMP/osis.err" 2>/dev/null | cut -c1-120)"
  case "$why" in *"doesn't have a resource type"*) why="resource type not served (4.22)" ;; esac
  jq -n --arg w "$why" '{absent: $w}' > "$TMP/osis.json"
fi
# The rendered MachineConfigs the nodes and pools point at, read by name (listing all MachineConfigs is large).
if [ -n "$FIXTURE_DIR" ] && [ -f "$FIXTURE_DIR/mcs.json" ]; then
  cp "$FIXTURE_DIR/mcs.json" "$TMP/mcs.json"
elif [ -f "$TMP/nodes.json" ] && [ -f "$TMP/mcp.json" ]; then
  : > "$TMP/mcs.list"; ok=1
  for mc in $(jq -r '(.items[].metadata.annotations | ."machineconfiguration.openshift.io/currentConfig", ."machineconfiguration.openshift.io/desiredConfig")' "$TMP/nodes.json" | sort -u); do
    if ! oc get machineconfigs.machineconfiguration.openshift.io "$mc" --request-timeout=30s -o json >> "$TMP/mcs.list" 2>/dev/null; then ok=0; fi
  done
  if [ "$ok" = 1 ]; then jq -s '{items: .}' "$TMP/mcs.list" > "$TMP/mcs.json" 2>/dev/null || rm -f "$TMP/mcs.json"; fi
fi

# ---- ClusterVersion ----------------------------------------------------------------------------------------------
run_check cv-desired '.cv.status.desired.version as $v
  | if $v == $t then "PASS desired=\($v)" else "FAIL desired=\($v) target=\($t)" end' cv
run_check cv-history '.cv.status.history[0] as $h
  | if $h.version == $t and $h.state == "Completed" then "PASS history[0] \($h.version) Completed \($h.completionTime)"
    else "FAIL history[0] \($h.version) state=\($h.state) (target \($t))" end' cv
run_check cv-verified '.cv.status.history[0] as $h
  | if $h.version == $t and $h.verified == true then "PASS history[0].verified=true (not forced)"
    else "FAIL history[0] \($h.version) verified=\($h.verified)" end' cv
run_check cv-conditions '.cv | cond("Available") as $a | cond("Progressing") as $p | cond("Failing") as $f
  | if $a == "True" and $p == "False" and $f == "False" then "PASS Available=True Progressing=False Failing=False"
    else "FAIL Available=\($a) Progressing=\($p) Failing=\($f)" end' cv

# ---- ClusterOperators --------------------------------------------------------------------------------------------
run_check co-versions '.co.items as $c | [$c[] | select(opver != $t) | "\(.metadata.name)=\(opver)"] as $bad
  | if ($c | length) > 0 and ($bad | length) == 0 then "PASS \($c | length)/\($c | length) on \($t)"
    else "FAIL \($bad | length) of \($c | length) not on \($t): \($bad | join(" "))" end' co
run_check co-clean '.co.items as $c
  | [$c[] | select(cond("Available") != "True" or cond("Progressing") != "False" or cond("Degraded") != "False")
      | "\(.metadata.name)(Available=\(cond("Available")),Progressing=\(cond("Progressing")),Degraded=\(cond("Degraded")))"] as $bad
  | if ($c | length) > 0 and ($bad | length) == 0 then "PASS \($c | length)/\($c | length) True/False/False"
    else "FAIL \($bad | join(" "))" end' co

# ---- nodes and MCO -----------------------------------------------------------------------------------------------
run_check nodes-ready '.nodes.items as $n
  | [$n[] | select(cond("Ready") != "True") | .metadata.name | short] as $nr
  | [$n[] | select(.spec.unschedulable == true) | .metadata.name | short] as $cd
  | if ($n | length) == '"$NODES_EXPECTED"' and ($nr | length) == 0 and ($cd | length) == 0
    then "PASS \($n | length)/\($n | length) Ready, none cordoned"
    else "FAIL nodes=\($n | length) notReady=[\($nr | join(","))] cordoned=[\($cd | join(","))]" end' nodes
run_check nodes-config '. as $d
  | ($d.mcp.items | map({(.metadata.name): .spec.configuration.name}) | add // {}) as $ps
  | [$d.nodes.items[] | (.metadata.annotations // {}) as $a
      | ($a["machineconfiguration.openshift.io/currentConfig"] // "") as $cur
      | (($cur | capture("^rendered-(?<p>.+)-[0-9a-f]+$") | .p) // "?") as $pool
      | {n: (.metadata.name | short), cur: $cur, des: ($a["machineconfiguration.openshift.io/desiredConfig"] // ""),
         want: ($ps[$pool] // "none"), state: ($a["machineconfiguration.openshift.io/state"] // "")}] as $r
  | [$r[] | select(.cur != .des or .cur != .want or .state != "Done")] as $bad
  | if ($r | length) == '"$NODES_EXPECTED"' and ($bad | length) == 0
    then "PASS " + ($r | map("\(.n) \(.cur | rshort)") | join(", ")) + " (current == desired == pool, Done)"
    else "FAIL " + ($bad | map("\(.n) current=\(.cur | rshort) desired=\(.des | rshort) pool=\(.want | rshort) state=\(.state)") | join("; ")) + " (\($r | length) nodes)" end' nodes mcp
run_check nodes-machine-os '. as $d
  | ($d.mcs.items | map({(.metadata.name): .}) | add // {}) as $m
  | ($d.mcp.items | map({(.metadata.name): .}) | add // {}) as $pools
  | ($d.osimage.data // {}) as $o
  | (if $d.osis.absent then null else $d.osis end) as $s
  | [$d.nodes.items[] | (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "") as $cur | $m[$cur] as $mc
      | (($cur | capture("^rendered-(?<p>.+)-[0-9a-f]+$") | .p) // "?") as $pool
      | (if $s == null then null
         else ($pools[$pool].spec.osImageStream.name // "") as $req
           | (if $req == "" then $s.status.defaultStream else $req end) as $sn
           | {name: $sn, img: ([$s.status.availableStreams[]? | select(.name == $sn) | .osImage] | first)} end) as $st
      | ($mc.spec.osImageURL // "unknown") as $os
      | {n: (.metadata.name | short), cur: $cur, os: $os,
         rel: ($mc.metadata.annotations["machineconfiguration.openshift.io/release-image-version"] // "unknown"),
         ovr: (($mc.metadata.annotations // {}) | has("machineconfiguration.openshift.io/os-image-url-overridden")),
         stream: (if $st == null then "none" else "\($st.name)=\($st.img // "none" | dshort)" end),
         via: (if $os == ($o.baseOSContainerImage // "none") then "ConfigMap"
               elif $st != null and ($st.img // "") != "" and $os == $st.img then "OSImageStream/\($st.name)"
               else "" end)}] as $r
  | [$r[] | select(.rel != $t or .ovr or .via == "")] as $bad
  | ($o.baseOSContainerImage // "none" | dshort) as $cm
  | (if $s == null then "OSImageStream: \($d.osis.absent)" else "OSImageStream default=\($s.status.defaultStream)" end) as $sinfo
  | if ($o.releaseVersion // "") != $t then "FAIL machine-config-osimageurl releaseVersion=\($o.releaseVersion) (target \($t))"
    elif ($r | length) == '"$NODES_EXPECTED"' and ($bad | length) == 0
    then "PASS every node on a \($t) rendered config, not overridden, osImageURL \([$r[].os | dshort] | unique | join(",")) from \([$r[].via] | unique | join(",")) (\($sinfo))"
    else "FAIL " + ($bad | map("\(.n) on \(.cur | rshort): release-image-version=\(.rel) os-image-url-overridden=\(.ovr) osImage=\(.os | dshort) stream=\(.stream)") | join("; "))
      + " (want \($t); ConfigMap \($cm); \($sinfo))" end' nodes mcs mcp osimage osis
run_check machineconfigpools '.mcp.items as $p
  | [$p[] | select(.spec.paused == true or cond("Updated") != "True" or cond("Updating") == "True" or cond("Degraded") == "True"
        or .status.updatedMachineCount != .status.machineCount or .status.configuration.name != .spec.configuration.name)
      | "\(.metadata.name)(paused=\(.spec.paused // false),Updated=\(cond("Updated")),Degraded=\(cond("Degraded")),\(.status.updatedMachineCount)/\(.status.machineCount))"] as $bad
  | if ($p | length) > 0 and ($bad | length) == 0
    then "PASS " + ([$p[] | "\(.metadata.name) \(.status.updatedMachineCount)/\(.status.machineCount)"] | join(", "))
    else "FAIL \($bad | join(" "))" end' mcp

# ---- apps, databases, storage, etcd ------------------------------------------------------------------------------
run_check argocd-apps '.apps.items as $a
  | [$a[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | "\(.metadata.name)=\(.status.sync.status)/\(.status.health.status)"] as $bad
  | if ($a | length) > 0 and ($bad | length) == 0 then "PASS \($a | length)/\($a | length) Synced/Healthy"
    else "FAIL \($bad | length) of \($a | length): \($bad | join(" "))" end' apps
run_check cnpg '.cnpg.items as $c
  | [$c[] | "\(.metadata.namespace)/\(.metadata.name) \(.status.readyInstances // 0)/\(.spec.instances) archiving=\(cond("ContinuousArchiving"))"] as $all
  | [$c[] | select(.spec.instances != 2 or (.status.readyInstances // 0) != 2 or cond("ContinuousArchiving") != "True")] as $bad
  | if ($c | length) == 3 and ($bad | length) == 0 then "PASS \($all | join(", "))"
    else "FAIL \($c | length) clusters (expect 3, each 2/2 archiving=True): \($all | join(", "))" end' cnpg
run_check ceph '.ceph.items[0] as $c | ($c.status.ceph.details // {} | keys) as $k | ($k - $cephok) as $extra
  | if $c == null then "FAIL no CephCluster"
    elif $c.status.phase == "Ready" and $c.status.ceph.health != "HEALTH_ERR" and ($extra | length) == 0
    then "PASS \($c.status.phase) \($c.status.ceph.health) details=[\($k | join(","))]"
    else "FAIL phase=\($c.status.phase) health=\($c.status.ceph.health) unexpected=[\($extra | join(","))]" end' ceph
run_check ceph-mgr-metrics '.mgr | if .up == 3 and .in == 3 and .pg > 0 and .active == .pg and .clean == .pg
    then "PASS osd up=3 in=3, pgs=\(.pg) active+clean"
    else "FAIL osd up=\(.up) in=\(.in), pgs=\(.pg) active=\(.active) clean=\(.clean)" end' mgr
run_check etcd '([.etcdpods.items[] | select(.status.phase == "Running" and cond("Ready") == "True") | .spec.nodeName | short]) as $r
  | (.etcd | cond("EtcdMembersAvailable")) as $m
  | if ($r | length) == 3 and $m == "True" then "PASS 3/3 etcd pods Ready (\($r | join(","))), EtcdMembersAvailable=True"
    else "FAIL etcd pods Ready=[\($r | join(","))] EtcdMembersAvailable=\($m)" end' etcdpods etcd

if [ "$DEFRAG_OFF" = 1 ]; then
  run_check etcd-defrag-switch '(.etcd | cond("DefragControllerDisabled")) as $d
    | if $d == "True" then "PASS DefragControllerDisabled=True" else "FAIL DefragControllerDisabled=\($d)" end' etcd
  run_check etcd-defrag-events '[.etcdevents.items[] | select((.reason // "") | test("^DefragController(Defragment|LeaderTransfer)"))
      | select($since == "" or evtime >= $since) | "\(evtime) \(.reason) \(.message // "" | .[0:80])"] as $e
    | if ($e | length) == 0 then "PASS no defrag event \(if $since == "" then "retained" else "since \($since)" end)"
      else "FAIL \($e | length) defrag events: \($e | join(" | "))" end' etcdevents
fi

# ---- context (never fails) ---------------------------------------------------------------------------------------
[ -f "$TMP/nodes.json" ] && echo "INFO nodes $(jall '[.nodes.items[] | "\(.metadata.name | short) \(.status.nodeInfo.kubeletVersion) \(.status.nodeInfo.osImage) kernel \(.status.nodeInfo.kernelVersion) \(.status.nodeInfo.containerRuntimeVersion)"] | join("; ")' nodes)"
[ -f "$TMP/etcd.json" ] && echo "INFO etcd DefragControllerDisabled=$(jall '.etcd | cond("DefragControllerDisabled")' etcd)"
[ -f "$TMP/csvs.json" ] && echo "INFO csvs $(jall '[.csvs.items[] | select(.metadata.labels["olm.copiedFrom"] == null)] as $c | [$c[] | select(.status.phase != "Succeeded") | "\(.metadata.namespace)/\(.metadata.name)=\(.status.phase)"] as $b | "\($c | length - ($b | length))/\($c | length) Succeeded \($b | join(" "))"' csvs)"
[ -f "$TMP/subs.json" ] && echo "INFO subscriptions $(jall '[.subs.items[] | select(any(.status.conditions[]?; .type == "ResolutionFailed" and .status == "True")) | "\(.metadata.namespace)/\(.metadata.name)"] as $r | [.subs.items[] | select((.spec.installPlanApproval // "Automatic") != "Manual") | .metadata.name] as $a | "ResolutionFailed=[\($r | join(","))] (normal for minutes after completion, HOP 2) notManual=[\($a | join(","))]"' subs)"

if [ "$FAILS" -eq 0 ]; then echo "RESULT PASS $TARGET"; exit 0; fi
echo "RESULT FAIL $TARGET ($FAILS failed)"
exit 1
