# CephObjectStore on OKD: an S3 endpoint inside the cluster

The homelab now has two S3-shaped consumers in the queue — Loki (the OKDerator-shipped Loki Operator's `LokiStack` requires object storage; no filesystem mode) and OADP (Velero-based PV + Kubernetes-resource backups, S3 destination). Both stalled at the same dependency: there's no S3 endpoint in the cluster.

Rook-Ceph's answer to that is `CephObjectStore` — a CR that creates an RGW deployment plus the two pools (metadata + data) it backs onto. This commit lands the CR; subsequent commits will land the operators that consume it.

## Why now, not after HDDs land

The original mental model was "wait for HDDs in the chassis, build `CephObjectStore` on HDD then." That's wrong on two counts:

1. **HDDs aren't a hard prerequisite.** RGW pools are just regular Ceph pools with a CRUSH rule on a device class. NVMe-only is a perfectly valid starting state — small, fast, and we have the headroom (cluster at 4% utilization, 175 GiB / 1.4 TiB used).
2. **The migration to HDD is one CRUSH-rule change.** Once HDDs exist, `dataPool.deviceClass: nvme` → `hdd` in the CR, Rook updates the CRUSH rule, Ceph rebalances data over the storage backnet. RGW endpoint, bucket names, secrets, client config — all unchanged. Clients don't notice.

So the path is: ship S3 on NVMe today, unblock Loki + OADP today, flip the data pool's device class to HDD when the chassis has them. **The metadata pool stays on NVMe permanently** — it's small, IO-hot, and benefits from the latency floor.

This is the same NVMe-metadata / HDD-data shape already planned for the CephFS rollout (per `project_cephfs_hdd_plan.md`). Coherent storage tier model across both filesystem and object storage.

## Chart layout

`components/storage/ceph-object-store/`, sibling to `ceph-cluster` and `ceph-storage-classes`. Sync wave 4, after the cluster and storage classes are up.

```
components/storage/ceph-object-store/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── cephobjectstore.yaml
    └── route.yaml
```

Two templates only — no namespace (uses the existing `rook-ceph` namespace), no SCC/RBAC (Rook owns RGW pod creation and serviceaccounts).

## Pool sizing decisions

`metadataPool` and `dataPool` both `replicated size 3` with `failureDomain: host` — the same constraint that the existing `nvme-replicated` block pool uses. That's the right invariant for a 3-OSD-on-3-host cluster: any single host can drop without losing data.

Deliberately *not* setting `pg_num` or `pg_num_min` on these pools at chart time:

- The existing `nvme-replicated` pool has `pg_num: 128` to absorb the bulk of the cluster's IO. Adding two more pools at 128 each would push us to ~225 PGs/OSD, near the `mon_max_pg_per_osd` warning threshold (~250).
- New RGW pools start at the Rook default (`pg_num: 32`). For metadata and a young data pool, that's fine. If/when log volume grows past what 32 PGs comfortably hold, bump manually — same pattern we already used for `nvme-replicated`.
- The autoscaler is broken on this cluster (`ceph osd pool autoscale-status` returns `[]`, likely a Squid 19.2.3 quirk; tracked separately). Don't rely on it; trust manual sizing.

## Gateway config

```yaml
gateway:
  instances: 1
  port: 80
  securePort: 0
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   {              memory: 1Gi  }
```

- **`instances: 1`** — one RGW pod is sufficient for homelab S3 traffic. Multiple instances would mean we need to think about session affinity / pre-signed URL host selection / etc; not worth it for the load.
- **`port: 80, securePort: 0`** — RGW listens on plain HTTP only. TLS is terminated at the OpenShift Route (edge); in-cluster clients hit the `rook-ceph-rgw-<name>.rook-ceph.svc:80` Service directly without going through the Route. RGW's own TLS (`securePort`) would require us to give it a cert; the wildcard cert lives at the Route layer and we don't want to duplicate it.
- **Resources:** RGW idle is light; under a logging workload it'll grow. 1Gi limit is comfortable headroom for now; if the OOMKill counter ever goes non-zero we bump.

## `preservePoolsOnDelete: true`

Same posture as `ceph-cluster`'s CephCluster CR. If someone uninstalls the chart by mistake (or Argo decides to prune it for an unrelated reason), the *pools* survive. The CR being recreated will adopt them again. RGW data isn't a thing you accidentally delete.

## Route + TLS

`s3.apps.okd.sudops.pl`, edge termination, `Redirect` on plain HTTP. Wildcard `*.apps.okd.sudops.pl` cert from cert-manager covers it automatically — no per-app Certificate resource. Same shape as `gatus`, `grafana`, `ceph-dashboard`.

In-cluster S3 clients (Loki's `LokiStack`, OADP's `BackupStorageLocation`, future apps doing direct backups) should use the in-cluster Service `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80` — that path skips Route + edge TLS and is faster + more reliable than going out to the LB and back. The `s3.apps.okd.sudops.pl` Route is for external admin (`mc`, `aws s3 ls`, browsers).

## What's deferred to follow-up commits

This chart ships **only** the `CephObjectStore` CR and the Route. Not in this commit:

- **`CephObjectStoreUser` CRs** — per-tenant credentials. Loki gets its own user (one bucket scope), OADP gets its own user (separate bucket scope), each is a separate chart concern. Shipping them here would couple this storage chart to specific consumers.
- **Bucket policy / CORS** — RGW supports both. Add when a client actually needs them.
- **Loki / OADP wiring** — separate charts under `operators/` (Subscriptions) + `cluster-config/` (LokiStack, ClusterLogForwarder, DataProtectionApplication CRs).

## Validation

```bash
$ helm lint components/storage/ceph-object-store/
1 chart(s) linted, 0 chart(s) failed

$ helm template ceph-object-store components/storage/ceph-object-store/ \
    -n rook-ceph -f components/storage/ceph-object-store/values.yaml | \
  kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
                              <- silent, all kinds OK

$ helm template ... | oc diff -f -
                              <- only the new CephObjectStore + Route, no drift
```

Post-deploy verification (captured 9 days post-rollout, with Loki actively writing):

```
$ oc get cephobjectstore -n rook-ceph
NAME               PHASE   ENDPOINT                                                 AGE
ceph-objectstore   Ready   http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80   9d

$ oc get pod -n rook-ceph -l app=rook-ceph-rgw
NAME                                                READY   STATUS    RESTARTS   AGE
rook-ceph-rgw-ceph-objectstore-a-6d5f7d86f6-8rvp6   1/1     Running   0          2d1h

$ oc get svc -n rook-ceph rook-ceph-rgw-ceph-objectstore
NAME                             TYPE        CLUSTER-IP       PORT(S)   AGE
rook-ceph-rgw-ceph-objectstore   ClusterIP   172.30.160.121   80/TCP    9d

$ oc get route -n rook-ceph ceph-objectstore-s3
NAME                  HOST/PORT                 SERVICES                         TERMINATION
ceph-objectstore-s3   s3.apps.okd.sudops.pl     rook-ceph-rgw-ceph-objectstore   edge/Redirect
```

Pool layout from `ceph df` after Loki adoption (data pool actively used; metadata family stays light):

```
ceph-objectstore.rgw.control          0 B    8 objs
ceph-objectstore.rgw.meta             2.4 KiB    11 objs
ceph-objectstore.rgw.log              81 KiB    373 objs
ceph-objectstore.rgw.buckets.index    9.5 MiB    11 objs
ceph-objectstore.rgw.buckets.non-ec   0 B
ceph-objectstore.rgw.otp              0 B
ceph-objectstore.rgw.buckets.data     33 GiB / 100 GiB raw   53.76k objs   ← Loki chunks
.rgw.root                             6.9 KiB    22 objs
```

`ceph -s` is clean: 13 pools, 189 PGs (up from 129 pre-rollout — +60 PGs as predicted), all `active+clean`. Cluster `HEALTH_OK`, well below the `mon_max_pg_per_osd` warning threshold.

## Impact on the degraded window: none

This is net-new workload, not a refactor:

- Two new empty pools (`ceph-objectstore.rgw.buckets.data` + the metadata pool family). They're empty, so PG creation is instant.
- One new RGW Deployment (single pod). It schedules and starts; nothing existing rolls.
- No OSD changes, no CRUSH-rule mutations on existing pools, no rebalance.

PG-count delta: ~32 (metadata) + ~32 (data) = +64 PGs cluster-wide, going from 129 to ~193. Comfortably under the 250-ish warning threshold for our 3-OSD config.

## Open follow-ups (post-deploy)

- **Loki Operator + OKD Logging adoption** — the next two commits, both Subscription-only at wave 1, then a `LokiStack` + `ClusterLogForwarder` chart at wave 5 that points the logs at a bucket on this CephObjectStore.
- **OADP adoption** — independent of Loki, same wave-1 Subscription pattern, plus a `DataProtectionApplication` CR at wave 5 referencing a separate user/bucket. Wait until logs are landing before we worry about backups.
- **HDD migration** — when bulk drives land, single-line PR: `dataPool.deviceClass: nvme` → `hdd`. Watch the rebalance complete. Capture before/after Loki query latency for the write-up; expect modestly higher write latency on HDD but that's intended (logs are cold-ish).
- **PG-count adjustment** — if log volume drives the data pool past comfortable use of 32 PGs (the autoscaler-empty bug means we can't trust auto-grow), bump `pg_num` manually via toolbox. Same pattern used to fix `nvme-replicated`.
