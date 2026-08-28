#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot pool creation for the TrueNAS box. NOT part of playbook.yml.
#
# WHY THIS IS NOT ANSIBLE: `pool.create` is a one-shot destructive job. Run
# twice it either errors, or -- against wiped disks -- silently builds a NEW
# empty pool where the old one was. The `truenas-storage` role therefore
# ASSERTS the pool and fails loudly if it is missing. This script is the
# genesis event that makes that assert satisfiable.
#
# WHY NOT A PASTED sdX LIST: SATA enumeration is not stable across reboots and
# the boot device is also SATA. A list captured today can name the boot disk
# tomorrow. So the member set is re-derived AT EXECUTION TIME and gated on:
#   - model matches exactly
#   - the disk is not already in a pool
#   - the disk is not in `boot.get_disks`
#   - the count is exactly $WANT
#   - no pool exists yet
# Any failure aborts before `pool.create` is called. Same fail-closed shape as
# the SSD-wipe gate in the root CLAUDE.md.
#
# Usage:  ./bootstrap-pool.sh            # dry run: gate + payload, no changes
#         ./bootstrap-pool.sh --create   # actually create, then verify
# ---------------------------------------------------------------------------
set -euo pipefail

HOST="${TRUENAS_HOST:-truenas_admin@192.168.1.25}"
POOL="${TRUENAS_POOL:-tank}"
MODEL="${TRUENAS_DISK_MODEL:-HUS726040ALA610}"
WANT="${TRUENAS_DISK_COUNT:-6}"
LAYOUT="${TRUENAS_RAID_LEVEL:-RAIDZ2}"

gate() {
  ssh -o ConnectTimeout=10 "$HOST" \
      POOL="$POOL" MODEL="$MODEL" WANT="$WANT" LAYOUT="$LAYOUT" 'bash -s' <<'REMOTE'
midclt call disk.query | python3 -c '
import sys, json, os, subprocess
disks = json.load(sys.stdin)
boot  = set(json.loads(subprocess.check_output(["midclt","call","boot.get_disks"])))
pools = [p["name"] for p in json.loads(subprocess.check_output(["midclt","call","pool.query"]))]

POOL, MODEL = os.environ["POOL"], os.environ["MODEL"]
WANT, LAYOUT = int(os.environ["WANT"]), os.environ["LAYOUT"]

cand  = [d for d in disks
         if d.get("model") == MODEL and d.get("pool") is None and d["name"] not in boot]
names = sorted(d["name"] for d in cand)

fail = []
if pools:              fail.append("a pool already exists: %s" % pools)
if len(names) != WANT: fail.append("expected %d disks, matched %d: %s" % (WANT, len(names), names))
if boot & set(names):  fail.append("BOOT DISK IN MEMBER SET: %s" % sorted(boot & set(names)))
if fail:
    sys.stderr.write("GATE FAILED:\n  " + "\n  ".join(fail) + "\n")
    sys.exit(1)

sys.stderr.write("gate passed - boot disk %s excluded; %s members:\n" % (sorted(boot), LAYOUT))
for d in sorted(cand, key=lambda x: x["name"]):
    sys.stderr.write("  %-5s %-12s %s GB\n" % (d["name"], d["serial"], round(d["size"]/1e9)))
print(json.dumps({"name": POOL, "encryption": False,
                  "topology": {"data": [{"type": LAYOUT, "disks": names}]}}))
'
REMOTE
}

PAYLOAD="$(gate)"
echo
echo "payload: $PAYLOAD"
echo

if [ "${1:-}" != "--create" ]; then
  echo "DRY RUN. Nothing changed. Re-run with --create to apply."
  exit 0
fi

echo ">>> creating pool '$POOL' (destructive, one-shot)"
ssh -o ConnectTimeout=10 "$HOST" midclt call pool.create "'$PAYLOAD'"

echo
echo ">>> verifying"
# ashift is NOT a pool.create parameter -- it is derived from the disks' sector
# size and is immutable per vdev. It can only be checked after the fact; 12 is
# correct for these 512e drives, 9 would mean a rebuild is the only fix.
ssh -o ConnectTimeout=10 "$HOST" "zpool status -v $POOL; zpool get ashift $POOL; zpool list -o name,size,alloc,free,cap $POOL"
