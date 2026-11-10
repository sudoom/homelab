#!/usr/bin/env bash
# OPERATOR: etcd consistency read across the three members (okd#2384). Runbook README.md, sections 2, 5.2 and 6.
#
#   bash tests/okd-5.0-upgrade/etcd-consistency.sh <label> [--out-dir DIR]
#
# Needs `oc exec` into an etcd pod, so it runs on the operator's kubeconfig, not the readonly SA.
# In the etcdctl container of one Ready etcd pod it reads `etcdctl endpoint status --cluster -w json` (revision,
# raftIndex, raftAppliedIndex, dbSize, dbSizeInUse per member), then `etcdctl endpoint hashkv --cluster
# --rev=<lowest revision of the members>`. Equal hash and equal compact_revision on all three members = CONSISTENT.
# (Without --rev each member hashes its own latest revision, so a live cluster always reads as diverged.)
# Writes <out-dir>/etcd-<label>-<UTC>.txt holding only member URLs, node names and those numbers: no Secret, key or
# certificate content (etcdctl takes its TLS files from the container's environment; nothing of it is printed).
# Last line and exit status:
#   CONSISTENT    0  equal hash and compact_revision on all three
#   DIVERGED      1  equal compact_revision, different hash: the okd#2384 signature. Runbook "okd#2384 recovery".
#   INCONCLUSIVE  2  a read failed, fewer than 3 members answered, or compact_revision differed on both attempts
#                    (a compaction landed mid-read; the read is retried once on its own). Re-run once; twice = stop.
# Default out-dir: $EVIDENCE_DIR, else <repo>/.superpowers/sdd/2026-11-10-okd-5.0-upgrade/evidence.
# Test only: --fixture-dir DIR reads DIR/status[-N].json and DIR/hashkv[-N].json (N = attempt) instead of exec.
set -u -o pipefail

usage() { sed -n '2,19p' "$0" >&2; exit 2; }
LABEL=""; OUT_DIR=""; FIXTURE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) [ $# -ge 2 ] || usage; OUT_DIR="$2"; shift ;;
    --fixture-dir) [ $# -ge 2 ] || usage; FIXTURE_DIR="$2"; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$LABEL" ] || usage; LABEL="$1" ;;
  esac
  shift
done
[ -n "$LABEL" ] || usage
case "$LABEL" in *[!A-Za-z0-9._-]*) echo "label: letters, digits, . _ - only" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
[ -n "$FIXTURE_DIR" ] || command -v oc >/dev/null 2>&1 || { echo "oc not found" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-${EVIDENCE_DIR:-$REPO_ROOT/.superpowers/sdd/2026-11-10-okd-5.0-upgrade/evidence}}"
mkdir -p "$OUT_DIR" || exit 2
UTC="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/etcd-$LABEL-$UTC.txt"
ERR_F="$(mktemp "${TMPDIR:-/tmp}/okd50-etcd.XXXXXX")" || exit 2
trap 'rm -f "$ERR_F"' EXIT

out() { printf '%s\n' "$*" >> "$OUT"; }
finish() { # finish <verdict> <exit> <detail>
  out "VERDICT $1 $3"
  echo "evidence: $OUT"
  echo "$1 $3"
  exit "$2"
}

# Member URL -> node name, from the etcd pods' host IPs (empty in fixture mode).
POD=""; HOSTMAP='{}'
if [ -z "$FIXTURE_DIR" ]; then
  PODS_JSON="$(oc -n openshift-etcd get pods -l app=etcd --request-timeout=30s -o json 2>"$ERR_F")" || { out "pod list failed"; finish INCONCLUSIVE 2 "cannot list etcd pods: $(head -1 "$ERR_F")"; }
  POD="$(printf '%s' "$PODS_JSON" | jq -r '[.items[] | select(.status.phase == "Running")
    | select(any(.status.containerStatuses[]?; .name == "etcdctl" and .ready == true)) | .metadata.name] | first // empty')"
  HOSTMAP="$(printf '%s' "$PODS_JSON" | jq -c '[.items[] | {(.status.hostIP // "?"): (.spec.nodeName | split(".")[0])}] | add // {}')"
  [ -n "$POD" ] || { out "no etcd pod with a ready etcdctl container"; finish INCONCLUSIVE 2 "no Ready etcd pod"; }
fi

ATTEMPT=1
ectl() { # ectl <etcdctl args...>
  if [ -n "$FIXTURE_DIR" ]; then
    local kind
    case "$1 $2" in "endpoint status") kind=status ;; "endpoint hashkv") kind=hashkv ;; *) return 1 ;; esac
    if [ -f "$FIXTURE_DIR/$kind-$ATTEMPT.json" ]; then cat "$FIXTURE_DIR/$kind-$ATTEMPT.json"; else cat "$FIXTURE_DIR/$kind.json"; fi
    return
  fi
  oc -n openshift-etcd exec "$POD" -c etcdctl -- etcdctl --command-timeout=60s "$@"
}

out "# etcd consistency read: label=$LABEL utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) pod=${POD:-fixture:$FIXTURE_DIR}"
while :; do
  out "## attempt $ATTEMPT"
  STATUS="$(ectl endpoint status --cluster -w json 2>"$ERR_F")" || { out "endpoint status failed: $(head -1 "$ERR_F")"; finish INCONCLUSIVE 2 "endpoint status failed: $(head -1 "$ERR_F")"; }
  printf '%s' "$STATUS" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || { out "endpoint status: not a JSON array"; finish INCONCLUSIVE 2 "endpoint status unreadable"; }
  out "member	node	revision	raftIndex	raftAppliedIndex	dbSize	dbSizeInUse"
  printf '%s' "$STATUS" | jq -r --argjson h "$HOSTMAP" '.[] | [.Endpoint, ($h[(.Endpoint | sub("^https?://"; "") | sub(":[0-9]+$"; ""))] // "-"),
      .Status.header.revision, .Status.raftIndex, .Status.raftAppliedIndex, .Status.dbSize, .Status.dbSizeInUse] | @tsv' >> "$OUT"
  NST="$(printf '%s' "$STATUS" | jq 'length')"
  REV="$(printf '%s' "$STATUS" | jq '[.[].Status.header.revision] | min')"
  out "$(printf '%s' "$STATUS" | jq -r '"spread: revision max-min=\([.[].Status.header.revision] | max - min), raftAppliedIndex max-min=\([.[].Status.raftAppliedIndex] | max - min) (one read; compare across reads: a revision gap that keeps growing while raftAppliedIndex stays in lockstep is the okd#2384 incident-1 signature)"')"

  HASHKV="$(ectl endpoint hashkv --cluster --rev="$REV" -w json 2>"$ERR_F")" || { out "endpoint hashkv --rev=$REV failed: $(head -1 "$ERR_F")"; finish INCONCLUSIVE 2 "endpoint hashkv failed: $(head -1 "$ERR_F")"; }
  printf '%s' "$HASHKV" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || { out "endpoint hashkv: not a JSON array"; finish INCONCLUSIVE 2 "endpoint hashkv unreadable"; }
  out "hashkv --rev=$REV"
  out "member	node	hash	compact_revision	hash_revision"
  printf '%s' "$HASHKV" | jq -r --argjson h "$HOSTMAP" '.[] | [.Endpoint, ($h[(.Endpoint | sub("^https?://"; "") | sub(":[0-9]+$"; ""))] // "-"),
      .HashKV.hash, .HashKV.compact_revision, .HashKV.hash_revision] | @tsv' >> "$OUT"
  NHK="$(printf '%s' "$HASHKV" | jq 'length')"
  UH="$(printf '%s' "$HASHKV" | jq '[.[].HashKV.hash] | unique | length')"
  UC="$(printf '%s' "$HASHKV" | jq '[.[].HashKV.compact_revision] | unique | length')"

  if [ "$NST" != 3 ] || [ "$NHK" != 3 ]; then finish INCONCLUSIVE 2 "members answering: status=$NST hashkv=$NHK (expect 3)"; fi
  if [ "$UC" = 1 ] && [ "$UH" = 1 ]; then
    finish CONSISTENT 0 "3 members, hash $(printf '%s' "$HASHKV" | jq '.[0].HashKV.hash') at rev $REV, compact_revision $(printf '%s' "$HASHKV" | jq '.[0].HashKV.compact_revision')"
  fi
  if [ "$UC" = 1 ]; then
    HGROUPS="$(printf '%s' "$HASHKV" | jq -r --argjson h "$HOSTMAP" 'group_by(.HashKV.hash) | sort_by(-length)
      | map("hash \(.[0].HashKV.hash): " + (map($h[(.Endpoint | sub("^https?://"; "") | sub(":[0-9]+$"; ""))] // .Endpoint) | join(","))) | join(" | ")')"
    out "hash groups (largest first): $HGROUPS"
    finish DIVERGED 1 "equal compact_revision, different hash at rev $REV: $HGROUPS (the minority member is the suspect; runbook okd#2384 recovery)"
  fi
  out "compact_revision differs between members: a compaction landed mid-read"
  if [ "$ATTEMPT" -ge 2 ]; then finish INCONCLUSIVE 2 "compact_revision differed on both attempts; re-run once, twice = stop and ask"; fi
  ATTEMPT=$((ATTEMPT + 1))
done
