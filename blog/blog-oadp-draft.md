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

## Restore drill — 2026-05-28, passed end-to-end

Ran a tight cycle the same session to verify backups actually round-trip content:

| Step | Time | Result |
|---|---|---|
| Create ConfigMap `restore-drill-172715` (`test=value-172715`) in `default` | 19:27:15 | ok |
| Backup `restore-drill-172715` (only ConfigMaps in `default`) | 19:27:15-21 | Completed in 6s |
| Delete the ConfigMap | 19:27:21 | NotFound confirmed |
| Restore from the backup | 19:27:22-27 | Completed in 5s |
| Verify ConfigMap is back with the SAME data | 19:27:27 | `test=value-172715` — exact match |

12 seconds total wall time. The restore put the actual value back, not just the resource shell — closes the loop on whether the backups are real.

## 2026-06-08 incident — Loki WAL backup filled Ceph to 97%

The cluster came back from a 10-day vacation shutdown (see `blog/blog-cluster-shutdown-draft.md`). The OADP daily Schedule was paused pre-shutdown; un-pausing it during the runbook fired an immediate catch-up run (Velero's behavior on un-pause). That daily backup tried to snapshot + S3-upload every PVC in every namespace — including Loki's two ingester WAL PVCs (150 GiB each, ~233 GiB actual data) into the same Ceph cluster the backup was supposed to protect. Ceph hit `full_ratio: 0.95` and blocked writes cluster-wide.

### Discovery sequence

1. User reported "we have a problem with monitoring." Prometheus pods stuck at 5/6 Ready — the `prometheus` container in a liveness-probe kill loop, 7 restart counts.
2. Initial diagnosis chased a duplicate-series rule eval error (stale rook-mgr pod still being scraped via a `[2d]` lookback). Real bottleneck was elsewhere.
3. User flagged the actual issue: `ceph df` showed **95.07% full**, hitting `OSD_BACKFILLFULL` on all 3 OSDs. Prometheus's TSDB couldn't fsync → liveness probe timed out → kubelet kill loop. Same explanation for any other RBD-backed workload that needed to write.

### Wrong fix sequence — what didn't work

1. **RBD trash purge** — 13 expired CSI snapshot images sitting in trash. Looked promising but they were thin-provisioned with ~0 bytes actual data; freed ~430 MiB total. The trash purge schedule (`every 1h` on `nvme-replicated`) was configured correctly but `rbd_support` mgr module's scheduler hadn't fired since power-on. Manual purge worked; the actual reclaim was tiny.
2. **Velero `DeleteBackupRequest` for the old daily backup (~80 GiB inventory)** — request went to `Processed` status quickly but freed **zero space**. Velero tombstones the snapshot in kopia, but the actual blob reclaim only happens during kopia's **full maintenance** pass, which runs **weekly** by default. The pruning logs showed `Pruning repository failed` with `Error response code InsufficientCapacity` — Velero's own deletion path needs to write metadata to RGW, which was blocked because RGW is on the full pool. Chicken-and-egg.
3. **Raising `full_ratio` from 0.95 → 0.97** to unblock writes long enough for Velero to drain — backfired. Every queued writer (Prometheus catch-up, Loki ingest, kopia maintenance retries) immediately consumed the new headroom. Cluster jumped from 95.05% to 97.02% in under 2 minutes, net deeper hole.

### The actual fix — bypass kopia, delete at rados level

`radosgw-admin --rgw-realm=ceph-objectstore --rgw-zonegroup=ceph-objectstore --rgw-zone=ceph-objectstore bucket rm --bucket=oadp --purge-objects` operates directly on the RADOS object store, skipping kopia entirely. No metadata writes needed; just enumerates and deletes the underlying RADOS objects.

```
$ ... bucket rm --bucket=oadp --purge-objects
2026-06-08T16:52:15.456+0000 ... garbage collection: RGWGC::send_split_chain - send chain returned error: -28
... [repeated] ...
```

The `-28` (ENOSPC) garbage-collection warnings are expected — RGW couldn't queue async GC operations because the pool was full. Sync deletes proceed anyway. ~3 GB/min purge rate; the 70 GiB bucket fully drained over ~10 minutes. Cluster dropped from 97.07% to ~95.5%.

### Second reclaim wave — orphan Released PVs

User caught this from the console: **3 PVs in `Released` status** with claim names `daily-20260608135520-{dljvg,rfwdq,z92jr}` — sizes 5 + 150 + 5 = 160 GiB provisioned. These were Velero data-mover scratch volumes: when the data-mover clones a CSI snapshot, mounts it, uploads, and then deletes the clone, the orphan dance leaves `Released` PVs behind on failure. CLAUDE.md's "Pre-flight checks for any CSI-mount-dependent work" already documents this pattern — but only as a CSI-mount-debugging trigger, not as a capacity-recovery trigger.

Deleting them (finalizer-clear + `oc delete pv`) yielded **0.08% cluster reduction** — the 150 GiB clone was COW-thin and held minimal unique data. The win was incidental cleanup, not space recovery. Chasing them surfaced 38 additional orphan `csi-snap-*` images in the pool, all from the same failed data-mover run. `rbd snap purge && rbd rm` against each (the self-referencing snap purge step required before image rm) freed ~negligible (all COW-thin).

### Third reclaim wave — Loki WAL flush via ingester restart

`csi-vol-88dc5225` and `csi-vol-deab95d6` (Loki's 2 ingester WAL PVCs) actually held the 117 + 116 GiB. Deleting them = data loss. Restarting the ingesters with 5-min `--grace-period` lets Loki gracefully flush WAL→RGW chunks on SIGTERM before exit. Ingester log on shutdown: `finished uploading table index_20611` → confirmed flush happened.

Caveat: the WAL PVC actual usage stayed at 118/116 GiB after restart even with flush succeeded. Loki replays WAL on startup; it doesn't truncate WAL files at flush time. The bulk cluster reclaim came from elsewhere (the bucket purge + Ceph background GC catching up). WAL non-truncation behavior is worth tracking separately — `wal_max_segment_size` and ingester chunk flush dynamics — but not blocking.

### Final state after recovery

| Metric | Worst | Final |
|---|---|---|
| Ceph `%RAW USED` | 97.07% | **82.80%** |
| Ceph AVAIL | 43 GiB | **246 GiB** |
| Prometheus | 5/6 Ready, kill loop | 6/6 Running |
| Loki ingesters | Running but WAL-bloated | 2/2 Running, fresh |
| `full_ratio` | bumped to 0.97 | restored to 0.95 |

### Architectural fix — OADP paused-by-default in chart

Per the user's plan ("OADP should just stay as app without backup until HDD pool"):

- `components/cluster-config/oadp/values.yaml`: added `schedule.paused: true` with a comment block explaining the constraint. Chart template plumbs `spec.paused` through. Runtime un-pause is now reverted by ArgoCD's selfHeal within minutes — backup can only fire if the chart says so. Commit `a75f688`.
- The earlier "narrow scope to media namespace" commit (`5667572`) was a half-step; replaced by paused-by-default because CNPG-native `volumeSnapshot` backup already handles psql in `media` (see `blog/blog-cnpg-draft.md` 2026-05-18 entry). OADP backing up the same namespace would be double-coverage waste.
- OADP infrastructure stays in place (operator, DPA, BSL) so the storage path is exercised and ready. When HDDs land, flip `paused: false` and add a scope (`includedNamespaces` / `excludedNamespaces`) that doesn't double-back-up CNPG-handled PVCs.
- Deleted the dangling OBC (still `Bound` to a deleted bucket) so ArgoCD recreates with a fresh RADOS bucket. BSL returns to Available once the bucket exists again.

Also discovered during this work: an orphan Loki bucket (`loki-a617fe86-...`, 423 MB, owner OBC UUID no longer existed) from a prior OBC instance — purged. Lib-bucket-provisioner doesn't always reclaim the bucket when the OBC is deleted; reclaim policy on the `StorageClass` controls this, and Loki's was set to `Retain` at some point in the past.

### Lessons

- **OADP's default "back up every namespace" is dangerous on a storage-constrained cluster.** Loki WAL and Prometheus TSDB are regeneratable scratch; snapshotting them into the same Ceph cluster doubles footprint with no DR benefit. Any future OADP un-pause must define an explicit scope, not rely on defaults.
- **Velero's `DeleteBackupRequest` doesn't free space immediately even on success.** Kopia tombstones the snapshot but only reclaims blob storage during the weekly full maintenance pass — and that maintenance itself needs working writes to RGW. When the cluster is full, the only reclaim path is bypassing kopia entirely (`radosgw-admin bucket rm --purge-objects` at RADOS level).
- **Raising `full_ratio` to unblock writes is dangerous if writers are queued.** Every workload waiting on writes will immediately fill the new headroom. Either stop the writers first (`oc scale --replicas=0` on the loudest ones) OR raise the ratio + immediately follow with RADOS-level deletes that don't add to write pressure.
- **Orphan Released PVs from failed data-mover runs are a capacity-recovery candidate** — CLAUDE.md only flags them as a CSI-mount debugging trigger. Adding them to the storage-recovery runbook would have surfaced 160 GiB of inventory ~30 minutes faster (even though most of that 160 was COW-thin in the end).
- **Always grep `blog/`, `CLAUDE.md`, `README.md` before proposing a "we should ship X" follow-up.** I proposed shipping CNPG `barmanObjectStore` as a follow-up; it had already shipped 2026-05-18 with a passing restore drill, documented in `blog/blog-cnpg-draft.md`. The user shouldn't have to be the verifier-of-last-resort. This is now a CLAUDE.md rule (`8f6f9da`) + memory entry (`feedback_grep_docs_before_proposing.md`).

## What's not done yet
- **Off-cluster bucket sync.** Today's backups live on the same Ceph cluster they're protecting. Loss of Ceph loses the backups too. A future job (rclone or s3cmd in a CronJob) could mirror the `oadp` bucket to an off-site target (Synology NAS, B2, cloud S3). Not blocking — even on-Ceph backups are useful for accidental-delete recovery.
- **Backup notification webhooks.** Velero doesn't natively post to webhooks; consider a CronJob that diffs `oc get backup` and alerts on PartiallyFailed / Failed.
- ~~CNPG `barmanObjectStore` separately~~ — **shipped 2026-05-18** as CNPG-native `volumeSnapshot` ScheduledBackup (see `blog/blog-cnpg-draft.md`). 7d retention, daily 04:00 UTC, restore drill passed 2026-05-20. Bucket `media-postgres-backups` was deleted at some point and never recreated — currently using CSI volume snapshot only, no S3-tier off-cluster. If S3-tier is wanted later, re-introduce `barmanObjectStore` as a separate ship.
- **Scope OADP backups before un-pausing.** When HDDs land and the schedule un-pauses, ship an explicit `excludedNamespaces` covering at minimum `openshift-logging`, `openshift-monitoring`, `openshift-user-workload-monitoring`, `media` (CNPG handles it), and probably `openshift-adp` (backing up the backup tool is circular).
- **Capture today's incident in CLAUDE.md storage runbook.** The "orphan Released PV as capacity candidate" angle, the kopia-weekly-maintenance gotcha, and the "raising full_ratio invites immediate refill" trap are all worth promoting from this blog draft to CLAUDE.md so they're loaded into the prompt context at session start.

## Caveats worth remembering

- **Toolbox-side `radosgw-admin` defaults to the orphan `default` zone.** All real data lives in the `ceph-objectstore` zone. Always pass `--rgw-realm=ceph-objectstore --rgw-zonegroup=ceph-objectstore --rgw-zone=ceph-objectstore` to inspect actual buckets. Same gotcha bit me during Loki bring-up; see `blog/blog-ceph-object-store-draft.md`.
- **First daily backup will be heavy.** Kopia walks every PVC on the cluster, including Prometheus TSDB (Grafana panels remain functional during/after; they read from the new TSDB after restart) and Loki chunks (already in RGW — kopia will dedupe but still has to walk). Expect the 02:00 UTC backup window to take an hour or more on day 1; subsequent days should be minutes.
- **Velero never modifies live state.** Restores are explicit `oc apply -f restore.yaml` actions, not automatic. There's no risk in having the operator + schedules running.
