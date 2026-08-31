#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot destroy of an EMPTY dataset. NOT part of playbook.yml.
#
# WHY THIS EXISTS: three ZFS dataset properties are fixed at create and can
# never be changed -- `casesensitivity` above all, but also the practical
# starting state of `acltype`/`aclmode`. The `truenas-storage` role therefore
# ASSERTS them and fails loudly on drift, because the alternative (a reconcile
# task) would call `pool.dataset.update`, which accepts the key, silently does
# nothing, and reports `ok` forever. This script is the only thing that can
# make that assert satisfiable, and destroy + re-create is the only remedy.
#
# WHY IT ONLY DESTROYS: re-creation belongs to the playbook, which already
# knows every declared property. A script that also created would be a second
# definition of the same datasets, free to drift from group_vars. So the flow
# is deliberately two steps:
#
#     ./destroy-empty-dataset.sh timemachine --destroy
#     ansible-playbook -i inventory.yml playbook.yml
#
# WHY "EMPTY" IS IN THE NAME: it is the load-bearing gate, not a description.
# This property is only recoverable for free while the dataset holds nothing.
# Once data lands, the fix is copy-out / destroy / re-create / copy-back, and
# no flag here will do that for you.
#
# The gate is re-derived ON THE BOX AT EXECUTION TIME (never from a value
# pasted in today) and is fail-closed -- same shape as bootstrap-pool.sh and
# the SSD-wipe gate in the root CLAUDE.md.
#
# Usage:  ./destroy-empty-dataset.sh <name>             # dry run: gate only
#         ./destroy-empty-dataset.sh <name> --destroy   # actually destroy
#
#   <name> is relative to the pool: `timemachine`, not `tank/timemachine`.
# ---------------------------------------------------------------------------
set -euo pipefail

HOST="${TRUENAS_HOST:-truenas_admin@192.168.1.25}"
POOL="${TRUENAS_POOL:-tank}"
# An empty ZFS dataset is ~192 KiB of metadata, never 0. 1 MiB is comfortably
# above that and far below anything that could be real data.
EMPTY_MAX="${TRUENAS_EMPTY_MAX:-1048576}"

DS="${1:-}"
if [ -z "$DS" ] || [ "${DS#-}" != "$DS" ]; then
  echo "usage: $0 <dataset-name-relative-to-pool> [--destroy]" >&2
  exit 2
fi

gate() {
  ssh -o ConnectTimeout=10 "$HOST" \
      POOL="$POOL" DS="$DS" EMPTY_MAX="$EMPTY_MAX" 'bash -s' <<'REMOTE'
python3 - <<'PY'
import json, os, subprocess, sys

def call(*a):
    return json.loads(subprocess.check_output(["midclt", "call", *a]))

POOL, DS   = os.environ["POOL"], os.environ["DS"]
EMPTY_MAX  = int(os.environ["EMPTY_MAX"])
FULL       = "%s/%s" % (POOL, DS)
MOUNT      = "/mnt/" + FULL

fail = []

# --- never touch the pool root or anything the appliance owns -------------
# These are not "unlikely typos", they are the ones that would be
# catastrophic AND are a single keystroke away (`tank` vs `tank/work`).
if DS.strip() == "":
    fail.append("empty dataset name -- that would resolve to the pool root")
if DS.startswith(".system") or DS.startswith("ix-apps") or DS.startswith("/"):
    fail.append("%s is appliance-owned or an absolute path; refusing" % DS)

ds = call("pool.dataset.query", json.dumps([["id", "=", FULL]]))
if not ds:
    fail.append("dataset %s does not exist" % FULL)
else:
    d = ds[0]
    used = int(d["used"]["parsed"])
    if used > EMPTY_MAX:
        fail.append("NOT EMPTY: %s holds %s (%d bytes) -- this script only ever "
                    "destroys empty datasets" % (FULL, d["used"]["value"], used))

    # A child would be destroyed silently along with the parent by `zfs destroy
    # -r`, and `zfs destroy` without -r simply fails. Either way the operator
    # should be doing this one dataset at a time, deliberately, parent last.
    kids = [k["id"] for k in call("pool.dataset.query",
                                  json.dumps([["id", "^", FULL + "/"]]))]
    if kids:
        fail.append("has %d child dataset(s): %s -- destroy children first"
                    % (len(kids), kids))

# --- snapshots: an empty dataset with snapshots is not empty history ------
snaps = subprocess.run(["zfs", "list", "-H", "-t", "snapshot", "-r", "-o", "name", FULL],
                       capture_output=True, text=True)
snapnames = [x for x in snaps.stdout.split() if x]
if snapnames:
    fail.append("has %d snapshot(s): %s" % (len(snapnames), snapnames[:5]))

# --- still shared? destroying underneath a live share is how you get a ----
# --- share pointing at a path that quietly becomes a plain directory ------
for kind, meth, key in (("SMB", "sharing.smb.query", "path"),
                        ("NFS", "sharing.nfs.query", "path")):
    hit = [s for s in call(meth)
           if s.get(key) == MOUNT or str(s.get(key, "")).startswith(MOUNT + "/")]
    if hit:
        fail.append("%s share(s) still reference %s: %s"
                    % (kind, MOUNT, [s.get("name", s.get(key)) for s in hit]))

if fail:
    sys.stderr.write("GATE FAILED:\n  " + "\n  ".join(fail) + "\n")
    sys.exit(1)

d = ds[0]
sys.stderr.write(
    "gate passed - %s is empty (%s), 0 snapshots, 0 children, 0 shares\n"
    "  current: casesensitivity=%s acltype=%s aclmode=%s recordsize=%s quota=%s\n"
    % (FULL, d["used"]["value"],
       d["casesensitivity"]["value"], d["acltype"]["value"],
       d["aclmode"]["value"], d["recordsize"]["value"], d["quota"]["value"]))
print(FULL)
PY
REMOTE
}

TARGET="$(gate)"
echo
echo "target: $TARGET"
echo

if [ "${2:-}" != "--destroy" ]; then
  echo "DRY RUN. Nothing changed. Re-run with --destroy to apply."
  echo "After destroying, run the playbook to re-create it with the declared"
  echo "properties:  ansible-playbook -i inventory.yml playbook.yml"
  exit 0
fi

echo ">>> destroying '$TARGET' (irreversible, one-shot)"
# pool.dataset.delete is NOT a job method (verified against core.get_methods on
# 25.10.6), so no --job here -- unlike pool.create. Do not add it by analogy;
# midclt errors on --job for a non-job method.
ssh -o ConnectTimeout=10 "$HOST" TARGET="$TARGET" 'bash -s' <<'REMOTE'
# `recursive: false` because the gate already refused any dataset with children,
# and `force: false` so the middleware refuses a dataset that is busy rather
# than yanking it out from under whatever has it open.
midclt call pool.dataset.delete "$TARGET" '{"recursive": false, "force": false}'
REMOTE

echo
echo ">>> verifying it is gone (expect [])"
ssh -o ConnectTimeout=10 "$HOST" TARGET="$TARGET" 'bash -s' <<'REMOTE'
midclt call pool.dataset.query "[[\"id\",\"=\",\"$TARGET\"]]"
REMOTE
echo
echo "Now re-create it with the declared properties:"
echo "  ansible-playbook -i inventory.yml playbook.yml"
