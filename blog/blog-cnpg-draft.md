# CloudNativePG on OKD: a shared Postgres layer for the homelab

A handful of apps queued for the homelab need Postgres — Immich is the obvious near-term one, with Forgejo, Wallabag, Mastodon-flavored things and so on likely to follow. The lazy path is "let each app's chart bundle its own Postgres." That's fine for one or two apps, but it fragments backups, upgrades, monitoring, and credential handling. CloudNativePG (CNPG) is the operator-driven alternative: one Postgres operator across the cluster, one `Cluster` CR per app, each with its own data, users, backups, and lifecycle.

## Why CNPG over the bundled-Postgres path

Three concrete things you stop fragmenting:

1. **Upgrades.** When a CVE drops or a minor version goes EOL, you don't have to bump every app chart and pray each app's bundled Postgres has been kept current by its maintainers. You bump the operator (or a `Cluster.spec.imageName`) and CNPG handles the rolling switchover.
2. **Backups.** Operator-driven WAL archiving + base backups to S3-compatible storage, with point-in-time recovery, all declared in the `Cluster` CR. No more per-app `pg_dump` cronjobs that you forget to monitor.
3. **Credentials.** CNPG generates per-cluster admin/app secrets automatically. Each app references the right Secret name; no manual secret creation, no cross-pollination.

The cost is one more operator running at idle. Worth it if you have ≥2 apps that need Postgres; arguably worth it for one if you expect more.

## The "use the bundled chart" pushback

Worth addressing because it's the path of least resistance:

- Immich's official Helm chart has a `postgres:` block that brings up a single Postgres pod. Quick to deploy, no operator. But: no automated backups, no PITR, no painless upgrade story, and when the second app shows up you're now running two flavors of "single Postgres pod with no operator."
- The "we don't have many apps yet" argument assumes app count stays low. In practice it doesn't.

CNPG is a small upfront investment that pays back the moment app #2 needs Postgres.

## Operator-only first

Shipped in this commit: the operator's OLM Subscription and nothing else. No `Cluster` CRs, no per-app Postgres pods. This is deliberate:

- The operator at idle is cheap (controller pod ~150Mi, watches CRDs, does nothing without a Cluster spec).
- CRDs become available immediately for apps to declare against.
- We don't end up with a half-finished test cluster nobody uses.

Chart layout matches the `cert-manager`, `nmstate`, `rook-ceph`, and `grafana` operator charts — `Namespace + OperatorGroup + Subscription` only:

```
components/operators/cnpg/
├── Chart.yaml
├── values.yaml
└── templates/
    └── operator.yaml
```

## Catalog and channel choice

CNPG is published as the package `cloudnative-pg`. Two things to get right in the Subscription, both of which I got wrong on the first commit:

### Channel: `stable-v1`, not `stable-v1.24`

Initial values had `channel: stable-v1.24` — a guess based on the upstream CNPG release line (1.24 is the current minor at time of writing). Wrong. The packagemanifest only exposes a single channel, `stable-v1`:

```
$ oc get packagemanifest -n openshift-marketplace cloudnative-pg \
    -o jsonpath='{.status.channels[*].name}{"\n"}{.status.defaultChannel}{"\n"}'
stable-v1
stable-v1
```

OLM doesn't subscribe to a minor version; it subscribes to the release stream. Within `stable-v1`, OLM resolves to whatever the catalog currently bundles (today, `cloudnative-pg.v1.29.0` — see "Rollout" below).

### CatalogSource: `operatorhubio-catalog`, not `community-operators`

This was the more interesting mistake. The first Subscription had:

```yaml
spec:
  source: community-operators
  sourceNamespace: openshift-marketplace
```

…because that's the catalog name I expected, by analogy with cert-manager (which lives in the `okderators` catalog). The Subscription resolved with this error:

```
no operators found in package cloudnative-pg in the catalog referenced
by subscription cloudnative-pg
```

The CSV never got created, the operator never installed, and the InstallPlan stayed empty. The fix is to ask the packagemanifest *which catalog* it actually came from:

```
$ oc get packagemanifest -n openshift-marketplace cloudnative-pg \
    -o jsonpath='{.status.catalogSource}{"\n"}'
operatorhubio-catalog
```

Two CatalogSources are wired into this cluster — `community-operators` and `operatorhubio-catalog`. Both are populated from upstream OperatorHub.io but they're different bundles maintained on slightly different schedules, and not every package shows up in both. CNPG is in `operatorhubio-catalog` but not `community-operators`.

Fixed in commit `9c0133b` by setting `source: operatorhubio-catalog`. After that, OLM resolved the InstallPlan within seconds.

Lesson, sharper than the channel one: the `oc get packagemanifest <pkg> -o jsonpath='{.status.catalogSource}'` query is the source of truth for which CatalogSource to point a Subscription at. Don't infer it from analogy with another operator. The OperatorHub UI in the OKD console hides this distinction; the YAML doesn't.

## OperatorGroup: cluster-scoped

`OperatorGroup` with empty `spec: {}`. That's the cluster-scoped install mode — the operator watches all namespaces, so any future app's `Cluster` CR works regardless of which namespace it's in. Same shape as the `cert-manager` install.

## Per-app pattern (deferred until first app)

When the first app onboards (Immich is queued, blocked on CephFS + the PNY swap), the pattern looks like this in the app's chart:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: immich-pg
  namespace: immich
spec:
  instances: 1                      # see the HA discussion below
  storage:
    storageClass: ceph-nvme-block
    size: 20Gi
  monitoring:
    enablePodMonitor: true          # auto-creates PodMonitor for UWM Prometheus
  bootstrap:
    initdb:
      database: immich
      owner: immich
  # backup: ... (wire barmanObjectStore at first-cluster time — see below)
```

CNPG creates the StatefulSet, generates the user/admin Secrets, and exposes `<name>-rw` (primary) / `<name>-ro` (replicas) Services. The app references `<name>-app` for the application credentials.

## HA: why `instances: 1` for now

CNPG defaults to `instances: 3` for HA (primary + 2 replicas, automatic failover). For a 3-OSD homelab cluster this is overkill:

- Each replica = a full Postgres pod = ~256–512Mi resident memory at idle, more under load.
- 3 apps × 3 replicas × ~400Mi = ~3.6Gi just for Postgres replicas.
- The actual durability story is already good: Ceph 3-way replication of the underlying RBD volumes means a node loss doesn't lose data.

So: `instances: 1` per cluster, lean on Ceph for durability. The trade-off is RTO — when a Postgres pod dies, the app is down until a new pod attaches the PVC (typically 30–60s on Ceph RBD with `csi.storage.k8s.io/fstype: ext4`). Acceptable for homelab apps.

If a workload turns up where 30–60s of downtime per pod kill is too much, that specific Cluster gets `instances: 2` and CNPG will run a synchronous standby. Not a global decision.

## Backup story: barmanObjectStore against the in-cluster RGW

CNPG's killer feature is WAL archiving + base backup to S3-compatible storage with PITR. The `CephObjectStore` shipped 2026-05-01 (see `blog-ceph-object-store-draft.md`), so the first CNPG `Cluster` can wire `barmanObjectStore` directly — no `pg_dump`-to-PVC interim needed.

Pattern for the first cluster:

```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://backups/immich-pg
      endpointURL: https://s3.apps.okd.sudops.pl
      s3Credentials:
        accessKeyId: { name: cnpg-s3-creds, key: accessKey }
        secretAccessKey: { name: cnpg-s3-creds, key: secretKey }
      wal:
        compression: gzip
    retentionPolicy: "30d"
```

The S3 keys ride in a `CephObjectStoreUser` (one per cluster, scoped to its own bucket prefix), then a small ObjectBucketClaim → SealedSecret pipeline lands the access keys in the cluster's namespace. Same pattern Loki uses; reuse the existing secret-translator approach in `components/cluster-config/logging-stack/`.

## Grafana dashboard

Wired up the official CNPG dashboard (`grafanaCom.id: 20417`) into `grafana-config` so the operator's metrics view is ready the moment a Cluster comes up with `monitoring.enablePodMonitor: true`. Until then it paints empty — there's no Cluster pod to scrape, so no postgres-side metrics in Prometheus.

The operator-controller's own metrics (reconcile counts, errors) aren't auto-scraped by user-workload-monitoring today — would need either a `PodMonitor` matching the operator deployment in `cnpg-system` or a label flip on the namespace. Skipped for now; operator-level metrics are not the interesting thing — per-cluster Postgres metrics are.

## Validation

```bash
$ helm lint components/operators/cnpg/
1 chart(s) linted, 0 chart(s) failed

$ helm template cnpg-operator components/operators/cnpg/ -n cnpg-system \
    -f components/operators/cnpg/values.yaml | \
  kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
                              <- silent, all kinds OK
```

Post-deploy verification (after the catalog/channel fixes landed):

```
$ oc get subscription -n cnpg-system cloudnative-pg \
    -o jsonpath='{.status.state}{"  "}{.status.currentCSV}{"\n"}'
AtLatestKnown  cloudnative-pg.v1.29.0

$ oc get csv -n cnpg-system cloudnative-pg.v1.29.0 \
    -o jsonpath='{.status.phase}{"\n"}'
Succeeded

$ oc get deploy -n cnpg-system cnpg-controller-manager
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
cnpg-controller-manager   1/1     1            1           19m

$ oc get crds | grep cnpg.io
backups.postgresql.cnpg.io
clusterimagecatalogs.postgresql.cnpg.io
clusters.postgresql.cnpg.io
databases.postgresql.cnpg.io
failoverquorums.postgresql.cnpg.io
imagecatalogs.postgresql.cnpg.io
poolers.postgresql.cnpg.io
publications.postgresql.cnpg.io
scheduledbackups.postgresql.cnpg.io
subscriptions.postgresql.cnpg.io
```

All ten CRDs present, controller running, CSV `Succeeded`. The cluster is now ready for the first `Cluster` CR — Immich's, when CephFS lands and the PNY swap completes.

## Rollout interference: pi-hole DNS rate-limit

Worth noting because it cost about ten minutes of staring at "stuck" Argo apps before realizing the apps weren't stuck — Argo's repo-server couldn't resolve `github.com`. Pi-hole at `192.168.1.12` (still authoritative for `cluster.local` until technitium migration) periodically rate-limits DNS queries from cluster nodes and starts returning SERVFAIL to bursty clients. The repo-server was logging `lookup github.com on 172.30.0.10:53: server misbehaving`.

Not a CNPG problem; it's the recurring pi-hole rate-limit issue documented in `blog-pihole-draft.md`. Workaround: wait it out (rate-limit window resets after a couple minutes). Long-term fix is the technitium migration, which retires the 192.168.1.12 box. Cross-referenced here only because if a future me pulls up this draft after a similar rollout that "didn't sync," the pi-hole DNS path is the second thing to check after the catalog source.

## Open follow-ups

- **First app onboarding (Immich)**: queued behind CephFS + PNY swap. The CNPG operator is already a noun; Immich just declares against it.
- **Backup target**: `CephObjectStore` is live (shipped 2026-05-01). First `Cluster` ships with `barmanObjectStore` pointing at a per-cluster bucket on the existing RGW; no PVC-dump interim.
- **Operator metrics scraping**: not done. Low priority; revisit if reconcile latency or error rates ever need investigating.
- **Cluster sizing defaults**: keep `instances: 1` as the default for all apps; bump only the specific Cluster where 30–60s of downtime per pod kill matters.

## 2026-05-18 — `barmanObjectStore` for `media-postgres` (continuous WAL + daily base)

Wired CNPG's barman-based backup pipeline to the existing `ceph-objectstore` RGW. Pattern is per the "Backup target" open follow-up above — per-cluster bucket on the RGW, daily base + continuous WAL.

### Why now

Three .NET servarrs (Sonarr/Radarr/Prowlarr) are now using the shared `media-postgres` Cluster (Pattern A: one Cluster, one user, multiple DBs). Schemas are reproducible from the apps if needed, but the **app-level config** (indexers, profiles, history, queue) lives inside Postgres for the v4+ servarrs. Losing the cluster meant manual re-onboarding of every servarr. Cheap to wire; high return.

### Design pivot vs the Loki precedent

LokiStack consumes credentials from a bundled-shape Secret (`endpoint` + `bucketnames` + `access_key_id` + `access_key_secret` + `region` as five keys in one Secret). That's why `components/cluster-config/logging-stack/` ships a secret-translator Job — translate the OBC controller's auto-Secret (`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`) into the LokiStack-shaped Secret.

CNPG's `barmanObjectStore.s3Credentials` is different: it references **individual keys by name** in any Secret:

```yaml
s3Credentials:
  accessKeyId:
    name: <secret-name>
    key: AWS_ACCESS_KEY_ID
  secretAccessKey:
    name: <secret-name>
    key: AWS_SECRET_ACCESS_KEY
```

So the OBC's auto-Secret works directly — no translator needed. Saves a chart-internal Job + RBAC + 60 lines. The plumbing is just OBC → wait for binding → Cluster CR references the auto-Secret.

### Bucket-name pinning

barman wants the bucket name baked into `destinationPath` as a static string (`s3://<bucket>/`). The Loki OBC uses `generateBucketName: loki` and the bucket comes out as `loki-<random-suffix>` — fine because Loki reads the actual bucket name from the OBC's ConfigMap at runtime. CNPG can't do that — `destinationPath` is a literal in the spec.

Fix: OBC uses `bucketName: media-postgres-backups` (pinned, deterministic). lib-bucket-provisioner honors `bucketName` and creates that exact bucket. The Cluster CR then references `s3://media-postgres-backups/` directly. If a second CNPG cluster ships later, it gets its own OBC + its own bucket; `serverName` (set to the cluster name) keeps the in-bucket prefix distinct if we ever decide to share.

### `ceph-bucket-retain` StorageClass added

Spotted a footgun while wiring this: `ceph-bucket` SC has `reclaimPolicy: Delete`. If the OBC ever gets pruned (ArgoCD selfHeal on a removed manifest, accidental `oc delete`, etc.), **the bucket and every byte in it gets wiped**. For Loki logs that's fine — the data is regeneratable. For DB backups that's the difference between "I have backups" and "I had backups."

Added a sibling SC `ceph-bucket-retain` with `reclaimPolicy: Retain` in `components/storage/rook-ceph-cluster/templates/object-bucket-storageclass.yaml`, gated on `objectBucket.retainStorageClassName`. The CNPG OBC uses it. Trade-off: if the OBC needs to be recreated, the leftover `ObjectBucket` in Released state needs manual cleanup (force-clear finalizers; same pattern as the teardown procedure in CLAUDE.md). Acceptable cost for the safety.

Loki's OBC is untouched — still on `ceph-bucket` (Delete). The two SCs co-exist by design.

`reclaimPolicy` is immutable on StorageClass, so we couldn't have just flipped `ceph-bucket` to Retain in place — that'd require deleting and recreating the SC, which would re-roll Loki's OBC too. Two SCs is the clean shape anyway: different intent, different SC.

### Schedule

Daily base backup at 04:00 UTC (`schedule: "0 0 4 * * *"`, CNPG-style 6-field cron). Combined with continuous WAL archiving, that gives PITR back to the last 30 days (`retentionPolicy: "30d"`). Quiet hour for the media stack — ahead of any morning use.

### Sync ordering

- OBC: intra-chart sync-wave `4` (before the Cluster at the chart's outer sync-wave `5`).
- Cluster: outer wave 5 (existing).
- ScheduledBackup: intra-chart sync-wave `6` (after the Cluster is up + the OBC's auto-Secret has materialized).

CNPG's reconciler retries archive setup, so if the Cluster comes up before the OBC's Secret exists, it self-heals on next loop. The waves are guidance, not strict ordering.

### Validation plan (post-merge)

- `oc -n media get obc media-postgres-backups -o yaml` → `phase: Bound`
- `oc -n rook-ceph exec deploy/rook-ceph-tools -- radosgw-admin bucket list --rgw-realm=ceph-objectstore --rgw-zonegroup=ceph-objectstore --rgw-zone=ceph-objectstore` → bucket present
- `oc -n media get cluster media-postgres -o jsonpath='{.status.firstRecoverabilityPoint}'` → timestamp populated after first WAL archives
- `oc -n media exec media-postgres-1 -c postgres -- barman-cloud-backup-list --cloud-provider aws-s3 --endpoint-url http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80 s3://media-postgres-backups/ media-postgres` → at least one base backup after the first scheduled run

### Open

- **WAL archive interval default** — CNPG defaults to checkpoint-on-archive. Fine for the workload (low write rate). Revisit if the WAL bucket grows fast.
- **Restore drill** — never tested. The first real validation should be standing up a sister Cluster via `bootstrap.recovery.source` pointing at this same bucket. TODO once the first base backup completes.
- **OADP follows** — uses the same OBC + retain-SC pattern, different bucket. Next item.

## 2026-05-20 — restore drill against `media-postgres-backups`

### Setup

Wrote a single-file restore Cluster manifest at
`tests/cnpg-restore-drill.yaml`. Single instance, 10Gi storage, no
backup section (don't overwrite the source's backup path), and an
`externalClusters[0].barmanObjectStore` pointing at the same
`destinationPath` + `serverName` as the source. Reuses the OBC-managed
Secret `media-postgres-backups` for S3 creds — CNPG operator auto-grants
the new SA `get` on it.

```yaml
spec:
  bootstrap:
    recovery:
      source: media-postgres-source
  externalClusters:
    - name: media-postgres-source
      barmanObjectStore:
        destinationPath: s3://media-postgres-backups/
        endpointURL: http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80
        serverName: media-postgres
        s3Credentials:
          accessKeyId:    { name: media-postgres-backups, key: AWS_ACCESS_KEY_ID }
          secretAccessKey: { name: media-postgres-backups, key: AWS_SECRET_ACCESS_KEY }
```

### Timeline

| Step | Wall clock |
|------|------------|
| `oc apply` → Cluster created, phase `Setting up primary` | t=0 |
| `media-postgres-restore-drill-1-full-recovery-<hash>` Job running (pulls base backup + replays WAL) | t=0…75s |
| Recovery Job → `Completed`; instance pod transitions `Init → Running` | t=80s |
| `phase: Cluster in healthy state`, `readyInstances: 1` | t=90s |

Source DB has ~140 tables across 7 user databases plus seeded
config rows; total restore wall-clock was ~90 seconds. Most of that
was barman-cloud-restore pulling the base backup from RGW; WAL replay
on a 13h-old backup was sub-second.

### Validation

| Check | Source | Restored | |
|-------|--------|----------|---|
| User databases | 7 | 7 | match (+`app` default DB CNPG creates on init — expected) |
| `sonarr-main` public tables | 38 | 38 | match |
| `radarr-main` public tables | 41 | 41 | match |
| `prowlarr-main` public tables | 20 | 20 | match |
| `sonarr-main.Config` rows | 12 | 12 | match |
| `sonarr-main.RootFolders` rows | 3 | 3 | match |
| `radarr-main.Indexers` rows | 2 | 2 | match |
| `prowlarr-main.Indexers` rows | 2 | 2 | match |

All counts byte-identical. Restore pipeline validated end-to-end.

### Teardown

```bash
oc -n media delete -f tests/cnpg-restore-drill.yaml
```

The CNPG operator cascade-deletes the StatefulSet → pods → PVCs (via
ownerReference). Took ~12 seconds end-to-end. Ceph went from 27.06% →
26.78% used as the restore-drill PVC was trashed and the RBD image
purged.

### Worth keeping

The manifest stays in `tests/` so future drills are a single
`oc apply` away. The blast radius is trivially small (separate cluster
name + namespace state isolation) and the validation is mechanical.
Recommend re-running quarterly, or after any chart change that touches
the backup path.

### Aside: deprecation warning

```
Native support for Barman Cloud backups and recovery is deprecated and
will be completely removed in CloudNativePG 1.30.0.
Found usage in: spec.externalClusters.0.barmanObjectStore.
Please migrate existing clusters to the new Barman Cloud Plugin.
```

CNPG is moving the barman integration from in-tree to an external
plugin (`barman-cloud-plugin`). Not urgent — current 1.x line is at
1.27 today — but it's an explicit deprecation, not a soft hint. Adds
to the chart-migration backlog: bump CNPG operator past whichever
release introduces the plugin contract, install the plugin, then move
both `spec.backup.barmanObjectStore` and the restore-drill
`externalClusters[].barmanObjectStore` to plugin-shaped configs.

## 2026-05-20 — migrate `media-postgres` off barman to CSI volume snapshots

### Why the plugin path was rejected

CNPG 1.30 hard-removes native `barmanObjectStore`. Cluster is on 1.29.0
today — literally one minor from the cliff. The official replacement is
the upstream `plugin-barman-cloud` operator. Pulled the v0.12.0 release
manifest and found the deal-breaker: both the operator and the per-pod
sidecar reference `:main` tags from `-testing` repos
(`plugin-barman-cloud-testing:main`,
`plugin-barman-cloud-sidecar-testing:main`).

A mutable tag on a backup path is the kind of thing that turns into a
2 AM page. Not willing to put production backups behind that until
upstream ships stable `:vX.Y.Z` tags from a non-`-testing` repo.

### Why CSI volume snapshots fit our workload

Looked at what's actually in `media-postgres`: servarr config DBs
(sonarr/radarr/prowlarr — both `-main` + `-log`) plus the `media`
default DB. These are write-light config stores; losing the last 24h
means re-running a Trakt sync and re-importing some naming edits.
**PITR is overkill for this workload.**

Trade-offs CSI snapshots vs barman:

| Aspect | CSI snapshot | barman |
|---|---|---|
| Granularity | Snapshot time (daily here) | PITR — any second within retention |
| Speed | Instant (CoW RBD snap) | Minutes (S3 push) |
| External deps | None | RGW bucket + OBC + plugin |
| Storage location | Same RBD pool as live data | Separate object store |
| DR if Ceph dies | Snapshots die with it | Off-cluster RGW survives |
| CNPG 1.30 ready | Yes | Needs plugin migration |

DR-if-Ceph-dies isn't a real homelab concern — if Ceph is gone, the
servarr config DBs aren't the only thing being rebuilt.

### What shipped

**`components/storage/rook-ceph-cluster/templates/volume-snapshot-class.yaml`**
— new `VolumeSnapshotClass/ceph-rbd-snapshot` tied to
`rook-ceph.rbd.csi.ceph.com`. deletionPolicy `Delete` so CNPG retention
sweeps actually free underlying RBD snapshots. Snapshotter secret refs
taken from the live `ceph-nvme-block` StorageClass.

**`components/apps/cnpg-clusters/`** — chart migration:
- `templates/clusters.yaml`: `spec.backup.barmanObjectStore` →
  `spec.backup.volumeSnapshot`; `ScheduledBackup.spec.method:
  volumeSnapshot`
- `values.yaml`: `media-postgres.backup` — removed bucketName /
  endpointURL / obcName; added `volumeSnapshotClassName`; retention
  30d → 7d (snapshots compound on live pool, shorter window matches
  the trade-off)
- `templates/obc.yaml`: deleted — no bucket needed

**`tests/cnpg-restore-drill.yaml`** — rewritten for volume-snapshot
recovery. `bootstrap.recovery.backup.name` with `BACKUP_NAME_HERE`
placeholder; user fills in the latest Backup name before applying.

### SSA cleanup gotcha that didn't bite

CLAUDE.md warns about the empty-managedFields gotcha. `oc diff` against
the new chart showed only the `volumeSnapshot` block being added — no
`barmanObjectStore` removal. Worried it was the gotcha.

It wasn't. ArgoCD's `argocd-controller` field manager had clean
ownership of the barman block (originally created via SSA), so dropping
it from the chart caused SSA to remove it cleanly on apply. Post-apply
`oc get cluster -o jsonpath='{.spec.backup.barmanObjectStore}'` was
empty. The diff output was just showing context lines, not preserved
fields.

(Lesson: read `oc diff` more carefully before pre-emptively planning
the cleanup `oc patch`.)

### Validation

On-demand `Backup` CR with `spec.method: volumeSnapshot` to validate
the path without waiting until 04:00 UTC tomorrow.

| Step | Wall clock |
|------|------------|
| apply to `Backup.phase: completed` | <3s |
| `VolumeSnapshot READYTOUSE: true` | same |
| Restore-drill Cluster `Setting up primary` to `Cluster in healthy state` | ~30s total |

(vs barman: ~90s end-to-end. RBD snapshot clone + in-snapshot pg_control
replay, no S3 round-trip.)

Source ↔ restored row-count comparisons across `sonarr-main.Config`
(12), `sonarr-main.RootFolders` (3), `radarr-main.Indexers` (2),
`prowlarr-main.Indexers` (2), `prowlarr-main.Tags` (0) — all match.

### Cleanup of barman artifacts

- Drop the test snapshot (`snapshotOwnerReference: cluster` means
  Backup delete doesn't cascade)
- Old barman-era `Backup` CRs (immutable archive references — once the
  bucket is gone they're useless pointers)
- RGW bucket survived the ArgoCD-OBC delete via `reclaimPolicy: Retain`
  on the `ceph-bucket-retain` StorageClass — manual purge via
  `radosgw-admin bucket rm --purge-objects`. ~100 MiB freed (the 119
  GiB figure from earlier was the cluster-full state, not the bucket
  data itself).

### Snapshot-ownership note

Used `snapshotOwnerReference: cluster` — snapshots survive Backup
deletion and are managed via CNPG retention sweeps on the 7d window.
If we ever want Backup-scoped lifetime (snapshot purged when its Backup
CR is deleted), switch to `snapshotOwnerReference: backup`.

### Follow-ups

- Tomorrow 04:00 UTC: verify the first ScheduledBackup-triggered
  volumeSnapshot lands.
- Watch the RBD pool over the next week — 7 days × ~10 GiB per
  snapshot × 3 replication = ~210 GiB raw ceiling. Reality should be
  much less since servarr writes are tiny.
- No need to install the plugin yet. Re-evaluate when upstream publishes
  a stable `:vX.Y.Z` tag from a non-`-testing` repo, OR when a future
  workload actually needs PITR.

## 2026-06-27 — barman-cloud plugin + offsite backups to Cloudflare R2

The "re-evaluate when upstream ships a stable tag" condition came true, and the
operator wanted a true-offsite DB copy. Stood up the **barman-cloud plugin** and
wired **both** `media-postgres` and `immich-postgres` → **Cloudflare R2**.
Design was grounded by a verified workflow (CNPG/secret/R2 inventory + a 3-lens
design panel + adversarial synthesis); the load-bearing facts and decisions:

### Why the plugin, not in-tree barmanObjectStore

- Running operator is **CNPG 1.29.1**. In-tree `spec.backup.barmanObjectStore`
  still works on 1.29 but is **deprecated @1.26, removed @1.30**.
- The CNPG OLM subscription is **`installPlanApproval: Automatic`** on
  `stable-v1` (already auto-advanced 1.29.0→1.29.1). So a 1.30 auto-upgrade would
  **silently delete in-tree barman** and break backups with no warning. In-tree
  is a dead end here. (Spotted follow-up: CNPG on Automatic approval is itself a
  latent migration risk — worth switching to Manual, like the Rook/Ceph gate.)
- The plugin (`barmancloud.cnpg.io/v1` `ObjectStore` CRD + `Cluster.spec.plugins`)
  is the forward CNPG-I contract and the **only shape with a clean home for the
  R2 checksum env** (`ObjectStore.spec.instanceSidecarConfiguration.env`).
- The 2026-05-20 blocker (plugin only shipped `:testing:main` images) is gone:
  **plugin v0.13.0 (2026-06-10) is a stable GA tag**, built against CNPG 1.29.1.

Vendored the upstream `manifest.yaml` verbatim into
`components/operators/cnpg-barman-plugin/templates/plugin.yaml` (1110 lines: the
ObjectStore CRD + controller Deployment + RBAC + a self-signed cert-manager
Issuer/Certificates for its gRPC mTLS; no `{{ }}` literals, so Helm renders it
unchanged). Targets the existing OLM `cnpg-system` ns. Root-app wave **3** (after
cert-manager + CNPG operator @1, before the consumer clusters @5/@7). Renovate
**disabled** for `ghcr.io/cloudnative-pg/plugin-barman-cloud` — a tag bump alone
would desync the vendored manifest (same trap as sealed-secrets/rook).

### The #1 R2 failure mode — boto3 checksums (baked into the ObjectStore)

R2 rejects the default integrity checksums that **boto3 ≥1.36** (Dec 2024) sends
on every `PutObject` → `XAmzContentSHA256Mismatch` (and the same on retention
deletes). Documented real break: `postgresql:17.4`→`17.5` rode boto3
`1.35.99`→`1.38.27`. The fix is two SDK env vars (lowercase `when_required`),
placed in `ObjectStore.spec.instanceSidecarConfiguration.env` (verified the field
path against the vendored CRD schema, line 414):

```
AWS_REQUEST_CHECKSUM_CALCULATION=when_required
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
```

Plus `AWS_REGION=auto`. **Re-verify after every plugin-barman-cloud bump** (boto3
rides the sidecar image, not the operand image, under the plugin shape).

### Encryption — at-rest only (corrected an earlier wrong claim)

barman-cloud is **server-side-only**; it has **no client-side/zero-knowledge**
path (the `barman backup` daemon got GPG client-side in 3.14, but `barman-cloud-*`
— what CNPG drives — did not). R2 **always encrypts at rest** (AES-256-GCM,
Cloudflare-managed keys), automatically. So: **omit the `encryption:` field** —
R2 has no SSE-KMS and rejects/ignores the per-object SSE header barman would send.
This **corrected the README's earlier "encrypt client-side before upload"
constraint, which was unsatisfiable via barman.** media-postgres is servarr
config (the README's own "lower-stakes, largely re-creatable"); at-rest +
bucket-scoped token is proportionate. True zero-knowledge stays for where it
matters (the sealed-secrets master key — a future OADP+kopia phase 2).

### Wiring (both clusters, coexisting with the local snapshot)

Per cluster: an `ObjectStore` CR (R2 endpoint/bucket/creds/checksum-env, 30d
retention), a `plugins: [barman-cloud, isWALArchiver:true]` entry on the Cluster
(continuous WAL→R2 = the PITR engine), and a second `ScheduledBackup`
(`method: plugin`, offset from the 04:00 volumeSnapshot). The existing 7d RBD
`volumeSnapshot` stays as the fast local-restore copy. **Decoupling:** when the
plugin is the WAL archiver, the local snapshot is set `online.waitForArchive:
false` — an R2 outage must not stall the *local* snapshot too (else both backups
fail together). The immich Cluster's wave -1 health gate keys on Postgres being
up, **not** on WAL-archive success, so adding R2 does NOT couple Immich's app
startup to R2. Different path prefixes share one bucket
(`s3://<bucket>/media-postgres/`, `…/immich-postgres/`).

All R2 rendering is gated behind `backup.objectStore.enabled` (default **false**)
+ placeholder `bucket`/`endpointURL`, so the commit is inert until the operator
fills the endpoint and seals the creds. Validated: `helm lint`, render
disabled→0 R2 resources / enabled→correct ObjectStore+plugin+ScheduledBackup,
`kubeconform` clean, root-app shows the operator App @ wave 3.

### Enablement (operator, per namespace — creds never in repo plaintext)

Two strict SealedSecrets (namespace-bound), same R2 creds sealed twice:

```bash
# media-postgres (namespace media):
oc -n media create secret generic media-postgres-r2-creds \
  --from-literal=ACCESS_KEY_ID='<R2_ACCESS_KEY_ID>' \
  --from-literal=ACCESS_SECRET_KEY='<R2_SECRET_ACCESS_KEY>' \
  --dry-run=client -o yaml | kubeseal --controller-namespace sealed-secrets --format yaml \
  > components/apps/cnpg-clusters/templates/sealed-media-postgres-r2-creds.yaml
# immich-postgres (namespace immich): same, -n immich, name immich-postgres-r2-creds,
#   output -> components/apps/immich/templates/sealed-immich-postgres-r2-creds.yaml
```

Then fill `bucket` + `endpointURL` in each chart's values, flip
`objectStore.enabled: true`, commit. Restore drill (recover into a scratch
cluster from R2; immich's restore needs the vchord operand image) tracked as the
proof step.
