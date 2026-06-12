# Rook does not propagate a `deviceClass` change to an existing pool's CRUSH rule

**Target:** github.com/rook/rook — Bug report
**Rook version:** operator v1.20.0 (cluster subchart render v1.19.5), Ceph Squid v19.2.4
**Discovered:** 2026-06-12 (HDD-tier rollout, RGW dataPool NVMe→HDD flip)

## Summary

Changing `deviceClass` on an **existing** pool (here a `CephObjectStore.spec.dataPool`,
but the same applies to `CephBlockPool.spec.deviceClass`) updates the CR and is accepted
by the operator's pool reconcile, **but the pool's CRUSH rule is never changed**, so no
data placement change or rebalance occurs. The change silently no-ops at the Ceph layer.

## Steps to reproduce

1. Have a `CephObjectStore` (or `CephBlockPool`) with `dataPool.deviceClass: nvme` and live data.
2. Change it to `deviceClass: hdd` and apply.
3. Operator reconciles: logs `reconciling replicated pool <pool> succeeded` and a struct diff
   `DeviceClass: "nvme" -> "hdd"`; it updates other pool properties (e.g. `pg_num_min`).
4. Inspect the pool's CRUSH rule:
   ```
   ceph osd crush rule dump <pool>   # still: step take default class nvme
   ```
   No new rule, no rebalance — data stays on the original device class.

## Expected

When `deviceClass` changes on an existing pool, Rook should update (or replace) the pool's
CRUSH rule to select the new device class, triggering Ceph's normal backfill — the same way
it sets the class-specific rule at pool creation.

## Actual

Rook sets the device-class CRUSH rule only at pool **creation**. On a later `deviceClass`
change it reconciles pool *properties* but leaves the CRUSH rule pointing at the original
class. The CR and the live placement silently diverge. An operator restart re-runs the same
no-op path (it does not re-derive the rule for an existing pool).

## Workaround

Manual one-time toolbox commands to create a class-specific rule and repoint the pool:

```bash
ceph osd crush rule create-replicated <pool>-hdd default host hdd
ceph osd pool set <pool> crush_rule <pool>-hdd
```

This triggers the intended backfill. The original Rook-created rule (`<pool>`, still on the
old class) is left orphaned (cosmetic; Rook does not reconcile/remove it).

## Impact

GitOps users who express the device tier declaratively (`deviceClass: hdd` in the chart) get
a silent no-op: the manifest says one thing, the live placement is another, with no error or
event. Particularly relevant to HDD-tiering migrations of existing object/block pools.

## Notes

Same operational family as Rook not clearing `public_network`/`cluster_network` from the Ceph
config DB on a `network.provider` change. Both are "reconcile applied the property delta but
not the downstream Ceph object" gaps.
