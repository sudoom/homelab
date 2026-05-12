# `network.provider` change does not clear `public_network` / `cluster_network` from Ceph config DB, causing OSDs to crashloop after the daemon roll

**Upstream:** https://github.com/rook/rook
**Component:** `cluster-controller` / network reconciliation
**Affected version:** Rook v1.18 with Ceph Squid 19.2.3 (deployed on OKD 4.20 / Kube 1.31)
**Severity:** Functional — first OSD rolled to the new network shape crashloops indefinitely until manual cleanup of the Ceph config DB. On a low-OSD-count cluster (3 OSDs, `min_size: 2`), this creates a chicken-and-egg deadlock with Rook's own safety check; recovery requires bypassing the operator with a manual `oc patch`.

## Summary

When a `CephCluster`'s `spec.network.provider` is changed (specifically `host → ""` as the documented first step of a `host → multus` migration), Rook updates the daemon Deployments to remove `hostNetwork: true` — but does **not** clear the corresponding `public_network` / `cluster_network` settings from the Ceph config database (`ceph config dump | grep public_network`). The first OSD daemon rolled to the new (pod-network) shape then reads the stale `public_network = <host CIDR>` from the mons' KV store at startup, fails to find a matching interface on the pod's net namespace, and refuses to start with:

```
unable to find any IPv4 address in networks '192.168.1.0/24' interfaces ''
Failed to pick public address.
```

…in a tight crashloop. On a 3-OSD-no-drain cluster, this is exposes a second, deeper bug: see "Cascading failure" below.

## Steps to reproduce

(Reproducer for the *primary* config-DB-stale issue. The cascading failure described later is topology-specific.)

1. Stand up a Rook v1.18 cluster with `CephCluster.spec.network.provider: host` and explicit `addressRanges.public: ["<host-CIDR>"]`. Wait for `HEALTH_OK`. Verify the config DB:
   ```
   ceph config dump | grep public_network
   # → global  advanced  public_network  <host-CIDR>  *
   ```
2. Edit the `CephCluster` to set `spec.network.provider: ""` (empty string) and remove the `addressRanges` block (required — Rook's operator-side validator rejects `addressRanges` for any provider other than `host` or `multus`).
3. Wait for Rook's reconciler to apply the new Deployment specs. The active mgr swap finishes cleanly. When the first OSD rolls (Deployment template updated, pod recreated with `hostNetwork: false` + pod IP), observe the OSD container immediately crashloops with the `Failed to pick public address` error above.
4. Verify the config DB still has the old setting:
   ```
   ceph config dump | grep public_network
   # → global  advanced  public_network  <host-CIDR>  *   ← still there
   ```

## Expected behavior

When `spec.network.provider` changes, the Rook cluster controller should update the Ceph config DB to match the new network shape:

- For `provider: host` with `addressRanges.public/cluster`, set `public_network` and `cluster_network` to those CIDRs (current behavior; works on initial install).
- For `provider: ""`, remove `public_network` and `cluster_network` from the config DB (so daemons bind to any available interface — the only sensible thing on pod-only networking).
- For `provider: multus` with `addressRanges.public/cluster`, set the config DB values to the Multus NAD CIDRs.

The third case probably works (we never got that far in the failing migration). The second case is what's broken.

## Actual behavior

The cluster controller updates Deployment shape but does not touch the Ceph config DB on a `host → ""` transition. Stale `public_network = <host-CIDR>` persists. First OSD on the new shape crashloops.

## Workaround

From the Rook toolbox, before or immediately after the network provider change:

```
ceph config rm global public_network
ceph config rm global cluster_network
```

After this, OSD daemons starting on the new (pod-network) shape bind to any available interface. Subsequent reconciles by the operator (when `provider` is later set back to `host` or to `multus` with `addressRanges`) re-set the values correctly.

## Cascading failure on `min_size: 2` clusters (worth documenting separately, but driven by the same bug)

After clearing the stale config DB entry and letting the first OSD come up on its pod IP, a second failure mode appears on small clusters with no drain headroom:

- OSD-0 is now advertising a pod IP (e.g. `10.x.x.x`)
- OSD-1, OSD-2 are still on host network (`192.168.1.x` + `192.168.10.x`)
- mons are still on host network

PG peering between the asymmetrically-addressed OSDs hangs indefinitely (220/220 PGs stuck `peering`, slow ops climbing monotonically). The connectivity exists (OVN passes pod↔host traffic in both directions) but msgr2 session establishment between mixed-network peers stalls without ever timing out hard enough to fail-and-retry-elsewhere.

Rook's `ceph osd ok-to-stop` safety check then refuses to roll *any* OSD because peering is unhealthy — including OSD-0, which needs to be rolled to a homogenous network shape to fix the hang. Chicken-and-egg deadlock. On a 3-OSD `min_size: 2` cluster, manually force-rolling two OSDs simultaneously risks a data-availability outage.

Escape required `oc patch` directly on the OSD-0 Deployment to set `hostNetwork: true`, bypassing Rook's blocked safety gate:

```
oc -n rook-ceph patch deploy rook-ceph-osd-0 --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/hostNetwork","value":true}]'
```

This patched state matches what Rook *wanted* to apply (per its current desired spec post-rollback), just without the blocked ok-to-stop check. New OSD-0 pod came up on host network, mons learned the host address, peering resumed within seconds.

## Implications / suggestions

The primary `public_network` config-DB-stale bug is independently fixable in the Rook cluster controller: on a `provider` change, reconcile the corresponding Ceph config DB keys to match.

The cascading deadlock with `ok-to-stop` is harder to address generically — it's a fundamental tension between "don't kill quorum-or-replication-critical daemons" and "the only way out of a stuck network shape is to kill a daemon". Possible directions:

- An explicit `force-network-provider-change` annotation or CR field that bypasses the ok-to-stop check for the duration of a network provider transition. Dangerous, but at least makes the operator's behavior debuggable rather than silently deadlocked.
- Better operator messaging: when `ok-to-stop` has been blocking for >N minutes during a network change, log a specific error pointing operators to the manual escape rather than just `OSD N is not ok-to-stop. will try updating it again later` indefinitely.
- Document explicitly that the `host → "" → multus` path is not safe on clusters with `< (min_size + 1)` OSDs per failure domain.

## Local context

- 3-node OKD 4.20 cluster, 3 OSDs (one per node), `replicated_rule_nvme` CRUSH rule on `host` failure domain.
- Rook v1.18.x via `rook-ceph` Helm chart; CephCluster CR vendored locally.
- Failure observed 2026-05-12 during a planned `provider: host → multus` migration. Full chronology in the cluster's `blog/blog-multus-ceph-migration-draft.md` (Phase 2 section).
