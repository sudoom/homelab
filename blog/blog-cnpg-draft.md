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

Worth noting because it cost about ten minutes of staring at "stuck" Argo apps before realizing the apps weren't stuck — Argo's repo-server couldn't resolve `github.com`. Pi-hole at `192.168.1.12` (still authoritative for `cluster.local` until technetium migration) periodically rate-limits DNS queries from cluster nodes and starts returning SERVFAIL to bursty clients. The repo-server was logging `lookup github.com on 172.30.0.10:53: server misbehaving`.

Not a CNPG problem; it's the recurring pi-hole rate-limit issue documented in `blog-pihole-draft.md`. Workaround: wait it out (rate-limit window resets after a couple minutes). Long-term fix is the technetium migration, which retires the 192.168.1.12 box. Cross-referenced here only because if a future me pulls up this draft after a similar rollout that "didn't sync," the pi-hole DNS path is the second thing to check after the catalog source.

## Open follow-ups

- **First app onboarding (Immich)**: queued behind CephFS + PNY swap. The CNPG operator is already a noun; Immich just declares against it.
- **Backup target**: `CephObjectStore` is live (shipped 2026-05-01). First `Cluster` ships with `barmanObjectStore` pointing at a per-cluster bucket on the existing RGW; no PVC-dump interim.
- **Operator metrics scraping**: not done. Low priority; revisit if reconcile latency or error rates ever need investigating.
- **Cluster sizing defaults**: keep `instances: 1` as the default for all apps; bump only the specific Cluster where 30–60s of downtime per pod kill matters.
