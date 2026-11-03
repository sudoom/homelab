#!/usr/bin/env bash
# Readonly CSI state check for the Rook/Ceph upgrade stages.
#
#   KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage0|stage1|stage2|stage3|stage4
#
# Prints one `CHECK PASS|FAIL <name> <observed>` line per check, then an INFO line.
# Exit 0 only if every check passed. A failed or empty oc read is a FAIL, never a pass.
# Uses `get` only: no mutating verb, no exec, no Secret read.
set -u

NS=rook-ceph
DRIVER=rook-ceph.rbd.csi.ceph.com
CTRL_DEPLOY="${DRIVER}-ctrlplugin"
NODE_DS="${DRIVER}-nodeplugin"
OLD_CTRL_SA=ceph-csi-rbd-ctrlplugin-sa
OLD_NODE_SA=ceph-csi-rbd-nodeplugin-sa
NEW_CTRL_SA=rook-ceph-rbd-csi-ceph-com-ctrlplugin-sa
NEW_NODE_SA=rook-ceph-rbd-csi-ceph-com-nodeplugin-sa
SCC=rook-ceph-csi

usage() { echo "usage: $0 --expect stage0|stage1|stage2|stage3|stage4" >&2; exit 2; }
[ "${1:-}" = "--expect" ] && [ $# -eq 2 ] || usage
STAGE="$2"
case "$STAGE" in stage0|stage1|stage2|stage3|stage4) ;; *) usage ;; esac
command -v oc >/dev/null 2>&1 || { echo "oc not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }

# Expectations per stage (stage3 and stage4 inherit stage2's).
case "$STAGE" in
  stage0) EXP_CTRL_SA=$OLD_CTRL_SA; EXP_NODE_SA=$OLD_NODE_SA; EXP_DRV_CTRL=""; EXP_DRV_NODE=""
          EXP_CSI=v3.16.2; EXP_OP=v1.19.5 ;;
  stage1) EXP_CTRL_SA=$NEW_CTRL_SA; EXP_NODE_SA=$NEW_NODE_SA; EXP_DRV_CTRL=$NEW_CTRL_SA; EXP_DRV_NODE=$NEW_NODE_SA
          EXP_CSI=v3.17.1; EXP_OP=v1.20.9 ;;
  *)      EXP_CTRL_SA=$NEW_CTRL_SA; EXP_NODE_SA=$NEW_NODE_SA; EXP_DRV_CTRL=$NEW_CTRL_SA; EXP_DRV_NODE=$NEW_NODE_SA
          EXP_CSI=v3.18.1; EXP_OP=v1.21.1 ;;
esac

FAILS=0
report() { # report <PASS|FAIL> <name> <observed>
  [ "$1" = FAIL ] && FAILS=$((FAILS + 1))
  echo "CHECK $1 $2 ${3:-<empty>}"
}
expect_eq() { # expect_eq <name> <observed> <expected>
  if [ "$2" = "$3" ]; then report PASS "$1" "$2"; else report FAIL "$1" "observed='$2' expected='$3'"; fi
}
# Run oc; on failure print a sentinel so a read error can never equal an expected value (not even an empty one).
ocr() { local out; if out="$(oc "$@" 2>/dev/null)"; then printf '%s' "$out"; else printf 'READ-ERROR'; fi; }

# ---- common checks -------------------------------------------------------------------------------------------
DRV_JSON="$(ocr -n $NS get drivers.csi.ceph.io $DRIVER -o json)"
if [ "$DRV_JSON" = READ-ERROR ] || ! echo "$DRV_JSON" | jq -e .metadata.uid >/dev/null 2>&1; then
  report FAIL driver-exists "Driver $DRIVER not readable"
  DRV_JSON='{"spec":{"controllerPlugin":{"serviceAccountName":"READ-ERROR"},"nodePlugin":{"serviceAccountName":"READ-ERROR"}}}'
else
  report PASS driver-exists "$DRIVER"
fi

DEP_JSON="$(ocr -n $NS get deploy $CTRL_DEPLOY -o json)"
[ "$DEP_JSON" = READ-ERROR ] && DEP_JSON='{}'
echo "$DEP_JSON" | jq -e . >/dev/null 2>&1 || DEP_JSON='{}'
expect_eq ctrlplugin-ready "$(echo "$DEP_JSON" | jq -r '"\(.status.readyReplicas // 0)/\(.spec.replicas // 0)"')" "2/2"
expect_eq ctrlplugin-hostNetwork "$(echo "$DEP_JSON" | jq -r '.spec.template.spec.hostNetwork // false')" "true"
expect_eq ctrlplugin-has-csi-snapshotter "$(echo "$DEP_JSON" | jq -r '[.spec.template.spec.containers[]?.name] | index("csi-snapshotter") != null')" "true"

DS_JSON="$(ocr -n $NS get ds $NODE_DS -o json)"
[ "$DS_JSON" = READ-ERROR ] && DS_JSON='{}'
echo "$DS_JSON" | jq -e . >/dev/null 2>&1 || DS_JSON='{}'
expect_eq nodeplugin-ready "$(echo "$DS_JSON" | jq -r '"\(.status.numberReady // 0)/\(.status.desiredNumberScheduled // 0)"')" "3/3"

# FailedCreate events in the last 30 minutes (lastTimestamp, eventTime or series.lastObservedTime).
EV_JSON="$(ocr -n $NS get events --field-selector reason=FailedCreate -o json)"
if echo "$EV_JSON" | jq -e .items >/dev/null 2>&1; then
  CUTOFF="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  RECENT="$(echo "$EV_JSON" | jq -r --arg c "$CUTOFF" '[.items[] | (.series.lastObservedTime // .lastTimestamp // .eventTime // .metadata.creationTimestamp) | select(. >= $c)] | length')"
  expect_eq no-recent-FailedCreate "$RECENT" "0"
else
  report FAIL no-recent-FailedCreate "events not readable"
fi

# ---- plugin pods: service accounts and cephcsi image ---------------------------------------------------------
CTRL_PODS="$(ocr -n $NS get pods -l "app=${CTRL_DEPLOY}" -o json)"
NODE_PODS="$(ocr -n $NS get pods -l "app=${NODE_DS}" -o json)"
for v in CTRL_PODS NODE_PODS; do
  eval "val=\${$v}"
  if [ "$val" = READ-ERROR ] || ! echo "$val" | jq -e .items >/dev/null 2>&1; then eval "$v='{\"items\":[]}'"; fi
done
sa_set()  { echo "$1" | jq -r '[.items[].spec.serviceAccountName] | unique | join(",")'; }
tag_set() { echo "$1" | jq -r '[.items[].spec.containers[] | select(.name=="csi-rbdplugin") | .image] | unique | map(select(startswith("quay.io/cephcsi/cephcsi:")) | sub("^quay.io/cephcsi/cephcsi:";"")) | join(",")'; }
expect_eq plugin-pod-SA-ctrl "$(sa_set "$CTRL_PODS")" "$EXP_CTRL_SA"
expect_eq plugin-pod-SA-node "$(sa_set "$NODE_PODS")" "$EXP_NODE_SA"
expect_eq driver-SA-ctrl "$(echo "$DRV_JSON" | jq -r '.spec.controllerPlugin.serviceAccountName // ""')" "$EXP_DRV_CTRL"
expect_eq driver-SA-node "$(echo "$DRV_JSON" | jq -r '.spec.nodePlugin.serviceAccountName // ""')" "$EXP_DRV_NODE"
expect_eq cephcsi-tag-ctrl "$(tag_set "$CTRL_PODS")" "$EXP_CSI"
expect_eq cephcsi-tag-node "$(tag_set "$NODE_PODS")" "$EXP_CSI"

OP_IMG="$(ocr -n $NS get deploy rook-ceph-operator -o jsonpath='{.spec.template.spec.containers[0].image}')"
expect_eq rook-operator-image "$OP_IMG" "docker.io/rook/ceph:${EXP_OP}"

# ---- stage-specific ------------------------------------------------------------------------------------------
if [ "$STAGE" != stage0 ]; then
  # New SAs must be covered by the SCC users list or by a binding to a ClusterRole that can `use` the SCC.
  SCC_USERS="$(ocr get scc $SCC -o json | jq -r '.users // [] | join(" ")' 2>/dev/null)"
  RB_JSON="$(ocr -n $NS get rolebindings -o json)"
  CRB_JSON="$(ocr get clusterrolebindings -o json)"
  CR_JSON="$(ocr get clusterroles -o json)"
  for sa in "$NEW_CTRL_SA" "$NEW_NODE_SA"; do
    how=""
    case " $SCC_USERS " in *" system:serviceaccount:${NS}:${sa} "*) how="scc-users" ;; esac
    if [ -z "$how" ]; then
      roles="$( { echo "$RB_JSON"; echo "$CRB_JSON"; } | jq -r --arg sa "$sa" --arg ns "$NS" \
        '.items[]? | select(any(.subjects[]?; .kind=="ServiceAccount" and .name==$sa and (.namespace // "")==$ns)) | select(.roleRef.kind=="ClusterRole") | .roleRef.name' 2>/dev/null | sort -u)"
      for r in $roles; do
        if echo "$CR_JSON" | jq -e --arg r "$r" --arg scc "$SCC" \
          '.items[]? | select(.metadata.name==$r) | .rules[]? | select((.resources // [] | index("securitycontextconstraints")) and (.verbs // [] | (index("use") or index("*"))) and ((.resourceNames // []) | (length==0 or index($scc))))' >/dev/null 2>&1; then
          how="clusterrole:$r"; break
        fi
      done
    fi
    if [ -n "$how" ]; then report PASS "scc-grant-$sa" "$how"; else report FAIL "scc-grant-$sa" "not in SCC $SCC users and no binding to a ClusterRole with use on it"; fi
  done
fi

if [ "$STAGE" = stage2 ] || [ "$STAGE" = stage3 ] || [ "$STAGE" = stage4 ]; then
  expect_eq operator-config-CREATE_CSI_OPERATOR_RESOURCES \
    "$(ocr -n $NS get cm rook-ceph-operator-config -o jsonpath='{.data.ROOK_CREATE_CSI_OPERATOR_RESOURCES}')" "true"
  expect_eq cephconnection-exists "$(ocr -n $NS get cephconnections.csi.ceph.io rook-ceph -o jsonpath='{.metadata.name}')" "rook-ceph"
  expect_eq clientprofile-exists "$(ocr -n $NS get clientprofiles.csi.ceph.io rook-ceph -o jsonpath='{.metadata.name}')" "rook-ceph"
fi

if [ "$STAGE" = stage3 ] || [ "$STAGE" = stage4 ]; then
  CONN="$(ocr -n $NS get cephconnections.csi.ceph.io rook-ceph -o json)"
  CONN_OBS="$(echo "$CONN" | jq -r '(.spec.monitors // []) as $m | if ($m|length)==0 then "none" else ([$m[] | select(endswith(":3300")|not)] | if length==0 then "all:3300 (\($m|length))" else "non-3300: \(join(","))" end) end' 2>/dev/null || echo unreadable)"
  case "$CONN_OBS" in all:3300*) report PASS cephconnection-monitors-3300 "$CONN_OBS" ;; *) report FAIL cephconnection-monitors-3300 "$CONN_OBS" ;; esac
  CFG="$(ocr -n $NS get cm ceph-csi-config -o jsonpath='{.data.config\.json}')"
  CFG_OBS="$(echo "$CFG" | jq -r '[.[]?.monitors[]?] as $m | if ($m|length)==0 then "none" else ([$m[] | select(endswith(":3300")|not)] | if length==0 then "all:3300 (\($m|length))" else "non-3300: \(join(","))" end) end' 2>/dev/null || echo unreadable)"
  case "$CFG_OBS" in all:3300*) report PASS ceph-csi-config-monitors-3300 "$CFG_OBS" ;; *) report FAIL ceph-csi-config-monitors-3300 "$CFG_OBS" ;; esac
fi

if [ "$STAGE" = stage4 ]; then
  CEPHVER="$(ocr -n $NS get cephcluster -o jsonpath='{.items[0].status.version.version}')"
  case "$CEPHVER" in 20.2.5*) report PASS cephcluster-version "$CEPHVER" ;; *) report FAIL cephcluster-version "observed='$CEPHVER' expected=20.2.5*" ;; esac
fi

# ---- info ----------------------------------------------------------------------------------------------------
CEPHX="$(ocr -n $NS get cephcluster -o json | jq -c '.items[0].status.cephx // "none"' 2>/dev/null)"
MON_EP="$(ocr -n $NS get cm rook-ceph-mon-endpoints -o jsonpath='{.data.csi-cluster-config-json}' | jq -c '[.[]?.monitors[]?]' 2>/dev/null)"
echo "INFO rook-ceph-mon-endpoints-csi-monitors=${MON_EP:-unreadable} (informational only: Rook keeps :6789 for existing mons)"
echo "INFO driver-uid=$(echo "$DRV_JSON" | jq -r '.metadata.uid // "unknown"') driver-generation=$(echo "$DRV_JSON" | jq -r '.metadata.generation // "unknown"') cephx=${CEPHX:-unreadable}"

if [ "$FAILS" -eq 0 ]; then echo "RESULT PASS $STAGE"; exit 0; fi
echo "RESULT FAIL $STAGE ($FAILS failed)"
exit 1
