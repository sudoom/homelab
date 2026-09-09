# cnpg-snapshot-retention

Prunes CloudNativePG `volumeSnapshot` backups. CNPG does not do this itself.

## Why

`Cluster.spec.backup.retentionPolicy` governs the **barman object-store path only**. For
`method: volumeSnapshot`, CNPG creates the `VolumeSnapshot` and the `Backup` CR and then never touches either
again. Nothing warns you: the field sits directly beside the `volumeSnapshot` block in
`components/apps/cnpg-clusters/values.yaml` and reads as though it applies.

On this cluster that produced 182 snapshots over 110 days under a policy that said `7d`, holding roughly
127 GiB on a 3-OSD NVMe pool that reached **84.53% against an 85% nearfull threshold** (2026-09-08). Accrual is
about 0.5 GiB/day/cluster. Full diagnosis and the manual reclaim: `blog/blog-cnpg-draft.md`, 2026-09-08.

## What it does

Daily at 05:30, offset from the ScheduledBackups (media 04:00, immich 04:30). For each cluster in
`values.clusters`:

1. List `Backup` CRs labelled `cnpg.io/cluster=<name>` that also carry `cnpg.io/scheduled-backup`, keep only
   `spec.method == volumeSnapshot`, sorted oldest first.
2. Keep the newest `retention.floor` unconditionally.
3. From the remainder, delete those older than `retention.maxAgeDays`.
4. Per deletion: delete the `VolumeSnapshot` (selected by `cnpg.io/backupName`), then the `Backup` CR.

Both objects must go. The `VolumeSnapshot`'s `ownerReference` is the **Cluster**, not the Backup, so deleting a
`Backup` does not cascade.

## Safety properties

| Property | Mechanism |
|---|---|
| Ships inert | `dryRun: true` — logs what it would delete, deletes nothing |
| Cannot touch non-CNPG snapshots | Label-scoped to `cnpg.io/cluster` |
| Cannot touch manual or restore-drill backups | Requires `cnpg.io/scheduled-backup`, which only ScheduledBackup-created Backups carry. This is what protects artefacts like `immich-postgres-prev3-20260706` from the July restore drill |
| Cannot empty the set | The floor is unconditional. If backups stop being created, everything ages past `maxAgeDays` and an age-only rule would delete every local restore point; with the floor, pruning simply stops |
| Cannot reach beyond two namespaces | No ClusterRole. One Role + RoleBinding per entry in `values.clusters` |
| Cannot create or modify anything | Verbs are `get`, `list`, `delete` only |
| Failures are visible | Non-zero exit on any delete failure; the existing `UserNamespaceCronJobNotSucceeding` AlertingRule in `components/cluster-config/monitoring-config/` already covers these namespaces |

## Enabling it for real

It ships with `dryRun: true` on purpose. Deleting backups is not a change to make sight-unseen.

```bash
# 1. Trigger a run and read what it would do
oc -n cnpg-snapshot-retention create job --from=cronjob/cnpg-snapshot-retention prune-check
oc -n cnpg-snapshot-retention logs job/prune-check

# 2. If the set is what you expect, flip dryRun to false in values.yaml and commit.
```

## Testing a change

The script can be exercised against the live cluster without any mutation, using the read-only kubeconfig and
the same image the CronJob uses:

```bash
helm template cnpg-snapshot-retention components/cluster-config/cnpg-snapshot-retention/ \
  | yq e 'select(.kind=="ConfigMap") | .data["prune.sh"]' - > /tmp/prune.sh

podman run --rm --platform linux/amd64 --network host \
  -v /tmp/prune.sh:/script/prune.sh:ro \
  -v "$HOME/.kube/config-readonly:/kube/config:ro" \
  -e KUBECONFIG=/kube/config \
  -e MAX_AGE_DAYS=7 -e FLOOR=7 -e DRY_RUN=true \
  -e CLUSTERS="media/media-postgres immich/immich-postgres" \
  quay.io/openshift/origin-cli:4.22 /bin/bash /script/prune.sh
```

`--platform linux/amd64` is required: `origin-cli` publishes no arm64 image.

## Values

| Key | Default | Notes |
|---|---|---|
| `dryRun` | `true` | Flip only after reading a run's log |
| `retention.maxAgeDays` | `7` | Matches the intent of the (inert) `retentionPolicy: "7d"` on the clusters |
| `retention.floor` | `7` | Minimum kept per cluster regardless of age |
| `schedule` | `30 5 * * *` | Offset from the 04:00/04:30 backups |
| `clusters` | media, immich | Each entry also generates its namespace's Role + RoleBinding |
