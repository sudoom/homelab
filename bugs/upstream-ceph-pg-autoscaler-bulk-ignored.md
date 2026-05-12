# pg_autoscaler returns empty `autoscale-status` and ignores `bulk: true` on Squid 19.2.3

**Upstream:** https://github.com/ceph/ceph
**Component:** `mgr/pg_autoscaler`
**Affected version:** Ceph Squid 19.2.3 (deployed via Rook v1.18 on OKD 4.20 / Kube 1.31)
**Severity:** Functional — autoscaler is silently inert; pools stay at `pg_num: 1` indefinitely until manually bumped.

## Summary

On a 3-OSD NVMe cluster with `device_class=nvme` CRUSH rules, creating a pool with `bulk: true` set does not cause the autoscaler to recommend (or apply) a `pg_num` increase. `ceph osd pool autoscale-status` returns `[]` (empty array) for the pool — not even a row showing the pool with `BIAS` / `PG_NUM` / `NEW PG_NUM` columns. The active mgr restart (`ceph mgr fail`) does not help.

Confirmed twice on the same cluster:

1. **`nvme-replicated`** pool (RBD-backing, `size=3`, `min_size=2`, CRUSH rule on `device_class=nvme`, `bulk: true`). Created at cluster bootstrap; stuck at `pg_num: 1`. Worked around by setting `pg_num_min: 128` in the Rook `CephBlockPool` chart, but doing so directly is rejected by Ceph (`EINVAL: pg_num_min must not be greater than current pg_num`). Required a one-time toolbox bump:
   ```
   ceph osd pool set nvme-replicated pg_num 128
   ceph osd pool set nvme-replicated pgp_num 128
   ```
   …after which `pg_num_min` enforcement from the chart took hold.

2. **`ceph-objectstore.rgw.buckets.data`** pool (RGW data pool, same CRUSH rule, `bulk: true`). Hit the identical issue on 2026-05-10. Same workaround needed (`pg_num 32; pgp_num 32`, then `pg_num_min: 32` from the Rook chart).

Both pools target the autoscaler-recommended floor of 128 / 32 PGs (per Ceph's `100 PGs/OSD × OSDs / replication` formula → next power of 2). The autoscaler itself never makes a recommendation.

## Steps to reproduce

(Approximation — exact reproducer in a clean upstream Ceph cluster would require setting up Squid 19.2.3 with a small device-class CRUSH topology.)

1. Stand up a Squid 19.2.3 cluster with at least 3 OSDs of a single device class (e.g. `nvme`).
2. Create a replicated pool with `bulk: true` set and a CRUSH rule targeting that device class. Example via Rook `CephBlockPool`:
   ```yaml
   spec:
     deviceClass: nvme
     replicated:
       size: 3
       requireSafeReplicaSize: true
     parameters:
       bulk: "true"
   ```
3. Wait for the pool to settle (`ceph osd pool ls detail` shows it created with `pg_num: 1`).
4. `ceph osd pool autoscale-status`

## Expected behavior

The pool appears in the `autoscale-status` table with a `NEW PG_NUM` column suggesting the formula-correct target (e.g. `128` for 3 OSDs × 100 PGs / 3-way replication, next power of 2). With `bulk: true`, the autoscaler should bias toward larger PG counts even for empty pools. The autoscaler then applies the recommendation over subsequent rebalance cycles.

## Actual behavior

`ceph osd pool autoscale-status` returns `[]`. The pool is silently absent from the output. `pg_num` stays at `1`. The `bulk` hint has no effect.

## Workaround

For each affected pool, after creating it via Rook (or directly):

1. Bump `pg_num` and `pgp_num` to the desired floor via the toolbox once:
   ```
   ceph osd pool set <pool> pg_num <floor>
   ceph osd pool set <pool> pgp_num <floor>
   ```
2. Enforce the floor going forward via `pg_num_min` in the pool spec (Rook chart `parameters.pg_num_min`, or `ceph osd pool set <pool> pg_num_min <floor>` directly).

This pattern works but requires one-time manual intervention per new pool — a GitOps regression that should not be necessary.

## Notes

- Tried `ceph mgr fail` to bounce the active mgr (forces re-init of all mgr modules including the autoscaler). No effect on the empty `autoscale-status`.
- Tried `ceph osd pool set <pool> pg_autoscale_mode on` explicitly (in case it was somehow `off` despite the default). Already `on`; no effect.
- The autoscaler is reporting *some* state for other pools — it's specifically the `bulk: true` pools that are absent from the output.
- Possible related: https://tracker.ceph.com/ search for `pg_autoscaler bulk` did not turn up an exact match for Squid 19.2.3 as of writing; worth confirming before filing.

## Local context where this was observed

- 3-node OKD 4.20 bare-metal cluster, 3× Samsung PM9A1 NVMe (one OSD per node).
- Rook v1.18 (rook-ceph-cluster helm chart + vendored manifests).
- Ceph image: `quay.io/ceph/ceph:v19.2.3`.
- Failure-domain CRUSH rule: `replicated_rule_nvme` on `host` failure domain, `device_class=nvme`.

Full chronology in the cluster's blog draft `blog/blog-rook-ceph-draft.md` (search "autoscale-status"), plus the RGW-side hit in `blog/blog-ceph-object-store-draft.md`.
