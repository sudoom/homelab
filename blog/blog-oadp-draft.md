# OADP — cluster backup rollout

Working draft. Captures the design choices + the shipping pass so a future post can retrace what landed and why.

## Framing

The cluster had no off-cluster backup path. Loki replays logs from RGW so observability data was already durable; everything else lived only in Ceph PVCs — primarily the CNPG `media-postgres` databases (Sonarr / Radarr / Prowlarr state), `media` + `keepers` app PVCs, and the `sealed-secrets` controller's master key. Loss of Ceph or the cluster meant rebuilding configs by hand.

OADP (OpenShift API for Data Protection) is the Velero-based answer. It backs up two things in one operation:

1. **Kubernetes resources** as serialized YAML — namespaces, ConfigMaps, Secrets, Deployments, CRs.
2. **Persistent volume data** via CSI VolumeSnapshot + datamover (kopia uploads the snapshot content to S3).

The target is a dedicated bucket on the existing `ceph-objectstore` RGW. Same OBC + secret-translator pattern Loki uses for its bucket, just reshaped for Velero's credential format.

## Catalog choice — okderators vs community-operators

OADP appears in both catalogs but with very different versions:

| Catalog | Channel | Current CSV |
|---|---|---|
| community-operators | stable | `oadp-operator.v0.4.2` (pre-v1 CR shape) |
| okderators | alpha | `oadp-operator.v1.5.0-2026-01-05-165341` |

community-operators is *stable* but stuck at v0.4 — old CR shape (`VeleroPlugins` not `defaultPlugins`, no nodeAgent block). The DPA I wanted to ship doesn't apply against it.

okderators is *alpha* channel but the CSV is dated 2026-01-05, matches current upstream OADP v1.5, has the modern `DataProtectionApplication` shape. The cluster is already on okderators for cert-manager — kept the catalog story coherent and picked okderators.

## Chart shape

Two charts, one per concern.

`components/operators/oadp/` — Wave 1:
- Namespace `openshift-adp`
- OperatorGroup with `targetNamespaces: [openshift-adp]` (OADP is namespace-scoped)
- Subscription pointing at okderators / alpha

`components/cluster-config/oadp/` — Wave 5:
- `ObjectBucketClaim` `oadp` against `ceph-objectstore` with deterministic `bucketName: oadp` (vs `generateBucketName`) so the DPA can hardcode the bucket name in its rendered manifest without a post-bind patch step
- ServiceAccount + Role + RoleBinding for the translator (scoped to OBC read + Secret write)
- Sync-hook Job that reshapes OBC creds into Velero's INI-format Secret — key `cloud`, body `[default]\naws_access_key_id=...\naws_secret_access_key=...\n`
- `DataProtectionApplication` CR with plugins (`aws`, `csi`, `openshift`), `nodeAgent.enable: true` (kopia), S3 target = in-cluster RGW Service `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80` (bypasses Route + edge TLS)
- Daily `Schedule` CR at 02:00 UTC, 14d retention, `snapshotMoveData: true`

The secret-translator pattern is identical in spirit to Loki's, with the output Secret reshaped. Velero expects a single-key Secret containing an INI-style cloud-credentials file; Loki expects a multi-key Secret with `endpoint` / `bucketnames` / `access_key_id` / `access_key_secret` / `region`. Same OBC, different downstream consumer convention.

## Schedule semantics

`snapshotMoveData: true` is the key knob — without it, the backup contains CSI snapshot *references* that are useless if the underlying Ceph cluster is gone. With it, kopia walks the snapshot at backup time and uploads chunked content to S3. Restore: download chunks, reassemble, mount.

Trade-off: first run is heavy (kopia walks every PVC once), subsequent runs are lightweight (chunk-deduplicated deltas). Total RGW footprint scales with actual data change, not total volume size.

`defaultVolumesToFsBackup: false` keeps PVC backup behind CSI snapshot + datamover (the modern path) rather than the older `velero-restic` annotation-driven model.

`includeClusterResources: true` covers cluster-scoped CRs (CRDs, ClusterRoles, etc.) — needed for true DR.

## What shipped — file inventory

```
components/operators/oadp/
├── Chart.yaml
├── values.yaml
└── templates/
    └── operator.yaml          # Namespace + OperatorGroup + Subscription

components/cluster-config/oadp/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── obc.yaml                       # OBC against ceph-objectstore
    ├── secret-translator-rbac.yaml    # SA + Role + RoleBinding
    ├── secret-translator-job.yaml     # Sync-hook Job; reshapes OBC creds
    ├── dataprotectionapplication.yaml # DPA CR
    └── schedule.yaml                  # Daily Schedule CR
```

Plus two entries in `bootstrap/root-app/values.yaml`.

## 2026-05-28 rollout — verified end-to-end

| Step | Result |
|---|---|
| Push `bffad4b` | OK |
| ArgoCD reconcile `oadp-operator` app | Synced+Healthy at 19:15:49 |
| CSV `oadp-operator.v1.5.0-2026-01-05-165341` | Succeeded |
| ArgoCD reconcile `oadp` app | Synced+Healthy at 19:16:51 |
| OBC `oadp` | Bound |
| Translator Job | Completed (wrote `cloud-credentials` Secret) |
| DPA `dpa` | Reconciled=True |
| Schedule `daily` | Enabled, cron `0 2 * * *` |
| Velero pods | 1 controller + 1 velero + 3 node-agent Running |
| BackupStorageLocation `default` | Available (RGW reachable) |

One-shot test backup of the `openshift-adp` namespace itself (small, no PVCs — confirms the resources path end-to-end):

| Field | Value |
|---|---|
| Name | `oneshot-test-172256` |
| Phase | Completed |
| Items | 146/146 |
| Start | 17:22:56Z |
| End | 17:23:01Z |
| Duration | 5 seconds |
| Errors | 0 |
| Warnings | 0 |

RGW bucket inspection via toolbox (with explicit `--rgw-realm=ceph-objectstore --rgw-zonegroup=ceph-objectstore --rgw-zone=ceph-objectstore` to bypass the orphan `default` zone):

```
"bucket": "oadp",
"size": 432962,
"num_objects": 12,
```

12 objects, ~423 KiB — Velero's standard per-backup metadata footprint (backup metadata, resource lists, logs, version info, several index files).

## What's not done yet

- **Restore drill.** Backups are only as useful as their restores. Need to take a known-good backup, delete a non-critical resource (e.g., a test ConfigMap), and verify the restore brings it back. Schedule this before relying on the backups for anything real.
- **Off-cluster bucket sync.** Today's backups live on the same Ceph cluster they're protecting. Loss of Ceph loses the backups too. A future job (rclone or s3cmd in a CronJob) could mirror the `oadp` bucket to an off-site target (Synology NAS, B2, cloud S3). Not blocking — even on-Ceph backups are useful for accidental-delete recovery.
- **Backup notification webhooks.** Velero doesn't natively post to webhooks; consider a CronJob that diffs `oc get backup` and alerts on PartiallyFailed / Failed.
- **CNPG `barmanObjectStore` separately.** CNPG has its own backup mechanism (continuous WAL streaming + base backups to S3). For Postgres DBs we'll likely run both: OADP for Kubernetes-resource snapshot of the Cluster CR, CNPG-barman for the actual database content with PITR. Not yet shipped.
- **Namespace filtering.** Today every namespace is in scope. After running for a week and seeing the bucket size, consider excluding the noisier system namespaces (`openshift-*`, `kube-*`) which Velero can't usefully restore anyway (operators reconcile them).

## Caveats worth remembering

- **Toolbox-side `radosgw-admin` defaults to the orphan `default` zone.** All real data lives in the `ceph-objectstore` zone. Always pass `--rgw-realm=ceph-objectstore --rgw-zonegroup=ceph-objectstore --rgw-zone=ceph-objectstore` to inspect actual buckets. Same gotcha bit me during Loki bring-up; see `blog/blog-ceph-object-store-draft.md`.
- **First daily backup will be heavy.** Kopia walks every PVC on the cluster, including Prometheus TSDB (Grafana panels remain functional during/after; they read from the new TSDB after restart) and Loki chunks (already in RGW — kopia will dedupe but still has to walk). Expect the 02:00 UTC backup window to take an hour or more on day 1; subsequent days should be minutes.
- **Velero never modifies live state.** Restores are explicit `oc apply -f restore.yaml` actions, not automatic. There's no risk in having the operator + schedules running.
