# okderators Kube Descheduler 5.4: in-cluster build Job

A one-off Job that runs okd-operator-pipeline's own `kube-descheduler/build.sh` on this cluster, pushes
the two images and the bundle to zot under `okd-test/`, and checks them: the images run, the operand
reports the pinned upstream version, the bundle holds exactly what the operator pin's `manifests/`
lists and names no Red Hat image. Its second mode edits the okderators catalog branches and builds the
test catalog. Container builds do not run on the Mac (arm64; the images have to install on the amd64
nodes, CLAUDE.md "Container image builds run on the cluster"). Same Job shape, contract lines, log
persistence, lock and push guards as `tests/okderators-nmstate-build/`; `PRUNE`, the image smoke tests
and the catalog scripts come from `tests/okderators-oadp-build/`. What differs is listed
[below](#what-differs-from-the-nmstate-and-oadp-jobs).

Not ArgoCD-managed. The operator applies, runs and deletes everything in this directory.
Chronology and results: `blog/blog-descheduler-draft.md`.

**Shared namespace.** This directory creates only the ConfigMap `descheduler-build-scripts`. The
namespace `okd-build`, ServiceAccount `builder`, the privileged RoleBinding and PVC `build-storage`
are owned by `tests/okderators-logging-build/manifests.yaml` and already exist. If the namespace is
ever gone, apply the logging directory first (`oc apply -k tests/okderators-logging-build/`, which
also creates its own `build-scripts` ConfigMap), then this one. `oc delete -k` here removes only the
ConfigMap; deleting the namespace and PVC is `oc delete -k tests/okderators-logging-build/`.

## Files

| file | what |
|---|---|
| `kustomization.yaml` | ConfigMap `descheduler-build-scripts` (no hash suffix), generated from `build.sh`, `catalog-edit.sh`, `catalog-walk.py` and `catalog-branches.tsv` |
| `build.sh` | the Job's entry point, mounted at `/scripts/build.sh` |
| `catalog-edit.sh` | `MODE=catalog`: the okderators catalog edit per branch, its checks and the test catalog image ([below](#modecatalog)) |
| `catalog-branches.tsv` | per catalog branch: the new entry's `replaces`, or `NONE` for a branch without the package, and the installed CSVs the walk starts from. Data, not code |
| `catalog-walk.py` | the upgrade-graph walker `catalog-edit.sh` runs (Python 3, standard library only); the OADP copy without its unused `--hop` |
| `job-template.yaml` | OpenShift Template for one run: Job `descheduler-build-<MODE>-<DATE>` |
| `log-reader.yaml` | read-only pod `descheduler-log-reader` for the log files on the PVC once a build pod is gone |

## Before each run (operator)

- **zot has at least 5 GiB free, read as a measured figure**: a full run pushes two images and the
  bundle (check the `PUSHED` bytes of the previous run). In the console (Observe, Metrics):
  `kubelet_volume_stats_available_bytes{namespace="zot",persistentvolumeclaim="data-zot-0"}`.
  A full zot breaks image pulls for the whole cluster. The Job cannot read this itself: its pod has no
  service account token.
- **Copy anything you still need from `/work`.** Both modes wipe `/work/run` (the previous run's
  diffs and renders are there), and a full run with `PRUNE=true` removes every unused image from the
  podman graph root. The `/work/logs` contract and log files are never touched.
- **No other run is active.** The `flock` on `/work/.lock` is shared with the logging, GitOps, NMState
  and OADP Jobs; a second run ends `RESULT FAIL another run holds /work/.lock`.

## Apply, run, read, delete

```bash
# the script ConfigMap (re-run after editing any file it is generated from)
oc apply -k tests/okderators-descheduler-build/

# one run per pipeline branch, each with a new DATE
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-descheduler-build/job-template.yaml \
  -p MODE=full -p PIPELINE_BRANCH=descheduler-5.4-4.22 -p DATE=$DATE | oc -n okd-build create -f -

# watch, then pull out the contract lines
oc -n okd-build logs -f job/descheduler-build-full-$DATE
oc -n okd-build logs job/descheduler-build-full-$DATE | grep -E '^(STEP|DISK|PUSHED|CHECK|RESULT) '

# step durations (STEP times are epoch seconds)
oc -n okd-build logs job/descheduler-build-full-$DATE | awk '$1=="STEP" && $3=="START" {s[$2]=$4} $1=="STEP" && $3=="END" {print $2, $4-s[$2] "s"}'
```

The two branches of `sudoom/okd-operator-pipeline`, each a row of the `BRANCHES` table in `build.sh`:

| branch | from | OKD release (its `common.sh`) | operator pin | descheduler pin | operand version | `olm.maxOpenShiftVersion` | `minKubeVersion` |
|---|---|---|---|---|---|---|---|
| `descheduler-5.4-4.22` | `release-4.22` | 4.22 | `1eb4d75f` (`release-4.22`) | `076d0fc5` (`release-4.22`) | `v20260219-v0.35.0` | 4.23 | 1.35.0 |
| `descheduler-5.4` | `main` | 5.0 | `5c0659fc` (`release-5.0`) | `ca28d9e9` (`release-5.0`) | `v20260520-v0.36.0` | 5.1 | recorded |

`kube-descheduler/build.sh` sets `MAJOR=5 MINOR=4` itself, so both branches build
`clusterkubedescheduleroperator.v5.4.0-<DATE>`; only `olm.maxOpenShiftVersion` tells the two bundles
apart. A branch without a row ends the run before anything starts. A pin bump changes the table and
the branch together: `submodule-pins` stops the run before the build if they disagree.

Cleanup:

```bash
# a finished run (its contract and full log stay on the PVC, see below)
oc -n okd-build delete job descheduler-build-full-$DATE

# this directory's ConfigMap
oc delete -k tests/okderators-descheduler-build/
```

Test images in zot are deleted by digest once nothing runs on them; the `PUSHED` lines carry the
digests. zot's GC (`gcDelay` 1h, `gcInterval` 24h) then frees the blobs; measure zot again.

```bash
# contract file saved with the log-reader commands below
awk '$1=="PUSHED" {print $2}' descheduler-build-full-$DATE.contract | sed 's/:[^:@/]*@/@/' \
  | while read -r ref; do skopeo delete "docker://$ref"; done   # wherever skopeo runs
```

## Reading the logs later

Same mechanism as the other build Jobs. `build.sh` writes on the PVC:

- `/work/logs/descheduler-build-<MODE>-<DATE>.contract`: every contract line, appended synchronously
  before it is printed, including the final `RESULT` (also `RESULT FAIL <step> (terminated)` of a
  deadline kill);
- `/work/logs/descheduler-build-<MODE>-<DATE>.log`: everything the run printed, copied by `tee`.

```bash
oc -n okd-build create -f tests/okderators-descheduler-build/log-reader.yaml
oc -n okd-build wait --for=condition=Ready pod/descheduler-log-reader --timeout=5m
oc -n okd-build exec descheduler-log-reader -- ls -l /work/logs
oc -n okd-build exec descheduler-log-reader -- cat /work/logs/descheduler-build-full-$DATE.contract > descheduler-build-full-$DATE.contract
oc -n okd-build exec descheduler-log-reader -- cat /work/logs/descheduler-build-full-$DATE.log > descheduler-build-full-$DATE.log
oc -n okd-build delete pod descheduler-log-reader
```

The pod is read-only, sleeps, ends by itself after an hour, and prefers the node of a running build
pod (the PVC is RWO). The log files stay until the PVC is deleted, so copy what the blog draft needs
first. A validation failure (bad `MODE`, `DATE`, `PRUNE`, `BASE_REGISTRY` or `PIPELINE_BRANCH`) happens
before the files are opened and is in the pod log only. A `DATE` whose log files already exist for that
`MODE` is refused: a run needs a new one.

## Modes

| `MODE` | does |
|---|---|
| `full` | tools, podman setup, **prune** (unless `PRUNE=false`), clone `PIPELINE_BRANCH`, tag check of both images and the bundle, `init`, **submodule-pins** (a FAIL ends the run here), `build_containers`, **image-smoke** and **operand-version** (a FAIL ends the run here, nothing pushed), `push_containers`, `build_bundle`, verify, `deinit`. Each pipeline step is a separate `./build.sh <step>` run of `kube-descheduler/build.sh`, the same functions its `main` runs, so each is timed. |
| `catalog` | tools, podman setup, tag check of `${BASE_REGISTRY}/descheduler-catalog:<DATE>`, `/scripts/catalog-edit.sh` in an empty `/work/run`: per branch in `CATALOG_BRANCHES` the new bundle is added to the channel, or a new package is created, `opm validate`, graph walk, the negative controls, then the test catalog image. Its `CHECK` lines go into the contract, a `CHECK ... FAIL` or a non-zero exit fails the run, and `build.sh` prints `PUSHED` for the catalog image. [Details below](#modecatalog). |

`./build.sh update` never runs (it moves the gitlinks to branch tips).

**prune.** `MODE=full` starts with `DISK`, `podman system prune -af`, `DISK`, whatever is free. Nothing
on the PVC needs keeping, and the command cannot be scoped to some images, so it removes every unused
one. The run's peak is `max(DISK)` over its contract lines after that prune: it approximates a fresh
runner because the base layers are pulled again. `PRUNE=false` skips it for a retry after a failed
round, so the retry does not repeat the compile; it logs `INFO prune skipped`, and that run's peak is
not a fresh-runner figure.

## Parameters

| parameter | default | meaning |
|---|---|---|
| `MODE` | required | `full` or `catalog` |
| `DATE` | required | `YYYY-MM-DD-HHMMSS`, new for every run; in `full` the image tags end in `5.4.0-<DATE>`, in `catalog` it is the catalog image's tag |
| `PIPELINE_REPO` | `https://github.com/sudoom/okd-operator-pipeline.git` | |
| `PIPELINE_BRANCH` | empty | `full` only, required there: one of the two branches above |
| `PRUNE` | `true` | `full` only: `false` keeps the layers of an earlier run; anything else is refused |
| `BASE_REGISTRY` | `zot.apps.okd.sudops.pl/okd-test` | anything outside `zot.apps.okd.sudops.pl/okd-test` is refused; images land in `<BASE_REGISTRY>/kube-descheduler/{operator,descheduler,operator-bundle}` |
| `CATALOG_BRANCHES` | empty | `catalog` only: okderators-catalog-index branches, `release-4.22 release-5.0`; must include `IMAGE_BRANCH` (the test catalog's source) |
| `BUNDLES` | empty | `catalog` only: one bundle per catalog branch, `<branch>=<ref@sha256:...>` separated by spaces, each ref as the full run's `PUSHED` line prints it |
| `IMAGE_BRANCH` | `release-4.22` | `catalog` only: the branch whose edited tree becomes the test catalog image; must be in `CATALOG_BRANCHES` |

The Job has no `OKD_VERSION` parameter: `common.sh` of the branch sets it, and only it names the OKD
release (`kube-descheduler/build.sh` keeps `MAJOR` and `MINOR` as the operator's own 5.4). It is logged
as `INFO var OKD_VERSION=`, and the run stops at the clone if the release it names is not the
`BRANCHES` row's.

## Output contract

Free-form output (the pipeline's `set -x` trace, `INFO`, `ERROR`) is interleaved with these lines in
the pod log and the `.log` file; the `.contract` file holds only these lines:

| line | meaning |
|---|---|
| `STEP <name> START\|END <seconds>` | epoch seconds; the duration is END minus START |
| `DISK <bytes>` | `du -sx` of `/var/lib/containers` + `/work`, after every step, and around the prune; `max(DISK)` after the prune is the run's peak |
| `PUSHED <ref>@<digest> <bytes>` | after `push_containers` and after `build_bundle`; in `catalog`, for the catalog image. Digest = sha256 of the manifest bytes zot serves; bytes = config + layer sizes in that manifest |
| `CHECK <name> PASS\|FAIL <detail>` | the checks below; in `catalog`, those of [MODE=catalog](#modecatalog) |
| `RESULT PASS\|FAIL <reason>` | the last line; on an error or SIGTERM the reason is the step that was running. `RESULT PASS` needs a `PASS` line for every check of the mode and no `FAIL` line in the contract |

## Verify

`submodule-pins` runs right after `init`, `image-smoke` and `operand-version` after `build_containers`,
before the images are pushed. The rest run after the bundle is pushed, on `opm render <bundle
repo>@<digest>` and on the bundle image's own files (`skopeo copy` of the pushed digest to a `dir:`
layout, layers unpacked).

| check | passes when |
|---|---|
| `submodule-pins` | `git submodule status -- kube-descheduler/` shows both submodules, unflagged, at their pins in the `BRANCHES` row. The first column matters: `-` prints the recorded commit although nothing is checked out, and `submodule_initialize` hides a failed update with `\|\| true`. `.gitmodules` is not what gets built, the gitlink is. There is no `kube-descheduler/patches`, so any commit on top is a failure |
| `image-smoke/operator`, `image-smoke/descheduler`, `image-smoke` | `podman run --rm --entrypoint <binary> <image> --help` exits 0 and prints the binary's own text: `/usr/bin/cluster-kube-descheduler-operator` (`Start the Cluster kube-descheduler Operator`) and `/usr/bin/descheduler` (`The descheduler evicts pods`), within 120 s. Both run even after a failure. The last line is the aggregate |
| `operand-version` | `/usr/bin/descheduler version` exits 0 and its `GitVersion` is the value the descheduler's Makefile stamps at the pin (`GO_LD_EXTRAFLAGS`), from the `BRANCHES` row. An unstamped binary prints an empty one |
| `bundle-objects` | the image's `manifests/` files and the objects `opm` renders are exactly what the operator pin's `manifests/` lists, read from git objects because `build_bundle()` edits the working tree: a manifest a pin adds, RBAC for the NetworkPolicy say, must reach the bundle, and nothing else may. Both pins hold the CSV and the CRD today. Always: one CSV, the CRD `kubedeschedulers.operator.openshift.io`, and `manifests` and `metadata` at the image's top level |
| `no-redhat-registry` | no `registry.redhat.io`, `registry-proxy`, `brew.registry` or `quay.io/openshift` (any case) in the CSV, the other bundle objects, the bundle image's files or its labels. The pin's CSV defaults are `registry-proxy.engineering.redhat.com/...`, which `build_bundle()` replaces |
| `csv-name` | package `cluster-kube-descheduler-operator`, CSV name `clusterkubedescheduleroperator.v5.4.0-<DATE>`, `spec.version`, the `olm.package` version and `OCP_DATE` `5.4.0-<DATE>`. The CSV's own `replaces`/`olm.skipRange` are printed as `INFO` (the catalog entry carries the real edges) |
| `images-by-digest` | as a set: `relatedImages` in the CSV and in what `opm` renders (minus the bundle itself) are exactly the two images, each `<BASE_REGISTRY>/kube-descheduler/<name>@<digest this run recorded>`. By name, because a swap passes as a set: `RELATED_IMAGE_OPERAND_IMAGE` is the operand, `RELATED_IMAGE_SOFTTAINTER_IMAGE` the operator, there is no other `RELATED_IMAGE_*` or `*_IMAGE` env, the deployment's only container is the operator and it has no init container, and the `containerImage` annotation is the operator |
| `max-ocp` | `olm.maxOpenShiftVersion`, in the CSV's `olm.properties` annotation and in `opm render`, is the `BRANCHES` row's: 4.23 from `descheduler-5.4-4.22`, 5.1 from `descheduler-5.4` |
| `min-kube` | `spec.minKubeVersion` is present and recorded in the detail; on `descheduler-5.4-4.22` it must be 1.35.0 |
| `operator-sdk-validate` | `operator-sdk bundle validate <unpacked bundle dir> -o json-alpha1` (v1.36.1, default validators) exits 0 with `passed: true`; warnings are counted and printed as `INFO` |

The image list is never written down here: `build.sh` sources the cloned `kube-descheduler/build.sh` and
reads every `IMG_*` variable. Exactly two images and one bundle are expected, and any `IMG_*` outside
`<BASE_REGISTRY>/kube-descheduler` is `RESULT FAIL` before anything is built. Any `FAIL` ends the run
`RESULT FAIL`.

## MODE=catalog

Adds each branch's new bundle to the okderators catalog branches, proves the upgrade graph, and builds
the test catalog image for the homelab's descheduler test CatalogSource.

```bash
DATE=$(date -u +%Y-%m-%d-%H%M%S)      # new for the catalog run; it only names the image tag and the logs
oc process --local -f tests/okderators-descheduler-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.22 release-5.0' \
  -p BUNDLES='release-4.22=<bundle ref@digest> release-5.0=<bundle ref@digest>' \
  | oc -n okd-build create -f -
oc -n okd-build logs -f job/descheduler-build-catalog-$DATE
oc -n okd-build logs job/descheduler-build-catalog-$DATE | grep -E '^(STEP|PUSHED|CHECK|RESULT) '
```

Each `BUNDLES` ref is the `PUSHED` line of that branch's run
(`.../kube-descheduler/operator-bundle:5.4.0-<DATE>@sha256:...`); the tag is dropped before use (opm
v1.74.0 refuses a reference with both a tag and a digest). `release-4.22` takes the bundle of
`descheduler-5.4-4.22`, `release-5.0` the bundle of `descheduler-5.4`; the two carry the same kind of
name, so `bundle-<branch>` tells them apart by the cap. The package is
`cluster-kube-descheduler-operator` only.

`catalog-branches.tsv` holds, per catalog branch (tab-separated, comma-separated list):

| column | meaning |
|---|---|
| `REPLACES` | the new entry's `replaces`. It must be the channel's single head before the edit; any other state stops the branch, because the graph it was written for has moved. `NONE`: the branch has no package, and `catalog/cluster-kube-descheduler-operator/` being there stops the branch |
| `INSTALLED` | CSVs a cluster may run; the walker starts from them too. `{DATE-1d}` is the new bundle's DATE a day earlier: the shape of our test CSV, for the later move of this cluster to the official build. `NONE` goes with `REPLACES=NONE` |

`release-4.22` has `REPLACES` `clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655`, its only entry
on 2026-11-02, and `INSTALLED` that plus `clusterkubedescheduleroperator.v5.4.0-{DATE-1d}`. `release-5.0`
has `NONE` in both. Per branch, in a depth-1 clone of `okd-project/okderators-catalog-index`:

1. The bundle file `catalog/cluster-kube-descheduler-operator/<CSV>.yaml` is written the way
   `hack/add-bundle.sh` writes it: `RENDERED=$(opm render <bundle>@<digest> -o yaml)`,
   `echo "$RENDERED" > <file>`. The script itself is not run: it `podman create`s the bundle, which
   fails for a `FROM scratch` bundle with no command (okderators-catalog-index PR #59).
2. With a `REPLACES`: the new entry goes at the end of the package file's `alpha` `entries:` block, every
   other line kept: `name: <CSV>`, `replaces: <REPLACES>`, `skipRange: '>=5.3.0-0 <5.4.0-<DATE>'`. `yq`
   then proves the entries are the old ones plus that one and that, with the `alpha` entries emptied,
   the old and new files are the same documents. Nothing is removed. `build_bundle()` deletes `replaces`
   from the CSV, so this entry is the only edge there is. The `-0` makes the prereleases of 5.3.0 count:
   the installed `5.3.0-2026-10-12-113655` sits below a bare `>=5.3.0`.
3. With `NONE`: the package file `catalog/cluster-kube-descheduler-operator/cluster-kube-descheduler-operator.yaml`
   is written the way the pipeline's `scripts/update-catalog-package.sh` creates one, an `olm.package`
   document (`defaultChannel: alpha`) and an `olm.channel` document, with the one entry carrying the same
   `skipRange` and no `replaces`.

| check | passes when |
|---|---|
| `branch-data-<branch>` | once per branch before anything else: one row, both columns filled, `NONE` in both or in neither, `REPLACES` otherwise a `clusterkubedescheduleroperator.v...` CSV name |
| `bundle-<branch>` | before any clone: package `cluster-kube-descheduler-operator`, version `5.4.0-<DATE>`, name `clusterkubedescheduleroperator.v<version>`, that CSV and the CRD among its objects, `olm.maxOpenShiftVersion` the branch's next release (`release-4.22` 4.23, `release-5.0` 5.1), `relatedImages` by digest with no `registry.redhat.io`, `registry-proxy`, `brew.registry` or `quay.io/openshift`. A wrong paste stops here |
| `installed-<branch>` | printed only as a `FAIL`: an `INSTALLED` template did not expand to a CSV name |
| `bundles-<branch>` | adding the bundle file is the only change in the clone at that point |
| `edit-<branch>` | with a `REPLACES`: the single head before the edit is `REPLACES`, and the package file changed only by the new entry (see 2.), no file removed. With `NONE`: the package directory was absent, the package file reads back as written (see 3.), and the two new files are the only change |
| `opm-validate-<branch>` | `opm validate catalog` passes on the edited tree |
| `walk-<branch>` | `catalog-walk.py`: the new CSV is the single head with the highest version, and every entry and every `INSTALLED` CSV reaches it by `replaces`, `skips` or `skipRange` edges with no other dead end |
| `negative-control-no-edge-<branch>` | only with a `REPLACES`. A copy whose entry has neither `replaces` nor `skipRange`: `opm validate` refuses it (multiple heads), the walker reports exactly `REPLACES` and the CSV as heads, and `REPLACES` stranded with everything else. The installed 5.3.0 would never update |
| `negative-control-replaces-only-<branch>` | only with a `REPLACES`. A copy whose entry has only `replaces`: `opm validate` passes, and the walker fails with exactly the `INSTALLED` CSVs absent from the channel stranded (the test-shaped CSV: the `skipRange` is what serves the later move). A row whose `INSTALLED` lists no such CSV fails, the control would show nothing |
| `fresh-head-<branch>` | only with `NONE`, instead of the two controls, which need an old head to strand: the new entry is the channel's one entry and single head, with no `replaces`. `opm-validate-<branch>` is the other half |
| `opm-validate-image`, `catalog-image` | the image context (the `IMAGE_BRANCH` tree, package `cluster-kube-descheduler-operator` only) passes `opm validate`; the image, built from that branch's `catalog.Containerfile` with its `FROM quay.io/operator-framework/opm:latest` pinned to the v1.74.0 digest, is pushed, rendered back from zot, and has exactly the one package, the new head and the same walk. Not built when an earlier check failed |

A `FAIL` in the first two stops the run before any clone. A `FAIL` of `edit-<branch>` or `bundles-<branch>`
stops that branch: nothing further runs on it, the other branch still does, and no image is built.
The push target is fixed in `build.sh`: `${BASE_REGISTRY}/descheduler-catalog:${DATE}`, through
`guard_registry` and the tag check, and `catalog-edit.sh` refuses anything outside
`zot.apps.okd.sudops.pl/okd-test/` again. `build.sh` prints `PUSHED` for it also when a later check
failed. Left in `/work/run` until the next run: `<branch>.diff` (the whole edit per branch, for the
catalog PRs), the `render-*.json` files, `catalog-edit.log`, the image context `catalog-image/`.

Test mode runs the same script on a laptop, without the Job, images or podman (bash 3.2 is enough;
`opm` v1.74.0, `yq` v4, `jq`, `git` and `python3` on PATH). `CATALOG_EDIT_TEST_BUNDLES` points at a
directory with one `olm.bundle` YAML file per branch, `<branch>.yaml`, which replaces the bundle
render; the image context is assembled and validated but not built. `CATALOG_BRANCH_DATA` points at
another data file:

```bash
# T=<scratch dir>; two shallow clones of okderators-catalog-index, one per branch
git init -q --bare $T/mirror.git
git -C $T/mirror.git fetch -q --update-shallow $T/cat-release-4.22 HEAD:refs/heads/release-4.22
git -C $T/mirror.git fetch -q --update-shallow $T/cat-release-5.0 HEAD:refs/heads/release-5.0
mkdir $T/run
RUN_DIR=$T/run CATALOG_REPO=$T/mirror.git CATALOG_BRANCHES='release-4.22 release-5.0' \
  CATALOG_EDIT_TEST_BUNDLES=$T/bundles bash tests/okderators-descheduler-build/catalog-edit.sh
```

A test bundle needs `schema: olm.bundle`, `name: clusterkubedescheduleroperator.v5.4.0-<DATE>`,
`package: cluster-kube-descheduler-operator`, `image`, `relatedImages`, an `olm.package` property with
that version, an `olm.maxOpenShiftVersion` property, and `olm.bundle.object` properties for the CRD and
a CSV of the same name (`opm render` of a directory holding the operator pin's `manifests/` and
`metadata/`, after `build_bundle()`'s edits, works).

## What differs from the NMState and OADP Jobs

- Runs `kube-descheduler/build.sh` (`NAMESPACE=kube-descheduler`, registry
  `<BASE_REGISTRY>/kube-descheduler`), one package, two images, one bundle `operator-bundle`; names are
  `descheduler-build-*`: Job, log files, ConfigMap `descheduler-build-scripts`, Template
  `okderators-descheduler-build`, pod `descheduler-log-reader`. The pod labels `okd-build/mode` and
  `okd-build/date` are the same, so a reader's affinity finds any of the Jobs' pods.
- `build.sh` is written for bash 3.2 as OADP's is, so its checks run on the Mac against fixtures. Its
  `BRANCHES` table holds what differs by pipeline branch. No `MODE=check`, no `REUSE_DATE` and no
  `OKD_VERSION` parameter: with two images to build, a retry is a new full run with `PRUNE=false`.
- Tools: the same pins and checksums as the other Jobs, without Go, kustomize and `make`: the compilers
  run inside the Containerfiles and `build_bundle()` edits the committed manifests with `yq`. No git
  identity either, because there is no patch for `git am`.
- Checks: new `max-ocp`, `min-kube` and `operand-version`. `submodule-pins` from OADP without the patch
  handling; `pipeline-gitlinks` is gone because `submodule-pins` runs right after `init`, before any
  compile. `image-smoke` from OADP, on the two binaries. `no-redhat-registry` also covers
  `quay.io/openshift` and all of `registry-proxy`. Not here: NMState's `no-imagestream`,
  `gitmodules-branch`, `csv-code-release`, `install-modes`, `operator-commit`, `nmstate-rpm`; OADP's
  `base-images`, `no-konveyor`, `okd-strings`, `install-modes`, `operator-commit` and its other
  operand checks.
- CPU limit 10 instead of 14.
- `catalog-edit.sh`: OADP's add-an-entry path, unchanged in shape, plus the fresh-package path for
  `REPLACES=NONE`. The replaces-only control has no "nothing absent" pass: every `REPLACES` row here
  lists the test-shaped CSV, and one that does not is a data error. `catalog-walk.py`: no `--hop`,
  nothing passes it.

## How it runs, and why

Unchanged from the logging Job, which documents it in full: privileged podman in a pod (SCC
`privileged` through the RoleBinding there), one PVC with two `subPath` mounts, pushes to zot
`okd-test/` only with no registry credentials in the pod, one run at a time via `flock`, no tag
pushed twice, `backoffLimit: 0`, 12 h `activeDeadlineSeconds`, requests 2 CPU / 8 Gi, limits
10 CPU / 48 Gi, podman image pinned by digest. The Containerfiles compile in `go-toolset:1.25` on
`descheduler-5.4-4.22` and `go-toolset:1.26` on `descheduler-5.4`. Expect about 3x longer builds while
the `powersave-experimental` Tuned profile pins cores at minimum frequency.
