# okderators NMState: in-cluster build Job

A one-off Job that runs okd-operator-pipeline's own `nmstate/build.sh` on this cluster, pushes the
images and the bundle to zot under `okd-test/`, and checks that the bundle is the fixed one: no
`ImageStream`, exactly the CRD and the CSV. Its second mode edits the okderators catalog branches and
builds the test catalog. Container builds do not run on the Mac (arm64; the images have to install
on the amd64 nodes, CLAUDE.md "Container image builds run on the cluster"). This is the NMState
counterpart of `tests/okderators-gitops-build/`: same Job shape, same contract lines, same log
persistence, lock, prune and push guards. What differs is listed
[below](#what-differs-from-the-gitops-job).

Not ArgoCD-managed. The operator applies, runs and deletes everything in this directory.
Chronology and results: `blog/blog-okderators-nmstate-draft.md`.

**Shared namespace.** This directory creates only the ConfigMap `nmstate-build-scripts`. The
namespace `okd-build`, ServiceAccount `builder`, the privileged RoleBinding and PVC `build-storage`
are owned by `tests/okderators-logging-build/manifests.yaml` and already exist. If the namespace is
ever gone, apply the logging directory first (`oc apply -k tests/okderators-logging-build/`, which
also creates its own `build-scripts` ConfigMap), then this one. `oc delete -k` here removes only the
ConfigMap; deleting the namespace and PVC is `oc delete -k tests/okderators-logging-build/`.

## Files

| file | what |
|---|---|
| `kustomization.yaml` | ConfigMap `nmstate-build-scripts` (no hash suffix), generated from `build.sh`, `catalog-edit.sh`, `catalog-walk.py` and `catalog-branches.tsv` |
| `build.sh` | the Job's entry point, mounted at `/scripts/build.sh` |
| `catalog-edit.sh` | `MODE=catalog`: the okderators catalog edit per branch, its checks and the test catalog image ([below](#modecatalog)) |
| `catalog-branches.tsv` | per catalog branch: the entries the edit replaces, the new entry's `skips`, the installed CSVs the walk starts from. Data, not code: a row with `TO-FILL` stops a catalog run |
| `catalog-walk.py` | the upgrade-graph walker `catalog-edit.sh` runs (Python 3, standard library only); byte-identical to the GitOps copy |
| `job-template.yaml` | OpenShift Template for one run: Job `nmstate-build-<MODE>-<DATE>` |
| `log-reader.yaml` | read-only pod `nmstate-log-reader` for the log files on the PVC once a build pod is gone |

## Before each run (operator)

- **zot has at least 5 GiB free**: a full run pushes three images and the bundle (check the
  `PUSHED` bytes of the previous run). In the console (Observe, Metrics):
  `kubelet_volume_stats_available_bytes{namespace="zot",persistentvolumeclaim="data-zot-0"}`.
  A full zot breaks image pulls for the whole cluster.
- **Copy anything you still need from `/work`.** Both modes wipe `/work/run` (the previous run's
  diffs and renders are there), and a full run always prunes every unused image from the podman graph
  root. The `/work/logs` contract and log files are never touched.
- **No other run is active.** The `flock` on `/work/.lock` is shared with the logging and GitOps
  Jobs; a second run ends `RESULT FAIL another run holds /work/.lock`.

## Apply, run, read, delete

```bash
# the script ConfigMap (re-run after editing any file it is generated from)
oc apply -k tests/okderators-nmstate-build/

# one run per pipeline branch, each with a new DATE
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-nmstate-build/job-template.yaml \
  -p MODE=full -p PIPELINE_BRANCH=nmstate-bundle-fix-4.21 -p DATE=$DATE | oc -n okd-build create -f -

# watch, then pull out the contract lines
oc -n okd-build logs -f job/nmstate-build-full-$DATE
oc -n okd-build logs job/nmstate-build-full-$DATE | grep -E '^(STEP|DISK|PUSHED|CHECK|RESULT) '

# step durations (STEP times are epoch seconds)
oc -n okd-build logs job/nmstate-build-full-$DATE | awk '$1=="STEP" && $3=="START" {s[$2]=$4} $1=="STEP" && $3=="END" {print $2, $4-s[$2] "s"}'
```

The four branches of `sudoom/okd-operator-pipeline` are `nmstate-bundle-fix` (from `main`),
`nmstate-bundle-fix-4.22`, `nmstate-bundle-fix-4.21` and `nmstate-bundle-fix-4.20`. Each builds with
its own `common.sh` `OKD_VERSION` default, which sets the CSV version, the image tags and the scos
base image (`release-4.20` 4.20.0-okd-scos.6, `release-4.21` 4.21.0-okd-scos.10, `release-4.22`
4.22.0-okd-scos.2, `main` 5.0.0-okd-scos.0, so the `main`-based branch builds
`kubernetes-nmstate-operator.v5.0.0-<DATE>`). Leave `OKD_VERSION` empty. An override is only for
another payload of the same release (a later `4.21.0-okd-scos.N`, say): `gitmodules-branch` ends the run
before anything is built when `release-<MAJOR>.<MINOR>` of the `OKD_VERSION` in effect is not the
release both nmstate submodules declare in the branch's `.gitmodules`, and `csv-code-release` fails a
bundle whose operator code belongs to another release than its name.

Cleanup:

```bash
# a finished run (its contract and full log stay on the PVC, see below)
oc -n okd-build delete job nmstate-build-full-$DATE

# this directory's ConfigMap
oc delete -k tests/okderators-nmstate-build/
```

Test images in zot are deleted by digest once nothing runs on them; the `PUSHED` lines carry the
digests. zot's GC (`gcDelay` 1h, `gcInterval` 24h) then frees the blobs; measure zot again.

```bash
# contract file saved with the log-reader commands below
awk '$1=="PUSHED" {print $2}' nmstate-build-full-$DATE.contract | sed 's/:[^:@/]*@/@/' \
  | while read -r ref; do skopeo delete "docker://$ref"; done   # wherever skopeo runs
```

## Reading the logs later

Same mechanism as the logging and GitOps Jobs. `build.sh` writes on the PVC:

- `/work/logs/nmstate-build-<MODE>-<DATE>.contract`: every contract line, appended synchronously
  before it is printed, including the final `RESULT` (also `RESULT FAIL <step> (terminated)` of a
  deadline kill);
- `/work/logs/nmstate-build-<MODE>-<DATE>.log`: everything the run printed, copied by `tee`.

```bash
oc -n okd-build create -f tests/okderators-nmstate-build/log-reader.yaml
oc -n okd-build wait --for=condition=Ready pod/nmstate-log-reader --timeout=5m
oc -n okd-build exec nmstate-log-reader -- ls -l /work/logs
oc -n okd-build exec nmstate-log-reader -- cat /work/logs/nmstate-build-full-$DATE.contract > nmstate-build-full-$DATE.contract
oc -n okd-build exec nmstate-log-reader -- cat /work/logs/nmstate-build-full-$DATE.log > nmstate-build-full-$DATE.log
oc -n okd-build delete pod nmstate-log-reader
```

The pod is read-only, sleeps, ends by itself after an hour, and prefers the node of a running build
pod (the PVC is RWO). The log files stay until the PVC is deleted, so copy what the blog draft
needs first. A validation failure (bad `MODE`, `DATE` or `BASE_REGISTRY`) happens before the files
are opened and is in the pod log only.

## Modes

| `MODE` | does |
|---|---|
| `full` | tools, podman setup, **prune**, clone `PIPELINE_BRANCH` and **gitmodules-branch** (a FAIL ends the run here), tag check of every image and the bundle, `init`, `build_containers`, **operator-commit**, `push_containers`, **nmstate-rpm**, `build_bundle`, `deinit`, verify. Each pipeline step is a separate `./build.sh <step>` run of `nmstate/build.sh`, the same functions its `main` runs, so each is timed. |
| `catalog` | tools, podman setup, tag check of `${BASE_REGISTRY}/nmstate-catalog:<DATE>`, `/scripts/catalog-edit.sh` in an empty `/work/run`: per branch in `CATALOG_BRANCHES` the new bundle replaces the broken one, `opm validate`, graph walk, two negative controls, then the test catalog image. Its `CHECK` lines go into the contract, a `CHECK ... FAIL` or a non-zero exit fails the run, and `build.sh` prints `PUSHED` for the catalog image. [Details below](#modecatalog). |

`./build.sh update` never runs (it moves the gitlinks to branch tips).

**prune (Ruling P2, amended).** `MODE=full` always starts with `DISK`, `podman system prune -af`, `DISK`,
whatever is free. Nothing on the PVC needs keeping, and the command cannot be scoped to some images,
so it removes every unused one. The run's peak is `max(DISK)` over its contract lines after that
prune: it approximates a fresh runner because the base layers are pulled again.

## Parameters

| parameter | default | meaning |
|---|---|---|
| `MODE` | required | `full` or `catalog` |
| `DATE` | required | `YYYY-MM-DD-HHMMSS`, new for every run; in `full` the image tags end in `<MAJOR>.<MINOR>.0-<DATE>`, in `catalog` it is the catalog image's tag |
| `PIPELINE_REPO` | `https://github.com/sudoom/okd-operator-pipeline.git` | |
| `PIPELINE_BRANCH` | empty | `full` only, required there: one of the four branches above |
| `BASE_REGISTRY` | `zot.apps.okd.sudops.pl/okd-test` | anything outside `zot.apps.okd.sudops.pl/okd-test` is refused; images land in `<BASE_REGISTRY>/nmstate/{operator,handler,console-plugin,bundle}` |
| `OKD_VERSION` | empty (branch default) | exported to `nmstate/build.sh`, where `common.sh` reads `${OKD_VERSION:-...}` (empty counts as unset): the payload `kube-rbac-proxy` comes from it, and its `MAJOR.MINOR` names the CSV, the tags and the `scos-<MAJOR>.<MINOR>:base-stream9` base. Must keep the branch's release (`gitmodules-branch`); leave it empty. Logged as `INFO OKD_VERSION=` and `INFO var OKD_VERSION=` |
| `CATALOG_BRANCHES` | empty | `catalog` only: okderators-catalog-index branches, e.g. `release-4.21 release-4.22`; must include `release-4.21` (the test catalog's source) |
| `BUNDLES` | empty | `catalog` only: one bundle per catalog branch, `<branch>=<ref@sha256:...>` separated by spaces, each ref as the full run's `PUSHED` line prints it |

## Output contract

Free-form output (the pipeline's `set -x` trace, `INFO`, `ERROR`) is interleaved with these lines in
the pod log and the `.log` file; the `.contract` file holds only these lines:

| line | meaning |
|---|---|
| `STEP <name> START\|END <seconds>` | epoch seconds; the duration is END minus START |
| `DISK <bytes>` | `du -sx` of `/var/lib/containers` + `/work`, after every step, and around the prune; `max(DISK)` after the prune is the run's peak |
| `PUSHED <ref>@<digest> <bytes>` | after `push_containers` and after `build_bundle`; in `catalog`, for the catalog image. Digest = sha256 of the manifest bytes zot serves; bytes = config + layer sizes in that manifest |
| `CHECK <name> PASS\|FAIL <detail>` | the checks below; in `catalog`, those of [MODE=catalog](#modecatalog) |
| `RESULT PASS\|FAIL <reason>` | the last line; on an error or SIGTERM the reason is the step that was running |

## Verify

`gitmodules-branch` runs right after the clone, `operator-commit` and `nmstate-rpm` during the build,
the rest after the bundle is pushed, on `opm render <bundle
repo>@<digest>` and on the bundle image's own files (`skopeo copy` of the pushed digest to a `dir:`
layout, layers unpacked): the bug this fixes is an extensionless file, `manifests/image-references`,
which `find -name '*.yaml'` missed, so the files are checked as well as the rendered objects.

| check | passes when |
|---|---|
| `gitmodules-branch` | after the clone, before any build: `.gitmodules` declares `branch = release-<OCP_SHORT>` for both `nmstate/operator` and `nmstate/console-plugin`, `OCP_SHORT` being `MAJOR.MINOR` of the `OKD_VERSION` in effect (`main`: `5.0`, `release-5.0`). A FAIL ends the run `RESULT FAIL gitmodules-branch: ...` there: the branch and `OKD_VERSION` disagree. `.gitmodules` is not what gets built (the gitlink is), which is why the next two checks exist |
| `operator-commit` | after `build_containers`: the `nmstate/operator` submodule's `HEAD` equals the gitlink the branch records (`git ls-tree HEAD nmstate/operator`), the tree is clean and no `patches/operator.patch` exists. Ruling N5: `nmstate/images/operator.Containerfile` sets no commit label and the operator's `.dockerignore` drops `.git` (so no Go VCS stamp; checked on the release-4.21 and release-4.22 sources), so the image cannot name its commit; the check proves the tree the pipeline's own `init` checked out. A commit-like label appearing in the Containerfile fails it until the check compares that label. The console plugin's `HEAD`, gitlink and `.gitmodules` branch are printed as `INFO` |
| `nmstate-rpm` | `rpm -q nmstate` in the built handler image prints an `nmstate-<version>` line (recorded in the detail) |
| `bundle-objects` | the rendered objects are exactly `CustomResourceDefinition/nmstates.nmstate.io` and one `ClusterServiceVersion`, and the image's `manifests/` holds exactly two files |
| `no-imagestream` | no `ImageStream` object, no file in the bundle image with `kind: ImageStream`, no `image-references` file |
| `no-redhat-registry` | no `registry.redhat.io`, `registry-proxy.engineering.redhat.com` or `brew.registry` (any case) in the CSV, the other bundle objects, the bundle image's files or its labels |
| `csv-name` | package `kubernetes-nmstate-operator`, CSV name `kubernetes-nmstate-operator.v<MAJOR>.<MINOR>.0-<DATE>`, `spec.version` and the `olm.package` version `<MAJOR>.<MINOR>.0-<DATE>`, with `MAJOR.MINOR` from the `OKD_VERSION` in effect. The CSV's own `replaces`/`skips`/`olm.skipRange`/`minKubeVersion` are printed as `INFO` (the catalog entry carries the real edges) |
| `csv-code-release` | the release the operator code itself declares: the CSV's `spec.labels.olm-status-descriptors` is `kubernetes-nmstate-operator.vX.Y.0` and the upper bound of its `olm.skipRange` is `<X.Y.0`, for X.Y the `MAJOR.MINOR` of the `OKD_VERSION` in effect. Both come from kubernetes-nmstate's CSV base at the gitlink, and the pipeline leaves them alone, so code of one release built under another's name fails here although `csv-name` passes. The 2026-05-05 4.21 catalog bundle (4.20 code named `v4.21.0`) carries `v4.20.0` and `<4.20.0` |
| `images-by-digest` | every `relatedImages` entry (bundle and CSV), every deployment container image, every `RELATED_IMAGE_*` / `*_IMAGE` env value and the `containerImage` annotation is `@sha256:`; refs under `<BASE_REGISTRY>/nmstate/` are digests this run pushed, every built image (operator, handler, console-plugin) is referenced, and the only other ref is `IMG_KUBE_RBAC_PROXY` exactly |
| `install-modes` | records every install mode; `AllNamespaces` must be supported (the homelab `OperatorGroup` is `spec: {}`), except for a `4.20` build, where it is only recorded |
| `operator-sdk-validate` | `operator-sdk bundle validate <unpacked bundle dir> -o json-alpha1` (v1.36.1, default validators) exits 0 with `passed: true`; warnings are counted and printed as `INFO`. The broken 4.21 catalog bundle fails it (`unsupported media type registry+v1 for bundle object` for the ImageStream) |

The image list is never written down here: `build.sh` sources the cloned `nmstate/build.sh` and reads
every `IMG_*` variable. `IMG_KUBE_RBAC_PROXY` is the one external image (`quay.io/okd/scos-content@sha256:...`,
from the payload): never pushed, accepted only by its exact digest. Any other `IMG_*` outside
`<BASE_REGISTRY>/nmstate` is `RESULT FAIL` before anything is built. Any `FAIL` ends the run `RESULT FAIL`.

## MODE=catalog

Adds each branch's new bundle to the okderators catalog branches in place of the broken one, proves
the upgrade graph, and builds the test catalog image for the homelab's NMState test CatalogSource.

```bash
DATE=$(date -u +%Y-%m-%d-%H%M%S)      # new for the catalog run; it only names the image tag
oc process --local -f tests/okderators-nmstate-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.21 release-4.22 release-4.20' \
  -p BUNDLES='release-4.21=<bundle ref@digest> release-4.22=<...> release-4.20=<...>' \
  | oc -n okd-build create -f -
oc -n okd-build logs -f job/nmstate-build-catalog-$DATE
oc -n okd-build logs job/nmstate-build-catalog-$DATE | grep -E '^(STEP|PUSHED|CHECK|RESULT) '
```

Each `BUNDLES` ref is the `PUSHED` line of that branch's full run
(`.../nmstate/bundle:4.N.0-<DATE>@sha256:...`); the tag is dropped before use (opm v1.74.0 refuses a
reference with both a tag and a digest). The package is `kubernetes-nmstate-operator` only.

`catalog-branches.tsv` holds, per catalog branch (tab-separated, comma-separated lists):

| column | meaning |
|---|---|
| `REMOVE` | channel `alpha`'s entries before the edit, exactly; any other state stops the branch. Their entries and bundle files (`catalog/kubernetes-nmstate-operator/<name>.yaml`) are removed |
| `SKIPS` | the new entry's `skips` |
| `INSTALLED` | CSVs a cluster may run that the channel may not list; the walker starts from them too. `{DATE}`, `{DATE-1d}`, `{DATE+1d}` are the new bundle's DATE, a day earlier or later: `{DATE-1d}` is the shape of our test build installed before the official one, and on 4.22 `v4.21.0-{DATE+1d}` an official 4.21 built after the 4.22 bundle |

The `release-4.21` and `release-4.22` rows hold the plan's values; `release-4.20` holds that branch's
current head, read 2026-10-23: `kubernetes-nmstate-operator.v4.20.0-2025-12-27-212436` is its only
entry, so it is both `REMOVE` and `SKIPS`. Per branch, in a depth-1 clone of
`okd-project/okderators-catalog-index`:

1. The bundle file `catalog/kubernetes-nmstate-operator/<CSV>.yaml` is written the way
   `hack/add-bundle.sh` writes it: `RENDERED=$(opm render <bundle>@<digest> -o yaml)`,
   `echo "$RENDERED" > <file>`. The script itself is not run: it `podman create`s the bundle, which
   fails for a `FROM scratch` bundle with no command (okderators-catalog-index PR #59).
2. `git rm` of every `REMOVE` bundle file.
3. The package file's `alpha` `entries:` block is replaced as text by one entry, every other line kept:
   `name: <CSV>`, `skips: <SKIPS>`, `skipRange: '>=4.3.0 <4.N.0-<DATE>'`. `yq` then proves the
   entries are exactly that one and that, with the `alpha` entries emptied, the old and new files are
   the same documents.

| check | passes when |
|---|---|
| `branch-data-<branch>` | once per branch before anything else: one row, no `TO-FILL`, every `REMOVE`/`SKIPS` name a `kubernetes-nmstate-operator.v...` CSV name |
| `bundle-<branch>` | before any clone: package `kubernetes-nmstate-operator`, version `4.N.0-<DATE>` for `release-4.N`, name `kubernetes-nmstate-operator.v<version>`, objects exactly the CRD `nmstates.nmstate.io` and that CSV |
| `no-imagestream-<branch>` | before any clone: no `ImageStream` object in the bundle |
| `installed-<branch>` | printed only as a `FAIL`: an `INSTALLED` template did not expand to a CSV name |
| `negative-control-imagestream-<branch>` | the unedited channel's single head, through the same ImageStream count as `no-imagestream-<branch>`, has at least one `ImageStream` (every okderators nmstate bundle today has one) |
| `bundles-<branch>` | adding the bundle file is the only change in the clone at that point |
| `edit-<branch>` | the entries before the edit are exactly `REMOVE` (each with its file), the files are removed, and the package file changed only in the `alpha` entries (see 3.) |
| `opm-validate-<branch>` | `opm validate catalog` passes on the edited tree |
| `walk-<branch>` | `catalog-walk.py`: the new CSV is the single head with the highest version, and every entry and every `INSTALLED` CSV reaches it by `replaces`, `skips` or `skipRange` edges with no other dead end |
| `negative-control-skiprange-<branch>` | a copy whose entry has no `skipRange` still passes `opm validate`, and the walker fails it with exactly the `INSTALLED` CSVs that `SKIPS` does not name reported as stranded (the test-shaped CSVs) |
| `opm-validate-image`, `catalog-image` | the image context (`release-4.21` tree, package `kubernetes-nmstate-operator` only) passes `opm validate`; the image, built from that branch's `catalog.Containerfile` with its `FROM quay.io/operator-framework/opm:latest` pinned to the v1.74.0 digest, is pushed, rendered back from zot, and has exactly the one package, the new head and the same walk. Not built when an earlier check failed |

A `FAIL` in the first three stops the run before any clone. The push target is fixed in `build.sh`:
`${BASE_REGISTRY}/nmstate-catalog:${DATE}`, through `guard_registry` and the tag check, and
`catalog-edit.sh` refuses anything outside `zot.apps.okd.sudops.pl/okd-test/` again. `build.sh` prints
`PUSHED` for it also when a later check failed. Left in `/work/run` until the next run: `<branch>.diff`
(the whole edit per branch, for the catalog PRs), the `render-*.json` files, `catalog-edit.log`, the
image context `catalog-image/`.

Test mode runs the same script on a laptop, without the Job, images or podman (bash 3.2 is enough;
`opm` v1.74.0, `yq` v4, `jq`, `git` and `python3` on PATH). `CATALOG_EDIT_TEST_BUNDLES` points at a
directory with one `olm.bundle` YAML file per branch, `<branch>.yaml`, which replaces the bundle
render; the image context is assembled and validated but not built. `CATALOG_BRANCH_DATA` points at
another data file (e.g. one with the `release-4.20` row filled in):

```bash
# T=<scratch dir>; CAT=<a clone of okderators-catalog-index with an upstream remote>
git init -q --bare $T/mirror.git
git -C $T/mirror.git fetch -q $CAT refs/remotes/upstream/release-4.21:refs/heads/release-4.21 \
  refs/remotes/upstream/release-4.22:refs/heads/release-4.22
mkdir $T/run
RUN_DIR=$T/run CATALOG_REPO=$T/mirror.git CATALOG_BRANCHES='release-4.21 release-4.22' \
  CATALOG_EDIT_TEST_BUNDLES=$T/bundles bash tests/okderators-nmstate-build/catalog-edit.sh
```

A test bundle needs `schema: olm.bundle`, `name: kubernetes-nmstate-operator.v4.N.0-<DATE>`,
`package: kubernetes-nmstate-operator`, `image`, an `olm.package` property with that version, and
`olm.bundle.object` properties for the CRD and a CSV of the same name (a catalog head with its
`ImageStream` object dropped and the CSV renamed works).

## What differs from the GitOps Job

- Runs `nmstate/build.sh` (`NAMESPACE=nmstate`, registry `<BASE_REGISTRY>/nmstate`), one package, one
  bundle; names are `nmstate-build-*`: Job, log files, ConfigMap `nmstate-build-scripts`, Template
  `okderators-nmstate-build`, pod `nmstate-log-reader`. The pod labels `okd-build/mode` and
  `okd-build/date` are the same, so a reader's affinity finds any of the three Jobs' pods.
- No `MODE=check`: every pipeline branch pins different operator code, so each gets its own full run
  with its own `DATE`. `PIPELINE_BRANCH` has no default.
- Tools: the same pins and checksums (the `/work/tools` and `/work/cache` the other Jobs filled are
  reused), without `gettext`: nothing in `nmstate/build.sh` or kubernetes-nmstate's Makefile and
  `hack/` runs `envsubst`. The Makefile fetches its own operator-sdk for `make bundle` (v1.37.0 on release-4.21 and release-4.22); the
  pinned v1.36.1 only validates.
- `argocd-version` is gone; `gitmodules-branch`, `operator-commit` and `nmstate-rpm` are new steps. External images: only
  `IMG_KUBE_RBAC_PROXY`, by digest.
- Verify: `csv/<pkg>`, `skip-range`, `no-replaces`, `max-openshift-version`, `branding` and `provider`
  are not checked (not in the plan's list; the upstream bundle script adds
  `operators.openshift.io/valid-subscription: "false"`, which the GitOps branding check would fail).
  New: `bundle-objects`, `no-imagestream`, `csv-code-release`, `install-modes`, `operator-sdk-validate`, the file-level
  scan of the bundle image, and `images-by-digest`, which merges the GitOps `images` and
  `images-built` and also requires each built image to be referenced.
- `catalog-edit.sh`: one bundle per branch (`BUNDLES` is a map), the per-branch values in
  `catalog-branches.tsv` instead of constants, the broken entries and bundle files replaced instead of
  an entry appended, no `hack/add-bundle.sh` attempt, and a different pair of negative controls.
  `catalog-walk.py` is unchanged (its `--hop` is unused here).

## How it runs, and why

Unchanged from the logging Job, which documents it in full: privileged podman in a pod (SCC
`privileged` through the RoleBinding there), one PVC with two `subPath` mounts, pushes to zot
`okd-test/` only with no registry credentials in the pod, one run at a time via `flock`, no tag
pushed twice, `backoffLimit: 0`, 12 h `activeDeadlineSeconds`, requests 2 CPU / 8 Gi, limits
14 CPU / 48 Gi, podman image pinned by digest. A full nmstate build is two Go binaries and one Node
UI, far less than GitOps' seven and two; the deadline and limits are kept anyway. The handler stage
runs `dnf update` and `dnf install nmstate` in the scos base, so the pod needs the SCOS mirrors.
Expect about 3x longer builds while the `powersave-experimental` Tuned profile pins cores at minimum
frequency.
