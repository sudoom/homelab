# okderators: OADP 1.6 for OKD 4.22 and 5.0 — working notes

Red Hat ships OADP 1.5.x for OCP 4.20/4.21 and 1.6.x only for OCP 4.22. This cluster is on OKD 4.22 since 2026-10-27 and
still runs `oadp-operator.v1.5.0-2026-01-05-165341` from `okderators`, which has no 1.6 build. The work follows the same
shape as logging 6.6, GitOps 1.22 and NMState: build on this cluster, move this cluster to a test build, soak, draft PRs
with that as proof, catalog PRs after upstream CI, then the official build. Earlier assessment:
`blog-okd-4.22-upgrade-draft.md` (OADP section, 2026-10-27).

## 2026-10-29 — recon; design and plan drafted, nothing built

The operator asked to plan it and skipped the design questions ("skip questions, same shape as nmstate"). So the design
choices below are mine and wait for the operator's review. The design and the 13-task plan are local
(`docs/superpowers/`, gitignored); nothing has been built, pushed or changed on the cluster.

### What OADP does here today

Nothing. Read on 2026-10-29:

```
CSV   version=1.5.0-2026-01-05-165341  skipRange=>=1.4.0 <1.5.3  installModes=OwnNamespace
DPA   Reconciled=True/Complete
BSL   truenas-garage Available
Schedule daily  paused=true  last=2026-06-08T13:55:20Z
backups: 0  restores: 0  backuprepos: 0  datauploads: 0
```

So the upgrade risks no backup data, and the proof has to create its own. That shaped the drill below.

### The pipeline: the OADP build has never run

`oadp/` is byte-identical on `main`, `release-4.22`, `release-4.21` and `release-4.20` (`build.sh`,
`patches/operator.patch`, every Containerfile, the `.gitmodules` stanzas); only the gitlinks differ. The OADP deploy
workflow has zero runs:

```
gh api "repos/okd-project/okd-operator-pipeline/actions/workflows/308632787/runs?per_page=10" --jq .total_count
0
```

The published 1.5.0 bundle (2026-01-05) is older than the current script ("[oadp] Update to 1.5", 2026-02-05), and it
reached the catalog through a direct maintainer commit (`57db45af`, "Finalise 4.20 catalog"). Our build would be the first
run of `oadp/build.sh` as it stands, so I expect more than one round.

What moving to 1.6 needs:

- `MINOR="6"` in `build.sh`. It is set before `common.sh`, so the bundle version is `1.<MINOR>.0-<DATE>` whatever
  `OKD_VERSION` says; `OKD_VERSION` only picks the payload `cli` image for must-gather.
- All 12 submodules at their `oadp-1.6` heads. Every repo has that branch, with an October 2026 head and `go 1.26.0`.
  Today's gitlinks are clean ancestors of `oadp-1.5`. The kubevirt plugin is hard-coded to `release-v0.8`; Red Hat's 1.6
  uses its `oadp-1.6` branch.
- Go 1.26 builders. Every Containerfile has `ubi9/go-toolset:1.24`; `go-toolset:1.26` exists (1.26.10).
- The Velero version string: `velero.Containerfile` hard-codes `buildinfo.Version=v1.16.1-OADP`, and 1.6 is Velero v1.18.x.
- The OKD patch regenerated. Against the `oadp-1.6` operator (head `483de5e`, 2026-10-22):

  ```
  git apply --check -v operator.patch
  error: while searching for:
      containerImage: quay.io/konveyor/oadp-operator:oadp-1.5
      createdAt: "2025-09-03T00:37:40Z"
  error: patch failed: config/manifests/bases/oadp-operator.clusterserviceversion.yaml:4
  ```

  Only the context lines moved; the OpenShift strings it replaces are still there.
- Two bugs read from the code, not yet seen in a run. `init()` never initialises `oadp/kopia` or `oadp/restic`, although
  two Containerfiles COPY them. `must-gather.Containerfile` builds "gather" from the operator's `cmd/main.go`, while 1.6's
  must-gather is its own repo, `openshift/oadp-must-gather`.
- `release-4.22`'s `oadp-deploy.yaml` triggers on `main` and would default to catalog `release-4.21`; it needs
  `release-4.22` and `catalog_branch: release-4.22`, as for NMState.

Red Hat has only `oadp-1.6` and `oadp-dev` (CSV 99.0.0), and openshift/release CI tests `oadp-1.6` on 4.22 and 5.0, so 1.6
is the right base for `main` too. No OADP PR or issue exists in `okd-operator-pipeline`.

### The image set: 18 in 1.6, the pipeline builds 10

Red Hat's 1.6.2 CSV has 18 `relatedImages`. The pipeline builds 10 of them plus the bundle. Not built: four VM file
restore images, `vmdp-cli-download`, two kubevirt-datamover images (all new in 1.6), and `oadp-cli-binaries`, which the 1.5
bundle already leaves as a `quay.io/konveyor` image pinned by digest (`build_bundle()` maps env vars by name and leaves the
rest alone).

My proposal: follow that precedent for the seven new ones, and state it in the PR. They need KubeVirt, which this cluster
does not run, so here I could only prove that they build. Building them means six more submodules, and is a follow-up if
the operator or the maintainers want it. This is the biggest open call.

### The catalog: Red Hat's range does not cover our install

`catalog/oadp-operator/` is identical on 4.20, 4.21 and 4.22: `v1.4.0-2024-09-04-143635` → `v1.4.0-2025-01-23-195220` →
`v1.5.0-2026-01-05-165341`, chained by `replaces`, no entry `skipRange`. `release-5.0` stops at the second 1.4.0, so 5.0
users have never been offered 1.5.

Our installed semver is `1.5.0-2026-01-05-165341`, a prerelease that sorts below `1.5.0`, so Red Hat's
`'>=1.5.0 <1.6.2'` does not reach it. `catalog-walk.py` on a synthetic catalog with a new head
`oadp-operator.v1.6.0-2026-11-01-120000`:

```
skipRange '>=1.5.0 <1.6.2' only        FAIL  two heads, installed CSV stranded
skipRange '>=1.5.0-0 <1.6.0' only      FAIL  the edge exists, still two heads
replaces: v1.5.0-2026-01-05-165341     PASS  single head, 4 entries reach it
```

The proposed 4.22 entry is that `replaces` plus `skipRange: '>=1.4.0-0 <1.6.0-<DATE>'`: the upper bound sits below the
entry's own prerelease, as for GitOps, and it is what lets a later official build pick up our test CSV. The 5.0 entry is
the same with `replaces: oadp-operator.v1.4.0-2025-01-23-195220`.

### The upgrade: this cluster's config survives

From a script diff of the CRDs on `oadp-1.5` and `oadp-1.6` and Red Hat's OADP 1.6 docs:

- DPA CRD: nothing removed, renamed or default-changed; 59 properties added. New CRDs
  `virtualmachinebackupsdiscoveries` and `virtualmachinefilerestores`. Velero CRDs only gain fields (five read in detail,
  the rest unverified).
- Every field this cluster's DPA, BSL and Schedule use is unchanged. 1.6 rejects `uploaderType: restic`; we use kopia.
- 1.6 creates NetworkPolicies in `openshift-adp`: egress is unrestricted, so garage at `192.168.1.25:30188` stays
  reachable. Velero ingress is limited to 8085 from the monitoring namespaces, and nothing here scrapes Velero.
- Kopia goes 0.19 → 0.22 with no documented repository-format migration. That is the absence of a note, not a guarantee.
- Red Hat's procedure starts from the latest 1.5.x. okderators only has 1.5.0 (operator `5520b16`, 82 commits behind
  1.5.8), and the CRD diff was against the 1.5 head, so reading the InstallPlan is the check for our older 1.5.

### The drill

With 0 backups there is nothing to restore across the upgrade, so the plan makes one: a scratch namespace with a 1 GiB
`ceph-nvme-block` PVC holding a 64 MiB file of known checksum. Backup on 1.5 and restore on 1.5, which proves the drill
itself; upgrade; restore the 1.5 backup on 1.6; fresh backup and restore on 1.6. The pass condition includes a `DataUpload`
with `bytesDone > 0` and a matching checksum, because a Backup can read `Completed` with no volume data. `ceph-rbd-snapshot`
has no `velero.io/csi-volumesnapshot-class` label, so the Backups name it by annotation instead of changing the Rook chart.
The drill's backups are deleted from the bucket after the 24 h soak, and Schedule `daily` stays paused throughout.

### Waiting on the operator

Review of the plan, mainly: the konveyor images above; branches `main` + `release-4.22` with catalogs 4.22 + 5.0; the drill
writing to the garage bucket; `main` built in full only with ≥ 8 GiB free on zot after the `release-4.22` build (14 GiB free
on 2026-10-29).

## 2026-11-02 — verifying backup after installation; corrections from the first review

The operator asked: "after installation, we should verify that backup is working". The plan already had a drill, so I
checked what it would and would not prove, then had a Fable review agent read the plan cold. Still nothing built.

### What changed in the drill

- **It takes the path `daily` takes.** Drill Backups use the Schedule's template (`snapshotMoveData: true`,
  `defaultVolumesToFsBackup: false`, BSL `truenas-garage`), scoped to `oadp-drill`. `includeClusterResources` stays unset
  on purpose: `true` would make its Restores try to recreate every cluster-scoped object on the live cluster.
- **The Schedule path.** A scoped `drill-schedule` with `skipImmediately: true` must produce a `Completed` Backup from a
  cron tick on 1.6, then is deleted. `daily` stays paused.
- **After a day of running.** At the end of the soak, once a maintenance Job has completed, one more backup and restore.
- **On the official build.** The earlier drills ran on the test images, so the drill repeats after the move to
  `okderators`, before the test catalog goes.
- **Proof the bytes landed.** Garage's `velero` bucket has to grow (`GetBucketInfo`, operator-run), for backups of new
  bytes only. My first version measured the `tank/s3/data` dataset, and the review caught two problems with it: Loki's
  bucket lives in the same garage, so a broken backup could pass on Loki's growth, and Kopia dedups a repeat of the same
  file, so the soak backup could fail for no reason.
- **`ttl: 336h`**, not 72 h. If the upgrade slipped past 72 h, `drill-15` would expire, and 1.5 cannot be re-installed to
  retake it.

No `DataDownload` appears anywhere in this repo. The proven restores are a ConfigMap (2026-05-28) and file-system backup
(2026-08-28), and `daily` uses neither path for volumes, so the drill on 1.5 is the first recorded data mover restore here.
The chart's "the restore path itself is proven" means the file-system path.

All of this proves the tool. `daily` stays paused (README TODO "Scope OADP backups before un-pausing"), so the cluster
still backs nothing up when the plan ends.

### Corrections to the 2026-10-29 section

- **"The 1.5 bundle already leaves `oadp-cli-binaries` as a `quay.io/konveyor` image": wrong for what is published.** That
  is what `build_bundle()` would do. The installed CSV has 21 `relatedImages`, all `quay.io/okderators`, and no CLI env:

  ```
  relatedImages 21 Counter({'quay.io/okderators': 21})
  openshift-adp-controller-manager []
  ```

  So there is no published precedent for a konveyor image in an okderators OADP bundle.
- **"They need KubeVirt, so here I could only prove that they build": wrong for two of them.** With the ConsoleCLIDownload
  CRD present, the 1.6 operator creates two download servers at start, KubeVirt or not (`cmd/main.go`, `CLIDownloadSetup`
  and `VMDPDownloadSetup`), each with a Deployment, Service, Route and a cluster-scoped `ConsoleCLIDownload`. Their images
  are `console-cli-download` and `vmdp-cli-download`, built from `migtools/oadp-cli` and `migtools/oadp-vmdp`, both with
  `oadp-1.6` branches. So the image call is now three options: keep all eight from konveyor, build the two that run, or
  build all eight. I recommend building the two.
- **"`ceph-rbd-snapshot` has no label, so the Backups name it by annotation": unnecessary.** Velero picks the only class
  for a driver without a label or annotation (`GetVolumeSnapshotClassForStorageClass`, same on `oadp-1.5` and `oadp-1.6`).
  The annotation only made the drill unlike `daily`, so it is gone.
- **"Kopia goes 0.19 → 0.22": does not match `go.mod`.** Both Velero branches pin `kopia v0.16.0`, replaced by a
  `migtools/kopia` fork (2026-09-04 on `oadp-1.5`, 2026-10-12 on `oadp-1.6`). The risk stands: no documented repository
  migration, and restoring the 1.5 backup on 1.6 is the check.
- **"The drill's backups are deleted from the bucket": not straight away.** `DeleteBackupRequest` tombstones them and Kopia
  reclaims the blobs at its weekly full maintenance, which is the 2026-06-08 lesson in `blog-oadp-draft.md`.

The review also changed the rollback order: commit the revert first, because ArgoCD selfHeal recreates a deleted
Subscription from git, then delete the 1.6 CSV. I took OLM's `startingCSV` behaviour from the review and did not read
`resolver.go` myself, so it gets confirmed when the runbook is written.

### Waiting on the operator

Plan review, now mainly: which of the eight unbuilt images to build, and whether real scheduled backups are part of this
work.

## 2026-11-02 — the operator's decisions; all 18 images

The operator's answers to the two open calls. Real scheduled backups: "no", so `daily` stays paused and that stays its own
README TODO. Images: "1.6 should be covered not only for me, but for everyone who want to use oadp". So the pipeline
builds all 18, and the bundle carries no konveyor image.

I kept `main` and `release-4.22` only, because Red Hat ships 1.6 only for 4.22. And I am not installing KubeVirt here for
one test, with two nodes at about 89% CPU requests, so the VM file restore and KubeVirt datamover images are built and
smoke-run but not exercised. The PR says so.

Where the eight images come from, read at their `oadp-1.6` heads (all `go 1.26.0`; compressed sizes of konveyor's builds,
912 MiB in total):

| `RELATED_IMAGE_*` | Source and build file | MiB |
|---|---|---|
| `VM_FILE_RESTORE_CONTROLLER` | `migtools/oadp-vm-file-restore` `Dockerfile` | 37 |
| `VM_FILE_RESTORE_ACCESS` | same, `containers/oadp-vmfr-access/Dockerfile` | 315 |
| `VM_FILE_RESTORE_SSH` | same, `containers/side-containers/sshd/Containerfile` | 67 |
| `VM_FILE_RESTORE_BROWSER` | `migtools/filebrowser` `Containerfile` | 54 |
| `CONSOLE_CLI_DOWNLOAD` | `migtools/oadp-cli` `Containerfile.download` | 152 |
| `VMDP_CLI_DOWNLOAD` | `migtools/oadp-vmdp` `Containerfile.download` | 107 |
| `KUBEVIRT_DATAMOVER_CONTROLLER` | `migtools/kubevirt-datamover-controller` `Dockerfile` | 95 |
| `KUBEVIRT_DATAMOVER_PLUGIN` | `migtools/kubevirt-datamover-plugin` `Dockerfile` | 85 |

A second Fable review read this scope against source. What it changed:

- **filebrowser would have shipped broken to exactly the people it is for.** I had named `konflux.Dockerfile`. That image
  puts the binary at `/filebrowser`, and the VM file restore controller runs the sidecar with `/bin/bash -c` and a script
  that hard-codes `/usr/local/bin/filebrowser` (`internal/controller/container_scripts.go`). It would have passed a
  `filebrowser version` check and failed at `config init` on every KubeVirt cluster. The public `Containerfile` has the
  right layout, and my claim that the only source build needs `brew.registry.redhat.io` was wrong. The build also fails now
  on a missing `frontend/dist/index.html`, because `dist/*` is embedded and a committed `.gitkeep` would otherwise build a
  UI-less binary silently.
- **Smoke tests that could not have worked.** Both download servers parse no flags and would block on `--help`, and
  `oadp-sshd` is a forced-command shim that exits 1 by design. Each now has its own check.
- **zot's budget is tighter than I had it.** GC runs every 24 h (`gcInterval`), so deleting a failed round frees nothing
  until the next pass. At about 3.5 GiB a full build, 14.6 GiB free covers two full builds and no uncollected failures,
  so the gates read measured free space.
- **Smaller:** `go-toolset` is uid 1001, so the download images cannot write `/archives` as upstream does; upstream's
  `fedora:42` is past Fedora's support window by its schedule (Task 1 confirms it); `relatedImages` has 19 entries, because
  `--use-image-digests` adds the manager; the datamover is enabled by `defaultPlugins: [kubevirt-datamover]`.

Rejected nothing. Still nothing built; waiting on plan approval.
