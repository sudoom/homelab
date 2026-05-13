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

## Update 2026-05-10: floor data pool at pg_num_min=32

A health-check 9 days post-deploy turned up the predictable autoscaler-empty bite. `ceph-objectstore.rgw.buckets.data` was sitting at `pg_num=1` despite holding 33 GiB / 53.76k Loki chunks — every RGW write funnelling through one PG → one primary OSD. `read_balance_score` of `3.00` (worst possible: all replicas on one OSD).

Same root cause as the `nvme-replicated` 1→128 fix: with `ceph osd pool autoscale-status` returning `[]` on this Squid 19.2.3 cluster, no auto-grow ever fires. Fix is the same shape — explicit floor.

**Chart change** (commit `32b2e64`):

```yaml
dataPool:
  failureDomain: host
  deviceClass: nvme
  replicated:
    size: 3
  parameters:
    pg_num_min: "32"
```

Argo synced via webhook in seconds. Rook saw the spec change (`generation 3 → 4`, `observedGeneration` followed) and tried to apply it:

```
I | cephclient: setting pool property "pg_num_min" to "32" on pool "ceph-objectstore.rgw.buckets.data"
E | cephclient: failed to set property "pg_num_min" ... Error EINVAL: specified pg_num_min 32 > pg_num 1
```

Ceph rejects `pg_num_min > pg_num`. The chart-only path is the chicken-and-egg loop: `pg_num` stays at 1 because the autoscaler is broken, `pg_num_min` can't be raised because it'd exceed `pg_num`. Rook applies the parameters but doesn't bump `pg_num` to satisfy them.

**Manual unstick via toolbox:**

```
$ oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph osd pool set ceph-objectstore.rgw.buckets.data pg_num 32
set pool 10 pg_num to 32
$ oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph osd pool set ceph-objectstore.rgw.buckets.data pgp_num 32
set pool 10 pgp_num to 32
```

PGs split immediately — one iteration of `1.818% pgs not active` while peering, then everything back to `active+clean` within ~20s. Cluster total PGs: 189 → 220 (+31 as predicted).

Then directly set the floor (same effect as waiting for Rook's next reconcile, but immediate):

```
$ ceph osd pool set ceph-objectstore.rgw.buckets.data pg_num_min 32
set pool 10 pg_num_min to 32
```

**Final state:**

```
pool 10 'ceph-objectstore.rgw.buckets.data' replicated size 3 min_size 2
  pg_num 32 pgp_num 32 ... pg_num_min 32 ... read_balance_score 1.22
```

`read_balance_score 1.22` (down from 3.00) — replicas now properly spread across OSDs. `HEALTH_OK`, 220 PGs all `active+clean`, no SLOW_OPS during the split. PG-per-OSD ~73 (was 63), still well below the warning threshold.

**Lesson for future RGW pools / new pool types:** Rook's `parameters.pg_num_min` is a passive constraint, not an autoscale trigger. On clusters where the autoscaler is healthy, the chart-only path is sufficient — Rook/Ceph will grow `pg_num` toward `pg_num_min`. On clusters where it isn't (us, Squid 19.2.3), expect to do a one-time toolbox `pg_num` bump to bootstrap. The chart's `pg_num_min` then enforces the floor going forward, so this isn't a recurring chore — only a first-fill artefact.

## Update 2026-05-13: RGW silent 21h outage from router co-location on host network

### Discovery

While building a long-lived read-only `claude-reader` ServiceAccount for out-of-band cluster reads (separate post), I ran a routine cluster health sweep and noticed an outlier in pod restart counts:

```
NAMESPACE    NAME                                                RESTARTS
rook-ceph    rook-ceph-rgw-ceph-objectstore-a-6d5f7d86f6-rlh4s   214
nmstate      nmstate-handler-rb6gs                                36
nmstate      nmstate-handler-dtflz                                20
openshift-ingress   router-default-559f95b7d-n4nrh                12
```

214 in a category where the next-highest "real" anomaly (nmstate, known upstream RBAC bug) is 36 deserved a look.

### Root cause — `EADDRINUSE` on the host port

`oc -n rook-ceph logs <rgw-pod> --previous` gave the answer on the second screen:

```
debug ... 0 framework: beast
debug ... 0 framework conf key: port, val: 80
...
debug ... -1 failed to bind address 0.0.0.0:80: Address already in use
debug ... -1 ERROR: failed initializing frontend
debug ... -1 ERROR:  initialize frontend fail, r = 98
```

Exit 98 = `EADDRINUSE`. RGW couldn't bind `0.0.0.0:80`.

Three loaded pieces of context locked the diagnosis:

1. **`CephCluster.spec.network.provider: host`** — RGW runs on host network (see `blog-multus-ceph-migration-draft.md` for why we're locked here until 4+ OSDs exist).
2. **`openshift-ingress/router-default` runs hostNetwork on port 80** — that's the cluster's edge HTTP listener. Two replicas (default HA mode for a 3-node bare-metal IngressController).
3. **2026-05-12 Multus migration attempt + rollback** rolled the RGW pod. After rescheduling, kube-scheduler picked node4 — which already had a `router-default` pod since 2026-05-11.

Pod placement after the reschedule, captured 2026-05-13 13:48 CEST:

| Node    | router-default | RGW |
|---------|----------------|-----|
| node4   | ✓ (pkrsj, 44h) | ✓ (rlh4s, 19h crashlooping) |
| node5   | — (free)       | — |
| node6   | ✓ (n4nrh, 4d19h) | — |

Node5 was the only collision-free placement on the cluster, and the scheduler hadn't been told to prefer it.

### Why no alarm

The pod was `CrashLoopBackOff` with `restartCount: 214`. ArgoCD's `logging-stack` Application reported `Synced + Healthy` throughout — ArgoCD checks the AppProject's resource health, not whether downstream consumers can actually use the resources. The Loki consumer was almost certainly silently failing S3 writes against the in-cluster `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80` endpoint (no healthy endpoints behind the Service), but that didn't bubble back as Application Degraded.

This is a real observability hole: any silent failure of `rook-ceph-rgw-*` Service endpoints needs to alert. A `PrometheusRule` on `kube_endpoint_address_available{endpoint=~"rook-ceph-rgw-.*"} == 0` would have caught this within minutes. Adding to the open-followups list.

### Fix — `requiredDuringSchedulingIgnoredDuringExecution` podAntiAffinity

Added to `gateway.placement` in `components/storage/ceph-object-store/values.yaml`, templated through to the CephObjectStore CR:

```yaml
placement:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
        namespaces:
          - openshift-ingress
        topologyKey: kubernetes.io/hostname
```

`required` not `preferred` is deliberate. Co-residence is functionally broken — better to be `Pending` and observable than `Running` and silently failing for 21 hours. With 2 routers + 1 RGW on 3 nodes, RGW now pins to node5; if node5 becomes unavailable (planned reboot, kernel panic), RGW goes `Pending` until either node5 comes back or a router moves. That's the right alarm shape: kube-scheduler refusing to place the pod is an event Prometheus *will* see.

The `namespaces` field is required because the router pods live in `openshift-ingress`, not in RGW's own `rook-ceph` namespace — without it, the labelSelector silently matches nothing (pod-anti-affinity defaults to same-namespace).

### oc diff before commit

```
@@ -31,7 +31,15 @@
   gateway:
     instances: 1
-    placement: {}
+    placement:
+      podAntiAffinity:
+        requiredDuringSchedulingIgnoredDuringExecution:
+        - labelSelector:
+            matchLabels:
+              ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
+          namespaces:
+          - openshift-ingress
+          topologyKey: kubernetes.io/hostname
```

Clean delta — only the `placement` field changes from `{}` to the rule. No SSA managed-fields drift to worry about here (CephObjectStore was created via ArgoCD SSA, unlike the CephCluster which has the empty-managedFields gotcha).

### Rollout

```
13:55:55 CEST  push commit 654558c (chart change with placement)
13:57:10       old pod still crashlooping on node4 (restartCount=215)
13:59:33       new pod 6ddb7d9cb9-gb8jn Running on node5, restarts=0
14:00:09       last Loki "connection refused" against rook-ceph-rgw service
14:00:33       Loki "finished uploading table" — chunks flowing again
```

Push → RGW Running: **3 min 38 s**. Push → Loki recovered: **~4 min 38 s**. The ~35 s tail between RGW Ready and Loki seeing the new endpoint is kube-proxy/EndpointSlice → iptables propagation plus Loki's already-in-flight retry batches reaching their 10-retry limit.

A note on the residual data loss: Loki has at-most-once semantics on chunks. The `failed to flush ... terminated after 10 retries` lines in the ingester logs indicate chunks that were dropped permanently. Over a 21 h window with constant infra-log traffic, that's a non-trivial number of dropped chunks — but most of the lost data was in-memory in ingesters that had already buffered against the failing S3 path, so the gap in query results is bounded by how much each ingester could hold before evicting. Acceptable for homelab; the alternative (Loki blocking ingest until S3 recovers) would have cascaded into log-stack pod OOMs and made the failure much louder + worse.

### CR diff verification post-rollout

Just to confirm the live `CephObjectStore` carries the new placement:

```yaml
spec:
  gateway:
    placement:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
            namespaces:
              - openshift-ingress
            topologyKey: kubernetes.io/hostname
```

And Pod placement:

```
NAME                                                NODE                  STATUS    READY  RESTARTS
rook-ceph-rgw-ceph-objectstore-a-6ddb7d9cb9-gb8jn   node5.okd.sudops.pl   Running   1/1    0
```

EndpointSlice now points to `192.168.1.8` (node5's host IP, since we're on host network) and condition `Ready=true`.

`ceph -s` post-recovery:
- `rgw: 1 daemon active (1 hosts, 1 zones)` ✓
- `HEALTH_WARN` persists due to the unrelated `BLUESTORE_SLOW_OP_ALERT` (recurring on this cluster; see `blog-rook-ceph-draft.md`)

### Open follow-ups

- **Endpoint-availability PrometheusRule** for the `rook-ceph-rgw-*` Service — fires on `kube_endpoint_address_available == 0` for any RGW Service. Would have caught this in minutes instead of 21h.
- **Verify Loki post-recovery** — confirm S3 writes are flowing again and the Loki ring isn't stuck in an unhappy state from 21h of failed writes. Check `loki_ingester_wal_disk_full_failures_total`, `loki_distributor_lines_received_total`, and the `ceph-objectstore.rgw.buckets.data` pool size in the toolbox.
- **Documented co-location constraint in CLAUDE.md** — the "Network provider — locked on host" section should mention this scheduling implication: under host network, any RGW (or future RGW-like) workload binding port 80 cannot co-exist with `router-default`. With 2 routers + 1 RGW on a 3-node cluster the constraint is tight; a 4th node would relax it.
