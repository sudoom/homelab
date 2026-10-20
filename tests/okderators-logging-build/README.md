# okderators Logging 6.6: in-cluster build Job

A one-off Job that runs okd-operator-pipeline's own `cluster-logging/build.sh` on this
cluster and pushes the images and bundles to zot under `okd-test/`. Container builds do not
run on the Mac: it is arm64, and these images have to install on the amd64 nodes (CLAUDE.md,
"Container image builds run on the cluster"). This cluster's logging will run the images built
here until upstream CI publishes its own.

Not ArgoCD-managed. The operator applies, runs and deletes everything in this directory.
Chronology and results: `blog/blog-okderators-logging-6.6-draft.md`.

**Status 2026-10-20:** written and validated offline (`bash -n`, `kubeconform`); not run yet.

## Files

| file | what |
|---|---|
| `manifests.yaml` | Namespace `okd-build` (PSA `privileged`, SCC label sync off), ServiceAccount `builder` (no token), RoleBinding to ClusterRole `system:openshift:scc:privileged`, PVC `build-storage` 100Gi `ceph-nvme-block` RWO |
| `kustomization.yaml` | `manifests.yaml` plus ConfigMap `build-scripts`, generated from `build.sh`, `catalog-edit.sh` and `catalog-walk.py` (no hash suffix), so each script exists once |
| `build.sh` | the Job's entry point, mounted at `/scripts/build.sh` |
| `catalog-edit.sh` | `MODE=catalog`: the okderators catalog edit, its checks and the test catalog image ([below](#modecatalog)) |
| `catalog-walk.py` | the upgrade-graph walker `catalog-edit.sh` runs (Python 3, standard library only) |
| `job-template.yaml` | OpenShift Template for one run: Job `build-<MODE>-<DATE>` |
| `log-reader.yaml` | read-only pod for the log files on the PVC once a build pod is gone |

## Before each run (operator)

- **zot has at least 5 GiB free.** The pod has no API rights, so this check stays outside the
  Job. In the console (Observe → Metrics):
  `kubelet_volume_stats_available_bytes{namespace="zot",persistentvolumeclaim="data-zot-0"}`.
  A full zot breaks image pulls for the whole cluster.
- **Before the first apply: `nvme-replicated` has room for the PVC** (per-pool `MAX AVAIL` from
  `ceph df`, not the cluster-level figure). The RBD image is thin; the `DISK` lines show what a
  build really writes.

## Apply, run, read, delete

```bash
# static part: namespace, SA, RBAC, PVC, ConfigMap (re-run after editing any of the scripts)
oc apply -k tests/okderators-logging-build/

# one run
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-logging-build/job-template.yaml \
  -p MODE=full -p DATE=$DATE | oc -n okd-build create -f -

# watch, then pull out the contract lines
oc -n okd-build logs -f job/build-full-$DATE
oc -n okd-build logs job/build-full-$DATE | grep -E '^(STEP|DISK|PUSHED|CHECK|RESULT) '

# step durations (STEP times are epoch seconds)
oc -n okd-build logs job/build-full-$DATE | awk '$1=="STEP" && $3=="START" {s[$2]=$4} $1=="STEP" && $3=="END" {print $2, $4-s[$2] "s"}'
```

`check` reuses the `DATE` of a full run: `-p MODE=check -p DATE=<that DATE> -p PIPELINE_BRANCH=<branch>`.

Cleanup:

```bash
# a finished run (its contract and full log stay on the PVC, see below)
oc -n okd-build delete job build-full-$DATE

# all build work done: namespace, PVC (reclaimPolicy Delete removes the RBD image), Jobs
oc delete -k tests/okderators-logging-build/
```

Test images in zot are deleted by digest once nothing runs on them; the `PUSHED` lines carry
the digests. zot's GC (`gcDelay` 1h, `gcInterval` 24h) then frees the blobs; measure zot again.

```bash
# contract file saved with the log-reader commands below
awk '$1=="PUSHED" {print $2}' build-full-$DATE.contract | sed 's/:[^:@/]*@/@/' \
  | while read -r ref; do skopeo delete "docker://$ref"; done   # wherever skopeo runs
```

## Reading the logs later

The pod log is not enough on its own. At `activeDeadlineSeconds` the Job controller deletes
the pod, and with it the log; the kubelet rotates container logs at 50Mi and `oc logs` returns
only the current file, while the pipeline's `set -x` traces the whole release-info JSON on every
`./build.sh` call. So `build.sh` also writes, on the PVC:

- `/work/logs/build-<MODE>-<DATE>.contract`: every contract line, appended synchronously before it
  is printed, including the final `RESULT` (also the `RESULT FAIL <step> (terminated)` of a
  deadline kill);
- `/work/logs/build-<MODE>-<DATE>.log`: everything the run printed, copied by `tee`.

Read them with the read-only `log-reader` pod (PVC attached and mounted read-only; it only
sleeps, and ends by itself after an hour). It is RWO storage: while a build pod runs, the reader
has to land on that pod's node, which its pod affinity prefers.

```bash
oc -n okd-build create -f tests/okderators-logging-build/log-reader.yaml
oc -n okd-build wait --for=condition=Ready pod/log-reader --timeout=5m
oc -n okd-build exec log-reader -- ls -l /work/logs
oc -n okd-build exec log-reader -- cat /work/logs/build-full-$DATE.contract > build-full-$DATE.contract
oc -n okd-build exec log-reader -- cat /work/logs/build-full-$DATE.log > build-full-$DATE.log
oc -n okd-build delete pod log-reader
```

The files are deleted with the PVC (`oc delete -k`), so copy what the blog draft needs first.
A validation failure (bad `MODE`, `DATE` or `BASE_REGISTRY`) happens before the files are opened
and is in the pod log only.

## Modes

| `MODE` | does |
|---|---|
| `full` | tools → podman setup → clone `PIPELINE_BRANCH` → tag check → `init` → `build_containers` → `push_containers` → `build_bundle` → `deinit` → verify. Each pipeline step is a separate `./build.sh <step>` run, the same functions `main` runs when given no arguments, so each is timed. |
| `check` | no image build. `skopeo copy --all` of every `IMG_*` image of `DATE` from `${BASE_REGISTRY}/cluster-logging/` to `${BASE_REGISTRY}/check-<branch>/cluster-logging/` (zot dedupes the blobs), then `init` → `build_bundle` → `deinit` against that registry, then verify. For the other pipeline branches, and to redo bundles and verify after a fix without rebuilding images. |
| `catalog` | tools → podman setup → tag check of `${BASE_REGISTRY}/logging-catalog:<DATE>` → `/scripts/catalog-edit.sh` in an empty `/work/run`: the 6.6 entries added to each okderators catalog branch in `CATALOG_BRANCHES`, `opm validate`, graph walk, negative control, then the test catalog image. Its `CHECK` lines go into the contract, a `CHECK … FAIL` or a non-zero exit fails the run, and `build.sh` prints `PUSHED` for the catalog image. [Details below](#modecatalog). |

`./build.sh update` never runs (it moves the gitlinks to branch tips).

## Parameters

| parameter | default | meaning |
|---|---|---|
| `MODE` | required | `full`, `check` or `catalog` |
| `DATE` | required | `YYYY-MM-DD-HHMMSS`; the image tags end in `<MAJOR>.<MINOR>.0-<DATE>`. New for every full run. |
| `PIPELINE_REPO` | `https://github.com/sudoom/okd-operator-pipeline.git` | |
| `PIPELINE_BRANCH` | `cluster-logging-6.6` | |
| `BASE_REGISTRY` | `zot.apps.okd.sudops.pl/okd-test` | anything outside `zot.apps.okd.sudops.pl/okd-test` is refused |
| `CATALOG_BRANCHES` | empty | `catalog` only: okderators-catalog-index branches, e.g. `release-4.20 release-4.21 release-4.22`; must include `release-4.21` (the test catalog's source) |
| `BUNDLES` | empty | `catalog` only: the two bundle refs (cluster-logging and loki-operator, any order), as the full run's `PUSHED` lines print them |

## Output contract

Free-form output (the pipeline's own `set -x` trace, `INFO`, `ERROR`) is interleaved with
these lines in the pod log and the `.log` file; the `.contract` file holds only these lines:

| line | meaning |
|---|---|
| `STEP <name> START\|END <seconds>` | epoch seconds; the duration is END − START |
| `DISK <bytes>` | `du -sx` of `/var/lib/containers` + `/work`, after every step |
| `PUSHED <ref>@<digest> <bytes>` | after `push_containers` / the `check` copy and after `build_bundle`; in `catalog`, for the catalog image. Digest = sha256 of the manifest bytes zot serves; bytes = config + layer sizes in that manifest (compressed, as stored), summed over the children of an index |
| `CHECK <name> PASS\|FAIL <detail>` | verify, below; in `catalog`, the checks of [MODE=catalog](#modecatalog) |
| `RESULT PASS\|FAIL <reason>` | the last line. On an error, or on SIGTERM (deadline, deleted Job), the reason is the step that was running. A SIGTERM is handled while a pipeline step, a skopeo copy or the catalog script runs; during a shorter command it waits for that command, and the kubelet's SIGKILL 30 s after SIGTERM leaves no `RESULT` line at all. |

## Verify

After the bundles are pushed, `opm render <bundle repo>@<digest>` for every `IMG_BUNDLE*`
image, and per package:

| check | passes when |
|---|---|
| `max-openshift-version/<pkg>` | `olm.maxOpenShiftVersion` is `4.23` |
| `images/<pkg>` | every `relatedImages[].image` and every `RELATED_IMAGE_*` / `*_IMAGE` env value in the CSV is `${BASE_REGISTRY}/…@sha256:…` (no `quay.io/openshift-logging`, no `registry.redhat.io`, no tags). One exception: the kube-rbac-proxy image `build.sh` resolves from the OKD release payload (`quay.io/okd/scos-content@sha256:…`), accepted only if it is exactly that value and by digest |
| `images-built/<pkg>` | each of those `${BASE_REGISTRY}` references is a digest this run pushed or copied |
| `kube-rbac-proxy-from-payload/<pkg>` | printed (always PASS) when the bundle carries the payload kube-rbac-proxy, with the exact reference, so the log records which OKD release it came from. The 6.6.1 loki-operator has no kube-rbac-proxy sidecar (the manager serves its metrics on 8443 itself), so the line is absent for both bundles |
| `branding/<pkg>` | the okderators OKDify standard, measured against the accepted okderators 6.5.0 CSVs: no `valid-subscription` anywhere (keys or values), no `support` annotation naming Red Hat (`red ?hat`, any case), and no `Red Hat` line outside `BRANDING_BASELINE` in `build.sh`. That baseline lists four fixed substrings the 6.5.0 CSVs carry too: the loki-operator maintainer `Red Hat, AOS Logging` and three cluster-logging API field descriptions. The text checked is every string value and key of the CSV JSON, split at its own newlines; the PASS detail counts the baseline hits allowed |
| `provider/<pkg>` | `spec.provider.name` is `OKD Community` |
| `passthrough-gateway/loki-operator` | only if the cloned `build.sh` defines `IMG_PASSTHROUGH_GATEWAY`: the loki-operator CSV carries `RELATED_IMAGE_PASSTHROUGH_GATEWAY` pointing at that image |

The image list is never written down here: `build.sh` sources the cloned
`cluster-logging/build.sh` and reads its `IMG_*` variables. Any `FAIL` ends the run
`RESULT FAIL`.

## MODE=catalog

Adds the two 6.6 bundles of a full run to the okderators catalog branches, proves the upgrade
graphs, and builds the test catalog image for the homelab's `okd-test-logging` CatalogSource (next step).

```bash
DATE=$(date -u +%Y-%m-%d-%H%M%S)      # new for the catalog run; it only names the image tag
oc process --local -f tests/okderators-logging-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.20 release-4.21 release-4.22' \
  -p BUNDLES='<loki bundle ref@digest> <clo bundle ref@digest>' | oc -n okd-build create -f -
oc -n okd-build logs -f job/build-catalog-$DATE
oc -n okd-build logs job/build-catalog-$DATE | grep -E '^(STEP|PUSHED|CHECK|RESULT) '
```

`BUNDLES` takes the two bundle refs from the full run's `PUSHED` lines
(`…/cluster-logging/loki-operator-bundle:6.6.0-<DATE>@sha256:…` and
`…/cluster-logging/operator-bundle:6.6.0-<DATE>@sha256:…`). The tag is dropped before use: opm
v1.74.0 refuses a reference with both a tag and a digest (`Docker references with both a tag and
digest are currently not supported`), so the catalog references each bundle by digest only.

First, once: each bundle is rendered and must be a `cluster-logging` or `loki-operator` bundle
(one of each) with a `6.6.*` version (`BUNDLE_MINOR` in the script, which also sets the
skipRange's upper bound). Anything else, say a 6.5 bundle pasted by mistake, stops the run before
any clone, edit or push.

Then for each branch, in a depth-1 clone of `okd-project/okderators-catalog-index`:

1. Each package (`cluster-logging`, `loki-operator`) must have exactly one head in channel `alpha`,
   computed as operator-registry does: the entry no other entry names in `replaces` or `skips`.
   That head is what the new entry replaces (6.5.0 on 4.20, 6.3.0 on 4.21/4.22), read from the
   tree, not written in the script.
2. The bundles go in with the branch's own `hack/add-bundle.sh`. On `release-4.2x` that script
   `podman create`s the bundle to read the CSV name, which fails for a bundle built `FROM scratch`
   with no `CMD` (every bundle the pipeline builds; okderators-catalog-index PR #59, open, drops
   that step). The script then writes the same file the same way: `opm render <bundle> -o yaml` to
   `catalog/<package>/<CSV name>.yaml`. The `bundles-<branch>` detail says which path ran.
3. `yq` appends one entry per package: `name: <6.6 CSV>`, `replaces: <head>`,
   `skipRange: '>=6.2.0-0 <6.6.0'`.

| check | passes when |
|---|---|
| `bundle-version-<pkg>` | once, before any branch: the bundle for `<pkg>` exists, is the only one, and has a `6.6.*` version |
| `bundles-<branch>` | adding the bundles created exactly one new file per package and changed no tracked file (a tree that already has them fails here) |
| `edit-<branch>-<pkg>` | one head before the edit, the 6.6 CSV not in the channel yet, and the package file changed by exactly the three appended lines (plus a final newline where it had none) |
| `opm-validate-<branch>` | `opm validate catalog` passes on the edited tree |
| `walk-<branch>-<pkg>` | `catalog-walk.py`: from every channel entry, from `<pkg>.v6.5.0-2026-06-04-101319` (what the homelab runs; absent from the 4.21/4.22 catalogs) and from `<pkg>.v6.2.0-2025-05-25-184240` (a past entry, today named only in the 6.2.0-2025-05-26 entry's `skips`), every OLM v0 upgrade edge (`replaces`, `skips`, version inside `skipRange`) ends at the single head with no other dead end on the way, and the head has the highest version. The head's own version `6.6.0-<DATE>` lies inside its own `skipRange` (a prerelease sorts below `6.6.0`); the walker does not count that as an edge. `opm validate` cannot confirm it (it parses a skipRange but never evaluates it); OLM in use does: catalog-index:4.21, served on this cluster, already has `ingress-node-firewall.v4.21.0-2026-05-19-130000` with entry skipRange `>=4.11.0 <4.21.0`, and here `oadp-operator.v1.5.0-2026-01-05-165341` (CSV `olm.skipRange` `>=1.4.0 <1.5.3`) and `cluster-logging.v6.5.0-2026-06-04-101319` (`>=6.3.0-0 <6.5.0`) sit at `AtLatestKnown` |
| `negative-control-<branch>` | a copy of the edited tree with the new entries' `replaces` removed fails `opm validate` with `multiple channel heads found in graph: <old head>, <6.6 CSV>` for both packages (`skipRange` does not count as an edge there) |
| `negative-control-skiprange-<branch>` | only where the homelab's 6.5.0 CSVs are absent from the channel (4.21, 4.22): a copy of the edited tree with the new entries' `skipRange` removed still passes `opm validate`, and the walker strands both 6.5.0 CSVs. This is the failure `opm validate` cannot see and the walker exists for |
| `opm-validate-image` | the image context passes `opm validate`: the edited `release-4.21` tree, `cluster-logging` and `loki-operator` only |
| `catalog-image` | the image, built from `release-4.21`'s own `catalog.Containerfile` with its `FROM quay.io/operator-framework/opm:latest` pinned to `quay.io/operator-framework/opm@sha256:b32d3891616662620da08d7f0ec42c2e69fa2de43427dc975d35b12f7a969a0f` (the v1.74.0 index, which `:latest` pointed at on 2026-10-20), is pushed, rendered back from zot with `opm render`, and has exactly the two packages, the 6.6 heads and passing walks. It is not built when an earlier check failed |

The push target is fixed in `build.sh`: `${BASE_REGISTRY}/logging-catalog:${DATE}`, passed through
`guard_registry` and the tag check (the tag must not exist yet) and handed to `catalog-edit.sh` as
`CATALOG_IMAGE`, which itself refuses anything outside `zot.apps.okd.sudops.pl/okd-test/`.
`build.sh` prints the `PUSHED` line for it, also when a later check failed, so it can be deleted.
Left in `/work/run` until the next run: `<branch>.diff` (the whole edit per branch, for the catalog
PRs), the `render-*.json` files, `catalog-edit.log` and the image context `catalog-image/`.

Test mode runs the same script on a laptop, without the Job, images or podman (bash 3.2 is
enough). `CATALOG_EDIT_TEST_BUNDLES` points at a directory of `olm.bundle` YAML documents that
replace the add-bundle step; the image context is assembled and validated but not built:

```bash
# T=<scratch dir>; CAT=<a clone of okderators-catalog-index>; opm v1.74.0 and yq v4 on PATH
git init -q --bare $T/mirror.git
git -C $T/mirror.git fetch -q $CAT refs/remotes/origin/release-4.20:refs/heads/release-4.20 \
  refs/remotes/origin/release-4.21:refs/heads/release-4.21 refs/remotes/origin/release-4.22:refs/heads/release-4.22
mkdir $T/run
RUN_DIR=$T/run CATALOG_REPO=$T/mirror.git CATALOG_BRANCHES='release-4.20 release-4.21 release-4.22' \
  CATALOG_EDIT_TEST_BUNDLES=$T/bundles bash tests/okderators-logging-build/catalog-edit.sh
```

A test bundle needs `schema: olm.bundle`, `name`, `package`, `image` and an `olm.package` property
with `packageName` and `version` (for example `6.6.0-2026-10-20-000000`).

## How it runs, and why

- **Privileged podman in a pod.** `quay.io/podman/stable` is built for nested use: its
  `containers.conf` runs containers in the host namespaces with `cgroups="disabled"` and
  cgroupfs, and the image sets `BUILDAH_ISOLATION=chroot`, so `RUN` steps need no OCI runtime,
  cgroup or network namespace. Privileged is for the overlay mounts. The namespace is PSA
  `privileged` with the SCC label syncer off, the RoleBinding grants the `privileged` SCC, and
  the pod asks for it with `openshift.io/required-scc`.
- **One PVC, two mounts.** `build-storage` is mounted by `subPath` at `/var/lib/containers`
  (podman's graph root) and `/work` (clones, tools, Go caches, `TMPDIR`), so nothing large lands
  on a node's root disk (node5's carries a mon and sits at the `MON_DISK_LOW` line). `build.sh`
  swaps the image's fuse-overlayfs for the kernel overlay driver: the graph root is ext4 on RBD,
  not the container's own overlay, so native overlay works and is faster. If `podman-setup`
  fails on the overlay mount, put `mount_program = "/usr/bin/fuse-overlayfs"` back in the
  generated `storage.conf`. Only the dnf packages land in the container's own layer.
- **Pushes go to zot `okd-test/` only.** There are no registry credentials in the pod, and
  `build.sh` refuses a `BASE_REGISTRY` outside `zot.apps.okd.sudops.pl/okd-test` and any `IMG_*`
  the cloned `build.sh` would push elsewhere. zot mirrors quay.io, docker.io, ghcr.io and
  registry.k8s.io for the whole cluster in one namespace, so a push to a real upstream path
  would shadow that image cluster-wide.
- **One run at a time.** Two runs would wipe each other's `/work/run` and share one podman graph
  root, which containers/storage does not support; RWO only keeps pods on other nodes away. So
  `build.sh` takes `flock -n` on `/work/.lock` before it touches `/work/run`, the caches or the
  graph root, and a second run ends `RESULT FAIL another run holds /work/.lock`. The kernel
  drops the lock when the pod dies; the log reader takes no lock.
- **No tag is pushed twice.** `full` stops with `RESULT FAIL tag exists` when
  `${BASE_REGISTRY}/cluster-logging/operator:<MAJOR>.<MINOR>.0-<DATE>` already exists.
- **Job shape.** `backoffLimit: 0` (a failed build is read, not retried), 12 h
  `activeDeadlineSeconds`, no `ttlSecondsAfterFinished` (the log stays until read), requests
  2 CPU / 8 Gi, limits 14 CPU / 48 Gi, no node pinning. The image is
  `quay.io/podman/stable:v5.8.9@sha256:dc02649067d5…` (the manifest list the tag pointed at on
  2026-10-20): quay re-pushes version tags, so the digest pins it. Expect about 3× longer builds while the
  `powersave-experimental` Tuned profile pins cores at their minimum frequency.

Tools, all pinned and checked against the sha256 their project publishes:

| tool | version | checksum source |
|---|---|---|
| Go | 1.26.10 | `https://go.dev/dl/?mode=json` |
| operator-sdk | v1.36.1 (what the pipeline's CI installs) | release `checksums.txt` |
| opm | v1.74.0 | release `checksums.txt` |
| yq | v4.54.1 | release `checksums` (SHA-256 column) |
| kustomize | v5.8.1 (loki's own bingo pin) | release `checksums.txt` |
| oc | 4.21.36 (`stable-4.21` on 2026-10-20) | `mirror.openshift.com/…/4.21.36/sha256sum.txt` |
| git, make, jq, skopeo, python3 | Fedora packages of the podman image | dnf |
