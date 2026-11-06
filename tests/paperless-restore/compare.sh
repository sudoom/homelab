#!/usr/bin/env bash
# Compare the live paperless with the restored throwaway through their APIs (README step 5).
#
# Pass: the same document count on both, and identical sets of `original_checksum` (the MD5 of
# each original file, from /api/documents/<id>/metadata/). Prints counts and the verdict only:
# no titles, no file names, no checksums.
#
# The password goes to curl through a config on stdin, not argv, so it stays out of `ps`.
set -euo pipefail

LIVE="${PAPERLESS_LIVE:-http://192.168.1.25:30070}"
RESTORE="${PAPERLESS_RESTORE:-http://192.168.1.25:30071}"

read -rp "paperless user on both [admin]: " USER_NAME
USER_NAME="${USER_NAME:-admin}"
read -rsp "password (input hidden): " PASSWORD
echo

api() {  # api <base-url> <path>
  printf 'user = "%s:%s"\n' "$USER_NAME" "$PASSWORD" | curl -fsS --config - "$1$2"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for side in live restore; do
  if [ "$side" = live ]; then base="$LIVE"; else base="$RESTORE"; fi
  if ! api "$base" "/api/documents/?page_size=1" > "$WORK/$side.page1" 2> "$WORK/$side.err"; then
    echo "$side: API call failed ($(tr -d '\n' < "$WORK/$side.err" | cut -c1-160))"
    echo "  On the restore side this most likely means the live account was not imported; record it."
    exit 1
  fi
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["count"])' "$WORK/$side.page1" > "$WORK/$side.count"
  api "$base" "/api/documents/?page_size=100000&fields=id" \
    | python3 -I -c 'import json,sys; [print(d["id"]) for d in json.load(sys.stdin)["results"]]' > "$WORK/$side.ids"
  while read -r id; do
    api "$base" "/api/documents/$id/metadata/" \
      | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["original_checksum"])'
  done < "$WORK/$side.ids" | sort > "$WORK/$side.sums"
done

live_n=$(cat "$WORK/live.count"); restore_n=$(cat "$WORK/restore.count")
echo "documents: live=$live_n restore=$restore_n"
echo "checksums read: live=$(wc -l < "$WORK/live.sums" | tr -d ' ') restore=$(wc -l < "$WORK/restore.sums" | tr -d ' ')"
only_live=$(comm -23 "$WORK/live.sums" "$WORK/restore.sums" | wc -l | tr -d ' ')
only_restore=$(comm -13 "$WORK/live.sums" "$WORK/restore.sums" | wc -l | tr -d ' ')
echo "checksums only on live: $only_live, only on restore: $only_restore"

if [ "$live_n" = "$restore_n" ] && [ "$only_live" = 0 ] && [ "$only_restore" = 0 ]; then
  echo "PASS: same count, identical original_checksum sets"
else
  echo "FAIL"
  exit 1
fi
