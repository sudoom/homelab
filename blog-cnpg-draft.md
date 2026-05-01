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

CNPG is published to OperatorHub.io's `community-operators` catalog (already wired into the cluster). The package name is `cloudnative-pg`.

Channel discovery via `oc get packagemanifest`:

```
$ oc get packagemanifest -n openshift-marketplace cloudnative-pg \
    -o jsonpath='{.status.channels[*].name}{"\n"}{.status.defaultChannel}{"\n"}'
stable-v1
stable-v1
```

Initial values had `channel: stable-v1.24` (a guess based on the upstream CNPG release line). The packagemanifest only exposes `stable-v1` — corrected to that. Not catching this would have left the Subscription in an unresolvable state forever, with the operator never installing.

Lesson: always `oc get packagemanifest` for the channel before guessing. The OLM bundle metadata is the source of truth, not the upstream project's release naming.

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
  # backup: ... (deferred until CephObjectStore exists)
```

CNPG creates the StatefulSet, generates the user/admin Secrets, and exposes `<name>-rw` (primary) / `<name>-ro` (replicas) Services. The app references `<name>-app` for the application credentials.

## HA: why `instances: 1` for now

CNPG defaults to `instances: 3` for HA (primary + 2 replicas, automatic failover). For a 3-OSD homelab cluster this is overkill:

- Each replica = a full Postgres pod = ~256–512Mi resident memory at idle, more under load.
- 3 apps × 3 replicas × ~400Mi = ~3.6Gi just for Postgres replicas.
- The actual durability story is already good: Ceph 3-way replication of the underlying RBD volumes means a node loss doesn't lose data.

So: `instances: 1` per cluster, lean on Ceph for durability. The trade-off is RTO — when a Postgres pod dies, the app is down until a new pod attaches the PVC (typically 30–60s on Ceph RBD with `csi.storage.k8s.io/fstype: ext4`). Acceptable for homelab apps.

If a workload turns up where 30–60s of downtime per pod kill is too much, that specific Cluster gets `instances: 2` and CNPG will run a synchronous standby. Not a global decision.

## Backup story: PVC-only first, S3 later

CNPG's killer feature is the WAL archiving + base backup story to S3-compatible storage with PITR. We don't have S3 yet — `CephObjectStore` is queued and HDD-blocked.

Interim plan: `pg_dump` + retention via a CronJob that lands dumps on a Ceph PVC. Restore = `pg_restore` from the dump volume. No PITR, no operator-level backup CR, but recoverable.

Once `CephObjectStore` lands:

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

Adds WAL streaming + scheduled base backups + PITR. That's the target end state.

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

Post-deploy verification (to fill in once OLM finishes):

- `Subscription cloudnative-pg` resolves and creates an `InstallPlan`.
- `ClusterServiceVersion` reaches `Phase: Succeeded`.
- `cnpg-controller-manager` deployment is `Ready 1/1` in `cnpg-system`.
- `Cluster.postgresql.cnpg.io` CRD exists cluster-wide.

## Open follow-ups

- **First app onboarding (Immich)**: queued behind CephFS + PNY swap. The CNPG operator is already a noun; Immich just declares against it.
- **Backup target**: blocked on `CephObjectStore` (HDD-dependent). Until then, per-cluster `pg_dump` CronJobs on PVC.
- **Operator metrics scraping**: not done. Low priority; revisit if reconcile latency or error rates ever need investigating.
- **Cluster sizing defaults**: keep `instances: 1` as the default for all apps; bump only the specific Cluster where 30–60s of downtime per pod kill matters.
