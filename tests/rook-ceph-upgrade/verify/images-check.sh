#!/usr/bin/env bash
# Check that images are available through the zot pull-through mirror (this also makes zot fetch them).
#
#   bash tests/rook-ceph-upgrade/verify/images-check.sh quay.io/ceph/ceph:v20.2.5-20261028 docker.io/rook/ceph:v1.21.1 ...
#
# zot mirrors by registry host only: the host is dropped and the rest is requested from zot.apps.okd.sudops.pl.
# Prints `IMAGE OK|MISSING <ref>`; exits non-zero if any is MISSING or the input is malformed.
set -u
ZOT=zot.apps.okd.sudops.pl
SKOPEO="$(command -v skopeo || echo /opt/homebrew/bin/skopeo)"
[ $# -ge 1 ] || { echo "usage: $0 <image>..." >&2; exit 2; }
[ -x "$SKOPEO" ] || { echo "skopeo not found" >&2; exit 2; }

rc=0
for ref in "$@"; do
  rest="${ref#*/}"                       # drop the registry host
  if [ "$rest" = "$ref" ] || [[ "$rest" != *:* ]] || [[ "$rest" == *@* ]]; then
    echo "IMAGE MISSING $ref (need registry/path:tag, no digest)"; rc=1; continue
  fi
  if "$SKOPEO" inspect --raw "docker://${ZOT}/${rest}" >/dev/null 2>&1; then
    echo "IMAGE OK $ref"
  else
    echo "IMAGE MISSING $ref"; rc=1
  fi
done
exit $rc
