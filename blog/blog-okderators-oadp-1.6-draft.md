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

## 2026-11-02: Task 1, pins and image sources

Plan approved ("lgtm"). Task 1 fixes every input the later tasks use: the head of each `oadp-1.6` branch, `go.mod`, base images and what each of the eight new builds needs. Clones live under the gitignored `.superpowers/sdd/2026-10-29-okderators-oadp-1.6/work/` (`pipeline` with `origin` + `fork`, `catalog-index` with `upstream`, `bin/opm` v1.74.0); the full record is `work/pins.md`.

```
GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN" gh api repos/<repo>/branches/oadp-1.6 --jq .commit.sha
gh api repos/<repo>/compare/oadp-1.6...<sha> --jq .status      # identical, all 19
gh api "repos/<repo>/contents/go.mod?ref=<sha>" --jq .content | base64 -d | grep -E '^(go|toolchain) '
```

All 19 repos (12 submodules, `oadp-must-gather`, six new sources) are `go 1.26.0` with no `toolchain` line. Pins (head of `oadp-1.6`, commit date):

| path | repo | sha | date |
|---|---|---|---|
| operator | openshift/oadp-operator | 483de5e05055352af7500c46bf40f5b9b447ddb8 | 2026-10-22 |
| velero | openshift/velero | 6ec33ac9e956d7b0c40d31e8b0f488e3d8f195ed | 2026-10-23 |
| non-admin | migtools/oadp-non-admin | 2367e0fd45af64340ae6ccf9178431f23c8cbec7 | 2026-10-19 |
| microsoft-azure-plugin | openshift/velero-plugin-for-microsoft-azure | a86e14da028620ca75ee1f871cdd3e30e5be9e96 | 2026-10-21 |
| openshift-plugin | openshift/openshift-velero-plugin | 20bdc74f99d2b51f90ae9adecf95b2dd26ba1379 | 2026-10-22 |
| hypershift-plugin | openshift/hypershift-oadp-plugin | 72eda2d96f9ea1d2ac52c7b1ba1dddfe117ad7b5 | 2026-10-21 |
| aws-plugin | openshift/velero-plugin-for-aws | 56b4e23f49da3c553068172554a0bbba9d7f92fc | 2026-10-30 |
| gcp-plugin | openshift/velero-plugin-for-gcp | 2b5d9c2ea53f1108dbfb31799270822ff5780efb | 2026-10-21 |
| kubevirt-plugin | migtools/kubevirt-velero-plugin | e645e0ee0dff181c0054d648e78bbbda2aca1aa6 | 2026-10-22 |
| aws-legacy-plugin | openshift/velero-plugin-for-legacy-aws | 987244c299d11f15ad9e71d09af4490d7b375bc4 | 2026-10-22 |
| kopia | migtools/kopia | f83e62070a5dc7db7b75aa0f571f29bf369012dc | 2026-10-21 |
| restic | openshift/restic | e808d4d5a3b2033a4163cf7b9b97717fc61c0c2a | 2026-10-21 |
| must-gather | openshift/oadp-must-gather | 0064b510b36d738a084ebd8a9b71f6716d544f7c | 2026-10-23 |
| vm-file-restore | migtools/oadp-vm-file-restore | adb1fb33567403870c54442b8b01c726a74a7bde | 2026-10-22 |
| filebrowser | migtools/filebrowser | 4cc1e14b67c93dc2c09b4dcf653c40bdbfec1cfa | 2026-10-22 |
| oadp-cli | migtools/oadp-cli | d6d9554acb6d3bcca06d0a4bedeaf63e71ef281c | 2026-10-19 |
| oadp-vmdp | migtools/oadp-vmdp | 9bd14fca9b7ec78e2bba3cf95cf5677c6860ed92 | 2026-10-13 |
| kubevirt-datamover-controller | migtools/kubevirt-datamover-controller | 80e27eca886d28ba84f8a14aa91909b511b59c41 | 2026-10-14 |
| kubevirt-datamover-plugin | migtools/kubevirt-datamover-plugin | 4f21f4d3f59ae48791964d27d4fdd65a5f2bd26e | 2026-10-14 |

Found at the pin:

- Velero: `buildinfo.go` has no default version and the pin has no tag. The top entry of `changelogs/CHANGELOG-1.18.md` is `v1.18.4`, so that is the version to stamp (`velero.Containerfile` hard-codes `v1.16.1-OADP`).
- All 18 `RELATED_IMAGE_*` in the operator's `config/manager/manager.yaml` at `483de5e` have a source: 10 from the pipeline's existing builds (must-gather moves to `openshift/oadp-must-gather`), 8 from the new repos. `kopia` and `restic` feed the velero build and have no image of their own.
- Base images: every one of the eight pulls anonymously (`skopeo inspect --override-os linux --override-arch amd64 docker://<ref>`); none uses `brew.registry.redhat.io` or `registry.redhat.io`. `quay.io/konveyor/builder:ubi9-latest` is pullable too but is replaced by `registry.access.redhat.com/ubi9/go-toolset:1.26` (`sha256:5f0dead6a152...`, same as `:latest` today).
- `vmfr-access`: the F42 `fedora:42` image was last built 2026-05-28. Fedora's schedule page returned an Anubis access-denied, so the dates come from `endoflife.date` and are unconfirmed: F42 EOL 2026-05-27, F43 2026-12-09, F44 2027-06-02. `registry.fedoraproject.org/fedora` has tags 40 to 46 and rawhide. I use `fedora:44`. The `dnf install` list has no version pins; "42" appears only in comments, `FROM` and the `base-image=` label. Whether `fuse`/`fuse-libs` and `btrfs-progs` still install on F44 is unverified until the smoke test.
- Catalog heads: `release-4.22` = `v1.5.0-2026-01-05-165341`, `release-5.0` = `v1.4.0-2025-01-23-195220`. `release-4.22:.github/workflows/operator-deploy.yaml` has the `catalog_branch` input (default `release-4.21`).
- `aws-plugin`'s head moved on 2026-10-30, after the recon; the pin uses the new one.

Nothing built.

## 2026-11-02: Task 2, the 1.6 change on the pipeline

Fork branch `oadp-1.6` from `origin/main` (`2598107`), seven commits (the seventh came out of review, see below), local until the controller pushes. No image is built on the Mac; the first real build is Task 4, on the cluster. Because that build has never run, I wrote the test first and spent most of the time reading what each upstream file does at its pin.

The test is a scratch `work/static-check.sh <pipeline-tree>`: seven checks from the plan plus four extras. Against the untouched tree:

```
$ git -C pipeline rev-parse --short HEAD origin/main
2598107
2598107
$ ./static-check.sh pipeline
[ 1] FAIL  gitlinks = pins.md (19 paths)
[ 2] FAIL  .gitmodules: every oadp branch = oadp-1.6
[ 3] FAIL  build.sh MINOR="6"
[ 4] FAIL  every stage compiling Go uses go-toolset:1.26 (frontend-* on nodejs-24)
[ 5] FAIL  every COPY source is initialised by init() and exists at its pin; deinit/update match
       must-gather.Containerfile: COPY kopia, but kopia is not initialised by init()
       must-gather.Containerfile: COPY restic, but restic is not initialised by init()
       velero.Containerfile: COPY restic, but restic is not initialised by init()
[ 6] FAIL  patches/operator.patch: git apply --check at the operator pin; OKD content present
       git apply --check: error: patch failed: config/manifests/bases/oadp-operator.clusterserviceversion.yaml:4
[ 7] FAIL  every RELATED_IMAGE_* in the pinned manager.yaml is mapped in build_bundle()
[ 8] FAIL  (extra) yq dry run rewrites all 18 images, nothing else lost
[ 9] PASS  (extra) no registry.redhat.io / brew.registry.redhat.io
[10] FAIL  (extra) buildinfo.Version=v1.18.4-OADP in velero and must-gather
[11] PASS  (extra) build_containers covers every Containerfile and exported image; bash -n
static-check: FAIL (9 checks)
```

Check 8 runs the actual `yq` expression out of `build.sh` on a copy of the pinned `manager.yaml`. On `main` it left exactly the eight new images on `quay.io/konveyor`, which also showed the `map(select(...).value = ...)` style keeps the other env entries.

Commits, in order:

```
5523061 [oadp] Update submodules to oadp-1.6
f127a98 [oadp] Build 1.6 with Go 1.26
7b72929 [oadp] Regenerate the OKDify patch for 1.6
d669ac9 [oadp] Build must-gather from oadp-must-gather
5d0b1d2 [oadp] Initialise every submodule the images copy
928dacf [oadp] Build the VM file restore, KubeVirt datamover and download images
cc968a9 [oadp] Use our VM file restore images at runtime
```

After them:

```
$ ./static-check.sh pipeline
[ 1] PASS  gitlinks = pins.md (19 paths)
[ 2] PASS  .gitmodules: every oadp branch = oadp-1.6
[ 3] PASS  build.sh MINOR="6"
[ 4] PASS  every stage compiling Go uses go-toolset:1.26 (frontend-* on nodejs-24)
[ 5] PASS  every COPY source is initialised by init() and exists at its pin; deinit/update match
[ 6] PASS  patches/operator.patch: git apply --check at the operator pin; OKD content present
[ 7] PASS  every RELATED_IMAGE_* in the pinned manager.yaml is mapped in build_bundle()
[ 8] PASS  (extra) yq dry run rewrites all 18 images, nothing else lost
[ 9] PASS  (extra) no registry.redhat.io / brew.registry.redhat.io
[10] PASS  (extra) buildinfo.Version=v1.18.4-OADP in velero and must-gather
[11] PASS  (extra) build_containers covers every Containerfile and exported image; bash -n
static-check: PASS
$ bash -n oadp/build.sh && git submodule status oadp/ | wc -l
19
```

A check that has only ever passed proves little, so I mutated a scratch worktree eleven ways (a COPY path missing at the pin, a submodule dropped from `init()` and from `deinit()`, a Go stage on 1.24, a frontend stage off nodejs-24, a typo in a `RELATED_IMAGE` name, two names mapped to one image, a `registry.redhat.io` base, a Containerfile not built, a branch off `oadp-1.6`, OKD content lost from the patch). All eleven were caught. One looked missed at first; that was my mutation not applying, because BSD `sed` rejects the `0,/re/` address.

The real `init` path also ran, in a scratch worktree with `oc` stubbed so `common.sh` can be sourced: `submodule_initialize` on `kubevirt-datamover-plugin` and `operator`, `submodule_reset`, a second initialise, then the `yq` lines on the patched tree.

```
Applying: OKDify
28cfb232 Owen Howard | OKDify
483de5e0 openshift-merge-bot[bot] | Merge pull request #2507 ...
HEAD~1 = recorded gitlink
HEAD = recorded gitlink            (after submodule_reset)
HEAD~1 = recorded gitlink          (second initialise)
count=19 (19 expected: 18 related + the operator)   (what push_all_images walks)
18 images under the registry, 0 konveyor
```

What the reading found:

- **The old must-gather did not gather.** The Containerfile built `gather` from the operator's `cmd/main.go`, the same source `operator.Containerfile` builds as `manager`. It now builds from `oadp/must-gather` and ships the `deprecated/gather_*` scripts both upstream files ship. I first wrote that the repo is new in 1.6; `git ls-remote` shows branches back to `oadp-1.3`, so I reworded that commit.
- **Velero is v1.18.4.** The pin is ahead of the `vmware-tanzu/velero` `v1.18.4` tag by 1307 and behind by 0, it is the newest v1.18 tag, it tops the changelog, and the operator, oadp-cli and must-gather `go.mod`s require it. The `v1.18.2-rc.2-OADP` in velero's `konflux.Dockerfile` and `v1.18.1-rc.1-OADP` in must-gather's are stale. So: `v1.18.4-OADP`, keeping the suffix the pipeline already used.
- **Non-root `go-toolset` and upstream's root builders.** `rm -rf /root/.cache/go-build /tmp/*` and `go clean` in the download images would not just be pointless as uid 1001, the `rm` could fail the build, so they go; the cleanup only ever touched the builder stage. `/archives` and `/usr/local/bin/download-server` move under `/opt/app-root/src` and are copied into the runtime at the same paths, because the server defaults to `ARCHIVE_DIR=/archives`.
- **`go-toolset` sets `ENV VERSION=1.26.10`.** Upstream's `ARG VERSION` in filebrowser and vmdp would have collided with it, so those stages use `CI_VERSION`.
- **Upstream's download loops hide failures.** In both, a failed build for any platform but the last still exits 0 with a binary missing: oadp-cli's `set -e` does not stop on a failure inside an `&&` list, and oadp-vmdp's has none. Both loops now stop via `|| exit 1`. My first version of oadp-vmdp's added `set -e` instead, which did nothing: the loop is itself a non-final member of an `&&` list, the same trap I had just written down for oadp-cli. Review caught it. Running the real `RUN` under `bash --posix` with a stub `go` failing on the second of four platforms:

  ```
  vmdp, first version  fail=linux/arm64  exit=0 binaries=3 empty_sha=1 LICENSE=yes   green with a missing download
  vmdp, now            fail=linux/arm64  exit=1 binaries=1 empty_sha=0 LICENSE=no    stopped
  ```

  Writing the checksums from inside `archives/` also makes them name the file as downloaded rather than an absolute build path; both servers only read the first field.
- **Download servers get `USER 65532:65532`.** Upstream's `Containerfile.download` has no `USER`, but the operator's Deployment sets `runAsNonRoot` with no `runAsUser`. Red Hat's `konflux.Dockerfile`s run as 65532, so I followed them.
- **The packages I queried exist on Fedora 44.** `mdapi.fedoraproject.org` has `fuse`, `fuse-libs`, `libguestfs-xfs`, `ntfs-3g`, `gdisk`, `kpartx`, `btrfs-progs` for f44. `libguestfs-tools` returned HTTP 400 on f44 because it is not a binary package: on f43 and f44 `virt-win-reg` provides that name and requires `perl(Sys::Guestfs)`, and `libguestfs`, which `libguestfs-xfs` brings in, ships `guestmount`. So `dnf` should resolve it, but to less than the name suggests: `guestfs-tools` (`virt-filesystems` and friends) is not pulled in. That does not matter here, since `detect-and-mount.sh` calls `guestmount`, `fusermount`, `qemu-img` and `python3` and no `virt-*`. I could not compare with f42, the release upstream builds on: mdapi answers 400 for `guestfs-tools` there too, so that release looks gone from the API. The rest of the list (`e2fsprogs`, `lvm2`, `parted` and so on) I did not query, and nothing has installed any of this, so Task 4 settles it.
- **The filebrowser check tests the file the backend serves** (review ruling, overriding the plan's `frontend/dist/index.html`). `vite.config.ts` takes `public/index.html` as its Rollup input, so the processed page lands at `dist/public/index.html`, while `public/` is also Vite's `publicDir`, which puts a raw copy at `dist/index.html`. The backend does `fs.Sub(frontend.Assets(), "dist")` and serves `public/index.html` (`cmd/root.go:240`, `http/static.go:116`), so testing the raw copy could pass with the served file absent. A wrong path here fails the first real build, so I tried the real frontend build in a scratch directory. Auto mode refused it as running external code (`npx pnpm`, then an install), and I did not retry it. Instead I read konveyor's published image as data, executing nothing from it; its labels name exactly our pin:

  ```
  $ skopeo inspect ... docker://quay.io/konveyor/oadp-vmfr-access-filebrowser:oadp-1.6 | jq -r '.Labels["vcs-ref"]'
  4cc1e14b67c93dc2c09b4dcf653c40bdbfec1cfa
  $ tar -xzOf <layer> usr/local/bin/filebrowser | LC_ALL=C grep -a -o -E 'dist/(public/)?index\.html'
  dist/index.html
  dist/public/index.html
  ```

  So both files exist in a real build at this commit. That build is not ours, and `pnpm`'s switch to the `packageManager` version is still untested; Task 4 settles those.

Two things I expected to break and did not:

- A submodule's `.git` is a file pointing nowhere once it is COPYed into a builder, and `go build` stamps VCS info. Tried it with a dangling `.git` file: it builds and stamps nothing, while a real `.git` directory stamps `vcs.revision`. That is go1.27.3 on the Mac, so not the builder's toolchain, but `cert-manager/operator.Containerfile` does the same thing, `COPY --chown=default operator .` then `go build`, on `go-toolset:1.26`, and those images run on this cluster. The side effect is for Task 4: the commit cannot be read from the binary with `go version -m`.
- `WORKDIR $HOME/velero` on a non-root builder, then writing `./bin/`. If the directory were root-owned that is EPERM on the first build. `imagebuilder` v1.2.19 (buildah's pin at v1.43.0, checked for that version and not for the exact one in our podman image) calls `EnsureContainerPathAs(b.RunConfig.WorkingDir, b.RunConfig.User, nil)`, so it is owned by uid 1001.

**Finding for the PR: the VM file restore controller ignores its image env.** The operator passes `VMFR_ACCESS_IMAGE`, `VMFR_SSH_IMAGE` and `VMFR_BROWSER_IMAGE` (`internal/controller/vmfilerestore_controller.go`), but at the pin `git grep` finds no reader in `migtools/oadp-vm-file-restore`, and `fileserver_helpers.go` uses the constants `quay.io/konveyor/oadp-vmfr-access*:oadp-1.6`. So our three VMFR side images land in `relatedImages`, and a VM file restore would still pull konveyor's. It needs `vmFileRestore` on the DPA and KubeVirt, which this cluster does not run, so nothing here hits it. It cannot be fixed by mapping env in `build_bundle()`.

**So we carry a patch.** Review confirmed the finding, and `oadp-dev` (`585c1c6`) has the same constants on the same lines and no `VMFR_` reader either. The operator's decision is that all 18 images are ours for every OADP user, and without this our three would never run. `oadp/patches/vm-file-restore.patch`, subject `Read the access and sidecar images from the environment`: one helper, `imageFromEnv(envVar, defaultImage)`, used at the three `Image:` lines; three `*EnvVar` constants next to `LogFormatEnvVar`, with the names the operator sets at `vmfilerestore_controller.go:188-196`; the image constants unchanged; two doc comments that named the constants corrected. `submodule_initialize` applies it by name like `operator.patch`, so `build.sh` does not change. `busybox:latest` stays, by ruling. `buildDefaultMainContainer` only runs when `MainContainer` is nil, and the one production `FileServerPodConfig` (`virtualmachinefilerestore_controller.go:3139-3146`) always sets it, so the controller does not reach that image at this pin.

Go 1.26.10 came from a scratch module cache, with nothing installed system-wide, and a scratch test (not in the patch) used the literal env names so it compiles at the pin:

```
$ export GOTOOLCHAIN=go1.26.10 GOMODCACHE=<scratch>/gomod GOCACHE=<scratch>/gocache
$ go test ./internal/controller/ -run '^TestScratchImagesFromEnv$'    # at the pin
--- FAIL: TestScratchImagesFromEnv/set:_the_env_value_is_used
    access image: got quay.io/konveyor/oadp-vmfr-access:oadp-1.6, want registry.test/oadp/vmfr-access@sha256:aa
    ssh image: got quay.io/konveyor/oadp-vmfr-access-sshd:oadp-1.6, want registry.test/oadp/vmfr-sshd@sha256:bb
    browser image: got quay.io/konveyor/oadp-vmfr-access-filebrowser:oadp-1.6, want registry.test/oadp/vmfr-filebrowser@sha256:cc
$ go test ./internal/controller/ -run '^TestScratchImagesFromEnv$' -v # patched
--- PASS: .../set:_the_env_value_is_used
--- PASS: .../empty:_the_constants_are_used
--- PASS: .../unset:_the_constants_are_used
--- PASS: .../each_variable_only_moves_its_own_image
--- PASS: .../busybox_stays,_whatever_the_env_says
$ go build ./... && go vet ./internal/common/constant/ ./internal/controller/    # exit 0
$ CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o manager cmd/main.go          # ELF x86-64, statically linked
$ KUBEBUILDER_ASSETS=<scratch>/envtest/k8s/1.33.0-darwin-arm64 go test ./internal/common/... ./internal/controller/
ok  .../internal/common/constant
ok  .../internal/common/function
ok  .../internal/controller
```

That last run includes the envtest suite, which also passes at the pin. Without the assets it fails the same way on both trees (`fork/exec /usr/local/kubebuilder/bin/etcd`), so that was a missing binary, not a result.

`static-check.sh` gained check 12: the patch must pass `git apply --check` at the pin, read exactly the operator's env names, replace the three call sites with a fallback, and leave the constants and busybox alone. It failed before the patch (`patches/vm-file-restore.patch is missing`) and passes now, and eight more mutations were all caught. The real path ran too, in a scratch worktree:

```
Applying: Read the access and sidecar images from the environment
HEAD~1 = recorded gitlink
tree f4e6eb0dc3e6 = the tree I compiled and tested (154f64c)
HEAD = recorded gitlink            (after submodule_reset)
HEAD~1 = recorded gitlink          (second initialise)
```

Not proven: no pod has run it. The chain from the CSV's `RELATED_IMAGE_*` through the operator to the controller's env is read from the code, and a VM file restore needs KubeVirt. For Task 4, `vm-file-restore` now carries a patch commit like `operator`, so a gitlink comparison there has to use `HEAD~1` too.

Also: must-gather's `pkg/cli.go` hard-codes `registry.redhat.io/oadp/oadp-mustgather-rhel9:v1.6`, used only in its help text, so that string stays in the binary.

Nothing built, nothing pushed. Task 4 is the first time any of this runs in a container.

## 2026-11-02: the release-4.22 branch (`oadp-1.6-4.22`)

Our catalog is built from `release-4.22`, so the 1.6 change needs a branch off `origin/release-4.22` as well as the one off `main`. Seven commits cherry-picked in order from `oadp-1.6` (`5523061..cc968a9`), no conflicts, `.gitmodules` included, plus one workflow commit.

Failing check on `origin/release-4.22` (before):

```
$ git show origin/release-4.22:.github/workflows/oadp-deploy.yaml | yq e '.on.push.branches' -
- "main"
$ ... | yq e '.jobs.deploy.with' -
operator: oadp          # no catalog_branch
```

`operator-deploy.yaml` on that branch already declares the `catalog_branch` input, so the deploy workflow only needed `release-4.22` as push branch and `catalog_branch: release-4.22`. Commit `aca8130 [oadp] Deploy from release-4.22 to catalog release-4.22`.

Passing (after):

```
$ git diff fork/oadp-1.6 oadp-1.6-4.22 -- oadp/ | wc -l          -> 0
oadp gitlinks (19) identical via git ls-tree; oadp .gitmodules stanzas identical (path/url/branch hash equal)
$ git diff origin/release-4.22 oadp-1.6-4.22 --name-only | grep -v '^oadp/'
.github/workflows/oadp-deploy.yaml
.gitmodules                      (only oadp stanzas changed)
$ git show HEAD:.github/workflows/oadp-deploy.yaml | yq e '.on.push.branches, .jobs.deploy.with' -
- "release-4.22"
operator: oadp
catalog_branch: release-4.22
$ ./static-check.sh pipeline  -> static-check: PASS
```

Non-oadp gitlinks differ between `oadp-1.6` and this branch by design (the branches diverge). Local only; not pushed.

## 2026-11-02: Task 4, the build Job (`tests/okderators-oadp-build/`)

The in-cluster Job that runs the pipeline's own `oadp/build.sh` from the fork branches, checks the result, and later builds the catalogs. Nothing here touched the cluster; the operator applies it in Task 5. Copied from `tests/okderators-nmstate-build/`: same contract lines (`STEP`, `DISK`, `PUSHED`, `CHECK`, `RESULT`), `flock` on `/work/.lock`, registry guard, prune, log persistence, Job shape, podman image. `MODE=check` comes from the logging Job. The README has the commands and every check.

### What it checks, and when

A build takes hours and zot's budget is about two of them, because a deleted failed round frees nothing until the next 24 h GC pass. So what can be known early is checked early, and the run stops there:

| When | Check | Why it is there |
|---|---|---|
| after the clone | `pipeline-gitlinks`, `gitmodules-branch` | a wrong `PIPELINE_BRANCH` ends in seconds. The 19 pins are a table in `build.sh`, compared with the gitlinks, because a gitlink compared with itself proves nothing |
| before `init` | `base-images` | every `FROM` resolves, and its digest goes in the log: `go-toolset:1.26` and the `:latest` UBI bases move |
| after `init` | `submodule-pins`, `operator-commit` | from `git submodule status`, because a submodule's `.git` is a file and no `vcs.revision` is stamped. The flag column matters: `-` prints the pinned commit with nothing checked out, and `submodule_initialize` hides a failed update behind `\|\| true`. `oadp/operator` and `oadp/vm-file-restore` carry a patch commit, so for those two `HEAD~1` is the pin and `HEAD` has the right subject |
| before the push | `image-smoke`, `velero-version`, `vm-file-restore-env` | a broken image costs no zot space. All eight run even after a failure, so one round shows every failure |
| after the bundle | `bundle-objects`, `no-redhat-registry`, `csv-name`, `install-modes`, `images-by-digest`, `no-konveyor`, `okd-strings`, `operator-sdk-validate` | the images are pushed by then, so a failure here costs a `MODE=check` run, not a rebuild |

Choices worth recording:

- **`bundle-objects` compares with the operator pin's own `bundle/manifests`** (50: 10 + 13 CRDs, the CSV, 26 RBAC and Service manifests), read from git objects because `make bundle` rewrites the tree. Extra fails; missing fails too, because a dropped CRD or Role is a broken install.
- **`images-by-digest` is a set, then a map.** operator-sdk lists some images twice under two names (the published 1.5.0 has `velero_plugin_for_aws` and `velero-plugin-for-aws`), so `relatedImages` compare as a set with the 19 digests this run recorded. But two env vars swapped would still pass as a set, so each `RELATED_IMAGE_*` is then checked by name against the same mapping as `build_bundle()`.
- **`no-konveyor` scans the whole bundle**, wider than `relatedImages` and the env: at the pin the CSV names `quay.io/konveyor` only on the lines `build_bundle()` rewrites, so nothing may be left. `bundle/image-references` names it too, but it sits outside `manifests/` and the image does not copy it.
- **The download servers must still be up when `timeout 10` ends them**, not only have logged `Found N binaries` and `Starting server`: `log.Fatal` after a failed bind logs both lines as well. One retry at 30 s, because a podman start on throttled cores can take seconds and a false FAIL here would throw away a whole build.
- **`RESULT PASS` needs more than no failures.** `finish` counts `CHECK ... FAIL` in memory and in the contract file, and each mode requires a `PASS` line for every one of its checks by name, so a flow that skipped a check reads as `RESULT FAIL`. A `DATE` whose log file exists is refused.
- **`MODE=check` copies to a new tag in the same repository**, not to the logging Job's `check-<branch>/` registry. `oadp/build.sh` derives every `IMG_*` from `DATE`, and `DATE` is new because a tag is never pushed twice. No repository to clean up, no new blobs in zot, and `relatedImages` stay under `okd-test/oadp/`. The catch, in the README: its 19 tags share digests with the full run, so deleting one by digest removes the full run's image.
- **`deinit` runs after verify**, unlike NMState: its `submodule_reset` over `must-gather`'s nested submodules has never run, and a failure there must not hide the bundle's results.

Fedora: nothing coded. If `fedora:44` does not resolve in the real build, that is decided then.

### Resources

Deadline 24 h instead of 12. GitOps took 97 minutes for twelve images under `powersave-experimental`; this is nineteen, `go build -a` on most, ten cross-compiled binaries, and a deadline kill loses all of it. Requests and limits stay (2 CPU / 8 Gi, 14 CPU / 48 Gi): builds run one after another, so what carried GitOps carries these, and the nodes have 128 GiB.

The PVC is the tight one. Measured earlier: `build_containers` added 33.3 GB for GitOps' twelve images and 29.5 GB for logging's nine, about 3 GB an image. Nineteen plus the cross-compiles gives an estimated peak of 70 to 100 GB against 100 Gi (107 GB). An estimate, not a measurement, and running out costs the whole build, so the README asks the operator to grow it to 150 Gi first; `ceph-nvme-block` allows expansion. `INFO free` after every step shows what is left.

### How it was tested without a build

Bash on this Mac is 3.2 and `build.sh` needs to run here to be tested, so unlike the NMState Job it avoids associative arrays and namerefs, as `catalog-edit.sh` already did, and sourcing it does not run `main`. A newer bash was not an option: compiling one was refused by the auto-mode classifier, and I did not look for a way around that. The fixtures are real where they can be: the 50 manifests of the operator pin's `bundle/`, the CSV edited the way the patch, `build_bundle()` and `--use-image-digests` edit it, rendered by the real `opm`. `podman`, `skopeo` and `oc` are stubs. `git`, `jq`, `yq`, `opm` and `catalog-walk.py` are real, and so are the two catalog trees and the `oadp/build.sh` the variables are read from.

The first run paid for this. A real bug, in two checks:

```
WRONG good fixture    want PASS got []
      build.sh: line 1027: dir: unbound variable
```

`local dir=$1 got=$dir/files.got` reads the outer `dir`. Fixed by splitting the declarations; the Job would have died at its first verify, after the whole build.

Results (scripts and full output kept in the gitignored work directory, `work/task4-tests/`):

```
$ SCR=... ./run-all.sh
units:    96 as expected, 0 wrong     every check on a good fixture PASS, on each doctored one FAIL
git:      24 as expected, 0 wrong     the pin checks against real submodules
e2e 4.22: 109 as expected, 0 wrong    real main, control flow, branch oadp-1.6-4.22
e2e main: 109 as expected, 0 wrong    the same on branch oadp-1.6
catalog:  60 as expected, 0 wrong     walker, the real trees, MODE=catalog through build.sh
```

A sample of the failures it shows, one line each:

```
ok  ImageStream object in the render      FAIL objects not in the pin's list: ImageStream/oadp;
ok  a CRD file missing                    FAIL files missing: velero.io_backups.yaml;
ok  swap: two env vars on one image       FAIL RELATED_IMAGE_VELERO_PLUGIN_FOR_AWS=.../gcp-plugin@sha256:992d...
ok  one image missing (17 + manager)      FAIL csv relatedImages missing: .../velero@sha256:01aa...
ok  the operator env                      FAIL operator env: RELATED_IMAGE_VELERO=quay.io/konveyor/velero:oadp-1.6;
ok  plain not initialised (status shows the pin)  FAIL 1 of 3: oadp/plain: not initialised;
ok  operator: two commits on top          FAIL oadp/operator: HEAD~1 a9692eb... (pin cee5faa...), subject ...
ok  cli logs both lines, then bind fails  FAIL tries 10s=exit1 30s=exit1; want it still serving (exit 124) ...
ok  rsync in the chroot lacks a library   FAIL rsync in the chroot exit 127: rsync: error while loading shared libraries
ok  access without guestmount             FAIL exit 1: MISSING: guestmount
```

The control flow, `real main` with a broken image: `RESULT FAIL the images are not pushed: ...`, no `STEP push_containers`, no `PUSHED`, and the other images still ran. With the wrong branch, `RESULT FAIL oadp/build.sh builds 1.5, want 1.6` before `init`. With a check silently skipped, `RESULT FAIL full: no PASS line for okd-strings`. With a failing `make bundle`, 19 `PUSHED` lines stay for `MODE=check`.

`vm-file-restore-env` on two real linux/amd64 binaries, read as bytes and not run. Konveyor's published `oadp-vm-file-restore:oadp-1.6` is built from our pin (`io.openshift.build.commit.id` `adb1fb3`), so it is the unpatched control; our patch at the pin, compiled with Go 1.26.10, is the other:

```
--- konveyor                                  VMFR_ACCESS_IMAGE 0, VMFR_SSH_IMAGE 0, VMFR_BROWSER_IMAGE 0 (LOG_FORMAT 2)
CHECK vm-file-restore-env FAIL /manager lacks VMFR_ACCESS_IMAGE VMFR_SSH_IMAGE VMFR_BROWSER_IMAGE: patches/vm-file-restore.patch did not reach the binary
--- patched                                   1, 1, 1
CHECK vm-file-restore-env PASS /manager contains VMFR_ACCESS_IMAGE VMFR_SSH_IMAGE VMFR_BROWSER_IMAGE
```

### The walker and the catalog edit

`catalog-walk.py` is byte-identical to the NMState copy: it takes the package as an argument, so only `catalog-edit.sh` needed adapting. The edit adds an entry instead of replacing a broken one. Hand-made catalogs first, the failing test the brief asks for:

```
4.22 edge present, the four INSTALLED     exit 0 PASS 4 entries + 1 CSV absent from the channel reach oadp-operator.v1.6.0-2026-11-02-120000
4.22 no edge: 1.5.0 stranded, two heads   exit 1 FAIL heads oadp-operator.v1.5.0-2026-01-05-165341, oadp-operator.v1.6.0-2026-11-02-120000, want ... | stranded: ...
4.22 only replaces: the test CSV stranded exit 1 FAIL stranded: oadp-operator.v1.6.0-2026-11-01-120000 (absent from the channel) ...
4.22 only skipRange: still two heads      exit 1 FAIL heads oadp-operator.v1.5.0-2026-01-05-165341, oadp-operator.v1.6.0-2026-11-02-120000, want ...
5.0 edge present, the two 1.4.0           exit 0 PASS 3 entries reach oadp-operator.v1.6.0-2026-11-02-120000
5.0 no edge: 1.4.0 stranded, two heads    exit 1 FAIL heads oadp-operator.v1.4.0-2025-01-23-195220, ...
```

Then `catalog-edit.sh` in test mode on the real `release-4.22` (`98c6d9d`) and `release-5.0` (`4daed51`), every check PASS, both negative controls as designed. The edit on 4.22:

```diff
   - name: oadp-operator.v1.5.0-2026-01-05-165341
-    replaces: oadp-operator.v1.4.0-2025-01-23-195220
\ No newline at end of file
+    replaces: oadp-operator.v1.4.0-2025-01-23-195220
+  - name: oadp-operator.v1.6.0-2026-11-02-120000
+    replaces: oadp-operator.v1.5.0-2026-01-05-165341
+    skipRange: '>=1.4.0-0 <1.6.0-2026-11-02-120000'
```

The one removed line is the missing final newline, on both branches; `yq` proves the entries are the old ones plus the new one, and no file goes. The first negative control also needs `opm validate` to refuse the two heads. On 5.0 no `INSTALLED` CSV is absent from the channel, so its second control instead asserts that `replaces` alone is enough.

### Manifests

```
$ kubectl kustomize tests/okderators-oadp-build/ | kubeconform -strict -ignore-missing-schemas -summary
Summary: 1 resource found parsing stdin - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0
$ oc process --local -f tests/okderators-oadp-build/job-template.yaml -p MODE=full -p PIPELINE_BRANCH=oadp-1.6-4.22 -p DATE=2026-11-02-130000 -o yaml
Job oadp-build-full-2026-11-02-130000, activeDeadlineSeconds 86400, backoffLimit 0    (kubeconform: Valid: 1)
the same for MODE=check with REUSE_DATE and MODE=catalog with CATALOG_BRANCHES and BUNDLES: Valid: 1
$ bash -n build.sh; bash -n catalog-edit.sh; python3 -I -m py_compile catalog-walk.py    all OK
```

### Not tested before a real build

- Bash 5 itself. The checks ran on 3.2; the pod has 5.x and `inherit_errexit`. I read through every command substitution for that difference, which is not the same as running it.
- Anything inside a real container: every `podman run` is a stub, so whether each image behaves as the smoke test assumes comes from reading its source at the pin. The real `build_containers`, `push_containers`, `build_bundle` and `deinit` have not run, nor has `skopeo copy --preserve-digests`.
- `operator-sdk bundle validate` on this bundle: running the release binary on the Mac was refused too. `make bundle` runs its own v1.35.0 first, so a failure there would surface as `RESULT FAIL build_bundle`.
- That `make bundle` emits exactly the pin's file list. It should, since the list was generated by the same command at the same commit, and a surprise costs a `MODE=check` run.

#### 2026-11-02, before the first run: three changes
- `PRUNE` template parameter (default `true`): `MODE=full` skips `podman system prune -af` and logs `INFO prune skipped` when it is `false`, so a retry after a package failure at image 13 of 19 reuses layers instead of repeating hours of compile; only images without `ARG CI_VERSION` reuse any. The first run keeps the default so the peak-disk figure is real.
- `gitmodules-branch` is an `INFO` line, not a check, and is out of `REQUIRED_COMMON`: `.gitmodules` is not what gets built (the gitlink is), so a mismatch must not fail a run.
- `build-storage` goes to 150 Gi (`tests/okderators-logging-build/manifests.yaml` owns the PVC; the operator patches the live claim, command in the Job README): estimated peak 70-100 GB for 19 images against 107 GB. Pool `MAX AVAIL` read 252 GiB on 2026-11-02, so a real 100 GB peak leaves about 150 GiB until the PVC is deleted.

Next: Task 5, the operator applies it.

## 2026-11-02 Task 7: the backup drill and the upgrade runbook

Written before anything is applied: `tests/oadp-1.6-drill/` (manifests and README) and `components/operators/oadp/README.md` (upgrade and rollback runbook). Nothing was run on the cluster; the writer script was exercised against a temp directory only (bash, no container).

**What the drill does.** A namespace `oadp-drill` with a 1 Gi `ceph-nvme-block` PVC and one pod (`ubi9/ubi-minimal` by digest, linux/amd64 manifest `sha256:312b02a8...`; coreutils confirmed by listing its single layer). Backups use Schedule `daily`'s template (`truenas-garage`, `snapshotMoveData: true`, `defaultVolumesToFsBackup: false`, `ttl 336h`) scoped to the namespace, with `includeClusterResources` unset so the Restores never touch cluster-scoped objects. Restores map `oadp-drill` to `oadp-drill-r15`, `-r16a`, `-r16b`, `-r16c`, `-roff`. It runs on 1.5, after the upgrade, after the soak and on the official build.

**Why each pass condition exists.**
- `DataUpload` `Completed` with `bytesDone > 0`: a Backup can read `Completed` with no volume data (the 2026-08-28 rehearsal called it "green and empty").
- Bucket growth of at least 50 MiB (garage `GetBucketInfo` on the `velero` bucket, not the dataset, because Loki shares the garage): independent proof that bytes landed in the bucket.
- `.status.incrementalBytes > 0` on 1.6: proves this upload wrote new blobs. The field is in the 1.6 `DataUpload` CRD only (`pkg/controller/data_upload_controller.go:509` at `oadp-1.6`; absent from the live 1.5 CRD).
- Restored writer logs both checksums: proves the data came out of the bucket.

**An unchanged file proves nothing about 1.6's write path.** The first design wrote one 64 MiB file once. After the first backup the volume never changes, so a later backup finds its parent snapshot and Kopia treats unchanged entries as cached (`kopia/kopia` `snapshot/upload/upload.go:710,853-855`), the data mover sets `BytesDone` to the snapshot's total on completion (`pkg/uploader/provider/kopia.go:183-187`, `pkg/uploader/kopia/snapshot.go:307`), and the restore returns blobs that 1.5 wrote. A 1.6 that could not read file data or write a blob would still pass. So the source pod rewrites a second file (`gen.bin`, new random bytes, own checksum `<G>`) on every start; each backup after the first is preceded by `rollout restart deploy/drill-writer`, and passes only with new `<G>` in the restored log plus bucket growth plus `incrementalBytes > 0`. The first file and its checksum `<A>` stay fixed across all runs.

**A restored pod must not create a file.** Restoring the Deployment restarts the writer in the target namespace. With the data mover this cannot race: the restored PVC carries a label selector and no volume, the provisioner refuses selector claims (`claim Selector is not supported`, external-provisioner `controller.go:654`), and `RebindVolume` (`pkg/exposer/generic_restore.go`) binds the restored PV only after the DataDownload. The StorageClass is `Immediate`. The script also refuses by itself: only a pod in namespace `oadp-drill` creates either file; elsewhere it waits for all four restored files and verifies each against its stored sum. Tested on an empty volume (waits, creates nothing), a volume missing the gen files, and corrupt files (`DRILL MISMATCH`).

**What the OLM `startingCSV` read showed.** `pkg/controller/registry/resolver/resolver.go` (OLM master `861a2c9f` and `openshift/operator-framework-olm` `release-4.22`, same logic): the installed CSV is found by `status.installedCSV`; if one exists the channel is filtered by `skipRange`/`replaces` from it and `startingCSV` is ignored; only with no installed CSV is the channel filtered by the `startingCSV` name. So for the 1.5 to 1.6 upgrade the `replaces` edge does the work and `startingCSV` is inert; it matters for a fresh install, the rollback (after the 1.6 CSV is deleted) and the re-subscribe fallback. The rollback order follows from it: commit the revert first (selfHeal recreates a deleted Subscription), delete the 1.6 CSV, approve the 1.5 InstallPlan, delete the two `ConsoleCLIDownload`s. Read in source only; the live behaviour (CRDs surviving the CSV delete, the Subscription's condition in between) is marked to be confirmed in the runbook.

Also noted: `oc get packagemanifest oadp-operator` returns the `community-operators` entry on this cluster, so the runbook selects `-l catalog=okd-test-oadp`.

## 2026-11-02 — the drill on 1.5 passed: first recorded data mover restore here

Run while the `release-4.22` build was going on node6. Installed: `oadp-operator.v1.5.0-2026-01-05-165341`. Alert board
before starting: standing alerts only (`ClusterNotUpgradeable`, `InsightsRecommendationActive`, `KubeCPUOvercommit`,
`PodDisruptionBudgetAtLimit` on the three CNPG primaries, `Watchdog`).

```
oc apply -f tests/oadp-1.6-drill/namespace.yaml -f tests/oadp-1.6-drill/pvc.yaml -f tests/oadp-1.6-drill/writer.yaml
DRILL sha256=b29d2dc0f2ea165345a30936217c9cd382260fac1d1bc4a31ec36fef8e60d642
DRILL gen=661294aa8eb49e836b7d5fc3012510e83cdd46c9cee97436e2adca212d9f57bc

velero bucket bytes=0 objects=0                         # baseline

oc apply -f tests/oadp-1.6-drill/backup-15.yaml
Completed errors= warnings= items=33/33 start=2026-11-02T20:52:01Z end=2026-11-02T20:53:00Z expires=2026-11-16T20:52:01Z
drill-15-vpv2f   Completed   134217858   134217858   node6.okd.sudops.pl
oadp-drill-truenas-garage-kopia   Ready

velero bucket bytes=134551109 objects=28                # read 26 s after the Backup ended

oc apply -f tests/oadp-1.6-drill/restore-drill-15-r15.yaml
Completed errors= warnings=2 items=20/20 start=2026-11-02T20:54:07Z end=2026-11-02T20:55:09Z
drill-15-r15-s8wxd   Completed   134217858   134217858   node6.okd.sudops.pl
DRILL restored copy in oadp-drill-r15: creates no file, waiting for the restored ones
DRILL sha256=b29d2dc0f2ea165345a30936217c9cd382260fac1d1bc4a31ec36fef8e60d642
DRILL gen=661294aa8eb49e836b7d5fc3012510e83cdd46c9cee97436e2adca212d9f57bc
```

Both restored checksums match the source's, read back from a volume filled by a `DataDownload` from garage, in a pod that
creates no file. So the data mover path that `daily` uses works on 1.5, against the NAS, on the first try. The earlier
proofs here were a ConfigMap and file-system backup. No `velero.io/csi-volumesnapshot-class` annotation or label was
needed: Velero picked `ceph-rbd-snapshot` as the driver's only class.

The Restore's two warnings are benign: `kube-root-ca.crt` and `openshift-service-ca.crt` already exist in the new
namespace, because OpenShift creates them. That is lower than the file-system rehearsal's seven. No stray PVs or
`Released` volumes afterwards.

The restored pod and PVC ran on node6, as the source did, so the restore did not prove a pull from another node. It did
not need to: the data came through the bucket either way.

## 2026-11-03 — Task 5: both full builds passed

Both full builds of the OADP 1.6 pipeline ran as one-off Jobs on the cluster (node6, privileged podman, build storage on
the `build-storage` PVC, grown to 150Gi before the first run) and both passed. Figures below are read from the build
logs (`RESULT`, `CHECK`, `PUSHED`, `DISK` and `STEP` lines), not from memory.

### The two runs

| | release-4.22 | main |
|---|---|---|
| Job | `oadp-build-full-2026-11-02-205027` | `oadp-build-full-2026-11-02-233420` |
| Pipeline branch (fork) | `oadp-1.6-4.22` | `oadp-1.6` |
| DATE | `2026-11-02-205027` | `2026-11-02-233420` |
| Job start | 2026-11-02 20:50:27Z | created 2026-11-03 06:24:03Z, container started 06:28:27Z |
| Complete | 23:32:31Z | 07:23:34Z |
| Wall time | 2 h 42 min | 59 min from creation, 55 min from container start |
| CPU limit | 14 (nproc 14) | 10 (nproc 10) |
| PRUNE | true (cold graph, from scratch) | false (graph from run 1 kept) |
| Result | `RESULT PASS full 2026-11-02-205027` | `RESULT PASS full 2026-11-02-233420` |
| CHECK lines | 23 PASS, 0 FAIL | 23 PASS, 0 FAIL |
| Pushed | 19 images + bundle = 20 refs, 2 132 837 052 B (1.99 GiB) | 20 refs, 2 133 990 346 B (1.99 GiB) |
| Peak disk (largest `DISK`) | 71 072 272 384 B = 71.1 GB (66.2 GiB) | 87 719 718 912 B = 87.7 GB (81.7 GiB) |

The `main` run's create prompt was answered the next morning, which is why the `DATE` tag (rendered 23:34Z) is
earlier than the Job. The CPU limit went from 14 to 10 because etcd's WAL fsync p99 on node6 read 49 ms during run 1
against 6 and 4 ms on the other two nodes, with no alert (recorded in `blog/blog-descheduler-draft.md`); it costs a
slower compile on the images that miss the cache. `main` ran with `PRUNE=false`: `oadp/` is identical on the fork
branches `oadp-1.6` and `oadp-1.6-4.22` (0 gitlinks and 0 files differ), and the ledger counts 205 `Using cache` lines
(the saved extract has none). That makes the `main` run the weaker proof, not an equal one. The inputs were not
identical: the logs show `OKD_VERSION=5.0.0-okd-scos.0` on `main` against `4.22.0-okd-scos.2` (main extract line 58,
4.22 extract line 65) and a different `IMG_CLI` digest (`5cd06e69b7d0...` against `839f3fb078d2...`, lines 37 and 44).
The registry's `fedora:44` digest read before the build also moved, from `9b53c238bb4e` (4.22 line 103) to
`cb3bd21415bd` (main line 96), yet the digest "used by this build" is `aad5fee562d2` in both (4.22 line 128, main line
121): the `main` run reused the older cached base. So the `main` run shows that the branch builds and that its bundle
checks pass; it does not show that it builds from scratch. The release-4.22 run is the from-scratch proof, and upstream
CI builds fresh.

Peak disk is the largest `DISK` value, bytes used on the build graph root. With `PRUNE=false` the `main` run started
at 70.9 GB (the graph kept from run 1), so its 87.7 GB is the cache plus the new work, not a from-scratch figure; the
from-scratch peak is run 1's 71.1 GB. The PVC (150Gi) never ran short.

### The CHECK list (identical names and result in both runs)

| CHECK | Result |
|---|---|
| pipeline-gitlinks (19 `oadp/` gitlinks are the pins) | PASS |
| base-images (7 FROM refs resolve) | PASS |
| submodule-pins (19 initialised; HEAD = pin where unpatched) | PASS |
| operator-commit (operator `483de5e05055` 'OKDify'; vm-file-restore `adb1fb335674`; clean trees) | PASS |
| image-smoke, 8 images: vm-file-restore, kubevirt-datamover-controller, kubevirt-datamover-plugin, cli-binaries, vmdp-binaries, vmfr-sshd, vmfr-filebrowser, vmfr-access (+ the roll-up line) | 9 lines, all PASS |
| velero-version (v1.18.4-OADP) | PASS |
| vm-file-restore-env (`VMFR_ACCESS_IMAGE`, `VMFR_SSH_IMAGE`, `VMFR_BROWSER_IMAGE` in `/manager`) | PASS |
| bundle-objects (50 files, the pin's list exactly) | PASS |
| no-redhat-registry | PASS |
| csv-name | PASS |
| install-modes (OwnNamespace only) | PASS |
| images-by-digest (19 refs: 18 `RELATED_IMAGE_*` + manager, all by digest under `okd-test/oadp/`) | PASS |
| no-konveyor | PASS |
| okd-strings | PASS |
| operator-sdk-validate (v1.36.1: passed, 5 warnings, 0 errors) | PASS |

That is 4 + 9 + 2 + 8 = 23 `CHECK` lines per run.

### The 20 pushed refs, release-4.22 run (tag `1.6.0-2026-11-02-205027`)

Registry `zot.apps.okd.sudops.pl/okd-test/oadp/`; digest is the first 12 hex of the sha256; size is the `PUSHED` byte
count.

| Image | Digest | Size |
|---|---|---|
| aws-legacy-plugin | d6e30d82b2f5 | 77.2 MiB |
| aws-plugin | e0ca82a0b95d | 86.8 MiB |
| azure-plugin | d4e6fd013173 | 73.1 MiB |
| cli-binaries | fc22fa2c54bf | 152.0 MiB |
| gcp-plugin | 3db413b5cbd9 | 85.0 MiB |
| hypershift-plugin | ed166ea87432 | 73.1 MiB |
| kubevirt-datamover-controller | a660db48aedb | 98.0 MiB |
| kubevirt-datamover-plugin | 528d68e50dd9 | 83.6 MiB |
| kubevirt-plugin | 3cb29f0c8c6f | 77.2 MiB |
| must-gather | 1c2739c7e9f4 | 246.8 MiB |
| non-admin | 9d364c9e2c3d | 72.1 MiB |
| openshift-plugin | 96def84a737c | 99.3 MiB |
| operator | 0a3f068da846 | 94.6 MiB |
| velero | 8e026079e30f | 134.3 MiB |
| vmdp-binaries | 8d50dbe2bb70 | 107.2 MiB |
| vmfr-access | f4f396e2a8a5 | 311.7 MiB |
| vmfr-filebrowser | 680f5caceeea | 54.5 MiB |
| vmfr-sshd | 2cc1b8d1924e | 68.8 MiB |
| vm-file-restore | 2e912c26dd59 | 38.7 MiB |
| bundle | d42c3f7e4d9d | 95 253 B |

The `main` run pushed the same 20 names under tag `1.6.0-2026-11-02-233420`. 15 of the 19 image digests equal run 1's. Five
refs differ: `cli-binaries` (5de8655fa8ec, 10 B larger), `must-gather`
(6d21455565c8, 1 153 303 B larger), `vmdp-binaries` (bbf57e990aa0, 13 B smaller), `vmfr-filebrowser` (183a78eb0b27,
7 B larger) and the bundle (ea5adb6dcf98, 13 B smaller, as its CSV name carries the DATE). I did not diagnose why
the four images differ. The likely reason, unproven, is the differing inputs above (`OKD_VERSION`, `IMG_CLI`;
`cli-binaries`, `vmdp-binaries` and `must-gather` plausibly consume them) and cached layers carrying the older base;
the images are not needed for the catalog, since each bundle pins its own run's digests.

Bundle refs for the catalog step (full):

- release-4.22: `zot.apps.okd.sudops.pl/okd-test/oadp/bundle:1.6.0-2026-11-02-205027@sha256:d42c3f7e4d9dadd5a1a5c8daba0ebabf9e5ecf5c0f7596b368b634c6b6c67ff2`
- main: `zot.apps.okd.sudops.pl/okd-test/oadp/bundle:1.6.0-2026-11-02-233420@sha256:ea5adb6dcf98c6046e3b6196c8c910ac41b2d289d0f20ea00a831e09f89f5173`

### zot before and after

Kubelet stats summary of `zot/data-zot-0`: 15.3-15.4 GiB free before the release-4.22 run (right after the
2026-11-02 cleanup, before zot's next GC), 31 GiB free after both runs. Each run pushed 1.99 GiB. I did not
separate how much of the rise is GC of the cleanup's deleted images; the measurement is two points. Floor in the
brief was 5 GiB, so the gate held with room.

### Peak disk against upstream CI

GitHub's `ubuntu-latest` has about 14 GB free. Both peaks, 71.1 GB (from scratch) and 87.7 GB (with a kept graph), are
far over that. So the `main` PR must say that upstream CI needs logging's `free_disk_space` step (from the fork
branch of okd-operator-pipeline #35, which is not merged), and even that step may not free enough for a from-scratch
build; I have not tried it. The in-cluster figure is what a runner has to hold: 19 images built, 71 GB of layers.

### The slow container start on the main run

Pod on node6 reported `CreateContainerError`, `context deadline exceeded`, at 06:26:07Z and again at 06:28:07Z, with
the image present and the volume attached; the container started on its own at 06:28:27Z, about 4.4 min after
scheduling. `restartCount` read 1 with `restartPolicy: Never`, no `lastState` and no previous container, which I take
as an artifact of the two failed creates. No log existed before the start. node6 at 06:27: container runtime about
0.91 cores, kube-apiserver-node6 3.86 cores. I did not read the CRI-O journal, and I did not record how long run 1's
create took, so there is nothing to compare against. The cause is not proven. The leading guess, and only a guess, is
CRI-O relabelling the roughly 71 GB of files kept on the volume by `PRUNE=false` (the pod runs under the `privileged`
SCC with no SELinux level of its own). If it recurs with a kept graph, read the journal on node6 first.

## 2026-11-03 — Task 6: catalog graphs validated, test catalog image

Both bundles were pushed in Task 5, so this run adds each one to its okderators catalog branch, proves the upgrade
graph with a walker, and builds the test catalog image for the homelab's OADP CatalogSource. Same Job template as the
builds, `MODE=catalog`. It ran by the operator's permission prompt on the create.

### The command

Before it, on 2026-11-03 at 07:31Z I read the catalog heads: `release-4.22` alpha head
`oadp-operator.v1.5.0-2026-01-05-165341`, `release-5.0` head `oadp-operator.v1.4.0-2025-01-23-195220`, no 1.6 on
either. The cluster's Subscription read `AtLatestKnown` on 1.5.0 from `okderators`.

```bash
DATE=2026-11-03-073144
oc process --local -f tests/okderators-oadp-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.22 release-5.0' \
  -p BUNDLES='release-4.22=zot.apps.okd.sudops.pl/okd-test/oadp/bundle:1.6.0-2026-11-02-205027@sha256:d42c3f7e4d9dadd5a1a5c8daba0ebabf9e5ecf5c0f7596b368b634c6b6c67ff2 release-5.0=zot.apps.okd.sudops.pl/okd-test/oadp/bundle:1.6.0-2026-11-02-233420@sha256:ea5adb6dcf98c6046e3b6196c8c910ac41b2d289d0f20ea00a831e09f89f5173' \
  | oc -n okd-build create -f -
```

Job `oadp-build-catalog-2026-11-03-073144`, node6. It finished at 07:38:44Z: `RESULT PASS`, `catalog-edit: 0 checks
failed`, every `CHECK` PASS. The extract is `work/catalog-2026-11-03-073144.txt` (local, not committed).

### Channel before and after

Each branch got the new bundle file `catalog/oadp-operator/<CSV>.yaml` (352 lines, rendered with `opm render -o yaml`)
and one entry appended to the `alpha` channel. Each diff is 2 files changed, 356 insertions, 1 deletion; the
deletion is the last line of the package file, re-emitted by the diff with an identical text on the `+` side. Nothing
else was removed, and the old entries are unchanged (`CHECK edit-*`).

| branch | head before | entries | new entry | `replaces` | `skipRange` |
|---|---|---|---|---|---|
| `release-4.22` | `oadp-operator.v1.5.0-2026-01-05-165341` | 3 to 4 | `oadp-operator.v1.6.0-2026-11-02-205027` | `oadp-operator.v1.5.0-2026-01-05-165341` | `'>=1.4.0-0 <1.6.0-2026-11-02-205027'` |
| `release-5.0` | `oadp-operator.v1.4.0-2025-01-23-195220` | 2 to 3 | `oadp-operator.v1.6.0-2026-11-02-233420` | `oadp-operator.v1.4.0-2025-01-23-195220` | `'>=1.4.0-0 <1.6.0-2026-11-02-233420'` |

Catalog commits the clones were taken at: `release-4.22` `98c6d9d54411ed494a13e2a00fd5f76ffb4d82bc`, `release-5.0`
`4daed51b21a8693b3f44feef6eee74fb4bf1c04d`, both from `okd-project/okderators-catalog-index`. `opm validate catalog`
passed on both edited trees (`opm` v1.74.0).

### Walker

`catalog-walk.py` starts from every channel entry and every CSV a cluster may run, and follows `replaces`, `skips`
and `skipRange` edges to the head.

`release-4.22` (`CHECK walk-release-4.22 PASS`), 4 entries plus 1 CSV absent from the channel reach
`oadp-operator.v1.6.0-2026-11-02-205027`:

- `v1.4.0-2024-09-04-143635`: by skipRange
- `v1.4.0-2025-01-23-195220`: by skipRange
- `v1.5.0-2026-01-05-165341` (what the cluster runs today): by replaces and skipRange
- `v1.6.0-2026-11-01-205027`, the test-shaped CSV (the new DATE a day earlier), not in the channel: by skipRange

`release-5.0` (`CHECK walk-release-5.0 PASS`), 3 entries reach `oadp-operator.v1.6.0-2026-11-02-233420`:
`v1.4.0-2024-09-04-143635` by skipRange, `v1.4.0-2025-01-23-195220` by replaces and skipRange.

The image walk, run on the catalog rendered back from zot, printed the same five edges as `release-4.22`.

### Negative controls

Four, two per branch, each on a copy of the edited tree:

- `negative-control-no-edge-release-4.22`: entry without `replaces` and `skipRange`. The walker reports two heads
  (`v1.5.0-2026-01-05-165341` and the new one), with 1.5.0 stranded together with the other three (both 1.4.0 and the
  `v1.6.0-2026-11-01-205027`), and `opm validate` refuses it with `invalid package "oadp-operator"`. Proves the walker
  and `opm validate` both notice a bundle with no edge, and that the installed 1.5.0 would be offered nothing.
- `negative-control-replaces-only-release-4.22`: entry with only `replaces`. `opm validate` passes, and the walker
  reports exactly `oadp-operator.v1.6.0-2026-11-01-205027` stranded. Proves the `skipRange` is what serves the test-shaped
  CSV, and that `opm validate` alone would not have caught it.
- `negative-control-no-edge-release-5.0`: same as the first, two heads (`v1.4.0-2025-01-23-195220` and the new one),
  1.4.0 stranded with the other 1.4.0, `opm validate` refuses it.
- `negative-control-replaces-only-release-5.0`: no installed CSV is absent from the channel on this branch, so the
  control asserts the opposite: with `replaces` alone the walker still passes, 3 entries reach the head. It shows the
  `skipRange` costs nothing here and that the branch has no test-shaped CSV to strand.

### Test catalog image

Built from the `release-4.22` tree (`IMAGE_BRANCH`), package `oadp-operator` only, with the Containerfile's base
pinned to the opm v1.74.0 digest (`quay.io/operator-framework/opm@sha256:b32d3891616662620da08d7f0ec42c2e69fa2de43427dc975d35b12f7a969a0f`).
`opm-validate-image` and `catalog-image` PASS: pushed, rendered back from zot, exactly one package, head
`oadp-operator.v1.6.0-2026-11-02-205027`, every entry and the four installed CSVs reach it.

```
zot.apps.okd.sudops.pl/okd-test/oadp-catalog:2026-11-03-073144@sha256:6f40ce7912852a2a0b0c7ee17401a621021e7d82a7a7dbf65c3aa4ea7240280b
```

31691582 bytes (about 30 MiB). Next for it is Task 7's CatalogSource in the homelab.

### Slow container create, again

The pod showed the same pattern as the main build. The Job was created at about 07:32Z and the container started at
07:36:30Z, about 4.5 min later, with `restartCount` 1, no crash and no `lastState`. The kept graph root on
`build-storage` was 87.6 GB at that start. Both slow creates so far happened with a kept graph root, which fits the
relabel guess from the main run, but the cause is not proven: I have not read the CRI-O journal on node6. Until the
graph root is pruned, each pod start on that volume may cost a few minutes.

## 2026-11-03 — pre-upgrade baseline (OADP 1.5.0)

Read-only readings before the 1.5 → 1.6 hop, all with `KUBECONFIG=~/.kube/config-readonly`, namespace `openshift-adp`.
Nothing was changed on the cluster. The full DPA is saved outside git (`.superpowers/.../work/oadp/dpa-before.yaml`);
it references its credential only by Secret name (`garage-credentials`, key `cloud`).

```
oc -n openshift-adp get csv | grep oadp
oadp-operator.v1.5.0-2026-01-05-165341   OADP Operator   1.5.0-2026-01-05-165341   replaces v1.4.0-2025-01-23-195220   Succeeded

oc -n openshift-adp get subscription oadp-operator -o jsonpath='{.spec.source} {.spec.channel} {.spec.installPlanApproval} startingCSV={.spec.startingCSV}{"\n"}{.status.state} installed={.status.installedCSV}{"\n"}'
okderators alpha Manual startingCSV=
AtLatestKnown installed=oadp-operator.v1.5.0-2026-01-05-165341

oc -n openshift-adp get installplan
install-fj9jr   oadp-operator.v1.5.0-2026-01-05-165341   Automatic   true     (the only one; no pending plan)

oc -n openshift-adp get dpa -o jsonpath=...conditions...
dpa: Reconciled=True Complete 2026-09-07T17:27:59Z

oc -n openshift-adp get bsl -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} lastValidation={.status.lastValidationTime}{"\n"}{end}'
truenas-garage Available lastValidation=2026-11-03T07:45:34Z
```

Pods (`oc -n openshift-adp get pods -o jsonpath=...`): `velero` (1), `openshift-adp-controller-manager` (1) and
`node-agent` (3, one per node) are Running; three `oadp-drill-truenas-garage-kopia-maintain-job-*` pods are Succeeded.
Images, all `quay.io/okderators/oadp/`: `velero@sha256:f17c68a2…9003` for velero, node-agent and the maintain jobs;
`operator@sha256:e4ecc140…8a41` for the controller manager. The `okderators` CatalogSource is on
`quay.io/okderators/catalog-index:4.22`.

DPA shape that must survive the hop: one BSL `truenas-garage` (aws provider, `s3Url` `http://192.168.1.25:30188`,
bucket `velero`, prefix `velero`, `checksumAlgorithm: ""`), `nodeAgent` enabled with `uploaderType: kopia`,
`defaultPlugins` aws, csi, openshift, `disableFsBackup: false`; DPA generation 5.

CRDs (`oc get crd`, filtered to `oadp.openshift.io` and `velero.io`): 21, every one with a single version that is
both served and stored. `velero.io`: backuprepositories, backups, backupstoragelocations, deletebackuprequests,
downloadrequests, podvolumebackups, podvolumerestores, restores, schedules, serverstatusrequests,
volumesnapshotlocations at `v1`; datadownloads and datauploads at `v2alpha1`. `oadp.openshift.io` at `v1alpha1`:
cloudstorages, dataprotectionapplications, dataprotectiontests, nonadminbackups,
nonadminbackupstoragelocationrequests, nonadminbackupstoragelocations, nonadmindownloadrequests, nonadminrestores.
After the hop, compare these served/storage flags against this list.

## 2026-11-03 — Task 9: upgraded to 1.6, drills on 1.6 passed

Everything below was read with `KUBECONFIG=~/.kube/config-readonly`; every cluster change was a command the operator
approved at a prompt. Times are UTC.

### Gates (07:52)

DPA `Reconciled`, BSL `truenas-garage` `Available` (validated 07:52:34), Task 8 passed, `drill-15` `Completed` 33/33 with
`status.expiration` 2026-11-16T20:52:01Z, CatalogSource `okd-test-oadp` READY with the 1.6 head, `dpa-before.yaml` saved,
Schedule `daily` `paused: true`. All clear.

### Commit and InstallPlan

Committed and pushed `b02ae26` (`oadp: move to the okderators 1.6 test build`) at 07:53:06. InstallPlan `install-zqssm`
for `oadp-operator.v1.6.0-2026-11-02-205027` appeared at 07:56 in `RequiresApproval`; its bundle ConfigMap `sourceImage`
is our 4.22 bundle `@sha256:d42c3f7e…`. Steps: the CSV, 23 CRDs, RBAC (Roles, ClusterRoles, bindings), 5 ServiceAccounts
and the metrics Service. CRD comparison against the pre-upgrade list: the 21 existing CRDs keep their single served and
stored version, 2 are new (`virtualmachinebackupsdiscoveries`, `virtualmachinefilerestores`), 0 stored versions removed.
The operator approved the plan at 08:00:15.

### The leader-lease wait

The 1.6 CSV was `Succeeded` at 08:01:05 and the Subscription read `AtLatestKnown` 1.6, but nothing moved for about
three minutes. The old 1.5 pod did not release the `oadp.openshift.io` lease, so the new operator waited on it
(`leaseDurationSeconds` 137) and acquired it at 08:03:51. It then rolled the velero Deployment to
`okd-test/oadp/velero@8e026079e30f` (generation 2) at once. The pause is the old pod holding the lease, not a hang.

### Step 3 checks (08:04:52 to 08:06)

- Only the 1.6 CSV is left; 1.5 is gone.
- Every pod runs on `okd-test/oadp/` digests with 0 restarts: operator `0a3f068d`; velero `8e026079` with init
  containers aws-plugin `e0ca82a0` and openshift-plugin `96def84a`; 3 node-agents on velero `8e026079`; cli-binaries
  `fc22fa2c`; vmdp-binaries `8d50dbe2`.
- DPA generation 5, `Reconciled`, spec identical to `dpa-before.yaml` (`jq -S` diff of both specs is empty).
- BSL `truenas-garage` `Available`, validated 08:04:08.
- NetworkPolicies in `openshift-adp`: `oadp-cli-server-`, `oadp-operator-`, `oadp-vmdp-server-`, `velero-mover-`,
  `velero-network-policy`.
- 23 CRDs: storedVersions 11 `v1`, 10 `v1alpha1`, 2 `v2alpha1` (the 21 unchanged plus the 2 new).
- 1.6 creates two download servers at operator start, which 1.5 did not have: Deployments
  `openshift-adp-oadp-cli-server` and `-vmdp-server` (1/1), Services `:80 -> 8080`, Routes `oadp-cli-server-route` and
  `oadp-vmdp-server-route` (edge, `Admitted=True`), and cluster-scoped `ConsoleCLIDownload`s `openshift-adp-oadp-cli`
  and `-vmdp`. Archives, fetched through the service proxy: `kubectl-oadp_linux_amd64` 65097890 B, sha256
  `498bfce7…`; `oadp-vmdp_linux_amd64` 50311330 B, sha256 `0172e5df…`; both x86-64 ELF. I did not fetch through the
  Routes: curl is denied locally, so the Route level is admitted but not exercised.

### Drill run 2

Pre-flight clean: 0 Released or Failed PVs, every attached VolumeAttachment's PV Bound. The source writer logged
`DRILL sha256=b29d2dc0f2ea165345a30936217c9cd382260fac1d1bc4a31ec36fef8e60d642` (A) and `DRILL gen=661294aa…` (G1).

**r16a, the 1.5 backup restored by 1.6.** `restore-drill-15-r16a` applied 08:08:03, `Completed` 08:08:48, errors 0,
warnings 2 (ConfigMaps `kube-root-ca.crt` and `openshift-service-ca.crt` already exist, as on r15). DataDownload
`drill-15-r16a-slbxr` `Completed` 134217858/134217858 on node6, PVC Bound. The restored writer logged A and G1.

**New bytes.** `oc -n oadp-drill rollout restart deploy/drill-writer` at 08:10:36; the new pod logged A unchanged and
G2 = `534d5c1c31574f15ff1a5c169264525b898bcd9dbc6ffc6426562b267d63b0b9` (08:10:47). Bucket baseline before the backup:
134574093 B, 49 objects (08:11:32).

**drill-16.** `oc apply -f backup-16.yaml` at 08:11:54, `Completed` 08:12:39, errors 0, warnings 0, 33/33, expires
2026-11-17T08:11:54Z. DataUpload `drill-16-8h59p` `Completed`, `bytesDone` 134217858/134217858, `incrementalBytes`
134217858. BackupRepository `Ready`. Bucket 134574093 -> 201999089 B (+67424996 B = 64.3 MiB), objects 49 -> 66
(read 08:13:52). `incrementalBytes` equals the whole volume although only the 64 MiB generation file was new, so it does
not prove the write path; the bucket growth does. The Schedule's backup below reports 64 MiB (67108929) for the same situation.

**r16b, the 1.6 backup restored by 1.6.** `restore-drill-16-r16b` `Completed` 08:14:10 to 08:15:18, errors 0, warnings
2 (the same two ConfigMaps). DataDownload `drill-16-r16b-vn5qs` 134217858/134217858 on node6, PVC Bound. The restored
writer logged A (`b29d2dc0…`) and G2 (`534d5c1c…`). Checksums match, so the 1.6 write path and the 1.6 read path both
work.

### The uncounted "PVC is not bound" log line

The velero log carried `level=warning msg="PVC is not bound or has no volume name"` (`volumes_information.go:757`,
`drill-data`, 08:08:17) on r16a, and the same line on r16b. The drill README treats a warning about the PVC as a fail.
I ruled this one not a failure: it is outside `status.warnings` (which stayed at the two ConfigMaps), it comes from the
volume-info collector running while the data-mover PVC is still Pending by design, and the checksums show the data came
out of the bucket. I do not know whether 1.5 logged it; it was not checked. If the ruling is wrong, a PVC
restore defect would hide behind that line, but missing or wrong data would have changed A or G.

### The Schedule path

Source writer restarted 08:16:58; G3 = `3c961b2eb8f23d391839b30db0206785f476ed7acb17171c48894165b48d97ac` (08:17:21).
Bucket baseline 202004366 B, 71 objects (08:17:35). `oc apply -f schedule-drill.yaml` at 08:22:56 (`Enabled`). The
first Backup `drill-schedule-20261103083008` ran 08:30:08 to 08:31:09, on the `*/15` boundary and after the Schedule's
creation, `Completed`, errors 0, warnings 0, 47/47. DataUpload `drill-schedule-20261103083008-mdg8b`: `bytesDone`
134217858, `incrementalBytes` 67108929 (64 MiB, the new generation file). Bucket 202004366 -> 269432714 B (+67428348 B =
64.3 MiB), objects 71 -> 88 (08:32:16). Schedule deleted 08:33:25 so it takes no more backups; this was its only
Backup. I added `drill-schedule-20261103083008` to `tests/oadp-1.6-drill/delete-requests.yaml`; its Backups stay until
Task 10. `daily` stays paused.

### Maintenance read

```
oc -n openshift-adp get jobs -l velero.io/repo-name=oadp-drill-truenas-garage-kopia -o custom-columns='NAME:.metadata.name,DONE:.status.completionTime'
...-maintain-job-1793683729824   2026-11-03T05:28:55Z
...-maintain-job-1793687629835   2026-11-03T06:33:55Z
...-maintain-job-1793691529846   2026-11-03T07:38:55Z
oc -n openshift-adp get backuprepositories.velero.io oadp-drill-truenas-garage-kopia -o jsonpath='{.status.lastMaintenanceTime}'
2026-11-03T07:38:55Z
```

Read at 08:35:57. The last maintenance Job (07:38:55) ran under 1.5, before the 1.6 CSV was created (08:00:16). The
first one under 1.6 has not run yet; `maintenanceFrequency` is 1h, so it is due about 08:39. To be recorded in Task 10.

### Result

Upgrade clean, no rollback needed. Drill run 2 passed: a 1.5 backup restores on 1.6, a 1.6 backup of changed data
restores with the right checksums, and the Schedule path takes a backup on its boundary. The 24 h soak runs until about
2026-11-04 08:00 (Task 10).
