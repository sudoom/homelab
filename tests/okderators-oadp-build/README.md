# okderators OADP 1.6: in-cluster build Job

A one-off Job that runs okd-operator-pipeline's own `oadp/build.sh` on this cluster, pushes the 19
images and the bundle to zot under `okd-test/`, and checks the result: no konveyor or Red Hat image
in the bundle, every related image by digest, each of the eight images new in 1.6 running its own
binary. A second mode rebuilds only the bundle against an earlier run's images, and a third edits the
okderators catalog branches and builds the test catalog. Container builds do not run on the Mac
(arm64; the images have to install on the amd64 nodes, CLAUDE.md "Container image builds run on the
cluster"). This is the OADP counterpart of `tests/okderators-nmstate-build/`: same Job shape, same
contract lines, same log persistence, lock, prune and push guards, plus the `check` mode of
`tests/okderators-logging-build/`. What differs is listed
[below](#what-differs-from-the-nmstate-job).

Not ArgoCD-managed. The operator applies, runs and deletes everything in this directory.
Chronology and results: `blog/blog-okderators-oadp-1.6-draft.md`.

**Shared namespace.** This directory creates only the ConfigMap `oadp-build-scripts`. The namespace
`okd-build`, ServiceAccount `builder`, the privileged RoleBinding and PVC `build-storage` are owned by
`tests/okderators-logging-build/manifests.yaml` and already exist. If the namespace is ever gone,
apply the logging directory first (`oc apply -k tests/okderators-logging-build/`, which also creates
its own `build-scripts` ConfigMap), then this one. `oc delete -k` here removes only the ConfigMap;
deleting the namespace and PVC is `oc delete -k tests/okderators-logging-build/`.

## Files

| file | what |
|---|---|
| `kustomization.yaml` | ConfigMap `oadp-build-scripts` (no hash suffix), generated from `build.sh`, `catalog-edit.sh`, `catalog-walk.py` and `catalog-branches.tsv` |
| `build.sh` | the Job's entry point, mounted at `/scripts/build.sh` |
| `catalog-edit.sh` | `MODE=catalog`: the okderators catalog edit per branch, its checks and the test catalog image ([below](#modecatalog)) |
| `catalog-branches.tsv` | per catalog branch: the new entry's `replaces` and the installed CSVs the walk starts from. Data, not code: a row with `TO-FILL` stops a catalog run |
| `catalog-walk.py` | the upgrade-graph walker `catalog-edit.sh` runs (Python 3, standard library only); byte-identical to the NMState copy, it takes the package as an argument |
| `job-template.yaml` | OpenShift Template for one run: Job `oadp-build-<MODE>-<DATE>` |
| `log-reader.yaml` | read-only pod `oadp-log-reader` for the log files on the PVC once a build pod is gone |

## Before each run (operator)

- **zot has at least 5 GiB free**, and at least 8 GiB before a second full build (`main`): a full run
  pushes 19 images and the bundle, roughly 3 to 4 GiB. zot's GC runs every 24 h, so what a deleted failed
  round used comes back only after the next pass: read the measured figure, never an expected one. In
  the console (Observe, Metrics):
  `kubelet_volume_stats_available_bytes{namespace="zot",persistentvolumeclaim="data-zot-0"}`.
  A full zot breaks image pulls for the whole cluster.
- **`build-storage` goes to 150 Gi before the first full run (decided).** Measured on earlier builds:
  `build_containers` added 33.3 GB for GitOps' twelve images and 29.5 GB for logging's nine, about 3 GB an
  image. This is nineteen, and two of them cross-compile ten binaries, so the estimate, not a
  measurement, is a peak of 70 to 100 GB against the old 100 Gi (107 GB); running out costs the whole
  build. The StorageClass `ceph-nvme-block` has `allowVolumeExpansion: true`, and the RBD image is thin.
  Pool `MAX AVAIL` read 252 GiB on 2026-11-02, so a real 100 GB peak leaves about 150 GiB until the PVC is
  deleted. The operator runs a real patch of the live PVC:

  ```bash
  oc -n okd-build patch pvc build-storage --type=merge -p '{"spec":{"resources":{"requests":{"storage":"150Gi"}}}}'
  oc -n okd-build get pvc build-storage -o jsonpath='{.status.capacity.storage}'
  ```

  The second command prints `150Gi` once the RBD image has grown. The filesystem grows the next time a
  pod mounts the claim, so the Job's pod does it. `tests/okderators-logging-build/manifests.yaml` owns
  the PVC and says `150Gi` too, so a later `oc apply -k` of that directory does not try to shrink it.
  `INFO free` after every step shows what is left as the build goes.
- **Copy anything you still need from `/work`.** All modes wipe `/work/run` (the previous run's diffs and
  renders are there), and a full run always prunes every unused image from the podman graph root. The
  `/work/logs` contract and log files are never touched.
- **No other run is active.** The `flock` on `/work/.lock` is shared with the logging, GitOps and NMState
  Jobs; a second run ends `RESULT FAIL another run holds /work/.lock`.

## Apply, run, read, delete

```bash
# the script ConfigMap (re-run after editing any file it is generated from)
oc apply -k tests/okderators-oadp-build/

# MODE=full, release-4.22 first: it gates the upgrade. A new DATE for every run.
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-oadp-build/job-template.yaml \
  -p MODE=full -p PIPELINE_BRANCH=oadp-1.6-4.22 -p DATE=$DATE | oc -n okd-build create -f -

# MODE=full on main (OKD 5.0), only with 8 GiB free in zot, measured, after the run above:
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-oadp-build/job-template.yaml \
  -p MODE=full -p PIPELINE_BRANCH=oadp-1.6 -p DATE=$DATE | oc -n okd-build create -f -

# MODE=check, bundle only, against the images of an earlier full run: for main when zot is short, and
# to redo the bundle after a build_bundle failure or a fix that touches only the bundle.
FULL_DATE=2026-11-02-120000   # the DATE of the full run
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-oadp-build/job-template.yaml \
  -p MODE=check -p PIPELINE_BRANCH=oadp-1.6 -p REUSE_DATE=$FULL_DATE -p DATE=$DATE | oc -n okd-build create -f -

# watch, then pull out the contract lines (MODE and DATE of the run)
MODE=full
oc -n okd-build logs -f job/oadp-build-$MODE-$DATE
oc -n okd-build logs job/oadp-build-$MODE-$DATE | grep -E '^(STEP|DISK|PUSHED|CHECK|RESULT) '

# step durations (STEP times are epoch seconds), the peak disk after the prune (full only), the base
# image digests
oc -n okd-build logs job/oadp-build-$MODE-$DATE | awk '$1=="STEP" && $3=="START" {s[$2]=$4} $1=="STEP" && $3=="END" {print $2, $4-s[$2] "s"}'
oc -n okd-build logs job/oadp-build-$MODE-$DATE | awk '$1=="STEP" && $2=="prune" && $3=="END" {on=1} on && $1=="DISK" && $2>m {m=$2} END {print "peak", m}'
oc -n okd-build logs job/oadp-build-$MODE-$DATE | grep '^INFO base '
```

`MODE=catalog` is [below](#modecatalog). Its `BUNDLES` come from the `PUSHED .../oadp/bundle:` lines.

The two branches of `sudoom/okd-operator-pipeline` are `oadp-1.6-4.22` (from `release-4.22`) and
`oadp-1.6` (from `main`); everything under `oadp/` is the same on both. Leave `OKD_VERSION` empty: it
only selects the payload's `cli` image that must-gather copies (`release-4.22` 4.22.0-okd-scos.2, `main`
5.0.0-okd-scos.0). `oadp/build.sh` sets `MAJOR=1 MINOR=6` itself, so the CSV is
`oadp-operator.v1.6.0-<DATE>` on both.

Cleanup:

```bash
# a finished run (its contract and full log stay on the PVC, see below)
oc -n okd-build delete job oadp-build-$MODE-$DATE

# this directory's ConfigMap
oc delete -k tests/okderators-oadp-build/
```

Test images in zot are deleted by digest once nothing runs on them; the `PUSHED` lines carry the
digests. zot's GC (`gcDelay` 1h, `gcInterval` 24h) then frees the blobs; measure zot again.

**A check run shares digests with its full run.** Its 19 image tags are copies, so deleting one of
those digests also removes the full run's image. To drop a failed `check` run, delete only its bundle.

```bash
# contract file saved with the log-reader commands below
awk '$1=="PUSHED" {print $2}' oadp-build-full-$DATE.contract | sed 's/:[^:@/]*@/@/' \
  | while read -r ref; do skopeo delete "docker://$ref"; done   # wherever skopeo runs
```

## Reading the logs later

Same mechanism as the other build Jobs. `build.sh` writes on the PVC:

- `/work/logs/oadp-build-<MODE>-<DATE>.contract`: every contract line, appended synchronously before it
  is printed, including the final `RESULT` (also `RESULT FAIL <step> (terminated)` of a deadline kill);
- `/work/logs/oadp-build-<MODE>-<DATE>.log`: everything the run printed, copied by `tee`.

```bash
oc -n okd-build create -f tests/okderators-oadp-build/log-reader.yaml
oc -n okd-build wait --for=condition=Ready pod/oadp-log-reader --timeout=5m
oc -n okd-build exec oadp-log-reader -- ls -l /work/logs
oc -n okd-build exec oadp-log-reader -- cat /work/logs/oadp-build-$MODE-$DATE.contract > oadp-build-$MODE-$DATE.contract
oc -n okd-build exec oadp-log-reader -- cat /work/logs/oadp-build-$MODE-$DATE.log > oadp-build-$MODE-$DATE.log
oc -n okd-build delete pod oadp-log-reader
```

The pod is read-only, sleeps, ends by itself after an hour, and prefers the node of a running build
pod (the PVC is RWO). The log files stay until the PVC is deleted, so copy what the blog draft needs
first. A validation failure (bad `MODE`, `DATE`, `REUSE_DATE` or `BASE_REGISTRY`, or a `DATE` already
used for this `MODE`) happens before the files are opened and is in the pod log only.

## Modes

| `MODE` | does |
|---|---|
| `full` | tools, podman setup, **prune** (skipped when `PRUNE=false`), clone `PIPELINE_BRANCH` and **pipeline-gitlinks**, an `INFO` line on `.gitmodules`, tag check of all 20 refs, **base-images**, `init`, **submodule-pins**, **operator-commit**, `build_containers`, **image-smoke**, **velero-version**, **vm-file-restore-env**, then and only then `push_containers`, `build_bundle`, verify, `deinit`. Each pipeline step is a separate `./build.sh <step>` run of `oadp/build.sh`, the same functions its `main` runs, so each is timed. |
| `check` | no image build, no prune. The same gates up to `init`, then `skopeo copy --all --preserve-digests` of every image of `REUSE_DATE` to this run's tag in the same repository (**reuse-digests**), the same image checks on those images, `build_bundle`, verify, `deinit`. Every check of `full` runs except `base-images`. |
| `catalog` | tools, podman setup, tag check of `${BASE_REGISTRY}/oadp-catalog:<DATE>`, `/scripts/catalog-edit.sh` in an empty `/work/run`: per branch in `CATALOG_BRANCHES` the new bundle is added, `opm validate`, graph walk, two negative controls, then the test catalog image. Its `CHECK` lines go into the contract, a `CHECK ... FAIL` or a non-zero exit fails the run, and `build.sh` prints `PUSHED` for the catalog image. [Details below](#modecatalog). |

`./build.sh update` never runs (it moves the gitlinks to branch tips).

**The order is deliberate.** A build takes hours and zot's budget is about two of them, so what can be
known early is checked early: a wrong branch ends in seconds at `pipeline-gitlinks`, a base image that
cannot be resolved before `init`, a bad submodule state before the build, and a broken image before
anything is pushed. All eight images are run even after one fails, so one round shows every failure.
If `build_bundle` or a bundle check fails, the images are already pushed: fix the branch and run
`MODE=check -p REUSE_DATE=<that DATE>`, no rebuild.

**prune.** `MODE=full` always starts with `DISK`, `podman system prune -af`, `DISK`, whatever is free.
Nothing on the PVC needs keeping, and the command cannot be scoped to some images, so it removes every
unused one. The run's peak is `max(DISK)` over its contract lines after that prune: it approximates a
fresh runner because the base layers are pulled again, which is the figure to compare with GitHub's
about 14 GB. A smoke failure stops before the push and the next full run prunes those images, so a fix
to the images always costs a full rebuild.

**`PRUNE`.** The default `true` keeps the above, and the first run keeps it so the peak-disk figure is
real. A retry after a failed round passes `-p PRUNE=false`: `MODE=full` then skips the prune (an `INFO
prune skipped` line says so), and the layers of the earlier run stay in the podman graph root. Only
images whose Containerfile has no `ARG CI_VERSION` reuse layers (the code at the top of those
Containerfiles shows it); the others rebuild as before. Nothing else changes.

## Parameters

| parameter | default | meaning |
|---|---|---|
| `MODE` | required | `full`, `check` or `catalog` |
| `DATE` | required | `YYYY-MM-DD-HHMMSS`, new for every run: in `full` and `check` the image and bundle tags end in `1.6.0-<DATE>`, in `catalog` it is the catalog image's tag, and it names the log files. A `DATE` whose log file exists is refused |
| `REUSE_DATE` | empty | `check` only, required there: the `DATE` of the full run whose images the bundle references. Refused in the other modes, and when equal to `DATE` |
| `PIPELINE_REPO` | `https://github.com/sudoom/okd-operator-pipeline.git` | |
| `PIPELINE_BRANCH` | empty | `full` and `check`, required there: `oadp-1.6-4.22` or `oadp-1.6` |
| `PRUNE` | `true` | `full` only: `false` skips the prune so a retry can reuse layers (see `prune` above) |
| `BASE_REGISTRY` | `zot.apps.okd.sudops.pl/okd-test` | anything outside `zot.apps.okd.sudops.pl/okd-test` is refused; images land in `<BASE_REGISTRY>/oadp/<name>` and the catalog in `<BASE_REGISTRY>/oadp-catalog` |
| `OKD_VERSION` | empty (branch default) | exported to `oadp/build.sh`, where `common.sh` reads `${OKD_VERSION:-...}` (empty counts as unset). Only the payload `cli` image comes from it. Logged as `INFO OKD_VERSION=` and `INFO var OKD_VERSION=` |
| `CATALOG_BRANCHES` | empty | `catalog` only: okderators-catalog-index branches, `release-4.22 release-5.0`; must include `IMAGE_BRANCH` |
| `BUNDLES` | empty | `catalog` only: one bundle per catalog branch, `<branch>=<ref@sha256:...>` separated by spaces, each ref as the full or check run's `PUSHED` line prints it |
| `IMAGE_BRANCH` | `release-4.22` | `catalog` only: the branch whose edited tree becomes the test catalog image; must be in `CATALOG_BRANCHES` |

## Output contract

Free-form output (the pipeline's `set -x` trace, `INFO`, `ERROR`) is interleaved with these lines in
the pod log and the `.log` file; the `.contract` file holds only these lines:

| line | meaning |
|---|---|
| `STEP <name> START\|END <seconds>` | epoch seconds; the duration is END minus START |
| `DISK <bytes>` | `du -sx` of `/var/lib/containers` + `/work`, after every step, and around the prune; `max(DISK)` after the prune is the run's peak |
| `PUSHED <ref>@<digest> <bytes>` | after `push_containers` (in `check`, after the copy) and after `build_bundle`; in `catalog`, for the catalog image. Digest = sha256 of the manifest bytes zot serves; bytes = config + layer sizes in that manifest. A good `full` or `check` has 20 of them |
| `CHECK <name> PASS\|FAIL <detail>` | the checks below; in `catalog`, those of [MODE=catalog](#modecatalog) |
| `RESULT PASS\|FAIL <reason>` | the last line; on an error or SIGTERM the reason is the step that was running |

`RESULT PASS` cannot print with a failed check: `finish` counts the failures in memory and the
`CHECK ... FAIL` lines in the contract file, and a mode ends by requiring a `PASS` line for each of
its checks by name, so a branch of the flow that skipped one reads as `RESULT FAIL`.

Also in the log, not the contract: `INFO base <ref> <digest>` for every `FROM` of the pipeline's
Containerfiles, once as the registry serves it before the build and once as the build used it (the
`:latest` UBI bases and `go-toolset:1.26` move), and `INFO free <bytes>` after every step.

## Verify

The bundle checks run on `opm render <bundle repo>@<digest>` and on the bundle image's own files
(`skopeo copy` of the pushed digest to a `dir:` layout, layers unpacked), so a stray extensionless
file counts as well as a rendered object.

| check | when | passes when |
|---|---|---|
| `pipeline-gitlinks` | after the clone, a FAIL ends the run | the branch's `oadp/` gitlinks are exactly the 19 pins (`PINS` in `build.sh`, from `pins.md`). The gitlink is what gets built, not `.gitmodules` |
| (`gitmodules-branch`, not a check) | after the clone, `INFO` only | prints which of the 19 submodules do not declare `branch = oadp-<OCP_SHORT>`; no `CHECK` line and no effect on `RESULT`, because `.gitmodules` is not what gets built |
| `base-images` | `full`, before `init`, a FAIL ends the run | every `FROM` ref resolves on its registry |
| `submodule-pins` | after `init`, a FAIL ends the run | `git submodule status oadp/` lists exactly the 19; those without a patch show flag ` ` and `HEAD` = pin. A `-` (not initialised) fails although it prints the pin, because `submodule_initialize` hides a failed update behind `\|\| true`. Read from git, because a submodule's `.git` is a file and the binaries stamp no `vcs.revision` |
| `operator-commit` | after `init`, a FAIL ends the run | for `oadp/operator` and `oadp/vm-file-restore`: `HEAD~1` = pin, `HEAD` subject `OKDify` and `Read the access and sidecar images from the environment`, clean tree |
| `reuse-digests` | `check`, after the copy, a FAIL ends the run | each copy has the digest of its source |
| `image-smoke/<image>`, `image-smoke` | before the push, a FAIL stops the push | each of the eight, under `podman run --rm`, below; the line without a suffix sums them up |
| `velero-version` | before the push | `velero version --client-only` in the built image prints `Version: v1.18.4-OADP` (pins.md v1.18.4, with the suffix the Containerfile stamps) |
| `vm-file-restore-env` | before the push | `/manager`, copied out with `podman create` and `podman cp` because the runtime is distroless, contains `VMFR_ACCESS_IMAGE`, `VMFR_SSH_IMAGE` and `VMFR_BROWSER_IMAGE`: `patches/vm-file-restore.patch` reached the binary |
| `bundle-objects` | verify | the image's `manifests/` files and the rendered objects are exactly what the operator pin's own `bundle/manifests` holds: 10 `oadp.openshift.io` and 13 `velero.io` CRDs, the CSV, and 26 RBAC and Service manifests (50). Anything else fails, and so does anything missing; the image's top level is `manifests`, `metadata`, `tests` |
| `no-redhat-registry` | verify | no `registry.redhat.io`, `registry-proxy.engineering.redhat.com` or `brew.registry` (any case) in the CSV, the other bundle objects, the bundle image's files or its labels. The bundle, not the binaries: must-gather's usage text names `registry.redhat.io` in a help string nothing pulls |
| `csv-name` | verify | package `oadp-operator`, CSV name `oadp-operator.v1.6.0-<DATE>`, `spec.version` and the `olm.package` version `1.6.0-<DATE>`. The CSV's own `replaces` and `olm.skipRange` do not match our graph and are printed as `INFO`: the channel entry is what OLM uses |
| `install-modes` | verify | `OwnNamespace` only, the other three `false` |
| `images-by-digest` | verify | as a set, `relatedImages` (CSV, and the render minus the bundle itself) are exactly the 19 refs, each `<BASE_REGISTRY>/oadp/<name>@<digest this run recorded>`: the 18 `RELATED_IMAGE_*` plus the manager. Then by name, because a swap would pass as a set: each `RELATED_IMAGE_*` env against the mapping in `build.sh`, no other such env, the manager container, the `containerImage` and `must-gather-image` annotations |
| `no-konveyor` | verify | no `quay.io/konveyor` in `relatedImages`, the operator's env or anywhere else in the bundle. At the pin the CSV names it only on lines `build_bundle()` rewrites, so nothing may be left |
| `okd-strings` | verify | `provider.name`, the `support` annotation and the maintainer are `OKD Community`, the `description` annotation says OKD, and no `operators.openshift.io/valid-subscription` anywhere |
| `operator-sdk-validate` | verify | `operator-sdk bundle validate <unpacked bundle dir> -o json-alpha1` (v1.36.1, default validators) exits 0 with `passed: true`; warnings are counted and printed as `INFO`. `make bundle` has run its own v1.35.0 by then |

The smoke tests, the way the controllers start these images where that matters:

| image | passes when |
|---|---|
| `vm-file-restore` | `--help` exits 0 and lists `-metrics-bind-address` |
| `kubevirt-datamover-controller` | the same, and `qemu-img --version` runs: the reason its base is CentOS Stream |
| `kubevirt-datamover-plugin` | `--entrypoint ls /plugins` lists `kubevirt-datamover-plugin` |
| `cli-binaries`, `vmdp-binaries` | `--entrypoint ls /archives` is not empty; then the image's own command under `timeout 10` logs `Found N binaries` (N > 0) and `Starting server` and is still up when the timeout ends it. They parse no flags, so `--help` would block; and a failed bind logs both lines too, hence the exit code. One retry at 30 s, because a podman start under `powersave-experimental` can take seconds |
| `vmfr-sshd` | `--entrypoint /oadp/bin/oadp-sshd` exits 1 with `Interactive shell access is disabled`; `/oadp/usr/libexec/openssh/sftp-server` is executable; `chroot /oadp /bin/bash -c 'rsync --version'` runs, because the Containerfile masks the library copies with `\|\| true` |
| `vmfr-filebrowser` | `--entrypoint /bin/bash -c '/usr/local/bin/filebrowser version'` prints `File Browser v1.6.0-...`. Bash and that path are the contract the VM file restore controller relies on |
| `vmfr-access` | `command -v` finds `guestmount guestunmount fusermount qemu-img python3 mountpoint mount grep awk sed basename mkdir date sleep tail`, everything `detect-and-mount.sh` and `entrypoint.sh` call at the pin (a virtual `libguestfs-tools` could install without `guestmount`), and both scripts are executable |

The image list is never written down here: `build.sh` sources the cloned `oadp/build.sh` and reads
every `IMG_*` variable. It must define 19 images and one bundle. `IMG_CLI` is the one external image
(`quay.io/okd/scos-content@sha256:...`, from the payload): never pushed, accepted only by digest. Any
other `IMG_*` outside `<BASE_REGISTRY>/oadp` is `RESULT FAIL` before anything is built. `build.sh` does
hold the pins, the `RELATED_IMAGE_*` mapping and the Velero version: a pin bump changes them and the
branch together.

## MODE=catalog

Adds each branch's new bundle to the okderators catalog branches, proves the upgrade graph, and builds
the test catalog image for the homelab's OADP test CatalogSource.

```bash
DATE=$(date -u +%Y-%m-%d-%H%M%S)      # new for the catalog run; it only names the image tag and the logs
oc process --local -f tests/okderators-oadp-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.22 release-5.0' \
  -p BUNDLES='release-4.22=<bundle ref@digest> release-5.0=<bundle ref@digest>' \
  | oc -n okd-build create -f -
oc -n okd-build logs -f job/oadp-build-catalog-$DATE
oc -n okd-build logs job/oadp-build-catalog-$DATE | grep -E '^(STEP|PUSHED|CHECK|RESULT) '
```

Each `BUNDLES` ref is the `PUSHED` line of that branch's run
(`.../oadp/bundle:1.6.0-<DATE>@sha256:...`); the tag is dropped before use (opm v1.74.0 refuses a
reference with both a tag and a digest). The package is `oadp-operator` only.

`catalog-branches.tsv` holds, per catalog branch (tab-separated, comma-separated list):

| column | meaning |
|---|---|
| `REPLACES` | the new entry's `replaces`. It must be the channel's single head before the edit; any other state stops the branch, because the graph it was written for has moved |
| `INSTALLED` | CSVs a cluster may run; the walker starts from them too. `{DATE-1d}` is the new bundle's DATE a day earlier: the shape of our test CSV, for the later move of this cluster to the official build. `release-4.22` names the installed 1.5.0, both 1.4.0 and that shape; `release-5.0` the two 1.4.0 |

Per branch, in a depth-1 clone of `okd-project/okderators-catalog-index`:

1. The bundle file `catalog/oadp-operator/<CSV>.yaml` is written the way `hack/add-bundle.sh` writes it:
   `RENDERED=$(opm render <bundle>@<digest> -o yaml)`, `echo "$RENDERED" > <file>`. The script itself is
   not run: it `podman create`s the bundle, which fails for a `FROM scratch` bundle with no command
   (okderators-catalog-index PR #59).
2. The new entry goes at the end of the package file's `alpha` `entries:` block, every other line kept:
   `name: <CSV>`, `replaces: <REPLACES>`, `skipRange: '>=1.4.0-0 <1.6.0-<DATE>'`. The file's last line
   gains the newline it lacks on both branches, so `git diff` shows that one line changed. `yq` then
   proves the entries are the old ones plus that one and that, with the `alpha` entries emptied, the old
   and new files are the same documents. Nothing is removed.

| check | passes when |
|---|---|
| `branch-data-<branch>` | once per branch before anything else: one row, no `TO-FILL`, `REPLACES` an `oadp-operator.v...` CSV name |
| `bundle-<branch>` | before any clone: package `oadp-operator`, version `1.6.0-<DATE>`, name `oadp-operator.v<version>`, that CSV and the 10 + 13 CRDs among its objects, `relatedImages` by digest with no `quay.io/konveyor` or Red Hat registry. A wrong paste stops here |
| `installed-<branch>` | printed only as a `FAIL`: an `INSTALLED` template did not expand to a CSV name |
| `bundles-<branch>` | adding the bundle file is the only change in the clone at that point |
| `edit-<branch>` | the single head before the edit is `REPLACES`, and the package file changed only by the new entry (see 2.), no file removed |
| `opm-validate-<branch>` | `opm validate catalog` passes on the edited tree |
| `walk-<branch>` | `catalog-walk.py`: the new CSV is the single head with the highest version, and every entry and every `INSTALLED` CSV reaches it by `replaces`, `skips` or `skipRange` edges with no other dead end |
| `negative-control-no-edge-<branch>` | a copy whose entry has neither `replaces` nor `skipRange`: `opm validate` refuses it (multiple heads), the walker reports exactly `REPLACES` and the CSV as heads, and `REPLACES` stranded with everything else. The installed CSV is a prerelease below `1.5.0`, so without an edge no upgrade is offered |
| `negative-control-replaces-only-<branch>` | a copy whose entry has only `replaces`: `opm validate` passes, and the walker fails with exactly the `INSTALLED` CSVs absent from the channel stranded (the test-shaped CSV: the `skipRange` is what serves the later move). A branch with no such CSV (`release-5.0`) instead asserts the walker passes with `replaces` alone |
| `opm-validate-image`, `catalog-image` | the image context (the `IMAGE_BRANCH` tree, package `oadp-operator` only) passes `opm validate`; the image, built from that branch's `catalog.Containerfile` with its `FROM quay.io/operator-framework/opm:latest` pinned to the v1.74.0 digest, is pushed, rendered back from zot, and has exactly the one package, the new head and the same walk. Not built when an earlier check failed |

A `FAIL` in the first two stops the run before any clone. The push target is fixed in `build.sh`:
`${BASE_REGISTRY}/oadp-catalog:${DATE}`, through `guard_registry` and the tag check, and
`catalog-edit.sh` refuses anything outside `zot.apps.okd.sudops.pl/okd-test/` again. `build.sh` prints
`PUSHED` for it also when a later check failed. Left in `/work/run` until the next run: `<branch>.diff`
(the whole edit per branch, for the catalog PRs), the `render-*.json` files, `catalog-edit.log`, the
image context `catalog-image/`.

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
  CATALOG_EDIT_TEST_BUNDLES=$T/bundles bash tests/okderators-oadp-build/catalog-edit.sh
```

A test bundle needs `schema: olm.bundle`, `name: oadp-operator.v1.6.0-<DATE>`, `package: oadp-operator`,
`image`, `relatedImages`, an `olm.package` property with that version, and `olm.bundle.object` properties
for the CRDs and a CSV of the same name (`opm render` of the operator pin's `bundle/`, with the CSV
renamed, works: `opm` renders a bundle directory).

## What differs from the NMState Job

- Runs `oadp/build.sh` (`NAMESPACE=oadp`, registry `<BASE_REGISTRY>/oadp`), one package, 19 images, one
  bundle; names are `oadp-build-*`: Job, log files, ConfigMap `oadp-build-scripts`, Template
  `okderators-oadp-build`, pod `oadp-log-reader`. The pod labels `okd-build/mode` and `okd-build/date`
  are the same, so a reader's affinity finds any of the Jobs' pods.
- `MODE=check` comes back, from the logging Job, with one change: `REUSE_DATE` names the full run and
  `DATE` is new, because a tag is never pushed twice and `oadp/build.sh` derives every `IMG_*` from
  `DATE`. So the images are copied to a new tag in the same repository, not to a `check-<branch>/`
  registry: no repository to clean up, no new blobs in zot, and `relatedImages` stay under
  `<BASE_REGISTRY>/oadp/` by the same digests.
- The pins are a table in `build.sh`, not only the branch's gitlinks: `operator_commit` compared `HEAD`
  with the gitlink, which a wrong branch passes. `pipeline-gitlinks` and `submodule-pins` are new, and
  `operator-commit` now covers two patched submodules with `HEAD~1`.
- The checks run earlier and stop the run: image checks before the push, pin checks before the build.
  `deinit` runs after verify, so a failing `deinit` cannot hide the bundle's results.
- `RESULT PASS` also needs a `PASS` line for every check of the mode by name, and a `DATE` whose log
  file exists is refused.
- `bundle-objects` compares against the operator pin's own list instead of a fixed two files. New:
  `no-konveyor`, `okd-strings`, `image-smoke`, `velero-version`, `vm-file-restore-env`, `base-images`.
  Gone: `no-imagestream` (`bundle-objects` covers it), `csv-code-release` and `nmstate-rpm`.
- External images: only `IMG_CLI`, by digest.
- `build.sh` is written for bash 3.2 as well, like `catalog-edit.sh` (variables in files instead of
  associative arrays), and sourcing it does not run `main`, so its checks ran against fixtures on the
  Mac before the first real build.
- `catalog-edit.sh`: the entry is added instead of replacing the broken one, one data column fewer, a
  different pair of negative controls, and branch names `release-N.M` because `release-5.0` is one.
  `catalog-walk.py` is unchanged (its `--hop` is unused here).

## How it runs, and why

Unchanged from the logging Job, which documents it in full: privileged podman in a pod (SCC
`privileged` through the RoleBinding there), one PVC with two `subPath` mounts, pushes to zot
`okd-test/` only with no registry credentials in the pod, one run at a time via `flock`, no tag
pushed twice, `backoffLimit: 0`, requests 2 CPU / 8 Gi, limits 14 CPU / 48 Gi, podman image pinned by
digest. The builds run one after another, so the limits that carried GitOps' twelve images carry these.
What changes is the deadline: 24 h of `activeDeadlineSeconds` instead of 12. GitOps took 97 minutes for
twelve images on throttled cores; this is nineteen, `go build -a` on most, and ten cross-compiled
binaries, so expect several hours while the `powersave-experimental` Tuned profile pins cores at minimum
frequency, and a deadline kill would lose all of it.
