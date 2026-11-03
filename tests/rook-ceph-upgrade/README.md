# Rook v1.19.5 -> v1.21.1 and Ceph Squid -> Tentacle: upgrade runbook

Staged upgrade of the storage stack (Rook v1.19.5 -> v1.20.9 -> v1.21.1, Ceph Squid 19.2.4 -> Tentacle 20.2.5,
msgr2 required in its own stage). This directory holds the read-only instruments every stage uses to decide whether
it went well, plus the CSI smoke test. The design record goes to `blog/blog-rook-ceph-draft.md`; every storage
action is logged there with the exact command and the output that drove the decision.

Stages: B (backup), M (baseline measurements), 1 (Rook v1.20.9), 2 (Rook v1.21.1), 3 (msgr2), 4 (Ceph Tentacle).

## Gates (before Stage B and before every stage commit)

- [ ] OADP and descheduler soaks finished
- [ ] Freeze holding since the baseline: no in-cluster builds, no MachineConfig reroll, no logging removal, no power-tuning change
- [ ] Ceph HEALTH_WARN with only `BLUESTORE_SLOW_OP_ALERT`
- [ ] PGs active+clean
- [ ] No MCP updating; no node cordoned
- [ ] CNPG `ContinuousArchiving=True` on media, immich and homebox
- [ ] Not Monday 19:00-23:00Z (descheduler operand roll; next Monday is 2026-11-09)
- [ ] 2 h headroom; quiet IO
- [ ] The stage's images `IMAGE OK` through zot, and zot's free space read after

## Scripts (`verify/`)

| Script | Who runs it | What it does |
|---|---|---|
| `csi-state.sh --expect stage0..stage4` | controller, readonly kubeconfig | One `CHECK PASS\|FAIL <name> <observed>` line per check, an `INFO driver-uid=... driver-generation=... cephx=...` line, exit 0 only if all pass. `KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage0` |
| `ceph-reads.sh <label>` | the operator (it needs `oc exec` into `deploy/rook-ceph-tools`) | Captures versions, health, df, osd tree, mon dump, cipher, osd flags, msgr config, the CSI user's caps and entity/type list. CephX keys are stripped by jq; if anything key-shaped remains the file is deleted and the script exits 2. |
| `images-check.sh <image>...` | controller (needs `zot.apps.okd.sudops.pl`) | Maps each ref onto zot by dropping the registry host and runs `skopeo inspect --raw`. Prints `IMAGE OK\|MISSING <ref>`, exit non-zero on any MISSING. A manifest request makes zot fetch the image, so it also pre-pulls: measure zot's free space after. |

Evidence goes to `.superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/` and is never committed (gitignored
tree); result rows are copied into the blog draft instead.

## CSI smoke test (`smoke/`)

Run before and after each stage. Apply and delete are the controller's, one permission prompt per command.

1. `namespace.yaml` -> namespace `rook-upgrade-smoke`
2. `pvc.yaml` -> PVC `smoke` (1Gi, `ceph-nvme-block`)
3. `pod.yaml` -> Pod `smoke-writer`: writes 64 MiB random data plus its sha256, prints `SMOKE written sha256=...`
4. `snapshot.yaml` -> VolumeSnapshot `smoke-snap` (class `ceph-rbd-snapshot`); wait for `readyToUse`
5. `restore-pvc.yaml` -> PVC `smoke-restore` from the snapshot
6. `restore-pod.yaml` -> Pod `smoke-reader`: prints `SMOKE restored sha256=<recomputed> stored=<stored>`

Pass = the writer's sum, the reader's recomputed sum and the reader's stored sum are all equal. Then delete the
namespace (`oc delete namespace rook-upgrade-smoke`) and confirm the PVs and RBD images are gone.

## Stage B: backup

One-off OADP 1.6 (Velero v1.18.4, Kopia data mover) backup of the app PVCs to the garage bucket (BSL
`truenas-garage`), proven by one restore. Manifests in `backup/`. Apply and delete are the controller's, one
permission prompt per command; the `!` lines are the operator's. Read the Velero kinds in full:
`backups.velero.io`, `restores.velero.io`, `datauploads.velero.io`, `datadownloads.velero.io` (`oc get backup`
resolves to CNPG's kind).

**Gates.** The list above, except that Stage B waits for the OADP soak and drill cleanup, not for the descheduler
soak (that one gates the stage commits and the baseline). Also: Schedule `daily` stays paused; do it in quiet hours
(the Kopia upload reads every Ceph PVC in scope).

**Scope** (2026-11-03): `grafana`, `homebox`, `immich`, `keepers`, `media`, `zot`; about 166 GiB of PVC requests
(grafana 1, homebox 5, immich 20, keepers 2, media 88, zot 50). CNPG volumes ride along in `homebox`, `immich` and
`media`. Snapshots are crash-consistent and the apps are not quiesced (accepted).

**Free space (operator).** Read the garage dataset's free space on the NAS and compare it with the 166 GiB scope:
`ssh truenas_admin@192.168.1.25 'zfs list -o name,used,avail tank/s3'`. Kopia compresses and dedups, so 166 GiB is the
ceiling; stop if avail is under it.

### Volume policy: every non-Ceph PV is skipped

`volume-policy.yaml` carries two `skip` rules (`nfs: {}` and `csi: {driver: nfs.csi.k8s.io}`), `version: v1`. Read
2026-11-03 from the PVs bound in the six namespaces (readonly kubeconfig): the four non-Ceph volumes are all CSI NFS
PVs (none uses the in-tree `nfs` source, so only the second rule matches them); every other bound PVC is
`rook-ceph.rbd.csi.ceph.com` / `ceph-nvme-block` and is backed up.

| ns/pvc | csi.driver | nfs.server (csi volumeAttributes) | storageClassName | matched by |
|---|---|---|---|---|
| immich/immich-library | nfs.csi.k8s.io | 192.168.1.2 | nfs-csi | csi rule |
| immich/immich-library-nfs | nfs.csi.k8s.io | 192.168.10.10 | (empty, static PV) | csi rule |
| keepers/keepers-data-nfs | nfs.csi.k8s.io | 192.168.10.10 | (empty, static PV) | csi rule |
| media/media-data-nfs-pvc | nfs.csi.k8s.io | 192.168.10.10 | (empty, static PV) | csi rule |

The other 17 PVCs are Ceph RBD and in scope: grafana-pvc; homebox-data, homebox-postgres-1, homebox-postgres-2;
immich-postgres-1, immich-postgres-2; transmission-config-pvc, webtlo-data-pvc (keepers); bazarr, jellyfin, prowlarr,
radarr, sonarr, transmission and transmission-slave config PVCs plus media-postgres-1 and media-postgres-3 (media);
data-zot-0. The expected DataUpload count is 17 (re-count with the command below before applying).
`grafana-pvc` is backed up but mounted by no pod (Grafana uses an emptyDir), so it is not the restore check.
`immich-library` (nfs-csi, 192.168.1.2) is a leftover dynamic PVC; it is skipped like the rest.

```bash
KUBECONFIG=~/.kube/config-readonly oc get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.storageClassName}{"\n"}{end}' | grep -E '^(grafana|homebox|immich|keepers|media|zot)/' | grep -c ceph-nvme-block   # 17
```

**Velero docs checked (v1.18).** Volume policy syntax (`version: v1`, `nfs: {}`, `csi: {driver: ...}`, actions
`skip|snapshot|fs-backup`, Backup `spec.resourcePolicy: {kind: configmap, name: ...}`):
https://velero.io/docs/v1.18/resource-filtering/ (that page shows the CLI flag `--resource-policies-configmap` and
names no ConfigMap data key; `policy.yaml` is our choice, the doc's example creates it from a file). The page does
not say that `skip` also covers the CSI-snapshot / data-mover path; that it does is from the Velero 1.14+ release
notes, not shown in a 1.18 page. The table above is therefore also what you verify after the Backup: no DataUpload
may exist for an NFS PVC.
Data-mover restore: https://velero.io/docs/v1.18/csi-snapshot-data-movement/ says the CSI plugin, per PVC, "checks the
backup information, if a data movement was involved, it creates a `DataDownload` CR". The page does not address a
PVC-only restore explicitly, but the trigger is the PVC item plus the backup's data-movement record, so
`includedResources: [persistentvolumeclaims]` should run the DataDownload; the pass criteria below confirm it
(if the PVC stays Pending with no DataDownload, read the Restore's `status.warnings` first, then add only the
kinds the logs name, still mapped into `rook-upgrade-restore`).

### Order

1. Baseline bucket size (operator, `tests/oadp-1.6-drill/README.md` "Bucket size"); note bytes and objects.
2. `volume-policy.yaml` -> ConfigMap `pre-rook-upgrade-policy` (ns `openshift-adp`).
3. `backup.yaml` -> Backup `pre-rook-upgrade`. Watch:
   `oc -n openshift-adp get backups.velero.io pre-rook-upgrade -o jsonpath='{.status.phase} errors={.status.errors} warnings={.status.warnings}{"\n"}'`
   and `oc -n openshift-adp get datauploads.velero.io -l velero.io/backup-name=pre-rook-upgrade`. Note
   `.status.startTimestamp`.
4. Bucket size again about a minute after `Completed`: it must have grown.
5. `restore-namespace.yaml`, then `restore-check.yaml` -> Restore `pre-rook-upgrade-check` (keepers PVCs only);
   watch `restores.velero.io` and `datadownloads.velero.io` until `Completed`. `webtlo-data-pvc` and
   `transmission-config-pvc` are Bound in `rook-upgrade-restore`. The restore also creates `keepers-data-nfs` there;
   it **stays Pending by design** (its PV `truenas-keepers-data` is a static NFS PV bound to the live claim, and the
   volume policy skipped it). Ignore it, never mount it; it is deleted with the namespace. A Restore that ends
   `PartiallyFailed` only because of that claim: read `status.warnings`/`errors` and report, do not retry.
6. `checker-pod.yaml` -> Pod `restore-checker` (mounts the two restored Ceph PVCs read-only);
   `oc -n rook-upgrade-restore logs restore-checker > restored.txt` prints `sha256  size  mtime  path` per file in
   sections `CHECK begin webtlo|transmission` ... `CHECK end ...`. Any `ERROR` line is a FAIL (a file could not be
   read; the list is never silently shortened).
7. Operator, the same list inside the live pods (read-only `oc exec`). Mounts read 2026-11-03: pod `webtlo-*`,
   container `webtlo`, `webtlo-data-pvc` at `/data`; pod `transmission-*`, container `transmission`,
   `transmission-config-pvc` at `/config` (`keepers-data-nfs` is also mounted at `/data` there; do not list it).

```bash
# OPERATOR
live_list() { oc -n keepers exec "$1" -c "$2" -- sh -c "cd $3 && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do sum=\$(sha256sum \"\$f\") || { echo \"ERROR \$f\"; continue; }; echo \"\${sum%% *}  \$(stat -c '%s  %Y' \"\$f\")  \$f\"; done"; }
live_list "$(oc -n keepers get pods -o name | grep '/webtlo-')" webtlo /data > webtlo-live.txt
live_list "$(oc -n keepers get pods -o name | grep '/transmission-')" transmission /config > transmission-live.txt
```

   If a live image lacks `find`/`stat`/`sha256sum`, say so and the controller adapts the one-liner.
8. Compare only files whose mtime predates the Backup's `status.startTimestamp` (apps write after the snapshot, and
   those files differ legitimately). `START` = the startTimestamp in epoch seconds
   (`date -u -j -f %Y-%m-%dT%H:%M:%SZ <ts> +%s` on macOS). Per PVC (`vol` = `webtlo` or `transmission`; the
   restored section is the lines between `CHECK begin vol` and `CHECK end vol`):
   `awk -v s="$START" '$3 < s' vol-live.txt > vol-live.cmp`, the same on the restored section into
   `vol-restored.cmp`, then `wc -l vol-live.cmp vol-restored.cmp` and `diff vol-live.cmp vol-restored.cmp`.
9. Cleanup (controller): delete the Restore, then `oc delete namespace rook-upgrade-restore` and confirm both PVs
   and RBD images are gone. The Backup stays (ttl 720h) as the pre-upgrade fallback.

### Pass criteria

- Backup `Completed`, `status.errors` 0 (note warnings).
- One DataUpload `Completed` per Ceph PVC in scope (17), none for an NFS PVC.
- Bucket bytes and objects grew.
- Restore: DataDownloads `Completed` for `webtlo-data-pvc` and `transmission-config-pvc`; no `ERROR` line in the
  checker log.
- Compare counts: per PVC the live and restored `.cmp` line counts are equal, and the total over both PVCs is at
  least 1. A diff of two empty files is not a pass.
- `diff` is empty for both PVCs (every sha256, size and mtime equal).

**Stop rules.** Any mismatch on a file older than the Backup's `status.startTimestamp` is a FAIL: Stage B stops and is
reported to the operator (no retry, no pass). An empty compare set (total 0) is also a stop-and-report; there is no
automatic fallback PVC.

## Stage M: baseline

(empty)

## Stage 1: Rook v1.20.9

(empty)

## Stage 2: Rook v1.21.1

(empty)

## Stage 3: msgr2

(empty)

## Stage 4: Ceph Tentacle 20.2.5

(empty)
