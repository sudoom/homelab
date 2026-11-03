#!/usr/bin/env bash
# Operator-run Ceph state capture (needs `oc exec`, so the operator runs it, never an agent).
#
#   bash tests/rook-ceph-upgrade/verify/ceph-reads.sh <label>
#
# Writes .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/ceph-reads-<label>-<UTC>.txt (never committed).
# jq runs here on the Mac, not in the toolbox. CephX key material is stripped by the jq filters; the final
# self-check deletes the file and exits 2 if anything shaped like a CephX key is still in it.
set -u -o pipefail

[ $# -eq 1 ] || { echo "usage: $0 <label>" >&2; exit 2; }
LABEL="$1"
case "$LABEL" in *[!A-Za-z0-9._-]*|"") echo "label must match [A-Za-z0-9._-]+" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$ROOT/.superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence"
mkdir -p "$DIR"
OUT="$DIR/ceph-reads-${LABEL}-$(date -u +%Y%m%dT%H%M%SZ).txt"
NS=rook-ceph
: > "$OUT"

# tool <ceph args...>: run a ceph command in the toolbox, stdout only to stdout, stderr kept visible in the file.
tool() { oc -n "$NS" exec deploy/rook-ceph-tools -- "$@"; }
section() { printf '\n===== %s =====\n' "$1" >> "$OUT"; }
# grep_read <pattern> <ceph args...>: grep exit 1 (no match) is a legitimate empty result, not a failure;
# only a failed ceph command or grep exit >= 2 is READ-FAILED.
grep_read() {
  local pat="$1"; shift
  tool "$@" 2>>"$OUT" | grep -E "$pat" >> "$OUT"
  local st=("${PIPESTATUS[@]}")
  if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ge 2 ]; then echo "READ-FAILED rc=${st[0]}/${st[1]}" >> "$OUT"
  elif [ "${st[1]}" -eq 1 ]; then echo "(no match, ceph command ok)" >> "$OUT"; fi
}

section "ceph versions";        tool ceph versions >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph health detail";   tool ceph health detail >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph -s";              tool ceph -s >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph df";              tool ceph df >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph osd tree";        tool ceph osd tree >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph mon dump";        tool ceph mon dump >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph mon dump -f json | jq auth_service_cipher.name"
tool ceph mon dump -f json 2>>"$OUT" | jq -r '.auth_service_cipher.name // "unset"' >> "$OUT" 2>&1 || echo "READ-FAILED or no output, rc=$?" >> "$OUT"
section "ceph osd dump | grep require_osd_release|flags"
grep_read 'require_osd_release|flags' ceph osd dump
section "ceph config dump | grep rbd_default_map_options|ms_"
grep_read 'rbd_default_map_options|ms_' ceph config dump
section "ceph auth get client.csi-rbd-provisioner.1 (key deleted)"
tool ceph auth get client.csi-rbd-provisioner.1 -f json 2>>"$OUT" | jq 'map(del(.key))' >> "$OUT" 2>&1 || echo "READ-FAILED or no output, rc=$?" >> "$OUT"
# Ceph docs: `ceph auth ls -f json` is {"auth_dump":[{"entity":"client.x","key":"AQ...","caps":{...}}]}. The
# shape of `auth dump-keys` is not verified on this cluster, so this filter keeps only .entity / .name and the
# type derived from it, and deletes every other field; the self-check below is the safety net.
section "ceph auth dump-keys (entity names and key type only)"
tool ceph auth dump-keys -f json 2>>"$OUT" | jq -c '
  def ents: if type=="array" then .[] elif type=="object" and has("auth_dump") then .auth_dump[] elif type=="object" then to_entries[] | (.value + {entity: .key}) else . end;
  [ ents | objects | {entity: (.entity // .name // "unknown"), type_str: (.type_str // ((.entity // .name // "") | split(".")[0]))} ]' >> "$OUT" 2>&1 \
  || echo "READ-FAILED or no output, rc=$?" >> "$OUT"
section "ceph mgr module ls | head -20"
tool ceph mgr module ls 2>>"$OUT" | head -20 >> "$OUT" || echo "READ-FAILED or no output, rc=$?" >> "$OUT"

# Self-check: no CephX key may be on disk.
if grep -Eq 'AQ[A-Za-z0-9+/]{20,}' "$OUT"; then
  rm -f "$OUT"
  echo "ceph-reads: CephX key material matched in the capture; file deleted. Fix the jq filters before re-running." >&2
  exit 2
fi
echo "wrote $OUT"
