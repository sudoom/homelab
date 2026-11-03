# OADP 1.6 backup drill

Proves that OADP takes a real data mover backup and restores it, on the path Schedule `daily` would take
(`snapshotMoveData: true`, BSL `truenas-garage`, `ceph-nvme-block` + `ceph-rbd-snapshot`), without backing up
anything the cluster depends on. It runs four times around the move from the okderators 1.5 build to the 1.6 test
build (`components/operators/oadp/README.md`): on 1.5, right after the upgrade, after a 24 h soak and on the official
build. Every command that mutates is **operator-run** (`# OPERATOR`); every check is a read under the readonly SA.
Schedule `daily` stays `paused: true` the whole time, and nothing here touches it or the DPA.

A `Completed` Backup proves nothing by itself (the 2026-08-28 rehearsal called a backup with no volume data "green and
empty"), and a backup of bytes that did not change proves little more: the data mover finds the parent snapshot and
Kopia treats unchanged entries as cached, so it uploads nothing and a restore just returns the blobs an earlier
backup (possibly 1.5) wrote. A 1.6 that cannot read file data or write a blob would pass. So **every backup after
the first writes new bytes first** (the `gen` file below). A drill passes only when all of these hold:

1. Backup `Completed`, `errors=0 warnings=0`;
2. a `DataUpload` for the PVC `Completed` with `bytesDone > 0` (zero DataUploads is a FAIL whatever the phase says);
3. garage's `velero` bucket grew by at least 50 MiB since the reading taken just before the Backup (below);
4. on 1.6 (`drill-16`, `drill-16-soak`, the Schedule's Backup, `drill-off`): the DataUpload's
   `.status.incrementalBytes > 0` (a field of the 1.6 CRD only, `pkg/controller/data_upload_controller.go:509`; the
   1.5 CRD has no such field, so run 1 relies on the bucket growth);
5. the Restore `Completed` with a `DataDownload` `Completed`;
6. the writer in the restore namespace logs `DRILL sha256=<A>` and `DRILL gen=<G>`, equal to the source writer's
   lines that were current when the Backup was taken.

## The writer

`writer.yaml` is one pod (`ubi9/ubi-minimal` by digest) with two 64 MiB files of `/dev/urandom` on `/data`:

- `drill.bin` + `drill.sha256`, written once, the first time the source pod starts. Its sum is `<A>`.
- `gen.bin` + `gen.sha256`, rewritten with fresh random bytes on **every start** of the source pod. Its sum is `<G>`,
  the generation. `oc -n oadp-drill rollout restart deploy/drill-writer` gives the next one.

The log shows `DRILL sha256=<A>` and `DRILL gen=<G>`: sums **recomputed from the files on the volume**, printed only
if they equal the sums stored next to the files. Random bytes do not compress or dedup, so each new generation costs
about 64 MiB in the bucket. Which `<G>` belongs to which Backup: the one logged after the last restart before the
Backup was applied. Do not restart the pod between reading `<G>` and the Backup being `Completed`.

A restore recreates the Deployment too, so the restored pod must not be able to write a new file and print a
checksum that looks right and proves nothing. Two things prevent it:

- **Velero.** The data mover restore creates the PVC with a label selector and no volume; no provisioner satisfies
  a selector (external-provisioner: `claim Selector is not supported`), so the PVC stays `Pending` and the pod stays
  unschedulable until the `DataDownload` has written the restored volume and Velero has rebound that PV to the PVC
  (`pkg/restore/actions/csi/pvc_action.go`, `pkg/exposer/generic_restore.go` `RebindVolume`, `openshift/velero`
  branch `oadp-1.6`). The storage class binds `Immediate`, so this does not depend on pod scheduling.
- **The script.** Only a pod in namespace `oadp-drill` ever creates either file. In any other namespace it creates
  nothing: it waits until `drill.bin`, `drill.sha256`, `gen.bin` and `gen.sha256` have all appeared, then checks each
  file against its sum. An empty or half-restored volume shows `DRILL waiting ...`, never a sum. A mismatch logs
  `DRILL MISMATCH`, not `DRILL sha256=` / `DRILL gen=`.

So a restored namespace that logs `<A>` and `<G>` printed the sums of data that came out of the bucket. If a restored
pod stays `Pending` during the restore, that is the expected state until the DataDownload ends.

## Order

Gates before any run:

```bash
ocr() { KUBECONFIG=~/.kube/config-readonly oc "$@"; }
ocr -n openshift-adp get bsl truenas-garage -o jsonpath='{.status.phase} {.status.lastValidationTime}{"\n"}'   # Available
ocr -n openshift-adp get dpa dpa -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}{"\n"}'      # True
ocr -n openshift-adp get schedules.velero.io daily -o jsonpath='{.spec.paused}{"\n"}'                          # true
# CSI pre-flight (rook-ceph skill): a stray Released PV or a stuck VolumeAttachment blocks the provisioner cluster-wide
ocr get pv | grep -E "Released|Failed"                                                                         # nothing
ocr get volumeattachment -o jsonpath='{range .items[?(@.status.attached==true)]}{.metadata.name} {.spec.source.persistentVolumeName} {.spec.nodeName}{"\n"}{end}'   # every PV listed exists and is Bound
```

Always name the Velero kinds in full (`backups.velero.io`, `restores.velero.io`): `oc get backup` resolves to CNPG's
Backup on this cluster.

Commands used in every run (substitute the names):

```bash
# Backup: phase, errors, warnings, expiry
ocr -n openshift-adp get backups.velero.io drill-15 \
  -o jsonpath='{.status.phase} errors={.status.errors} warnings={.status.warnings} expires={.status.expiration}{"\n"}'
# DataUpload: bytesDone; incrementalBytes is empty on 1.5 (field absent), must be > 0 on 1.6
ocr -n openshift-adp get datauploads.velero.io -l velero.io/backup-name=drill-15 \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,DONE:.status.progress.bytesDone,TOTAL:.status.progress.totalBytes,INCR:.status.incrementalBytes'
# Restore: phase, errors, warnings
ocr -n openshift-adp get restores.velero.io drill-15-r15 \
  -o jsonpath='{.status.phase} errors={.status.errors} warnings={.status.warnings}{"\n"}'
# what the warnings and errors are (Velero's own log; the pod name is not needed)
ocr -n openshift-adp logs deploy/velero | grep -E 'drill-15-r15' | grep -E 'level=(warning|error)'
# the same for a Backup (condition 1 needs warnings=0; this shows what they are)
ocr -n openshift-adp logs deploy/velero | grep 'backup=openshift-adp/drill-15' | grep -E 'level=(warning|error)'
ocr -n openshift-adp get datadownloads.velero.io -l velero.io/restore-name=drill-15-r15 \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,DONE:.status.progress.bytesDone'
ocr -n oadp-drill-r15 get pods,pvc
ocr -n oadp-drill-r15 logs deploy/drill-writer
```

Restore warnings are recorded, not a fail by count: the 2026-08-28 rehearsal Restore (a ConfigMap-mapped
storage-class restore) was `Completed` with 0 errors and 7 warnings (`blog/blog-truenas-migration-draft.md`). A
Backup with warnings fails condition 1; a Restore with warnings is read line by line, and any warning about the PVC,
the DataDownload or the volume data is a FAIL. One expected exception: the Velero log line `PVC is not bound or has
no volume name` (`volumes_information.go`) is logged by `RestoreVolumeInfoTracker.Populate`, which runs after
`status.Warnings` is computed and while a data-mover PVC is still Pending by design (openshift/velero oadp-1.6
`restore_controller.go:700`, after L653 and L673-676; oadp-1.5 has the same code path). It is expected on every
data-mover restore and is not a FAIL; the checksums decide.

**Re-running a failed Restore:** applying the same name again does nothing, and an existing PVC in the target namespace
is skipped. Delete the Restore and its target namespace first, wait until both and the target PV are gone, then apply:

```bash
oc -n openshift-adp delete restores.velero.io drill-15-r15 --ignore-not-found     # OPERATOR
oc delete ns oadp-drill-r15 --ignore-not-found                                    # OPERATOR
ocr get pv | grep -E "oadp-drill-r15|Released|Failed"                              # nothing, then re-apply
```

### Run 1, on 1.5 (before the upgrade)

```bash
cd tests/oadp-1.6-drill
oc apply -f namespace.yaml -f pvc.yaml -f writer.yaml                                  # OPERATOR
ocr -n oadp-drill get pods                                                             # Running
ocr -n oadp-drill logs deploy/drill-writer                                             # DRILL sha256=<A>, DRILL gen=<G1>; write both down
```

Record the bucket (below), then back up:

```bash
oc apply -f backup-15.yaml                                                             # OPERATOR
ocr -n openshift-adp get backups.velero.io drill-15 -w                                 # until Completed / terminal
ocr -n openshift-adp get backuprepositories.velero.io                                  # oadp-drill-truenas-garage-kopia Ready
```

Read the bucket again: it grew by at least 50 MiB (conditions 1 to 3; no `incrementalBytes` on 1.5). Then:

```bash
oc apply -f restore-drill-15-r15.yaml                                                  # OPERATOR
```

`oadp-drill-r15` must log `DRILL sha256=<A>` and `DRILL gen=<G1>`.

### Run 2, on 1.6 (after the upgrade)

```bash
oc apply -f restore-drill-15-r16a.yaml                                                 # OPERATOR; the 1.5 backup restored by 1.6
```

`oadp-drill-r16a` logs `<A>` and `<G1>` (the generation `drill-15` captured). Then new bytes and the 1.6 backup:

```bash
oc -n oadp-drill rollout restart deploy/drill-writer                                   # OPERATOR
ocr -n oadp-drill rollout status deploy/drill-writer
ocr -n oadp-drill logs deploy/drill-writer                                             # DRILL gen=<G2>, a new value; sha256 still <A>
# record the bucket, then:
oc apply -f backup-16.yaml                                                             # OPERATOR
```

Conditions 1 to 4 for `drill-16`: bucket grew by at least 50 MiB, `INCR` greater than 0. Then
`oc apply -f restore-drill-16-r16b.yaml` (OPERATOR); `oadp-drill-r16b` logs `<A>` and `<G2>`.

A repository maintenance Job should have run since the upgrade, or record when it will. Newer than the upgrade means
its completion time is after the 1.6 CSV's creation:

```bash
ocr -n openshift-adp get jobs -l velero.io/repo-name=oadp-drill-truenas-garage-kopia \
  -o custom-columns='NAME:.metadata.name,DONE:.status.completionTime'
ocr -n openshift-adp get backuprepositories.velero.io oadp-drill-truenas-garage-kopia -o jsonpath='{.status.lastMaintenanceTime}{"\n"}'
ocr -n openshift-adp get csv oadp-operator.v1.6.0-2026-11-02-205027 -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
```

Then the Schedule path. The Backup it produces must write new bytes too, so restart the writer and record the bucket
first, and do not restart it again until that Backup is `Completed`:

```bash
oc -n oadp-drill rollout restart deploy/drill-writer                                   # OPERATOR; note the new DRILL gen
# record the bucket, then:
oc apply -f schedule-drill.yaml                                                        # OPERATOR
ocr -n openshift-adp get backups.velero.io -l velero.io/schedule-name=drill-schedule \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,START:.status.startTimestamp'
oc -n openshift-adp delete schedules.velero.io drill-schedule                          # OPERATOR, after the first Completed
```

The first Backup labelled `velero.io/schedule-name=drill-schedule` must be `Completed` (condition 1), have a
`DataUpload` with `bytesDone > 0` and `INCR > 0` (condition 4), its `startTimestamp` after the Schedule's creation and
on a `*/15` boundary, and the bucket must have grown by at least 50 MiB (condition 3). No restore is required for it.
Its Backups stay until cleanup.

### Run 3, after the 24 h soak

Required first: a repository maintenance Job `Completed` since the upgrade (commands above; its time must be after the
CSV's creation), because maintenance is what can damage a repository. Then new bytes and the backup:

```bash
oc -n oadp-drill rollout restart deploy/drill-writer                                   # OPERATOR; note DRILL gen=<G3>
# record the bucket, then:
oc apply -f backup-16-soak.yaml                                                        # OPERATOR
# conditions 1 to 4 (bucket grew >= 50 MiB, INCR > 0), then:
oc apply -f restore-drill-16-soak-r16c.yaml                                            # OPERATOR
```

`oadp-drill-r16c` logs `<A>` and `<G3>`. A failure here is a soak failure.

### Run 4, on the official build

First prove the drill runs on the official images, not the test build:

```bash
ocr -n openshift-adp get csv -o custom-columns='NAME:.metadata.name,PHASE:.status.phase'     # oadp-operator.v1.6.0-<official date> Succeeded; no -2026-11-02-205027
ocr -n openshift-adp get pods -o custom-columns='NAME:.metadata.name,IMAGES:.spec.containers[*].image,INIT:.spec.initContainers[*].image'
```

Every operator, Velero, node-agent and plugin image must be under `quay.io/okderators/oadp/` (none under
`zot.apps.okd.sudops.pl/okd-test/`). Then delete `oadp-drill` and recreate it (a fresh PVC, so a **new** `<A>`, call
it `<B>`, and a new `<G>`), record the bucket, `backup-off.yaml`, conditions 1 to 4, `restore-drill-off-roff.yaml`;
writer in `oadp-drill-roff` logs `DRILL sha256=<B>` and the source's `DRILL gen=`.

## Bucket size (operator-run, on the NAS)

garage's admin API, `GetBucketInfo` for bucket `velero` (`bytes` and `objects`). The token is read into a shell
variable on the NAS and never printed; the query shape matches `ansible/truenas/roles/truenas-apps/tasks/main.yml`
(`GetBucketInfo?id=<bucket id>`, the id from `ListBuckets`). Use the bucket, not the `tank/s3/data` dataset: Loki
writes to the same garage, so the dataset grows anyway. garage's counters lag a little, so read about a minute after
the Backup completes, and read once more just before each Backup is applied (the baseline).

```bash
# OPERATOR, from the workstation
ssh truenas_admin@192.168.1.25 'bash -s' <<'REMOTE'
set -eu
API=http://192.168.10.10:30190
TOK=$(midclt call app.config garage | python3 -c 'import sys,json;print(json.load(sys.stdin)["garage"]["admin_token"])')
BID=$(curl -s -H "Authorization: Bearer $TOK" "$API/v2/ListBuckets" | python3 -c '
import sys,json
print(next(b["id"] for b in json.load(sys.stdin) if "velero" in b.get("globalAliases", [])))')
curl -s -H "Authorization: Bearer $TOK" "$API/v2/GetBucketInfo?id=$BID" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print("velero bucket bytes=%s objects=%s" % (d["bytes"], d["objects"]))'
REMOTE
```

## Cleanup (after the last run that needs these Backups)

Order matters: the `DeleteBackupRequest`s need the Backups and the BackupRepository, and a plain
`delete backup` is wrong (the data stays in the bucket and the BSL sync recreates the CR).

```bash
# Task 9 Step 5 records the drill-schedule Backups' names; the Step 6 commit adds one DeleteBackupRequest each to
# delete-requests.yaml, by name, before this file is applied.
oc apply -f delete-requests.yaml                                                       # OPERATOR
ocr -n openshift-adp get deletebackuprequests.velero.io                                # none left, or read .status.errors on each
ocr -n openshift-adp get backups.velero.io | grep drill                                # none left
oc delete ns oadp-drill oadp-drill-r15 oadp-drill-r16a oadp-drill-r16b oadp-drill-r16c --ignore-not-found # OPERATOR
ocr get pv | grep -E "oadp-drill|Released|Failed"                                      # nothing (ceph-nvme-block reclaims)
oc -n openshift-adp delete restores.velero.io drill-15-r15 drill-15-r16a drill-16-r16b drill-16-soak-r16c --ignore-not-found   # OPERATOR
ocr -n openshift-adp get schedules.velero.io                                           # only daily, paused: true
```

On success the controller deletes each `DeleteBackupRequest` after processing it, so a request that is still listed
(phase `Processed` with errors) means something failed: read `.status.errors`. (The Restores are usually already gone,
because deleting the Backup removes the Restores made from it; hence `--ignore-not-found`.)

After the official-build run: `oc apply -f delete-requests-off.yaml`, delete namespaces `oadp-drill` and
`oadp-drill-roff` and Restore `drill-off-roff` (`--ignore-not-found`), then the BackupRepository, which nothing else
reaps and whose maintenance would otherwise keep running on an orphan:

```bash
oc -n openshift-adp delete backuprepositories.velero.io oadp-drill-truenas-garage-kopia   # OPERATOR, once no DeleteBackupRequest is left
```

Do not expect the bucket to shrink: Kopia reclaims blobs only at its weekly full maintenance
(`blog/blog-oadp-draft.md`, 2026-06-08), and the leftover is now several hundred MiB (a fresh generation per backup,
so the exact figure is the sum of the growths you recorded) rather than well under 1 GiB; say which in the blog.
Restore artifacts under `velero/restores/` and the `velero/kopia/oadp-drill/` prefix can outlive the CRs (rehearsal
cleanup note, 2026-09-07); look at the bucket after the final cleanup and delete leftover `oadp-drill` / `drill-*`
prefixes directly if present.
