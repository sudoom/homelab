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
command -v oc >/dev/null 2>&1 || { echo "oc not found" >&2; exit 2; }
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

section "ceph versions"
VERS="$(tool ceph versions 2>&1)"; VERS_RC=$?
printf '%s\n' "$VERS" >> "$OUT"
[ "$VERS_RC" -eq 0 ] || echo "READ-FAILED rc=$VERS_RC" >> "$OUT"
# Tentacle-or-later only if some daemon is not 19.x; unknown (read or parse failed) counts as "run it".
PRE_TENTACLE=0
if [ "$VERS_RC" -eq 0 ]; then
  [ "$(printf '%s' "$VERS" | jq -r '[.overall // {} | keys[]] | if length>0 and all(.[]; test("^ceph version 19\\.")) then "yes" else "no" end' 2>/dev/null)" = yes ] && PRE_TENTACLE=1
fi
section "ceph health detail";   tool ceph health detail >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph -s";              tool ceph -s >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph df";              tool ceph df >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph osd tree";        tool ceph osd tree >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph mon dump";        tool ceph mon dump >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph mon dump -f json | jq auth_service_cipher.name"
tool ceph mon dump -f json 2>>"$OUT" | jq -r '.auth_service_cipher.name // "unset"' >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
section "ceph osd dump | grep require_osd_release|flags"
grep_read 'require_osd_release|flags' ceph osd dump
section "ceph config dump | grep rbd_default_map_options|ms_"
grep_read 'rbd_default_map_options|ms_' ceph config dump
section "ceph auth get client.csi-rbd-provisioner.1 (key deleted)"
tool ceph auth get client.csi-rbd-provisioner.1 -f json 2>>"$OUT" | jq 'map(del(.key))' >> "$OUT" 2>&1 || echo "READ-FAILED rc=$?" >> "$OUT"
# Shape verified on 20.2.5 (key-free probe, operator 2026-11-10; evidence file dump-keys-shape-s4.txt):
#   {data: {version, rotating_version,
#           secrets: [{entity: {type, type_str, id}, auth: {key: {type, type_str, created}, pending_key: {...},
#                      caps: [{service_name, access_spec}]}}],
#           rotating_secrets: [{entity: {...}, secrets: {max_ver, keys: [{id, expiring_key: {expiration,
#                      key: {type, type_str, created}}}]}}]}}
# The filter is an allowlist: it builds new objects from named fields only (entity "<type_str>.<id>", key type
# names) and never passes a whole sub-object through. An empty or missing .data.secrets is a changed shape and is
# reported as READ-FAILED. The self-check below stays as the safety net.
section "ceph auth dump-keys (entity names and key type only)"
if [ "$PRE_TENTACLE" -eq 1 ]; then
  echo "READ-SKIPPED (pre-Tentacle, dump-keys needs 20.2.4+)" >> "$OUT"
else
tool ceph auth dump-keys -f json 2>>"$OUT" | jq -r '
  def s: if type=="string" then . elif type=="number" then tostring else "?" end;
  if ((.data.secrets // []) | length) == 0 then "READ-FAILED unexpected dump-keys shape"
  else
    ( .data.secrets[]
      | {entity: "\(.entity.type_str | s).\(.entity.id | s)", key_type: (.auth.key.type_str | s)}
        + (if .auth.pending_key != null then {pending_key_type: (.auth.pending_key.type_str | s)} else {} end)
      | tojson ),
    ( (.data.rotating_secrets // [])[]
      | {service: (.entity.type_str | s), key_types: ([.secrets.keys[]?.expiring_key.key.type_str | s] | unique)}
      | tojson )
  end' >> "$OUT" 2>&1 \
  || echo "READ-FAILED rc=$?" >> "$OUT"
fi
section "ceph mgr module ls | head -20"
# Read fully first, then truncate: head closing early under pipefail would report SIGPIPE (141) as a failure.
MGR="$(tool ceph mgr module ls 2>>"$OUT")" && printf '%s\n' "$MGR" | sed -n '1,20p' >> "$OUT" \
  || echo "READ-FAILED rc=$?" >> "$OUT"

# Self-check: no CephX key may be on disk. Three shapes: the AES key prefix `AQ...`; any AES key (28 raw bytes =
# 40 base64 chars ending `==`); any AES256K key (2+8+2+32 = 44 raw bytes = 60 chars ending `=`, Tentacle daemon
# keys). The mandatory padding keeps a 40-hex git sha (`ceph versions`) or a 64-hex sha256 from matching.
KEYRE='AQ[A-Za-z0-9+/]{20,}|(^|[^A-Za-z0-9+/])([A-Za-z0-9+/]{38}==|[A-Za-z0-9+/]{59}=)($|[^A-Za-z0-9+/=])'
if grep -Eq "$KEYRE" "$OUT"; then
  rm -f "$OUT"
  echo "ceph-reads: CephX key material matched in the capture; file deleted. Fix the jq filters before re-running." >&2
  exit 2
fi
NFAIL="$(grep -c '^READ-FAILED' "$OUT")"
echo "$NFAIL reads failed"
echo "wrote $OUT"
[ "$NFAIL" -eq 0 ] || exit 1
