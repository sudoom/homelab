#!/usr/bin/env bash
# Window watcher for the OKD 4.22 -> 5.0 hop (runbook README.md, section 2), readonly. A writer loop appends one
# line per change to an events file and a Monitor follows that file (the pattern of the Rook stage-4 watcher).
#
#   bash tests/okd-5.0-upgrade/watch.sh [--defrag-off] [--interval S] [--prehop FILE] <events-file> <target-version> [seconds]
#
# Run it outside the sandbox (it reads ~/.kube/config-readonly; RO_KUBECONFIG overrides the path), before the start
# command. Default deadline 14400 s, poll every 20 s. A Monitor on the file:
#   tail -n +1 -F <events-file> | grep -E --line-buffered '^[^ ]+ (START|ALERT|CLEARED|ETCD-ON-TARGET|settled|DONE|TIMEOUT|STOPPED)'
# (anchored after the timestamp: a bare 'ALERT' would also match Ceph's BLUESTORE_SLOW_OP_ALERT in the ceph line)
#
# Lines: "<UTC> <key>: <value>" whenever a watched value changes; "<UTC> ALERT <key>: <text>" when a stop-and-ask
# condition starts (and again if its text changes), "<UTC> CLEARED <key>" when it ends; "ETCD-ON-TARGET" once; the
# last line is "DONE" (exit 0) or "TIMEOUT" (exit 1).
# At start the pre-hop rendered MachineConfig of each pool goes to <events-file>.prehop.json. When restarting the
# watcher mid-hop, pass that file with --prehop, or DONE can never be reached.
# DONE, held 2 minutes: ClusterVersion history[0] is the target and Completed; every ClusterOperator on the target and
# Available=True Progressing=False Degraded=False; every MCP updated; every node Ready with currentConfig ==
# desiredConfig == its pool's spec.configuration.name, state Done, and that config differs from the pool's pre-hop
# config; 3 etcd pods Ready.
# --defrag-off: ALERT when DefragControllerDisabled is not True or on any DefragControllerDefragment* /
# DefragControllerLeaderTransfer* event after the start.
# A failed read (the API blanks on every drain) changes nothing: no value line, no CLEARED, no restarted clock. It
# shows as one "read-errors: <reads>" line when the streak starts and "read-errors: none" when it ends.
# Test only: --once runs one poll and prints "DONE-CHECK MET" or "DONE-CHECK NOT-MET: <reasons>" (exit 0/1);
# --fixture-dir DIR serves a read named <name> from DIR/<name>.<poll>.json, else DIR/<name>.json (pods: .txt), and
# fails it when DIR/<name>.<poll>.err exists (<poll> counts from 1).
set -u -o pipefail

usage() { sed -n '2,27p' "$0" >&2; exit 2; }
DEFRAG_OFF=0; INTERVAL=20; PREHOP=""; ONCE=0; FIXTURE_DIR=""; EV=""; TARGET=""; SECS=14400; npos=0
while [ $# -gt 0 ]; do
  case "$1" in
    --defrag-off) DEFRAG_OFF=1 ;;
    --interval) [ $# -ge 2 ] || usage; INTERVAL="$2"; shift ;;
    --prehop) [ $# -ge 2 ] || usage; PREHOP="$2"; shift ;;
    --once) ONCE=1 ;;
    --fixture-dir) [ $# -ge 2 ] || usage; FIXTURE_DIR="$2"; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) npos=$((npos + 1))
       case "$npos" in 1) EV="$1" ;; 2) TARGET="$1" ;; 3) SECS="$1" ;; *) usage ;; esac ;;
  esac
  shift
done
[ -n "$EV" ] && [ -n "$TARGET" ] || usage
case "$SECS$INTERVAL" in *[!0-9]*) usage ;; esac
command -v oc >/dev/null 2>&1 || { echo "oc not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
export KUBECONFIG="${RO_KUBECONFIG:-$HOME/.kube/config-readonly}"

ST="$EV.state"; rm -rf "$ST"; mkdir -p "$ST" || exit 2
RD="$ST/reads"
DEADLINE=$(( $(date +%s) + SECS ))
START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOLD_S=120
POLL=0

fmt_epoch() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
emit() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$EV"; }
chg() { # chg <key> <value>: a line when the value changes; a failed read ("ERR") keeps the last value
  local k="$1" v="$2"
  [ "$v" = ERR ] && return 0
  if [ ! -f "$ST/v-$k" ] || [ "$(cat "$ST/v-$k")" != "$v" ]; then printf '%s' "$v" > "$ST/v-$k"; emit "$k: $v"; fi
}
alert() { # alert <key> <0|1> [text]: ALERT when it starts or its text changes, CLEARED when it ends
  local k="$1" on="$2" txt="${3:-}" f="$ST/alert-$1"
  if [ "$on" = 1 ]; then
    if [ ! -f "$f" ] || [ "$(cat "$f")" != "$txt" ]; then printf '%s' "$txt" > "$f"; emit "ALERT $k: $txt"; fi
  elif [ -f "$f" ]; then rm -f "$f"; emit "CLEARED $k"; fi
}
held() { # held <key> <0|1> <seconds>: true once the condition has held that long
  local f="$ST/since-$1"
  if [ "$2" != 1 ]; then rm -f "$f"; return 1; fi
  [ -f "$f" ] || date +%s > "$f"
  [ $(( $(date +%s) - $(cat "$f") )) -ge "$3" ]
}
starts_true() { case "$1" in True*) echo 1 ;; *) echo 0 ;; esac; }   # 1 if the value starts with True
since_of() { fmt_epoch "$(cat "$ST/since-$1" 2>/dev/null || date +%s)"; }

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
fixture() { # fixture <name> <ext> <dest>: 0 served, 1 forced failure, 2 no fixture (read live)
  [ -n "$FIXTURE_DIR" ] || return 2
  if [ -f "$FIXTURE_DIR/$1.$POLL.err" ]; then rm -f "$3"; return 1; fi
  if [ -f "$FIXTURE_DIR/$1.$POLL.$2" ]; then cp "$FIXTURE_DIR/$1.$POLL.$2" "$3"; return 0; fi
  if [ -f "$FIXTURE_DIR/$1.$2" ]; then cp "$FIXTURE_DIR/$1.$2" "$3"; return 0; fi
  return 2
}
kget() { # kget <name> <oc get args...> -> $RD/<name>.json, no file on a failed read
  local name="$1" f rc; shift
  f="$RD/$name.json"
  fixture "$name" json "$f"; rc=$?; [ "$rc" = 2 ] || return "$rc"
  if oc get "$@" --request-timeout=30s -o json > "$f" 2>/dev/null && jq -e . "$f" >/dev/null 2>&1; then return 0; fi
  rm -f "$f"; return 1
}
kmgr() {
  local f="$RD/mgr.json" out rc
  fixture mgr json "$f"; rc=$?; [ "$rc" = 2 ] || return "$rc"
  out="$(with_timeout 30 oc get --raw /api/v1/namespaces/rook-ceph/services/http:rook-ceph-mgr:9283/proxy/metrics 2>/dev/null | awk '
    /^ceph_osd_up\{/ {u+=$NF} /^ceph_osd_in\{/ {i+=$NF}
    /^ceph_pg_total\{/ {t+=$NF; seen=1} /^ceph_pg_active\{/ {a+=$NF} /^ceph_pg_clean\{/ {c+=$NF}
    END {if (seen) printf "{\"up\":%d,\"in\":%d,\"pg\":%d,\"active\":%d,\"clean\":%d}\n", u, i, t, a, c}')"
  if [ -n "$out" ]; then printf '%s\n' "$out" > "$f"; return 0; fi
  return 1
}
kpods() { # every pod's waiting reasons, one line per pod: "<ns>/<name> <reason>..."
  local f="$RD/pods.txt" rc
  fixture pods txt "$f"; rc=$?; [ "$rc" = 2 ] || return "$rc"
  oc get pods -A --request-timeout=30s -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{range .status.initContainerStatuses[*]}{.state.waiting.reason}{" "}{end}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}' > "$f" 2>/dev/null || { rm -f "$f"; return 1; }
}

JQDEFS='
def cond($t): (((.status.conditions // []) | map(select(.type == $t)) | .[0].status) // "Unknown");
def opver: ([.status.versions[]? | select(.name == "operator") | .version] | first) // "";
def short: split(".")[0];
def rshort: (capture("^rendered-(?<p>.+)-(?<h>[0-9a-f]{8})") | "\(.p)-\(.h)") // .;
def evtime: (.series.lastObservedTime // .lastTimestamp // .eventTime // .metadata.creationTimestamp) // "";
def nz: if . == null or . == "" then "-" else . end;
'
jv() { # jv <name> <prog>: run <prog> on one read; "ERR" if the read is missing or jq fails
  [ -f "$RD/$1.json" ] || { echo ERR; return; }
  jq -r --arg t "$TARGET" --arg s "$START_ISO" "$JQDEFS $2" "$RD/$1.json" 2>/dev/null || echo ERR
}
jall() { # jall <prog> <name>...: run <prog> over {<name>: <doc>, ...}; status 1 on a missing read
  local prog="$1" n files=""; shift
  for n in "$@"; do [ -f "$RD/$n.json" ] || return 1; files="$files $RD/$n.json"; done
  # shellcheck disable=SC2086  # $files is a space-separated list of paths under the state directory
  jq -n -r --arg t "$TARGET" \
    "$JQDEFS reduce inputs as \$x ({}; . + {(input_filename | split(\"/\") | last | rtrimstr(\".json\")): \$x}) | $prog" $files
}

# One reason per line for every DONE condition not met; no output = all met.
DONE_JQ='
. as $d
| ($d.mcp.items | map({(.metadata.name): .spec.configuration.name}) | add // {}) as $ps
| ($d.prehop // {}) as $pre
| ($d.cv.status.history[0] // {}) as $h
| (if ($h.version // "") != $t then "ClusterVersion history[0] is \($h.version), not \($t)" else empty end),
  (if ($h.state // "") != "Completed" then "ClusterVersion history[0] state \($h.state)" else empty end),
  (if ($d.co.items | length) == 0 then "no ClusterOperator read" else empty end),
  ($d.co.items[] | select(opver != $t or cond("Available") != "True" or cond("Progressing") != "False" or cond("Degraded") != "False")
    | "co \(.metadata.name) \(opver) Available=\(cond("Available")) Progressing=\(cond("Progressing")) Degraded=\(cond("Degraded"))"),
  ($d.mcp.items[] | select(cond("Updated") != "True" or cond("Updating") == "True" or cond("Degraded") == "True"
      or .status.updatedMachineCount != .status.machineCount or .status.configuration.name != .spec.configuration.name)
    | "mcp \(.metadata.name) not updated (\(.status.updatedMachineCount)/\(.status.machineCount), Updated=\(cond("Updated")))"),
  (if ($d.nodes.items | length) != 3 then "\($d.nodes.items | length) nodes, expect 3" else empty end),
  ($d.nodes.items[] | (.metadata.annotations // {}) as $a | (.metadata.name | short) as $n
    | ($a["machineconfiguration.openshift.io/currentConfig"] // "") as $cur
    | ($a["machineconfiguration.openshift.io/desiredConfig"] // "") as $des
    | (($cur | capture("^rendered-(?<p>.+)-[0-9a-f]+$") | .p) // "?") as $pool
    | if cond("Ready") != "True" then "node \($n) not Ready"
      elif $cur != $des or $cur != ($ps[$pool] // "none")
        then "node \($n) current=\($cur | rshort) desired=\($des | rshort) pool=\($ps[$pool] // "none" | rshort)"
      elif ($a["machineconfiguration.openshift.io/state"] // "") != "Done" then "node \($n) state \($a["machineconfiguration.openshift.io/state"])"
      elif ($pre[$pool] // "") == "" then "node \($n): no pre-hop config recorded for pool \($pool)"
      elif $cur == $pre[$pool] then "node \($n) still on the pre-hop config \($cur | rshort)"
      else empty end),
  ([$d.etcdpods.items[] | select(.status.phase == "Running" and cond("Ready") == "True")] | length
    | if . != 3 then "etcd pods Ready \(.)/3" else empty end)
'

poll() {
  local n missing=""
  POLL=$((POLL + 1))
  rm -rf "$RD"; mkdir -p "$RD"
  kget cv clusterversion version
  kget co clusteroperators
  kget mcp machineconfigpools
  kget nodes nodes
  kget etcdpods -n openshift-etcd pods -l app=etcd
  kget etcd etcd.operator.openshift.io cluster
  kget etcdevents -n openshift-etcd-operator events
  kget ceph -n rook-ceph cephclusters.ceph.rook.io
  kmgr
  kget cnpg clusters.postgresql.cnpg.io -A
  kget zotpod -n zot pods --field-selector metadata.name=zot-0
  kpods
  cp "$PH_FILE" "$RD/prehop.json"
  for n in cv co mcp nodes etcdpods etcd etcdevents ceph mgr cnpg zotpod; do [ -f "$RD/$n.json" ] || missing="$missing,$n"; done
  [ -f "$RD/pods.txt" ] || missing="$missing,pods"
  missing="${missing#,}"
  chg read-errors "${missing:-none}"
}

observe() {
  local now n rdy uns boot cur txt f t0 ncord=0 v x
  now=$(date +%s)
  # ClusterVersion and ClusterOperators
  chg cv "$(jv cv '"desired=\(.status.desired.version) history[0]=\(.status.history[0].version)/\(.status.history[0].state) Progressing=\(cond("Progressing")) Failing=\(cond("Failing")) ReleaseAccepted=\(cond("ReleaseAccepted"))"')"
  chg cv-progress "$(jv cv '[(.status.conditions // [])[] | select(.type == "Progressing")][0].message // "" | gsub("[\n\r]"; " ") | .[0:160]')"
  chg co-bad "$(jv co '[.items[] | select(cond("Available") != "True" or cond("Progressing") != "False" or cond("Degraded") != "False") | "\(.metadata.name)(A=\(cond("Available")[0:1]),P=\(cond("Progressing")[0:1]),D=\(cond("Degraded")[0:1]))"] | if length == 0 then "none" else join(" ") end')"
  chg co-on-target "$(jv co '"\([.items[] | select(opver == $t)] | length)/\(.items | length) on \($t)"')"
  v="$(jv co '[.items[] | select(.metadata.name == "etcd")][0] | "version=\(opver) Available=\(cond("Available")) Progressing=\(cond("Progressing")) Degraded=\(cond("Degraded"))"')"
  chg etcd-co "$v"
  # From here on a failed read (ERR) leaves every alert, CLEARED state and clock as it is.
  if [ "$v" != ERR ]; then
    case "$v" in
      "version=$TARGET "*)
        if [ ! -f "$ST/etcd-on-target" ]; then : > "$ST/etcd-on-target"
          emit "ETCD-ON-TARGET etcd operator reports $TARGET: point of no return passed; OPERATOR etcd-consistency.sh mid now, before the first node reboot"; fi ;;
    esac
    case "$v" in *" Degraded=True"*) alert etcd-co-degraded 1 "etcd ClusterOperator Degraded=True" ;; *) alert etcd-co-degraded 0 ;; esac
  fi
  # ReleaseAccepted and Failing
  x="$(jv cv '[(.status.conditions // [])[] | select(.type == "ReleaseAccepted")][0] | "\(.status)|ReleaseAccepted=\(.status) \(.reason // ""): \(.message // "" | gsub("[\n\r]"; " ") | .[0:200])"')"
  case "$x" in
    ERR) ;;
    "False|"*) alert release-accepted 1 "${x#*|}: stop; OPERATOR oc adm upgrade --clear (runbook Abort)" ;;
    *) alert release-accepted 0 ;;
  esac
  x="$(jv cv '[(.status.conditions // [])[] | select(.type == "Failing")][0] | "\(.status) \(.reason // "")"')"
  if [ "$x" != ERR ]; then
    if held cv-failing "$(starts_true "$x")" 600; then
      alert cv-failing 1 "ClusterVersion Failing=True since $(since_of cv-failing) (>10 min), reason ${x#True }"
    else alert cv-failing 0; fi
  fi
  # etcd defrag switch and events
  v="$(jv etcd 'cond("DefragControllerDisabled")')"
  [ "$v" = ERR ] || chg defrag-switch "DefragControllerDisabled=$v"
  x="$(jv etcdevents '[.items[] | select((.reason // "") | test("^DefragController(Defragment|LeaderTransfer)")) | select(evtime >= $s)] | sort_by(evtime)
    | if length == 0 then "none" else "\(length) since start, last \(.[-1] | evtime) \(.[-1].reason) \(.[-1].message // "" | gsub("[\n\r]"; " ") | .[0:100])" end')"
  chg defrag-events "$x"
  if [ "$DEFRAG_OFF" = 1 ]; then
    case "$v" in ERR) ;; True) alert defrag-switch 0 ;; *) alert defrag-switch 1 "DefragControllerDisabled=$v while the hop runs with defrag off: stop (runbook okd#2384)" ;; esac
    case "$x" in ERR) ;; none) alert defrag-event 0 ;; *) alert defrag-event 1 "defrag event with the switch set: $x" ;; esac
  fi
  # MCO and nodes
  chg mcp "$(jv mcp '[.items[] | "\(.metadata.name) \(.status.updatedMachineCount)/\(.status.readyMachineCount)/\(.status.machineCount) degraded=\(.status.degradedMachineCount) Updating=\(cond("Updating")) Degraded=\(cond("Degraded")) spec=\(.spec.configuration.name | rshort)"] | join("; ")')"
  x="$(jv mcp '[.items[] | select(cond("Degraded") == "True" or (.status.degradedMachineCount // 0) > 0) | .metadata.name] | join(",")')"
  case "$x" in ERR) ;; "") alert mcp-degraded 0 ;; *) alert mcp-degraded 1 "MachineConfigPool Degraded: $x" ;; esac
  jv nodes '.items[] | (.metadata.annotations // {}) as $a
    | "\(.metadata.name | short)\t\(cond("Ready"))\t\(.spec.unschedulable // false)\t\(.status.nodeInfo.bootID | nz)\t\($a["machineconfiguration.openshift.io/currentConfig"] | nz)\tReady=\(cond("Ready")) \(.status.nodeInfo.kubeletVersion) current=\($a["machineconfiguration.openshift.io/currentConfig"] // "" | rshort) desired=\($a["machineconfiguration.openshift.io/desiredConfig"] // "" | rshort) state=\($a["machineconfiguration.openshift.io/state"] // "") cordoned=\(.spec.unschedulable // false) boot=\(.status.nodeInfo.bootID[0:8])"' > "$ST/nodes.tsv"
  if [ "$(head -1 "$ST/nodes.tsv")" = ERR ]; then
    chg nodes ERR
  else
    while IFS="$(printf '\t')" read -r n rdy uns boot cur txt; do
      [ -n "$n" ] || continue
      chg "node-$n" "$txt"
      if held "notready-$n" "$( [ "$rdy" != True ] && echo 1 || echo 0 )" 900; then
        alert "node-notready-$n" 1 "$n NotReady since $(since_of "notready-$n") (>15 min): okd#2361 check and recovery block in the runbook"
      else alert "node-notready-$n" 0; fi
      # Stuck drain: cordoned 20 min with the same boot and the same current config. A reboot (new bootID) or a new
      # current config restarts the clock and clears the alert, even while the node is still cordoned.
      f="$ST/cordon-$n"
      if [ "$uns" = true ]; then
        ncord=$((ncord + 1))
        if [ ! -f "$f" ] || [ "$(cut -d' ' -f2- "$f")" != "$boot $cur" ]; then echo "$now $boot $cur" > "$f"; fi
        t0=$(cut -d' ' -f1 "$f")
        if [ $(( now - t0 )) -ge 1200 ]; then
          alert "stuck-drain-$n" 1 "$n cordoned since $(fmt_epoch "$t0") without a reboot (>20 min): stuck drain? PDBs, CNPG, VolumeAttachments (network-change skill)"
        else alert "stuck-drain-$n" 0; fi
      else rm -f "$f"; alert "stuck-drain-$n" 0; fi
    done < "$ST/nodes.tsv"
  fi
  # etcd pods
  x="$(jv etcdpods '[.items[] | select(.status.phase == "Running" and cond("Ready") == "True") | .spec.nodeName | short] | "\(length) \(join(","))"')"
  if [ "$x" = ERR ]; then chg etcd-pods ERR
  else
    chg etcd-pods "${x%% *}/3 Ready (${x#* })"
    if held etcd-pods-low "$( [ "${x%% *}" -lt 3 ] && [ "$ncord" -eq 0 ] && echo 1 || echo 0 )" 60; then
      alert etcd-pods 1 "etcd pods Ready ${x%% *}/3 with no node cordoned (since $(since_of etcd-pods-low))"
    else alert etcd-pods 0; fi
  fi
  # Ceph
  chg ceph "$(jv ceph '.items[0] | "\(.status.phase) \(.status.ceph.health) [\(.status.ceph.details // {} | keys | join(","))]"')"
  chg osd "$(jv mgr '"up=\(.up) in=\(.in) pgs=\(.pg) active=\(.active) clean=\(.clean)"')"
  x="$(jv mgr '.up')"
  case "$x" in
    ""|ERR|*[!0-9]*) ;;
    *) if [ "$x" -le 1 ]; then alert osds-down 1 "only $x of 3 OSDs up: two OSDs down"; else alert osds-down 0; fi ;;
  esac
  # CNPG, zot, image pulls
  chg cnpg "$(jv cnpg '[.items[] | "\(.metadata.name) \(.status.readyInstances // 0)/\(.spec.instances)"] | join(" ")')"
  x="$(jv cnpg '[.items[] | select((.status.readyInstances // 0) == 0) | "\(.metadata.namespace)/\(.metadata.name)"] | join(",")')"
  case "$x" in ERR) ;; "") alert cnpg-zero 0 ;; *) alert cnpg-zero 1 "CNPG cluster at 0 ready: $x" ;; esac
  chg zot-0 "$(jv zotpod '.items[0] | if . == null then "absent" else "\(.spec.nodeName | short) \(.status.phase) Ready=\(cond("Ready"))" end')"
  if [ -f "$RD/pods.txt" ]; then
    x="$(grep -E 'ImagePullBackOff|ErrImagePull' "$RD/pods.txt" | awk '{print $1}' | sort | paste -sd' ' - | cut -c1-400)"
    chg imagepullbackoff "${x:-none}"
  else chg imagepullbackoff ERR; fi
}

done_check() { # sets DONE_MET (1/0) and DONE_REASONS
  local out
  if out="$(jall "$DONE_JQ" cv co mcp nodes etcdpods prehop 2>&1)"; then
    if [ -z "$out" ]; then DONE_MET=1; DONE_REASONS=""; else DONE_MET=0; DONE_REASONS="$(printf '%s\n' "$out" | paste -sd';' -)"; fi
  else
    DONE_MET=0; DONE_REASONS="read error or jq error: $(printf '%s' "$out" | head -1)"
  fi
}

# ---- start -------------------------------------------------------------------------------------------------------
mkdir -p "$RD"
if [ -n "$PREHOP" ]; then
  PH_FILE="$PREHOP"
  jq -e 'type == "object" and length > 0' "$PH_FILE" >/dev/null 2>&1 || { echo "--prehop $PH_FILE is not a pool->config JSON object" >&2; exit 2; }
  PH_SRC="from $PH_FILE"
else
  PH_FILE="$EV.prehop.json"
  kget mcp machineconfigpools || { echo "cannot read MachineConfigPools to record the pre-hop configs" >&2; exit 2; }
  jq '[.items[] | {(.metadata.name): .spec.configuration.name}] | add' "$RD/mcp.json" > "$PH_FILE" || exit 2
  PH_SRC="recorded to $PH_FILE"
fi
emit "START watch target=$TARGET interval=${INTERVAL}s deadline=$(fmt_epoch "$DEADLINE") defrag-off=$DEFRAG_OFF kubeconfig=$KUBECONFIG"
emit "prehop ($PH_SRC): $(jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' "$PH_FILE")"
trap 'emit "STOPPED watcher interrupted"; exit 130' INT TERM

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  t_start=$(date +%s)
  poll
  observe
  done_check
  if [ "$ONCE" = 1 ]; then
    if [ "$DONE_MET" = 1 ]; then echo "DONE-CHECK MET"; exit 0; fi
    echo "DONE-CHECK NOT-MET: $DONE_REASONS"; exit 1
  fi
  case "$(jv cv '"\(.status.history[0].version) \(.status.history[0].state)"')" in
    "$TARGET Completed") [ "$DONE_MET" = 1 ] || chg done-pending "$DONE_REASONS" ;;
  esac
  if [ "$DONE_MET" = 1 ]; then
    if [ ! -f "$ST/settled-since" ]; then date +%s > "$ST/settled-since"; emit "settled: every DONE condition met, holding ${HOLD_S}s"; fi
    if [ $(( $(date +%s) - $(cat "$ST/settled-since") )) -ge "$HOLD_S" ]; then
      emit "DONE $TARGET: history[0] Completed, all ClusterOperators on target and clean, MCPs updated, 3 nodes Ready on a new rendered config (current == desired == pool, Done), 3 etcd pods Ready; held ${HOLD_S}s"
      exit 0
    fi
  elif [ -f "$ST/settled-since" ]; then
    rm -f "$ST/settled-since"; emit "settled: lost ($DONE_REASONS)"
  fi
  el=$(( $(date +%s) - t_start )); sl=$(( INTERVAL - el )); [ "$sl" -ge 1 ] || sl=1
  sleep "$sl"
done
emit "TIMEOUT deadline reached without DONE"
exit 1
